import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  AI_CHAT_MAX_ROOM_AGENT_TURN_LIMIT,
  AI_CHAT_OPERATION_SCHEMA,
  type AIChatOperation,
  isValidRoomAgentTurnLimit,
  loadAIChatOperations,
  nextAIChatOperationIdentity,
  queueAIChatOperation,
} from "./aiChatOperationJournal.js";
import { schemaMatches, stateDir } from "./brandNames.js";

export const OPENCLAW_THREAD_STATE_SCHEMA = "org2:openclaw-thread-state:v1";
export const OPENCLAW_TRANSCRIPT_VERSION = 6;
const STORE_MARKER_SCHEMA = "org2:ai-chat-transcript-store-marker:v1";
const STORE_HEAD_SCHEMA = "org2:ai-chat-transcript-head:v1";
const MANIFEST_V2_SCHEMA = "org2:ai-chat-transcript-manifest:v2";
const MANIFEST_V1_SCHEMA = "org2:ai-chat-transcript-manifest:v1";
const THREAD_SHARD_SCHEMA = "org2:ai-chat-thread:v1";
const APPLE_REFERENCE_DATE_UNIX_SECONDS = 978_307_200;

type JSONRecord = Record<string, unknown>;

export interface OpenClawThreadSettlementSettings {
  autoSettleAfterSeconds: number | null;
}

export interface OpenClawChatMessageRecord {
  id?: string;
  role?: string;
  content?: string;
  deliveryStatus?: string;
  sendFailure?: string | null;
  authorLabel?: string;
  authorAgentRef?: string;
  source?: string;
  attachments?: unknown[];
  [key: string]: unknown;
}

export interface OpenClawChatThreadRecord {
  id: string;
  title?: string;
  updatedAt: number | string;
  messages?: OpenClawChatMessageRecord[];
  storedMessageCount?: number | null;
  storedHasUnresolvedLatestDelivery?: boolean | null;
  storedLatestDeliveryNeedsAttention?: boolean | null;
  isPinned?: boolean;
  isArchived?: boolean;
  settledAt?: number | string | null;
  unreadMessageCount?: number;
  pendingTurn?: unknown;
  runtime?: "openClaw" | "codex" | "claude" | "pi" | "openCode";
  destinationID?: string;
  runtimeThreadID?: string | null;
  model?: string | null;
  reasoningEffort?: string | null;
  isSharedRoom?: boolean;
  roomDestinationIDs?: string[];
  roomAgentTurnLimit?: number | null;
  [key: string]: unknown;
}

export interface OpenClawTranscriptRecord {
  version: number;
  messages?: unknown[] | null;
  threads?: OpenClawChatThreadRecord[] | null;
  selectedThreadID?: string | null;
  settlementSettings?: Partial<OpenClawThreadSettlementSettings> | null;
  [key: string]: unknown;
}

export type OpenClawThreadStorageLayout =
  | "empty"
  | "legacy-monolith"
  | "sharded-v1"
  | "sharded-v2"
  | "sharded-v2-pointer";

export type OpenClawThreadRecoveryStatus = "healthy" | "recovered-previous-manifest";

export interface OpenClawThreadState {
  schema: typeof OPENCLAW_THREAD_STATE_SCHEMA;
  file: string;
  legacyFile: string;
  version: number;
  selectedThreadID: string | null;
  settlementSettings: OpenClawThreadSettlementSettings;
  threads: OpenClawChatThreadRecord[];
  storageLayout: OpenClawThreadStorageLayout;
  recoveryStatus: OpenClawThreadRecoveryStatus;
  commitID: string | null;
  generation: number | null;
  pendingOperationCount: number;
}

export interface OpenClawThreadMutationResult {
  applied: boolean;
  queued: boolean;
  committed: false;
  changed: boolean;
  state: OpenClawThreadState;
  affectedThreadIds: string[];
  operationFiles: string[];
  operation?: AIChatOperation;
}

export interface LoadOpenClawThreadStateOptions {
  hydrateThreadID?: string;
  /** Hydrate messages in recently updated threads using Unix milliseconds. */
  hydrateUpdatedSince?: number;
  /** Let read-only projections discard trace payloads while each shard is decoded. */
  projectMessage?: (message: OpenClawChatMessageRecord) => OpenClawChatMessageRecord;
  includePendingOperations?: boolean;
}

interface StoreMarker {
  currentManifest: string;
  currentDigest: string;
  previousManifest: string | null;
  previousDigest: string | null;
}

interface ManifestThreadEntry {
  metadata: OpenClawChatThreadRecord;
  shard: string;
  shardDigest: string;
}

interface ResolvedTranscript {
  state: OpenClawThreadState;
  entries: Map<string, ManifestThreadEntry>;
  storeRoot: string | null;
}

interface ParsedManifest {
  file: string;
  layout: "sharded-v1" | "sharded-v2";
  threads: OpenClawChatThreadRecord[];
  entries: ManifestThreadEntry[];
  selectedThreadID: string | null;
  settlementSettings: OpenClawThreadSettlementSettings;
  commitID: string | null;
  generation: number | null;
  /** Commits this manifest already incorporates (ancestors and merged branches). */
  subsumedCommitIDs?: string[];
}

