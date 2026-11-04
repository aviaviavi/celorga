import path from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { DuckDBConnection } from "@duckdb/node-api";
import { findConfigFile, loadConfig, type Org2DataSourceConfig } from "./config.js";
import { loadRemoteDataset, type RemoteDatasetRequest } from "./dataSources.js";
import { isOrgTableDataLine, isOrgTableHline, parseOrgTableDataLine } from "./orgTableData.js";
import { formatLocalOrgDate } from "./calendarDate.js";
import { CELORGA_DATASET_SCHEMAS, createCelorgaDatasetLoader, parseCelorgaDataset, type CelorgaDatasetSpec } from "./celorgaDatasets.js";

export type DataQueryDiagnostic = {
  severity: "error" | "warning";
  message: string;
  source?: {
    line?: number;
    blockId?: string;
  };
};

export type DataQueryDataset = {
  id: string;
  line: number;
  type: "csv" | "parquet" | "json" | "table" | "clickhouse" | "metabase" | "celorga";
  engine: "duckdb";
  path?: string;
  url?: string;
  credentialRef?: string;
  configRef?: string;
  resolvedPath?: string;
  sourceTable?: string;
  profile?: string;
  query?: string;
  questionId?: number;
  parameters?: unknown;
  source?: {
    line: number;
    endLine: number;
  };
  rowCount?: number;
  celorga?: CelorgaDatasetSpec;
};

export type DataQuerySqlBlock = {
  resultId: string;
  sourceIds?: string[];
  artifact?: string;
  freshness?: string;
  line: number;
  endLine: number;
  sql: string;
};

export type DataQueryResultBlock = {
  resultId: string;
  sourceIds?: string[];
  artifact?: string;
  freshness?: string;
  line: number;
  endLine: number;
};

export type DataQuerySqlView = {
  id: string;
  line: number;
  endLine: number;
  sql: string;
};

export type DataQueryResult = {
  ok: boolean;
  mode: "execute" | "inspect";
  engine: "duckdb";
  resultId?: string;
  source?: {
    file?: string;
    line: number;
    endLine: number;
  };
  datasets: DataQueryDataset[];
  views: DataQuerySqlView[];
  resultBlocks: DataQueryResultBlock[];
  rowCount: number;
  rows: Record<string, unknown>[];
  provenance?: {
    resultId: string;
    artifact?: string;
    freshness?: string;
    ranAt?: string;
    querySha256: string;
    scriptSha256: string;
    datasetIds: string[];
    viewIds: string[];
  };
  orgTable?: string;
  duckdbScript?: string;
  diagnostics: DataQueryDiagnostic[];
};

export type RunDataQueryOptions = {
  file?: string;
  resultId?: string;
  resultLine?: number;
  outputArtifact?: string;
  duckdbPath?: string;
  includeScript?: boolean;
  inspectOnly?: boolean;
  ranAt?: string;
  dataSources?: Record<string, Org2DataSourceConfig>;
  env?: NodeJS.ProcessEnv;
};

type FencedBlock = {
  kind: string;
  args: string[];
  line: number;
  endLine: number;
  body: string;
};

type NamedOrgTable = {
  name: string;
  line: number;
  endLine: number;
  headers: string[];
  rows: string[][];
};

const SUPPORTED_DATASET_TYPES = new Set(["csv", "parquet", "json", "table", "org-table", "clickhouse", "metabase", "celorga"]);

function diagnostic(message: string, source?: { line?: number; blockId?: string }, severity: "error" | "warning" = "error"): DataQueryDiagnostic {
  return { severity, message, ...(source ? { source } : {}) };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function parseKeyValueBody(body: string): Map<string, string> {
  const out = new Map<string, string>();
  const lines = body.split("\n");
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index] || "";
    const match = /^(\s*)([A-Za-z0-9_-]+)\s*[:=]\s*(.*?)\s*$/.exec(line);
    if (!match) continue;
    const key = String(match[2] || "").toLowerCase();
    const value = String(match[3] || "").trim();
    if (value !== "|" && value !== ">") {
      out.set(key, value);
      continue;
    }

    const parentIndent = String(match[1] || "").length;
    const bodyLines: string[] = [];
    let next = index + 1;
    while (next < lines.length) {
      const candidate = lines[next] || "";
      if (!candidate.trim()) {
        bodyLines.push("");
        next++;
        continue;
      }
      const indent = /^\s*/.exec(candidate)?.[0].length || 0;
      if (indent <= parentIndent) break;
      bodyLines.push(candidate);
      next++;
    }
    const nonBlankIndents = bodyLines
      .filter((candidate) => candidate.trim())
      .map((candidate) => /^\s*/.exec(candidate)?.[0].length || 0);
    const trimIndent = nonBlankIndents.length > 0 ? Math.min(...nonBlankIndents) : 0;
    const multiline = bodyLines.map((candidate) => candidate.slice(trimIndent)).join(value === ">" ? " " : "\n").trim();
    out.set(key, multiline);
    index = next - 1;
  }
  return out;
}

function isSafeCredentialRef(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) return true;
  if (/^none$/i.test(trimmed)) return true;
  return /^(?:env|secret|config|profile):[A-Za-z0-9_.:-]+$/.test(trimmed);
}

function isSafeConfigRef(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) return true;
  return /^(?:[A-Za-z0-9_.-]+|(?:config|profile|env|file):[A-Za-z0-9_./:-]+)$/.test(trimmed);
}

function profileName(value: string): string {
  return value.trim().replace(/^profile:/i, "");
}

function parseFenceArgs(raw: string): { kind: string; args: string[] } | null {
  const tokens = raw.trim().split(/\s+/).filter(Boolean);
  const kind = String(tokens.shift() || "").toLowerCase();
  if (!kind) return null;
  return { kind, args: tokens };
}

