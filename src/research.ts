// Research notes: citations resolved against BibTeX bibliographies, checks that
// quoted passages appear in their cited sources, the queue of sources that no
// note distills yet, and a tag-based concept index.
//
// Everything is computed from plain files on each run. Nothing here keeps a
// database; generated output is an ordinary Org file under views/.

import fs from "node:fs";
import path from "node:path";
import type { CitationNode, DocumentNode, LinkNode } from "./ast.js";
import { citationFromNode } from "./citationSyntax.js";
import { findConfigFile, loadConfig, type Org2Config } from "./config.js";
export type { Org2ResearchConfig } from "./config.js";
import { listOrgLikeFiles } from "./corpusFiles.js";
import { parseInlinesFromText, parseOrgToCanonicalAst } from "./parser.js";

export { citationFromLinkTarget, citationFromNode, isCitationLinkType } from "./citationSyntax.js";
export type { CitationReference, ParsedCitation } from "./citationSyntax.js";

// ---------------------------------------------------------------------------
// BibTeX

export type BibEntry = {
  key: string;
  type: string;
  fields: Record<string, string>;
  /** The .bib file and 1-based line of the entry. */
  bibFile: string;
  line: number;
};

/** A tolerant BibTeX reader: entries, braced or quoted values, `#` joins. */
export function parseBibtex(text: string, bibFile = ""): BibEntry[] {
  const entries: BibEntry[] = [];
  const strings = new Map<string, string>();
  let index = 0;
  const lineAt = (offset: number) => text.slice(0, offset).split("\n").length;
  while (index < text.length) {
    const at = text.indexOf("@", index);
    if (at < 0) break;
    const header = /^@([A-Za-z]+)\s*([{(])/.exec(text.slice(at));
    if (!header) { index = at + 1; continue; }
    const type = header[1]!.toLowerCase();
    const open = header[2]!;
    const close = open === "{" ? "}" : ")";
    let cursor = at + header[0].length;
    // Find the end of the entry by brace depth.
    let depth = 1;
    let end = cursor;
    let inQuote = false;
    for (; end < text.length && depth > 0; end += 1) {
      const ch = text[end];
      if (ch === "\\") { end += 1; continue; }
      if (ch === "\"" && depth === 1) inQuote = !inQuote;
      if (inQuote) continue;
      if (ch === "{" || (open === "(" && ch === "(")) depth += 1;
      else if (ch === "}" || (open === "(" && ch === ")")) depth -= 1;
    }
    const body = text.slice(cursor, Math.max(cursor, end - 1));
    index = end;
    if (type === "comment" || type === "preamble") continue;
    if (type === "string") {
      for (const [name, value] of parseBibFields(body, strings)) strings.set(name, value);
      continue;
    }
    const comma = body.indexOf(",");
    const key = (comma < 0 ? body : body.slice(0, comma)).trim();
    if (!key) continue;
    const fields: Record<string, string> = {};
    if (comma >= 0) for (const [name, value] of parseBibFields(body.slice(comma + 1), strings)) fields[name] = value;
    entries.push({ key, type, fields, bibFile, line: lineAt(at) });
    void close;
  }
  return entries;
}

function parseBibFields(body: string, strings: Map<string, string>): Array<[string, string]> {
  const out: Array<[string, string]> = [];
  let index = 0;
  while (index < body.length) {
    const name = /^\s*,?\s*([A-Za-z][\w:.+-]*)\s*=\s*/.exec(body.slice(index));
    if (!name) break;
    index += name[0].length;
    const parts: string[] = [];
    while (index < body.length) {
      const ch = body[index];
      if (ch === "{") {
        let depth = 1;
        let end = index + 1;
        for (; end < body.length && depth > 0; end += 1) {
          if (body[end] === "\\") { end += 1; continue; }
          if (body[end] === "{") depth += 1;
          else if (body[end] === "}") depth -= 1;
        }
        parts.push(body.slice(index + 1, end - 1));
        index = end;
      } else if (ch === "\"") {
        let end = index + 1;
        let depth = 0;
        for (; end < body.length; end += 1) {
          if (body[end] === "\\") { end += 1; continue; }
          if (body[end] === "{") depth += 1;
          else if (body[end] === "}") depth -= 1;
          else if (body[end] === "\"" && depth === 0) break;
        }
        parts.push(body.slice(index + 1, end));
        index = end + 1;
      } else {
        const bare = /^[^,#\s}]+/.exec(body.slice(index));
        if (!bare) break;
        parts.push(strings.get(bare[0].toLowerCase()) ?? bare[0]);
        index += bare[0].length;
      }
      const join = /^\s*#\s*/.exec(body.slice(index));
      if (!join) break;
      index += join[0].length;
    }
    out.push([name[1]!.toLowerCase(), parts.join("").replace(/\s+/g, " ").trim()]);
    const next = body.indexOf(",", index);
    if (next < 0) break;
    index = next;
  }
  return out;
}

function stripLatex(value: string): string {
  return value.replace(/\\[a-zA-Z]+\s*/g, "").replace(/[{}]/g, "").replace(/~/g, " ").replace(/\s+/g, " ").trim();
}

/** "Doe and Roe" style short author list. */
function shortAuthors(author: string): string {
  const names = author.split(/\s+and\s+/i).map((name) => {
    const clean = stripLatex(name);
    return clean.includes(",") ? clean.split(",")[0]!.trim() : clean.split(" ").at(-1) || clean;
  }).filter(Boolean);
  if (names.length === 0) return "";
  if (names.length === 1) return names[0]!;
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names[0]} et al.`;
}

export function describeBibEntry(entry: BibEntry): string {
  const author = shortAuthors(entry.fields.author || entry.fields.editor || "");
  const year = stripLatex(entry.fields.year || (entry.fields.date || "").slice(0, 4));
  const title = stripLatex(entry.fields.title || "");
  const head = [author, year ? `(${year})` : ""].filter(Boolean).join(" ");
  if (!title) return head;
  if (!head) return `${title}.`;
  return `${head}${head.endsWith(".") ? "" : "."} ${title}${/[.?!]$/.test(title) ? "" : "."}`;
}

/** Paths named in the entry's `file` field (BibTeX, JabRef, and Zotero forms). */
function bibEntryFileValues(entry: BibEntry): string[] {
  const raw = entry.fields.file || entry.fields.pdf || "";
  if (!raw) return [];
  return raw.split(";").map((part) => {
    const pieces = part.split(":");
    // JabRef/Zotero write DESCRIPTION:PATH:TYPE.
    if (pieces.length >= 3 && !/^[A-Za-z]$/.test(pieces[0]!)) return pieces.slice(1, -1).join(":");
    return part;
  }).map((value) => value.trim()).filter(Boolean);
}

/**
 * Resolves the entry's source files. Relative paths are tried against the
 * .bib file's folder and its parents (crucible writes them relative to the
 * project above `.crucible/`), then the corpus root.
 */
export function bibEntrySourceFiles(entry: BibEntry, corpusRoot?: string): string[] {
  const out: string[] = [];
  for (const value of bibEntryFileValues(entry)) {
    const expanded = value.startsWith("~/") ? path.join(process.env.HOME || "", value.slice(2)) : value;
    const candidates: string[] = [];
    if (path.isAbsolute(expanded)) candidates.push(expanded);
    else {
      let base = path.dirname(entry.bibFile);
      for (let depth = 0; depth < 3; depth += 1) {
        candidates.push(path.resolve(base, expanded));
        base = path.dirname(base);
      }
      if (corpusRoot) candidates.push(path.resolve(corpusRoot, expanded));
    }
    const found = candidates.find((candidate) => fs.existsSync(candidate));
    if (found && !out.includes(found)) out.push(found);
  }
  return out;
}

const bibliographyCache = new Map<string, { mtimeMs: number; size: number; entries: BibEntry[] }>();

export function loadBibliographyFile(file: string): BibEntry[] {
  let stat: fs.Stats;
  try { stat = fs.statSync(file); } catch { return []; }
  const cached = bibliographyCache.get(file);
  if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) return cached.entries;
  const entries = parseBibtex(fs.readFileSync(file, "utf8"), file);
  bibliographyCache.set(file, { mtimeMs: stat.mtimeMs, size: stat.size, entries });
  return entries;
}

export type ResearchSettings = {
  corpusRoot: string;
  bibliography: string[];
  sourceDirs: string[];
};

const DEFAULT_BIBLIOGRAPHY_NAMES = ["references.bib", "bibliography.bib"];
const DEFAULT_SOURCE_DIRS = ["raw", "sources"];

export function researchSettings(corpusRoot: string, config?: Org2Config | null): ResearchSettings {
  const root = path.resolve(corpusRoot);
  let loaded = config;
  if (loaded === undefined) {
    const configPath = findConfigFile(root);
    loaded = null;
    if (configPath && path.dirname(configPath) === root) {
      try { loaded = loadConfig(configPath); } catch { loaded = null; }
    }
  }
  const research = loaded?.research;
  const configured = (research?.bibliography || []).map((file) => path.resolve(root, file));
  const defaults = DEFAULT_BIBLIOGRAPHY_NAMES.map((name) => path.join(root, name)).filter((file) => fs.existsSync(file));
  return {
    corpusRoot: root,
    bibliography: configured.length ? configured : defaults,
    sourceDirs: (research?.sourceDirs?.length ? research.sourceDirs : DEFAULT_SOURCE_DIRS)
      .map((dir) => path.resolve(root, dir)),
  };
}

/** `#+BIBLIOGRAPHY:` keywords and org-ref `bibliography:` links in a note. */
export function documentBibliographyFiles(text: string, filePath: string): string[] {
  const out: string[] = [];
  const dir = path.dirname(path.resolve(filePath));
  const add = (value: string) => {
    for (const part of value.split(",")) {
      const trimmed = part.trim().replace(/^"(.*)"$/, "$1");
      if (!trimmed) continue;
      const resolved = path.resolve(dir, trimmed.startsWith("~/") ? path.join(process.env.HOME || "", trimmed.slice(2)) : trimmed);
      if (!out.includes(resolved)) out.push(resolved);
    }
  };
  for (const match of text.matchAll(/^[ \t]*#\+bibliography:[ \t]*(.+?)[ \t]*$/gim)) add(match[1]!);
  for (const match of text.matchAll(/(?:^|[\s[])(?:bibliography|addbibresource):([^\s\]]+)/gim)) add(match[1]!);
  return out;
}

export type Bibliography = {
  files: string[];
  entries: Map<string, BibEntry>;
};

export function bibliographyForDocument(text: string, filePath: string | undefined, settings?: ResearchSettings): Bibliography {
  const files: string[] = [];
  if (filePath) for (const file of documentBibliographyFiles(text, filePath)) if (!files.includes(file)) files.push(file);
  for (const file of settings?.bibliography || []) if (!files.includes(file)) files.push(file);
  const entries = new Map<string, BibEntry>();
  const existing = files.filter((file) => fs.existsSync(file));
  for (const file of existing) {
    for (const entry of loadBibliographyFile(file)) if (!entries.has(entry.key)) entries.set(entry.key, entry);
  }
  return { files: existing, entries };
}

export type { CitationLookup, CitationRenderInfo } from "./citationSyntax.js";
import type { CitationLookup } from "./citationSyntax.js";

/**
 * Builds the renderer's lookup for one note, or undefined when the note has
 * no bibliography (citations then render as plain keys).
 */
export function citationLookupForDocument(text: string, sourcePath: string | undefined, corpusRoot?: string): CitationLookup | undefined {
  if (!sourcePath) return undefined;
  const root = corpusRoot || (() => {
    const configPath = findConfigFile(path.dirname(path.resolve(sourcePath)));
    return configPath ? path.dirname(configPath) : undefined;
  })();
  const settings = root ? researchSettings(root) : undefined;
  const bibliography = bibliographyForDocument(text, sourcePath, settings);
  if (bibliography.files.length === 0) return undefined;
  return (key) => {
    const entry = bibliography.entries.get(key);
    if (!entry) return { resolved: false };
    const source = bibEntrySourceFiles(entry, root)[0];
    return {
      resolved: true,
      title: describeBibEntry(entry) || key,
      ...(source ? { sourceTarget: `file:${source}` } : {}),
    };
  };
}

// ---------------------------------------------------------------------------
// Citations and quotes in a note

export type CitedSource =
  | { kind: "key"; key: string }
  | { kind: "file"; target: string; file: string; startLine?: number; endLine?: number };

export type NoteCitation = {
  file: string;
  line: number;
  raw: string;
  syntax: "org-cite" | "org-ref";
  style?: string;
  keys: string[];
};

export type NoteQuote = {
  file: string;
  line: number;
  text: string;
  kind: "block" | "inline";
  sources: CitedSource[];
};

type SourceRange = { startLine: number; endLine: number };
type Ranged = { sourceRange?: SourceRange };

function lineOfRaw(lines: string[], range: SourceRange | undefined, raw: string): number {
  if (!range) return 1;
  for (let line = range.startLine; line <= Math.min(range.endLine, lines.length); line += 1) {
    if (lines[line - 1]?.includes(raw)) return line;
  }
  return range.startLine;
}

function fileLinkSource(target: string, noteFile: string): CitedSource | null {
  const match = /^file:(.+)$/i.exec(target.trim());
  if (!match) return null;
  let location = match[1]!;
  let search = "";
  const separator = location.indexOf("::");
  if (separator >= 0) {
    search = location.slice(separator + 2).trim();
    location = location.slice(0, separator);
  }
  const file = path.resolve(path.dirname(noteFile), location.startsWith("~/") ? path.join(process.env.HOME || "", location.slice(2)) : location);
  const range = /^(\d+)(?:\s*-\s*(\d+))?$/.exec(search);
  return {
    kind: "file",
    target,
    file,
    ...(range ? { startLine: Number(range[1]), endLine: Number(range[2] || range[1]) } : {}),
  };
}

function sourcesInInlines(nodes: unknown[], noteFile: string, out: CitedSource[]): void {
  for (const node of nodes as Array<{ type?: string }>) {
    if (!node || typeof node !== "object") continue;
    if (node.type === "Citation" || node.type === "Link") {
      const citation = citationFromNode(node as CitationNode | LinkNode);
      if (citation) {
        for (const reference of citation.references) out.push({ kind: "key", key: reference.key });
        continue;
      }
      if (node.type === "Link") {
        const source = fileLinkSource((node as LinkNode).targetRaw, noteFile);
        if (source) out.push(source);
      }
    }
  }
}

const INLINE_QUOTE = /“([^”\n]+)”|"([^"\n]+)"/g;
const MINIMUM_QUOTE_WORDS = 5;
/** Words allowed between an inline quote and its citation, as in `" (see p. 4) citep:key`. */
const ADJACENT_CITATION_WORDS = 4;

function wordCount(text: string): number {
  return text.split(/\s+/).filter((word) => /[\p{L}\p{N}]/u.test(word)).length;
}

function plainInlineText(nodes: unknown[]): string {
  let out = "";
  for (const node of nodes as Array<Record<string, unknown>>) {
    if (!node || typeof node !== "object") continue;
    if (node.type === "Text") out += String(node.value || "");
    else if (node.type === "Emphasis") out += String(node.content || "");
    else if (node.type === "Link") out += String(node.descriptionRaw ?? node.raw ?? "");
    else if (node.type === "Entity" || node.type === "LineBreak") out += " ";
    else if (typeof node.raw === "string") out += node.raw;
  }
  return out;
}

export type NoteResearchFacts = {
  citations: NoteCitation[];
  quotes: NoteQuote[];
  /** Keys a note names as its sources: citations plus :SOURCE_KEYS:. */
  sourceKeys: Set<string>;
  /** Files the note links to with file: links. */
  linkedFiles: Set<string>;
  title: string;
  id?: string;
  tags: string[];
};

/** Reads one note's citations, quotes, links, title and tags. */
export function readNoteResearchFacts(text: string, file: string): NoteResearchFacts {
  const lines = text.split("\n");
  let doc: DocumentNode;
  try {
    doc = parseOrgToCanonicalAst(text.replace(/\t/g, "  "), { sourceRanges: true, sourcePath: file });
  } catch {
    doc = { type: "Document", version: "0", children: [] };
  }
  const citations: NoteCitation[] = [];
  const quotes: NoteQuote[] = [];
  const sourceKeys = new Set<string>();
  const linkedFiles = new Set<string>();
  const tags = new Set<string>();
  let title = "";
  let id: string | undefined;

  const recordInlines = (nodes: unknown[], range: SourceRange | undefined) => {
    for (const node of nodes as Array<Record<string, unknown>>) {
      if (!node || typeof node !== "object") continue;
      if (node.type === "Emphasis") continue;
      if (node.type === "Citation" || node.type === "Link") {
        const citation = citationFromNode(node as unknown as CitationNode | LinkNode);
        if (citation) {
          const raw = String(node.raw || "");
          citations.push({
            file,
            line: lineOfRaw(lines, range, raw),
            raw,
            syntax: citation.syntax,
            ...(citation.style ? { style: citation.style } : {}),
            keys: citation.references.map((reference) => reference.key),
          });
          for (const reference of citation.references) sourceKeys.add(reference.key);
        } else if (node.type === "Link") {
          const source = fileLinkSource(String(node.targetRaw || ""), file);
          if (source && source.kind === "file") linkedFiles.add(source.file);
        }
      }
    }
  };

  // An inline quote is checked against the citation written right after it
  // (or, failing that, right before it). A link elsewhere in the paragraph
  // usually supports a different claim.
  const inlineQuotes = (nodes: unknown[], range: SourceRange | undefined) => {
    let plain = "";
    const cited: Array<{ offset: number; sources: CitedSource[] }> = [];
    for (const node of nodes) {
      const sources: CitedSource[] = [];
      sourcesInInlines([node], file, sources);
      if (sources.length) {
        cited.push({ offset: plain.length, sources });
        const type = (node as { type?: string }).type;
        if (type === "Citation" || (type === "Link" && citationFromNode(node as LinkNode))) continue;
      }
      plain += plainInlineText([node]);
    }
    if (cited.length === 0) return;
    const matches = [...plain.matchAll(INLINE_QUOTE)];
    matches.forEach((match, index) => {
      const quoted = (match[1] ?? match[2] ?? "").trim();
      if (wordCount(quoted) < MINIMUM_QUOTE_WORDS) return;
      const start = match.index ?? 0;
      const end = start + match[0].length;
      const nextStart = matches[index + 1]?.index ?? Number.POSITIVE_INFINITY;
      const near = (from: number, to: number) => wordCount(plain.slice(from, to)) <= ADJACENT_CITATION_WORDS;
      let sources = cited.filter((entry) => entry.offset >= end && entry.offset < nextStart && near(end, entry.offset)).flatMap((entry) => entry.sources);
      if (sources.length === 0) sources = cited.filter((entry) => entry.offset <= start && near(entry.offset, start)).at(-1)?.sources ?? [];
      if (sources.length === 0) return;
      quotes.push({ file, line: lineOfRaw(lines, range, quoted.slice(0, 24)), text: quoted, kind: "inline", sources });
    });
  };

  const visit = (nodes: unknown[], inheritedRange?: SourceRange) => {
    for (let index = 0; index < nodes.length; index += 1) {
      const node = nodes[index] as Record<string, unknown> & Ranged;
      if (!node || typeof node !== "object") continue;
      const range = node.sourceRange ?? inheritedRange;
      switch (node.type) {
        case "KeywordLine": {
          const key = String(node.keyRaw || "").toUpperCase();
          const value = String(node.valueRaw || "").trim();
          if (key === "TITLE" && !title) title = value;
          if (key === "FILETAGS") for (const tag of value.split(/[:\s]+/)) if (tag) tags.add(tag);
          break;
        }
        case "PropertyDrawer": {
          for (const property of (node.properties as Array<{ key: string; value: string }>) || []) {
            const key = property.key.toUpperCase();
            if (key === "ID" && !id && !inheritedRange) id = property.value.trim();
            if (key === "SOURCE_KEYS" || key === "SOURCES" || key === "CITES") {
              for (const value of property.value.split(/[\s,;]+/)) {
                const trimmed = value.replace(/^[@&]/, "").trim();
                if (trimmed) sourceKeys.add(trimmed);
              }
            }
          }
          break;
        }
        case "Headline": {
          for (const tag of (node.tags as string[]) || []) tags.add(tag);
          const titleNodes = (node.title as unknown[]) || [];
          if (!title) title = plainInlineText(titleNodes).trim();
          recordInlines(titleNodes, range);
          visit((node.children as unknown[]) || [], range);
          break;
        }
        case "Paragraph": {
          const children = (node.children as unknown[]) || [];
          recordInlines(children, range);
          inlineQuotes(children, range);
          break;
        }
        case "ListItem": {
          const tag = (node.descriptionTag as unknown[]) || [];
          recordInlines(tag, range);
          visit((node.children as unknown[]) || [], range);
          break;
        }
        case "List": {
          visit((node.items as unknown[]) || [], range);
          break;
        }
        case "Table": {
          for (const row of (node.rows as Array<{ cells?: unknown[][] }>) || []) {
            for (const cell of row.cells || []) if (Array.isArray(cell)) recordInlines(cell, range);
          }
          break;
        }
        case "Block": {
          if (String(node.kind || "").toLowerCase() !== "quote") break;
          const body = String(node.bodyRaw || "");
          const bodyNodes = body.split("\n").flatMap((line) => parseInlinesFromText(line));
          recordInlines(bodyNodes, range);
          const sources: CitedSource[] = [];
          sourcesInInlines(bodyNodes, file, sources);
          // An attribution paragraph right after the block also cites it.
          const next = nodes[index + 1] as Record<string, unknown> | undefined;
          if (next?.type === "Paragraph") sourcesInInlines((next.children as unknown[]) || [], file, sources);
          // Quoted text excludes citation and link markup.
          const quoted = plainInlineText(bodyNodes.filter((child) => {
            const type = (child as { type?: string }).type;
            return type !== "Citation" && !(type === "Link" && citationFromNode(child as LinkNode));
          })).replace(/\s+/g, " ").trim();
          if (sources.length && wordCount(quoted) >= 2) {
            quotes.push({ file, line: (range?.startLine ?? 1), text: quoted, kind: "block", sources });
          }
          break;
        }
        default:
          if (Array.isArray(node.children)) visit(node.children as unknown[], range);
      }
    }
  };
  visit(doc.children);
  if (!title) title = path.basename(file).replace(/\.(org2?|org_archive)$/i, "");
  return { citations, quotes, sourceKeys, linkedFiles, title, ...(id ? { id } : {}), tags: [...tags] };
}

// ---------------------------------------------------------------------------
// Quote verification

const TEXT_SOURCE_EXTENSIONS = new Set([".org", ".org2", ".txt", ".md", ".markdown", ".html", ".htm", ".tex", ".rst", ".text"]);

/** Readable text for a source file, or a sibling text export of it. */
export function readableSourceFile(file: string): string | null {
  const extension = path.extname(file).toLowerCase();
  if (TEXT_SOURCE_EXTENSIONS.has(extension) && fs.existsSync(file)) return file;
  const base = file.slice(0, file.length - extension.length);
  for (const sibling of [".txt", ".md", ".org", ".html"]) {
    if (fs.existsSync(base + sibling)) return base + sibling;
  }
  return null;
}

function readSourceText(file: string, startLine?: number, endLine?: number): string {
  let text = fs.readFileSync(file, "utf8");
  if (startLine) text = text.split("\n").slice(startLine - 1, endLine ?? startLine).join("\n");
  if (/\.html?$/i.test(file)) text = text.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'");
  return text;
}

/** Lowercase words only, so line breaks, markup and punctuation don't matter. */
export function normalizeQuoteText(text: string): string {
  return text.normalize("NFKC").toLowerCase()
    .replace(/[‘’ʼ]/g, "'")
    .replace(/[^\p{L}\p{N}']+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * True when every part of the quote appears in the source, in order. An
 * ellipsis or a bracketed editorial insertion splits the quote into parts.
 */
export function quoteAppearsInSource(quote: string, source: string): boolean {
  const haystack = ` ${normalizeQuoteText(source)} `;
  // Each part notes whether an ellipsis cuts it, since a cut may fall mid-word.
  // A bracket touching a letter, as in "[W]hen" or "remove[d]", alters part
  // of a word, so the text beside it is a partial word too.
  const pieces = quote.split(/(\.\.\.|…|\[[^\]]*\])/);
  const parts: Array<{ text: string; cutBefore: boolean; cutAfter: boolean }> = [];
  const isEllipsis = (value: string | undefined) => value === "..." || value === "…";
  const isBracket = (value: string | undefined) => value?.startsWith("[") ?? false;
  for (let index = 0; index < pieces.length; index += 2) {
    const raw = pieces[index] ?? "";
    const text = normalizeQuoteText(raw);
    if (!text) continue;
    const cutBefore = isEllipsis(pieces[index - 1]) || (isBracket(pieces[index - 1]) && /^[\p{L}\p{N}]/u.test(raw));
    const cutAfter = isEllipsis(pieces[index + 1]) || (isBracket(pieces[index + 1]) && /[\p{L}\p{N}]$/u.test(raw));
    parts.push({ text, cutBefore, cutAfter });
  }
  if (parts.length === 0) return true;
  let from = 0;
  for (const part of parts) {
    const needle = `${part.cutBefore ? "" : " "}${part.text}${part.cutAfter ? "" : " "}`;
    const found = haystack.indexOf(needle, from);
    if (found < 0) return false;
    from = found + needle.length - 1;
  }
  return true;
}

export type QuoteCheck = NoteQuote & {
  status: "verified" | "mismatch" | "unverifiable";
  checkedSources: string[];
  message: string;
};

function displayPath(file: string, root: string): string {
  const relative = path.relative(root, file);
  return relative && !relative.startsWith("..") ? relative : file;
}

export function checkQuote(quote: NoteQuote, bibliography: Bibliography, corpusRoot: string): QuoteCheck {
  const checked: string[] = [];
  const unreadable: string[] = [];
  const moved: string[] = [];
  for (const source of quote.sources) {
    const files: Array<{ file: string; startLine?: number; endLine?: number; label: string }> = [];
    if (source.kind === "key") {
      const entry = bibliography.entries.get(source.key);
      if (!entry) { unreadable.push(`@${source.key} (not in the bibliography)`); continue; }
      const sourceFiles = bibEntrySourceFiles(entry, corpusRoot);
      if (sourceFiles.length === 0) {
        const declared = bibEntryFileValues(entry);
        unreadable.push(declared.length
          ? `@${source.key} (file not found: ${declared.join("; ")})`
          : `@${source.key} (no file field)`);
        continue;
      }
      for (const file of sourceFiles) files.push({ file, label: `@${source.key}` });
    } else {
      files.push({ file: source.file, startLine: source.startLine, endLine: source.endLine, label: source.target });
    }
    for (const candidate of files) {
      const readable = candidate.startLine ? (fs.existsSync(candidate.file) ? candidate.file : null) : readableSourceFile(candidate.file);
      if (!readable) { unreadable.push(`${candidate.label} (${displayPath(candidate.file, corpusRoot)} has no text to compare)`); continue; }
      checked.push(displayPath(readable, corpusRoot) + (candidate.startLine ? `::${candidate.startLine}${candidate.endLine && candidate.endLine !== candidate.startLine ? `-${candidate.endLine}` : ""}` : ""));
      let text: string;
      try { text = readSourceText(readable, candidate.startLine, candidate.endLine); } catch { unreadable.push(candidate.label); continue; }
      if (quoteAppearsInSource(quote.text, text)) {
        return { ...quote, status: "verified", checkedSources: checked, message: `Found in ${checked.at(-1)}` };
      }
      if (candidate.startLine) {
        const line = lineContainingQuote(readable, quote.text);
        if (line) moved.push(`${displayPath(readable, corpusRoot)}:${line}`);
      }
    }
  }
  if (checked.length === 0) {
    return { ...quote, status: "unverifiable", checkedSources: [], message: `No readable source: ${unreadable.join("; ")}` };
  }
  if (unreadable.length) {
    // It may be in the source we could not read.
    return { ...quote, status: "unverifiable", checkedSources: checked, message: `Not found in ${checked.join(", ")}; could not read ${unreadable.join("; ")}` };
  }
  const where = moved.length ? `; it is at ${moved.join(", ")}` : "";
  return { ...quote, status: "mismatch", checkedSources: checked, message: `Quoted text not found in ${checked.join(", ")}${where}` };
}

/** The first line of `file` where the quote starts, when the whole file contains it. */
function lineContainingQuote(file: string, quote: string): number | null {
  let text: string;
  try { text = readSourceText(file); } catch { return null; }
  if (!quoteAppearsInSource(quote, text)) return null;
  const opening = normalizeQuoteText(quote.split(/\.\.\.|…|\[[^\]]*\]/)[0] || quote).split(" ").slice(0, 4).join(" ");
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    if (` ${normalizeQuoteText(lines[index]!)} `.includes(` ${opening} `)) return index + 1;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Corpus-wide reports

export type ResearchNote = NoteResearchFacts & { file: string };

function isInside(file: string, dir: string): boolean {
  const relative = path.relative(dir, file);
  return Boolean(relative) && !relative.startsWith("..") && !path.isAbsolute(relative);
}

export function readResearchNotes(settings: ResearchSettings, files?: string[]): ResearchNote[] {
  const noteFiles = (files ?? listOrgLikeFiles(settings.corpusRoot, true))
    .filter((file) => !settings.sourceDirs.some((dir) => isInside(file, dir)));
  const notes: ResearchNote[] = [];
  for (const file of noteFiles.sort()) {
    let text: string;
    try { text = fs.readFileSync(file, "utf8"); } catch { continue; }
    notes.push({ file, ...readNoteResearchFacts(text, file) });
  }
  return notes;
}

export type CitationReport = {
  $schema: "celorga:research-citations:v1";
  corpusRoot: string;
  bibliography: string[];
  citations: Array<NoteCitation & { unresolvedKeys: string[] }>;
  quotes: QuoteCheck[];
  summary: { citations: number; unresolvedKeys: number; quotes: number; verified: number; mismatched: number; unverifiable: number };
};

export function citationReport(settings: ResearchSettings, files?: string[]): CitationReport {
  const notes = readResearchNotes(settings, files);
  const citations: CitationReport["citations"] = [];
  const quotes: QuoteCheck[] = [];
  const bibliographyFiles = new Set<string>();
  for (const note of notes) {
    const text = fs.readFileSync(note.file, "utf8");
    const bibliography = bibliographyForDocument(text, note.file, settings);
    bibliography.files.forEach((file) => bibliographyFiles.add(file));
    for (const citation of note.citations) {
      const unresolvedKeys = bibliography.files.length
        ? citation.keys.filter((key) => !bibliography.entries.has(key))
        : [];
      citations.push({ ...citation, unresolvedKeys });
    }
    for (const quote of note.quotes) quotes.push(checkQuote(quote, bibliography, settings.corpusRoot));
  }
  return {
    $schema: "celorga:research-citations:v1",
    corpusRoot: settings.corpusRoot,
    bibliography: [...bibliographyFiles].sort(),
    citations,
    quotes,
    summary: {
      citations: citations.length,
      unresolvedKeys: citations.reduce((total, citation) => total + citation.unresolvedKeys.length, 0),
      quotes: quotes.length,
      verified: quotes.filter((quote) => quote.status === "verified").length,
      mismatched: quotes.filter((quote) => quote.status === "mismatch").length,
      unverifiable: quotes.filter((quote) => quote.status === "unverifiable").length,
    },
  };
}

export type ResearchLintIssue = { severity: "warning"; rule: string; file: string; line: number; message: string };

const CITATION_HINT = /\[cite[:/]|(?:^|[^\w&])(?:[Cc]ite|[A-Za-z]*cites?)\w*\*?:[&\w]/m;
const QUOTE_HINT = /#\+begin_quote|“[^”\n]{12,}”|"[^"\n]{12,}"/i;

/** `celorga lint` rules: unresolved citation keys and quotes not in their source. */
export function researchLintIssues(files: string[], fileContents: Map<string, string>, rootHint?: string): ResearchLintIssue[] {
  const issues: ResearchLintIssue[] = [];
  const settingsByRoot = new Map<string, ResearchSettings>();
  for (const file of files) {
    const text = fileContents.get(file);
    if (typeof text !== "string") continue;
    // Most notes have no citation and no cited quote; skip them unparsed.
    const hasCitation = CITATION_HINT.test(text);
    if (!hasCitation && !(QUOTE_HINT.test(text) && /file:/i.test(text))) continue;
    const configPath = findConfigFile(path.dirname(file));
    const root = configPath ? path.dirname(configPath) : (rootHint ? path.resolve(rootHint) : path.dirname(file));
    let settings = settingsByRoot.get(root);
    if (!settings) { settings = researchSettings(root); settingsByRoot.set(root, settings); }
    if (settings.sourceDirs.some((dir) => isInside(file, dir))) continue;
    const facts = readNoteResearchFacts(text, file);
    if (facts.citations.length === 0 && facts.quotes.length === 0) continue;
    const bibliography = bibliographyForDocument(text, file, settings);
    if (bibliography.files.length) {
      for (const citation of facts.citations) {
        for (const key of citation.keys) {
          if (bibliography.entries.has(key)) continue;
          issues.push({ severity: "warning", rule: "unresolved-citation", file, line: citation.line,
            message: `Citation key '${key}' is not in ${bibliography.files.map((bib) => path.basename(bib)).join(", ")}.` });
        }
      }
    }
    for (const quote of facts.quotes) {
      const check = checkQuote(quote, bibliography, settings.corpusRoot);
      if (check.status !== "mismatch") continue;
      issues.push({ severity: "warning", rule: "quote-not-in-source", file, line: quote.line,
        message: `${check.message}: “${quote.text.length > 80 ? quote.text.slice(0, 77) + "..." : quote.text}”` });
    }
  }
  return issues;
}

// ---------------------------------------------------------------------------
// Sources awaiting distillation

export type QueuedSource = {
  /** Corpus-relative source path, or the citation key of a bibliography entry without a file. */
  source: string;
  kind: "file" | "bibliography";
  files: string[];
  keys: string[];
  title?: string;
  addedAt?: string;
};

export type DistillationQueue = {
  $schema: "celorga:research-queue:v1";
  corpusRoot: string;
  sourceDirs: string[];
  bibliography: string[];
  pending: QueuedSource[];
  distilled: Array<QueuedSource & { notes: string[] }>;
};

function walkSourceFiles(dir: string): string[] {
  const out: string[] = [];
  const walk = (current: string) => {
    let entries: fs.Dirent[];
    try { entries = fs.readdirSync(current, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (entry.name.startsWith(".")) continue;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) out.push(full);
    }
  };
  walk(dir);
  return out;
}

/** A source file and its text exports (paper.pdf, paper.txt) are one source. */
function sourceGroupKey(file: string): string {
  return file.slice(0, file.length - path.extname(file).length);
}

export function distillationQueue(settings: ResearchSettings, files?: string[]): DistillationQueue {
  const notes = readResearchNotes(settings, files);
  const bibliography = bibliographyForDocument("", undefined, settings);
  const groups = new Map<string, QueuedSource>();
  const groupFor = (file: string): QueuedSource => {
    const key = sourceGroupKey(file);
    let group = groups.get(key);
    if (!group) {
      group = { source: displayPath(file, settings.corpusRoot), kind: "file", files: [], keys: [] };
      groups.set(key, group);
    }
    if (!group.files.includes(file)) group.files.push(file);
    return group;
  };
  for (const dir of settings.sourceDirs) for (const file of walkSourceFiles(dir)) groupFor(file);
  const keyless: QueuedSource[] = [];
  for (const entry of bibliography.entries.values()) {
    const sourceFiles = bibEntrySourceFiles(entry, settings.corpusRoot);
    const title = describeBibEntry(entry) || undefined;
    if (sourceFiles.length) {
      for (const file of sourceFiles) {
        const group = groupFor(file);
        if (!group.keys.includes(entry.key)) group.keys.push(entry.key);
        if (title && !group.title) group.title = title;
      }
    } else {
      keyless.push({ source: entry.key, kind: "bibliography", files: [], keys: [entry.key], ...(title ? { title } : {}) });
    }
  }
  const all = [...groups.values(), ...keyless];
  const pending: QueuedSource[] = [];
  const distilled: DistillationQueue["distilled"] = [];
  for (const source of all) {
    const basenames = new Set(source.files.map((file) => path.basename(sourceGroupKey(file))));
    const groupKeys = new Set(source.files.map(sourceGroupKey));
    const citing = notes.filter((note) =>
      source.keys.some((key) => note.sourceKeys.has(key))
      || [...basenames].some((name) => note.sourceKeys.has(name))
      || [...note.linkedFiles].some((linked) => groupKeys.has(sourceGroupKey(linked))),
    ).map((note) => displayPath(note.file, settings.corpusRoot));
    const mtimes = source.files.map((file) => { try { return fs.statSync(file).mtimeMs; } catch { return 0; } }).filter(Boolean);
    const withDate = mtimes.length ? { ...source, addedAt: new Date(Math.min(...mtimes)).toISOString() } : source;
    const presented = { ...withDate, files: source.files.map((file) => displayPath(file, settings.corpusRoot)) };
    if (citing.length) distilled.push({ ...presented, notes: citing });
    else pending.push(presented);
  }
  const byDate = (left: QueuedSource, right: QueuedSource) => (left.addedAt || "").localeCompare(right.addedAt || "") || left.source.localeCompare(right.source);
  return {
    $schema: "celorga:research-queue:v1",
    corpusRoot: settings.corpusRoot,
    sourceDirs: settings.sourceDirs.map((dir) => displayPath(dir, settings.corpusRoot)),
    bibliography: bibliography.files,
    pending: pending.sort(byDate),
    distilled: distilled.sort(byDate),
  };
}

// ---------------------------------------------------------------------------
// Concepts and related notes

export type ConceptIndex = {
  $schema: "celorga:research-concepts:v1";
  corpusRoot: string;
  concepts: Array<{
    tag: string;
    notes: Array<{ file: string; title: string; id?: string }>;
    related: Array<{ tag: string; shared: number }>;
  }>;
  untagged: number;
};

export function conceptIndex(settings: ResearchSettings, files?: string[], exclude?: string): ConceptIndex {
  const notes = readResearchNotes(settings, files).filter((note) => !exclude || path.resolve(note.file) !== path.resolve(exclude));
  const byTag = new Map<string, ResearchNote[]>();
  for (const note of notes) for (const tag of note.tags) {
    const list = byTag.get(tag) ?? [];
    list.push(note);
    byTag.set(tag, list);
  }
  const concepts = [...byTag.entries()].map(([tag, tagged]) => {
    const related = new Map<string, number>();
    for (const note of tagged) for (const other of note.tags) if (other !== tag) related.set(other, (related.get(other) ?? 0) + 1);
    return {
      tag,
      notes: tagged.map((note) => ({ file: displayPath(note.file, settings.corpusRoot), title: note.title, ...(note.id ? { id: note.id } : {}) }))
        .sort((left, right) => left.title.localeCompare(right.title)),
      related: [...related.entries()].map(([other, shared]) => ({ tag: other, shared }))
        .sort((left, right) => right.shared - left.shared || left.tag.localeCompare(right.tag)).slice(0, 5),
    };
  }).sort((left, right) => right.notes.length - left.notes.length || left.tag.localeCompare(right.tag));
  return { $schema: "celorga:research-concepts:v1", corpusRoot: settings.corpusRoot, concepts, untagged: notes.filter((note) => note.tags.length === 0).length };
}

function orgLinkTo(note: { file: string; title: string; id?: string }, fromDir: string, root: string): string {
  const label = note.title.replace(/[[\]]/g, "");
  if (note.id) return `[[id:${note.id}][${label}]]`;
  const relative = path.relative(fromDir, path.resolve(root, note.file)) || note.file;
  return `[[file:${relative}][${label}]]`;
}

export function renderConceptIndexOrg(index: ConceptIndex, outFile: string): string {
  const fromDir = path.dirname(path.resolve(outFile));
  const lines = [
    "#+TITLE: Concepts",
    "#+CELORGA_GENERATED: celorga research concepts",
    "",
    `Generated from note tags. ${index.concepts.length} concepts; ${index.untagged} notes have no tags. Regenerate with =celorga research concepts --apply=; edits here are replaced.`,
    "",
  ];
  for (const concept of index.concepts) {
    lines.push(`* ${concept.tag} (${concept.notes.length})`);
    if (concept.related.length) lines.push(`Related: ${concept.related.map((related) => `=${related.tag}= (${related.shared})`).join(", ")}`, "");
    for (const note of concept.notes) lines.push(`- ${orgLinkTo(note, fromDir, index.corpusRoot)}`);
    lines.push("");
  }
  return lines.join("\n").replace(/\n+$/, "\n");
}

export type RelatedNotes = {
  $schema: "celorga:research-related:v1";
  file: string;
  related: Array<{ file: string; title: string; id?: string; score: number; sharedTags: string[]; sharedSources: string[]; linked: boolean }>;
};

/** Notes that share tags or cited sources with a note, or link with it. */
export function relatedNotes(settings: ResearchSettings, target: string, limit = 10, files?: string[]): RelatedNotes {
  const notes = readResearchNotes(settings, files);
  const focus = notes.find((note) => path.resolve(note.file) === path.resolve(target));
  if (!focus) throw new Error(`Not a note in this corpus: ${target}`);
  const focusLinks = new Set([...focus.linkedFiles].map((file) => path.resolve(file)));
  const related = notes.filter((note) => note !== focus).map((note) => {
    const sharedTags = note.tags.filter((tag) => focus.tags.includes(tag));
    const sharedSources = [...note.sourceKeys].filter((key) => focus.sourceKeys.has(key));
    const linked = focusLinks.has(path.resolve(note.file)) || [...note.linkedFiles].some((file) => path.resolve(file) === path.resolve(focus.file));
    const score = sharedTags.length + sharedSources.length * 2 + (linked ? 3 : 0);
    return { file: displayPath(note.file, settings.corpusRoot), title: note.title, ...(note.id ? { id: note.id } : {}), score, sharedTags, sharedSources, linked };
  }).filter((note) => note.score > 0)
    .sort((left, right) => right.score - left.score || left.title.localeCompare(right.title))
    .slice(0, limit);
  return { $schema: "celorga:research-related:v1", file: displayPath(focus.file, settings.corpusRoot), related };
}
