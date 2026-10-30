import fs from "node:fs";
import path from "node:path";
import v8 from "node:v8";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { defaultSearchIndexPath } from "./indexPaths.js";
import { computeSubtreeRange } from "./sourceLines.js";
import { documentTodoSequences, todoSequencesForFile, todoConfigurationKey, todoKeywordInWorkflow, type TodoSequence, isActiveTodoKeyword, isTerminalTodoKeyword } from "./todo.js";
import { schemaMatches } from "./brandNames.js";

export { defaultSearchIndexPath };

export function binarySearchIndexPath(indexPath: string): string {
  return `${indexPath}.v8`;
}

function readSearchIndex(indexPath: string): Org2SearchIndex {
  const binaryPath = binarySearchIndexPath(indexPath);
  try {
    const binaryStat = fs.statSync(binaryPath);
    const jsonStat = fs.statSync(indexPath);
    if (binaryStat.mtimeMs >= jsonStat.mtimeMs) {
      return v8.deserialize(fs.readFileSync(binaryPath)) as Org2SearchIndex;
    }
  } catch {
    // Older indexes and portable copies may only have the JSON representation.
  }
  return JSON.parse(fs.readFileSync(indexPath, "utf8")) as Org2SearchIndex;
}

export type Org2SearchIndexFile = {
  path: string;
  relativePath: string;
  modifiedMs: number;
  byteCount: number;
  lines: string[];
  /**
   * Optional query-time metadata. Older v1 indexes do not contain this field
   * and remain readable through the line-parser fallback.
   */
  headings?: Org2SearchIndexHeading[];
  todoConfiguration?: string;
};

export type Org2SearchIndexHeading = {
  /** Zero-based source line, matching the representation used by `lines`. */
  line: number;
  /** Inclusive, zero-based end of this heading's subtree. */
  endLine: number;
  level: number;
  title: string;
  todo?: string;
  todoTerminal?: boolean;
  tags: string[];
  id?: string;
  /** The ID is visible only to matches at or after its property line. */
  idLine?: number;
  /** Index of the parent heading in the containing file's headings array. */
  parent?: number;
  /** First timestamp-like date found in this heading's subtree. */
  date?: string;
};

export type Org2SearchIndex = {
  $schema: "org2:search-index:v1";
  version: 1;
  todoWorkflowVersion?: 1;
  rootDir: string;
  recursive: boolean;
  includeArchives: boolean;
  builtAt: string;
  files: Org2SearchIndexFile[];
};

export type Org2SearchIndexBuildResult = {
  index: Org2SearchIndex;
  path: string;
  fileCount: number;
  lineCount: number;
  byteCount: number;
  skippedFiles: number;
};

export type Org2SearchIndexUpdateResult = Org2SearchIndexBuildResult & {
  updatedFiles: number;
};

export type Org2SearchResultPayload = {
  $schema: "org2:search:v1";
  query: string;
  mode: "line" | "subtree";
  sort: string;
  dateFrom?: string;
  dateTo?: string;
  fileZones?: string[];
  index?: {
    mode: "auto" | "current" | "never" | "rebuild";
    used: boolean;
    path?: string;
    builtAt?: string;
    stale?: boolean;
  };
  results: Org2SearchHit[];
};

export type Org2SearchHit = {
  file: string;
  line: number;
  lineEnd: number;
  heading?: string;
  headingLine?: number;
  headingLevel?: number;
  headingAncestry: SearchHeadingRef[];
  id?: string;
  todo?: string;
  todoTerminal?: boolean;
  tags: string[];
  snippet: string;
  context: { startLine: number; endLine: number; lines: string[] };
  sourceRange: { startLine: number; endLine: number };
  matchedLines: { line: number; snippet: string }[];
  date?: string;
  sortDate?: string;
  answerContext?: string;
};

export type Org2SearchOptions = {
  query: string;
  context: number;
  limit: number;
  todoFilters: Set<string>;
  tagFilters: Set<string>;
  fileZoneFilters: string[];
  headingNeedle: string;
  sort: string;
  dateFrom: string;
  dateTo: string;
  subtree: boolean;
  answerContext: boolean;
  /**
   * Keep only matches of one kind: `heading` (the match is on a heading
   * line), `todo` (inside an entry with an open TODO), or `text` (a body
   * line, not a heading).
   */
  matchKind?: Org2SearchMatchKind;
  /** Shorten snippet and context lines longer than this, keeping the match in view. */
  maxLineLength?: number;
};

export type Org2SearchMatchKind = "heading" | "todo" | "text";

export function parseSearchMatchKind(value: unknown): Org2SearchMatchKind | undefined {
  return value === "heading" || value === "todo" || value === "text" ? value : undefined;
}

/** Optional accelerators a long-lived caller can supply from its own caches. */
export type Org2IndexedSearchAccelerators = {
  /** False when the file cannot contain the lower-cased needle at all. */
  mayContain?: (file: Org2SearchIndexFile, needle: string) => boolean;
  /**
   * Zero-based numbers of the lines that contain the lower-cased needle, in
   * ascending order. Must agree with a per-line case-insensitive match.
   */
  matchingLines?: (file: Org2SearchIndexFile, needle: string) => Iterable<number>;
};

type SearchHeading = { line: number; level: number; title: string; todo?: string; todoTerminal?: boolean; tags: string[]; id?: string };
type SearchHeadingRef = { level: number; title: string; line: number; lineNumber: number };
type LiteralCaseInsensitiveMatcher = { needle: string; asciiPattern?: RegExp };

const NON_ASCII_PATTERN = /[^\x00-\x7f]/;

function indexSearchFile(rootDir: string, absolutePath: string, stat: fs.Stats, lines: string[]): Org2SearchIndexFile {
  return {
    path: absolutePath,
    relativePath: relativeIndexPath(rootDir, absolutePath),
    modifiedMs: Math.trunc(stat.mtimeMs),
    byteCount: stat.size,
    lines,
    headings: buildSearchIndexHeadings(lines, absolutePath),
    todoConfiguration: todoConfigurationKey(absolutePath),
  };
}

