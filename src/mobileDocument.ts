import type { DocumentNode, HeadlineNode, InlineNode, Node } from "./ast.js";
import { parseInlinesFromText, parseOrgToCanonicalAst } from "./parser.js";
import { documentTodoSequences, parseTodoSequenceDefinitions } from "./todo.js";
import { renderOrgDocumentToAppHtml } from "./export.js";
import { parseIdLinkTarget, resolveIdLinkInText } from "./linkSearch.js";
import { isPresentationDocument } from "./presentation.js";

type Ranged = Node & { sourceRange?: { startLine: number; endLine: number } };

function inlineText(nodes: InlineNode[]): string {
  return nodes.map(node => node.type === "Text" ? node.value
    : node.type === "Emphasis" ? node.content
    : node.type === "Link" ? node.descriptionRaw ?? node.targetRaw
    : "raw" in node ? node.raw : "").join("");
}

function visibleText(nodes: Node[]): string {
  return nodes.map(node => {
    switch (node.type) {
      case "Paragraph": return inlineText(node.children);
      case "Headline": return `${inlineText(node.title)} ${visibleText(node.children)}`;
      case "List": return visibleText(node.items);
      case "ListItem": return `${inlineText(node.descriptionTag ?? [])} ${visibleText(node.children)}`;
      case "Text": return node.value;
      case "SrcBlock": return node.bodyRaw;
      case "Table": return node.rows.filter(row => row.type === "TableRow").map(row => row.cells.map(cell => inlineText(parseInlinesFromText(cell))).join(" ")).join("\n");
      case "Block": return ["quote", "verse", "example", "center"].includes(node.kind) ? node.bodyRaw : "";
      default: return "";
    }
  }).join("\n").trim();
}

function parse(source: string, sequences: string[] = []): DocumentNode {
  const normalized = source.replace(/\r\n?/g, "\n");
  const options = { sourceRanges: true, todoSequences: documentTodoSequences(normalized,
    sequences.length ? parseTodoSequenceDefinitions(sequences) : []) };
  try { return parseOrgToCanonicalAst(normalized, options); }
  catch (error) {
    if (!(error instanceof Error) || !error.message.includes("Unsupported construct: tab character")) throw error;
    return parseOrgToCanonicalAst(normalized.replace(/\t/g, "  "), options);
  }
}

function property(nodes: Node[], key: string): string {
  const drawer = nodes.find(node => node.type === "PropertyDrawer");
  return drawer?.type === "PropertyDrawer" ? drawer.properties.find(p => p.key.toUpperCase() === key)?.value ?? "" : "";
}

// Resolve against freshly read source, using the same AST as indexing/rendering.
export function resolveEntry(source: string, path: string, selector: string, sequences: string[] = []) {
  const doc = parse(source, sequences);
  const entries = indexDocument(source, path, sequences);
  if (!selector) return { entry: null };
  let matches: typeof entries = [];
  const idTarget = parseIdLinkTarget(selector);
  if (idTarget?.search) {
    // Org 10 `id:ID::SEARCH`: select the entry that contains the match,
    // searching the ID's subtree first and then its file.
    const owners = entries.filter(entry => entry.nodeID === idTarget.id);
    if (owners.length > 1) throw new Error("This entry link is ambiguous.");
    const match = owners.length ? resolveIdLinkInText(source, idTarget) : null;
    if (!match) throw new Error("The linked entry no longer exists. Refresh the corpus and try again.");
    matches = entries.filter(entry => entry.line > 0 && entry.line <= match.line).slice(-1);
    if (!matches.length) return { entry: null };
  } else if (idTarget) {
    matches = entries.filter(entry => entry.nodeID === idTarget.id);
  } else if (/^[1-9][0-9]*$/.test(selector)) {
    const line = Number(selector);
    if (line > source.replace(/\r\n?/g, "\n").split("\n").length) throw new Error("The linked line no longer exists.");
    matches = entries.filter(entry => entry.line > 0 && entry.line <= line).slice(-1);
    if (!matches.length) return { entry: null };
  } else if (selector.startsWith("#")) {
    const lines = new Set<number>();
    function walk(nodes: Node[]) {
      for (const node of nodes) if (node.type === "Headline") {
        if (property(node.children, "CUSTOM_ID") === selector.slice(1)) lines.add((node as Ranged).sourceRange!.startLine);
        walk(node.children);
      }
    }
    walk(doc.children);
    matches = entries.filter(entry => lines.has(entry.line));
    if (property(doc.children, "CUSTOM_ID") === selector.slice(1)) matches.push(entries[0]!);
  } else {
    const title = selector.replace(/^\*+\s*/, "");
    matches = entries.filter(entry => entry.line > 0 && entry.title === title);
  }
  if (matches.length !== 1) throw new Error(matches.length ? "This entry link is ambiguous." : "The linked entry no longer exists. Refresh the corpus and try again.");
  return { entry: matches[0]!.line === 0 ? null : matches[0] };
}