export function openClawTranscriptPath(corpusRoot: string): string {
  return stateDir(path.resolve(corpusRoot), "openclaw-chat.json");
}

export function openClawTranscriptStorePath(corpusRoot: string): string {
  const transcript = openClawTranscriptPath(corpusRoot);
  return path.join(path.dirname(transcript), `${path.basename(transcript, path.extname(transcript))}.store`);
}

function isRecord(value: unknown): value is JSONRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function digest(data: Buffer): string {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function isDigest(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{64}$/iu.test(value);
}

function settlementSettings(payload: JSONRecord): OpenClawThreadSettlementSettings {
  const rawSettings = isRecord(payload.settlementSettings) ? payload.settlementSettings : undefined;
  const value = rawSettings?.autoSettleAfterSeconds;
  return {
    autoSettleAfterSeconds: typeof value === "number" && Number.isFinite(value) && value > 0
      ? value
      : null,
  };
}

function normalizedThread(value: unknown): OpenClawChatThreadRecord | null {
  if (!isRecord(value)
      || typeof value.id !== "string"
      || (typeof value.updatedAt !== "number" && typeof value.updatedAt !== "string")) {
    return null;
  }
  if (value.messages !== undefined && !Array.isArray(value.messages)) return null;
  return value as unknown as OpenClawChatThreadRecord;
}

function normalizedLegacyThreads(payload: JSONRecord): OpenClawChatThreadRecord[] {
  if (!Array.isArray(payload.threads)) return [];
  return payload.threads
    .map(normalizedThread)
    .filter((thread): thread is OpenClawChatThreadRecord => thread !== null);
}

function safeManifestName(value: unknown): value is string {
  return typeof value === "string"
    && value.length > 0
    && path.basename(value) === value;
}

function parseMarker(file: string): StoreMarker | null {
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
    if (!isRecord(value)
        || !schemaMatches(value.schema, STORE_MARKER_SCHEMA)
        || typeof value.version !== "number"
        || !safeManifestName(value.currentManifest)
        || !isDigest(value.currentDigest)
        || (value.previousManifest !== undefined
          && value.previousManifest !== null
          && !safeManifestName(value.previousManifest))
        || (value.previousDigest !== undefined
          && value.previousDigest !== null
          && !isDigest(value.previousDigest))) {
      return null;
    }
    return {
      currentManifest: value.currentManifest,
      currentDigest: value.currentDigest,
      previousManifest: typeof value.previousManifest === "string" ? value.previousManifest : null,
      previousDigest: typeof value.previousDigest === "string" ? value.previousDigest : null,
    };
  } catch {
    return null;
  }
}

/**
 * Per-writer commit points (`heads/<writer>.json`). Each Celorga app host owns one
 * head so synchronized replicas never rewrite the same file. Newest first.
 */
