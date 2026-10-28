// Search for files on this Mac by name and folder.
//
// Celorga keeps its own index of file and folder names under the configured
// roots (by default the home folder plus iCloud Drive and the cloud storage
// providers under ~/Library/CloudStorage), so file search works even when
// Spotlight is turned off. The index is machine-local and disposable: it lives
// under the Celorga index home, never in a corpus, and can be rebuilt at any
// time from the file system.
//
// Results group repeat downloads and copies ("Report (3).pdf", "Report copy.pdf",
// and same-named documents in different folders) into one family whose newest
// member is shown first.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { brandEnv } from "./brandNames.js";

export const FILE_SEARCH_CONFIG_SCHEMA = "org2:file-search-config:v1";
export const FILE_SEARCH_INDEX_SCHEMA = "org2:file-search-index:v1";
export const FILE_SEARCH_RESULT_SCHEMA = "org2:file-search-result:v1";

export type FileSearchConfig = {
  schema: typeof FILE_SEARCH_CONFIG_SCHEMA;
  /** Folders to index; `~` expands to the home folder. Missing folders are skipped. */
  roots: string[];
  /** Extra exclusions: a bare name skips that name anywhere; a path skips that folder. */
  exclude: string[];
  /** Index dot files and dot folders. */
  includeHidden: boolean;
};

export type FileSearchKind =
  | "folder"
  | "pdf"
  | "document"
  | "spreadsheet"
  | "presentation"
  | "image"
  | "video"
  | "audio"
  | "archive"
  | "installer"
  | "text"
  | "code"
  | "app"
  | "other";

export type FileSearchCopy = {
  path: string;
  directory: string;
  size: number;
  modifiedAt: string;
  /** True when the copy has the same bytes as the family's newest file; absent when not checked. */
  identical?: boolean;
};

export type FileSearchHit = {
  path: string;
  name: string;
  directory: string;
  kind: FileSearchKind;
  extension: string;
  isDirectory: boolean;
  size: number;
  modifiedAt: string;
  score: number;
  /** Older copies of this file (repeat downloads, "copy" files, same-named documents elsewhere). */
  copyCount: number;
  copies: FileSearchCopy[];
};

export type FileSearchIndexStatus = {
  path: string;
  builtAt: string | null;
  building: boolean;
  entries: number;
  roots: string[];
  stale: boolean;
};

export type FileSearchPayload = {
  schema: typeof FILE_SEARCH_RESULT_SCHEMA;
  query: string;
  index: FileSearchIndexStatus;
  results: FileSearchHit[];
  elapsedMs: number;
};

export type FileSearchOptions = {
  query: string;
  limit?: number;
  kinds?: FileSearchKind[];
  extensions?: string[];
  /** Return every copy as its own result instead of grouping. */
  group?: boolean;
  /** Compare copies' bytes with the newest file (local files up to 64 MB). */
  checkIdentical?: boolean;
  now?: number;
};

// ---------------------------------------------------------------------------
// Locations and configuration

function expandHome(input: string, homeDir = os.homedir()): string {
  if (input === "~") return homeDir;
  if (input.startsWith("~/")) return path.join(homeDir, input.slice(2));
  return input;
}

export function abbreviateHome(input: string, homeDir = os.homedir()): string {
  if (input === homeDir) return "~";
  if (input.startsWith(`${homeDir}/`)) return `~/${input.slice(homeDir.length + 1)}`;
  return input;
}

/** Machine-local folder for the file search config and index. */
export function fileSearchHome(): string {
  const configured = String(brandEnv("ORG2_FILES_HOME") || "").trim();
  if (configured) return path.resolve(expandHome(configured));
  return path.join(os.homedir(), ".org2", "files");
}

export function fileSearchConfigPath(home = fileSearchHome()): string {
  return path.join(home, "config.json");
}

export function fileSearchIndexPath(home = fileSearchHome()): string {
  return path.join(home, "index-v1.json");
}

export const DEFAULT_FILE_SEARCH_ROOTS = [
  "~",
  "~/Library/Mobile Documents/com~apple~CloudDocs",
  "~/Library/CloudStorage",
];

export function defaultFileSearchConfig(): FileSearchConfig {
  return { schema: FILE_SEARCH_CONFIG_SCHEMA, roots: [...DEFAULT_FILE_SEARCH_ROOTS], exclude: [], includeHidden: false };
}

function stringList(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null;
  return value.filter((item): item is string => typeof item === "string" && item.trim() !== "").map((item) => item.trim());
}