function buildSearchIndexHeadings(lines: string[], filePath: string): Org2SearchIndexHeading[] {
  const headings: Org2SearchIndexHeading[] = [];
  const stack: number[] = [];
  const sequences = documentTodoSequences(lines.join("\n"), todoSequencesForFile(filePath));

  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex] || "";
    const parsed = line.charCodeAt(0) === 42 ? parseSearchHeading(line, sequences) : null;
    if (parsed) {
      while (stack.length && headings[stack[stack.length - 1]!]!.level >= parsed.level) {
        headings[stack.pop()!]!.endLine = lineIndex - 1;
      }
      const parent = stack[stack.length - 1];
      const heading: Org2SearchIndexHeading = {
        line: lineIndex,
        endLine: lines.length - 1,
        level: parsed.level,
        title: parsed.title,
        todo: parsed.todo,
        ...(parsed.todoTerminal !== undefined ? { todoTerminal: parsed.todoTerminal } : {}),
        tags: parsed.tags,
        ...(parent !== undefined ? { parent } : {}),
      };
      headings.push(heading);
      stack.push(headings.length - 1);
    }

    const currentIndex = stack[stack.length - 1];
    const current = currentIndex === undefined ? undefined : headings[currentIndex];
    const idMatch = current && line.includes(":ID:") ? /^:ID:\s*(\S+)\s*$/.exec(line.trim()) : null;
    if (idMatch && current) {
      current.id = idMatch[1];
      current.idLine = lineIndex;
    }

    const date = extractDateFromTimestamp(line);
    if (date) {
      for (const openHeadingIndex of stack) {
        const openHeading = headings[openHeadingIndex]!;
        if (!openHeading.date) openHeading.date = date;
      }
    }
  }

  for (const headingIndex of stack) headings[headingIndex]!.endLine = lines.length - 1;
  return headings;
}

export function buildSearchIndex(options: {
  rootDir: string;
  files: string[];
  recursive: boolean;
  includeArchives: boolean;
}): Org2SearchIndexBuildResult {
  const rootDir = path.resolve(options.rootDir);
  const indexPath = defaultSearchIndexPath(rootDir);
  const indexedFiles: Org2SearchIndexFile[] = [];
  let lineCount = 0;
  let byteCount = 0;
  let skippedFiles = 0;

  for (const file of options.files) {
    const absolutePath = path.resolve(file);
    try {
      const stat = fs.statSync(absolutePath);
      if (!stat.isFile()) continue;
      const raw = fs.readFileSync(absolutePath, "utf8").replace(/\r\n/g, "\n");
      const lines = raw.split("\n");
      lineCount += lines.length;
      byteCount += stat.size;
      indexedFiles.push(indexSearchFile(rootDir, absolutePath, stat, lines));
    } catch {
      skippedFiles += 1;
    }
  }

  const index: Org2SearchIndex = {
    $schema: "org2:search-index:v1",
    version: 1,
    todoWorkflowVersion: 1,
    rootDir,
    recursive: options.recursive,
    includeArchives: options.includeArchives,
    builtAt: new Date().toISOString(),
    files: indexedFiles.sort((a, b) => a.path.localeCompare(b.path)),
  };

  return { index, path: indexPath, fileCount: indexedFiles.length, lineCount, byteCount, skippedFiles };
}

/**
 * Updates only the supplied paths in an existing index. Removed paths are
 * deleted from the index. Returns null when a compatible base index does not
 * exist, so callers can fall back to a complete rebuild without trusting stale
 * derived data.
 */
export function updateSearchIndex(options: {
  rootDir: string;
  changedFiles: string[];
  recursive: boolean;
  includeArchives: boolean;
}): Org2SearchIndexUpdateResult | null {
  const rootDir = path.resolve(options.rootDir);
  const indexPath = defaultSearchIndexPath(rootDir);
  let existing: Org2SearchIndex;
  try {
    existing = readSearchIndex(indexPath);
  } catch {
    return null;
  }
  if (
    !schemaMatches(existing.$schema, "org2:search-index:v1") ||
    existing.version !== 1 ||
    existing.todoWorkflowVersion !== 1 ||
    path.resolve(existing.rootDir) !== rootDir ||
    existing.recursive !== options.recursive ||
    existing.includeArchives !== options.includeArchives
  ) {
    return null;
  }

  const changed = new Set(options.changedFiles.map((file) => path.resolve(file)));
  const indexedFiles = existing.files.filter((file) => !changed.has(path.resolve(file.path)));
  let skippedFiles = 0;
  for (const absolutePath of changed) {
    if (!isIndexableChangedPath(rootDir, absolutePath, options.includeArchives)) continue;
    try {
      const stat = fs.statSync(absolutePath);
      if (!stat.isFile()) continue;
      const raw = fs.readFileSync(absolutePath, "utf8").replace(/\r\n/g, "\n");
      indexedFiles.push(indexSearchFile(rootDir, absolutePath, stat, raw.split("\n")));
    } catch (error) {
      // A path that vanished between the event and this read is a deletion, not
      // an indexing failure. Other read errors are reported but never preserve
      // the stale indexed copy.
      if (fs.existsSync(absolutePath)) skippedFiles += 1;
    }
  }

  indexedFiles.sort((a, b) => a.path.localeCompare(b.path));
  const index: Org2SearchIndex = {
    ...existing,
    builtAt: new Date().toISOString(),
    files: indexedFiles,
  };
  const result: Org2SearchIndexUpdateResult = {
    index,
    path: indexPath,
    fileCount: indexedFiles.length,
    lineCount: indexedFiles.reduce((count, file) => count + file.lines.length, 0),
    byteCount: indexedFiles.reduce((count, file) => count + file.byteCount, 0),
    skippedFiles,
    updatedFiles: changed.size,
  };
  return result;
}

/**
 * Brings an in-memory index up to date with the files on disk: rereads files
 * whose size or modification time changed, adds new files, and drops removed
 * ones. Returns null when nothing changed.
 */
