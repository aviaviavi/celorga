import crypto from "node:crypto";
import { continueWorkspaceOffer, coordinateWorkspace } from "./workspaceCoordinator.js";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { spawnSync } from "node:child_process";
import { buildAgentContextPayload, type AgentAction, type AgentInclude } from "./agentContext.js";
import { listAgentRuns, loadAgentRunSnapshot, saveAgentRun, transitionAgentRun } from "./agentRun.js";
import { instantiateWorkflow, listWorkflows, loadWorkflow } from "./agentWorkflow.js";
import { resolveAgentProfile } from "./coordination.js";
import { compileCorpusIncremental } from "./corpusCompile.js";
import {
  isDefaultArchivePath,
  isDefaultIgnoredSyncArtifactPath,
  isOrgLikeFileName,
  listOrgLikeFiles,
} from "./corpusFiles.js";
import { defaultCorpusCachePath } from "./indexPaths.js";
import { safeIdentifier } from "./safeIdentifier.js";
import { queueAIChatInboxMessage } from "./aiChatInbox.js";
import { queueSecretRequest, secretRequestStatus } from "./secretRequest.js";
import { isOpenClawThreadSettled, loadOpenClawThreadState, openClawDateMilliseconds } from "./openClawThreadState.js";
import { celorgaToolName, legacyToolName, stateDir } from "./brandNames.js";

type JsonObject = Record<string, unknown>;
type JsonRpcId = string | number | null;

interface JsonRpcRequest {
  id?: JsonRpcId;
  method: string;
  params: JsonObject;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  result?: unknown;
  error?: { code: number; message: string };
}

type JsonRpcOutput = JsonRpcResponse | JsonRpcResponse[];

export interface McpServerOptions {
  readOnly?: boolean;
}

export const ORG2_MCP_PROTOCOL_VERSION = "2025-03-26";

class InvalidJsonRpcRequestError extends Error {}

function jsonObject(value: unknown): JsonObject | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as JsonObject
    : undefined;
}

function parseJsonRpcRequest(value: unknown): JsonRpcRequest {
  const request = jsonObject(value);
  if (!request || request.jsonrpc !== "2.0" || typeof request.method !== "string" || !request.method.trim()) {
    throw new InvalidJsonRpcRequestError("invalid JSON-RPC request");
  }
  if (request.id !== undefined && typeof request.id !== "string" && typeof request.id !== "number") {
    throw new InvalidJsonRpcRequestError("invalid JSON-RPC request id");
  }
  const params = request.params === undefined ? {} : jsonObject(request.params);
  if (!params) throw new InvalidJsonRpcRequestError("JSON-RPC params must be an object");
  return { id: request.id as JsonRpcId | undefined, method: request.method, params };
}

function parseJsonRpcMessage(line: string): JsonObject {
  const value: unknown = JSON.parse(line);
  const message = jsonObject(value);
  if (!message) throw new Error("MCP client returned a non-object JSON-RPC message");
  return message;
}

function responseResult(message: JsonObject | undefined): JsonObject | undefined {
  return jsonObject(message?.result);
}

function responseArray(message: JsonObject | undefined, key: string): unknown[] {
  const value = responseResult(message)?.[key];
  return Array.isArray(value) ? value : [];
}

