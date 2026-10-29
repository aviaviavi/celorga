import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig, type Org2Config, type Org2PluginConfig } from "./config.js";
import { parseSince } from "./activityCli.js";
import {
  ORG2_PLUGIN_ACTION_LIST_SCHEMA,
  applyPluginProposal,
  dismissPluginProposal,
  dispatchPluginHooksOnce,
  followPluginHooks,
  listPluginActions,
  listPluginHooks,
  listPluginProposals,
  loadPluginProposal,
  pluginSandboxAvailable,
  runPluginAction,
  type PluginActionContextRef,
  type PluginProposalRecord,
} from "./pluginActions.js";
import {
  ORG2_PLUGIN_ACTION_CONTEXTS,
  ORG2_PLUGIN_INVOCATION_SCHEMA,
  ORG2_PLUGIN_LOCK_SCHEMA,
  ORG2_PLUGIN_RESULT_SCHEMA,
  assertPluginEngineCompatible,
  copyPluginDirectory,
  desiredPlugins,
  emptyPluginLock,
  hashPluginDirectory,
  invokePlugin,
  isPluginTrusted,
  loadPluginManifest,
  org2PluginHome,
  org2PluginLockPath,
  org2PluginStorePath,
  pluginEntryPath,
  readPluginLock,
  readPluginTrust,
  trustPluginContentHash,
  untrustPluginContentHash,
  verifyPluginStore,
  writeJSONAtomic,
  writePluginLock,
  type Org2PluginActionContext,
  type Org2PluginLock,
  type Org2PluginLockEntry,
} from "./pluginRuntime.js";
import { configFilePath, schemaMatches } from "./brandNames.js";

type ParsedPluginArgs = {
  positional: string[];
  flags: Map<string, string[]>;
  passthrough: string[];
};

type ResolvedPluginSource = {
  requestedSource: string;
  resolvedSource: string;
  ref?: string;
};

const HELP = `Celorga plugins

Usage:
  celorga plugin list [--dir CORPUS] [--json]
  celorga plugin init [--apply] [--dir CORPUS]
  celorga plugin add GIT_SOURCE [--ref REF] [--subdir PATH] [--trust] [--apply] [--dir CORPUS]
  celorga plugin remove PLUGIN_ID [--apply] [--dir CORPUS]
  celorga plugin update [PLUGIN_ID] [--trust] [--apply] [--dir CORPUS]
  celorga plugin sync [--apply] [--dir CORPUS]
  celorga plugin trust PLUGIN_ID [--revoke] [--apply] [--dir CORPUS]
  celorga plugin doctor [--dir CORPUS] [--json]
  celorga plugin exec PLUGIN_ID COMMAND_ID [--dir CORPUS] -- [ARG ...]
  celorga plugin template PLUGIN_ID:TEMPLATE_ID --out FILE [--apply] [--force] [--dir CORPUS]
  celorga plugin actions [--context note|heading|thread|run|approval] [--dir CORPUS] [--json]
  celorga plugin action run PLUGIN_ID:ACTION_ID --context note|heading --file FILE [--line N] [--apply] [--json]
  celorga plugin action run PLUGIN_ID:ACTION_ID --context thread --thread ID | --context run|approval --run ID [--approval ID]
  celorga plugin proposals list [--status pending|applied|dismissed] [--json]
  celorga plugin proposals show|apply|dismiss PROPOSAL_ID [--only N[,N]] [--actor NAME] [--apply] [--json]
  celorga plugin hooks list [--json]
  celorga plugin hooks dispatch [--since ISO|DURATION] [--follow] [--apply] [--json]

Sources:
  github:OWNER/REPOSITORY
  https://github.com/OWNER/REPOSITORY.git
  ssh://git@example.com/path/repository.git
  git@example.com:path/repository.git
  file:///path/to/repository or a local Git checkout

Actions and hooks never write the corpus directly. They receive the selected
note, heading, thread, run, approval, or lifecycle event as JSON, run under a
macOS sandbox that denies corpus writes (and corpus reads or network unless
the manifest requests read-corpus or network), and return proposals that stay
pending under .org2/plugin-proposals/ until a person applies them.

Source intent lives in celorga.json. org2.plugins.lock.json pins an exact Git
commit and SHA-256 content hash. sync reproduces the lock without moving refs;
update is the explicit operation that advances mutable refs. Plugin code runs
only after its exact content hash is trusted on the current machine.`;

function parseArgs(args: string[]): ParsedPluginArgs {
  const delimiter = args.indexOf("--");
  const own = delimiter >= 0 ? args.slice(0, delimiter) : args;
  const passthrough = delimiter >= 0 ? args.slice(delimiter + 1) : [];
  const positional: string[] = [];
  const flags = new Map<string, string[]>();
  for (let index = 0; index < own.length; index += 1) {
    const argument = own[index]!;
    if (!argument.startsWith("--")) {
      positional.push(argument);
      continue;
    }
    const equal = argument.indexOf("=");
    const name = equal >= 0 ? argument.slice(2, equal) : argument.slice(2);
    const explicit = equal >= 0 ? argument.slice(equal + 1) : undefined;
    const next = own[index + 1];
    const value = explicit ?? (next && !next.startsWith("--") ? own[++index]! : "true");
    flags.set(name, [...(flags.get(name) || []), value]);
  }
  return { positional, flags, passthrough };
}

