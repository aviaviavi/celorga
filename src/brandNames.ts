import fs from "node:fs";
import path from "node:path";

/**
 * Celorga names and their pre-rename (Org2/OpenOrg) equivalents.
 *
 * Phase 1 of the rename (see docs/rename/celorga.org): every reader accepts
 * both spellings, preferring the Celorga one. Writers keep editing whichever
 * config file a corpus already has; brand-new corpora get `celorga.json`.
 */

export const PROPERTY_PREFIX = "CELORGA_";
export const LEGACY_PROPERTY_PREFIX = "ORG2_";
export const CONFIG_FILE = "celorga.json";
export const LEGACY_CONFIG_FILE = "org2.json";
export const STATE_DIR = ".celorga";
export const LEGACY_STATE_DIR = ".org2";
export const SCHEMA_NAMESPACE = "celorga";
export const LEGACY_SCHEMA_NAMESPACE = "org2";
export const MCP_TOOL_PREFIX = "celorga_";
export const LEGACY_MCP_TOOL_PREFIX = "org2_";

/** The Celorga spelling of a property or environment name (`ORG2_X` -> `CELORGA_X`). */
export function celorgaName(name: string): string {
  return name.startsWith(LEGACY_PROPERTY_PREFIX) ? PROPERTY_PREFIX + name.slice(LEGACY_PROPERTY_PREFIX.length) : name;
}

/** The legacy spelling of a property or environment name (`CELORGA_X` -> `ORG2_X`). */
export function legacyName(name: string): string {
  return name.startsWith(PROPERTY_PREFIX) ? LEGACY_PROPERTY_PREFIX + name.slice(PROPERTY_PREFIX.length) : name;
}

/** Both spellings, Celorga first. Names without a brand prefix are returned unchanged. */
export function nameAliases(name: string): string[] {
  const modern = celorgaName(name);
  const legacy = legacyName(name);
  return modern === legacy ? [name] : [modern, legacy];
}

/** Expand a list of candidate names so each branded name is tried as CELORGA_X, then ORG2_X. */
export function withNameAliases(names: readonly string[]): string[] {
  const result: string[] = [];
  for (const name of names) {
    for (const alias of nameAliases(name)) if (!result.includes(alias)) result.push(alias);
  }
  return result;
}

type PropertySource =
  | Map<string, string>
  | Record<string, string | undefined>
  | ReadonlyArray<{ key: string; value: string }>
  | null
  | undefined;

function lookup(source: PropertySource, key: string): string | undefined {
  if (!source) return undefined;
  if (source instanceof Map) return source.get(key);
  if (Array.isArray(source)) {
    const upper = key.toUpperCase();
    return (source as ReadonlyArray<{ key: string; value: string }>).find((entry) => entry.key.toUpperCase() === upper)?.value;
  }
  return (source as Record<string, string | undefined>)[key];
}

/**
 * Read a branded property (`ORG2_X` or `CELORGA_X`, either spelling accepted
 * as the argument). Returns the Celorga value when present and non-empty,
 * otherwise the legacy value.
 */
export function brandProperty(source: PropertySource, name: string): string | undefined {
  let fallback: string | undefined;
  for (const alias of nameAliases(name)) {
    const value = lookup(source, alias);
    if (value !== undefined && String(value).trim() !== "") return value;
    if (value !== undefined && fallback === undefined) fallback = value;
  }
  return fallback;
}

/** The key a branded property is stored under in this source, if any (for in-place updates). */
export function brandPropertyKey(source: PropertySource, name: string): string | undefined {
  return nameAliases(name).find((alias) => lookup(source, alias) !== undefined);
}

/** True for `CELORGA_X` or `ORG2_X` matching the given name in either spelling. */
export function isBrandName(candidate: string, name: string): boolean {
  return nameAliases(name).includes(candidate.toUpperCase()) || nameAliases(name).includes(candidate);
}

/** Read a branded environment variable, preferring `CELORGA_X` over `ORG2_X`. */
export function brandEnv(name: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  for (const alias of nameAliases(name)) {
    const value = env[alias];
    if (value !== undefined && value !== "") return value;
  }
  return undefined;
}

