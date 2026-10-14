import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type {
  DocumentNode,
  InlineNode,
  ListItemNode,
  Node,
  TableNode,
} from "./ast.js";
import { compileBeamerPdf } from "./beamerCompile.js";
import {
  compilePresentation,
  renderPresentationToBeamer,
} from "./presentation.js";

export type PreparedPublishedBeamer = {
  tex: string;
  byteLength: number;
  sha256: string;
  slideCount: number;
};

export type PreparedPublishedBeamerPdf = {
  mediaType: "application/pdf";
  bytes: Buffer;
  byteLength: number;
  sha256: string;
  slideCount: number;
};

type EmbeddedImage = {
  extension: "jpg" | "png";
  data: Buffer;
};

function digest(value: string | Buffer): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function safeMetadataText(value: string): string {
  return String(value || "")
    .replace(/\\/g, "＼")
    .replace(/\$/g, "＄")
    .replace(/\{/g, "｛")
    .replace(/\}/g, "｝");
}

function codeInline(value: string): InlineNode {
  return {
    type: "Emphasis",
    kind: "code",
    marker: "=",
    content: value,
  };
}

function parseEmbeddedImage(target: string): EmbeddedImage | null {
  const match = /^data:(image\/(?:jpeg|png));base64,([a-z0-9+/=]+)$/i.exec(String(target || "").trim());
  if (!match) return null;
  return {
    extension: match[1]!.toLowerCase() === "image/jpeg" ? "jpg" : "png",
    data: Buffer.from(match[2]!, "base64"),
  };
}

function normalizeInline(node: InlineNode, imageDirectory?: string): InlineNode {
  switch (node.type) {
    case "Text":
      return { type: "Text", value: node.value };
    case "Timestamp":
      return { type: "Text", value: node.raw };
    case "TimestampRange":
      return { type: "Text", value: `${node.start.raw}${node.separatorRaw}${node.end.raw}` };
    case "Emphasis":
      if (/[$\\]/.test(node.content)) return codeInline(node.content);
      return { ...node };
    case "Link": {
      const embedded = parseEmbeddedImage(node.targetRaw);
      if (embedded) {
        const filename = `published-image-${digest(embedded.data).slice(0, 16)}.${embedded.extension}`;
        const target = imageDirectory ? path.join(imageDirectory, filename) : filename;
        if (imageDirectory && !fs.existsSync(target)) fs.writeFileSync(target, embedded.data);
        return {
          type: "Link",
          format: node.format,
          raw: `[[${target}]]`,
          targetRaw: target,
        };
      }
      if (/^data:image\//i.test(node.targetRaw)) {
        throw new Error("Safe Beamer publishing supports embedded PNG and JPEG images; convert this image or publish HTML/PDF instead");
      }
      return {
        ...node,
        ...(node.descriptionRaw !== undefined
          ? { descriptionRaw: safeMetadataText(node.descriptionRaw) }
          : {}),
      };
    }
    case "ProgressCookie":
      return { ...node };
    case "Entity":
    case "LatexFragment":
      return codeInline(node.raw);
    case "ExportSnippet":
      return { type: "Text", value: "" };
    case "FootnoteReference":
      return codeInline(node.definitionRaw || node.labelRaw || "footnote");
    case "Citation":
      return { type: "Text", value: node.references.map((reference) => `@${reference.keyRaw}`).join("; ") };
    case "Target":
      return { type: "Text", value: "" };
    case "Script":
      return { ...node, valueRaw: safeMetadataText(node.valueRaw) };
    case "LineBreak":
      return { ...node };
  }
}

function normalizeInlines(nodes: InlineNode[], imageDirectory?: string): InlineNode[] {
  return nodes.map((node) => normalizeInline(node, imageDirectory));
}

function literalParagraphs(value: string): Node[] {
  return String(value || "").replace(/\r\n/g, "\n").split("\n").map((line) => ({
    type: "Paragraph" as const,
    children: [codeInline(line)],
  }));
}

function normalizeListItem(item: ListItemNode, imageDirectory?: string): ListItemNode {
  return {
    type: "ListItem",
    ...(item.ordinal !== undefined ? { ordinal: item.ordinal } : {}),
    ...(item.counter !== undefined ? { counter: item.counter } : {}),
    ...(item.checkbox !== undefined ? { checkbox: item.checkbox } : {}),
    ...(item.progressCookie ? { progressCookie: { ...item.progressCookie } } : {}),
    ...(item.descriptionTag ? { descriptionTag: normalizeInlines(item.descriptionTag, imageDirectory) } : {}),
    children: normalizeNodes(item.children, imageDirectory),
  };
}

