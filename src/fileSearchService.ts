// File search inside the app's long-lived search worker.
//
// The worker loads the saved file index (or builds one), keeps it current from
// file system change notifications, and rebuilds it in the background when it
// is older than FILE_SEARCH_INDEX_MAX_AGE_MS or the configuration changed. A
// query never waits for a build: it searches whatever has been indexed so far
// and reports `index.building` so the client can ask again.

import fs from "node:fs";
import path from "node:path";
import {
  buildFileSearchIndex,
  FILE_SEARCH_INDEX_MAX_AGE_MS,
  FileSearchIndex,
  fileSearchConfigPath,
  fileSearchHome,
  fileSearchPayload,
  isIndexedPath,
  loadFileSearchIndex,
  parseFileSearchKind,
  readFileSearchConfig,
  refreshDirectory,
  saveFileSearchIndex,
  searchFileIndex,
  type FileSearchConfig,
  type FileSearchKind,
  type FileSearchPayload,
} from "./fileSearch.js";

export type FileSearchServiceRequest = {
  /** Omit to only load or start building the index (warm-up). */
  query?: string;
  limit?: number;
  kinds?: string[];
  /** Rebuild the index now, even when it is fresh. */
  rebuild?: boolean;
};

type State = {
  home: string;
  configSignature: string;
  config: FileSearchConfig;
  /** The index queries read. During a first build it fills in as the walk proceeds. */
  live: FileSearchIndex;
  rebuilding: Promise<void> | null;
  watchers: fs.FSWatcher[];
  pendingDirs: Set<string>;
  flushTimer: NodeJS.Timeout | null;
  saveTimer: NodeJS.Timeout | null;
  dirtySinceSave: boolean;
};

let state: State | null = null;

function signatureOf(file: string): string {
  try {
    const stat = fs.statSync(file);
    return `${stat.mtimeMs}:${stat.size}`;
  } catch {
    return "missing";
  }
}

function stopWatching(current: State): void {
  for (const watcher of current.watchers) {
    try { watcher.close(); } catch { /* already closed */ }
  }
  current.watchers = [];
  if (current.flushTimer) clearTimeout(current.flushTimer);
  if (current.saveTimer) clearTimeout(current.saveTimer);
  current.flushTimer = null;
  current.saveTimer = null;
}

function scheduleSave(current: State): void {
  current.dirtySinceSave = true;
  if (current.saveTimer) return;
  current.saveTimer = setTimeout(() => {
    current.saveTimer = null;
    if (state !== current || current.rebuilding || !current.dirtySinceSave) return;
    current.dirtySinceSave = false;
    try { saveFileSearchIndex(current.live, current.home); } catch { /* the next save retries */ }
  }, 30_000);
  current.saveTimer.unref?.();
}

function flushPending(current: State): void {
  current.flushTimer = null;
  if (state !== current) return;
  // While a rebuild runs, changes wait so they also apply to the new index.
  if (current.rebuilding) return;
  const dirs = [...current.pendingDirs].sort((left, right) => left.length - right.length);
  current.pendingDirs.clear();
  for (const dir of dirs) refreshDirectory(current.live, dir);
  if (dirs.length > 0) scheduleSave(current);
}

function noteChange(current: State, changedPath: string): void {
  const rules = current.live.rules;
  if (!isIndexedPath(changedPath, rules)) return;
  const parent = path.dirname(changedPath);
  current.pendingDirs.add(rules.roots.includes(changedPath) ? changedPath : parent);
  if (current.flushTimer) return;
  current.flushTimer = setTimeout(() => flushPending(current), 400);
  current.flushTimer.unref?.();
}

function startWatching(current: State): void {
  stopWatching(current);
  for (const root of current.live.rules.roots) {
    try {
      const watcher = fs.watch(root, { recursive: true, persistent: false }, (_event, filename) => {
        if (!filename) {
          noteChange(current, root);
          return;
        }
        noteChange(current, path.join(root, filename.toString()));
      });
      watcher.on("error", () => { /* the next periodic rebuild catches up */ });
      current.watchers.push(watcher);
    } catch {
      // A missing or unreadable root is simply not watched.
    }
  }
}

function startRebuild(current: State): Promise<void> {
  if (current.rebuilding) return current.rebuilding;
  const fresh = new FileSearchIndex(current.config);
  // A first build fills the live index directly so queries see results at once.
  const target = current.live.builtAt === null && current.live.size === 0 ? current.live : fresh;
  target.building = true;
  current.live.building = true;
  current.rebuilding = (async () => {
    try {
      await buildFileSearchIndex(target, { shouldStop: () => state !== current });
      if (state !== current) return;
      target.building = false;
      current.live.building = false;
      current.live = target;
      current.rebuilding = null;
      target.prepare();
      try { saveFileSearchIndex(target, current.home); } catch { /* a later save retries */ }
      current.dirtySinceSave = false;
      if (current.pendingDirs.size > 0) flushPending(current);
    } finally {
      target.building = false;
      if (state === current) {
        current.live.building = false;
        current.rebuilding = null;
      }
    }
  })();
  return current.rebuilding;
}

function ensureState(): State {
  const home = fileSearchHome();
  const configSignature = `${home}\u0000${signatureOf(fileSearchConfigPath(home))}`;
  if (state && state.configSignature === configSignature) return state;
  if (state) stopWatching(state);
  const config = readFileSearchConfig(home);
  const loaded = loadFileSearchIndex(config, home);
  const current: State = {
    home,
    configSignature,
    config,
    live: loaded ?? new FileSearchIndex(config),
    rebuilding: null,
    watchers: [],
    pendingDirs: new Set(),
    flushTimer: null,
    saveTimer: null,
    dirtySinceSave: false,
  };
  state = current;
  startWatching(current);
  if (!loaded || loaded.builtAt === null || Date.now() - loaded.builtAt > FILE_SEARCH_INDEX_MAX_AGE_MS) {
    void startRebuild(current);
  }
  return current;
}

export function resetFileSearchService(): void {
  if (state) stopWatching(state);
  state = null;
}

/** Waits for a running build (tests and `--wait` callers). */
export async function waitForFileSearchIndex(): Promise<void> {
  await state?.rebuilding;
}

export function fileSearchServiceResponse(request: FileSearchServiceRequest): FileSearchPayload {
  const startedAt = Date.now();
  const current = ensureState();
  if (request.rebuild) void startRebuild(current);
  else if (current.live.builtAt !== null && Date.now() - current.live.builtAt > FILE_SEARCH_INDEX_MAX_AGE_MS) void startRebuild(current);
  // Apply queued changes before answering, so a file saved a moment ago shows up.
  if (current.flushTimer && !current.rebuilding) {
    clearTimeout(current.flushTimer);
    flushPending(current);
  }
  const query = typeof request.query === "string" ? request.query : "";
  const kinds = (request.kinds ?? []).map((kind) => parseFileSearchKind(String(kind))).filter((kind): kind is FileSearchKind => kind !== null);
  // A warm-up also prepares the query structures, so the first search is fast.
  if (typeof request.query !== "string" && !current.live.building) current.live.prepare();
  const results = typeof request.query === "string"
    ? searchFileIndex(current.live, {
      query,
      limit: Math.max(1, Math.min(500, Math.trunc(Number(request.limit ?? 60)) || 60)),
      kinds,
    })
    : [];
  return fileSearchPayload(query, current.live, results, startedAt, current.home);
}
