import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { assignAutomationHost } from "./automationHost.js";
import { corpusIdentityStatus } from "./corpusIdentity.js";
import { guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { mcpAccessTokenHash, startMcpHttpServer, type McpHttpServerHandle } from "./mcpHttp.js";
import { defaultNativeServerExecutable } from "./nativeServerExecutable.js";
import { safeIdentifier } from "./safeIdentifier.js";
import { schemaMatches } from "./brandNames.js";

interface ServerDestination {
  id: string; name: string; mention: string; adapter: string; endpoint: string;
  agentID: string; workspaceRoot: string; isEnabled: boolean;
}

export interface ServerMcpAccessToken {
  id: string;
  name: string;
  tokenHash: string;
  scopes: ["corpus:read"];
  createdAt: string;
}

export interface ServerMcpConfiguration {
  enabled: boolean;
  port: number;
  allowedOrigins: string[];
  accessTokens: ServerMcpAccessToken[];
}

export interface ServerConfiguration {
  schema: "org2:server-config:v1";
  hostRef: string;
  name: string;
  corpusRoot: string;
  bindHost: string;
  port: number;
  repoRoot: string;
  nodePath: string;
  executable: string;
  destinations: ServerDestination[];
  schedulesEnabled: boolean;
  chatRepairIntervalSeconds: number;
  localAgentFilesystemAccess: "readOnly" | "workspaceWrite" | "fullAccess";
  mcp: ServerMcpConfiguration;
}

function localAgentFilesystemAccess(value: unknown): ServerConfiguration["localAgentFilesystemAccess"] {
  const normalized = value === undefined || value === null
    ? "workspace-write"
    : String(value).trim();
  const aliases: Record<string, ServerConfiguration["localAgentFilesystemAccess"]> = {
    "read-only": "readOnly",
    readOnly: "readOnly",
    "workspace-write": "workspaceWrite",
    workspaceWrite: "workspaceWrite",
    "full-access": "fullAccess",
    fullAccess: "fullAccess",
  };
  const access = aliases[normalized];
  if (!access) throw new Error("Choose read-only, workspace-write, or full-access for local agent filesystem access");
  return access;
}

function chatRepairInterval(value: unknown): number {
  if (value === null || (value !== undefined && typeof value !== "string" && typeof value !== "number")) {
    throw new Error("Chat repair interval must be off or between 10 and 86400 seconds");
  }
  const seconds = value === undefined ? 120 : value === "off" || value === "never" ? 0 : Number(value);
  if (!Number.isFinite(seconds) || (seconds !== 0 && (seconds < 10 || seconds > 86_400))) {
    throw new Error("Chat repair interval must be off or between 10 and 86400 seconds");
  }
  return seconds;
}

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const help = `Celorga headless server (macOS 14 or later)

  celorga server init --dir CORPUS --host-ref HOST --bind TAILSCALE_IP [--name NAME] [--destination codex|claude|pi|opencode|openclaw] [--filesystem-access read-only|workspace-write|full-access] [--chat-repair-interval off|SECONDS] [--mcp-port PORT] [--apply]
  celorga server chat-repair --interval off|SECONDS [--config FILE] [--apply]
  celorga server permissions --filesystem-access read-only|workspace-write|full-access [--config FILE] [--apply]
  celorga server token create --name NAME [--config FILE] [--apply]
  celorga server token list [--config FILE]
  celorga server token revoke --id ID [--config FILE] [--apply]
  celorga server mcp enable|disable [--mcp-port PORT] [--allow-origin ORIGIN ...] [--config FILE] [--apply]
  celorga server start [--config FILE]
  celorga server status|pair|stop [--config FILE]
  celorga server drain [--drain-timeout SECONDS] [--config FILE]
  celorga server resume [--config FILE]
  celorga server stop|restart --drain [--drain-timeout SECONDS] [--config FILE]
  celorga server revoke --device-id ID [--config FILE]
  celorga server push-config --team-id ID --key-id ID --key-file FILE [--apply] [--config FILE]
  celorga server assign --dir CORPUS --host-ref HOST [--apply]
  celorga server service [--config FILE] [--apply]

init, assign, and service preview by default. init writes machine-local configuration,
outside the corpus. assign chooses the corpus scheduler owner (desktop by default).
start runs in the foreground; service installs a launchd agent that runs at login
and restarts after failures. pair issues a one-use code valid for ten minutes.
permissions previews or updates the local-agent filesystem policy; restart the server
after applying it. Full access disables interactive approval prompts for local agents.
chat-repair sets the deterministic chat check interval (120 seconds by default;
off disables it); restart the server after applying a change.
Creating a token enables a read-only Streamable HTTP MCP endpoint and prints the
credential once. Only token hashes are stored. Token, MCP, and permission changes
require a restart. Browser origins are rejected unless explicitly allowed.
drain prepares for an upgrade or restart without interrupting live turns: the server
accepts no new turns, hand-offs, or scheduled automations (clients route new turns to
another online host or wait for it), and drain waits for running turns to finish
(900 seconds by default). stop --drain stops only after they finish; restart --drain
then starts the launchd service again (for example after updating the build); resume
cancels a drain.
The private control socket permits only this OS user; the relay binds only to Tailscale.
Build the native worker with npm run build:server before starting from a checkout.
Use --config for separate hosts. --executable PATH overrides the native worker at init.
`;

function defaultMcpPort(relayPort: number): number {
  return relayPort < 65_535 ? relayPort + 1 : relayPort - 1;
}

function normalizedOrigins(value: unknown): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error("MCP allowedOrigins must be an array of URL origins");
  }
  return Array.from(new Set(value.map((item) => {
    const parsed = new URL(item);
    if (!/^https?:$/.test(parsed.protocol) || parsed.origin !== item || parsed.username || parsed.password) {
      throw new Error(`Invalid MCP allowed origin: ${item}`);
    }
    return parsed.origin;
  }))).sort();
}