export function refreshSearchIndexFiles(index: Org2SearchIndex, files: string[]): Org2SearchIndex | null {
  const rootDir = path.resolve(index.rootDir);
  const wanted = new Set(files.map((file) => path.resolve(file)));
  const kept: Org2SearchIndexFile[] = [];
  let changed = false;
  for (const file of index.files) {
    const absolutePath = path.resolve(file.path);
    if (!wanted.has(absolutePath)) {
      changed = true;
      continue;
    }
    wanted.delete(absolutePath);
    try {
      const stat = fs.statSync(absolutePath);
      if (Math.trunc(stat.mtimeMs) === file.modifiedMs && stat.size === file.byteCount) {
        kept.push(file);
        continue;
      }
      const raw = fs.readFileSync(absolutePath, "utf8").replace(/\r\n/g, "\n");
      kept.push(indexSearchFile(rootDir, absolutePath, stat, raw.split("\n")));
    } catch {
      // Unreadable now: drop it rather than serve stale text.
    }
    changed = true;
  }
  for (const absolutePath of wanted) {
    try {
      const stat = fs.statSync(absolutePath);
      if (!stat.isFile()) continue;
      const raw = fs.readFileSync(absolutePath, "utf8").replace(/\r\n/g, "\n");
      kept.push(indexSearchFile(rootDir, absolutePath, stat, raw.split("\n")));
      changed = true;
    } catch {
      // Vanished between listing and reading.
    }
  }
  if (!changed) return null;
  kept.sort((a, b) => a.path.localeCompare(b.path));
  return { ...index, builtAt: new Date().toISOString(), files: kept };
}

export function writeSearchIndex(result: Org2SearchIndexBuildResult): void {
  fs.mkdirSync(path.dirname(result.path), { recursive: true });
  const binaryPath = binarySearchIndexPath(result.path);
  const jsonTmpPath = `${result.path}.${process.pid}.tmp`;
  const binaryTmpPath = `${binaryPath}.${process.pid}.tmp`;
  fs.writeFileSync(jsonTmpPath, JSON.stringify(result.index) + "\n", "utf8");
  fs.writeFileSync(binaryTmpPath, v8.serialize(result.index));
  fs.renameSync(jsonTmpPath, result.path);
  fs.renameSync(binaryTmpPath, binaryPath);
}

export function loadFreshSearchIndex(options: {
  rootDir: string;
  files: string[];
  recursive: boolean;
  includeArchives: boolean;
}): { index: Org2SearchIndex; path: string } | null {
  const rootDir = path.resolve(options.rootDir);
  const indexPath = defaultSearchIndexPath(rootDir);
  let parsed: Org2SearchIndex;
  try {
    parsed = readSearchIndex(indexPath);
  } catch {
    return null;
  }

  if (!schemaMatches(parsed.$schema, "org2:search-index:v1") || parsed.version !== 1) return null;
  if (path.resolve(parsed.rootDir) !== rootDir) return null;
  if (parsed.recursive !== options.recursive) return null;
  if (parsed.includeArchives !== options.includeArchives) return null;

  const expected = new Map(options.files.map((file) => [path.resolve(file), true]));
  if (expected.size !== parsed.files.length) return null;

  for (const indexedFile of parsed.files) {
    const absolutePath = path.resolve(indexedFile.path);
    if (!expected.has(absolutePath)) return null;
    try {
      const stat = fs.statSync(absolutePath);
      if (!stat.isFile()) return null;
      if (Math.trunc(stat.mtimeMs) !== indexedFile.modifiedMs || stat.size !== indexedFile.byteCount) return null;
    } catch {
      return null;
    }
  }

  return { index: parsed, path: indexPath };
}

export function loadCompatibleSearchIndex(options: {
  rootDir: string;
  recursive: boolean;
  includeArchives: boolean;
}): { index: Org2SearchIndex; path: string } | null {
  const rootDir = path.resolve(options.rootDir);
  const indexPath = defaultSearchIndexPath(rootDir);
  let index: Org2SearchIndex;
  try {
    index = readSearchIndex(indexPath);
  } catch {
    return null;
  }
  if (!schemaMatches(index.$schema, "org2:search-index:v1") || index.version !== 1) return null;
  if (path.resolve(index.rootDir) !== rootDir) return null;
  if (index.recursive !== options.recursive || index.includeArchives !== options.includeArchives) return null;
  return { index, path: indexPath };
}

/**
 * `mayContain` lets a long-lived caller skip whole files with a cached
 * lower-cased copy of their text; it must never reject a file that has a
 * matching line.
 */
export function searchIndexedCorpus(
  index: Org2SearchIndex,
  options: Org2SearchOptions,
  accelerators?: Org2IndexedSearchAccelerators | ((file: Org2SearchIndexFile, needle: string) => boolean),
): Org2SearchHit[] {
  const { mayContain, matchingLines } = typeof accelerators === "function" ? { mayContain: accelerators, matchingLines: undefined } : (accelerators ?? {});
  const hits: Org2SearchHit[] = [];
  const matcher = literalCaseInsensitiveMatcher(options.query);
  const fileZoneFilters = options.fileZoneFilters.map((zone) => zone.toLowerCase()).filter(Boolean);
  // Files in one folder share their TODO configuration; reading celorga.json
  // once per folder instead of once per file keeps common words fast.
  const configurationByDirectory = new Map<string, string>();
  const configurationKey = (filePath: string): string => {
    const directory = path.dirname(filePath);
    let key = configurationByDirectory.get(directory);
    if (key === undefined) {
      key = todoConfigurationKey(filePath);
      configurationByDirectory.set(directory, key);
    }
    return key;
  };
  // `best` ranking needs only a few heading fields per match, so matches are
  // scored first and only the results that make the cut are built in full.
  const ranked = normalizedSort(options.sort) === "best" && !options.subtree ? new BestCandidates(options) : null;

  for (const file of index.files) {
    const normalizedFile = file.path.toLowerCase();
    if (fileZoneFilters.length && !fileZoneFilters.some((zone) => normalizedFile.includes(zone))) continue;
    if (mayContain && !mayContain(file, matcher.needle)) continue;
    if (file.headings && index.todoWorkflowVersion === 1 && file.todoConfiguration === configurationKey(file.path)) {
      const lines = matchingLines ? matchingLines(file, matcher.needle) : undefined;
      if (ranked) ranked.collect(file, matcher, lines);
      else collectSearchHitsForIndexedFile(file, matcher, options, hits, lines);
    } else {
      const before = hits.length;
      collectSearchHitsForLines(file.path, file.lines, matcher, options, hits);
      if (options.matchKind) filterHitsByMatchKind(hits, before, options.matchKind);
      if (ranked) ranked.addHits(hits.splice(before));
    }
    if (hits.length >= options.limit && normalizedSort(options.sort) === "scan") break;
  }

  const modifiedMsByFile = new Map(index.files.map((file) => [file.path, file.modifiedMs]));
  const results = ranked
    ? ranked.top(options.limit, modifiedMsByFile)
    : sortAndLimitSearchHits(hits, options.sort, options.limit, options.query, modifiedMsByFile);
  return options.maxLineLength ? results.map((hit) => shortenSearchHit(hit, options.maxLineLength!, matcher.needle)) : results;
}