export function indexDocument(source: string, path: string, sequences: string[] = []) {
  const doc = parse(source, sequences);
  const title = doc.children.find(node => node.type === "KeywordLine" && node.keyRaw.toUpperCase() === "TITLE");
  const pageTitle = title?.type === "KeywordLine" ? title.valueRaw.trim() : path.split("/").pop() ?? path;
  const entries = [{ path, title: pageTitle, parent: "", line: 0, nodeID: property(doc.children, "ID"), body: visibleText(doc.children.filter(n => n.type !== "Headline")) }];
  function walk(nodes: Node[], parents: string[]) {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const title = inlineText(node.title);
      const drawer = node.children.find(n => n.type === "PropertyDrawer");
      const nodeID = drawer?.type === "PropertyDrawer" ? drawer.properties.find(p => p.key.toUpperCase() === "ID")?.value ?? "" : "";
      entries.push({ path, title, parent: parents.join(" › "), line: (node as Ranged).sourceRange!.startLine,
        nodeID, body: visibleText(node.children.filter(n => n.type !== "Headline")) });
      walk(node.children, [...parents, title]);
    }
  }
  walk(doc.children, [pageTitle]);
  return entries;
}

export function renderDocument(source: string, path: string, line = 0, nodeID = "", sequences: string[] = [], expectedTitle = "") {
  const doc = parse(source, sequences);
  let selected: HeadlineNode | undefined;
  function walk(nodes: Node[]) {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const drawer = node.children.find(n => n.type === "PropertyDrawer");
      const id = drawer?.type === "PropertyDrawer" ? drawer.properties.find(p => p.key.toUpperCase() === "ID")?.value : undefined;
      if (nodeID ? id === nodeID : (node as Ranged).sourceRange?.startLine === line) selected = node;
      walk(node.children);
    }
  }
  if (line > 0) {
    walk(doc.children);
    if (!selected || (!nodeID && expectedTitle && inlineText(selected.title) !== expectedTitle)) throw new Error("This entry changed. Refresh search and try again.");
  }
  const rendered = renderOrgDocumentToAppHtml(selected ? { ...doc, children: [selected] } : doc, {
    sourcePath: path,
    nativeInternalLinks: true,
    title: selected ? inlineText(selected.title) : undefined,
    customCss: "body{padding:16px;margin:0;max-width:none} .org2-document-title::before,.org2-headline-summary::before,.org2-headline-summary>h1::before,.org2-headline-summary>h2::before,.org2-headline-summary>h3::before,.org2-headline-summary>h4::before,.org2-headline-summary>h5::before,.org2-headline-summary>h6::before{content:none} .org2-headline{border-left:0}"
  });
  // The local reader never executes source-provided scripts or loads remote embeds.
  const policy = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'none'">`;
  // A whole presentation file can also be shown as slides rendered by the host.
  const kind = !selected && isPresentationDocument(doc) ? "slides" : "document";
  const html = rendered.html.replace("<head>", `<head>${policy}`);
  return { title: rendered.title, html, kind, images: documentImages(html, path) };
}

function decodeAttribute(value: string): string {
  return value.replace(/&(amp|quot|#39|lt|gt);/g, (_, entity: string) =>
    ({ amp: "&", quot: "\"", "#39": "'", lt: "<", gt: ">" } as Record<string, string>)[entity]!);
}

// The reader blocks file and network loads, so the phone fetches each local
// image from the host and swaps it in as a data URL. `src` is the attribute as
// written in the HTML; `path` is corpus-relative (or absolute, for the host to
// authorize) with `..` already resolved.
export function documentImages(html: string, documentPath: string): { src: string; path: string }[] {
  const images: { src: string; path: string }[] = [];
  const seen = new Set<string>();
  for (const match of html.matchAll(/<img class="org2-image" src="([^"]*)"/g)) {
    const src = match[1]!;
    if (seen.has(src)) continue;
    seen.add(src);
    let target = decodeAttribute(src);
    if (/^[a-z][a-z0-9+.-]*:/i.test(target) && !target.startsWith("file:")) continue;
    target = target.replace(/^file:/, "").replace(/[?#].*$/, "");
    try { target = decodeURI(target); } catch { /* keep the literal path */ }
    if (!target || target.startsWith("~")) continue;
    const absolute = target.startsWith("/");
    const parts = absolute ? [] : documentPath.split("/").slice(0, -1);
    let escaped = false;
    for (const part of target.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") { if (parts.length && parts[parts.length - 1] !== "..") parts.pop(); else escaped = true; }
      else parts.push(part);
    }
    if (escaped) continue;
    images.push({ src, path: (absolute ? "/" : "") + parts.join("/") });
  }
  return images;
}