function parseHeads(storeRoot: string): Array<StoreMarker & { generation: number }> {
  const headsRoot = path.join(storeRoot, "heads");
  let names: string[] = [];
  try {
    names = fs.readdirSync(headsRoot, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json") && !entry.name.startsWith("."))
      .map((entry) => entry.name);
  } catch {
    return [];
  }
  const heads: Array<StoreMarker & { generation: number }> = [];
  for (const name of names) {
    try {
      const value = JSON.parse(fs.readFileSync(path.join(headsRoot, name), "utf8")) as unknown;
      if (!isRecord(value)
          || !schemaMatches(value.schema, STORE_HEAD_SCHEMA)
          || !safeManifestName(value.currentManifest)
          || !isDigest(value.currentDigest)
          || !Number.isSafeInteger(value.currentGeneration)) {
        continue;
      }
      heads.push({
        currentManifest: value.currentManifest,
        currentDigest: value.currentDigest,
        previousManifest: typeof value.previousManifest === "string" && safeManifestName(value.previousManifest)
          ? value.previousManifest
          : null,
        previousDigest: typeof value.previousDigest === "string" && isDigest(value.previousDigest)
          ? value.previousDigest
          : null,
        generation: value.currentGeneration as number,
      });
    } catch {
      // A partially synchronized or corrupt head is ignored; others remain valid.
    }
  }
  return heads.sort((left, right) => right.generation - left.generation);
}

function parseManifestV2Data(
  data: Buffer,
  file: string,
  expectedDigest?: string | null,
): ParsedManifest | null {
  try {
    if (expectedDigest && digest(data) !== expectedDigest) return null;
    const payload = JSON.parse(data.toString("utf8")) as unknown;
    if (!isRecord(payload)
        || !schemaMatches(payload.schema, MANIFEST_V2_SCHEMA)
        || payload.version !== 2
        || !Number.isSafeInteger(payload.generation)
        || (payload.generation as number) < 0
        || typeof payload.commitID !== "string"
        || !safeManifestName(payload.commitID)
        || !Array.isArray(payload.threads)) {
      return null;
    }
    const entries: ManifestThreadEntry[] = [];
    for (const value of payload.threads) {
      if (!isRecord(value)
          || typeof value.shard !== "string"
          || typeof value.shardDigest !== "string") {
        return null;
      }
      const metadata = normalizedThread(value.metadata);
      if (!metadata) return null;
      entries.push({ metadata, shard: value.shard, shardDigest: value.shardDigest });
    }
    const threadIDs = new Set(entries.map((entry) => entry.metadata.id.toLowerCase()));
    if (threadIDs.size !== entries.length) return null;
    const selectedThreadID = typeof payload.selectedThreadID === "string"
      ? payload.selectedThreadID
      : null;
    if (selectedThreadID && !threadIDs.has(selectedThreadID.toLowerCase())) return null;
    return {
      file,
      layout: "sharded-v2",
      threads: entries.map((entry) => entry.metadata),
      entries,
      selectedThreadID,
      settlementSettings: settlementSettings(payload),
      commitID: payload.commitID,
      generation: payload.generation as number,
      subsumedCommitIDs: [payload.ancestorCommitIDs, payload.mergedCommitIDs]
        .flatMap((value) => (Array.isArray(value) ? value : []))
        .filter((value): value is string => typeof value === "string"),
    };
  } catch {
    return null;
  }
}

function loadManifestV2(file: string, expectedDigest?: string | null): ParsedManifest | null {
  try {
    return parseManifestV2Data(fs.readFileSync(file), file, expectedDigest);
  } catch {
    return null;
  }
}

function loadManifestV1(file: string): ParsedManifest | null {
  try {
    const payload = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
    if (!isRecord(payload) || !schemaMatches(payload.schema, MANIFEST_V1_SCHEMA) || !Array.isArray(payload.threads)) {
      return null;
    }
    const threads: OpenClawChatThreadRecord[] = [];
    const entries: ManifestThreadEntry[] = [];
    for (const value of payload.threads) {
      const metadata = normalizedThread(value);
      if (!metadata) return null;
      threads.push(metadata);
      entries.push({
        metadata,
        shard: `threads/${metadata.id.toLowerCase()}.json`,
        shardDigest: "",
      });
    }
    return {
      file,
      layout: "sharded-v1",
      threads,
      entries,
      selectedThreadID: typeof payload.selectedThreadID === "string" ? payload.selectedThreadID : null,
      settlementSettings: settlementSettings(payload),
      commitID: null,
      generation: null,
    };
  } catch {
    return null;
  }
}

function manifestNamed(
  storeRoot: string,
  name: string,
  expectedDigest: string | null,
): ParsedManifest | null {
  if (!safeManifestName(name)) return null;
  return loadManifestV2(path.join(storeRoot, "manifests", name), expectedDigest);
}

/**
 * Shards already verified by this process, keyed by path and expected digest.
 * Long-lived readers (activity event streams and waits) reload the store
 * whenever it changes; a shard whose inode, size, and modification time are
 * unchanged since it last hashed to the same digest does not need rehashing.
 */
const verifiedShardCache = new Map<string, { ino: number; size: number; mtimeMs: number }>();
const VERIFIED_SHARD_CACHE_LIMIT = 20_000;

function validManifestEntry(storeRoot: string, entry: ManifestThreadEntry): boolean {
  try {
    if (!isDigest(entry.shardDigest)
        || entry.shard !== `threads/${path.basename(entry.shard)}`) {
      return false;
    }
    const shardFile = confinedShardPath(storeRoot, entry.shard);
    const cacheKey = `${shardFile}\0${entry.shardDigest}`;
    const stat = fs.statSync(shardFile);
    const cached = verifiedShardCache.get(cacheKey);
    if (cached && cached.ino === stat.ino && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
      return true;
    }
    const data = fs.readFileSync(shardFile);
    if (digest(data) !== entry.shardDigest) return false;
    const shard = JSON.parse(data.toString("utf8")) as unknown;
    if (!isRecord(shard)
        || !schemaMatches(shard.schema, THREAD_SHARD_SCHEMA)
        || shard.version !== 1
        || !Array.isArray(shard.messages)) {
      return false;
    }
    for (const stored of shard.messages) {
      if (!isRecord(stored) || !isRecord(stored.message) || !Array.isArray(stored.attachments)) {
        return false;
      }
    }
    if (verifiedShardCache.size >= VERIFIED_SHARD_CACHE_LIMIT) verifiedShardCache.clear();
    verifiedShardCache.set(cacheKey, { ino: stat.ino, size: stat.size, mtimeMs: stat.mtimeMs });
    return true;
  } catch {
    return false;
  }
}

function isCompleteManifest(storeRoot: string, manifest: ParsedManifest): boolean {
  return manifest.layout === "sharded-v2"
    && manifest.entries.every((entry) => validManifestEntry(storeRoot, entry));
}

function recoveryManifestCandidates(storeRoot: string): ParsedManifest[] {
  const files: string[] = [];
  const manifestsRoot = path.join(storeRoot, "manifests");
  try {
    files.push(...fs.readdirSync(manifestsRoot, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .map((entry) => path.join(manifestsRoot, entry.name)));
  } catch {
    // A missing immutable directory is handled by the fail-closed path below.
  }
  try {
    files.push(...fs.readdirSync(storeRoot, { withFileTypes: true })
      .filter((entry) => (
        entry.isFile() && entry.name.startsWith("manifest") && entry.name.endsWith(".json")
      ))
      .map((entry) => path.join(storeRoot, entry.name)));
  } catch {
    // A missing store root means there are no recovery candidates.
  }
  return files.map((file) => loadManifestV2(file)).filter(
    (manifest): manifest is ParsedManifest => manifest !== null,
  );
}

function updatedAtValue(thread: OpenClawChatThreadRecord): number {
  if (typeof thread.updatedAt === "number") return thread.updatedAt;
  const parsed = Date.parse(thread.updatedAt);
  return Number.isFinite(parsed) ? parsed : Number.NEGATIVE_INFINITY;
}

function prefersRecoveryEntry(
  candidate: { entry: ManifestThreadEntry; generation: number },
  existing: { entry: ManifestThreadEntry; generation: number },
): boolean {
  const candidateUpdatedAt = updatedAtValue(candidate.entry.metadata);
  const existingUpdatedAt = updatedAtValue(existing.entry.metadata);
  if (candidateUpdatedAt !== existingUpdatedAt) return candidateUpdatedAt > existingUpdatedAt;
  const candidateCount = candidate.entry.metadata.storedMessageCount ?? -1;
  const existingCount = existing.entry.metadata.storedMessageCount ?? -1;
  if (candidateCount !== existingCount) return candidateCount > existingCount;
  if (candidate.generation !== existing.generation) return candidate.generation > existing.generation;
  return candidate.entry.shardDigest > existing.entry.shardDigest;
}

function reconcileRecoveryManifest(
  storeRoot: string,
  candidates: ParsedManifest[],
): ParsedManifest | null {
  const unique = new Map<string, ParsedManifest>();
  for (const candidate of candidates) {
    if (!candidate.commitID) continue;
    const existing = unique.get(candidate.commitID);
    if (!existing || (candidate.generation ?? 0) > (existing.generation ?? 0)) {
      unique.set(candidate.commitID, candidate);
    }
  }
  const sorted = [...unique.values()].sort(
    (left, right) => (right.generation ?? 0) - (left.generation ?? 0),
  );
  const completeBase = sorted.find((candidate) => isCompleteManifest(storeRoot, candidate));
  if (!completeBase) return null;
  if (sorted.length === 1) return completeBase;

  const selectedEntries = new Map<
    string,
    { entry: ManifestThreadEntry; generation: number }
  >();
  for (const candidate of sorted) {
    for (const entry of candidate.entries) {
      if (!validManifestEntry(storeRoot, entry)) continue;
      const key = entry.metadata.id.toLowerCase();
      const selected = { entry, generation: candidate.generation ?? 0 };
      const existing = selectedEntries.get(key);
      if (!existing || prefersRecoveryEntry(selected, existing)) selectedEntries.set(key, selected);
    }
  }
  const baseIDs = completeBase.entries.map((entry) => entry.metadata.id.toLowerCase());
  const baseIDSet = new Set(baseIDs);
  const additionalIDs = [...selectedEntries.keys()]
    .filter((id) => !baseIDSet.has(id))
    .sort((left, right) => (
      updatedAtValue(selectedEntries.get(right)!.entry.metadata)
        - updatedAtValue(selectedEntries.get(left)!.entry.metadata)
        || left.localeCompare(right)
    ));
  const entries = [...baseIDs, ...additionalIDs]
    .map((id) => selectedEntries.get(id)?.entry)
    .filter((entry): entry is ManifestThreadEntry => entry !== undefined);
  const context = sorted[0] ?? completeBase;
  const entryIDs = new Set(entries.map((entry) => entry.metadata.id.toLowerCase()));
  const selectedThreadID = [context.selectedThreadID, completeBase.selectedThreadID]
    .find((id): id is string => Boolean(id && entryIDs.has(id.toLowerCase())))
    ?? entries[0]?.metadata.id
    ?? null;
  const generation = Math.max(...sorted.map((candidate) => candidate.generation ?? 0)) + 1;
  return {
    file: completeBase.file,
    layout: "sharded-v2",
    threads: entries.map((entry) => entry.metadata),
    entries,
    selectedThreadID,
    settlementSettings: context.settlementSettings,
    commitID: `recovered-${completeBase.commitID}`,
    generation,
  };
}

function resolveShardedManifest(storeRoot: string): {
  manifest: ParsedManifest;
  recoveryStatus: OpenClawThreadRecoveryStatus;
} | null {
  const markerFile = path.join(storeRoot, "migration-marker.json");
  const previousMarkerFile = path.join(storeRoot, "migration-marker.previous.json");
  const currentView = path.join(storeRoot, "manifest.json");
  const previousView = path.join(storeRoot, "manifest.previous.json");
  const heads = parseHeads(storeRoot);
  const markerExists = fs.existsSync(markerFile) || fs.existsSync(previousMarkerFile) || heads.length > 0;
  const candidates: ParsedManifest[] = [];

  if (heads.length > 0) {
    const tips: ParsedManifest[] = [];
    for (const head of heads) {
      const current = manifestNamed(storeRoot, head.currentManifest, head.currentDigest);
      if (current && isCompleteManifest(storeRoot, current)) {
        tips.push(current);
        continue;
      }
      if (current) candidates.push(current);
      if (head.previousManifest) {
        const previous = manifestNamed(storeRoot, head.previousManifest, head.previousDigest);
        if (previous) candidates.push(previous);
      }
    }
    if (tips.length > 0) {
      const subsumed = new Set(tips.flatMap((tip) => tip.subsumedCommitIDs ?? []));
      const live = tips.filter((tip) => !tip.commitID || !subsumed.has(tip.commitID));
      if (live.length === 1) return { manifest: live[0]!, recoveryStatus: "healthy" };
      const merged = reconcileRecoveryManifest(storeRoot, live);
      if (merged) return { manifest: merged, recoveryStatus: "healthy" };
    }
  }

  const marker = heads.length > 0 ? null : parseMarker(markerFile);
  if (marker) {
    const current = manifestNamed(storeRoot, marker.currentManifest, marker.currentDigest);
    if (current && isCompleteManifest(storeRoot, current)) {
      return { manifest: current, recoveryStatus: "healthy" };
    }
    if (current) candidates.push(current);
    if (marker.previousManifest) {
      const previous = manifestNamed(storeRoot, marker.previousManifest, marker.previousDigest);
      if (previous) candidates.push(previous);
    }
  }

  const previousMarker = parseMarker(previousMarkerFile);
  if (previousMarker) {
    const current = manifestNamed(
      storeRoot,
      previousMarker.currentManifest,
      previousMarker.currentDigest,
    );
    if (current) candidates.push(current);
    if (previousMarker.previousManifest) {
      const previous = manifestNamed(
        storeRoot,
        previousMarker.previousManifest,
        previousMarker.previousDigest,
      );
      if (previous) candidates.push(previous);
    }
  }

  if (markerExists) {
    candidates.push(...recoveryManifestCandidates(storeRoot));
    const recovered = reconcileRecoveryManifest(storeRoot, candidates);
    if (recovered) {
      return { manifest: recovered, recoveryStatus: "recovered-previous-manifest" };
    }
    throw new Error(
      "AI chat storage metadata is corrupt. The stale legacy transcript was not loaded and writes are disabled.",
    );
  }

  const v2 = loadManifestV2(currentView);
  if (v2 && isCompleteManifest(storeRoot, v2)) {
    return { manifest: v2, recoveryStatus: "healthy" };
  }
  const v1 = loadManifestV1(currentView);
  if (v1) return { manifest: v1, recoveryStatus: "healthy" };
  if (fs.existsSync(currentView) || fs.existsSync(previousView)) {
    throw new Error("AI chat storage exists but no valid manifest can be recovered. Writes are disabled.");
  }
  return null;
}

function stateFromManifest(
  corpusRoot: string,
  manifest: ParsedManifest,
  recoveryStatus: OpenClawThreadRecoveryStatus,
  layout: OpenClawThreadStorageLayout = manifest.layout,
): ResolvedTranscript {
  const legacyFile = openClawTranscriptPath(corpusRoot);
  return {
    state: {
      schema: OPENCLAW_THREAD_STATE_SCHEMA,
      file: manifest.file,
      legacyFile,
      version: OPENCLAW_TRANSCRIPT_VERSION,
      selectedThreadID: manifest.selectedThreadID,
      settlementSettings: manifest.settlementSettings,
      threads: manifest.threads,
      storageLayout: layout,
      recoveryStatus,
      commitID: manifest.commitID,
      generation: manifest.generation,
      pendingOperationCount: 0,
    },
    entries: new Map(manifest.entries.map((entry) => [entry.metadata.id.toLowerCase(), entry])),
    storeRoot: openClawTranscriptStorePath(corpusRoot),
  };
}

function emptyOrLegacyState(corpusRoot: string): ResolvedTranscript {
  const file = openClawTranscriptPath(corpusRoot);
  if (!fs.existsSync(file)) {
    return {
      state: {
        schema: OPENCLAW_THREAD_STATE_SCHEMA,
        file,
        legacyFile: file,
        version: OPENCLAW_TRANSCRIPT_VERSION,
        selectedThreadID: null,
        settlementSettings: { autoSettleAfterSeconds: null },
        threads: [],
        storageLayout: "empty",
        recoveryStatus: "healthy",
        commitID: null,
        generation: null,
        pendingOperationCount: 0,
      },
      entries: new Map(),
      storeRoot: null,
    };
  }
  const data = fs.readFileSync(file);
  const parsed = JSON.parse(data.toString("utf8")) as unknown;
  if (!isRecord(parsed)) throw new Error(`invalid OpenClaw transcript payload: ${file}`);
  if (schemaMatches(parsed.schema, MANIFEST_V2_SCHEMA)) {
    const pointer = parseManifestV2Data(data, file);
    if (!pointer) throw new Error(`invalid OpenClaw transcript compatibility pointer: ${file}`);
    return stateFromManifest(corpusRoot, pointer, "healthy", "sharded-v2-pointer");
  }
  const numericVersion = typeof parsed.version === "number" && Number.isFinite(parsed.version)
    ? parsed.version
    : 1;
  return {
    state: {
      schema: OPENCLAW_THREAD_STATE_SCHEMA,
      file,
      legacyFile: file,
      version: numericVersion,
      selectedThreadID: typeof parsed.selectedThreadID === "string" ? parsed.selectedThreadID : null,
      settlementSettings: settlementSettings(parsed),
      threads: normalizedLegacyThreads(parsed),
      storageLayout: "legacy-monolith",
      recoveryStatus: "healthy",
      commitID: null,
      generation: null,
      pendingOperationCount: 0,
    },
    entries: new Map(),
    storeRoot: null,
  };
}

function resolveAuthoritativeTranscript(corpusRoot: string): ResolvedTranscript {
  const storeRoot = openClawTranscriptStorePath(corpusRoot);
  const sharded = resolveShardedManifest(storeRoot);
  return sharded
    ? stateFromManifest(corpusRoot, sharded.manifest, sharded.recoveryStatus)
    : emptyOrLegacyState(corpusRoot);
}

function confinedShardPath(storeRoot: string, relativeShard: string): string {
  const threadsRoot = path.resolve(storeRoot, "threads");
  const shard = path.resolve(storeRoot, relativeShard);
  if (!shard.startsWith(`${threadsRoot}${path.sep}`)) {
    throw new Error(`invalid AI chat thread shard path: ${relativeShard}`);
  }
  const resolvedRoot = fs.realpathSync(threadsRoot);
  const resolvedShard = fs.realpathSync(shard);
  if (!resolvedShard.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`unsafe AI chat thread shard path: ${relativeShard}`);
  }
  return resolvedShard;
}

function hydrateThread(
  state: OpenClawThreadState,
  entries: Map<string, ManifestThreadEntry>,
  storeRoot: string,
  requestedThreadID: string,
  projectMessage?: LoadOpenClawThreadStateOptions["projectMessage"],
): OpenClawThreadState {
  const canonicalID = requestedThreadID.toLowerCase();
  const entry = entries.get(canonicalID);
  if (!entry) return state;
  const shardFile = confinedShardPath(storeRoot, entry.shard);
  const data = fs.readFileSync(shardFile);
  if (entry.shardDigest && (!isDigest(entry.shardDigest) || digest(data) !== entry.shardDigest)) {
    throw new Error(`AI chat thread shard digest mismatch: ${shardFile}`);
  }
  const shard = JSON.parse(data.toString("utf8")) as unknown;
  if (!isRecord(shard) || !schemaMatches(shard.schema, THREAD_SHARD_SCHEMA) || !Array.isArray(shard.messages)) {
    throw new Error(`invalid AI chat thread shard: ${shardFile}`);
  }
  const messages = shard.messages.map((stored, index): OpenClawChatMessageRecord => {
    if (!isRecord(stored) || !isRecord(stored.message) || !Array.isArray(stored.attachments)) {
      throw new Error(`invalid AI chat stored message ${index}: ${shardFile}`);
    }
    const message = {
      ...stored.message,
      attachments: stored.attachments,
    } as OpenClawChatMessageRecord;
    return projectMessage ? projectMessage(message) : message;
  });
  return {
    ...state,
    threads: state.threads.map((thread) => (
      thread.id.toLowerCase() === canonicalID ? { ...thread, messages } : thread
    )),
  };
}

function copyState(state: OpenClawThreadState): OpenClawThreadState {
  return {
    ...state,
    settlementSettings: { ...state.settlementSettings },
    threads: state.threads.map((thread) => ({
      ...thread,
      messages: thread.messages ? [...thread.messages] : thread.messages,
    })),
  };
}

function matchingThreadIndex(threads: OpenClawChatThreadRecord[], threadID: string): number {
  const canonicalID = threadID.trim().toLowerCase();
  return threads.findIndex((thread) => thread.id.toLowerCase() === canonicalID);
}

function applyOperation(state: OpenClawThreadState, operation: AIChatOperation): string[] {
  if (operation.kind === "settle-thread") {
    const index = matchingThreadIndex(state.threads, operation.threadID);
    if (index < 0 || isOpenClawThreadSettled(state.threads[index]!)) return [];
    state.threads[index] = settledThread(state.threads[index]!, new Date(operation.settledAt));
    return [state.threads[index]!.id];
  }
  if (operation.kind === "reopen-thread") {
    const index = matchingThreadIndex(state.threads, operation.threadID);
    if (index < 0 || !isOpenClawThreadSettled(state.threads[index]!)) return [];
    state.threads[index] = reopenedThread(state.threads[index]!);
    return [state.threads[index]!.id];
  }
  if (operation.kind === "configure-room-agent-turns") {
    const index = matchingThreadIndex(state.threads, operation.threadID);
    if (index < 0 || roomAgentTurnLimitSetting(state.threads[index]!) === operation.agentTurnLimit) return [];
    const thread = { ...state.threads[index]! };
    if (operation.agentTurnLimit === null) delete thread.roomAgentTurnLimit;
    else thread.roomAgentTurnLimit = operation.agentTurnLimit;
    state.threads[index] = thread;
    return [thread.id];
  }
  if (operation.kind === "configure-auto-settle") {
    if (state.settlementSettings.autoSettleAfterSeconds === operation.autoSettleAfterSeconds) return [];
    state.settlementSettings = { autoSettleAfterSeconds: operation.autoSettleAfterSeconds };
    return ["settings"];
  }
  const now = new Date(operation.evaluatedAt);
  const affected: string[] = [];
  state.threads = state.threads.map((thread) => {
    if (!canAutoSettleOpenClawThread(
      thread,
      state.settlementSettings,
      now,
      state.selectedThreadID,
    )) return thread;
    affected.push(thread.id);
    return settledThread(thread, now);
  });
  return affected;
}

function stateIncludingPendingOperations(
  corpusRoot: string,
  state: OpenClawThreadState,
): OpenClawThreadState {
  const operations = loadAIChatOperations(corpusRoot);
  if (operations.length === 0) return state;
  const effective = copyState(state);
  for (const operation of operations) applyOperation(effective, operation);
  effective.pendingOperationCount = operations.length;
  return effective;
}

export function loadOpenClawThreadState(
  corpusRoot: string,
  options: LoadOpenClawThreadStateOptions = {},
): OpenClawThreadState {
  const resolved = resolveAuthoritativeTranscript(corpusRoot);
  let hydrated = options.hydrateThreadID && resolved.storeRoot
    ? hydrateThread(
      resolved.state,
      resolved.entries,
      resolved.storeRoot,
      options.hydrateThreadID,
      options.projectMessage,
    )
    : resolved.state;
  if (options.hydrateUpdatedSince !== undefined && resolved.storeRoot) {
    for (const thread of resolved.state.threads) {
      const at = openClawDateMilliseconds(thread.updatedAt);
      if (!Number.isFinite(at) || at >= options.hydrateUpdatedSince) {
        hydrated = hydrateThread(hydrated, resolved.entries, resolved.storeRoot, thread.id, options.projectMessage);
      }
    }
  }
  return options.includePendingOperations === false
    ? hydrated
    : stateIncludingPendingOperations(corpusRoot, hydrated);
}

export function findOpenClawThread(
  state: OpenClawThreadState,
  threadID: string,
): OpenClawChatThreadRecord | undefined {
  const index = matchingThreadIndex(state.threads, threadID);
  return index < 0 ? undefined : state.threads[index];
}

export function isOpenClawThreadSettled(thread: OpenClawChatThreadRecord): boolean {
  return thread.settledAt !== undefined && thread.settledAt !== null
    ? true
    : thread.isArchived === true;
}

export function openClawDateMilliseconds(value: number | string): number {
  if (typeof value === "number") {
    return (value + APPLE_REFERENCE_DATE_UNIX_SECONDS) * 1000;
  }
  return Date.parse(value);
}

export function appleReferenceDateSeconds(date: Date): number {
  return date.getTime() / 1000 - APPLE_REFERENCE_DATE_UNIX_SECONDS;
}

export function canAutoSettleOpenClawThread(
  thread: OpenClawChatThreadRecord,
  settings: OpenClawThreadSettlementSettings,
  now = new Date(),
  selectedThreadID: string | null = null,
): boolean {
  const interval = settings.autoSettleAfterSeconds;
  if (!interval || interval <= 0 || isOpenClawThreadSettled(thread)) return false;
  if (thread.id.toLowerCase() === selectedThreadID?.toLowerCase()
      || thread.isPinned
      || thread.pendingTurn) return false;
  if ((thread.unreadMessageCount || 0) > 0) return false;
  if (thread.storedHasUnresolvedLatestDelivery === true
      || thread.storedLatestDeliveryNeedsAttention === true) return false;
  const latestMessage = thread.messages?.[thread.messages.length - 1];
  if (
    latestMessage?.deliveryStatus === "sending"
    || latestMessage?.deliveryStatus === "failed"
    || latestMessage?.deliveryStatus === "interrupted"
    || Boolean(latestMessage?.sendFailure)
  ) return false;
  const updatedAt = openClawDateMilliseconds(thread.updatedAt);
  return Number.isFinite(updatedAt) && updatedAt <= now.getTime() - interval * 1000;
}

function settledThread(thread: OpenClawChatThreadRecord, at: Date): OpenClawChatThreadRecord {
  return {
    ...thread,
    isArchived: true,
    settledAt: appleReferenceDateSeconds(at),
  };
}

function reopenedThread(thread: OpenClawChatThreadRecord): OpenClawChatThreadRecord {
  return {
    ...thread,
    isArchived: false,
    settledAt: null,
  };
}

function mutationResult(
  corpusRoot: string,
  state: OpenClawThreadState,
  operation: AIChatOperation,
  affectedThreadIds: string[],
  apply: boolean,
): OpenClawThreadMutationResult {
  const queued = queueAIChatOperation(corpusRoot, operation, apply);
  const nextState = copyState(state);
  applyOperation(nextState, operation);
  if (queued.applied) nextState.pendingOperationCount += 1;
  return {
    applied: queued.applied,
    queued: queued.applied,
    committed: false,
    changed: true,
    state: nextState,
    affectedThreadIds,
    operationFiles: [queued.file],
    operation: queued.operation,
  };
}

function unchangedMutationResult(state: OpenClawThreadState): OpenClawThreadMutationResult {
  return {
    applied: false,
    queued: false,
    committed: false,
    changed: false,
    state,
    affectedThreadIds: [],
    operationFiles: [],
  };
}

export function settleOpenClawThread(
  corpusRoot: string,
  threadID: string,
  options: { apply?: boolean; now?: Date } = {},
): OpenClawThreadMutationResult {
  const state = loadOpenClawThreadState(corpusRoot);
  const thread = findOpenClawThread(state, threadID);
  if (!thread) throw new Error(`unknown OpenClaw thread: ${threadID}`);
  if (isOpenClawThreadSettled(thread)) return unchangedMutationResult(state);
  const at = options.now || new Date();
  if (!Number.isFinite(at.getTime())) throw new Error("OpenClaw settlement time must be valid");
  const operation: AIChatOperation = {
    schema: AI_CHAT_OPERATION_SCHEMA,
    ...nextAIChatOperationIdentity(),
    kind: "settle-thread",
    threadID: thread.id,
    settledAt: at.toISOString(),
  };
  return mutationResult(corpusRoot, state, operation, [thread.id], options.apply === true);
}

export function reopenOpenClawThread(
  corpusRoot: string,
  threadID: string,
  options: { apply?: boolean } = {},
): OpenClawThreadMutationResult {
  const state = loadOpenClawThreadState(corpusRoot);
  const thread = findOpenClawThread(state, threadID);
  if (!thread) throw new Error(`unknown OpenClaw thread: ${threadID}`);
  if (!isOpenClawThreadSettled(thread)) return unchangedMutationResult(state);
  const operation: AIChatOperation = {
    schema: AI_CHAT_OPERATION_SCHEMA,
    ...nextAIChatOperationIdentity(),
    kind: "reopen-thread",
    threadID: thread.id,
  };
  return mutationResult(corpusRoot, state, operation, [thread.id], options.apply === true);
}

export function configureOpenClawThreadSettlement(
  corpusRoot: string,
  autoSettleAfterSeconds: number | null,
  options: { apply?: boolean } = {},
): OpenClawThreadMutationResult {
  if (autoSettleAfterSeconds !== null
      && (!Number.isFinite(autoSettleAfterSeconds) || autoSettleAfterSeconds <= 0)) {
    throw new Error("auto-settle interval must be a positive number of seconds or null");
  }
  const state = loadOpenClawThreadState(corpusRoot);
  if (state.settlementSettings.autoSettleAfterSeconds === autoSettleAfterSeconds) {
    return unchangedMutationResult(state);
  }
  const operation: AIChatOperation = {
    schema: AI_CHAT_OPERATION_SCHEMA,
    ...nextAIChatOperationIdentity(),
    kind: "configure-auto-settle",
    autoSettleAfterSeconds,
  };
  return mutationResult(corpusRoot, state, operation, ["settings"], options.apply === true);
}

/** The room's stored agent-turn limit, or null when it follows the default. */
export function roomAgentTurnLimitSetting(thread: OpenClawChatThreadRecord): number | null {
  const value = thread.roomAgentTurnLimit;
  return typeof value === "number" && isValidRoomAgentTurnLimit(value) ? value : null;
}

/**
 * Sets how many agent-requested turns may run back to back in one shared room
 * before a person must reply. `0` turns agent hand-offs off; `null` restores
 * the default of AI_CHAT_DEFAULT_ROOM_AGENT_TURN_LIMIT.
 */
export function configureOpenClawRoomAgentTurnLimit(
  corpusRoot: string,
  threadID: string,
  agentTurnLimit: number | null,
  options: { apply?: boolean } = {},
): OpenClawThreadMutationResult {
  if (!isValidRoomAgentTurnLimit(agentTurnLimit)) {
    throw new Error(`agent turn limit must be an integer from 0 to ${AI_CHAT_MAX_ROOM_AGENT_TURN_LIMIT}, or default`);
  }
  const state = loadOpenClawThreadState(corpusRoot);
  const thread = findOpenClawThread(state, threadID);
  if (!thread) throw new Error(`unknown OpenClaw thread: ${threadID}`);
  if (thread.isSharedRoom !== true) {
    throw new Error("agent turn limits apply to shared AI rooms; this thread has a single agent");
  }
  if (roomAgentTurnLimitSetting(thread) === agentTurnLimit) return unchangedMutationResult(state);
  const operation: AIChatOperation = {
    schema: AI_CHAT_OPERATION_SCHEMA,
    ...nextAIChatOperationIdentity(),
    kind: "configure-room-agent-turns",
    threadID: thread.id,
    agentTurnLimit,
  };
  return mutationResult(corpusRoot, state, operation, [thread.id], options.apply === true);
}

export function autoSettleOpenClawThreads(
  corpusRoot: string,
  options: { apply?: boolean; now?: Date } = {},
): OpenClawThreadMutationResult {
  const state = loadOpenClawThreadState(corpusRoot);
  const now = options.now || new Date();
  if (!Number.isFinite(now.getTime())) throw new Error("OpenClaw auto-settlement time must be valid");
  const affectedThreadIds = state.threads
    .filter((thread) => canAutoSettleOpenClawThread(
      thread,
      state.settlementSettings,
      now,
      state.selectedThreadID,
    ))
    .map((thread) => thread.id);
  if (affectedThreadIds.length === 0) return unchangedMutationResult(state);
  const operation: AIChatOperation = {
    schema: AI_CHAT_OPERATION_SCHEMA,
    ...nextAIChatOperationIdentity(),
    kind: "auto-settle",
    evaluatedAt: now.toISOString(),
  };
  return mutationResult(
    corpusRoot,
    state,
    operation,
    affectedThreadIds,
    options.apply === true,
  );
}
