import fs from "node:fs";
import path from "node:path";
import { renderOrgCharts } from "./chartRender.js";
import { findConfigFile, loadConfig } from "./config.js";
import { renderOrgDocumentToAppHtml } from "./export.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { renderPluginSourceBlocks } from "./pluginRuntime.js";
import { createLiveEmbedResolver } from "./liveEmbeds.js";
import { codeLanguageForPath } from "./codeHighlight.js";
import { citationLookupForDocument } from "./research.js";
import type { DocumentNode, SrcBlockNode } from "./ast.js";

export interface AppHTMLRenderOptions {
  sourcePath?: string;
  title?: string;
  corpusRoot?: string;
  referenceEmbeds?: boolean;
  sourceLineOffset?: number;
  stylesheetPath?: string;
}

/**
 * Render a non-Org code or text file (for example a Python script linked from
 * chat) as one highlighted, line-addressable source block instead of parsing
 * it as Org markup.
 */
export function renderCodeFileAppHTML(input: string, language: string, options: AppHTMLRenderOptions): string {
  const sourcePath = options.sourcePath;
  const text = input.replace(/\r\n/g, "\n");
  const lineCount = Math.max(1, text.replace(/\n$/, "").split("\n").length);
  const startLine = 1 + (options.sourceLineOffset ?? 0);
  const block: SrcBlockNode & { sourceRange: { startLine: number; endLine: number } } = {
    type: "SrcBlock",
    terminated: true,
    begin: { indent: "", keywordRaw: "#+begin_src", afterKeywordRaw: ` ${language}` },
    bodyRaw: text,
    end: { indent: "", keywordRaw: "#+end_src", afterKeywordRaw: "" },
    sourceRange: { startLine, endLine: startLine + lineCount - 1 },
  };
  const document: DocumentNode = { type: "Document", version: "0", children: [block] };
  return renderOrgDocumentToAppHtml(document, {
    title: options.title ?? (sourcePath ? path.basename(sourcePath) : undefined),
    sourcePath,
    customCss: options.stylesheetPath ? fs.readFileSync(options.stylesheetPath, "utf8") : undefined,
    codeFile: true,
  }).html;
}

export function renderAppHTML(input: string, options: AppHTMLRenderOptions): string {
  const sourcePath = options.sourcePath;
  const codeLanguage = codeLanguageForPath(sourcePath);
  if (codeLanguage) return renderCodeFileAppHTML(input, codeLanguage, options);
  const sourceLineOffset = options.sourceLineOffset ?? 0;
  const normalizedInput = input.replace(/\r\n/g, "\n");
  let renderInput = normalizedInput;
  let document: ReturnType<typeof parseOrgToCanonicalAst>;
  try {
    document = parseOrgToCanonicalAst(renderInput, {
      sourceRanges: true,
      sourcePath,
      sourceLineOffset,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("Unsupported construct: tab character")) throw error;
    renderInput = normalizedInput.replace(/\t/g, "  ");
    document = parseOrgToCanonicalAst(renderInput, {
      sourceRanges: true,
      sourcePath,
      sourceLineOffset,
    });
  }

  const customCss = options.stylesheetPath
    ? fs.readFileSync(options.stylesheetPath, "utf8")
    : undefined;
  const charts = renderOrgCharts(renderInput, { file: sourcePath, sourceLineOffset })
    .filter((chart): chart is typeof chart & { svg: string; source: NonNullable<typeof chart.source> } => chart.ok && Boolean(chart.svg && chart.source))
    .map((chart) => ({ svg: chart.svg, source: chart.source, presentation: chart.presentation }));
  const pluginRenders = renderPluginSourceBlocks(document, { sourcePath }).renders;
  let linkAbbreviations: Record<string, string> | undefined;
  let linearTeam: string | undefined;
  if (sourcePath) {
    const configPath = findConfigFile(path.dirname(path.resolve(sourcePath)));
    if (configPath) {
      try {
        const config = loadConfig(configPath);
        linkAbbreviations = config.links?.abbreviations;
        linearTeam = config.links?.linearTeam;
      } catch {
        // A malformed workspace config should not make the document preview unavailable.
      }
    }
  }

  return renderOrgDocumentToAppHtml(document, {
    title: options.title,
    sourcePath,
    customCss,
    charts,
    pluginRenders,
    linkAbbreviations,
    linearTeam,
    citationLookup: citationLookupForDocument(renderInput, sourcePath, options.corpusRoot),
    embedResolver: sourcePath && !options.referenceEmbeds
      ? createLiveEmbedResolver({ sourcePath, rootDir: options.corpusRoot })
      : undefined,
  }).html;
}
