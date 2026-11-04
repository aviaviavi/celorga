import fs from "node:fs";
import path from "node:path";
import { findConfigFile } from "./config.js";
import { loadOpenClawThreadState, openClawDateMilliseconds } from "./openClawThreadState.js";
import { loadActivityHosts, isHostLive } from "./activityState.js";

export const CELORGA_DATASET_SCHEMAS = {
  "chat-threads": { thread_id: "VARCHAR", title: "VARCHAR", updated_at: "VARCHAR", destination_id: "VARCHAR", runtime: "VARCHAR", is_shared_room: "BOOLEAN", is_archived: "BOOLEAN", settled_at: "VARCHAR", room_destination_ids: "VARCHAR", room_default_destination_id: "VARCHAR" },
  "chat-messages": { thread_id: "VARCHAR", message_id: "VARCHAR", ordinal: "BIGINT", created_at: "VARCHAR", role: "VARCHAR", content: "VARCHAR", delivery_status: "VARCHAR", send_failure: "VARCHAR", delivery_kind: "VARCHAR", delivery_attempt_state: "VARCHAR", target_destination_id: "VARCHAR", author_destination_id: "VARCHAR", room_round_id: "VARCHAR", is_dispatch_copy: "BOOLEAN", author_label: "VARCHAR", author_agent_ref: "VARCHAR", source: "VARCHAR", requested_by_destination_id: "VARCHAR", audience_destination_ids: "VARCHAR", attachment_count: "BIGINT" },
  "chat-turns": { thread_id: "VARCHAR", message_id: "VARCHAR", destination_id: "VARCHAR", destination_name: "VARCHAR", started_at: "VARCHAR", host_ref: "VARCHAR" },
} as const;
export type CelorgaDatasetSource = keyof typeof CELORGA_DATASET_SCHEMAS;
export interface CelorgaDatasetSpec { source: CelorgaDatasetSource; sinceDays: number }
export interface CelorgaDatasetTable { columns: Record<string, string>; rows: Record<string, unknown>[] }