function responseErrorMessage(message: JsonObject | undefined): string | undefined {
  if (message?.error === undefined) return undefined;
  const error = jsonObject(message?.error);
  return typeof error?.message === "string" ? error.message : "unknown MCP error";
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${label} must be a non-empty string`);
  return value;
}

function optionalString(value: unknown, label: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  return value;
}

function stringArray(value: unknown, label: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new Error(`${label} must be an array of strings`);
  }
  return value;
}

function boundedInteger(value: unknown, label: string, fallback: number, minimum: number, maximum: number): number {
  if (value === undefined) return fallback;
  if (typeof value !== "number" || !Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${label} must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}

function agentIncludes(value: unknown): AgentInclude[] {
  const values = stringArray(value, "include") ?? ["sources"];
  const allowed = new Set<AgentInclude>(["sources", "backlinks", "neighbors"]);
  if (values.some((item) => !allowed.has(item as AgentInclude))) {
    throw new Error("include entries must be sources, backlinks, or neighbors");
  }
  return Array.from(new Set(values as AgentInclude[]));
}

function mcpClientDefinition(value: unknown, index: number): McpClientDefinition {
  const client = jsonObject(value);
  const label = `MCP client ${index + 1}`;
  if (!client) throw new Error(`${label} must be an object`);
  const args = stringArray(client.args, `${label} args`);
  const environmentVariables = stringArray(client.environmentVariables, `${label} environmentVariables`);
  const capabilities = stringArray(client.capabilities, `${label} capabilities`);
  return {
    id: safeIdentifier(requiredString(client.id, `${label} id`), { label: `${label} id` }),
    command: requiredString(client.command, `${label} command`),
    ...(args ? { args } : {}),
    ...(environmentVariables ? { environmentVariables } : {}),
    ...(capabilities ? { capabilities } : {}),
  };
}

function mcpClientDefinitions(value: unknown[]): McpClientDefinition[] {
  const clients = value.map(mcpClientDefinition);
  const ids = new Set<string>();
  for (const client of clients) {
    if (ids.has(client.id)) throw new Error(`duplicate MCP client id: ${client.id}`);
    ids.add(client.id);
  }
  return clients;
}

function workflowInputs(value: unknown): Record<string, string> {
  if (value === undefined) return {};
  const inputs = jsonObject(value);
  if (!inputs || Object.values(inputs).some((item) => typeof item !== "string")) {
    throw new Error("workflow inputs must be an object with string values");
  }
  return inputs as Record<string, string>;
}

export interface McpClientDefinition {
  id: string;
  command: string;
  args?: string[];
  environmentVariables?: string[];
  capabilities?: string[];
}

export interface McpSnapshot {
  schema: "org2:mcp-snapshot:v1";
  id: string;
  source: string;
  retrievedAt: string;
  identity?: string;
  freshUntil?: string;
  payload: unknown;
}

const MCP_DISCOVERY_BASE_ENVIRONMENT_VARIABLES = ["PATH", "Path", "ComSpec", "PATHEXT", "SystemRoot", "TEMP", "TMP", "TMPDIR", "WINDIR"] as const;

function discoveryEnvironment(client: McpClientDefinition): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};
  for (const name of [...MCP_DISCOVERY_BASE_ENVIRONMENT_VARIABLES, ...(client.environmentVariables || [])]) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}

export function mcpClientConfigPath(root: string): string { return stateDir(path.resolve(root), "mcp-clients.json"); }
export function loadMcpClients(root: string): McpClientDefinition[] {
  const file = mcpClientConfigPath(root);
  if (!fs.existsSync(file)) return [];
  const value: unknown = JSON.parse(fs.readFileSync(file, "utf8"));
  const clients = Array.isArray(value) ? value : jsonObject(value)?.clients;
  if (!Array.isArray(clients)) throw new Error("MCP client configuration must be an array or an object with a clients array");
  return mcpClientDefinitions(clients);
}
export function saveMcpClients(root: string, clients: McpClientDefinition[]): string {
  const validatedClients = mcpClientDefinitions(clients);
  const file = mcpClientConfigPath(root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ schema: "org2:mcp-clients:v1", clients: validatedClients }, null, 2)}\n`, "utf8");
  return file;
}
export function writeMcpSnapshot(root: string, snapshot: McpSnapshot): string {
  const id = safeIdentifier(snapshot.id, { label: "snapshot id" });
  const file = path.join(path.resolve(root), "raw", "connectors", "mcp", `${id}.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
  return file;
}

export function discoverMcpClient(root: string, clientId: string, options: { timeoutMs?: number; snapshotId?: string; now?: string } = {}): { client: McpClientDefinition; capabilities: Record<string, unknown>; snapshot?: string } {
  const client = loadMcpClients(root).find((item) => item.id === clientId);
  if (!client) throw new Error(`MCP client not found: ${clientId}`);
  const requests = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: ORG2_MCP_PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "org2", version: "0.3.0" } } },
    { jsonrpc: "2.0", method: "notifications/initialized", params: {} },
    { jsonrpc: "2.0", id: 2, method: "resources/list", params: {} },
    { jsonrpc: "2.0", id: 3, method: "tools/list", params: {} },
    { jsonrpc: "2.0", id: 4, method: "prompts/list", params: {} },
  ];
  const execution = spawnSync(client.command, client.args || [], {
    cwd: path.resolve(root),
    env: discoveryEnvironment(client),
    input: `${requests.map((item) => JSON.stringify(item)).join("\n")}\n`,
    encoding: "utf8",
    timeout: options.timeoutMs || 10_000,
    maxBuffer: 10 * 1024 * 1024,
  });
  if (execution.error) throw execution.error;
  if (execution.status !== 0) throw new Error(`MCP client ${clientId} exited ${execution.status}: ${String(execution.stderr || "").trim()}`);
  const messages = String(execution.stdout || "").split(/\r?\n/).filter(Boolean).map(parseJsonRpcMessage);
  const byId = new Map<unknown, JsonObject>(messages.filter((item) => item.id !== undefined).map((item) => [item.id, item]));
  const initializeError = responseErrorMessage(byId.get(1));
  if (initializeError) throw new Error(`MCP initialize failed: ${initializeError}`);
  const initializeResult = responseResult(byId.get(1));
  const capabilities = {
    serverInfo: initializeResult?.serverInfo,
    protocolVersion: initializeResult?.protocolVersion,
    advertised: jsonObject(initializeResult?.capabilities) || {},
    resources: responseArray(byId.get(2), "resources"),
    tools: responseArray(byId.get(3), "tools"),
    prompts: responseArray(byId.get(4), "prompts"),
  };
  let snapshot: string | undefined;
  if (options.snapshotId) {
    snapshot = writeMcpSnapshot(root, {
      schema: "org2:mcp-snapshot:v1",
      id: options.snapshotId,
      source: `mcp-client:${client.id}`,
      retrievedAt: new Date(options.now || Date.now()).toISOString(),
      identity: client.id,
      payload: capabilities,
    });
  }
  return { client, capabilities, ...(snapshot ? { snapshot } : {}) };
}

const RESOURCE_PAGE_SIZE = 100;

function resourceList(root: string) {
  return listOrgLikeFiles(root, true, false)
    .map((file) => path.relative(root, file))
    .sort()
    .map((name) => ({ uri: `org2://corpus/${name}`, name, mimeType: "text/org" }));
}

function resourceCursor(offset: number): string {
  return Buffer.from(String(offset), "utf8").toString("base64url");
}

function resourceOffset(value: unknown): number {
  if (value === undefined) return 0;
  if (typeof value !== "string" || !value) throw new Error("resource cursor must be a string");
  const decoded = Buffer.from(value, "base64url").toString("utf8");
  if (!/^\d+$/.test(decoded)) throw new Error("invalid resource cursor");
  const offset = Number(decoded);
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error("invalid resource cursor");
  return offset;
}

function corpusResourceFile(root: string, relative: string): string {
  const normalizedRelative = path.normalize(relative);
  const components = normalizedRelative.split(path.sep);
  if (!isOrgLikeFileName(path.basename(normalizedRelative), false)
    || isDefaultArchivePath(normalizedRelative)
    || isDefaultIgnoredSyncArtifactPath(normalizedRelative)
    || components.some((component) => component.startsWith("."))) {
    throw new Error("resource is not a Celorga source file exposed by this server");
  }
  const lexicalRoot = path.resolve(root);
  const requested = path.resolve(lexicalRoot, normalizedRelative);
  const lexicalRelative = path.relative(lexicalRoot, requested);
  if (!lexicalRelative || lexicalRelative === ".." || lexicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(lexicalRelative)) {
    throw new Error("resource is outside the corpus");
  }
  let current = lexicalRoot;
  let requestedStat: fs.Stats | undefined;
  for (const component of components) {
    current = path.join(current, component);
    try {
      requestedStat = fs.lstatSync(current);
    } catch {
      throw new Error("resource does not exist");
    }
    if (requestedStat.isSymbolicLink()) throw new Error("resource is a symbolic link");
  }
  if (!requestedStat?.isFile()) throw new Error("resource is not a file");

  const canonicalRoot = fs.realpathSync(lexicalRoot);
  const canonicalFile = fs.realpathSync(requested);
  const canonicalRelative = path.relative(canonicalRoot, canonicalFile);
  if (!canonicalRelative || canonicalRelative === ".." || canonicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(canonicalRelative)) {
    throw new Error("resource resolves outside the corpus");
  }
  return canonicalFile;
}

function retrievalPayload(root: string, action: AgentAction, args: JsonObject): unknown {
  const files = listOrgLikeFiles(root, true, false).sort((left, right) => left.localeCompare(right));
  if (files.length === 0) throw new Error("no Org files found for corpus retrieval");
  const corpus = compileCorpusIncremental(files, {
    rootDir: root,
    cacheFile: defaultCorpusCachePath(root),
  });
  return buildAgentContextPayload(corpus, {
    action,
    query: action === "fetch" ? undefined : requiredString(args.query, "query"),
    id: action === "fetch" ? requiredString(args.id, "id") : undefined,
    limit: action === "fetch" ? 1 : boundedInteger(args.limit, "limit", 10, 1, 50),
    maxChars: boundedInteger(args.maxChars, "maxChars", 12_000, 1_000, 50_000),
    include: agentIncludes(args.include),
    scope: optionalString(args.scope, "scope"),
    since: optionalString(args.since, "since"),
    sourceType: optionalString(args.sourceType, "sourceType"),
    reviewStatus: optionalString(args.reviewStatus, "reviewStatus"),
  });
}

function toolResult(payload: unknown): JsonObject {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    structuredContent: payload,
  };
}

const readOnlyAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};

const writeAnnotations = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
};

function retrievalProperties() {
  return {
    limit: { type: "integer", minimum: 1, maximum: 50, default: 10 },
    maxChars: { type: "integer", minimum: 1_000, maximum: 50_000, default: 12_000 },
    include: { type: "array", items: { type: "string", enum: ["sources", "backlinks", "neighbors"] }, default: ["sources"] },
    scope: { type: "string" },
    since: { type: "string" },
    sourceType: { type: "string" },
    reviewStatus: { type: "string" },
  };
}

// Tools are advertised as celorga_X; calls with the legacy org2_X name still work.
function mcpTools(readOnly: boolean) {
  return legacyMcpTools(readOnly).map((tool) => ({ ...tool, name: celorgaToolName(tool.name) }));
}

function legacyMcpTools(readOnly: boolean) {
  const readTools = [
    {
      name: "org2_search",
      description: "Search the selected Celorga corpus and return bounded, ranked results with source citations",
      inputSchema: { type: "object", required: ["query"], properties: { query: { type: "string" }, ...retrievalProperties() } },
      annotations: readOnlyAnnotations,
    },
    {
      name: "org2_fetch",
      description: "Fetch one corpus node by stable Celorga ID with bounded source, backlinks, or neighbors",
      inputSchema: { type: "object", required: ["id"], properties: { id: { type: "string" }, maxChars: { type: "integer", minimum: 1_000, maximum: 50_000, default: 12_000 }, include: { type: "array", items: { type: "string", enum: ["sources", "backlinks", "neighbors"] }, default: ["sources"] } } },
      annotations: readOnlyAnnotations,
    },
    {
      name: "org2_context",
      description: "Assemble bounded, cited corpus context for a question without calling a model",
      inputSchema: { type: "object", required: ["query"], properties: { query: { type: "string" }, ...retrievalProperties() } },
      annotations: readOnlyAnnotations,
    },
    { name: "org2_agent_profile_resolve", description: "Resolve a runtime agent ID to a portable Celorga agent profile and primary goal", inputSchema: { type: "object", required: ["runtime", "runtimeAgentId"], properties: { runtime: { type: "string" }, runtimeAgentId: { type: "string" } } }, annotations: readOnlyAnnotations },
    { name: "org2_run_list", description: "List durable Celorga runs and review state", inputSchema: { type: "object", properties: {} }, annotations: readOnlyAnnotations },
  ];
  if (readOnly) return readTools;
  return [
    ...readTools,
    { name: "org2_run_create", description: "Create a durable Celorga agent run from a reusable workflow", inputSchema: { type: "object", required: ["workflow"], properties: { workflow: { type: "string" }, inputs: { type: "object" }, owner: { type: "string" }, agentRef: { type: "string" }, goalRef: { type: "string" } } }, annotations: writeAnnotations },
    { name: "org2_run_transition", description: "Transition a durable Celorga run. Completion requires a concise, human-readable summary.", inputSchema: { type: "object", required: ["run", "status"], properties: { run: { type: "string" }, status: { type: "string" }, actor: { type: "string" }, reason: { type: "string" }, summary: { type: "string" }, highlights: { type: "array", items: { type: "string" } }, nextActions: { type: "array", items: { type: "string" } } } }, annotations: writeAnnotations },
    { name: "org2_thread_list", description: "List Celorga AI chats (newest first) with each thread's ID, title, state, runtime, destination, and whether it is a shared room. Use the ID with thread_send or thread_post", inputSchema: { type: "object", properties: { state: { type: "string", enum: ["all", "active", "settled"], default: "active" }, limit: { type: "integer", minimum: 1, maximum: 200, default: 50 } } }, annotations: readOnlyAnnotations },
    { name: "org2_thread_send", description: "Message the agent in an existing single-agent Celorga AI chat and start its turn, as if the user sent it (a follow-up if it is busy). Use this, not a new automation or scheduled job, to hand work to another agent. For a shared room use thread_post with requestTurn", inputSchema: { type: "object", required: ["threadId", "message"], properties: { threadId: { type: "string" }, message: { type: "string" }, author: { type: "string" }, idempotencyKey: { type: "string" } } }, annotations: writeAnnotations },
    { name: "org2_workspace_coordinate", description: "Review this corpus's agent work across hosts: what needs you, what is stuck, what is working, what shipped (with evidence links), and guarded continuation offers. Read-only; derived from durable runs, chats, and host presence", inputSchema: { type: "object", properties: { sinceHours: { type: "number", minimum: 1, maximum: 720, default: 24 }, quietMinutes: { type: "integer", minimum: 0, maximum: 10080, default: 15 } } }, annotations: readOnlyAnnotations },
    { name: "org2_workspace_continue", description: "Execute one current continuation offer from workspace_coordinate after re-checking every guard. Preview unless apply is true. Queues an idempotent single-agent send or a revision-guarded run retry; never confirms a turn started", inputSchema: { type: "object", required: ["offerId"], properties: { offerId: { type: "string" }, apply: { type: "boolean", default: false }, actor: { type: "string" } } }, annotations: writeAnnotations },
    { name: "org2_thread_post", description: "Post an attributed background message to an existing Celorga AI chat. It is context only unless requestTurn names shared-room agents (destination IDs or @mentions) that should each take a turn in response", inputSchema: { type: "object", required: ["threadId", "message", "author"], properties: { threadId: { type: "string" }, message: { type: "string" }, author: { type: "string" }, agentRef: { type: "string" }, source: { type: "string" }, idempotencyKey: { type: "string" }, requestTurn: { type: "array", items: { type: "string" }, maxItems: 8 } } }, annotations: writeAnnotations },
    { name: "org2_secret_request", description: "Ask the person for a credential through Celorga's secure entry sheet instead of chat. The app seals the value with GPG into the corpus secrets file; this tool never returns it. Check with secret_status, then run commands with `celorga secret exec NAME -- COMMAND`", inputSchema: { type: "object", required: ["name", "reason", "author"], properties: { name: { type: "string" }, reason: { type: "string" }, author: { type: "string" }, agentRef: { type: "string" }, threadId: { type: "string" }, recipients: { type: "array", items: { type: "string" } }, recipientFiles: { type: "array", items: { type: "string" } }, idempotencyKey: { type: "string" } } }, annotations: writeAnnotations },
    { name: "org2_secret_status", description: "Report whether a secret request is pending, fulfilled, or declined. Never returns the value", inputSchema: { type: "object", required: ["requestId"], properties: { requestId: { type: "string" } } }, annotations: readOnlyAnnotations },
  ];
}

