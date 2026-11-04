import fs from "node:fs";
import path from "node:path";
import type { DocumentNode, HeadlineNode, Node } from "./ast.js";
import { findConfigFile, loadConfig, resolveFilesFromDir } from "./config.js";
import { compileCorpus, type CompiledCorpus, type CompiledCorpusNode } from "./corpusCompile.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { configFilePath } from "./brandNames.js";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { parseIdLinkTarget, resolveOrgSearchOption } from "./linkSearch.js";

export type LiveEmbedResolution = {
  ok: true; key: string; file: string; line: number; title: string;
  document: DocumentNode; bytes: number; sourceDocument?: DocumentNode;
} | { ok: false; message: string };
export type LiveEmbedResolver = ((target: string, sourcePath?: string) => LiveEmbedResolution) & { sourceKey?: string };

/** Portable syntax deliberately uses the existing explicit file/ID link targets. */
export function liveEmbedDirective(target: string): string {
  target = target.trim();
  if (!target || /[\r\n\0]/.test(target) || target.length > 4096) throw new Error("An embed needs one file: or id: target on a single line");
  const idTarget = parseIdLinkTarget(target);
  if (idTarget && /^[^\s\[\]]+$/.test(idTarget.id) && !/[\[\]]/.test(idTarget.search ?? "")) {
    return `#+EMBED: id:${idTarget.id.toLowerCase()}${idTarget.search ? `::${idTarget.search}` : ""}`;
  }
  if (/^file:.+\.(org|org2)$/i.test(target) && !target.includes("::") && !path.isAbsolute(target.slice(5)) && !target.slice(5).startsWith("~")) return `#+EMBED: ${target}`;
  throw new Error("Use id:STABLE-ID (optionally id:STABLE-ID::SEARCH) for a note or heading, or file:relative/path.org for a whole note");
}

type RangedNode = Node & { sourceRange?: { startLine: number; endLine: number } };
function canonicalEmbedRange(document: DocumentNode, candidate: CompiledCorpusNode): { line: number; endLine?: number } | null {
  const drawerID = (nodes: Node[]): string | undefined => {
    const drawer = nodes.find(node => node.type === "PropertyDrawer");
    if (drawer?.type !== "PropertyDrawer") return undefined;
    const ids = drawer.properties.filter(property => property.key.toUpperCase() === "ID");
    return ids.length === 1 ? ids[0]!.value.trim().toLowerCase() : undefined;
  };
  if (candidate.kind === "file") {
    const firstHeading = document.children.findIndex(node => node.type === "Headline");
    const preamble = firstHeading < 0 ? document.children : document.children.slice(0, firstHeading);
    const keywords = preamble.filter(node => node.type === "KeywordLine" && node.keyRaw.toUpperCase() === "ID");
    const keywordID = keywords.length === 1 && keywords[0]?.type === "KeywordLine" ? keywords[0].valueRaw.trim().toLowerCase() : undefined;
    return (keywordID || drawerID(preamble)) === candidate.id ? { line: 1 } : null;
  }
  let heading: (HeadlineNode & RangedNode) | undefined;
  const visit = (nodes: Node[]) => {
    for (const node of nodes) if (node.type === "Headline") {
      if ((node as RangedNode).sourceRange?.startLine === candidate.sourceRange.startLine) heading = node as HeadlineNode & RangedNode;
      visit(node.children);
    }
  };
  visit(document.children);
  if (!heading?.sourceRange || drawerID(heading.children) !== candidate.id) return null;
  return { line: heading.sourceRange.startLine, endLine: heading.sourceRange.endLine };
}

function innermostHeading(document: DocumentNode, line: number): (HeadlineNode & RangedNode) | undefined {
  let found: (HeadlineNode & RangedNode) | undefined;
  const visit = (nodes: Node[]) => {
    for (const node of nodes) if (node.type === "Headline") {
      const range = (node as RangedNode).sourceRange;
      if (range && range.startLine <= line && line <= range.endLine) {
        found = node as HeadlineNode & RangedNode;
        visit(node.children);
      }
    }
  };
  visit(document.children);
  return found;
}

