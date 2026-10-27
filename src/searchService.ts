import fs from "node:fs";
import path from "node:path";
import { listOrgLikeFiles } from "./corpusFiles.js";
import {
  binarySearchIndexPath,
  defaultSearchIndexPath,
  loadCompatibleSearchIndex,
  searchFilesByScan,
  searchIndexedCorpus,
  searchPayload,
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
};

export type SearchServiceResponse = {
  id: string;
  payload?: Org2SearchResultPayload;
  warmed?: boolean;
  error?: string;
};

type CachedIndex = {
  key: string;
  signature: string;
  index: Org2SearchIndex;
  path: string;
  lowerText: WeakMap<Org2SearchIndexFile, string>;
};

let cached: CachedIndex | null = null;

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

/** Returns the in-memory index for a corpus, rereading it only when the files changed. */
export function cachedCompatibleSearchIndex(options: {
  rootDir: string;
  recursive: boolean;
  includeArchives: boolean;
}): { index: Org2SearchIndex; path: string; reloaded: boolean } | null {
  const rootDir = path.resolve(options.rootDir);
  const key = `${rootDir}\u0000${options.recursive}\u0000${options.includeArchives}`;
  const signature = indexSignature(defaultSearchIndexPath(rootDir));
  if (cached && cached.key === key && cached.signature === signature) {
    return { index: cached.index, path: cached.path, reloaded: false };
  }
  cached = null;
  const loaded = loadCompatibleSearchIndex({ ...options, rootDir });
  if (!loaded) return null;
  cached = { key, signature, index: loaded.index, path: loaded.path, lowerText: new WeakMap() };
  return { index: loaded.index, path: loaded.path, reloaded: true };
}

/** Lower-cased whole-file text, built once per loaded index, for skipping files. */
function cachedLowerText(file: Org2SearchIndexFile): string {
  const cache = cached?.lowerText;
  let text = cache?.get(file);
  if (text === undefined) {
    text = file.lines.join("\n").toLowerCase();
    cache?.set(file, text);
  }
  return text;
}

function fileMayContain(file: Org2SearchIndexFile, needle: string): boolean {
  return cachedLowerText(file).includes(needle);
}

export function resetSearchServiceCache(): void {
  cached = null;
}

export function searchIndexServiceResponse(request: SearchServiceRequest): SearchServiceResponse {
  const id = String(request?.id ?? "");
  try {
    const rootDir = String(request?.rootDir ?? "").trim();
    if (!rootDir) return { id, error: "rootDir is required" };
    const recursive = request.recursive !== false;
    const includeArchives = request.includeArchives === true;
    const loaded = cachedCompatibleSearchIndex({ rootDir, recursive, includeArchives });
    const query = typeof request.query === "string" ? request.query : undefined;
    if (query === undefined) {
      if (loaded) for (const file of loaded.index.files) cachedLowerText(file);
      return { id, warmed: loaded !== null };
    }

    const sort = String(request.sort || "best");
    const options: Org2SearchOptions = {
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
    };
    let index: Org2SearchResultPayload["index"];
    let results;
    if (loaded) {
      results = searchIndexedCorpus(loaded.index, options, fileMayContain);
      index = { mode: "current", used: true, path: loaded.path, builtAt: loaded.index.builtAt };
    } else {
      const files = listOrgLikeFiles(path.resolve(rootDir), recursive, includeArchives);
      results = searchFilesByScan(files, options).hits;
      index = { mode: "current", used: false, stale: true };
    }
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
