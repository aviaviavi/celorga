import { CHART_INTERACTION_SCRIPT, CHART_INTERACTION_STYLE } from "./chartInteraction.js";
import path from "node:path";
import type {
  BlockNode,
  DocumentNode,
  EmphasisNode,
  HeadlineNode,
  InlineNode,
  LinkNode,
  ListItemNode,
  ListNode,
  Node,
  ParagraphNode,
  PlanningNode,
  PropertyDrawerNode,
  SrcBlockNode,
  TableHlineNode,
  TableNode,
  TableRowNode,
  TimestampNode,
  TimestampRangeNode,
} from "./ast.js";
import { parseInlinesFromText } from "./parser.js";
import { terminalTodoStatusFromKeyword } from "./todo.js";
import { parseOrgColorBindingTarget, type OrgColorBinding } from "./colorBinding.js";
import {
  buildBuiltInLinkAbbreviations,
  collectLinkAbbreviationsFromDoc,
  collectLinkAbbreviationsFromRecord,
  expandLinkAbbreviationTarget,
  mergeLinkAbbreviations,
  type LinkAbbreviationMap,
  type LinkAbbreviationRecord,
} from "./link-abbrev.js";
import { COMPAT_CONTENT_CLOSE, COMPAT_CONTENT_OPEN, COMPAT_CONTENT_STYLE_SECTION } from "./publish-defaults.js";
import { isPresentationDocument } from "./presentation.js";
import { evaluateTableNode } from "./tableFormula.js";
import type { Org2PluginRender } from "./pluginRuntime.js";
import type { LiveEmbedResolver } from "./liveEmbeds.js";
import { highlightCodeLinesToHtml, highlightCodeToHtml, normalizeCodeLanguage } from "./codeHighlight.js";

function escapeHtml(value: string): string {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;");
}

