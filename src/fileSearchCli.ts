import os from "node:os";
import path from "node:path";
import {
  abbreviateHome,
  buildFileSearchIndexSync,
  DEFAULT_FILE_SEARCH_ROOTS,
  FILE_SEARCH_CONFIG_SCHEMA,
  FILE_SEARCH_KINDS,
  fileSearchConfigPath,
  fileSearchHome,
  fileSearchPayload,
  indexStatus,
  loadFileSearchIndex,
  normalizeConfigPath,
  parseFileSearchKind,
  readFileSearchConfig,
  saveFileSearchIndex,
  searchFileIndex,
  writeFileSearchConfig,
  type FileSearchConfig,
  type FileSearchHit,
  type FileSearchIndex,
  type FileSearchKind,
} from "./fileSearch.js";

const HELP = `celorga files: find files on this Mac by name and folder

Usage:
  celorga files search QUERY... [--kind KIND]... [--ext EXT]... [--limit N] [--no-group] [--refresh] [--json]
  celorga files index [--json]
  celorga files status [--json]
  celorga files config [--add-root PATH]... [--remove-root PATH]... [--exclude NAME|PATH]... [--include NAME|PATH]...
                       [--hidden on|off] [--reset] [--apply] [--json]

search   Search file and folder names (and the folders they are in). Every word must match.
         Repeat downloads and copies ("Report (3).pdf", "Report copy.pdf", the same document
         in two folders) come back as one result: the newest file, with its older copies.
         Recent files and documents rank higher. Filters may also be typed in the query:
         kind:pdf, kind:sheet, ext:xlsx, or a bare .pdf. Kinds: ${FILE_SEARCH_KINDS.join(", ")}.
         Builds the index first if there is none; --refresh rebuilds it before searching.
index    Rebuild the index now.
status   Show the index location, age, size, and indexed folders.
config   Show or change which folders are indexed. Default folders: ${DEFAULT_FILE_SEARCH_ROOTS.join(", ")}.
         ~/Library is skipped except for folders listed here. --exclude skips a folder path or a
         name anywhere (for example node_modules); --include removes an exclusion. Changes
         preview until --apply.

The index and config are machine-local (${abbreviateHome(fileSearchHome())}; set CELORGA_FILES_HOME
to move them) and never stored in a corpus. The Celorga app's Search › This Mac uses the same index
and keeps it current while it runs.
`;

type Parsed = { positional: string[]; flags: Map<string, string[]> };

const BOOLEAN_FLAGS = new Set(["apply", "json", "help", "no-group", "refresh", "reset"]);

function parse(args: string[]): Parsed {
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let index = 0; index < args.length; index += 1) {
    const item = args[index]!;
    if (item === "-h") { flags.set("help", ["true"]); continue; }
    if (!item.startsWith("--")) { positional.push(item); continue; }
    const equal = item.indexOf("=");
    const name = equal >= 0 ? item.slice(2, equal) : item.slice(2);
    let value: string;
    if (equal >= 0) value = item.slice(equal + 1);
    else if (BOOLEAN_FLAGS.has(name)) value = "true";
    else {
      const next = args[index + 1];
      if (next === undefined) throw new Error(`--${name} requires a value`);
      value = next;
      index += 1;
    }
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags };
}

const flag = (parsed: Parsed, name: string): string | undefined => parsed.flags.get(name)?.at(-1);
const flagList = (parsed: Parsed, name: string): string[] => parsed.flags.get(name) || [];
const enabled = (parsed: Parsed, name: string): boolean => parsed.flags.has(name);
const wantsJSON = (parsed: Parsed): boolean => enabled(parsed, "json") || flag(parsed, "format") === "json";

function print(parsed: Parsed, value: unknown, text: string): void {
  process.stdout.write(wantsJSON(parsed) ? `${JSON.stringify(value, null, 2)}\n` : `${text}\n`);
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
}

function formatHit(hit: FileSearchHit): string {
  const date = hit.modifiedAt.slice(0, 10);
  const details = [hit.isDirectory && hit.kind === "folder" ? "folder" : formatSize(hit.size), date];
  if (hit.copyCount > 0) details.push(`+${hit.copyCount} older cop${hit.copyCount === 1 ? "y" : "ies"}`);
  return `${abbreviateHome(hit.path)}  (${details.join(", ")})`;
}

function ensureIndex(config: FileSearchConfig, refresh: boolean): { index: FileSearchIndex; built: boolean } {
  const home = fileSearchHome();
  if (!refresh) {
    const loaded = loadFileSearchIndex(config, home);
    if (loaded) return { index: loaded, built: false };
  }
  process.stderr.write("Indexing files on this Mac…\n");
  const index = buildFileSearchIndexSync(config);
  saveFileSearchIndex(index, home);
  return { index, built: true };
}

