import { configFileIn } from "./brandNames.js";
import fs from "node:fs";
import path from "node:path";
import type { Org2CorpusIdentity } from "./corpusIdentity.js";

export type Org2PublishProjectConfig = {
  baseDir: string;
  outDir: string;
  recursive?: boolean;
  include?: string[];
  ignore?: string[];
  index?: string | { file: string; title?: string };
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  toc?: boolean;
  tocDepth?: number;
  numberHeadings?: boolean;
  numberHeadingsDepth?: number;
  rewriteFileLinks?: boolean;
  preambleHtml?: string;
  postambleHtml?: string;
  headIncludes?: string[];
  syntaxHighlighting?: boolean;
  openGraph?: {
    imageFormat?: "svg" | "png";
    siteName?: string;
    locale?: string;
  };
  assets?: {
    include?: string[];
    ignore?: string[];
  };
  sitemapXml?: {
    file?: string;
    baseUrl: string;
    includeIndexPage?: boolean;
  };
};

export type Org2ClickHouseDataSourceConfig = {
  type: "clickhouse";
  url: string;
  database?: string;
  userEnv?: string;
  passwordEnv?: string;
  timeoutMs?: number;
  maxRows?: number;
  maxResponseBytes?: number;
};

export type Org2MetabaseDataSourceConfig = {
  type: "metabase";
  url: string;
  apiKeyEnv: string;
  databaseId?: number;
  databaseIdEnv?: string;
  timeoutMs?: number;
  maxRows?: number;
  maxResponseBytes?: number;
};

export type Org2DataSourceConfig = Org2ClickHouseDataSourceConfig | Org2MetabaseDataSourceConfig;

export type Org2ExternalSourceType = "slack" | "notion" | "email" | "google-calendar";

export type Org2ExternalSourceConfig = {
  type: Org2ExternalSourceType;
  /** Non-secret IMAP account settings for `type: "email"`. Passwords stay machine-local. */
  email?: {
    host: string;
    port?: number;
    security?: "tls" | "starttls" | "none";
    username: string;
    mailboxes?: string[];
    maxMessageBytes?: number;
    /** The account's SMTP submission server, recorded for reference and future sending. */
    smtp?: { host: string; port?: number; security?: "tls" | "starttls" | "none" };
  };
  /** Non-secret settings for `type: "google-calendar"`. The OAuth credential stays machine-local. */
  googleCalendar?: {
    /** Calendar IDs to read; defaults to ["primary"]. */
    calendars?: string[];
    /** How many days ahead to keep synced; defaults to 14. */
    lookaheadDays?: number;
  };
  enabled?: boolean;
  scopes?: string[];
  workspaceId?: string;
  rawZone?: string;
  media?: "lazy" | "metadata-only";
  syncArgs?: string[];
  ingestion?: {
    since?: string;
    maxItems?: number;
    reviewZone?: string;
  };
  schedule?: {
    enabled?: boolean;
    kind: "interval" | "daily";
    everyMinutes?: number;
    time?: string;
    /** IANA timezone name or "local" to follow the machine running the sync. */
    timezone?: string;
  };
};

export type Org2PluginConfig = {
  /** GitHub shorthand, Git URL, file URL, or local Git checkout. */
  source: string;
  /** Mutable source intent; the lock file records the immutable commit. */
  ref?: string;
  /** Optional plugin package directory within a larger repository. */
  subdir?: string;
};

export interface Org2Config {
  /** Symbolic scheduler owner; defaults to desktop. Machine endpoints stay outside the corpus. */
  automationHostRef?: string;
  corpus?: Org2CorpusIdentity;
  agendaFiles?: string[];
  recursive?: boolean;
  ignorePatterns?: string[];
  roam?: {
    indexDir?: string;
    dailiesDir?: string;
    /**
     * Corpus-relative daily note path template, for example
     * `journal/{YYYY}/{MM}/{YYYY}-{MM}-{DD}-wind-down.md`. Overrides the
     * `dailiesDir/YYYY-MM-DD.org` convention. See dailyNoteTemplate.ts.
     */
    dailyFileTemplate?: string;
    nodesDir?: string;
  };
  links?: {
    abbreviations?: Record<string, string>;
    linearTeam?: string;
  };
  todo?: {
    /** Default Org sequences; file-local declarations take precedence. */
    sequences?: string[];
    writeTransitionLogbook?: boolean;
  };
  publish?: {
    projects?: Record<string, Org2PublishProjectConfig>;
  };
  dataSources?: Record<string, Org2DataSourceConfig>;
  /** Portable plugin source intent. Exact commits and hashes live in org2.plugins.lock.json. */
  plugins?: Org2PluginConfig[];
  /** Portable, non-secret source intent. Credentials and machine paths live in local bindings. */
  externalSources?: Record<string, Org2ExternalSourceConfig>;
}