function matchKindAccepts(kind: Org2SearchMatchKind, isHeadingLine: boolean, todo: string | undefined, todoTerminal: boolean | undefined): boolean {
  if (kind === "heading") return isHeadingLine;
  if (kind === "text") return !isHeadingLine;
  if (!todo) return false;
  return !(todoTerminal ?? !isActiveTodoKeyword(todo.trim().toUpperCase()));
}

function filterHitsByMatchKind(hits: Org2SearchHit[], from: number, kind: Org2SearchMatchKind): void {
  let write = from;
  for (let read = from; read < hits.length; read += 1) {
    const hit = hits[read]!;
    if (matchKindAccepts(kind, hit.headingLine !== undefined && hit.headingLine === hit.line, hit.todo, hit.todoTerminal)) hits[write++] = hit;
  }
  hits.length = write;
}

function shortenLine(line: string, max: number, needle: string): string {
  if (line.length <= max) return line;
  const at = needle ? line.toLowerCase().indexOf(needle) : -1;
  const start = at < 0 ? 0 : Math.max(0, Math.min(at - Math.floor(max / 3), line.length - max));
  return `${start > 0 ? "…" : ""}${line.slice(start, start + max)}${start + max < line.length ? "…" : ""}`;
}

function shortenSearchHit(hit: Org2SearchHit, max: number, needle: string): Org2SearchHit {
  const long = (text: string | undefined) => (text?.length ?? 0) > max;
  if (!long(hit.snippet) && !hit.context?.lines.some(long) && !hit.matchedLines.some((match) => long(match.snippet))) return hit;
  return {
    ...hit,
    snippet: shortenLine(hit.snippet, max, needle),
    matchedLines: hit.matchedLines.map((match) => ({ ...match, snippet: shortenLine(match.snippet, max, needle) })),
    ...(hit.context ? { context: { ...hit.context, lines: hit.context.lines.map((line) => shortenLine(line, max, needle)) } } : {}),
  };
}

/**
 * Collects `best`-ranked matches without building a full hit for each one.
 * Scores, order, and tie-breaking are identical to sorting full hits with
 * `sortAndLimitSearchHits`.
 */
class BestCandidates {
  private readonly needle: string;
  private readonly now = Date.now();
  private readonly fileDate = new Map<string, string>();
  private readonly qualityByHeading = new Map<Org2SearchIndexHeading, [number, number]>();
  private readonly timestampByDate = new Map<string, number | undefined>();
  private readonly candidates: Array<{ file: Org2SearchIndexFile | null; line: number; headingIndex: number; quality: number; date: string | undefined; hit?: Org2SearchHit }> = [];

  constructor(private readonly options: Org2SearchOptions) {
    this.needle = options.query.trim().toLowerCase();
  }

  private headingQuality(heading: Org2SearchIndexHeading | undefined, isHeadingLine: boolean): number {
    if (!heading) return 10;
    let cached = this.qualityByHeading.get(heading);
    if (!cached) {
      const probe = (line: number) => bestSearchQuality({ heading: heading.title, headingLine: heading.line + 1, line, todo: heading.todo, todoTerminal: heading.todoTerminal } as Org2SearchHit, this.needle);
      // The heading line itself, and any body line under it.
      cached = [probe(heading.line + 1), probe(heading.line + 2)];
      this.qualityByHeading.set(heading, cached);
    }
    return isHeadingLine ? cached[0] : cached[1];
  }

  collect(file: Org2SearchIndexFile, matcher: LiteralCaseInsensitiveMatcher, matchingLines?: Iterable<number>): void {
    const headings = file.headings || [];
    let fileDate = this.fileDate.get(file.path);
    if (fileDate === undefined) {
      fileDate = dateKeyFromFile(file.path);
      this.fileDate.set(file.path, fileDate);
    }
    const kind = this.options.matchKind;
    let headingIndex = -1;
    const visit = (j: number): void => {
      while (headingIndex + 1 < headings.length && headings[headingIndex + 1]!.line <= j) headingIndex += 1;
      const current = headingIndex >= 0 ? headings[headingIndex] : undefined;
      if (this.options.todoFilters.size && (!current?.todo || !this.options.todoFilters.has(current.todo.toUpperCase()))) return;
      if (
        this.options.tagFilters.size &&
        !Array.from(this.options.tagFilters).every((tag) => current?.tags.some((candidate) => candidate.toLowerCase() === tag))
      ) return;
      if (this.options.headingNeedle && !(current?.title || "").toLowerCase().includes(this.options.headingNeedle)) return;
      const isHeadingLine = current !== undefined && current.line === j;
      if (kind && !matchKindAccepts(kind, isHeadingLine, current?.todo, current?.todoTerminal)) return;
      const sortDate = current?.date || fileDate;
      if (!inDateWindow(sortDate, this.options.dateFrom, this.options.dateTo)) return;
      this.candidates.push({ file, line: j, headingIndex, quality: this.headingQuality(current, isHeadingLine), date: sortDate || undefined });
    };
    if (matchingLines) {
      for (const j of matchingLines) visit(j);
    } else {
      for (let j = 0; j < file.lines.length; j += 1) {
        if (matchesCaseInsensitiveLiteral(file.lines[j] || "", matcher)) visit(j);
      }
    }
  }