/** Resolution is scoped to one explicitly selected corpus, with no mounts or network reads. */
export function createLiveEmbedResolver(options: { sourcePath: string; rootDir?: string }): LiveEmbedResolver {
  const configFile = options.rootDir ? configFilePath(options.rootDir) : findConfigFile(path.dirname(path.resolve(options.sourcePath)));
  const root = fs.realpathSync(options.rootDir ?? (configFile ? path.dirname(configFile) : path.dirname(path.resolve(options.sourcePath))));
  let corpus: CompiledCorpus | undefined;
  const inside = (file: string): string => {
    const resolved = fs.realpathSync(file);
    const relative = path.relative(root, resolved);
    if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error("Embed target is outside the active corpus");
    if (!/\.(org|org2)$/i.test(resolved)) throw new Error("Embed targets must be Org notes");
    return resolved;
  };
  const resolve: LiveEmbedResolver = (rawTarget, sourcePath = options.sourcePath) => {
    try {
      const target = liveEmbedDirective(rawTarget).slice("#+EMBED: ".length);
      let file: string;
      let line = 1;
      let endLine: number | undefined;
      let title: string | undefined;
      let verifiedSource: string | undefined;
      let sourceDocument: DocumentNode | undefined;
      const idTarget = parseIdLinkTarget(target);
      if (idTarget) {
        const idValue = idTarget.id;
        const search = idTarget.search;
        if (!corpus) {
          const config = configFile && fs.existsSync(configFile) ? loadConfig(configFile) : {};
          const candidates = resolveFilesFromDir(root, ["**/*.org", "**/*.org2"], ["node_modules", "node_modules/**", ".git", ".git/**", ...(config.ignorePatterns ?? [])], true);
          if (candidates.length > 10000) throw new Error("Embed ID lookup exceeds the 10,000-note limit; use a file: target");
          let totalBytes = 0;
          const files = candidates.filter(candidate => {
            try { inside(candidate); } catch { return false; }
            const size = fs.statSync(candidate).size;
            totalBytes += size;
            return size <= 4 * 1024 * 1024;
          });
          if (totalBytes > 64 * 1024 * 1024) throw new Error("Embed ID lookup exceeds the 64 MiB limit; use a file: target");
          corpus = compileCorpus(files, { rootDir: root });
        }
        const candidates = corpus.nodes.filter(node => node.id === idValue);
        if (candidates.length === 0) return { ok: false, message: "Embed target is missing (or excluded from this corpus)" };
        // Compiled projections can contain Org-looking text inside source or
        // example blocks. Verify actual full-document nodes before ambiguity
        // checks and slicing, and use canonical subtree boundaries as well.
        const documents = new Map<string, { raw: string; document: DocumentNode }>();
        const verified = candidates.flatMap(candidate => {
          const candidateFile = inside(path.resolve(root, candidate.file));
          let source = documents.get(candidateFile);
          if (!source) {
            if (fs.statSync(candidateFile).size > 4 * 1024 * 1024) throw new Error("Embed source exceeds the 4 MiB file limit");
            const raw = fs.readFileSync(candidateFile, "utf8").replace(/\r\n?/g, "\n");
            source = { raw, document: parseOrgToCanonicalAst(raw, { sourceRanges: true, sourcePath: candidateFile }) };
            documents.set(candidateFile, source);
          }
          const range = canonicalEmbedRange(source.document, candidate);
          return range ? [{ ...range, file: candidateFile, title: candidate.title, raw: source.raw, document: source.document }] : [];
        });
        if (verified.length === 0) return { ok: false, message: "Embed target is missing: ID has no matching canonical note or heading; examples are not embed targets" };
        if (verified.length !== 1) return { ok: false, message: "Embed ID is ambiguous; repair duplicate IDs before embedding" };
        const selected = verified[0]!;
        file = selected.file;
        line = selected.line;
        endLine = selected.endLine;
        title = selected.title;
        if (search) {
          // Org 10 `id:ID::SEARCH`: search the ID's subtree, then its file,
          // and embed the heading section that contains the match.
          const lines = selected.raw.split("\n");
          const match = resolveOrgSearchOption(lines, search, { scope: { startLine: line, endLine: endLine ?? lines.length } });
          if (!match) return { ok: false, message: `Embed search option "${search}" was not found in the note that contains ${idValue}` };
          const section = innermostHeading(selected.document, match.line);
          if (section?.sourceRange) {
            line = section.sourceRange.startLine;
            endLine = section.sourceRange.endLine;
            title = parseHeadlineTitleForRoam(lines[line - 1] ?? "") || title;
          } else {
            line = 1;
            endLine = undefined;
            title = undefined;
          }
        }
        verifiedSource = selected.raw;
        sourceDocument = selected.document;
      } else {
        file = inside(path.resolve(path.dirname(path.resolve(sourcePath)), target.slice(5)));
      }
      if (fs.statSync(file).size > 4 * 1024 * 1024) throw new Error("Embed source exceeds the 4 MiB file limit");
      const raw = verifiedSource ?? fs.readFileSync(file, "utf8").replace(/\r\n?/g, "\n");
      const text = endLine === undefined ? raw : raw.split("\n").slice(line - 1, endLine).join("\n");
      const bytes = Buffer.byteLength(text);
      if (bytes > 256 * 1024) throw new Error("Embed exceeds the 256 KiB content limit; embed a smaller heading");
      const document = parseOrgToCanonicalAst(text, { sourceRanges: true, sourcePath: file, sourceLineOffset: line - 1 });
      sourceDocument ??= endLine === undefined ? document : parseOrgToCanonicalAst(raw, { sourceRanges: true, sourcePath: file });
      const titleKeyword = document.children.find(node => node.type === "KeywordLine" && node.keyRaw.toUpperCase() === "TITLE");
      return { ok: true, key: `${file}:${line}`, file, line, title: title ?? (titleKeyword?.type === "KeywordLine" ? titleKeyword.valueRaw.trim() : path.basename(file)), document, sourceDocument, bytes };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return { ok: false, message: /ENOENT/.test(message) ? "Embed target is missing" : message };
    }
  };
  try { resolve.sourceKey = `${fs.realpathSync(options.sourcePath)}:1`; } catch { /* Unsaved source path. */ }
  return resolve;
}

