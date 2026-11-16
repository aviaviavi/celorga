// Citation syntax shared by the renderer (including the mobile bundle, which
// has no filesystem) and the research module.

import type { CitationNode, LinkNode } from "./ast.js";

/** org-ref and biblatex citation link types. */
const CITATION_LINK_TYPE = /^(?:[Cc]ite(?:p|t|alp|alt|author|year|yearpar|num|text|url)?|(?:[Pp]aren|[Tt]ext|[Aa]uto|[Ff]oot|[Ff]ull|[Ss]mart|[Ss]uper|no)cites?)\*?$/;

export type CitationReference = { key: string; prefix?: string; suffix?: string };

export type ParsedCitation = {
  syntax: "org-cite" | "org-ref";
  style?: string;
  references: CitationReference[];
};

export function isCitationLinkType(type: string): boolean {
  return CITATION_LINK_TYPE.test(type);
}

/** Reads `citep:a,b` (org-ref 2) or `citep:See &a p. 3;&b` (org-ref 3). */
export function citationFromLinkTarget(target: string): ParsedCitation | null {
  const separator = target.indexOf(":");
  if (separator <= 0) return null;
  const type = target.slice(0, separator);
  if (!isCitationLinkType(type)) return null;
  const body = target.slice(separator + 1).trim();
  if (!body) return null;
  const references: CitationReference[] = [];
  if (body.includes("&")) {
    for (const segment of body.split(";")) {
      const match = /^(.*?)&([^\s;,&]+)(.*)$/.exec(segment);
      if (!match) continue;
      const prefix = (match[1] ?? "").trim();
      const suffix = (match[3] ?? "").trim();
      references.push({ key: match[2]!, ...(prefix ? { prefix } : {}), ...(suffix ? { suffix } : {}) });
    }
  } else {
    for (const key of body.split(",")) {
      const trimmed = key.trim();
      if (trimmed) references.push({ key: trimmed });
    }
  }
  return references.length ? { syntax: "org-ref", style: type, references } : null;
}

export function citationFromNode(node: CitationNode | LinkNode): ParsedCitation | null {
  if (node.type === "Citation") {
    return {
      syntax: "org-cite",
      ...(node.styleRaw ? { style: node.styleRaw } : {}),
      references: node.references.map((reference) => ({
        key: reference.keyRaw,
        ...(reference.prefixRaw ? { prefix: reference.prefixRaw } : {}),
        ...(reference.suffixRaw ? { suffix: reference.suffixRaw } : {}),
      })),
    };
  }
  return citationFromLinkTarget(String(node.targetRaw || "").trim());
}

/** What a rendered citation shows for one key; see research.ts. */
export type CitationRenderInfo = {
  resolved: boolean;
  title?: string;
  /** A file: link target for the cited source, when it exists. */
  sourceTarget?: string;
};

export type CitationLookup = (key: string) => CitationRenderInfo;