  addHits(hits: Org2SearchHit[]): void {
    for (const hit of hits) {
      this.candidates.push({ file: null, line: hit.line - 1, headingIndex: -1, quality: bestSearchQuality(hit, this.needle), date: hit.sortDate || hit.date, hit });
    }
  }

  private timestamp(date: string | undefined): number | undefined {
    if (!date) return undefined;
    if (this.timestampByDate.has(date)) return this.timestampByDate.get(date);
    const value = bestSearchWrittenTimestamp({ sortDate: date } as Org2SearchHit);
    this.timestampByDate.set(date, value);
    return value;
  }

  top(limit: number, modifiedMsByFile: ReadonlyMap<string, number>): Org2SearchHit[] {
    const boostByDate = new Map<string, number>();
    const scored = this.candidates.map((candidate, index) => {
      const filePath = candidate.file?.path ?? candidate.hit!.file;
      let recency = candidate.date === undefined ? undefined : boostByDate.get(candidate.date);
      if (recency === undefined) {
        const written = this.timestamp(candidate.date);
        recency = written !== undefined
          ? bestRecencyBoost(written, this.now)
          : bestRecencyBoost(modifiedMsByFile.get(filePath), this.now) * BEST_MODIFIED_TIME_RECENCY_FACTOR;
        if (written !== undefined) boostByDate.set(candidate.date!, recency);
      }
      return { index, score: candidate.quality + recency };
    });
    scored.sort((a, b) => b.score - a.score || a.index - b.index);
    return scored.slice(0, limit).map(({ index }) => {
      const candidate = this.candidates[index]!;
      return candidate.hit ?? buildIndexedSearchHit(candidate.file!, candidate.line, candidate.headingIndex, candidate.date, this.options);
    });
  }
}

function buildIndexedSearchHit(file: Org2SearchIndexFile, j: number, headingIndex: number, sortDate: string | undefined, options: Org2SearchOptions): Org2SearchHit {
  const headings = file.headings || [];
  const current = headingIndex >= 0 ? headings[headingIndex] : undefined;
  const line = file.lines[j] || "";
  const start = Math.max(0, j - options.context);
  const end = Math.min(file.lines.length - 1, j + options.context);
  const match = { line: j + 1, snippet: line.trim() };
  return {
    file: file.path,
    line: j + 1,
    lineEnd: j + 1,
    heading: current?.title,
    headingLine: current ? current.line + 1 : undefined,
    headingLevel: current?.level,
    headingAncestry: searchHeadingAncestry(headings, headingIndex),
    id: current?.idLine !== undefined && current.idLine <= j ? current.id : undefined,
    todo: current?.todo,
    ...(current?.todoTerminal !== undefined ? { todoTerminal: current.todoTerminal } : {}),
    tags: current?.tags || [],
    snippet: line.trim(),
    context: { startLine: start + 1, endLine: end + 1, lines: file.lines.slice(start, end + 1) },
    sourceRange: { startLine: j + 1, endLine: j + 1 },
    matchedLines: [match],
    date: sortDate || undefined,
    sortDate: sortDate || undefined,
    ...(options.answerContext ? { answerContext: file.lines.slice(start, end + 1).join("\n") } : {}),
  };
}

export function searchFilesByScan(files: string[], options: Org2SearchOptions): { hits: Org2SearchHit[]; skippedFileCount: number } {
  const hits: Org2SearchHit[] = [];
  const subtreeHits = new Map<string, Org2SearchHit>();
  const matcher = literalCaseInsensitiveMatcher(options.query);
  const fileZoneFilters = options.fileZoneFilters.map((zone) => zone.toLowerCase()).filter(Boolean);
  const modifiedMsByFile = new Map<string, number>();
  const ranksByRecency = normalizedSort(options.sort) === "best";
  let skippedFileCount = 0;

  for (const filePath of files) {
    try {
      const normalizedFile = filePath.toLowerCase();
      if (fileZoneFilters.length && !fileZoneFilters.some((zone) => normalizedFile.includes(zone))) continue;
      const raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
      const fileHits: Org2SearchHit[] = [];
      const subtreeCount = subtreeHits.size;
      collectSearchHitsForLines(filePath, raw.split("\n"), matcher, options, fileHits, subtreeHits);
      if (options.matchKind) filterHitsByMatchKind(fileHits, 0, options.matchKind);
      if (ranksByRecency && (fileHits.length > 0 || subtreeHits.size > subtreeCount)) {
        modifiedMsByFile.set(filePath, fs.statSync(filePath).mtimeMs);
      }
      hits.push(...fileHits);
    } catch {
      skippedFileCount += 1;
    }
  }

  return {
    hits: sortAndLimitSearchHits(
      options.subtree ? Array.from(subtreeHits.values()) : hits,
      options.sort,
      options.limit,
      options.query,
      modifiedMsByFile,
    ),
    skippedFileCount,
  };
}

export function searchPayload(options: {
  query: string;
  subtree: boolean;
  sort: string;
  dateFrom: string;
  dateTo: string;
  fileZones: string[];
  index?: Org2SearchResultPayload["index"];
  results: Org2SearchHit[];
}): Org2SearchResultPayload {
  return {
    $schema: "org2:search:v1",
    query: options.query,
    mode: options.subtree ? "subtree" : "line",
    sort: normalizedSort(options.sort),
    ...(options.dateFrom ? { dateFrom: options.dateFrom } : {}),
    ...(options.dateTo ? { dateTo: options.dateTo } : {}),
    ...(options.fileZones.length ? { fileZones: options.fileZones } : {}),
    ...(options.index ? { index: options.index } : {}),
    results: options.results,
  };
}