function tokenizeBlockArgs(raw: string): string[] {
  return raw.trim().split(/\s+/).filter(Boolean);
}

function collectMarkdownFencedBlocks(input: string): FencedBlock[] {
  const lines = input.replace(/\r\n/g, "\n").split("\n");
  const blocks: FencedBlock[] = [];
  let i = 0;

  while (i < lines.length) {
    const opener = /^\s*```($|[^`].*)$/.exec(lines[i] || "");
    if (!opener) {
      i++;
      continue;
    }

    const parsed = parseFenceArgs(String(opener[1] || ""));
    if (!parsed) {
      i++;
      continue;
    }

    const bodyLines: string[] = [];
    let j = i + 1;
    while (j < lines.length && !/^\s*```\s*$/.test(lines[j] || "")) {
      bodyLines.push(lines[j] || "");
      j++;
    }

    blocks.push({
      kind: parsed.kind,
      args: parsed.args,
      line: i + 1,
      endLine: Math.min(j + 1, lines.length),
      body: bodyLines.join("\n").trim(),
    });
    i = j + 1;
  }

  return blocks;
}

function collectOrgStyleBlocks(input: string): FencedBlock[] {
  const lines = input.replace(/\r\n/g, "\n").split("\n");
  const blocks: FencedBlock[] = [];
  let pendingName = "";
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] || "";
    const keyword = parseKeywordLine(line);
    if (keyword) {
      pendingName = keyword.key === "NAME" ? keyword.value : pendingName;
      i++;
      continue;
    }

    const srcMatch = /^\s*#\+begin_src(?:\s+([A-Za-z0-9_-]+))?(.*)$/i.exec(line);
    const blockMatch = /^\s*#\+begin_(dataset|data|sql)\b(.*)$/i.exec(line);
    const kind = srcMatch ? String(srcMatch[1] || "").toLowerCase() : blockMatch ? String(blockMatch[1] || "").toLowerCase() : "";
    const argsRaw = srcMatch ? String(srcMatch[2] || "") : blockMatch ? String(blockMatch[2] || "") : "";

    if (kind) {
      const endPattern = srcMatch ? /^\s*#\+end_src\b/i : new RegExp(`^\\s*#\\+end_${kind}\\b`, "i");
      const bodyLines: string[] = [];
      let j = i + 1;
      while (j < lines.length && !endPattern.test(lines[j] || "")) {
        bodyLines.push(lines[j] || "");
        j++;
      }
      blocks.push({
        kind,
        args: [...(pendingName ? [`name=${pendingName}`] : []), ...tokenizeBlockArgs(argsRaw)],
        line: i + 1,
        endLine: Math.min(j + 1, lines.length),
        body: bodyLines.join("\n").trim(),
      });
      pendingName = "";
      i = j + 1;
      continue;
    }

    if (line.trim() !== "") pendingName = "";
    i++;
  }

  return blocks;
}

function collectFencedBlocks(input: string): FencedBlock[] {
  return [...collectMarkdownFencedBlocks(input), ...collectOrgStyleBlocks(input)].sort((a, b) => a.line - b.line || a.endLine - b.endLine);
}

function argValue(args: string[], keys: string[], opts: { separated?: boolean } = {}): string | undefined {
  const separated = opts.separated !== false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index] || "";
    for (const key of keys) {
      const match = new RegExp(`^:?${key}(?:=|:)(.+)$`, "i").exec(arg);
      if (match) return String(match[1] || "").trim();
      if (separated && new RegExp(`^:?${key}$`, "i").test(arg)) {
        const value = args[index + 1];
        if (value && !value.startsWith(":")) return value.trim();
      }
    }
  }
  return undefined;
}

function positionalArg(args: string[]): string | undefined {
  return args.find((arg, index) => Boolean(arg && !arg.includes("=") && !arg.startsWith(":") && !(args[index - 1] || "").startsWith(":")));
}

function parseKeywordLine(line: string): { key: string; value: string } | null {
  const match = /^\s*#\+([A-Za-z0-9_]+):[ \t]*(.*)$/.exec(line);
  if (!match) return null;
  return { key: String(match[1] || "").toUpperCase(), value: String(match[2] || "").trim() };
}

function parseNamedOrgTable(name: string, line: number, endLine: number, tableLines: string[]): NamedOrgTable | null {
  const rows = tableLines.map(parseOrgTableDataLine).filter((row): row is string[] => Array.isArray(row));
  const firstDataRow = rows.find((row) => !isOrgTableHline(row));
  if (!firstDataRow) return null;
  const headerIndex = rows.indexOf(firstDataRow);
  return {
    name,
    line,
    endLine,
    headers: firstDataRow,
    rows: rows.slice(headerIndex + 1).filter((row) => !isOrgTableHline(row)),
  };
}

function collectNamedOrgTables(input: string): Map<string, NamedOrgTable> {
  const lines = input.replace(/\r\n/g, "\n").split("\n");
  const tables = new Map<string, NamedOrgTable>();
  let pendingName = "";
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] || "";
    const keyword = parseKeywordLine(line);
    if (keyword) {
      pendingName = keyword.key === "NAME" ? keyword.value : pendingName;
      i++;
      continue;
    }

    if (isOrgTableDataLine(line)) {
      const tableStartLine = i + 1;
      const tableLines: string[] = [];
      while (i < lines.length && isOrgTableDataLine(lines[i] || "")) {
        tableLines.push(lines[i] || "");
        i++;
      }
      if (pendingName) {
        const table = parseNamedOrgTable(pendingName, tableStartLine, i, tableLines);
        if (table) tables.set(pendingName, table);
      }
      pendingName = "";
      continue;
    }

    if (line.trim() !== "") pendingName = "";
    i++;
  }

  return tables;
}

