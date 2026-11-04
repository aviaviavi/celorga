import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { canonicalNoteTargets, type CanonicalNoteTarget } from "./canonicalNoteTargets.js";
import { loadConfig, resolveFilesFromDir } from "./config.js";
import { guardedContentRevision, guardedWriteFile, readGuardedFile } from "./guardedFile.js";
import { configFilePath } from "./brandNames.js";
import { parseIdLinkTarget } from "./linkSearch.js";

export type CanvasObject = Record<string, unknown>;
export interface JSONCanvasNode extends CanvasObject {
  id: string; type: string; x: number; y: number; width: number; height: number;
}
export interface JSONCanvasEdge extends CanvasObject { id: string; fromNode: string; toNode: string }
export interface JSONCanvasDocument extends CanvasObject { nodes?: JSONCanvasNode[]; edges?: JSONCanvasEdge[] }
export type JSONCanvasOperation =
  | { action: "add-node"; node: JSONCanvasNode }
  | { action: "update-node"; id: string; patch: CanvasObject }
  | { action: "remove-node"; id: string }
  | { action: "add-edge"; edge: JSONCanvasEdge }
  | { action: "update-edge"; id: string; patch: CanvasObject }
  | { action: "remove-edge"; id: string };

const MAX_BYTES = 8 * 1024 * 1024;
const SIDES = ["top", "right", "bottom", "left"];
const ENDS = ["none", "arrow"];
const IMAGE_TYPES: Record<string, string> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" };