function serverMcpConfiguration(value: unknown, relayPort: number): ServerMcpConfiguration {
  if (value === undefined || value === null) {
    return { enabled: false, port: defaultMcpPort(relayPort), allowedOrigins: [], accessTokens: [] };
  }
  if (typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid MCP server configuration");
  const raw = value as Partial<ServerMcpConfiguration>;
  if (typeof raw.enabled !== "boolean") throw new Error("MCP enabled must be a boolean");
  if (!Number.isInteger(raw.port) || Number(raw.port) < 1 || Number(raw.port) > 65_535 || raw.port === relayPort) {
    throw new Error("MCP port must be a valid port different from the Mobile Remote port");
  }
  if (!Array.isArray(raw.accessTokens)) throw new Error("MCP accessTokens must be an array");
  const ids = new Set<string>();
  const accessTokens = raw.accessTokens.map((rawToken, index): ServerMcpAccessToken => {
    const label = `MCP access token ${index + 1}`;
    if (!rawToken || typeof rawToken !== "object") throw new Error(`${label} must be an object`);
    const token = rawToken as Partial<ServerMcpAccessToken>;
    const id = safeIdentifier(String(token.id || ""), { label: `${label} id` });
    if (ids.has(id)) throw new Error(`Duplicate MCP access token id: ${id}`);
    ids.add(id);
    if (typeof token.name !== "string" || !token.name.trim() || token.name.length > 120) {
      throw new Error(`${label} name must contain 1-120 characters`);
    }
    if (typeof token.tokenHash !== "string" || !/^[a-f0-9]{64}$/.test(token.tokenHash)) {
      throw new Error(`${label} must contain a SHA-256 token hash`);
    }
    if (!Array.isArray(token.scopes) || token.scopes.length !== 1 || token.scopes[0] !== "corpus:read") {
      throw new Error(`${label} must have only the corpus:read scope`);
    }
    if (typeof token.createdAt !== "string" || !Number.isFinite(Date.parse(token.createdAt))) {
      throw new Error(`${label} createdAt must be an ISO timestamp`);
    }
    return { id, name: token.name.trim(), tokenHash: token.tokenHash, scopes: ["corpus:read"], createdAt: token.createdAt };
  });
  if (raw.enabled && accessTokens.length === 0) throw new Error("Enable MCP only after creating a read-only access token");
  return {
    enabled: raw.enabled,
    port: Number(raw.port),
    allowedOrigins: normalizedOrigins(raw.allowedOrigins),
    accessTokens,
  };
}

function publicMcpConfiguration(config: ServerConfiguration): Record<string, unknown> {
  return {
    enabled: config.mcp.enabled,
    endpoint: `http://${config.bindHost}:${config.mcp.port}/mcp`,
    allowedOrigins: config.mcp.allowedOrigins,
    tokens: config.mcp.accessTokens.map(({ id, name, scopes, createdAt }) => ({ id, name, scopes, createdAt })),
  };
}

function existingRealPath(file: string): string {
  if (fs.existsSync(file)) return fs.realpathSync(file);
  return path.join(existingRealPath(path.dirname(file)), path.basename(file));
}

function contained(root: string, file: string): boolean {
  const relative = path.relative(root, file);
  return !relative || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

export function validateServerConfiguration(value: unknown, configFile: string): ServerConfiguration {
  if (!value || typeof value !== "object") throw new Error("Invalid server configuration");
  const config = value as ServerConfiguration;
  if (!schemaMatches(config.schema, "org2:server-config:v1")) throw new Error("Unsupported server configuration schema");
  safeIdentifier(config.hostRef);
  if (!config.name?.trim() || config.name.length > 120) throw new Error("Server name must contain 1-120 characters");
  const octets = String(config.bindHost).split(".");
  if (octets.length !== 4 || octets.some((part) => !/^\d{1,3}$/.test(part) || Number(part) > 255)
    || Number(octets[0]) !== 100 || Number(octets[1]) < 64 || Number(octets[1]) > 127) {
    throw new Error("--bind must be this host's Tailscale IPv4 address");
  }
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error("Invalid server port");
  const mcp = serverMcpConfiguration(config.mcp, config.port);
  for (const key of ["corpusRoot", "repoRoot", "nodePath", "executable"] as const) {
    if (typeof config[key] !== "string" || !path.isAbsolute(config[key])) throw new Error(`${key} must be an absolute path`);
  }
  const corpus = corpusIdentityStatus(config.corpusRoot);
  if (!corpus.valid) throw new Error(`Invalid corpus: ${corpus.issues.map((item) => item.message).join("; ")}`);
  const localConfig = existingRealPath(configFile);
  if (contained(fs.realpathSync(config.corpusRoot), localConfig) || contained(existingRealPath(config.repoRoot), localConfig)) {
    throw new Error("Server configuration must be machine-local, outside the corpus and source checkout");
  }
  if (typeof config.schedulesEnabled !== "boolean") throw new Error("schedulesEnabled must be a boolean");
  const filesystemAccess = localAgentFilesystemAccess(config.localAgentFilesystemAccess);
  if (!Array.isArray(config.destinations) || !config.destinations.length) throw new Error("Choose at least one AI destination");
  const ids = new Set<string>();
  for (const destination of config.destinations) {
    if (!destination.id || ids.has(destination.id)) throw new Error("AI destination IDs must be unique");
    ids.add(destination.id);
    if (!["codexLocal", "claudeLocal", "piLocal", "piRemote", "openCodeLocal", "openCodeRemote", "openClaw", "codexRemote", "codexManagedRemote", "openAI", "anthropic", "openRouter", "ollama", "openAIDot"].includes(destination.adapter)) {
      throw new Error(`Unsupported AI destination adapter: ${destination.adapter}`);
    }
    for (const key of ["name", "mention", "endpoint", "agentID", "workspaceRoot"] as const) {
      if (typeof destination[key] !== "string") throw new Error(`Destination ${key} must be a string`);
    }
    if (typeof destination.isEnabled !== "boolean") throw new Error("Destination isEnabled must be a boolean");
    if (/token|secret|password|credential|api.?key/i.test(Object.keys(destination).filter((key) => !["id", "name", "mention", "adapter", "endpoint", "agentID", "workspaceRoot", "model", "isEnabled"].includes(key)).join(" "))) {
      throw new Error("Credentials must stay in the runtime's login store or Keychain");
    }
  }
  return { ...config, localAgentFilesystemAccess: filesystemAccess,
    chatRepairIntervalSeconds: chatRepairInterval(config.chatRepairIntervalSeconds), mcp };
}

function socketPath(configFile: string): string {
  return path.join(path.dirname(configFile), `control-${crypto.createHash("sha256").update(configFile).digest("hex").slice(0, 12)}.sock`);
}

// Stopping persists every chat before the worker exits, which can take well
// over 30 seconds on a large corpus.
export const STOP_CONTROL_TIMEOUT_MS = 180_000;
const DEFAULT_CONTROL_TIMEOUT_MS = 30_000;

function controlTimeoutMs(command: string): number {
  return command === "stop" ? STOP_CONTROL_TIMEOUT_MS : DEFAULT_CONTROL_TIMEOUT_MS;
}

export function serverControl(configFile: string, command: string, extra: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socketPath(configFile));
    let buffer = "";
    client.setTimeout(controlTimeoutMs(command) + 5_000, () => client.destroy(new Error("Server control request timed out")));
    client.on("error", reject);
    client.on("connect", () => client.write(`${JSON.stringify({ command, ...extra })}\n`));
    client.on("data", (chunk) => {
      buffer += chunk.toString();
      if (buffer.length > 1_000_000) { client.destroy(new Error("Oversized server control response")); return; }
      if (!buffer.includes("\n")) return;
      client.end();
      try { resolve(JSON.parse(buffer.slice(0, buffer.indexOf("\n")))); } catch (error) { reject(error); }
    });
    client.on("end", () => { if (!buffer.includes("\n")) reject(new Error("Server closed the control connection")); });
  });
}