function flag(parsed: ParsedPluginArgs, name: string): string | undefined {
  return parsed.flags.get(name)?.at(-1);
}

function enabled(parsed: ParsedPluginArgs, name: string): boolean {
  return parsed.flags.has(name);
}

function required(value: string | undefined, message: string): string {
  const text = String(value || "").trim();
  if (!text) throw new Error(message);
  return text;
}

function corpusRoot(parsed: ParsedPluginArgs): string {
  return path.resolve(flag(parsed, "dir") || ".");
}

function configPath(corpus: string): string {
  const file = configFilePath(corpus);
  if (!fs.existsSync(file)) throw new Error(`plugin commands require ${file}`);
  return file;
}

function output(parsed: ParsedPluginArgs, value: unknown, text: string): void {
  if (enabled(parsed, "json") || flag(parsed, "format") === "json") process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  else process.stdout.write(`${text}\n`);
}

function sourceKey(source: Pick<Org2PluginConfig, "source" | "ref" | "subdir">): string {
  return [source.source, source.ref || "", source.subdir || ""].join("\0");
}

function sanitizedSource(source: string): string {
  const trimmed = source.trim();
  if (/^github:/i.test(trimmed)) return trimmed;
  if (/^(?:https?|ssh|git|file):/i.test(trimmed.replace(/^git\+/, ""))) {
    const normalized = trimmed.replace(/^git\+/, "");
    if (/^(?:https?|ssh|file):/i.test(normalized)) {
      const url = new URL(normalized);
      if (url.username || url.password) throw new Error("plugin source URLs may not contain credentials");
    }
  }
  return trimmed;
}