function collectSearchHitsForLines(
  filePath: string,
  lines: string[],
  matcher: LiteralCaseInsensitiveMatcher,
  options: Org2SearchOptions,
  hits: Org2SearchHit[],
  subtreeHits = new Map<string, Org2SearchHit>(),
): void {
  const stack: SearchHeading[] = [];
  const sequences = documentTodoSequences(lines.join("\n"), todoSequencesForFile(filePath));

  for (let j = 0; j < lines.length; j += 1) {
    const line = lines[j] || "";
    const parsed = line.charCodeAt(0) === 42 ? parseSearchHeading(line, sequences) : null;
    if (parsed) {
      while (stack.length && stack[stack.length - 1]!.level >= parsed.level) stack.pop();
      stack.push({ line: j, ...parsed });
    }

    const current = stack[stack.length - 1];
    const idMatch = current && line.includes(":ID:") ? /^:ID:\s*(\S+)\s*$/.exec(line.trim()) : null;
    if (idMatch && current) current.id = idMatch[1];
    if (!matchesCaseInsensitiveLiteral(line, matcher)) continue;
    if (options.todoFilters.size && (!current?.todo || !options.todoFilters.has(current.todo.toUpperCase()))) continue;
    if (
      options.tagFilters.size &&
      !Array.from(options.tagFilters).every((tag) => current?.tags.map((t) => t.toLowerCase()).includes(tag))
    ) continue;
    if (options.headingNeedle && !(current?.title || "").toLowerCase().includes(options.headingNeedle)) continue;

    const fileDate = dateKeyFromFile(filePath);
    const headingEnd = subtreeEndLine(lines, current, j);
    const headingDate = current ? dateKeyFromLines(lines, current.line, headingEnd) : dateKeyFromLines(lines, j, j);
    const sortDate = headingDate || fileDate;
    if (!inDateWindow(sortDate, options.dateFrom, options.dateTo)) continue;

    const headingAncestry: SearchHeadingRef[] = stack.map((h) => ({
      level: h.level,
      title: h.title,
      line: h.line,
      lineNumber: h.line + 1,
    }));

    const sourceStart = options.subtree && current ? current.line : j;
    const sourceEnd = options.subtree && current ? headingEnd : j;
    const start = options.subtree ? sourceStart : Math.max(0, j - options.context);
    const end = options.subtree ? sourceEnd : Math.min(lines.length - 1, j + options.context);
    const key = `${filePath}:${sourceStart + 1}:${sourceEnd + 1}`;
    const match = { line: j + 1, snippet: line.trim() };

    if (options.subtree) {
      const existing = subtreeHits.get(key);
      if (existing) {
        existing.matchedLines.push(match);
        if (!existing.snippet && match.snippet) existing.snippet = match.snippet;
        continue;
      }
    }

    const hit: Org2SearchHit = {
      file: filePath,
      line: options.subtree ? sourceStart + 1 : j + 1,
      lineEnd: options.subtree ? sourceEnd + 1 : j + 1,
      heading: current?.title,
      headingLine: current ? current.line + 1 : undefined,
      headingLevel: current?.level,
      headingAncestry,
      id: current?.id,
      todo: current?.todo,
      ...(current?.todoTerminal !== undefined ? { todoTerminal: current.todoTerminal } : {}),
      tags: current?.tags || [],
      snippet: line.trim(),
      context: { startLine: start + 1, endLine: end + 1, lines: lines.slice(start, end + 1) },
      sourceRange: { startLine: sourceStart + 1, endLine: sourceEnd + 1 },
      matchedLines: [match],
      date: sortDate || undefined,
      sortDate: sortDate || undefined,
      ...(options.answerContext ? { answerContext: lines.slice(start, end + 1).join("\n") } : {}),
    };

    if (options.subtree) subtreeHits.set(key, hit);
    hits.push(hit);
  }
}

function collectSearchHitsForIndexedFile(
  file: Org2SearchIndexFile,
  matcher: LiteralCaseInsensitiveMatcher,
  options: Org2SearchOptions,
  hits: Org2SearchHit[],
  matchingLines?: Iterable<number>,
): void {
  const headings = file.headings || [];
  const subtreeHits = new Map<string, Org2SearchHit>();
  const fileDate = dateKeyFromFile(file.path);
  const normalized = normalizedSort(options.sort);
  let headingIndex = -1;
  const candidateLines = matchingLines ?? allLineNumbers(file.lines.length);

  for (const j of candidateLines) {
    while (headingIndex + 1 < headings.length && headings[headingIndex + 1]!.line <= j) headingIndex += 1;

    const line = file.lines[j] || "";
    if (!matchingLines && !matchesCaseInsensitiveLiteral(line, matcher)) continue;

    const currentIndex = headingIndex;
    const current = currentIndex >= 0 ? headings[currentIndex] : undefined;
    if (options.todoFilters.size && (!current?.todo || !options.todoFilters.has(current.todo.toUpperCase()))) continue;
    if (
      options.tagFilters.size &&
      !Array.from(options.tagFilters).every((tag) => current?.tags.some((candidate) => candidate.toLowerCase() === tag))
    ) continue;
    if (options.headingNeedle && !(current?.title || "").toLowerCase().includes(options.headingNeedle)) continue;
    if (options.matchKind && !matchKindAccepts(options.matchKind, current !== undefined && current.line === j, current?.todo, current?.todoTerminal)) continue;

    const sortDate = current?.date || fileDate;
    if (!inDateWindow(sortDate, options.dateFrom, options.dateTo)) continue;

    const headingAncestry = searchHeadingAncestry(headings, currentIndex);
    const sourceStart = options.subtree && current ? current.line : j;
    const sourceEnd = options.subtree && current ? current.endLine : j;
    const start = options.subtree ? sourceStart : Math.max(0, j - options.context);
    const end = options.subtree ? sourceEnd : Math.min(file.lines.length - 1, j + options.context);
    const key = `${file.path}:${sourceStart + 1}:${sourceEnd + 1}`;
    const match = { line: j + 1, snippet: line.trim() };

    if (options.subtree) {
      const existing = subtreeHits.get(key);
      if (existing) {
        existing.matchedLines.push(match);
        if (!existing.snippet && match.snippet) existing.snippet = match.snippet;
        continue;
      }
    }

    const hit: Org2SearchHit = {
      file: file.path,
      line: options.subtree ? sourceStart + 1 : j + 1,
      lineEnd: options.subtree ? sourceEnd + 1 : j + 1,
      heading: current?.title,
      headingLine: current ? current.line + 1 : undefined,
      headingLevel: current?.level,
      headingAncestry,
      id: current?.idLine !== undefined && current.idLine <= j ? current.id : undefined,
      todo: current?.todo,
      ...(current?.todoTerminal !== undefined ? { todoTerminal: current.todoTerminal } : {}),
      tags: current?.tags || [],
      snippet: line.trim(),
      context: { startLine: start + 1, endLine: end + 1, lines: file.lines.slice(start, end + 1) },
      sourceRange: { startLine: sourceStart + 1, endLine: sourceEnd + 1 },
      matchedLines: [match],
      date: sortDate || undefined,
      sortDate: sortDate || undefined,
      ...(options.answerContext ? { answerContext: file.lines.slice(start, end + 1).join("\n") } : {}),
    };

    if (options.subtree) subtreeHits.set(key, hit);
    hits.push(hit);
    if (!options.subtree && normalized === "scan" && hits.length >= options.limit) return;
  }
}

