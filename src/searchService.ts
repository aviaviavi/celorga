import fs from "node:fs";
import path from "node:path";
import { listOrgLikeFiles } from "./corpusFiles.js";
import { todoConfigurationKey } from "./todo.js";
import { interleaveFederatedResults, resolveFederatedCorpora, type WorkspaceCorpusRef, type WorkspaceReadIssue } from "./federatedWorkspace.js";
import {
  binarySearchIndexPath,
  buildSearchIndex,
  defaultSearchIndexPath,
  loadCompatibleSearchIndex,
  parseSearchMatchKind,
  refreshSearchIndexFiles,
  searchFilesByScan,
  searchIndexedCorpus,
  searchPayload,
  writeSearchIndex,
  type Org2SearchHit,
  type Org2SearchIndex,
  type Org2SearchIndexFile,
  type Org2SearchOptions,
  type Org2SearchResultPayload,
  warmBestSearchRanking,
} from "./searchIndex.js";

export type SearchServiceRequest = {
  id: string;
  /** Corpus root; the index is the one `celorga index --dir ROOT` writes. */
  rootDir: string;
  /** Omit to only load the index (warm-up). */
  query?: string;
  limit?: number;
  context?: number;
  sort?: string;
  recursive?: boolean;
  includeArchives?: boolean;
  /** Only matches on heading lines, inside open TODOs, or in body text. */
  matchKind?: string;
  /** Shorten snippet and context lines longer than this. */
  maxLineLength?: number;
  /**
   * Search these corpora together (like `celorga workspace search`). `rootDir`
   * keeps the index the app maintains; the worker keeps every other mounted
   * corpus's index current itself.
   */
  mounts?: string[];
  /**
   * With no query: bring the in-memory index up to date with the files on
   * disk now (rereading only changed files, or building it when missing)
   * and save it once the worker is idle. This replaces running a full
   * `celorga index` after every change.
   */
  refresh?: boolean;
};

export type SearchServiceIndexSummary = {
  fileCount: number;
  lineCount: number;
  byteCount: number;
  skippedFiles: number;
  builtAt: string;
  /** Files reread, added, or dropped by this refresh. */
  updatedFiles: number;
};

export type SearchServiceResponse = {
  id: string;
  payload?: Org2SearchResultPayload | Record<string, unknown>;
  warmed?: boolean;
  /** For a `refresh` request: the active corpus's index after the refresh. */
  indexed?: SearchServiceIndexSummary;
  error?: string;
};

type CachedIndex = {
  signature: string;
  index: Org2SearchIndex;
  path: string;
  /** For indexes this worker maintains: when the files were last compared with the index. */
  checkedAt?: number;
};

/** Indexes by corpus root and options; a handful of mounted corpora at most. */
const cache = new Map<string, CachedIndex>();
const MAX_CACHED_INDEXES = 6;
/** How often a worker-maintained index is compared with the files on disk. */
const MAINTAINED_INDEX_CHECK_MS = 5_000;

// Per-file caches keyed by the indexed file object, so they die with it.
const lowerTextByFile = new WeakMap<Org2SearchIndexFile, string>();
const lineStartsByFile = new WeakMap<Org2SearchIndexFile, Int32Array>();

function fileSignature(filePath: string): string {
  try {
    const stat = fs.statSync(filePath);
    return `${stat.mtimeMs}:${stat.size}`;
  } catch {
    return "missing";
  }
}

function indexSignature(indexPath: string): string {
  return `${fileSignature(indexPath)}|${fileSignature(binarySearchIndexPath(indexPath))}`;
}

function cacheKey(rootDir: string, recursive: boolean, includeArchives: boolean): string {
  return `${rootDir}\u0000${recursive}\u0000${includeArchives}`;
}

function remember(key: string, entry: CachedIndex): void {
  cache.delete(key);
  cache.set(key, entry);
  while (cache.size > MAX_CACHED_INDEXES) cache.delete(cache.keys().next().value!);
}