async function handle(root: string, request: JsonRpcRequest, options: McpServerOptions): Promise<JsonRpcResponse | null> {
  const id = request.id;
  const result = (value: unknown): JsonRpcResponse => ({ jsonrpc: "2.0", id, result: value });
  const readOnly = options.readOnly === true;
  if (request.method === "initialize") return result({
    protocolVersion: ORG2_MCP_PROTOCOL_VERSION,
    capabilities: { resources: { listChanged: false }, tools: { listChanged: false }, prompts: { listChanged: false } },
    serverInfo: { name: "celorga", version: "0.3.0" },
    instructions: readOnly
      ? "Read-only Celorga corpus. Search with celorga_search, fetch stable IDs with celorga_fetch, and assemble cited context with celorga_context. Results are bounded and cite canonical source files and line ranges. Do not claim corpus facts without returned evidence."
      : "Search with celorga_search before broad resource reads, fetch stable IDs with celorga_fetch, and use celorga_context for bounded cited context. Corpus source is canonical. Run and thread tools write immediately; use them only when the user requested the action. Never ask the user to paste credentials into chat; use celorga_secret_request.",
  });
  if (request.method === "notifications/initialized") return null;
  if (request.method === "resources/list") {
    const resources = resourceList(root);
    const offset = resourceOffset(request.params.cursor);
    if (offset > resources.length) throw new Error("resource cursor is beyond the available resources");
    const page = resources.slice(offset, offset + RESOURCE_PAGE_SIZE);
    const nextOffset = offset + page.length;
    return result({ resources: page, ...(nextOffset < resources.length ? { nextCursor: resourceCursor(nextOffset) } : {}) });
  }
  if (request.method === "resources/read") {
    const uri = String(request.params.uri || "");
    const prefix = "org2://corpus/";
    if (!uri.startsWith(prefix)) throw new Error("unsupported resource URI");
    const relative = uri.slice(prefix.length);
    const file = corpusResourceFile(root, relative);
    const text = fs.readFileSync(file, "utf8");
    const revision = `sha256:${crypto.createHash("sha256").update(text).digest("hex")}`;
    return result({ contents: [{ uri, mimeType: "text/org", text, _meta: { revision, lineCount: text.split("\n").length } }] });
  }
  if (request.method === "prompts/list") return result({ prompts: listWorkflows(root).map((workflow) => ({ name: workflow.id, description: workflow.description, arguments: workflow.inputs.map((input) => ({ name: input.id, description: input.description, required: input.required })) })) });
  if (request.method === "prompts/get") {
    const workflow = loadWorkflow(root, String(request.params.name || ""));
    return result({ description: workflow.description, messages: [{ role: "user", content: { type: "text", text: workflow.instructions } }] });
  }
  if (request.method === "tools/list") return result({ tools: mcpTools(readOnly) });
  if (request.method === "tools/call") {
    const name = legacyToolName(String(request.params.name ?? ""));
    const args = jsonObject(request.params.arguments) || {};
    if (name === "org2_search") return result(toolResult(retrievalPayload(root, "search", args)));
    if (name === "org2_fetch") return result(toolResult(retrievalPayload(root, "fetch", args)));
    if (name === "org2_context") return result(toolResult(retrievalPayload(root, "context", args)));
    if (name === "org2_run_list") return result(toolResult(listAgentRuns(root)));
    if (name === "org2_agent_profile_resolve") {
      const resolved = resolveAgentProfile(root, requiredString(args.runtime, "runtime"), requiredString(args.runtimeAgentId, "runtimeAgentId"));
      return result(toolResult(resolved));
    }
    if (readOnly && ["org2_run_create", "org2_run_transition", "org2_thread_list", "org2_thread_send", "org2_thread_post", "org2_workspace_coordinate", "org2_workspace_continue", "org2_secret_request", "org2_secret_status"].includes(String(name))) {
      throw new Error("tool is unavailable on the read-only MCP endpoint");
    }
    if (name === "org2_workspace_coordinate" || name === "org2_workspace_continue") {
      const sinceHours = typeof args.sinceHours === "number" && Number.isFinite(args.sinceHours) ? Math.min(720, Math.max(1, args.sinceHours)) : 24;
      const quietMinutes = Number.isInteger(args.quietMinutes) ? Math.min(10080, Math.max(0, Number(args.quietMinutes))) : undefined;
      const options = { root, shippedWindowSeconds: sinceHours * 3600, ...(quietMinutes !== undefined ? { quietSeconds: quietMinutes * 60 } : {}) };
      if (name === "org2_workspace_coordinate") return result(toolResult(coordinateWorkspace(options)));
      return result(toolResult(continueWorkspaceOffer(requiredString(args.offerId, "offerId"), { ...options, apply: args.apply === true, actor: optionalString(args.actor, "actor") })));
    }
    if (name === "org2_thread_list") {
      const filter = optionalString(args.state, "state") ?? "active";
      if (!["all", "active", "settled"].includes(filter)) throw new Error("state must be all, active, or settled");
      const limit = Math.min(200, Math.max(1, Number.isInteger(args.limit) ? Number(args.limit) : 50));
      const threads = loadOpenClawThreadState(root).threads
        .filter((thread) => filter === "all" || (filter === "settled") === isOpenClawThreadSettled(thread))
        .sort((left, right) => (openClawDateMilliseconds(right.updatedAt) || 0) - (openClawDateMilliseconds(left.updatedAt) || 0))
        .slice(0, limit)
        .map((thread) => ({
          id: thread.id.toLowerCase(),
          title: thread.title || "Untitled",
          state: isOpenClawThreadSettled(thread) ? "settled" : "active",
          runtime: thread.runtime,
          destinationId: thread.destinationID,
          sharedRoom: thread.isSharedRoom === true,
        }));
      return result({ content: [{ type: "text", text: JSON.stringify({ threads }, null, 2) }] });
    }
    if (name === "org2_thread_send") {
      const queued = queueAIChatInboxMessage(
        root,
        requiredString(args.threadId, "threadId"),
        requiredString(args.message, "message"),
        {
          send: true,
          authorLabel: optionalString(args.author, "author"),
          idempotencyKey: optionalString(args.idempotencyKey, "idempotencyKey"),
          apply: true,
        },
      );
      return result({ content: [{ type: "text", text: JSON.stringify(queued, null, 2) }] });
    }
    if (name === "org2_thread_post") {
      const queued = queueAIChatInboxMessage(
        root,
        requiredString(args.threadId, "threadId"),
        requiredString(args.message, "message"),
        {
          authorLabel: requiredString(args.author, "author"),
          authorAgentRef: optionalString(args.agentRef, "agentRef"),
          source: optionalString(args.source, "source"),
          idempotencyKey: optionalString(args.idempotencyKey, "idempotencyKey"),
          requestedResponders: stringArray(args.requestTurn, "requestTurn"),
          apply: true,
        },
      );
      return result({ content: [{ type: "text", text: JSON.stringify(queued, null, 2) }] });
    }
    if (name === "org2_secret_request") {
      const queued = queueSecretRequest(root, requiredString(args.name, "name"), {
        reason: requiredString(args.reason, "reason"),
        authorLabel: requiredString(args.author, "author"),
        authorAgentRef: optionalString(args.agentRef, "agentRef"),
        threadID: optionalString(args.threadId, "threadId"),
        recipients: stringArray(args.recipients, "recipients"),
        recipientFiles: stringArray(args.recipientFiles, "recipientFiles"),
        idempotencyKey: optionalString(args.idempotencyKey, "idempotencyKey"),
        apply: true,
      });
      return result({ content: [{ type: "text", text: JSON.stringify(queued, null, 2) }] });
    }
    if (name === "org2_secret_status") {
      return result({ content: [{ type: "text", text: JSON.stringify(secretRequestStatus(root, requiredString(args.requestId, "requestId")), null, 2) }] });
    }
    if (name === "org2_run_create") {
      const run = instantiateWorkflow(loadWorkflow(root, requiredString(args.workflow, "workflow")), workflowInputs(args.inputs), {
        owner: optionalString(args.owner, "owner"),
        agentRef: optionalString(args.agentRef, "agentRef"),
        goalRef: optionalString(args.goalRef, "goalRef"),
      });
      const file = saveAgentRun(root, run, { expectedRevision: null });
      return result({ content: [{ type: "text", text: JSON.stringify({ run, file }, null, 2) }] });
    }
    if (name === "org2_run_transition") {
      const snapshot = loadAgentRunSnapshot(root, requiredString(args.run, "run"));
      if (snapshot.sourceIssues.length > 0) throw new Error(`run source has out-of-band readable-state changes: ${snapshot.sourceIssues.map((issue) => issue.field).join(", ")}`);
      const run = transitionAgentRun(snapshot.run, requiredString(args.status, "status") as Parameters<typeof transitionAgentRun>[1], {
        actor: optionalString(args.actor, "actor"), reason: optionalString(args.reason, "reason"), summary: optionalString(args.summary, "summary"),
        highlights: stringArray(args.highlights, "highlights"), nextActions: stringArray(args.nextActions, "nextActions"),
      });
      saveAgentRun(root, run, { expectedRevision: snapshot.revision, rejectSourceDrift: true });
      return result({ content: [{ type: "text", text: JSON.stringify(run, null, 2) }] });
    }
    throw new Error(`unknown tool: ${String(request.params.name ?? "")}`);
  }
  return { jsonrpc: "2.0", id, error: { code: -32601, message: `method not found: ${request.method}` } };
}

