import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { DocumentNode, ListItemNode, Node, SrcBlockNode } from "./ast.js";
import { findConfigFile, loadConfig, type Org2PluginConfig } from "./config.js";
import { brandEnv, configFilePath, nameAliases, schemaMatches } from "./brandNames.js";

export const ORG2_PLUGIN_MANIFEST_SCHEMA = "org2:plugin-manifest:v1" as const;
export const ORG2_PLUGIN_LOCK_SCHEMA = "org2:plugin-lock:v1" as const;
export const ORG2_PLUGIN_TRUST_SCHEMA = "org2:plugin-trust:v1" as const;
export const ORG2_PLUGIN_INVOCATION_SCHEMA = "org2:plugin-invocation:v1" as const;
export const ORG2_PLUGIN_RESULT_SCHEMA = "org2:plugin-result:v1" as const;
export const ORG2_PLUGIN_RENDER_RESULT_SCHEMA = "org2:plugin-render-result:v1" as const;

export type Org2PluginCommandContribution = {
  id: string;
  description?: string;
  entry: string;
};

export type Org2PluginRendererContribution = {
  id: string;
  description?: string;
  languages: string[];
  entry: string;
};

export type Org2PluginTemplateContribution = {
  id: string;
  description?: string;
  path: string;
};

/** Selections a context-aware action can run against. */
export const ORG2_PLUGIN_ACTION_CONTEXTS = ["note", "heading", "thread", "run", "approval"] as const;
export type Org2PluginActionContext = (typeof ORG2_PLUGIN_ACTION_CONTEXTS)[number];

/**
 * Optional capabilities an action or hook may request. Corpus writes are never
 * a capability: actions and hooks return proposals that a person reviews.
 */
export const ORG2_PLUGIN_ACTION_CAPABILITIES = ["read-corpus", "network"] as const;
export type Org2PluginActionCapability = (typeof ORG2_PLUGIN_ACTION_CAPABILITIES)[number];

/** Lifecycle events a hook can subscribe to. */
export const ORG2_PLUGIN_HOOK_EVENTS = [
  "run.created",
  "run.running",
  "run.waiting-approval",
  "run.blocked",
  "run.completed",
  "run.failed",
  "run.canceled",
  "approval.requested",
  "approval.decided",
  "thread.reply-received",
  "thread.needs-you",
  "workflow.dispatched",
] as const;
export type Org2PluginHookEvent = (typeof ORG2_PLUGIN_HOOK_EVENTS)[number];

export type Org2PluginActionContribution = {
  id: string;
  title: string;
  description?: string;
  contexts: Org2PluginActionContext[];
  entry: string;
  capabilities?: Org2PluginActionCapability[];
};

/**
 * A workspace app surface: a sidebar entry whose page is rendered by the
 * plugin as sandboxed HTML. The entry returns org2:plugin-render-result:v1 and
 * runs under the same sandbox as actions; it never writes the corpus.
 */
export type Org2PluginSurfaceContribution = {
  id: string;
  title: string;
  description?: string;
  /** SF Symbol name shown in the app sidebar. */
  symbol?: string;
  entry: string;
  capabilities?: Org2PluginActionCapability[];
};

export type Org2PluginHookContribution = {
  id: string;
  description?: string;
  events: Org2PluginHookEvent[];
  entry: string;
  capabilities?: Org2PluginActionCapability[];
};

export type Org2PluginManifest = {
  $schema: typeof ORG2_PLUGIN_MANIFEST_SCHEMA;
  id: string;
  name: string;
  version: string;
  description?: string;
  engines?: { org2?: string };
  permissions?: { environment?: string[] };
  contributes?: {
    commands?: Org2PluginCommandContribution[];
    renderers?: Org2PluginRendererContribution[];
    templates?: Org2PluginTemplateContribution[];
    actions?: Org2PluginActionContribution[];
    hooks?: Org2PluginHookContribution[];
    surfaces?: Org2PluginSurfaceContribution[];
  };
};

export type Org2PluginLockEntry = {
  id: string;
  name: string;
  version: string;
  source: string;
  resolvedSource: string;
  ref?: string;
  subdir?: string;
  revision: string;
  contentHash: string;
  manifest: Org2PluginManifest;
};

export type Org2PluginLock = {
  $schema: typeof ORG2_PLUGIN_LOCK_SCHEMA;
  plugins: Org2PluginLockEntry[];
};

export type Org2PluginTrust = {
  $schema: typeof ORG2_PLUGIN_TRUST_SCHEMA;
  trustedContentHashes: string[];
};

export type Org2PluginRender = {
  pluginId: string;
  rendererId: string;
  language: string;
  html?: string;
  css?: string;
  script?: string;
  title?: string;
  height: number;
  error?: string;
  source: { line: number; endLine: number };
};

export type Org2PluginDiagnostic = {
  severity: "warning" | "error";
  pluginId?: string;
  message: string;
  line?: number;
};