function runSearch(parsed: Parsed): void {
  const query = parsed.positional.slice(1).join(" ");
  const kinds: FileSearchKind[] = [];
  for (const raw of flagList(parsed, "kind")) {
    const kind = parseFileSearchKind(raw);
    if (!kind) throw new Error(`unknown --kind ${raw}; expected one of ${FILE_SEARCH_KINDS.join(", ")}`);
    kinds.push(kind);
  }
  const limit = Number(flag(parsed, "limit") ?? 20);
  if (!Number.isInteger(limit) || limit < 1) throw new Error("--limit must be a positive integer");
  const startedAt = Date.now();
  const config = readFileSearchConfig();
  const { index } = ensureIndex(config, enabled(parsed, "refresh"));
  const results = searchFileIndex(index, {
    query,
    limit,
    kinds,
    extensions: flagList(parsed, "ext"),
    group: !enabled(parsed, "no-group"),
  });
  const payload = fileSearchPayload(query, index, results, startedAt);
  const lines = results.length === 0 ? [`No files match "${query}".`] : results.map(formatHit);
  if (payload.index.stale) lines.push(`(index built ${payload.index.builtAt ?? "never"}; run celorga files index to refresh)`);
  print(parsed, payload, lines.join("\n"));
}

function runIndex(parsed: Parsed): void {
  const startedAt = Date.now();
  const config = readFileSearchConfig();
  const index = buildFileSearchIndexSync(config);
  const file = saveFileSearchIndex(index);
  const status = indexStatus(index);
  print(parsed, { ...status, elapsedMs: Date.now() - startedAt }, `Indexed ${status.entries} files and folders in ${((Date.now() - startedAt) / 1000).toFixed(1)}s → ${abbreviateHome(file)}`);
}

function runStatus(parsed: Parsed): void {
  const config = readFileSearchConfig();
  const index = loadFileSearchIndex(config);
  const status = { ...indexStatus(index), configPath: fileSearchConfigPath(), config };
  const lines = [
    `Index: ${abbreviateHome(status.path)}${index ? "" : " (not built yet)"}`,
    `Built: ${status.builtAt ?? "never"}${status.stale && index ? " (stale)" : ""}`,
    `Entries: ${status.entries}`,
    `Folders: ${config.roots.join(", ")}`,
  ];
  if (config.exclude.length > 0) lines.push(`Excluded: ${config.exclude.join(", ")}`);
  print(parsed, status, lines.join("\n"));
}

function runConfig(parsed: Parsed): void {
  const homeDir = os.homedir();
  const before = readFileSearchConfig();
  let next: FileSearchConfig = enabled(parsed, "reset")
    ? { schema: FILE_SEARCH_CONFIG_SCHEMA, roots: [...DEFAULT_FILE_SEARCH_ROOTS], exclude: [], includeHidden: false }
    : { ...before, roots: [...before.roots], exclude: [...before.exclude] };
  for (const raw of flagList(parsed, "add-root")) {
    const root = normalizeConfigPath(raw.includes("/") || raw === "~" ? raw : path.resolve(raw), homeDir);
    if (!next.roots.includes(root)) next.roots.push(root);
  }
  for (const raw of flagList(parsed, "remove-root")) {
    const root = normalizeConfigPath(raw.includes("/") || raw === "~" ? raw : path.resolve(raw), homeDir);
    next.roots = next.roots.filter((item) => item !== root && normalizeConfigPath(item, homeDir) !== root);
  }
  for (const raw of flagList(parsed, "exclude")) {
    const entry = normalizeConfigPath(raw, homeDir);
    if (!next.exclude.includes(entry)) next.exclude.push(entry);
  }
  for (const raw of flagList(parsed, "include")) {
    const entry = normalizeConfigPath(raw, homeDir);
    next.exclude = next.exclude.filter((item) => item !== entry);
  }
  const hidden = flag(parsed, "hidden");
  if (hidden !== undefined) {
    if (!["on", "off", "true", "false"].includes(hidden)) throw new Error("--hidden must be on or off");
    next.includeHidden = hidden === "on" || hidden === "true";
  }
  next = { ...next, schema: FILE_SEARCH_CONFIG_SCHEMA };
  const changed = JSON.stringify(before) !== JSON.stringify(next);
  const apply = enabled(parsed, "apply");
  const file = apply && changed ? writeFileSearchConfig(next) : fileSearchConfigPath();
  const verb = !changed ? "unchanged" : apply ? "saved" : "preview (add --apply to save)";
  const lines = [
    `File search config ${verb}: ${abbreviateHome(file)}`,
    `Folders: ${next.roots.join(", ") || "(none)"}`,
    `Excluded: ${next.exclude.join(", ") || "(defaults only)"}`,
    `Hidden files: ${next.includeHidden ? "on" : "off"}`,
  ];
  if (apply && changed) lines.push("The next search rebuilds the index for the new folders.");
  print(parsed, { path: file, apply, changed, before, config: next }, lines.join("\n"));
}

export async function runFilesCommand(args: string[]): Promise<void> {
  const parsed = parse(args);
  const action = parsed.positional[0] || "";
  if (enabled(parsed, "help") || action === "" || action === "help") {
    process.stdout.write(HELP);
    return;
  }
  switch (action) {
    case "search":
    case "find":
      runSearch(parsed);
      return;
    case "index":
      runIndex(parsed);
      return;
    case "status":
      runStatus(parsed);
      return;
    case "config":
      runConfig(parsed);
      return;
    default:
      throw new Error(`unknown files command: ${action}\n\n${HELP}`);
  }
}