function normalizeTable(node: TableNode, imageDirectory?: string): TableNode {
  return {
    type: "Table",
    rows: node.rows.map((row) => {
      if (row.type === "TableHline") return { ...row };
      const contents = (row.contents || row.cells.map((cell) => [{ type: "Text" as const, value: cell }]))
        .map((cell) => normalizeInlines(cell, imageDirectory));
      return { ...row, contents };
    }),
  };
}

function normalizeNode(node: Node, imageDirectory?: string): Node[] {
  switch (node.type) {
    case "Headline":
      return [{
        type: "Headline",
        level: node.level,
        title: normalizeInlines(node.title, imageDirectory),
        children: normalizeNodes(node.children, imageDirectory),
      }];
    case "Paragraph":
      return [{ type: "Paragraph", children: normalizeInlines(node.children, imageDirectory) }];
    case "List":
      return [{ type: "List", ordered: node.ordered, items: node.items.map((item) => normalizeListItem(item, imageDirectory)) }];
    case "ListItem":
      return [normalizeListItem(node, imageDirectory)];
    case "KeywordLine": {
      const key = node.keyRaw.trim().toUpperCase();
      const value = ["BEAMER_FRAME_LEVEL", "CELORGA_SLIDE_LEVEL", "ORG2_SLIDE_LEVEL", "SLIDE_LEVEL"].includes(key)
        ? node.valueRaw
        : safeMetadataText(node.valueRaw);
      return [{ ...node, raw: `#+${key}: ${value}`, keyRaw: key, valueRaw: value }];
    }
    case "SrcBlock":
    case "Block":
      return literalParagraphs(node.bodyRaw);
    case "FixedWidth":
      return literalParagraphs(node.lines.map((line) => line.valueRaw).join("\n"));
    case "LatexEnvironment":
      return literalParagraphs([node.beginRaw, node.bodyRaw, node.endRaw].filter(Boolean).join("\n"));
    case "FootnoteDefinition":
      return [{ type: "Paragraph", children: [codeInline(`[${node.labelRaw}] ${node.children.map((child) => "raw" in child ? child.raw : "").join("")}`)] }];
    case "Table":
      return [normalizeTable(node, imageDirectory)];
    case "Text":
      return [{ type: "Paragraph", children: [{ type: "Text", value: node.value }] }];
    case "HorizontalRule":
      return [{ ...node }];
    default:
      return [];
  }
}

function normalizeNodes(nodes: Node[], imageDirectory?: string): Node[] {
  return nodes.flatMap((node) => normalizeNode(node, imageDirectory));
}

function normalizedPresentationDocument(document: DocumentNode, imageDirectory?: string): DocumentNode {
  return {
    type: "Document",
    version: document.version,
    children: normalizeNodes(document.children, imageDirectory),
  };
}

function validatePresentation(document: DocumentNode): number {
  const presentation = compilePresentation(document);
  const fatal = presentation.diagnostics.find((diagnostic) => diagnostic.severity === "error");
  if (fatal) throw new Error(`Beamer publishing requires slide headings: ${fatal.message}`);
  const slideCount = presentation.sections.reduce((sum, section) => sum + section.slides.length, 0);
  if (!slideCount) throw new Error("Beamer publishing requires at least one slide heading");
  return slideCount;
}

export function preparePublishedBeamer(document: DocumentNode): PreparedPublishedBeamer {
  const normalized = normalizedPresentationDocument(document);
  const slideCount = validatePresentation(normalized);
  const rendered = renderPresentationToBeamer(normalized);
  const fatal = rendered.diagnostics.find((diagnostic) => diagnostic.severity === "error");
  if (fatal) throw new Error(`Beamer publishing failed: ${fatal.message}`);
  return {
    tex: rendered.tex,
    byteLength: Buffer.byteLength(rendered.tex),
    sha256: digest(rendered.tex),
    slideCount,
  };
}

export function compilePublishedBeamerPdf(
  document: DocumentNode,
  options: { engine?: string; passes?: number } = {},
): PreparedPublishedBeamerPdf {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "org2-published-beamer-"));
  try {
    const normalized = normalizedPresentationDocument(document, temporaryDirectory);
    const slideCount = validatePresentation(normalized);
    const rendered = renderPresentationToBeamer(normalized);
    const fatal = rendered.diagnostics.find((diagnostic) => diagnostic.severity === "error");
    if (fatal) throw new Error(`Beamer publishing failed: ${fatal.message}`);
    const compiled = compileBeamerPdf(rendered.tex, {
      sourcePath: path.join(temporaryDirectory, "publication.org"),
      engine: options.engine,
      passes: options.passes ?? 1,
    });
    if (!compiled.ok) throw new Error(compiled.message);
    return {
      mediaType: "application/pdf",
      bytes: compiled.pdf,
      byteLength: compiled.pdf.length,
      sha256: digest(compiled.pdf),
      slideCount,
    };
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
