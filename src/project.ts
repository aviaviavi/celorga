import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { parseOrgToCanonicalAst } from "./parser.js";
import { loadConfig, resolveFilesFromDir } from "./config.js";
import { guardedContentRevision, guardedWriteFile } from "./guardedFile.js";
import type { Node } from "./ast.js";
import { configFilePath, isBrandName } from "./brandNames.js";
import { isProjectThreadsBlock, PROJECT_THREADS_BLOCK_SOURCE } from "./projectThreadsView.js";

export const PROJECT_COLORS = ["blue", "teal", "green", "orange", "red", "purple", "gray"] as const;
export interface ProjectNote {
  id: string; title: string; color: string; file: string; relativePath: string;
  revision: string; threadIDs: string[]; brief: string; briefTruncated: boolean;
}
const marker = /^#\+(?:CELORGA|ORG2)_KIND:\s*project\s*$/im;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const maxBytes = 1024 * 1024;
function config(root: string) {
  const file = configFilePath(root);
  return fs.existsSync(file) ? loadConfig(file) : {};
}
function inside(root: string, file: string): string {
  const base = fs.realpathSync(root);
  const target = path.resolve(root, file);
  let ancestor = target;
  while (!fs.existsSync(ancestor)) ancestor = path.dirname(ancestor);
  const resolved = path.resolve(fs.realpathSync(ancestor), path.relative(ancestor, target));
  const relative = path.relative(base, resolved);
  if (!relative || relative.startsWith(".." + path.sep) || relative === ".." || path.isAbsolute(relative)) throw new Error("Project notes must stay inside the corpus");
  if (![".org", ".org2"].includes(path.extname(target))) throw new Error("A project must be an .org file");
  return target;
}
function document(raw: string) {
  return parseOrgToCanonicalAst(raw.replace(/\r\n?/g, "\n"), { sourceRanges: true });
}
function keywords(raw: string) {
  return document(raw).children.filter(n => n.type === "KeywordLine");
}
export function parseProjectNote(root: string, file: string, raw: string): ProjectNote {
  const doc = document(raw);
  const keys = doc.children.filter(n => n.type === "KeywordLine");
  const value = (key: string) => {
    const matches = keys.filter(n => isBrandName(n.keyRaw.toUpperCase(), key));
    if (matches.length > 1) throw new Error(`Duplicate project metadata: ${key}`);
    return matches[0]?.valueRaw.trim() ?? "";
  };
  if (value("ORG2_KIND") !== "project") throw new Error("Not a project note");
  const drawer = doc.children.find(n => n.type === "PropertyDrawer");
  const id = drawer?.type === "PropertyDrawer" ? drawer.properties.find(p => p.key.toUpperCase() === "ID")?.value.trim() : "";
  if (!id || id.length > 200 || /[\s\[\]]/.test(id)) throw new Error("Project note needs a stable file-level :ID:");
  const color = value("PROJECT_COLOR") || "none";
  if (color !== "none" && !(PROJECT_COLORS as readonly string[]).includes(color) && !/^#[0-9a-f]{6}$/i.test(color)) throw new Error(`Invalid project color: ${color}`);
  const threadIDs = [...new Set(value("PROJECT_THREADS").split(/\s+/).filter(Boolean).map(x => x.toLowerCase()))];
  if (threadIDs.some(x => !uuid.test(x))) throw new Error("PROJECT_THREADS must contain stable Celorga thread UUIDs");
  const lines = raw.replace(/\r\n?/g, "\n").split("\n");
  const metadataLines = new Set<number>();
  // The live chat table block is presentation, not part of the brief.
  for (const node of doc.children) if (node.type === "PropertyDrawer" || node.type === "KeywordLine" || isProjectThreadsBlock(node)) {
    const range = (node as Node & { sourceRange?: { startLine: number; endLine: number } }).sourceRange;
    if (range) for (let i = range.startLine; i <= range.endLine; i++) metadataLines.add(i);
  }
  const body = lines.filter((_, i) => !metadataLines.has(i + 1)).join("\n").trim();
  return { id, title: value("TITLE") || path.basename(file), color, file: path.resolve(file), relativePath: path.relative(root, file),
    revision: guardedContentRevision(raw), threadIDs, brief: body.slice(0, 12000), briefTruncated: body.length > 12000 };
}
export function listProjectNotes(root: string) {
  const cfg = config(root);
  const projects: ProjectNote[] = [];
  const diagnostics: Array<{ file: string; message: string }> = [];
  const files = resolveFilesFromDir(root, ["**/*.org", "**/*.org2"], ["node_modules", "node_modules/**", ...(cfg.ignorePatterns ?? [])], true);
  for (const file of files) {
    // Classify only the header; ordinary notes/transcripts are never parsed here.
    let descriptor: number | undefined;
    try {
      descriptor = fs.openSync(file, "r");
      const header = Buffer.alloc(8192);
      const count = fs.readSync(descriptor, header, 0, header.length, 0);
      if (!marker.test(header.toString("utf8", 0, count))) continue;
      if (fs.fstatSync(descriptor).size > maxBytes) throw new Error("Project note exceeds the 1 MiB limit");
      projects.push(parseProjectNote(root, file, fs.readFileSync(file, "utf8")));
    } catch (error) {
      if (error instanceof Error && error.message === "Not a project note") continue;
      diagnostics.push({ file, message: error instanceof Error ? error.message : String(error) });
    } finally { if (descriptor !== undefined) fs.closeSync(descriptor); }
  }
  const counts = new Map<string, number>();
  for (const project of projects) counts.set(project.id, (counts.get(project.id) ?? 0) + 1);
  for (const project of projects) if (counts.get(project.id)! > 1) diagnostics.push({ file: project.file, message: `Duplicate project ID: ${project.id}` });
  return { schema: "org2:project-list:v1", projects: projects.filter(p => counts.get(p.id) === 1).sort((a, b) => a.title.localeCompare(b.title)), diagnostics };
}
function setKeyword(raw: string, key: string, value: string): string {
  if (/[\r\n]/.test(value)) throw new Error(`${key} must be one line`);
  const node = keywords(raw).find(n => n.keyRaw.toUpperCase() === key);
  const range = (node as (Node & { sourceRange?: { startLine: number } }) | undefined)?.sourceRange;
  const newline = raw.includes("\r\n") ? "\r\n" : "\n";
  const line = `#+${key}: ${value}`;
  if (!range) return line + newline + raw;
  const lines = raw.split(newline); lines[range.startLine - 1] = line;
  return lines.join(newline);
}
function removeKeyword(raw: string, key: string): string {
  const node = keywords(raw).find(n => n.keyRaw.toUpperCase() === key);
  const range = (node as (Node & { sourceRange?: { startLine: number } }) | undefined)?.sourceRange;
  if (!range) return raw;
  const newline = raw.includes("\r\n") ? "\r\n" : "\n";
  const lines = raw.split(newline);
  lines.splice(range.startLine - 1, 1);
  return lines.join(newline);
}
function ensureID(raw: string, id: string): string {
  const doc = document(raw);
  const drawer = doc.children.find(n => n.type === "PropertyDrawer");
  if (drawer?.type === "PropertyDrawer" && drawer.properties.some(p => p.key.toUpperCase() === "ID")) return raw;
  const newline = raw.includes("\r\n") ? "\r\n" : "\n";
  const idLine = `:ID: ${id}`;
  const range = (drawer as (Node & { sourceRange?: { startLine: number } }) | undefined)?.sourceRange;
  if (range) {
    const lines = raw.split(newline); lines.splice(range.startLine, 0, idLine); return lines.join(newline);
  }
  return [":PROPERTIES:", idLine, ":END:", raw].join(newline);
}
export function createProjectNote(root: string, input: { title: string; description?: string; id?: string; color?: string; file?: string; adopt?: boolean; apply?: boolean; expectedRevision?: string }) {
  if (!input.title.trim() || /[\r\n]/.test(input.title)) throw new Error("Project title must be a nonempty single line");
  const cfg = config(root);
  const id = input.id ?? crypto.randomUUID();
  if (input.adopt ? !id || id.length > 200 || /[\s\[\]]/.test(id) : !uuid.test(id)) throw new Error("Project ID is invalid");
  const destination = input.file ?? path.join(cfg.roam?.nodesDir || "notes", "projects", id + ".org");
  const file = inside(root, destination);
  if (input.adopt && !fs.existsSync(file)) throw new Error("Cannot adopt a missing note");
  if (!input.adopt && fs.existsSync(file)) throw new Error("Project file already exists; use adopt to keep its contents");
  const previous = input.adopt ? fs.readFileSync(file, "utf8") : "";
  if (Buffer.byteLength(previous) > maxBytes) throw new Error("Project note exceeds the 1 MiB limit");
  const kind = keywords(previous).find(n => isBrandName(n.keyRaw.toUpperCase(), "ORG2_KIND"))?.valueRaw.trim();
  if (kind) throw new Error("This note already declares an ORG2_KIND");
  const description = (input.description ?? "").trim();
  if (Buffer.byteLength(description) > maxBytes / 2) throw new Error("Project description is too long");
  // A new note shows its chats in a live table; an adopted note keeps its layout.
  const fresh = PROJECT_THREADS_BLOCK_SOURCE + "\n" + (description ? "\n" + description + "\n" : "");
  let content = ensureID(input.adopt ? previous : fresh, id);
  content = setKeyword(content, "TITLE", input.title.trim());
  content = setKeyword(content, "ORG2_KIND", "project");
  if (input.color && input.color !== "none") content = setKeyword(content, "PROJECT_COLOR", input.color);
  const project = parseProjectNote(root, file, content);
  if (input.apply) guardedWriteFile(file, content, { expectedRevision: input.adopt ? input.expectedRevision ?? guardedContentRevision(previous) : null, preserveMode: true });
  return { schema: "org2:project-edit:v1", applied: Boolean(input.apply), baseRevision: input.adopt ? guardedContentRevision(previous) : null, project, content };
}
export function updateProjectNote(root: string, id: string, input: { threadID?: string; remove?: boolean; color?: string; apply?: boolean; expectedRevision?: string }) {
  const project = listProjectNotes(root).projects.find(p => p.id === id);
  if (!project) throw new Error("Project not found or its ID is ambiguous");
  const file = inside(root, project.file);
  let content = fs.readFileSync(file, "utf8");
  const previousRevision = guardedContentRevision(content);
  if (previousRevision !== project.revision) throw new Error("Project changed; refresh and try again");
  if (input.threadID) {
    if (!uuid.test(input.threadID)) throw new Error("A stable Celorga thread UUID is required");
    const threadID = input.threadID.toLowerCase();
    const ids = input.remove ? project.threadIDs.filter(id => id !== threadID) : [...new Set([...project.threadIDs, threadID])];
    content = setKeyword(content, "PROJECT_THREADS", ids.join(" "));
  }
  if (input.color) content = input.color === "none" ? removeKeyword(content, "PROJECT_COLOR") : setKeyword(content, "PROJECT_COLOR", input.color);
  const updated = parseProjectNote(root, file, content);
  if (input.apply) guardedWriteFile(file, content, { expectedRevision: input.expectedRevision ?? previousRevision, preserveMode: true });
  return { schema: "org2:project-edit:v1", applied: Boolean(input.apply), baseRevision: previousRevision, project: updated, content };
}
