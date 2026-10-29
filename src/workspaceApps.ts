import fs from "node:fs";
import path from "node:path";
import { configFilePath, schemaMatches } from "./brandNames.js";
import { loadConfig, resolveFilesFromDir, type Org2AppsConfig, type Org2Config } from "./config.js";
import { guardedContentRevision, guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { invokePluginSandboxed } from "./pluginActions.js";
import {
  ORG2_PLUGIN_INVOCATION_SCHEMA,
  ORG2_PLUGIN_RENDER_RESULT_SCHEMA,
  isPluginTrusted,
  readPluginLock,
  type Org2PluginLockEntry,
  type Org2PluginSurfaceContribution,
} from "./pluginRuntime.js";

/**
 * Workspace apps are optional sidebar surfaces. Built-in apps (People &
 * Companies, Canvases) ship with Celorga but stay hidden until a corpus turns
 * them on; plugin apps come from installed plugins that contribute
 * `contributes.surfaces`. Enablement is portable corpus intent in the
 * `apps` key of celorga.json, so every machine opening the corpus agrees.
 */
export const WORKSPACE_APPS_SCHEMA = "org2:workspace-apps:v1" as const;
export const WORKSPACE_APP_CHANGE_SCHEMA = "org2:workspace-app-change:v1" as const;
export const PLUGIN_SURFACE_RENDER_SCHEMA = "org2:plugin-surface-render:v1" as const;

export interface WorkspaceAppSurface {
  id: string;
  title: string;
  symbol: string;
}

export interface WorkspaceApp {
  id: string;
  title: string;
  description: string;
  symbol: string;
  source: "built-in" | "plugin";
  pluginId?: string;
  trusted?: boolean;
  defaultEnabled: boolean;
  enabled: boolean;
  surfaces: WorkspaceAppSurface[];
  /** Present when the corpus already contains data this app is useful for. */
  suggestion?: { reason: string };
}

interface BuiltInApp {
  id: string;
  title: string;
  description: string;
  symbol: string;
  surfaces: WorkspaceAppSurface[];
  suggest: (root: string, config: Org2Config) => string | null;
}

const ENTITY_TYPE_PATTERN = /^[ \t]*:(?:CELORGA_|ORG2_)?ENTITY_TYPE:[ \t]*([A-Za-z_-]+)/gim;
const TYPE_TAG_PATTERN = /:type[_-](person|company|organization|organisation):/gi;
const PERSON_TYPES = new Set(["person", "people", "contact"]);
const COMPANY_TYPES = new Set(["company", "organization", "organisation", "org"]);

function corpusOrgFiles(root: string, config: Org2Config): string[] {
  const patterns = [...(config.agendaFiles?.length ? config.agendaFiles : ["**/*.org", "**/*.org2"])];
  const nodesDir = String(config.roam?.nodesDir || "notes").replace(/^\.\//, "").replace(/\/+$/, "");
  if (nodesDir && !path.isAbsolute(nodesDir)) patterns.push(`${nodesDir}/**/*.org`, `${nodesDir}/**/*.org2`);
  return resolveFilesFromDir(root, patterns, ["node_modules", "node_modules/**", "raw/**", ...(config.ignorePatterns ?? [])], config.recursive !== false);
}

/** Count people and companies from file heads only; a cheap discovery signal. */
export function countEntityNotes(root: string, config: Org2Config): { people: number; companies: number } {
  let people = 0;
  let companies = 0;
  for (const file of corpusOrgFiles(root, config)) {
    if (/\/notes\/[^/]+\/accounts\//.test(file.replace(/\\/g, "/"))) continue;
    let head: string;
    try {
      const descriptor = fs.openSync(file, "r");
      try {
        const buffer = Buffer.alloc(4096);
        const read = fs.readSync(descriptor, buffer, 0, buffer.length, 0);
        head = buffer.subarray(0, read).toString("utf8");
      } finally { fs.closeSync(descriptor); }
    } catch { continue; }
    const types = new Set<string>();
    for (const match of head.matchAll(ENTITY_TYPE_PATTERN)) types.add(String(match[1]).toLowerCase());
    for (const match of head.matchAll(TYPE_TAG_PATTERN)) types.add(String(match[1]).toLowerCase());
    if ([...types].some((type) => PERSON_TYPES.has(type))) people += 1;
    else if ([...types].some((type) => COMPANY_TYPES.has(type))) companies += 1;
  }
  return { people, companies };
}

function countLedgerAccounts(root: string): number {
  const notes = path.join(root, "notes");
  if (!fs.existsSync(notes)) return 0;
  let count = 0;
  for (const entry of fs.readdirSync(notes, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const accounts = path.join(notes, entry.name, "accounts");
    if (!fs.existsSync(accounts)) continue;
    count += fs.readdirSync(accounts).filter((name) => /\.org2?$/i.test(name)).length;
  }
  return count;
}

function hasCanvasFiles(root: string, config: Org2Config): boolean {
  return resolveFilesFromDir(root, ["**/*.canvas"], ["node_modules", "node_modules/**", "raw/**", ...(config.ignorePatterns ?? [])], true).length > 0;
}

const BUILT_IN_APPS: BuiltInApp[] = [
  {
    id: "crm",
    title: "People & Companies",
    description: "A lightweight CRM over the person and company notes, meetings, tasks, outreach ledgers, and calendar already in your corpus.",
    symbol: "person.2",
    surfaces: [
      { id: "people", title: "People", symbol: "person.crop.circle" },
      { id: "companies", title: "Companies", symbol: "building.2" },
    ],
    suggest(root, config) {
      const { people, companies } = countEntityNotes(root, config);
      const accounts = countLedgerAccounts(root);
      if (people + companies < 5 && accounts === 0) return null;
      const parts = [
        people ? `${people} ${people === 1 ? "person" : "people"}` : "",
        companies ? `${companies} ${companies === 1 ? "company" : "companies"}` : "",
        accounts ? `${accounts} ledger account${accounts === 1 ? "" : "s"}` : "",
      ].filter(Boolean);
      return `Your corpus already has ${parts.join(", ")}.`;
    },
  },
  {
    id: "canvases",
    title: "Canvases",
    description: "Spatial JSON Canvas boards that arrange notes, files, and cards.",
    symbol: "rectangle.3.group",
    surfaces: [{ id: "canvases", title: "Canvases", symbol: "rectangle.3.group" }],
    suggest(root, config) {
      return hasCanvasFiles(root, config) ? "Your corpus contains .canvas files." : null;
    },
  },
];

export const BUILT_IN_APP_IDS = BUILT_IN_APPS.map((app) => app.id);

function appIdPattern(id: string): boolean {
  return /^(?:[a-z0-9][a-z0-9-]{0,63}|plugin:[a-z0-9][a-z0-9.-]{0,127})$/.test(id);
}

function readCorpusConfig(root: string): { file: string; config: Org2Config; revision: string | null; raw: string | null } {
  const file = configFilePath(root);
  if (!fs.existsSync(file)) return { file, config: {}, revision: null, raw: null };
  const snapshot = readGuardedFile(file);
  return { file, config: loadConfig(file), revision: snapshot.revision, raw: snapshot.content };
}

function normalizedAppsConfig(config: Org2Config): Required<Org2AppsConfig> {
  const apps = config.apps;
  if (apps === undefined) return { enabled: [], disabled: [] };
  if (!apps || typeof apps !== "object" || Array.isArray(apps)) throw new Error("celorga.json apps must be an object");
  const list = (value: unknown, key: string): string[] => {
    if (value === undefined) return [];
    if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) throw new Error(`celorga.json apps.${key} must be an array of app IDs`);
    return [...new Set((value as string[]).map((item) => item.trim().toLowerCase()).filter(Boolean))];
  };
  return { enabled: list(apps.enabled, "enabled"), disabled: list(apps.disabled, "disabled") };
}

function pluginSurfaces(root: string): Array<{ entry: Org2PluginLockEntry; surfaces: Org2PluginSurfaceContribution[] }> {
  let lock;
  try { lock = readPluginLock(root); } catch { return []; }
  return lock.plugins
    .map((entry) => ({ entry, surfaces: entry.manifest.contributes?.surfaces ?? [] }))
    .filter((item) => item.surfaces.length > 0);
}

export function listWorkspaceApps(rootRaw: string, options: { suggestions?: boolean } = {}) {
  const root = path.resolve(rootRaw);
  const { file, config } = readCorpusConfig(root);
  const settings = normalizedAppsConfig(config);
  const isEnabled = (id: string, defaultEnabled: boolean) =>
    settings.disabled.includes(id) ? false : settings.enabled.includes(id) ? true : defaultEnabled;
  const apps: WorkspaceApp[] = BUILT_IN_APPS.map((app) => {
    const enabled = isEnabled(app.id, false);
    const reason = options.suggestions === false || enabled ? null : app.suggest(root, config);
    return {
      id: app.id,
      title: app.title,
      description: app.description,
      symbol: app.symbol,
      source: "built-in" as const,
      defaultEnabled: false,
      enabled,
      surfaces: app.surfaces,
      ...(reason ? { suggestion: { reason } } : {}),
    };
  });
  for (const { entry, surfaces } of pluginSurfaces(root)) {
    const id = `plugin:${entry.id}`;
    apps.push({
      id,
      title: entry.name,
      description: entry.manifest.description || surfaces[0]?.description || `Pages contributed by the ${entry.name} plugin.`,
      symbol: surfaces[0]?.symbol || "puzzlepiece.extension",
      source: "plugin",
      pluginId: entry.id,
      trusted: isPluginTrusted(entry.contentHash),
      // Installing and pinning a plugin is already an explicit choice.
      defaultEnabled: true,
      enabled: isEnabled(id, true),
      surfaces: surfaces.map((surface) => ({ id: surface.id, title: surface.title, symbol: surface.symbol || "puzzlepiece.extension" })),
    });
  }
  return {
    schema: WORKSPACE_APPS_SCHEMA,
    configFile: path.relative(root, file) || path.basename(file),
    apps,
    enabled: apps.filter((app) => app.enabled).map((app) => app.id),
  };
}

/** Turn an app on or off in celorga.json. Previews unless `apply` is set. */
export function setWorkspaceAppEnabled(rootRaw: string, appIdRaw: string, enabled: boolean, options: { apply?: boolean; expectedRevision?: string } = {}) {
  const root = path.resolve(rootRaw);
  const appId = String(appIdRaw || "").trim().toLowerCase();
  if (!appIdPattern(appId)) throw new Error(`invalid app id: ${appIdRaw}`);
  const known = listWorkspaceApps(root, { suggestions: false }).apps.find((app) => app.id === appId);
  if (!known) throw new Error(`unknown app ${appId}; run celorga apps list to see available apps`);
  const { file, config, revision, raw } = readCorpusConfig(root);
  if (options.expectedRevision && options.expectedRevision !== revision) throw new Error(`${path.basename(file)} changed; reload and retry`);
  const settings = normalizedAppsConfig(config);
  const nextEnabled = settings.enabled.filter((id) => id !== appId);
  const nextDisabled = settings.disabled.filter((id) => id !== appId);
  if (enabled !== known.defaultEnabled) (enabled ? nextEnabled : nextDisabled).push(appId);
  const appsConfig: Org2AppsConfig = {
    ...(nextEnabled.length ? { enabled: nextEnabled.sort() } : {}),
    ...(nextDisabled.length ? { disabled: nextDisabled.sort() } : {}),
  };
  const next: Record<string, unknown> = { ...(raw ? JSON.parse(raw) : {}) };
  if (Object.keys(appsConfig).length) next.apps = appsConfig;
  else delete next.apps;
  const content = JSON.stringify(next, null, 2) + "\n";
  const changed = content !== (raw ?? "");
  if (options.apply && changed) guardedWriteFile(file, content, { expectedRevision: revision, preserveMode: true });
  return {
    schema: WORKSPACE_APP_CHANGE_SCHEMA,
    app: appId,
    enabled,
    changed,
    applied: Boolean(options.apply && changed),
    file: path.relative(root, file) || path.basename(file),
    baseRevision: revision,
    revision: guardedContentRevision(content),
    content,
  };
}

function boundedString(value: unknown, maximum: number, label: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  if (Buffer.byteLength(value, "utf8") > maximum) throw new Error(`${label} exceeds ${maximum} bytes`);
  return value;
}

/** Render one plugin surface. The plugin runs sandboxed and returns HTML only. */
export function renderPluginSurface(rootRaw: string, selector: string) {
  const root = path.resolve(rootRaw);
  const separator = selector.indexOf(":");
  if (separator < 1) throw new Error("surface selector must be PLUGIN_ID:SURFACE_ID");
  const pluginId = selector.slice(0, separator).toLowerCase();
  const surfaceId = selector.slice(separator + 1).toLowerCase();
  const found = pluginSurfaces(root).find((item) => item.entry.id === pluginId);
  if (!found) throw new Error(`plugin ${pluginId} is not locked in this corpus or contributes no surfaces`);
  const surface = found.surfaces.find((item) => item.id === surfaceId);
  if (!surface) throw new Error(`plugin ${pluginId} does not contribute surface ${surfaceId}`);
  const app = listWorkspaceApps(root, { suggestions: false }).apps.find((item) => item.id === `plugin:${pluginId}`);
  if (!app?.enabled) throw new Error(`app plugin:${pluginId} is turned off; enable it with celorga apps enable plugin:${pluginId} --apply`);
  const { entry } = found;
  const capabilities = surface.capabilities ?? [];
  const { result, sandbox } = invokePluginSandboxed(root, entry, surface.entry, capabilities, {
    $schema: ORG2_PLUGIN_INVOCATION_SCHEMA,
    kind: "surface",
    plugin: { id: entry.id, version: entry.version, contentHash: entry.contentHash },
    contribution: { id: surface.id, title: surface.title },
    capabilities,
    ...(capabilities.includes("read-corpus") ? { corpus: { root } } : {}),
  });
  if (!schemaMatches(result.$schema, ORG2_PLUGIN_RENDER_RESULT_SCHEMA)) throw new Error(`surface must return ${ORG2_PLUGIN_RENDER_RESULT_SCHEMA}`);
  const html = boundedString(result.html, 1_000_000, "surface html");
  if (!html) throw new Error("surface html is required");
  const css = boundedString(result.css, 200_000, "surface css");
  const script = boundedString(result.script, 500_000, "surface script");
  const title = typeof result.title === "string" && result.title.trim() ? result.title.trim().slice(0, 200) : surface.title;
  return {
    schema: PLUGIN_SURFACE_RENDER_SCHEMA,
    pluginId: entry.id,
    surfaceId: surface.id,
    title,
    html,
    ...(css ? { css } : {}),
    ...(script ? { script } : {}),
    sandbox,
  };
}