function* allLineNumbers(count: number): Iterable<number> {
  for (let j = 0; j < count; j += 1) yield j;
}

function searchHeadingAncestry(headings: Org2SearchIndexHeading[], headingIndex: number): SearchHeadingRef[] {
  if (headingIndex < 0) return [];
  const ancestry: SearchHeadingRef[] = [];
  let currentIndex: number | undefined = headingIndex;
  while (currentIndex !== undefined) {
    const heading: Org2SearchIndexHeading = headings[currentIndex]!;
    ancestry.push({
      level: heading.level,
      title: heading.title,
      line: heading.line,
      lineNumber: heading.line + 1,
    });
    currentIndex = heading.parent;
  }
  ancestry.reverse();
  return ancestry;
}

function literalCaseInsensitiveMatcher(query: string): LiteralCaseInsensitiveMatcher {
  const needle = query.toLowerCase();
  if (NON_ASCII_PATTERN.test(query)) return { needle };
  return {
    needle,
    asciiPattern: new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"),
  };
}

function matchesCaseInsensitiveLiteral(line: string, matcher: LiteralCaseInsensitiveMatcher): boolean {
  // RegExp avoids allocating a lower-cased copy on the overwhelmingly common
  // ASCII path. Unicode retains the exact legacy toLowerCase/includes behavior;
  // JavaScript's /i folding intentionally differs for characters such as the
  // Kelvin sign, dotted capital I, and long s.
  if (matcher.asciiPattern && !NON_ASCII_PATTERN.test(line)) return matcher.asciiPattern.test(line);
  return line.toLowerCase().includes(matcher.needle);
}

function sortAndLimitSearchHits(
  hits: Org2SearchHit[],
  sort: string,
  limit: number,
  query: string,
  modifiedMsByFile: ReadonlyMap<string, number> = new Map(),
): Org2SearchHit[] {
  const normalized = normalizedSort(sort);
  if (normalized === "best") {
    const needle = query.trim().toLowerCase();
    const now = Date.now();
    return hits
      .map((hit, index) => ({ hit, index, score: bestSearchScore(hit, needle, now, modifiedMsByFile.get(hit.file)) }))
      .sort((a, b) => b.score - a.score || a.index - b.index)
      .slice(0, limit)
      .map(({ hit }) => hit);
  }
  if (["date-desc", "newest", "recent"].includes(normalized)) {
    hits.sort((a, b) => (b.sortDate || "").localeCompare(a.sortDate || "") || a.file.localeCompare(b.file) || a.line - b.line);
  } else if (["date-asc", "oldest"].includes(normalized)) {
    hits.sort((a, b) => (a.sortDate || "").localeCompare(b.sortDate || "") || a.file.localeCompare(b.file) || a.line - b.line);
  } else if (normalized === "relevance") {
    const needle = query.trim().toLowerCase();
    hits.sort((a, b) => compareSearchRelevance(a, b, needle));
  }
  return hits.slice(0, limit);
}

// `best` blends match quality with a strong recency bias so the most recently
// relevant material leads. Keep the weights aligned with the macOS app's
// WorkspaceSearchRanking, which reranks these candidates alongside chats,
// files, and pages.
const BEST_RECENCY_WEIGHT = 60;
const BEST_RECENCY_HALF_LIFE_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;

// A file's modification time is a weaker signal than a date written in the
// note: catch-all files change often while the matching line may be old.
const BEST_MODIFIED_TIME_RECENCY_FACTOR = 0.5;

function bestSearchScore(hit: Org2SearchHit, needle: string, now: number, modifiedMs: number | undefined): number {
  const writtenDate = bestSearchWrittenTimestamp(hit);
  const recency = writtenDate !== undefined
    ? bestRecencyBoost(writtenDate, now)
    : bestRecencyBoost(modifiedMs, now) * BEST_MODIFIED_TIME_RECENCY_FACTOR;
  return bestSearchQuality(hit, needle) + recency;
}