function parseDataset(block: FencedBlock, baseDir: string, namedTables: Map<string, NamedOrgTable>): { dataset?: DataQueryDataset; diagnostics: DataQueryDiagnostic[] } {
  const diagnostics: DataQueryDiagnostic[] = [];
  const id = argValue(block.args, ["id", "name"]) || positionalArg(block.args) || "";
  if (!id) diagnostics.push(diagnostic("Dataset block requires a name, e.g. ```dataset fetches", { line: block.line }));

  const values = parseKeyValueBody(block.body);
  const typeRaw = (values.get("type") || "").toLowerCase();
  const type = typeRaw === "org-table" ? "table" : typeRaw;
  const engineRaw = (values.get("engine") || "duckdb").toLowerCase();
  const sourcePath = values.get("path") || values.get("file") || "";
  const sourceUrl = values.get("url") || values.get("uri") || values.get("endpoint") || "";
  const sourceTable = values.get("source") || values.get("table") || "";
  const credentialRef = values.get("credential") || values.get("credentials") || values.get("auth") || values.get("auth-ref") || "";
  const configRef = values.get("config") || values.get("profile") || "";
  const remoteProfile = profileName(configRef);
  const query = values.get("query") || values.get("sql") || "";
  const questionRaw = values.get("question") || values.get("question-id") || values.get("card") || values.get("card-id") || "";
  const questionId = Number.parseInt(questionRaw, 10);
  const parametersRaw = values.get("parameters") || values.get("params") || "";
  const remoteType = type === "clickhouse" || type === "metabase";

  if (type === "celorga") {
    try {
      const celorga = parseCelorgaDataset(sourceTable, values.get("since") || "7d");
      if (sourcePath || sourceUrl || credentialRef || configRef || query || questionRaw || parametersRaw) throw new Error("Celorga datasets read their report's own corpus; path, URL, credentials, profiles, and remote queries are not accepted");
      if (engineRaw !== "duckdb") throw new Error("Celorga datasets require engine: duckdb");
      if (!id) throw new Error("Celorga dataset requires a name");
      return { dataset: { id, line: block.line, type: "celorga", engine: "duckdb", celorga }, diagnostics };
    } catch (error) {
      return { diagnostics: [diagnostic(error instanceof Error ? error.message : String(error), { line: block.line, blockId: id })] };
    }
  }

  if (!SUPPORTED_DATASET_TYPES.has(typeRaw)) {
    diagnostics.push(diagnostic("Dataset type must be csv, parquet, json, table, clickhouse, metabase, or celorga", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (engineRaw && engineRaw !== "duckdb") {
    diagnostics.push(diagnostic(`Unsupported dataset engine "${engineRaw}"; only duckdb is supported`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (remoteType && !remoteProfile) {
    diagnostics.push(diagnostic(`${type} dataset block requires profile: NAME`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (type === "clickhouse" && !query) {
    diagnostics.push(diagnostic("ClickHouse dataset block requires query: | followed by indented SQL", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (type === "metabase" && !query && (!questionRaw || !Number.isInteger(questionId) || questionId <= 0)) {
    diagnostics.push(diagnostic("Metabase dataset block requires either query: | SQL or a positive question: ID", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (type === "metabase" && query && questionRaw) {
    diagnostics.push(diagnostic("Metabase dataset block accepts only one of query: | SQL or question: ID", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (type === "table" && !sourceTable) {
    diagnostics.push(diagnostic("Table dataset block requires source: named_table", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (!remoteType && type !== "table" && !sourcePath && !sourceUrl) {
    diagnostics.push(diagnostic("Dataset block requires path: ./file.csv or url: https://example.com/file.csv", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (!remoteType && type !== "table" && sourcePath && sourceUrl) {
    diagnostics.push(diagnostic("Dataset block accepts only one of path/file or url/uri/endpoint", { line: block.line, ...(id ? { blockId: id } : {}) }));
  } else if (remoteType && (sourcePath || sourceUrl)) {
    diagnostics.push(diagnostic(`${type} dataset URLs come from the named profile; path/url is not accepted in the note`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  const table = type === "table" && sourceTable ? namedTables.get(sourceTable) : undefined;
  if (type === "table" && sourceTable && !table) {
    diagnostics.push(diagnostic(`No named org table found for dataset source "${sourceTable}"`, { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (credentialRef && !isSafeCredentialRef(credentialRef)) {
    diagnostics.push(diagnostic("Dataset credential/auth metadata must be a reference such as env:VAR, secret:NAME, config:NAME, profile:NAME, or none; inline secrets are not accepted", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  if (configRef && !isSafeConfigRef(configRef)) {
    diagnostics.push(diagnostic("Dataset config/profile metadata must be a reference such as config:NAME, profile:NAME, env:VAR, or file:PATH", { line: block.line, ...(id ? { blockId: id } : {}) }));
  }
  let parameters: unknown;
  if (parametersRaw) {
    try {
      parameters = JSON.parse(parametersRaw);
    } catch (error) {
      diagnostics.push(diagnostic(`Metabase parameters must be valid JSON: ${error instanceof Error ? error.message : String(error)}`, { line: block.line, ...(id ? { blockId: id } : {}) }));
    }
  }
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };

  if (type === "clickhouse") {
    return {
      dataset: {
        id,
        line: block.line,
        type,
        engine: "duckdb",
        profile: remoteProfile,
        query,
        ...(configRef ? { configRef } : {}),
      },
      diagnostics,
    };
  }

  if (type === "metabase") {
    return {
      dataset: {
        id,
        line: block.line,
        type,
        engine: "duckdb",
        profile: remoteProfile,
        ...(query ? { query } : { questionId }),
        ...(parameters !== undefined ? { parameters } : {}),
        ...(configRef ? { configRef } : {}),
      },
      diagnostics,
    };
  }

  if (type === "table" && table) {
    return {
      dataset: {
        id,
        line: block.line,
        type: "table",
        engine: "duckdb",
        ...(credentialRef ? { credentialRef } : {}),
        ...(configRef ? { configRef } : {}),
        sourceTable,
        source: { line: table.line, endLine: table.endLine },
        rowCount: table.rows.length,
      },
      diagnostics,
    };
  }

  const resolvedPath = sourcePath ? (path.isAbsolute(sourcePath) ? sourcePath : path.resolve(baseDir, sourcePath)) : "";
  return {
    dataset: {
      id,
      line: block.line,
      type: type as DataQueryDataset["type"],
      engine: "duckdb",
      ...(sourcePath ? { path: sourcePath, resolvedPath } : {}),
      ...(sourceUrl ? { url: sourceUrl } : {}),
      ...(credentialRef ? { credentialRef } : {}),
      ...(configRef ? { configRef } : {}),
    },
    diagnostics,
  };
}

function parseSqlBlock(block: FencedBlock): { sql?: DataQuerySqlBlock; diagnostics: DataQueryDiagnostic[] } {
  const resultId = argValue(block.args, ["id", "name"]) || argValue(block.args, ["results", "result"], { separated: false }) || positionalArg(block.args) || "";
  const sourceIds = (argValue(block.args, ["sources", "datasets"], { separated: false }) || "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  const artifact = argValue(block.args, ["artifact", "out", "output"]);
  const freshness = argValue(block.args, ["freshness", "ttl", "max-age"], { separated: false });
  const diagnostics: DataQueryDiagnostic[] = [];
  if (!resultId) diagnostics.push(diagnostic("SQL block requires results=NAME", { line: block.line }));
  if (!block.body.trim()) diagnostics.push(diagnostic("SQL block is empty", { line: block.line, ...(resultId ? { blockId: resultId } : {}) }));
  if (freshness && !/^[A-Za-z0-9_.:/+-]+$/.test(freshness)) {
    diagnostics.push(diagnostic("SQL result freshness metadata must be a compact token such as 1h, 24h, P1D, or manual", { line: block.line, ...(resultId ? { blockId: resultId } : {}) }));
  }
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };
  return { sql: { resultId, ...(sourceIds.length > 0 ? { sourceIds } : {}), ...(artifact ? { artifact } : {}), ...(freshness ? { freshness } : {}), line: block.line, endLine: block.endLine, sql: block.body.trim() }, diagnostics };
}

function hasSqlViewArg(block: FencedBlock): boolean {
  return block.args.some((arg) => /^:?view(?:=|:|$)/i.test(arg));
}

function parseSqlViewBlock(block: FencedBlock): { view?: DataQuerySqlView; diagnostics: DataQueryDiagnostic[] } {
  const viewId = argValue(block.args, ["view"]) || argValue(block.args, ["id", "name"]) || positionalArg(block.args) || "";
  const resultId = argValue(block.args, ["results", "result"], { separated: false });
  const diagnostics: DataQueryDiagnostic[] = [];
  if (resultId) diagnostics.push(diagnostic("SQL block cannot declare both view=NAME and results=NAME", { line: block.line, blockId: resultId }));
  if (!viewId) diagnostics.push(diagnostic("SQL view block requires view=NAME", { line: block.line }));
  if (!block.body.trim()) diagnostics.push(diagnostic("SQL view block is empty", { line: block.line, ...(viewId ? { blockId: viewId } : {}) }));
  if (diagnostics.some((item) => item.severity === "error")) return { diagnostics };
  return { view: { id: viewId, line: block.line, endLine: block.endLine, sql: block.body.trim() }, diagnostics };
}

function quoteIdentifier(value: string): string {
  return `"${value.replace(/"/g, '""')}"`;
}

function quoteString(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function readFunctionForType(type: DataQueryDataset["type"]): string {
  if (type === "parquet") return "read_parquet";
  if (type === "json") return "read_json_auto";
  return "read_csv_auto";
}

function sqlLiteral(value: string): string {
  const trimmed = value.trim();
  if (trimmed === "") return "NULL";
  if (/^-?(?:\d+|\d*\.\d+)$/.test(trimmed)) return trimmed;
  if (/^(?:true|false)$/i.test(trimmed)) return trimmed.toLowerCase();
  return quoteString(value);
}

function inlineOrgTableView(dataset: DataQueryDataset, table: NamedOrgTable): string {
  if (table.rows.length === 0) {
    const columns = table.headers.map((header) => `NULL AS ${quoteIdentifier(header)}`).join(", ");
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT ${columns} WHERE false;`;
  }

  const values = table.rows
    .map((row) => `(${table.headers.map((_, index) => sqlLiteral(row[index] || "")).join(", ")})`)
    .join(", ");
  const columns = table.headers.map(quoteIdentifier).join(", ");
  return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT * FROM (VALUES ${values}) AS t(${columns});`;
}

function sqlValue(value: unknown): string {
  if (value === null || value === undefined) return "NULL";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "NULL";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "object") return quoteString(JSON.stringify(value));
  return quoteString(String(value));
}

function inlineRemoteRowsView(dataset: DataQueryDataset, rows: Record<string, unknown>[]): string {
  if (dataset.celorga) {
    const schema = CELORGA_DATASET_SCHEMAS[dataset.celorga.source];
    const columns = Object.keys(schema);
    const projection = columns.map(column => `CAST(${rows.length ? quoteIdentifier(column) : "NULL"} AS ${schema[column as keyof typeof schema]}) AS ${quoteIdentifier(column)}`).join(", ");
    if (!rows.length) return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT ${projection} WHERE false;`;
    const values = rows.map(row => `(${columns.map(column => sqlValue(row[column])).join(", ")})`).join(", ");
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT ${projection} FROM (VALUES ${values}) AS t(${columns.map(quoteIdentifier).join(", ")});`;
  }
  const columns = Array.from(rows.reduce((keys, row) => {
    for (const key of Object.keys(row)) keys.add(key);
    return keys;
  }, new Set<string>()));
  if (columns.length === 0) {
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT NULL AS ${quoteIdentifier("_empty")} WHERE false;`;
  }
  if (rows.length === 0) {
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT ${columns.map((column) => `NULL AS ${quoteIdentifier(column)}`).join(", ")} WHERE false;`;
  }
  const values = rows
    .map((row) => `(${columns.map((column) => sqlValue(row[column])).join(", ")})`)
    .join(", ");
  return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT * FROM (VALUES ${values}) AS t(${columns.map(quoteIdentifier).join(", ")});`;
}

function viewSql(view: DataQuerySqlView): string {
  return `CREATE OR REPLACE VIEW ${quoteIdentifier(view.id)} AS SELECT * FROM (${view.sql.replace(/;\s*$/, "")}) AS org2_view;`;
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function buildDuckDbScript(
  datasets: DataQueryDataset[],
  views: DataQuerySqlView[],
  sql: string,
  namedTables: Map<string, NamedOrgTable>,
  remoteRows: Map<string, Record<string, unknown>[]> = new Map(),
): string {
  const setup = datasets.map((dataset) => {
    if (dataset.type === "clickhouse" || dataset.type === "metabase" || dataset.type === "celorga") {
      return inlineRemoteRowsView(dataset, remoteRows.get(dataset.id) || []);
    }
    if (dataset.type === "table" && dataset.sourceTable) {
      const table = namedTables.get(dataset.sourceTable);
      if (table) return inlineOrgTableView(dataset, table);
    }
    const readFn = readFunctionForType(dataset.type);
    return `CREATE OR REPLACE VIEW ${quoteIdentifier(dataset.id)} AS SELECT * FROM ${readFn}(${quoteString(dataset.url || dataset.resolvedPath || "")});`;
  });
  return [...setup, ...views.map(viewSql), sql.replace(/;\s*$/, "") + ";"].join("\n");
}

function parseDuckDbJson(stdout: string): Record<string, unknown>[] {
  const trimmed = stdout.trim();
  if (!trimmed) return [];
  const parsed = JSON.parse(trimmed);
  if (Array.isArray(parsed)) {
    if (parsed.every(isRecord)) return parsed;
    return parsed.map((value) => ({ value }));
  }
  if (isRecord(parsed) && Array.isArray(parsed.rows) && parsed.rows.every(isRecord)) return parsed.rows;
  if (isRecord(parsed)) return [parsed];
  return [{ value: parsed }];
}

async function runBundledDuckDb(script: string): Promise<Record<string, unknown>[]> {
  const connection = await DuckDBConnection.create();
  try {
    const reader = await connection.runAndReadAll(script);
    return reader.getRowObjectsJson() as Record<string, unknown>[];
  } finally {
    connection.closeSync();
  }
}

function formatCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

export function rowsToOrgTable(rows: Record<string, unknown>[]): string {
  const headers = Array.from(rows.reduce((keys, row) => {
    for (const key of Object.keys(row)) keys.add(key);
    return keys;
  }, new Set<string>()));
  if (headers.length === 0) return "| |\n|-|\n";

  const renderedRows = rows.map((row) => headers.map((header) => formatCell(row[header])));
  const widths = headers.map((header, index) => {
    const cells = renderedRows.map((row) => row[index] || "");
    return Math.max(header.length, ...cells.map((cell) => cell.length));
  });

  const rowLine = (cells: string[]) => `| ${cells.map((cell, index) => cell.padEnd(widths[index] || 1)).join(" | ")} |`;
  const separator = `|${widths.map((width) => "-".repeat(width + 2)).join("+")}|`;
  return [rowLine(headers), separator, ...renderedRows.map(rowLine)].join("\n") + "\n";
}

function localOrgTimestamp(date: Date, openingDelimiter: "[" | "<" = "["): string {
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  const timeZone = new Intl.DateTimeFormat("en-US", { timeZoneName: "short" })
    .formatToParts(date)
    .find((part) => part.type === "timeZoneName")
    ?.value
    .replace(/\s+/g, "");
  const closingDelimiter = openingDelimiter === "<" ? ">" : "]";
  return `${openingDelimiter}${formatLocalOrgDate(date)} ${hours}:${minutes}${timeZone ? ` ${timeZone}` : ""}${closingDelimiter}`;
}

function latestDataQueryRunAt(results: DataQueryResult[]): string | undefined {
  let latestValue: string | undefined;
  let latestTime = Number.NEGATIVE_INFINITY;
  for (const result of results) {
    const value = String(result.provenance?.ranAt || "").trim();
    const time = Date.parse(value);
    if (!value || Number.isNaN(time) || time < latestTime) continue;
    latestValue = value;
    latestTime = time;
  }
  return latestValue;
}

function updateDataNotebookRefreshMetadata(input: string, refreshedAt: string): string {
  const date = new Date(refreshedAt);
  if (Number.isNaN(date.getTime())) return input;

  let text = input;
  text = text.replace(
    /^(\s*#\+updated:\s*)(.*)$/im,
    (_match, prefix: string, currentValue: string) => {
      const current = String(currentValue || "").trim();
      const nextValue = current.startsWith("[")
        ? `[${formatLocalOrgDate(date)}]`
        : current.startsWith("<")
          ? `<${formatLocalOrgDate(date)}>`
          : formatLocalOrgDate(date).slice(0, 10);
      return `${prefix}${nextValue}`;
    },
  );
  text = text.replace(
    /^(\s*#\+property:\s+(?:CELORGA|ORG2)_OBSERVED_AT(?:\s+|=))(.*)$/im,
    (_match, prefix: string, currentValue: string) => {
      const current = String(currentValue || "").trim();
      const nextValue = current.startsWith("[")
        ? localOrgTimestamp(date)
        : current.startsWith("<")
          ? localOrgTimestamp(date, "<")
          : date.toISOString();
      return `${prefix}${nextValue}`;
    },
  );
  return text;
}

export function applyDataQueryResult(input: string, result: DataQueryResult): { text: string; changed: boolean } {
  if (!result.ok || !result.resultId || !result.orgTable || !result.source) {
    throw new Error("Cannot apply an unsuccessful or incomplete data query result");
  }
  const normalized = input.replace(/\r\n/g, "\n");
  const hadTrailingNewline = normalized.endsWith("\n");
  const lines = normalized.split("\n");
  if (hadTrailingNewline) lines.pop();
  const generated = result.orgTable.trimEnd().split("\n");
  const resultPattern = new RegExp(`^\\s*#\\+query-data:\\s+.*\\bresult=${result.resultId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:\\s|$)`, "i");
  const existingStart = lines.findIndex((line) => resultPattern.test(line));

  if (existingStart >= 0) {
    let existingEnd = existingStart + 1;
    while (existingEnd < lines.length) {
      const line = lines[existingEnd] || "";
      if (/^\s*#\+(?:name|results):/i.test(line) || isOrgTableDataLine(line)) {
        existingEnd++;
        continue;
      }
      break;
    }
    lines.splice(existingStart, existingEnd - existingStart, ...generated);
  } else {
    const insertIndex = Math.max(0, Math.min(lines.length, result.source.endLine));
    const before = lines.slice(0, insertIndex);
    const after = lines.slice(insertIndex);
    while (before.length > 0 && before[before.length - 1] === "") before.pop();
    while (after.length > 0 && after[0] === "") after.shift();
    lines.splice(0, lines.length, ...before, "", ...generated, "", ...after);
  }

  const text = `${lines.join("\n")}${hadTrailingNewline ? "\n" : ""}`;
  return { text, changed: text !== normalized };
}

export function applyDataQueryResults(
  input: string,
  results: DataQueryResult[],
): { text: string; changed: boolean; changedResultCount: number } {
  const ordered = [...results].sort((left, right) => {
    const leftLine = left.source?.endLine || left.source?.line || 0;
    const rightLine = right.source?.endLine || right.source?.line || 0;
    return rightLine - leftLine;
  });
  let text = input.replace(/\r\n/g, "\n");
  let changedResultCount = 0;
  for (const result of ordered) {
    const applied = applyDataQueryResult(text, result);
    text = applied.text;
    if (applied.changed) changedResultCount++;
  }
  const refreshedAt = latestDataQueryRunAt(results);
  if (refreshedAt) {
    text = updateDataNotebookRefreshMetadata(text, refreshedAt);
  }
  return {
    text,
    changed: text !== input.replace(/\r\n/g, "\n"),
    changedResultCount,
  };
}

function materializedResultTable(resultId: string, rows: Record<string, unknown>[], provenance: NonNullable<DataQueryResult["provenance"]>): string {
  const artifact = provenance.artifact ? ` artifact=${provenance.artifact}` : "";
  const freshness = provenance.freshness ? ` freshness=${provenance.freshness}` : "";
  const ranAt = provenance.ranAt ? ` ran_at=${provenance.ranAt}` : "";
  return `#+query-data: result=${resultId} rows=${rows.length}${artifact}${freshness} query_sha256=${provenance.querySha256} script_sha256=${provenance.scriptSha256}${ranAt}\n#+name: ${resultId}\n#+results: query-data-${resultId}\n${rowsToOrgTable(rows)}`;
}

function selectSqlBlockByLine(blocks: DataQuerySqlBlock[], line: number): DataQuerySqlBlock | undefined {
  return blocks.find((block) => line >= block.line && line <= block.endLine) || blocks.find((block) => block.line >= line);
}

function resultBlockMetadata(blocks: DataQuerySqlBlock[]): DataQueryResultBlock[] {
  return blocks.map((block) => ({
    resultId: block.resultId,
    ...(block.sourceIds ? { sourceIds: block.sourceIds } : {}),
    ...(block.artifact ? { artifact: block.artifact } : {}),
    ...(block.freshness ? { freshness: block.freshness } : {}),
    line: block.line,
    endLine: block.endLine,
  }));
}

function resultProvenance(
  selected: DataQuerySqlBlock,
  datasets: DataQueryDataset[],
  views: DataQuerySqlView[],
  script: string,
  outputArtifact?: string,
  ranAt?: string,
): NonNullable<DataQueryResult["provenance"]> {
  return {
    resultId: selected.resultId,
    ...(outputArtifact || selected.artifact ? { artifact: outputArtifact || selected.artifact } : {}),
    ...(selected.freshness ? { freshness: selected.freshness } : {}),
    ...(ranAt ? { ranAt } : {}),
    querySha256: sha256(selected.sql),
    scriptSha256: sha256(script),
    datasetIds: datasets.map((dataset) => dataset.id),
    viewIds: views.map((view) => view.id),
  };
}

function remoteDatasetRequest(dataset: DataQueryDataset): RemoteDatasetRequest | undefined {
  if (dataset.type === "clickhouse" && dataset.profile && dataset.query) {
    return { type: "clickhouse", profile: dataset.profile, query: dataset.query };
  }
  if (dataset.type === "metabase" && dataset.profile && dataset.questionId) {
    return {
      type: "metabase",
      profile: dataset.profile,
      questionId: dataset.questionId,
      ...(dataset.parameters !== undefined ? { parameters: dataset.parameters } : {}),
    };
  }
  if (dataset.type === "metabase" && dataset.profile && dataset.query) {
    return {
      type: "metabase",
      profile: dataset.profile,
      query: dataset.query,
      ...(dataset.parameters !== undefined ? { parameters: dataset.parameters } : {}),
    };
  }
  return undefined;
}

function resolveDataSources(file: string | undefined, explicit: Record<string, Org2DataSourceConfig> | undefined): Record<string, Org2DataSourceConfig> | undefined {
  if (explicit) return explicit;
  const startDir = file ? path.dirname(path.resolve(file)) : process.cwd();
  const configPath = findConfigFile(startDir);
  return configPath ? loadConfig(configPath).dataSources : undefined;
}

export async function runOrg2DataQuery(input: string, opts: RunDataQueryOptions = {}): Promise<DataQueryResult> {
  const file = opts.file;
  const baseDir = file ? path.dirname(path.resolve(file)) : process.cwd();
  const diagnostics: DataQueryDiagnostic[] = [];
  const blocks = collectFencedBlocks(input);
  const namedTables = collectNamedOrgTables(input);
  const datasets: DataQueryDataset[] = [];
  const views: DataQuerySqlView[] = [];
  const sqlBlocks: DataQuerySqlBlock[] = [];

  for (const block of blocks) {
    if (block.kind === "dataset" || block.kind === "data") {
      const parsed = parseDataset(block, baseDir, namedTables);
      diagnostics.push(...parsed.diagnostics);
      if (parsed.dataset) datasets.push(parsed.dataset);
    } else if (block.kind === "sql") {
      if (hasSqlViewArg(block)) {
        const parsed = parseSqlViewBlock(block);
        diagnostics.push(...parsed.diagnostics);
        if (parsed.view) views.push(parsed.view);
      } else {
        const parsed = parseSqlBlock(block);
        diagnostics.push(...parsed.diagnostics);
        if (parsed.sql) sqlBlocks.push(parsed.sql);
      }
    }
  }

  const seenDatasetIds = new Set<string>();
  for (const dataset of datasets) {
    if (seenDatasetIds.has(dataset.id)) {
      diagnostics.push(diagnostic(`Duplicate dataset block "${dataset.id}"`, { line: dataset.line, blockId: dataset.id }));
    }
    seenDatasetIds.add(dataset.id);
  }

  const seenViewIds = new Set<string>();
  for (const view of views) {
    if (seenViewIds.has(view.id)) {
      diagnostics.push(diagnostic(`Duplicate SQL view block "${view.id}"`, { line: view.line, blockId: view.id }));
    }
    if (seenDatasetIds.has(view.id)) {
      diagnostics.push(diagnostic(`SQL view block "${view.id}" conflicts with a dataset block of the same name`, { line: view.line, blockId: view.id }));
    }
    seenViewIds.add(view.id);
  }

  const seenResultIds = new Set<string>();
  for (const block of sqlBlocks) {
    if (seenResultIds.has(block.resultId)) {
      diagnostics.push(diagnostic(`Duplicate SQL result block "${block.resultId}"`, { line: block.line, blockId: block.resultId }));
    }
    seenResultIds.add(block.resultId);
    for (const sourceId of block.sourceIds || []) {
      if (!seenDatasetIds.has(sourceId) && !seenViewIds.has(sourceId)) {
        diagnostics.push(diagnostic(`SQL result block "${block.resultId}" declares unknown source "${sourceId}"`, { line: block.line, blockId: block.resultId }));
      }
    }
  }

  const resultBlocks = resultBlockMetadata(sqlBlocks);
  const selectedByLine = opts.resultLine && opts.resultLine > 0 ? selectSqlBlockByLine(sqlBlocks, opts.resultLine) : undefined;
  const resultId = opts.resultId?.trim() || selectedByLine?.resultId || (sqlBlocks.length === 1 ? sqlBlocks[0]?.resultId : "");
  const selected = selectedByLine || (resultId ? sqlBlocks.find((block) => block.resultId === resultId) : undefined);
  const activeDatasets = selected?.sourceIds?.length
    ? datasets.filter((dataset) => selected.sourceIds?.includes(dataset.id))
    : datasets;
  const remoteDatasets = activeDatasets.filter((dataset) => dataset.type === "clickhouse" || dataset.type === "metabase");
  let dataSources: Record<string, Org2DataSourceConfig> | undefined;
  if (remoteDatasets.length > 0) {
    try {
      dataSources = resolveDataSources(file, opts.dataSources);
      for (const dataset of remoteDatasets) {
        const request = remoteDatasetRequest(dataset);
        const profile = request ? dataSources?.[request.profile] : undefined;
        if (!request) continue;
        if (!profile) diagnostics.push(diagnostic(`No data source profile named "${request.profile}" was found in celorga.json`, { line: dataset.line, blockId: dataset.id }));
        else if (profile.type !== request.type) diagnostics.push(diagnostic(`Data source profile "${request.profile}" is ${profile.type}, but dataset "${dataset.id}" requires ${request.type}`, { line: dataset.line, blockId: dataset.id }));
      }
    } catch (error) {
      diagnostics.push(diagnostic(error instanceof Error ? error.message : String(error)));
    }
  }

  if (opts.inspectOnly) {
    if (sqlBlocks.length === 0) diagnostics.push(diagnostic("No SQL result blocks found"));
    if (opts.resultLine && opts.resultLine > 0 && !selectedByLine) diagnostics.push(diagnostic(`No SQL result block found at or after line ${opts.resultLine}`, { line: opts.resultLine }));
    if (resultId && !selected) diagnostics.push(diagnostic(`No SQL result block found for "${resultId}"`, { blockId: resultId }));
    const ok = !diagnostics.some((item) => item.severity === "error");
    const script = ok && selected ? buildDuckDbScript(activeDatasets, views, selected.sql, namedTables) : "";
    const provenance = ok && selected ? resultProvenance(selected, activeDatasets, views, script, opts.outputArtifact) : undefined;
    return {
      ok,
      mode: "inspect",
      engine: "duckdb",
      ...(selected ? { resultId: selected.resultId, source: { ...(file ? { file } : {}), line: selected.line, endLine: selected.endLine } } : resultId ? { resultId } : {}),
      datasets,
      views,
      resultBlocks,
      rowCount: 0,
      rows: [],
      ...(provenance ? { provenance } : {}),
      ...(opts.includeScript && script ? { duckdbScript: script } : {}),
      diagnostics,
    };
  }

  if (datasets.length === 0) diagnostics.push(diagnostic("No dataset blocks found"));
  if (sqlBlocks.length === 0) diagnostics.push(diagnostic("No SQL result blocks found"));
  if (!resultId && sqlBlocks.length > 1) diagnostics.push(diagnostic("Multiple SQL result blocks found; pass --results NAME or --line N"));
  if (opts.resultLine && opts.resultLine > 0 && !selectedByLine) diagnostics.push(diagnostic(`No SQL result block found at or after line ${opts.resultLine}`, { line: opts.resultLine }));
  if (resultId && !selected) diagnostics.push(diagnostic(`No SQL result block found for "${resultId}"`, { blockId: resultId }));

  if (diagnostics.some((item) => item.severity === "error") || !selected) {
    return { ok: false, mode: "execute", engine: "duckdb", ...(resultId ? { resultId } : {}), datasets, views, resultBlocks, rowCount: 0, rows: [], diagnostics };
  }

  const remoteRows = new Map<string, Record<string, unknown>[]>();
  const localDatasets = activeDatasets.filter(dataset => dataset.celorga);
  if (localDatasets.length) {
    try {
      const load = createCelorgaDatasetLoader(file, localDatasets.map(dataset => dataset.celorga!), opts.ranAt ? new Date(opts.ranAt) : new Date());
      for (const dataset of localDatasets) {
        const loaded = load(dataset.celorga!);
        remoteRows.set(dataset.id, loaded.rows);
        dataset.rowCount = loaded.rows.length;
      }
    } catch (error) {
      diagnostics.push(diagnostic(`Failed to load Celorga dataset: ${error instanceof Error ? error.message : String(error)}`));
    }
  }
  await Promise.all(remoteDatasets.map(async (dataset) => {
    const request = remoteDatasetRequest(dataset);
    if (!request) return;
    try {
      const loaded = await loadRemoteDataset(request, dataSources, opts.env);
      remoteRows.set(dataset.id, loaded.rows);
      dataset.rowCount = loaded.rows.length;
    } catch (error) {
      diagnostics.push(diagnostic(`Failed to load dataset "${dataset.id}": ${error instanceof Error ? error.message : String(error)}`, { line: dataset.line, blockId: dataset.id }));
    }
  }));
  if (diagnostics.some((item) => item.severity === "error")) {
    return { ok: false, mode: "execute", engine: "duckdb", resultId: selected.resultId, datasets, views, resultBlocks, rowCount: 0, rows: [], diagnostics };
  }

  const script = buildDuckDbScript(activeDatasets, views, selected.sql, namedTables, remoteRows);
  const provenance = resultProvenance(selected, activeDatasets, views, script, opts.outputArtifact, opts.ranAt || new Date().toISOString());
  let rows: Record<string, unknown>[] = [];
  if (opts.duckdbPath) {
    const child = spawnSync(opts.duckdbPath, ["-json", ":memory:"], {
      encoding: "utf8",
      input: script,
      maxBuffer: 1024 * 1024 * 16,
    });
    if (child.error) {
      diagnostics.push(diagnostic(`Failed to run DuckDB CLI "${opts.duckdbPath}": ${child.error.message}`, { line: selected.line, blockId: selected.resultId }));
    } else if (child.status !== 0) {
      const stderr = String(child.stderr || "").trim();
      diagnostics.push(diagnostic(`DuckDB query failed${stderr ? `: ${stderr}` : ""}`, { line: selected.line, blockId: selected.resultId }));
    }
    try {
      if (!diagnostics.some((item) => item.severity === "error")) {
        rows = parseDuckDbJson(String(child.stdout || ""));
      }
    } catch (err) {
      diagnostics.push(diagnostic(`DuckDB did not return JSON rows: ${err instanceof Error ? err.message : String(err)}`, { line: selected.line, blockId: selected.resultId }));
    }
  } else {
    try {
      rows = await runBundledDuckDb(script);
    } catch (error) {
      diagnostics.push(diagnostic(`DuckDB query failed: ${error instanceof Error ? error.message : String(error)}`, { line: selected.line, blockId: selected.resultId }));
    }
  }

  const ok = !diagnostics.some((item) => item.severity === "error");
  return {
    ok,
    mode: "execute",
    engine: "duckdb",
    resultId: selected.resultId,
    source: { ...(file ? { file } : {}), line: selected.line, endLine: selected.endLine },
    datasets,
    views,
    resultBlocks,
    rowCount: rows.length,
    rows,
    provenance,
    ...(ok ? { orgTable: materializedResultTable(selected.resultId, rows, provenance) } : {}),
    ...(opts.includeScript ? { duckdbScript: script } : {}),
    diagnostics,
  };
}