const ID_PATTERN = /^[a-z0-9][a-z0-9.-]{0,127}$/;
const CONTRIBUTION_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const LANGUAGE_PATTERN = /^[a-z0-9][a-z0-9_+-]{0,63}$/;
const RESERVED_RENDERER_LANGUAGES = new Set(["chart", "plot"]);
const CONTENT_HASH_PATTERN = /^sha256:[a-f0-9]{64}$/;
const REVISION_PATTERN = /^[a-f0-9]{40,64}$/;
const MAX_PLUGIN_STDOUT_BYTES = 1_048_576;
const MAX_PLUGIN_PACKAGE_BYTES = 64 * 1024 * 1024;
const MAX_PLUGIN_PACKAGE_FILES = 10_000;

function expandHome(input: string): string {
  if (input === "~") return os.homedir();
  if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
  return input;
}

export function org2PluginHome(): string {
  const configured = String(brandEnv("ORG2_PLUGIN_HOME") || "").trim();
  if (configured) return path.resolve(expandHome(configured));
  return path.join(os.homedir(), ".org2", "plugins");
}

export function org2PluginLockPath(corpusRoot: string): string {
  return path.join(path.resolve(corpusRoot), "org2.plugins.lock.json");
}

export function org2PluginTrustPath(): string {
  return path.join(org2PluginHome(), "trust.json");
}

export function org2PluginStorePath(contentHash: string): string {
  if (!CONTENT_HASH_PATTERN.test(contentHash)) throw new Error(`invalid plugin content hash: ${contentHash}`);
  return path.join(org2PluginHome(), "store", contentHash.replace(":", "-"));
}

export function emptyPluginLock(): Org2PluginLock {
  return { $schema: ORG2_PLUGIN_LOCK_SCHEMA, plugins: [] };
}

export function readPluginLock(corpusRoot: string): Org2PluginLock {
  const file = org2PluginLockPath(corpusRoot);
  if (!fs.existsSync(file)) return emptyPluginLock();
  const value = JSON.parse(fs.readFileSync(file, "utf8")) as Partial<Org2PluginLock>;
  if (!schemaMatches(value.$schema, ORG2_PLUGIN_LOCK_SCHEMA) || !Array.isArray(value.plugins)) {
    throw new Error(`${file} must use ${ORG2_PLUGIN_LOCK_SCHEMA}`);
  }
  const plugins = value.plugins.map((entry, index) => validateLockEntry(entry, `plugins[${index}]`));
  const ids = new Set<string>();
  for (const entry of plugins) {
    if (ids.has(entry.id)) throw new Error(`${file} contains duplicate plugin id ${entry.id}`);
    ids.add(entry.id);
  }
  return { $schema: ORG2_PLUGIN_LOCK_SCHEMA, plugins };
}

export function readPluginTrust(): Org2PluginTrust {
  const file = org2PluginTrustPath();
  if (!fs.existsSync(file)) return { $schema: ORG2_PLUGIN_TRUST_SCHEMA, trustedContentHashes: [] };
  const value = JSON.parse(fs.readFileSync(file, "utf8")) as Partial<Org2PluginTrust>;
  if (!schemaMatches(value.$schema, ORG2_PLUGIN_TRUST_SCHEMA) || !Array.isArray(value.trustedContentHashes)) {
    throw new Error(`${file} must use ${ORG2_PLUGIN_TRUST_SCHEMA}`);
  }
  const trustedContentHashes = [...new Set(value.trustedContentHashes.map(String))].sort();
  for (const hash of trustedContentHashes) {
    if (!CONTENT_HASH_PATTERN.test(hash)) throw new Error(`${file} contains invalid content hash ${hash}`);
  }
  return { $schema: ORG2_PLUGIN_TRUST_SCHEMA, trustedContentHashes };
}