function bestSearchQuality(hit: Org2SearchHit, needle: string): number {
  // Match the visible heading, not hidden link targets such as URLs.
  const heading = (hit.heading || "").replace(/\[\[[^\]]*\]\[([^\]]*)\]\]/g, "$1").trim().toLowerCase();
  const isHeadingLine = hit.headingLine !== undefined && hit.headingLine === hit.line;
  let quality = 10;
  if (needle && heading) {
    if (heading === needle) quality = 50;
    else if (heading.startsWith(needle) || wordBoundaryIncludes(heading, needle)) quality = 35;
    else if (heading.includes(needle)) quality = 30;
    if (quality > 10 && !isHeadingLine) quality -= 5;
  }
  const todo = (hit.todo || "").trim().toUpperCase();
  if (todo) {
    const terminal = hit.todoTerminal ?? !isActiveTodoKeyword(todo);
    quality += terminal ? -5 : 10;
  }
  return quality;
}

function wordBoundaryIncludes(text: string, needle: string): boolean {
  let index = text.indexOf(needle);
  while (index > 0) {
    if (!/[\p{L}\p{N}]/u.test(text[index - 1] || "")) return true;
    index = text.indexOf(needle, index + 1);
  }
  return index === 0;
}

function bestSearchWrittenTimestamp(hit: Org2SearchHit): number | undefined {
  const date = hit.sortDate || hit.date;
  const match = date ? /^(\d{4})-(\d{2})-(\d{2})/.exec(date) : null;
  return match ? new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12).getTime() : undefined;
}

function bestRecencyBoost(timestamp: number | undefined, now: number): number {
  if (timestamp === undefined || !Number.isFinite(timestamp)) return 0;
  const ageDays = Math.max(0, now - timestamp) / DAY_MS;
  return BEST_RECENCY_WEIGHT * Math.pow(0.5, ageDays / BEST_RECENCY_HALF_LIFE_DAYS);
}

function compareSearchRelevance(a: Org2SearchHit, b: Org2SearchHit, needle: string): number {
  const aRank = searchRelevanceRank(a, needle);
  const bRank = searchRelevanceRank(b, needle);
  for (let index = 0; index < aRank.length; index += 1) {
    const difference = aRank[index]! - bRank[index]!;
    if (difference !== 0) return difference;
  }
  return 0;
}

function searchRelevanceRank(hit: Org2SearchHit, needle: string): number[] {
  const todo = (hit.todo || "").trim().toUpperCase();
  const hasHeading = Boolean(hit.heading?.trim());
  const heading = (hit.heading || "").trim().toLowerCase();
  const headingMatch = heading === needle ? 0 : heading.includes(needle) ? 1 : 2;
  const matchedHeadingLine = hit.headingLine === hit.line ? 0 : 1;

  // Keep the broad buckets deliberately small and deterministic. The caller's
  // scan order remains the tie-breaker because modern Array.sort is stable.
  const resultKind = (hit.todoTerminal === undefined ? isActiveTodoKeyword(todo) : Boolean(todo) && !hit.todoTerminal) ? 0 : hasHeading ? 1 : 2;
  return [resultKind, headingMatch, matchedHeadingLine];
}

function parseSearchHeading(line: string, sequences: readonly TodoSequence[] = []): Omit<SearchHeading, "line"> | null {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return null;
  let rest = (m[2] || "").trim();
  const tagMatch = /\s+:([A-Za-z0-9_@#%:.-]+):\s*$/.exec(rest);
  const tags = tagMatch ? (tagMatch[1] || "").split(":").filter(Boolean) : [];
  if (tagMatch) rest = rest.slice(0, tagMatch.index).trim();
  const parts = rest.split(/\s+/);
  const todo = todoKeywordInWorkflow(parts[0], sequences);
  if (todo) rest = parts.slice(1).join(" ").trim();
  return { level: (m[1] || "").length, title: parseHeadlineTitleForRoam(`${m[1]} ${rest}`), todo, tags, ...(todo && sequences.length ? { todoTerminal: isTerminalTodoKeyword(todo, sequences) } : {}) };
}

function subtreeEndLine(lines: string[], heading: SearchHeading | undefined, matchLine: number): number {
  if (!heading) return matchLine;
  return Math.max(heading.line, computeSubtreeRange(lines, heading.line).endExclusive - 1);
}

function dateKeyFromFile(file: string): string {
  const base = path.basename(file);
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(base) || /^(\d{4})(\d{2})(\d{2})/.exec(base);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : "";
}

function dateKeyFromLines(lines: string[], start: number, end: number): string {
  for (let j = Math.max(0, start); j <= Math.min(lines.length - 1, end); j += 1) {
    const found = extractDateFromTimestamp(lines[j] || "");
    if (found) return found;
  }
  return "";
}

function extractDateFromTimestamp(raw: string): string | null {
  const match = raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  return match ? match[0] : null;
}

function inDateWindow(date: string, dateFrom: string, dateTo: string): boolean {
  if (!dateFrom && !dateTo) return true;
  if (!date) return false;
  if (dateFrom && date < dateFrom) return false;
  if (dateTo && date > dateTo) return false;
  return true;
}

function normalizedSort(sort: string): string {
  return String(sort || "scan").toLowerCase();
}

function relativeIndexPath(rootDir: string, absolutePath: string): string {
  const relative = path.relative(rootDir, absolutePath);
  return relative && !relative.startsWith("..") && !path.isAbsolute(relative) ? relative : path.basename(absolutePath);
}

function isIndexableChangedPath(rootDir: string, absolutePath: string, includeArchives: boolean): boolean {
  const relativePath = path.relative(rootDir, absolutePath);
  if (!relativePath || relativePath.startsWith("..") || path.isAbsolute(relativePath)) return false;
  const extension = path.extname(absolutePath).toLowerCase();
  if (extension !== ".org" && extension !== ".org2") return false;
  const components = relativePath.split(path.sep);
  if (components.some((component) => component.startsWith(".") || component === "node_modules" || component === "dist" || component === "build" || component === "DerivedData" || component === "sync-conflicts")) return false;
  if (!includeArchives && components.some((component) => component.toLowerCase() === "archive" || component.toLowerCase() === "archives")) return false;
  const name = path.basename(absolutePath);
  return !name.startsWith(".syncthing.") && !name.includes(".sync-conflict-") && !name.endsWith(".tmp");
}