export function findConfigFile(startDir: string): string | null {
  let currentDir = path.resolve(startDir);

  while (true) {
    // celorga.json wins over the legacy org2.json in the same directory.
    const configPath = configFileIn(currentDir);
    if (configPath) {
      return configPath;
    }

    const parentDir = path.dirname(currentDir);
    if (parentDir === currentDir) {
      break;
    }
    currentDir = parentDir;
  }

  return null;
}

export function loadConfig(configPath: string): Org2Config {
  try {
    const content = fs.readFileSync(configPath, "utf8");
    return JSON.parse(content) as Org2Config;
  } catch (err) {
    throw new Error(
      `Failed to load config from ${configPath}: ${err instanceof Error ? err.message : String(err)}`
    );
  }
}

export function getDefaultConfig(): Org2Config {
  return {
    agendaFiles: ["*.org"],
    recursive: true,
    ignorePatterns: [".git/**", "node_modules/**", ".#*"],
  };
}

function normalizePathForMatch(value: string): string {
  return String(value || "").replace(/\\/g, "/");
}

function segmentMatches(pathSegment: string, patternSegment: string): boolean {
  const escaped = patternSegment.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  const regex = new RegExp(`^${escaped.replace(/\*/g, ".*")}$`);
  return regex.test(pathSegment);
}

function matchSegments(pathSegments: string[], patternSegments: string[], pi: number = 0, pj: number = 0): boolean {
  if (pj >= patternSegments.length) return pi >= pathSegments.length;

  const pat = patternSegments[pj];
  if (pat === "**") {
    for (let k = pi; k <= pathSegments.length; k += 1) {
      if (matchSegments(pathSegments, patternSegments, k, pj + 1)) return true;
    }
    return false;
  }

  if (pi >= pathSegments.length) return false;
  if (!segmentMatches(pathSegments[pi] ?? "", pat)) return false;
  return matchSegments(pathSegments, patternSegments, pi + 1, pj + 1);
}

function matchesPattern(filePath: string, pattern: string): boolean {
  const normalizedPath = normalizePathForMatch(filePath);
  const normalizedPattern = normalizePathForMatch(pattern);

  if (normalizedPattern.includes("*")) {
    const pathSegments = normalizedPath.split("/").filter((seg) => seg.length > 0);
    const patternSegments = normalizedPattern.split("/").filter((seg) => seg.length > 0);
    return matchSegments(pathSegments, patternSegments);
  }

  return normalizedPath === normalizedPattern || normalizedPath.startsWith(normalizedPattern + "/");
}

function shouldIgnore(filePath: string, ignorePatterns: string[]): boolean {
  const baseName = path.basename(filePath);
  if (
    baseName.startsWith(".syncthing.") ||
    baseName.includes(".sync-conflict-") ||
    baseName.endsWith(".tmp")
  ) {
    return true;
  }

  for (const pattern of ignorePatterns) {
    if (matchesPattern(filePath, pattern)) {
      return true;
    }
  }
  return false;
}

export function resolveFilesFromDir(
  dir: string,
  patterns: string[],
  ignorePatterns: string[],
  recursive: boolean = true
): string[] {
  const allFiles: string[] = [];

  function walk(currentPath: string, relPath: string = ""): void {
    try {
      const entries = fs.readdirSync(currentPath, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(currentPath, entry.name);
        const relativePath = relPath ? path.join(relPath, entry.name) : entry.name;

        if (shouldIgnore(relativePath, ignorePatterns)) {
          continue;
        }

        if (entry.isDirectory()) {
          if (recursive && !entry.name.startsWith(".")) {
            walk(fullPath, relativePath);
          }
        } else if (entry.isFile()) {
          for (const pattern of patterns) {
            if (matchesPattern(relativePath, pattern)) {
              allFiles.push(path.resolve(fullPath));
              break;
            }
          }
        }
      }
    } catch (err) {
      console.error(
        `Error reading directory ${currentPath}: ${err instanceof Error ? err.message : String(err)}`
      );
    }
  }

  walk(dir);
  return allFiles.sort();
}

export function resolveFilesFromConfig(
  config: Org2Config,
  baseDir: string = process.cwd()
): string[] {
  const patterns = config.agendaFiles || ["*.org"];
  const ignorePatterns = config.ignorePatterns || [];
  const recursive = config.recursive !== false;

  return resolveFilesFromDir(baseDir, patterns, ignorePatterns, recursive);
}

export function resolveRoamIndexRootDir(config: Org2Config, baseDir: string = process.cwd()): string {
  const configured = String(config.roam?.indexDir || "").trim();
  if (!configured) return baseDir;
  return path.isAbsolute(configured) ? configured : path.resolve(baseDir, configured);
}

export function resolveRoamDailiesRootDir(config: Org2Config, baseDir: string = process.cwd()): string {
  const configured = String(config.roam?.dailiesDir || "").trim();
  if (!configured) return resolveRoamIndexRootDir(config, baseDir);
  return path.isAbsolute(configured) ? configured : path.resolve(baseDir, configured);
}