export async function handleMcpMessage(root: string, value: unknown, options: McpServerOptions = {}): Promise<JsonRpcOutput | null> {
  if (Array.isArray(value)) {
    if (value.length === 0 || value.length > 100) {
      return { jsonrpc: "2.0", id: null, error: { code: -32600, message: "MCP batches must contain 1 through 100 messages" } };
    }
    const responses: JsonRpcResponse[] = [];
    for (const item of value) {
      const response = await handleMcpMessage(root, item, options);
      if (response && !Array.isArray(response)) responses.push(response);
    }
    return responses.length > 0 ? responses : null;
  }
  let id: JsonRpcId = null;
  try {
    const parsedValue = jsonObject(value);
    if (parsedValue
      && parsedValue.jsonrpc === "2.0"
      && parsedValue.method === undefined
      && (typeof parsedValue.id === "string" || typeof parsedValue.id === "number" || parsedValue.id === null)
      && (Object.hasOwn(parsedValue, "result") || Object.hasOwn(parsedValue, "error"))) {
      return null;
    }
    if (parsedValue && (typeof parsedValue.id === "string" || typeof parsedValue.id === "number")) {
      id = parsedValue.id as JsonRpcId;
    }
    const request = parseJsonRpcRequest(value);
    if (request.id === undefined && request.method !== "notifications/initialized") return null;
    return await handle(path.resolve(root), request, options);
  } catch (error) {
    const parsedValue = jsonObject(value);
    if (parsedValue?.jsonrpc === "2.0" && typeof parsedValue.method === "string" && !Object.hasOwn(parsedValue, "id")) {
      return null;
    }
    return {
      jsonrpc: "2.0",
      id,
      error: {
        code: error instanceof InvalidJsonRpcRequestError ? -32600 : -32603,
        message: error instanceof Error ? error.message : String(error),
      },
    };
  }
}

export async function serveMcp(root: string, input: NodeJS.ReadableStream = process.stdin, output: NodeJS.WritableStream = process.stdout, options: McpServerOptions = {}): Promise<void> {
  const lines = readline.createInterface({ input });
  for await (const line of lines) {
    if (!String(line).trim()) continue;
    let value: unknown;
    try {
      value = JSON.parse(String(line));
    } catch (error) {
      const response: JsonRpcResponse = {
        jsonrpc: "2.0",
        id: null,
        error: {
          code: -32700,
          message: error instanceof Error ? error.message : String(error),
        },
      };
      output.write(`${JSON.stringify(response)}\n`);
      continue;
    }
    const response: JsonRpcOutput | null = await handleMcpMessage(root, value, options);
    if (response) output.write(`${JSON.stringify(response)}\n`);
  }
}

/** @deprecated Import from agentWorkflow instead. */
export { installBuiltinWorkflow } from "./agentWorkflow.js";