/** Returns the in-memory index for a corpus, rereading it only when the files changed. */
export function cachedCompatibleSearchIndex(options: {
  rootDir: string;
  recursive: boolean;
  includeArchives: boolean;
}): { index: Org2SearchIndex; path: string; reloaded: boolean } | null {
  const rootDir = path.resolve(options.rootDir);
  const key = cacheKey(rootDir, options.recursive, options.includeArchives);
  const signature = indexSignature(defaultSearchIndexPath(rootDir));
  const existing = cache.get(key);
  if (existing && existing.signature === signature) {
    remember(key, existing);
    return { index: existing.index, path: existing.path, reloaded: false };
  }
  if (existing && !signature.startsWith("missing|")) {
    // The app rewrote the index after files changed. Rereading and decoding
    // the whole index (and every file's lower-cased text) takes most of a
    // second on a large corpus; comparing the files on disk with the index
    // in memory and rereading only the changed ones takes a fraction of
    // that, and keeps the per-file caches of unchanged files.
    try {
      const files = listOrgLikeFiles(rootDir, options.recursive, options.includeArchives);
      const refreshed = refreshSearchIndexFiles(existing.index, files) ?? existing.index;
      remember(key, { signature, index: refreshed, path: existing.path });
      return { index: refreshed, path: existing.path, reloaded: false };
    } catch {
      // Fall through to a full reload.
    }
  }
  cache.delete(key);
  const loaded = loadCompatibleSearchIndex({ ...options, rootDir });
  if (!loaded) return null;
  remember(key, { signature, index: loaded.index, path: loaded.path });
  return { index: loaded.index, path: loaded.path, reloaded: true };
}

/** Saves waiting for the worker to go idle, by cache key. */
const pendingSaves = new Map<string, { timer: ReturnType<typeof setTimeout>; firstScheduledAt: number }>();
/** Wait this long after a change before saving, so a burst of edits saves once. */
const SAVE_DELAY_MS = 2_000;
/** Postpone a save while queries keep arriving this close together... */
const SAVE_IDLE_MS = 750;
/** ...but never for longer than this. */
const SAVE_MAX_DELAY_MS = 30_000;
let lastRequestAt = 0;

/**
 * Writing a large index takes most of a second, during which the worker
 * cannot answer. Saves therefore wait until queries stop arriving; the
 * in-memory index answers meanwhile.
 */
function scheduleSave(key: string): void {
  const pending = pendingSaves.get(key);
  if (pending) return;
  const firstScheduledAt = Date.now();
  const arm = (delay: number): void => {
    const timer = setTimeout(() => {
      const now = Date.now();
      if (now - lastRequestAt < SAVE_IDLE_MS && now - firstScheduledAt < SAVE_MAX_DELAY_MS) {
        arm(SAVE_IDLE_MS);
        return;
      }
      saveNow(key);
    }, delay);
    timer.unref?.();
    pendingSaves.set(key, { timer, firstScheduledAt });
  };
  arm(SAVE_DELAY_MS);
}

function saveNow(key: string): void {
  const pending = pendingSaves.get(key);
  if (pending) clearTimeout(pending.timer);
  pendingSaves.delete(key);
  const entry = cache.get(key);
  if (!entry) return;
  try {
    writeSearchIndex({ index: entry.index, path: entry.path, fileCount: entry.index.files.length, lineCount: 0, byteCount: 0, skippedFiles: 0 });
    entry.signature = indexSignature(entry.path);
  } catch {
    // The in-memory index still answers; the next change retries the save.
  }
}

/** Writes every index whose save is still waiting; call before exiting. */
export function flushSearchServiceSaves(): void {
  for (const key of Array.from(pendingSaves.keys())) saveNow(key);
}

/**
 * An index this worker keeps current itself. It is built when missing; after
 * that only files whose size or modification time changed are reread. Without
 * `force`, files are compared with the index at most every few seconds.
 * Changes are saved once the worker is idle, so other callers and the next
 * launch see them too.
 */
function maintainedSearchIndex(
  options: { rootDir: string; recursive: boolean; includeArchives: boolean },
  force = false,
): { index: Org2SearchIndex; path: string; updatedFiles: number; skippedFiles: number } {
  const rootDir = path.resolve(options.rootDir);
  const key = cacheKey(rootDir, options.recursive, options.includeArchives);
  const indexPath = defaultSearchIndexPath(rootDir);
  const now = Date.now();
  const entry = cache.get(key);
  const signature = indexSignature(indexPath);
  if (!force && entry && entry.signature === signature && entry.checkedAt !== undefined && now - entry.checkedAt < MAINTAINED_INDEX_CHECK_MS) {
    remember(key, entry);
    return { ...entry, updatedFiles: 0, skippedFiles: 0 };
  }
  const files = listOrgLikeFiles(rootDir, options.recursive, options.includeArchives);
  // Comparing the files with the index already in memory is much cheaper
  // than decoding the saved index again, even when another process saved a
  // newer one.
  let index = entry?.index ?? loadCompatibleSearchIndex({ ...options, rootDir })?.index;
  let updatedFiles = 0;
  let skippedFiles = 0;
  if (!index || index.todoWorkflowVersion !== 1) {
    const built = buildSearchIndex({ rootDir, files, recursive: options.recursive, includeArchives: options.includeArchives });
    index = built.index;
    updatedFiles = built.fileCount;
    skippedFiles = built.skippedFiles;
  } else {
    const before = new Set(index.files);
    const refreshed = refreshSearchIndexFiles(index, files);
    if (refreshed) {
      // Reread and added files are new objects; removed files are missing paths.
      const paths = new Set(refreshed.files.map((file) => file.path));
      for (const file of refreshed.files) if (!before.has(file)) updatedFiles += 1;
      for (const file of index.files) if (!paths.has(file.path)) updatedFiles += 1;
      index = refreshed;
    }
  }
  remember(key, { signature, index, path: indexPath, checkedAt: now });
  if (updatedFiles > 0 || signature.startsWith("missing|")) scheduleSave(key);
  return { index, path: indexPath, updatedFiles, skippedFiles };
}