export function readFileSearchConfig(home = fileSearchHome()): FileSearchConfig {
  const file = fileSearchConfigPath(home);
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return defaultFileSearchConfig();
    throw new Error(`file search config at ${file} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error(`file search config at ${file} must be a JSON object`);
  }
  const record = raw as Record<string, unknown>;
  const defaults = defaultFileSearchConfig();
  return {
    schema: FILE_SEARCH_CONFIG_SCHEMA,
    roots: stringList(record.roots) ?? defaults.roots,
    exclude: stringList(record.exclude) ?? [],
    includeHidden: record.includeHidden === true,
  };
}

/** File names are private: the folder and files are readable by this user only. */
function writeFileAtomic(file: string, text: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  fs.writeFileSync(temporary, text, { encoding: "utf8", mode: 0o600 });
  fs.renameSync(temporary, file);
}

export function writeFileSearchConfig(config: FileSearchConfig, home = fileSearchHome()): string {
  const file = fileSearchConfigPath(home);
  writeFileAtomic(file, `${JSON.stringify({ ...config, schema: FILE_SEARCH_CONFIG_SCHEMA }, null, 2)}\n`);
  return file;
}

/** Stored form of a folder: absolute, with the home folder written as `~`. */
export function normalizeConfigPath(input: string, homeDir = os.homedir()): string {
  const trimmed = input.trim();
  if (!trimmed.includes("/") && trimmed !== "~") return trimmed;
  return abbreviateHome(path.resolve(expandHome(trimmed, homeDir)), homeDir);
}

function configHash(config: FileSearchConfig): string {
  return crypto.createHash("sha256").update(JSON.stringify([config.roots, config.exclude, config.includeHidden])).digest("hex").slice(0, 16);
}

// ---------------------------------------------------------------------------
// What to index

/** Names never worth descending into: build output, dependency caches, VCS data. */
const SKIPPED_NAMES = new Set([
  "node_modules", ".git", ".hg", ".svn", ".Trash", ".Trashes", ".build", "DerivedData", "__pycache__",
  ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", ".gradle", ".cargo", ".rustup", ".npm",
  ".cache", "Pods", ".next", ".turbo", ".DocumentRevisions-V100", ".Spotlight-V100", ".fseventsd",
  ".DS_Store", ".localized", "Icon\r",
]);

/** Folder-shaped documents and bundles: indexed as one item, never descended into. */
const PACKAGE_EXTENSIONS = new Set([
  "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary",
  "pages", "numbers", "key", "rtfd", "xcodeproj", "xcworkspace", "playground", "sparsebundle", "fcpbundle",
  "logicx", "band", "imovielibrary", "dSYM", "xcarchive", "scriptd", "workflow", "mpkg", "pkg",
]);

const KIND_BY_EXTENSION: Record<string, FileSearchKind> = {};
function assignKind(kind: FileSearchKind, extensions: string): void {
  for (const extension of extensions.split(" ")) KIND_BY_EXTENSION[extension] = kind;
}
assignKind("pdf", "pdf");
assignKind("document", "doc docx pages rtf rtfd odt epub");
assignKind("spreadsheet", "xls xlsx xlsm numbers csv tsv ods");
assignKind("presentation", "ppt pptx key odp");
assignKind("image", "png jpg jpeg gif heic heif webp tif tiff bmp svg psd ai sketch fig raw cr2 nef dng ico icns");
assignKind("video", "mov mp4 m4v avi mkv webm wmv");
assignKind("audio", "mp3 m4a wav aiff aif flac ogg aac caf");
assignKind("archive", "zip tar gz tgz bz2 xz 7z rar");
assignKind("installer", "dmg pkg mpkg iso");
assignKind("text", "txt md markdown org rst log tex");
assignKind("code", "js mjs cjs ts tsx jsx swift py rb go rs java kt c h cc cpp hpp m mm cs php sh zsh bash fish sql json yaml yml toml xml html css scss lua pl r hs ex exs elm vue svelte gradle lock plist");
assignKind("app", "app");

const DOCUMENT_KINDS = new Set<FileSearchKind>(["pdf", "document", "spreadsheet", "presentation", "image", "video", "audio", "archive", "installer"]);

export const FILE_SEARCH_KINDS: FileSearchKind[] = [
  "folder", "pdf", "document", "spreadsheet", "presentation", "image", "video", "audio", "archive", "installer", "text", "code", "app", "other",
];

const KIND_ALIASES: Record<string, FileSearchKind> = {
  folder: "folder", folders: "folder", dir: "folder", directory: "folder",
  pdf: "pdf", pdfs: "pdf",
  doc: "document", docs: "document", document: "document", documents: "document", word: "document",
  sheet: "spreadsheet", sheets: "spreadsheet", spreadsheet: "spreadsheet", spreadsheets: "spreadsheet", excel: "spreadsheet", table: "spreadsheet",
  slides: "presentation", deck: "presentation", presentation: "presentation", presentations: "presentation", keynote: "presentation", powerpoint: "presentation",
  image: "image", images: "image", photo: "image", photos: "image", picture: "image", screenshot: "image",
  video: "video", videos: "video", movie: "video",
  audio: "audio", music: "audio", sound: "audio", recording: "audio",
  archive: "archive", archives: "archive", zip: "archive",
  installer: "installer", dmg: "installer",
  text: "text", note: "text", notes: "text",
  code: "code", source: "code",
  app: "app", apps: "app", application: "app",
  other: "other",
};

export function parseFileSearchKind(input: string): FileSearchKind | null {
  return KIND_ALIASES[input.trim().toLowerCase()] ?? null;
}

function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return "";
  return name.slice(dot + 1).toLowerCase();
}

export function fileSearchKind(name: string, isDirectory: boolean): FileSearchKind {
  if (isDirectory && !isPackageName(name)) return "folder";
  return KIND_BY_EXTENSION[extensionOf(name)] ?? "other";
}

function isPackageName(name: string): boolean {
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return false;
  const extension = name.slice(dot + 1);
  return PACKAGE_EXTENSIONS.has(extension) || PACKAGE_EXTENSIONS.has(extension.toLowerCase());
}

type IndexRules = {
  homeDir: string;
  roots: string[];
  excludedPaths: string[];
  excludedNames: Set<string>;
  includeHidden: boolean;
};

export function indexRules(config: FileSearchConfig, homeDir = os.homedir()): IndexRules {
  const roots: string[] = [];
  for (const root of config.roots) {
    const resolved = path.resolve(expandHome(root, homeDir));
    if (!roots.includes(resolved)) roots.push(resolved);
  }
  const excludedPaths = [path.join(homeDir, "Library")];
  const excludedNames = new Set(SKIPPED_NAMES);
  for (const entry of config.exclude) {
    if (entry.includes("/") || entry === "~") excludedPaths.push(path.resolve(expandHome(entry, homeDir)));
    else excludedNames.add(entry);
  }
  return { homeDir, roots, excludedPaths, excludedNames, includeHidden: config.includeHidden };
}

function isWithin(candidate: string, folder: string): boolean {
  return candidate === folder || candidate.startsWith(folder.endsWith("/") ? folder : `${folder}/`);
}

/**
 * A folder is excluded when it sits under an excluded path, unless a configured
 * root is at or below that path (so ~/Library/CloudStorage stays searchable
 * while the rest of ~/Library does not).
 */
function isExcludedPath(candidate: string, rules: IndexRules): boolean {
  for (const excluded of rules.excludedPaths) {
    if (!isWithin(candidate, excluded)) continue;
    const rescued = rules.roots.some((root) => isWithin(root, excluded) && isWithin(candidate, root) && root !== excluded);
    if (!rescued) return true;
  }
  return false;
}

function skipsName(name: string, rules: IndexRules): boolean {
  if (rules.excludedNames.has(name)) return true;
  return !rules.includeHidden && name.startsWith(".");
}

/** Whether a changed path should be reflected in the index. */
export function isIndexedPath(candidate: string, rules: IndexRules): boolean {
  const root = rules.roots.find((item) => isWithin(candidate, item));
  if (!root) return false;
  if (isExcludedPath(candidate, rules)) return false;
  const relative = path.relative(root, candidate);
  if (!relative) return true;
  const parts = relative.split(path.sep);
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index]!;
    if (skipsName(part, rules)) return false;
    if (index < parts.length - 1 && isPackageName(part)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// The in-memory index
//
// Entries are stored column by column (parallel arrays indexed by slot), and
// queries scan one joined string of every normalized name with indexOf, so a
// search over hundreds of thousands of files touches only the entries whose
// names actually contain a query word.

/** A materialized index entry, built only for query candidates. */
export type FileEntry = {
  slot: number;
  dir: string;
  name: string;
  isDirectory: boolean;
  size: number;
  mtimeMs: number;
  kind: FileSearchKind;
  /** Lower-cased name with punctuation runs collapsed to single spaces. */
  key: string;
};

const ASCII_TEXT = /^[\x20-\x7e]*$/;

export function normalizeText(input: string): string {
  if (ASCII_TEXT.test(input)) return input.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return input
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

const NOISY_SEGMENTS = [" dist ", " build ", " vendor ", " third party ", " site packages ", " target ", " out ", " tmp ", " temp ", " cache ", " caches ", " fixtures ", " test ", " tests ", " spec ", " backup ", " backups "];
const FAVORED_SEGMENTS = [" desktop ", " documents ", " downloads ", " clouddocs ", " cloudstorage ", " my drive ", " dropbox "];

type DirInfo = {
  path: string;
  /** Normalized path wrapped in spaces, for whole-word folder matches. */
  key: string;
  /** Location score shared by every entry in the folder. */
  bonus: number;
  inRepo: boolean;
  children: Map<string, number>;
};

const KIND_CODES = new Map<FileSearchKind, number>();

/** Drops every space; several times faster than a regular-expression replace on a large string. */
function withoutSpaces(text: string): string {
  const bytes = Buffer.from(text, "utf8");
  let length = 0;
  for (let index = 0; index < bytes.length; index += 1) {
    const byte = bytes[index]!;
    if (byte !== 0x20) bytes[length++] = byte;
  }
  return bytes.toString("utf8", 0, length);
}

export class FileSearchIndex {
  readonly rules: IndexRules;
  readonly configHash: string;
  builtAt: number | null = null;
  building = false;

  private names: string[] = [];
  private keys: string[] = [];
  private dirOf: number[] = [];
  private sizes: number[] = [];
  private mtimes: number[] = [];
  /** Kind code (index into FILE_SEARCH_KINDS) times two, plus one for a folder-shaped entry; -1 for a free slot. */
  private meta: number[] = [];
  private free: number[] = [];
  private dirs: DirInfo[] = [];
  private dirIds = new Map<string, number>();
  private repoRoots = new Set<string>();

  // Query structures. The joined haystack covers the entries present when it
  // was built; entries added since are checked one by one (`overlay`), and
  // entries removed or replaced since are skipped (`stale`). It is rebuilt
  // once enough has changed, so a stream of file changes never forces a
  // full rebuild on every query.
  private haystack: string | null = null;
  private flatHaystack = "";
  private offsets: Int32Array<ArrayBuffer> = new Int32Array(0);
  private flatOffsets: Int32Array<ArrayBuffer> = new Int32Array(0);
  private order: Int32Array<ArrayBuffer> = new Int32Array(0);
  private inHaystack: Uint8Array<ArrayBuffer> = new Uint8Array(0);
  private overlay = new Set<number>();
  private stale = new Set<number>();

  constructor(config: FileSearchConfig, homeDir = os.homedir()) {
    this.rules = indexRules(config, homeDir);
    this.configHash = configHash(config);
    if (KIND_CODES.size === 0) FILE_SEARCH_KINDS.forEach((kind, code) => KIND_CODES.set(kind, code));
  }

  get size(): number {
    return this.names.length - this.free.length;
  }

  /** Records that a folder is the top of a source repository. */
  markRepository(dir: string): void {
    this.repoRoots.add(dir);
  }

  private dirId(dir: string): number {
    let id = this.dirIds.get(dir);
    if (id !== undefined) return id;
    const key = ` ${normalizeText(dir)} `;
    let bonus = 0;
    if (FAVORED_SEGMENTS.some((segment) => key.includes(segment))) bonus += 2;
    if (NOISY_SEGMENTS.some((segment) => key.includes(segment))) bonus -= 4;
    bonus -= Math.max(0, dir.split("/").length - 4) * 0.4;
    let inRepo = false;
    for (let current = dir; ; current = path.dirname(current)) {
      if (this.repoRoots.has(current)) { inRepo = true; break; }
      const parentId = this.dirIds.get(current);
      if (parentId !== undefined && current !== dir) { inRepo = this.dirs[parentId]!.inRepo; break; }
      if (path.dirname(current) === current) break;
    }
    id = this.dirs.length;
    this.dirs.push({ path: dir, key, bonus, inRepo, children: new Map() });
    this.dirIds.set(dir, id);
    return id;
  }

  add(dir: string, name: string, isDirectory: boolean, size: number, mtimeMs: number): void {
    const dirId = this.dirId(dir);
    const children = this.dirs[dirId]!.children;
    const kindCode = KIND_CODES.get(fileSearchKind(name, isDirectory))!;
    const meta = kindCode * 2 + (isDirectory ? 1 : 0);
    const existing = children.get(name);
    if (existing !== undefined) {
      this.sizes[existing] = size;
      this.mtimes[existing] = mtimeMs;
      if (this.meta[existing] !== meta) {
        this.meta[existing] = meta;
      }
      return;
    }
    const key = normalizeText(name);
    this.addSlot(dirId, name, key, meta, size, mtimeMs);
  }

  private addSlot(dirId: number, name: string, key: string, meta: number, size: number, mtimeMs: number): void {
    const slot = this.free.pop() ?? this.names.length;
    this.names[slot] = name;
    this.keys[slot] = key;
    this.dirOf[slot] = dirId;
    this.sizes[slot] = size;
    this.mtimes[slot] = mtimeMs;
    this.meta[slot] = meta;
    this.dirs[dirId]!.children.set(name, slot);
    if (this.haystack !== null) {
      if (this.inHaystack[slot] === 1) this.stale.add(slot);
      this.overlay.add(slot);
      this.dropHaystackIfChurned();
    }
  }

  private removeSlot(slot: number): void {
    const dir = this.dirs[this.dirOf[slot]!]!;
    dir.children.delete(this.names[slot]!);
    this.names[slot] = "";
    this.keys[slot] = "";
    this.meta[slot] = -1;
    this.free.push(slot);
    if (this.haystack !== null) {
      if (this.inHaystack[slot] === 1) this.stale.add(slot);
      this.overlay.delete(slot);
      this.dropHaystackIfChurned();
    }
  }

  private dropHaystackIfChurned(): void {
    if (this.overlay.size + this.stale.size > 5_000) this.haystack = null;
  }

  /** Removes a path and, for a folder, everything under it. */
  removePath(target: string): void {
    const parent = this.dirIds.get(path.dirname(target));
    const slot = parent === undefined ? undefined : this.dirs[parent]!.children.get(path.basename(target));
    if (slot !== undefined) {
      const wasFile = (this.meta[slot]! & 1) === 0;
      this.removeSlot(slot);
      if (wasFile) return;
    }
    const prefix = `${target}/`;
    for (const dir of this.dirs) {
      if (dir.children.size > 0 && (dir.path === target || dir.path.startsWith(prefix))) {
        for (const child of [...dir.children.values()]) this.removeSlot(child);
      }
    }
  }

  namesIn(dir: string): string[] {
    const id = this.dirIds.get(dir);
    return id === undefined ? [] : [...this.dirs[id]!.children.keys()];
  }

  has(dir: string, name: string): boolean {
    const id = this.dirIds.get(dir);
    return id !== undefined && this.dirs[id]!.children.has(name);
  }

  entry(slot: number): FileEntry {
    const meta = this.meta[slot]!;
    return {
      slot,
      dir: this.dirs[this.dirOf[slot]!]!.path,
      name: this.names[slot]!,
      isDirectory: (meta & 1) === 1,
      size: this.sizes[slot]!,
      mtimeMs: this.mtimes[slot]!,
      kind: FILE_SEARCH_KINDS[meta >> 1]!,
      key: this.keys[slot]!,
    };
  }

  /** Every live slot. */
  slots(): number[] {
    const result: number[] = [];
    for (let slot = 0; slot < this.meta.length; slot += 1) if (this.meta[slot]! >= 0) result.push(slot);
    return result;
  }

  kindOf(slot: number): FileSearchKind {
    return FILE_SEARCH_KINDS[this.meta[slot]! >> 1]!;
  }

  dirInfo(slot: number): { key: string; bonus: number; inRepo: boolean } {
    return this.dirs[this.dirOf[slot]!]!;
  }

  mtime(slot: number): number {
    return this.mtimes[slot]!;
  }

  private ensureHaystack(): void {
    if (this.haystack !== null) return;
    const live = this.slots();
    const haystack = live.map((slot) => this.keys[slot]!).join("\n") + "\n";
    // Keys never contain newlines, so entry boundaries are the newlines.
    const boundaries = (text: string): Int32Array<ArrayBuffer> => {
      const offsets = new Int32Array(live.length + 1);
      let position = 0;
      for (let index = 0; index < live.length; index += 1) {
        offsets[index] = position;
        position = text.indexOf("\n", position) + 1;
      }
      offsets[live.length] = position;
      return offsets;
    };
    this.haystack = haystack;
    this.flatHaystack = withoutSpaces(haystack);
    this.offsets = boundaries(this.haystack);
    this.flatOffsets = boundaries(this.flatHaystack);
    this.order = Int32Array.from(live);
    this.inHaystack = new Uint8Array(this.meta.length);
    for (const slot of live) this.inHaystack[slot] = 1;
    this.overlay.clear();
    this.stale.clear();
  }

  /** Builds the query structures now instead of on the first query. */
  prepare(): void {
    this.ensureHaystack();
  }

  private static entryAt(offsets: Int32Array, position: number): number {
    let low = 0;
    let high = offsets.length - 2;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (offsets[middle]! <= position) low = middle;
      else high = middle - 1;
    }
    return low;
  }

  /** Slots whose normalized name contains `token` (with or without spaces). */
  nameMatches(token: string, into: Set<number>): void {
    this.ensureHaystack();
    const scan = (haystack: string, offsets: Int32Array): void => {
      let from = 0;
      while (true) {
        const found = haystack.indexOf(token, from);
        if (found < 0) return;
        const index = FileSearchIndex.entryAt(offsets, found);
        const slot = this.order[index]!;
        if (!this.stale.has(slot)) into.add(slot);
        from = offsets[index + 1]!;
      }
    };
    scan(this.haystack!, this.offsets);
    if (token.length > 1) scan(this.flatHaystack, this.flatOffsets);
    for (const slot of this.overlay) {
      const key = this.keys[slot]!;
      if (key.includes(token) || (token.length > 1 && key.replace(/ /g, "").includes(token))) into.add(slot);
    }
  }

  toJSON(): unknown {
    const live = this.slots();
    const dirIndex = new Map<number, number>();
    const dirs: string[] = [];
    const dir: number[] = [];
    const meta: number[] = [];
    const size: number[] = [];
    const mtime: number[] = [];
    const names: string[] = [];
    const keys: string[] = [];
    for (const slot of live) {
      let index = dirIndex.get(this.dirOf[slot]!);
      if (index === undefined) {
        index = dirs.length;
        dirs.push(this.dirs[this.dirOf[slot]!]!.path);
        dirIndex.set(this.dirOf[slot]!, index);
      }
      dir.push(index);
      meta.push(this.meta[slot]!);
      size.push(this.sizes[slot]!);
      mtime.push(Math.round(this.mtimes[slot]!));
      names.push(this.names[slot]!);
      keys.push(this.keys[slot]!);
    }
    return {
      schema: FILE_SEARCH_INDEX_SCHEMA,
      builtAt: this.builtAt === null ? null : new Date(this.builtAt).toISOString(),
      configHash: this.configHash,
      roots: this.rules.roots,
      repositories: [...this.repoRoots],
      dirs,
      // File names may contain newlines, so they stay an array; normalized keys never do.
      names,
      keys: keys.join("\n"),
      dir,
      meta,
      size,
      mtime,
    };
  }

  static fromJSON(raw: unknown, config: FileSearchConfig, homeDir = os.homedir()): FileSearchIndex | null {
    if (!raw || typeof raw !== "object") return null;
    const record = raw as Record<string, unknown>;
    if (record.schema !== FILE_SEARCH_INDEX_SCHEMA) return null;
    const { dirs, names, keys, dir, meta, size, mtime } = record;
    if (!Array.isArray(dirs) || !Array.isArray(names) || typeof keys !== "string" || !Array.isArray(dir) || !Array.isArray(meta) || !Array.isArray(size) || !Array.isArray(mtime)) return null;
    const index = new FileSearchIndex(config, homeDir);
    if (record.configHash !== index.configHash) return null;
    for (const repository of Array.isArray(record.repositories) ? record.repositories : []) {
      if (typeof repository === "string") index.markRepository(repository);
    }
    const keyList = keys.split("\n");
    if (keyList.length !== names.length || dir.length !== names.length) return null;
    const dirIds = (dirs as unknown[]).map((item) => (typeof item === "string" ? index.dirId(item) : -1));
    for (let position = 0; position < names.length; position += 1) {
      const dirId = dirIds[dir[position] as number];
      const name = names[position];
      const entryMeta = Number(meta[position]);
      if (dirId === undefined || dirId < 0 || typeof name !== "string" || !(entryMeta >= 0)) continue;
      if (index.dirs[dirId]!.children.has(name)) continue;
      index.addSlot(dirId, name, keyList[position]!, entryMeta, Number(size[position]) || 0, Number(mtime[position]) || 0);
    }
    const builtAt = typeof record.builtAt === "string" ? Date.parse(record.builtAt) : NaN;
    index.builtAt = Number.isFinite(builtAt) ? builtAt : null;
    return index;
  }
}

// ---------------------------------------------------------------------------
// Building

type DirectoryListing = Array<{ name: string; isDirectory: boolean; isSymbolicLink: boolean }>;

function listSync(dir: string): DirectoryListing | null {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).map((item) => ({
      name: item.name,
      isDirectory: item.isDirectory(),
      isSymbolicLink: item.isSymbolicLink(),
    }));
  } catch {
    return null;
  }
}

async function listAsync(dir: string): Promise<DirectoryListing | null> {
  try {
    const items = await fs.promises.readdir(dir, { withFileTypes: true });
    return items.map((item) => ({ name: item.name, isDirectory: item.isDirectory(), isSymbolicLink: item.isSymbolicLink() }));
  } catch {
    return null;
  }
}

type Stat = { size: number; mtimeMs: number; isDirectory: boolean };

function statSync(target: string): Stat | null {
  try {
    const stat = fs.lstatSync(target);
    return { size: stat.size, mtimeMs: stat.mtimeMs, isDirectory: stat.isDirectory() };
  } catch {
    return null;
  }
}

async function statAsync(target: string): Promise<Stat | null> {
  try {
    const stat = await fs.promises.lstat(target);
    return { size: stat.size, mtimeMs: stat.mtimeMs, isDirectory: stat.isDirectory() };
  } catch {
    return null;
  }
}

/** Entries to record for one listing, and the subfolders to walk next. */
function planListing(dir: string, listing: DirectoryListing, rules: IndexRules): { record: Array<{ name: string; isDirectory: boolean }>; descend: string[]; isRepository: boolean } {
  const record: Array<{ name: string; isDirectory: boolean }> = [];
  const descend: string[] = [];
  let isRepository = false;
  for (const item of listing) {
    if (item.name === ".git") isRepository = true;
    if (skipsName(item.name, rules)) continue;
    // Symbolic links are listed but never followed, so loops cannot form.
    const full = path.join(dir, item.name);
    if (item.isDirectory && !item.isSymbolicLink) {
      if (isExcludedPath(full, rules)) continue;
      record.push({ name: item.name, isDirectory: true });
      // A nested configured root is listed here but walked as its own root.
      if (rules.roots.includes(full)) continue;
      if (!isPackageName(item.name)) descend.push(full);
    } else {
      record.push({ name: item.name, isDirectory: false });
    }
  }
  return { record, descend, isRepository };
}

/** Synchronous full build, used by the one-shot CLI. */
export function buildFileSearchIndexSync(config: FileSearchConfig, homeDir = os.homedir()): FileSearchIndex {
  const index = new FileSearchIndex(config, homeDir);
  const stack = index.rules.roots.filter((root) => statSync(root)?.isDirectory);
  while (stack.length > 0) {
    const dir = stack.pop()!;
    const listing = listSync(dir);
    if (!listing) continue;
    const { record, descend, isRepository } = planListing(dir, listing, index.rules);
    if (isRepository) index.markRepository(dir);
    for (const item of record) {
      const stat = statSync(path.join(dir, item.name));
      if (!stat) continue;
      index.add(dir, item.name, item.isDirectory, item.isDirectory ? 0 : stat.size, stat.mtimeMs);
    }
    stack.push(...descend);
  }
  index.builtAt = Date.now();
  return index;
}

/**
 * Asynchronous build that keeps the event loop free, so a long-lived worker
 * can keep answering queries (including from the partly built index).
 */
export async function buildFileSearchIndex(target: FileSearchIndex, options: { concurrency?: number; shouldStop?: () => boolean } = {}): Promise<FileSearchIndex> {
  const rules = target.rules;
  const queue: string[] = [];
  for (const root of rules.roots) if ((await statAsync(root))?.isDirectory) queue.push(root);
  const concurrency = Math.max(1, options.concurrency ?? 16);
  let active = 0;
  await new Promise<void>((resolve) => {
    const pump = (): void => {
      if (options.shouldStop?.()) queue.length = 0;
      while (active < concurrency && queue.length > 0) {
        const dir = queue.pop()!;
        active += 1;
        void (async () => {
          const listing = await listAsync(dir);
          if (listing) {
            const { record, descend, isRepository } = planListing(dir, listing, rules);
            if (isRepository) target.markRepository(dir);
            const stats = await Promise.all(record.map((item) => statAsync(path.join(dir, item.name))));
            record.forEach((item, position) => {
              const stat = stats[position];
              if (stat) target.add(dir, item.name, item.isDirectory, item.isDirectory ? 0 : stat.size, stat.mtimeMs);
            });
            queue.push(...descend);
          }
          active -= 1;
          if (active === 0 && queue.length === 0) resolve();
          else pump();
        })();
      }
      if (active === 0 && queue.length === 0) resolve();
    };
    pump();
  });
  target.builtAt = Date.now();
  return target;
}

/**
 * Brings one folder's entries up to date after a change notification. New
 * subfolders are walked; vanished entries (and their contents) are removed.
 */
export function refreshDirectory(index: FileSearchIndex, dir: string): void {
  const rules = index.rules;
  if (!isIndexedPath(dir, rules)) return;
  const stat = statSync(dir);
  if (!stat || !stat.isDirectory) {
    index.removePath(dir);
    return;
  }
  // Known subfolders get their own change notifications; only folders that
  // are new to the index (and everything under them) are walked.
  const stack: Array<{ dir: string; walkAll: boolean }> = [{ dir, walkAll: false }];
  while (stack.length > 0) {
    const current = stack.pop()!;
    const listing = listSync(current.dir);
    if (!listing) continue;
    const { record, descend, isRepository } = planListing(current.dir, listing, rules);
    if (isRepository) index.markRepository(current.dir);
    const walkable = new Set(descend);
    const present = new Set(record.map((item) => item.name));
    for (const name of index.namesIn(current.dir)) {
      if (!present.has(name)) index.removePath(path.join(current.dir, name));
    }
    for (const item of record) {
      const full = path.join(current.dir, item.name);
      const itemStat = statSync(full);
      if (!itemStat) continue;
      const known = index.has(current.dir, item.name);
      index.add(current.dir, item.name, item.isDirectory, item.isDirectory ? 0 : itemStat.size, itemStat.mtimeMs);
      if (walkable.has(full) && (current.walkAll || !known)) stack.push({ dir: full, walkAll: true });
    }
  }
  // The folder's own row lives in its parent's listing and may be new too.
  const parent = path.dirname(dir);
  if (!rules.roots.includes(dir) && isIndexedPath(parent, rules)) {
    index.add(parent, path.basename(dir), true, 0, stat.mtimeMs);
  }
}

// ---------------------------------------------------------------------------
// Persistence

export function loadFileSearchIndex(config: FileSearchConfig, home = fileSearchHome(), homeDir = os.homedir()): FileSearchIndex | null {
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(fileSearchIndexPath(home), "utf8"));
  } catch {
    return null;
  }
  return FileSearchIndex.fromJSON(raw, config, homeDir);
}

export function saveFileSearchIndex(index: FileSearchIndex, home = fileSearchHome()): string {
  const file = fileSearchIndexPath(home);
  writeFileAtomic(file, JSON.stringify(index.toJSON()));
  return file;
}

/** How long a saved index may go without a full rebuild before a worker refreshes it. */
export const FILE_SEARCH_INDEX_MAX_AGE_MS = 6 * 60 * 60 * 1000;

export function indexStatus(index: FileSearchIndex | null, home = fileSearchHome(), now = Date.now()): FileSearchIndexStatus {
  return {
    path: fileSearchIndexPath(home),
    builtAt: index?.builtAt ? new Date(index.builtAt).toISOString() : null,
    building: index?.building ?? false,
    entries: index?.size ?? 0,
    roots: index?.rules.roots ?? [],
    stale: !index?.builtAt || now - index.builtAt > FILE_SEARCH_INDEX_MAX_AGE_MS,
  };
}

// ---------------------------------------------------------------------------
// Querying

type ParsedQuery = { tokens: string[]; phrase: string; kinds: Set<FileSearchKind>; extensions: Set<string> };

export function parseFileSearchQuery(query: string, options: Pick<FileSearchOptions, "kinds" | "extensions"> = {}): ParsedQuery {
  const kinds = new Set<FileSearchKind>(options.kinds ?? []);
  const extensions = new Set<string>((options.extensions ?? []).map((item) => item.replace(/^\./, "").toLowerCase()).filter(Boolean));
  const words: string[] = [];
  for (const word of query.trim().split(/\s+/).filter(Boolean)) {
    const lower = word.toLowerCase();
    const filter = /^(kind|type|ext):(.+)$/.exec(lower);
    if (filter) {
      if (filter[1] === "ext") extensions.add(filter[2]!.replace(/^\./, ""));
      else {
        const kind = parseFileSearchKind(filter[2]!);
        if (kind) kinds.add(kind);
      }
      continue;
    }
    // A bare ".pdf" filters by extension.
    if (/^\.[a-z0-9]{1,10}$/.test(lower)) {
      extensions.add(lower.slice(1));
      continue;
    }
    words.push(word);
  }
  const phrase = normalizeText(words.join(" "));
  return { tokens: phrase ? phrase.split(" ") : [], phrase, kinds, extensions };
}

function baseKey(name: string, key: string, isDirectory: boolean): string {
  const extension = extensionOf(name);
  if (!extension || isDirectory) return key;
  const suffix = ` ${normalizeText(extension)}`;
  return key.endsWith(suffix) ? key.slice(0, -suffix.length) : key;
}

/** Whether `token` starts at a word of `key` when the following words are joined without spaces. */
function matchesAcrossWords(key: string, token: string): boolean {
  const words = key.split(" ");
  for (let start = 0; start < words.length; start += 1) {
    const word = words[start]!;
    if (!token.startsWith(word.slice(0, token.length))) continue;
    let joined = "";
    for (let end = start; end < words.length && joined.length < token.length; end += 1) joined += words[end];
    if (joined.startsWith(token)) return true;
  }
  return false;
}

/** Score for one candidate, or null when a query word or filter does not match. */
function scoreSlot(index: FileSearchIndex, slot: number, query: ParsedQuery, now: number): number | null {
  const kind = index.kindOf(slot);
  if (query.kinds.size > 0 && !query.kinds.has(kind)) return null;
  const entry = index.entry(slot);
  if (query.extensions.size > 0 && !query.extensions.has(extensionOf(entry.name))) return null;
  const dir = index.dirInfo(slot);

  let score = 0;
  let nameMatches = 0;
  if (query.tokens.length > 0) {
    const spaced = ` ${entry.key} `;
    for (const token of query.tokens) {
      // Word starts match any word; the middle of a word only for longer
      // words, so "soc" does not find "rsocket".
      if (spaced.includes(` ${token}`)) {
        nameMatches += 1;
        score += spaced.includes(` ${token} `) ? 18 : 15;
        continue;
      }
      if (token.length >= 4 && entry.key.includes(token)) {
        nameMatches += 1;
        score += 8;
        continue;
      }
      // Across word breaks, "soc2" finds "SOC 2" and "captable" finds "Cap Table".
      if (token.length >= 3 && matchesAcrossWords(entry.key, token)) {
        nameMatches += 1;
        score += 12;
        continue;
      }
      // Folder words: whole words for short ones, so "2" does not match "2026".
      if (token.length >= 3 ? dir.key.includes(` ${token}`) : dir.key.includes(` ${token} `)) {
        score += 3;
        continue;
      }
      return null;
    }
    if (nameMatches === 0) return null;
    if (nameMatches === query.tokens.length) score += 10;
    const base = baseKey(entry.name, entry.key, entry.isDirectory);
    if (base === query.phrase) score += 25;
    else if (base.startsWith(query.phrase)) score += 10;
    else if (query.tokens.length > 1 && entry.key.includes(query.phrase)) score += 8;
  }

  const ageDays = Math.max(0, (now - entry.mtimeMs) / 86_400_000);
  score += 12 * Math.exp(-ageDays / 30) + 4 * Math.exp(-ageDays / 365);
  const isDocument = DOCUMENT_KINDS.has(kind);
  if (isDocument) score += 4;
  else if (kind === "folder" || kind === "app") score += 1;
  // Files inside source repositories are rarely what someone is looking for
  // by name; they still match, just lower.
  if (dir.inRepo) score -= isDocument ? 3 : 8;
  return score + dir.bonus;
}

type CopyMark = "none" | "strong" | "weak";

/**
 * The name a copy was made from. Strong marks are unambiguous copy names:
 * "Report (3)", "Report copy", "Report copy 2", "Report - Copy". A weak mark is
 * Safari's repeat-download name "Report-2", which could also be a real name,
 * so it only groups when the unmarked original is present too.
 */
export function copyStem(name: string, isDirectory: boolean): { stem: string; mark: CopyMark } {
  const extension = isDirectory ? "" : extensionOf(name);
  const base = extension ? name.slice(0, -(extension.length + 1)) : name;
  const strong = /^(.*?)(?: \(\d{1,3}\)| copy(?: \d{1,3})?| - copy(?: \(\d{1,3}\))?)+$/i.exec(base);
  if (strong && strong[1]!.trim()) return { stem: normalizeText(strong[1]!), mark: "strong" };
  const weak = /^(.*[^\d\s-])-\d{1,2}$/.exec(base);
  if (weak) return { stem: normalizeText(weak[1]!), mark: "weak" };
  return { stem: normalizeText(base), mark: "none" };
}

function familyKey(entry: FileEntry): string {
  const extension = entry.isDirectory ? "/" : extensionOf(entry.name);
  // Documents group across folders ("Report.pdf" in Downloads and in
  // Documents); everything else only within one folder, so README.md in
  // every repository stays separate.
  const crossFolder = DOCUMENT_KINDS.has(entry.kind);
  return `${crossFolder ? "" : `${entry.dir}\u0000`}${copyStem(entry.name, entry.isDirectory).stem}\u0000${extension}`;
}

const identicalCache = new Map<string, string>();

function isCloudPath(file: string, homeDir: string): boolean {
  return isWithin(file, path.join(homeDir, "Library", "CloudStorage")) || isWithin(file, path.join(homeDir, "Library", "Mobile Documents"));
}

/** SHA-256 of a local file, cached by path, size, and modification time. Never reads cloud files. */
function contentHash(entry: FileEntry, homeDir: string, budget: { bytes: number }): string | null {
  const full = path.join(entry.dir, entry.name);
  if (entry.isDirectory || entry.size <= 0 || entry.size > 64 * 1024 * 1024 || isCloudPath(full, homeDir)) return null;
  const cacheKey = `${full}\u0000${entry.size}\u0000${entry.mtimeMs}`;
  const cachedHash = identicalCache.get(cacheKey);
  if (cachedHash) return cachedHash;
  if (budget.bytes < entry.size) return null;
  budget.bytes -= entry.size;
  try {
    const hash = crypto.createHash("sha256").update(fs.readFileSync(full)).digest("hex");
    if (identicalCache.size > 5_000) identicalCache.clear();
    identicalCache.set(cacheKey, hash);
    return hash;
  } catch {
    return null;
  }
}

function hitFrom(entry: FileEntry, score: number, copies: FileEntry[], options: { checkIdentical: boolean; homeDir: string; budget: { bytes: number } }): FileSearchHit {
  const newestHash = options.checkIdentical && copies.some((copy) => copy.size === entry.size)
    ? contentHash(entry, options.homeDir, options.budget)
    : null;
  return {
    path: path.join(entry.dir, entry.name),
    name: entry.name,
    directory: entry.dir,
    kind: entry.kind,
    extension: entry.isDirectory ? "" : extensionOf(entry.name),
    isDirectory: entry.isDirectory,
    size: entry.size,
    modifiedAt: new Date(entry.mtimeMs).toISOString(),
    score: Math.round(score * 100) / 100,
    copyCount: copies.length,
    copies: copies.slice(0, 50).map((copy) => {
      const item: FileSearchCopy = {
        path: path.join(copy.dir, copy.name),
        directory: copy.dir,
        size: copy.size,
        modifiedAt: new Date(copy.mtimeMs).toISOString(),
      };
      if (!options.checkIdentical || entry.isDirectory) return item;
      if (copy.size !== entry.size) item.identical = false;
      else if (newestHash) {
        const hash = contentHash(copy, options.homeDir, options.budget);
        if (hash) item.identical = hash === newestHash;
      }
      return item;
    }),
  };
}

type Scored = { slot: number; score: number };

function candidateSlots(index: FileSearchIndex, query: ParsedQuery): Iterable<number> {
  if (query.tokens.length === 0) return index.slots();
  // Single characters match nearly everything; let longer words pick the
  // candidates whenever the query has any.
  const seeds = query.tokens.some((token) => token.length > 1) ? query.tokens.filter((token) => token.length > 1) : query.tokens;
  const slots = new Set<number>();
  for (const token of seeds) index.nameMatches(token, slots);
  return slots;
}

export function searchFileIndex(index: FileSearchIndex, options: FileSearchOptions): FileSearchHit[] {
  const now = options.now ?? Date.now();
  const limit = Math.max(1, Math.trunc(options.limit ?? 50));
  const query = parseFileSearchQuery(options.query, options);
  // With no words and no filters, show recently changed documents.
  const browsing = query.tokens.length === 0 && query.kinds.size === 0 && query.extensions.size === 0;

  const scored: Scored[] = [];
  for (const slot of candidateSlots(index, query)) {
    if (browsing && !DOCUMENT_KINDS.has(index.kindOf(slot))) continue;
    const score = scoreSlot(index, slot, query, now);
    if (score !== null) scored.push({ slot, score });
  }
  scored.sort((left, right) => right.score - left.score || index.mtime(right.slot) - index.mtime(left.slot));
  const budget = { bytes: 64 * 1024 * 1024 };
  const homeDir = index.rules.homeDir;

  if (options.group === false) {
    return scored.slice(0, limit).map(({ slot, score }) => hitFrom(index.entry(slot), score, [], { checkIdentical: false, homeDir, budget }));
  }

  // Group the strongest candidates into families of copies, then collect
  // every copy of the families that make the cut, wherever it ranked.
  const families = new Map<string, { score: number; members: FileEntry[] }>();
  const ordered: string[] = [];
  for (const { slot, score } of scored) {
    if (ordered.length >= limit * 2) break;
    const entry = index.entry(slot);
    const key = familyKey(entry);
    const family = families.get(key);
    if (family) family.members.push(entry);
    else {
      families.set(key, { score, members: [entry] });
      ordered.push(key);
    }
  }
  const chosen = new Set(ordered);
  const stems = new Set(ordered.map((key) => key.split("\u0000").at(-2)!));
  const counted = new Set<number>();
  for (const family of families.values()) for (const member of family.members) counted.add(member.slot);
  // Copies share their family's name, so they score close to it; looking
  // through the first few thousand candidates finds them.
  for (const { slot } of scored.slice(0, 5_000)) {
    if (counted.has(slot)) continue;
    const entry = index.entry(slot);
    // Cheap check first: a copy's name contains its family's stem.
    let possible = false;
    for (const stem of stems) if (entry.key.includes(stem)) { possible = true; break; }
    if (!possible) continue;
    const key = familyKey(entry);
    if (chosen.has(key)) families.get(key)!.members.push(entry);
  }

  const results: Array<{ score: number; members: FileEntry[] }> = [];
  for (const key of ordered) {
    const { score, members } = families.get(key)!;
    if (members.length === 1) {
      results.push({ score, members });
      continue;
    }
    // Without the original name, "Report-2" style names stand alone: they
    // may be real names rather than repeat downloads.
    const marks = members.map((member) => copyStem(member.name, member.isDirectory).mark);
    const groups = marks.includes("none")
      ? [members]
      : [members.filter((_, position) => marks[position] === "strong"), ...members.filter((_, position) => marks[position] === "weak").map((member) => [member])];
    for (const group of groups) {
      if (group.length === 0) continue;
      group.sort((left, right) => right.mtimeMs - left.mtimeMs);
      results.push({ score: score + Math.min(3, Math.log2(group.length)), members: group });
    }
  }
  results.sort((left, right) => right.score - left.score || right.members[0]!.mtimeMs - left.members[0]!.mtimeMs);
  return results.slice(0, limit).map(({ score, members }) =>
    hitFrom(members[0]!, score, members.slice(1), { checkIdentical: options.checkIdentical !== false, homeDir, budget }));
}

export function fileSearchPayload(query: string, index: FileSearchIndex | null, results: FileSearchHit[], startedAt: number, home = fileSearchHome()): FileSearchPayload {
  return {
    schema: FILE_SEARCH_RESULT_SCHEMA,
    query,
    index: indexStatus(index, home),
    results,
    elapsedMs: Math.round(Date.now() - startedAt),
  };
}
