import fs from "node:fs";
import path from "node:path";
import { listOrgLikeFiles } from "./corpusFiles.js";
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
};

export type SearchServiceResponse = {
  id: string;
  payload?: Org2SearchResultPayload | Record<string, unknown>;
  warmed?: boolean;
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

/**
 * The index for a mounted corpus whose files the app does not index. The
 * worker builds it when missing and, at most every few seconds, rereads only
 * the files whose size or modification time changed, saving the result so
 * other callers and the next launch see it too.
 */
function maintainedSearchIndex(options: { rootDir: string; recursive: boolean; includeArchives: boolean }): { index: Org2SearchIndex; path: string } {
  const rootDir = path.resolve(options.rootDir);
  const key = cacheKey(rootDir, options.recursive, options.includeArchives);
  const indexPath = defaultSearchIndexPath(rootDir);
  const now = Date.now();
  let entry = cache.get(key);
  if (entry && entry.signature !== indexSignature(indexPath)) entry = undefined;
  if (entry && entry.checkedAt !== undefined && now - entry.checkedAt < MAINTAINED_INDEX_CHECK_MS) {
    remember(key, entry);
    return entry;
  }
  const files = listOrgLikeFiles(rootDir, options.recursive, options.includeArchives);
  let index = entry?.index ?? loadCompatibleSearchIndex({ ...options, rootDir })?.index;
  let changed = false;
  if (!index || index.todoWorkflowVersion !== 1) {
    index = buildSearchIndex({ rootDir, files, recursive: options.recursive, includeArchives: options.includeArchives }).index;
    changed = true;
  } else {
    const refreshed = refreshSearchIndexFiles(index, files);
    if (refreshed) {
      index = refreshed;
      changed = true;
    }
  }
  if (changed) {
    try {
      writeSearchIndex({ index, path: indexPath, fileCount: index.files.length, lineCount: 0, byteCount: 0, skippedFiles: 0 });
    } catch {
      // The in-memory index still answers; the next change retries the save.
    }
  }
  entry = { signature: indexSignature(indexPath), index, path: indexPath, checkedAt: now };
  remember(key, entry);
  return entry;
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

function warmIndex(index: Org2SearchIndex): void {
  for (const file of index.files) cachedLineStarts(file, cachedLowerText(file));
}

export function resetSearchServiceCache(): void {
  cache.clear();
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
      results: searchIndexedCorpus(loaded.index, options, { mayContain: fileMayContain, matchingLines: fileMatchingLines }),
      index: { mode: "current", used: true, path: loaded.path, builtAt: loaded.index.builtAt },
    };
  }
  const files = listOrgLikeFiles(path.resolve(rootDir), flags.recursive, flags.includeArchives);
  return { results: searchFilesByScan(files, options).hits, index: { mode: "current", used: false, stale: true } };
}

export function searchIndexServiceResponse(request: SearchServiceRequest): SearchServiceResponse {
  const id = String(request?.id ?? "");
  try {
    const rootDir = String(request?.rootDir ?? "").trim();
    if (!rootDir) return { id, error: "rootDir is required" };
    const recursive = request.recursive !== false;
    const includeArchives = request.includeArchives === true;
    const mounts = Array.isArray(request.mounts) ? request.mounts.map(String).filter(Boolean) : [];
    const activeRoot = path.resolve(rootDir);
    const isMaintained = (root: string) => path.resolve(root) !== activeRoot;
    const query = typeof request.query === "string" ? request.query : undefined;

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