function indexSummary(index: Org2SearchIndex, updatedFiles: number, skippedFiles: number): SearchServiceIndexSummary {
  let lineCount = 0;
  let byteCount = 0;
  for (const file of index.files) {
    lineCount += file.lines.length;
    byteCount += file.byteCount;
  }
  return { fileCount: index.files.length, lineCount, byteCount, skippedFiles, builtAt: index.builtAt, updatedFiles };
}

/** Lower-cased whole-file text, built once per indexed file, for skipping files. */
function cachedLowerText(file: Org2SearchIndexFile): string {
  let text = lowerTextByFile.get(file);
  if (text === undefined) {
    text = file.lines.join("\n").toLowerCase();
    lowerTextByFile.set(file, text);
  }
  return text;
}

function fileMayContain(file: Org2SearchIndexFile, needle: string): boolean {
  return cachedLowerText(file).includes(needle);
}

/** Offsets in the cached lower-cased text where each line starts. */
function cachedLineStarts(file: Org2SearchIndexFile, text: string): Int32Array {
  let starts = lineStartsByFile.get(file);
  if (!starts) {
    starts = new Int32Array(file.lines.length);
    let position = 0;
    for (let line = 0; line < file.lines.length; line += 1) {
      starts[line] = position;
      position = text.indexOf("\n", position) + 1;
      if (position === 0) position = text.length + 1;
    }
    lineStartsByFile.set(file, starts);
  }
  return starts;
}

/**
 * Lines containing the needle, found with indexOf over the whole lower-cased
 * file instead of a test per line. Lower-casing keeps newlines, so line
 * numbers come from the lower-cased text itself.
 */
function* fileMatchingLines(file: Org2SearchIndexFile, needle: string): Iterable<number> {
  if (!needle) {
    for (let line = 0; line < file.lines.length; line += 1) yield line;
    return;
  }
  const text = cachedLowerText(file);
  const starts = cachedLineStarts(file, text);
  let from = text.indexOf(needle);
  let line = 0;
  while (from >= 0) {
    while (line + 1 < starts.length && starts[line + 1]! <= from) line += 1;
    yield line;
    if (line + 1 >= starts.length) return;
    from = text.indexOf(needle, starts[line + 1]!);
  }
}

/**
 * TODO configuration keys by folder, shared across queries. Reading
 * celorga.json for every folder on every query cost tens of milliseconds;
 * a configuration change is picked up within a few seconds.
 */
const configurationKeyByDirectory = new Map<string, { key: string; checkedAt: number }>();
const CONFIGURATION_KEY_TTL_MS = 3_000;

function cachedConfigurationKey(filePath: string): string {
  const directory = path.dirname(filePath);
  const now = Date.now();
  const cached = configurationKeyByDirectory.get(directory);
  if (cached && now - cached.checkedAt < CONFIGURATION_KEY_TTL_MS) return cached.key;
  const key = todoConfigurationKey(filePath);
  configurationKeyByDirectory.set(directory, { key, checkedAt: now });
  return key;
}

function warmIndex(index: Org2SearchIndex): void {
  for (const file of index.files) {
    cachedLineStarts(file, cachedLowerText(file));
    warmBestSearchRanking(file);
  }
}

export function resetSearchServiceCache(): void {
  for (const pending of pendingSaves.values()) clearTimeout(pending.timer);
  pendingSaves.clear();
  cache.clear();
  configurationKeyByDirectory.clear();
}

function searchOptions(request: SearchServiceRequest, query: string, sort: string): Org2SearchOptions {
  return {
    query,
    context: Math.max(0, Math.trunc(Number(request.context ?? 0)) || 0),
    limit: Math.max(1, Math.trunc(Number(request.limit ?? 50)) || 50),
    todoFilters: new Set(),
    tagFilters: new Set(),
    fileZoneFilters: [],
    headingNeedle: "",
    sort,
    dateFrom: "",
    dateTo: "",
    subtree: false,
    answerContext: false,
    matchKind: parseSearchMatchKind(request.matchKind),
    ...(Number(request.maxLineLength) > 0 ? { maxLineLength: Math.trunc(Number(request.maxLineLength)) } : {}),
  };
}