/** Resolve once nothing accepts connections on the control socket, or after timeoutMs. */
export async function waitForControlSocketClosed(configFile: string, timeoutMs: number, pollMs = 250): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const open = await new Promise<boolean>((resolve) => {
      const probe = net.createConnection(socketPath(configFile));
      probe.once("connect", () => { probe.destroy(); resolve(true); });
      probe.once("error", () => resolve(false));
    });
    if (!open) return true;
    if (Date.now() >= deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  }
}

async function serve(configFile: string, config: ServerConfiguration): Promise<void> {
  if (process.platform !== "darwin") throw new Error("The current chat worker requires macOS 14 or later");
  fs.accessSync(config.executable, fs.constants.X_OK);
  const directory = path.dirname(configFile);
  const directoryStat = fs.statSync(directory);
  if (directoryStat.uid !== process.getuid?.() || (directoryStat.mode & 0o077) !== 0) {
    throw new Error("The server config directory must be owned by this user with mode 0700");
  }
  const socket = socketPath(configFile);
  if (Buffer.byteLength(socket) > 100) throw new Error("Server config path is too long for its private control socket; use a shorter state directory");
  if (fs.existsSync(socket)) {
    try { await serverControl(configFile, "status"); throw new Error("This server is already running"); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ECONNREFUSED") throw error;
      fs.unlinkSync(socket);
    }
  }
  const pending = new Map<string, { client: net.Socket; timer: NodeJS.Timeout; command: string }>();
  const clients = new Set<net.Socket>();
  let stopping = false;
  let child: ReturnType<typeof spawn> | undefined;
  let mcpServer: McpHttpServerHandle | undefined;
  const server = net.createServer((client) => {
    clients.add(client);
    client.on("close", () => clients.delete(client));
    client.on("error", () => {});
    client.setTimeout(STOP_CONTROL_TIMEOUT_MS + 10_000, () => client.destroy());
    let buffer = "";
    client.on("data", (chunk) => {
      buffer += chunk.toString();
      if (buffer.length > 4096) { client.destroy(); return; }
      if (!buffer.includes("\n")) return;
      client.removeAllListeners("data");
      try {
        const request = JSON.parse(buffer.slice(0, buffer.indexOf("\n")));
        if (!["status", "pair", "revoke", "stop", "push-config", "drain", "resume", "stop-thread", "retry-message"].includes(request.command)) throw new Error("Unknown control command");
        if (!child?.stdin?.writable) throw new Error("Server worker is starting or unavailable");
        const id = crypto.randomUUID();
        const timer = setTimeout(() => { pending.delete(id); client.end('{"error":"Worker timed out"}\n'); }, controlTimeoutMs(request.command));
        pending.set(id, { client, timer, command: request.command });
        child.stdin.write(`${JSON.stringify({ ...request, id })}\n`);
      } catch (error) { client.end(`${JSON.stringify({ error: (error as Error).message })}\n`); }
    });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(socket, resolve); });
  fs.chmodSync(socket, 0o600);
  const stop = () => {
    if (stopping) return;
    stopping = true;
    child?.stdin?.end();
    setTimeout(() => child?.kill("SIGKILL"), 25_000).unref();
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  try {
    if (config.mcp.enabled) {
      mcpServer = await startMcpHttpServer({
        root: config.corpusRoot,
        host: config.bindHost,
        port: config.mcp.port,
        accessTokens: config.mcp.accessTokens,
        allowedOrigins: config.mcp.allowedOrigins,
      });
    }
    child = spawn(config.executable, ["--config", configFile], { stdio: ["pipe", "pipe", "inherit"] });
    const lines = readline.createInterface({ input: child.stdout! });
    lines.on("line", (line) => {
      try {
        const event = JSON.parse(line);
        if (event.event === "ready") {
          process.stdout.write(`${JSON.stringify({ ...event, ...(mcpServer ? { mcpEndpoint: mcpServer.endpoint } : {}) })}\n`);
        }
        const request = pending.get(event.id);
        if (request) {
          clearTimeout(request.timer);
          pending.delete(event.id);
          if (event.result?.stopped === true) event.result.supervisorPID = process.pid;
          if (request.command === "status") event.result.mcp = publicMcpConfiguration(config);
          request.client.end(`${JSON.stringify(event.result)}\n`);
        }
      } catch { /* Native diagnostics are not control replies. */ }
    });
    const result = await new Promise<number>((resolve, reject) => {
      child!.once("error", reject);
      child!.once("exit", (code) => resolve(code ?? 1));
    });
    if (result !== 0) throw new Error(`Celorga server worker exited with status ${result}`);
  } finally {
    process.removeListener("SIGTERM", stop);
    process.removeListener("SIGINT", stop);
    for (const { client, timer } of pending.values()) { clearTimeout(timer); client.destroy(); }
    for (const client of clients) client.destroy();
    await mcpServer?.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

function drainTimeoutSeconds(raw: string | undefined): number {
  if (raw === undefined) return 900;
  const seconds = Number(raw);
  if (!Number.isFinite(seconds) || seconds < 0 || seconds > 86_400) throw new Error("--drain-timeout must be between 0 and 86400 seconds");
  return seconds;
}

/**
 * Asks the worker to stop accepting turns and polls until its running turns
 * finish (or the timeout elapses). Clients route new turns elsewhere meanwhile.
 */
export async function drainServer(
  configFile: string,
  timeoutSeconds: number,
  control: (command: string) => Promise<Record<string, unknown>> = (command) => serverControl(configFile, command),
  pollMs = 1000,
): Promise<{ drained: boolean; remaining: number; waitedSeconds: number }> {
  const started = Date.now();
  const first = await control("drain");
  if (first.error) throw new Error(String(first.error));
  let remaining = Number(first.runningThreads ?? 0);
  while (remaining > 0 && Date.now() - started < timeoutSeconds * 1000) {
    await new Promise((resolve) => setTimeout(resolve, pollMs));
    const status = await control("status");
    if (status.error) throw new Error(String(status.error));
    remaining = Number(status.runningThreads ?? 0);
  }
  return { drained: remaining === 0, remaining, waitedSeconds: Math.round((Date.now() - started) / 1000) };
}

function xml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function serverLaunchAgent(configFile: string, config: ServerConfiguration): string {
  const argumentsList = [config.nodePath, path.join(config.repoRoot, "dist", "cli.js"), "server", "start", "--config", configFile];
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.org2.server.${xml(config.hostRef)}</string>
<key>ProgramArguments</key><array>${argumentsList.map((arg) => `<string>${xml(arg)}</string>`).join("")}</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>15</integer>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml([path.dirname(config.nodePath), "/opt/homebrew/bin", "/usr/local/bin", path.join(os.homedir(), ".local/bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(":"))}</string></dict>
<key>StandardOutPath</key><string>${xml(path.join(path.dirname(configFile), "server.log"))}</string>
<key>StandardErrorPath</key><string>${xml(path.join(path.dirname(configFile), "server-error.log"))}</string>
</dict></plist>
`;
}

export async function runServerCommand(args: string[]): Promise<void> {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, options: {
    config: { type: "string" }, dir: { type: "string" }, "host-ref": { type: "string" },
    bind: { type: "string" }, name: { type: "string" }, port: { type: "string" },
    executable: { type: "string" }, destination: { type: "string" }, "device-id": { type: "string" },
    id: { type: "string" }, "mcp-port": { type: "string" }, "allow-origin": { type: "string", multiple: true },
    "filesystem-access": { type: "string" }, "chat-repair-interval": { type: "string" }, interval: { type: "string" },
    "team-id": { type: "string" }, "key-id": { type: "string" }, "key-file": { type: "string" },
    apply: { type: "boolean" }, json: { type: "boolean" }, help: { type: "boolean" },
    drain: { type: "boolean" }, "drain-timeout": { type: "string" },
  } });
  const command = positionals[0];
  if (!command || values.help) { process.stdout.write(help); return; }
  const configFile = path.resolve(values.config || path.join(os.homedir(), ".local/state/openorg/server.json"));
  const print = (value: unknown) => process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  if (command === "assign") {
    if (!values.dir || !values["host-ref"]) throw new Error("assign requires --dir and --host-ref");
    print(assignAutomationHost(path.resolve(values.dir), values["host-ref"], !!values.apply));
    return;
  }
  if (command === "init") {
    if (!values.dir || !values["host-ref"] || !values.bind) throw new Error("init requires --dir, --host-ref, and --bind");
    const destination = values.destination || "codex";
    const builtInDestinations: Record<string, { name: string; adapter: string }> = {
      codex: { name: "Codex", adapter: "codexLocal" },
      claude: { name: "Claude Code", adapter: "claudeLocal" },
      pi: { name: "Pi", adapter: "piLocal" },
      opencode: { name: "OpenCode", adapter: "openCodeLocal" },
      openclaw: { name: "OpenClaw", adapter: "openClaw" },
    };
    const builtInDestination = builtInDestinations[destination];
    if (!builtInDestination) throw new Error("Choose codex, claude, pi, opencode, or openclaw");
    const relayPort = Number(values.port || 48922);
    const config = validateServerConfiguration({
      schema: "org2:server-config:v1", hostRef: values["host-ref"], name: values.name || `Celorga on ${values["host-ref"]}`,
      corpusRoot: fs.realpathSync(path.resolve(values.dir)), bindHost: values.bind, port: relayPort,
      repoRoot: packageRoot, nodePath: process.execPath,
      executable: path.resolve(values.executable || defaultNativeServerExecutable(packageRoot)),
      schedulesEnabled: true,
      chatRepairIntervalSeconds: chatRepairInterval(values["chat-repair-interval"]),
      localAgentFilesystemAccess: localAgentFilesystemAccess(values["filesystem-access"]),
      mcp: {
        enabled: false,
        port: Number(values["mcp-port"] || defaultMcpPort(relayPort)),
        allowedOrigins: values["allow-origin"] || [],
        accessTokens: [],
      },
      destinations: [{ id: `builtin.${destination}`, name: builtInDestination.name,
        mention: destination, adapter: builtInDestination.adapter,
        endpoint: "", agentID: "", workspaceRoot: "", isEnabled: true }],
    }, configFile);
    if (values.apply) {
      const directory = path.dirname(configFile);
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
      if ((fs.statSync(directory).mode & 0o077) !== 0) throw new Error("Use a private config directory with mode 0700");
      guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, { expectedRevision: null });
    }
    print({ applied: !!values.apply, configFile, config });
    return;
  }
  if (command === "chat-repair") {
    if (values.interval === undefined) throw new Error("chat-repair requires --interval off|SECONDS");
    const snapshot = readGuardedFile(configFile);
    const current = validateServerConfiguration(JSON.parse(snapshot.content), configFile);
    const config = { ...current, chatRepairIntervalSeconds: chatRepairInterval(values.interval) };
    if (values.apply) guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, {
      expectedRevision: snapshot.revision, preserveMode: true });
    print({ applied: !!values.apply, chatRepairIntervalSeconds: config.chatRepairIntervalSeconds,
      restartRequired: !!values.apply, configFile });
    return;
  }
  if (command === "permissions") {
    if (!values["filesystem-access"]) throw new Error("permissions requires --filesystem-access");
    const snapshot = readGuardedFile(configFile);
    const current = validateServerConfiguration(JSON.parse(snapshot.content), configFile);
    const filesystemAccess = localAgentFilesystemAccess(values["filesystem-access"]);
    const config = { ...current, localAgentFilesystemAccess: filesystemAccess };
    if (values.apply) {
      guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, {
        expectedRevision: snapshot.revision,
        preserveMode: true,
      });
    }
    print({
      applied: !!values.apply,
      configFile,
      previousFilesystemAccess: current.localAgentFilesystemAccess,
      filesystemAccess,
      restartRequired: !!values.apply && filesystemAccess !== current.localAgentFilesystemAccess,
    });
    return;
  }
  if (command === "token") {
    const action = positionals[1];
    const snapshot = readGuardedFile(configFile);
    const current = validateServerConfiguration(JSON.parse(snapshot.content), configFile);
    if (action === "list") {
      print({ configFile, mcp: publicMcpConfiguration(current) });
      return;
    }
    if (action === "create") {
      if (!values.name?.trim()) throw new Error("token create requires --name");
      if (values.name.length > 120) throw new Error("Token name must contain 1-120 characters");
      if (current.mcp.accessTokens.some((token) => token.name.toLowerCase() === values.name!.trim().toLowerCase())) {
        throw new Error(`An MCP access token named ${values.name.trim()} already exists`);
      }
      if (!values.apply) {
        print({ applied: false, configFile, name: values.name.trim(), scopes: ["corpus:read"], enablesMcp: !current.mcp.enabled, restartRequired: false });
        return;
      }
      const accessToken = `org2_${crypto.randomBytes(32).toString("base64url")}`;
      const token: ServerMcpAccessToken = {
        id: `token-${crypto.randomBytes(8).toString("hex")}`,
        name: values.name.trim(),
        tokenHash: mcpAccessTokenHash(accessToken),
        scopes: ["corpus:read"],
        createdAt: new Date().toISOString(),
      };
      const config = validateServerConfiguration({
        ...current,
        mcp: { ...current.mcp, enabled: true, accessTokens: [...current.mcp.accessTokens, token] },
      }, configFile);
      guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, { expectedRevision: snapshot.revision, preserveMode: true });
      print({ applied: true, configFile, token: { id: token.id, name: token.name, scopes: token.scopes, createdAt: token.createdAt }, accessToken, endpoint: publicMcpConfiguration(config).endpoint, restartRequired: true, warning: "Store this token now; Celorga retains only its SHA-256 hash." });
      return;
    }
    if (action === "revoke") {
      if (!values.id) throw new Error("token revoke requires --id");
      const token = current.mcp.accessTokens.find((item) => item.id === values.id);
      if (!token) throw new Error(`MCP access token not found: ${values.id}`);
      const remaining = current.mcp.accessTokens.filter((item) => item.id !== token.id);
      const config = validateServerConfiguration({
        ...current,
        mcp: { ...current.mcp, enabled: remaining.length > 0 && current.mcp.enabled, accessTokens: remaining },
      }, configFile);
      if (values.apply) {
        guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, { expectedRevision: snapshot.revision, preserveMode: true });
      }
      print({ applied: !!values.apply, configFile, revoked: { id: token.id, name: token.name }, disablesMcp: remaining.length === 0, restartRequired: !!values.apply });
      return;
    }
    throw new Error("token requires create, list, or revoke");
  }
  if (command === "mcp") {
    const action = positionals[1];
    if (!["enable", "disable"].includes(action || "")) throw new Error("mcp requires enable or disable");
    const snapshot = readGuardedFile(configFile);
    const current = validateServerConfiguration(JSON.parse(snapshot.content), configFile);
    const enabled = action === "enable";
    if (enabled && current.mcp.accessTokens.length === 0) throw new Error("Create a read-only MCP access token before enabling the endpoint");
    const mcp = {
      ...current.mcp,
      enabled,
      port: values["mcp-port"] === undefined ? current.mcp.port : Number(values["mcp-port"]),
      allowedOrigins: values["allow-origin"] === undefined ? current.mcp.allowedOrigins : values["allow-origin"],
    };
    const config = validateServerConfiguration({ ...current, mcp }, configFile);
    if (values.apply) {
      guardedWriteFile(configFile, `${JSON.stringify(config, null, 2)}\n`, { expectedRevision: snapshot.revision, preserveMode: true });
    }
    print({ applied: !!values.apply, configFile, mcp: publicMcpConfiguration(config), restartRequired: !!values.apply });
    return;
  }
  const config = validateServerConfiguration(JSON.parse(fs.readFileSync(configFile, "utf8")), configFile);
  if (command === "start") { await serve(configFile, config); return; }
  if (command === "push-config") {
    if (!values["team-id"] || !values["key-id"] || !values["key-file"]) throw new Error("push-config requires --team-id, --key-id, and --key-file");
    if (!values.apply) { print({ applied: false, teamID: values["team-id"], keyID: values["key-id"], keyFile: path.resolve(values["key-file"]) }); return; }
    const privateKey = fs.readFileSync(values["key-file"], "utf8");
    if (privateKey.length > 2048) throw new Error("Invalid APNs private key file");
    const result = await serverControl(configFile, "push-config", { teamID: values["team-id"], keyID: values["key-id"], privateKey });
    if (result.error) throw new Error(String(result.error));
    print(result); return;
  }
  if (command === "drain" || command === "resume" || command === "restart" || (command === "stop" && values.drain)) {
    if (command === "resume") {
      const result = await serverControl(configFile, "resume");
      if (result.error) throw new Error(String(result.error));
      print(result); return;
    }
    const drained = await drainServer(configFile, drainTimeoutSeconds(values["drain-timeout"]));
    if (command === "drain") { print(drained); return; }
    if (!drained.drained) {
      throw new Error(`${drained.remaining} turn(s) are still running after ${drained.waitedSeconds}s; run celorga server resume, wait, or stop without --drain to interrupt them`);
    }
    let result: Record<string, unknown>;
    try {
      result = await serverControl(configFile, "stop");
    } catch (error) {
      // The worker may still be shutting down. For restart, wait for it to go
      // away and start it again instead of leaving the service stopped.
      if (command !== "restart") throw error;
      result = { stopped: "unknown", stopError: (error as Error).message };
    }
    if (result.error && command !== "restart") throw new Error(String(result.error));
    let restart: Record<string, unknown> | undefined;
    if (command === "restart") {
      // A deliberate stop leaves the launchd service stopped; start it again
      // (with the newly installed build) through launchctl.
      const label = `org.org2.server.${config.hostRef}`;
      const plist = path.join(os.homedir(), "Library/LaunchAgents", `${label}.plist`);
      if (process.platform === "darwin" && fs.existsSync(plist)) {
        if (typeof result.supervisorPID === "number") {
          const deadline = Date.now() + 30_000;
          for (;;) {
            try { process.kill(result.supervisorPID, 0); } catch { break; }
            if (Date.now() >= deadline) break;
            await new Promise((resolve) => setTimeout(resolve, 50));
          }
        } else {
          await waitForControlSocketClosed(configFile, STOP_CONTROL_TIMEOUT_MS);
        }
        // Without -k, kickstart starts a stopped service and leaves a running one alone.
        const kick = spawnSync("launchctl", ["kickstart", `gui/${process.getuid?.()}/${label}`], { encoding: "utf8" });
        restart = { service: label, started: kick.status === 0, ...(kick.status === 0 ? {} : { error: (kick.stderr || kick.stdout || "").trim() }) };
      } else {
        restart = { started: false, next: "No launchd service is installed; run celorga server start" };
      }
    }
    print({ ...result, drain: drained, ...(restart ? { restart } : {}) });
    return;
  }
  if (["status", "pair", "revoke", "stop"].includes(command)) {
    if (command === "revoke" && !values["device-id"]) throw new Error("revoke requires --device-id");
    const result = await serverControl(configFile, command, { deviceID: values["device-id"] });
    if (result.error) throw new Error(String(result.error));
    if (command === "stop" && result.stopped && typeof result.supervisorPID === "number") {
      const deadline = Date.now() + 30_000;
      while (true) {
        try { process.kill(result.supervisorPID, 0); }
        catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") break; throw error; }
        if (Date.now() >= deadline) throw new Error("Worker saved its state, but the supervisor did not exit");
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }
    print(result); return;
  }
  if (command === "service") {
    if (process.platform !== "darwin") throw new Error("Service installation currently requires macOS launchd");
    const file = path.join(os.homedir(), "Library/LaunchAgents", `org.org2.server.${config.hostRef}.plist`);
    const plist = serverLaunchAgent(configFile, config);
    if (values.apply) {
      fs.accessSync(config.executable, fs.constants.X_OK);
      guardedWriteFile(file, plist, { expectedRevision: null });
    }
    print({ applied: !!values.apply, file, plist, start: ["launchctl", "bootstrap", `gui/${process.getuid?.()}`, file] });
    return;
  }
  throw new Error(`Unknown server command: ${command}`);
}