function escapeAttr(value: string): string {
  return escapeHtml(value).replace(/`/g, "&#96;");
}

function normalizeStylesheets(stylesheets: string[] | undefined): string[] {
  if (!Array.isArray(stylesheets)) return [];
  return stylesheets.map((href) => String(href || "").trim()).filter((href) => href.length > 0);
}

const DEFAULT_DOCUMENT_STYLE = `:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 860px; padding: 0 1rem; line-height: 1.5; }
main { display: grid; gap: 0.75rem; }
section.org2-headline { margin: 0.5rem 0 1rem; }
h1,h2,h3,h4,h5,h6 { margin: 1rem 0 0.5rem; line-height: 1.25; }
.org2-todo { display: inline-block; font-size: 0.8em; font-weight: 700; letter-spacing: 0.02em; text-transform: uppercase; opacity: 0.9; }
.org2-headline .org2-headline-done { opacity: 0.65; }
.org2-headline .org2-headline-canceled { opacity: 0.45; text-decoration: line-through; }
.org2-tags { font-size: 0.8em; opacity: 0.8; }
.org2-tag { border: 1px solid currentColor; border-radius: 999px; padding: 0 0.35em; }
.org2-planning { font-size: 0.95em; opacity: 0.9; }
.org2-planning-kind { font-weight: 600; }
.org2-properties { display: grid; grid-template-columns: max-content 1fr; gap: 0.15rem 0.75rem; margin: 0.5rem 0; }
.org2-properties dt { font-weight: 600; }
.org2-properties dd { margin: 0; }
.org2-src, .org2-example, .org2-verse, .org2-comment, .org2-directive, pre { overflow-x: auto; padding: 0.75rem; border-radius: 0.5rem; background: rgba(127,127,127,0.12); }
.org2-center { text-align: center; }
.org2-underline { text-decoration: underline; }
table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1rem; }
th, td { border: 1px solid rgba(127,127,127,0.35); padding: 0.35rem 0.5rem; text-align: left; }
thead th { background: rgba(127,127,127,0.16); }
a { text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }`;

const DOCUMENT_IMAGE_STYLE = `
.org2-image-figure { max-width: 100%; margin: 0.75rem 0 1rem; }
.org2-image-link { display: block; border: 0; }
.org2-image { display: block; width: auto; max-width: 100%; height: auto; border-radius: 0.5rem; }
li > .org2-image-figure { margin-top: 0.55rem; }
.org2-inline-image-link { width: fit-content; max-width: 100%; margin: 0.55rem 0 0.75rem; }`;

const DOCUMENT_CHART_STYLE = `:root {
  --org2-chart-axis: #475569;
  --org2-chart-grid: #d7dee8;
  --org2-chart-mark: #2563eb;
  --org2-chart-label: #475569;
  --org2-chart-title: #0f172a;
  --org2-chart-surface: #ffffff;
  --org2-chart-series-2: #d9480f;
  --org2-chart-series-3: #0f9d8a;
  --org2-chart-series-4: #8e44ad;
  --org2-chart-series-5: #c2185b;
  --org2-chart-series-6: #5c8a1f;
  --org2-chart-series-7: #b7791f;
  --org2-chart-series-8: #2b6cb0;
}
@media (prefers-color-scheme: dark) {
  :root {
    --org2-chart-axis: rgba(233, 234, 237, 0.5);
    --org2-chart-grid: rgba(233, 234, 237, 0.12);
    --org2-chart-mark: #79b8ed;
    --org2-chart-label: #a4a8b0;
    --org2-chart-title: #e9eaed;
    --org2-chart-surface: #202226;
    --org2-chart-series-2: #ff9b6a;
    --org2-chart-series-3: #4fd1c5;
    --org2-chart-series-4: #c39bf0;
    --org2-chart-series-5: #f687b3;
    --org2-chart-series-6: #9ae66e;
    --org2-chart-series-7: #f6c66b;
    --org2-chart-series-8: #7fb2f0;
  }
}
.org2-chart { width: min(100%, 800px); margin: 1rem 0 1.35rem; overflow-x: auto; }
.org2-chart-compact { width: min(100%, 680px); }
.org2-chart-wide { width: 100%; }
.org2-chart svg { display: block; width: 100%; height: auto; margin: 0; }`;

const DOCUMENT_TOC_STYLE = `.org2-toc { border: 1px solid rgba(127,127,127,0.35); border-radius: 0.5rem; padding: 0.75rem 1rem; margin: 0.25rem 0 1rem; }
.org2-toc h2 { margin: 0 0 0.5rem; font-size: 1rem; }
.org2-toc ul { margin: 0; padding-left: 1.25rem; display: grid; gap: 0.25rem; }
.org2-toc li.org2-toc-level-2 { margin-left: 0.75rem; }
.org2-toc li.org2-toc-level-3 { margin-left: 1.5rem; }
.org2-toc li.org2-toc-level-4 { margin-left: 2.25rem; }
.org2-toc li.org2-toc-level-5 { margin-left: 3rem; }
.org2-toc li.org2-toc-level-6 { margin-left: 3.75rem; }`;

/** Token colors for the app view's native code highlighting (app profile only). */
const APP_CODE_HIGHLIGHT_STYLE = `.org2-code-file { margin-top: 0.4rem; }
.org2-tok-comment { color: #6b7570; font-style: italic; }
.org2-tok-string { color: #1f7a3d; }
.org2-tok-keyword { color: #8a3fb8; font-weight: 600; }
.org2-tok-number, .org2-tok-literal { color: #b0561b; }
.org2-tok-type { color: #1d6f9e; }
.org2-tok-function { color: #2854d7; }
.org2-tok-property, .org2-tok-attr { color: #9a4a12; }
.org2-tok-meta, .org2-tok-variable { color: #a33a6e; }
.org2-tok-tag { color: #8a3fb8; }
@media (prefers-color-scheme: dark) {
  .org2-tok-comment { color: #87918c; }
  .org2-tok-string { color: #8fd19e; }
  .org2-tok-keyword { color: #d3a4f5; }
  .org2-tok-number, .org2-tok-literal { color: #f0a673; }
  .org2-tok-type { color: #79c5ec; }
  .org2-tok-function { color: #9db4ff; }
  .org2-tok-property, .org2-tok-attr { color: #f2c27d; }
  .org2-tok-meta, .org2-tok-variable { color: #f29bc5; }
  .org2-tok-tag { color: #d3a4f5; }
}`;

const APP_DOCUMENT_STYLE = `.org2-live-embed { margin: 1rem 0; border: 1px solid var(--org2-rule); border-radius: 8px; overflow: hidden; }
.org2-live-embed > header { padding: 9px 12px; font-size: 0.84rem; background: var(--org2-faint); }
.org2-live-embed > p { padding: 0 12px; }
.org2-live-embed-frame { display: block; width: 100%; height: 320px; border: 0; background: transparent; }
:root {
  color-scheme: light dark;
  --org2-text: #18201e;
  --org2-muted: #5e6b66;
  --org2-faint: rgba(40, 84, 215, 0.065);
  --org2-rule: #d7d6ce;
  --org2-code: #f1f3ef;
  --org2-surface: #fcfbf7;
  --org2-elevated-surface: #ffffff;
  --org2-shadow: rgba(29, 43, 38, 0.065);
  --org2-link: #2854d7;
  --org2-accent: #2854d7;
  --org2-signal: #c2472c;
  --org2-success: #20804a;
  --org2-danger: #b64238;
  --org2-warning: #966512;
  --org2-chart-axis: rgba(56, 61, 69, 0.54);
  --org2-chart-grid: rgba(56, 61, 69, 0.12);
  --org2-chart-mark: #3478d4;
  --org2-chart-label: #6c7078;
  --org2-chart-title: #24262a;
  --org2-chart-surface: #ffffff;
  --org2-chart-series-2: #d9480f;
  --org2-chart-series-3: #0f9d8a;
  --org2-chart-series-4: #8e44ad;
  --org2-chart-series-5: #c2185b;
  --org2-chart-series-6: #5c8a1f;
  --org2-chart-series-7: #b7791f;
  --org2-chart-series-8: #2b6cb0;
  --org2-font-mono: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
  --org2-content-width: 960px;
  --org2-page-padding: 28px;
}
@media (prefers-color-scheme: dark) {
  :root {
    --org2-text: #dce3de;
    --org2-muted: #a2ada7;
    --org2-faint: rgba(134, 163, 255, 0.09);
    --org2-rule: #36403c;
    --org2-code: #121715;
    --org2-surface: #1b211f;
    --org2-elevated-surface: #222927;
    --org2-shadow: rgba(0, 0, 0, 0.24);
    --org2-link: #86a3ff;
    --org2-accent: #86a3ff;
    --org2-signal: #ff8668;
    --org2-success: #6ac58c;
    --org2-danger: #ee8178;
    --org2-warning: #e0b361;
    --org2-chart-axis: rgba(233, 234, 237, 0.5);
    --org2-chart-grid: rgba(233, 234, 237, 0.12);
    --org2-chart-mark: #79b8ed;
    --org2-chart-label: #a4a8b0;
    --org2-chart-title: #e9eaed;
    --org2-chart-surface: #202226;
    --org2-chart-series-2: #ff9b6a;
    --org2-chart-series-3: #4fd1c5;
    --org2-chart-series-4: #c39bf0;
    --org2-chart-series-5: #f687b3;
    --org2-chart-series-6: #9ae66e;
    --org2-chart-series-7: #f6c66b;
    --org2-chart-series-8: #7fb2f0;
  }
}
*, *::before, *::after { box-sizing: border-box; }
html, body { width: 100%; max-width: 100%; min-height: 100%; margin: 0; background: transparent; overflow-x: hidden; }
body {
  color: var(--org2-text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
  font-size: 15px;
  line-height: 1.58;
  letter-spacing: 0;
  -webkit-font-smoothing: antialiased;
  overflow-wrap: anywhere;
}
main.org2-document {
  width: min(100%, var(--org2-content-width));
  max-width: 100%;
  margin: 0 auto;
  padding: 22px clamp(16px, 5vw, var(--org2-page-padding)) 64px;
}
main.org2-document,
main.org2-document > *,
section.org2-headline,
details.org2-headline,
.org2-headline-body { min-width: 0; }
.org2-document-header { margin: 0.15rem 0 1.1rem; }
.org2-document-title {
  margin: 0;
  font-size: clamp(1.9rem, 4vw, 2.45rem);
  font-weight: 650;
  line-height: 1.14;
  letter-spacing: -0.025em;
}
.org2-document-title::before {
  display: inline-block;
  margin-right: 0.48rem;
  color: var(--org2-signal);
  content: "*";
  font-family: var(--org2-font-mono);
  font-size: 0.38em;
  font-weight: 650;
  vertical-align: 0.72em;
}
.org2-document-subtitle { margin: 0.32rem 0 0; color: var(--org2-muted); font-size: 1rem; }
.org2-file-properties {
  margin: 0 0 1rem;
  color: var(--org2-muted);
  font-family: var(--org2-font-mono);
  font-size: 0.84rem;
}
.org2-file-properties > summary {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 0.42rem;
  padding-left: 1rem;
  color: var(--org2-muted);
  cursor: pointer;
  list-style: none;
  font-weight: 600;
  user-select: none;
}
.org2-file-properties > summary::-webkit-details-marker { display: none; }
.org2-file-properties > summary::before {
  content: "▶";
  position: absolute;
  left: 0;
  color: var(--org2-muted);
  font-size: 0.7rem;
}
.org2-file-properties[open] > summary::before { content: "▼"; }
.org2-file-properties-count {
  min-width: 1.35rem;
  padding: 0.04rem 0.32rem;
  border-radius: 999px;
  background: var(--org2-faint);
  text-align: center;
  font-size: 0.72rem;
  font-variant-numeric: tabular-nums;
}
.org2-file-properties-body {
  margin: 0.55rem 0 0;
  padding: 0.58rem 0.72rem;
  border: 1px solid var(--org2-rule);
  border-radius: 10px;
  background: var(--org2-elevated-surface);
  box-shadow: 0 1px 2px var(--org2-shadow);
}
.org2-file-properties .org2-properties { margin: 0; padding: 0; border-top: 0; }
.org2-headline { margin: 0; }
.org2-headline + .org2-headline { margin-top: 0.72rem; }
.org2-headline-summary {
  margin: 0.9rem 0 0.36rem;
  padding-left: 1.15rem;
  color: var(--org2-text);
  cursor: pointer;
  list-style: none;
  position: relative;
}
.org2-headline-summary::-webkit-details-marker,
.org2-properties-drawer > summary::-webkit-details-marker,
.org2-large-source > summary::-webkit-details-marker,
.org2-drawer > summary::-webkit-details-marker { display: none; }
.org2-headline-summary::before,
.org2-properties-drawer > summary::before,
.org2-large-source > summary::before,
.org2-drawer > summary::before {
  content: "▶";
  position: absolute;
  left: 0.05rem;
  top: 0.22em;
  color: var(--org2-muted);
  font-size: 0.82rem;
  font-weight: 750;
  line-height: 1.2;
}
details[open] > summary::before { content: "▼"; }
.org2-headline-summary:hover::before,
.org2-properties-drawer > summary:hover::before,
.org2-drawer > summary:hover::before { color: var(--org2-accent); }
.org2-headline-summary > h1,
.org2-headline-summary > h2,
.org2-headline-summary > h3,
.org2-headline-summary > h4,
.org2-headline-summary > h5,
.org2-headline-summary > h6 { display: inline; margin: 0; }
.org2-headline-summary > h1::before,
.org2-headline-summary > h2::before,
.org2-headline-summary > h3::before,
.org2-headline-summary > h4::before,
.org2-headline-summary > h5::before,
.org2-headline-summary > h6::before {
  display: inline-block;
  margin-right: 0.44rem;
  color: var(--org2-accent);
  content: "*";
  font-family: var(--org2-font-mono);
  font-size: 0.64em;
  font-weight: 650;
  vertical-align: 0.08em;
}
.org2-headline-summary > h2::before {
  color: var(--org2-signal);
  content: "**";
  font-size: 0.52em;
  letter-spacing: -0.16em;
}
.org2-headline-summary > h3::before,
.org2-headline-summary > h4::before,
.org2-headline-summary > h5::before,
.org2-headline-summary > h6::before {
  color: var(--org2-muted);
  content: "***";
  font-size: 0.46em;
  letter-spacing: -0.18em;
}
.org2-heading-ai-action {
  display: inline-flex;
  align-items: center;
  margin-left: 0.45rem;
  padding: 0.12rem 0.34rem;
  border: 0;
  border-radius: 4px;
  background: transparent;
  color: var(--org2-muted);
  font: inherit;
  font-size: 0.76rem;
  font-weight: 600;
  line-height: 1.25;
  letter-spacing: 0;
  vertical-align: middle;
  transform: translateY(-2px);
  opacity: 0;
  pointer-events: none;
  cursor: pointer;
  transition: opacity 110ms ease-out, color 110ms ease-out, background-color 110ms ease-out;
}
.org2-headline-summary:hover > .org2-heading-ai-action,
.org2-section-label:hover > .org2-heading-ai-action,
.org2-headline-summary:focus-within > .org2-heading-ai-action,
.org2-heading-ai-action:focus-visible {
  opacity: 1;
  pointer-events: auto;
}
.org2-heading-ai-action:hover,
.org2-heading-ai-action:focus-visible {
  color: var(--org2-accent);
  background: color-mix(in srgb, var(--org2-accent) 9%, transparent);
  outline: none;
}
.org2-headline.level-1 > .org2-headline-summary { margin-top: 0.08rem; }
.org2-headline-body { min-width: 0; }
.org2-headline-body > .org2-headline.level-2 { margin-left: 0.35rem; padding-left: 0.5rem; border-left: 1px solid var(--org2-rule); }
.org2-headline-body > .org2-headline.level-3 { margin-left: 0.25rem; padding-left: 0.45rem; border-left: 1px solid var(--org2-rule); }
.org2-headline-body > .org2-headline.level-4,
.org2-headline-body > .org2-headline.level-5,
.org2-headline-body > .org2-headline.level-6 { margin-left: 0.2rem; padding-left: 0.35rem; border-left: 1px solid var(--org2-rule); }
h1, h2, h3, h4, h5, h6 {
  color: var(--org2-text);
  font-weight: 620;
  line-height: 1.3;
  letter-spacing: 0;
  margin: 1rem 0 0.42rem;
  overflow-wrap: normal;
  word-break: normal;
  text-wrap: wrap;
}
h1 { font-size: 1.16rem; margin-top: 0.1rem; }
h2 { font-size: 1.08rem; color: color-mix(in srgb, var(--org2-text) 78%, var(--org2-accent)); }
h3 { font-size: 1.02rem; color: color-mix(in srgb, var(--org2-text) 72%, var(--org2-muted)); }
h4, h5, h6 { font-size: 0.98rem; color: var(--org2-muted); }
p { max-width: 100%; margin: 0.55rem 0 0.8rem; overflow-wrap: anywhere; }
a { color: var(--org2-link); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--org2-link) 35%, transparent); }
a:hover { border-bottom-color: var(--org2-link); }
strong { font-weight: 650; }
code {
  font-family: var(--org2-font-mono);
  font-size: 0.9em;
  background: var(--org2-code);
  border: 1px solid var(--org2-rule);
  border-radius: 4px;
  padding: 0.08em 0.3em;
}
pre, .org2-src, .org2-example, .org2-verse, .org2-export, .org2-directive {
  box-sizing: border-box;
  max-width: 100%;
  overflow: auto;
  margin: 0.85rem 0 1rem;
  padding: 0.9rem 1rem !important;
  color: var(--org2-text);
  background: var(--org2-code) !important;
  border: 1px solid var(--org2-rule) !important;
  border-radius: 10px !important;
  font-family: var(--org2-font-mono);
  font-size: 0.88rem !important;
  line-height: 1.45 !important;
  white-space: pre;
}
pre code { padding: 0; border: 0; background: transparent; font-size: inherit; }
.org2-large-source { margin: 0.85rem 0 1rem; }
.org2-large-source > summary { position: relative; padding-left: 1.15rem; list-style: none; cursor: pointer; color: var(--org2-muted); font-size: 0.88rem; }
.org2-large-source > pre { margin-top: 0.5rem; }
blockquote { margin: 0.9rem 0; padding: 0.15rem 0 0.15rem 1rem; border-left: 3px solid var(--org2-accent); color: var(--org2-muted); }
.org2-quote { white-space: pre-wrap; overflow-wrap: anywhere; }
ul, ol { margin: 0.55rem 0 0.9rem; padding-left: 1.55rem; }
li { min-width: 0; margin: 0.24rem 0; padding-left: 0.12rem; overflow-wrap: anywhere; }
li > p { display: inline; }
input[type="checkbox"] { width: 0.95rem; height: 0.95rem; margin: 0 0.42rem 0 -0.05rem; accent-color: var(--org2-accent); vertical-align: -0.11rem; }
li:has(> input[type="checkbox"]:checked) > p { color: var(--org2-muted); text-decoration: line-through; }
.org2-checkbox-mixed { display: inline-grid; width: 0.95rem; height: 0.95rem; margin: 0 0.42rem 0 -0.05rem; place-items: center; border: 1px solid var(--org2-muted); border-radius: 3px; color: var(--org2-muted); font-size: 0.8rem; line-height: 1; vertical-align: -0.11rem; }
.org2-priority { color: var(--org2-danger); font-family: var(--org2-font-mono); font-size: 0.72em; font-weight: 750; }
.org2-comment-keyword { color: var(--org2-muted); font-family: var(--org2-font-mono); font-size: 0.72em; font-weight: 700; }
.org2-headline.commented { opacity: 0.7; }
.org2-headline .org2-headline-done { color: color-mix(in srgb, var(--org2-text) 58%, transparent); }
.org2-headline .org2-headline-canceled { color: color-mix(in srgb, var(--org2-text) 42%, transparent); text-decoration: line-through; text-decoration-color: color-mix(in srgb, var(--org2-text) 35%, transparent); }
.org2-progress-cookie, .org2-latex-fragment, .org2-citation, .org2-export-snippet { font-family: var(--org2-font-mono); }
.org2-latex-fragment { color: var(--org2-accent); }
.org2-footnote-definition { margin: 0.7rem 0; padding-top: 0.45rem; border-top: 1px solid var(--org2-rule); color: var(--org2-muted); font-size: 0.86rem; }
.org2-description-list { display: grid; grid-template-columns: max-content 1fr; gap: 0.32rem 0.8rem; }
.org2-description-list dt { font-weight: 700; }
.org2-description-list dd { margin: 0; }
.org2-image-figure {
  width: fit-content;
  max-width: 100%;
  margin: 0.8rem 0 1.1rem;
}
.org2-image-link { display: block; max-width: 100%; border: 0; }
.org2-image-link:hover { border: 0; }
.org2-image {
  display: block;
  width: auto;
  max-width: 100%;
  height: auto;
  max-height: 72vh;
  border: 1px solid color-mix(in srgb, var(--org2-text) 10%, transparent);
  border-radius: 10px;
  background: color-mix(in srgb, var(--org2-elevated-surface) 96%, var(--org2-faint));
  box-shadow: 0 1px 3px color-mix(in srgb, var(--org2-text) 8%, transparent);
  object-fit: contain;
}
li > .org2-image-figure { margin-top: 0.65rem; }
.org2-inline-image-link { width: fit-content; margin: 0.6rem 0 0.8rem; }
.org2-todo {
  display: inline-block;
  margin-right: 0.35rem;
  padding: 0.08rem 0.34rem;
  color: var(--org2-accent);
  background: color-mix(in srgb, var(--org2-accent) 10%, transparent);
  border-radius: 4px;
  font-size: 0.67em;
  font-weight: 750;
  line-height: 1.35;
  vertical-align: 0.12em;
}
.org2-todo.todo-done { color: var(--org2-success); background: color-mix(in srgb, var(--org2-success) 11%, transparent); }
.org2-todo.todo-canceled, .org2-todo.todo-cancelled { color: var(--org2-muted); background: color-mix(in srgb, var(--org2-muted) 10%, transparent); }
.org2-tags { display: inline-flex; flex-wrap: wrap; gap: 0.28rem; margin-left: 0.35rem; vertical-align: 0.1em; }
.org2-tag { color: var(--org2-muted); background: var(--org2-faint); border-radius: 4px; padding: 0.08rem 0.34rem; font-size: 0.65em; font-weight: 550; }
.org2-encrypted {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  width: fit-content;
  min-width: min(22rem, 100%);
  margin: 0.55rem 0 0.85rem;
  padding: 0.5rem 0.7rem;
  border: 1px solid var(--org2-rule);
  border-radius: 10px;
  background: var(--org2-elevated-surface);
  box-shadow: 0 1px 2px var(--org2-shadow);
  color: var(--org2-muted);
  font-size: 0.86rem;
  cursor: pointer;
  user-select: none;
  -webkit-user-select: none;
}
.org2-encrypted:hover, .org2-encrypted:focus-visible { border-color: color-mix(in srgb, var(--org2-accent) 45%, var(--org2-rule)); outline: none; }
.org2-encrypted-icon { font-size: 0.95em; filter: grayscale(1); }
.org2-encrypted-label { flex: 1; color: var(--org2-text); font-weight: 600; }
.org2-encrypted-action { color: var(--org2-accent); font-weight: 600; }
.org2-encrypted[aria-busy="true"] .org2-encrypted-action { opacity: 0.55; }
.org2-planning { color: var(--org2-muted); font-family: var(--org2-font-mono); font-size: 0.82rem; font-variant-numeric: tabular-nums; }
.org2-planning-kind { color: var(--org2-warning); font-size: 0.78em; font-weight: 700; }
.org2-timestamp, .org2-timestamp-range { font-variant-numeric: tabular-nums; }
.org2-properties-drawer {
  margin: 0.75rem 0 1rem;
  padding: 0.58rem 0.72rem;
  border: 1px solid var(--org2-rule);
  border-radius: 10px;
  background: var(--org2-elevated-surface);
  box-shadow: 0 1px 2px var(--org2-shadow);
  font-size: 0.82rem;
}
.org2-properties-drawer > summary {
  position: relative;
  padding-left: 1.15rem;
  color: var(--org2-muted);
  cursor: pointer;
  font-weight: 650;
  list-style: none;
  user-select: none;
}
.org2-properties-drawer[open] > summary { margin-bottom: 0.52rem; }
.org2-properties {
  display: grid;
  grid-template-columns: minmax(6rem, max-content) 1fr;
  gap: 0.3rem 0.9rem;
  margin: 0;
  padding: 0.5rem 0 0;
  border-top: 1px solid var(--org2-rule);
}
.org2-properties dt { color: var(--org2-muted); font-family: var(--org2-font-mono); font-weight: 650; }
.org2-properties dd { margin: 0; min-width: 0; overflow-wrap: anywhere; font-family: var(--org2-font-mono); }
.org2-drawer { margin: 0.75rem 0; color: var(--org2-muted); font-size: 0.9rem; }
.org2-drawer summary { position: relative; padding-left: 1.15rem; cursor: pointer; font-weight: 600; list-style: none; }
.org2-keyword { color: var(--org2-muted); font-size: 0.88rem; }
.org2-keyword-name { font-weight: 650; }
table { width: 100%; margin: 0.8rem 0 1.15rem; border-collapse: collapse; font-size: 0.9rem; font-variant-numeric: tabular-nums; }
th, td { padding: 0.46rem 0.58rem; border-bottom: 1px solid var(--org2-rule); text-align: left; vertical-align: top; }
th { color: var(--org2-muted); background: var(--org2-faint); font-family: var(--org2-font-mono); font-size: 0.78rem; font-weight: 650; }
.org2-table-scroll { display: block; width: 100%; max-width: 100%; min-width: 0; margin: 0.8rem 0 1.15rem; overflow-x: auto; overscroll-behavior-inline: contain; -webkit-overflow-scrolling: touch; }
.org2-table-scroll table { width: auto; min-width: 100%; margin: 0; }
.org2-table-scroll th, .org2-table-scroll td { overflow-wrap: normal; word-break: normal; hyphens: none; }
.org2-table-controls {
  position: sticky;
  left: 0;
  display: flex;
  align-items: center;
  gap: 0.48rem;
  width: max-content;
  min-width: min(100%, 420px);
  margin: 0 0 0.42rem;
  color: var(--org2-muted);
  font-size: 0.76rem;
}
.org2-table-filter {
  box-sizing: border-box;
  width: clamp(150px, 34vw, 260px);
  min-height: 28px;
  padding: 0.25rem 0.55rem;
  border: 1px solid color-mix(in srgb, var(--org2-text) 16%, transparent);
  border-radius: 8px;
  color: var(--org2-text);
  background: color-mix(in srgb, var(--org2-surface) 96%, var(--org2-faint));
  font: inherit;
  outline: none;
}
.org2-table-filter:focus { border-color: var(--org2-accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--org2-accent) 16%, transparent); }
.org2-table-row-count { min-width: 64px; font-variant-numeric: tabular-nums; white-space: nowrap; }
.org2-table-control-button,
.org2-table-sort-button {
  border: 0;
  border-radius: 7px;
  color: var(--org2-muted);
  background: transparent;
  font: inherit;
  cursor: pointer;
}
.org2-table-control-button { min-height: 26px; padding: 0.22rem 0.45rem; white-space: nowrap; }
.org2-table-control-button:hover,
.org2-table-sort-button:hover { color: var(--org2-text); background: var(--org2-faint); }
.org2-table-control-button:disabled { cursor: default; opacity: 0.44; }
.org2-table-save-button { color: var(--org2-accent); font-weight: 650; }
.org2-table-formula-button { color: var(--org2-accent); font-weight: 650; }
.org2-table-formula-status { display: block; margin: -0.75rem 0 1rem; color: var(--org2-muted); font-size: 0.78rem; }
.org2-table-formula-error { color: var(--org2-danger, #b42318); }
.org2-table-sort-button { margin-left: 0.28rem; padding: 0.06rem 0.22rem; font-size: 0.72rem; }
.org2-table-sort-button[aria-pressed="true"] { color: var(--org2-accent); background: color-mix(in srgb, var(--org2-accent) 10%, transparent); }
.org2-resizable-table th, .org2-resizable-table td { min-width: 72px; }
.org2-table-resize-anchor { position: relative; }
.org2-chart {
  box-sizing: border-box;
  position: relative;
  width: min(100%, 800px);
  max-width: 100%;
  min-width: min(360px, 100%);
  margin: 1rem 0 1.4rem;
  padding: 0.9rem 1rem 0.6rem;
  border: 1px solid color-mix(in srgb, var(--org2-text) 7%, transparent);
  border-radius: 14px;
  background: var(--org2-chart-surface);
  overflow: hidden;
  resize: horizontal;
}
.org2-chart-compact { width: min(100%, 680px); }
.org2-chart-wide { width: 100%; }
.org2-chart svg { display: block; width: 100%; height: auto; margin: 0; overflow: visible; }
.org2-chart-mark { cursor: crosshair; outline: none; transition: opacity 120ms ease-out, fill-opacity 120ms ease-out, stroke-opacity 120ms ease-out; }
.org2-chart-bar { transition: opacity 120ms ease-out; }
.org2-chart:hover .org2-chart-bar { opacity: 0.55; }
.org2-chart:hover .org2-chart-bar.org2-chart-mark-active, .org2-chart-bar:focus-visible { opacity: 1; }
.org2-chart-point.org2-chart-mark-active, .org2-chart-point:focus-visible { fill-opacity: 1; stroke-opacity: 1; }
.org2-chart-bar:focus-visible { stroke: var(--org2-text); stroke-width: 2; }
.org2-chart-crosshair { opacity: 0.5; }
.org2-chart-tooltip {
  position: absolute;
  z-index: 3;
  min-width: 112px;
  max-width: min(240px, calc(100% - 20px));
  padding: 0.45rem 0.6rem;
  border: 1px solid color-mix(in srgb, var(--org2-text) 10%, transparent);
  border-radius: 10px;
  color: var(--org2-text);
  background: color-mix(in srgb, var(--org2-chart-surface) 92%, transparent);
  -webkit-backdrop-filter: blur(12px);
  backdrop-filter: blur(12px);
  box-shadow: 0 10px 30px color-mix(in srgb, var(--org2-text) 14%, transparent), 0 1px 2px color-mix(in srgb, var(--org2-text) 8%, transparent);
  font-size: 0.78rem;
  line-height: 1.35;
  pointer-events: none;
}
.org2-chart-tooltip[hidden] { display: none; }
.org2-chart-tooltip-label { display: block; color: var(--org2-muted); font-size: 0.72rem; }
.org2-chart-tooltip-value { display: flex; align-items: center; gap: 0.35rem; margin-top: 0.12rem; font-weight: 600; font-variant-numeric: tabular-nums; }
.org2-chart-tooltip-swatch { flex: none; width: 8px; height: 8px; border-radius: 2px; }
${CHART_INTERACTION_STYLE}
.org2-html-preview { width: 100%; min-width: 0; margin: 0.85rem 0 1.25rem; }
.org2-html-source { margin-top: 0.5rem; }
.org2-plugin-render { width: 100%; margin: 0.85rem 0 1.25rem; overflow: hidden; }
.org2-plugin-render iframe { color-scheme: light dark; }
.org2-plugin-render-error {
  display: grid;
  gap: 0.25rem;
  margin: 0.75rem 0 1rem;
  padding: 0.75rem 0.9rem;
  border: 1px solid color-mix(in srgb, var(--org2-danger, #b42318) 40%, transparent);
  border-radius: 10px;
  color: var(--org2-danger, #b42318);
  background: color-mix(in srgb, var(--org2-danger, #b42318) 7%, transparent);
  font-size: 0.86rem;
}
.org2-column-resizer {
  position: absolute;
  top: 0;
  right: -5px;
  bottom: 0;
  width: 10px;
  z-index: 2;
  cursor: col-resize;
  touch-action: none;
}
.org2-column-resizer::after {
  content: "";
  position: absolute;
  top: 18%;
  right: 4px;
  bottom: 18%;
  width: 2px;
  border-radius: 1px;
  background: transparent;
}
.org2-column-resizer:hover::after,
body.org2-resizing-column .org2-column-resizer::after { background: var(--org2-accent); }
body.org2-resizing-column { cursor: col-resize; user-select: none; }
::selection { background: color-mix(in srgb, var(--org2-accent) 30%, transparent); }
@media (max-width: 560px) {
  main.org2-document { padding-top: 18px; padding-bottom: 48px; }
  .org2-properties { grid-template-columns: 1fr; gap: 0.08rem; }
  .org2-properties dd { margin-bottom: 0.35rem; }
}`;

const APP_DOCUMENT_SCRIPT = `(() => {
  const minimumColumnWidth = 72;

  function appendAIAction(container, line) {
    if (!container || !line || container.querySelector(":scope > .org2-heading-ai-action")) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "org2-heading-ai-action";
    button.textContent = "✦ Ask AI";
    button.title = "Ask AI about this section";
    button.setAttribute("aria-label", "Ask AI about this section");
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      window.location.href = "org2-workspace://ask-ai?line=" + encodeURIComponent(line);
    });
    container.appendChild(button);
  }

  function installHeadingActions() {
    document.querySelectorAll("details.org2-headline[data-org2-start-line]").forEach((headline) => {
      const summary = headline.querySelector(":scope > .org2-headline-summary");
      const line = headline.dataset.org2StartLine;
      appendAIAction(summary, line);
    });

    document.querySelectorAll("p[data-org2-start-line]").forEach((paragraph) => {
      const meaningfulChildren = Array.from(paragraph.childNodes).filter((node) =>
        node.nodeType !== Node.TEXT_NODE || Boolean(node.textContent && node.textContent.trim())
      );
      if (meaningfulChildren.length !== 1) return;
      const label = meaningfulChildren[0];
      if (!(label instanceof HTMLElement) || label.tagName !== "STRONG") return;
      paragraph.classList.add("org2-section-label");
      appendAIAction(paragraph, paragraph.dataset.org2StartLine);
    });
  }

  function installTableResizers() {
    document.querySelectorAll(".org2-table-scroll table").forEach((table) => {
      if (table.dataset.org2Resizable === "true") return;
      const row = table.tHead && table.tHead.rows.length > 0 ? table.tHead.rows[0] : table.rows[0];
      if (!row || row.cells.length === 0) return;

      const measuredTableWidth = Math.ceil(table.getBoundingClientRect().width);
      const measuredWidths = Array.from(row.cells, (cell) =>
        Math.max(minimumColumnWidth, Math.ceil(cell.getBoundingClientRect().width))
      );
      const colgroup = document.createElement("colgroup");
      const columns = measuredWidths.map((width) => {
        const column = document.createElement("col");
        column.style.width = width + "px";
        colgroup.appendChild(column);
        return column;
      });
      table.insertBefore(colgroup, table.firstChild);
      table.dataset.org2Resizable = "true";
      table.classList.add("org2-resizable-table");
      table.style.tableLayout = "fixed";
      table.style.width = Math.max(
        measuredTableWidth,
        measuredWidths.reduce((total, width) => total + width, 0)
      ) + "px";

      Array.from(row.cells).forEach((cell, index) => {
        cell.classList.add("org2-table-resize-anchor");
        const handle = document.createElement("span");
        handle.className = "org2-column-resizer";
        handle.setAttribute("role", "separator");
        handle.setAttribute("aria-orientation", "vertical");
        handle.setAttribute("aria-label", "Resize table column " + (index + 1));
        handle.title = "Drag to resize column";

        handle.addEventListener("mousedown", (event) => {
          if (event.button !== 0) return;
          event.preventDefault();
          event.stopPropagation();

          const startX = event.clientX;
          const startWidth = parseFloat(columns[index].style.width) || measuredWidths[index];
          const startTableWidth = table.getBoundingClientRect().width;
          document.body.classList.add("org2-resizing-column");

          const move = (moveEvent) => {
            const nextWidth = Math.max(minimumColumnWidth, startWidth + moveEvent.clientX - startX);
            columns[index].style.width = nextWidth + "px";
            table.style.width = Math.max(
              table.parentElement ? table.parentElement.clientWidth : 0,
              startTableWidth + nextWidth - startWidth
            ) + "px";
          };
          const finish = () => {
            document.body.classList.remove("org2-resizing-column");
            window.removeEventListener("mousemove", move);
            window.removeEventListener("mouseup", finish);
          };

          window.addEventListener("mousemove", move);
          window.addEventListener("mouseup", finish);
        });

        cell.appendChild(handle);
      });
    });
  }

  function installInteractiveTables() {
    const initialVisibleRowLimit = 100;
    const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
    document.querySelectorAll(".org2-table-scroll table").forEach((table) => {
      if (table.dataset.org2Interactive === "true") return;
      const body = table.tBodies && table.tBodies[0];
      const originalRows = body ? Array.from(body.rows) : [];
      if (!body || originalRows.length === 0) return;

      table.dataset.org2Interactive = "true";
      const rowRecords = originalRows.map((row, index) => ({
        originalIndex: index,
        searchText: row.innerText.toLocaleLowerCase(),
        cellTexts: Array.from(row.cells, (cell) => cell.innerText.trim()),
        html: row.innerHTML,
        attributes: Array.from(row.attributes, (attribute) => [attribute.name, attribute.value])
      }));
      body.replaceChildren();

      const wrapper = table.closest(".org2-table-scroll");
      if (!wrapper) return;
      const controls = document.createElement("div");
      controls.className = "org2-table-controls";
      controls.setAttribute("role", "group");
      controls.setAttribute("aria-label", "Table view controls");

      const filter = document.createElement("input");
      filter.type = "search";
      filter.className = "org2-table-filter";
      filter.placeholder = "Filter rows";
      filter.setAttribute("aria-label", "Filter table rows");

      const count = document.createElement("span");
      count.className = "org2-table-row-count";
      count.setAttribute("aria-live", "polite");

      const reset = document.createElement("button");
      reset.type = "button";
      reset.className = "org2-table-control-button";
      reset.textContent = "Reset";
      reset.title = "Clear filtering and restore source order";

      const showMore = document.createElement("button");
      showMore.type = "button";
      showMore.className = "org2-table-control-button";
      showMore.dataset.org2TableShowMore = "true";

      const save = document.createElement("button");
      save.type = "button";
      save.className = "org2-table-control-button org2-table-save-button";
      save.textContent = "Save view to source";
      save.title = "Replace source table rows with this filtered and sorted view";
      save.hidden = !window.__org2TablePersistenceEnabled;
      save.dataset.org2TableSave = "true";

      const recalculate = document.createElement("button");
      recalculate.type = "button";
      recalculate.className = "org2-table-control-button org2-table-formula-button";
      recalculate.textContent = "Recalculate";
      recalculate.title = "Recalculate this table from its #+TBLFM formulas and save the results";
      recalculate.hidden = !window.__org2TablePersistenceEnabled || Number(table.dataset.org2FormulaCount || 0) === 0;
      recalculate.dataset.org2TableFormula = "true";

      controls.append(filter, count, showMore, reset, recalculate, save);
      wrapper.insertBefore(controls, table);

      let sortColumn = null;
      let sortDirection = null;
      let visibleRowLimit = initialVisibleRowLimit;
      let currentRows = [...rowRecords];
      const headerRow = table.tHead && table.tHead.rows.length > 0
        ? table.tHead.rows[table.tHead.rows.length - 1]
        : null;
      const sortButtons = [];

      function renderedRow(record) {
        const row = document.createElement("tr");
        record.attributes.forEach(([name, value]) => row.setAttribute(name, value));
        row.dataset.org2OriginalRowIndex = String(record.originalIndex);
        row.innerHTML = record.html;
        return row;
      }

      function cellText(record, column) {
        return record.cellTexts[column] || "";
      }

      function refresh(resetVisibleLimit = false) {
        if (resetVisibleLimit) visibleRowLimit = initialVisibleRowLimit;
        const query = filter.value.trim().toLocaleLowerCase();
        let rows = [...rowRecords];
        if (sortColumn !== null && sortDirection) {
          rows.sort((lhs, rhs) => {
            const comparison = collator.compare(cellText(lhs, sortColumn), cellText(rhs, sortColumn));
            if (comparison !== 0) return sortDirection === "ascending" ? comparison : -comparison;
            return lhs.originalIndex - rhs.originalIndex;
          });
        } else {
          rows.sort((lhs, rhs) => lhs.originalIndex - rhs.originalIndex);
        }
        currentRows = rows.filter((row) => !query || row.searchText.includes(query));
        const renderedCount = Math.min(currentRows.length, visibleRowLimit);
        body.replaceChildren(...currentRows.slice(0, renderedCount).map(renderedRow));

        count.textContent = currentRows.length === rowRecords.length
          ? renderedCount + " of " + rowRecords.length + " rows shown"
          : renderedCount + " of " + currentRows.length + " matching · " + rowRecords.length + " total";
        const remainingCount = Math.max(0, currentRows.length - renderedCount);
        showMore.hidden = remainingCount === 0;
        showMore.textContent = remainingCount > 0
          ? "Show " + Math.min(initialVisibleRowLimit, remainingCount) + " more"
          : "";
        reset.disabled = !query && sortColumn === null;
        save.disabled = currentRows.length === 0;
      }

      if (headerRow) {
        Array.from(headerRow.cells).forEach((cell, column) => {
          const button = document.createElement("button");
          button.type = "button";
          button.className = "org2-table-sort-button";
          button.textContent = "↕";
          button.title = "Sort by " + (cell.innerText.trim() || "column " + (column + 1));
          button.setAttribute("aria-label", button.title);
          button.setAttribute("aria-pressed", "false");
          button.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            sortDirection = sortColumn === column && sortDirection === "ascending"
              ? "descending"
              : "ascending";
            sortColumn = column;
            sortButtons.forEach((candidate, candidateColumn) => {
              const active = candidateColumn === sortColumn;
              candidate.textContent = active ? (sortDirection === "ascending" ? "↑" : "↓") : "↕";
              candidate.setAttribute("aria-pressed", active ? "true" : "false");
              candidate.parentElement?.setAttribute("aria-sort", active ? sortDirection : "none");
            });
            refresh(true);
          });
          sortButtons.push(button);
          cell.appendChild(button);
        });
      }

      filter.addEventListener("input", () => refresh(true));
      showMore.addEventListener("click", () => {
        visibleRowLimit += initialVisibleRowLimit;
        refresh();
      });
      reset.addEventListener("click", () => {
        filter.value = "";
        sortColumn = null;
        sortDirection = null;
        sortButtons.forEach((button) => {
          button.textContent = "↕";
          button.setAttribute("aria-pressed", "false");
          button.parentElement?.setAttribute("aria-sort", "none");
        });
        refresh(true);
        filter.focus();
      });
      save.addEventListener("click", () => {
        if (currentRows.length === 0) return;
        const handler = window.webkit?.messageHandlers?.org2TableView;
        if (!handler) return;
        handler.postMessage({
          startLine: Number(table.dataset.org2StartLine || 0),
          endLine: Number(table.dataset.org2EndLine || 0),
          visibleBodyRowIndices: currentRows.map((row) => row.originalIndex),
          totalBodyRowCount: rowRecords.length,
          filterActive: Boolean(filter.value.trim()),
          sortActive: sortColumn !== null
        });
      });
      recalculate.addEventListener("click", () => {
        const handler = window.webkit?.messageHandlers?.org2TableFormula;
        if (!handler) return;
        handler.postMessage({ startLine: Number(table.dataset.org2StartLine || 0) });
      });

      refresh();
    });

    window.__org2SetTablePersistenceEnabled = (enabled) => {
      window.__org2TablePersistenceEnabled = Boolean(enabled);
      document.querySelectorAll("[data-org2-table-save='true']").forEach((button) => {
        button.hidden = !window.__org2TablePersistenceEnabled;
      });
      document.querySelectorAll("[data-org2-table-formula='true']").forEach((button) => {
        const table = button.closest(".org2-table-scroll")?.querySelector("table");
        button.hidden = !window.__org2TablePersistenceEnabled || Number(table?.dataset.org2FormulaCount || 0) === 0;
      });
    };
  }

  // Live HTML previews report their content height; only the frame that sent
  // the message, and only one that asked for automatic sizing, is resized.
  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || data.type !== "org2-frame-size" || !Number.isFinite(data.height)) return;
    for (const frame of document.querySelectorAll("iframe[data-org2-autosize='true']")) {
      if (frame.contentWindow !== event.source) continue;
      const chrome = frame.offsetHeight - frame.clientHeight;
      frame.style.height = Math.min(1600, Math.max(24, Math.ceil(data.height))) + chrome + "px";
      break;
    }
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      installHeadingActions();
      installTableResizers();
      installInteractiveTables();
    }, { once: true });
  } else {
    installHeadingActions();
    installTableResizers();
    installInteractiveTables();
  }
})();`;

const DEFAULT_INDEX_STYLE = `:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem auto; max-width: 860px; padding: 0 1rem; line-height: 1.5; }
main { display: grid; gap: 1rem; }
h1 { margin: 0; }
ul.org2-export-index { padding-left: 1.25rem; margin: 0; display: grid; gap: 0.35rem; }
.org2-export-source { opacity: 0.75; font-size: 0.9em; }
a { text-decoration-thickness: 0.08em; text-underline-offset: 0.15em; }`;

function renderHeadStyleSection(opts: {
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  defaultStyle: string;
}): string {
  const includeDefaultStyle = opts.includeDefaultStyle !== false;
  const stylesheets = normalizeStylesheets(opts.stylesheets);
  const stylesheetLinks = stylesheets
    .map((href) => `<link rel="stylesheet" href="${escapeAttr(href)}" />`)
    .join("\n");

  const defaultStyleBlock = includeDefaultStyle ? `<style>\n${opts.defaultStyle}\n</style>` : "";

  if (stylesheetLinks && defaultStyleBlock) {
    return `${stylesheetLinks}\n${defaultStyleBlock}\n`;
  }

  if (stylesheetLinks) {
    return `${stylesheetLinks}\n`;
  }

  if (defaultStyleBlock) {
    return `${defaultStyleBlock}\n`;
  }

  return "";
}

type TocItem = {
  id: string;
  title: string;
  level: number;
  number?: string;
};

type RenderContext = {
  headlineIds?: WeakMap<HeadlineNode, string>;
  headlineSlugIds?: Map<string, string>;
  headlineNumbers?: WeakMap<HeadlineNode, string>;
  rewriteFileLinks?: boolean;
  linkAbbreviations?: LinkAbbreviationMap;
  nativeInternalLinks?: boolean;
  profile?: "publish" | "app";
  chartsByTableLine?: Map<number, OrgEmbeddedChart>;
  chartsByBlockLine?: Map<number, OrgEmbeddedChart>;
  pluginRendersByBlockLine?: Map<number, Org2PluginRender>;
  embedResolver?: LiveEmbedResolver;
  sourcePath?: string;
  embedStack?: string[];
  embedBudget?: { remaining: number; bytes: number };
  embedded?: boolean;
  embeddedAnchorLines?: Map<string, number>;
  /** The document is a single code file shown as one highlighted source block. */
  codeFile?: boolean;
};

export type OrgEmbeddedChart = {
  svg: string;
  presentation?: {
    size: "compact" | "medium" | "wide";
    height: number;
    interactive: boolean;
  };
  source: {
    line: number;
    chartLine?: number;
  };
};

export type OrgExportMetadata = {
  author?: string;
  date?: string;
  subtitle?: string;
  description?: string;
  keywords?: string[];
  language?: string;
  htmlHead?: string[];
};

type OrgExportOptions = {
  toc?: boolean;
  tocDepth?: number;
  num?: boolean;
  numDepth?: number;
};

const HIDDEN_DOCUMENT_KEYWORDS = new Set([
  "TITLE",
  "AUTHOR",
  "DATE",
  "SUBTITLE",
  "DESCRIPTION",
  "KEYWORDS",
  "LANGUAGE",
  "HTML_HEAD",
  "HTML_HEAD_EXTRA",
  "OPTIONS",
  "LINK",
]);

function parseKeywordList(value: string): string[] {
  const values = String(value || "")
    .split(/[;,]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  return Array.from(new Set(values));
}

function normalizeDocumentLanguage(value: string): string | null {
  const normalized = String(value || "").trim();
  if (!normalized) return null;
  if (!/^[A-Za-z0-9-]+$/.test(normalized)) return null;
  return normalized;
}

function parseKeywordOptionsMap(value: string): Map<string, string> {
  const assignments = new Map<string, string>();
  const tokens = String(value || "")
    .trim()
    .split(/\s+/)
    .filter((token) => token.length > 0);

  for (const token of tokens) {
    const separatorIndex = token.indexOf(":");
    if (separatorIndex <= 0) continue;
    const key = token.slice(0, separatorIndex).trim().toLowerCase();
    const optionValue = token.slice(separatorIndex + 1).trim();
    if (!key || !optionValue) continue;
    assignments.set(key, optionValue);
  }

  return assignments;
}

function parseKeywordBooleanOption(value: string | undefined): boolean | null {
  const normalized = String(value || "").trim().toLowerCase();
  if (!normalized) return null;

  if (["t", "true", "yes", "on"].includes(normalized)) return true;
  if (["nil", "false", "no", "off"].includes(normalized)) return false;

  if (/^\d+$/.test(normalized)) {
    return Number(normalized) > 0;
  }

  return null;
}

function parseKeywordPositiveIntegerOption(value: string | undefined): number | null {
  const normalized = String(value || "").trim();
  if (!/^\d+$/.test(normalized)) return null;

  const parsed = Number.parseInt(normalized, 10);
  if (!Number.isFinite(parsed) || parsed < 1) return null;
  return parsed;
}

function collectKeywordOptions(doc: DocumentNode): OrgExportOptions {
  const options: OrgExportOptions = {};

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (key !== "OPTIONS") continue;

    const assignments = parseKeywordOptionsMap(node.valueRaw);
    if (assignments.has("toc")) {
      const tocRaw = assignments.get("toc");
      const parsed = parseKeywordBooleanOption(tocRaw);
      if (parsed !== null) {
        options.toc = parsed;
      }

      const parsedDepth = parseKeywordPositiveIntegerOption(tocRaw);
      if (parsedDepth !== null) {
        options.toc = true;
        options.tocDepth = parsedDepth;
      }
    }

    if (assignments.has("num")) {
      const numRaw = assignments.get("num");
      const parsed = parseKeywordBooleanOption(numRaw);
      if (parsed !== null) {
        options.num = parsed;
      }

      const parsedDepth = parseKeywordPositiveIntegerOption(numRaw);
      if (parsedDepth !== null) {
        options.num = true;
        options.numDepth = parsedDepth;
      }
    }
  }

  return options;
}

function collectKeywordMetadata(doc: DocumentNode): OrgExportMetadata {
  const metadata: OrgExportMetadata = {};

  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    const key = String(node.keyRaw || "").trim().toUpperCase();
    const value = String(node.valueRaw || "").trim();
    if (!value) continue;

    if (key === "AUTHOR" && !metadata.author) {
      metadata.author = value;
      continue;
    }

    if (key === "DATE" && !metadata.date) {
      metadata.date = value;
      continue;
    }

    if (key === "SUBTITLE" && !metadata.subtitle) {
      metadata.subtitle = value;
      continue;
    }

    if (key === "DESCRIPTION" && !metadata.description) {
      metadata.description = value;
      continue;
    }

    if (key === "KEYWORDS" && !metadata.keywords) {
      const parsedKeywords = parseKeywordList(value);
      if (parsedKeywords.length > 0) {
        metadata.keywords = parsedKeywords;
      }
      continue;
    }

    if (key === "LANGUAGE" && !metadata.language) {
      const normalizedLanguage = normalizeDocumentLanguage(value);
      if (normalizedLanguage) {
        metadata.language = normalizedLanguage;
      }
      continue;
    }

    if (key === "HTML_HEAD" || key === "HTML_HEAD_EXTRA") {
      if (!metadata.htmlHead) metadata.htmlHead = [];
      metadata.htmlHead.push(value);
    }
  }

  return metadata;
}

function hasKeywordMetadata(metadata: OrgExportMetadata): boolean {
  return Boolean(
    metadata.author ||
      metadata.date ||
      metadata.subtitle ||
      metadata.description ||
      (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) ||
      metadata.language ||
      (Array.isArray(metadata.htmlHead) && metadata.htmlHead.length > 0),
  );
}

function renderHeadMetaSection(metadata: OrgExportMetadata): string {
  if (!hasKeywordMetadata(metadata)) return "";

  const rows: string[] = [];
  if (metadata.author) {
    rows.push(`<meta name="author" content="${escapeAttr(metadata.author)}" />`);
  }
  if (metadata.date) {
    rows.push(`<meta name="date" content="${escapeAttr(metadata.date)}" />`);
  }
  if (metadata.subtitle) {
    rows.push(`<meta name="subtitle" content="${escapeAttr(metadata.subtitle)}" />`);
  }
  if (metadata.description) {
    rows.push(`<meta name="description" content="${escapeAttr(metadata.description)}" />`);
  }
  if (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) {
    rows.push(`<meta name="keywords" content="${escapeAttr(metadata.keywords.join(", "))}" />`);
  }

  return rows.length > 0 ? `${rows.join("\n")}\n` : "";
}

function renderHeadExtraSection(
  metadata: OrgExportMetadata,
  extraHead?: string[],
  includeDocumentHtml = true,
): string {
  const snippets = [
    ...(includeDocumentHtml && Array.isArray(metadata.htmlHead) ? metadata.htmlHead : []),
    ...(Array.isArray(extraHead) ? extraHead : []),
  ]
    .map((snippet) => String(snippet || "").trim())
    .filter((snippet) => snippet.length > 0);
  return snippets.length > 0 ? `${snippets.join("\n")}\n` : "";
}

function slugifyHeadlineTitle(value: string): string {
  const normalized = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || "section";
}

function normalizeAnchorId(value: string): string | null {
  const normalized = String(value || "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/[^A-Za-z0-9_.:-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return normalized || null;
}

function findHeadlineCustomId(node: HeadlineNode): string | null {
  for (const child of node.children) {
    if (child.type !== "PropertyDrawer") continue;
    for (const property of child.properties) {
      if (String(property.key || "").trim().toUpperCase() !== "CUSTOM_ID") continue;
      const normalized = normalizeAnchorId(property.value);
      if (normalized) return normalized;
    }
  }

  return null;
}

function normalizeTocDepth(value: number | undefined): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  const normalized = Math.trunc(value);
  if (normalized < 1) return null;
  return Math.min(6, normalized);
}

function normalizeHeadlineNumberDepth(value: number | undefined): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isFinite(value)) return null;
  const normalized = Math.trunc(value);
  if (normalized < 1) return null;
  return Math.min(6, normalized);
}

function buildHeadlineAnchors(
  doc: DocumentNode,
  opts: {
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
  } = {},
): {
  items: TocItem[];
  headlineIds: WeakMap<HeadlineNode, string>;
  headlineSlugIds: Map<string, string>;
  headlineNumbers: WeakMap<HeadlineNode, string>;
} {
  const includeToc = opts.includeToc === true;
  const includeTocDepth = normalizeTocDepth(opts.includeTocDepth);
  const includeHeadlineNumbers = opts.includeHeadlineNumbers === true;
  const includeHeadlineNumberDepth = normalizeHeadlineNumberDepth(opts.includeHeadlineNumberDepth);
  const items: TocItem[] = [];
  const headlineIds = new WeakMap<HeadlineNode, string>();
  const headlineSlugIds = new Map<string, string>();
  const headlineNumbers = new WeakMap<HeadlineNode, string>();
  const headlineNumberCounts = [0, 0, 0, 0, 0, 0];
  const idCounts = new Map<string, number>();

  const nextId = (baseId: string): string => {
    const normalizedBase = normalizeAnchorId(baseId) || "section";
    const key = normalizedBase.toLowerCase();
    const count = (idCounts.get(key) || 0) + 1;
    idCounts.set(key, count);
    if (count === 1) return normalizedBase;
    return `${normalizedBase}-${count}`;
  };

  const visitNodes = (nodes: Node[]): void => {
    for (const node of nodes) {
      if (node.type !== "Headline") continue;
      const title = node.title.map((child) => inlineToText(child)).join("").trim() || "Untitled";
      const titleSlug = slugifyHeadlineTitle(title);
      const customId = findHeadlineCustomId(node);
      const id = nextId(customId || titleSlug);
      const level = Math.max(1, Math.min(6, node.level));
      headlineIds.set(node, id);
      const titleKey = titleSlug.toLowerCase();
      if (!headlineSlugIds.has(titleKey)) {
        headlineSlugIds.set(titleKey, id);
      }

      headlineNumberCounts[level - 1] += 1;
      for (let idx = level; idx < headlineNumberCounts.length; idx += 1) {
        headlineNumberCounts[idx] = 0;
      }

      let headlineNumber: string | null = null;
      if (includeHeadlineNumbers && (includeHeadlineNumberDepth === null || level <= includeHeadlineNumberDepth)) {
        const parts = headlineNumberCounts.slice(0, level).filter((value) => value > 0);
        if (parts.length > 0) {
          headlineNumber = parts.join(".");
          headlineNumbers.set(node, headlineNumber);
        }
      }

      if (includeToc && (includeTocDepth === null || level <= includeTocDepth)) {
        items.push({
          id,
          title,
          level,
          ...(headlineNumber ? { number: headlineNumber } : {}),
        });
      }

      visitNodes(node.children);
    }
  };

  visitNodes(doc.children);
  return { items, headlineIds, headlineSlugIds, headlineNumbers };
}

function renderToc(items: TocItem[]): string {
  if (!Array.isArray(items) || items.length === 0) return "";
  const rows = items
    .map((item) => {
      const level = Math.max(1, Math.min(6, item.level));
      const numberPrefix = item.number ? `${escapeHtml(item.number)} ` : "";
      return `<li class="org2-toc-level-${level}"><a href="#${escapeAttr(item.id)}">${numberPrefix}${escapeHtml(item.title)}</a></li>`;
    })
    .join("\n");
  return `<nav class="org2-toc" aria-label="Table of contents">\n<h2>Contents</h2>\n<ul>\n${rows}\n</ul>\n</nav>`;
}

function rewriteOrgFileHrefForHtml(rawHref: string): string {
  const href = String(rawHref || "").trim();
  if (!href) return href;

  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(href);
  const isFileScheme = /^file:/i.test(href);
  if (hasScheme && !isFileScheme) return href;

  const source = isFileScheme ? href.slice(5) : href;
  const searchSeparatorIndex = source.indexOf("::");
  const pathPart = searchSeparatorIndex >= 0 ? source.slice(0, searchSeparatorIndex) : source;
  const searchSuffix = searchSeparatorIndex >= 0 ? source.slice(searchSeparatorIndex + 2) : "";

  if (!/\.(org|org2)(?=($|[?#]))/i.test(pathPart)) return href;
  const rewrittenPath = pathPart.replace(/\.(org|org2)(?=($|[?#]))/i, ".html");

  if (!searchSuffix.trim()) return rewrittenPath;

  const trimmedSearchSuffix = searchSuffix.trim();
  if (trimmedSearchSuffix.startsWith("#")) {
    return `${rewrittenPath}${trimmedSearchSuffix}`;
  }

  if (trimmedSearchSuffix.startsWith("*")) {
    const headingText = trimmedSearchSuffix.replace(/^\*+\s*/, "").trim();
    return `${rewrittenPath}#${slugifyHeadlineTitle(headingText || "section")}`;
  }

  return href;
}

function rewriteOrgInternalHrefForHtml(rawHref: string, context: RenderContext): string {
  const href = String(rawHref || "").trim();
  if (!href) return href;

  if (href.startsWith("#")) {
    const normalizedAnchor = normalizeAnchorId(href.slice(1));
    return normalizedAnchor ? `#${normalizedAnchor}` : href;
  }

  if (!href.startsWith("*")) return href;

  const headingText = href.replace(/^\*+\s*/, "").trim();
  const headingSlug = slugifyHeadlineTitle(headingText || "section");
  const resolvedHeadingId = context.headlineSlugIds?.get(headingSlug.toLowerCase()) || headingSlug;
  return `#${resolvedHeadingId}`;
}

function linkTargetNeedsHeadingAnchor(rawTarget: string): boolean {
  const target = String(rawTarget || "").trim();
  if (!target) return false;
  return target.startsWith("#") || target.startsWith("*");
}

function resolveDefaultInternalLinkText(rawTarget: string): string | null {
  const target = String(rawTarget || "").trim();
  if (!target) return null;

  if (target.startsWith("*")) {
    const headingText = target.replace(/^\*+\s*/, "").trim();
    return headingText || null;
  }

  if (target.startsWith("#")) {
    const anchorRaw = target.slice(1).trim();
    if (!anchorRaw) return null;
    return normalizeAnchorId(anchorRaw) || anchorRaw;
  }

  return null;
}

function inlineNodesNeedHeadingAnchors(nodes: InlineNode[]): boolean {
  for (const node of nodes) {
    if (node.type !== "Link") continue;
    if (linkTargetNeedsHeadingAnchor(node.targetRaw)) return true;
  }

  return false;
}

function nodesNeedHeadingAnchors(nodes: Node[]): boolean {
  for (const node of nodes) {
    if (node.type === "Headline") {
      if (inlineNodesNeedHeadingAnchors(node.title)) return true;
      if (nodesNeedHeadingAnchors(node.children)) return true;
      continue;
    }

    if (node.type === "Paragraph") {
      if (inlineNodesNeedHeadingAnchors(node.children)) return true;
      continue;
    }

    if (node.type === "List") {
      for (const item of node.items) {
        if (nodesNeedHeadingAnchors(item.children)) return true;
      }
      continue;
    }

    if (node.type === "ListItem") {
      if (nodesNeedHeadingAnchors(node.children)) return true;
    }
  }

  return false;
}

function inlineToText(node: InlineNode): string {
  if (node.type === "Text") return node.value;
  if (node.type === "Timestamp") return node.raw;
  if (node.type === "TimestampRange") return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
  if (node.type === "Emphasis") return node.content;
  if (node.type === "Link") return node.descriptionRaw || node.targetRaw;
  if (node.type === "Target") return node.valueRaw;
  if (node.type === "Script") return node.valueRaw;
  if (node.type === "ExportSnippet") return node.valueRaw;
  if (node.type === "FootnoteReference") return node.definitionRaw || node.labelRaw || "";
  return node.raw;
}

const HTML_ENTITY_VALUES: Record<string, string> = {
  alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", zeta: "ζ", eta: "η", theta: "θ", iota: "ι", kappa: "κ", lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", omicron: "ο", pi: "π", rho: "ρ", sigma: "σ", tau: "τ", upsilon: "υ", phi: "φ", chi: "χ", psi: "ψ", omega: "ω",
  Alpha: "Α", Beta: "Β", Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π", Sigma: "Σ", Upsilon: "Υ", Phi: "Φ", Psi: "Ψ", Omega: "Ω",
  nbsp: "\u00a0", copy: "©", reg: "®", trade: "™", ndash: "–", mdash: "—", hellip: "…", laquo: "«", raquo: "»", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", bull: "•", middot: "·", times: "×", divide: "÷", plusmn: "±", le: "≤", ge: "≥", ne: "≠", infin: "∞", rarr: "→", larr: "←", uarr: "↑", darr: "↓", harr: "↔", check: "✓", deg: "°",
};

function renderTimestamp(node: TimestampNode): string {
  const klass = node.active ? "org2-timestamp active" : "org2-timestamp inactive";
  return `<time class="${klass}">${escapeHtml(node.raw)}</time>`;
}

function renderTimestampRange(node: TimestampRangeNode): string {
  const klass = node.start.active ? "org2-timestamp-range active" : "org2-timestamp-range inactive";
  return `<time class="${klass}">${escapeHtml(node.start.raw + node.separatorRaw + node.end.raw)}</time>`;
}

function renderEmphasis(node: EmphasisNode): string {
  const content = escapeHtml(node.content);
  if (node.kind === "bold") return `<strong>${content}</strong>`;
  if (node.kind === "italic") return `<em>${content}</em>`;
  if (node.kind === "underline") return `<span class="org2-underline">${content}</span>`;
  if (node.kind === "strike") return `<del>${content}</del>`;
  return `<code>${content}</code>`;
}

function embeddedFileLinkTarget(target: string, sourcePath: string): string {
  const explicitFile = /^file:/i.test(target);
  if (!explicitFile && /^[a-z][a-z0-9+.-]*:/i.test(target)) return target;
  const source = explicitFile ? target.slice(5) : target;
  const separator = source.indexOf("::");
  const file = separator < 0 ? source : source.slice(0, separator);
  const search = separator < 0 ? "" : source.slice(separator);
  // Bare paths follow the native file router's path/extension convention.
  // Plain fuzzy titles and stable ID links keep their existing lookup behavior.
  if (!explicitFile && (!file.includes("/") && !path.extname(file))) return target;
  if (file.startsWith("~")) return `file:${file}${search}`;
  return `file:${path.resolve(path.dirname(sourcePath), file)}${search}`;
}

function embeddedAnchorKey(target: string): string {
  return target.startsWith("#")
    ? `#${(normalizeAnchorId(target.slice(1)) ?? "").toLowerCase()}`
    : `*${slugifyHeadlineTitle(target.replace(/^\*+\s*/, ""))}`;
}

function embeddedSourceAnchorLines(document: DocumentNode): Map<string, number> {
  const candidates = new Map<string, number | null>();
  const add = (key: string, line: number) => candidates.set(key, candidates.has(key) ? null : line);
  const visit = (nodes: Node[]) => {
    for (const node of nodes) if (node.type === "Headline") {
      const line = (node as SourceRangedNode).sourceRange?.startLine;
      if (line !== undefined) {
        const title = node.title.map(inlineToText).join("").trim() || "Untitled";
        const customId = findHeadlineCustomId(node);
        add(embeddedAnchorKey(`#${customId ?? slugifyHeadlineTitle(title)}`), line);
        add(embeddedAnchorKey(`*${title}`), line);
      }
      visit(node.children);
    }
  };
  visit(document.children);
  // Ambiguity never chooses a different source heading on the user's behalf.
  return new Map([...candidates].filter((entry): entry is [string, number] => entry[1] !== null));
}

function appLinkHref(rawTarget: string, expandedTarget: string, context: RenderContext): string {
  if (context.embedded && context.sourcePath) {
    rawTarget = expandedTarget;
    if (linkTargetNeedsHeadingAnchor(rawTarget)) {
      const line = context.embeddedAnchorLines?.get(embeddedAnchorKey(rawTarget));
      rawTarget = `file:${context.sourcePath}${line === undefined ? "" : `::${line}`}`;
    } else {
      rawTarget = embeddedFileLinkTarget(rawTarget, context.sourcePath);
    }
    if (!/^(https?|mailto):/i.test(rawTarget)) return `org2-workspace://open-link?target=${encodeURIComponent(rawTarget)}`;
  }
  if (!context.nativeInternalLinks && linkTargetNeedsHeadingAnchor(expandedTarget)) {
    return rewriteOrgInternalHrefForHtml(expandedTarget, context);
  }

  if (/^(https?|mailto):/i.test(expandedTarget)) {
    return expandedTarget;
  }

  return `org2-workspace://open-link?target=${encodeURIComponent(rawTarget)}`;
}

function appLinkTooltip(rawTarget: string, expandedTarget: string): string {
  if (/^https?:/i.test(expandedTarget)) return `External link\n${expandedTarget}`;
  if (/^mailto:/i.test(expandedTarget)) return `Email link\n${expandedTarget.slice("mailto:".length)}`;

  const target = expandedTarget.replace(/^file:/i, "");
  const pathPart = target.split("::", 1)[0]?.split(/[?#]/, 1)[0] || "";
  // String-only extension parsing: the iOS JavaScriptCore runtime provides
  // no node:path beyond basename, so path.extname would throw there.
  const fileName = pathPart.split("/").pop() ?? "";
  const dot = fileName.lastIndexOf(".");
  const extension = dot > 0 ? fileName.slice(dot + 1).toLowerCase() : "";
  if (extension === "org" || extension === "org2") {
    return `Org document\n${expandedTarget}`;
  }
  if (extension) return `${extension.toUpperCase()} file\n${expandedTarget}`;
  if (/^(?:id:|#|\*)/i.test(rawTarget) || !/^[a-z][a-z0-9+.-]*:/i.test(rawTarget)) {
    return `Workspace link\n${rawTarget}`;
  }
  return `File\n${expandedTarget}`;
}

function renderLink(node: LinkNode, context: RenderContext): string {
  const hrefRaw = String(node.targetRaw || "").trim();
  const colorBinding = node.descriptionRaw !== undefined
    ? parseOrgColorBindingTarget(hrefRaw)
    : null;
  if (colorBinding) {
    return renderColorBinding(node.descriptionRaw || "", colorBinding, false);
  }
  const expandedHrefRaw = expandLinkAbbreviationTarget(hrefRaw, context.linkAbbreviations);
  let href = context.profile === "app"
    ? appLinkHref(hrefRaw, expandedHrefRaw, context)
    : expandedHrefRaw;

  if (context.profile !== "app" && context.rewriteFileLinks) {
    href = rewriteOrgFileHrefForHtml(expandedHrefRaw);
  }

  if (context.profile !== "app" && linkTargetNeedsHeadingAnchor(expandedHrefRaw)) {
    href = rewriteOrgInternalHrefForHtml(expandedHrefRaw, context);
  }

  const explicitDescription = String(node.descriptionRaw || "").trim();
  const tooltip = context.profile === "app"
    ? ` title="${escapeAttr(appLinkTooltip(hrefRaw, expandedHrefRaw))}"`
    : "";
  // An image link without a description is shown as the image, even when
  // prose surrounds it. A described link inside prose stays a text link.
  if (!explicitDescription) {
    const imageSource = resolveImageLinkSource(hrefRaw, context);
    if (imageSource) {
      const imageHref = context.profile === "app" ? href : imageSource;
      return `<a class="org2-image-link org2-inline-image-link" href="${escapeAttr(imageHref)}"${tooltip}><img class="org2-image" src="${escapeAttr(imageSource)}" alt="${escapeAttr(imageAltText(imageSource))}" loading="lazy" decoding="async" /></a>`;
    }
  }
  const defaultInternalText = resolveDefaultInternalLinkText(hrefRaw);
  const text = explicitDescription || defaultInternalText || String(node.targetRaw || "").trim() || href;
  return `<a href="${escapeAttr(href)}"${tooltip}>${escapeHtml(text)}</a>`;
}

function colorBindingStyles(binding: OrgColorBinding, wholeCell: boolean): string {
  const styles: string[] = [];
  if (binding.foreground) styles.push(`color: ${binding.foreground.css}`);
  if (binding.background) styles.push(`background-color: ${binding.background.css}`);
  if (binding.background && !wholeCell) {
    styles.push("border-radius: 0.2em", "padding: 0 0.12em", "box-decoration-break: clone", "-webkit-box-decoration-break: clone");
  }
  return styles.join("; ") + (styles.length > 0 ? ";" : "");
}

function renderColorBinding(label: string, binding: OrgColorBinding, wholeCell: boolean): string {
  const style = escapeAttr(colorBindingStyles(binding, wholeCell));
  if (wholeCell) return escapeHtml(label);
  return `<span class="org2-color-binding" style="${style}">${escapeHtml(label)}</span>`;
}

const IMAGE_LINK_EXTENSION = /\.(?:avif|bmp|gif|heic|heif|jpe?g|png|svg|webp)$/i;

function resolveImageLinkSource(rawTarget: string, context: RenderContext): string | null {
  const expandedTarget = expandLinkAbbreviationTarget(
    String(rawTarget || "").trim(),
    context.linkAbbreviations,
  );
  if (!expandedTarget) return null;

  if (/^data:image\/(?:avif|gif|jpeg|png|webp);base64,[a-z0-9+/=]+$/i.test(expandedTarget)) {
    return expandedTarget;
  }

  const targetWithoutSearch = expandedTarget.split("::", 1)[0] || "";
  const match = targetWithoutSearch.match(/^([^?#]*)([?#].*)?$/);
  const pathPart = match?.[1] || "";
  const suffix = match?.[2] || "";
  if (!IMAGE_LINK_EXTENSION.test(pathPart)) return null;

  if (/^https?:/i.test(pathPart)) return `${pathPart}${suffix}`;
  if (/^file:/i.test(pathPart)) {
    const fileTarget = pathPart.slice(5);
    if (fileTarget.startsWith("//")) return `file:${fileTarget}${suffix}`;
    if (fileTarget.startsWith("/")) return `file://${fileTarget}${suffix}`;
    return `${fileTarget}${suffix}`;
  }

  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(pathPart)) return null;
  return `${pathPart}${suffix}`;
}

function imageAltText(source: string): string {
  if (/^data:image\//i.test(source)) return "Image";
  const pathPart = source.split(/[?#]/, 1)[0] || "";
  const filename = path.basename(pathPart).replace(/\.[^.]+$/, "");
  try {
    return decodeURIComponent(filename).replace(/[-_]+/g, " ").trim() || "Image";
  } catch {
    return filename.replace(/[-_]+/g, " ").trim() || "Image";
  }
}

function renderStandaloneImageParagraph(node: ParagraphNode, context: RenderContext): string | null {
  const meaningfulChildren = node.children.filter(
    (child) => child.type !== "Text" || child.value.trim().length > 0,
  );
  if (meaningfulChildren.length !== 1 || meaningfulChildren[0]?.type !== "Link") return null;

  const link = meaningfulChildren[0];
  const description = String(link.descriptionRaw || "").trim();
  const source = resolveImageLinkSource(link.targetRaw, context);
  if (!source) return null;

  const expandedTarget = expandLinkAbbreviationTarget(link.targetRaw, context.linkAbbreviations);
  const href = context.profile === "app"
    ? appLinkHref(link.targetRaw, expandedTarget, context)
    : source;
  const sourceAttributes = renderSourceAttributes(node, context);
  return `<figure class="org2-image-figure"${sourceAttributes}><a class="org2-image-link" href="${escapeAttr(href)}"><img class="org2-image" src="${escapeAttr(source)}" alt="${escapeAttr(description || imageAltText(source))}" loading="lazy" decoding="async" /></a></figure>`;
}

function renderInline(node: InlineNode, context: RenderContext): string {
  if (node.type === "Text") return escapeHtml(node.value);
  if (node.type === "Timestamp") return renderTimestamp(node);
  if (node.type === "TimestampRange") return renderTimestampRange(node);
  if (node.type === "Emphasis") return renderEmphasis(node);
  if (node.type === "Link") return renderLink(node, context);
  if (node.type === "ProgressCookie") return `<span class="org2-progress-cookie">${escapeHtml(node.raw)}</span>`;
  if (node.type === "Entity") return `<span class="org2-entity" title="${escapeAttr(node.raw)}">${escapeHtml(HTML_ENTITY_VALUES[node.nameRaw] || node.raw)}</span>`;
  if (node.type === "LatexFragment") {
    const displayClass = node.display ? " display" : "";
    return `<span class="org2-latex-fragment${displayClass}">${escapeHtml(node.raw)}</span>`;
  }
  if (node.type === "ExportSnippet") {
    if (node.backendRaw.toLowerCase() !== "html") return "";
    return context.profile === "app"
      ? `<span class="org2-export-snippet">${escapeHtml(node.valueRaw)}</span>`
      : node.valueRaw;
  }
  if (node.type === "FootnoteReference") {
    const label = node.labelRaw || "*";
    if (node.definitionRaw !== undefined) {
      return `<sup class="org2-footnote-reference inline" title="${escapeAttr(node.definitionRaw)}">${escapeHtml(label)}</sup>`;
    }
    const id = normalizeAnchorId(`fn-${label}`) || "fn-inline";
    return `<sup class="org2-footnote-reference"><a href="#${escapeAttr(id)}">${escapeHtml(label)}</a></sup>`;
  }
  if (node.type === "Citation") {
    const references = node.references.map((reference) =>
      [reference.prefixRaw, `@${reference.keyRaw}`, reference.suffixRaw].filter(Boolean).join(" "),
    ).join("; ");
    const content = [node.prefixRaw, references, node.suffixRaw].filter(Boolean).join(" ");
    return `<cite class="org2-citation" data-org2-citation-style="${escapeAttr(node.styleRaw || "")}">${escapeHtml(content)}</cite>`;
  }
  if (node.type === "Target") {
    const id = normalizeAnchorId(node.valueRaw) || "target";
    return `<span class="org2-target${node.radio ? " radio" : ""}" id="${escapeAttr(id)}"></span>`;
  }
  if (node.type === "Script") {
    const tag = node.kind === "subscript" ? "sub" : "sup";
    return `<${tag}>${escapeHtml(node.valueRaw)}</${tag}>`;
  }
  if (node.type === "LineBreak") return "<br />";
  return "";
}

function renderInlineChildren(nodes: InlineNode[], context: RenderContext): string {
  return nodes.map((node) => renderInline(node, context)).join("");
}

type SourceRangedNode = Node & { sourceRange?: { startLine: number; endLine: number } };

function renderSourceAttributes(node: Node, context: RenderContext): string {
  if (context.profile !== "app" || context.embedded) return "";
  const range = (node as SourceRangedNode).sourceRange;
  if (!range) return "";
  return ` data-org2-start-line="${range.startLine}" data-org2-end-line="${range.endLine}"`;
}

function renderParagraph(node: ParagraphNode, context: RenderContext): string {
  const image = renderStandaloneImageParagraph(node, context);
  if (image) return image;

  const sourceAttributes = renderSourceAttributes(node, context);
  if (node.children.length === 1 && node.children[0]?.type === "Text") {
    const raw = String(node.children[0].value || "").trim();
    if (raw === "--") return `<p${sourceAttributes}>&#x2013;</p>`;
    if (raw === "---") return `<p${sourceAttributes}>&#x2014;</p>`;
  }
  return `<p${sourceAttributes}>${renderInlineChildren(node.children, context)}</p>`;
}

function renderPlanning(node: PlanningNode, context: RenderContext): string {
  const raw = node.timestamp
    ? node.timestamp.type === "Timestamp"
      ? node.timestamp.raw
      : node.timestamp.start.raw + node.timestamp.separatorRaw + node.timestamp.end.raw
    : node.raw;
  return `<p class="org2-planning"${renderSourceAttributes(node, context)}><span class="org2-planning-kind">${escapeHtml(node.kind)}</span> ${escapeHtml(raw)}</p>`;
}

function renderPropertyDrawer(node: PropertyDrawerNode, context: RenderContext): string {
  if (!node.properties.length) return "";

  const rows = node.properties
    .map((property) => `<dt>${escapeHtml(property.key)}</dt><dd>${escapeHtml(property.value)}</dd>`)
    .join("\n");

  if (context.profile === "app") {
    return `<details class="org2-properties-drawer" open${renderSourceAttributes(node, context)}>\n<summary>Properties</summary>\n<dl class="org2-properties">\n${rows}\n</dl>\n</details>`;
  }

  return `<dl class="org2-properties"${renderSourceAttributes(node, context)}>\n${rows}\n</dl>`;
}

function renderSrcBlock(node: SrcBlockNode, context: RenderContext): string {
  const languageRaw = String(node.begin.afterKeywordRaw || "")
    .trim()
    .split(/\s+/)[0];
  const language = languageRaw.toLowerCase().replace(/[^a-z0-9_+-]/g, "");
  const sourceRange = (node as SourceRangedNode).sourceRange;
  const pluginRender = sourceRange ? context.pluginRendersByBlockLine?.get(sourceRange.startLine) : undefined;
  if (pluginRender) return renderPluginFrame(pluginRender, renderSourceAttributes(node, context));
  const embeddedChart = sourceRange && (language === "chart" || language === "plot")
    ? context.chartsByBlockLine?.get(sourceRange.startLine)
    : undefined;
  if (embeddedChart) return renderEmbeddedChart(embeddedChart, renderSourceAttributes(node, context));
  const languageClass = language ? ` language-${language}` : "";
  const codeClassAttr = language ? ` class="language-${escapeAttr(language)}"` : "";
  const raw = node.bodyRaw.replace(/\n$/, "");
  if (context.codeFile && context.profile === "app") {
    // A code file view keeps every line addressable so chat links such as
    // `file:script.py::27` scroll to the exact line; it is never collapsed.
    const startLine = sourceRange?.startLine ?? 1;
    const lines = highlightCodeLinesToHtml(raw, language, (line) => {
      const sourceLine = startLine + line - 1;
      return ` data-org2-start-line="${sourceLine}" data-org2-end-line="${sourceLine}"`;
    });
    return `<pre class="org2-src org2-code-file${languageClass}"><code${codeClassAttr}>${lines}</code></pre>`;
  }
  // The app view highlights known languages natively (no script in the
  // document); published HTML keeps plain code for its configured highlighter.
  const body = context.profile === "app" && normalizeCodeLanguage(language)
    ? highlightCodeToHtml(raw, language)
    : escapeHtml(raw);
  const baseStyle = "padding: 0.9rem 1rem; border: 1px solid rgba(127,127,127,0.28); border-radius: 0.6rem; background: rgba(127,127,127,0.11); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace; font-size: 0.92rem; line-height: 1.28;";
  const pre = `<pre class="org2-src${languageClass}"${renderSourceAttributes(node, context)} style="${escapeAttr(baseStyle)}"><code${codeClassAttr}>${body}</code></pre>`;
  if (context.profile === "app" && language === "html" && node.terminated) {
    return renderHtmlPreview(raw, String(node.begin.afterKeywordRaw || ""), pre, renderSourceAttributes(node, context));
  }
  // Large audit payloads can dwarf the readable document. A closed native
  // disclosure keeps their complete text available without laying out every
  // line on initial display. Published/exported documents remain expanded.
  const lineCount = raw.split("\n").length;
  if (context.profile === "app" && (raw.length > 32_768 || lineCount > 200)) {
    return `<details class="org2-large-source"${renderSourceAttributes(node, context)}><summary>${language ? `${escapeHtml(language)} source` : "Source"} · ${lineCount} lines</summary>${pre}</details>`;
  }
  return pre;
}

/** Host message a sandboxed HTML preview posts when its content height changes. */
export const HTML_PREVIEW_SIZE_MESSAGE = "org2-frame-size";
export const HTML_PREVIEW_DEFAULT_HEIGHT = 320;
export const HTML_PREVIEW_MAX_HEIGHT = 1600;

/**
 * Reports the preview's content height to the host so it can grow or shrink
 * the frame. Content sized from the viewport (for example `100vh` plus a
 * margin) would grow on every report; repeated identical growth stops it.
 */
const HTML_PREVIEW_SIZING_SCRIPT = `(() => {
  let last = 0, growth = 0, repeats = 0;
  const measure = () => {
    const root = document.documentElement, body = document.body;
    let height = root.scrollHeight;
    if (body) {
      const style = getComputedStyle(body);
      const bottom = body.getBoundingClientRect().bottom + scrollY + (parseFloat(style.marginBottom) || 0);
      height = root.scrollHeight > innerHeight + 1 ? Math.max(bottom, root.scrollHeight) : bottom;
    }
    height = Math.ceil(height);
    if (Math.abs(height - last) < 1) return;
    const delta = height - innerHeight;
    if (delta > 0 && delta === growth) { if (++repeats >= 3) return; } else repeats = 0;
    growth = delta; last = height;
    parent.postMessage({ type: "${HTML_PREVIEW_SIZE_MESSAGE}", height }, "*");
  };
  const start = () => {
    const observer = new ResizeObserver(() => requestAnimationFrame(measure));
    observer.observe(document.documentElement);
    if (document.body) observer.observe(document.body);
    addEventListener("load", measure);
    measure();
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();`;

/**
 * An app-profile HTML block becomes a live preview: scripts run, and remote
 * HTTPS scripts, styles, images, fonts, and requests may load. Isolation comes
 * from the opaque-origin sandbox (no `allow-same-origin`), so the snippet cannot
 * read or script the surrounding document, its storage, or the host app. It
 * cannot navigate the top-level page or submit forms anywhere. `:height N`
 * fixes the frame height; otherwise the host sizes it to its content.
 */
function renderHtmlPreview(raw: string, parameters: string, sourcePre: string, sourceAttributes: string): string {
  const csp = [
    "default-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "script-src 'unsafe-inline' 'unsafe-eval' https: blob:",
    "style-src 'unsafe-inline' https:",
    "img-src data: blob: https:",
    "font-src data: https:",
    "media-src data: blob: https:",
    "connect-src https:",
    "worker-src blob:",
  ].join("; ");
  const requested = Number(/(?:^|\s):height\s+(\d+)(?:px)?(?=\s|$)/i.exec(parameters)?.[1]);
  const fixedHeight = Number.isFinite(requested) && requested > 0
    ? Math.min(HTML_PREVIEW_MAX_HEIGHT, Math.max(24, Math.round(requested)))
    : undefined;
  const sizing = fixedHeight ? "" : `<script>${HTML_PREVIEW_SIZING_SCRIPT}</script>`;
  const document = `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${escapeAttr(csp)}"><meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width, initial-scale=1"><style>html{color-scheme:light dark}body{margin:12px;font-family:system-ui}*{box-sizing:border-box}</style>${sizing}</head><body>${raw}</body></html>`;
  const height = fixedHeight ?? HTML_PREVIEW_DEFAULT_HEIGHT;
  const autosize = fixedHeight ? "" : ' data-org2-autosize="true"';
  return `<figure class="org2-html-preview"${sourceAttributes}><iframe title="HTML preview" sandbox="allow-scripts allow-forms allow-popups" referrerpolicy="no-referrer"${autosize} style="display:block;box-sizing:border-box;width:100%;height:${height}px;border:1px solid rgba(127,127,127,0.28);border-radius:10px" srcdoc="${escapeAttr(document)}"></iframe><details class="org2-html-source"><summary>HTML source</summary>${sourcePre}</details></figure>`;
}

function renderPluginFrame(render: Org2PluginRender, sourceAttributes = ""): string {
  const identity = `${render.pluginId}:${render.rendererId}`;
  if (render.error) {
    return `<aside class="org2-plugin-render-error" data-org2-plugin="${escapeAttr(identity)}"${sourceAttributes}><strong>Plugin renderer unavailable</strong><span>${escapeHtml(render.error)}</span></aside>`;
  }
  const csp = "default-src 'none'; base-uri 'none'; connect-src 'none'; font-src data:; form-action 'none'; frame-src 'none'; img-src data: blob:; media-src data: blob:; navigate-to 'none'; object-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; worker-src 'none'";
  const css = String(render.css || "").replace(/<\/style/gi, "<\\/style");
  const script = String(render.script || "").replace(/<\/script/gi, "<\\/script");
  const document = `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${escapeAttr(csp)}"><meta name="referrer" content="no-referrer"><style>html,body{margin:0;padding:0;color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}*{box-sizing:border-box}${css}</style></head><body>${render.html || ""}${script ? `<script>${script}</script>` : ""}</body></html>`;
  const title = render.title || `${render.pluginId} ${render.rendererId}`;
  return `<figure class="org2-plugin-render" data-org2-plugin="${escapeAttr(identity)}"${sourceAttributes}><iframe title="${escapeAttr(title)}" sandbox="allow-scripts" referrerpolicy="no-referrer" loading="lazy" style="display:block;width:100%;height:${render.height}px;border:0;background:transparent" srcdoc="${escapeAttr(document)}"></iframe></figure>`;
}

function renderEmbeddedChart(chart: OrgEmbeddedChart, sourceAttributes = ""): string {
  const presentation = chart.presentation;
  const size = presentation?.size || "medium";
  const interactive = presentation?.interactive !== false;
  return `<figure class="org2-chart org2-chart-${size} celorga-chart" data-org2-chart-interactive="${interactive}"${sourceAttributes}>\n${chart.svg.trim()}\n</figure>`;
}

function renderBlock(node: BlockNode, context: RenderContext): string {
  const bodyRaw = node.bodyRaw.replace(/\n$/, "");
  const body = escapeHtml(node.kind === "quote" ? dedentBlockBody(bodyRaw, node.begin.indent) : bodyRaw);

  if (node.kind === "quote") {
    const appClass = context.profile === "app" ? ' class="org2-quote"' : "";
    return `<blockquote${appClass}${renderSourceAttributes(node, context)}>${body}</blockquote>`;
  }
  if (node.kind === "center") return `<div class="org2-center">${body}</div>`;
  if (node.kind === "verse") return `<pre class="org2-verse">${body}</pre>`;
  if (node.kind === "comment") return `<pre class="org2-comment">${body}</pre>`;
  if (node.kind === "export") {
    const exportTarget = String(node.begin.afterKeywordRaw || "").trim().toLowerCase();
    if (exportTarget === "html" && context.profile !== "app") return bodyRaw;
    return `<pre class="org2-export">${body}</pre>`;
  }
  if (node.kind === "example") return `<pre class="org2-example">${body}</pre>`;
  const kind = node.kind.toLowerCase().replace(/[^a-z0-9_-]+/g, "-");
  return `<div class="org2-special-block org2-special-block-${escapeAttr(kind)}"${renderSourceAttributes(node, context)}><pre>${body}</pre></div>`;
}

function dedentBlockBody(bodyRaw: string, indent: string): string {
  if (!indent) return bodyRaw;
  return bodyRaw
    .split("\n")
    .map((line) => line.startsWith(indent) ? line.slice(indent.length) : line)
    .join("\n");
}

function renderTableRow(
  row: TableRowNode,
  asHeader: boolean,
  context: RenderContext,
): string {
  const cellTag = asHeader ? "th" : "td";
  const cells = row.cells
    .map((cell) => {
      const parsed = parseInlinesFromText(String(cell || "").trim());
      if (parsed.length === 1 && parsed[0]?.type === "Link" && parsed[0].descriptionRaw !== undefined) {
        const binding = parseOrgColorBindingTarget(parsed[0].targetRaw);
        if (binding) {
          const style = escapeAttr(colorBindingStyles(binding, true));
          return `<${cellTag} class="org2-color-cell" style="${style}">${renderColorBinding(parsed[0].descriptionRaw, binding, true)}</${cellTag}>`;
        }
      }
      const rendered = renderInlineChildren(parsed, context);
      return `<${cellTag}>${rendered}</${cellTag}>`;
    })
    .join("");
  return `<tr>${cells}</tr>`;
}

function renderTable(node: TableNode, context: RenderContext): string {
  const formulaResult = node.formulas?.length ? evaluateTableNode(node) : undefined;
  const renderedNode = formulaResult?.ok ? formulaResult.table : node;
  const rows = renderedNode.rows;
  const firstHline = rows.findIndex((row): row is TableHlineNode => row.type === "TableHline");

  const headerRows =
    firstHline > 0
      ? rows.slice(0, firstHline).filter((row): row is TableRowNode => row.type === "TableRow")
      : [];

  const bodyRows =
    firstHline >= 0
      ? rows.slice(firstHline + 1).filter((row): row is TableRowNode => row.type === "TableRow")
      : rows.filter((row): row is TableRowNode => row.type === "TableRow");

  const resolvedBodyRows = bodyRows.length > 0 ? bodyRows : headerRows;
  const renderedHead =
    headerRows.length > 0 ? `<thead>\n${headerRows.map((row) => renderTableRow(row, true, context)).join("\n")}\n</thead>` : "";
  const renderedBody = `<tbody>\n${resolvedBodyRows.map((row) => renderTableRow(row, false, context)).join("\n")}\n</tbody>`;

  const sourceAttributes = renderSourceAttributes(node, context);
  const formulaAttributes = node.formulas?.length
    ? ` data-org2-formula-count="${node.formulas.length}" data-org2-formula-state="${formulaResult?.ok ? "current" : "error"}"`
    : "";
  const table = `<table${sourceAttributes}${formulaAttributes}>\n${[renderedHead, renderedBody].filter(Boolean).join("\n")}\n</table>`;
  const tableHtml = context.profile === "app" || context.profile === "publish"
    ? `<div class="org2-table-scroll">\n${table}\n</div>`
    : table;
  const formulaStatus = formulaResult
    ? `<small class="org2-table-formula-status${formulaResult.ok ? "" : " org2-table-formula-error"}">${formulaResult.ok ? `Calculated from TBLFM${(node.formulas?.length ?? 0) > 1 ? ` line 1 of ${node.formulas?.length}` : ""}` : `Formula not evaluated: ${escapeHtml(formulaResult.diagnostics[0]?.message ?? "unsupported formula")}`}</small>`
    : "";
  const sourceRange = (node as SourceRangedNode).sourceRange;
  const chart = sourceRange ? context.chartsByTableLine?.get(sourceRange.startLine) : undefined;
  const output = `${tableHtml}${formulaStatus ? `\n${formulaStatus}` : ""}`;
  return chart ? `${output}\n${renderEmbeddedChart(chart)}` : output;
}

function renderListItem(node: ListItemNode, context: RenderContext): string {
  const body = renderNodes(node.children, context);
  const sourceAttributes = renderSourceAttributes(node, context);
  const ordinalAttribute = node.ordinal !== undefined ? ` value="${node.ordinal}"` : "";
  const counterAttribute = node.counter !== undefined ? ` data-org2-counter="${node.counter}"` : "";
  const checkbox =
    node.checkbox === "checked"
      ? '<input type="checkbox" checked disabled /> '
      : node.checkbox === "unchecked"
        ? '<input type="checkbox" disabled /> '
        : node.checkbox === "indeterminate"
          ? '<span class="org2-checkbox-mixed" role="checkbox" aria-checked="mixed">−</span> '
        : "";
  const description = node.descriptionTag
    ? `<strong class="org2-description-tag">${renderInlineChildren(node.descriptionTag, context)}</strong> — `
    : "";

  if (!body.trim()) return `<li${ordinalAttribute}${counterAttribute}${sourceAttributes}>${checkbox}${description}</li>`;
  if (body.includes("\n")) return `<li${ordinalAttribute}${counterAttribute}${sourceAttributes}>${checkbox}${description}\n${body}\n</li>`;
  return `<li${ordinalAttribute}${counterAttribute}${sourceAttributes}>${checkbox}${description}${body}</li>`;
}

function renderList(node: ListNode, context: RenderContext): string {
  if (node.items.length > 0 && node.items.every((item) => item.descriptionTag)) {
    const entries = node.items.map((item) => {
      const term = renderInlineChildren(item.descriptionTag || [], context);
      const body = renderNodes(item.children, context);
      const checkbox = item.checkbox === "checked"
        ? '<input type="checkbox" checked disabled /> '
        : item.checkbox === "unchecked"
          ? '<input type="checkbox" disabled /> '
          : item.checkbox === "indeterminate"
            ? '<span class="org2-checkbox-mixed" role="checkbox" aria-checked="mixed">−</span> '
            : "";
      const counterAttribute = item.counter !== undefined ? ` data-org2-counter="${item.counter}"` : "";
      return `<dt${counterAttribute}>${term}</dt><dd>${checkbox}${body}</dd>`;
    }).join("\n");
    return `<dl class="org2-description-list"${renderSourceAttributes(node, context)}>\n${entries}\n</dl>`;
  }
  const tag = node.ordered ? "ol" : "ul";
  const items = node.items.map((item) => renderListItem(item, context)).join("\n");
  return `<${tag}${renderSourceAttributes(node, context)}>\n${items}\n</${tag}>`;
}

/**
 * Finished headings recede like Emacs Org's `org-headline-done`: done titles
 * soften and canceled titles grey out and strike through. Open headings carry
 * no class, so their markup is unchanged.
 */
function headlineTodoStateClassAttribute(node: HeadlineNode): string {
  if (!node.todo) return "";
  const status = node.todoTerminal === false ? undefined : terminalTodoStatusFromKeyword(node.todo) ?? (node.todoTerminal ? "done" : undefined);
  if (status === "canceled") return ' class="org2-headline-canceled"';
  if (status === "done") return ' class="org2-headline-done"';
  return "";
}

function renderHeadline(node: HeadlineNode, context: RenderContext): string {
  const headingLevel = Math.max(1, Math.min(6, node.level));
  const headingTag = `h${headingLevel}`;
  const title = renderInlineChildren(node.title, context);
  const headingNumberRaw = context.headlineNumbers?.get(node);
  const headingNumber = headingNumberRaw ? `<span class="org2-headline-number">${escapeHtml(headingNumberRaw)}</span> ` : "";
  const todoClass = String(node.todo || "").trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "-");
  const appTodoClass = context.profile === "app" && todoClass ? ` todo-${escapeAttr(todoClass)}` : "";
  const todo = node.todo ? `<span class="org2-todo${appTodoClass}">${escapeHtml(node.todo)}</span> ` : "";
  const headingStateAttr = headlineTodoStateClassAttribute(node);
  const priority = node.priority ? `<span class="org2-priority">[#${escapeHtml(node.priority)}]</span> ` : "";
  const comment = node.commented ? '<span class="org2-comment-keyword">COMMENT</span> ' : "";
  const tags =
    node.tags && node.tags.length > 0
      ? ` <span class="org2-tags">${node.tags.map((tag) => `<span class="org2-tag">${escapeHtml(tag)}</span>`).join(" ")}</span>`
      : "";
  const headingId = context.headlineIds?.get(node);
  const headingIdAttr = headingId ? ` id="${escapeAttr(headingId)}"` : "";

  const childrenHtml = renderNodes(node.children, context);
  if (context.profile === "app") {
    const body = childrenHtml.trim()
      ? `\n<div class="org2-headline-body">\n${childrenHtml}\n</div>`
      : "";
    return `<details class="org2-headline level-${node.level}${node.commented ? " commented" : ""}" open${renderSourceAttributes(node, context)}>\n<summary class="org2-headline-summary"><${headingTag}${headingIdAttr}${headingStateAttr}>${headingNumber}${todo}${priority}${comment}${title}${tags}</${headingTag}></summary>${body}\n</details>`;
  }

  if (!childrenHtml.trim()) {
    return `<section class="org2-headline level-${node.level}${node.commented ? " commented" : ""}"${renderSourceAttributes(node, context)}>\n<${headingTag}${headingIdAttr}${headingStateAttr}>${headingNumber}${todo}${priority}${comment}${title}${tags}</${headingTag}>\n</section>`;
  }

  return `<section class="org2-headline level-${node.level}${node.commented ? " commented" : ""}"${renderSourceAttributes(node, context)}>\n<${headingTag}${headingIdAttr}${headingStateAttr}>${headingNumber}${todo}${priority}${comment}${title}${tags}</${headingTag}>\n${childrenHtml}\n</section>`;
}

function renderLiveEmbed(target: string, context: RenderContext): string {
  // Publishing never dereferences corpus content. The disclosure-safe publisher
  // further replaces this reference with a target-free omission marker.
  const reference = context.profile === "app"
    ? `<a href="org2-workspace://open-link?target=${encodeURIComponent(context.embedded && context.sourcePath ? embeddedFileLinkTarget(target, context.sourcePath) : target)}">Open source · ${escapeHtml(target)}</a>`
    : `<span>Live embed reference: ${escapeHtml(target)} (content not exported)</span>`;
  const shell = (body: string) => `<aside class="org2-live-embed" data-org2-live-embed="true"><header>${reference}</header>${body}</aside>`;
  if (context.profile !== "app") return shell("");
  if (!context.embedResolver) return shell('<p role="status">Live content is not included in this rendering. Open the source to read it.</p>');
  const budget = context.embedBudget!;
  if ((context.embedStack?.length ?? 0) > 4 || budget.remaining-- <= 0) return shell('<p role="status">Embed limit reached (4 levels / 32 references).</p>');
  const result = context.embedResolver(target, context.sourcePath);
  if (!result.ok) return shell(`<p role="status">${escapeHtml(result.message)}</p>`);
  if (context.embedStack?.includes(result.key)) return shell('<p role="status">Embed cycle stopped.</p>');
  if ((budget.bytes -= result.bytes) < 0) return shell('<p role="status">Embed content limit reached (1 MiB per render).</p>');
  const childContext: RenderContext = {
    ...context, sourcePath: result.file, embedded: true,
    embeddedAnchorLines: embeddedSourceAnchorLines(result.sourceDocument ?? result.document),
    embedStack: [...(context.embedStack ?? []), result.key],
    headlineIds: undefined, headlineSlugIds: undefined, headlineNumbers: undefined,
    chartsByTableLine: undefined, chartsByBlockLine: undefined, pluginRendersByBlockLine: undefined,
    linkAbbreviations: mergeLinkAbbreviations([context.linkAbbreviations ?? new Map(), collectLinkAbbreviationsFromDoc(result.document)]),
  };
  let body = renderNodes(result.document.children, childContext);
  // File links and images are relative to the embedded source, never its host.
  body = body.replace(/(<img\b[^>]*\bsrc=")([^"]+)(")/g, (match, before: string, image: string, after: string) => {
    if (/^(?:[a-z]+:|\/\/)/i.test(image)) return match;
    const decoded = image.replace(/&amp;/g, "&").replace(/&quot;/g, '"');
    return `${before}org2-resource://local?target=${encodeURIComponent(path.resolve(path.dirname(result.file), decoded))}${after}`;
  });
  // A script-free sandbox keeps embedded source completely outside host editing,
  // source-range selection, table mutations, and heading action affordances.
  const frame = `<!doctype html><html><head><meta charset="utf-8"><base target="_top"><style>${APP_DOCUMENT_STYLE} body { padding: 12px; } .org2-live-embed { margin: 8px 0; }</style></head><body>${body}</body></html>`;
  return shell(`<iframe class="org2-live-embed-frame" title="${escapeAttr(result.title)}" sandbox="allow-same-origin allow-top-navigation-by-user-activation" srcdoc="${escapeAttr(frame)}"></iframe>`);
}

function renderNode(node: Node, context: RenderContext): string {
  if (node.type === "Headline") return renderHeadline(node, context);
  if (node.type === "Paragraph") return renderParagraph(node, context);
  if (node.type === "List") return renderList(node, context);
  if (node.type === "ListItem") return renderListItem(node, context);
  if (node.type === "Planning") return renderPlanning(node, context);
  if (node.type === "PropertyDrawer") return renderPropertyDrawer(node, context);
  if (node.type === "SrcBlock") return renderSrcBlock(node, context);
  if (node.type === "Block") return renderBlock(node, context);
  if (node.type === "DynamicBlock") {
    const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
    return `<section class="org2-dynamic-block" data-org2-dynamic-block="${escapeAttr(node.nameRaw)}"${renderSourceAttributes(node, context)}><header>${escapeHtml(node.nameRaw)}</header><pre>${body}</pre></section>`;
  }
  if (node.type === "FixedWidth") {
    const body = node.lines.map((line) => line.valueRaw).join("\n");
    return `<pre class="org2-fixed-width"${renderSourceAttributes(node, context)}>${escapeHtml(body)}</pre>`;
  }
  if (node.type === "HorizontalRule") return `<hr${renderSourceAttributes(node, context)} />`;
  if (node.type === "LatexEnvironment") {
    const raw = [node.beginRaw, node.bodyRaw, node.endRaw].filter(Boolean).join("\n");
    return `<pre class="org2-latex-environment" data-org2-latex-environment="${escapeAttr(node.nameRaw)}"${renderSourceAttributes(node, context)}>${escapeHtml(raw)}</pre>`;
  }
  if (node.type === "DiarySexp") return `<code class="org2-diary-sexp"${renderSourceAttributes(node, context)}>${escapeHtml(node.raw)}</code>`;
  if (node.type === "FootnoteDefinition") {
    const id = normalizeAnchorId(`fn-${node.labelRaw}`) || "fn";
    return `<aside class="org2-footnote-definition" id="${escapeAttr(id)}"${renderSourceAttributes(node, context)}><sup>${escapeHtml(node.labelRaw)}</sup> ${renderInlineChildren(node.children, context)}</aside>`;
  }
  if (node.type === "Table") return renderTable(node, context);
  if (node.type === "Drawer") {
    const name = escapeHtml(node.nameRaw);
    const body = escapeHtml(node.bodyRaw.replace(/\n$/, ""));
    return `<details class="org2-drawer"${renderSourceAttributes(node, context)}><summary>${name}</summary><pre>${body}</pre></details>`;
  }
  if (node.type === "KeywordLine") {
    const key = String(node.keyRaw || "").trim().toUpperCase();
    if (key === "EMBED") return renderLiveEmbed(node.valueRaw.trim(), context);
    if (HIDDEN_DOCUMENT_KEYWORDS.has(key)) return "";
    return `<p class="org2-keyword"><span class="org2-keyword-name">${escapeHtml(node.keyRaw)}</span>: ${escapeHtml(node.valueRaw.trim())}</p>`;
  }
  if (node.type === "DirectiveLine") {
    return `<pre class="org2-directive">${escapeHtml(node.raw)}</pre>`;
  }
  if (node.type === "CommentLine") return "";
  if (node.type === "Text") {
    const text = String(node.value || "");
    return text.trim().length > 0 ? `<p>${escapeHtml(text)}</p>` : "";
  }

  return "";
}

function renderNodes(nodes: Node[], context: RenderContext = {}): string {
  return nodes
    .map((node) => renderNode(node, context))
    .filter((html) => String(html || "").trim().length > 0)
    .join("\n");
}

type AppFileProperty = { key: string; value: string };

// File-level metadata can be written as a leading :PROPERTIES: drawer, as
// #+KEYWORD lines, or both. They describe the same thing (the file), so the app
// view shows them as one uniform "File properties" list instead of a drawer box
// followed by loose keyword paragraphs.
function splitAppFileProperties(nodes: Node[]): { properties: AppFileProperty[]; body: Node[] } {
  const properties: AppFileProperty[] = [];
  const seen = new Set<string>();
  const body: Node[] = [];
  let inPreamble = true;
  let drawerSeen = false;

  const add = (key: string, value: string) => {
    const identity = `${key.toUpperCase()}\u0000${value}`;
    if (seen.has(identity)) return;
    seen.add(identity);
    properties.push({ key, value });
  };

  for (const node of nodes) {
    if (!inPreamble) { body.push(node); continue; }
    if (node.type === "CommentLine") continue;
    if (node.type === "PropertyDrawer" && !drawerSeen) {
      drawerSeen = true;
      for (const property of node.properties) add(property.key, property.value);
      continue;
    }
    if (node.type === "KeywordLine") {
      const key = String(node.keyRaw || "").trim();
      const upper = key.toUpperCase();
      if (upper === "EMBED") { inPreamble = false; body.push(node); continue; }
      if (HIDDEN_DOCUMENT_KEYWORDS.has(upper)) continue;
      const value = node.valueRaw.trim();
      if (upper === "PROPERTY") {
        const match = /^(\S+)\s*(.*)$/.exec(value);
        if (match) { add(match[1]!, match[2]!.trim()); continue; }
      }
      add(key, value);
      continue;
    }
    inPreamble = false;
    body.push(node);
  }

  return { properties, body };
}

function renderAppFileProperties(properties: AppFileProperty[]): string {
  if (properties.length === 0) return "";
  const rows = properties
    .map((property) => `<dt>${escapeHtml(property.key)}</dt><dd>${escapeHtml(property.value)}</dd>`)
    .join("\n");
  return `<details class="org2-file-properties">\n<summary>File properties <span class="org2-file-properties-count">${properties.length}</span></summary>\n<div class="org2-file-properties-body">\n<dl class="org2-properties">\n${rows}\n</dl>\n</div>\n</details>`;
}

function findTitleFromKeywords(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "TITLE") continue;
    const value = String(node.valueRaw || "").trim();
    if (value) return value;
  }
  return null;
}

function findSubtitleFromKeywords(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "KeywordLine") continue;
    if (String(node.keyRaw || "").trim().toUpperCase() !== "SUBTITLE") continue;
    const value = String(node.valueRaw || "").trim();
    if (value) return value;
  }
  return null;
}

function findTitleFromHeadlines(doc: DocumentNode): string | null {
  for (const node of doc.children) {
    if (node.type !== "Headline") continue;
    const text = node.title.map((child) => inlineToText(child)).join("").trim();
    if (text) return text;
  }
  return null;
}

function resolveTitle(doc: DocumentNode, explicitTitle: string | undefined, sourcePath: string | undefined): string {
  const explicit = String(explicitTitle || "").trim();
  if (explicit) return explicit;

  const keyword = findTitleFromKeywords(doc);
  if (keyword) return keyword;

  const headline = findTitleFromHeadlines(doc);
  if (headline) return headline;

  if (sourcePath) return path.basename(sourcePath);
  return "Celorga Document";
}

function renderDocumentHeader(opts: { title: string; subtitle?: string }): string {
  const title = String(opts.title || "").trim();
  if (!title) return "";

  const subtitle = String(opts.subtitle || "").trim();
  const subtitleHtml = subtitle ? `\n<p class="org2-document-subtitle" role="doc-subtitle">${escapeHtml(subtitle)}</p>` : "";
  return `<header class="org2-document-header">\n<h1 class="org2-document-title">${escapeHtml(title)}</h1>${subtitleHtml}\n</header>`;
}

type ResolvedDocumentRenderOptions = {
  includeToc: boolean;
  includeTocDepth: number | undefined;
  includeHeadlineNumbers: boolean;
  includeHeadlineNumberDepth: number | undefined;
  includeDocumentHeader: boolean;
};

function resolveDocumentRenderOptions(
  doc: DocumentNode,
  opts: {
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
    includeDocumentHeader?: boolean;
  },
): ResolvedDocumentRenderOptions {
  const exportOptions = collectKeywordOptions(doc);
  const includeToc = opts.includeToc === true || (opts.includeToc !== false && exportOptions.toc === true);
  const includeTocDepth =
    normalizeTocDepth(opts.includeTocDepth) ?? normalizeTocDepth(exportOptions.tocDepth) ?? undefined;
  const includeHeadlineNumbers =
    opts.includeHeadlineNumbers === true ||
    (opts.includeHeadlineNumbers !== false && exportOptions.num === true);
  const includeHeadlineNumberDepth =
    normalizeHeadlineNumberDepth(opts.includeHeadlineNumberDepth) ??
    normalizeHeadlineNumberDepth(exportOptions.numDepth) ??
    undefined;
  const includeDocumentHeader =
    opts.includeDocumentHeader === true ||
    (opts.includeDocumentHeader !== false && Boolean(findSubtitleFromKeywords(doc)));

  return {
    includeToc,
    includeTocDepth,
    includeHeadlineNumbers,
    includeHeadlineNumberDepth,
    includeDocumentHeader,
  };
}

function buildDocumentRenderContext(
  doc: DocumentNode,
  opts: {
    includeToc: boolean;
    sourcePath?: string;
    includeTocDepth?: number;
    includeHeadlineNumbers: boolean;
    includeHeadlineNumberDepth?: number;
    rewriteFileLinks?: boolean;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
    nativeInternalLinks?: boolean;
    profile?: "publish" | "app";
    charts?: OrgEmbeddedChart[];
    pluginRenders?: Org2PluginRender[];
    embedResolver?: LiveEmbedResolver;
    codeFile?: boolean;
  },
): { context: RenderContext; tocItems: TocItem[] } {
  let tocItems: TocItem[] = [];
  const includeHeadingAnchors = opts.includeToc || opts.rewriteFileLinks === true || nodesNeedHeadingAnchors(doc.children);
  const includeHeadlineData = includeHeadingAnchors || opts.includeHeadlineNumbers;
  const builtIns = buildBuiltInLinkAbbreviations(opts.linearTeam);
  const configAbbreviations = collectLinkAbbreviationsFromRecord(opts.linkAbbreviations);
  const documentAbbreviations = collectLinkAbbreviationsFromDoc(doc);

  const context: RenderContext = {
    rewriteFileLinks: opts.rewriteFileLinks === true,
    nativeInternalLinks: opts.nativeInternalLinks,
    profile: opts.profile,
    embedResolver: opts.embedResolver,
    sourcePath: opts.sourcePath,
    codeFile: opts.codeFile,
    // Reference-only clients (including the mobile JavaScriptCore bundle) have
    // no filesystem. Only a supplied resolver needs a canonical cycle key.
    embedStack: opts.embedResolver && opts.sourcePath ? [opts.embedResolver.sourceKey ?? `${path.resolve(opts.sourcePath)}:1`] : [],
    embedBudget: { remaining: 32, bytes: 1024 * 1024 },
    // Precedence: built-ins < config < document-local #+LINK
    linkAbbreviations: mergeLinkAbbreviations([builtIns, configAbbreviations, documentAbbreviations]),
  };

  if (opts.charts?.length) {
    context.chartsByTableLine = new Map();
    context.chartsByBlockLine = new Map();
    for (const chart of opts.charts) {
      if (chart.source.chartLine) context.chartsByBlockLine.set(chart.source.chartLine, chart);
      else context.chartsByTableLine.set(chart.source.line, chart);
    }
  }

  if (opts.pluginRenders?.length) {
    context.pluginRendersByBlockLine = new Map(opts.pluginRenders.map((render) => [render.source.line, render]));
  }

  if (includeHeadlineData) {
    const anchors = buildHeadlineAnchors(doc, {
      includeToc: opts.includeToc,
      includeTocDepth: opts.includeTocDepth,
      includeHeadlineNumbers: opts.includeHeadlineNumbers,
      includeHeadlineNumberDepth: opts.includeHeadlineNumberDepth,
    });
    tocItems = anchors.items;
    context.headlineIds = anchors.headlineIds;
    context.headlineSlugIds = anchors.headlineSlugIds;
    context.headlineNumbers = anchors.headlineNumbers;
  }

  return { context, tocItems };
}

function renderMainBody(opts: {
  doc: DocumentNode;
  context: RenderContext;
  includeToc: boolean;
  tocItems: TocItem[];
  includeDocumentHeader: boolean;
  title: string;
  subtitle?: string;
}): string {
  const appDocument = opts.context.profile === "app";
  const split = appDocument
    ? splitAppFileProperties(opts.doc.children)
    : { properties: [] as AppFileProperty[], body: opts.doc.children };
  const body = renderNodes(split.body, opts.context);
  const fileProperties = appDocument ? renderAppFileProperties(split.properties) : "";
  const tocHtml = opts.includeToc ? renderToc(opts.tocItems) : "";
  const documentHeader = opts.includeDocumentHeader
    ? renderDocumentHeader({ title: opts.title, subtitle: opts.subtitle })
    : "";

  return [documentHeader, fileProperties, tocHtml, body]
    .filter((segment) => String(segment || "").trim().length > 0)
    .join("\n");
}

function renderDocumentHtml(opts: {
  title: string;
  language: string;
  metadata: OrgExportMetadata;
  headIncludes?: string[];
  stylesheets?: string[];
  includeDefaultStyle?: boolean;
  includeToc: boolean;
  mainBody: string;
  preambleHtml?: string;
  postambleHtml?: string;
  compatContentWrapper?: boolean;
  includeDocumentHtml?: boolean;
}): string {
  const headMetaSection = renderHeadMetaSection(opts.metadata);
  const headExtraSection = renderHeadExtraSection(
    opts.metadata,
    opts.headIncludes,
    opts.includeDocumentHtml,
  );
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: [
      DEFAULT_DOCUMENT_STYLE,
      opts.mainBody.includes('class="org2-image"') ? DOCUMENT_IMAGE_STYLE : "",
      opts.includeToc ? DOCUMENT_TOC_STYLE : "",
    ].filter(Boolean).join("\n"),
  });

  const preambleSection = opts.preambleHtml ? `${opts.preambleHtml}
` : "";
  const postambleSection = opts.postambleHtml ? `${opts.postambleHtml}
` : "";
  const compatOpen = opts.compatContentWrapper ? COMPAT_CONTENT_OPEN : "";
  const compatClose = opts.compatContentWrapper ? COMPAT_CONTENT_CLOSE : "";
  const compatStyleSection = opts.compatContentWrapper ? COMPAT_CONTENT_STYLE_SECTION : "";

  return `<!doctype html>
<html lang="${escapeAttr(opts.language)}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(opts.title)}</title>
${headMetaSection}${headExtraSection}${headStyleSection}${compatStyleSection}</head>
<body>
${compatOpen}<main class="org2-document">
${preambleSection}${opts.mainBody}
</main>
${compatClose}${postambleSection}</body>
</html>
`;
}

export function renderOrgDocumentToHtml(
  doc: DocumentNode,
  opts: {
    title?: string;
    sourcePath?: string;
    stylesheets?: string[];
    includeDefaultStyle?: boolean;
    includeToc?: boolean;
    includeTocDepth?: number;
    includeHeadlineNumbers?: boolean;
    includeHeadlineNumberDepth?: number;
    rewriteFileLinks?: boolean;
    preambleHtml?: string;
    postambleHtml?: string;
    headIncludes?: string[];
    includeDocumentHeader?: boolean;
    compatContentWrapper?: boolean;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
    nativeInternalLinks?: boolean;
    profile?: "publish" | "app";
    charts?: OrgEmbeddedChart[];
    pluginRenders?: Org2PluginRender[];
    embedResolver?: LiveEmbedResolver;
    codeFile?: boolean;
  } = {},
): { html: string; title: string; metadata: OrgExportMetadata } {
  const title = resolveTitle(doc, opts.title, opts.sourcePath);
  const metadata = collectKeywordMetadata(doc);
  const renderOptions = resolveDocumentRenderOptions(doc, opts);
  const { context, tocItems } = buildDocumentRenderContext(doc, {
    includeToc: renderOptions.includeToc,
    includeTocDepth: renderOptions.includeTocDepth,
    includeHeadlineNumbers: renderOptions.includeHeadlineNumbers,
    includeHeadlineNumberDepth: renderOptions.includeHeadlineNumberDepth,
    rewriteFileLinks: opts.rewriteFileLinks,
    linkAbbreviations: opts.linkAbbreviations,
    linearTeam: opts.linearTeam,
    nativeInternalLinks: opts.nativeInternalLinks,
    profile: opts.profile,
    sourcePath: opts.sourcePath,
    charts: opts.charts,
    pluginRenders: opts.pluginRenders,
    embedResolver: opts.embedResolver,
    codeFile: opts.codeFile,
  });

  const mainBody = renderMainBody({
    doc,
    context,
    includeToc: renderOptions.includeToc,
    tocItems,
    includeDocumentHeader: renderOptions.includeDocumentHeader,
    title,
    subtitle: metadata.subtitle,
  });

  const html = renderDocumentHtml({
    title,
    language: metadata.language || "en",
    metadata,
    headIncludes: [
      ...(opts.headIncludes || []),
      opts.profile === "publish"
        ? `<style id="org2-publish-document-style">\n${APP_DOCUMENT_STYLE}${renderOptions.includeToc ? `\n${DOCUMENT_TOC_STYLE}` : ""}\n</style>`
        : "",
      opts.charts?.length && opts.profile !== "app" && opts.profile !== "publish"
        ? `<style id="org2-chart-style">\n${DOCUMENT_CHART_STYLE}\n</style>`
        : "",
    ].filter(Boolean),
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.profile === "publish" ? false : opts.includeDefaultStyle,
    includeToc: renderOptions.includeToc,
    mainBody,
    preambleHtml: String(opts.preambleHtml || "").trim(),
    postambleHtml: String(opts.postambleHtml || "").trim(),
    compatContentWrapper: opts.compatContentWrapper,
    includeDocumentHtml: opts.profile !== "app",
  });

  return { html, title, metadata };
}

export function renderOrgDocumentToAppHtml(
  doc: DocumentNode,
  opts: {
    title?: string;
    sourcePath?: string;
    linkAbbreviations?: LinkAbbreviationRecord;
    linearTeam?: string;
    customCss?: string;
    nativeInternalLinks?: boolean;
    charts?: OrgEmbeddedChart[];
    pluginRenders?: Org2PluginRender[];
    embedResolver?: LiveEmbedResolver;
    codeFile?: boolean;
  } = {},
): { html: string; title: string; metadata: OrgExportMetadata } {
  const customCss = String(opts.customCss || "").trim();
  const customStyle = customCss
    ? `<style id="org2-app-user-style">\n${customCss.replace(/<\/style/gi, "<\\/style")}\n</style>`
    : "";
  const rendered = renderOrgDocumentToHtml(doc, {
    title: opts.title,
    sourcePath: opts.sourcePath,
    includeDefaultStyle: false,
    includeToc: false,
    includeHeadlineNumbers: false,
    includeDocumentHeader: true,
    rewriteFileLinks: false,
    headIncludes: [
      `<meta name="org2-document-kind" content="${isPresentationDocument(doc) ? "slides" : "document"}" />`,
      `<style id="org2-app-document-style">\n${APP_DOCUMENT_STYLE}\n</style>`,
      `<style id="org2-app-code-style">\n${APP_CODE_HIGHLIGHT_STYLE}\n</style>`,
      `<script id="org2-app-document-script">\n${APP_DOCUMENT_SCRIPT}\n</script>`,
      opts.charts?.length ? `<script id="org2-chart-interaction">\n${CHART_INTERACTION_SCRIPT}\n</script>` : "",
      customStyle,
    ].filter(Boolean),
    linkAbbreviations: opts.linkAbbreviations,
    linearTeam: opts.linearTeam,
    nativeInternalLinks: opts.nativeInternalLinks,
    profile: "app",
    charts: opts.charts,
    pluginRenders: opts.pluginRenders,
    embedResolver: opts.embedResolver,
    codeFile: opts.codeFile,
  });
  return { ...rendered, html: collapseAppPgpArmorParagraphs(rendered.html) };
}

const APP_PGP_PARAGRAPH_RE = /<p\b([^>]*)>([\s\S]*?)<\/p>/g;

function appParagraphText(innerHtml: string): string {
  return innerHtml
    .replace(/<[^>]*>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .trim();
}

function appParagraphLine(attributes: string, name: "start" | "end"): number | null {
  const match = new RegExp(`data-org2-${name}-line="(\\d+)"`).exec(attributes);
  return match ? Number(match[1]) : null;
}

/**
 * The app preview shows an org-crypt armored block as one compact "Encrypted"
 * card instead of paragraphs of base64. Clicking the card asks the host app to
 * decrypt it into a temporary view; the card carries only source lines.
 */
export function collapseAppPgpArmorParagraphs(html: string): string {
  if (!html.includes("-----BEGIN PGP MESSAGE-----")) return html;
  const paragraphs = [...html.matchAll(APP_PGP_PARAGRAPH_RE)].map((match) => ({
    start: match.index ?? 0,
    end: (match.index ?? 0) + match[0].length,
    attributes: match[1] ?? "",
    text: appParagraphText(match[2] ?? ""),
  }));

  let out = "";
  let cursor = 0;
  for (let i = 0; i < paragraphs.length; i += 1) {
    const first = paragraphs[i]!;
    if (!/^-----BEGIN PGP MESSAGE-----(\s|$)/.test(first.text)) continue;
    let lastIndex = -1;
    for (let j = i; j < paragraphs.length; j += 1) {
      const candidate = paragraphs[j]!;
      if (j > i && html.slice(paragraphs[j - 1]!.end, candidate.start).trim() !== "") break;
      if (/(^|\s)-----END PGP MESSAGE-----$/.test(candidate.text)) {
        lastIndex = j;
        break;
      }
    }
    if (lastIndex < 0) continue;
    const last = paragraphs[lastIndex]!;
    const startLine = appParagraphLine(first.attributes, "start");
    const endLine = appParagraphLine(last.attributes, "end") ?? startLine;
    const lineAttributes = startLine
      ? ` data-org2-start-line="${startLine}" data-org2-end-line="${endLine ?? startLine}"`
      : "";
    out += html.slice(cursor, first.start);
    out +=
      `<div class="org2-encrypted" role="button" tabindex="0" data-org2-encrypted="true"${lineAttributes} title="View decrypted text without changing the file">` +
      `<span class="org2-encrypted-icon" aria-hidden="true">&#128274;</span>` +
      `<span class="org2-encrypted-label">Encrypted</span>` +
      `<span class="org2-encrypted-action">View</span>` +
      `</div>`;
    cursor = last.end;
    i = lastIndex;
  }
  return out + html.slice(cursor);
}

export type OrgExportIndexItem = {
  title: string;
  href: string;
  sourcePath?: string;
};

export function renderOrgExportIndexToHtml(opts: {
  title?: string;
  sourcePath?: string;
  items: OrgExportIndexItem[];
  stylesheets?: string[];
  headIncludes?: string[];
  includeDefaultStyle?: boolean;
}): { html: string; title: string } {
  const title = String(opts.title || "").trim() || (opts.sourcePath ? path.basename(opts.sourcePath) : "Celorga Export Index");
  const items = Array.isArray(opts.items) ? opts.items : [];

  const listHtml = items
    .map((item) => {
      const itemTitle = String(item.title || "").trim() || String(item.href || "").trim() || "Untitled";
      const href = String(item.href || "").trim() || "#";
      const source = String(item.sourcePath || "").trim();
      const sourceHtml = source ? ` <span class="org2-export-source">(${escapeHtml(source)})</span>` : "";
      return `<li><a href="${escapeAttr(href)}">${escapeHtml(itemTitle)}</a>${sourceHtml}</li>`;
    })
    .join("\n");

  const body = listHtml || "<li>No exported files.</li>";
  const headStyleSection = renderHeadStyleSection({
    stylesheets: opts.stylesheets,
    includeDefaultStyle: opts.includeDefaultStyle,
    defaultStyle: DEFAULT_INDEX_STYLE,
  });
  const headExtraSection = renderHeadExtraSection({}, opts.headIncludes, false);
  const titleId = slugifyHeadlineTitle(title);

  const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<meta name="viewport" content="width=device-width, initial-scale=1" />\n<title>${escapeHtml(title)}</title>\n${headExtraSection}${headStyleSection}</head>\n<body>\n<main id="content" class="content org2-export-index-document">\n<h1 id="${escapeAttr(titleId)}">${escapeHtml(title)}</h1>\n<ul class="org2-export-index">\n${body}\n</ul>\n</main>\n</body>\n</html>\n`;

  return { html, title };
}