/**
 * Copy every `CELORGA_X` environment variable to `ORG2_X` when the legacy name
 * is unset, so code (and child processes) that read the legacy name see the
 * Celorga value. Call once at process start.
 */
export function mirrorCelorgaEnvironment(env: NodeJS.ProcessEnv = process.env): void {
  for (const [key, value] of Object.entries(env)) {
    if (!key.startsWith(PROPERTY_PREFIX) || value === undefined) continue;
    const legacy = legacyName(key);
    if (env[legacy] === undefined || env[legacy] === "") env[legacy] = value;
  }
}

/** `celorga:kind:v1` and `org2:kind:v1` are the same record type. */
export function schemaMatches(value: unknown, legacyOrModernId: string): boolean {
  if (typeof value !== "string") return false;
  const suffix = legacyOrModernId.replace(/^(?:org2|celorga):/, "");
  return value === `${SCHEMA_NAMESPACE}:${suffix}` || value === `${LEGACY_SCHEMA_NAMESPACE}:${suffix}`;
}

/** Normalize a schema ID to the legacy spelling used for internal comparisons and writes. */
export function legacySchemaId(value: string): string {
  return value.startsWith(`${SCHEMA_NAMESPACE}:`) ? `${LEGACY_SCHEMA_NAMESPACE}:${value.slice(SCHEMA_NAMESPACE.length + 1)}` : value;
}

/** The workspace config file in a directory: `celorga.json` if present, else `org2.json` if present. */
export function configFileIn(dir: string): string | null {
  for (const name of [CONFIG_FILE, LEGACY_CONFIG_FILE]) {
    const candidate = path.join(dir, name);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * The config file to read or edit in a directory: the existing `celorga.json`
 * or `org2.json`, otherwise `celorga.json` for a new corpus.
 */
export function configFilePath(dir: string): string {
  return configFileIn(dir) ?? path.join(dir, CONFIG_FILE);
}

/** Whether a file name is a workspace config file (either spelling). */
export function isConfigFileName(name: string): boolean {
  return name === CONFIG_FILE || name === LEGACY_CONFIG_FILE;
}

/**
 * The corpus state directory: `.celorga/` once a corpus has been migrated,
 * otherwise `.org2/`. New and unmigrated corpora keep `.org2/` in phase 1.
 */
export function stateDirName(corpusRoot: string): string {
  return fs.existsSync(path.join(corpusRoot, STATE_DIR)) ? STATE_DIR : LEGACY_STATE_DIR;
}

export function stateDir(corpusRoot: string, ...segments: string[]): string {
  return path.join(corpusRoot, stateDirName(corpusRoot), ...segments);
}

/** MCP tool names: accept `celorga_x` and `org2_x`; returns the legacy spelling used internally. */
export function legacyToolName(name: string): string {
  return name.startsWith(MCP_TOOL_PREFIX) ? LEGACY_MCP_TOOL_PREFIX + name.slice(MCP_TOOL_PREFIX.length) : name;
}

export function celorgaToolName(name: string): string {
  return name.startsWith(LEGACY_MCP_TOOL_PREFIX) ? MCP_TOOL_PREFIX + name.slice(LEGACY_MCP_TOOL_PREFIX.length) : name;
}

/** Extension for every Org document Celorga creates. */
export const ORG_EXTENSION = ".org";
/** Pre-rename extension. Still read everywhere, never used for new files. */
export const LEGACY_ORG_EXTENSION = ".org2";

/** True for `.org` and legacy `.org2` file names. */
export function isOrgRecordFileName(name: string): boolean {
  return /\.org2?$/i.test(name);
}

/**
 * Path of the Org record `baseName` in `dir`. An existing `.org` file wins,
 * then an existing legacy `.org2` file (so older records keep updating in
 * place); otherwise a new record is always `.org`.
 */
export function orgRecordPath(dir: string, baseName: string): string {
  const preferred = path.join(dir, `${baseName}${ORG_EXTENSION}`);
  if (fs.existsSync(preferred)) return preferred;
  const legacy = path.join(dir, `${baseName}${LEGACY_ORG_EXTENSION}`);
  return fs.existsSync(legacy) ? legacy : preferred;
}