const text = (value: unknown): string | null => typeof value === "string" && value.trim() ? value.trim() : null;
const identifier = (value: unknown): string | null => text(value)?.toLowerCase() ?? null;
const record = (value: unknown): Record<string, unknown> => value && typeof value === "object" ? value as Record<string, unknown> : {};
const array = (value: unknown): unknown[] => Array.isArray(value) ? value : [];
const messageFields = ["id", "role", "content", "createdAt", "deliveryStatus", "sendFailure", "deliveryKind", "deliveryAttemptState", "targetDestinationID", "authorDestinationID", "roomRoundID", "isRoomDispatchCopy", "authorLabel", "authorAgentRef", "source", "provenance", "audienceDestinationIDs"];
function date(value: unknown): string | null {
  const ms = typeof value === "number" || typeof value === "string" ? openClawDateMilliseconds(value) : Number.NaN;
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

export function parseCelorgaDataset(source: string, since: string = "7d"): CelorgaDatasetSpec {
  if (!Object.hasOwn(CELORGA_DATASET_SCHEMAS, source)) throw new Error("Celorga dataset source must be chat-threads, chat-messages, or chat-turns");
  const match = /^(\d+)d$/.exec(since);
  const sinceDays = Number(match?.[1]);
  if (!match || sinceDays < 1 || sinceDays > 3650) throw new Error("Celorga dataset since must be 1d to 3650d (default 7d)");
  return { source: source as CelorgaDatasetSource, sinceDays };
}

/** A single canonical snapshot is shared by all local relations in one query. */
export function createCelorgaDatasetLoader(file: string | undefined, specs: readonly CelorgaDatasetSpec[], now = new Date()) {
  const sourcePath = path.resolve(file ?? path.join(process.cwd(), "stdin.org"));
  const config = findConfigFile(path.dirname(sourcePath));
  if (!config) throw new Error("Celorga datasets require a report inside a configured corpus");
  const root = fs.realpathSync(path.dirname(config));
  const source = fs.existsSync(sourcePath) ? fs.realpathSync(sourcePath) : sourcePath;
  const relative = path.relative(root, source);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error("Celorga dataset report is outside its corpus");
  const widestDays = Math.max(...specs.map(spec => spec.sinceDays));
  const state = specs.some(spec => spec.source !== "chat-turns") ? loadOpenClawThreadState(root, {
    ...(specs.some(spec => spec.source === "chat-messages") ? { hydrateUpdatedSince: now.getTime() - widestDays * 86_400_000 } : {}),
    projectMessage: message => ({ ...Object.fromEntries(messageFields.map(field => [field, message[field]])), attachments: array(message.attachments).map(() => null) }),
  }) : undefined;
  if (state && state.recoveryStatus !== "healthy") throw new Error("Chat storage recovered an older snapshot; reconcile the transcript before refreshing this report");
  const turns = specs.some(spec => spec.source === "chat-turns")
    ? loadActivityHosts(root, now).filter(isHostLive).flatMap(host => host.turns.map(turn => ({ host, turn }))) : [];
  return (spec: CelorgaDatasetSpec): CelorgaDatasetTable => {
    const cutoff = now.getTime() - spec.sinceDays * 86_400_000;
    const rows: Record<string, unknown>[] = [];
    if (spec.source === "chat-turns") {
      for (const { host, turn } of turns) rows.push({ thread_id: identifier(turn.threadID), message_id: identifier(turn.userMessageID), destination_id: identifier(turn.destinationID), destination_name: text(turn.destinationName), started_at: date(turn.startedAt), host_ref: host.hostRef });
    } else for (const thread of state?.threads ?? []) {
      const updatedAt = openClawDateMilliseconds(thread.updatedAt);
      if (Number.isFinite(updatedAt) && updatedAt < cutoff) continue;
      if (spec.source === "chat-threads") {
        rows.push({ thread_id: identifier(thread.id), title: text(thread.title) ?? "Untitled chat", updated_at: date(thread.updatedAt), destination_id: identifier(thread.destinationID), runtime: text(thread.runtime), is_shared_room: thread.isSharedRoom === true, is_archived: thread.isArchived === true, settled_at: date(thread.settledAt), room_destination_ids: JSON.stringify(array(thread.roomDestinationIDs).map(identifier)), room_default_destination_id: typeof thread.roomDefaultDestinationID === "string" ? thread.roomDefaultDestinationID.toLowerCase() : null });
      } else (thread.messages ?? []).forEach((message, index) => {
        const createdAt = date(message.createdAt);
        if (createdAt && Date.parse(createdAt) < cutoff) return;
        rows.push({ thread_id: identifier(thread.id), message_id: identifier(message.id), ordinal: index + 1, created_at: createdAt, role: text(message.role), content: typeof message.content === "string" ? message.content : "", delivery_status: text(message.deliveryStatus) ?? "sent", send_failure: text(message.sendFailure), delivery_kind: text(message.deliveryKind) ?? "turn", delivery_attempt_state: text(message.deliveryAttemptState), target_destination_id: identifier(message.targetDestinationID), author_destination_id: identifier(message.authorDestinationID), room_round_id: identifier(message.roomRoundID), is_dispatch_copy: message.isRoomDispatchCopy === true, author_label: text(message.authorLabel), author_agent_ref: text(message.authorAgentRef), source: text(message.source), requested_by_destination_id: identifier(record(message.provenance).requestedByDestinationID), audience_destination_ids: JSON.stringify(array(message.audienceDestinationIDs).map(identifier)), attachment_count: array(message.attachments).length });
      });
    }
    if (rows.length > 100_000) throw new Error("Celorga dataset exceeds 100,000 rows; choose a shorter since window");
    return { columns: CELORGA_DATASET_SCHEMAS[spec.source], rows };
  };
}