export function resolvePluginSource(source: string, explicitRef?: string): ResolvedPluginSource {
  const sanitized = sanitizedSource(required(source, "plugin source is required"));
  let requestedSource = sanitized;
  let ref = String(explicitRef || "").trim() || undefined;
  if (/^github:/i.test(sanitized)) {
    const match = /^github:([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:#(.+))?$/.exec(sanitized);
    if (!match) throw new Error("GitHub shorthand must be github:OWNER/REPOSITORY");
    const owner = match[1]!;
    const repository = match[2]!.replace(/\.git$/i, "");
    if (match[3] && ref) throw new Error("specify a plugin ref either in the source fragment or --ref, not both");
    ref = ref || match[3];
    requestedSource = `github:${owner}/${repository}`;
    return { requestedSource, resolvedSource: `https://github.com/${owner}/${repository}.git`, ...(ref ? { ref } : {}) };
  }
  if (sanitized.startsWith("file://")) {
    const resolvedSource = path.resolve(fileURLToPath(sanitized));
    return { requestedSource: sanitized, resolvedSource, ...(ref ? { ref } : {}) };
  }
  if (fs.existsSync(path.resolve(sanitized))) {
    const resolvedSource = path.resolve(sanitized);
    return { requestedSource: sanitized, resolvedSource, ...(ref ? { ref } : {}) };
  }
  const sourceWithoutGitPrefix = sanitized.replace(/^git\+/, "");
  if (/^https?:/i.test(sourceWithoutGitPrefix)) {
    const url = new URL(sourceWithoutGitPrefix);
    if (url.hash) {
      if (ref) throw new Error("specify a plugin ref either in the source fragment or --ref, not both");
      ref = decodeURIComponent(url.hash.slice(1));
      url.hash = "";
    }
    requestedSource = url.toString();
    return { requestedSource, resolvedSource: url.toString(), ...(ref ? { ref } : {}) };
  }
  return { requestedSource: sanitized, resolvedSource: sourceWithoutGitPrefix, ...(ref ? { ref } : {}) };
}

function git(args: string[], cwd?: string): string {
  const child = spawnSync("git", args, {
    ...(cwd ? { cwd } : {}),
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_LFS_SKIP_SMUDGE: "1" },
    encoding: "utf8",
    timeout: 120_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (child.error) throw child.error;
  if (child.status !== 0) {
    const detail = String(child.stderr || child.stdout || "").trim().slice(0, 2_000);
    throw new Error(`git ${args[0] || "command"} failed${detail ? `: ${detail}` : ""}`);
  }
  return String(child.stdout || "").trim();
}

function gitBuffer(args: string[], cwd?: string, maxBuffer: number = 128 * 1024 * 1024): Buffer {
  const child = spawnSync("git", args, {
    ...(cwd ? { cwd } : {}),
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_LFS_SKIP_SMUDGE: "1" },
    encoding: "buffer",
    timeout: 120_000,
    maxBuffer,
  });
  if (child.error) throw child.error;
  if (child.status !== 0) {
    const detail = Buffer.from(child.stderr || child.stdout || "").toString("utf8").trim().slice(0, 2_000);
    throw new Error(`git ${args[0] || "command"} failed${detail ? `: ${detail}` : ""}`);
  }
  return Buffer.from(child.stdout || "");
}

function resolveRevision(repository: string, requestedRef?: string): string {
  if (!requestedRef) return git(["rev-parse", "HEAD^{commit}"], repository).toLowerCase();
  for (const candidate of [requestedRef, `origin/${requestedRef}`]) {
    const child = spawnSync("git", ["rev-parse", "--verify", `${candidate}^{commit}`], {
      cwd: repository,
      env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
      encoding: "utf8",
      timeout: 30_000,
    });
    if (child.status === 0) return String(child.stdout || "").trim().toLowerCase();
  }
  throw new Error(`plugin Git ref was not found: ${requestedRef}`);
}

function normalizedPluginSubdir(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const normalized = value.replace(/\\/g, "/").replace(/^\.\//, "").replace(/\/$/, "");
  if (!normalized || normalized === "." || path.posix.isAbsolute(normalized) || normalized.split("/").includes("..")) {
    throw new Error("plugin subdir must name a directory inside the Git repository");
  }
  return normalized;
}

function materializeGitTree(repository: string, revision: string, subdir: string | undefined, destination: string): void {
  const pathspec = subdir ? ["--", subdir] : [];
  const listing = gitBuffer(["ls-tree", "-r", "-z", "--full-tree", revision, ...pathspec], repository, 16 * 1024 * 1024).toString("utf8");
  const entries = listing.split("\0").filter(Boolean);
  if (!entries.length) throw new Error(subdir ? `plugin subdir does not exist at ${revision}: ${subdir}` : `plugin Git tree is empty at ${revision}`);
  if (entries.length > 10_000) throw new Error("plugin package exceeds 10000 files");
  fs.mkdirSync(destination, { recursive: true });
  let totalBytes = 0;
  for (const record of entries) {
    const match = /^(\d{6}) (\w+) ([a-f0-9]{40,64})\t([\s\S]+)$/.exec(record);
    if (!match) throw new Error("plugin Git tree contains an unsupported entry");
    const [, mode, type, object, repositoryPath] = match;
    if (type !== "blob" || mode === "120000") throw new Error(`plugin packages may not contain links or submodules: ${repositoryPath}`);
    if (mode !== "100644" && mode !== "100755") throw new Error(`plugin package contains unsupported Git mode ${mode}: ${repositoryPath}`);
    const relative = subdir ? path.posix.relative(subdir, repositoryPath!) : repositoryPath!;
    if (!relative || relative.startsWith("../") || path.posix.isAbsolute(relative)) throw new Error(`plugin Git path escapes its package: ${repositoryPath}`);
    if (relative.split("/").includes(".git") || path.posix.basename(relative) === ".DS_Store") continue;
    const output = path.join(destination, ...relative.split("/"));
    const prefix = destination.endsWith(path.sep) ? destination : `${destination}${path.sep}`;
    if (!output.startsWith(prefix)) throw new Error(`plugin Git path escapes its package: ${repositoryPath}`);
    const contents = gitBuffer(["cat-file", "blob", object!], repository, 64 * 1024 * 1024 + 1);
    totalBytes += contents.byteLength;
    if (totalBytes > 64 * 1024 * 1024) throw new Error("plugin package exceeds 67108864 bytes");
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.writeFileSync(output, contents, { mode: mode === "100755" ? 0o755 : 0o644 });
  }
}

function installPluginPackage(packageRoot: string, contentHash: string): string {
  const destination = org2PluginStorePath(contentHash);
  if (fs.existsSync(destination)) {
    const actual = hashPluginDirectory(destination);
    if (actual !== contentHash) throw new Error(`plugin store entry ${destination} was modified (${actual})`);
    return destination;
  }
  const store = path.dirname(destination);
  fs.mkdirSync(store, { recursive: true });
  const temporary = path.join(store, `.install-${process.pid}-${crypto.randomUUID()}`);
  try {
    copyPluginDirectory(packageRoot, temporary);
    const copiedHash = hashPluginDirectory(temporary);
    if (copiedHash !== contentHash) throw new Error(`plugin copy hash changed from ${contentHash} to ${copiedHash}`);
    fs.renameSync(temporary, destination);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
  return destination;
}

function validateManifestEntries(packageRoot: string, manifest: ReturnType<typeof loadPluginManifest>): void {
  for (const command of manifest.contributes?.commands || []) pluginEntryPath(packageRoot, command.entry);
  for (const renderer of manifest.contributes?.renderers || []) pluginEntryPath(packageRoot, renderer.entry);
  for (const template of manifest.contributes?.templates || []) pluginEntryPath(packageRoot, template.path);
  for (const surface of manifest.contributes?.surfaces || []) pluginEntryPath(packageRoot, surface.entry);
}

export function resolveGitPlugin(
  desired: Org2PluginConfig,
  opts: { install?: boolean; lockedResolvedSource?: string } = {},
): Org2PluginLockEntry {
  const source = resolvePluginSource(desired.source, desired.ref);
  const resolvedSource = opts.lockedResolvedSource || source.resolvedSource;
  const subdir = normalizedPluginSubdir(desired.subdir);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "org2-plugin-resolve-"));
  const repository = path.join(temporary, "repository");
  const packageRoot = path.join(temporary, "package");
  try {
    git(["clone", "--quiet", "--no-checkout", resolvedSource, repository]);
    const revision = resolveRevision(repository, source.ref);
    materializeGitTree(repository, revision, subdir, packageRoot);
    const manifest = loadPluginManifest(packageRoot);
    assertPluginEngineCompatible(manifest);
    validateManifestEntries(packageRoot, manifest);
    const contentHash = hashPluginDirectory(packageRoot);
    if (opts.install) installPluginPackage(packageRoot, contentHash);
    return {
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      source: source.requestedSource,
      resolvedSource,
      ...(source.ref ? { ref: source.ref } : {}),
      ...(subdir ? { subdir } : {}),
      revision,
      contentHash,
      manifest,
    };
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function materializeLockedPlugin(entry: Org2PluginLockEntry, apply: boolean): { changed: boolean; root: string } {
  const status = verifyPluginStore(entry);
  if (status.valid) return { changed: false, root: status.root };
  if (!apply) return { changed: true, root: status.root };
  const resolved = resolveGitPlugin(
    { source: entry.source, ref: entry.revision, ...(entry.subdir ? { subdir: entry.subdir } : {}) },
    { install: true, lockedResolvedSource: entry.resolvedSource },
  );
  if (resolved.revision !== entry.revision || resolved.contentHash !== entry.contentHash || resolved.id !== entry.id) {
    throw new Error(`locked plugin ${entry.id} did not reproduce its commit and content hash`);
  }
  return { changed: true, root: org2PluginStorePath(entry.contentHash) };
}

function writeConfigPlugins(corpus: string, plugins: Org2PluginConfig[]): void {
  const file = configPath(corpus);
  const config = loadConfig(file) as Org2Config;
  if (plugins.length) config.plugins = plugins;
  else delete config.plugins;
  writeJSONAtomic(file, config);
}

function pluginStatuses(corpus: string): Array<Record<string, unknown>> {
  const desired = desiredPlugins(corpus);
  const lock = readPluginLock(corpus);
  const trust = readPluginTrust();
  return lock.plugins.map((entry) => {
    const store = verifyPluginStore(entry);
    let compatibilityIssue: string | undefined;
    try {
      assertPluginEngineCompatible(entry.manifest);
    } catch (error) {
      compatibilityIssue = error instanceof Error ? error.message : String(error);
    }
    return {
      id: entry.id,
      name: entry.name,
      version: entry.version,
      source: entry.source,
      ...(entry.ref ? { ref: entry.ref } : {}),
      ...(entry.subdir ? { subdir: entry.subdir } : {}),
      revision: entry.revision,
      contentHash: entry.contentHash,
      desired: desired.some((item) => sourceKey(item) === sourceKey(entry)),
      installed: store.valid,
      trusted: isPluginTrusted(entry.contentHash, trust),
      compatible: !compatibilityIssue,
      contributions: {
        commands: entry.manifest.contributes?.commands?.map((item) => item.id) || [],
        renderers: entry.manifest.contributes?.renderers?.map((item) => ({ id: item.id, languages: item.languages })) || [],
        templates: entry.manifest.contributes?.templates?.map((item) => item.id) || [],
        ...(entry.manifest.contributes?.actions?.length ? { actions: entry.manifest.contributes.actions.map((item) => ({ id: item.id, contexts: item.contexts })) } : {}),
        ...(entry.manifest.contributes?.hooks?.length ? { hooks: entry.manifest.contributes.hooks.map((item) => ({ id: item.id, events: item.events })) } : {}),
        ...(entry.manifest.contributes?.surfaces?.length ? { surfaces: entry.manifest.contributes.surfaces.map((item) => ({ id: item.id, title: item.title })) } : {}),
      },
      ...(store.issue ? { issue: store.issue } : {}),
      ...(compatibilityIssue ? { compatibilityIssue } : {}),
    };
  });
}

function doctor(corpus: string): { ok: boolean; issues: Array<{ severity: "warning" | "error"; pluginId?: string; message: string }>; plugins: Array<Record<string, unknown>> } {
  const desired = desiredPlugins(corpus);
  const lock = readPluginLock(corpus);
  const plugins = pluginStatuses(corpus);
  const issues: Array<{ severity: "warning" | "error"; pluginId?: string; message: string }> = [];
  for (const item of desired) {
    if (!lock.plugins.some((entry) => sourceKey(entry) === sourceKey(item))) issues.push({ severity: "error", message: `plugin source is not locked: ${item.source}` });
  }
  for (const entry of lock.plugins) {
    const status = plugins.find((item) => item.id === entry.id)!;
    if (!status.desired) issues.push({ severity: "warning", pluginId: entry.id, message: "plugin is locked but no longer declared in celorga.json" });
    if (!status.installed) issues.push({ severity: "error", pluginId: entry.id, message: String(status.issue || "plugin is not installed") });
    if (!status.trusted) issues.push({ severity: "warning", pluginId: entry.id, message: "content hash is not trusted on this machine" });
    if (!status.compatible) issues.push({ severity: "error", pluginId: entry.id, message: String(status.compatibilityIssue) });
  }
  const languageOwner = new Map<string, string>();
  for (const entry of lock.plugins) {
    for (const renderer of entry.manifest.contributes?.renderers || []) {
      for (const language of renderer.languages) {
        const owner = languageOwner.get(language);
        if (owner) issues.push({ severity: "error", pluginId: entry.id, message: `renderer language ${language} is already claimed by ${owner}` });
        else languageOwner.set(language, `${entry.id}:${renderer.id}`);
      }
    }
  }
  return { ok: !issues.some((issue) => issue.severity === "error"), issues, plugins };
}

function updateLock(corpus: string, selectedId: string | undefined, apply: boolean): Org2PluginLock {
  const desired = desiredPlugins(corpus);
  const current = readPluginLock(corpus);
  const currentBySource = new Map(current.plugins.map((entry) => [sourceKey(entry), entry]));
  const next: Org2PluginLockEntry[] = [];
  for (const item of desired) {
    const existing = currentBySource.get(sourceKey(item));
    if (selectedId && existing?.id !== selectedId) {
      if (existing) next.push(existing);
      else throw new Error(`cannot update ${selectedId}: another declared plugin is not locked`);
      continue;
    }
    next.push(resolveGitPlugin(item, { install: apply }));
  }
  if (selectedId && !next.some((entry) => entry.id === selectedId)) throw new Error(`plugin is not declared: ${selectedId}`);
  const lock = { $schema: ORG2_PLUGIN_LOCK_SCHEMA, plugins: next } satisfies Org2PluginLock;
  if (apply) writePluginLock(corpus, lock);
  return lock;
}

function selectLockEntry(corpus: string, id: string): Org2PluginLockEntry {
  const normalized = id.trim().toLowerCase();
  const entry = readPluginLock(corpus).plugins.find((candidate) => candidate.id === normalized);
  if (!entry) throw new Error(`plugin is not locked: ${id}`);
  return entry;
}

function safeOutputPath(corpus: string, requested: string): string {
  const root = path.resolve(corpus);
  const output = path.resolve(root, requested);
  const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
  if (output !== root && !output.startsWith(prefix)) throw new Error("plugin template output must stay inside the corpus");
  return output;
}

export async function runPluginCommand(args: string[]): Promise<boolean> {
  if (!args.length || !["plugin", "plugins"].includes(args[0] || "")) return false;
  const parsed = parseArgs(args.slice(1));
  const action = parsed.positional[0] || "list";
  if (action === "help" || enabled(parsed, "help") || enabled(parsed, "h")) {
    process.stdout.write(`${HELP}\n`);
    return true;
  }
  const corpus = corpusRoot(parsed);
  configPath(corpus);

  if (action === "list") {
    const plugins = pluginStatuses(corpus);
    output(parsed, { $schema: "org2:plugin-list:v1", corpus, lockFile: org2PluginLockPath(corpus), pluginHome: org2PluginHome(), plugins }, plugins.length
      ? plugins.map((item) => `${item.id}\t${item.version}\t${item.installed ? "installed" : "missing"}\t${item.trusted ? "trusted" : "untrusted"}`).join("\n")
      : "No plugins declared");
    return true;
  }

  if (action === "doctor") {
    const result = doctor(corpus);
    output(parsed, { $schema: "org2:plugin-doctor:v1", corpus, ...result }, result.ok && !result.issues.length
      ? "Plugin environment is healthy"
      : result.issues.map((issue) => `${issue.severity}: ${issue.pluginId ? `${issue.pluginId}: ` : ""}${issue.message}`).join("\n"));
    if (!result.ok) process.exitCode = 1;
    return true;
  }

  if (action === "add") {
    const source = required(parsed.positional[1], "plugin add requires a Git source");
    const desired: Org2PluginConfig = {
      source,
      ...(flag(parsed, "ref") ? { ref: flag(parsed, "ref") } : {}),
      ...(flag(parsed, "subdir") ? { subdir: flag(parsed, "subdir") } : {}),
    };
    const apply = enabled(parsed, "apply");
    const resolved = resolveGitPlugin(desired, { install: apply });
    const currentDesired = desiredPlugins(corpus);
    const currentLock = readPluginLock(corpus);
    if (currentDesired.some((item) => sourceKey(item) === sourceKey(resolved))) throw new Error(`plugin source is already declared: ${resolved.source}`);
    if (currentLock.plugins.some((entry) => entry.id === resolved.id)) throw new Error(`plugin id is already locked: ${resolved.id}`);
    const normalizedDesired: Org2PluginConfig = {
      source: resolved.source,
      ...(resolved.ref ? { ref: resolved.ref } : {}),
      ...(resolved.subdir ? { subdir: resolved.subdir } : {}),
    };
    const lock = { ...currentLock, plugins: [...currentLock.plugins, resolved] } satisfies Org2PluginLock;
    if (apply) {
      writeConfigPlugins(corpus, [...currentDesired, normalizedDesired]);
      writePluginLock(corpus, lock);
      if (enabled(parsed, "trust")) trustPluginContentHash(resolved.contentHash);
    }
    output(parsed, {
      $schema: "org2:plugin-change:v1",
      action: "add",
      applied: apply,
      plugin: resolved,
      trusted: apply && enabled(parsed, "trust"),
      configFile: configPath(corpus),
      lockFile: org2PluginLockPath(corpus),
    }, `${apply ? "added" : "would add"} ${resolved.id}@${resolved.version} ${resolved.revision.slice(0, 12)} (${resolved.contentHash})${apply && enabled(parsed, "trust") ? " and trusted" : ""}`);
    return true;
  }

  if (action === "remove") {
    const id = required(parsed.positional[1], "plugin remove requires a plugin id").toLowerCase();
    const apply = enabled(parsed, "apply");
    const lock = readPluginLock(corpus);
    const entry = selectLockEntry(corpus, id);
    const desired = desiredPlugins(corpus);
    const nextDesired = desired.filter((item) => sourceKey(item) !== sourceKey(entry));
    const nextLock = { ...lock, plugins: lock.plugins.filter((item) => item.id !== id) } satisfies Org2PluginLock;
    if (apply) {
      writeConfigPlugins(corpus, nextDesired);
      writePluginLock(corpus, nextLock);
    }
    output(parsed, { $schema: "org2:plugin-change:v1", action: "remove", applied: apply, plugin: entry, storeRetained: true }, `${apply ? "removed" : "would remove"} ${id}; immutable store content is retained for other corpora`);
    return true;
  }

  if (action === "update") {
    const id = parsed.positional[1]?.toLowerCase();
    const apply = enabled(parsed, "apply");
    const lock = updateLock(corpus, id, apply);
    if (apply && enabled(parsed, "trust")) {
      for (const entry of lock.plugins.filter((item) => !id || item.id === id)) trustPluginContentHash(entry.contentHash);
    }
    output(parsed, { $schema: "org2:plugin-change:v1", action: "update", applied: apply, plugins: lock.plugins }, `${apply ? "updated" : "would update"} ${id || `${lock.plugins.length} plugins`}${apply && enabled(parsed, "trust") ? " and trusted new content" : ""}`);
    return true;
  }

  if (action === "sync") {
    const apply = enabled(parsed, "apply");
    const desired = desiredPlugins(corpus);
    const lock = readPluginLock(corpus);
    if (desired.length && !lock.plugins.length) throw new Error("plugins are declared but no lock exists; run celorga plugin update --apply");
    const plugins = lock.plugins.map((entry) => ({ id: entry.id, ...materializeLockedPlugin(entry, apply) }));
    output(parsed, { $schema: "org2:plugin-sync:v1", applied: apply, plugins }, plugins.some((item) => item.changed)
      ? `${apply ? "materialized" : "would materialize"} ${plugins.filter((item) => item.changed).map((item) => item.id).join(", ")}`
      : "All locked plugins are installed");
    return true;
  }

  if (action === "trust") {
    const id = required(parsed.positional[1], "plugin trust requires a plugin id").toLowerCase();
    const entry = selectLockEntry(corpus, id);
    const apply = enabled(parsed, "apply");
    const revoke = enabled(parsed, "revoke");
    if (apply) {
      if (revoke) untrustPluginContentHash(entry.contentHash);
      else trustPluginContentHash(entry.contentHash);
    }
    const verb = revoke ? "untrust" : "trust";
    output(parsed, { $schema: "org2:plugin-trust-change:v1", applied: apply, revoked: revoke, pluginId: id, contentHash: entry.contentHash }, `${apply ? `${verb}ed` : `would ${verb}`} ${id} at ${entry.contentHash}`);
    return true;
  }

  if (action === "exec") {
    const id = required(parsed.positional[1], "plugin exec requires a plugin id").toLowerCase();
    const commandId = required(parsed.positional[2], "plugin exec requires a command id").toLowerCase();
    const entry = selectLockEntry(corpus, id);
    const command = entry.manifest.contributes?.commands?.find((item) => item.id === commandId);
    if (!command) throw new Error(`plugin ${id} does not contribute command ${commandId}`);
    const result = invokePlugin(entry, command.entry, {
      $schema: ORG2_PLUGIN_INVOCATION_SCHEMA,
      kind: "command",
      plugin: { id: entry.id, version: entry.version, contentHash: entry.contentHash },
      contribution: { id: command.id },
      corpusRoot: corpus,
      cwd: process.cwd(),
      arguments: parsed.passthrough,
    });
    if (!schemaMatches(result.$schema, ORG2_PLUGIN_RESULT_SCHEMA)) throw new Error(`plugin command must return ${ORG2_PLUGIN_RESULT_SCHEMA}`);
    if (result.ok !== true) throw new Error(typeof result.error === "string" ? result.error : `plugin command ${id}:${commandId} failed`);
    output(parsed, result, typeof result.text === "string" ? result.text : JSON.stringify(result.data ?? result, null, 2));
    return true;
  }

  if (action === "template") {
    const selector = required(parsed.positional[1], "plugin template requires PLUGIN_ID:TEMPLATE_ID");
    const separator = selector.indexOf(":");
    if (separator < 1) throw new Error("plugin template selector must be PLUGIN_ID:TEMPLATE_ID");
    const id = selector.slice(0, separator).toLowerCase();
    const templateId = selector.slice(separator + 1).toLowerCase();
    const entry = selectLockEntry(corpus, id);
    if (!isPluginTrusted(entry.contentHash)) throw new Error(`plugin ${id} is not trusted on this machine`);
    const installed = verifyPluginStore(entry);
    if (!installed.valid) throw new Error(`plugin ${id} is unavailable: ${installed.issue}`);
    const template = entry.manifest.contributes?.templates?.find((item) => item.id === templateId);
    if (!template) throw new Error(`plugin ${id} does not contribute template ${templateId}`);
    const source = pluginEntryPath(installed.root, template.path);
    const destination = safeOutputPath(corpus, required(flag(parsed, "out"), "plugin template requires --out FILE"));
    if (fs.existsSync(destination) && !enabled(parsed, "force")) throw new Error(`template output already exists: ${destination}; pass --force to replace it`);
    const apply = enabled(parsed, "apply");
    if (apply) {
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      const temporary = `${destination}.${process.pid}.${crypto.randomUUID()}.tmp`;
      fs.copyFileSync(source, temporary);
      fs.renameSync(temporary, destination);
    }
    output(parsed, { $schema: "org2:plugin-template:v1", applied: apply, pluginId: id, templateId, source, destination }, `${apply ? "created" : "would create"} ${path.relative(corpus, destination)}`);
    return true;
  }

  if (action === "actions") {
    const context = flag(parsed, "context");
    if (context && !(ORG2_PLUGIN_ACTION_CONTEXTS as readonly string[]).includes(context)) throw new Error(`--context must be one of ${ORG2_PLUGIN_ACTION_CONTEXTS.join(", ")}`);
    const actions = listPluginActions(corpus, context as Org2PluginActionContext | undefined);
    output(parsed, { $schema: ORG2_PLUGIN_ACTION_LIST_SCHEMA, actions, hooks: listPluginHooks(corpus), sandbox: pluginSandboxAvailable() ? "macos-sandbox-exec" : "none" }, actions.length
      ? actions.map((item) => `${item.id}\t${item.contexts.join(",")}\t${item.trusted ? "trusted" : "untrusted"}\t${item.title}`).join("\n")
      : "No plugin actions");
    return true;
  }

  if (action === "action") {
    const sub = parsed.positional[1];
    if (sub !== "run") throw new Error("usage: celorga plugin action run PLUGIN_ID:ACTION_ID --context KIND ...");
    const selector = required(parsed.positional[2], "plugin action run requires PLUGIN_ID:ACTION_ID");
    const kind = required(flag(parsed, "context"), "--context is required");
    if (!(ORG2_PLUGIN_ACTION_CONTEXTS as readonly string[]).includes(kind)) throw new Error(`--context must be one of ${ORG2_PLUGIN_ACTION_CONTEXTS.join(", ")}`);
    const line = flag(parsed, "line");
    const ref: PluginActionContextRef = {
      kind: kind as Org2PluginActionContext,
      ...(flag(parsed, "file") ? { file: flag(parsed, "file") } : {}),
      ...(line ? { line: Number(line) } : {}),
      ...(flag(parsed, "thread") ? { threadId: flag(parsed, "thread") } : {}),
      ...(flag(parsed, "run") ? { runId: flag(parsed, "run") } : {}),
      ...(flag(parsed, "approval") ? { approvalId: flag(parsed, "approval") } : {}),
    };
    if (ref.line !== undefined && (!Number.isInteger(ref.line) || ref.line < 1)) throw new Error("--line must be a positive integer");
    const result = runPluginAction(corpus, selector, ref);
    if (enabled(parsed, "apply") && result.proposal) {
      const applied = applyPluginProposal(corpus, result.proposal.id, { apply: true, actor: flag(parsed, "actor") });
      output(parsed, { ...result, applied }, `${result.text ? `${result.text}\n` : ""}applied ${applied.changes.length} change(s) from proposal ${result.proposal.id}`);
      return true;
    }
    output(parsed, result, [
      result.text,
      result.proposal
        ? `proposal ${result.proposal.id}: ${result.proposal.proposals.length} change(s) pending review\n${result.proposal.proposals.map((change, index) => `  #${index} ${change.kind} ${"path" in change ? change.path : "threadId" in change ? change.threadId : change.runId}${change.summary ? ` — ${change.summary}` : ""}`).join("\n")}\nApply with: celorga plugin proposals apply ${result.proposal.id} --apply`
        : "no proposals",
    ].filter(Boolean).join("\n"));
    return true;
  }

  if (action === "proposals") {
    const sub = parsed.positional[1] || "list";
    if (sub === "list") {
      const status = flag(parsed, "status") as PluginProposalRecord["status"] | undefined;
      const proposals = listPluginProposals(corpus, status);
      output(parsed, { $schema: "org2:plugin-proposal-list:v1", proposals }, proposals.length
        ? proposals.map((item) => `${item.id}\t${item.status}\t${item.source.pluginId}:${item.source.contributionId}\t${item.proposals.length} change(s)\t${item.source.title}`).join("\n")
        : "No plugin proposals");
      return true;
    }
    const id = required(parsed.positional[2], `plugin proposals ${sub} requires a proposal id`);
    if (sub === "show") {
      const { record } = loadPluginProposal(corpus, id);
      output(parsed, record, JSON.stringify(record, null, 2));
      return true;
    }
    if (sub === "apply") {
      const only = (flag(parsed, "only") || "").split(",").map((item) => item.trim()).filter(Boolean).map(Number);
      if (only.some((item) => !Number.isInteger(item) || item < 0)) throw new Error("--only must list proposal change indexes");
      const result = applyPluginProposal(corpus, id, { apply: enabled(parsed, "apply"), actor: flag(parsed, "actor"), only });
      output(parsed, result, result.changes.map((change) => `#${change.index} ${change.ok ? "ok" : "blocked"} ${change.kind} ${change.target}: ${change.detail}${change.diff ? `\n${change.diff}` : ""}`).join("\n") + (result.applied ? `\napplied proposal ${id}` : `\npreview only; add --apply to apply proposal ${id}`));
      return true;
    }
    if (sub === "dismiss") {
      const result = dismissPluginProposal(corpus, id, { apply: enabled(parsed, "apply"), actor: flag(parsed, "actor") });
      output(parsed, result, `${result.applied ? "dismissed" : "would dismiss"} proposal ${id}`);
      return true;
    }
    throw new Error(`unknown plugin proposals action: ${sub}`);
  }

  if (action === "hooks") {
    const sub = parsed.positional[1] || "list";
    if (sub === "list") {
      const hooks = listPluginHooks(corpus);
      output(parsed, { $schema: "org2:plugin-hook-list:v1", hooks }, hooks.length
        ? hooks.map((item) => `${item.id}\t${item.events.join(",")}\t${item.trusted ? "trusted" : "untrusted"}`).join("\n")
        : "No plugin hooks");
      return true;
    }
    if (sub === "dispatch") {
      const apply = enabled(parsed, "apply");
      const json = enabled(parsed, "json") || flag(parsed, "format") === "json";
      if (enabled(parsed, "follow")) {
        if (!apply) throw new Error("hooks dispatch --follow requires --apply");
        const controller = new AbortController();
        const stop = () => controller.abort();
        process.once("SIGINT", stop);
        process.once("SIGTERM", stop);
        try {
          await followPluginHooks(corpus, (outcome) => process.stdout.write(json ? `${JSON.stringify(outcome)}\n` : `${outcome.ok ? "ok" : "error"}\t${outcome.eventType}\t${outcome.hook}\t${outcome.detail}\n`), { signal: controller.signal });
        } finally {
          process.off("SIGINT", stop);
          process.off("SIGTERM", stop);
        }
        return true;
      }
      const since = flag(parsed, "since");
      const result = dispatchPluginHooksOnce(corpus, { apply, ...(since ? { since: parseSince(since) } : {}) });
      output(parsed, { $schema: "org2:plugin-hook-dispatch:v1", applied: apply, ...result }, result.outcomes.length
        ? result.outcomes.map((outcome) => `${outcome.ok ? "ok" : "error"}\t${outcome.eventType}\t${outcome.hook}\t${outcome.detail}`).join("\n")
        : "No hook invocations");
      return true;
    }
    throw new Error(`unknown plugin hooks action: ${sub}`);
  }

  if (action === "init") {
    const apply = enabled(parsed, "apply");
    const lock = emptyPluginLock();
    if (apply && !fs.existsSync(org2PluginLockPath(corpus))) writePluginLock(corpus, lock);
    output(parsed, { $schema: "org2:plugin-change:v1", action: "init", applied: apply, lockFile: org2PluginLockPath(corpus), lock }, `${apply ? "initialized" : "would initialize"} ${org2PluginLockPath(corpus)}`);
    return true;
  }

  throw new Error(`unknown plugin action: ${action}\n\n${HELP}`);
}