export async function runEmbedCommand(args: string[]): Promise<void> {
  if (args.includes("--help") || args.includes("-h")) {
    console.log("Usage: celorga embed resolve --target file:NOTE.org|id:ID[::SEARCH] --file SOURCE [--dir CORPUS] [--json]\nRead-only validation returns a portable #+EMBED directive and source location; it never copies content or writes files.");
    return;
  }
  if (args[0] !== "resolve") throw new Error("Use celorga embed resolve --help");
  let target = "", file = "", rootDir: string | undefined;
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--target") target = args[++i] ?? "";
    else if (args[i] === "--file") file = args[++i] ?? "";
    else if (args[i] === "--dir") rootDir = args[++i];
    else if (args[i] !== "--json") throw new Error(`Unknown embed option: ${args[i]}`);
  }
  if (!file || !target) throw new Error("Embed resolution needs --file SOURCE and --target TARGET");
  const directive = liveEmbedDirective(target);
  const resolved = createLiveEmbedResolver({ sourcePath: file, rootDir })(target);
  const result = resolved.ok ? { ok: true, directive, file: resolved.file, line: resolved.line, title: resolved.title } : resolved;
  console.log(JSON.stringify({ schema: "org2:embed-resolution:v1", ...result }, null, 2));
  if (!resolved.ok) process.exitCode = 1;
}