function object(value: unknown, label: string): asserts value is CanvasObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
}
function string(value: unknown, label: string): asserts value is string {
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
}
function optionalString(value: unknown, label: string) { if (value !== undefined) string(value, label); }
function enumValue(value: unknown, allowed: string[], label: string) {
  if (value !== undefined && !allowed.includes(String(value))) throw new Error(`${label} must be ${allowed.join(" or ")}`);
}
function color(value: unknown) {
  if (value !== undefined && (typeof value !== "string" || !/^(?:#[0-9a-fA-F]{6}|[1-6])$/.test(value))) throw new Error("Canvas color must be #RRGGBB or a preset 1–6");
}

/** JSON Canvas 1.0; unknown fields and future node types remain in the document. */
export function parseJSONCanvas(text: string): JSONCanvasDocument {
  if (Buffer.byteLength(text) > MAX_BYTES) throw new Error("Canvas exceeds the 8 MiB document limit");
  const document: unknown = JSON.parse(text);
  object(document, "Canvas");
  if (document.nodes !== undefined && !Array.isArray(document.nodes)) throw new Error("nodes must be an array");
  if (document.edges !== undefined && !Array.isArray(document.edges)) throw new Error("edges must be an array");
  const nodes = (document.nodes || []) as unknown[];
  const edges = (document.edges || []) as unknown[];
  if (nodes.length > 1000 || edges.length > 5000) throw new Error("Canvas exceeds 1000 nodes or 5000 edges");
  const ids = new Set<string>();
  for (const [index, node] of nodes.entries()) {
    object(node, `Node ${index}`);
    string(node.id, "Node id"); string(node.type, "Node type");
    if (!node.id || ids.has(node.id)) throw new Error(`Duplicate or empty node ID: ${node.id}`);
    ids.add(node.id);
    for (const key of ["x", "y", "width", "height"]) {
      if (!Number.isSafeInteger(node[key]) || Math.abs(Number(node[key])) > 1_000_000) throw new Error(`Node ${node.id} ${key} must be an integer within ±1000000`);
    }
    if (Number(node.width) <= 0 || Number(node.height) <= 0) throw new Error("Canvas node dimensions must be positive");
    color(node.color);
    if (node.type === "text") string(node.text, "Text node text");
    if (node.type === "file") {
      string(node.file, "File node file");
      optionalString(node.subpath, "File subpath");
      if (typeof node.subpath === "string" && !node.subpath.startsWith("#")) throw new Error("File subpath must start with #");
    }
    if (node.type === "link") string(node.url, "Link node url");
    if (node.type === "group") {
      optionalString(node.label, "Group label"); optionalString(node.background, "Group background");
      enumValue(node.backgroundStyle, ["cover", "ratio", "repeat"], "Group backgroundStyle");
    }
    optionalString(node.org2Ref, "org2Ref");
  }
  const edgeIds = new Set<string>();
  for (const [index, edge] of edges.entries()) {
    object(edge, `Edge ${index}`);
    string(edge.id, "Edge id"); string(edge.fromNode, "Edge fromNode"); string(edge.toNode, "Edge toNode");
    if (!edge.id || edgeIds.has(edge.id)) throw new Error(`Duplicate or empty edge ID: ${edge.id}`);
    edgeIds.add(edge.id);
    if (!ids.has(edge.fromNode) || !ids.has(edge.toNode)) throw new Error(`Edge ${edge.id} references a missing node`);
    enumValue(edge.fromSide, SIDES, "fromSide"); enumValue(edge.toSide, SIDES, "toSide");
    enumValue(edge.fromEnd, ENDS, "fromEnd"); enumValue(edge.toEnd, ENDS, "toEnd");
    optionalString(edge.label, "Edge label"); color(edge.color);
  }
  return document as JSONCanvasDocument;
}

function isSymbolicLink(file: string): boolean {
  try { return fs.lstatSync(file).isSymbolicLink(); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return false; throw error; }
}

function canvasRelativePath(root: string, file: string): string | undefined {
  const rawRoot = path.resolve(root);
  const canonicalRoot = fs.realpathSync(rawRoot);
  const candidate = path.resolve(rawRoot, file);
  const isInside = (relative: string) => Boolean(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
  let relative = path.relative(rawRoot, candidate);
  // Files discovery returns canonical paths, while native URLs may retain a
  // corpus-root alias such as /tmp. Accept either root spelling, but do not
  // resolve the candidate: symlinks below the root must still be rejected.
  if (!isInside(relative)) relative = path.relative(canonicalRoot, candidate);
  if (isInside(relative)) return relative;
  // Native file panels can use another spelling of a parent directory (for
  // example /var while Node uses /private/var). Find the first ancestor that
  // names this corpus, then retain every segment below it for symlink checks.
  const ancestors: string[] = [];
  for (let parent = path.dirname(candidate);; parent = path.dirname(parent)) {
    ancestors.push(parent);
    if (parent === path.dirname(parent)) break;
  }
  for (const parent of ancestors.reverse()) {
    try {
      if (fs.realpathSync(parent) === canonicalRoot) return path.relative(parent, candidate) || undefined;
    } catch (error) {
      if (!["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
    }
  }
  return undefined;
}

/** Only .canvas files inside the active corpus are mutated; never follow symlinks. */
export function scopedCanvasPath(root: string, file: string, write = false): string {
  const relative = canvasRelativePath(root, file);
  if (relative === undefined) throw new Error("Canvas path must be inside the active corpus");
  const parts = relative.split(path.sep);
  if (parts.some(part => part.startsWith(".")) || (write && parts[0]!.toLowerCase() === "raw")) throw new Error("Canvas writes cannot target raw or hidden corpus state");
  let current = fs.realpathSync(root);
  for (const part of parts) {
    current = path.join(current, part);
    if (isSymbolicLink(current)) throw new Error("Canvas paths cannot traverse symlinks");
  }
  if (path.extname(current).toLowerCase() !== ".canvas") throw new Error("Canvas files must use the .canvas extension");
  return current;
}

function resourcePath(root: string, file: string): string {
  if (!file || path.isAbsolute(file) || file.includes("\\")) throw new Error("Canvas resource paths must be relative to the active corpus");
  const rawRoot = fs.realpathSync(root);
  const resolved = path.resolve(rawRoot, file);
  const relative = path.relative(rawRoot, resolved);
  if (!relative || relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) throw new Error("Canvas resource escapes the active corpus");
  let current = rawRoot;
  for (const part of relative.split(path.sep)) {
    if (part.startsWith(".")) throw new Error("Hidden canvas resources are not loaded");
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error("Canvas resources cannot traverse symlinks");
  }
  if (!fs.statSync(current).isFile()) throw new Error("Canvas resource is not a file");
  return current;
}

function corpusNotes(root: string): string[] {
  const configFile = configFilePath(root);
  const ignores = fs.existsSync(configFile) ? loadConfig(configFile).ignorePatterns || [] : [];
  return resolveFilesFromDir(root, ["**/*.org", "**/*.org2"], ["**/raw", "**/archive", "**/archives", "**/sync-conflicts", "**/node_modules", "**/dist", "**/build", "**/DerivedData", ...ignores])
    .filter(file => {
      const relative = path.relative(root, file);
      if (relative.split(path.sep).some(part => part.startsWith(".") || ["raw", "archive", "archives", "sync-conflicts"].includes(part.toLowerCase()))) return false;
      try { return resourcePath(root, relative) === path.resolve(file); }
      catch { return false; }
    });
}

export function canvasTargets(root: string, query = "") {
  root = fs.realpathSync(root);
  const targets = corpusNotes(root).flatMap(file => canonicalNoteTargets(root, file));
  const needle = query.trim().toLowerCase();
  const matches = targets.filter(node => (node.kind === "file" || node.id) && (!needle || `${node.title} ${node.file} ${node.id || ""}`.toLowerCase().includes(needle)));
  return { $schema: "org2:canvas-targets:v1", targets: matches.slice(0, 200).map(node => ({
    title: node.title, file: node.file, line: node.sourceRange.startLine, id: node.id,
    ...(node.id ? { org2Ref: `id:${node.id}`, ...(node.kind === "heading" ? { subpath: `#id:${node.id}` } : {}) } : {}),
  })), truncated: matches.length > 200 };
}

export interface CanvasResource {
  status: "ready" | "missing" | "ambiguous" | "unsupported";
  title: string;
  message?: string;
  file?: string;
  line?: number;
  id?: string | null;
  text?: string;
  imageData?: string;
  imageMime?: string;
  url?: string;
}

function nodeResource(root: string, node: JSONCanvasNode, allNodes: () => CanonicalNoteTarget[], imageBudget: { remaining: number }): CanvasResource {
  const title = String(node.label || node.file || node.url || node.type);
  try {
    if (node.type === "text") return { status: "ready", title: "Text", text: String(node.text) };
    if (node.type === "link") {
      const url = new URL(String(node.url));
      if (!["https:", "http:", "mailto:"].includes(url.protocol)) return { status: "unsupported", title, message: "This URL scheme is not opened by Canvas." };
      return { status: "ready", title, url: url.href };
    }
    if (node.type === "group" && !node.background) return { status: "ready", title: String(node.label || "Group") };
    if (!["file", "group"].includes(node.type)) return { status: "unsupported", title, message: "Unknown node type retained for roundtrip." };
    const idRef = typeof node.org2Ref === "string" && node.org2Ref.startsWith("id:")
      ? parseIdLinkTarget(node.org2Ref)?.id : typeof node.subpath === "string" && node.subpath.startsWith("#id:") ? node.subpath.slice(4) : undefined;
    let targetNode: CanonicalNoteTarget | undefined;
    let file: string;
    if (idRef) {
      const matches = allNodes().filter(candidate => candidate.id?.toLowerCase() === idRef.toLowerCase());
      if (matches.length !== 1) return { status: matches.length ? "ambiguous" : "missing", title, message: `Stable ID ${idRef} resolves to ${matches.length} sources.` };
      targetNode = matches[0]!;
      file = resourcePath(root, targetNode.file);
    } else {
      file = resourcePath(root, String(node.type === "group" ? node.background : node.file));
    }
    const imageMime = IMAGE_TYPES[path.extname(file).toLowerCase()];
    if (imageMime) {
      const bytes = fs.statSync(file).size;
      if (bytes > MAX_BYTES || bytes > imageBudget.remaining) return { status: "unsupported", title, message: "Image exceeds the 8 MiB per-image or 16 MiB board preview limit." };
      imageBudget.remaining -= bytes;
      return { status: "ready", title, file, imageMime, imageData: fs.readFileSync(file).toString("base64") };
    }
    if ([".org", ".org2"].includes(path.extname(file).toLowerCase())) {
      if (fs.statSync(file).size > MAX_BYTES) return { status: "unsupported", title, message: "Note exceeds 8 MiB preview limit." };
      if (!targetNode) {
        const nodes = canonicalNoteTargets(fs.realpathSync(root), file);
        const subpath = typeof node.subpath === "string" ? node.subpath.slice(1) : "";
        const matches = subpath ? nodes.filter(candidate => candidate.kind === "heading" && (candidate.title === subpath || candidate.properties.CUSTOM_ID === subpath)) : nodes.filter(candidate => candidate.kind === "file");
        if (matches.length !== 1) return { status: matches.length ? "ambiguous" : "missing", title, message: "Heading subpath does not identify one source." };
        targetNode = matches[0]!;
      }
      return { status: "ready", title: targetNode.title, file, line: targetNode.sourceRange.startLine, id: targetNode.id, text: targetNode.snippet.slice(0, 1200) };
    }
    if ([".canvas", ".pdf", ".md", ".txt", ".csv", ".mp3", ".wav", ".m4a", ".mp4", ".mov"].includes(path.extname(file).toLowerCase())) {
      return { status: "ready", title, file, line: 1, message: "Attachment; open its source to view." };
    }
    return { status: "unsupported", title, message: "Attachment type retained without an automatic open action." };
  } catch (error) {
    return { status: "missing", title, message: error instanceof Error ? error.message : String(error) };
  }
}

export function showJSONCanvas(root: string, file: string) {
  const scoped = scopedCanvasPath(root, file);
  if (fs.statSync(scoped).size > MAX_BYTES) throw new Error("Canvas exceeds the 8 MiB document limit");
  const snapshot = readGuardedFile(scoped);
  const document = parseJSONCanvas(snapshot.content);
  const canonicalRoot = fs.realpathSync(root);
  let targetsInCorpus: CanonicalNoteTarget[] | undefined;
  const allNodes = () => targetsInCorpus ||= corpusNotes(canonicalRoot).flatMap(file => canonicalNoteTargets(canonicalRoot, file));
  const imageBudget = { remaining: 16 * 1024 * 1024 };
  return {
    $schema: "org2:canvas:v1", file: scoped, revision: snapshot.revision, document,
    resources: Object.fromEntries((document.nodes || []).map(node => [node.id, nodeResource(root, node, allNodes, imageBudget)])),
  };
}

export function applyJSONCanvasOperations(document: JSONCanvasDocument, operations: JSONCanvasOperation[]): JSONCanvasDocument {
  if (!Array.isArray(operations) || operations.length > 100) throw new Error("Canvas edits require at most 100 operations");
  const result: JSONCanvasDocument = JSON.parse(JSON.stringify(document));
  for (const operation of operations) {
    object(operation, "Operation");
    switch (operation.action) {
      case "add-node":
        if (operation.node?.type === "group") (result.nodes ||= []).unshift(operation.node);
        else (result.nodes ||= []).push(operation.node);
        break;
      case "add-edge":
        (result.edges ||= []).push(operation.edge);
        break;
      case "update-node":
      case "update-edge": {
        object(operation.patch, "Patch");
        if (Object.hasOwn(operation.patch, "id")) throw new Error("Canvas IDs cannot be changed by a patch");
        const item = (operation.action === "update-node" ? result.nodes : result.edges)?.find(item => item.id === operation.id);
        if (!item) throw new Error(`Canvas item ${operation.id} no longer exists`);
        // JSON properties are copied without interpreting prototype keys.
        for (const [key, value] of Object.entries(operation.patch)) Object.defineProperty(item, key, { value, enumerable: true, configurable: true, writable: true });
        break;
      }
      case "remove-node":
        if (!result.nodes?.some(node => node.id === operation.id)) throw new Error(`Canvas node ${operation.id} no longer exists`);
        result.nodes = result.nodes.filter(node => node.id !== operation.id);
        if (result.edges) result.edges = result.edges.filter(edge => edge.fromNode !== operation.id && edge.toNode !== operation.id);
        break;
      case "remove-edge":
        if (!result.edges?.some(edge => edge.id === operation.id)) throw new Error(`Canvas edge ${operation.id} no longer exists`);
        result.edges = result.edges.filter(edge => edge.id !== operation.id);
        break;
      default: throw new Error(`Unknown canvas operation: ${String((operation as CanvasObject).action)}`);
    }
  }
  return parseJSONCanvas(JSON.stringify(result));
}

export function editJSONCanvas(root: string, file: string, revision: string, operations: JSONCanvasOperation[], apply = false) {
  const scoped = scopedCanvasPath(root, file, true);
  const snapshot = readGuardedFile(scoped);
  if (snapshot.revision !== revision) throw new Error("Canvas changed since it was opened. Reload before editing.");
  const document = applyJSONCanvasOperations(parseJSONCanvas(snapshot.content), operations);
  const text = JSON.stringify(document, null, 2) + "\n";
  if (apply) guardedWriteFile(scoped, text, { expectedRevision: revision, preserveMode: true });
  return { $schema: "org2:canvas-edit:v1", file: scoped, applied: apply, revision: guardedContentRevision(text), document };
}

export function createJSONCanvas(root: string, file: string, apply = false, sourceText?: string) {
  const scoped = scopedCanvasPath(root, file, true);
  const text = sourceText ?? JSON.stringify({ nodes: [], edges: [] }, null, 2) + "\n";
  const document = parseJSONCanvas(text);
  if (fs.existsSync(scoped)) throw new Error("Canvas destination already exists; choose another file name.");
  if (apply) guardedWriteFile(scoped, text, { expectedRevision: null });
  return { $schema: "org2:canvas-edit:v1", file: scoped, applied: apply, revision: guardedContentRevision(text), document };
}

export function exportJSONCanvas(root: string, file: string, out: string, apply = false) {
  const snapshot = readGuardedFile(scopedCanvasPath(root, file));
  parseJSONCanvas(snapshot.content);
  let output = path.resolve(out);
  if (canvasRelativePath(root, output) !== undefined) output = scopedCanvasPath(root, output, true);
  if (path.extname(output).toLowerCase() !== ".canvas") throw new Error("Export must use the .canvas extension");
  if (fs.existsSync(output) || isSymbolicLink(output)) throw new Error("Export destination exists; choose another file name.");
  // Explicit export destinations may be outside the corpus. Reject symlink parents.
  let parent = path.dirname(output);
  while (parent !== path.dirname(parent)) {
    if (isSymbolicLink(parent)) throw new Error("Export cannot traverse symlinks");
    parent = path.dirname(parent);
  }
  if (apply) guardedWriteFile(output, snapshot.content, { expectedRevision: null });
  return { $schema: "org2:canvas-export:v1", file: snapshot.file, output, applied: apply, revision: snapshot.revision };
}

export function newCanvasID(): string { return crypto.randomUUID(); }