function searchOneCorpus(
  rootDir: string,
  options: Org2SearchOptions,
  flags: { recursive: boolean; includeArchives: boolean; maintained: boolean },
): { results: Org2SearchHit[]; index: Org2SearchResultPayload["index"] } {
  const loaded = flags.maintained
    ? maintainedSearchIndex({ rootDir, ...flags })
    : cachedCompatibleSearchIndex({ rootDir, ...flags });
  if (loaded) {
    return {
      results: searchIndexedCorpus(loaded.index, options, {
        mayContain: fileMayContain,
        matchingLines: fileMatchingLines,
        configurationKey: cachedConfigurationKey,
      }),
      index: { mode: "current", used: true, path: loaded.path, builtAt: loaded.index.builtAt },
    };
  }
  const files = listOrgLikeFiles(path.resolve(rootDir), flags.recursive, flags.includeArchives);
  return { results: searchFilesByScan(files, options).hits, index: { mode: "current", used: false, stale: true } };
}

export function searchIndexServiceResponse(request: SearchServiceRequest): SearchServiceResponse {
  const id = String(request?.id ?? "");
  try {
    return answerSearchServiceRequest(id, request);
  } catch (error) {
    return { id, error: error instanceof Error ? error.message : String(error) };
  } finally {
    lastRequestAt = Date.now();
  }
}

function answerSearchServiceRequest(id: string, request: SearchServiceRequest): SearchServiceResponse {
  try {
    const rootDir = String(request?.rootDir ?? "").trim();
    if (!rootDir) return { id, error: "rootDir is required" };
    const recursive = request.recursive !== false;
    const includeArchives = request.includeArchives === true;
    const mounts = Array.isArray(request.mounts) ? request.mounts.map(String).filter(Boolean) : [];
    const activeRoot = path.resolve(rootDir);
    const isMaintained = (root: string) => path.resolve(root) !== activeRoot;
    const query = typeof request.query === "string" ? request.query : undefined;

    if (query === undefined && request.refresh === true) {
      const refreshed = maintainedSearchIndex({ rootDir, recursive, includeArchives }, true);
      for (const root of mounts) {
        if (isMaintained(root)) warmIndex(maintainedSearchIndex({ rootDir: root, recursive, includeArchives }).index);
      }
      warmIndex(refreshed.index);
      return { id, warmed: true, indexed: indexSummary(refreshed.index, refreshed.updatedFiles, refreshed.skippedFiles) };
    }

    if (query === undefined) {
      let warmed = false;
      for (const root of mounts.length > 0 ? mounts : [rootDir]) {
        const loaded = isMaintained(root)
          ? maintainedSearchIndex({ rootDir: root, recursive, includeArchives })
          : cachedCompatibleSearchIndex({ rootDir: root, recursive, includeArchives });
        if (loaded) {
          warmIndex(loaded.index);
          warmed = true;
        }
      }
      return { id, warmed };
    }

    const sort = String(request.sort || "best");
    const options = searchOptions(request, query, sort);
    if (mounts.length > 0) {
      const { corpora, issues } = resolveFederatedCorpora(mounts);
      const perCorpus: Array<{ corpus: WorkspaceCorpusRef; results: Array<Record<string, unknown>> }> = [];
      const allIssues: WorkspaceReadIssue[] = [...issues];
      for (const corpus of corpora) {
        try {
          const { results } = searchOneCorpus(corpus.root, options, { recursive, includeArchives, maintained: isMaintained(corpus.root) });
          perCorpus.push({ corpus, results: results as unknown as Array<Record<string, unknown>> });
        } catch (error) {
          allIssues.push({ root: corpus.root, message: error instanceof Error ? error.message : String(error) });
        }
      }
      allIssues.sort((left, right) => left.root.localeCompare(right.root) || left.message.localeCompare(right.message));
      return {
        id,
        payload: {
          $schema: "org2:workspace-search:v1",
          query,
          mode: "line",
          sort: searchPayload({ query, subtree: false, sort, dateFrom: "", dateTo: "", fileZones: [], results: [] }).sort,
          corpora,
          issues: allIssues,
          results: interleaveFederatedResults(perCorpus, options.limit),
        },
      };
    }

    const { results, index } = searchOneCorpus(rootDir, options, { recursive, includeArchives, maintained: false });
    return {
      id,
      payload: searchPayload({
        query,
        subtree: false,
        sort,
        dateFrom: "",
        dateTo: "",
        fileZones: [],
        index,
        results,
      }),
    };
  } catch (error) {
    return { id, error: error instanceof Error ? error.message : String(error) };
  }
}