export function writeJSONAtomic(file: string, value: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${crypto.randomUUID()}.tmp`;
  const mode = fs.existsSync(file) ? fs.statSync(file).mode & 0o777 : 0o644;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", mode });
  fs.renameSync(temporary, file);
}

export function writePluginLock(corpusRoot: string, lock: Org2PluginLock): void {
  const plugins = lock.plugins.map((entry, index) => validateLockEntry(entry, `plugins[${index}]`));
  const ids = new Set<string>();
  for (const entry of plugins) {
    if (ids.has(entry.id)) throw new Error(`plugin lock contains duplicate plugin id ${entry.id}`);
    ids.add(entry.id);
  }
  writeJSONAtomic(org2PluginLockPath(corpusRoot), { $schema: ORG2_PLUGIN_LOCK_SCHEMA, plugins });
}

export function trustPluginContentHash(contentHash: string): Org2PluginTrust {
  if (!CONTENT_HASH_PATTERN.test(contentHash)) throw new Error(`invalid plugin content hash: ${contentHash}`);
  const current = readPluginTrust();
  const next = {
    $schema: ORG2_PLUGIN_TRUST_SCHEMA,
    trustedContentHashes: [...new Set([...current.trustedContentHashes, contentHash])].sort(),
  } satisfies Org2PluginTrust;
  writeJSONAtomic(org2PluginTrustPath(), next);
  return next;
}

export function untrustPluginContentHash(contentHash: string): Org2PluginTrust {
  if (!CONTENT_HASH_PATTERN.test(contentHash)) throw new Error(`invalid plugin content hash: ${contentHash}`);
  const current = readPluginTrust();
  const next = {
    $schema: ORG2_PLUGIN_TRUST_SCHEMA,
    trustedContentHashes: current.trustedContentHashes.filter((candidate) => candidate !== contentHash),
  } satisfies Org2PluginTrust;
  writeJSONAtomic(org2PluginTrustPath(), next);
  return next;
}

export function isPluginTrusted(contentHash: string, trust: Org2PluginTrust = readPluginTrust()): boolean {
  return trust.trustedContentHashes.includes(contentHash);
}

function requiredString(value: unknown, label: string): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) throw new Error(`${label} is required`);
  return text;
}

function optionalString(value: unknown): string | undefined {
  const text = typeof value === "string" ? value.trim() : "";
  return text || undefined;
}

function safeRelativePath(value: unknown, label: string): string {
  const text = requiredString(value, label).replace(/\\/g, "/");
  if (text === "." || path.posix.isAbsolute(text) || text.split("/").includes("..")) {
    throw new Error(`${label} must stay inside the plugin package`);
  }
  return text.replace(/^\.\//, "");
}

function safeProcessEntry(value: unknown, label: string): string {
  const entry = safeRelativePath(value, label);
  if (!/[.](?:c|m)?js$/i.test(entry)) throw new Error(`${label} must be a self-contained .js, .mjs, or .cjs entry`);
  return entry;
}

function contributionArray(value: unknown, label: string): Record<string, unknown>[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error(`${label} must be an array`);
  return value.map((item, index) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error(`${label}[${index}] must be an object`);
    return item as Record<string, unknown>;
  });
}

function assertOnlyKeys(value: Record<string, unknown>, allowed: readonly string[], label: string): void {
  const allowedSet = new Set(allowed);
  const unknown = Object.keys(value).filter((key) => !allowedSet.has(key));
  if (unknown.length) throw new Error(`${label} contains unsupported field${unknown.length === 1 ? "" : "s"}: ${unknown.join(", ")}`);
}

export function validatePluginManifest(value: unknown, label: string = "org2-plugin.json"): Org2PluginManifest {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const raw = value as Record<string, unknown>;
  assertOnlyKeys(raw, ["$schema", "id", "name", "version", "description", "engines", "permissions", "contributes"], label);
  if (!schemaMatches(raw.$schema, ORG2_PLUGIN_MANIFEST_SCHEMA)) throw new Error(`${label} must use ${ORG2_PLUGIN_MANIFEST_SCHEMA}`);
  const id = requiredString(raw.id, `${label}.id`).toLowerCase();
  if (!ID_PATTERN.test(id)) throw new Error(`${label}.id must match ${ID_PATTERN}`);
  const name = requiredString(raw.name, `${label}.name`);
  const version = requiredString(raw.version, `${label}.version`);
  const rawContributes = raw.contributes;
  if (rawContributes !== undefined && (!rawContributes || typeof rawContributes !== "object" || Array.isArray(rawContributes))) {
    throw new Error(`${label}.contributes must be an object`);
  }
  const contributesRecord = (rawContributes || {}) as Record<string, unknown>;
  assertOnlyKeys(contributesRecord, ["commands", "renderers", "templates", "actions", "hooks", "surfaces"], `${label}.contributes`);
  const seen = new Set<string>();
  const commands = contributionArray(contributesRecord.commands, `${label}.contributes.commands`).map((item, index) => {
    assertOnlyKeys(item, ["id", "description", "entry"], `${label}.contributes.commands[${index}]`);
    const contributionId = requiredString(item.id, `${label}.contributes.commands[${index}].id`).toLowerCase();
    if (!CONTRIBUTION_ID_PATTERN.test(contributionId)) throw new Error(`invalid command id ${contributionId}`);
    if (seen.has(`command:${contributionId}`)) throw new Error(`duplicate command id ${contributionId}`);
    seen.add(`command:${contributionId}`);
    return {
      id: contributionId,
      ...(optionalString(item.description) ? { description: optionalString(item.description) } : {}),
      entry: safeProcessEntry(item.entry, `${label}.contributes.commands[${index}].entry`),
    };
  });
  const renderers = contributionArray(contributesRecord.renderers, `${label}.contributes.renderers`).map((item, index) => {
    assertOnlyKeys(item, ["id", "description", "languages", "entry"], `${label}.contributes.renderers[${index}]`);
    const contributionId = requiredString(item.id, `${label}.contributes.renderers[${index}].id`).toLowerCase();
    if (!CONTRIBUTION_ID_PATTERN.test(contributionId)) throw new Error(`invalid renderer id ${contributionId}`);
    if (seen.has(`renderer:${contributionId}`)) throw new Error(`duplicate renderer id ${contributionId}`);
    seen.add(`renderer:${contributionId}`);
    if (!Array.isArray(item.languages) || item.languages.length === 0) throw new Error(`renderer ${contributionId} requires languages`);
    const languages = [...new Set(item.languages.map((language) => requiredString(language, `renderer ${contributionId} language`).toLowerCase()))];
    for (const language of languages) {
      if (!LANGUAGE_PATTERN.test(language)) throw new Error(`invalid renderer language ${language}`);
      if (RESERVED_RENDERER_LANGUAGES.has(language)) throw new Error(`renderer language ${language} is reserved by the Celorga runtime`);
    }
    return {
      id: contributionId,
      ...(optionalString(item.description) ? { description: optionalString(item.description) } : {}),
      languages,
      entry: safeProcessEntry(item.entry, `${label}.contributes.renderers[${index}].entry`),
    };
  });
  const templates = contributionArray(contributesRecord.templates, `${label}.contributes.templates`).map((item, index) => {
    assertOnlyKeys(item, ["id", "description", "path"], `${label}.contributes.templates[${index}]`);
    const contributionId = requiredString(item.id, `${label}.contributes.templates[${index}].id`).toLowerCase();
    if (!CONTRIBUTION_ID_PATTERN.test(contributionId)) throw new Error(`invalid template id ${contributionId}`);
    if (seen.has(`template:${contributionId}`)) throw new Error(`duplicate template id ${contributionId}`);
    seen.add(`template:${contributionId}`);
    return {
      id: contributionId,
      ...(optionalString(item.description) ? { description: optionalString(item.description) } : {}),
      path: safeRelativePath(item.path, `${label}.contributes.templates[${index}].path`),
    };
  });
  const capabilityList = (value: unknown, itemLabel: string): Org2PluginActionCapability[] => {
    if (value === undefined) return [];
    if (!Array.isArray(value)) throw new Error(`${itemLabel}.capabilities must be an array`);
    const result = [...new Set(value.map((item) => requiredString(item, `${itemLabel} capability`).toLowerCase()))];
    for (const capability of result) {
      if (!(ORG2_PLUGIN_ACTION_CAPABILITIES as readonly string[]).includes(capability)) {
        throw new Error(`${itemLabel} requests unsupported capability ${capability}; corpus writes are proposals, never a capability`);
      }
    }
    return result as Org2PluginActionCapability[];
  };
  const actions = contributionArray(contributesRecord.actions, `${label}.contributes.actions`).map((item, index) => {
    const itemLabel = `${label}.contributes.actions[${index}]`;
    assertOnlyKeys(item, ["id", "title", "description", "contexts", "entry", "capabilities"], itemLabel);
    const contributionId = requiredString(item.id, `${itemLabel}.id`).toLowerCase();
    if (!CONTRIBUTION_ID_PATTERN.test(contributionId)) throw new Error(`invalid action id ${contributionId}`);
    if (seen.has(`action:${contributionId}`)) throw new Error(`duplicate action id ${contributionId}`);
    seen.add(`action:${contributionId}`);
    if (!Array.isArray(item.contexts) || item.contexts.length === 0) throw new Error(`action ${contributionId} requires contexts`);
    const contexts = [...new Set(item.contexts.map((context) => requiredString(context, `action ${contributionId} context`).toLowerCase()))];
    for (const context of contexts) {
      if (!(ORG2_PLUGIN_ACTION_CONTEXTS as readonly string[]).includes(context)) throw new Error(`action ${contributionId} has unsupported context ${context}`);
    }
    const capabilities = capabilityList(item.capabilities, itemLabel);
    return {
      id: contributionId,
      title: requiredString(item.title, `${itemLabel}.title`),
      ...(optionalString(item.description) ? { description: optionalString(item.description) } : {}),
      contexts: contexts as Org2PluginActionContext[],
      entry: safeProcessEntry(item.entry, `${itemLabel}.entry`),
      ...(capabilities.length ? { capabilities } : {}),
    };
  });
  const hooks = contributionArray(contributesRecord.hooks, `${label}.contributes.hooks`).map((item, index) => {
    const itemLabel = `${label}.contributes.hooks[${index}]`;
    assertOnlyKeys(item, ["id", "description", "events", "entry", "capabilities"], itemLabel);
    const contributionId = requiredString(item.id, `${itemLabel}.id`).toLowerCase();
    if (!CONTRIBUTION_ID_PATTERN.test(contributionId)) throw new Error(`invalid hook id ${contributionId}`);
    if (seen.has(`hook:${contributionId}`)) throw new Error(`duplicate hook id ${contributionId}`);
    seen.add(`hook:${contributionId}`);
    if (!Array.isArray(item.events) || item.events.length === 0) throw new Error(`hook ${contributionId} requires events`);
    const events = [...new Set(item.events.map((event) => requiredString(event, `hook ${contributionId} event`)))];
    for (const event of events) {
      if (!(ORG2_PLUGIN_HOOK_EVENTS as readonly string[]).includes(event)) throw new Error(`hook ${contributionId} subscribes to unsupported event ${event}`);
    }
    const capabilities = capabilityList(item.capabilities, itemLabel);
    return {
      id: contributionId,
      ...(optionalString(item.description) ? { description: optionalString(item.description) } : {}),
      events: events as Org2PluginHookEvent[],
      entry: safeProcessEntry(item.entry, `${itemLabel}.entry`),
      ...(capabilities.length ? { capabilities } : {}),
    };
  });
  const surfaces = contributionArray(contributesRecord.surfaces, `${label}.contributes.surfaces`).map((item, index) => {
    const itemLabel = `${label}.contributes.surfaces[${index}]`;
    assertOnlyKeys(item, ["id", "title", "description", "symbol", "entry", "capabilities"], itemLabel);
    const contributionId = requiredString(item.id, `${itemLabel}.id`).toLowerCase();
    if (!CONTRIBUTION_ID_PATTERN.test(contributionId)) throw new Error(`invalid surface id ${contributionId}`);
    if (seen.has(`surface:${contributionId}`)) throw new Error(`duplicate surface id ${contributionId}`);
    seen.add(`surface:${contributionId}`);
    const symbol = optionalString(item.symbol);
    if (symbol && !/^[a-z0-9][a-z0-9.]{0,79}$/.test(symbol)) throw new Error(`surface ${contributionId} symbol must be an SF Symbol name`);
    const capabilities = capabilityList(item.capabilities, itemLabel);
    return {
      id: contributionId,
      title: requiredString(item.title, `${itemLabel}.title`),
      ...(optionalString(item.description) ? { description: optionalString(item.description) } : {}),
      ...(symbol ? { symbol } : {}),
      entry: safeProcessEntry(item.entry, `${itemLabel}.entry`),
      ...(capabilities.length ? { capabilities } : {}),
    };
  });
  const permissionsRaw = raw.permissions;
  if (permissionsRaw !== undefined && (!permissionsRaw || typeof permissionsRaw !== "object" || Array.isArray(permissionsRaw))) {
    throw new Error(`${label}.permissions must be an object`);
  }
  if (permissionsRaw) assertOnlyKeys(permissionsRaw as Record<string, unknown>, ["environment"], `${label}.permissions`);
  const environmentRaw = (permissionsRaw as Record<string, unknown> | undefined)?.environment;
  if (environmentRaw !== undefined && !Array.isArray(environmentRaw)) throw new Error(`${label}.permissions.environment must be an array`);
  const environment = [...new Set((environmentRaw as unknown[] | undefined || []).map((item) => requiredString(item, "environment variable")))];
  for (const variable of environment) {
    if (!/^[A-Z_][A-Z0-9_]*$/.test(variable)) throw new Error(`invalid environment variable permission ${variable}`);
  }
  const enginesRaw = raw.engines;
  if (enginesRaw !== undefined && (!enginesRaw || typeof enginesRaw !== "object" || Array.isArray(enginesRaw))) {
    throw new Error(`${label}.engines must be an object`);
  }
  if (enginesRaw) assertOnlyKeys(enginesRaw as Record<string, unknown>, ["celorga", "org2"], `${label}.engines`);
  const org2Engine = enginesRaw && typeof enginesRaw === "object" && !Array.isArray(enginesRaw)
    ? optionalString((enginesRaw as Record<string, unknown>).celorga) || optionalString((enginesRaw as Record<string, unknown>).org2)
    : undefined;
  return {
    $schema: ORG2_PLUGIN_MANIFEST_SCHEMA,
    id,
    name,
    version,
    ...(optionalString(raw.description) ? { description: optionalString(raw.description) } : {}),
    ...(org2Engine ? { engines: { org2: org2Engine } } : {}),
    ...(environment.length ? { permissions: { environment } } : {}),
    contributes: {
      ...(commands.length ? { commands } : {}),
      ...(renderers.length ? { renderers } : {}),
      ...(templates.length ? { templates } : {}),
      ...(actions.length ? { actions } : {}),
      ...(hooks.length ? { hooks } : {}),
      ...(surfaces.length ? { surfaces } : {}),
    },
  };
}

type SemanticVersion = [number, number, number];

function parseSemanticVersion(value: string): SemanticVersion | null {
  const match = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-+].*)?$/.exec(value.trim());
  return match ? [Number(match[1]), Number(match[2] || 0), Number(match[3] || 0)] : null;
}

function compareSemanticVersions(left: SemanticVersion, right: SemanticVersion): number {
  for (let index = 0; index < 3; index += 1) {
    if (left[index]! !== right[index]!) return left[index]! < right[index]! ? -1 : 1;
  }
  return 0;
}

function satisfiesComparator(version: SemanticVersion, comparator: string): boolean {
  const match = /^(>=|<=|>|<|=|\^|~)?\s*(v?\d+(?:\.\d+){0,2}(?:[-+][A-Za-z0-9.-]+)?)$/.exec(comparator.trim());
  if (!match) throw new Error(`unsupported Celorga engine comparator: ${comparator}`);
  const operator = match[1] || "=";
  const target = parseSemanticVersion(match[2]!);
  if (!target) throw new Error(`invalid Celorga engine version: ${match[2]}`);
  const comparison = compareSemanticVersions(version, target);
  if (operator === ">=") return comparison >= 0;
  if (operator === "<=") return comparison <= 0;
  if (operator === ">") return comparison > 0;
  if (operator === "<") return comparison < 0;
  if (operator === "=") return comparison === 0;
  if (comparison < 0) return false;
  const upper: SemanticVersion = operator === "~"
    ? [target[0], target[1] + 1, 0]
    : target[0] > 0
      ? [target[0] + 1, 0, 0]
      : target[1] > 0
        ? [0, target[1] + 1, 0]
        : [0, 0, target[2] + 1];
  return compareSemanticVersions(version, upper) < 0;
}

export function pluginEngineSatisfied(range: string | undefined, currentVersion: string): boolean {
  if (!range || range.trim() === "" || range.trim() === "*") return true;
  const version = parseSemanticVersion(currentVersion);
  if (!version) throw new Error(`invalid installed Celorga version: ${currentVersion}`);
  return range.split(/\s*\|\|\s*/).some((alternative) => {
    const comparators = alternative.trim().split(/\s+/).filter(Boolean);
    return comparators.length > 0 && comparators.every((comparator) => satisfiesComparator(version, comparator));
  });
}

let cachedInstalledOrg2Version: string | undefined;

export function installedOrg2Version(): string {
  if (cachedInstalledOrg2Version) return cachedInstalledOrg2Version;
  const packageURL = new URL("../package.json", import.meta.url);
  const metadata = JSON.parse(fs.readFileSync(packageURL, "utf8")) as { version?: unknown };
  cachedInstalledOrg2Version = requiredString(metadata.version, `${packageURL.pathname}.version`);
  return cachedInstalledOrg2Version;
}

export function assertPluginEngineCompatible(manifest: Org2PluginManifest, currentVersion: string = installedOrg2Version()): void {
  const range = manifest.engines?.org2;
  if (range && !pluginEngineSatisfied(range, currentVersion)) {
    throw new Error(`plugin ${manifest.id} requires Celorga ${range}, but this installation is ${currentVersion}`);
  }
}

function validateLockEntry(value: unknown, label: string): Org2PluginLockEntry {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const raw = value as Record<string, unknown>;
  assertOnlyKeys(raw, ["id", "name", "version", "source", "resolvedSource", "ref", "subdir", "revision", "contentHash", "manifest"], label);
  const manifest = validatePluginManifest(raw.manifest, `${label}.manifest`);
  const id = requiredString(raw.id, `${label}.id`).toLowerCase();
  if (id !== manifest.id) throw new Error(`${label}.id does not match its manifest`);
  const revision = requiredString(raw.revision, `${label}.revision`).toLowerCase();
  if (!REVISION_PATTERN.test(revision)) throw new Error(`${label}.revision must be an immutable Git commit`);
  const contentHash = requiredString(raw.contentHash, `${label}.contentHash`).toLowerCase();
  if (!CONTENT_HASH_PATTERN.test(contentHash)) throw new Error(`${label}.contentHash is invalid`);
  return {
    id,
    name: requiredString(raw.name, `${label}.name`),
    version: requiredString(raw.version, `${label}.version`),
    source: requiredString(raw.source, `${label}.source`),
    resolvedSource: requiredString(raw.resolvedSource, `${label}.resolvedSource`),
    ...(optionalString(raw.ref) ? { ref: optionalString(raw.ref) } : {}),
    ...(optionalString(raw.subdir) ? { subdir: safeRelativePath(raw.subdir, `${label}.subdir`) } : {}),
    revision,
    contentHash,
    manifest,
  };
}

export function loadPluginManifest(pluginRoot: string): Org2PluginManifest {
  // celorga-plugin.json is the current manifest name; org2-plugin.json is still accepted.
  const modern = path.join(pluginRoot, "celorga-plugin.json");
  const file = fs.existsSync(modern) ? modern : path.join(pluginRoot, "org2-plugin.json");
  if (!fs.existsSync(file)) throw new Error(`plugin package is missing ${modern}`);
  return validatePluginManifest(JSON.parse(fs.readFileSync(file, "utf8")), file);
}

function pluginFiles(root: string, directory: string = root): string[] {
  const files: string[] = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.name === ".git" || entry.name === ".DS_Store") continue;
    const absolute = path.join(directory, entry.name);
    const relative = path.relative(root, absolute).split(path.sep).join("/");
    if (entry.isSymbolicLink()) throw new Error(`plugin packages may not contain symbolic links: ${relative}`);
    if (entry.isDirectory()) files.push(...pluginFiles(root, absolute));
    else if (entry.isFile()) files.push(relative);
    else throw new Error(`plugin package contains unsupported filesystem entry: ${relative}`);
  }
  return files;
}

export function hashPluginDirectory(root: string): string {
  const digest = crypto.createHash("sha256");
  const files = pluginFiles(root);
  if (files.length > MAX_PLUGIN_PACKAGE_FILES) throw new Error(`plugin package exceeds ${MAX_PLUGIN_PACKAGE_FILES} files`);
  let totalBytes = 0;
  for (const relative of files) {
    const absolute = path.join(root, ...relative.split("/"));
    totalBytes += fs.statSync(absolute).size;
    if (totalBytes > MAX_PLUGIN_PACKAGE_BYTES) throw new Error(`plugin package exceeds ${MAX_PLUGIN_PACKAGE_BYTES} bytes`);
    const executable = (fs.statSync(absolute).mode & 0o111) !== 0 ? "x" : "-";
    digest.update(`file\0${relative}\0${executable}\0`);
    digest.update(fs.readFileSync(absolute));
    digest.update("\0");
  }
  return `sha256:${digest.digest("hex")}`;
}

export function copyPluginDirectory(source: string, destination: string): void {
  fs.mkdirSync(destination, { recursive: true });
  for (const relative of pluginFiles(source)) {
    const from = path.join(source, ...relative.split("/"));
    const to = path.join(destination, ...relative.split("/"));
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(from, to);
    fs.chmodSync(to, fs.statSync(from).mode & 0o777);
  }
}

export function verifyPluginStore(entry: Org2PluginLockEntry): { valid: boolean; root: string; issue?: string } {
  const root = org2PluginStorePath(entry.contentHash);
  if (!fs.existsSync(root)) return { valid: false, root, issue: "not installed" };
  try {
    const actualHash = hashPluginDirectory(root);
    if (actualHash !== entry.contentHash) return { valid: false, root, issue: `content hash mismatch: ${actualHash}` };
    const manifest = loadPluginManifest(root);
    if (manifest.id !== entry.id || manifest.version !== entry.version) return { valid: false, root, issue: "stored manifest does not match lock" };
    return { valid: true, root };
  } catch (error) {
    return { valid: false, root, issue: error instanceof Error ? error.message : String(error) };
  }
}

export function pluginEntryPath(pluginRoot: string, relative: string): string {
  const resolvedRoot = path.resolve(pluginRoot);
  const candidate = path.resolve(resolvedRoot, relative);
  const prefix = resolvedRoot.endsWith(path.sep) ? resolvedRoot : `${resolvedRoot}${path.sep}`;
  if (candidate !== resolvedRoot && !candidate.startsWith(prefix)) throw new Error(`plugin entry escapes package: ${relative}`);
  if (!fs.existsSync(candidate) || !fs.statSync(candidate).isFile()) throw new Error(`plugin entry does not exist: ${relative}`);
  return candidate;
}

export function pluginEnvironment(manifest: Org2PluginManifest, entry: Org2PluginLockEntry): NodeJS.ProcessEnv {
  const allowed = new Set(["HOME", "PATH", "TMPDIR", "TEMP", "TMP", "LANG", "LC_ALL", "TZ"]);
  for (const variable of manifest.permissions?.environment || []) for (const alias of nameAliases(variable)) allowed.add(alias);
  // Plugins see both spellings (CELORGA_X and ORG2_X) of the variables set for them.
  const environment: NodeJS.ProcessEnv = {
    ORG2_PLUGIN_ID: entry.id,
    ORG2_PLUGIN_VERSION: entry.version,
    ORG2_PLUGIN_CONTENT_HASH: entry.contentHash,
    CELORGA_PLUGIN_ID: entry.id,
    CELORGA_PLUGIN_VERSION: entry.version,
    CELORGA_PLUGIN_CONTENT_HASH: entry.contentHash,
  };
  for (const variable of allowed) {
    if (process.env[variable] !== undefined) environment[variable] = process.env[variable];
  }
  return environment;
}

export function invokePlugin(
  entry: Org2PluginLockEntry,
  relativeEntry: string,
  invocation: Record<string, unknown>,
  timeoutMs: number = 10_000,
): Record<string, unknown> {
  assertPluginEngineCompatible(entry.manifest);
  if (!isPluginTrusted(entry.contentHash)) throw new Error(`plugin ${entry.id} is not trusted on this machine`);
  const stored = verifyPluginStore(entry);
  if (!stored.valid) throw new Error(`plugin ${entry.id} is unavailable: ${stored.issue}`);
  const executable = pluginEntryPath(stored.root, relativeEntry);
  const child = spawnSync(process.execPath, [executable], {
    cwd: stored.root,
    env: pluginEnvironment(entry.manifest, entry),
    input: `${JSON.stringify(invocation)}\n`,
    encoding: "utf8",
    timeout: Math.max(100, Math.min(60_000, timeoutMs)),
    maxBuffer: MAX_PLUGIN_STDOUT_BYTES,
  });
  if (child.error) throw child.error;
  if (child.status !== 0) {
    const detail = String(child.stderr || child.stdout || "").trim().slice(0, 1_000);
    throw new Error(`plugin ${entry.id} exited with status ${child.status}${detail ? `: ${detail}` : ""}`);
  }
  const output = String(child.stdout || "").trim();
  if (!output) throw new Error(`plugin ${entry.id} returned no result`);
  let parsed: unknown;
  try {
    parsed = JSON.parse(output);
  } catch {
    throw new Error(`plugin ${entry.id} returned invalid JSON`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error(`plugin ${entry.id} result must be an object`);
  return parsed as Record<string, unknown>;
}

function sourceBlockLanguage(node: SrcBlockNode): { language: string; arguments: string[] } | null {
  const parts = String(node.begin.afterKeywordRaw || "").trim().split(/\s+/).filter(Boolean);
  const language = String(parts.shift() || "").toLowerCase().replace(/[^a-z0-9_+-]/g, "");
  return language ? { language, arguments: parts } : null;
}

type SourceRangedNode = Node & { sourceRange?: { startLine: number; endLine: number } };

function collectSourceBlocks(document: DocumentNode): Array<{ node: SrcBlockNode; line: number; endLine: number; language: string; arguments: string[] }> {
  const output: Array<{ node: SrcBlockNode; line: number; endLine: number; language: string; arguments: string[] }> = [];
  const visitItem = (item: ListItemNode): void => item.children.forEach(visit);
  const visit = (node: Node): void => {
    if (node.type === "SrcBlock") {
      const parsed = sourceBlockLanguage(node);
      const range = (node as SourceRangedNode).sourceRange;
      if (parsed && range) output.push({ node, line: range.startLine, endLine: range.endLine, ...parsed });
      return;
    }
    if (node.type === "Headline" || node.type === "ListItem") node.children.forEach(visit);
    else if (node.type === "List") node.items.forEach(visitItem);
  };
  document.children.forEach(visit);
  return output;
}

function renderError(entry: Org2PluginLockEntry, renderer: Org2PluginRendererContribution, block: ReturnType<typeof collectSourceBlocks>[number], error: unknown): Org2PluginRender {
  return {
    pluginId: entry.id,
    rendererId: renderer.id,
    language: block.language,
    height: 100,
    error: error instanceof Error ? error.message : String(error),
    source: { line: block.line, endLine: block.endLine },
  };
}

function boundedString(value: unknown, maximum: number, label: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  if (Buffer.byteLength(value, "utf8") > maximum) throw new Error(`${label} exceeds ${maximum} bytes`);
  return value;
}

export function renderPluginSourceBlocks(
  document: DocumentNode,
  opts: { sourcePath?: string; timeoutMs?: number } = {},
): { renders: Org2PluginRender[]; diagnostics: Org2PluginDiagnostic[] } {
  if (!opts.sourcePath) return { renders: [], diagnostics: [] };
  const configPath = findConfigFile(path.dirname(path.resolve(opts.sourcePath)));
  if (!configPath) return { renders: [], diagnostics: [] };
  let lock: Org2PluginLock;
  try {
    lock = readPluginLock(path.dirname(configPath));
  } catch (error) {
    return { renders: [], diagnostics: [{ severity: "error", message: error instanceof Error ? error.message : String(error) }] };
  }
  if (!lock.plugins.length) return { renders: [], diagnostics: [] };
  const blocks = collectSourceBlocks(document);
  const renderers = new Map<string, { entry: Org2PluginLockEntry; renderer: Org2PluginRendererContribution }>();
  const diagnostics: Org2PluginDiagnostic[] = [];
  for (const entry of lock.plugins) {
    for (const renderer of entry.manifest.contributes?.renderers || []) {
      for (const language of renderer.languages) {
        if (renderers.has(language)) {
          diagnostics.push({ severity: "warning", pluginId: entry.id, message: `renderer language ${language} is already claimed; ${entry.id}:${renderer.id} was ignored` });
          continue;
        }
        renderers.set(language, { entry, renderer });
      }
    }
  }
  const renders: Org2PluginRender[] = [];
  for (const block of blocks) {
    const match = renderers.get(block.language);
    if (!match) continue;
    const { entry, renderer } = match;
    try {
      const result = invokePlugin(entry, renderer.entry, {
        $schema: ORG2_PLUGIN_INVOCATION_SCHEMA,
        kind: "render",
        plugin: { id: entry.id, version: entry.version, contentHash: entry.contentHash },
        contribution: { id: renderer.id },
        document: { sourcePath: path.resolve(opts.sourcePath) },
        block: {
          language: block.language,
          arguments: block.arguments,
          body: block.node.bodyRaw.replace(/\n$/, ""),
          startLine: block.line,
          endLine: block.endLine,
        },
      }, opts.timeoutMs ?? 5_000);
      if (!schemaMatches(result.$schema, ORG2_PLUGIN_RENDER_RESULT_SCHEMA)) throw new Error(`renderer must return ${ORG2_PLUGIN_RENDER_RESULT_SCHEMA}`);
      const html = boundedString(result.html, 500_000, "renderer html");
      const css = boundedString(result.css, 100_000, "renderer css");
      const script = boundedString(result.script, 200_000, "renderer script");
      if (!html) throw new Error("renderer html is required");
      const rawHeight = typeof result.height === "number" ? result.height : 360;
      const height = Math.max(80, Math.min(2_400, Math.round(rawHeight)));
      renders.push({
        pluginId: entry.id,
        rendererId: renderer.id,
        language: block.language,
        html,
        ...(css ? { css } : {}),
        ...(script ? { script } : {}),
        ...(optionalString(result.title) ? { title: optionalString(result.title) } : {}),
        height,
        source: { line: block.line, endLine: block.endLine },
      });
    } catch (error) {
      renders.push(renderError(entry, renderer, block, error));
      diagnostics.push({ severity: "warning", pluginId: entry.id, message: error instanceof Error ? error.message : String(error), line: block.line });
    }
  }
  return { renders, diagnostics };
}

export function desiredPlugins(corpusRoot: string): Org2PluginConfig[] {
  const configPath = configFilePath(path.resolve(corpusRoot));
  if (!fs.existsSync(configPath)) throw new Error(`plugin commands require ${configPath}`);
  const config = loadConfig(configPath);
  if (config.plugins === undefined) return [];
  if (!Array.isArray(config.plugins)) throw new Error(`${configPath} plugins must be an array`);
  const plugins = config.plugins.map((plugin, index) => {
    if (!plugin || typeof plugin !== "object" || Array.isArray(plugin)) throw new Error(`${configPath} plugins[${index}] must be an object`);
    const source = requiredString(plugin.source, `plugins[${index}].source`);
    return {
      source,
      ...(optionalString(plugin.ref) ? { ref: optionalString(plugin.ref) } : {}),
      ...(optionalString(plugin.subdir) ? { subdir: safeRelativePath(plugin.subdir, `plugins[${index}].subdir`) } : {}),
    };
  });
  const sources = new Set<string>();
  for (const plugin of plugins) {
    const key = [plugin.source, plugin.ref || "", plugin.subdir || ""].join("\0");
    if (sources.has(key)) throw new Error(`${configPath} contains a duplicate plugin source: ${plugin.source}`);
    sources.add(key);
  }
  return plugins;
}
