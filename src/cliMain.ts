#!/usr/bin/env node
import { renderCaptureEntry } from "./captureEntry.js";

import {
  normalizeRoamLinkLabel,
  parseRoamAliasTokens,
  type RoamLinkifyCandidate,
  type RoamLinkifyFileResult,
  type RoamGraphNode,
  type RoamGraphData,
  buildRoamTitleIndex,
  buildRoamLinkifyIndex,
  findRoamIdLinksInLine,
  findRoamWikiLinksInLine,
  readRoamSourceStructure,
  buildRoamGraph,
  renderRoamLink,
  applyRoamLinkifyToFile,
} from "./roam.js";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import crypto from "node:crypto";
import os from "node:os";
import { spawnSync } from "node:child_process";
import { buildUnifiedDiff } from "./unifiedDiff.js";
import { parseOrgToCanonicalAst } from "./parser.js";
import { canonicalizeOrgSyntaxSugar } from "./canonicalOrg.js";
import { printCanonicalAstToOrg } from "./printer.js";
import { normalizePgpArmorForDecrypt, protectPgpBlocks, restorePgpBlocks } from "./pgp.js";
import {
  findConfigFile,
  loadConfig,
  resolveFilesFromConfig,
  resolveFilesFromDir,
  resolveRoamDailiesRootDir,
  type Org2Config,
  type Org2PublishProjectConfig,
} from "./config.js";
import {
  isDefaultArchivePath,
  isDefaultIgnoredSyncArtifactPath,
  isOrgLikeFileName,
  listOrgLikeFiles,
} from "./corpusFiles.js";
import { resolvePublishHeadIncludes } from "./publish-defaults.js";
import { documentTodoSequences, todoSequencesForFile, todoConfigurationKey, todoKeywordInWorkflow, type TodoSequence, assignTodoInText, formatOrgTimestamp, isActiveTodoKeyword, isTerminalTodoKeyword, normalizeTodoKeyword, TODO_KEYWORDS, updateTodoInText, type TodoStatus } from "./todo.js";
import { planningKindFromArg, updatePlanningInText, type PlanningKindArg } from "./planning.js";
import { computeSubtreeRange, findHeadingAtOrAbove, isHeadlineLine, upsertHeadlinePropertyInLines } from "./sourceLines.js";
import { findBacklinksInText, type Backlink } from "./backlinks.js";
import { renderOrgDocumentToHtml, renderOrgExportIndexToHtml } from "./export.js";
import { renderPresentationToBeamer } from "./presentation.js";
import { compileBeamerPdf } from "./beamerCompile.js";
import { compileCorpus, compileCorpusIncremental, extractOwnedCheckboxIssues, renderCompiledCorpus } from "./corpusCompile.js";
import { queryNodeActions } from "./nodeActions.js";
import { extractClockReport } from "./clock.js";
import { buildAgentContextPayload, isStaleOpenAgentTodo, renderAgentContextPack, type AgentInclude } from "./agentContext.js";
import { buildOrg2CapabilityManifest } from "./capabilities.js";
import {
  agentRunApprovalDecisionKeys,
  agentRunPath,
  currentAgentRunApprovalBoundary,
  loadAgentRun,
  listAgentRunsWithApprovals,
  type AgentRun,
} from "./agentRun.js";
import { renderOrgChart, renderOrgCharts } from "./chartRender.js";
import {
  buildSearchIndex,
  loadCompatibleSearchIndex,
  loadFreshSearchIndex,
  searchFilesByScan,
  searchIndexedCorpus,
  searchPayload,
  updateSearchIndex,
  writeSearchIndex,
  type Org2SearchIndex,
  type Org2SearchIndexBuildResult,
  type Org2SearchHit,
  type Org2SearchOptions,
  type Org2SearchResultPayload,
} from "./searchIndex.js";
import { loadAiJobManifest, validateAiJobManifest } from "./aiJobManifest.js";
import { createAiAdapterRequest, MockAiAdapter, type AiAdapterContextItem, type AiAdapterResponse } from "./aiAdapter.js";
import { buildGeneratedArtifactMetadata, formatOrg2ArtifactPropertyDrawer, sha256Hex, updateArtifactReviewStatusInText } from "./artifactMetadata.js";
import { defaultCorpusCachePath, org2CorpusIndexDir, org2IndexHome } from "./indexPaths.js";
import { ingestDemoSource, type Org2RawCaptureInput } from "./ingestionPipeline.js";
import { readStdinText } from "./stdin.js";
import { parseHeadlineTitleForRoam } from "./headlineTitle.js";
import { formatOrgDateTimestamp, parseIsoCalendarDate } from "./calendarDate.js";
import { parseTimestampRepeater, parseTimestampWarning } from "./timestampModifiers.js";
import type { TimestampRepeater, TimestampWarning } from "./ast.js";
import {
  collectArtifactPropertyDrawersInText,
  collectArtifactIdsInText,
  collectArtifactProvenanceRefsInText,
  findDuplicateArtifactIds,
  lintArtifactMetadataInText,
  parseArtifactSourceHashEntry,
  type ArtifactLintIssue,
} from "./artifactLint.js";
import type {
  DocumentNode,
  HeadlineNode,
  InlineNode,
  Node,
  PlanningNode,
  PropertyDrawerNode,
} from "./ast.js";
import { brandEnv, brandProperty, nameAliases, withNameAliases } from "./brandNames.js";

function org2PackageVersion(): string {
  const packageUrl = new URL("../package.json", import.meta.url);
  const metadata = JSON.parse(fs.readFileSync(packageUrl, "utf8")) as { version?: unknown };
  if (typeof metadata.version !== "string" || !metadata.version.trim()) {
    throw new Error(`package metadata at ${packageUrl.pathname} does not declare a version`);
  }
  return metadata.version;
}

function embeddedChartsForSource(raw: string, file?: string) {
  return renderOrgCharts(raw, { file })
    .filter((chart): chart is typeof chart & { svg: string; source: NonNullable<typeof chart.source> } => chart.ok && Boolean(chart.svg && chart.source))
    .map((chart) => ({ svg: chart.svg, source: chart.source, presentation: chart.presentation }));
}

let pluginRuntimePromise: Promise<typeof import("./pluginRuntime.js")> | undefined;

async function pluginRendersForDocument(document: DocumentNode, sourcePath: string) {
  pluginRuntimePromise ||= import("./pluginRuntime.js");
  const runtime = await pluginRuntimePromise;
  return runtime.renderPluginSourceBlocks(document, { sourcePath }).renders;
}

function parseIsoDate(dateStr: string): Date {
  const parsed = parseIsoCalendarDate(dateStr);
  if (!parsed) {
    throw new Error(`Invalid date format: ${dateStr}`);
  }
  return parsed.date;
}

// Parse timestamp like "<2026-01-17 Sat>"
function extractDateFromTimestamp(raw: string): string | null {
  const match = raw.match(/(\d{4})-(\d{2})-(\d{2})/);
  return match ? match[0] : null;
}

function normalizeAgendaTimeToken(raw: string): string | null {
  const match = String(raw || "").match(/(?:^|\s)(\d{1,2}):(\d{2})(?=[^0-9]|$)/);
  if (!match) return null;

  const hour = Number.parseInt(match[1] ?? "", 10);
  const minute = Number.parseInt(match[2] ?? "", 10);

  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function parseAgendaTimeToMinutes(raw: string | undefined): number | null {
  const normalized = normalizeAgendaTimeToken(String(raw || ""));
  if (!normalized) return null;

  const [hourRaw, minuteRaw] = normalized.split(":");
  const hour = Number.parseInt(hourRaw || "", 10);
  const minute = Number.parseInt(minuteRaw || "", 10);

  if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
  return hour * 60 + minute;
}

function extractTimeFromTimestamp(raw: string): string | undefined {
  const normalized = normalizeAgendaTimeToken(raw);
  return normalized || undefined;
}

type ExportMetadataPayload = {
  author?: string;
  date?: string;
  subtitle?: string;
  description?: string;
  keywords?: string[];
  language?: string;
  htmlHead?: string[];
};


function renderBriefing(payload: ReturnType<typeof buildAgentContextPayload>, title: string, format: "markdown" | "org" = "markdown"): string {
  const isOrg = format === "org";
  const h1 = isOrg ? "*" : "#";
  const h2 = isOrg ? "**" : "##";
  const generatedAt = new Date().toISOString();
  const lines: string[] = [];
  const reviewRequired = payload.results.some((node) => node.claimState.reviewStatus !== "reviewed" && node.claimState.reviewStatus !== "promoted");
  const cited = payload.results.slice(0, 8);
  const glanceNodes = [
    ...cited.filter((node) => !(node.todoTerminal ?? isTerminalTodoKeyword(node.todo))),
    ...cited.filter((node) => node.todoTerminal ?? isTerminalTodoKeyword(node.todo)),
  ].slice(0, 5);

  lines.push(`${h1} ${title}`);
  lines.push("");
  lines.push(`- Generated: ${generatedAt}`);
  lines.push(`- Corpus: ${payload.corpus.rootDir}`);
  lines.push(`- Review: ${reviewRequired ? "REVIEW REQUIRED for generated synthesis and any unreviewed/stale cited claims." : "Source-backed; verify before external use."}`);
  lines.push("");
  lines.push(`${h2} At a glance`);
  if (cited.length === 0) lines.push("- No matching notes found.");
  for (const node of glanceNodes) {
    const status = `${node.claimState.reviewStatus}/${node.claimState.freshness}`;
    lines.push(`- ${node.todo ? `${node.todo} ` : ""}${node.title} — ${status} [${node.citation}]`);
  }
  lines.push("");
  lines.push(`${h2} Source-backed notes`);
  if (cited.length === 0) lines.push("- None");
  for (const node of cited) {
    lines.push(`- ${node.title} [${node.citation}]`);
    if (node.selectionReason?.length) lines.push(`  - Why included: ${node.selectionReason.join("; ")}`);
    const snippet = String(node.snippet || "").replace(/\s+/g, " ").trim();
    if (snippet) lines.push(`  - Evidence: ${snippet.slice(0, 240)}${snippet.length > 240 ? "…" : ""}`);
    lines.push(`  - Review/freshness: ${node.claimState.reviewStatus}/${node.claimState.freshness}`);
  }
  lines.push("");
  lines.push(`${h2} Review-required synthesis`);
  if (cited.length === 0) lines.push("- [review-required] Broaden the query/scope or add source notes before drawing conclusions.");
  else {
    lines.push("- [review-required] Treat this briefing as a navigational summary, not canonical truth.");
    const active = cited.filter((node) => isActiveTodoKeyword(node.todo) && !isStaleOpenAgentTodo(node)).slice(0, 5);
    if (active.length) lines.push(`- [review-required] Active work surfaced: ${active.map((node) => `${node.todo} ${node.title} [${node.citation}]`).join("; ")}.`);
    const staleOpen = cited.filter((node) => isStaleOpenAgentTodo(node)).slice(0, 5);
    if (staleOpen.length) lines.push(`- [review-required] Possible stale open work: ${staleOpen.map((node) => `${node.todo} ${node.title} [${node.citation}]`).join("; ")}.`);
    const stale = cited.filter((node) => node.claimState.freshness === "stale" || node.claimState.freshness === "expired");
    if (stale.length) lines.push(`- [review-required] Refresh stale/expired sources before relying on: ${stale.map((node) => `${node.title} [${node.citation}]`).join("; ")}.`);
  }
  lines.push("");
  lines.push(`${h2} Citations`);
  if (cited.length === 0) lines.push("- None");
  for (const node of cited) lines.push(`- ${node.citation} — ${node.title}`);
  lines.push("");
  return lines.join("\n");
}

function isOperationalNodeBriefFile(file: string): boolean {
  const normalized = file.replace(/\\/g, "/").toLowerCase();
  return normalized.startsWith("agents/")
    || normalized.startsWith("views/")
    || normalized.includes("/agents/")
    || normalized.includes("/views/")
    || normalized.includes("sync-conflict")
    || normalized.includes("generated")
    || normalized.includes("brief");
}

function renderNodeBriefing(payload: ReturnType<typeof buildAgentContextPayload>, title: string, format: "markdown" | "org" = "markdown"): string {
  const isOrg = format === "org";
  const h1 = isOrg ? "*" : "#";
  const h2 = isOrg ? "**" : "##";
  const h3 = isOrg ? "***" : "###";
  const generatedAt = new Date().toISOString();
  const node = payload.results[0];
  const lines: string[] = [];

  lines.push(`${h1} ${title}`);
  lines.push("");
  lines.push(`- Generated: ${generatedAt}`);
  lines.push(`- Corpus: ${payload.corpus.rootDir}`);
  lines.push("- Review: REVIEW REQUIRED for generated synthesis and any unreviewed/stale cited claims.");
  if (payload.id) lines.push(`- ID: ${payload.id}`);
  lines.push("");

  if (!node) {
    lines.push(`${h2} Node`);
    lines.push("- No node found for the requested ID.");
    if (payload.errors.length) {
      lines.push("");
      lines.push(`${h2} Errors`);
      for (const err of payload.errors) lines.push(`- ${err}`);
    }
    lines.push("");
    return lines.join("\n");
  }

  const backlinks = Array.from(
    new Map((node.backlinks || []).map((backlink) => [`${backlink.file}:${backlink.line}`, backlink])).values(),
  );
  const neighbors = node.neighbors || [];
  const backlinkFiles = new Set(backlinks.map((link) => link.file));
  const backlinkGroups = Array.from(
    backlinks.reduce((groups, backlink) => {
      const existing = groups.get(backlink.file) || [];
      existing.push(backlink);
      groups.set(backlink.file, existing);
      return groups;
    }, new Map<string, NonNullable<typeof node.backlinks>>()),
  ).sort((a, b) => (b[1].length - a[1].length) || a[0].localeCompare(b[0]));
  const primaryBacklinkGroups = backlinkGroups.filter(([file]) => !isOperationalNodeBriefFile(file));
  const operationalBacklinkGroups = backlinkGroups.filter(([file]) => isOperationalNodeBriefFile(file));
  const renderBacklinkGroup = ([file, items]: [string, NonNullable<typeof node.backlinks>]) => {
    lines.push(`${h3} ${file} (${items.length})`);
    for (const backlink of items.slice(0, 5)) {
      lines.push(`- ${backlink.sourceTitle} [${backlink.citation}]`);
    }
    if (items.length > 5) lines.push(`- ... ${items.length - 5} more reference${items.length - 5 === 1 ? "" : "s"} in this file`);
    lines.push("");
  };

  lines.push(`${h2} At a glance`);
  lines.push(`- Node: ${node.title} [${node.citation}]`);
  if (node.todo) lines.push(`- TODO: ${node.todo}`);
  if (node.tags.length) lines.push(`- Tags: ${node.tags.join(", ")}`);
  lines.push(`- Backlinks: ${backlinks.length} reference${backlinks.length === 1 ? "" : "s"} across ${backlinkFiles.size} file${backlinkFiles.size === 1 ? "" : "s"}`);
  lines.push(`- Neighbors: ${neighbors.length}`);
  lines.push(`- Review/freshness: ${node.claimState.reviewStatus}/${node.claimState.freshness}`);
  lines.push("");

  lines.push(`${h2} Selected source`);
  lines.push(`- Citation: ${node.citation}`);
  const snippet = String(node.snippet || "").trim();
  lines.push(snippet ? snippet : "- No snippet available.");
  lines.push("");

  lines.push(`${h2} Referencing files`);
  if (primaryBacklinkGroups.length === 0) {
    lines.push("- No backlinks found.");
  } else {
    for (const group of primaryBacklinkGroups.slice(0, 24)) renderBacklinkGroup(group);
    if (primaryBacklinkGroups.length > 24) lines.push(`- ... ${primaryBacklinkGroups.length - 24} more primary referencing file${primaryBacklinkGroups.length - 24 === 1 ? "" : "s"}.`);
  }

  lines.push(`${h2} Operational and generated references`);
  if (operationalBacklinkGroups.length === 0) {
    lines.push("- None found.");
  } else {
    const count = operationalBacklinkGroups.reduce((sum, [, items]) => sum + items.length, 0);
    lines.push(`- ${count} reference${count === 1 ? "" : "s"} across ${operationalBacklinkGroups.length} operational/generated file${operationalBacklinkGroups.length === 1 ? "" : "s"}.`);
    for (const group of operationalBacklinkGroups.slice(0, 8)) renderBacklinkGroup(group);
    if (operationalBacklinkGroups.length > 8) lines.push(`- ... ${operationalBacklinkGroups.length - 8} more operational/generated file${operationalBacklinkGroups.length - 8 === 1 ? "" : "s"}.`);
  }

  lines.push(`${h2} Related nodes`);
  if (neighbors.length === 0) {
    lines.push("- None found.");
  } else {
    for (const neighbor of neighbors.slice(0, 24)) {
      lines.push(`- ${neighbor.direction}: ${neighbor.title} [${neighbor.citation}]`);
    }
    if (neighbors.length > 24) lines.push(`- ... ${neighbors.length - 24} more related node${neighbors.length - 24 === 1 ? "" : "s"}.`);
  }
  lines.push("");

  lines.push(`${h2} Briefing prompt`);
  lines.push("- [review-required] Summarize this node using the selected source, referencing files, and related nodes above.");
  lines.push("- [review-required] Cite file:line provenance for concrete claims.");
  lines.push("- [review-required] Treat backlinks as computed context; do not write generated backlinks sections into notes.");
  lines.push("");
  return lines.join("\n");
}

function hasExportMetadata(metadata: ExportMetadataPayload | null | undefined): boolean {
  if (!metadata) return false;
  return Boolean(
    metadata.author ||
      metadata.date ||
      metadata.subtitle ||
      metadata.description ||
      metadata.language ||
      (Array.isArray(metadata.keywords) && metadata.keywords.length > 0) ||
      (Array.isArray(metadata.htmlHead) && metadata.htmlHead.length > 0),
  );
}

function daysInUtcMonth(year: number, monthZeroBased: number): number {
  return new Date(Date.UTC(year, monthZeroBased + 1, 0)).getUTCDate();
}

function addMonthsUtcClamped(date: Date, monthDelta: number): Date {
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth();
  const day = date.getUTCDate();

  const totalMonths = year * 12 + month + monthDelta;
  const targetYear = Math.floor(totalMonths / 12);
  const targetMonth = ((totalMonths % 12) + 12) % 12;
  const targetDay = Math.min(day, daysInUtcMonth(targetYear, targetMonth));

  return new Date(
    Date.UTC(
      targetYear,
      targetMonth,
      targetDay,
      date.getUTCHours(),
      date.getUTCMinutes(),
      date.getUTCSeconds(),
      date.getUTCMilliseconds(),
    ),
  );
}

function addYearsUtcClamped(date: Date, yearDelta: number): Date {
  const targetYear = date.getUTCFullYear() + yearDelta;
  const targetMonth = date.getUTCMonth();
  const targetDay = Math.min(date.getUTCDate(), daysInUtcMonth(targetYear, targetMonth));

  return new Date(
    Date.UTC(
      targetYear,
      targetMonth,
      targetDay,
      date.getUTCHours(),
      date.getUTCMinutes(),
      date.getUTCSeconds(),
      date.getUTCMilliseconds(),
    ),
  );
}

function addTimestampInterval(
  date: Date,
  value: number,
  unit: "d" | "w" | "m" | "y",
  direction: 1 | -1,
): Date {
  const next = new Date(date.getTime());
  const signedValue = direction * value;

  switch (unit) {
    case "d":
      next.setUTCDate(next.getUTCDate() + signedValue);
      break;
    case "w":
      next.setUTCDate(next.getUTCDate() + signedValue * 7);
      break;
    case "m":
      return addMonthsUtcClamped(date, signedValue);
    case "y":
      return addYearsUtcClamped(date, signedValue);
  }

  return next;
}

function addRepeaterInterval(date: Date, repeater: TimestampRepeater): Date {
  // For agenda projection we treat +, ++, and .+ as fixed intervals from the
  // timestamp date and expand occurrences that fall within the requested range.
  return addTimestampInterval(date, repeater.value, repeater.unit, 1);
}

function subtractWarningInterval(date: Date, warning: TimestampWarning): Date {
  return addTimestampInterval(date, warning.value, warning.unit, -1);
}

function addWarningInterval(date: Date, warning: TimestampWarning): Date {
  return addTimestampInterval(date, warning.value, warning.unit, 1);
}

function formatIsoDateUtc(date: Date): string {
  const year = String(date.getUTCFullYear());
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function resolveAgendaDatesFromTimestamp(
  raw: string,
  startDate: Date,
  endDate: Date,
  wantsOverdue: boolean,
  planningKind: "SCHEDULED" | "DEADLINE",
): string[] {
  const dateStr = extractDateFromTimestamp(raw);
  if (!dateStr) return [];

  const firstDate = parseIsoDate(dateStr);
  const repeater = parseTimestampRepeater(raw);
  const warning = parseTimestampWarning(raw);

  const seen = new Set<string>();
  const resolved: string[] = [];
  let latestBeforeStart: Date | null = null;

  const addResolved = (date: Date): void => {
    const iso = formatIsoDateUtc(date);
    if (seen.has(iso)) return;
    seen.add(iso);
    resolved.push(iso);
  };

  const consider = (date: Date): void => {
    if (date >= startDate && date <= endDate) {
      addResolved(date);
      return;
    }

    if (date < startDate && (!latestBeforeStart || date.getTime() > latestBeforeStart.getTime())) {
      latestBeforeStart = new Date(date.getTime());
    }
  };

  const considerOccurrence = (occurrenceDate: Date, occurrenceIndex: number): void => {
    if (planningKind === "SCHEDULED") {
      let scheduledDate = occurrenceDate;
      if (warning) {
        const warningApplies = warning.mode === "-" || !repeater || occurrenceIndex === 0;
        if (warningApplies) {
          scheduledDate = addWarningInterval(occurrenceDate, warning);
        }
      }
      consider(scheduledDate);
      return;
    }

    consider(occurrenceDate);

    if (!warning) return;
    const warningDate = subtractWarningInterval(occurrenceDate, warning);

    if (warning.mode === "--") {
      if (warningDate < startDate) {
        const latestWindowBeforeStart = occurrenceDate < startDate
          ? new Date(occurrenceDate.getTime())
          : addTimestampInterval(startDate, 1, "d", -1);
        if (latestWindowBeforeStart.getTime() >= warningDate.getTime()) {
          consider(latestWindowBeforeStart);
        }
      }

      const inRangeStartMs = Math.max(warningDate.getTime(), startDate.getTime());
      const inRangeEndMs = Math.min(occurrenceDate.getTime(), endDate.getTime());
      if (inRangeStartMs <= inRangeEndMs) {
        let cursorDate = new Date(inRangeStartMs);
        while (cursorDate.getTime() <= inRangeEndMs) {
          consider(cursorDate);
          cursorDate = addTimestampInterval(cursorDate, 1, "d", 1);
        }
      }
      return;
    }

    consider(warningDate);
  };

  if (!repeater) {
    considerOccurrence(firstDate, 0);
    if (wantsOverdue && latestBeforeStart) addResolved(latestBeforeStart);
    return resolved.sort();
  }

  const maxIterations = 10000;
  let cursor = new Date(firstDate.getTime());
  let occurrenceIndex = 0;

  for (let i = 0; i < maxIterations && cursor < startDate; i += 1) {
    considerOccurrence(cursor, occurrenceIndex);
    occurrenceIndex += 1;

    const next = addRepeaterInterval(cursor, repeater);
    if (next.getTime() <= cursor.getTime()) break;
    cursor = next;
  }

  const repeatUpperBound = warning && planningKind === "DEADLINE"
    ? addTimestampInterval(endDate, warning.value, warning.unit, 1)
    : new Date(endDate.getTime());

  for (let i = 0; i < maxIterations && cursor <= repeatUpperBound; i += 1) {
    considerOccurrence(cursor, occurrenceIndex);
    occurrenceIndex += 1;

    const next = addRepeaterInterval(cursor, repeater);
    if (next.getTime() <= cursor.getTime()) break;
    cursor = next;
  }

  if (wantsOverdue && latestBeforeStart) {
    addResolved(latestBeforeStart);
  }

  return resolved.sort();
}

export const DEFAULT_AGENDA_DEADLINE_WARNING_DAYS = 14;

/**
 * Emacs Org shows an upcoming deadline on today's agenda during its warning
 * period ("In 6 d.:"), even when the task is not scheduled. The warning period
 * comes from the timestamp's own `-Nd` cookie, or `defaultWarningDays` when it
 * has none. Deadlines due on or before `startDate` (today) are already shown
 * as today or overdue, so they get no warning copy.
 */
export function agendaDeadlineWarningForStart(
  raw: string,
  startDate: Date,
  defaultWarningDays: number,
): AgendaDeadlineWarning | null {
  const dateStr = extractDateFromTimestamp(raw);
  if (!dateStr) return null;
  let occurrence = parseIsoDate(dateStr);
  const repeater = parseTimestampRepeater(raw);
  const warning = parseTimestampWarning(raw);
  if (repeater) {
    for (let i = 0; i < 10000 && occurrence.getTime() <= startDate.getTime(); i += 1) {
      const next = addRepeaterInterval(occurrence, repeater);
      if (next.getTime() <= occurrence.getTime()) break;
      occurrence = next;
    }
  }
  if (occurrence.getTime() <= startDate.getTime()) return null;

  let warningStart: Date;
  if (warning) {
    warningStart = subtractWarningInterval(occurrence, warning);
  } else if (defaultWarningDays > 0) {
    warningStart = addTimestampInterval(occurrence, defaultWarningDays, "d", -1);
  } else {
    return null;
  }
  if (warningStart.getTime() > startDate.getTime()) return null;

  const daysUntil = Math.round((occurrence.getTime() - startDate.getTime()) / (24 * 60 * 60 * 1000));
  return { due: formatIsoDateUtc(occurrence), daysUntil };
}

function agendaItemKindLabel(item: ScheduledItem): string {
  const warning = item.deadlineWarning;
  if (!warning) return item.kind;
  return `${item.kind} in ${warning.daysUntil} d. ${warning.due}`;
}

// Get today's date as YYYY-MM-DD string
function getTodayString(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

type RoamGraphMaintenanceLinkFinding = {
  rule: "unresolved-id-link" | "unresolved-wiki-link" | "ambiguous-wiki-link";
  severity: "warning";
  file: string;
  line: number;
  target: string;
  message: string;
  candidates?: string[];
};

type RoamGraphMaintenanceAliasCollision = {
  label: string;
  nodes: Array<{ id: string; label: string; file: string }>;
};

type RoamGraphMaintenanceLinkifySuggestion = {
  kind: "exact" | "represented-node";
  file: string;
  line: number;
  lineEnd?: number;
  sourceRange?: { startLine: number; endLine: number };
  sourceKind?: "line" | "paragraph";
  label: string;
  candidate: string;
  count?: number;
  confidence?: number;
  reason: string;
  text?: string;
  evidence?: string[];
};

type RoamGraphMaintenanceReport = {
  summary: {
    scannedFiles: number;
    nodeCount: number;
    edgeCount: number;
    orphanNodeCount: number;
    aliasCollisionCount: number;
    unresolvedLinkCount: number;
    ambiguousLinkCount: number;
    linkifySuggestionCount: number;
  };
  orphanNodes: RoamGraphNode[];
  highDegreeNodes: RoamGraphNode[];
  aliasCollisions: RoamGraphMaintenanceAliasCollision[];
  linkFindings: RoamGraphMaintenanceLinkFinding[];
  linkifySuggestions: RoamGraphMaintenanceLinkifySuggestion[];
};

type GraphAuditFinding = {
  type: "broken-link" | "orphan-note" | "duplicate-id" | "duplicate-entity" | "stale-generated-artifact";
  severity: "error" | "warning" | "info";
  file: string;
  line?: number;
  id?: string;
  target?: string;
  label?: string;
  rule: string;
  explanation: string;
  deterministicFix?: string;
  reviewSuggestion?: string;
  related?: unknown;
};

type GraphAuditReport = {
  $schema: "org2:graph-audit:v1";
  summary: {
    scannedFiles: number;
    nodeCount: number;
    edgeCount: number;
    findingCount: number;
    errorCount: number;
    warningCount: number;
    infoCount: number;
  };
  findings: GraphAuditFinding[];
};

type ApprovalQueueItem = {
  kind: "headline" | "run";
  title: string;
  status: string;
  todo: string | null;
  level: number | null;
  file: string;
  line: number;
  idValue: string | null;
  properties: Record<string, string>;
  body: string;
  tags: string[];
  approvalId?: string;
  fingerprint?: string;
  action?: string;
  riskClass?: string;
  requestedRole?: string;
  requestedFrom?: string;
  requestedAt?: string;
  runId?: string;
  runGoal?: string;
  runStatus?: string;
  runPendingApprovalCount?: number;
  runApprovalCount?: number;
  runDecisionEffect?: string;
  decisionKeys?: string[];
  priority?: string;
};

type ApprovalQueuePayload = {
  $schema: "org2:approvals:v2";
  count: number;
  index?: {
    mode: "auto" | "current" | "never" | "rebuild";
    used: boolean;
    path?: string;
    builtAt?: string;
    stale?: boolean;
    rebuilt?: boolean;
  };
  skippedCandidates?: number;
  items: ApprovalQueueItem[];
  runDetails?: AgentRun[];
};

type ApprovalQueueCandidate = {
  item: ApprovalQueueItem;
  decisionKeys: string[];
  requestedAt?: string;
  isPending: boolean;
};

type SourceRange = { startLine: number; endLine: number };
type SourceRangedHeadlineNode = HeadlineNode & { sourceRange?: SourceRange };
type SourceRangedPropertyDrawerNode = PropertyDrawerNode & { sourceRange?: SourceRange };
type SourceRangedPlanningNode = PlanningNode & { sourceRange?: SourceRange };

type ApprovalCandidateSource = {
  file: string;
  sourceText: string;
  parseText: string;
  sourceLineOffset: number;
};

const APPROVAL_STATUS_NEEDLES = [
  "review-required",
  "requires-review",
  "approval-required",
  "needs-approval",
  "need-approval",
  "needs-review",
  "need-review",
  "pending-review",
  "pending-approval",
  "require-approval",
  "waiting-on-approval",
  "draft-needs-review",
  "draft-needs-approval",
  "reply-review",
  "needs-avi",
  "avi-approval",
  "needs-human",
  "human-review",
  "generated",
  "draft",
] as const;

function approvalHeadingLevel(line: string): number | null {
  const match = /^(\*+)\s+/.exec(line);
  return match ? match[1]!.length : null;
}

function firstApprovalHeadingIndex(lines: string[], afterIndex: number, maxLevel?: number): number | null {
  for (let index = afterIndex + 1; index < lines.length; index += 1) {
    const level = approvalHeadingLevel(lines[index] || "");
    if (level === null) continue;
    if (maxLevel === undefined || level <= maxLevel) return index;
  }
  return null;
}

function containsApprovalSignal(raw: string): boolean {
  const normalized = raw.toLowerCase();
  return normalized.includes("approval")
    || normalized.includes("approve")
    || normalized.includes("review")
    || normalized.includes("avi");
}

function approvalTextHasHumanApprovalTitle(normalizedText: string): boolean {
  return /(?:^|\n)\*+\s+(?:(?:todo|in_progress|prog|wait|hold|paused)\s+)?(?:\[#[a-z0-9]\]\s+)?(?:approve|review|review\/|review-send|review and approve|review\/approve)\b/i.test(normalizedText);
}

function approvalCandidateTextMayContainItem(raw: string): boolean {
  const normalized = raw.toLowerCase();
  if (!normalized.includes(":")) return false;

  const hasHumanApprovalTitle = approvalTextHasHumanApprovalTitle(normalized);
  const hasPendingStatus = APPROVAL_STATUS_NEEDLES.some((needle) => normalized.includes(needle));
  const hasSpecificReviewStatusKey = [
    ":celorga_review_status:",
    ":org2_review_status:",
    ":review_status:",
    ":review:",
    ":followup_status:",
    ":reply_status:",
  ].some((needle) => normalized.includes(needle));
  if (hasSpecificReviewStatusKey && hasPendingStatus && hasHumanApprovalTitle) return true;

  if (normalized.includes(":status:") && hasPendingStatus && hasHumanApprovalTitle) return true;

  const hasGateKey = [
    ":waiting_on:",
    ":blocked_by:",
    ":celorga_waiting_on:",
    ":org2_waiting_on:",
    ":next_action:",
    ":action_required:",
    ":celorga_next_action:",
    ":org2_next_action:",
    ":handoff_summary:",
    ":celorga_handoff_summary:",
    ":org2_handoff_summary:",
  ].some((needle) => normalized.includes(needle));
  if (hasGateKey && containsApprovalSignal(normalized)) return true;

  const hasAccessPolicyKey = [
    ":access_policy:",
    ":review_policy:",
  ].some((needle) => normalized.includes(needle));
  return hasAccessPolicyKey && (hasPendingStatus || containsApprovalSignal(normalized));
}

function mergedApprovalCandidateRanges(ranges: Array<[number, number]>): Array<[number, number]> {
  const sorted = [...ranges].sort((lhs, rhs) => (lhs[0] - rhs[0]) || (lhs[1] - rhs[1]));
  const merged: Array<[number, number]> = [];
  for (const range of sorted) {
    const last = merged[merged.length - 1];
    if (!last) {
      merged.push(range);
      continue;
    }
    if (range[0] <= last[1]) {
      last[1] = Math.max(last[1], range[1]);
    } else {
      merged.push(range);
    }
  }
  return merged;
}

function isApprovalIndexableFilePath(filePath: string, includeArchives = false): boolean {
  return isOrgLikeFileName(path.basename(filePath), includeArchives)
    && !isDefaultIgnoredSyncArtifactPath(filePath)
    && (includeArchives || !isDefaultArchivePath(filePath));
}

function approvalCandidateSources(file: string, sourceLines: string[]): ApprovalCandidateSource[] {
  const ranges: Array<[number, number]> = [];
  for (let index = 0; index < sourceLines.length; index += 1) {
    const level = approvalHeadingLevel(sourceLines[index] || "");
    if (level === null) continue;

    const directEnd = firstApprovalHeadingIndex(sourceLines, index) ?? sourceLines.length;
    const directText = sourceLines.slice(index, directEnd).join("\n");
    if (!approvalCandidateTextMayContainItem(directText)) continue;

    const subtreeEnd = firstApprovalHeadingIndex(sourceLines, index, level) ?? sourceLines.length;
    ranges.push([index, subtreeEnd]);
  }
  if (ranges.length === 0) return [];

  const parseLines = sourceLines.map((line) => approvalHeadingLevel(line) === null ? "" : line);
  for (const [start, end] of mergedApprovalCandidateRanges(ranges)) {
    for (let index = start; index < end; index += 1) {
      parseLines[index] = sourceLines[index] || "";
    }
  }

  return [{
    file,
    sourceText: sourceLines.join("\n"),
    parseText: parseLines.join("\n"),
    sourceLineOffset: 0,
  }];
}

function isPendingApprovalStatus(raw: string): boolean {
  const normalized = raw.toLowerCase().trim();
  if ([
    "review-required",
    "requires-review",
    "approval-required",
    "needs-approval",
    "needs-review",
    "pending-review",
    "pending-approval",
    "require-approval",
    "generated",
    "draft",
  ].includes(normalized)) {
    return true;
  }

  return normalized.includes("needs-review")
    || normalized.includes("need-review")
    || normalized.includes("needs-approval")
    || normalized.includes("need-approval")
    || normalized.includes("waiting-on-approval")
    || normalized.includes("pending-review")
    || normalized.includes("pending-approval")
    || normalized.includes("draft-needs-review")
    || normalized.includes("draft-needs-approval")
    || normalized.includes("reply-review")
    || normalized.includes("needs-avi")
    || normalized.includes("avi-approval")
    || normalized.includes("needs-human")
    || normalized.includes("human-review");
}

function titleNeedsHumanApproval(title: string): boolean {
  const normalized = title.toLowerCase().trim();
  return normalized.startsWith("approve ")
    || normalized.startsWith("review ")
    || normalized.startsWith("review/")
    || normalized.startsWith("review-send ")
    || normalized.startsWith("review and approve ")
    || normalized.startsWith("review/approve ");
}

function firstApprovalPropertyText(properties: Record<string, string>, keys: string[]): string | null {
  for (const key of withNameAliases(keys)) {
    const value = String(properties[key] || "").trim();
    if (value) return value;
  }
  return null;
}

function approvalStatus(title: string, properties: Record<string, string>): string | null {
  const status = firstApprovalPropertyText(properties, [
    "ORG2_REVIEW_STATUS",
    "REVIEW_STATUS",
    "REVIEW",
    "STATUS",
    "FOLLOWUP_STATUS",
    "REPLY_STATUS",
  ]);
  if (status && isPendingApprovalStatus(status) && titleNeedsHumanApproval(title)) {
    return status;
  }

  const waitingOn = firstApprovalPropertyText(properties, ["WAITING_ON", "BLOCKED_BY", "ORG2_WAITING_ON"]) || "";
  if (containsApprovalSignal(waitingOn)) return waitingOn.trim() || "approval-required";

  const nextAction = firstApprovalPropertyText(properties, ["NEXT_ACTION", "ACTION_REQUIRED", "ORG2_NEXT_ACTION"]) || "";
  if (containsApprovalSignal(nextAction)) return "approval-required";

  const handoff = firstApprovalPropertyText(properties, ["HANDOFF_SUMMARY", "ORG2_HANDOFF_SUMMARY"]) || "";
  if (containsApprovalSignal(handoff)) return "approval-required";

  const accessPolicy = firstApprovalPropertyText(properties, ["ACCESS_POLICY", "REVIEW_POLICY"]) || "";
  if (isPendingApprovalStatus(accessPolicy) || containsApprovalSignal(accessPolicy)) {
    return accessPolicy.trim() || "approval-required";
  }

  return null;
}

function inlineText(node: InlineNode): string {
  switch (node.type) {
    case "Text":
      return node.value;
    case "Timestamp":
      return node.raw;
    case "TimestampRange":
      return `${node.start.raw}${node.separatorRaw}${node.end.raw}`;
    case "Emphasis":
      return `${node.marker}${node.content}${node.marker}`;
    case "Link":
      return node.descriptionRaw ?? node.targetRaw;
    case "ProgressCookie":
      return node.raw;
    case "Entity":
    case "LatexFragment":
    case "ExportSnippet":
    case "FootnoteReference":
    case "Citation":
    case "Target":
    case "Script":
    case "LineBreak":
      return node.raw;
  }
}

function headlineTitleText(headline: HeadlineNode): string {
  return headline.title.map(inlineText).join("");
}

function approvalHeadlineProperties(headline: HeadlineNode): Record<string, string> {
  for (const child of headline.children) {
    if (child.type !== "PropertyDrawer") continue;
    return Object.fromEntries(
      child.properties.map((property) => [property.key.toUpperCase(), property.value]),
    );
  }
  return {};
}

function approvalHeadlinePropertiesFromSource(
  headline: HeadlineNode,
  sourceLines: string[],
): Record<string, string> {
  const sourceRange = (headline as SourceRangedHeadlineNode).sourceRange;
  if (!sourceRange) return {};
  let index = sourceRange.startLine;
  while (index < sourceLines.length) {
    const line = String(sourceLines[index] || "").trim();
    if (!line || /^(?:SCHEDULED|DEADLINE|CLOSED):/i.test(line)) {
      index += 1;
      continue;
    }
    break;
  }
  if (String(sourceLines[index] || "").trim().toUpperCase() !== ":PROPERTIES:") return {};

  const properties: Record<string, string> = {};
  for (index += 1; index < sourceLines.length; index += 1) {
    const line = String(sourceLines[index] || "").trim();
    if (line.toUpperCase() === ":END:") break;
    const match = /^:([A-Za-z0-9_-]+):\s*(.*?)\s*$/.exec(line);
    if (match) properties[String(match[1] || "").toUpperCase()] = String(match[2] || "");
  }
  return properties;
}

function approvalBody(sourceLines: string[], sourceRange: SourceRange, children: Node[]): string {
  const startLine = Math.max(1, sourceRange.startLine + 1);
  const endLine = Math.max(startLine, sourceRange.endLine);
  if (sourceLines.length === 0 || startLine > endLine) return "";

  const hiddenRanges = children.flatMap((child): SourceRange[] => {
    if (child.type === "PropertyDrawer") {
      const range = (child as SourceRangedPropertyDrawerNode).sourceRange;
      return range ? [range] : [];
    }
    if (child.type === "Planning") {
      const range = (child as SourceRangedPlanningNode).sourceRange;
      return range ? [range] : [];
    }
    return [];
  });

  const bodyLines: string[] = [];
  for (let lineNumber = startLine; lineNumber <= endLine; lineNumber += 1) {
    if (hiddenRanges.some((range) => lineNumber >= range.startLine && lineNumber <= range.endLine)) continue;
    bodyLines.push(sourceLines[lineNumber - 1] || "");
  }
  return bodyLines.join("\n").trim();
}

function approvalDecisionKey(raw: string): string | null {
  const normalized = raw.trim().toLowerCase();
  if (!normalized) return null;
  return normalized.startsWith("artifact:") ? normalized : `artifact:${normalized}`;
}

function approvalDecisionKeysFromProperties(properties: Record<string, string>): string[] {
  const gmailDraftId = String(properties.GMAIL_DRAFT_ID || "").trim();
  const key = gmailDraftId ? approvalDecisionKey(`gmail:gog:${gmailDraftId}`) : null;
  return key ? [key] : [];
}

function appendApprovalItemsFromNodes(
  nodes: Node[],
  file: string,
  sourceLines: string[],
  candidates: ApprovalQueueCandidate[],
  inheritedDecisionKeys: string[] = [],
): void {
  for (const node of nodes) {
    if (node.type !== "Headline") continue;
    const properties = {
      ...approvalHeadlinePropertiesFromSource(node, sourceLines),
      ...approvalHeadlineProperties(node),
    };
    const decisionKeys = Array.from(new Set([
      ...inheritedDecisionKeys,
      ...approvalDecisionKeysFromProperties(properties),
    ]));
    const item = approvalItemFromHeadline(node, file, sourceLines, properties);
    if (item) {
      candidates.push({ item, decisionKeys, isPending: true });
    }
    appendApprovalItemsFromNodes(node.children, file, sourceLines, candidates, decisionKeys);
  }
}

function approvalItemFromHeadline(
  headline: HeadlineNode,
  file: string,
  sourceLines: string[],
  properties: Record<string, string>,
): ApprovalQueueItem | null {
  const todo = headline.todo?.toUpperCase() ?? null;
  if (headline.todoTerminal ?? isTerminalTodoKeyword(todo)) return null;

  const sourceRange = (headline as SourceRangedHeadlineNode).sourceRange;
  if (!sourceRange) return null;

  const title = extractAgendaPriorityFromHeadlineTitle(headlineTitleText(headline)).title;
  const status = approvalStatus(title, properties);
  if (!status) return null;

  return {
    kind: "headline",
    title,
    status,
    todo,
    level: headline.level,
    file,
    line: sourceRange.startLine,
    idValue: properties.ID || null,
    properties,
    body: approvalBody(sourceLines, sourceRange, headline.children),
    tags: headline.tags ?? [],
  };
}

function approvalCandidatesFromRuns(rootDir: string, runs: AgentRun[]): ApprovalQueueCandidate[] {
  return runs.flatMap((run) => {
    const emitsPendingDecisions = run.status !== "completed" && run.status !== "canceled";
    const pending = run.approvals.filter((approval) => approval.status === "pending");
    return run.approvals.map((approval) => {
      const remainingAfterThis = pending.length - 1;
      const otherBoundaryDecisions = currentAgentRunApprovalBoundary(run)
        .filter((candidate) => candidate.id !== approval.id);
      const hasRequestedRevision = otherBoundaryDecisions
        .some((candidate) => candidate.status === "revised");
      const hasDeclinedAction = otherBoundaryDecisions
        .some((candidate) => candidate.status === "rejected" || candidate.status === "canceled");
      const runDecisionEffect = run.status !== "waiting-approval"
        ? `Deciding this approval does not clear the run's separate ${run.status} state.`
        : remainingAfterThis > 0
          ? `Approving this leaves ${remainingAfterThis} other pending approval${remainingAfterThis === 1 ? "" : "s"} before the run can resume.`
          : hasRequestedRevision
            ? "This is the last pending approval, but another decision requested revision, so the run will remain blocked for replacement material."
            : hasDeclinedAction
              ? "This is the last pending approval; deciding it resumes the run with rejected or canceled actions excluded."
              : "This is the last pending approval; approving it resumes the run.";
      return {
        item: {
          kind: "run" as const,
          title: approval.title,
          status: approval.status,
          todo: null,
          level: null,
          file: agentRunPath(rootDir, run.id),
          line: 1,
          idValue: approval.id,
          properties: {},
          body: approval.note || approval.action,
          tags: [],
          approvalId: approval.id,
          fingerprint: approval.fingerprint,
          action: approval.action,
          riskClass: approval.riskClass,
          ...(approval.requestedRole ? { requestedRole: approval.requestedRole } : {}),
          ...(approval.requestedFrom ? { requestedFrom: approval.requestedFrom } : {}),
          requestedAt: approval.requestedAt,
          runId: run.id,
          runGoal: run.goal,
          runStatus: run.status,
          runPendingApprovalCount: pending.length,
          runApprovalCount: run.approvals.length,
          runDecisionEffect,
          decisionKeys: agentRunApprovalDecisionKeys(approval),
          ...(approval.priority === "urgent" ? { priority: "urgent" } : {}),
        },
        decisionKeys: agentRunApprovalDecisionKeys(approval),
        requestedAt: approval.requestedAt,
        isPending: emitsPendingDecisions && approval.status === "pending",
      };
    });
  });
}

function approvalCandidatesInDocument(document: DocumentNode, file: string, sourceText: string): ApprovalQueueCandidate[] {
  const sourceLines = sourceText.replace(/\r\n/g, "\n").split("\n");
  const candidates: ApprovalQueueCandidate[] = [];
  appendApprovalItemsFromNodes(document.children, file, sourceLines, candidates);
  return candidates;
}

function latestApprovalCandidate(
  lhs: ApprovalQueueCandidate,
  rhs: ApprovalQueueCandidate,
): ApprovalQueueCandidate {
  const requestedOrder = String(lhs.requestedAt || "").localeCompare(String(rhs.requestedAt || ""));
  if (requestedOrder !== 0) return requestedOrder > 0 ? lhs : rhs;
  const lhsId = `${lhs.item.runId || ""}:${lhs.item.approvalId || ""}`;
  const rhsId = `${rhs.item.runId || ""}:${rhs.item.approvalId || ""}`;
  return lhsId.localeCompare(rhsId) >= 0 ? lhs : rhs;
}

function unifiedPendingApprovalItems(candidates: ApprovalQueueCandidate[]): ApprovalQueueItem[] {
  const latestRunCandidateByDecisionKey = new Map<string, ApprovalQueueCandidate>();
  const runCandidatesByRunId = new Map<string, ApprovalQueueCandidate[]>();
  for (const candidate of candidates) {
    if (candidate.item.kind !== "run") continue;
    if (candidate.item.runId) {
      runCandidatesByRunId.set(candidate.item.runId, [
        ...(runCandidatesByRunId.get(candidate.item.runId) || []),
        candidate,
      ]);
    }
    for (const key of candidate.decisionKeys) {
      const current = latestRunCandidateByDecisionKey.get(key);
      latestRunCandidateByDecisionKey.set(
        key,
        current ? latestApprovalCandidate(current, candidate) : candidate,
      );
    }
  }

  const items = candidates.flatMap((candidate): ApprovalQueueItem[] => {
    if (candidate.item.kind === "headline") {
      const linkedRunId = String(brandProperty(candidate.item.properties, "ORG2_RUN_ID") || "").trim();
      const linkedCandidates = linkedRunId ? runCandidatesByRunId.get(linkedRunId) || [] : [];
      const linkedApprovalId = String(
        brandProperty(candidate.item.properties, "ORG2_APPROVAL_ID")
          || candidate.item.properties.APPROVAL_ID
          || "",
      ).trim();
      const exactLinkedApproval = linkedApprovalId
        ? linkedCandidates.find((runCandidate) => runCandidate.item.approvalId === linkedApprovalId)
        : undefined;
      const normalizedTitle = candidate.item.title.toLowerCase().replace(/\s+/g, " ").trim();
      const titleMatches = linkedCandidates.filter((runCandidate) =>
        runCandidate.item.title.toLowerCase().replace(/\s+/g, " ").trim() === normalizedTitle);
      const pendingLinked = linkedCandidates.filter((runCandidate) => runCandidate.isPending);
      const isCanonicalRunProjection = Boolean(exactLinkedApproval)
        || titleMatches.length === 1
        || (!linkedApprovalId && pendingLinked.length === 1);
      if (isCanonicalRunProjection) return [];
      const hasCanonicalRunDecision = candidate.decisionKeys.some((key) =>
        latestRunCandidateByDecisionKey.has(key));
      return hasCanonicalRunDecision ? [] : [candidate.item];
    }
    if (!candidate.isPending) return [];
    const isLatestDecision = candidate.decisionKeys.every((key) =>
      latestRunCandidateByDecisionKey.get(key) === candidate);
    return isLatestDecision ? [candidate.item] : [];
  });
  return sortedApprovalItems(items);
}

function sortedApprovalItems(items: ApprovalQueueItem[]): ApprovalQueueItem[] {
  return [...items].sort((lhs, rhs) => {
    if (lhs.kind !== rhs.kind) return lhs.kind === "run" ? -1 : 1;
    if (lhs.kind === "run" && rhs.kind === "run") {
      const requestedOrder = String(rhs.requestedAt || "").localeCompare(String(lhs.requestedAt || ""));
      if (requestedOrder !== 0) return requestedOrder;
    }
    const statusOrder = lhs.status.localeCompare(rhs.status, undefined, { sensitivity: "base" });
    if (statusOrder !== 0) return statusOrder;
    const titleOrder = lhs.title.localeCompare(rhs.title, undefined, { sensitivity: "base" });
    if (titleOrder !== 0) return titleOrder;
    const fileOrder = lhs.file.localeCompare(rhs.file);
    if (fileOrder !== 0) return fileOrder;
    return lhs.line - rhs.line;
  });
}

function approvalCandidateSourcesByScanningFiles(files: string[], includeArchives: boolean): { candidates: ApprovalCandidateSource[]; skippedFiles: number } {
  const candidates: ApprovalCandidateSource[] = [];
  let skippedFiles = 0;

  for (const file of files) {
    if (!isApprovalIndexableFilePath(file, includeArchives)) continue;
    try {
      const lines = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n");
      candidates.push(...approvalCandidateSources(path.resolve(file), lines));
    } catch {
      skippedFiles += 1;
    }
  }

  return { candidates, skippedFiles };
}

function approvalCandidateSourcesFromIndex(index: Org2SearchIndex, includeArchives: boolean): ApprovalCandidateSource[] {
  const candidates: ApprovalCandidateSource[] = [];
  for (const file of index.files) {
    if (!isApprovalIndexableFilePath(file.path, includeArchives)) continue;
    candidates.push(...approvalCandidateSources(path.resolve(file.path), file.lines));
  }
  return candidates;
}

function findRoamLabelLineForLint(content: string, labelRaw: string): number {
  const target = normalizeRoamLinkLabel(labelRaw);
  if (!target) return 1;

  const lines = content.replace(/\r\n/g, "\n").split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    const titleMatch = /^#\+title:\s*(.*?)\s*$/i.exec(line.trim());
    if (titleMatch && normalizeRoamLinkLabel(titleMatch[1] || "") === target) return i + 1;

    const fileAliasMatch = /^#\+roam_alias(?:es)?:\s*(.*?)\s*$/i.exec(line.trim());
    if (fileAliasMatch && parseRoamAliasTokens(fileAliasMatch[1] || "").some((alias) => normalizeRoamLinkLabel(alias) === target)) {
      return i + 1;
    }

    const headlineMatch = /^(\*+)\s+/.exec(line);
    if (headlineMatch && normalizeRoamLinkLabel(parseHeadlineTitleForRoam(line)) === target) return i + 1;

    const drawerAliasMatch = /^:ROAM_ALIASES:\s*(.*?)\s*$/i.exec(line.trim());
    if (drawerAliasMatch && parseRoamAliasTokens(drawerAliasMatch[1] || "").some((alias) => normalizeRoamLinkLabel(alias) === target)) {
      return i + 1;
    }
  }

  return 1;
}

function appendRoamGraphLintIssues(files: string[], issues: ArtifactLintIssue[]): void {
  if (files.length === 0) return;

  const graph = buildRoamGraph(files);
  const maintenance = buildRoamGraphMaintenanceReport(files, graph, {
    includeLinkifySuggestions: false,
  });

  for (const finding of maintenance.linkFindings) {
    issues.push({
      severity: finding.severity,
      rule: finding.rule,
      file: finding.file,
      line: finding.line,
      message: finding.message,
    });
  }

  for (const collision of maintenance.aliasCollisions) {
    if (collision.nodes.length < 2) continue;
    const primary = collision.nodes[0];
    if (!primary) continue;

    let raw = "";
    try {
      raw = fs.readFileSync(primary.file, "utf8");
    } catch {
      raw = "";
    }

    const alsoSeen = collision.nodes
      .slice(1)
      .map((node) => `${node.label} (${node.file})`)
      .join(", ");

    issues.push({
      severity: "warning",
      rule: "ambiguous-wiki-label",
      file: primary.file,
      line: findRoamLabelLineForLint(raw, collision.label),
      message: `Title/alias '${collision.label}' resolves to multiple roam nodes; ambiguous wiki links should use an id link or a more specific alias (also at ${alsoSeen}).`,
    });
  }
}

function splitLintList(raw: string): string[] {
  return String(raw || "")
    .split(/[,;]+/)
    .map((part) => part.trim())
    .filter(Boolean);
}

function appendArtifactFreshnessLintIssues(content: string, filePath: string, issues: ArtifactLintIssue[]): void {
  for (const drawer of collectArtifactPropertyDrawersInText(content)) {
    const role = String(brandProperty(drawer.properties, "ORG2_ARTIFACT_ROLE") || "").trim().toLowerCase();
    if (!["compiled", "view", "report"].includes(role)) continue;

    const generatedAtRaw = String(brandProperty(drawer.properties, "ORG2_GENERATED_AT") || "").trim();
    const generatedAt = generatedAtRaw ? new Date(generatedAtRaw) : null;
    const reviewStatus = String(brandProperty(drawer.properties, "ORG2_REVIEW_STATUS") || "").trim().toLowerCase();
    const sourceMtimeRequiresReview = !["reviewed", "promoted"].includes(reviewStatus);

    if (sourceMtimeRequiresReview && generatedAt && !Number.isNaN(generatedAt.getTime())) {
      for (const entry of splitLintList(brandProperty(drawer.properties, "ORG2_PROVENANCE") || "")) {
        const match = /^file:(\S.*)$/.exec(entry);
        if (!match) continue;
        const sourcePath = path.resolve(path.dirname(filePath), String(match[1] || "").trim());
        try {
          const stat = fs.statSync(sourcePath);
          if (stat.mtime.getTime() > generatedAt.getTime()) {
            issues.push({
              severity: "warning",
              rule: "artifact-stale-source-mtime",
              file: filePath,
              line: drawer.line,
              message: `Generated artifact is older than provenance source '${match[1]}'; regenerate or review before trusting this output.`,
            });
          }
        } catch {
          // Missing provenance file references are reported by artifact-provenance-file-missing.
        }
      }
    }

    for (const entry of splitLintList(brandProperty(drawer.properties, "ORG2_SOURCE_HASHES") || "")) {
      const parsed = parseArtifactSourceHashEntry(entry);
      if (!parsed || parsed.kind !== "file") continue;
      const sourcePath = path.resolve(path.dirname(filePath), parsed.value);
      try {
        const actualHash = crypto.createHash("sha256").update(fs.readFileSync(sourcePath)).digest("hex");
        if (actualHash !== parsed.hash) {
          issues.push({
            severity: "warning",
            rule: "artifact-source-hash-mismatch",
            file: filePath,
            line: drawer.line,
            message: `ORG2_SOURCE_HASHES entry for '${parsed.value}' does not match current file content; regenerate or review before trusting this output.`,
          });
        }
      } catch {
        // Missing provenance/source files are reported separately when they appear in ORG2_PROVENANCE.
      }
    }
  }
}

function buildRoamGraphMaintenanceReport(
  files: string[],
  graph: RoamGraphData,
  options: { includeLinkifySuggestions?: boolean } = {},
): RoamGraphMaintenanceReport {
  const nodeIds = new Set(graph.nodes.map((node) => node.id.toLowerCase()));
  const nodeById = new Map(graph.nodes.map((node) => [node.id.toLowerCase(), node]));
  const titleIndex = buildRoamTitleIndex(files);
  const includeLinkifySuggestions = options.includeLinkifySuggestions === true;
  const labelIndex = includeLinkifySuggestions ? buildRoamLinkifyIndex(files) : null;
  const linkFindings: RoamGraphMaintenanceLinkFinding[] = [];
  const linkifySuggestions: RoamGraphMaintenanceLinkifySuggestion[] = [];

  const aliasCollisions = Array.from(titleIndex.entries())
    .filter(([, ids]) => ids.size > 1)
    .map(([label, ids]) => ({
      label,
      nodes: Array.from(ids)
        .map((id) => nodeById.get(id.toLowerCase()))
        .filter((node): node is RoamGraphNode => Boolean(node))
        .map((node) => ({ id: node.id, label: node.label, file: node.file }))
        .sort((a, b) => a.label.localeCompare(b.label) || a.file.localeCompare(b.file)),
    }))
    .filter((collision) => collision.nodes.length > 1)
    .sort((a, b) => a.label.localeCompare(b.label));

  for (const filePath of files) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch {
      continue;
    }

    const { lines, windows } = readRoamSourceStructure(content, filePath);
    for (let i = 0; i < lines.length; i += 1) {
      // Match graph edges and mention edits: metadata and literal blocks have
      // their own semantics and must not also produce prose-link diagnostics.
      const window = windows[i];
      if (!window) continue;
      const line = lines[i]!.slice(window.start, window.end);

      for (const id of findRoamIdLinksInLine(line)) {
        if (nodeIds.has(id.toLowerCase())) continue;
        linkFindings.push({
          rule: "unresolved-id-link",
          severity: "warning",
          file: filePath,
          line: i + 1,
          target: id,
          message: `id:${id} does not resolve to a scanned roam node.`,
        });
      }

      for (const label of findRoamWikiLinksInLine(line)) {
        const normalizedLabel = normalizeRoamLinkLabel(label);
        if (!normalizedLabel) continue;
        const candidates = Array.from(titleIndex.get(normalizedLabel) || []);
        if (candidates.length === 0) {
          linkFindings.push({
            rule: "unresolved-wiki-link",
            severity: "warning",
            file: filePath,
            line: i + 1,
            target: label,
            message: `[[${label}]] does not resolve to a scanned title or alias.`,
          });
        } else if (candidates.length > 1) {
          linkFindings.push({
            rule: "ambiguous-wiki-link",
            severity: "warning",
            file: filePath,
            line: i + 1,
            target: label,
            candidates,
            message: `[[${label}]] resolves to ${candidates.length} nodes; use an id link or disambiguate aliases.`,
          });
        }
      }
    }

    if (labelIndex) {
      const linkifyResult = applyRoamLinkifyToFile(content, filePath, labelIndex);
      for (const match of linkifyResult.debugMatches || []) {
        linkifySuggestions.push({
          kind: "exact",
          file: filePath,
          line: match.line,
          label: match.label,
          candidate: match.candidate,
          count: match.count,
          reason: "exact eligible label occurrence can be linked safely in preview/apply mode",
        });
      }
      for (const suggestion of linkifyResult.debugRepresented || []) {
        linkifySuggestions.push({
          kind: "represented-node",
          file: filePath,
          line: suggestion.line,
          lineEnd: suggestion.lineEnd,
          sourceRange: suggestion.sourceRange,
          sourceKind: suggestion.sourceKind,
          label: suggestion.label,
          candidate: suggestion.candidate,
          confidence: suggestion.confidence,
          reason: suggestion.reason,
          text: suggestion.text,
          evidence: suggestion.evidence,
        });
      }
    }
  }

  const orphanNodes = graph.nodes
    .filter((node) => node.degree === 0)
    .sort((a, b) => a.file.localeCompare(b.file) || a.label.localeCompare(b.label));
  const highDegreeNodes = graph.nodes
    .filter((node) => node.degree > 0)
    .slice()
    .sort((a, b) => b.degree - a.degree || a.label.localeCompare(b.label))
    .slice(0, 20);
  const unresolvedLinkCount = linkFindings.filter((finding) => finding.rule !== "ambiguous-wiki-link").length;
  const ambiguousLinkCount = linkFindings.filter((finding) => finding.rule === "ambiguous-wiki-link").length;

  return {
    summary: {
      scannedFiles: files.length,
      nodeCount: graph.nodes.length,
      edgeCount: graph.edges.length,
      orphanNodeCount: orphanNodes.length,
      aliasCollisionCount: aliasCollisions.length,
      unresolvedLinkCount,
      ambiguousLinkCount,
      linkifySuggestionCount: linkifySuggestions.length,
    },
    orphanNodes,
    highDegreeNodes,
    aliasCollisions,
    linkFindings: linkFindings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.rule.localeCompare(b.rule)),
    linkifySuggestions: linkifySuggestions.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || a.label.localeCompare(b.label)),
  };
}

function renderRoamGraphReportText(report: RoamGraphMaintenanceReport): string {
  const lines: string[] = [];
  lines.push("Celorga roam maintenance report");
  lines.push("============================");
  lines.push("");
  lines.push(`Scanned files: ${report.summary.scannedFiles}`);
  lines.push(`Nodes: ${report.summary.nodeCount}`);
  lines.push(`Edges: ${report.summary.edgeCount}`);
  lines.push(`Orphan nodes: ${report.summary.orphanNodeCount}`);
  lines.push(`Alias collisions: ${report.summary.aliasCollisionCount}`);
  lines.push(`Unresolved links: ${report.summary.unresolvedLinkCount}`);
  lines.push(`Ambiguous links: ${report.summary.ambiguousLinkCount}`);
  lines.push(`Linkify suggestions: ${report.summary.linkifySuggestionCount}`);
  lines.push("");

  lines.push("High-degree nodes");
  lines.push("-----------------");
  if (report.highDegreeNodes.length === 0) {
    lines.push("- none");
  } else {
    for (const node of report.highDegreeNodes.slice(0, 12)) {
      lines.push(`- ${node.label} (${node.degree}; in ${node.degreeIn}, out ${node.degreeOut}) — ${node.file}`);
    }
  }
  lines.push("");

  lines.push("Orphan nodes");
  lines.push("------------");
  if (report.orphanNodes.length === 0) {
    lines.push("- none");
  } else {
    for (const node of report.orphanNodes.slice(0, 20)) {
      lines.push(`- ${node.label} — ${node.file}`);
    }
    if (report.orphanNodes.length > 20) lines.push(`- … ${report.orphanNodes.length - 20} more`);
  }
  lines.push("");

  lines.push("Alias/title collisions");
  lines.push("----------------------");
  if (report.aliasCollisions.length === 0) {
    lines.push("- none");
  } else {
    for (const collision of report.aliasCollisions.slice(0, 20)) {
      const nodes = collision.nodes.map((node) => `${node.label} (${node.id}, ${node.file})`).join("; ");
      lines.push(`- ${collision.label}: ${nodes}`);
    }
    if (report.aliasCollisions.length > 20) lines.push(`- … ${report.aliasCollisions.length - 20} more`);
  }
  lines.push("");

  lines.push("Link findings");
  lines.push("-------------");
  if (report.linkFindings.length === 0) {
    lines.push("- none");
  } else {
    for (const finding of report.linkFindings.slice(0, 40)) {
      const candidates = finding.candidates?.length ? ` Candidates: ${finding.candidates.join(", ")}` : "";
      lines.push(`- ${finding.rule} ${finding.file}:${finding.line} ${finding.message}${candidates}`);
    }
    if (report.linkFindings.length > 40) lines.push(`- … ${report.linkFindings.length - 40} more`);
  }
  lines.push("");

  lines.push("Linkify suggestions");
  lines.push("-------------------");
  if (report.linkifySuggestions.length === 0) {
    lines.push("- none");
  } else {
    for (const suggestion of report.linkifySuggestions.slice(0, 40)) {
      const confidence = typeof suggestion.confidence === "number" ? ` confidence=${suggestion.confidence.toFixed(2)}` : "";
      const count = typeof suggestion.count === "number" ? ` count=${suggestion.count}` : "";
      const lineRange = suggestion.lineEnd && suggestion.lineEnd !== suggestion.line ? `${suggestion.line}-${suggestion.lineEnd}` : `${suggestion.line}`;
      const sourceKind = suggestion.sourceKind ? ` ${suggestion.sourceKind}` : "";
      lines.push(
        `- ${suggestion.kind}${sourceKind} ${suggestion.file}:${lineRange} ${suggestion.label} -> ${suggestion.candidate}${count}${confidence}; ${suggestion.reason}`,
      );
    }
    if (report.linkifySuggestions.length > 40) lines.push(`- … ${report.linkifySuggestions.length - 40} more`);
  }
  lines.push("");

  return lines.join("\n");
}


function buildGraphAuditReport(files: string[]): GraphAuditReport {
  const graph = buildRoamGraph(files);
  const maintenance = buildRoamGraphMaintenanceReport(files, graph, {
    includeLinkifySuggestions: false,
  });
  const findings: GraphAuditFinding[] = [];

  for (const finding of maintenance.linkFindings) {
    findings.push({
      type: "broken-link",
      severity: finding.rule === "ambiguous-wiki-link" ? "warning" : "error",
      file: finding.file,
      line: finding.line,
      target: finding.target,
      rule: finding.rule,
      explanation: finding.message,
      deterministicFix:
        finding.rule === "unresolved-id-link"
          ? "Create or restore a node with this ID, or update the id: link to an existing node."
          : undefined,
      reviewSuggestion:
        finding.rule === "ambiguous-wiki-link"
          ? "Pick the intended node and replace the wiki link with an id link, or rename aliases to remove the ambiguity."
          : "Review whether the target was renamed, moved outside the scan, or should be created.",
      related: finding.candidates?.length ? { candidates: finding.candidates } : undefined,
    });
  }

  for (const node of maintenance.orphanNodes) {
    findings.push({
      type: "orphan-note",
      severity: "info",
      file: node.file,
      id: node.id,
      label: node.label,
      rule: "orphan-note",
      explanation: `Node '${node.label}' has no inbound or outbound graph edges in the scanned corpus.`,
      reviewSuggestion: "Review whether this note should link to related notes, receive backlinks, or be archived.",
    });
  }

  for (const collision of maintenance.aliasCollisions) {
    findings.push({
      type: "duplicate-entity",
      severity: "warning",
      file: collision.nodes[0]?.file || files[0] || ".",
      label: collision.label,
      rule: "duplicate-entity-label",
      explanation: `Label/alias '${collision.label}' resolves to multiple nodes and can make entity links ambiguous.`,
      reviewSuggestion: "Merge duplicate entities, rename aliases, or use explicit id links for ambiguous references.",
      related: { nodes: collision.nodes },
    });
  }

  const artifactIdRefs = [] as ReturnType<typeof collectArtifactIdsInText>;
  const fileContents = new Map<string, string>();
  for (const filePath of files) {
    try {
      const raw = fs.readFileSync(filePath, "utf8");
      fileContents.set(filePath, raw);
      artifactIdRefs.push(...collectArtifactIdsInText(raw, filePath));
    } catch {
      // Ignore unreadable files here; lint reports parse/read failures separately.
    }
  }

  for (const duplicate of findDuplicateArtifactIds(artifactIdRefs)) {
    const primary = duplicate.refs[0];
    if (!primary) continue;
    findings.push({
      type: "duplicate-id",
      severity: "error",
      file: primary.file,
      line: primary.line,
      id: duplicate.id,
      rule: "artifact-id-duplicate",
      explanation: `ID '${duplicate.id}' appears ${duplicate.refs.length} times in the scanned corpus.`,
      deterministicFix: "Generate a new stable ID for all but the canonical occurrence, then update inbound id/provenance references deterministically.",
      reviewSuggestion: "Choose which occurrence is canonical before changing references if the duplicated records may represent the same entity.",
      related: { refs: duplicate.refs },
    });
  }

  for (const [filePath, raw] of fileContents) {
    const lintIssues: ArtifactLintIssue[] = [];
    appendArtifactFreshnessLintIssues(raw, filePath, lintIssues);
    for (const issue of lintIssues) {
      findings.push({
        type: "stale-generated-artifact",
        severity: issue.severity,
        file: issue.file,
        line: issue.line,
        rule: issue.rule,
        explanation: issue.message,
        deterministicFix: "Regenerate this artifact from its declared provenance/source inputs, then update ORG2_GENERATED_AT and ORG2_SOURCE_HASHES.",
        reviewSuggestion: "If the artifact was edited by hand or source provenance changed, review before replacing generated content.",
      });
    }
  }

  findings.sort((a, b) => a.file.localeCompare(b.file) || (a.line || 0) - (b.line || 0) || a.type.localeCompare(b.type));
  return {
    $schema: "org2:graph-audit:v1",
    summary: {
      scannedFiles: files.length,
      nodeCount: graph.nodes.length,
      edgeCount: graph.edges.length,
      findingCount: findings.length,
      errorCount: findings.filter((finding) => finding.severity === "error").length,
      warningCount: findings.filter((finding) => finding.severity === "warning").length,
      infoCount: findings.filter((finding) => finding.severity === "info").length,
    },
    findings,
  };
}

function renderGraphAuditReportText(report: GraphAuditReport): string {
  const lines: string[] = [];
  lines.push("Celorga graph quality audit");
  lines.push("========================");
  lines.push(`Scanned files: ${report.summary.scannedFiles}`);
  lines.push(`Graph: ${report.summary.nodeCount} nodes, ${report.summary.edgeCount} edges`);
  lines.push(`Findings: ${report.summary.findingCount} (${report.summary.errorCount} error, ${report.summary.warningCount} warning, ${report.summary.infoCount} info)`);
  lines.push("");
  if (report.findings.length === 0) {
    lines.push("No graph quality findings.");
    return lines.join("\n") + "\n";
  }
  for (const finding of report.findings) {
    const loc = `${finding.file}${finding.line ? `:${finding.line}` : ""}`;
    lines.push(`- ${finding.severity.toUpperCase()} ${finding.type}/${finding.rule} ${loc}`);
    lines.push(`  ${finding.explanation}`);
    if (finding.deterministicFix) lines.push(`  deterministic fix: ${finding.deterministicFix}`);
    if (finding.reviewSuggestion) lines.push(`  review suggestion: ${finding.reviewSuggestion}`);
  }
  return lines.join("\n") + "\n";
}

function escapeHtml(raw: string): string {
  return String(raw || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;");
}

function renderRoamGraphHtml(graph: RoamGraphData, opts?: { title?: string; dir?: string }): string {
  const title = opts?.title || "Celorga Roam Graph";
  const subtitle = opts?.dir ? `Source: ${opts.dir}` : "Static debug view";
  const isolatedCount = graph.nodes.filter((node) => node.degree === 0).length;
  const connectedNodes = graph.nodes.filter((node) => node.degree > 0);
  const topNodes = graph.nodes
    .slice()
    .sort((a, b) => b.degree - a.degree || a.label.localeCompare(b.label))
    .slice(0, 12)
    .map((node) => ({ label: node.label, degree: node.degree }));
  const payload = JSON.stringify({
    totalNodes: graph.nodes.length,
    totalEdges: graph.edges.length,
    isolatedCount,
    connectedCount: connectedNodes.length,
    nodes: graph.nodes,
    edges: graph.edges,
  });

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; background: #0b1020; color: #e5e7eb; }
    .wrap { display: grid; grid-template-columns: 360px 1fr; height: 100vh; overflow: hidden; }
    .sidebar { padding: 16px; background: rgba(15, 23, 42, 0.96); border-right: 1px solid rgba(148, 163, 184, 0.22); overflow: auto; }
    h1 { margin: 0 0 6px; font-size: 18px; }
    .sub { color: #94a3b8; margin-bottom: 14px; word-break: break-word; }
    .stats { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-bottom: 12px; }
    .card { background: rgba(30, 41, 59, 0.86); border: 1px solid rgba(148, 163, 184, 0.18); border-radius: 10px; padding: 10px; }
    .card strong { display: block; font-size: 18px; }
    .hint { color: #94a3b8; margin: 12px 0; }
    .controls { display: flex; gap: 8px; margin: 10px 0; }
    button { border: 1px solid rgba(148, 163, 184, 0.28); background: rgba(15, 23, 42, 0.9); color: #e5e7eb; border-radius: 8px; padding: 7px 9px; cursor: pointer; }
    button:hover { background: rgba(96, 165, 250, 0.18); }
    input { width: 100%; margin: 8px 0; padding: 8px 10px; border-radius: 8px; border: 1px solid rgba(148, 163, 184, 0.28); background: rgba(15, 23, 42, 0.9); color: #e5e7eb; }
    ul { list-style: none; margin: 0; padding: 0; max-height: 36vh; overflow: auto; }
    li { margin: 0; padding: 7px 8px; border-radius: 8px; cursor: pointer; }
    li:hover, li.active { background: rgba(96, 165, 250, 0.2); }
    .meta { display: block; color: #94a3b8; font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .details { margin-top: 12px; word-break: break-word; }
    .stage { position: relative; min-width: 0; height: 100vh; overflow: hidden; }
    canvas { display: block; width: 100%; height: 100%; cursor: crosshair; }
    .overlay { position: absolute; left: 16px; top: 16px; right: 16px; display: flex; justify-content: space-between; gap: 16px; pointer-events: none; }
    .pill { pointer-events: auto; max-width: min(680px, 70vw); background: rgba(15, 23, 42, 0.86); border: 1px solid rgba(148, 163, 184, 0.24); border-radius: 999px; padding: 8px 12px; color: #cbd5e1; }
  </style>
</head>
<body>
  <div class="wrap">
    <aside class="sidebar">
      <h1>${escapeHtml(title)}</h1>
      <div class="sub">${escapeHtml(subtitle)}</div>
      <div class="stats">
        <div class="card"><strong>${graph.nodes.length}</strong>nodes</div>
        <div class="card"><strong>${graph.edges.length}</strong>edges</div>
        <div class="card"><strong>${isolatedCount}</strong>isolated</div>
        <div class="card"><strong>${connectedNodes.length}</strong>connected</div>
      </div>
      <div class="hint">Search includes the full graph. The canvas shows a readable neighborhood for the selected node instead of trying to draw all ${graph.nodes.length} nodes at once.</div>
      <input id="nodeSearch" placeholder="Search all nodes/files" autofocus />
      <ul id="nodeList"></ul>
      <div class="controls">
        <button id="resetBtn">Top nodes</button>
        <button id="fitBtn">Fit view</button>
      </div>
      <div class="details card" id="details">Select a node to inspect its links.</div>
      <div class="card" style="margin-top:12px">
        <strong style="font-size:14px">Top connected nodes</strong>
        <ol>${topNodes.map((node) => `<li style="cursor:pointer" data-top-label="${escapeHtml(node.label)}">${escapeHtml(node.label)} <span style="color:#94a3b8">(${node.degree})</span></li>`).join("")}</ol>
      </div>
    </aside>
    <main class="stage">
      <canvas id="graph"></canvas>
      <div class="overlay"><div class="pill" id="status">Top connected nodes overview</div><div class="pill">Hover a node or click dots • drag to pan • wheel to zoom</div></div>
    </main>
  </div>
  <script>
    const payload = ${payload};
    const canvas = document.getElementById('graph');
    const ctx = canvas.getContext('2d');
    const nodeSearch = document.getElementById('nodeSearch');
    const nodeList = document.getElementById('nodeList');
    const details = document.getElementById('details');
    const statusEl = document.getElementById('status');
    const resetBtn = document.getElementById('resetBtn');
    const fitBtn = document.getElementById('fitBtn');
    const dpr = Math.max(1, window.devicePixelRatio || 1);
    const esc = (value) => String(value || '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
    const allNodes = payload.nodes.slice().sort((a, b) => b.degree - a.degree || a.label.localeCompare(b.label));
    const nodeById = new Map(allNodes.map((node) => [node.id, node]));
    const edgeByNode = new Map();
    for (const edge of payload.edges) {
      if (!edgeByNode.has(edge.source)) edgeByNode.set(edge.source, []);
      if (!edgeByNode.has(edge.target)) edgeByNode.set(edge.target, []);
      edgeByNode.get(edge.source).push(edge);
      edgeByNode.get(edge.target).push(edge);
    }
    let width = 1, height = 1, scale = 1, panX = 0, panY = 0;
    let viewNodes = [], viewEdges = [], selected = null, hovered = null;
    let dragging = false, dragStart = null;

    function resize() {
      width = Math.max(1, canvas.clientWidth);
      height = Math.max(1, canvas.clientHeight);
      canvas.width = Math.floor(width * dpr);
      canvas.height = Math.floor(height * dpr);
      draw();
    }
    function screenToWorld(clientX, clientY) {
      const rect = canvas.getBoundingClientRect();
      return { x: (clientX - rect.left - width / 2 - panX) / scale, y: (clientY - rect.top - height / 2 - panY) / scale };
    }
    function setTransform() { ctx.setTransform(dpr * scale, 0, 0, dpr * scale, dpr * (width / 2 + panX), dpr * (height / 2 + panY)); }
    function radius(node) { return 5 + Math.min(16, Math.sqrt(node.degree || 0) * 1.7); }
    function cloneNode(node) { return { ...node, x: 0, y: 0, r: radius(node) }; }
    function topOverview() {
      selected = null;
      const top = allNodes.filter((node) => node.degree > 0).slice(0, 80);
      viewNodes = top.map(cloneNode);
      const ids = new Set(viewNodes.map((node) => node.id));
      viewEdges = payload.edges.filter((edge) => ids.has(edge.source) && ids.has(edge.target));
      layoutRadial(viewNodes, null);
      fitView();
      statusEl.textContent = 'Top connected nodes overview';
      renderDetails(null);
      renderNodeList();
      draw();
    }
    function selectNodeById(id) {
      const center = nodeById.get(id);
      if (!center) return;
      selected = center;
      const rawEdges = (edgeByNode.get(id) || []).slice().sort((a, b) => (b.count || 1) - (a.count || 1)).slice(0, 140);
      const ids = new Set([id]);
      for (const edge of rawEdges) ids.add(edge.source === id ? edge.target : edge.source);
      const nodes = [...ids].map((nodeId) => nodeById.get(nodeId)).filter(Boolean);
      viewNodes = nodes.map(cloneNode);
      viewEdges = rawEdges.filter((edge) => ids.has(edge.source) && ids.has(edge.target));
      layoutRadial(viewNodes, id);
      fitView();
      statusEl.textContent = center.label + ' · ' + viewEdges.length + ' visible links';
      renderDetails(center);
      renderNodeList();
      draw();
    }
    function layoutRadial(nodes, centerId) {
      const center = centerId ? nodes.find((node) => node.id === centerId) : null;
      const others = center ? nodes.filter((node) => node.id !== centerId) : nodes;
      if (center) { center.x = 0; center.y = 0; }
      const rings = center ? [170, 300, 440, 580] : [170, 320, 470, 620];
      others.forEach((node, index) => {
        const ring = rings[Math.min(rings.length - 1, Math.floor(index / 36))];
        const inRing = index % 36;
        const count = Math.min(36, others.length - Math.floor(index / 36) * 36);
        const angle = (inRing / Math.max(1, count)) * Math.PI * 2 + (Math.floor(index / 36) * 0.37);
        node.x = Math.cos(angle) * ring;
        node.y = Math.sin(angle) * ring;
      });
    }
    function fitView() {
      if (!viewNodes.length) return;
      const minX = Math.min(...viewNodes.map((node) => node.x - node.r));
      const maxX = Math.max(...viewNodes.map((node) => node.x + node.r));
      const minY = Math.min(...viewNodes.map((node) => node.y - node.r));
      const maxY = Math.max(...viewNodes.map((node) => node.y + node.r));
      scale = Math.max(0.35, Math.min(1.6, Math.min((width - 80) / Math.max(1, maxX - minX), (height - 80) / Math.max(1, maxY - minY))));
      panX = -((minX + maxX) / 2) * scale;
      panY = -((minY + maxY) / 2) * scale;
    }
    function hitTest(world) {
      let best = null, bestD = Infinity;
      for (const node of viewNodes) {
        const dx = world.x - node.x, dy = world.y - node.y;
        const hit = Math.max(node.r + 5 / scale, 10 / scale);
        const d = dx * dx + dy * dy;
        if (d <= hit * hit && d < bestD) { best = node; bestD = d; }
      }
      return best;
    }
    function draw() {
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.fillStyle = '#0b1020';
      ctx.fillRect(0, 0, width, height);
      setTransform();
      ctx.lineWidth = Math.max(1 / scale, 0.6);
      const viewById = new Map(viewNodes.map((node) => [node.id, node]));
      for (const edge of viewEdges) {
        const a = viewById.get(edge.source), b = viewById.get(edge.target);
        if (!a || !b) continue;
        const active = hovered && (edge.source === hovered.id || edge.target === hovered.id);
        ctx.strokeStyle = active ? 'rgba(251, 191, 36, 0.75)' : 'rgba(148, 163, 184, 0.18)';
        ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
      }
      for (const node of viewNodes) {
        const isSelected = selected && selected.id === node.id;
        const isHovered = hovered && hovered.id === node.id;
        ctx.fillStyle = isSelected ? '#f97316' : isHovered ? '#fbbf24' : '#60a5fa';
        ctx.beginPath(); ctx.arc(node.x, node.y, node.r, 0, Math.PI * 2); ctx.fill();
        if (isSelected || isHovered || node.degree >= 25 || viewNodes.length <= 40) {
          ctx.fillStyle = '#e5e7eb'; ctx.font = Math.max(11 / scale, 10) + 'px -apple-system, BlinkMacSystemFont, sans-serif';
          ctx.fillText(node.label.slice(0, 70), node.x + node.r + 5 / scale, node.y + 4 / scale);
        }
      }
    }
    function renderDetails(node) {
      if (!node) { details.innerHTML = 'Select a node to inspect its links.'; return; }
      const edges = (edgeByNode.get(node.id) || []).slice(0, 12).map((edge) => nodeById.get(edge.source === node.id ? edge.target : edge.source)).filter(Boolean);
      details.innerHTML = '<strong>' + esc(node.label) + '</strong>' +
        '<div class="meta">degree ' + node.degree + ' · ' + node.degreeIn + ' in / ' + node.degreeOut + ' out</div>' +
        '<div class="meta">' + esc(node.file) + '</div>' +
        (edges.length ? '<hr style="border-color:rgba(148,163,184,.18)"><div class="meta">linked nodes</div>' + edges.map((n) => '<div>• ' + esc(n.label) + '</div>').join('') : '');
    }
    function renderNodeList() {
      const q = String(nodeSearch.value || '').toLowerCase();
      const matches = allNodes.filter((node) => !q || node.label.toLowerCase().includes(q) || String(node.file || '').toLowerCase().includes(q)).slice(0, 120);
      nodeList.innerHTML = matches.map((node) => '<li data-id="' + esc(node.id) + '"' + (selected && selected.id === node.id ? ' class="active"' : '') + '>' + esc(node.label) + '<span class="meta">' + esc(node.file) + ' · degree ' + node.degree + '</span></li>').join('');
    }
    canvas.addEventListener('mousemove', (event) => {
      if (dragging && dragStart) { panX = dragStart.panX + event.clientX - dragStart.x; panY = dragStart.panY + event.clientY - dragStart.y; draw(); return; }
      hovered = hitTest(screenToWorld(event.clientX, event.clientY));
      if (hovered) renderDetails(hovered); else renderDetails(selected);
      draw();
    });
    canvas.addEventListener('mousedown', (event) => { dragging = true; dragStart = { x: event.clientX, y: event.clientY, panX, panY }; });
    window.addEventListener('mouseup', () => { dragging = false; dragStart = null; });
    canvas.addEventListener('click', (event) => { const node = hitTest(screenToWorld(event.clientX, event.clientY)); if (node) selectNodeById(node.id); });
    canvas.addEventListener('wheel', (event) => { event.preventDefault(); const factor = event.deltaY < 0 ? 1.12 : 0.9; scale = Math.max(0.2, Math.min(4, scale * factor)); draw(); }, { passive: false });
    canvas.addEventListener('mouseleave', () => { hovered = null; renderDetails(selected); draw(); });
    nodeSearch.addEventListener('input', renderNodeList);
    nodeList.addEventListener('click', (event) => { const li = event.target.closest('li[data-id]'); if (li) selectNodeById(li.dataset.id); });
    document.querySelectorAll('[data-top-label]').forEach((li) => li.addEventListener('click', () => { const node = allNodes.find((candidate) => candidate.label === li.dataset.topLabel); if (node) selectNodeById(node.id); }));
    resetBtn.addEventListener('click', topOverview);
    fitBtn.addEventListener('click', () => { fitView(); draw(); });
    window.addEventListener('resize', resize);
    resize(); topOverview(); renderNodeList();
  </script>
</body>
</html>`;
}

function insertTextAtLinePosition(raw: string, pos: string, insertText: string): { outText: string; changed: boolean } {
  const normalized = raw.replace(/\r\n/g, "\n");
  const [lineRaw, colRaw] = pos.split(":");
  const line1 = parseInt(lineRaw, 10);
  if (!Number.isFinite(line1) || line1 < 1) {
    throw new Error(`invalid --pos ${pos}`);
  }

  let col: number | null = null;
  if (colRaw !== undefined) {
    const c = parseInt(colRaw, 10);
    if (!Number.isFinite(c) || c < 0) {
      throw new Error(`invalid --pos ${pos}`);
    }
    col = c;
  }

  const lines = normalized.split("\n");
  const lineIndex = line1 - 1;
  if (lineIndex >= lines.length) {
    throw new Error(`--pos line out of range: ${pos}`);
  }

  const lineText = lines[lineIndex] ?? "";
  const insertCol = col === null ? lineText.length : Math.min(col, lineText.length);
  lines[lineIndex] = lineText.slice(0, insertCol) + insertText + lineText.slice(insertCol);

  const outText = lines.join("\n");
  return { outText, changed: outText !== normalized };
}

interface HabitAgendaState {
  marker: string;
  streak: number;
  closedDates: string[];
}

interface ScheduledItem {
  filePath: string;
  // 0-based (VS Code uses 0-based positions)
  lineNumber: number;
  headline: string;
  body: string;
  todo: string | undefined;
  priority: string | undefined;
  effort: string | undefined;
  id: string | undefined;
  level: number;
  date: string;
  time: string | undefined;
  kind: string;
  tags: string[];
  properties: Record<string, string>;
  habit?: HabitAgendaState;
  todoTerminal?: boolean;
  /**
   * Set on the copy of an upcoming DEADLINE that is shown on the first day of
   * the range (normally today) during its warning period, like Emacs Org's
   * `org-deadline-warning-days`.
   */
  deadlineWarning?: AgendaDeadlineWarning;
}

interface AgendaDeadlineWarning {
  due: string;
  daysUntil: number;
}

const AGENDA_CACHE_SCHEMA_VERSION = "org2-agenda-cache/v3";
const AGENDA_CACHE_MAX_QUERIES = 4;

type AgendaCacheFileEntry = {
  todoConfiguration?: string;
  size: number;
  mtimeMs: number;
  ctimeMs: number;
  items: ScheduledItem[];
};

type AgendaCacheQueryEntry = {
  updatedAt: string;
  files: Record<string, AgendaCacheFileEntry>;
};

type AgendaCache = {
  schemaVersion: typeof AGENDA_CACHE_SCHEMA_VERSION;
  rootDir: string;
  queries: Record<string, AgendaCacheQueryEntry>;
};

function emptyAgendaCache(rootDir: string): AgendaCache {
  return {
    schemaVersion: AGENDA_CACHE_SCHEMA_VERSION,
    rootDir: path.resolve(rootDir),
    queries: {},
  };
}

function readAgendaCache(cacheFile: string, rootDir: string): AgendaCache {
  try {
    const parsed = JSON.parse(fs.readFileSync(cacheFile, "utf8")) as Partial<AgendaCache>;
    const queriesAreValid = parsed.queries
      && typeof parsed.queries === "object"
      && !Array.isArray(parsed.queries)
      && Object.values(parsed.queries).every((query) => (
        query
        && typeof query === "object"
        && !Array.isArray(query)
        && typeof query.updatedAt === "string"
        && query.files
        && typeof query.files === "object"
        && !Array.isArray(query.files)
        && Object.values(query.files).every((entry) => (
          entry
          && typeof entry === "object"
          && !Array.isArray(entry)
          && typeof entry.size === "number"
          && typeof entry.mtimeMs === "number"
          && typeof entry.ctimeMs === "number"
          && Array.isArray(entry.items)
        ))
      ));
    if (
      parsed.schemaVersion === AGENDA_CACHE_SCHEMA_VERSION
      && parsed.rootDir === path.resolve(rootDir)
      && queriesAreValid
    ) {
      return parsed as AgendaCache;
    }
  } catch {
    // A missing, stale, or corrupt derived cache is always safe to rebuild.
  }
  return emptyAgendaCache(rootDir);
}

function writeAgendaCache(cacheFile: string, cache: AgendaCache): void {
  try {
    fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
    const tempFile = `${cacheFile}.${process.pid}.tmp`;
    fs.writeFileSync(tempFile, JSON.stringify(cache) + "\n", "utf8");
    fs.renameSync(tempFile, cacheFile);
  } catch {
    // Agenda remains fully functional when its disposable cache cannot be written.
  }
}

function pruneAgendaCacheQueries(cache: AgendaCache, keepQueryKey: string): void {
  const queryKeys = Object.keys(cache.queries);
  if (queryKeys.length <= AGENDA_CACHE_MAX_QUERIES) return;

  queryKeys
    .filter((queryKey) => queryKey !== keepQueryKey)
    .sort((a, b) => {
      const aUpdated = cache.queries[a]?.updatedAt || "";
      const bUpdated = cache.queries[b]?.updatedAt || "";
      return bUpdated.localeCompare(aUpdated);
    })
    .slice(AGENDA_CACHE_MAX_QUERIES - 1)
    .forEach((queryKey) => delete cache.queries[queryKey]);
}

function agendaCacheFileEntryMatches(entry: AgendaCacheFileEntry | undefined, stat: fs.Stats): boolean {
  return Boolean(
    entry
    && Array.isArray(entry.items)
    && entry.size === stat.size
    && entry.mtimeMs === stat.mtimeMs
    && entry.ctimeMs === stat.ctimeMs,
  );
}

function agendaCacheRootForFiles(filePaths: string[], fallbackRoot: string): string {
  const firstFile = filePaths[0];
  if (!firstFile) return path.resolve(fallbackRoot);

  let commonRoot = path.dirname(path.resolve(firstFile));
  for (const filePath of filePaths.slice(1)) {
    const fileDir = path.dirname(path.resolve(filePath));
    while (true) {
      const relative = path.relative(commonRoot, fileDir);
      if (relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative))) {
        break;
      }
      const parent = path.dirname(commonRoot);
      if (parent === commonRoot) break;
      commonRoot = parent;
    }
  }
  return commonRoot;
}

function deduplicateAgendaPlanningItems(items: ScheduledItem[]): ScheduledItem[] {
  const deduplicated: ScheduledItem[] = [];
  const itemIndexesBySourceDate = new Map<string, number>();

  for (const item of items) {
    const key = `${item.filePath}\u0000${item.lineNumber}\u0000${item.date}`;
    const existingIndex = itemIndexesBySourceDate.get(key);

    if (existingIndex === undefined) {
      itemIndexesBySourceDate.set(key, deduplicated.length);
      deduplicated.push(item);
      continue;
    }

    const existing = deduplicated[existingIndex];
    if (!existing) continue;
    if (item.deadlineWarning) {
      // A warning copy lands before its due date, so an existing DEADLINE row
      // on that day is an unlabeled prewarning row. A SCHEDULED row already
      // puts the task on that day and stays.
      if (existing.kind === "DEADLINE" && !existing.deadlineWarning) deduplicated[existingIndex] = item;
    } else if (existing.deadlineWarning ? item.kind !== "DEADLINE" : existing.kind !== "DEADLINE" && item.kind === "DEADLINE") {
      deduplicated[existingIndex] = item;
    }
  }

  return deduplicated;
}

type AgendaStatusBucket = "todo" | "in_progress" | "done" | "canceled" | "custom";
type AgendaPlanningKind = "SCHEDULED" | "DEADLINE";
type AgendaWhenBucket = "overdue" | "today" | "upcoming";

type AgendaStatusFilter = Set<AgendaStatusBucket> | null;
type AgendaExcludeStatusFilter = Set<AgendaStatusBucket> | null;
type AgendaPlanningFilter = Set<AgendaPlanningKind> | null;
type AgendaExcludePlanningFilter = Set<AgendaPlanningKind> | null;
type AgendaWhenFilter = Set<AgendaWhenBucket> | null;
type AgendaExcludeWhenFilter = Set<AgendaWhenBucket> | null;
type AgendaWeekdayFilter = Set<number> | null;
type AgendaExcludeWeekdayFilter = Set<number> | null;
type AgendaWeekFilter = Set<number> | null;
type AgendaExcludeWeekFilter = Set<number> | null;
type AgendaDayOfMonthFilter = Set<number> | null;
type AgendaExcludeDayOfMonthFilter = Set<number> | null;
type AgendaMonthFilter = Set<number> | null;
type AgendaExcludeMonthFilter = Set<number> | null;
type AgendaQuarterFilter = Set<number> | null;
type AgendaExcludeQuarterFilter = Set<number> | null;
type AgendaYearFilter = Set<number> | null;
type AgendaExcludeYearFilter = Set<number> | null;
type AgendaDateFilter = Set<string> | null;
type AgendaExcludeDateFilter = Set<string> | null;
type AgendaLevelFilter = Set<number> | null;
type AgendaExcludeLevelFilter = Set<number> | null;
type AgendaMatchFilter = string[] | null;
type AgendaExcludeMatchFilter = string[] | null;
type AgendaTagFilter = string[] | null;
type AgendaIdFilter = Set<string> | null;
type AgendaTodoFilter = Set<string> | null;
type AgendaPriorityFilter = Set<string> | null;
type AgendaTimeRange = {
  startMinutes: number;
  endMinutes: number;
  wraps: boolean;
};
type AgendaTimeFilter = { tokens: Set<string>; ranges: AgendaTimeRange[] } | null;
type AgendaEffortFilter = Set<string> | null;
type AgendaPropertyFilterTerm = { key: string; value: string };
type AgendaPropertyFilter = AgendaPropertyFilterTerm[] | null;
type AgendaExcludeTagFilter = string[] | null;
type AgendaExcludeTodoFilter = Set<string> | null;
type AgendaExcludePriorityFilter = Set<string> | null;
type AgendaExcludeTimeFilter = AgendaTimeFilter;
type AgendaExcludeEffortFilter = Set<string> | null;
type AgendaExcludePropertyFilter = AgendaPropertyFilterTerm[] | null;
type AgendaExcludeIdFilter = AgendaIdFilter;
type AgendaFileFilter = string[] | null;
type AgendaExcludeFileFilter = string[] | null;
type AgendaTodoOrder = Map<string, number> | null;
type AgendaStatusOrder = Map<AgendaStatusBucket, number> | null;
type AgendaKindOrder = Map<AgendaPlanningKind, number> | null;
type AgendaPriorityOrder = Map<string, number> | null;
type AgendaTagOrder = Map<string, number> | null;
type AgendaEffortOrder = Map<string, number> | null;
type AgendaSortKey =
  | "file"
  | "headline"
  | "todo"
  | "status"
  | "priority"
  | "effort"
  | "id"
  | "level"
  | "time"
  | "kind"
  | "tags"
  | "line";
type AgendaSortDirection = "asc" | "desc";
type AgendaSortField = { key: AgendaSortKey; direction: AgendaSortDirection };
type AgendaSortOrder = AgendaSortField[] | null;
type AgendaGroupField = { key: AgendaSortKey; direction: AgendaSortDirection };
type AgendaGroupOrder = AgendaGroupField[] | null;
type AgendaDateOrder = "asc" | "desc";
type AgendaTuiMode = "focus" | "today" | "range";

type AgendaTuiSection = {
  key: string;
  label: string;
  items: ScheduledItem[];
  hint?: string;
};

type AgendaTuiRow =
  | { type: "section"; key: string; label: string; count: number; hint?: string; collapsed: boolean }
  | { type: "item"; item: ScheduledItem; sectionKey: string; hint?: string };

const AGENDA_STATUS_ALLOWED_HINT =
  "default|none, all, active(=todo,in_progress), actionable(=todo,in_progress,custom), open|todo|backlog, in_progress|in-progress|prog|doing|started|waiting|wait|blocked|next|wip|hold|on-hold|paused, done|complete|completed|finish|finished|resolved, canceled|cancel|cancelled, closed(=done,canceled), custom";
const AGENDA_STATUS_ORDER_ALLOWED_HINT =
  "default|none, all(=todo,in_progress,done,canceled,custom), active(=todo,in_progress), actionable(=todo,in_progress,custom), todo|open|backlog, in_progress|in-progress|prog|doing|started|waiting|wait|blocked|next|wip|hold|on-hold|paused, done|complete|completed|finish|finished|resolved, canceled|cancel|cancelled, closed(=done,canceled), custom";
const AGENDA_KIND_ORDER_ALLOWED_HINT = "default, scheduled, deadline";
const AGENDA_PRIORITY_ORDER_ALLOWED_HINT = "default, A-Z or 0-9 (for example: A,[#B],9)";
const AGENDA_EFFORT_ORDER_EMPTY = "__none__";
const AGENDA_KIND_ALLOWED_HINT = "all, scheduled, deadline";
const AGENDA_WHEN_ALLOWED_HINT = "all, overdue, today, upcoming";
const AGENDA_WEEKDAY_ALLOWED_HINT =
  "all, mon|monday, tue|tuesday, wed|wednesday, thu|thursday, fri|friday, sat|saturday, sun|sunday, weekday, weekend";
const AGENDA_WEEK_ALLOWED_HINT = "all, 1-53 or w1..w53 (for example: 1,w2,week10,53)";
const AGENDA_DAY_OF_MONTH_ALLOWED_HINT = "all, 1-31 (for example: 1,15,31)";
const AGENDA_MONTH_ALLOWED_HINT =
  "all, 1-12 or jan|january...dec|december (for example: 1,jan,mar,12)";
const AGENDA_QUARTER_ALLOWED_HINT = "all, 1-4 or q1..q4 (for example: 1,q2,quarter3,4)";
const AGENDA_YEAR_ALLOWED_HINT = "all, positive year numbers (for example: 2025,2026,2027)";
const AGENDA_DATE_ALLOWED_HINT = "all, YYYY-MM-DD (for example: 2026-02-17,2026-02-20)";
const AGENDA_LEVEL_ALLOWED_HINT = "positive integers (for example: 1,2,3)";
const AGENDA_ID_ALLOWED_HINT = "all, exact ID/CUSTOM_ID terms (for example: 9f8a7b6c,project-roadmap)";
const AGENDA_PRIORITY_ALLOWED_HINT = "A-Z or 0-9 (for example: A,B,C or [#A],[#B])";
const AGENDA_TIME_ALLOWED_HINT =
  "all, timed, untimed, HH:MM, HH:MM-HH:MM (for example: 09:30,17:45,09:00-12:30,22:00-02:00)";
const AGENDA_PROPERTY_ALLOWED_HINT = "KEY=VALUE (for example: OWNER=Avi,TEAM=Platform)";
const AGENDA_SORT_ALLOWED_HINT = "default, [+-]file, [+-]headline, [+-]todo, [+-]status, [+-]priority, [+-]effort, [+-]id, [+-]level, [+-]time, [+-]kind, [+-]tags, [+-]line";
const AGENDA_GROUP_ALLOWED_HINT = AGENDA_SORT_ALLOWED_HINT;
const AGENDA_DATE_ORDER_ALLOWED_HINT = "asc, desc";

const AGENDA_STATUS_BUCKET_TOKEN_MAP: Record<string, AgendaStatusBucket> = {
  todo: "todo",
  open: "todo",
  backlog: "todo",
  in_progress: "in_progress",
  inprogress: "in_progress",
  prog: "in_progress",
  doing: "in_progress",
  started: "in_progress",
  waiting: "in_progress",
  wait: "in_progress",
  blocked: "in_progress",
  next: "in_progress",
  wip: "in_progress",
  hold: "in_progress",
  on_hold: "in_progress",
  onhold: "in_progress",
  paused: "in_progress",
  pause: "in_progress",
  done: "done",
  complete: "done",
  completed: "done",
  finish: "done",
  finished: "done",
  closed: "done",
  resolved: "done",
  canceled: "canceled",
  cancelled: "canceled",
  cancel: "canceled",
  custom: "custom",
};

function agendaStatusBucketForKeyword(todo: string | undefined): AgendaStatusBucket | null {
  const token = normalizeAgendaStatusFilterToken(String(todo || ""));
  if (!token) return null;
  return AGENDA_STATUS_BUCKET_TOKEN_MAP[token] || "custom";
}

function normalizeAgendaStatusFilterToken(tokenRaw: string): string {
  return tokenRaw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function splitAgendaStatusFilterTokens(raw: string): string[] {
  return String(raw || "").split(/[;,\n]/);
}

function parseTodoStatusArg(rawStatus: string): TodoStatus | "" {
  const bucket = agendaStatusBucketForKeyword(rawStatus);
  return bucket && bucket !== "custom" ? bucket : "";
}

function parseAgendaStatusFilterArgs(rawArgs: string[]): {
  filter: AgendaStatusFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<AgendaStatusBucket>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = normalizeAgendaStatusFilterToken(tokenRaw);
    if (!token) return;

    if (token === "none") {
      return;
    }

    if (token === "all" || token === "default") {
      sawAll = true;
      return;
    }

    if (token === "active") {
      selected.add("todo");
      selected.add("in_progress");
      return;
    }

    if (token === "actionable") {
      selected.add("todo");
      selected.add("in_progress");
      selected.add("custom");
      return;
    }

    if (token === "closed") {
      selected.add("done");
      selected.add("canceled");
      return;
    }

    const bucket = AGENDA_STATUS_BUCKET_TOKEN_MAP[token];
    if (bucket) {
      selected.add(bucket);
      return;
    }

    invalid.push(tokenRaw.trim());
  };

  for (const raw of rawArgs) {
    for (const token of splitAgendaStatusFilterTokens(raw)) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeStatusFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeStatusFilter;
  invalid: string[];
} {
  return parseAgendaStatusFilterArgs(rawArgs);
}

function parseAgendaKindFilterArgs(rawArgs: string[]): {
  filter: AgendaPlanningFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<AgendaPlanningKind>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "scheduled") {
      selected.add("SCHEDULED");
      return;
    }

    if (token === "deadline") {
      selected.add("DEADLINE");
      return;
    }

    invalid.push(tokenRaw.trim());
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeKindFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludePlanningFilter;
  invalid: string[];
} {
  return parseAgendaKindFilterArgs(rawArgs);
}

function parseAgendaWhenFilterArgs(rawArgs: string[]): {
  filter: AgendaWhenFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<AgendaWhenBucket>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "overdue" || token === "today" || token === "upcoming") {
      selected.add(token as AgendaWhenBucket);
      return;
    }

    invalid.push(tokenRaw.trim());
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeWhenFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeWhenFilter;
  invalid: string[];
} {
  return parseAgendaWhenFilterArgs(rawArgs);
}

const AGENDA_WEEKDAY_TOKEN_MAP: Record<string, number[]> = {
  sunday: [0],
  sun: [0],
  monday: [1],
  mon: [1],
  tuesday: [2],
  tue: [2],
  tues: [2],
  wednesday: [3],
  wed: [3],
  thursday: [4],
  thu: [4],
  thur: [4],
  thurs: [4],
  friday: [5],
  fri: [5],
  saturday: [6],
  sat: [6],
  weekday: [1, 2, 3, 4, 5],
  weekdays: [1, 2, 3, 4, 5],
  weekend: [0, 6],
  weekends: [0, 6],
};

function parseAgendaWeekdayFilterArgs(rawArgs: string[]): {
  filter: AgendaWeekdayFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    const dayIndexes = AGENDA_WEEKDAY_TOKEN_MAP[token];
    if (!dayIndexes) {
      invalid.push(tokenRaw.trim());
      return;
    }

    for (const dayIndex of dayIndexes) {
      selected.add(dayIndex);
    }
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeWeekdayFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeWeekdayFilter;
  invalid: string[];
} {
  return parseAgendaWeekdayFilterArgs(rawArgs);
}

function parseAgendaWeekFilterArgs(rawArgs: string[]): {
  filter: AgendaWeekFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      const weekMatch = /^(?:w|week)?(\d{1,2})$/.exec(token);
      if (!weekMatch) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const week = Number.parseInt(weekMatch[1] ?? "", 10);
      if (!Number.isFinite(week) || week < 1 || week > 53) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(week);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeWeekFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeWeekFilter;
  invalid: string[];
} {
  return parseAgendaWeekFilterArgs(rawArgs);
}

function parseAgendaDayOfMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaDayOfMonthFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      if (!/^\d+$/.test(token)) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const day = Number.parseInt(token, 10);
      if (!Number.isFinite(day) || day < 1 || day > 31) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(day);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeDayOfMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeDayOfMonthFilter;
  invalid: string[];
} {
  return parseAgendaDayOfMonthFilterArgs(rawArgs);
}

const AGENDA_MONTH_TOKEN_MAP: Record<string, number> = {
  jan: 1,
  january: 1,
  feb: 2,
  february: 2,
  mar: 3,
  march: 3,
  apr: 4,
  april: 4,
  may: 5,
  jun: 6,
  june: 6,
  jul: 7,
  july: 7,
  aug: 8,
  august: 8,
  sep: 9,
  sept: 9,
  september: 9,
  oct: 10,
  october: 10,
  nov: 11,
  november: 11,
  dec: 12,
  december: 12,
};

function parseAgendaMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaMonthFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      if (/^\d+$/.test(token)) {
        const month = Number.parseInt(token, 10);
        if (!Number.isFinite(month) || month < 1 || month > 12) {
          invalid.push(tokenRaw.trim());
          continue;
        }
        selected.add(month);
        continue;
      }

      const month = AGENDA_MONTH_TOKEN_MAP[token];
      if (!month) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(month);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeMonthFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeMonthFilter;
  invalid: string[];
} {
  return parseAgendaMonthFilterArgs(rawArgs);
}

function parseAgendaQuarterFilterArgs(rawArgs: string[]): {
  filter: AgendaQuarterFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      const quarterMatch = /^(?:q|quarter)?([1-4])$/.exec(token);
      if (!quarterMatch) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const quarter = Number.parseInt(quarterMatch[1] ?? "", 10);
      if (!Number.isFinite(quarter) || quarter < 1 || quarter > 4) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(quarter);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeQuarterFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeQuarterFilter;
  invalid: string[];
} {
  return parseAgendaQuarterFilterArgs(rawArgs);
}

function parseAgendaYearFilterArgs(rawArgs: string[]): {
  filter: AgendaYearFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "all") {
        sawAll = true;
        continue;
      }

      if (!/^\d+$/.test(token)) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      const year = Number.parseInt(token, 10);
      if (!Number.isFinite(year) || year < 1) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      selected.add(year);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeYearFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeYearFilter;
  invalid: string[];
} {
  return parseAgendaYearFilterArgs(rawArgs);
}

function parseAgendaDateFilterArgs(rawArgs: string[]): {
  filter: AgendaDateFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const invalid: string[] = [];
  let sawAll = false;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      if (token.toLowerCase() === "all") {
        sawAll = true;
        continue;
      }

      if (!/^\d{4}-\d{2}-\d{2}$/.test(token)) {
        invalid.push(token);
        continue;
      }

      try {
        const normalized = parseIsoDate(token).toISOString().slice(0, 10);
        selected.add(normalized);
      } catch {
        invalid.push(token);
      }
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeDateFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeDateFilter;
  invalid: string[];
} {
  return parseAgendaDateFilterArgs(rawArgs);
}

function parseAgendaLevelFilterArgs(rawArgs: string[]): {
  filter: AgendaLevelFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<number>();
  const invalid: string[] = [];

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;
      if (!/^\d+$/.test(token)) {
        invalid.push(token);
        continue;
      }

      const level = Number.parseInt(token, 10);
      if (!Number.isFinite(level) || level < 1) {
        invalid.push(token);
        continue;
      }

      selected.add(level);
    }
  }

  return { filter: selected.size > 0 ? selected : null, invalid };
}

function parseAgendaExcludeLevelFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeLevelFilter;
  invalid: string[];
} {
  return parseAgendaLevelFilterArgs(rawArgs);
}

function parseAgendaMatchFilterArgs(rawArgs: string[]): AgendaMatchFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaExcludeMatchFilterArgs(rawArgs: string[]): AgendaExcludeMatchFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaTagFilterArgs(rawArgs: string[]): AgendaTagFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaIdFilterArgs(rawArgs: string[]): {
  filter: AgendaIdFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    selected.add(token);
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { filter: selected.size > 0 ? selected : null, invalid };
  }

  if (sawAll || selected.size === 0) {
    return { filter: null, invalid: [] };
  }

  return { filter: selected, invalid: [] };
}

function parseAgendaExcludeIdFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeIdFilter;
  invalid: string[];
} {
  return parseAgendaIdFilterArgs(rawArgs);
}

function parseAgendaTodoFilterArgs(rawArgs: string[]): AgendaTodoFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toUpperCase())
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
}

function normalizeAgendaPriorityToken(tokenRaw: string): string | null {
  let token = tokenRaw.trim();
  if (!token) return null;

  const bracketed = token.match(/^\[#([A-Za-z0-9])\]$/);
  if (bracketed) {
    token = bracketed[1] ?? "";
  }

  if (token.length !== 1 || !/^[A-Za-z0-9]$/.test(token)) return null;
  return token.toUpperCase();
}

function parseAgendaEffortToMinutes(tokenRaw: string): number | null {
  const token = String(tokenRaw || "").trim().toLowerCase().replace(/\s+/g, "");
  if (!token) return null;

  const parseIntStrict = (raw: string): number | null => {
    if (!/^\d+$/.test(raw)) return null;
    const parsed = Number.parseInt(raw, 10);
    return Number.isFinite(parsed) ? parsed : null;
  };

  const hm = token.match(/^(\d+):(\d{1,2})$/);
  if (hm) {
    const hours = parseIntStrict(hm[1] ?? "");
    const minutes = parseIntStrict(hm[2] ?? "");
    if (hours === null || minutes === null || minutes >= 60) return null;
    return hours * 60 + minutes;
  }

  const hoursOnly = token.match(/^(\d+)h$/);
  if (hoursOnly) {
    const hours = parseIntStrict(hoursOnly[1] ?? "");
    return hours === null ? null : hours * 60;
  }

  const minutesOnly = token.match(/^(\d+)m$/);
  if (minutesOnly) {
    return parseIntStrict(minutesOnly[1] ?? "");
  }

  const hmCompact = token.match(/^(\d+)h(\d+)m$/);
  if (hmCompact) {
    const hours = parseIntStrict(hmCompact[1] ?? "");
    const minutes = parseIntStrict(hmCompact[2] ?? "");
    if (hours === null || minutes === null) return null;
    return hours * 60 + minutes;
  }

  return parseIntStrict(token);
}

function normalizeAgendaEffortToken(tokenRaw: string): string {
  const token = String(tokenRaw || "").trim();
  if (!token) return "";

  const minutes = parseAgendaEffortToMinutes(token);
  if (minutes !== null) {
    return `m:${minutes}`;
  }

  return token.toLowerCase().replace(/\s+/g, " ");
}

function parseAgendaPriorityFilterArgs(rawArgs: string[]): {
  filter: AgendaPriorityFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const invalid: string[] = [];

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      const normalized = normalizeAgendaPriorityToken(token);
      if (!normalized) {
        invalid.push(token);
        continue;
      }

      selected.add(normalized);
    }
  }

  return { filter: selected.size > 0 ? selected : null, invalid };
}

function parseAgendaExcludePriorityFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludePriorityFilter;
  invalid: string[];
} {
  return parseAgendaPriorityFilterArgs(rawArgs);
}

const AGENDA_TIME_FILTER_TIMED = "__timed__";
const AGENDA_TIME_FILTER_UNTIMED = "__untimed__";

function parseAgendaTimeRangeToken(raw: string): AgendaTimeRange | null {
  const match = String(raw || "").match(/^(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})$/);
  if (!match) return null;

  const startToken = normalizeAgendaTimeToken(match[1] || "");
  const endToken = normalizeAgendaTimeToken(match[2] || "");
  if (!startToken || !endToken) return null;

  const startMinutes = parseAgendaTimeToMinutes(startToken);
  const endMinutes = parseAgendaTimeToMinutes(endToken);
  if (startMinutes === null || endMinutes === null) return null;

  return {
    startMinutes,
    endMinutes,
    wraps: startMinutes > endMinutes,
  };
}

function parseAgendaTimeFilterArgs(rawArgs: string[]): {
  filter: AgendaTimeFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const selected = new Set<string>();
  const ranges: AgendaTimeRange[] = [];
  const seenRanges = new Set<string>();
  const invalid: string[] = [];
  let sawAll = false;

  const addToken = (tokenRaw: string): void => {
    const token = tokenRaw.trim().toLowerCase();
    if (!token) return;

    if (token === "all") {
      sawAll = true;
      return;
    }

    if (token === "timed" || token === "time") {
      selected.add(AGENDA_TIME_FILTER_TIMED);
      return;
    }

    if (token === "untimed" || token === "no-time" || token === "none") {
      selected.add(AGENDA_TIME_FILTER_UNTIMED);
      return;
    }

    if (token.includes("-")) {
      const parsedRange = parseAgendaTimeRangeToken(token);
      if (!parsedRange) {
        invalid.push(tokenRaw.trim());
        return;
      }

      const rangeKey = `${parsedRange.startMinutes}-${parsedRange.endMinutes}`;
      if (!seenRanges.has(rangeKey)) {
        seenRanges.add(rangeKey);
        ranges.push(parsedRange);
      }
      return;
    }

    const normalized = normalizeAgendaTimeToken(token);
    if (!normalized) {
      invalid.push(tokenRaw.trim());
      return;
    }

    selected.add(normalized);
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      addToken(tokenRaw);
    }
  }

  const builtFilter: AgendaTimeFilter =
    selected.size > 0 || ranges.length > 0
      ? {
          tokens: selected,
          ranges,
        }
      : null;

  if (invalid.length > 0) {
    return { filter: builtFilter, invalid };
  }

  if (sawAll || !builtFilter) {
    return { filter: null, invalid: [] };
  }

  return { filter: builtFilter, invalid: [] };
}

function parseAgendaExcludeTimeFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludeTimeFilter;
  invalid: string[];
} {
  return parseAgendaTimeFilterArgs(rawArgs);
}

function parseAgendaEffortFilterArgs(rawArgs: string[]): AgendaEffortFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => normalizeAgendaEffortToken(token))
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
}

function parseAgendaExcludeEffortFilterArgs(rawArgs: string[]): AgendaExcludeEffortFilter {
  return parseAgendaEffortFilterArgs(rawArgs);
}

function normalizeAgendaPropertyKey(raw: string): string {
  return String(raw || "")
    .trim()
    .replace(/^:+|:+$/g, "")
    .toUpperCase();
}

function normalizeAgendaPropertyValue(raw: string): string {
  return String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ");
}

function parseAgendaPropertyFilterArgs(rawArgs: string[]): {
  filter: AgendaPropertyFilter;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { filter: null, invalid: [] };

  const filters: AgendaPropertyFilterTerm[] = [];
  const invalid: string[] = [];
  const seen = new Set<string>();

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      const splitAt = token.indexOf("=");
      if (splitAt <= 0 || splitAt === token.length - 1) {
        invalid.push(token);
        continue;
      }

      const key = normalizeAgendaPropertyKey(token.slice(0, splitAt));
      const value = normalizeAgendaPropertyValue(token.slice(splitAt + 1));
      if (!key || !value) {
        invalid.push(token);
        continue;
      }

      const dedupeKey = `${key}=${value}`;
      if (seen.has(dedupeKey)) continue;
      seen.add(dedupeKey);
      filters.push({ key, value });
    }
  }

  return { filter: filters.length > 0 ? filters : null, invalid };
}

function parseAgendaExcludePropertyFilterArgs(rawArgs: string[]): {
  filter: AgendaExcludePropertyFilter;
  invalid: string[];
} {
  return parseAgendaPropertyFilterArgs(rawArgs);
}

function parseAgendaExcludeTagFilterArgs(rawArgs: string[]): AgendaExcludeTagFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaExcludeTodoFilterArgs(rawArgs: string[]): AgendaExcludeTodoFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toUpperCase())
    .filter(Boolean);

  return tokens.length > 0 ? new Set(tokens) : null;
}

function parseAgendaTodoOrderArgs(rawArgs: string[]): AgendaTodoOrder {
  if (rawArgs.length === 0) return null;

  const ordered: string[] = [];
  const seen = new Set<string>();

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;

      const normalized = token.toUpperCase();
      if (normalized === "DEFAULT") continue;
      if (seen.has(normalized)) continue;

      seen.add(normalized);
      ordered.push(normalized);
    }
  }

  if (ordered.length === 0) return null;

  const rank = new Map<string, number>();
  for (let i = 0; i < ordered.length; i += 1) {
    rank.set(ordered[i]!, i);
  }

  return rank;
}

function parseAgendaStatusOrderArgs(rawArgs: string[]): {
  statusOrder: AgendaStatusOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { statusOrder: null, invalid: [] };

  const rank = new Map<AgendaStatusBucket, number>();
  const invalid: string[] = [];
  let nextRank = 0;

  const expandToken = (tokenRaw: string): AgendaStatusBucket[] | null => {
    const token = normalizeAgendaStatusFilterToken(tokenRaw);
    if (token === "all") return ["todo", "in_progress", "done", "canceled", "custom"];
    if (token === "active") return ["todo", "in_progress"];
    if (token === "actionable") return ["todo", "in_progress", "custom"];
    if (token === "closed") return ["done", "canceled"];
    const bucket = AGENDA_STATUS_BUCKET_TOKEN_MAP[token];
    if (bucket) return [bucket];
    return null;
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of splitAgendaStatusFilterTokens(raw)) {
      const token = normalizeAgendaStatusFilterToken(tokenRaw);
      if (!token) continue;
      if (token === "default" || token === "none") continue;

      const expanded = expandToken(tokenRaw);
      if (!expanded || expanded.length === 0) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      for (const bucket of expanded) {
        if (rank.has(bucket)) continue;
        rank.set(bucket, nextRank);
        nextRank += 1;
      }
    }
  }

  if (invalid.length > 0) {
    return { statusOrder: rank.size > 0 ? rank : null, invalid };
  }

  return { statusOrder: rank.size > 0 ? rank : null, invalid: [] };
}

function parseAgendaKindOrderArgs(rawArgs: string[]): {
  kindOrder: AgendaKindOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { kindOrder: null, invalid: [] };

  const rank = new Map<AgendaPlanningKind, number>();
  const invalid: string[] = [];
  let nextRank = 0;

  const normalizeToken = (token: string): AgendaPlanningKind | null => {
    if (token === "scheduled") return "SCHEDULED";
    if (token === "deadline") return "DEADLINE";
    return null;
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;
      if (token === "default") continue;

      const normalized = normalizeToken(token);
      if (!normalized) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  if (invalid.length > 0) {
    return { kindOrder: rank.size > 0 ? rank : null, invalid };
  }

  return { kindOrder: rank.size > 0 ? rank : null, invalid: [] };
}

function parseAgendaPriorityOrderArgs(rawArgs: string[]): {
  priorityOrder: AgendaPriorityOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { priorityOrder: null, invalid: [] };

  const rank = new Map<string, number>();
  const invalid: string[] = [];
  let nextRank = 0;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim();
      if (!token) continue;
      if (token.toLowerCase() === "default") continue;

      const normalized = normalizeAgendaPriorityToken(token);
      if (!normalized) {
        invalid.push(tokenRaw.trim());
        continue;
      }

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  if (invalid.length > 0) {
    return { priorityOrder: rank.size > 0 ? rank : null, invalid };
  }

  return { priorityOrder: rank.size > 0 ? rank : null, invalid: [] };
}

function parseAgendaTagOrderArgs(rawArgs: string[]): AgendaTagOrder {
  if (rawArgs.length === 0) return null;

  const rank = new Map<string, number>();
  let nextRank = 0;

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;
      if (token === "default") continue;

      if (!rank.has(token)) {
        rank.set(token, nextRank);
        nextRank += 1;
      }
    }
  }

  return rank.size > 0 ? rank : null;
}

function parseAgendaEffortOrderArgs(rawArgs: string[]): AgendaEffortOrder {
  if (rawArgs.length === 0) return null;

  const rank = new Map<string, number>();
  let nextRank = 0;

  const normalizeToken = (tokenRaw: string): string | null => {
    const token = tokenRaw.trim();
    if (!token) return null;

    const lowered = token.toLowerCase();
    if (lowered === "default") return null;
    if (lowered === "none" || lowered === "empty" || lowered === "unset" || lowered === "no-effort") {
      return AGENDA_EFFORT_ORDER_EMPTY;
    }

    return normalizeAgendaEffortToken(token);
  };

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const normalized = normalizeToken(tokenRaw);
      if (!normalized) continue;

      if (!rank.has(normalized)) {
        rank.set(normalized, nextRank);
        nextRank += 1;
      }
    }
  }

  return rank.size > 0 ? rank : null;
}

function parseAgendaFileFilterArgs(rawArgs: string[]): AgendaFileFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaExcludeFileFilterArgs(rawArgs: string[]): AgendaExcludeFileFilter {
  if (rawArgs.length === 0) return null;

  const tokens = rawArgs
    .flatMap((raw) => String(raw).split(","))
    .map((token) => token.trim().toLowerCase())
    .filter(Boolean);

  return tokens.length > 0 ? tokens : null;
}

function parseAgendaSortArgs(rawArgs: string[]): {
  sortOrder: AgendaSortOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) return { sortOrder: null, invalid: [] };

  const sortOrder: AgendaSortField[] = [];
  const seen = new Set<AgendaSortKey>();
  const invalid: string[] = [];

  const addToken = (tokenRaw: string): void => {
    const original = tokenRaw.trim();
    let token = original.toLowerCase();
    if (!token) return;

    if (token === "default") {
      return;
    }

    let direction: AgendaSortDirection = "asc";
    if (token.startsWith("+")) {
      token = token.slice(1);
    } else if (token.startsWith("-")) {
      direction = "desc";
      token = token.slice(1);
    }

    if (token.endsWith(":asc")) {
      direction = "asc";
      token = token.slice(0, -":asc".length);
    } else if (token.endsWith(":desc")) {
      direction = "desc";
      token = token.slice(0, -":desc".length);
    }

    let normalized: AgendaSortKey | null = null;
    if (token === "file" || token === "path") normalized = "file";
    else if (token === "headline" || token === "title") normalized = "headline";
    else if (token === "todo" || token === "keyword") normalized = "todo";
    else if (token === "status" || token === "state" || token === "bucket") normalized = "status";
    else if (token === "priority" || token === "prio") normalized = "priority";
    else if (token === "effort" || token === "estimate") normalized = "effort";
    else if (token === "id" || token === "custom-id" || token === "custom_id" || token === "node") normalized = "id";
    else if (token === "level" || token === "depth") normalized = "level";
    else if (token === "time" || token === "clock") normalized = "time";
    else if (token === "kind" || token === "planning") normalized = "kind";
    else if (token === "tags" || token === "tag" || token === "labels") normalized = "tags";
    else if (token === "line" || token === "position") normalized = "line";

    if (!normalized) {
      invalid.push(original);
      return;
    }

    if (!seen.has(normalized)) {
      seen.add(normalized);
      sortOrder.push({ key: normalized, direction });
    }
  };

  for (const raw of rawArgs) {
    for (const token of String(raw).split(",")) {
      addToken(token);
    }
  }

  if (invalid.length > 0) {
    return { sortOrder: sortOrder.length > 0 ? sortOrder : null, invalid };
  }

  if (sortOrder.length === 0) {
    return { sortOrder: null, invalid: [] };
  }

  return { sortOrder, invalid: [] };
}

function parseAgendaGroupArgs(rawArgs: string[]): {
  groupOrder: AgendaGroupOrder;
  invalid: string[];
} {
  const parsed = parseAgendaSortArgs(rawArgs);
  return {
    groupOrder: parsed.sortOrder,
    invalid: parsed.invalid,
  };
}

function parseAgendaDateOrderArgs(rawArgs: string[]): {
  dateOrder: AgendaDateOrder;
  invalid: string[];
} {
  if (rawArgs.length === 0) {
    return { dateOrder: "asc", invalid: [] };
  }

  const invalid: string[] = [];
  let dateOrder: AgendaDateOrder = "asc";

  for (const raw of rawArgs) {
    for (const tokenRaw of String(raw).split(",")) {
      const token = tokenRaw.trim().toLowerCase();
      if (!token) continue;

      if (token === "asc" || token === "ascending" || token === "oldest") {
        dateOrder = "asc";
        continue;
      }

      if (token === "desc" || token === "descending" || token === "newest") {
        dateOrder = "desc";
        continue;
      }

      invalid.push(tokenRaw.trim());
    }
  }

  return { dateOrder, invalid };
}

function matchesAgendaTextFilter(headline: string, textFilter: AgendaMatchFilter): boolean {
  if (!textFilter || textFilter.length === 0) return true;

  const haystack = String(headline || "").trim().toLowerCase();
  return textFilter.some((token) => haystack.includes(token));
}

function matchesAgendaExcludeTextFilter(headline: string, excludeTextFilter: AgendaExcludeMatchFilter): boolean {
  if (!excludeTextFilter || excludeTextFilter.length === 0) return true;

  const haystack = String(headline || "").trim().toLowerCase();
  return !excludeTextFilter.some((token) => haystack.includes(token));
}

function matchesAgendaTagFilter(tags: string[], tagFilter: AgendaTagFilter): boolean {
  if (!tagFilter || tagFilter.length === 0) return true;

  const normalizedTags = tags.map((tag) => String(tag).trim().toLowerCase()).filter(Boolean);
  return tagFilter.some((token) => normalizedTags.includes(token));
}

function agendaIdsFromProperties(properties: Record<string, string>): string[] {
  const candidates = [properties.ID, properties.CUSTOM_ID]
    .map((value) => String(value || "").trim().toLowerCase())
    .filter(Boolean);
  return [...new Set(candidates)];
}

function agendaPrimaryIdFromProperties(properties: Record<string, string>): string | undefined {
  const directId = String(properties.ID || "").trim();
  if (directId) return directId;

  const customId = String(properties.CUSTOM_ID || "").trim();
  if (customId) return customId;

  return undefined;
}

function normalizeAgendaItemId(item: ScheduledItem): string {
  return String(item.id || "").trim().toLowerCase();
}

function matchesAgendaIdFilter(properties: Record<string, string>, idFilter: AgendaIdFilter): boolean {
  if (!idFilter || idFilter.size === 0) return true;
  const ids = agendaIdsFromProperties(properties);
  if (ids.length === 0) return false;
  return ids.some((id) => idFilter.has(id));
}

function matchesAgendaExcludeIdFilter(properties: Record<string, string>, excludeIdFilter: AgendaExcludeIdFilter): boolean {
  if (!excludeIdFilter || excludeIdFilter.size === 0) return true;
  const ids = agendaIdsFromProperties(properties);
  if (ids.length === 0) return true;
  return !ids.some((id) => excludeIdFilter.has(id));
}

function matchesAgendaTodoFilter(todo: string | undefined, todoFilter: AgendaTodoFilter): boolean {
  if (!todoFilter || todoFilter.size === 0) return true;
  const normalized = String(todo || "").trim().toUpperCase();
  if (!normalized) return false;
  return todoFilter.has(normalized);
}

function matchesAgendaPriorityFilter(priority: string | undefined, priorityFilter: AgendaPriorityFilter): boolean {
  if (!priorityFilter || priorityFilter.size === 0) return true;
  const normalized = normalizeAgendaPriorityToken(String(priority || ""));
  if (!normalized) return false;
  return priorityFilter.has(normalized);
}

function matchesAgendaTimeFilterTokenSet(
  time: string | undefined,
  timeFilter: Exclude<AgendaTimeFilter, null>,
): boolean {
  const normalized = normalizeAgendaTimeToken(String(time || ""));
  const hasTime = Boolean(normalized);

  if (hasTime && timeFilter.tokens.has(AGENDA_TIME_FILTER_TIMED)) return true;
  if (!hasTime && timeFilter.tokens.has(AGENDA_TIME_FILTER_UNTIMED)) return true;
  if (normalized && timeFilter.tokens.has(normalized)) return true;

  if (normalized) {
    const minutes = parseAgendaTimeToMinutes(normalized);
    if (minutes !== null) {
      for (const range of timeFilter.ranges) {
        if (!range.wraps && minutes >= range.startMinutes && minutes <= range.endMinutes) {
          return true;
        }
        if (range.wraps && (minutes >= range.startMinutes || minutes <= range.endMinutes)) {
          return true;
        }
      }
    }
  }

  return false;
}

function matchesAgendaTimeFilter(time: string | undefined, timeFilter: AgendaTimeFilter): boolean {
  if (!timeFilter || (timeFilter.tokens.size === 0 && timeFilter.ranges.length === 0)) return true;
  return matchesAgendaTimeFilterTokenSet(time, timeFilter);
}

function matchesAgendaExcludeTimeFilter(time: string | undefined, excludeTimeFilter: AgendaExcludeTimeFilter): boolean {
  if (!excludeTimeFilter || (excludeTimeFilter.tokens.size === 0 && excludeTimeFilter.ranges.length === 0)) {
    return true;
  }
  return !matchesAgendaTimeFilterTokenSet(time, excludeTimeFilter);
}


function matchesAgendaExcludeKindFilter(
  kind: AgendaPlanningKind,
  excludeKindFilter: AgendaExcludePlanningFilter,
): boolean {
  if (!excludeKindFilter || excludeKindFilter.size === 0) return true;
  return !excludeKindFilter.has(kind);
}

function matchesAgendaExcludeTagFilter(tags: string[], excludeTagFilter: AgendaExcludeTagFilter): boolean {
  if (!excludeTagFilter || excludeTagFilter.length === 0) return true;

  const normalizedTags = tags.map((tag) => String(tag).trim().toLowerCase()).filter(Boolean);
  return !excludeTagFilter.some((token) => normalizedTags.includes(token));
}

function matchesAgendaExcludeTodoFilter(todo: string | undefined, excludeTodoFilter: AgendaExcludeTodoFilter): boolean {
  if (!excludeTodoFilter || excludeTodoFilter.size === 0) return true;
  const normalized = String(todo || "").trim().toUpperCase();
  if (!normalized) return true;
  return !excludeTodoFilter.has(normalized);
}

function matchesAgendaExcludePriorityFilter(
  priority: string | undefined,
  excludePriorityFilter: AgendaExcludePriorityFilter,
): boolean {
  if (!excludePriorityFilter || excludePriorityFilter.size === 0) return true;
  const normalized = normalizeAgendaPriorityToken(String(priority || ""));
  if (!normalized) return true;
  return !excludePriorityFilter.has(normalized);
}

function matchesAgendaEffortFilter(effort: string | undefined, effortFilter: AgendaEffortFilter): boolean {
  if (!effortFilter || effortFilter.size === 0) return true;
  const normalized = normalizeAgendaEffortToken(String(effort || ""));
  if (!normalized) return false;
  return effortFilter.has(normalized);
}

function matchesAgendaExcludeEffortFilter(
  effort: string | undefined,
  excludeEffortFilter: AgendaExcludeEffortFilter,
): boolean {
  if (!excludeEffortFilter || excludeEffortFilter.size === 0) return true;
  const normalized = normalizeAgendaEffortToken(String(effort || ""));
  if (!normalized) return true;
  return !excludeEffortFilter.has(normalized);
}

function matchesAgendaPropertyFilter(
  properties: Record<string, string>,
  propertyFilter: AgendaPropertyFilter,
): boolean {
  if (!propertyFilter || propertyFilter.length === 0) return true;

  return propertyFilter.some((term) => {
    const valueRaw = properties[term.key];
    if (!valueRaw) return false;
    return normalizeAgendaPropertyValue(valueRaw) === term.value;
  });
}

function matchesAgendaExcludePropertyFilter(
  properties: Record<string, string>,
  excludePropertyFilter: AgendaExcludePropertyFilter,
): boolean {
  if (!excludePropertyFilter || excludePropertyFilter.length === 0) return true;

  return !excludePropertyFilter.some((term) => {
    const valueRaw = properties[term.key];
    if (!valueRaw) return false;
    return normalizeAgendaPropertyValue(valueRaw) === term.value;
  });
}

function matchesAgendaFileFilter(filePath: string, fileFilter: AgendaFileFilter): boolean {
  if (!fileFilter || fileFilter.length === 0) return true;

  const normalizedPath = String(filePath || "").toLowerCase();
  return fileFilter.some((token) => normalizedPath.includes(token));
}

function matchesAgendaExcludeFileFilter(filePath: string, excludeFileFilter: AgendaExcludeFileFilter): boolean {
  if (!excludeFileFilter || excludeFileFilter.length === 0) return true;

  const normalizedPath = String(filePath || "").toLowerCase();
  return !excludeFileFilter.some((token) => normalizedPath.includes(token));
}

function agendaWhenBucketForDate(itemDate: Date, startDate: Date): AgendaWhenBucket {
  if (itemDate < startDate) return "overdue";

  const itemIso = itemDate.toISOString().slice(0, 10);
  const startIso = startDate.toISOString().slice(0, 10);
  if (itemIso === startIso) return "today";

  return "upcoming";
}

function matchesAgendaWhenFilter(
  itemDate: Date,
  startDate: Date,
  whenFilter: AgendaWhenFilter,
): boolean {
  if (!whenFilter || whenFilter.size === 0) return true;
  return whenFilter.has(agendaWhenBucketForDate(itemDate, startDate));
}

function matchesAgendaExcludeWhenFilter(
  itemDate: Date,
  startDate: Date,
  excludeWhenFilter: AgendaExcludeWhenFilter,
): boolean {
  if (!excludeWhenFilter || excludeWhenFilter.size === 0) return true;
  return !excludeWhenFilter.has(agendaWhenBucketForDate(itemDate, startDate));
}

function matchesAgendaWeekdayFilter(itemDate: Date, weekdayFilter: AgendaWeekdayFilter): boolean {
  if (!weekdayFilter || weekdayFilter.size === 0) return true;
  return weekdayFilter.has(itemDate.getUTCDay());
}

function matchesAgendaExcludeWeekdayFilter(
  itemDate: Date,
  excludeWeekdayFilter: AgendaExcludeWeekdayFilter,
): boolean {
  if (!excludeWeekdayFilter || excludeWeekdayFilter.size === 0) return true;
  return !excludeWeekdayFilter.has(itemDate.getUTCDay());
}

function agendaIsoWeekForDate(itemDate: Date): number {
  const normalized = new Date(Date.UTC(itemDate.getUTCFullYear(), itemDate.getUTCMonth(), itemDate.getUTCDate()));
  const weekday = normalized.getUTCDay() || 7;
  normalized.setUTCDate(normalized.getUTCDate() + 4 - weekday);

  const yearStart = new Date(Date.UTC(normalized.getUTCFullYear(), 0, 1));
  const dayOffset = Math.floor((normalized.getTime() - yearStart.getTime()) / (24 * 60 * 60 * 1000));
  return Math.floor((dayOffset + 7) / 7);
}

function matchesAgendaWeekFilter(itemDate: Date, weekFilter: AgendaWeekFilter): boolean {
  if (!weekFilter || weekFilter.size === 0) return true;
  return weekFilter.has(agendaIsoWeekForDate(itemDate));
}

function matchesAgendaExcludeWeekFilter(
  itemDate: Date,
  excludeWeekFilter: AgendaExcludeWeekFilter,
): boolean {
  if (!excludeWeekFilter || excludeWeekFilter.size === 0) return true;
  return !excludeWeekFilter.has(agendaIsoWeekForDate(itemDate));
}

function matchesAgendaDayOfMonthFilter(itemDate: Date, dayOfMonthFilter: AgendaDayOfMonthFilter): boolean {
  if (!dayOfMonthFilter || dayOfMonthFilter.size === 0) return true;
  return dayOfMonthFilter.has(itemDate.getUTCDate());
}

function matchesAgendaExcludeDayOfMonthFilter(
  itemDate: Date,
  excludeDayOfMonthFilter: AgendaExcludeDayOfMonthFilter,
): boolean {
  if (!excludeDayOfMonthFilter || excludeDayOfMonthFilter.size === 0) return true;
  return !excludeDayOfMonthFilter.has(itemDate.getUTCDate());
}

function matchesAgendaMonthFilter(itemDate: Date, monthFilter: AgendaMonthFilter): boolean {
  if (!monthFilter || monthFilter.size === 0) return true;
  return monthFilter.has(itemDate.getUTCMonth() + 1);
}

function matchesAgendaExcludeMonthFilter(itemDate: Date, excludeMonthFilter: AgendaExcludeMonthFilter): boolean {
  if (!excludeMonthFilter || excludeMonthFilter.size === 0) return true;
  return !excludeMonthFilter.has(itemDate.getUTCMonth() + 1);
}

function agendaQuarterForDate(itemDate: Date): number {
  return Math.floor(itemDate.getUTCMonth() / 3) + 1;
}

function matchesAgendaQuarterFilter(itemDate: Date, quarterFilter: AgendaQuarterFilter): boolean {
  if (!quarterFilter || quarterFilter.size === 0) return true;
  return quarterFilter.has(agendaQuarterForDate(itemDate));
}

function matchesAgendaExcludeQuarterFilter(
  itemDate: Date,
  excludeQuarterFilter: AgendaExcludeQuarterFilter,
): boolean {
  if (!excludeQuarterFilter || excludeQuarterFilter.size === 0) return true;
  return !excludeQuarterFilter.has(agendaQuarterForDate(itemDate));
}

function matchesAgendaYearFilter(itemDate: Date, yearFilter: AgendaYearFilter): boolean {
  if (!yearFilter || yearFilter.size === 0) return true;
  return yearFilter.has(itemDate.getUTCFullYear());
}

function matchesAgendaExcludeYearFilter(itemDate: Date, excludeYearFilter: AgendaExcludeYearFilter): boolean {
  if (!excludeYearFilter || excludeYearFilter.size === 0) return true;
  return !excludeYearFilter.has(itemDate.getUTCFullYear());
}

function matchesAgendaDateFilter(itemDate: Date, dateFilter: AgendaDateFilter): boolean {
  if (!dateFilter || dateFilter.size === 0) return true;
  return dateFilter.has(itemDate.toISOString().slice(0, 10));
}

function matchesAgendaExcludeDateFilter(itemDate: Date, excludeDateFilter: AgendaExcludeDateFilter): boolean {
  if (!excludeDateFilter || excludeDateFilter.size === 0) return true;
  return !excludeDateFilter.has(itemDate.toISOString().slice(0, 10));
}

function matchesAgendaLevelFilter(level: number, levelFilter: AgendaLevelFilter): boolean {
  if (!levelFilter || levelFilter.size === 0) return true;
  return levelFilter.has(level);
}

function matchesAgendaExcludeLevelFilter(level: number, excludeLevelFilter: AgendaExcludeLevelFilter): boolean {
  if (!excludeLevelFilter || excludeLevelFilter.size === 0) return true;
  return !excludeLevelFilter.has(level);
}

function agendaWantsOverdue(
  includeOverdue: boolean,
  whenFilter: AgendaWhenFilter,
  excludeWhenFilter: AgendaExcludeWhenFilter,
): boolean {
  const includesOverdue = whenFilter ? whenFilter.has("overdue") : includeOverdue;
  if (!includesOverdue) return false;
  if (excludeWhenFilter && excludeWhenFilter.has("overdue")) return false;
  return true;
}

function extractAgendaPriorityFromHeadlineTitle(rawTitle: string): { priority?: string; title: string } {
  let title = String(rawTitle || "").trimStart();
  const match = title.match(/^\[#([A-Za-z0-9])\](?:\s+|$)/);
  if (!match) {
    return { title };
  }

  const priority = normalizeAgendaPriorityToken(match[1] ?? "");
  title = title.slice(match[0].length).trimStart();

  if (!priority) {
    return { title };
  }

  return { priority, title };
}

function parseHeadlineLine(line: string, sequences: readonly TodoSequence[] = []): { todo?: string; priority?: string; title: string; tags: string[]; level: number } | null {
  const m = /^(\*+)\s+(.*)$/.exec(line);
  if (!m) return null;

  const level = m[1]!.length;
  let rest = m[2] ?? "";
  rest = rest.trimEnd();

  let tags: string[] = [];

  // Capture/strip tags suffix: " ... :tag:tag:".
  const tagSuffixMatch = /\s+:([^\s:]+(?::[^\s:]+)*)\:\s*$/.exec(rest);
  if (tagSuffixMatch) {
    tags = tagSuffixMatch[1]
      .split(":")
      .map((tag) => tag.trim().toLowerCase())
      .filter(Boolean);

    const suffixStart = tagSuffixMatch.index ?? rest.length;
    rest = rest.slice(0, suffixStart).trimEnd();
  }

  const pieces = rest.trim().split(/\s+/);
  const first = pieces[0] ?? "";
  let todo: string | undefined;
  let titleRest = rest;

  // Heuristic: TODO keywords are usually uppercase-ish.
  if ((todoKeywordInWorkflow(first, sequences) || /^[A-Z][A-Z0-9_-]*$/.test(first)) && pieces.length > 1) {
    todo = first;
    titleRest = rest.slice(first.length).trimStart();
  }

  const { priority, title } = extractAgendaPriorityFromHeadlineTitle(titleRest);

  if (todo) {
    return { todo, priority, title, tags, level };
  }

  return { priority, title, tags, level };
}

function isAgendaHabitProperties(properties: Record<string, string>): { isHabit: boolean; marker: string } {
  const raw = String(properties.HABIT || properties.STYLE || brandProperty(properties, "ORG2_HABIT") || "").trim();
  const normalized = raw.toLowerCase();
  return { isHabit: normalized === "habit" || normalized === "true" || normalized === "yes", marker: raw || "habit" };
}

function collectClosedDatesInSubtree(lines: string[], headlineLineIndex: number): string[] {
  const dates = new Set<string>();
  const headline = parseHeadlineLine(lines[headlineLineIndex] ?? "");
  const level = headline?.level ?? 1;
  for (let i = headlineLineIndex + 1; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    const nestedHeadline = parseHeadlineLine(line);
    if (nestedHeadline && nestedHeadline.level <= level) break;
    for (const match of line.matchAll(/\bCLOSED:\s*[<[\[]?(\d{4}-\d{2}-\d{2})\b/g)) {
      if (match[1]) dates.add(match[1]);
    }
  }
  return [...dates].sort();
}

function agendaHabitStreak(closedDates: string[], currentDate: string): number {
  if (closedDates.length === 0) return 0;
  const closed = new Set(closedDates);
  let cursor = parseIsoDate(currentDate);
  let streak = 0;
  for (let i = 0; i < 366; i += 1) {
    const iso = cursor.toISOString().slice(0, 10);
    if (!closed.has(iso)) break;
    streak += 1;
    cursor = addTimestampInterval(cursor, 1, "d", -1);
  }
  return streak;
}


function appendCheckboxProgressLintIssues(raw: string, filePath: string, issues: ArtifactLintIssue[]): void {
  const lines = String(raw || "").split(/\r\n|\n|\r/);
  for (const cookie of extractOwnedCheckboxIssues(lines)) {
    issues.push({
      severity: "warning",
      rule: "checkbox-progress-cookie-stale",
      file: filePath,
      line: cookie.line,
      message: `Progress cookie ${cookie.raw} is stale; expected ${cookie.expectedRaw} for ${cookie.checked}/${cookie.total} checked boxes.`,
    });
  }
}

function appendHabitLintIssues(raw: string, filePath: string, issues: ArtifactLintIssue[]): void {
  const lines = raw.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const parsed = parseHeadlineLine(lines[i] ?? "");
    if (!parsed) continue;
    const properties = extractAgendaPropertiesNearHeadline(lines, i);
    const habit = isAgendaHabitProperties(properties);
    if (!habit.isHabit) continue;

    let hasRepeatingPlanning = false;
    let hasAnyPlanning = false;
    for (let j = i + 1; j < lines.length; j += 1) {
      const line = lines[j] ?? "";
      const nestedHeadline = parseHeadlineLine(line);
      if (nestedHeadline && nestedHeadline.level <= parsed.level) break;
      const planningRe = /\b(SCHEDULED|DEADLINE):\s*([<[].*?[>\]])/g;
      let match: RegExpExecArray | null;
      while ((match = planningRe.exec(line)) !== null) {
        hasAnyPlanning = true;
        if (parseTimestampRepeater(match[2] ?? "")) hasRepeatingPlanning = true;
      }
    }

    if (!hasRepeatingPlanning) {
      issues.push({
        severity: "warning",
        rule: hasAnyPlanning ? "habit-missing-repeater" : "habit-missing-planning",
        file: filePath,
        line: i + 1,
        message: hasAnyPlanning
          ? "Habit headlines should use a repeater on SCHEDULED or DEADLINE (for example: SCHEDULED: <2026-05-26 Tue +1d>)."
          : "Habit headlines need SCHEDULED or DEADLINE planning with a repeater.",
      });
    }
  }
}

function extractAgendaPropertiesNearHeadline(lines: string[], headlineLineIndex: number): Record<string, string> {
  const properties: Record<string, string> = {};
  let inProperties = false;

  for (let i = headlineLineIndex + 1; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (/^(\*+)\s+/.test(line)) break;

    const trimmed = line.trim();

    if (!inProperties) {
      if (!trimmed) continue;
      if (/^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) continue;
      if (trimmed === ":PROPERTIES:") {
        inProperties = true;
        continue;
      }
      break;
    }

    if (trimmed === ":END:") break;
    if (!trimmed) continue;

    const match = /^:([A-Za-z0-9_@#%+.-]+):\s*(.*)$/.exec(trimmed);
    if (!match) continue;

    const key = normalizeAgendaPropertyKey(match[1] ?? "");
    const value = (match[2] ?? "").trim();
    if (!key || !value) continue;

    properties[key] = value;
  }

  return properties;
}

function extractAgendaFileProperties(lines: string[]): Record<string, string> {
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (/^(\*+)\s+/.test(line)) break;
    if (line.trim().toUpperCase() !== ":PROPERTIES:") continue;
    const properties: Record<string, string> = {};
    for (let j = i + 1; j < lines.length; j += 1) {
      const trimmed = (lines[j] ?? "").trim();
      if (trimmed.toUpperCase() === ":END:") return properties;
      const match = /^:([A-Za-z0-9_@#%+.-]+):\s*(.*)$/.exec(trimmed);
      if (!match) continue;
      const key = normalizeAgendaPropertyKey(match[1] ?? "");
      const value = (match[2] ?? "").trim();
      if (key && value) properties[key] = value;
    }
    break;
  }
  return {};
}

function extractAgendaEntryBody(lines: string[], headlineLineIndex: number): string {
  const bodyLines: string[] = [];
  let inProperties = false;
  let sawProperties = false;

  for (let i = headlineLineIndex + 1; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (/^(\*+)\s+/.test(line)) break;

    const trimmed = line.trim();
    if (inProperties) {
      if (trimmed.toUpperCase() === ":END:") inProperties = false;
      continue;
    }

    if (trimmed.toUpperCase() === ":PROPERTIES:" && !sawProperties) {
      inProperties = true;
      sawProperties = true;
      continue;
    }

    if (/^(SCHEDULED|DEADLINE|CLOSED):/i.test(trimmed)) continue;
    bodyLines.push(line);
  }

  return bodyLines.join("\n").trim();
}

function appendEffortLintIssues(raw: string, filePath: string, issues: ArtifactLintIssue[]): void {
  const lines = raw.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const match = /^\s*:EFFORT:\s*(.*?)\s*$/.exec(lines[i] || "");
    if (!match) continue;
    const value = String(match[1] || "").trim();
    if (!value) continue;
    if (parseAgendaEffortToMinutes(value) !== null) continue;
    issues.push({
      severity: "warning",
      rule: "effort-malformed",
      file: filePath,
      line: i + 1,
      message: `EFFORT '${value}' is not a supported duration. Use minutes, H:MM, 2h, 30m, or 2h30m.`,
    });
  }
}

function agendaWorkloadSummaryForItems(
  items: ScheduledItem[],
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): {
  totalMinutes: number;
  byDate: Record<string, number>;
  byGroup: Record<string, number>;
  byTag: Record<string, number>;
} {
  const byDate: Record<string, number> = {};
  const byGroup: Record<string, number> = {};
  const byTag: Record<string, number> = {};
  let totalMinutes = 0;
  const add = (bucket: Record<string, number>, key: string, minutes: number) => {
    bucket[key] = (bucket[key] || 0) + minutes;
  };

  for (const item of items) {
    const minutes = parseAgendaEffortToMinutes(String(item.effort || ""));
    if (minutes === null) continue;
    totalMinutes += minutes;
    add(byDate, item.date, minutes);
    const groupLabel = groupOrder && groupOrder.length > 0 ? agendaGroupLabelForItem(item, groupOrder, tagOrder) : "All items";
    add(byGroup, groupLabel || "(none)", minutes);
    for (const tag of item.tags || []) add(byTag, tag, minutes);
  }

  return { totalMinutes, byDate, byGroup, byTag };

}

function findScheduledItemsInText(
  content: string,
  filePath: string,
  startDate: Date,
  endDate: Date,
  includeOverdue: boolean,
  statusFilter: AgendaStatusFilter,
  excludeStatusFilter: AgendaExcludeStatusFilter,
  planningFilter: AgendaPlanningFilter,
  excludePlanningFilter: AgendaExcludePlanningFilter,
  whenFilter: AgendaWhenFilter,
  excludeWhenFilter: AgendaExcludeWhenFilter,
  weekdayFilter: AgendaWeekdayFilter,
  excludeWeekdayFilter: AgendaExcludeWeekdayFilter,
  weekFilter: AgendaWeekFilter,
  excludeWeekFilter: AgendaExcludeWeekFilter,
  dayOfMonthFilter: AgendaDayOfMonthFilter,
  excludeDayOfMonthFilter: AgendaExcludeDayOfMonthFilter,
  monthFilter: AgendaMonthFilter,
  excludeMonthFilter: AgendaExcludeMonthFilter,
  quarterFilter: AgendaQuarterFilter,
  excludeQuarterFilter: AgendaExcludeQuarterFilter,
  yearFilter: AgendaYearFilter,
  excludeYearFilter: AgendaExcludeYearFilter,
  dateFilter: AgendaDateFilter,
  excludeDateFilter: AgendaExcludeDateFilter,
  levelFilter: AgendaLevelFilter,
  excludeLevelFilter: AgendaExcludeLevelFilter,
  textFilter: AgendaMatchFilter,
  excludeTextFilter: AgendaExcludeMatchFilter,
  tagFilter: AgendaTagFilter,
  idFilter: AgendaIdFilter,
  todoFilter: AgendaTodoFilter,
  priorityFilter: AgendaPriorityFilter,
  timeFilter: AgendaTimeFilter,
  effortFilter: AgendaEffortFilter,
  propertyFilter: AgendaPropertyFilter,
  excludeTagFilter: AgendaExcludeTagFilter,
  excludeIdFilter: AgendaExcludeIdFilter,
  excludeTodoFilter: AgendaExcludeTodoFilter,
  excludePriorityFilter: AgendaExcludePriorityFilter,
  excludeTimeFilter: AgendaExcludeTimeFilter,
  excludeEffortFilter: AgendaExcludeEffortFilter,
  excludePropertyFilter: AgendaExcludePropertyFilter,
  deadlineWarningDays: number = 0,
  deadlineWarningDate: Date | null = null,
): ScheduledItem[] {
  const items: ScheduledItem[] = [];
  const lines = content.split("\n");
  const sequences = documentTodoSequences(content, todoSequencesForFile(filePath));
  const fileProperties = extractAgendaFileProperties(lines);
  const propertyStack: Array<{ level: number; effectiveProperties: Record<string, string> }> = [];

  let current: {
    todo?: string;
    priority?: string;
    effort?: string;
    properties: Record<string, string>;
    title: string;
    tags: string[];
    level: number;
    lineNumber: number;
    habit: { isHabit: boolean; marker: string };
    closedDates: string[];
  } | null = null;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";

    // Headline line
    if (/^(\*+)\s+/.test(line)) {
      const parsed = parseHeadlineLine(line, sequences);
      if (parsed) {
        while (propertyStack.length && (propertyStack[propertyStack.length - 1]?.level || 0) >= parsed.level) propertyStack.pop();
        const explicitProperties = extractAgendaPropertiesNearHeadline(lines, i);
        const inheritedProperties = propertyStack[propertyStack.length - 1]?.effectiveProperties || fileProperties;
        const properties = { ...inheritedProperties, ...explicitProperties };
        propertyStack.push({ level: parsed.level, effectiveProperties: properties });
        current = {
          ...parsed,
          effort: properties.EFFORT,
          properties,
          lineNumber: i,
          habit: isAgendaHabitProperties(properties),
          closedDates: collectClosedDatesInSubtree(lines, i),
        };
      } else {
        current = null;
      }
      continue;
    }

    // Planning line(s) belong to the most recent headline.
    if (!current) continue;

    // Skip non-todo headlines.
    const todo = current.todo;
    if (!todo) continue;

    const configured = sequences.some(sequence => sequence.keywords.includes(todo));
    const todoBucket = isTerminalTodoKeyword(todo, sequences) ? (todo.toUpperCase().startsWith("CANCEL") ? "canceled" : "done") : configured && isTerminalTodoKeyword(todo) ? "todo" : agendaStatusBucketForKeyword(todo);
    if (statusFilter && (!todoBucket || !statusFilter.has(todoBucket))) continue;
    if (todoBucket && excludeStatusFilter?.has(todoBucket)) continue;
    if (!matchesAgendaTextFilter(current.title, textFilter)) continue;
    if (!matchesAgendaExcludeTextFilter(current.title, excludeTextFilter)) continue;
    if (!matchesAgendaTagFilter(current.tags, tagFilter)) continue;
    if (!matchesAgendaIdFilter(current.properties, idFilter)) continue;
    if (!matchesAgendaTodoFilter(todo, todoFilter)) continue;
    if (!matchesAgendaPriorityFilter(current.priority, priorityFilter)) continue;
    if (!matchesAgendaEffortFilter(current.effort, effortFilter)) continue;
    if (!matchesAgendaPropertyFilter(current.properties, propertyFilter)) continue;
    if (!matchesAgendaExcludeTagFilter(current.tags, excludeTagFilter)) continue;
    if (!matchesAgendaExcludeIdFilter(current.properties, excludeIdFilter)) continue;
    if (!matchesAgendaExcludeTodoFilter(todo, excludeTodoFilter)) continue;
    if (!matchesAgendaExcludePriorityFilter(current.priority, excludePriorityFilter)) continue;
    if (!matchesAgendaExcludeEffortFilter(current.effort, excludeEffortFilter)) continue;
    if (!matchesAgendaExcludePropertyFilter(current.properties, excludePropertyFilter)) continue;
    if (!matchesAgendaLevelFilter(current.level, levelFilter)) continue;
    if (!matchesAgendaExcludeLevelFilter(current.level, excludeLevelFilter)) continue;

    const isDoneLike = isTerminalTodoKeyword(todo, sequences);
    const isProgLike = todo === "PROG" || todo === "IN_PROGRESS";

    // Match multiple planning tokens on a single line.
    // Example: "SCHEDULED: <2026-02-01 Sun> DEADLINE: <...>"
    const planningRe = /(SCHEDULED|DEADLINE|CLOSED):\s*([<[].*?[>\]])/g;
    planningRe.lastIndex = 0;

    let m: RegExpExecArray | null;
    while ((m = planningRe.exec(line)) !== null) {
      const kind = m[1] ?? "";
      // CLOSED is metadata for completed tasks; don't create a separate agenda entry.
      if (kind === "CLOSED") continue;
      if (planningFilter && !planningFilter.has(kind as AgendaPlanningKind)) continue;
      if (!matchesAgendaExcludeKindFilter(kind as AgendaPlanningKind, excludePlanningFilter)) continue;

      const tsRaw = m[2] ?? "";
      const planningTime = extractTimeFromTimestamp(tsRaw);
      if (!matchesAgendaTimeFilter(planningTime, timeFilter)) continue;
      if (!matchesAgendaExcludeTimeFilter(planningTime, excludeTimeFilter)) continue;
      const wantsOverdue = agendaWantsOverdue(includeOverdue, whenFilter, excludeWhenFilter);
      const agendaDates: Array<{ dateStr: string; deadlineWarning?: AgendaDeadlineWarning }> =
        resolveAgendaDatesFromTimestamp(tsRaw, startDate, endDate, wantsOverdue, kind as AgendaPlanningKind)
          .map((dateStr) => ({ dateStr }));
      if (kind === "DEADLINE" && !isDoneLike && deadlineWarningDate) {
        const deadlineWarning = agendaDeadlineWarningForStart(tsRaw, deadlineWarningDate, deadlineWarningDays);
        if (deadlineWarning) agendaDates.push({ dateStr: formatIsoDateUtc(deadlineWarningDate), deadlineWarning });
      }

      for (const { dateStr, deadlineWarning } of agendaDates) {
        const itemDate = parseIsoDate(dateStr);
        const inRange = itemDate >= startDate && itemDate <= endDate;
        const isOverdue = itemDate < startDate;

        // TODO state filtering:
        // - DONE/CANCELLED: only show if not overdue.
        // - PROG (and IN_PROGRESS): can appear when overdue regardless of includeOverdue
        //   because those tasks are still active.
        // - Everything else: show inRange, and show overdue when includeOverdue (or when
        //   --when explicitly requests overdue rows).
        if (isDoneLike && isOverdue) continue;
        if (!(inRange || (isProgLike && isOverdue) || (!isDoneLike && wantsOverdue && isOverdue))) continue;
        if (!matchesAgendaWhenFilter(itemDate, startDate, whenFilter)) continue;
        if (!matchesAgendaExcludeWhenFilter(itemDate, startDate, excludeWhenFilter)) continue;
        if (!matchesAgendaWeekdayFilter(itemDate, weekdayFilter)) continue;
        if (!matchesAgendaExcludeWeekdayFilter(itemDate, excludeWeekdayFilter)) continue;
        if (!matchesAgendaWeekFilter(itemDate, weekFilter)) continue;
        if (!matchesAgendaExcludeWeekFilter(itemDate, excludeWeekFilter)) continue;
        if (!matchesAgendaDayOfMonthFilter(itemDate, dayOfMonthFilter)) continue;
        if (!matchesAgendaExcludeDayOfMonthFilter(itemDate, excludeDayOfMonthFilter)) continue;
        if (!matchesAgendaMonthFilter(itemDate, monthFilter)) continue;
        if (!matchesAgendaExcludeMonthFilter(itemDate, excludeMonthFilter)) continue;
        if (!matchesAgendaQuarterFilter(itemDate, quarterFilter)) continue;
        if (!matchesAgendaExcludeQuarterFilter(itemDate, excludeQuarterFilter)) continue;
        if (!matchesAgendaYearFilter(itemDate, yearFilter)) continue;
        if (!matchesAgendaExcludeYearFilter(itemDate, excludeYearFilter)) continue;
        if (!matchesAgendaDateFilter(itemDate, dateFilter)) continue;
        if (!matchesAgendaExcludeDateFilter(itemDate, excludeDateFilter)) continue;

        const habit = current.habit.isHabit
          ? {
              marker: current.habit.marker,
              streak: agendaHabitStreak(current.closedDates, dateStr),
              closedDates: current.closedDates,
            }
          : undefined;

        items.push({
          filePath,
          lineNumber: current.lineNumber,
          headline: current.title,
          todo,
          priority: current.priority,
          body: extractAgendaEntryBody(lines, current.lineNumber),
          ...(sequences.length ? { todoTerminal: isDoneLike } : {}),
          effort: current.effort,
          id: agendaPrimaryIdFromProperties(current.properties),
          level: current.level,
          date: dateStr,
          time: planningTime,
          kind,
          tags: [...current.tags],
          properties: { ...current.properties },
          ...(habit ? { habit } : {}),
          ...(deadlineWarning ? { deadlineWarning } : {}),
        });
      }
    }
  }

  return deduplicateAgendaPlanningItems(items);
}

function formatDateHeader(dateStr: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateStr);
  if (!match) return dateStr;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);

  // Compute weekday deterministically without local timezone effects.
  const dateUtc = new Date(Date.UTC(year, month - 1, day));

  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const dayName = days[dateUtc.getUTCDay()];
  return `${dateStr} ${dayName}`;
}

function formatSectionHeader(title: string): string {
  const separator = "═".repeat(title.length + 2);
  return `\n${separator}\n ${title}\n${separator}\n\n`;
}

/**
 * Generate unified diff format for archive output.
 */
function formatArchiveDiff(
  sourcePath: string,
  archivePath: string,
  subtreeText: string
): string {
  let diff = `--- ${sourcePath}\n`;
  diff += `+++ ${archivePath}\n`;

  // Show what's being removed from source
  const subtreeLines = subtreeText.split("\n");

  diff += `@@ archive @@\n`;
  diff += `--- ${sourcePath} (removed lines)\n`;
  for (const line of subtreeLines) {
    if (line) diff += `- ${line}\n`;
  }

  diff += `\n+++ ${archivePath} (appended lines)\n`;
  for (const line of subtreeLines) {
    if (line) diff += `+ ${line}\n`;
  }

  return diff;
}

function defaultArchivePathForSource(sourcePath: string): string {
  if (/\.org2?$/i.test(sourcePath)) return `${sourcePath}_archive`;
  return `${sourcePath}.archive`;
}

function appendSubtreeToArchiveText(existingArchive: string, subtreeText: string): string {
  const existing = String(existingArchive || "").replace(/\r\n/g, "\n").trimEnd();
  return existing ? `${existing}\n\n${subtreeText}` : subtreeText;
}

function extractArchiveHeadlineTitle(line: string): string {
  return line.replace(/^\*+\s+/, "").replace(/\s+:[\w@#%:]+:\s*$/, "").trim();
}

function findArchiveOriginalId(subtreeLines: string[]): string | undefined {
  const scanLimit = Math.min(subtreeLines.length, 20);
  for (let idx = 1; idx < scanLimit; idx += 1) {
    const line = subtreeLines[idx] ?? "";
    if (/^\*+\s+/.test(line)) break;
    const trimmed = line.trim();
    const match = /^:ID:\s*(\S+)\s*$/i.exec(trimmed);
    if (match) return match[1];
    if (trimmed === ":END:") break;
  }
  return undefined;
}

function buildArchiveHeadingPath(lines: string[], headlineLineIndex: number): string[] {
  const headingPath: string[] = [];
  let currentLevel = Infinity;
  for (let idx = headlineLineIndex; idx >= 0; idx -= 1) {
    const line = lines[idx] ?? "";
    const match = /^(\*+)\s+/.exec(line);
    if (!match) continue;
    const level = match[1].length;
    if (level < currentLevel) {
      headingPath.unshift(extractArchiveHeadlineTitle(line));
      currentLevel = level;
    }
  }
  return headingPath;
}

function addArchiveProvenanceDrawer(subtreeLines: string[], provenance: Record<string, string | undefined>): string[] {
  const out = [...subtreeLines];
  const drawer = [
    ":PROPERTIES:",
    `:ARCHIVED_AT: ${provenance.archivedAt}`,
    `:ARCHIVE_SOURCE: ${provenance.sourcePath}`,
    `:ARCHIVE_SOURCE_LINE: ${provenance.sourceLine}`,
    provenance.originalId ? `:ARCHIVE_ORIGINAL_ID: ${provenance.originalId}` : undefined,
    provenance.headingPath ? `:ARCHIVE_HEADING_PATH: ${provenance.headingPath}` : undefined,
    ":END:",
    "",
  ].filter((line): line is string => typeof line === "string");

  const hasDrawer = out.length > 1 && (out[1] ?? "").trim().toUpperCase() === ":PROPERTIES:";
  if (hasDrawer) {
    out.splice(2, 0, ...drawer.slice(1, -2));
  } else {
    out.splice(1, 0, ...drawer);
  }
  return out;
}

function formatOutput(
  items: ScheduledItem[],
  startDate: Date,
  dateOrder: AgendaDateOrder,
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): string {
  if (items.length === 0) {
    return "No scheduled items in range.\n";
  }

  const startIso = startDate.toISOString().slice(0, 10);
  const dateCompare = (a: ScheduledItem, b: ScheduledItem): number => {
    const cmp = a.date.localeCompare(b.date);
    return dateOrder === "desc" ? -cmp : cmp;
  };

  const overdueItems = items.filter((it) => it.date < startIso).sort(dateCompare);
  const upcomingItems = items.filter((it) => it.date >= startIso).sort(dateCompare);

  let output = "";

  if (overdueItems.length > 0) {
    output += formatSectionHeader(`OVERDUE (before ${startIso})`);
    output += formatUnifiedSection(overdueItems, groupOrder, tagOrder);

    if (upcomingItems.length > 0) {
      output += formatSectionHeader(`UPCOMING (from ${startIso})`);
    }
  }

  output += formatByDate(upcomingItems, dateOrder, groupOrder, tagOrder);
  return output;
}

function formatUnifiedSection(
  items: ScheduledItem[],
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): string {
  if (items.length === 0) return "";

  let output = "\n";

  if (groupOrder && groupOrder.length > 0) {
    let previousGroupKey = "";
    for (const item of items) {
      const nextGroupKey = agendaGroupKeyForItem(item, groupOrder, tagOrder);
      if (nextGroupKey !== previousGroupKey) {
        if (previousGroupKey) output += "\n";
        output += `  ─ ${agendaGroupLabelForItem(item, groupOrder, tagOrder)}\n`;
        previousGroupKey = nextGroupKey;
      }

      const status = item.todo || "ITEM";
      const timePrefix = item.time ? `${item.time} ` : "";
      output += `    [${status}] ${timePrefix}${item.headline} (${agendaItemKindLabel(item)}) ${item.filePath}\n`;
    }
  } else {
    for (const item of items) {
      const status = item.todo || "ITEM";
      const timePrefix = item.time ? `${item.time} ` : "";
      output += `  [${status}] ${timePrefix}${item.headline} (${agendaItemKindLabel(item)}) ${item.filePath}\n`;
    }
  }

  output += "\n";
  return output;
}

function formatByDate(
  items: ScheduledItem[],
  dateOrder: AgendaDateOrder,
  groupOrder: AgendaGroupOrder,
  tagOrder: AgendaTagOrder,
): string {
  if (items.length === 0) return "";

  // Group by date
  const byDate = new Map<string, ScheduledItem[]>();
  for (const item of items) {
    if (!byDate.has(item.date)) {
      byDate.set(item.date, []);
    }
    byDate.get(item.date)!.push(item);
  }

  // Sort dates
  const dates = Array.from(byDate.keys()).sort((a, b) => {
    const cmp = a.localeCompare(b);
    return dateOrder === "desc" ? -cmp : cmp;
  });

  let output = "";
  for (let i = 0; i < dates.length; i++) {
    const date = dates[i];
    const dateHeader = formatDateHeader(date);
    const separator = "═".repeat(dateHeader.length + 2);

    output += `\n${separator}\n`;
    output += ` ${dateHeader}\n`;
    output += `${separator}\n\n`;

    const dayItems = byDate.get(date)!;
    if (groupOrder && groupOrder.length > 0) {
      let previousGroupKey = "";
      for (const item of dayItems) {
        const nextGroupKey = agendaGroupKeyForItem(item, groupOrder, tagOrder);
        if (nextGroupKey !== previousGroupKey) {
          if (previousGroupKey) output += "\n";
          output += `  ─ ${agendaGroupLabelForItem(item, groupOrder, tagOrder)}\n`;
          previousGroupKey = nextGroupKey;
        }

        const status = item.todo || "ITEM";
        const timePrefix = item.time ? `${item.time} ` : "";
        output += `    [${status}] ${timePrefix}${item.headline} (${agendaItemKindLabel(item)}) ${item.filePath}\n`;
      }
    } else {
      for (const item of dayItems) {
        const status = item.todo || "ITEM";
        const timePrefix = item.time ? `${item.time} ` : "";
        output += `  [${status}] ${timePrefix}${item.headline} (${agendaItemKindLabel(item)}) ${item.filePath}\n`;
      }
    }

    output += "\n";
  }

  return output;
}

function truncateForTerminal(input: string, width: number): string {
  if (width <= 0) return "";
  if (input.length <= width) return input;
  if (width <= 1) return input.slice(0, width);
  return `${input.slice(0, width - 1)}…`;
}

function wrapTerminalLine(input: string, width: number, continuationIndent = 0): string[] {
  if (width <= 0) return [""];

  const text = input.trimEnd();
  if (!text) return [""];

  const indent = Math.max(0, Math.min(continuationIndent, Math.max(0, width - 1)));
  const indentText = " ".repeat(indent);
  const available = Math.max(1, width - indent);
  const words = text.split(/\s+/).filter(Boolean);
  const lines: string[] = [];
  let current = "";

  const pushCurrent = (): void => {
    if (current) lines.push(current);
    current = "";
  };

  for (const word of words) {
    const lineWidth = lines.length === 0 ? width : available;
    const candidate = current ? `${current} ${word}` : word;
    if (candidate.length <= lineWidth) {
      current = candidate;
      continue;
    }

    if (current) pushCurrent();

    let remainder = word;
    while (remainder.length > lineWidth) {
      lines.push(remainder.slice(0, lineWidth));
      remainder = remainder.slice(lineWidth);
    }
    current = remainder;
  }

  pushCurrent();
  return lines.map((line, index) => (index === 0 ? line : `${indentText}${line}`));
}

function stripRoamLinksForAgendaTui(input: string): string {
  return String(input || "")
    .replace(/\[\[id:[^\]\[]+\]\[([^\]\[]+)\]\]/gi, "$1")
    .replace(/\[\[id:([^\]\[]+)\]\]/gi, "$1")
    .replace(/\[\[([^\]\[]+)\]\]/g, "$1")
    .replace(/(?:\s*\/\s*){2,}/g, " / ")
    .replace(/(^|\s)\/(\s|$)/g, " ")
    .replace(/\s+([,.;:!?])/g, "$1")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function agendaTuiStatus(item: ScheduledItem): string {
  return item.todo || "ITEM";
}

function isAgendaTuiActionable(item: ScheduledItem): boolean {
  const bucket = agendaStatusBucketForKeyword(item.todo);
  return bucket !== "done" && bucket !== "canceled";
}

function buildAgendaTuiSections(items: ScheduledItem[], startIso: string, mode: AgendaTuiMode): AgendaTuiSection[] {
  const overdue = items.filter((item) => item.date < startIso);
  const today = items.filter((item) => item.date === startIso);
  const upcoming = items.filter((item) => item.date > startIso);
  const next7EndIso = formatAgendaTuiIsoDate(addAgendaTuiUtcDays(parseIsoDate(startIso), 7));
  const next7Days = upcoming.filter((item) => item.date <= next7EndIso);
  const laterUpcoming = upcoming.filter((item) => item.date > next7EndIso);
  const overdueActionable = overdue.filter(isAgendaTuiActionable);
  const todayActionable = today.filter(isAgendaTuiActionable);

  const sections: AgendaTuiSection[] = [];
  const pushSection = (key: string, label: string, sectionItems: ScheduledItem[], hint?: string): void => {
    sections.push({ key, label, items: sectionItems, hint });
  };

  if (mode === "focus") {
    pushSection("focus-today", `Today`, todayActionable, "today");
    if (overdueActionable.length > 0) {
      pushSection("focus-overdue", `Overdue`, overdueActionable, "overdue");
    }
    if (today.length > todayActionable.length) {
      pushSection("focus-closed", `Done or canceled`, today.filter((item) => !isAgendaTuiActionable(item)), "today");
    }
  } else if (mode === "today") {
    pushSection("today", "Today", today, "today");
    if (overdue.length > 0) pushSection("overdue", "Overdue", overdue, "overdue");
  } else {
    if (overdue.length > 0) pushSection("overdue", "Overdue", overdue, "overdue");
    if (today.length > 0) pushSection("today", "Today", today, "today");
    if (next7Days.length > 0) pushSection("next-7-days", "Next 7 days", next7Days, "upcoming");
    if (laterUpcoming.length > 0) pushSection("later", "Later", laterUpcoming, "upcoming");
  }

  return sections;
}

function buildAgendaTuiRows(sections: AgendaTuiSection[], collapsedSections: Set<string>): AgendaTuiRow[] {
  const rows: AgendaTuiRow[] = [];

  for (const section of sections) {
    const collapsed = collapsedSections.has(section.key);
    rows.push({ type: "section", key: section.key, label: section.label, count: section.items.length, hint: section.hint, collapsed });
    if (!collapsed) {
      for (const item of section.items) {
        rows.push({ type: "item", item, sectionKey: section.key, hint: section.hint });
      }
    }
  }

  if (rows.length === 0) {
    rows.push({ type: "section", key: "empty", label: "Nothing scheduled in this view. Nice.", count: 0, collapsed: false });
  }

  return rows;
}

function agendaTuiSearchText(item: ScheduledItem): string {
  const properties = Object.entries(item.properties || {})
    .map(([key, value]) => `${key} ${value}`)
    .join("\n");
  return [
    item.headline,
    item.body,
    item.todo,
    item.priority,
    item.effort,
    item.id,
    item.time,
    item.kind,
    item.tags.join(" "),
    properties,
  ]
    .filter((part) => String(part || "").trim().length > 0)
    .join("\n")
    .toLowerCase();
}

function filterAgendaTuiItems(items: ScheduledItem[], query: string): ScheduledItem[] {
  const terms = String(query || "")
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);
  if (terms.length === 0) return items;
  return items.filter((item) => {
    const haystack = agendaTuiSearchText(item);
    return terms.every((term) => haystack.includes(term));
  });
}

function nextAgendaTuiMode(mode: AgendaTuiMode, key: string): AgendaTuiMode {
  if (key === "1") return "focus";
  if (key === "2") return "today";
  if (key === "3") return "range";
  return mode;
}

function cycleAgendaTuiStatus(item: ScheduledItem): TodoStatus {
  const bucket = parseTodoStatusArg(String(item.todo || ""));
  if (bucket === "todo") return "in_progress";
  if (bucket === "in_progress") return "done";
  return "todo";
}

function formatAgendaTuiIsoDate(date: Date): string {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function addAgendaTuiUtcDays(date: Date, daysToAdd: number): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + daysToAdd));
}

function computeAgendaTuiUpcomingMonday(date: Date): Date {
  const weekday = date.getUTCDay();
  const delta = weekday === 1 ? 7 : ((8 - weekday) % 7 || 7);
  return addAgendaTuiUtcDays(date, delta);
}

function computeAgendaTuiNextMonthFirst(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1));
}

function formatAgendaTuiPlanningLabel(dateIso: string): string {
  const timestamp = formatOrgDateTimestamp(dateIso);
  if (!timestamp) throw new Error(`Invalid date: ${dateIso}`);
  return timestamp;
}

function applyAgendaTuiPlanning(item: ScheduledItem, kind: "scheduled" | "deadline", dateIso: string): ScheduledItem {
  const input = fs.readFileSync(item.filePath, "utf8");
  const updated = updatePlanningInText(input, {
    filePath: item.filePath,
    lineNumber: item.lineNumber + 1,
    kind: planningKindFromArg(kind),
    date: dateIso,
  });
  fs.writeFileSync(item.filePath, updated.text, "utf8");
  return { ...item, date: dateIso, kind: planningKindFromArg(kind) };
}

function applyAgendaTuiTodo(item: ScheduledItem, status: TodoStatus): ScheduledItem {
  const input = fs.readFileSync(item.filePath, "utf8");
  const updated = updateTodoInText(input, {
    filePath: item.filePath,
    lineNumber: item.lineNumber + 1,
    status,
  });
  fs.writeFileSync(item.filePath, updated.text, "utf8");
  return { ...item, todo: status === "in_progress" ? "IN_PROGRESS" : status.toUpperCase() };
}

function applyAgendaTuiDoneAndAgentHandoff(item: ScheduledItem): ScheduledItem {
  const timestamp = formatOrgTimestamp(new Date());
  const parentSendItem = findAgendaTuiParentSendItem(item);
  const doneItem = applyAgendaTuiTodo(item, "done");
  if (parentSendItem) {
    const approvedItem = applyAgendaTuiProperty(doneItem, "STATUS", "approved");
    let sendItem = applyAgendaTuiProperty(parentSendItem, "STATUS", agendaApprovedAgentActionStatus(parentSendItem.headline));
    sendItem = applyAgendaTuiProperty(sendItem, "ASSIGNEE", "OpenClaw");
    sendItem = applyAgendaTuiProperty(sendItem, "ORG2_AGENT_HANDOFF_AT", timestamp);
    if (item.id) sendItem = applyAgendaTuiProperty(sendItem, "APPROVAL_ID", item.id);
    return approvedItem;
  }
  const readyItem = applyAgendaTuiProperty(doneItem, "STATUS", "ready-for-agent");
  return applyAgendaTuiProperty(readyItem, "ORG2_AGENT_HANDOFF_AT", timestamp);
}

function isAgendaApprovalTitle(title: string): boolean {
  return /^Approve\b/i.test(title);
}

function isAgendaApprovedSendTitle(title: string): boolean {
  return /^Send approved\b/i.test(title);
}

function isAgendaApprovedAgentActionTitle(title: string): boolean {
  return /^(Send approved|Continue approved)\b/i.test(title);
}

function agendaApprovedAgentActionStatus(title: string): string {
  return isAgendaApprovedSendTitle(title) ? "approved-to-send" : "ready-for-agent";
}

function agendaPairedActionTitleCandidates(properties: Record<string, string>): string[] {
  return [
    "PAIRED_SEND_TODO",
    "PAIRED_AGENT_TODO",
    "PAIRED_TODO",
    "NEXT_AGENT_TODO",
    "SEND_TODO",
  ].flatMap((key) => {
    const value = properties[key]?.trim();
    return value ? [value] : [];
  });
}

function applyNestedApprovalHandoffInText(text: string, lineNumber: number, timestamp: string): { text: string; changed: boolean } {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  let childIndex = Math.max(0, Math.min(lines.length - 1, lineNumber - 1));
  while (childIndex >= 0 && !parseHeadlineLine(lines[childIndex] ?? "")) childIndex -= 1;
  if (childIndex < 0) return { text, changed: false };

  const child = parseHeadlineLine(lines[childIndex] ?? "");
  if (!child || child.level <= 1 || child.todo !== "DONE" || !isAgendaApprovalTitle(child.title)) {
    return { text, changed: false };
  }

  const childProperties = extractAgendaPropertiesNearHeadline(lines, childIndex);
  const pairedTitles = new Set(agendaPairedActionTitleCandidates(childProperties).map(normalizeAgendaPropertyValue));
  let parentIndex = -1;
  let parent: ReturnType<typeof parseHeadlineLine> = null;
  for (let i = childIndex - 1; i >= 0; i -= 1) {
    const parsed = parseHeadlineLine(lines[i] ?? "");
    if (!parsed) continue;
    if (parsed.level >= child.level) continue;
    if (pairedTitles.size > 0 && !pairedTitles.has(normalizeAgendaPropertyValue(parsed.title))) return { text, changed: false };
    if (pairedTitles.size === 0 && !isAgendaApprovedAgentActionTitle(parsed.title)) return { text, changed: false };
    parentIndex = i;
    parent = parsed;
    break;
  }
  if (parentIndex < 0 || !parent) return { text, changed: false };

  const approvalId = agendaPrimaryIdFromProperties(childProperties);
  upsertHeadlinePropertyInLines(lines, childIndex, "STATUS", "approved");
  upsertHeadlinePropertyInLines(lines, childIndex, isAgendaApprovedSendTitle(parent.title) ? "PAIRED_SEND_TODO" : "PAIRED_AGENT_TODO", parent.title);
  upsertHeadlinePropertyInLines(lines, parentIndex, "STATUS", agendaApprovedAgentActionStatus(parent.title));
  upsertHeadlinePropertyInLines(lines, parentIndex, "ASSIGNEE", "OpenClaw");
  upsertHeadlinePropertyInLines(lines, parentIndex, "ORG2_AGENT_HANDOFF_AT", timestamp);
  if (approvalId) upsertHeadlinePropertyInLines(lines, parentIndex, "APPROVAL_ID", approvalId);
  return { text: lines.join("\n"), changed: true };
}

function findAgendaTuiParentSendItem(item: ScheduledItem): ScheduledItem | null {
  if (item.level <= 1 || !isAgendaApprovalTitle(item.headline)) return null;
  const content = fs.readFileSync(item.filePath, "utf8").replace(/\r\n/g, "\n");
  const lines = content.split("\n");
  for (let i = item.lineNumber - 1; i >= 0; i -= 1) {
    const parsed = parseHeadlineLine(lines[i] ?? "");
    if (!parsed) continue;
    if (parsed.level >= item.level) continue;
    if (!isAgendaApprovedAgentActionTitle(parsed.title)) return null;
    const properties = extractAgendaPropertiesNearHeadline(lines, i);
    const candidateId = agendaPrimaryIdFromProperties(properties);
    return {
      filePath: item.filePath,
      lineNumber: i,
      headline: parsed.title,
      body: "",
      todo: parsed.todo,
      priority: parsed.priority,
      effort: properties.EFFORT,
      id: candidateId,
      level: parsed.level,
      date: item.date,
      time: undefined,
      kind: item.kind,
      tags: parsed.tags,
      properties,
    };
  }

  return null;
}

function applyAgendaTuiPriority(item: ScheduledItem, priority: string | null): ScheduledItem {
  const lines = fs.readFileSync(item.filePath, "utf8").split(/\r?\n/);
  const lineIndex = item.lineNumber;
  const originalLine = lines[lineIndex] ?? "";
  const parsed = parseHeadlineLine(originalLine);
  if (!parsed) {
    throw new Error(`Could not parse headline at ${item.filePath}:${lineIndex + 1}`);
  }

  const starsMatch = /^(\*+)\s+/.exec(originalLine);
  if (!starsMatch) {
    throw new Error(`Could not locate headline stars at ${item.filePath}:${lineIndex + 1}`);
  }

  const nextPriority = normalizeAgendaPriorityToken(priority ?? "");
  const todoPrefix = parsed.todo ? `${parsed.todo} ` : "";
  const priorityPrefix = nextPriority ? `[#${nextPriority}] ` : "";
  const tagsSuffix = parsed.tags.length > 0 ? ` :${parsed.tags.join(":")}:` : "";
  lines[lineIndex] = `${starsMatch[1]} ${todoPrefix}${priorityPrefix}${parsed.title}${tagsSuffix}`;
  fs.writeFileSync(item.filePath, lines.join("\n"), "utf8");
  return { ...item, priority: nextPriority ?? undefined };
}

function parseAgendaTuiPropertyAssignment(raw: string): { key: string; value: string } | null {
  const trimmed = String(raw || "").trim();
  const equalsIndex = trimmed.indexOf("=");
  if (equalsIndex <= 0) return null;

  const key = normalizeAgendaPropertyKey(trimmed.slice(0, equalsIndex));
  const value = trimmed.slice(equalsIndex + 1).trim();
  if (!key || !/^[A-Z0-9_@#%+.-]+$/.test(key)) return null;
  return { key, value };
}

function applyAgendaTuiProperty(item: ScheduledItem, key: string, value: string): ScheduledItem {
  const lines = fs.readFileSync(item.filePath, "utf8").replace(/\r\n/g, "\n").split("\n");
  const headingIndex = item.lineNumber;
  if (!isHeadlineLine(lines[headingIndex] ?? "")) {
    throw new Error(`Could not locate headline at ${item.filePath}:${headingIndex + 1}`);
  }

  upsertHeadlinePropertyInLines(lines, headingIndex, key, value);
  fs.writeFileSync(item.filePath, lines.join("\n"), "utf8");
  return { ...item, properties: { ...item.properties, [key]: value } };
}

function openAgendaTuiItem(item: ScheduledItem): void {
  const line = item.lineNumber + 1;
  const target = `${item.filePath}:${line}`;
  const editor = String(process.env.EDITOR || "").trim();

  if (editor) {
    spawnSync(editor, [item.filePath], { stdio: "inherit", shell: true });
    return;
  }

  const code = spawnSync("code", ["-g", target], { stdio: "inherit" });
  if ((code.status ?? 1) === 0) return;

  spawnSync("open", [item.filePath], { stdio: "inherit" });
}

function resolveAgendaTuiTodayDailyNotePath(config: Org2Config | null, baseDir: string): string {
  const dailiesRoot = resolveRoamDailiesRootDir(config || {}, baseDir);
  // Reuse an existing legacy .org2 daily note; new ones are .org.
  const legacy = path.join(dailiesRoot, `${getTodayString()}.org2`);
  return fs.existsSync(legacy) ? legacy : path.join(dailiesRoot, `${getTodayString()}.org`);
}

function formatAgendaTuiDateTimestamp(dateIso: string): string {
  const timestamp = formatOrgDateTimestamp(dateIso);
  if (!timestamp) throw new Error(`Invalid date: ${dateIso}`);
  return timestamp;
}

function appendAgendaTuiTodoToDailyNote(dailyNotePath: string, title: string): void {
  fs.mkdirSync(path.dirname(dailyNotePath), { recursive: true });
  const scheduled = formatAgendaTuiDateTimestamp(getTodayString());
  const entry = `* TODO ${title}\nSCHEDULED: ${scheduled}\n`;
  if (!fs.existsSync(dailyNotePath)) {
    fs.writeFileSync(dailyNotePath, entry, "utf8");
    return;
  }

  const existing = fs.readFileSync(dailyNotePath, "utf8");
  const prefix = existing.length === 0 || existing.endsWith("\n") ? existing : `${existing}\n`;
  fs.writeFileSync(dailyNotePath, `${prefix}${entry}`, "utf8");
}

async function runAgendaTui(options: {
  startIso: string;
  rangeLabel: string;
  refreshMs: number;
  collect: (runtime: { startIso: string }) => { items: ScheduledItem[]; skippedFiles: number };
  getTodayDailyNotePath: () => string;
}): Promise<void> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.error("Error: --tui requires an interactive terminal.");
    process.exit(1);
  }

  const ansi = {
    reset: "\u001b[0m",
    dim: "\u001b[2m",
    bold: "\u001b[1m",
    reverse: "\u001b[7m",
    cyan: "\u001b[36m",
    yellow: "\u001b[33m",
    green: "\u001b[32m",
    red: "\u001b[31m",
    magenta: "\u001b[35m",
  } as const;

  let mode: AgendaTuiMode = "range";
  let selected = 0;
  let scrollOffset = 0;
  let detailScrollOffset = 0;
  let lastBodyHeight = 8;
  let message = "";
  let items: ScheduledItem[] = [];
  let skippedFiles = 0;
  let sections: AgendaTuiSection[] = [];
  let rows: AgendaTuiRow[] = [];
  let lastRefresh = new Date(0);
  let currentStartIso = options.startIso;
  let disposed = false;
  let refreshTimer: NodeJS.Timeout | null = null;
  let pendingPriorityKey: "p" | null = null;
  let captureInputActive = false;
  let captureInputValue = "";
  let propertyInputActive = false;
  let propertyInputValue = "";
  let searchInputActive = false;
  let searchQuery = "";
  const collapsedSections = new Set<string>();

  const stripAnsi = (input: string): string => input.replace(/\u001b\[[0-9;]*m/g, "");
  const padPlain = (input: string, width: number): string => truncateForTerminal(input, width).padEnd(Math.max(width, 0), " ");
  const padStyled = (input: string, width: number): string => {
    const plain = truncateForTerminal(stripAnsi(input), width);
    return plain.padEnd(Math.max(width, 0), " ");
  };
  const colorize = (text: string, color: string): string => `${color}${text}${ansi.reset}`;
  const bucketForItem = (item: ScheduledItem): AgendaStatusBucket | null => agendaStatusBucketForKeyword(item.todo);
  const colorForBucket = (bucket: AgendaStatusBucket | null): string => {
    if (bucket === "todo") return ansi.yellow;
    if (bucket === "in_progress") return ansi.cyan;
    if (bucket === "done") return ansi.green;
    if (bucket === "canceled") return ansi.dim;
    if (bucket === "custom") return ansi.magenta;
    return ansi.reset;
  };

  const selectedRow = (): AgendaTuiRow | undefined => rows[selected];

  const ensureSelection = (): void => {
    if (rows.length === 0) {
      selected = 0;
      return;
    }
    selected = Math.max(0, Math.min(selected, rows.length - 1));
  };

  const refresh = (): void => {
    currentStartIso = getTodayString();
    const result = options.collect({ startIso: currentStartIso });
    items = filterAgendaTuiItems(result.items, searchQuery);
    skippedFiles = result.skippedFiles;
    sections = buildAgendaTuiSections(items, currentStartIso, mode);
    const liveKeys = new Set(sections.map((section) => section.key));
    for (const key of Array.from(collapsedSections)) {
      if (!liveKeys.has(key)) collapsedSections.delete(key);
    }
    rows = buildAgendaTuiRows(sections, collapsedSections);
    ensureSelection();
    lastRefresh = new Date();
  };

  const moveSelection = (delta: number): void => {
    if (rows.length === 0) return;
    const before = selected;
    selected = Math.max(0, Math.min(rows.length - 1, selected + delta));
    if (selected !== before) detailScrollOffset = 0;
  };

  const scrollDetail = (delta: number): void => {
    detailScrollOffset = Math.max(0, detailScrollOffset + delta);
  };

  const toggleCollapse = (): void => {
    const row = selectedRow();
    if (!row) return;
    const key = row.type === "section" ? row.key : row.sectionKey;
    if (!key) return;
    if (collapsedSections.has(key)) collapsedSections.delete(key);
    else collapsedSections.add(key);
    rows = buildAgendaTuiRows(sections, collapsedSections);
    if (row.type === "item") {
      selected = Math.max(0, rows.findIndex((candidate) => candidate.type === "section" && candidate.key === key));
    }
    ensureSelection();
  };

  const buildDetailLines = (row: AgendaTuiRow | undefined, width: number): string[] => {
    const lines: string[] = [];
    const pushWrapped = (text = "", continuationIndent = 0): void => {
      for (const line of wrapTerminalLine(text, width, continuationIndent)) {
        lines.push(padPlain(line, width));
      }
    };
    if (!row) return [padPlain("No items.", width)];

    if (row.type === "section") {
      const section = sections.find((candidate) => candidate.key === row.key);
      pushWrapped(`${row.label} (${row.count})`);
      pushWrapped(row.collapsed ? "collapsed, press enter/l to expand" : "expanded, press enter/h to collapse");
      if (row.hint) pushWrapped(`bucket: ${row.hint}`);
      if (section && section.items.length > 0) {
        lines.push(padPlain("", width));
        pushWrapped("first items:");
        for (const item of section.items) {
          pushWrapped(`• ${stripRoamLinksForAgendaTui(item.headline)}`, 2);
        }
      }
    } else {
      const item = row.item;
      const status = agendaTuiStatus(item);
      const timing = item.date === currentStartIso ? "today" : item.date < currentStartIso ? `overdue since ${item.date}` : item.date;
      const kind = String(item.kind || "").toUpperCase();
      pushWrapped(stripRoamLinksForAgendaTui(item.headline));
      pushWrapped(`${status || "ITEM"} · ${kind || "ITEM"} · ${timing}`);
      pushWrapped(`${path.basename(item.filePath)}:${item.lineNumber + 1}`);
      if (item.time) pushWrapped(`time: ${item.time}`);
      if (item.priority) pushWrapped(`priority: ${item.priority}`);
      if (item.effort) pushWrapped(`effort: ${item.effort}`);
      if (item.tags && item.tags.length > 0) pushWrapped(`tags: ${item.tags.join(", ")}`, "tags: ".length);
      if (item.id) pushWrapped(`id: ${item.id}`);
      lines.push(padPlain("", width));
      const properties = Object.entries(item.properties || {}).sort((a, b) => a[0].localeCompare(b[0]));
      pushWrapped("properties:");
      if (properties.length === 0) {
        pushWrapped("(none)", 2);
      } else {
        for (const [key, value] of properties) {
          pushWrapped(`${key}: ${value}`, 2);
        }
      }
      lines.push(padPlain("", width));
      pushWrapped("body:");
      const body = String(item.body || "").trim();
      if (!body) {
        pushWrapped("(empty)", 2);
      } else {
        for (const bodyLine of body.split("\n")) {
          pushWrapped(bodyLine, 2);
        }
      }
      lines.push(padPlain("", width));
      pushWrapped("P set property   c capture TODO   t/i/d/x/A status");
      pushWrapped("s/n/w/m schedule  S/N/W/M deadline  o open");
    }

    return lines;
  };

  const buildRowLines = (row: AgendaTuiRow, width: number): { lines: string[]; color: string } => {
    if (row.type === "section") {
      const marker = row.collapsed ? "▶" : "▼";
      const text = `${marker} ${row.label} (${row.count})`;
      return {
        lines: [padPlain(text, width)],
        color: row.hint === "overdue" ? ansi.red : ansi.bold + ansi.cyan,
      };
    }

    const item = row.item;
    const status = `[${agendaTuiStatus(item)}]`;
    const timing = item.date === currentStartIso ? "today" : item.date < currentStartIso ? `late ${item.date}` : item.date;
    const prefix = `  ${status} ${item.time ? `${item.time} ` : ""}`;
    const displayHeadline = stripRoamLinksForAgendaTui(item.headline);
    const suffix = `${displayHeadline}${item.priority ? ` [#${item.priority}]` : ""} · ${timing}`;
    const wrapped = wrapTerminalLine(`${prefix}${suffix}`, width, prefix.length);
    return {
      lines: wrapped.map((line) => padPlain(line, width)),
      color: colorForBucket(bucketForItem(item)),
    };
  };

  const render = (): void => {
    const width = process.stdout.columns || 100;
    const height = process.stdout.rows || 30;
    const actionableToday = items.filter((item) => item.date === currentStartIso && isAgendaTuiActionable(item)).length;
    const actionableOverdue = items.filter((item) => item.date < currentStartIso && isAgendaTuiActionable(item)).length;
    const rangeLabel = options.rangeLabel.replace(options.startIso, currentStartIso);
    const searchLabel = searchQuery.trim() ? `, filter /${searchQuery.trim()} (${items.length})` : "";
    const keyHelp = pendingPriorityKey
      ? "priority mode: a/b/c set priority, 0 clears, esc cancels"
      : "j/k arrows move, J/K detail scroll, Ctrl-d/u half-page detail, / search, gg/G jump, 1/2/3 views, enter collapse, c capture, P set property, t/i/d/x status, A done+handoff, p+a/b/c priority, p+0 clear, s/n/w/m schedule, S/N/W/M deadline, o open, r refresh, q quit";
    const header = [
      `${ansi.bold}Celorga agenda${ansi.reset}  ${mode === "focus" ? "focus" : mode === "today" ? "today" : "range"}  ${rangeLabel}`,
      `${actionableToday} actionable today, ${actionableOverdue} overdue${searchLabel}, refresh ${Math.max(1, Math.round(options.refreshMs / 1000))}s, updated ${lastRefresh.toLocaleTimeString()}`,
      ...(captureInputActive
        ? [
            `CAPTURE TODO: ${captureInputValue}`,
            "type title, enter save, esc cancel, backspace delete",
          ]
        : propertyInputActive
          ? [
              `SET PROPERTY: ${propertyInputValue}`,
              "type KEY=VALUE, enter save, esc cancel, backspace delete",
            ]
        : searchInputActive
          ? [
              `SEARCH: /${searchQuery}`,
              "type filter, enter keep, esc clear, backspace delete",
            ]
        : wrapTerminalLine(keyHelp, width).slice(0, 2)),
      "",
    ];
    const headerHeight = header.length;
    const bodyHeight = Math.max(8, height - headerHeight - 1);
    lastBodyHeight = bodyHeight;
    const leftWidth = Math.max(30, Math.min(width - 22, Math.floor(width * 0.58)));
    const rightWidth = Math.max(20, width - leftWidth - 3);

    const renderedRows = rows.map((row) => buildRowLines(row, leftWidth));
    const rowOffsets: number[] = [];
    let totalLeftLines = 0;
    for (const rendered of renderedRows) {
      rowOffsets.push(totalLeftLines);
      totalLeftLines += rendered.lines.length;
    }

    const selectedStart = rowOffsets[selected] || 0;
    const selectedHeight = renderedRows[selected]?.lines.length || 1;
    const selectedEnd = selectedStart + selectedHeight;
    if (selectedStart < scrollOffset) scrollOffset = selectedStart;
    if (selectedEnd > scrollOffset + bodyHeight) scrollOffset = selectedEnd - bodyHeight;
    scrollOffset = Math.max(0, Math.min(scrollOffset, Math.max(0, totalLeftLines - bodyHeight)));

    const leftLines: string[] = [];
    for (let rowIndex = 0; rowIndex < renderedRows.length; rowIndex += 1) {
      const rowStart = rowOffsets[rowIndex] || 0;
      const rowEnd = rowStart + renderedRows[rowIndex].lines.length;
      if (rowEnd <= scrollOffset) continue;
      if (rowStart >= scrollOffset + bodyHeight) break;
      const isSelected = rowIndex === selected;
      for (let lineIndex = 0; lineIndex < renderedRows[rowIndex].lines.length; lineIndex += 1) {
        const absoluteLine = rowStart + lineIndex;
        if (absoluteLine < scrollOffset) continue;
        if (absoluteLine >= scrollOffset + bodyHeight) break;
        const padded = padStyled(renderedRows[rowIndex].lines[lineIndex] || "", leftWidth);
        const tinted = renderedRows[rowIndex].color === ansi.reset ? padded : colorize(padded, renderedRows[rowIndex].color);
        leftLines.push(isSelected ? `${ansi.reverse}${tinted}${ansi.reset}` : tinted);
      }
    }

    while (leftLines.length < bodyHeight) leftLines.push(" ".repeat(leftWidth));
    const detailLines = buildDetailLines(selectedRow(), rightWidth);
    const maxDetailScroll = Math.max(0, detailLines.length - bodyHeight);
    detailScrollOffset = Math.max(0, Math.min(detailScrollOffset, maxDetailScroll));
    const rightLines = detailLines
      .slice(detailScrollOffset, detailScrollOffset + bodyHeight)
      .map((line) => padPlain(line, rightWidth));
    while (rightLines.length < bodyHeight) rightLines.push(" ".repeat(rightWidth));
    if (maxDetailScroll > 0 && rightLines.length > 0) {
      const indicator = `detail ${Math.min(detailScrollOffset + 1, detailLines.length)}/${detailLines.length}`;
      rightLines[0] = padPlain(`${truncateForTerminal(stripAnsi(rightLines[0] || ""), Math.max(0, rightWidth - indicator.length - 1))} ${indicator}`, rightWidth);
    }

    const screen = ["\u001b[?25l\u001b[2J\u001b[H", ...header.map((line) => padPlain(line, width))];
    for (let index = 0; index < bodyHeight; index += 1) {
      const left = leftLines[index] || " ".repeat(leftWidth);
      const gap = `${ansi.dim} │ ${ansi.reset}`;
      const right = rightLines[index] || " ".repeat(rightWidth);
      screen.push(`${left}${gap}${right}`);
    }

    const footer = padPlain(message || `skipped files: ${skippedFiles}`, width);
    screen.push(footer);
    process.stdout.write(screen.join("\n"));
  };

  const cleanup = (): void => {
    if (disposed) return;
    disposed = true;
    if (refreshTimer) clearInterval(refreshTimer);
    process.stdin.setRawMode(false);
    process.stdin.pause();
    process.stdout.write("\u001b[0m\u001b[?25h\u001b[2J\u001b[H");
  };

  const withSuspendedTty = (fn: () => void): void => {
    process.stdout.write("\u001b[0m\u001b[?25h");
    process.stdin.setRawMode(false);
    try {
      fn();
    } finally {
      process.stdin.setRawMode(true);
      process.stdin.resume();
    }
  };

  refresh();
  render();
  refreshTimer = setInterval(() => {
    try {
      refresh();
      message = "";
      render();
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
      render();
    }
  }, options.refreshMs);

  process.stdin.setRawMode(true);
  process.stdin.resume();

  await new Promise<void>((resolve, reject) => {
    let pendingG = false;
    const onData = async (chunk: Buffer) => {
      const key = chunk.toString("utf8");
      try {
        if (captureInputActive) {
          if (key === "\u0003") {
            cleanup();
            process.stdin.off("data", onData);
            resolve();
            return;
          }
          if (key === "\u001b") {
            captureInputActive = false;
            captureInputValue = "";
            message = "capture canceled";
            render();
            return;
          }
          if (key === "\r" || key === "\n") {
            const title = captureInputValue.trim().replace(/[\r\n]+/g, " ");
            captureInputActive = false;
            captureInputValue = "";
            if (title) {
              const dailyNotePath = options.getTodayDailyNotePath();
              appendAgendaTuiTodoToDailyNote(dailyNotePath, title);
              message = `captured TODO → ${path.basename(dailyNotePath)}`;
              refresh();
            } else {
              message = "capture canceled";
            }
            render();
            return;
          }
          if (key === "\u007f" || key === "\b" || key === "\x08") {
            captureInputValue = captureInputValue.slice(0, -1);
            render();
            return;
          }
          if (key >= " " && key !== "\u007f" && !key.startsWith("\u001b")) {
            captureInputValue += key.replace(/[\r\n]+/g, " ");
            render();
            return;
          }
          render();
          return;
        }

        if (propertyInputActive) {
          if (key === "\u0003") {
            cleanup();
            process.stdin.off("data", onData);
            resolve();
            return;
          }
          if (key === "\u001b") {
            propertyInputActive = false;
            propertyInputValue = "";
            message = "property edit canceled";
            render();
            return;
          }
          if (key === "\r" || key === "\n") {
            const assignment = parseAgendaTuiPropertyAssignment(propertyInputValue);
            propertyInputActive = false;
            propertyInputValue = "";
            const row = selectedRow();
            if (row?.type === "item" && assignment) {
              applyAgendaTuiProperty(row.item, assignment.key, assignment.value);
              message = `${assignment.key}=${assignment.value} → ${stripRoamLinksForAgendaTui(row.item.headline)}`;
              refresh();
            } else {
              message = "property edit canceled; use KEY=VALUE";
            }
            render();
            return;
          }
          if (key === "\u007f" || key === "\b" || key === "\x08") {
            propertyInputValue = propertyInputValue.slice(0, -1);
            render();
            return;
          }
          if (key >= " " && key !== "\u007f" && !key.startsWith("\u001b")) {
            propertyInputValue += key.replace(/[\r\n]+/g, " ");
            render();
            return;
          }
          render();
          return;
        }

        if (searchInputActive) {
          if (key === "\u0003") {
            cleanup();
            process.stdin.off("data", onData);
            resolve();
            return;
          }
          if (key === "\u001b") {
            searchInputActive = false;
            searchQuery = "";
            message = "search cleared";
            refresh();
            render();
            return;
          }
          if (key === "\r" || key === "\n") {
            searchInputActive = false;
            message = searchQuery.trim() ? `filter /${searchQuery.trim()}` : "search cleared";
            refresh();
            render();
            return;
          }
          if (key === "\u007f" || key === "\b" || key === "\x08") {
            searchQuery = searchQuery.slice(0, -1);
            refresh();
            render();
            return;
          }
          if (key >= " " && key !== "\u007f" && !key.startsWith("\u001b")) {
            searchQuery += key.replace(/[\r\n]+/g, " ");
            refresh();
            render();
            return;
          }
          render();
          return;
        }

        if (key === "q" || key === "\u0003") {
          cleanup();
          process.stdin.off("data", onData);
          resolve();
          return;
        }

        if (pendingG) {
          if (key === "g") {
            selected = 0;
            detailScrollOffset = 0;
          }
          pendingG = false;
          render();
          return;
        }

        if (pendingPriorityKey) {
          if (key === "\u001b") {
            pendingPriorityKey = null;
            message = "Priority change canceled";
          } else {
            const row = selectedRow();
            const nextPriority = key === "0" ? null : normalizeAgendaPriorityToken(key);
            if (row?.type === "item" && (nextPriority || key === "0")) {
              applyAgendaTuiPriority(row.item, nextPriority);
              message = nextPriority ? `priority [#${nextPriority}] → ${stripRoamLinksForAgendaTui(row.item.headline)}` : `priority cleared → ${stripRoamLinksForAgendaTui(row.item.headline)}`;
              refresh();
            } else {
              message = "Priority mode: press a, b, c, or 0 to clear";
            }
            pendingPriorityKey = null;
          }
        } else if (key === "g") pendingG = true;
        else if (key === "G") {
          selected = Math.max(0, rows.length - 1);
          detailScrollOffset = 0;
        }
        else if (key === "j" || key === "\u001b[B") moveSelection(1);
        else if (key === "k" || key === "\u001b[A") moveSelection(-1);
        else if (key === "J") scrollDetail(1);
        else if (key === "K") scrollDetail(-1);
        else if (key === "\u0004") scrollDetail(Math.max(1, Math.floor(lastBodyHeight / 2)));
        else if (key === "\u0015") scrollDetail(-Math.max(1, Math.floor(lastBodyHeight / 2)));
        else if (key === "/") {
          searchInputActive = true;
          searchQuery = "";
          message = "";
          refresh();
        }
        else if (key === "c") {
          captureInputActive = true;
          captureInputValue = "";
          message = "";
        } else if (key === "P") {
          const row = selectedRow();
          if (row?.type === "item") {
            propertyInputActive = true;
            propertyInputValue = "";
            message = "";
          } else {
            message = "Select an agenda item before setting a property";
          }
        } else if (key === "r") refresh();
        else if (key === "p") {
          pendingPriorityKey = "p";
          message = "Priority mode: press a, b, c, or 0 to clear";
        } else if (key === "1" || key === "2" || key === "3") {
          mode = nextAgendaTuiMode(mode, key);
          detailScrollOffset = 0;
          refresh();
        } else if (key === "\r" || key === "\n" || key === "h" || key === "l") {
          toggleCollapse();
          detailScrollOffset = 0;
        } else if ([" ", "t", "i", "d", "x", "A", "o", "s", "n", "w", "m", "S", "N", "W", "M"].includes(key)) {
          const row = selectedRow();
          if (row?.type === "item") {
            if (key === "o") {
              withSuspendedTty(() => openAgendaTuiItem(row.item));
            } else if (key === "A") {
              applyAgendaTuiDoneAndAgentHandoff(row.item);
              message = `done + OpenClaw handoff → ${stripRoamLinksForAgendaTui(row.item.headline)}`;
              refresh();
            } else if (["s", "n", "w", "m", "S", "N", "W", "M"].includes(key)) {
              const now = new Date();
              const today = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
              const kind = ["S", "N", "W", "M"].includes(key) ? "deadline" : "scheduled";
              const target =
                key === "s" || key === "S"
                  ? today
                  : key === "n" || key === "N"
                    ? addAgendaTuiUtcDays(today, 1)
                    : key === "w" || key === "W"
                      ? computeAgendaTuiUpcomingMonday(today)
                      : computeAgendaTuiNextMonthFirst(today);
              const dateIso = formatAgendaTuiIsoDate(target);
              applyAgendaTuiPlanning(row.item, kind, dateIso);
              message = `${kind.toUpperCase()} ${formatAgendaTuiPlanningLabel(dateIso)} → ${stripRoamLinksForAgendaTui(row.item.headline)}`;
              refresh();
            } else {
              const nextStatus: TodoStatus =
                key === " "
                  ? cycleAgendaTuiStatus(row.item)
                  : key === "t"
                    ? "todo"
                    : key === "i"
                      ? "in_progress"
                      : key === "d"
                        ? "done"
                        : "canceled";
              applyAgendaTuiTodo(row.item, nextStatus);
              message = `${nextStatus} → ${stripRoamLinksForAgendaTui(row.item.headline)}`;
              refresh();
            }
          }
        }

        render();
      } catch (error) {
        cleanup();
        process.stdin.off("data", onData);
        reject(error);
      }
    };

    process.stdin.on("data", onData);
  }).finally(() => cleanup());
}

function compareAgendaPriorityValues(
  aPriority: string | undefined,
  bPriority: string | undefined,
  priorityOrder: AgendaPriorityOrder,
): number {
  const a = normalizeAgendaPriorityToken(String(aPriority || ""));
  const b = normalizeAgendaPriorityToken(String(bPriority || ""));

  if (!a && !b) return 0;
  if (!a) return 1;
  if (!b) return -1;

  const defaultRank = (priority: string): number => {
    if (/^[A-Z]$/.test(priority)) {
      return priority.charCodeAt(0) - 65;
    }
    if (/^[0-9]$/.test(priority)) {
      return 26 + Number.parseInt(priority, 10);
    }
    return 100 + priority.charCodeAt(0);
  };

  const rank = (priority: string): number => {
    if (priorityOrder && priorityOrder.size > 0) {
      const customRank = priorityOrder.get(priority);
      if (customRank !== undefined) return customRank;
      return priorityOrder.size + defaultRank(priority);
    }

    return defaultRank(priority);
  };

  return rank(a) - rank(b);
}

function agendaEffortOrderToken(effort: string | undefined): string {
  const normalized = normalizeAgendaEffortToken(String(effort || ""));
  if (!normalized) return AGENDA_EFFORT_ORDER_EMPTY;
  return normalized;
}

function compareAgendaEffortValues(
  aEffort: string | undefined,
  bEffort: string | undefined,
  effortOrder: AgendaEffortOrder,
): number {
  if (effortOrder && effortOrder.size > 0) {
    const aRank = effortOrder.get(agendaEffortOrderToken(aEffort));
    const bRank = effortOrder.get(agendaEffortOrderToken(bEffort));

    if (aRank !== undefined && bRank !== undefined) {
      const byRank = aRank - bRank;
      if (byRank !== 0) return byRank;
    } else if (aRank !== undefined) {
      return -1;
    } else if (bRank !== undefined) {
      return 1;
    }
  }

  const aMinutes = parseAgendaEffortToMinutes(String(aEffort || ""));
  const bMinutes = parseAgendaEffortToMinutes(String(bEffort || ""));

  if (aMinutes !== null && bMinutes !== null) {
    return aMinutes - bMinutes;
  }

  if (aMinutes !== null) return -1;
  if (bMinutes !== null) return 1;

  const aText = normalizeAgendaEffortToken(String(aEffort || ""));
  const bText = normalizeAgendaEffortToken(String(bEffort || ""));

  if (!aText && !bText) return 0;
  if (!aText) return 1;
  if (!bText) return -1;

  return aText.localeCompare(bText);
}

function agendaStatusSortBucketForItem(item: ScheduledItem): AgendaStatusBucket | null {
  return item.todoTerminal === true ? "done" : item.todoTerminal === false && isTerminalTodoKeyword(item.todo) ? "todo" : agendaStatusBucketForKeyword(item.todo);
}

function agendaActiveTerminalSortRankForItem(item: ScheduledItem): number {
  const bucket = agendaStatusSortBucketForItem(item);
  if (bucket === "todo" || bucket === "in_progress") return 0;
  if (bucket === "done" || bucket === "canceled") return 1;
  return 2;
}

function compareAgendaActiveTerminalStatusBuckets(a: ScheduledItem, b: ScheduledItem): number {
  return agendaActiveTerminalSortRankForItem(a) - agendaActiveTerminalSortRankForItem(b);
}

function compareAgendaStatusBuckets(a: ScheduledItem, b: ScheduledItem, statusOrder: AgendaStatusOrder): number {
  const defaultRankForBucket = (bucket: AgendaStatusBucket | null): number => {
    if (bucket === "todo") return 0;
    if (bucket === "in_progress") return 1;
    if (bucket === "done") return 2;
    if (bucket === "canceled") return 3;
    if (bucket === "custom") return 4;
    return 5;
  };

  const rankForBucket = (bucket: AgendaStatusBucket | null): number => {
    if (!bucket) return 5;

    if (statusOrder && statusOrder.size > 0) {
      const customRank = statusOrder.get(bucket);
      if (customRank !== undefined) return customRank;
      return statusOrder.size + defaultRankForBucket(bucket);
    }

    return defaultRankForBucket(bucket);
  };

  const aBucket = agendaStatusSortBucketForItem(a);
  const bBucket = agendaStatusSortBucketForItem(b);

  const byRank = rankForBucket(aBucket) - rankForBucket(bBucket);
  if (byRank !== 0) return byRank;

  return String(a.todo || "").localeCompare(String(b.todo || ""));
}

function agendaPlanningKindForItem(item: ScheduledItem): AgendaPlanningKind | null {
  const kind = String(item.kind || "").trim().toUpperCase();
  if (kind === "SCHEDULED" || kind === "DEADLINE") return kind;
  return null;
}

function compareAgendaKinds(a: ScheduledItem, b: ScheduledItem, kindOrder: AgendaKindOrder): number {
  const defaultRankForKind = (kind: AgendaPlanningKind | null): number => {
    if (kind === "DEADLINE") return 0;
    if (kind === "SCHEDULED") return 1;
    return 2;
  };

  const rankForKind = (kind: AgendaPlanningKind | null): number => {
    if (!kind) return 2;

    if (kindOrder && kindOrder.size > 0) {
      const customRank = kindOrder.get(kind);
      if (customRank !== undefined) return customRank;
      return kindOrder.size + defaultRankForKind(kind);
    }

    return defaultRankForKind(kind);
  };

  const aKind = agendaPlanningKindForItem(a);
  const bKind = agendaPlanningKindForItem(b);

  const byRank = rankForKind(aKind) - rankForKind(bKind);
  if (byRank !== 0) return byRank;

  return String(a.kind || "").localeCompare(String(b.kind || ""));
}

function compareAgendaTodoValues(
  aTodo: string | undefined,
  bTodo: string | undefined,
  todoOrder: AgendaTodoOrder,
): number {
  const a = String(aTodo || "").trim().toUpperCase();
  const b = String(bTodo || "").trim().toUpperCase();

  if (todoOrder && todoOrder.size > 0) {
    const aRank = a ? todoOrder.get(a) : undefined;
    const bRank = b ? todoOrder.get(b) : undefined;

    if (aRank !== undefined && bRank !== undefined) {
      const byRank = aRank - bRank;
      if (byRank !== 0) return byRank;
    } else if (aRank !== undefined) {
      return -1;
    } else if (bRank !== undefined) {
      return 1;
    }
  }

  if (!a && !b) return 0;
  if (!a) return 1;
  if (!b) return -1;

  return a.localeCompare(b);
}

function compareAgendaTagTokens(aTag: string, bTag: string, tagOrder: AgendaTagOrder): number {
  if (tagOrder && tagOrder.size > 0) {
    const aRank = tagOrder.get(aTag);
    const bRank = tagOrder.get(bTag);
    if (aRank !== undefined && bRank !== undefined) {
      if (aRank !== bRank) return aRank - bRank;
    } else if (aRank !== undefined) {
      return -1;
    } else if (bRank !== undefined) {
      return 1;
    }
  }

  return aTag.localeCompare(bTag);
}

function normalizeAgendaTagsForOrdering(tags: string[], tagOrder: AgendaTagOrder): string[] {
  const normalized = Array.from(
    new Set(
      tags
        .map((tag) => String(tag).trim().toLowerCase())
        .filter(Boolean),
    ),
  );

  if (normalized.length === 0) return [];

  normalized.sort((a, b) => compareAgendaTagTokens(a, b, tagOrder));
  return normalized;
}

function compareAgendaTagValues(aTags: string[], bTags: string[], tagOrder: AgendaTagOrder): number {
  const aNormalized = normalizeAgendaTagsForOrdering(aTags, tagOrder);
  const bNormalized = normalizeAgendaTagsForOrdering(bTags, tagOrder);

  if (aNormalized.length === 0 && bNormalized.length === 0) return 0;
  if (tagOrder && tagOrder.size > 0) {
    if (aNormalized.length === 0) return 1;
    if (bNormalized.length === 0) return -1;
  } else {
    if (aNormalized.length === 0) return -1;
    if (bNormalized.length === 0) return 1;
  }

  const maxLen = Math.max(aNormalized.length, bNormalized.length);
  for (let i = 0; i < maxLen; i += 1) {
    const aTag = aNormalized[i];
    const bTag = bNormalized[i];

    if (aTag === undefined && bTag === undefined) break;
    if (aTag === undefined) return -1;
    if (bTag === undefined) return 1;

    const byTag = compareAgendaTagTokens(aTag, bTag, tagOrder);
    if (byTag !== 0) return byTag;
  }

  return 0;
}

function compareAgendaItemsByKey(
  a: ScheduledItem,
  b: ScheduledItem,
  key: AgendaSortKey,
  todoOrder: AgendaTodoOrder,
  statusOrder: AgendaStatusOrder,
  kindOrder: AgendaKindOrder,
  priorityOrder: AgendaPriorityOrder,
  effortOrder: AgendaEffortOrder,
  tagOrder: AgendaTagOrder,
): number {
  if (key === "file") {
    const byFile = a.filePath.localeCompare(b.filePath);
    if (byFile !== 0) return byFile;
    return a.lineNumber - b.lineNumber;
  }

  if (key === "headline") {
    return a.headline.localeCompare(b.headline);
  }

  if (key === "todo") {
    return compareAgendaTodoValues(a.todo, b.todo, todoOrder);
  }

  if (key === "status") {
    return compareAgendaStatusBuckets(a, b, statusOrder);
  }

  if (key === "priority") {
    return compareAgendaPriorityValues(a.priority, b.priority, priorityOrder);
  }

  if (key === "effort") {
    return compareAgendaEffortValues(a.effort, b.effort, effortOrder);
  }

  if (key === "id") {
    const aId = normalizeAgendaItemId(a);
    const bId = normalizeAgendaItemId(b);

    if (!aId && !bId) return 0;
    if (!aId) return 1;
    if (!bId) return -1;

    const byId = aId.localeCompare(bId);
    if (byId !== 0) return byId;
    return a.lineNumber - b.lineNumber;
  }

  if (key === "level") {
    return a.level - b.level;
  }

  if (key === "time") {
    const aMinutes = parseAgendaTimeToMinutes(a.time);
    const bMinutes = parseAgendaTimeToMinutes(b.time);

    if (aMinutes !== null && bMinutes !== null) {
      return aMinutes - bMinutes;
    }

    if (aMinutes !== null) return -1;
    if (bMinutes !== null) return 1;

    return String(a.time || "").localeCompare(String(b.time || ""));
  }

  if (key === "kind") {
    return compareAgendaKinds(a, b, kindOrder);
  }

  if (key === "tags") {
    const byTags = compareAgendaTagValues(a.tags || [], b.tags || [], tagOrder);
    if (byTags !== 0) return byTags;
    return a.lineNumber - b.lineNumber;
  }

  return a.lineNumber - b.lineNumber;
}

function agendaGroupValueForKey(item: ScheduledItem, key: AgendaSortKey, tagOrder: AgendaTagOrder): string {
  if (key === "file") return item.filePath;
  if (key === "headline") return item.headline;
  if (key === "todo") return String(item.todo || "").trim();
  if (key === "status") return agendaStatusSortBucketForItem(item) || "";
  if (key === "priority") return normalizeAgendaPriorityToken(String(item.priority || "")) || "";
  if (key === "effort") return String(item.effort || "").trim();
  if (key === "id") return normalizeAgendaItemId(item);
  if (key === "level") return String(item.level || "").trim();
  if (key === "time") return normalizeAgendaTimeToken(String(item.time || "")) || "";
  if (key === "kind") return String(item.kind || "").trim();
  if (key === "tags") {
    return normalizeAgendaTagsForOrdering(item.tags || [], tagOrder).join(",");
  }
  return String(item.lineNumber);
}

function agendaGroupLabelForItem(item: ScheduledItem, groupOrder: AgendaGroupOrder, tagOrder: AgendaTagOrder): string {
  if (!groupOrder || groupOrder.length === 0) return "";

  const labelForKey = (key: AgendaSortKey): string => {
    if (key === "file") return "File";
    if (key === "headline") return "Headline";
    if (key === "todo") return "TODO";
    if (key === "status") return "Status";
    if (key === "priority") return "Priority";
    if (key === "effort") return "Effort";
    if (key === "id") return "ID";
    if (key === "level") return "Level";
    if (key === "time") return "Time";
    if (key === "kind") return "Kind";
    if (key === "tags") return "Tags";
    return "Line";
  };

  return groupOrder
    .map((field) => {
      const value = agendaGroupValueForKey(item, field.key, tagOrder);
      return `${labelForKey(field.key)}: ${value || "(none)"}`;
    })
    .join(" · ");
}

function agendaGroupKeyForItem(item: ScheduledItem, groupOrder: AgendaGroupOrder, tagOrder: AgendaTagOrder): string {
  if (!groupOrder || groupOrder.length === 0) return "";
  return groupOrder.map((field) => `${field.key}=${agendaGroupValueForKey(item, field.key, tagOrder)}`).join("|\u001f|");
}

function compareAgendaItems(
  a: ScheduledItem,
  b: ScheduledItem,
  groupOrder: AgendaGroupOrder,
  sortOrder: AgendaSortOrder,
  dateOrder: AgendaDateOrder,
  todoOrder: AgendaTodoOrder,
  statusOrder: AgendaStatusOrder,
  kindOrder: AgendaKindOrder,
  priorityOrder: AgendaPriorityOrder,
  effortOrder: AgendaEffortOrder,
  tagOrder: AgendaTagOrder,
): number {
  if (groupOrder && groupOrder.length > 0) {
    for (const field of groupOrder) {
      const cmp = compareAgendaItemsByKey(
        a,
        b,
        field.key,
        todoOrder,
        statusOrder,
        kindOrder,
        priorityOrder,
        effortOrder,
        tagOrder,
      );
      if (cmp !== 0) {
        return field.direction === "desc" ? -cmp : cmp;
      }
    }
  }

  if (sortOrder && sortOrder.length > 0) {
    for (const field of sortOrder) {
      const cmp = compareAgendaItemsByKey(
        a,
        b,
        field.key,
        todoOrder,
        statusOrder,
        kindOrder,
        priorityOrder,
        effortOrder,
        tagOrder,
      );
      if (cmp !== 0) {
        return field.direction === "desc" ? -cmp : cmp;
      }
    }
  }

  const byDate = a.date.localeCompare(b.date);
  if (byDate !== 0) {
    return dateOrder === "desc" ? -byDate : byDate;
  }

  const byActiveTerminalStatus = compareAgendaActiveTerminalStatusBuckets(a, b);
  if (byActiveTerminalStatus !== 0) return byActiveTerminalStatus;

  const byPriority = compareAgendaPriorityValues(a.priority, b.priority, priorityOrder);
  if (byPriority !== 0) return byPriority;

  const byFile = a.filePath.localeCompare(b.filePath);
  if (byFile !== 0) return byFile;

  const byLine = a.lineNumber - b.lineNumber;
  if (byLine !== 0) return byLine;

  const byHeadline = a.headline.localeCompare(b.headline);
  if (byHeadline !== 0) return byHeadline;

  const byTodo = String(a.todo || "").localeCompare(String(b.todo || ""));
  if (byTodo !== 0) return byTodo;

  return a.kind.localeCompare(b.kind);
}

function applyAgendaGroupLimit(
  items: ScheduledItem[],
  groupOrder: AgendaGroupOrder,
  groupLimit: number | null,
  tagOrder: AgendaTagOrder,
): ScheduledItem[] {
  if (!groupLimit || groupLimit < 1) return items;
  if (!groupOrder || groupOrder.length === 0) return items;

  const perDateGroupCounts = new Map<string, number>();
  const kept: ScheduledItem[] = [];

  for (const item of items) {
    const groupKey = agendaGroupKeyForItem(item, groupOrder, tagOrder);
    const dateGroupKey = `${item.date}\u001f${groupKey}`;
    const seen = perDateGroupCounts.get(dateGroupKey) || 0;
    if (seen >= groupLimit) continue;

    perDateGroupCounts.set(dateGroupKey, seen + 1);
    kept.push(item);
  }

  return kept;
}

function applyAgendaDayLimit(items: ScheduledItem[], dayLimit: number | null): ScheduledItem[] {
  if (!dayLimit || dayLimit < 1) return items;

  const perDayCounts = new Map<string, number>();
  const kept: ScheduledItem[] = [];

  for (const item of items) {
    const seen = perDayCounts.get(item.date) || 0;
    if (seen >= dayLimit) continue;

    perDayCounts.set(item.date, seen + 1);
    kept.push(item);
  }

  return kept;
}

function isDefaultRoamLinkifyArchivedPath(filePath: string): boolean {
  return isDefaultArchivePath(filePath);
}

function resolveRoamLinkifyExclude(rootDir: string, rawExclude: string): string {
  const expanded = rawExclude.replace(/^~(?=$|\/|\\)/, os.homedir());
  return path.resolve(path.isAbsolute(expanded) ? expanded : path.join(rootDir, expanded));
}

function isPathWithinOrEqual(child: string, parent: string): boolean {
  const relative = path.relative(parent, child);
  return relative === "" || (!!relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function filterRoamLinkifyFiles(files: string[], rootDir: string, excludes: string[]): string[] {
  const root = path.resolve(rootDir);
  const excludePaths = excludes.map((exclude) => resolveRoamLinkifyExclude(root, exclude));
  return files.filter((file) => {
    const resolved = path.resolve(file);
    if (isDefaultRoamLinkifyArchivedPath(resolved)) return false;
    return !excludePaths.some((excludePath) => isPathWithinOrEqual(resolved, excludePath));
  });
}

function listAgendaFiles(dirPath: string, recursiveScan: boolean, includeArchives = false): string[] {
  const out: string[] = [];
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      if (!recursiveScan) continue;
      if (entry.name.startsWith(".")) continue;
      out.push(...listAgendaFiles(fullPath, recursiveScan, includeArchives));
      continue;
    }

    if (!entry.isFile()) continue;
    if (!isOrgLikeFileName(entry.name, includeArchives)) continue;
    if (!includeArchives && isDefaultArchivePath(fullPath)) continue;
    if (entry.name.startsWith(".#")) continue; // Emacs lockfile
    out.push(fullPath);
  }

  return out;
}


type AiDraftSource = {
  absolutePath: string;
  relativePath: string;
  text: string;
  sha256: string;
  lineCount: number;
};

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringField(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  return typeof value === "string" ? value.trim() : "";
}

function nestedRecord(record: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = record[key];
  return isPlainRecord(value) ? value : {};
}

function stringArrayField(record: Record<string, unknown>, key: string): string[] {
  const value = record[key];
  if (!Array.isArray(value)) return [];
  return value.map((item) => (typeof item === "string" ? item.trim() : "")).filter(Boolean);
}

function slugForOrg2Id(raw: string): string {
  const slug = String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return slug || "ai-draft";
}

function aiDraftRoleForTarget(target: string): "compiled" | "view" | "report" {
  if (target === "compiled") return "compiled";
  if (target === "patch-file") return "report";
  return "view";
}

function resolveWorkspaceRelative(baseDir: string, rawPath: string, label: string): string {
  const value = String(rawPath || "").trim();
  if (!value) throw new Error(`${label} is required`);
  if (path.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value)) {
    throw new Error(`${label} must be a relative path inside the workspace`);
  }
  const segments = value.split(/[\\/]+/);
  if (segments.includes("..")) throw new Error(`${label} must not contain '..' path traversal segments`);
  return path.resolve(baseDir, value);
}


function containsGlob(rawPath: string): boolean {
  return /[*?[{]/.test(rawPath);
}

function globPatternToRegExp(pattern: string): RegExp {
  const normalized = pattern.replace(/\\/g, "/");
  let out = "^";
  for (let i = 0; i < normalized.length; i += 1) {
    const ch = normalized[i] || "";
    const next = normalized[i + 1] || "";
    if (ch === "*" && next === "*") {
      out += ".*";
      i += 1;
    } else if (ch === "*") {
      out += "[^/]*";
    } else if (ch === "?") {
      out += "[^/]";
    } else {
      out += ch.replace(/[\^$+?.()|[\]{}]/g, "\\$&");
    }
  }
  out += "$";
  return new RegExp(out);
}

function walkFiles(root: string): string[] {
  const out: string[] = [];
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop()!;
    if (!fs.existsSync(current)) continue;
    const stat = fs.statSync(current);
    if (stat.isFile()) {
      out.push(current);
    } else if (stat.isDirectory()) {
      for (const entry of fs.readdirSync(current).sort().reverse()) {
        if (entry === ".git" || entry === "node_modules" || entry === "dist") continue;
        stack.push(path.join(current, entry));
      }
    }
  }
  return out;
}

function expandAiSourceFiles(manifestDir: string, sourceFiles: string[]): string[] {
  const expanded: string[] = [];
  for (const file of sourceFiles) {
    if (!containsGlob(file)) {
      expanded.push(file);
      continue;
    }
    const regex = globPatternToRegExp(file.replace(/\\/g, "/"));
    const matches = walkFiles(manifestDir)
      .map((absolutePath) => path.relative(manifestDir, absolutePath).replace(/\\/g, "/"))
      .filter((relativePath) => regex.test(relativePath));
    expanded.push(...matches);
  }
  return Array.from(new Set(expanded)).sort();
}

function readAiDraftSources(manifest: Record<string, unknown>, manifestDir: string): AiDraftSource[] {
  const input = nestedRecord(manifest, "input");
  const sourceFiles = expandAiSourceFiles(manifestDir, stringArrayField(input, "files"));
  if (sourceFiles.length === 0) {
    throw new Error("celorga ai run currently writes draft artifacts from manifest input.files; add at least one matching input file");
  }

  return sourceFiles.map((file) => {
    const absolutePath = resolveWorkspaceRelative(manifestDir, file, "input.files entry");
    const text = fs.readFileSync(absolutePath, "utf8").replace(/\r\n/g, "\n");
    return {
      absolutePath,
      relativePath: file.replace(/\\/g, "/"),
      text,
      sha256: sha256Hex(text),
      lineCount: text.split("\n").length,
    };
  });
}

function stripOrgMarkupForSnippet(raw: string): string {
  return String(raw || "")
    .replace(/^\*+\s+/, "")
    .replace(/^#\+\w+:\s*/i, "")
    .replace(/^:[A-Z0-9_]+:\s*/i, "")
    .replace(/\s+/g, " ")
    .trim();
}

function sourceExcerptBullets(sources: AiDraftSource[], maxPerFile: number): string[] {
  const out: string[] = [];
  for (const source of sources) {
    const lines = source.text.split("\n");
    let emitted = 0;
    for (let i = 0; i < lines.length && emitted < maxPerFile; i += 1) {
      const snippet = stripOrgMarkupForSnippet(lines[i] || "");
      if (!snippet || snippet.length < 8) continue;
      out.push(`- [[file:${source.relativePath}::${i + 1}][${source.relativePath}:${i + 1}]] ${snippet.slice(0, 180)}`);
      emitted += 1;
    }
  }
  return out;
}

const GENERIC_ENTITY_STOP_WORDS = new Set([
  "TODO",
  "DONE",
  "CANCELLED",
  "IN",
  "PROPERTIES",
  "END",
  "TITLE",
  "ID",
  "THE",
  "A",
  "AN",
  "MONDAY",
  "TUESDAY",
  "WEDNESDAY",
  "THURSDAY",
  "FRIDAY",
  "SATURDAY",
  "SUNDAY",
]);

type AiDraftSourceLine = {
  source: AiDraftSource;
  line: number;
  text: string;
  citation: string;
};

type MeetingSummaryJson = {
  summary: string[];
  decisions: Array<{ text: string; citations: string[] }>;
  actionItems: Array<{ text: string; todo: string; citations: string[] }>;
  entities: Array<{ name: string; mentions: number; citations: string[] }>;
  suggestedLinks: Array<{ label: string; reason: string; confidence: string; citations: string[] }>;
  citations: Array<{ file: string; line: number; label: string }>;
};


type AiLinkSuggestionCandidateNode = {
  id: string;
  label: string;
  file: string;
  aliases: string[];
  degree: number;
};

type AiLinkSuggestionSourceRef = {
  file: string;
  line: number;
  endLine?: number;
};

type AiLinkEntitySuggestion = {
  kind: "link" | "entity";
  strategy: "roam-linkify-exact" | "roam-linkify-represented-node" | "entity-extraction";
  label: string;
  candidate?: AiLinkSuggestionCandidateNode;
  file: string;
  line: number;
  lineEnd?: number;
  sourceKind: "line" | "paragraph";
  sourceContext: string;
  confidence: number;
  reason: string;
  evidence: string[];
  sourceRefs: AiLinkSuggestionSourceRef[];
  reviewOnly: true;
};

type AiLinkSuggestionReport = {
  $schema: "org2:ai-link-suggestions:v1";
  action: "ai-suggest-links";
  dir: string;
  recursive: boolean;
  scanned: number;
  targetFileCount: number;
  graph: { nodeCount: number; edgeCount: number; aliasCollisionCount: number };
  adapter: AiAdapterResponse["metadata"];
  applied: false;
  output?: string;
  suggestions: AiLinkEntitySuggestion[];
};

function orgCitationLink(source: AiDraftSource, line: number): string {
  return `[[file:${source.relativePath}::${line}][${source.relativePath}:${line}]]`;
}

function collectAiDraftSourceLines(sources: AiDraftSource[]): AiDraftSourceLine[] {
  const out: AiDraftSourceLine[] = [];
  for (const source of sources) {
    const lines = source.text.split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const raw = lines[index] || "";
      const trimmed = raw.trim();
      if (!trimmed || /^#\+/.test(trimmed) || /^:/.test(trimmed) || /^\*+\s+/.test(trimmed) || /^- \[ \]/.test(trimmed)) continue;
      const text = stripOrgMarkupForSnippet(raw);
      if (!text || text.length < 3) continue;
      if (/^(PROPERTIES|END|Notes|Raw transcript|AI Summary|Summary|TODO items|Review checklist|Job|Sources|Source excerpts)$/i.test(text)) continue;
      out.push({
        source,
        line: index + 1,
        text,
        citation: orgCitationLink(source, index + 1),
      });
    }
  }
  return out;
}

function normalizeMeetingItemText(raw: string): string {
  return String(raw || "")
    .replace(/^[-+*]\s+/, "")
    .replace(/^TODO\s+/i, "")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[.;:]?$/, ".");
}

function firstUniqueMeetingLines(lines: AiDraftSourceLine[], predicate: (line: AiDraftSourceLine) => boolean, limit: number): AiDraftSourceLine[] {
  const seen = new Set<string>();
  const out: AiDraftSourceLine[] = [];
  for (const line of lines) {
    if (!predicate(line)) continue;
    const key = normalizeMeetingItemText(line.text).toLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(line);
    if (out.length >= limit) break;
  }
  return out;
}

function collectMeetingEntities(lines: AiDraftSourceLine[]): Array<{ name: string; mentions: number; citations: string[] }> {
  const entities = new Map<string, { mentions: number; citations: string[] }>();
  const re = /\b[A-Z][A-Za-z0-9]*(?:[\s-]+[A-Z][A-Za-z0-9]*){0,3}\b/g;
  for (const line of lines) {
    let match: RegExpExecArray | null;
    while ((match = re.exec(line.text)) !== null) {
      const entity = String(match[0] || "").trim();
      if (entity.length < 3) continue;
      if (GENERIC_ENTITY_STOP_WORDS.has(entity.toUpperCase())) continue;
      const current = entities.get(entity) || { mentions: 0, citations: [] };
      current.mentions += 1;
      if (!current.citations.includes(line.citation)) current.citations.push(line.citation);
      entities.set(entity, current);
    }
  }

  return Array.from(entities.entries())
    .map(([name, value]) => ({ name, mentions: value.mentions, citations: value.citations.slice(0, 3) }))
    .sort((a, b) => b.mentions - a.mentions || a.name.localeCompare(b.name))
    .slice(0, 25);
}


function clampConfidence(value: number): number {
  return Math.max(0, Math.min(1, Math.round(value * 100) / 100));
}

function sourceLineContext(filePath: string, startLine: number, endLine = startLine): string {
  try {
    const lines = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n").split("\n");
    return lines
      .slice(Math.max(0, startLine - 1), Math.max(startLine, endLine))
      .map((line) => stripOrgMarkupForSnippet(line))
      .filter(Boolean)
      .join(" ")
      .slice(0, 280);
  } catch {
    return "";
  }
}

function aiLinkSuggestionNodeForCandidate(graph: RoamGraphData, candidateRaw: string, labelRaw: string): AiLinkSuggestionCandidateNode | undefined {
  const raw = String(candidateRaw || "").trim();
  const normalizedLabel = normalizeRoamLinkLabel(labelRaw);
  let node = graph.nodes.find((candidate) => candidate.id.toLowerCase() === raw.toLowerCase());
  if (!node) {
    const atIndex = raw.lastIndexOf(" @ ");
    const candidateLabel = atIndex >= 0 ? raw.slice(0, atIndex) : raw;
    const candidateFile = atIndex >= 0 ? path.resolve(raw.slice(atIndex + 3)) : "";
    const normalizedCandidateLabel = normalizeRoamLinkLabel(candidateLabel) || normalizedLabel;
    node = graph.nodes.find((candidate) => {
      const fileMatches = !candidateFile || path.resolve(candidate.file) === candidateFile;
      return fileMatches && candidate.labels.some((alias) => normalizeRoamLinkLabel(alias) === normalizedCandidateLabel);
    });
  }
  if (!node) return undefined;
  return { id: node.id, label: node.label, file: node.file, aliases: node.labels, degree: node.degree };
}

function collectAiEntitySuggestions(targetFiles: string[], labelIndex: Map<string, RoamLinkifyCandidate[]>): AiLinkEntitySuggestion[] {
  const entities = new Map<string, { label: string; mentions: number; refs: AiLinkSuggestionSourceRef[]; contexts: string[] }>();
  const re = /\b[A-Z][A-Za-z0-9]*(?:[\s-]+[A-Z][A-Za-z0-9]*){0,3}\b/g;

  for (const file of targetFiles) {
    let lines: string[];
    try {
      lines = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n");
    } catch {
      continue;
    }

    for (let index = 0; index < lines.length; index += 1) {
      const rawLine = lines[index] || "";
      const trimmed = rawLine.trim();
      if (!trimmed || /^#\+/.test(trimmed) || /^:/.test(trimmed) || /^\*+\s+/.test(trimmed)) continue;
      if (/\[\[|id:[0-9a-f-]{32,}/i.test(rawLine)) continue;

      const context = stripOrgMarkupForSnippet(rawLine);
      if (!context || context.length < 8) continue;
      let match: RegExpExecArray | null;
      while ((match = re.exec(context)) !== null) {
        const label = String(match[0] || "").trim();
        const normalized = normalizeRoamLinkLabel(label);
        if (label.length < 3 || GENERIC_ENTITY_STOP_WORDS.has(label.toUpperCase()) || labelIndex.has(normalized)) continue;
        const current = entities.get(normalized) || { label, mentions: 0, refs: [], contexts: [] };
        current.mentions += 1;
        const ref = { file, line: index + 1 };
        if (!current.refs.some((existing) => existing.file === ref.file && existing.line === ref.line)) current.refs.push(ref);
        if (!current.contexts.includes(context)) current.contexts.push(context);
        entities.set(normalized, current);
      }
    }
  }

  return Array.from(entities.values())
    .sort((a, b) => b.mentions - a.mentions || a.label.localeCompare(b.label))
    .slice(0, 20)
    .map((entity) => {
      const firstRef = entity.refs[0] || { file: "", line: 1 };
      return {
        kind: "entity" as const,
        strategy: "entity-extraction" as const,
        label: entity.label,
        file: firstRef.file,
        line: firstRef.line,
        sourceKind: "line" as const,
        sourceContext: entity.contexts[0] || "",
        confidence: clampConfidence(entity.mentions > 1 ? 0.62 : 0.45),
        reason: `Title-case entity mentioned ${entity.mentions} time${entity.mentions === 1 ? "" : "s"}; review whether it should become a new node or alias.`,
        evidence: entity.contexts.slice(0, 3),
        sourceRefs: entity.refs.slice(0, 3),
        reviewOnly: true as const,
      };
    });
}

async function buildAiLinkSuggestionReport(options: { dir: string; recursive: boolean; targetFiles: string[]; out?: string; includeArchives?: boolean }): Promise<AiLinkSuggestionReport> {
  const explicitTargets = new Set(options.targetFiles.map((file) => path.resolve(file)));
  const allFiles = explicitTargets.size > 0 ? Array.from(explicitTargets) : listOrgLikeFiles(options.dir, options.recursive, options.includeArchives);
  const labelIndex = buildRoamLinkifyIndex(allFiles);
  const graph = buildRoamGraph(allFiles);
  const maintenance = buildRoamGraphMaintenanceReport(allFiles, graph, {
    includeLinkifySuggestions: true,
  });
  const targetFiles = explicitTargets.size > 0 ? allFiles.filter((file) => explicitTargets.has(path.resolve(file))) : allFiles;
  const targetSet = new Set(targetFiles.map((file) => path.resolve(file)));
  const suggestions: AiLinkEntitySuggestion[] = [];

  for (const suggestion of maintenance.linkifySuggestions) {
    if (!targetSet.has(path.resolve(suggestion.file))) continue;
    const candidate = aiLinkSuggestionNodeForCandidate(graph, suggestion.candidate, suggestion.label);
    suggestions.push({
      kind: "link",
      strategy: suggestion.kind === "exact" ? "roam-linkify-exact" : "roam-linkify-represented-node",
      label: suggestion.label,
      candidate,
      file: suggestion.file,
      line: suggestion.line,
      lineEnd: suggestion.lineEnd,
      sourceKind: suggestion.sourceKind || "line",
      sourceContext: suggestion.text || sourceLineContext(suggestion.file, suggestion.line, suggestion.lineEnd || suggestion.line),
      confidence: clampConfidence(typeof suggestion.confidence === "number" ? suggestion.confidence : 0.9),
      reason: suggestion.reason,
      evidence: suggestion.evidence || [],
      sourceRefs: [{ file: suggestion.file, line: suggestion.line, endLine: suggestion.lineEnd }],
      reviewOnly: true,
    });
  }

  suggestions.push(...collectAiEntitySuggestions(targetFiles, labelIndex));
  const ranked = suggestions
    .sort((a, b) => b.confidence - a.confidence || a.file.localeCompare(b.file) || a.line - b.line || a.label.localeCompare(b.label))
    .slice(0, 80);

  const adapter = new MockAiAdapter({
    name: "local-link-suggester",
    model: "deterministic-link-entity-ranker",
    responder: (request) => ({
      schema: "org2:ai-adapter-response:v1",
      text: "Ranked review-only link and entity suggestions from Celorga compiler graph/linkify context.",
      json: { suggestions: ranked, graph: { nodeCount: graph.nodes.length, edgeCount: graph.edges.length } },
      citations: ranked.flatMap((suggestion) => suggestion.sourceRefs.map((source) => ({ source }))),
      metadata: {
        adapterName: "placeholder",
        model: "placeholder",
        provider: "mock",
        invocationId: `mock-link-${sha256Hex(request.context.map((item) => item.text).join("\n")).slice(0, 12)}`,
        completedAt: new Date().toISOString(),
      },
    }),
  });
  const response = await adapter.generate(createAiAdapterRequest({
    jobId: "inline-link-entity-suggestions",
    task: {
      type: "suggest-links",
      template: "link-entity-suggestions@v1",
      instructions: "Rank and explain candidate links/entities using only compiler-provided Celorga graph, aliases, linkify suggestions, and source context.",
    },
    prompt: [
      { role: "system", content: "Use only supplied Celorga compiler context. Return review-only suggestions with citations; never edit canonical notes." },
      { role: "user", content: "Rank likely links and entities with confidence, reason, and source context." },
    ],
    context: [
      {
        id: "graph-state",
        type: "compiled-corpus",
        title: "Celorga roam graph state",
        text: JSON.stringify({ nodes: graph.nodes, edges: graph.edges, aliasCollisions: maintenance.aliasCollisions }, null, 2),
      },
      {
        id: "compiler-candidates",
        type: "query-result",
        title: "Compiler linkify/entity candidates",
        text: JSON.stringify(ranked, null, 2),
        sourceRefs: ranked.flatMap((suggestion) => suggestion.sourceRefs),
      },
    ],
    output: { contentType: "text+json", schemaHint: "org2:ai-link-suggestions:v1" },
    provenance: { requireSourceRefs: true, promptTemplateVersion: "link-entity-suggestions@v1" },
  }));

  return {
    $schema: "org2:ai-link-suggestions:v1",
    action: "ai-suggest-links",
    dir: options.dir,
    recursive: options.recursive,
    scanned: allFiles.length,
    targetFileCount: targetFiles.length,
    graph: {
      nodeCount: graph.nodes.length,
      edgeCount: graph.edges.length,
      aliasCollisionCount: maintenance.aliasCollisions.length,
    },
    adapter: response.metadata,
    applied: false,
    output: options.out,
    suggestions: ranked,
  };
}

function renderAiLinkSuggestionReportText(report: AiLinkSuggestionReport): string {
  const lines: string[] = [];
  lines.push("Celorga AI-assisted link/entity suggestions");
  lines.push("=========================================");
  lines.push("");
  lines.push(`Scanned files: ${report.scanned}`);
  lines.push(`Target files: ${report.targetFileCount}`);
  lines.push(`Graph: ${report.graph.nodeCount} nodes, ${report.graph.edgeCount} edges, ${report.graph.aliasCollisionCount} alias collisions`);
  lines.push(`Adapter: ${report.adapter.adapterName} ${report.adapter.model}${report.adapter.provider ? ` (${report.adapter.provider})` : ""}`);
  lines.push("Mode: review-only; no canonical notes were edited.");
  lines.push("");
  if (report.suggestions.length === 0) {
    lines.push("- No link or entity suggestions found.");
  } else {
    for (const suggestion of report.suggestions) {
      const lineRange = suggestion.lineEnd && suggestion.lineEnd !== suggestion.line ? `${suggestion.line}-${suggestion.lineEnd}` : `${suggestion.line}`;
      const target = suggestion.candidate ? ` -> ${suggestion.candidate.label} (${suggestion.candidate.id})` : "";
      const evidence = suggestion.evidence.length > 0 ? ` Evidence: ${suggestion.evidence.join("; ")}` : "";
      lines.push(`- ${suggestion.kind} ${suggestion.strategy} ${suggestion.file}:${lineRange} ${suggestion.label}${target} confidence=${suggestion.confidence.toFixed(2)}; ${suggestion.reason}${evidence}`);
      if (suggestion.sourceContext) lines.push(`  Context: ${suggestion.sourceContext}`);
    }
  }
  lines.push("");
  return lines.join("\n");
}

function renderEntityExtraction(sources: AiDraftSource[]): string {
  const entities = collectMeetingEntities(collectAiDraftSourceLines(sources));

  if (entities.length === 0) return "- No obvious title-case entities found; review the source excerpts manually.\n";
  return entities.map((entity) => `- ${entity.name} (${entity.mentions})`).join("\n") + "\n";
}

function buildMeetingSummaryJson(sources: AiDraftSource[]): MeetingSummaryJson {
  const lines = collectAiDraftSourceLines(sources);
  const decisionLines = firstUniqueMeetingLines(
    lines,
    (line) => /\b(decided|decision|agreed|approved|resolved|chose|committed|ship(?:ped)?)\b/i.test(line.text),
    8,
  );
  const actionLines = firstUniqueMeetingLines(
    lines,
    (line) => /\b(?:TODO|ACTION|follow[- ]?up|next step|bug|fix(?:ing)? a bug|owner:)\b/i.test(line.text)
      && !/\b(?:Action items \/ TODO suggestions|Transcript-derived action cues|Source citations|Suggested links)\b/i.test(line.text),
    5,
  );
  const substantiveSummaryLine = (line: AiDraftSourceLine) => !/^#+/.test(line.text)
    && !/^:/.test(line.text)
    && !/\b(?:thanks for watching|patio door|sliding glass|bathroom|fence|quote|10 grand)\b/i.test(line.text);
  const relevantSummaryLines = firstUniqueMeetingLines(
    lines,
    (line) => substantiveSummaryLine(line)
      && /\b(?:Scarf|Clickhouse|ClickHouse|unlock|credits?|billing|model|companies|filters?|segments?|downloads?|telemetry|Maven|HubSpot|Slack|webhooks?|exports?|package|registry|customer|contract|premium|runs?)\b/i.test(line.text),
    8,
  );
  const summaryLines = relevantSummaryLines.length > 0
    ? relevantSummaryLines
    : firstUniqueMeetingLines(lines, substantiveSummaryLine, 5);
  const entities = collectMeetingEntities(lines);
  return {
    summary: summaryLines.length > 0
      ? summaryLines.slice(0, 3).map((line) => normalizeMeetingItemText(line.text))
      : ["Review the transcript manually; no substantive meeting discussion was detected."],
    decisions: decisionLines.map((line) => ({ text: normalizeMeetingItemText(line.text), citations: [line.citation] })),
    actionItems: actionLines.map((line) => ({ text: normalizeMeetingItemText(line.text), todo: normalizeMeetingItemText(line.text), citations: [line.citation] })),
    entities,
    suggestedLinks: [],
    citations: [],
  };
}

function createMeetingSummaryAdapterResponse(manifest: Record<string, unknown>, sources: AiDraftSource[]): AiAdapterResponse {
  const adapter = nestedRecord(manifest, "adapter");
  const adapterName = stringField(adapter, "name") || "mock";
  const model = stringField(adapter, "model") || "deterministic-meeting-summary";
  const json = buildMeetingSummaryJson(sources);
  const text = [
    "Meeting summary draft generated from supplied Celorga source context.",
    "Review all sections against the citations before promotion.",
  ].join("\n");

  return {
    schema: "org2:ai-adapter-response:v1",
    text,
    json,
    citations: json.citations.map((citation) => ({ source: { file: citation.file, line: citation.line } })),
    metadata: {
      adapterName,
      model,
      provider: "mock",
      invocationId: `mock-${sha256Hex(sources.map((source) => source.sha256).join(":")).slice(0, 12)}`,
      completedAt: new Date().toISOString(),
    },
  };
}

function buildAiAdapterContextItems(sources: AiDraftSource[]): AiAdapterContextItem[] {
  return sources.map((source, index) => ({
    id: `source-${index + 1}`,
    type: "raw-transcript",
    title: source.relativePath,
    text: source.text,
    sourceRefs: [{ file: source.relativePath, line: 1, endLine: source.lineCount }],
    metadata: { sha256: source.sha256 },
  }));
}

async function generateAiDraftResponse(manifest: Record<string, unknown>, sources: AiDraftSource[]): Promise<AiAdapterResponse | null> {
  const task = nestedRecord(manifest, "task");
  const adapter = nestedRecord(manifest, "adapter");
  const provenance = nestedRecord(manifest, "provenance");
  const taskType = stringField(task, "type") || "summarize";
  if (taskType !== "summarize-meeting") return null;

  const adapterName = stringField(adapter, "name") || "mock";
  const model = stringField(adapter, "model") || "deterministic-meeting-summary";
  const response = createMeetingSummaryAdapterResponse(manifest, sources);
  const mock = new MockAiAdapter({
    name: adapterName,
    model,
    responder: () => response,
  });
  return mock.generate(createAiAdapterRequest({
    jobId: stringField(manifest, "id"),
    task: {
      type: taskType,
      template: stringField(task, "template"),
      instructions: stringField(task, "instructions"),
    },
    prompt: [
      { role: "system", content: "Use only supplied Celorga transcript context. Preserve citations and produce reviewable output." },
      { role: "user", content: stringField(task, "instructions") || `Run ${taskType}.` },
    ],
    context: buildAiAdapterContextItems(sources),
    output: { contentType: "text+json", schemaHint: stringField(task, "template") || taskType },
    provenance: {
      requireSourceRefs: Boolean(provenance.requireSourceRefs),
      promptTemplateVersion: stringField(provenance, "promptTemplateVersion") || stringField(task, "template"),
    },
  }));
}

function bulletOrFallback(items: string[], fallback: string): string {
  return items.length > 0 ? items.map((item) => `- ${item}`).join("\n") + "\n" : `- ${fallback}\n`;
}

function renderTodoItems(items: Array<{ todo: string; citations: string[] }>, fallback: string): string {
  if (items.length === 0) return `${fallback}\n`;
  return items.map((item) => `* TODO ${item.todo}\nSCHEDULED: <${new Date().toISOString().slice(0, 10)}>`).join("\n") + "\n";
}

function renderMeetingSummarySections(response: AiAdapterResponse | null | undefined): string | null {
  if (!response || !response.json || typeof response.json !== "object" || Array.isArray(response.json)) return null;
  const json = response.json as Partial<MeetingSummaryJson>;
  const summary = Array.isArray(json.summary) ? json.summary.map((item) => String(item || "").trim()).filter(Boolean) : [];
  const actionItems = Array.isArray(json.actionItems) ? json.actionItems : [];

  const todoSection = actionItems.length > 0 ? `
** TODO items
${renderTodoItems(actionItems, "")}` : "";

  return `* Generated meeting summary
** Summary
${bulletOrFallback(summary, "Review the transcript manually; no generated summary was returned.")}${todoSection}`;
}

function renderAiGeneratedDraft(manifest: Record<string, unknown>, sources: AiDraftSource[], outputPath: string, adapterResponse?: AiAdapterResponse | null): string {
  const id = stringField(manifest, "id") || "ai-draft";
  const description = stringField(manifest, "description");
  const task = nestedRecord(manifest, "task");
  const adapter = nestedRecord(manifest, "adapter");
  const review = nestedRecord(manifest, "review");
  const output = nestedRecord(manifest, "output");
  const taskType = stringField(task, "type") || "summarize";
  const promptTemplate = stringField(task, "template");
  const instructions = stringField(task, "instructions");
  const adapterName = adapterResponse?.metadata.adapterName || stringField(adapter, "name") || "unspecified";
  const model = adapterResponse?.metadata.model || stringField(adapter, "model") || "unspecified";
  const target = stringField(output, "target") || "views";
  const reviewPolicy = stringField(review, "policy") || "require-approval";
  const reviewStatus = reviewPolicy === "require-approval" ? "review-required" : "generated";
  const generator = `org2 ai run ${id} adapter=${adapterName} model=${model}`;
  const metadata = buildGeneratedArtifactMetadata({
    role: aiDraftRoleForTarget(target),
    generator,
    provenance: sources.map((source) => `file:${source.relativePath}`),
    sourceHashes: sources.map((source) => ({ kind: "file", value: source.relativePath, sha256: source.sha256 })),
    reviewStatus,
    aiJobId: id,
    aiTask: taskType,
    promptTemplate,
    adapter: adapterName,
    model,
  });
  const drawer = formatOrg2ArtifactPropertyDrawer(metadata, slugForOrg2Id(`${id}-${path.basename(outputPath || "draft")}`));
  const title = description || `AI draft: ${id}`;
  const excerpts = sourceExcerptBullets(sources, taskType.includes("meeting") ? 8 : 5);
  const sourceList = sources.map((source) => `- ${source.relativePath} (${source.lineCount} lines, sha256:${source.sha256.slice(0, 12)}…)`).join("\n");
  const summaryBullets = excerpts.length > 0 ? excerpts.slice(0, 10).join("\n") : "- No substantive source lines found.";
  const extraction = taskType === "extract-entities" ? renderEntityExtraction(sources) : "";
  const generatedBody = taskType === "summarize-meeting"
    ? renderMeetingSummarySections(adapterResponse) || `* Generated meeting summary\n** Summary\n${summaryBullets}\n`
    : `* Generated ${taskType === "extract-entities" ? "extraction" : "summary"}\n${taskType === "extract-entities" ? extraction : summaryBullets + "\n"}`;
  const modelRun = adapterResponse?.metadata.invocationId ? `- Adapter invocation: =${adapterResponse.metadata.invocationId}=\n` : "";

  return `#+TITLE: ${title}\n${drawer}\n* Review checklist\n- [ ] Verify every generated claim against the cited source lines.\n- [ ] Edit this draft until it is safe for canonical notes.\n- [ ] Set =ORG2_REVIEW_STATUS= to =reviewed= before running =celorga ai promote=.\n\n* Job\n- Job: =${id}=\n- Task: =${taskType}=\n- Adapter: =${adapterName}=\n- Model: =${model}=\n${modelRun}${promptTemplate ? `- Prompt/template: =${promptTemplate}=\n` : ""}${instructions ? `- Instructions: ${instructions}\n` : ""}\n* Sources\n${sourceList}\n\n${generatedBody}\n* Source excerpts\n${excerpts.length > 0 ? excerpts.join("\n") : "- No source excerpts available."}\n`;
}

function removeTopPropertyDrawer(raw: string): string {
  const lines = raw.replace(/\r\n/g, "\n").split("\n");
  const firstHeading = lines.findIndex((line) => /^\*+\s+/.test(line || ""));
  const scanEnd = firstHeading === -1 ? lines.length : firstHeading;
  const start = lines.findIndex((line, index) => index < scanEnd && (line || "").trim().toUpperCase() === ":PROPERTIES:");
  if (start === -1) return raw.replace(/\r\n/g, "\n").trim() + "\n";
  let end = -1;
  for (let i = start + 1; i < lines.length && i < scanEnd; i += 1) {
    if ((lines[i] || "").trim().toUpperCase() === ":END:") {
      end = i;
      break;
    }
  }
  if (end === -1) return raw.replace(/\r\n/g, "\n").trim() + "\n";
  const kept = [...lines.slice(0, start), ...lines.slice(end + 1)];
  return kept.join("\n").replace(/^\n+/, "").trim() + "\n";
}

type AiReviewQueueItem = {
  file: string;
  title: string;
  status: string;
  jobId: string;
  task: string;
  todos: string[];
  sources: string[];
};

function artifactProperty(raw: string, key: string): string {
  for (const alias of nameAliases(key)) {
    const drawerMatch = raw.match(new RegExp(`^:${alias}:\\s*(.+?)\\s*$`, "im"));
    if (drawerMatch) return String(drawerMatch[1] || "").trim();
  }
  for (const alias of nameAliases(key)) {
    const keywordMatch = raw.match(new RegExp(`^#\\+${alias}:\\s*(.+?)\\s*$`, "im"));
    if (keywordMatch) return String(keywordMatch[1] || "").trim();
  }
  return "";
}
function collectAiReviewQueue(filesToScan: string[]): AiReviewQueueItem[] {
  const items: AiReviewQueueItem[] = [];
  for (const file of filesToScan) {
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) continue;
    const raw = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
    const status = artifactProperty(raw, "ORG2_REVIEW_STATUS");
    if (status !== "review-required" && status !== "deferred") continue;
    const title = (raw.match(/^#\+TITLE:\s*(.+)$/im)?.[1] || path.basename(file)).trim();
    const todos = Array.from(raw.matchAll(/^\*+\s+TODO\s+(.+)$/gm)).map((match) => String(match[1] || "").trim()).filter((todo) => Boolean(todo) && todo.toLowerCase() !== "items");
    const sources = Array.from(raw.matchAll(/(?:file:|\[\[file:)([^\]\s:]+(?:\.org2|\.org)?)/g)).map((match) => String(match[1] || "").trim());
    items.push({
      file,
      title,
      status,
      jobId: artifactProperty(raw, "ORG2_AI_JOB_ID"),
      task: artifactProperty(raw, "ORG2_AI_TASK"),
      todos: Array.from(new Set(todos)),
      sources: Array.from(new Set(sources)),
    });
  }
  return items.sort((a, b) => a.file.localeCompare(b.file));
}

function hasReviewedArtifactStatus(raw: string): boolean {
  return /^:(?:CELORGA|ORG2)_REVIEW_STATUS:\s*(reviewed|promoted)\s*$/im.test(raw);
}

function markArtifactPromoted(raw: string): string {
  if (/^:(?:CELORGA|ORG2)_REVIEW_STATUS:\s*(reviewed|generated|review-required)\s*$/im.test(raw)) {
    return raw.replace(/^:((?:CELORGA|ORG2)_REVIEW_STATUS):\s*(reviewed|generated|review-required)\s*$/im, ":$1: promoted");
  }
  return raw;
}

function formatClockMinutes(minutes: number): string {
  const sign = minutes < 0 ? "-" : "";
  const abs = Math.abs(minutes);
  const hours = Math.floor(abs / 60);
  const mins = abs % 60;
  return `${sign}${hours}:${String(mins).padStart(2, "0")}`;
}

async function runIngestCommand(args: string[]): Promise<void> {
  const take = (flag: string): string => {
    const i = args.indexOf(flag);
    if (i < 0) return "";
    const value = args[i + 1];
    if (!value || value.startsWith("--")) throw new Error(`ingest ${flag} requires a value`);
    args.splice(i, 2);
    return value;
  };
  const has = (flag: string): boolean => {
    const i = args.indexOf(flag);
    if (i < 0) return false;
    args.splice(i, 1);
    return true;
  };

  if (has("--help") || has("-h")) {
    console.log(`celorga ingest

Usage:
  celorga ingest (--file FILE|--stdin|--json FILE) --corpus DIR [--apply]

Options:
  --corpus DIR       Corpus root; writes raw/ingest and views/ingest
  --file FILE        Ingest a local text file
  --stdin            Read local text from stdin
  --json FILE        Read structured JSON capture input
  --source-type T    Override source type (default: file/stdin/json)
  --external-id ID   Stable source id (default: path/stdin/json id)
  --author NAME      Author; repeatable by comma-separating names
  --source-ref REF   Provenance ref (default: file:path, stdin, json:path)
  --occurred-at ISO  Source occurrence timestamp
  --captured-at ISO  Capture timestamp
  --sensitivity S    public|internal|private|restricted (default: private)
  --apply            Write artifacts. Omit for dry-run.
  --format json|text Output format (default: text)

Structured JSON may be either {sourceType, externalId, authors, content, ...}
or {metadata:{...}, content:"..."}. Generated view artifacts are review-required.`);
    return;
  }

  const corpus = take("--corpus") || take("--dir") || ".";
  const file = take("--file");
  const jsonFile = take("--json");
  const readStdin = has("--stdin");
  const apply = has("--apply");
  const formatRaw = take("--format") || "text";
  const sourceTypeOverride = take("--source-type");
  const externalIdOverride = take("--external-id");
  const authorRaw = take("--author");
  const sourceRefOverride = take("--source-ref");
  const occurredAt = take("--occurred-at");
  const capturedAt = take("--captured-at");
  const sensitivityRaw = take("--sensitivity");
  if (args.length) throw new Error(`unknown ingest arguments: ${args.join(" ")}`);
  const inputs = [file ? "file" : "", jsonFile ? "json" : "", readStdin ? "stdin" : ""].filter(Boolean);
  if (inputs.length !== 1) throw new Error("ingest requires exactly one of --file, --stdin, or --json");
  if (formatRaw !== "text" && formatRaw !== "json") throw new Error("ingest --format must be text or json");

  let input: Org2RawCaptureInput;
  if (jsonFile) {
    let raw: Record<string, unknown>;
    try {
      raw = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      throw new Error(`ingest --json could not read structured capture input at ${jsonFile}: ${detail}`);
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error(`ingest --json requires a JSON object at ${jsonFile}`);
    }
    const metadata = raw.metadata && typeof raw.metadata === "object" && !Array.isArray(raw.metadata) ? raw.metadata as Record<string, unknown> : raw;
    const metadataString = (key: string): string | undefined => typeof metadata[key] === "string" ? metadata[key] : undefined;
    const rawContent = typeof raw.content === "string" ? raw.content : undefined;
    input = {
      sourceType: sourceTypeOverride || metadataString("sourceType") || "json",
      externalId: externalIdOverride || metadataString("externalId") || path.basename(jsonFile),
      authors: authorRaw ? authorRaw.split(",").map((s) => s.trim()).filter(Boolean) : (Array.isArray(metadata.authors) ? metadata.authors.map(String) : metadataString("author") ? [metadataString("author") as string] : []),
      capturedAt: capturedAt || metadataString("capturedAt"),
      occurredAt: occurredAt || metadataString("occurredAt") || metadataString("timestamp"),
      visibility: metadataString("visibility") || "unspecified",
      sensitivity: (sensitivityRaw || metadataString("sensitivity") || "private") as Org2RawCaptureInput["sensitivity"],
      sourceRef: sourceRefOverride || metadataString("sourceRef") || `json:${path.resolve(jsonFile)}`,
      content: rawContent || metadataString("content") || "",
    };
  } else {
    const content = readStdin ? await readStdinText() : fs.readFileSync(file, "utf8");
    const sourceKind = readStdin ? "stdin" : "file";
    input = {
      sourceType: sourceTypeOverride || sourceKind,
      externalId: externalIdOverride || (readStdin ? `stdin-${sha256Hex(content).slice(0, 12)}` : path.basename(file)),
      authors: authorRaw ? authorRaw.split(",").map((s) => s.trim()).filter(Boolean) : [],
      capturedAt: capturedAt || undefined,
      occurredAt: occurredAt || undefined,
      visibility: "unspecified",
      sensitivity: (sensitivityRaw || "private") as Org2RawCaptureInput["sensitivity"],
      sourceRef: sourceRefOverride || (readStdin ? "stdin" : `file:${path.resolve(file)}`),
      content,
    };
  }

  const result = ingestDemoSource({
    input,
    rawDir: path.join(corpus, "raw", "ingest"),
    reviewDir: path.join(corpus, "views", "ingest"),
    now: capturedAt || undefined,
    dryRun: !apply,
  });

  if (formatRaw === "json") {
    console.log(JSON.stringify({ kind: "ingest", apply, rawPath: result.rawPath, reviewPath: result.reviewPath, rawRef: result.rawCapture.rawRef, contentHash: result.rawCapture.contentHash, reviewStatus: result.reviewArtifact.reviewStatus }, null, 2));
  } else {
    console.log(`${apply ? "ingested" : "dry-run"}: ${result.rawCapture.rawRef}`);
    console.log(`raw: ${result.rawPath}`);
    console.log(`view: ${result.reviewPath}`);
    console.log(`review: ${result.reviewArtifact.reviewStatus} (generated artifact remains review-required before promotion to notes/)`);
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args[0] === "ingest") {
    await runIngestCommand(args.slice(1));
    return;
  }

  let command = "";
  let dir = "";
  let files: string[] = [];
  let days = 7;
  let today = getTodayString();
  let format: "text" | "json" = "text";
  let agendaTui = false;
  let agendaWorkload = false;
  let agendaTuiRefreshSeconds = 30;
  let recursive = false;
  let includeArchives = false;
  let includeOverdue = true;
  let agendaStatusFiltersRaw: string[] = [];
  let agendaExcludeStatusFiltersRaw: string[] = [];
  let agendaKindFiltersRaw: string[] = [];
  let agendaExcludeKindFiltersRaw: string[] = [];
  let agendaWhenFiltersRaw: string[] = [];
  let agendaExcludeWhenFiltersRaw: string[] = [];
  let agendaWeekdayFiltersRaw: string[] = [];
  let agendaExcludeWeekdayFiltersRaw: string[] = [];
  let agendaWeekFiltersRaw: string[] = [];
  let agendaExcludeWeekFiltersRaw: string[] = [];
  let agendaDayOfMonthFiltersRaw: string[] = [];
  let agendaExcludeDayOfMonthFiltersRaw: string[] = [];
  let agendaMonthFiltersRaw: string[] = [];
  let agendaExcludeMonthFiltersRaw: string[] = [];
  let agendaQuarterFiltersRaw: string[] = [];
  let agendaExcludeQuarterFiltersRaw: string[] = [];
  let agendaYearFiltersRaw: string[] = [];
  let agendaExcludeYearFiltersRaw: string[] = [];
  let agendaDateFiltersRaw: string[] = [];
  let agendaExcludeDateFiltersRaw: string[] = [];
  let agendaLevelFiltersRaw: string[] = [];
  let agendaExcludeLevelFiltersRaw: string[] = [];
  let agendaMatchFiltersRaw: string[] = [];
  let agendaExcludeMatchFiltersRaw: string[] = [];
  let agendaTagFiltersRaw: string[] = [];
  let agendaIdFiltersRaw: string[] = [];
  let agendaTodoFiltersRaw: string[] = [];
  let agendaTodoOrderRaw: string[] = [];
  let agendaStatusOrderRaw: string[] = [];
  let agendaKindOrderRaw: string[] = [];
  let agendaPriorityOrderRaw: string[] = [];
  let agendaTagOrderRaw: string[] = [];
  let agendaEffortOrderRaw: string[] = [];
  let agendaPriorityFiltersRaw: string[] = [];
  let agendaTimeFiltersRaw: string[] = [];
  let agendaEffortFiltersRaw: string[] = [];
  let agendaPropertyFiltersRaw: string[] = [];
  let agendaExcludeTagFiltersRaw: string[] = [];
  let agendaExcludeIdFiltersRaw: string[] = [];
  let agendaExcludeTodoFiltersRaw: string[] = [];
  let agendaExcludePriorityFiltersRaw: string[] = [];
  let agendaExcludeTimeFiltersRaw: string[] = [];
  let agendaExcludeEffortFiltersRaw: string[] = [];
  let agendaExcludePropertyFiltersRaw: string[] = [];
  let agendaFileFiltersRaw: string[] = [];
  let agendaExcludeFileFiltersRaw: string[] = [];
  let agendaSortRaw: string[] = [];
  let agendaGroupRaw: string[] = [];
  let agendaDateOrderRaw: string[] = [];
  let agendaLimitRaw = "";
  let agendaDayLimitRaw = "";
  let agendaGroupLimitRaw = "";
  let agendaDeadlineWarningDaysRaw = "";
  let agendaFromRaw = "";
  let agendaToRaw = "";
  let verboseErrors = false;
  let help = false;

  let archiveFile = "";
  let archivePos = "";
  let archiveApply = false;
  let archiveFormat: "text" | "diff" | "json" = "text";

  // Refile workflow
  let refileFile = "";
  let refilePos = "";
  let refileToFile = "";
  let refileToPos = "";
  let refileApply = false;
  let refileFormat: "text" | "diff" | "json" = "text";

  // Document export/publishing
  let exportAction: "html" | "beamer" = "html";
  let exportFile = "";
  let publishProject = "";
  let publishConfigPath = "";
  let publishPreview = false;
  let publishFormat: "text" | "json" = "text";
  let exportOut = "";
  let exportOutDir = "";
  let exportIndex = "";
  let exportIndexTitle = "";
  let exportStylesheets: string[] = [];
  let exportIncludeDefaultStyle = true;
  let exportIncludeToc: boolean | undefined = undefined;
  let exportTocDepthRaw = "";
  let exportIncludeHeadlineNumbers: boolean | undefined = undefined;
  let exportHeadlineNumberDepthRaw = "";
  let exportRewriteFileLinks = false;
  let exportApply = false;
  let exportFormat: "text" | "json" = "text";
  let exportTitle = "";
  let exportPdf = false;
  let exportLatexEngine = "pdflatex";

  // Todo status editing
  let todoAction: "set" | "toggle" | "assign" | "approve" = "toggle";
  let todoFile = "";
  let todoLine = 0;
  let todoStatus: TodoStatus | "" = "";
  let todoKeyword = "";
  let todoAssignee = "";
  let todoAgentRef = "";
  let todoGoalRef = "";
  let todoApply = false;
  let todoFormat: "text" | "json" | "diff" = "json";
  let todoNow = ""; // ISO string
  let todoLogbook = false;
  let todoLogbookFlagSet = false;

  // Quick capture
  let captureFile = "";
  let captureTargetFile = "";
  let captureSourceFile = "";
  let captureTextRaw = "";
  let captureUrl = "";
  let captureReadStdin = false;
  let captureSourceTypeRaw = "";
  let captureOrigin = "";
  let captureAuthor = "";
  let captureTitle = "";
  let captureTemplateRaw = "note";
  let captureTodoKeywordRaw = "TODO";
  let captureTodoKeywordFlagSet = false;
  let captureBodyRaw = "";
  let captureNow = ""; // ISO string
  let captureApply = false;
  let captureFormat: "text" | "json" | "diff" = "text";

  // Planning editing
  let planAction: "set" | "today" = "set";
  let planFile = "";
  let planLine = 0;
  let planKind: PlanningKindArg | "" = "";
  let planDate = ""; // YYYY-MM-DD
  let planApply = false;
  let planFormat: "text" | "json" | "diff" = "json";

  // Org-crypt (basic)
  let cryptAction: "encrypt" | "decrypt" | "reencrypt" = "decrypt";
  let cryptFile = "";
  let cryptLine = 0;
  let cryptPassphrase = "";
  let cryptRecipients: string[] = [];
  let cryptRecipientFiles: string[] = [];
  let cryptUseDefaultRecipientSelf = false;
  let cryptApply = false;
  let cryptFormat: "text" | "json" | "diff" = "json";
  let cryptGpgProgram = "gpg";
  let cryptGpgTimeoutMs = 30_000;

  // Formatter
  let fmtStdin = false;
  let fmtApply = false;
  let fmtCheck = false;
  let fmtCanonicalOrg = false;
  let fmtFormat: "text" | "json" = "text";
  let fmtConfigPath = "";
  let fmtFileFiltersRaw: string[] = [];
  let fmtExcludeFileFiltersRaw: string[] = [];

  // IDs (Roam)
  let idAction: "get" | "ensure" = "get";
  let idFile = "";
  let idLine = 0;
  let idApply = false;
  let idFormat: "text" | "json" | "diff" = "text";
  let idForced = "";

  // Backlinks (Roam)
  let backlinksId = "";
  let backlinksFormat: "text" | "json" = "text";

  // Query (Roam)
  let queryId = "";
  let queryTerm = "";
  let queryText = "";
  let queryFormat: "text" | "json" = "text";
  let queryRelations = false;
  let queryActions = false;
  let queryClocks = false;
  let queryRelationObject = "";
  let queryRelationPredicate = "";
  let queryRecentDaysRaw = "30";
  let queryOpenLimitRaw = "8";
  let queryCompletedLimitRaw = "4";

  // Cited search
  let searchTerm = "";
  let searchFormat: "text" | "json" = "text";
  let searchContextRaw = "1";
  let searchLimitRaw = "50";
  let searchTodoFiltersRaw: string[] = [];
  let searchTagFiltersRaw: string[] = [];
  let searchFileZoneFiltersRaw: string[] = [];
  let searchHeadingFilter = "";
  let searchSort = "scan";
  let searchDateFrom = "";
  let searchDateTo = "";
  let searchIndexMode: "auto" | "current" | "never" | "rebuild" = "auto";
  let querySubtree = false;
  let queryAnswerContext = false;

  // Approval queue
  let approvalsFormat: "text" | "json" = "text";
  let approvalRunDetailIDs: string[] = [];

  // Rebuildable local indexes
  let indexFormat: "text" | "json" = "text";
  let indexIncremental = false;

  // Lint / corpus health
  let lintFormat: "text" | "json" = "text";
  let graphAction: "audit" | "repair-candidates" = "audit";
  let graphFormat: "report" | "json" = "report";

  // Compile / machine-readable corpus artifacts
  let compileAction: "corpus" = "corpus";
  let compileFormat: "json" | "jsonl" = "json";
  let compileOut = "";
  let compileIncremental = false;
  let compileCache = "";

  // Chart rendering for editor/client integrations
  let renderChartFile = "";
  let renderChartLine = 0;
  let renderChartBlockId = "";
  let renderChartOut = "";
  let renderChartStdin = false;
  let renderChartFormat: "svg" | "json" = "svg";

  // DuckDB-backed local/ad hoc data queries
  let dataQueryFile = "";
  let dataQueryResultId = "";
  let dataQueryLine = 0;
  let dataQueryOut = "";
  let dataQueryDuckdb: string | undefined;
  let dataQueryFormat: "org" | "json" = "org";
  let dataQueryIncludeScript = false;
  let dataQueryInspect = false;
  let dataQueryStdin = false;
  let dataQueryApply = false;
  let dataQueryAllResults = false;

  // Clock reports
  let clockFormat: "text" | "json" = "text";

  // Agent-ready retrieval/context API
  let agentAction: "capabilities" | "context" | "search" | "fetch" | "bundle" | "" = "";
  let agentQuery = "";
  let agentId = "";
  let agentLimitRaw = "10";
  let agentMaxCharsRaw = "12000";
  let agentIncludeRaw = "sources";
  let agentScope = "";
  let agentSince = "";
  let agentSourceType = "";
  let agentReviewStatus = "";
  let agentRecencyWeightRaw = "1";
  let agentSalienceWeightRaw = "1";
  let contextFormat: "markdown" | "org" | "json" = "markdown";
  let briefAction: "today" | "project" | "node" | "" = "";
  let briefName = "";
  let briefOut = "";

  // Entity profiles
  let entityAction: "show" = "show";
  let entityName = "";
  let entityFormat: "text" | "json" = "text";

  // AI job manifests and provider-free draft artifact workflows
  let aiAction: "validate-job" | "run" | "promote" | "suggest-links" | "review" | "" = "";
  let aiJobFile = "";
  let aiFormat: "text" | "json" = "text";
  let aiOut = "";
  let aiTask = "";
  let aiPromoteFile = "";
  let aiPromoteToFile = "";
  let aiApply = false;
  let aiReviewStatus: "reviewed" | "rejected" | "deferred" | "" = "";

  // Roam meta
  let roamAction: "db-sync" | "backlinks" | "node" | "link" | "linkify" | "graph" = "db-sync";
  let roamNodeAction: "new" = "new";
  let roamLinkAction: "insert-backlink" = "insert-backlink";
  let roamFormat: "text" | "json" | "report" = "text";
  let roamApply = false;
  let roamTitle = "";
  let roamIdForced = "";
  let roamLinkFile = "";
  let roamLinkifyFile = "";
  let roamLinkifyExcludes: string[] = [];
  let roamGraphOut = "";
  let roamLinkPos = "";
  let roamLinkId = "";
  let roamLinkTitle = "";
  let roamLinkStyle: "wiki" | "id" = "wiki";

  // Parse arguments
  let i = 0;
  while (i < args.length) {
    const arg = args[i];

    if (arg === "--help" || arg === "-h") {
      help = true;
      i++;
      continue;
    }

    if (arg === "agenda") {
      command = "agenda";
      i++;
    } else if (arg === "archive") {
      command = "archive";
      i++;
    } else if (arg === "refile") {
      command = "refile";
      i++;
    } else if (arg === "export") {
      command = "export";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "html" || sub === "beamer") {
          exportAction = sub;
          i++;
        }
      }
    } else if (arg === "publish") {
      command = "publish";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        publishProject = args[i]!;
        i++;
      }
    } else if (arg === "lsp") {
      command = "lsp";
      i++;
    } else if (arg === "fmt" || arg === "format") {
      command = "fmt";
      i++;
    } else if (arg === "todo") {
      command = "todo";
      i++;
      // Optional subcommand: set|toggle|assign|approve (default toggle)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!
        if (sub === "set" || sub === "toggle" || sub === "assign" || sub === "approve") {
          todoAction = sub;
          i++;
        }
      }
    } else if (arg === "capture") {
      command = "capture";
      i++;
    } else if (arg === "plan" || arg === "planning") {
      command = "plan";
      i++;
      // Optional subcommand: set|today (default set)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "set" || sub === "today") {
          planAction = sub;
          i++;
        }
      }
    } else if (arg === "crypt") {
      command = "crypt";
      i++;
      // Optional subcommand: encrypt|decrypt (default decrypt)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = String(args[i] || "").trim().toLowerCase();
        if (sub === "encrypt" || sub === "decrypt" || sub === "reencrypt") {
          cryptAction = sub as "encrypt" | "decrypt" | "reencrypt";
          i++;
        }
      }
    } else if (arg === "id") {
      command = "id";
      i++;
      // Optional subcommand: get|ensure (default get)
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "get" || sub === "ensure") {
          idAction = sub;
          i++;
        }
      }
    } else if (arg === "backlinks") {
      command = "backlinks";
      i++;
    } else if (arg === "approvals") {
      command = "approvals";
      i++;
    } else if (arg === "index") {
      command = "index";
      i++;
    } else if (arg === "search") {
      command = "search";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        searchTerm = args[i]!;
        i++;
      }
    } else if (arg === "query") {
      command = "query";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        if (args[i] === "relations") {
          queryRelations = true;
        } else if (args[i] === "actions") {
          queryActions = true;
        } else if (args[i] === "clocks" || args[i] === "clock") {
          queryClocks = true;
        } else {
          queryTerm = args[i]!;
          searchTerm = queryTerm;
        }
        i++;
      }
    } else if (arg === "lint") {
      command = "lint";
      i++;
    } else if (arg === "graph") {
      command = "graph";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "audit" || sub === "repair-candidates") {
          graphAction = sub;
          i++;
        }
      }
    } else if (arg === "clock" || arg === "clocks") {
      command = "clock";
      i++;
    } else if (arg === "compile") {
      command = "compile";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "corpus") {
          compileAction = "corpus";
          i++;
        }
      }
    } else if (arg === "render-chart") {
      command = "render-chart";
      i++;
    } else if (arg === "query-data" || arg === "data-query") {
      command = "query-data";
      i++;
    } else if (arg === "context") {
      command = "context";
      agentAction = "bundle";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        agentQuery = args[i]!;
        i++;
      }
    } else if (arg === "brief") {
      command = "brief";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "today" || sub === "project" || sub === "node") { briefAction = sub; i++; }
      }
      if (i < args.length && !args[i]!.startsWith("--")) { briefName = args[i]!; i++; }
    } else if (arg === "entity") {
      command = "entity";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "show") { entityAction = "show"; i++; }
      }
      if (i < args.length && !args[i]!.startsWith("--")) { entityName = args[i]!; i++; }
    } else if (arg === "agent") {
      command = "agent";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "capabilities" || sub === "context" || sub === "search" || sub === "fetch" || sub === "bundle") {
          agentAction = sub;
          i++;
        }
      }
      if (i < args.length && !args[i]!.startsWith("--")) {
        agentQuery = args[i]!;
        i++;
      }
    } else if (arg === "ai") {
      command = "ai";
      i++;
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "validate-job" || sub === "validate") {
          aiAction = "validate-job";
        } else if (sub === "run") {
          aiAction = "run";
        } else if (sub === "promote") {
          aiAction = "promote";
        } else if (sub === "review" || sub === "queue") {
          aiAction = "review";
        } else if (sub === "suggest-links" || sub === "suggest" || sub === "links") {
          aiAction = "suggest-links";
        }
        i++;
      }
    } else if (arg === "roam") {
      command = "roam";
      i++;
      // Optional subcommands:
      // - db-sync (default)
      // - node new
      // - link insert-backlink
      if (i < args.length && !args[i]!.startsWith("--")) {
        const sub = args[i]!;
        if (sub === "db-sync") {
          roamAction = "db-sync";
          i++;
        } else if (sub === "backlinks") {
          roamAction = "backlinks";
          i++;
        } else if (sub === "linkify") {
          roamAction = "linkify";
          i++;
        } else if (sub === "graph") {
          roamAction = "graph";
          i++;
        } else if (sub === "node") {
          roamAction = "node";
          i++;
          if (i < args.length && !args[i]!.startsWith("--")) {
            const sub2 = args[i]!;
            if (sub2 === "new") {
              roamNodeAction = "new";
              i++;
            }
          }
        } else if (sub === "link") {
          roamAction = "link";
          i++;
          if (i < args.length && !args[i]!.startsWith("--")) {
            const sub2 = args[i]!;
            if (sub2 === "insert-backlink") {
              roamLinkAction = "insert-backlink";
              i++;
            }
          }
        }
      }
    } else if (arg === "--dir") {
      i++;
      if (i < args.length) {
        dir = args[i];
        i++;
      }
    } else if (arg === "--files") {
      i++;
      // Collect all following non-flag arguments as files
      while (i < args.length && !args[i].startsWith("--")) {
        files.push(args[i]);
        i++;
      }
    } else if (arg === "--job") {
      i++;
      if (i < args.length) {
        if (command === "ai") {
          aiJobFile = args[i]!;
        }
        i++;
      }
    } else if (arg === "--file") {
      i++;
      if (i < args.length) {
        if (command === "todo") {
          todoFile = args[i]!;
        } else if (command === "capture") {
          if (captureTargetFile) {
            captureSourceFile = args[i]!;
          } else {
            captureFile = args[i]!;
          }
        } else if (command === "plan") {
          planFile = args[i]!;
        } else if (command === "crypt") {
          cryptFile = args[i]!;
        } else if (command === "id") {
          idFile = args[i]!;
        } else if (command === "refile") {
          refileFile = args[i]!;
        } else if (command === "export") {
          exportFile = args[i]!;
        } else if (command === "render-chart") {
          renderChartFile = args[i]!;
        } else if (command === "query-data") {
          dataQueryFile = args[i]!;
        } else if (command === "roam" && roamAction === "link") {
          roamLinkFile = args[i]!;
        } else if (command === "ai" && (aiAction === "promote" || aiAction === "review")) {
          aiPromoteFile = args[i]!;
        } else if (command === "roam" && roamAction === "linkify") {
          roamLinkifyFile = args[i]!;
        } else {
          files.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--line") {
      i++;
      if (i < args.length) {
        const n = parseInt(args[i]!, 10);
        if (command === "todo") {
          todoLine = n;
        } else if (command === "plan") {
          planLine = n;
        } else if (command === "crypt") {
          cryptLine = n;
        } else if (command === "id") {
          idLine = n;
        } else if (command === "render-chart") {
          renderChartLine = n;
        } else if (command === "query-data") {
          dataQueryLine = n;
        }
        i++;
      }
    } else if (arg === "--keyword" && command === "todo") {
      todoKeyword = args[++i] ?? "";
      i++;
    } else if (arg === "--status") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaStatusFiltersRaw.push(args[i]!);
        } else if (command === "ai" && aiAction === "review") {
          const raw = String(args[i] || "").trim().toLowerCase();
          if (raw === "reviewed" || raw === "rejected" || raw === "deferred") aiReviewStatus = raw;
        } else {
          todoStatus = parseTodoStatusArg(args[i] ?? "");
          if (!todoStatus) todoKeyword = args[i] ?? "";
        }
        i++;
      }
    } else if (arg === "--assignee") {
      i++;
      if (i < args.length) {
        if (command === "todo") {
          todoAssignee = args[i]!;
        }
        i++;
      }
    } else if (arg === "--agent-ref") {
      i++;
      if (i < args.length) {
        if (command === "todo") todoAgentRef = args[i]!;
        i++;
      }
    } else if (arg === "--goal-ref") {
      i++;
      if (i < args.length) {
        if (command === "todo") todoGoalRef = args[i]!;
        i++;
      }
    } else if (arg === "--exclude-status") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeStatusFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--now") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureNow = args[i]!;
        } else {
          todoNow = args[i]!;
        }
        i++;
      }
    } else if (arg === "--logbook") {
      if (command === "todo") {
        todoLogbook = true;
        todoLogbookFlagSet = true;
      }
      i++;
    } else if (arg === "--days") {
      i++;
      if (i < args.length) {
        days = parseInt(args[i], 10);
        if (isNaN(days) || days < 1) {
          days = 1;
        }
        i++;
      }
    } else if (arg === "--today") {
      i++;
      if (i < args.length) {
        today = args[i];
        i++;
      }
    } else if (arg === "--tui") {
      if (command === "agenda") {
        agendaTui = true;
      }
      i++;
    } else if (arg === "--workload") {
      if (command === "agenda") {
        agendaWorkload = true;
      }
      i++;
    } else if (arg === "--refresh-seconds") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          const parsed = parseInt(args[i]!, 10);
          if (!isNaN(parsed) && parsed >= 1) agendaTuiRefreshSeconds = parsed;
        }
        i++;
      }
    } else if (arg === "--from" || arg === "--date-from") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaFromRaw = args[i]!;
        } else if (command === "search" || command === "query") {
          searchDateFrom = args[i]!;
        }
        i++;
      }
    } else if ((arg === "--to" && command !== "capture") || arg === "--date-to") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaToRaw = args[i]!;
        } else if (command === "search" || command === "query") {
          searchDateTo = args[i]!;
        }
        i++;
      }
    } else if (arg === "--kind") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaKindFiltersRaw.push(args[i]!);
        } else {
          planKind = args[i] as PlanningKindArg;
        }
        i++;
      }
    } else if (arg === "--exclude-kind") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeKindFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--when") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWhenFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-when") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeWhenFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--weekday") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWeekdayFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-weekday") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeWeekdayFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--week") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaWeekFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-week") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeWeekFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--day-of-month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDayOfMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-day-of-month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeDayOfMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-month") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeMonthFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--quarter") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaQuarterFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-quarter") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeQuarterFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--year") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaYearFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-year") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeYearFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--level") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaLevelFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-level") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeLevelFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--match") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaMatchFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-match") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeMatchFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--tag") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTagFiltersRaw.push(args[i]!);
        } else if (command === "search" || command === "query") {
          searchTagFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--todo") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTodoFiltersRaw.push(args[i]!);
        } else if (command === "search" || command === "query") {
          searchTodoFiltersRaw.push(args[i]!);
        } else if (command === "capture") {
          captureTodoKeywordRaw = args[i]!;
          captureTodoKeywordFlagSet = true;
        }
        i++;
      }
    } else if (arg === "--todo-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTodoOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--status-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaStatusOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--kind-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaKindOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--priority-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaPriorityOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--tag-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTagOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--effort-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaEffortOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--priority") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaPriorityFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--time") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaTimeFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--effort") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaEffortFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--property") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaPropertyFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-tag") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTagFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-id") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeIdFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-todo") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTodoFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-priority") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludePriorityFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-time") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeTimeFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-effort") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeEffortFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-property") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludePropertyFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--file-match" || arg === "--file-zone") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaFileFiltersRaw.push(args[i]!);
        } else if (command === "fmt") {
          fmtFileFiltersRaw.push(args[i]!);
        } else if (command === "search" || command === "query") {
          searchFileZoneFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--exclude-file") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeFileFiltersRaw.push(args[i]!);
        } else if (command === "fmt") {
          fmtExcludeFileFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--config") {
      i++;
      if (i < args.length) {
        if (command === "fmt") {
          fmtConfigPath = args[i]!;
        } else if (command === "publish") {
          publishConfigPath = args[i]!;
        }
        i++;
      }
    } else if (arg === "--sort") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaSortRaw.push(args[i]!);
        } else if (command === "search" || command === "query") {
          searchSort = args[i]!;
        }
        i++;
      }
    } else if (arg === "--group") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaGroupRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--date-order") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDateOrderRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaLimitRaw = args[i]!;
        } else if (command === "search" || command === "query") {
          searchLimitRaw = args[i]!;
        } else if (command === "agent" || command === "context" || command === "brief") {
          agentLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--day-limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDayLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--group-limit") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaGroupLimitRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--date") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaDateFiltersRaw.push(args[i]!);
        } else {
          planDate = args[i]!;
        }
        i++;
      }
    } else if (arg === "--exclude-date") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaExcludeDateFiltersRaw.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--template") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureTemplateRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--task") {
      i++;
      if (i < args.length) {
        if (command === "ai") {
          aiTask = args[i]!;
        }
        i++;
      }
    } else if (arg === "--to") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureTargetFile = args[i]!;
          if (captureFile && !captureSourceFile) {
            captureSourceFile = captureFile;
            captureFile = "";
          }
        } else if (command === "ai" && aiAction === "promote") {
          aiPromoteToFile = args[i]!;
        }
        i++;
      }
    } else if (arg === "--text") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureTextRaw = args[i]!;
        } else if (command === "query") {
          queryText = args[i]!;
        }
        i++;
      }
    } else if (arg === "--url") {
      i++;
      if (i < args.length) {
        if (command === "capture") captureUrl = args[i]!;
        i++;
      }
    } else if (arg === "--source-type" && command === "capture") {
      i++;
      if (i < args.length) {
        captureSourceTypeRaw = args[i]!;
        i++;
      }
    } else if (arg === "--origin") {
      i++;
      if (i < args.length) {
        if (command === "capture") captureOrigin = args[i]!;
        i++;
      }
    } else if (arg === "--author") {
      i++;
      if (i < args.length) {
        if (command === "capture") captureAuthor = args[i]!;
        i++;
      }
    } else if (arg === "--title") {
      i++;
      if (i < args.length) {
        if (command === "roam") {
          if (roamAction === "link") {
            roamLinkTitle = args[i]!;
          } else {
            roamTitle = args[i]!;
          }
        } else if (command === "capture") {
          captureTitle = args[i]!;
        } else if (command === "export") {
          exportTitle = args[i]!;
        }
        i++;
      }
    } else if (arg === "--body") {
      i++;
      if (i < args.length) {
        if (command === "capture") {
          captureBodyRaw = args[i]!;
        }
        i++;
      }
    } else if (arg === "--passphrase") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          cryptPassphrase = args[i]!;
        }
        i++;
      }
    } else if (arg === "--recipient" || arg === "-r") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          cryptRecipients.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--recipient-file") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          cryptRecipientFiles.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--default-recipient-self") {
      if (command === "crypt") {
        cryptUseDefaultRecipientSelf = true;
      }
      i++;
    } else if (arg === "--gpg-program") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          cryptGpgProgram = args[i]!;
        }
        i++;
      }
    } else if (arg === "--gpg-timeout") {
      i++;
      if (i < args.length) {
        if (command === "crypt") {
          const seconds = Number.parseFloat(args[i] ?? "");
          if (!Number.isFinite(seconds) || seconds <= 0) {
            console.error("Error: --gpg-timeout requires a positive number of seconds");
            process.exit(1);
          }
          cryptGpgTimeoutMs = Math.max(100, Math.round(seconds * 1000));
        }
        i++;
      }
    } else if (arg === "--query" && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) {
        agentQuery = args[i]!;
        i++;
      }
    } else if (arg === "--include" && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) {
        agentIncludeRaw = args[i]!;
        i++;
      }
    } else if (arg === "--scope" && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) { agentScope = args[i]!; i++; }
    } else if (arg === "--since" && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) { agentSince = args[i]!; i++; }
    } else if ((arg === "--source-type" || arg === "--type") && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) { agentSourceType = args[i]!; i++; }
    } else if ((arg === "--review-status" || arg === "--review") && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) { agentReviewStatus = args[i]!; i++; }
    } else if (arg === "--recency-weight" && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) { agentRecencyWeightRaw = args[i]!; i++; }
    } else if (arg === "--salience-weight" && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) { agentSalienceWeightRaw = args[i]!; i++; }
    } else if ((arg === "--budget" || arg === "--max-tokens" || arg === "--max-chars" || arg === "--max-bytes") && (command === "agent" || command === "context" || command === "brief")) {
      i++;
      if (i < args.length) {
        agentMaxCharsRaw = args[i]!;
        i++;
      }
    } else if (arg === "--object" && command === "query") {
      i++;
      if (i < args.length) {
        queryRelationObject = args[i]!;
        i++;
      }
    } else if (arg === "--predicate" && command === "query") {
      i++;
      if (i < args.length) {
        queryRelationPredicate = args[i]!;
        i++;
      }
    } else if (arg === "--recent-days" && command === "query") {
      i++;
      if (i < args.length) {
        queryRecentDaysRaw = args[i]!;
        i++;
      }
    } else if (arg === "--open-limit" && command === "query") {
      i++;
      if (i < args.length) {
        queryOpenLimitRaw = args[i]!;
        i++;
      }
    } else if (arg === "--completed-limit" && command === "query") {
      i++;
      if (i < args.length) {
        queryCompletedLimitRaw = args[i]!;
        i++;
      }
    } else if (arg === "--text" || arg === "--contains") {
      i++;
      if (i < args.length) {
        if (command === "query") {
          queryText = args[i]!;
        }
        i++;
      }
    } else if (arg === "--id") {
      i++;
      if (i < args.length) {
        if (command === "agenda") {
          agendaIdFiltersRaw.push(args[i]!);
        } else if (command === "id") {
          idForced = args[i]!;
        } else if (command === "backlinks") {
          backlinksId = args[i]!;
        } else if (command === "query") {
          queryId = args[i]!;
        } else if (command === "agent" || command === "context" || command === "brief") {
          agentId = args[i]!;
        } else if (command === "render-chart") {
          renderChartBlockId = args[i]!;
        } else if (command === "roam") {
          if (roamAction === "link") {
            roamLinkId = args[i]!;
          } else if (roamAction === "backlinks") {
            backlinksId = args[i]!;
          } else {
            roamIdForced = args[i]!;
          }
        }
        i++;
      }
    } else if ((arg === "--results" || arg === "--result") && command === "query-data") {
      i++;
      if (i < args.length) {
        dataQueryResultId = args[i]!;
        i++;
      }
    } else if (arg === "--duckdb" && command === "query-data") {
      i++;
      if (i < args.length) {
        dataQueryDuckdb = args[i]!;
        i++;
      }
    } else if (arg === "--block-id" && command === "render-chart") {
      i++;
      if (i < args.length) {
        renderChartBlockId = args[i]!;
        i++;
      }
    } else if (arg === "--json") {
      if (command === "archive") archiveFormat = "json";
      else if (command === "refile") refileFormat = "json";
      else if (command === "export") exportFormat = "json";
      else if (command === "publish") publishFormat = "json";
      else if (command === "agenda") format = "json";
      else if (command === "todo") todoFormat = "json";
      else if (command === "capture") captureFormat = "json";
      else if (command === "plan") planFormat = "json";
      else if (command === "crypt") cryptFormat = "json";
      else if (command === "fmt") fmtFormat = "json";
      else if (command === "id") idFormat = "json";
      else if (command === "backlinks") backlinksFormat = "json";
      else if (command === "approvals") approvalsFormat = "json";
      else if (command === "index") indexFormat = "json";
      else if (command === "query") { queryFormat = "json"; searchFormat = "json"; }
      else if (command === "search") searchFormat = "json";
      else if (command === "entity") entityFormat = "json";
      else if (command === "lint") lintFormat = "json";
      else if (command === "graph") graphFormat = "json";
      else if (command === "compile") compileFormat = "json";
      else if (command === "render-chart") renderChartFormat = "json";
      else if (command === "query-data") dataQueryFormat = "json";
      else if (command === "clock") clockFormat = "json";
      else if (command === "context" || command === "brief") contextFormat = "json";
      else if (command === "ai") aiFormat = "json";
      else if (command === "roam" && roamAction === "backlinks") backlinksFormat = "json";
      else if (command === "roam") roamFormat = "json";
      i++;
    } else if (arg === "--format") {
      i++;
      if (i < args.length) {
        const v = args[i];
        if (command === "archive" && (v === "text" || v === "diff" || v === "json")) {
          archiveFormat = v as "text" | "diff" | "json";
        } else if (command === "refile" && (v === "text" || v === "diff" || v === "json")) {
          refileFormat = v as "text" | "diff" | "json";
        } else if (command === "export" && (v === "text" || v === "json")) {
          exportFormat = v;
        } else if (command === "publish" && (v === "text" || v === "json")) {
          publishFormat = v;
        } else if (command === "agenda" && (v === "text" || v === "json")) {
          format = v;
        } else if (command === "todo" && (v === "text" || v === "json" || v === "diff")) {
          todoFormat = v as "text" | "json" | "diff";
        } else if (command === "capture" && (v === "text" || v === "json" || v === "diff")) {
          captureFormat = v as "text" | "json" | "diff";
        } else if (command === "plan" && (v === "text" || v === "json" || v === "diff")) {
          planFormat = v as "text" | "json" | "diff";
        } else if (command === "crypt" && (v === "text" || v === "json" || v === "diff")) {
          cryptFormat = v as "text" | "json" | "diff";
        } else if (command === "fmt" && (v === "text" || v === "json")) {
          fmtFormat = v;
        } else if (command === "id" && (v === "text" || v === "json" || v === "diff")) {
          idFormat = v;
        } else if (command === "backlinks" && (v === "text" || v === "json")) {
          backlinksFormat = v;
        } else if (command === "approvals" && (v === "text" || v === "json")) {
          approvalsFormat = v;
        } else if (command === "index" && (v === "text" || v === "json")) {
          indexFormat = v;
        } else if (command === "query" && (v === "text" || v === "json")) {
          queryFormat = v;
          searchFormat = v;
        } else if (command === "search" && (v === "text" || v === "json")) {
          searchFormat = v;
        } else if (command === "entity" && (v === "text" || v === "json")) {
          entityFormat = v;
        } else if (command === "lint" && (v === "text" || v === "json")) {
          lintFormat = v;
        } else if (command === "graph" && (v === "report" || v === "json")) {
          graphFormat = v;
        } else if (command === "compile" && (v === "json" || v === "jsonl")) {
          compileFormat = v;
        } else if (command === "render-chart" && (v === "svg" || v === "json")) {
          renderChartFormat = v;
        } else if (command === "query-data" && (v === "org" || v === "org-table" || v === "json")) {
          dataQueryFormat = v === "org-table" ? "org" : v;
        } else if (command === "clock" && (v === "text" || v === "json")) {
          clockFormat = v;
        } else if ((command === "context" || command === "brief") && (v === "markdown" || v === "md" || v === "org" || v === "org2" || v === "json")) {
          contextFormat = v === "md" ? "markdown" : v === "org2" ? "org" : v as "markdown" | "org" | "json";
        } else if (command === "ai" && (v === "text" || v === "json")) {
          aiFormat = v;
        } else if (
          command === "roam" &&
          roamAction === "backlinks" &&
          (v === "text" || v === "json")
        ) {
          backlinksFormat = v;
        } else if (command === "roam" && (v === "text" || v === "json" || v === "report")) {
          roamFormat = v;
        }
        i++;
      }
    } else if (arg === "--run-detail" && command === "approvals") {
      i++;
      if (i < args.length) {
        approvalRunDetailIDs.push(args[i]!);
        i++;
      }
    } else if (arg === "--context") {
      i++;
      if (i < args.length) {
        if (command === "search" || command === "query") searchContextRaw = args[i]!;
        i++;
      }
    } else if (arg === "--index") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportIndex = args[i]!;
        } else if (command === "search" || command === "query" || command === "approvals") {
          const value = String(args[i] || "").trim().toLowerCase();
          if (value === "auto" || value === "never" || value === "rebuild" || ((command === "search" || command === "query") && value === "current")) {
            searchIndexMode = value;
          } else {
            console.error("Error: --index must be one of auto, current (search/query only), never, or rebuild");
            process.exit(1);
          }
        }
        i++;
      }
    } else if (arg === "--heading") {
      i++;
      if (i < args.length) {
        if (command === "search" || command === "query") searchHeadingFilter = args[i]!;
        i++;
      }
    } else if (arg === "--q" || arg === "--term") {
      i++;
      if (i < args.length) {
        if (command === "search") searchTerm = args[i]!;
        else if (command === "query") {
          if (args[i] === "relations") queryRelations = true;
          else if (args[i] === "actions") queryActions = true;
          else if (args[i] === "clocks" || args[i] === "clock") queryClocks = true;
          else { queryTerm = args[i]!; searchTerm = args[i]!; }
        }
        i++;
      }
    } else if (arg === "--style" || arg === "--link-style") {
      i++;
      if (i < args.length) {
        const v = String(args[i] || "").trim().toLowerCase();
        if (command === "roam" && roamAction === "link" && (v === "wiki" || v === "id")) {
          roamLinkStyle = v;
        }
        i++;
      }
    } else if (arg === "--subtree") {
      if (command === "query" || command === "search") querySubtree = true;
      i++;
    } else if (arg === "--answer-context") {
      if (command === "query" || command === "search") {
        querySubtree = true;
        queryAnswerContext = true;
      }
      i++;
    } else if (arg === "--recursive") {
      recursive = true;
      i++;
    } else if (arg === "--include-archives") {
      includeArchives = true;
      i++;
    } else if (arg === "--incremental") {
      if (command === "compile") compileIncremental = true;
      if (command === "index") indexIncremental = true;
      i++;
    } else if (arg === "--cache") {
      i++;
      if (i < args.length) {
        if (command === "compile") compileCache = args[i]!;
        i++;
      }
    } else if (arg === "--exclude") {
      i++;
      if (i < args.length) {
        if (command === "roam" && roamAction === "linkify") {
          roamLinkifyExcludes.push(args[i]!);
        }
        i++;
      }
    } else if (arg === "--deadline-warning-days") {
      i++;
      if (i < args.length) {
        if (command === "agenda") agendaDeadlineWarningDaysRaw = args[i]!;
        i++;
      }
    } else if (arg === "--no-overdue") {
      includeOverdue = false;
      i++;
    } else if (arg === "--overdue") {
      includeOverdue = true;
      i++;
    } else if (arg === "--project") {
      i++;
      if (i < args.length) {
        if (command === "publish") {
          publishProject = args[i]!;
        }
        i++;
      }
    } else if (arg === "--preview") {
      if (command === "publish") {
        publishPreview = true;
      }
      i++;
    } else if (arg === "--out" || arg === "--output") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportOut = args[i]!;
        } else if (command === "roam" && roamAction === "graph") {
          roamGraphOut = args[i]!;
        } else if (command === "compile") {
          compileOut = args[i]!;
        } else if (command === "render-chart") {
          renderChartOut = args[i]!;
        } else if (command === "query-data") {
          dataQueryOut = args[i]!;
        } else if (command === "ai") {
          aiOut = args[i]!;
        } else if (command === "brief") {
          briefOut = args[i]!;
        }
        i++;
      }
    } else if (arg === "--out-dir") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportOutDir = args[i]!;
        }
        i++;
      }
    } else if (arg === "--index") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportIndex = args[i]!;
        }
        i++;
      }
    } else if (arg === "--index-title") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportIndexTitle = args[i]!;
        }
        i++;
      }
    } else if (arg === "--css") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          const cssValues = String(args[i] || "")
            .split(",")
            .map((value) => value.trim())
            .filter((value) => value.length > 0);
          exportStylesheets.push(...cssValues);
        }
        i++;
      }
    } else if (arg === "--no-default-style") {
      if (command === "export") {
        exportIncludeDefaultStyle = false;
      }
      i++;
    } else if (arg === "--pdf") {
      if (command === "export") {
        exportPdf = true;
      }
      i++;
    } else if (arg === "--latex-engine") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportLatexEngine = String(args[i] || "").trim() || "pdflatex";
        }
        i++;
      }
    } else if (arg === "--toc") {
      if (command === "export") {
        exportIncludeToc = true;
      }
      i++;
    } else if (arg === "--toc-depth") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportTocDepthRaw = String(args[i] || "");
          exportIncludeToc = true;
        }
        i++;
      }
    } else if (arg === "--number-headings") {
      if (command === "export") {
        exportIncludeHeadlineNumbers = true;
      }
      i++;
    } else if (arg === "--number-headings-depth") {
      i++;
      if (i < args.length) {
        if (command === "export") {
          exportHeadlineNumberDepthRaw = String(args[i] || "");
          exportIncludeHeadlineNumbers = true;
        }
        i++;
      }
    } else if (arg === "--rewrite-file-links") {
      if (command === "export") {
        exportRewriteFileLinks = true;
      }
      i++;
    } else if (arg === "--archive-file") {
      i++;
      if (i < args.length) {
        archiveFile = args[i];
        i++;
      }
    } else if (arg === "--to-file") {
      i++;
      if (i < args.length) {
        if (command === "refile") {
          refileToFile = args[i]!;
        } else if (command === "ai" && aiAction === "promote") {
          aiPromoteToFile = args[i]!;
        }
        i++;
      }
    } else if (arg === "--to-pos") {
      i++;
      if (i < args.length) {
        if (command === "refile") {
          refileToPos = args[i]!;
        }
        i++;
      }
    } else if (arg === "--pos") {
      i++;
      if (i < args.length) {
        const rawPos = args[i]!;
        // For editor integrations it's convenient to pass LINE[:COL].
        // - archive uses the full string
        // - todo/plan/id only use the line component
        if (command === "archive") {
          archivePos = rawPos;
        } else if (command === "refile") {
          refilePos = rawPos;
        } else if (command === "todo") {
          todoLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "plan") {
          planLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "crypt") {
          cryptLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "id") {
          idLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "render-chart") {
          renderChartLine = parseInt(rawPos.split(":")[0]!, 10);
        } else if (command === "roam" && roamAction === "link") {
          roamLinkPos = rawPos;
        }
        i++;
      }
    } else if (arg === "--stdin") {
      if (command === "fmt") fmtStdin = true;
      if (command === "capture") captureReadStdin = true;
      if (command === "render-chart") renderChartStdin = true;
      if (command === "query-data") dataQueryStdin = true;
      i++;
    } else if (arg === "--include-script") {
      if (command === "query-data") dataQueryIncludeScript = true;
      i++;
    } else if (arg === "--inspect") {
      if (command === "query-data") dataQueryInspect = true;
      i++;
    } else if (arg === "--all-results" && command === "query-data") {
      dataQueryAllResults = true;
      i++;
    } else if (arg === "--check") {
      if (command === "fmt") {
        fmtCheck = true;
      }
      i++;
    } else if (arg === "--canonical-org") {
      if (command === "fmt") fmtCanonicalOrg = true;
      i++;
    } else if (arg === "--apply" || arg === "--in-place") {
      if (command === "todo") {
        todoApply = true;
      } else if (command === "capture") {
        captureApply = true;
      } else if (command === "plan") {
        planApply = true;
      } else if (command === "crypt") {
        cryptApply = true;
      } else if (command === "archive") {
        archiveApply = true;
      } else if (command === "refile") {
        refileApply = true;
      } else if (command === "export") {
        exportApply = true;
      } else if (command === "fmt") {
        fmtApply = true;
      } else if (command === "id") {
        idApply = true;
      } else if (command === "roam") {
        roamApply = true;
      } else if (command === "ai") {
        aiApply = true;
      } else if (command === "query-data") {
        dataQueryApply = true;
      }
      i++;
    } else if (arg === "--verbose" || arg === "--verbose-errors") {
      verboseErrors = true;
      i++;
    } else {
      i++;
    }
  }


function parseBudgetToChars(raw: string): number {
  const value = String(raw || "").trim().toLowerCase();
  const match = /^(\d+(?:\.\d+)?)(k|m)?$/.exec(value);
  if (!match) return Number.parseInt(value, 10) || 12000;
  const n = Number.parseFloat(match[1] || "0");
  const multiplier = match[2] === "m" ? 1000000 : match[2] === "k" ? 1000 : 1;
  return Math.max(200, Math.floor(n * multiplier));
}

function parseAgentRankingWeight(raw: string, flag: string): number {
  const value = String(raw || "").trim();
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(value)) {
    console.error(`Error: ${flag} requires a numeric value`);
    process.exit(1);
  }
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed)) {
    console.error(`Error: ${flag} requires a finite numeric value`);
    process.exit(1);
  }
  return parsed;
}

function printGeneralUsage(exitCode: number): never {
  console.error(`Celorga CLI

Usage:
  celorga <command> [options]

Core commands:
  celorga doctor [--dir CORPUS] [--json]
  celorga doctor --machine [--dir CORPUS] [--json]
  celorga doctor --handoff codex|claude|opencode|pi|openclaw [--agent-ref ID] [--apply] [--launch] [--dir CORPUS] [--json]
    Bounded troubleshooting handoff to the selected agent; works without the app. --apply writes views/diagnostics/handoffs/; --launch starts the runtime once in this terminal. Never schedules.
  celorga ledger <list|show|create|update|event> LEDGER [ACCOUNT] [options]
  celorga corpus <show|validate|init> [--dir CORPUS] [--id ID --name NAME --kind KIND] [--apply]
  celorga workspace agent-state --dir CORPUS --json
  celorga workspace <agenda|search> [QUERY] --mount CORPUS [--mount CORPUS ...] [--json]
  celorga project <list|show|create|adopt|update> [options]
  celorga goal <list|show|create|update> [options]
  celorga agent-profile <list|show|create|update|resolve> [options]
  celorga run <create|list|show|validate|start|resume|retry|cancel|complete|complete-external|reopen-external|fail|block|fork|normalize|reconcile-source|assign|comment|outcome|runtime|step|artifact|artifact-review|validation|approval-request|approval-decide> [options]
  celorga review <list|show> [options]
  celorga workflow <list|show|validate|save|run|triggers|package|corpus-template|install-builtin> [options]
  celorga artifact <graph|rebuild> --manifest FILE [--apply]
  celorga runtime <init|show|select|verify-paths> [POLICY] [--capability ID]...
  celorga mcp <serve|clients|client-add|discover|snapshot> [options]
  celorga skill install [--dir CORPUS] [--apply] [--format text|json]
  celorga plugin <list|init|add|remove|update|sync|trust|doctor|exec|template> [options]
  celorga eval <run|fixture> RUN [options]
  celorga agenda --dir DIR [--recursive] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--tui]
  celorga migrate-names [--dir CORPUS] [--apply] [--force] [--json]
  celorga todo-config <show|set> --dir CORPUS [--sequences-json JSON] [--apply]
  celorga daily-config <show|infer|set> --dir CORPUS [--file PATH] [--template FORMAT|--clear] [--apply]
  celorga embed resolve --target file:NOTE.org|id:ID --file SOURCE [--dir CORPUS] [--json]
  celorga checkbox [cycle|toggle|set|fix-cookies] --file FILE [--line N] [--status STATE] [--fix-cookies] [--apply]
  celorga todo <set|toggle|assign|approve> --file FILE (--line N | --pos LINE[:COL]) [--apply]
  celorga approvals --dir DIR [--recursive] [--include-archives] [--index auto|never|rebuild] [--run-detail ID] [--format text|json]
  celorga plan <set|today> --file FILE (--line N | --pos LINE[:COL]) [--apply]
  celorga crypt <encrypt|decrypt|reencrypt> --file FILE (--line N | --pos LINE[:COL]) [--passphrase PASS] [--recipient USER]... [--recipient-file FILE]... [--default-recipient-self] [--gpg-program PATH] [--gpg-timeout SECONDS] [--apply]
  celorga browser-clip import --file CLIP.org2clip --dir CORPUS [--if-revision HASH --if-clip-revision HASH --apply]
  celorga capture --file FILE --title TITLE [--template note|task] [--apply]
  celorga capture (--text TEXT|--stdin|--url URL|--file SOURCE) --to FILE [--title TITLE] [--apply]
  celorga archive --file FILE --pos LINE[:COL] [--archive-file FILE] [--apply]
  celorga refile --file FILE --pos LINE[:COL] --to-file FILE [--to-pos LINE[:COL]] [--apply]

Export / publish:
  celorga export html --file FILE [--out FILE] [--apply]
  celorga export html --dir DIR [--recursive] [--out-dir DIR] [--index FILE] [--apply]
  celorga export beamer --file FILE [--out FILE] [--pdf] [--latex-engine COMMAND] [--apply]
  celorga publish document --file FILE --to web --out-dir DIR [--line N] [--apply]
  celorga publish document --file FILE --to beamer-pdf --out-file FILE.pdf [--line N] [--apply]
  celorga publish document --file FILE --to google-docs|google-slides|google-sheets [--folder-id ID] [--apply]
  celorga publish document --file FILE --to google-drive-pdf --pdf-file FILE.pdf [--folder-id ID] [--apply]
  celorga publish [PROJECT] [--config PATH] [--preview]

Canvas:
  celorga canvas show|targets|create|edit|import|export --dir DIR [--file FILE] [--json]

Roam / IDs:
  celorga id <get|ensure> --file FILE [--line N|--pos LINE[:COL]] [--apply]
  celorga backlinks --id UUID [--dir DIR] [--recursive]
  celorga index --dir DIR [--recursive] [--include-archives] [--format text|json]
  celorga search QUERY [--dir DIR] [--recursive] [--include-archives] [--format text|json]
  celorga query QUERY [--dir DIR] [--recursive] [--include-archives] [--format text|json]
  celorga query actions --object ID|TITLE|LINK [--recent-days N] [--dir DIR] [--recursive] [--format text|json]
  celorga entity show NAME [--dir DIR] [--recursive] [--format text|json]
  celorga query (--id UUID|--text TEXT) [--dir DIR] [--recursive] [--include-archives]
  celorga query clocks --dir DIR [--recursive] [--format text|json]
  celorga clock --dir DIR [--recursive] [--format text|json]
  celorga compile corpus --dir DIR [--recursive] [--out FILE] [--format json|jsonl]
  celorga render-chart --file FILE [--block-id ID|--line N] [--out FILE] [--format svg|json]
  celorga property-view list|query|save|edit --dir CORPUS [--help]
  celorga view list|create|show|refresh|state|action|undo|bridge --dir CORPUS [--help]
  celorga query-data (--file FILE|--stdin) [--results NAME|--line N] [--out FILE|--apply] [--format org|json]
  celorga table recalculate --file FILE [--line N] [--formula-index N] [--apply] [--format text|diff|json]
  celorga agent capabilities
  celorga agent <context|search|fetch|bundle> [options]
  celorga context QUERY [--dir DIR] [--recursive] [--budget 8k] [--format markdown|org|json]
  celorga brief today [--dir DIR] [--recursive] [--out views/today.org]
  celorga brief project NAME [--dir DIR] [--recursive] [--out views/NAME.org]
  celorga brief node --id ID [--dir DIR] [--recursive] [--out views/node.org]
  celorga ai validate-job --job FILE [--format text|json]
  celorga ai run --job FILE [--out FILE] [--apply] [--format text|json]
  celorga ai run --task summarize-meeting --file FILE [--out FILE] [--apply]
  celorga ai suggest-links --dir DIR [--recursive] [--file FILE] [--out FILE --apply] [--format text|json]
  celorga ai review --dir DIR [--recursive] [--file FILE|--files FILE ...] [--format text|json]
  celorga ai review --file DRAFT --status reviewed|rejected|deferred [--apply] [--format text|json]
  celorga ai promote --file DRAFT --to-file NOTE [--apply] [--format text|json]
  celorga roam db-sync --dir DIR [--recursive] [--apply]
  celorga roam node new --dir DIR --title TITLE [--id UUID] [--apply]
  celorga roam link insert-backlink --file FILE --pos LINE[:COL] --title TITLE [--style wiki|id] [--id UUID] [--apply]
  celorga roam linkify --dir DIR [--recursive] [--file FILE] [--exclude PATH]... [--apply] [--format text|json]
  celorga roam connections --dir DIR (--id ID | --file FILE) [--depth 1|2] [--format json]
  celorga roam mention-link --dir DIR --file FILE --mention KEY --target ID --if-revision HASH [--apply]
  celorga roam graph --dir DIR [--recursive] [--out FILE] [--format text|report|json]
  celorga graph audit --dir DIR [--recursive] [--format report|json]

Maintenance / health:
  celorga doctor [--dir CORPUS] [--json]
  celorga doctor --machine [--dir CORPUS] [--json]
  celorga doctor --handoff codex|claude|opencode|pi|openclaw [--agent-ref ID] [--apply] [--launch] [--dir CORPUS] [--json]
    Bounded troubleshooting handoff to the selected agent; works without the app. --apply writes views/diagnostics/handoffs/; --launch starts the runtime once in this terminal. Never schedules.
  celorga index [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--incremental] [--format text|json]
  celorga approvals [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--index auto|never|rebuild] [--run-detail ID] [--format text|json]
  celorga compile corpus [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--out FILE] [--format json|jsonl] [--incremental] [--cache FILE]
  celorga ai validate-job --job FILE [--format text|json]
  celorga ai run --job FILE [--out FILE] [--apply] [--format text|json]
  celorga ai run --task summarize-meeting --file FILE [--out FILE] [--apply]
  celorga ai suggest-links --dir DIR [--recursive] [--file FILE] [--out FILE --apply] [--format text|json]
  celorga ai review --dir DIR [--recursive] [--file FILE|--files FILE ...] [--format text|json]
  celorga ai review --file DRAFT --status reviewed|rejected|deferred [--apply] [--format text|json]
  celorga ai promote --file DRAFT --to-file NOTE [--apply] [--format text|json]
  celorga graph audit [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--format report|json]
  celorga lint [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--format text|json]
  celorga fmt [--stdin] [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--canonical-org] [--check] [--apply]

Other:
  celorga version
  celorga --version
  celorga lsp
  celorga server <init|start|status|pair|revoke|stop|permissions|token|mcp|assign|service|push-config> [options]

Tips:
  - Use --help with subcommands for detailed flags (e.g., celorga agenda --help).
  - Use --format json for scriptable output where supported; --json is a shorthand alias.
  - Commands that mutate files preview by default and require --apply to write.`);
  process.exit(exitCode);
}

function printScopedUsage(
  command: string,
  options: {
    exportAction: "html" | "beamer";
    todoAction: "set" | "toggle" | "assign" | "approve";
    planAction: "set" | "today";
    cryptAction: "encrypt" | "decrypt" | "reencrypt";
    idAction: "get" | "ensure";
    roamAction: "db-sync" | "backlinks" | "node" | "link" | "linkify" | "graph";
    graphAction: "audit" | "repair-candidates";
    roamNodeAction: "new";
    roamLinkAction: "insert-backlink";
    aiAction: "validate-job" | "run" | "promote" | "suggest-links" | "review" | "";
    agentAction: "capabilities" | "context" | "search" | "fetch" | "bundle" | "";
  },
  exitCode: number,
): never {
  let text = "";

  if (command === "agenda") {
    text = `celorga agenda

Usage:
  celorga agenda --dir DIR [--recursive] [--include-archives] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--tui]

Flags:
  --dir DIR           Root directory to scan
  --recursive         Recurse into subdirectories
  --include-archives  Include archive files/directories in agenda scans
  --from YYYY-MM-DD   Start date filter
  --to YYYY-MM-DD     End date filter
  --tui               Open the interactive terminal agenda
  --workload          Include JSON effort workload rollups by date/group/tag
  --format text|json  Output format`;
  } else if (command === "todo") {
    text = `celorga todo ${options.todoAction}

Usage:
  celorga todo <set|toggle|assign|approve> --file FILE (--line N | --pos LINE[:COL]) [--apply]

Flags:
  --file FILE         Target file
  --line N            Heading line number
  --pos LINE[:COL]    Heading position
  --status STATUS     Standard status or declared custom keyword for 'set'
  --keyword KEYWORD   Exact declared TODO keyword (preserves case)
  --assignee NAME     Assignee for 'assign'
  --agent-ref ID      Portable agent profile ID for 'assign'
  --goal-ref ID       Portable goal ID for 'assign'
  --now ISO           Override approval / closed timestamp
  --apply             Write changes instead of previewing`;
  } else if (command === "approvals") {
    text = `celorga approvals

Usage:
  celorga approvals [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--index auto|never|rebuild] [--format text|json]

Flags:
  --dir DIR           Root directory to scan
  --recursive         Recurse into subdirectories
  --include-archives  Include archive files/directories
  --index MODE        auto (default), never, or rebuild. Auto uses a fresh search index or rebuilds it.
  --run-detail ID     Include the current full run in JSON output; repeatable
  --format text|json  Output format`;
  } else if (command === "plan") {
    text = `celorga plan ${options.planAction}

Usage:
  celorga plan <set|today> --file FILE (--line N | --pos LINE[:COL]) [--apply]

Flags:
  --file FILE         Target file
  --line N            Heading line number
  --pos LINE[:COL]    Heading position
  --date YYYY-MM-DD   Planned date for 'set'
  --apply             Write changes instead of previewing`;
  } else if (command === "crypt") {
    text = `celorga crypt ${options.cryptAction}

Usage:
  celorga crypt <encrypt|decrypt|reencrypt> --file FILE (--line N | --pos LINE[:COL]) [--passphrase PASS] [--recipient USER]... [--recipient-file FILE]... [--default-recipient-self] [--gpg-program PATH] [--gpg-timeout SECONDS] [--apply]

Flags:
  --file FILE         Target file
  --line N            Heading line number
  --pos LINE[:COL]    Heading position
  --passphrase PASS   Symmetric encryption passphrase, or private-key passphrase for decrypt/reencrypt
  --recipient USER     Public-key recipient (repeatable)
  --recipient-file FILE Public-key recipient file (repeatable)
  --default-recipient-self Use GPG's default key as the public-key recipient
  --gpg-program PATH  Optional gpg binary path
  --gpg-timeout SECONDS Maximum time to wait for gpg
  --apply             Write changes instead of previewing`;
  } else if (command === "capture") {
    text = `celorga capture

Usage:
  celorga capture --file FILE --title TITLE [--template note|task] [--body TEXT] [--apply]
  celorga capture (--text TEXT|--stdin|--url URL|--file SOURCE) --to FILE [--title TITLE] [--author NAME] [--apply]

Flags:
  --file FILE           Target file, or source file when --to is set
  --to FILE             Target file for unified capture sources
  --text TEXT           Capture literal text as source content
  --stdin               Read capture content from standard input
  --url URL             Fetch and capture a URL as text
  --title TITLE         Heading title
  --author NAME         Optional source author metadata
  --origin VALUE        Optional source origin/provenance override
  --source-type TYPE    Optional source type override
  --template note|task  Capture template
  --apply               Write changes instead of previewing`;
  } else if (command === "archive") {
    text = `celorga archive

Usage:
  celorga archive --file FILE --pos LINE[:COL] [--archive-file FILE] [--apply]

Flags:
  --file FILE          Source file
  --pos LINE[:COL]     Heading position
  --archive-file FILE  Destination archive file (default FILE_archive for .org)
  --format text|diff|json  Output format; diff/json include archive provenance preview
  --apply              Write changes instead of previewing`;
  } else if (command === "refile") {
    text = `celorga refile

Usage:
  celorga refile --file FILE --pos LINE[:COL] --to-file FILE [--to-pos LINE[:COL]] [--apply]

Flags:
  --file FILE        Source file
  --pos LINE[:COL]   Source heading position
  --to-file FILE     Destination file
  --to-pos LINE[:COL] Destination position
  --apply            Write changes instead of previewing`;
  } else if (command === "export") {
    text = options.exportAction === "beamer"
      ? `celorga export beamer

Usage:
  celorga export beamer --file FILE [--out FILE] [--pdf] [--latex-engine COMMAND] [--apply]

Flags:
  --file FILE             Input Org presentation
  --out FILE              Output .tex or .pdf file
  --pdf                   Compile the generated Beamer source to PDF
  --latex-engine COMMAND  LaTeX engine command or path (default: pdflatex)
  --apply                 Write the output instead of previewing`
      : `celorga export html

Usage:
  celorga export html --file FILE [--out FILE] [--apply]
  celorga export html --dir DIR [--recursive] [--out-dir DIR] [--index FILE] [--apply]

Flags:
  --file FILE      Single input file
  --dir DIR        Input directory
  --recursive      Recurse into subdirectories
  --out FILE       Output file for single-file export
  --out-dir DIR    Output directory for multi-file export
  --index FILE     Optional index file name
  --apply          Write files instead of previewing`;
  } else if (command === "publish") {
    text = `celorga publish

Usage:
  celorga publish [PROJECT] [--config PATH] [--preview]
  celorga publish document --file FILE --to web --out-dir DIR [--line N] [--apply]
  celorga publish document --file FILE --to beamer-pdf --out-file FILE.pdf [--line N] [--apply]
  celorga publish document --file FILE --to google-docs|google-slides|google-sheets [--folder-id ID] [--apply]
  celorga publish document --file FILE --to google-drive-pdf --pdf-file FILE.pdf [--folder-id ID] [--apply]

Flags:
  --config PATH   Publish config file
  --preview       Do not write project outputs

Run 'celorga publish document --help' for single-document destinations and guarded Google Drive updates.`;
  } else if (command === "fmt") {
    text = `celorga fmt

Usage:
  celorga fmt [--stdin] [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--canonical-org] [--check] [--apply]

Flags:
  --stdin         Read input from stdin
  --dir DIR       Root directory to scan
  --recursive     Recurse into subdirectories
  --file FILE     Single target file
  --files FILE    One or more target files
  --canonical-org Rewrite accepted syntax sugar to ordinary Org forms (automatic for .org file targets; required for stdin)
  --check         Exit non-zero if formatting would change files
  --apply         Write changes instead of previewing`;
  } else if (command === "lsp") {
    text = `celorga lsp

Usage:
  celorga lsp`;
  } else if (command === "id") {
    text = `celorga id ${options.idAction}

Usage:
  celorga id <get|ensure> --file FILE [--line N|--pos LINE[:COL]] [--apply]

Flags:
  --file FILE       Target file
  --line N          Heading line number
  --pos LINE[:COL]  Heading position
  --format text|json Output format
  --apply           Write changes for 'ensure'`;
  } else if (command === "backlinks") {
    text = `celorga backlinks

Usage:
  celorga backlinks --id UUID [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--format text|json]

Flags:
  --id UUID         Target ID
  --dir DIR         Root directory to scan
  --recursive       Recurse into subdirectories
  --file FILE       Single target file
  --files FILE      One or more target files
  --format text|json Output format`;
  } else if (command === "index") {
    text = `celorga index

Usage:
  celorga index [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--incremental] [--format text|json]

Builds a rebuildable exact-text search index under ${org2IndexHome()}/<corpus-slug>-<hash>/search-v1.json. Org files remain canonical; the index is disposable machine-local derived storage.

Flags:
  --dir DIR          Root directory to scan
  --recursive        Recurse into subdirectories
  --include-archives Include archive files/directories in index scans
  --file FILE        Single target file
  --files FILE       One or more target files
  --incremental      Update only --file/--files in an existing compatible index
  --format text|json Output format`;
  } else if (command === "search") {
    text = `celorga search

Usage:
  celorga search QUERY [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--format text|json]

Search scans .org files for literal, case-insensitive text and returns cited file/line matches. Directory scans are non-recursive unless --recursive is set.

Flags:
  --dir DIR          Root directory to scan
  --recursive        Recurse into subdirectories
  --include-archives Include archive files/directories in search scans
  --file FILE        Single target file
  --files FILE       One or more target files
  --todo TODO        Require nearest heading TODO keyword
  --tag TAG          Require nearest heading tag
  --heading TEXT     Require nearest heading title text
  --limit N          Maximum matches (default 50)
  --context N        Context lines around each match (default 1)
  --index auto|current|never|rebuild Use a fresh derived index, a watcher-maintained current index, no index, or rebuild before searching
  --subtree          Return one cited heading/subtree per matching section
  --answer-context   Include subtree text for downstream answer prompts (JSON)
  --date-from DATE   Filter by file/heading date (YYYY-MM-DD)
  --date-to DATE     Filter by file/heading date (YYYY-MM-DD)
  --file-zone TEXT   Require TEXT in the file path
  --sort MODE        scan|relevance|best|date-desc|date-asc
  --format text|json Output format`;
  } else if (command === "query") {
    text = `celorga query

Usage:
  celorga query QUERY [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--format text|json]
  celorga query --id UUID [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--format text|json]
  celorga query --text TEXT [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--format text|json]
  celorga query relations --object ID|TITLE|LINK [--predicate PREDICATE] [--dir DIR] [--recursive] [--include-archives] [--format text|json]
  celorga query actions --object ID|TITLE|LINK [--recent-days N] [--open-limit N] [--completed-limit N] [--dir DIR] [--recursive] [--format text|json]

Flags:
  --id UUID         Target ID lookup (legacy)
  --text TEXT       Text to search for; returns cited file/line snippets
  --object TARGET   Target node for relations or actions
  --recent-days N   Completed-action lookback for actions (default 30)
  --open-limit N    Maximum open actions returned (default 8)
  --completed-limit N Maximum completed actions returned (default 4)
  --dir DIR         Root directory to scan
  --recursive       Recurse into subdirectories
  --include-archives Include archive files/directories in query scans
  --file FILE       Single target file
  --files FILE      One or more target files
  --todo TODO       Require nearest heading TODO keyword
  --tag TAG         Require nearest heading tag
  --heading TEXT    Require nearest heading title text
  --limit N         Maximum matches (default 50)
  --context N       Context lines around each match (default 1)
  --subtree         Return one cited heading/subtree per matching section
  --answer-context  Include subtree text for downstream answer prompts (JSON)
  --date-from DATE  Filter by file/heading date (YYYY-MM-DD)
  --date-to DATE    Filter by file/heading date (YYYY-MM-DD)
  --file-zone TEXT  Require TEXT in the file path
  --sort MODE       scan|relevance|best|date-desc|date-asc
  --format text|json Output format`;
  } else if (command === "compile") {
    text = `celorga compile corpus

Usage:
  celorga compile corpus [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--out FILE] [--format json|jsonl] [--incremental] [--cache FILE]

Flags:
  --dir DIR          Root directory to scan
  --recursive        Recurse into subdirectories
  --include-archives Include archive files/directories in corpus scans
  --file FILE        Single target file
  --files FILE       One or more target files
  --out FILE         Write the compiled corpus artifact to a file
  --format json|jsonl Output format (default json)
  --incremental      Reparse only changed files and reuse cached file fragments
  --cache FILE       Override the machine-local incremental cache path

Output:
  Stable schema-versioned corpus artifact for LLM/tool clients. Includes
  standardized generated-artifact metadata, source hashes, headings, IDs,
  aliases, links, backlinks, TODO/planning state, properties, source ranges,
  and snippets. Celorga emits data only; it does not call an LLM.`;
  } else if (command === "render-chart") {
    text = `celorga render-chart

Usage:
  celorga render-chart --file FILE [--block-id ID|--line N] [--out FILE] [--format svg|json]
  celorga render-chart --stdin [--out FILE] [--format svg|json]

Flags:
  --file FILE       Source Org file
  --stdin           Read Org input from standard input
  --block-id ID     Select a chart by adjacent #+name
  --id ID           Alias for --block-id
  --line N          Select the first chart table at or after line N
  --out FILE        Write the SVG artifact to FILE
  --format FORMAT   svg (default) or json diagnostics envelope

Output:
  Deterministic SVG for #+chart or #+plot metadata attached to an Org table.
  Line and bar charts accept comma-separated y columns for multiple series.
  JSON output includes ok, format, artifact, source, diagnostics, and svg.`;
  } else if (command === "query-data") {
    text = `celorga query-data

Usage:
  celorga query-data --file FILE [--results NAME|--line N] [--out FILE|--apply] [--format org|json]
  celorga query-data --file FILE --all-results --apply [--format json]
  celorga query-data --stdin [--results NAME|--line N] [--out FILE] [--format org|json]
  celorga query-data --file FILE --inspect

Flags:
  --file FILE         Source Org file containing dataset and SQL blocks
  --stdin             Read Org input from standard input
  --results NAME      SQL result block to run; optional when the file has one SQL block
  --all-results       Run every SQL result and apply them with one atomic file write
  --line N            Select the SQL result block containing or after line N
  --duckdb PATH       Override the bundled DuckDB engine with a CLI path
  --out FILE          Write materialized org table or JSON envelope to FILE
  --apply             Insert or replace the materialized result in the source file
  --format FORMAT     org (default) or json diagnostics envelope
  --include-script    Include generated DuckDB SQL setup in JSON/inspect output
  --inspect           Parse query-data blocks as JSON without running DuckDB

Input:
  Reads fenced \`\`\`dataset NAME blocks with engine: duckdb and either
  type: csv|parquet|json plus path/url, type: table plus source:
  named_org_table, type: clickhouse plus profile/query, or type: metabase
  plus profile/question. Remote profiles are resolved from dataSources in the
  nearest celorga.json and secrets are read from profile-named environment
  variables. Optional \`\`\`sql view=NAME blocks define reusable
  DuckDB views before the selected \`\`\`sql results=NAME block is run. SQL result
  result names must be unique. Dataset names and SQL view names must not
  conflict because they share DuckDB's relation namespace. SQL result blocks may
  include artifact=PATH to record the intended materialized output, and
  freshness=24h/ttl=24h/max-age=24h to tell clients how long a materialized
  result should be treated as fresh; --out FILE records the actual artifact
  path. Dataset credential/auth and config/profile metadata must be external
  references such as env:VAR, secret:NAME, config:NAME, or profile:NAME; inline
  secrets are rejected and references are not injected into DuckDB SQL.
  Refresh is explicit: this command may call configured remote sources, while
  HTML rendering never executes warehouse queries.`;
  } else if (command === "context") {
    text = `celorga context

Usage:
  celorga context QUERY [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--budget 8k] [--limit N] [--include sources,backlinks,neighbors] [--format markdown|org|json]
  celorga context --id ID [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--format markdown|org|json]

Flags:
  --query QUERY      Retrieval query (or pass QUERY as first positional argument)
  --id ID            Render a context pack for one selected heading/file ID
  --budget N         Approximate max context characters; supports k/m suffixes (default 12000)
  --format FORMAT    markdown (default), org, or json
  --scope NAME       Optional project/person/task scope filter
  --since RANGE      Optional recency filter such as 90d
  --recency-weight N Ranking weight for recent dates/planning (default 1; 0 disables)
  --salience-weight N Ranking weight for salience metadata, TODOs, backlinks, and scope proximity (default 1)

Output:
  Deterministic context pack for agents and humans: objective/query, cited notes with file:line provenance, recent timeline entries, active TODOs, related entities/backlinks, uncertainty, and next actions.`;
  } else if (command === "brief") {
    text = `celorga brief

Usage:
  celorga brief today [--dir DIR] [--recursive] [--limit N] [--out views/today.org] [--format markdown|org|json]
  celorga brief project NAME [--dir DIR] [--recursive] [--limit N] [--out views/NAME.org] [--format markdown|org|json]
  celorga brief node --id ID [--dir DIR] [--recursive] [--out views/node.org] [--format markdown|org|json]

Human-facing briefings from the agent context substrate. Output cites notes/raw sources and marks generated synthesis review-required.`;
  } else if (command === "agent") {
    text = `celorga agent ${options.agentAction || "context"}

Usage:
  celorga agent capabilities
  celorga agent bundle --query QUERY [--scope project:NAME] [--since 90d] [--source-type TYPE] [--review-status STATUS] [--max-tokens N]
  celorga agent context --query QUERY [--dir DIR] [--recursive] [--file FILE|--files FILE ...]
  celorga agent search --query QUERY [--dir DIR] [--recursive] [--file FILE|--files FILE ...]
  celorga agent fetch --id ID [--dir DIR] [--recursive] [--file FILE|--files FILE ...]

Flags:
  --query QUERY      Retrieval query for context/search
  --id ID            Heading/file ID or compiled node key for fetch
  --dir DIR          Root directory to scan
  --recursive        Recurse into subdirectories
  --file FILE        Single target file
  --files FILE       One or more target files
  --limit N          Maximum result count (default 10)
  --max-chars N      Maximum context text characters (default 12000)
  --include LIST     Comma-separated sources,backlinks,neighbors
  --format json      Stable JSON output (default)
  --recency-weight N Ranking weight for recent dates/planning (default 1; 0 disables)
  --salience-weight N Ranking weight for salience metadata, TODOs, backlinks, and scope proximity (default 1)

Output:
  capabilities emits schema org2:capabilities:v1 with workflows, safety rules, clients, and documentation entry points.
  Schema org2:agent-context:v1 with source ranges, citations, IDs, titles,
  tags, properties, optional backlinks/neighbors, and bounded context text.`;
  } else if (command === "graph") {
    text = `celorga graph ${options.graphAction || "audit"}

Usage:
  celorga graph audit [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--format report|json]
  celorga graph repair-candidates [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--format json]

Checks:
  Broken links, orphan notes, duplicate IDs/entities, and stale generated artifacts.
  Findings separate deterministic fixes from review-gated suggestions.`;
  } else if (command === "lint") {
    text = `celorga lint

Usage:
  celorga lint [--dir DIR] [--recursive] [--include-archives] [--file FILE|--files FILE ...] [--format text|json]

Flags:
  --dir DIR         Root directory to scan
  --recursive       Recurse into subdirectories
  --include-archives Include archive files/directories in lint scans
  --file FILE       Single target file
  --files FILE      One or more target files
  --format text|json Output format

Checks:
  Artifact metadata, source hash/review status syntax, duplicate IDs,
  unresolved provenance references, graph link health (broken id/wiki links
  and ambiguous wiki labels), and conventional corpus-flow role/path
  mismatches.`;
  } else if (command === "ai") {
    text = `celorga ai ${options.aiAction || "validate-job"}

Usage:
  celorga ai validate-job --job FILE [--format text|json]
  celorga ai run --job FILE [--out FILE] [--apply] [--format text|json]
  celorga ai run --task summarize-meeting --file FILE [--out FILE] [--apply]
  celorga ai suggest-links --dir DIR [--recursive] [--file FILE] [--out FILE --apply] [--format text|json]
  celorga ai review --dir DIR [--recursive] [--file FILE|--files FILE ...] [--format text|json]
  celorga ai review --file DRAFT --status reviewed|rejected|deferred [--apply] [--format text|json]
  celorga ai promote --file DRAFT --to-file NOTE [--apply] [--format text|json]

Flags:
  --job FILE         AI job manifest JSON file
  --out FILE         Override manifest output.path for ai run
  --file FILE        Draft artifact for review/promote, or source for ai run
  --status STATUS    Review status for ai review: reviewed, rejected, or deferred
  --to-file NOTE     Canonical note file to append promoted body to
  --apply            Write changes; without it, print a safe preview
  --format text|json Output format

Checks:
  validate-job checks provider-free manifest shape and accidental secrets.
  run writes a generated draft artifact with provenance/source hashes and review status.
  review lists pending artifacts and marks candidates reviewed/rejected/deferred.
  promote appends only reviewed drafts to canonical notes and marks the source promoted.`;
  } else if (command === "roam") {
    if (options.roamAction === "db-sync") {
      text = `celorga roam db-sync

Usage:
  celorga roam db-sync --dir DIR [--recursive] [--apply] [--format text|json]

Flags:
  --dir DIR         Root directory to scan
  --recursive       Recurse into subdirectories
  --format text|json Output format
  --apply           Write missing file IDs`;
    } else if (options.roamAction === "backlinks") {
      text = `celorga roam backlinks

Usage:
  celorga roam backlinks --id UUID [--dir DIR] [--recursive] [--file FILE|--files FILE ...] [--format text|json]

Notes:
  Alias for celorga backlinks, kept for namespaced editor flows.`;
    } else if (options.roamAction === "node") {
      text = `celorga roam node ${options.roamNodeAction}

Usage:
  celorga roam node new --dir DIR --title TITLE [--id UUID] [--apply] [--format text|json]

Flags:
  --dir DIR         Output directory
  --title TITLE     Node title
  --id UUID         Optional explicit ID
  --format text|json Output format
  --apply           Write the file instead of previewing`;
    } else if (options.roamAction === "link") {
      text = `celorga roam link ${options.roamLinkAction}

Usage:
  celorga roam link insert-backlink --file FILE --pos LINE[:COL] --title TITLE [--style wiki|id] [--id UUID] [--apply] [--format text|json]

Flags:
  --file FILE       Target file
  --pos LINE[:COL]  Insert position
  --title TITLE     Link title
  --style wiki|id   Render as wiki or id link
  --id UUID         Required when --style id
  --format text|json Output format
  --apply           Write changes instead of previewing`;
    } else if (options.roamAction === "linkify") {
      text = `celorga roam linkify

Usage:
  celorga roam linkify --dir DIR [--recursive] [--file FILE] [--exclude PATH]... [--apply] [--format text|json]

Flags:
  --dir DIR         Root directory to scan
  --recursive       Recurse into subdirectories
  --file FILE       Restrict rewrites to one file
  --format text|json Output format
  --apply           Write linkified content instead of previewing`;
    } else if (options.roamAction === "graph") {
      text = `celorga roam graph

Usage:
  celorga roam graph --dir DIR [--recursive] [--out FILE] [--format text|report|json]

Flags:
  --dir DIR         Root directory to scan
  --recursive       Recurse into subdirectories
  --out FILE        Output HTML/report file
  --format text|report|json Output format (text writes the interactive HTML graph)`;
    }
  }

  if (!text) {
    printGeneralUsage(exitCode);
  }

  console.error(text);
  process.exit(exitCode);
}

  if (help) {
    if (command) {
      printScopedUsage(command, { exportAction, todoAction, planAction, cryptAction, idAction, roamAction, graphAction, roamNodeAction, roamLinkAction, aiAction, agentAction }, 0);
    }
    printGeneralUsage(0);
  }

  if (command !== "agenda" && command !== "archive" && command !== "refile" && command !== "export" && command !== "publish" && command !== "todo" && command !== "capture" && command !== "plan" && command !== "crypt" && command !== "fmt" && command !== "lsp" && command !== "id" && command !== "backlinks" && command !== "approvals" && command !== "index" && command !== "search" && command !== "query" && command !== "clock" && command !== "compile" && command !== "render-chart" && command !== "query-data" && command !== "entity" && command !== "agent" && command !== "context" && command !== "brief" && command !== "lint" && command !== "graph" && command !== "ai" && command !== "roam") {
    printGeneralUsage(1);
  }

  if (command === "lsp") {
    // The LSP server runs over stdio and expects to own stdin/stdout.
    // Importing this module starts the server.
    await import("./lsp.js");
    return;
  }

  if (command === "render-chart") {
    if (renderChartFile && renderChartStdin) {
      console.error("Error: render-chart accepts only one of --file or --stdin");
      process.exit(1);
    }
    if (!renderChartFile && !renderChartStdin) {
      console.error("Error: render-chart requires --file FILE or --stdin");
      process.exit(1);
    }

    const input = renderChartStdin
      ? (await readStdinText()).replace(/\r\n/g, "\n")
      : fs.readFileSync(path.resolve(renderChartFile), "utf8").replace(/\r\n/g, "\n");
    const sourceFile = renderChartStdin ? undefined : renderChartFile;
    const result = renderOrgChart(input, {
      ...(sourceFile ? { file: sourceFile } : {}),
      ...(renderChartLine > 0 ? { line: renderChartLine } : {}),
      ...(renderChartBlockId ? { blockId: renderChartBlockId } : {}),
      ...(renderChartOut ? { outputPath: renderChartOut } : {}),
    });

    if (result.ok && result.svg && renderChartOut) {
      const outputPath = path.resolve(renderChartOut);
      fs.mkdirSync(path.dirname(outputPath), { recursive: true });
      fs.writeFileSync(outputPath, result.svg, "utf8");
    }

    if (renderChartFormat === "json") {
      process.stdout.write(JSON.stringify(result, null, 2) + "\n");
    } else if (result.ok && result.svg) {
      if (renderChartOut) process.stdout.write(`Wrote chart SVG to ${renderChartOut}\n`);
      else process.stdout.write(result.svg);
    } else {
      for (const item of result.diagnostics) {
        const where = item.source?.line ? `:${item.source.line}` : "";
        console.error(`${item.severity}: ${item.message}${where}`);
      }
    }

    if (!result.ok) process.exit(1);
    return;
  }

  if (command === "query-data") {
    const { applyDataQueryResult, applyDataQueryResults, runOrg2DataQuery } = await import("./dataQuery.js");
    if (dataQueryFile && dataQueryStdin) {
      console.error("Error: query-data accepts only one of --file or --stdin");
      process.exit(1);
    }
    if (!dataQueryFile && !dataQueryStdin) {
      console.error("Error: query-data requires --file FILE or --stdin");
      process.exit(1);
    }
    if (dataQueryResultId && dataQueryLine > 0) {
      console.error("Error: query-data accepts only one of --results or --line");
      process.exit(1);
    }
    if (dataQueryAllResults && (dataQueryResultId || dataQueryLine > 0)) {
      console.error("Error: query-data --all-results cannot be combined with --results or --line");
      process.exit(1);
    }
    if (dataQueryAllResults && !dataQueryApply) {
      console.error("Error: query-data --all-results requires --apply");
      process.exit(1);
    }
    if (dataQueryApply && dataQueryStdin) {
      console.error("Error: query-data --apply requires --file");
      process.exit(1);
    }
    if (dataQueryApply && dataQueryOut) {
      console.error("Error: query-data accepts only one of --apply or --out");
      process.exit(1);
    }
    if (dataQueryApply && dataQueryInspect) {
      console.error("Error: query-data accepts only one of --apply or --inspect");
      process.exit(1);
    }

    const input = dataQueryStdin
      ? (await readStdinText()).replace(/\r\n/g, "\n")
      : fs.readFileSync(path.resolve(dataQueryFile), "utf8").replace(/\r\n/g, "\n");
    if (dataQueryAllResults) {
      const inspection = await runOrg2DataQuery(input, {
        file: dataQueryFile,
        ...(dataQueryDuckdb ? { duckdbPath: dataQueryDuckdb } : {}),
        inspectOnly: true,
      });
      const results = [];
      if (inspection.ok) {
        for (const block of inspection.resultBlocks) {
          const result = await runOrg2DataQuery(input, {
            file: dataQueryFile,
            resultId: block.resultId,
            ...(dataQueryDuckdb ? { duckdbPath: dataQueryDuckdb } : {}),
            includeScript: dataQueryIncludeScript,
          });
          results.push(result);
          if (!result.ok) break;
        }
      }
      const diagnostics = inspection.ok
        ? results.flatMap((result) => result.diagnostics)
        : inspection.diagnostics;
      const ok = inspection.ok
        && results.length === inspection.resultBlocks.length
        && results.every((result) => result.ok);
      const sourcePath = path.resolve(dataQueryFile);
      if (!ok) {
        const envelope = {
          ok: false,
          mode: "execute",
          engine: "duckdb",
          resultBlocks: inspection.resultBlocks,
          results,
          applied: false,
          changed: false,
          changedResultCount: 0,
          resultCount: inspection.resultBlocks.length,
          file: sourcePath,
          diagnostics,
        };
        if (dataQueryFormat === "json") process.stdout.write(JSON.stringify(envelope, null, 2) + "\n");
        else {
          for (const item of diagnostics) {
            const where = item.source?.line ? `:${item.source.line}` : "";
            console.error(`${item.severity}: ${item.message}${where}`);
          }
        }
        process.exit(1);
      }

      const applied = applyDataQueryResults(input, results);
      if (applied.changed) fs.writeFileSync(sourcePath, applied.text, "utf8");
      const envelope = {
        ok: true,
        mode: "execute",
        engine: "duckdb",
        resultBlocks: inspection.resultBlocks,
        results,
        applied: true,
        changed: applied.changed,
        changedResultCount: applied.changedResultCount,
        resultCount: results.length,
        file: sourcePath,
        diagnostics,
      };
      if (dataQueryFormat === "json") process.stdout.write(JSON.stringify(envelope, null, 2) + "\n");
      else process.stdout.write(`${applied.changed ? "Updated" : "Unchanged"} ${dataQueryFile} (${results.length} results)\n`);
      return;
    }
    const result = await runOrg2DataQuery(input, {
      ...(dataQueryFile ? { file: dataQueryFile } : {}),
      ...(dataQueryResultId ? { resultId: dataQueryResultId } : {}),
      ...(dataQueryLine > 0 ? { resultLine: dataQueryLine } : {}),
      ...(dataQueryOut ? { outputArtifact: dataQueryOut } : {}),
      ...(dataQueryDuckdb ? { duckdbPath: dataQueryDuckdb } : {}),
      includeScript: dataQueryIncludeScript,
      inspectOnly: dataQueryInspect,
    });

    const outputIsJson = dataQueryFormat === "json" || dataQueryInspect;
    const output = outputIsJson ? JSON.stringify(result, null, 2) + "\n" : result.orgTable || "";
    if (result.ok && dataQueryApply) {
      const sourcePath = path.resolve(dataQueryFile);
      const applied = applyDataQueryResult(input, result);
      if (applied.changed) fs.writeFileSync(sourcePath, applied.text, "utf8");
      if (outputIsJson) {
        process.stdout.write(JSON.stringify({ ...result, applied: true, changed: applied.changed, file: sourcePath }, null, 2) + "\n");
      } else {
        process.stdout.write(`${applied.changed ? "Updated" : "Unchanged"} ${dataQueryFile}\n`);
      }
    } else if (result.ok && dataQueryOut) {
      const outputPath = path.resolve(dataQueryOut);
      fs.mkdirSync(path.dirname(outputPath), { recursive: true });
      fs.writeFileSync(outputPath, output, "utf8");
      if (!outputIsJson) process.stdout.write(`Wrote org table to ${dataQueryOut}\n`);
    } else if (outputIsJson) {
      process.stdout.write(output);
    } else if (result.ok) {
      process.stdout.write(output);
    } else {
      for (const item of result.diagnostics) {
        const where = item.source?.line ? `:${item.source.line}` : "";
        console.error(`${item.severity}: ${item.message}${where}`);
      }
    }

    if (!result.ok) process.exit(1);
    return;
  }

  if (command === "brief") {
    if (!briefAction) { console.error("Error: celorga brief requires a subcommand (today, project, or node)"); process.exit(1); }
    if (briefAction === "project" && !briefName.trim()) { console.error("Error: celorga brief project requires a project name"); process.exit(1); }
    if (briefAction === "node" && !agentId.trim()) { console.error("Error: celorga brief node requires --id ID"); process.exit(1); }
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try { const config = loadConfig(configPath); const configDir = path.dirname(configPath); files = resolveFilesFromConfig(config, configDir); if (files.length === 0) { console.error(`Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`); process.exit(1); } dir = configDir; }
        catch (err) { console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`); process.exit(1); }
      } else { console.error("Error: provide either --dir, --files, --file, or celorga.json config for celorga brief"); process.exit(1); }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);
    files = Array.from(new Set(files)).sort((a, b) => a.localeCompare(b));
    if (files.length === 0) { console.error("Error: no Org files found for celorga brief"); process.exit(1); }
    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const include = Array.from(new Set((agentIncludeRaw || "sources,backlinks").split(",").map((value) => value.trim().toLowerCase()).filter((value): value is AgentInclude => value === "sources" || value === "backlinks" || value === "neighbors")));
    const today = brandEnv("ORG2_TODAY") || new Date().toISOString().slice(0, 10);
    const query = agentQuery || (briefAction === "today" ? today : briefName);
    const scope = agentScope || (briefAction === "project" ? `project:${briefName}` : "");
    const corpus = compileCorpusIncremental(files, {
      rootDir,
      cacheFile: defaultCorpusCachePath(rootDir),
    });
    const recencyWeight = parseAgentRankingWeight(agentRecencyWeightRaw, "--recency-weight");
    const salienceWeight = parseAgentRankingWeight(agentSalienceWeightRaw, "--salience-weight");
    const payload = briefAction === "node"
      ? buildAgentContextPayload(corpus, { action: "fetch", id: agentId, limit: 1, maxChars: parseBudgetToChars(agentMaxCharsRaw), include: ["sources", "backlinks", "neighbors"], recencyWeight, salienceWeight })
      : buildAgentContextPayload(corpus, { action: "bundle", query, limit: Number.parseInt(agentLimitRaw, 10) || 10, maxChars: parseBudgetToChars(agentMaxCharsRaw), include, scope, since: agentSince, sourceType: agentSourceType, reviewStatus: agentReviewStatus, recencyWeight, salienceWeight });
    const title = briefAction === "today"
      ? `Celorga Briefing: Today (${today})`
      : briefAction === "node"
        ? `Celorga Briefing: Node ${payload.results[0]?.title || agentId}`
        : `Celorga Briefing: Project ${briefName}`;
    const rendered = contextFormat === "json"
      ? JSON.stringify(payload, null, 2) + "\n"
      : (briefAction === "node" ? renderNodeBriefing(payload, title, contextFormat) : renderBriefing(payload, title, contextFormat)) + "\n";
    if (briefOut) { fs.mkdirSync(path.dirname(path.resolve(briefOut)), { recursive: true }); fs.writeFileSync(briefOut, rendered, "utf8"); process.stdout.write(`Wrote briefing to ${briefOut}\n`); }
    else process.stdout.write(rendered);
    return;
  }

  if (command === "agent" || command === "context") {
    if (command === "context") agentAction = agentId.trim() ? "fetch" : "bundle";
    if (!agentAction) { console.error("Error: celorga agent requires a subcommand (capabilities, bundle, context, search, or fetch)"); process.exit(1); }
    if (agentAction === "capabilities") {
      process.stdout.write(JSON.stringify(buildOrg2CapabilityManifest(), null, 2) + "\n");
      return;
    }
    if (command === "context" && agentQuery.trim() && agentId.trim()) { console.error("Error: celorga context accepts either QUERY/--query or --id ID, not both"); process.exit(1); }
    if ((agentAction === "bundle" || agentAction === "context" || agentAction === "search") && !agentQuery.trim()) {
      console.error(command === "context" ? "Error: celorga context requires QUERY/--query or --id ID" : "Error: celorga agent/context requires --query QUERY");
      process.exit(1);
    }
    if (agentAction === "fetch" && !agentId.trim()) { console.error("Error: celorga agent fetch requires --id ID"); process.exit(1); }
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try { const config = loadConfig(configPath); const configDir = path.dirname(configPath); files = resolveFilesFromConfig(config, configDir); if (files.length === 0) { console.error(`Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`); process.exit(1); } dir = configDir; }
        catch (err) { console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`); process.exit(1); }
      } else { console.error("Error: provide either --dir, --files, --file, or celorga.json config for celorga agent/context"); process.exit(1); }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);
    files = Array.from(new Set(files)).sort((a, b) => a.localeCompare(b));
    if (files.length === 0) { console.error("Error: no Org files found for celorga agent/context retrieval"); process.exit(1); }
    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const include = Array.from(new Set(agentIncludeRaw.split(",").map((value) => value.trim().toLowerCase()).filter((value): value is AgentInclude => value === "sources" || value === "backlinks" || value === "neighbors")));
    const corpus = compileCorpusIncremental(files, {
      rootDir,
      cacheFile: defaultCorpusCachePath(rootDir),
    });
    const recencyWeight = parseAgentRankingWeight(agentRecencyWeightRaw, "--recency-weight");
    const salienceWeight = parseAgentRankingWeight(agentSalienceWeightRaw, "--salience-weight");
    const payload = buildAgentContextPayload(corpus, { action: agentAction, query: agentQuery, id: agentId, limit: Number.parseInt(agentLimitRaw, 10) || 10, maxChars: parseBudgetToChars(agentMaxCharsRaw), include, scope: agentScope, since: agentSince, sourceType: agentSourceType, reviewStatus: agentReviewStatus, recencyWeight, salienceWeight });
    if (command === "context" && contextFormat !== "json") process.stdout.write(renderAgentContextPack(payload, contextFormat) + "\n");
    else process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
    return;
  }

  if (command === "ai") {
    if (!aiAction) {
      console.error("Error: celorga ai requires a subcommand (validate-job, run, review, suggest-links, or promote)");
      process.exit(1);
    }

    if (aiAction === "review") {
      let reviewFiles = files.length > 0 ? files.map((file) => path.resolve(file)) : [];
      if (dir) reviewFiles = listOrgLikeFiles(dir, recursive, includeArchives);
      if (aiPromoteFile && aiReviewStatus) {
        const reviewPath = path.resolve(aiPromoteFile);
        const raw = fs.readFileSync(reviewPath, "utf8").replace(/\r\n/g, "\n");
        const updated = updateArtifactReviewStatusInText(raw, aiReviewStatus);
        if (!aiApply) {
          if (aiFormat === "json") {
            console.log(JSON.stringify({ $schema: "org2:ai-review:v1", file: aiPromoteFile, applied: false, status: aiReviewStatus }, null, 2));
          } else {
            process.stdout.write(`Would mark ${aiPromoteFile} as ${aiReviewStatus}. Use --apply to write changes.\n`);
          }
          return;
        }
        fs.writeFileSync(reviewPath, updated, "utf8");
        if (aiFormat === "json") {
          console.log(JSON.stringify({ $schema: "org2:ai-review:v1", file: aiPromoteFile, applied: true, status: aiReviewStatus }, null, 2));
        } else {
          process.stdout.write(`Marked ${aiPromoteFile} as ${aiReviewStatus}\n`);
        }
        return;
      }

      if (reviewFiles.length === 0) {
        console.error("Error: celorga ai review requires --dir DIR or --files FILE... to list, or --file DRAFT --status reviewed|rejected|deferred to update");
        process.exit(1);
      }
      const queue = collectAiReviewQueue(reviewFiles);
      if (aiFormat === "json") {
        console.log(JSON.stringify({ $schema: "org2:ai-review-queue:v1", count: queue.length, items: queue }, null, 2));
      } else if (queue.length === 0) {
        process.stdout.write("No generated artifacts pending review.\n");
      } else {
        for (const item of queue) {
          process.stdout.write(`${item.file} [${item.status}] ${item.title}\n`);
          if (item.jobId) process.stdout.write(`  job: ${item.jobId}${item.task ? ` (${item.task})` : ""}\n`);
          if (item.sources.length > 0) process.stdout.write(`  sources: ${item.sources.join(", ")}\n`);
          if (item.todos.length > 0) process.stdout.write(`  todos: ${item.todos.join("; ")}\n`);
        }
      }
      return;
    }

    if (aiAction === "promote") {
      if (!aiPromoteFile) {
        console.error("Error: celorga ai promote requires --file DRAFT");
        process.exit(1);
      }
      if (!aiPromoteToFile) {
        console.error("Error: celorga ai promote requires --to-file NOTE");
        process.exit(1);
      }

      const draftPath = path.resolve(aiPromoteFile);
      const toPath = path.resolve(aiPromoteToFile);
      const draftText = fs.readFileSync(draftPath, "utf8").replace(/\r\n/g, "\n");
      if (!hasReviewedArtifactStatus(draftText)) {
        const message = "generated artifact must have ORG2_REVIEW_STATUS reviewed before promotion";
        if (aiFormat === "json") {
          console.log(JSON.stringify({ $schema: "org2:ai-promote:v1", source: aiPromoteFile, target: aiPromoteToFile, applied: false, valid: false, issues: [{ message }] }, null, 2));
        } else {
          console.error(`Error: ${message}`);
        }
        process.exit(1);
      }

      const promotedBody = removeTopPropertyDrawer(draftText);
      if (!aiApply) {
        if (aiFormat === "json") {
          console.log(JSON.stringify({ $schema: "org2:ai-promote:v1", source: aiPromoteFile, target: aiPromoteToFile, applied: false, preview: promotedBody }, null, 2));
        } else {
          process.stdout.write(`Would append reviewed artifact body from ${aiPromoteFile} to ${aiPromoteToFile}.\nUse --apply to write changes.\n\n${promotedBody}`);
        }
        return;
      }

      const existing = fs.existsSync(toPath) ? fs.readFileSync(toPath, "utf8").replace(/\r\n/g, "\n").trimEnd() : "";
      fs.mkdirSync(path.dirname(toPath), { recursive: true });
      fs.writeFileSync(toPath, `${existing}${existing ? "\n\n" : ""}${promotedBody.trimEnd()}\n`, "utf8");
      fs.writeFileSync(draftPath, markArtifactPromoted(draftText), "utf8");
      if (aiFormat === "json") {
        console.log(JSON.stringify({ $schema: "org2:ai-promote:v1", source: aiPromoteFile, target: aiPromoteToFile, applied: true }, null, 2));
      } else {
        process.stdout.write(`Promoted reviewed artifact to ${aiPromoteToFile}\n`);
      }
      return;
    }

    if (aiAction === "suggest-links") {
      if (!dir) {
        console.error("Error: celorga ai suggest-links requires --dir DIR");
        process.exit(1);
      }
      const report = await buildAiLinkSuggestionReport({ dir, recursive, targetFiles: files, out: aiOut || undefined });
      if (aiApply) {
        if (!aiOut) {
          console.error("Error: celorga ai suggest-links --apply requires --out FILE; canonical notes are never edited directly");
          process.exit(1);
        }
        const outputPath = resolveWorkspaceRelative(process.cwd(), aiOut, "--out");
        fs.mkdirSync(path.dirname(outputPath), { recursive: true });
        const writtenReport = { ...report, applied: true, output: aiOut };
        fs.writeFileSync(outputPath, aiFormat === "json" ? JSON.stringify(writtenReport, null, 2) + "\n" : renderAiLinkSuggestionReportText(report), "utf8");
        if (aiFormat === "json") {
          console.log(JSON.stringify(writtenReport, null, 2));
        } else {
          process.stdout.write(`Wrote review-only AI link/entity suggestion report to ${aiOut}\n`);
        }
        return;
      }
      if (aiFormat === "json") {
        console.log(JSON.stringify(report, null, 2));
      } else {
        process.stdout.write(renderAiLinkSuggestionReportText(report));
      }
      return;
    }

    if (!aiJobFile && !(aiAction === "run" && aiTask && files.length > 0)) {
      console.error(`Error: celorga ai ${aiAction} requires --job FILE${aiAction === "run" ? " or --task TASK --file FILE" : ""}`);
      process.exit(1);
    }

    let manifest: unknown;
    if (aiJobFile) {
      try {
        manifest = loadAiJobManifest(aiJobFile);
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        if (aiFormat === "json") {
          console.log(JSON.stringify({ $schema: "org2:ai-job-validation:v1", job: aiJobFile, valid: false, issues: [{ path: "$", message }] }, null, 2));
        } else {
          console.error(`Error: ${message}`);
        }
        process.exit(1);
      }
    } else {
      manifest = {
        schemaVersion: "org2-ai-job/v1",
        id: `inline-${aiTask.replace(/[^a-z0-9_.-]+/gi, "-").replace(/^-+|-+$/g, "") || "ai-run"}`,
        description: `Inline ${aiTask} AI draft run`,
        input: { files },
        task: {
          type: aiTask,
          template: aiTask === "summarize-meeting" ? "meeting-summary@v1" : aiTask,
          instructions: aiTask === "summarize-meeting"
            ? "Summarize the meeting into a concise brief with key decisions, action items, entities, suggested links, and source citations."
            : `Run ${aiTask} on the supplied Celorga source files.`,
        },
        adapter: { name: "local-test", model: aiTask === "summarize-meeting" ? "deterministic-meeting-summary" : "deterministic-fixture" },
        output: { target: aiOut ? "views" : "stdout", path: aiOut || undefined },
        provenance: { requireSourceRefs: true, promptTemplateVersion: aiTask === "summarize-meeting" ? "meeting-summary@v1" : aiTask, recordModelMetadata: true, recordGeneratedAt: true },
        review: { policy: "require-approval", reviewer: "human" },
      };
    }

    const validation = validateAiJobManifest(manifest);
    if (aiAction === "validate-job") {
      if (aiFormat === "json") {
        console.log(JSON.stringify({ $schema: "org2:ai-job-validation:v1", job: aiJobFile, ...validation }, null, 2));
      } else if (validation.valid) {
        console.log(`AI job manifest OK: ${aiJobFile}`);
      } else {
        console.error(`AI job manifest invalid: ${aiJobFile}`);
        for (const issue of validation.issues) {
          console.error(`- ${issue.path}: ${issue.message}`);
        }
      }
      process.exit(validation.valid ? 0 : 1);
    }

    if (!validation.valid) {
      if (aiFormat === "json") {
        console.log(JSON.stringify({ $schema: "org2:ai-run:v1", job: aiJobFile, valid: false, applied: false, issues: validation.issues }, null, 2));
      } else {
        console.error(`AI job manifest invalid: ${aiJobFile}`);
        for (const issue of validation.issues) {
          console.error(`- ${issue.path}: ${issue.message}`);
        }
      }
      process.exit(1);
    }

    if (aiAction === "run") {
      if (!isPlainRecord(manifest)) {
        console.error("Error: AI job manifest must be an object");
        process.exit(1);
      }
      const workspaceDir = process.cwd();
      const output = nestedRecord(manifest, "output");
      const outputTarget = stringField(output, "target") || "stdout";
      const manifestOutputPath = stringField(output, "path");
      const outputPathRaw = aiOut || manifestOutputPath;
      const outputPath = outputPathRaw ? resolveWorkspaceRelative(workspaceDir, outputPathRaw, "output.path") : "";
      const sources = readAiDraftSources(manifest, workspaceDir);
      const adapterResponse = await generateAiDraftResponse(manifest, sources);
      const artifactText = renderAiGeneratedDraft(manifest, sources, outputPathRaw || "stdout.org", adapterResponse);

      if (outputTarget === "stdout" && !aiOut) {
        if (aiFormat === "json") {
          console.log(JSON.stringify({ $schema: "org2:ai-run:v1", job: aiJobFile, target: "stdout", applied: false, artifact: artifactText }, null, 2));
        } else {
          process.stdout.write(artifactText);
        }
        return;
      }

      if (!outputPath) {
        console.error("Error: celorga ai run requires manifest output.path or --out FILE for non-stdout outputs");
        process.exit(1);
      }

      if (!aiApply) {
        if (aiFormat === "json") {
          console.log(JSON.stringify({ $schema: "org2:ai-run:v1", job: aiJobFile, output: outputPathRaw, applied: false, artifact: artifactText }, null, 2));
        } else {
          process.stdout.write(`Would write generated draft artifact to ${outputPathRaw}.\nUse --apply to write changes.\n\n${artifactText}`);
        }
        return;
      }

      fs.mkdirSync(path.dirname(outputPath), { recursive: true });
      fs.writeFileSync(outputPath, artifactText, "utf8");
      if (aiFormat === "json") {
        console.log(JSON.stringify({ $schema: "org2:ai-run:v1", job: aiJobFile, output: outputPathRaw, applied: true, bytes: Buffer.byteLength(artifactText) }, null, 2));
      } else {
        process.stdout.write(`${outputPath}\n`);
      }
      return;
    }

    console.error("Error: celorga ai requires a subcommand (validate-job, run, review, suggest-links, or promote)");
    process.exit(1);
  }

  // Treat `celorga roam backlinks ...` as a namespaced alias for `celorga backlinks ...`.
  // This lets editor integrations stay under `roam` while sharing the same implementation.
  if (command === "roam" && roamAction === "backlinks") {
    command = "backlinks";
  }

  if (command === "roam") {
    if (roamAction !== "link" && !dir) {
      console.error("Error: celorga roam requires --dir DIR");
      process.exit(1);
    }

    if (roamAction === "link") {
      if (roamLinkAction !== "insert-backlink") {
        console.error("Error: celorga roam link requires a subcommand (insert-backlink)");
        process.exit(1);
      }
      if (!roamLinkFile) {
        console.error("Error: celorga roam link insert-backlink requires --file FILE");
        process.exit(1);
      }
      if (!roamLinkPos) {
        console.error("Error: celorga roam link insert-backlink requires --pos LINE[:COL]");
        process.exit(1);
      }
      if (!roamLinkTitle) {
        console.error("Error: celorga roam link insert-backlink requires --title TITLE");
        process.exit(1);
      }
      if (roamLinkStyle === "id" && !roamLinkId) {
        console.error("Error: celorga roam link insert-backlink with --style id requires --id UUID");
        process.exit(1);
      }

      const raw = fs.readFileSync(roamLinkFile, "utf8");
      const linkText = renderRoamLink(roamLinkTitle, { style: roamLinkStyle, id: roamLinkId || null });
      let outText = raw.replace(/\r\n/g, "\n");
      let changed = false;
      try {
        const result = insertTextAtLinePosition(raw, roamLinkPos, linkText);
        outText = result.outText;
        changed = result.changed;
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        console.error(`Error: ${msg}`);
        process.exit(1);
      }

      if (roamApply) {
        fs.writeFileSync(roamLinkFile, outText, "utf8");
      }

      if (roamFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              action: "link-insert-backlink",
              file: roamLinkFile,
              id: roamLinkId || null,
              title: roamLinkTitle,
              style: roamLinkStyle,
              link: linkText,
              pos: roamLinkPos,
              applied: roamApply,
              changed,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(outText + (outText.endsWith("\n") ? "" : "\n"));
      }

      return;
    }

    if (roamAction === "node") {
      if (roamNodeAction !== "new") {
        console.error("Error: celorga roam node requires a subcommand (new)");
        process.exit(1);
      }

      if (!roamTitle) {
        console.error("Error: celorga roam node new requires --title TITLE");
        process.exit(1);
      }

      const slugify = (s: string): string => {
        return s
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+/, "")
          .replace(/-+$/, "")
          .replace(/-+/g, "-")
          .slice(0, 80);
      };

      const slug = slugify(roamTitle) || "node";
      const filePath = path.join(dir, `${slug}.org`);
      const newId = roamIdForced || crypto.randomUUID();

      const content = `#+TITLE: ${roamTitle}\n\n:PROPERTIES:\n:ID: ${newId}\n:END:\n\n`;

      if (roamApply) {
        // Make this command idempotent so it can be safely re-run.
        // If the file exists and already matches, treat as success.
        if (fs.existsSync(filePath)) {
          const existing = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
          if (existing !== content) {
            console.error(`Error: file already exists with different contents: ${filePath}`);
            process.exit(1);
          }
        } else {
          fs.mkdirSync(dir, { recursive: true });
          fs.writeFileSync(filePath, content, "utf8");
        }
      } else {
        console.error("Error: celorga roam node new is mutating; pass --apply to write the file");
        process.exit(1);
      }

      if (roamFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              action: "node-new",
              dir,
              title: roamTitle,
              file: filePath,
              id: newId,
              applied: true,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(filePath + "\n");
      }

      return;
    }


    if (roamAction === "linkify") {
      const explicitTargetFiles = roamLinkifyFile ? [roamLinkifyFile] : files;
      const allFilesUnfiltered = explicitTargetFiles.length > 0
        ? Array.from(new Set([...listOrgLikeFiles(dir, recursive, includeArchives), ...explicitTargetFiles.map((file) => path.resolve(file))]))
        : listOrgLikeFiles(dir, recursive, includeArchives);
      const allFiles = filterRoamLinkifyFiles(allFilesUnfiltered, dir, roamLinkifyExcludes);
      const labelIndex = buildRoamLinkifyIndex(allFiles);
      const targetFiles = explicitTargetFiles.length > 0
        ? filterRoamLinkifyFiles(explicitTargetFiles.map((file) => path.resolve(file)), dir, roamLinkifyExcludes)
        : allFiles;
      const results: RoamLinkifyFileResult[] = [];
      let appliedCount = 0;
      let skippedUnreadable = 0;

      for (const filePath of targetFiles) {
        let raw: string;
        try {
          raw = fs.readFileSync(filePath, "utf8");
        } catch {
          skippedUnreadable += 1;
          continue;
        }

        const result = applyRoamLinkifyToFile(raw, filePath, labelIndex);
        results.push(result);
        if (!result.changed) continue;

        if (roamApply) {
          fs.writeFileSync(filePath, result.outText, "utf8");
          appliedCount += 1;
        }
      }

      const changedFiles = results.filter((result) => result.changed);
      const replacementCount = results.reduce((sum, result) => sum + result.replacements, 0);
      const ambiguousSkipCount = results.reduce((sum, result) => sum + result.ambiguousSkips, 0);
      const representedSuggestionCount = results.reduce((sum, result) => sum + result.representedSuggestions, 0);

      if (roamFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              action: "linkify",
              dir,
              recursive,
              scanned: targetFiles.length,
              indexFileCount: allFiles.length,
              excludedFileCount: allFilesUnfiltered.length - allFiles.length,
              skippedUnreadable,
              candidateLabelCount: labelIndex.size,
              changedFileCount: changedFiles.length,
              replacementCount,
              ambiguousSkipCount,
              representedSuggestionCount,
              applied: roamApply,
              appliedCount,
              files: results
                .map((result) => ({
                  file: result.file,
                  changed: result.changed,
                  replacements: result.replacements,
                  ambiguousSkips: result.ambiguousSkips,
                  representedSuggestions: result.representedSuggestions,
                  debugMatches: result.debugMatches,
                  debugAmbiguous: result.debugAmbiguous,
                  debugRepresented: result.debugRepresented,
                })),
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        for (const result of changedFiles) {
          process.stdout.write(`${result.file}\t${result.replacements}\n`);
        }
        console.error(
          `celorga roam linkify: scanned ${targetFiles.length} target file(s) from ${allFiles.length} indexed file(s)` +
            (allFilesUnfiltered.length > allFiles.length ? `; excluded ${allFilesUnfiltered.length - allFiles.length} file(s)` : "") +
            `; ${changedFiles.length} file(s) changed; ` +
            `${replacementCount} link(s) inserted; ` +
            `${ambiguousSkipCount} ambiguous match(es) skipped; ` +
            `${representedSuggestionCount} represented-node suggestion(s)` +
            (roamApply ? `; wrote ${appliedCount} file(s)` : ""),
        );
      }

      return;
    }

    if (roamAction === "graph") {
      const allFiles = files.length > 0 ? files.map((file) => path.resolve(file)) : listOrgLikeFiles(dir, recursive, includeArchives);
      const graph = buildRoamGraph(allFiles);
      const outputPath = path.resolve(roamGraphOut || path.join(dir, "org2-roam-graph.html"));

      if (roamFormat === "json") {
        const maintenance = buildRoamGraphMaintenanceReport(allFiles, graph, {
          includeLinkifySuggestions: true,
        });
        process.stdout.write(
          JSON.stringify(
            {
              action: "graph",
              dir,
              recursive,
              scanned: allFiles.length,
              output: outputPath,
              nodeCount: graph.nodes.length,
              edgeCount: graph.edges.length,
              nodes: graph.nodes,
              edges: graph.edges,
              maintenance,
            },
            null,
            2,
          ) + "\n",
        );
      } else if (roamFormat === "report") {
        const maintenance = buildRoamGraphMaintenanceReport(allFiles, graph, {
          includeLinkifySuggestions: true,
        });
        const reportText = renderRoamGraphReportText(maintenance);
        if (roamGraphOut) {
          fs.mkdirSync(path.dirname(outputPath), { recursive: true });
          fs.writeFileSync(outputPath, reportText, "utf8");
          process.stdout.write(outputPath + "\n");
        } else {
          process.stdout.write(reportText);
        }
      } else {
        const html = renderRoamGraphHtml(graph, { title: "Celorga Roam Graph", dir });
        fs.mkdirSync(path.dirname(outputPath), { recursive: true });
        fs.writeFileSync(outputPath, html, "utf8");
        process.stdout.write(outputPath + "\n");
      }

      return;
    }

    const hasFileId = (text: string): boolean => {
      const norm = text.replace(/\r\n/g, "\n");
      const top = norm.split("\n").slice(0, 80);

      // Accept a #+id keyword anywhere near the top (read-only compat).
      for (const l of top) {
        if (/^#\+id:\s*\S+/i.test(l.trim())) return true;
      }

      let i = 0;
      while (i < top.length && (top[i] ?? "").trim() === "") i += 1;
      if ((top[i] ?? "").trim() !== ":PROPERTIES:") return false;

      for (let j = i + 1; j < top.length; j += 1) {
        const l = (top[j] ?? "").trim();
        if (l === ":END:") break;
        if (/^:ID:\s*\S+/.test(l)) return true;
      }

      return false;
    };

    const allFiles = listOrgLikeFiles(dir, recursive, includeArchives);
    const missing: string[] = [];

    for (const filePath of allFiles) {
      try {
        const raw = fs.readFileSync(filePath, "utf8");
        if (!hasFileId(raw)) missing.push(filePath);
      } catch {
        // ignore unreadable
      }
    }

    let applied = 0;
    if (roamApply) {
      for (const filePath of missing) {
        try {
          const raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
          // Double-check before mutating.
          if (hasFileId(raw)) continue;

          const newId = crypto.randomUUID();
          const header = `:PROPERTIES:\n:ID: ${newId}\n:END:\n\n`;
          const out = header + raw.replace(/^\n+/, "");
          fs.writeFileSync(filePath, out, "utf8");
          applied += 1;
        } catch {
          // ignore write errors
        }
      }
    }

    if (roamFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            action: "db-sync",
            dir,
            recursive,
            scanned: allFiles.length,
            missingFileIdCount: missing.length,
            missingFileIds: missing,
            applied: roamApply,
            appliedCount: applied,
          },
          null,
          2
        ) + "\n"
      );
    } else {
      for (const filePath of missing) {
        process.stdout.write(filePath + "\n");
      }
      console.error(
        `celorga roam db-sync: scanned ${allFiles.length} file(s); ${missing.length} missing file-level IDs` +
          (roamApply ? `; applied IDs to ${applied} file(s)` : "")
      );
    }

    return;
  }

  if (command === "publish") {
    const configPathResolved = publishConfigPath.trim().length > 0
      ? path.resolve(publishConfigPath.trim())
      : findConfigFile(process.cwd());
    if (!configPathResolved) {
      console.error("Error: publish requires a celorga.json config (pass --config PATH or run from a configured directory)");
      process.exit(1);
    }

    let project: Org2PublishProjectConfig | null = null;
    let projectNames: string[] = [];
    let configLinkAbbreviations: Record<string, string> | undefined;
    let configLinearTeam: string | undefined;
    try {
      const cfg = loadConfig(configPathResolved);
      configLinkAbbreviations = cfg.links?.abbreviations;
      configLinearTeam = cfg.links?.linearTeam;
      const projects = cfg.publish?.projects || {};
      projectNames = Object.keys(projects).sort((a, b) => a.localeCompare(b));
      if (!publishProject) {
        if (projectNames.length === 1) publishProject = projectNames[0]!;
        else {
          console.error(`Error: publish requires a project name${projectNames.length > 0 ? ` (available: ${projectNames.join(", ")})` : ""}`);
          process.exit(1);
        }
      }
      project = projects[publishProject] || null;
    } catch (err) {
      console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
      process.exit(1);
    }

    if (!project) {
      console.error(`Error: publish project \"${publishProject}\" not found in ${configPathResolved}${projectNames.length > 0 ? ` (available: ${projectNames.join(", ")})` : ""}`);
      process.exit(1);
    }

    const sourceDirValue = String(project.baseDir || "").trim();
    const outDirValue = String(project.outDir || "").trim();
    if (!sourceDirValue) {
      console.error(`Error: publish project \"${publishProject}\" is missing required field: baseDir`);
      process.exit(1);
    }
    if (!outDirValue) {
      console.error(`Error: publish project \"${publishProject}\" is missing required field: outDir`);
      process.exit(1);
    }

    const configDir = path.dirname(configPathResolved);
    const sourceDir = path.resolve(configDir, sourceDirValue);
    const outputRoot = path.resolve(configDir, outDirValue);
    const sourceDirInput = path.relative(process.cwd(), sourceDir) || sourceDir;
    const outputRootInput = path.relative(process.cwd(), outputRoot) || outputRoot;

    const includePatterns = Array.isArray(project.include) && project.include.length > 0 ? project.include : ["*.org", "*.org2"];
    const ignorePatterns = Array.isArray(project.ignore) ? project.ignore : [];
    const publishRecursive = project.recursive !== false;
    const sourceFiles = resolveFilesFromDir(sourceDir, includePatterns, ignorePatterns, publishRecursive).sort((a, b) => a.localeCompare(b));

    const toDisplayPath = (absolutePath: string): string => {
      const relative = path.relative(process.cwd(), absolutePath);
      if (!relative || (!relative.startsWith("..") && !path.isAbsolute(relative))) {
        return relative || path.basename(absolutePath);
      }
      return absolutePath;
    };

    const resolvedHeadIncludes = resolvePublishHeadIncludes(project);
    const ogBaseUrlRaw = String(project.sitemapXml?.baseUrl || "").trim();
    const ogBaseUrl = ogBaseUrlRaw ? ogBaseUrlRaw.replace(/\/$/, "") : "";
    const escapeHeadAttr = (value: string): string =>
      String(value || "")
        .replace(/&/g, "&amp;")
        .replace(/"/g, "&quot;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
    const htmlToPlainText = (value: string): string =>
      String(value || "")
        .replace(/<[^>]*>/g, " ")
        .replace(/&#(\d+);/g, (_match, rawCodePoint: string) => {
          const codePoint = Number.parseInt(rawCodePoint, 10);
          return Number.isFinite(codePoint) ? String.fromCodePoint(codePoint) : " ";
        })
        .replace(/&#x([0-9a-f]+);/gi, (_match, rawCodePoint: string) => {
          const codePoint = Number.parseInt(rawCodePoint, 16);
          return Number.isFinite(codePoint) ? String.fromCodePoint(codePoint) : " ";
        })
        .replace(/&(amp|quot|apos|lt|gt|nbsp);/g, (entity) => ({
          "&amp;": "&",
          "&quot;": '"',
          "&apos;": "'",
          "&lt;": "<",
          "&gt;": ">",
          "&nbsp;": " ",
        })[entity] || " ")
        .replace(/\s+/g, " ")
        .replace(/\s+([,.;:!?])/g, "$1")
        .trim();
    const firstParagraphText = (html: string): string => {
      const match = html.match(/<p(?:\s[^>]*)?>([\s\S]*?)<\/p>/i);
      return match ? htmlToPlainText(match[1] || "") : "";
    };
    const truncateMetadataText = (value: string, maxLength: number): string => {
      const normalized = String(value || "").replace(/\s+/g, " ").trim();
      if (normalized.length <= maxLength) return normalized;
      const shortened = normalized.slice(0, Math.max(0, maxLength - 1));
      const lastSpace = shortened.lastIndexOf(" ");
      return `${(lastSpace > maxLength * 0.6 ? shortened.slice(0, lastSpace) : shortened).trim()}…`;
    };
    const wrapOpenGraphText = (value: string, maxCharacters: number, maxLines: number): string[] => {
      const words = String(value || "").replace(/\s+/g, " ").trim().split(" ").filter(Boolean);
      const lines: string[] = [];
      for (const word of words) {
        const current = lines.at(-1);
        if (!current || (current.length + 1 + word.length > maxCharacters && lines.length < maxLines)) {
          lines.push(word);
        } else {
          lines[lines.length - 1] = `${current} ${word}`;
        }
      }
      if (lines.length > maxLines) {
        const overflow = lines.splice(maxLines - 1).join(" ");
        lines[maxLines - 1] = truncateMetadataText(overflow, maxCharacters);
      } else if (lines.length === maxLines && lines[maxLines - 1]!.length > maxCharacters) {
        lines[maxLines - 1] = truncateMetadataText(lines[maxLines - 1]!, maxCharacters);
      }
      return lines.length > 0 ? lines : [""];
    };
    const ogImageFormatRaw = String(project.openGraph?.imageFormat || "svg").trim().toLowerCase();
    if (ogImageFormatRaw !== "svg" && ogImageFormatRaw !== "png") {
      console.error(`Error: publish project "${publishProject}" openGraph.imageFormat must be "svg" or "png"`);
      process.exit(1);
    }
    const ogImageFormat = ogImageFormatRaw as "svg" | "png";
    const ogSiteName = String(project.openGraph?.siteName || "").trim();
    const ogLocale = String(project.openGraph?.locale || "").trim();
    // The social card header shows the configured site name and the site's host.
    const ogCardBrand = ogSiteName || "Celorga";
    const ogCardHost = (() => {
      try {
        return ogBaseUrlRaw ? new URL(ogBaseUrlRaw).host.toUpperCase() : "";
      } catch {
        return "";
      }
    })();
    let resvgModulePromise: Promise<typeof import("@resvg/resvg-js")> | null = null;
    const renderOpenGraphPng = async (svg: string): Promise<Buffer> => {
      resvgModulePromise ||= import("@resvg/resvg-js");
      const { Resvg } = await resvgModulePromise;
      const renderer = new Resvg(svg, {
        fitTo: { mode: "width", value: 1200 },
        font: { loadSystemFonts: true, defaultFontFamily: "Arial" },
      });
      return Buffer.from(renderer.render().asPng());
    };

    const exported: Array<{ sourcePath: string; outputPath: string; outputPathAbsolute: string; title: string; changed: boolean; metadata?: ExportMetadataPayload; }> = [];
    for (const sourcePath of sourceFiles) {
      const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
      const sourceAst = parseOrgToCanonicalAst(sourceRaw, { sourceRanges: true, sourcePath });
      const sourceCharts = embeddedChartsForSource(sourceRaw, sourcePath);
      const sourcePluginRenders = await pluginRendersForDocument(sourceAst, sourcePath);

      const relativeSourcePath = path.relative(sourceDir, sourcePath);
      const outputRelativePath = /\.(org|org2)$/i.test(relativeSourcePath)
        ? relativeSourcePath.replace(/\.(org|org2)$/i, ".html")
        : `${relativeSourcePath}.html`;

      const outputPathAbsolute = path.resolve(outputRoot, outputRelativePath);
      const outputPathDisplay = path.join(outputRootInput, outputRelativePath);
      const outputRelativePathPosix = outputRelativePath.split(path.sep).join("/");

      const firstPass = renderOrgDocumentToHtml(sourceAst, {
        sourcePath: toDisplayPath(sourcePath),
        stylesheets: project.stylesheets,
        includeDefaultStyle: project.includeDefaultStyle,
        includeToc: project.toc,
        includeTocDepth: project.tocDepth,
        includeHeadlineNumbers: project.numberHeadings,
        includeHeadlineNumberDepth: project.numberHeadingsDepth,
        rewriteFileLinks: project.rewriteFileLinks,
        preambleHtml: project.preambleHtml,
        postambleHtml: project.postambleHtml,
        headIncludes: resolvedHeadIncludes,
        includeDocumentHeader: true,
        compatContentWrapper: true,
        linkAbbreviations: configLinkAbbreviations,
        linearTeam: configLinearTeam,
        charts: sourceCharts,
        pluginRenders: sourcePluginRenders,
      });

      const ogSlug = outputRelativePathPosix
        .replace(/^\//, "")
        .replace(/\.html$/i, "")
        .replace(/\//g, "-") || "index";
      const ogRelPath = `assets/og/${ogSlug}.${ogImageFormat}`;
      const ogAbsPath = path.resolve(outputRoot, ogRelPath);
      const ogTitle = firstPass.title;
      const ogDescRaw = String(
        firstPass.metadata?.description
          || firstPass.metadata?.subtitle
          || firstParagraphText(firstPass.html)
          || firstPass.title
          || "Celorga docs",
      ).trim();
      const ogDesc = truncateMetadataText(ogDescRaw, 200);
      const titleLines = wrapOpenGraphText(ogTitle, 30, 2);
      const descriptionLines = wrapOpenGraphText(ogDesc, 62, 2);
      const titleStartY = titleLines.length === 1 ? 248 : 207;
      const descriptionStartY = titleStartY + titleLines.length * 68 + 29;
      const titleSvg = titleLines.map((line, index) =>
        `  <text x="104" y="${titleStartY + index * 68}" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="60" font-weight="500" letter-spacing="-2.7" fill="#18201e">${escapeHeadAttr(line)}</text>`,
      );
      const descriptionSvg = descriptionLines.map((line, index) =>
        `  <text x="104" y="${descriptionStartY + index * 38}" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="27" font-weight="400" letter-spacing="-0.3" fill="#5e6b66">${escapeHeadAttr(line)}</text>`,
      );

      // Keep social cards in the public site's "compiled paper" visual system.
      // These colors, type roles, and workflow cells mirror docs/site/assets/site.css.
      const ogSvg = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">',
        '  <defs>',
        '    <filter id="paper-shadow" x="-10%" y="-10%" width="120%" height="125%">',
        '      <feDropShadow dx="0" dy="12" stdDeviation="18" flood-color="#1d2b26" flood-opacity="0.075" />',
        '    </filter>',
        '  </defs>',
        '  <rect width="1200" height="630" fill="#f2f0e9" />',
        '  <rect x="35" y="31" width="1130" height="568" rx="10" fill="#fcfbf7" stroke="#d7d6ce" filter="url(#paper-shadow)" />',
        `  <text x="75" y="83" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="22" font-weight="600" letter-spacing="-0.35" fill="#18201e">${escapeHeadAttr(ogCardBrand)}</text>`,
        ogCardHost ? `  <text x="1125" y="82" text-anchor="end" font-family="SFMono-Regular,Menlo,Consolas,monospace" font-size="15" font-weight="600" letter-spacing="0.7" fill="#2854d7">${escapeHeadAttr(ogCardHost)}</text>` : "",
        '  <line x1="75" y1="111" x2="1125" y2="111" stroke="#d7d6ce" />',
        `  <text x="75" y="${titleStartY - 29}" font-family="SFMono-Regular,Menlo,Consolas,monospace" font-size="24" font-weight="600" fill="#c2472c">*</text>`,
        ...titleSvg,
        ...descriptionSvg,
        '  <rect x="75" y="469" width="1050" height="88" rx="8" fill="#fcfbf7" stroke="#d7d6ce" />',
        '  <line x1="337.5" y1="469" x2="337.5" y2="557" stroke="#d7d6ce" />',
        '  <line x1="600" y1="469" x2="600" y2="557" stroke="#d7d6ce" />',
        '  <line x1="862.5" y1="469" x2="862.5" y2="557" stroke="#d7d6ce" />',
        '  <circle cx="337.5" cy="490" r="4.5" fill="#2854d7" />',
        '  <circle cx="600" cy="490" r="4.5" fill="#2854d7" />',
        '  <circle cx="862.5" cy="490" r="4.5" fill="#2854d7" />',
        '  <text x="96" y="497" font-family="SFMono-Regular,Menlo,Consolas,monospace" font-size="14" font-weight="600" fill="#c2472c">01</text>',
        '  <text x="96" y="535" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="22" font-weight="500" letter-spacing="-0.35" fill="#18201e">Capture</text>',
        '  <text x="359" y="497" font-family="SFMono-Regular,Menlo,Consolas,monospace" font-size="14" font-weight="600" fill="#c2472c">02</text>',
        '  <text x="359" y="535" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="22" font-weight="500" letter-spacing="-0.35" fill="#18201e">Delegate</text>',
        '  <text x="621" y="497" font-family="SFMono-Regular,Menlo,Consolas,monospace" font-size="14" font-weight="600" fill="#c2472c">03</text>',
        '  <text x="621" y="535" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="22" font-weight="500" letter-spacing="-0.35" fill="#18201e">Review</text>',
        '  <text x="884" y="497" font-family="SFMono-Regular,Menlo,Consolas,monospace" font-size="14" font-weight="600" fill="#c2472c">04</text>',
        '  <text x="884" y="535" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-size="22" font-weight="500" letter-spacing="-0.35" fill="#18201e">Verify</text>',
        '</svg>',
        '',
      ].filter(Boolean).join("\n");

      const ogImageBytes = ogImageFormat === "png"
        ? await renderOpenGraphPng(ogSvg)
        : Buffer.from(ogSvg, "utf8");
      const existingOg = fs.existsSync(ogAbsPath) ? fs.readFileSync(ogAbsPath) : null;
      if (!publishPreview && (!existingOg || !existingOg.equals(ogImageBytes))) {
        fs.mkdirSync(path.dirname(ogAbsPath), { recursive: true });
        fs.writeFileSync(ogAbsPath, ogImageBytes);
      }

      const pageUrl = ogBaseUrl
        ? outputRelativePathPosix === "index.html" ? `${ogBaseUrl}/` : `${ogBaseUrl}/${outputRelativePathPosix}`
        : "";
      const ogImageUrl = ogBaseUrl ? `${ogBaseUrl}/${ogRelPath}` : ogRelPath;
      const ogImageType = ogImageFormat === "png" ? "image/png" : "image/svg+xml";
      // Join title and description without an em dash; a title that already
      // ends in punctuation is followed by a plain space.
      const ogImageAlt = truncateMetadataText(
        /[.!?:]$/.test(ogTitle) ? `${ogTitle} ${ogDesc}` : `${ogTitle}: ${ogDesc}`,
        300
      );
      const ogHeadIncludes = [
        !firstPass.metadata?.description ? `<meta name="description" content="${escapeHeadAttr(ogDesc)}" />` : "",
        pageUrl ? `<link rel="canonical" href="${escapeHeadAttr(pageUrl)}" />` : "",
        '<meta property="og:type" content="website" />',
        ogSiteName ? `<meta property="og:site_name" content="${escapeHeadAttr(ogSiteName)}" />` : "",
        ogLocale ? `<meta property="og:locale" content="${escapeHeadAttr(ogLocale)}" />` : "",
        `<meta property="og:title" content="${escapeHeadAttr(ogTitle)}" />`,
        `<meta property="og:description" content="${escapeHeadAttr(ogDesc)}" />`,
        pageUrl ? `<meta property="og:url" content="${escapeHeadAttr(pageUrl)}" />` : "",
        `<meta property="og:image" content="${escapeHeadAttr(ogImageUrl)}" />`,
        ogImageUrl.startsWith("https://") ? `<meta property="og:image:secure_url" content="${escapeHeadAttr(ogImageUrl)}" />` : "",
        `<meta property="og:image:type" content="${ogImageType}" />`,
        '<meta property="og:image:width" content="1200" />',
        '<meta property="og:image:height" content="630" />',
        `<meta property="og:image:alt" content="${escapeHeadAttr(ogImageAlt)}" />`,
        '<meta name="twitter:card" content="summary_large_image" />',
        `<meta name="twitter:title" content="${escapeHeadAttr(ogTitle)}" />`,
        `<meta name="twitter:description" content="${escapeHeadAttr(ogDesc)}" />`,
        pageUrl ? `<meta name="twitter:url" content="${escapeHeadAttr(pageUrl)}" />` : "",
        `<meta name="twitter:image" content="${escapeHeadAttr(ogImageUrl)}" />`,
        `<meta name="twitter:image:alt" content="${escapeHeadAttr(ogImageAlt)}" />`,
      ].filter((item) => String(item || "").trim().length > 0);

      const rendered = renderOrgDocumentToHtml(sourceAst, {
        sourcePath: toDisplayPath(sourcePath),
        stylesheets: project.stylesheets,
        includeDefaultStyle: project.includeDefaultStyle,
        includeToc: project.toc,
        includeTocDepth: project.tocDepth,
        includeHeadlineNumbers: project.numberHeadings,
        includeHeadlineNumberDepth: project.numberHeadingsDepth,
        rewriteFileLinks: project.rewriteFileLinks,
        preambleHtml: project.preambleHtml,
        postambleHtml: project.postambleHtml,
        headIncludes: [...resolvedHeadIncludes, ...ogHeadIncludes],
        includeDocumentHeader: true,
        compatContentWrapper: true,
        linkAbbreviations: configLinkAbbreviations,
        linearTeam: configLinearTeam,
        charts: sourceCharts,
        pluginRenders: sourcePluginRenders,
      });

      const existingOutput = fs.existsSync(outputPathAbsolute)
        ? fs.readFileSync(outputPathAbsolute, "utf8").replace(/\r\n/g, "\n")
        : "";
      const changed = existingOutput !== rendered.html;

      if (!publishPreview) {
        fs.mkdirSync(path.dirname(outputPathAbsolute), { recursive: true });
        fs.writeFileSync(outputPathAbsolute, rendered.html, "utf8");
      }

      exported.push({
        sourcePath: toDisplayPath(sourcePath),
        outputPath: outputPathDisplay,
        outputPathAbsolute,
        title: rendered.title,
        changed,
        ...(hasExportMetadata(rendered.metadata) ? { metadata: rendered.metadata } : {}),
      });
    }

    const exportedForOutput = exported.map(({ sourcePath, outputPath, title, changed, metadata }) => ({
      sourcePath,
      outputPath,
      title,
      changed,
      ...(hasExportMetadata(metadata) ? { metadata } : {}),
    }));

    let indexOutput: { outputPath: string; title: string; changed: boolean } | null = null;
    let sitemapXmlOutput: { outputPath: string; urlCount: number; changed: boolean } | null = null;
    let indexPathRaw = "";
    let indexTitleRaw = "";
    if (typeof project.index === "string") indexPathRaw = project.index;
    else if (project.index && typeof project.index === "object") {
      indexPathRaw = String(project.index.file || "").trim();
      indexTitleRaw = String(project.index.title || "").trim();
    }

    if (indexPathRaw) {
      const indexPathAbsolute = path.isAbsolute(indexPathRaw) ? path.resolve(indexPathRaw) : path.resolve(outputRoot, indexPathRaw);
      const indexPathDisplay = path.isAbsolute(indexPathRaw) ? toDisplayPath(indexPathAbsolute) : path.join(outputRootInput, indexPathRaw);
      const indexRendered = renderOrgExportIndexToHtml({
        title: indexTitleRaw || undefined,
        sourcePath: indexPathRaw,
        stylesheets: project.stylesheets,
        headIncludes: project.headIncludes,
        includeDefaultStyle: project.includeDefaultStyle,
        items: exported.map((item) => {
          const hrefRaw = path.relative(path.dirname(indexPathAbsolute), item.outputPathAbsolute);
          const href = String(hrefRaw || path.basename(item.outputPathAbsolute)).split(path.sep).join("/");
          return { title: item.title, href };
        }),
      });

      const existingIndex = fs.existsSync(indexPathAbsolute)
        ? fs.readFileSync(indexPathAbsolute, "utf8").replace(/\r\n/g, "\n")
        : "";
      const indexChanged = existingIndex !== indexRendered.html;

      if (!publishPreview) {
        fs.mkdirSync(path.dirname(indexPathAbsolute), { recursive: true });
        fs.writeFileSync(indexPathAbsolute, indexRendered.html, "utf8");
      }

      indexOutput = { outputPath: indexPathDisplay, title: indexRendered.title, changed: indexChanged };
    }

    if (project.sitemapXml) {
      const baseUrlRaw = String(project.sitemapXml.baseUrl || "").trim();
      if (!baseUrlRaw) {
        console.error(`Error: publish project "${publishProject}" sitemapXml.baseUrl is required when sitemapXml is configured`);
        process.exit(1);
      }

      const baseUrl = baseUrlRaw.replace(/\/$/, "");
      const sitemapFileRaw = String(project.sitemapXml.file || "sitemap.xml").trim() || "sitemap.xml";
      const sitemapPathAbsolute = path.isAbsolute(sitemapFileRaw)
        ? path.resolve(sitemapFileRaw)
        : path.resolve(outputRoot, sitemapFileRaw);
      const sitemapPathDisplay = path.isAbsolute(sitemapFileRaw)
        ? toDisplayPath(sitemapPathAbsolute)
        : path.join(outputRootInput, sitemapFileRaw);

      const includeIndexPage = project.sitemapXml.includeIndexPage !== false;
      const urlEntries: string[] = [];
      if (includeIndexPage) {
        urlEntries.push(`${baseUrl}/`);
      }
      for (const item of exported) {
        const rel = path.relative(outputRoot, item.outputPathAbsolute).split(path.sep).join("/");
        const relWithoutDot = rel.startsWith("./") ? rel.slice(2) : rel;
        if (includeIndexPage && relWithoutDot === "index.html") continue;
        urlEntries.push(`${baseUrl}/${relWithoutDot}`);
      }

      const uniqueUrls = Array.from(new Set(urlEntries));
      const sitemapXml = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
        ...uniqueUrls.map((url) => {
          const escapedUrl = url
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/\"/g, "&quot;")
            .replace(/'/g, "&#39;");
          return `  <url>\n    <loc>${escapedUrl}</loc>\n  </url>`;
        }),
        '</urlset>',
        '',
      ].join("\n");

      const existingSitemap = fs.existsSync(sitemapPathAbsolute)
        ? fs.readFileSync(sitemapPathAbsolute, "utf8").replace(/\r\n/g, "\n")
        : "";
      const sitemapChanged = existingSitemap !== sitemapXml;

      if (!publishPreview) {
        fs.mkdirSync(path.dirname(sitemapPathAbsolute), { recursive: true });
        fs.writeFileSync(sitemapPathAbsolute, sitemapXml, "utf8");
      }

      sitemapXmlOutput = { outputPath: sitemapPathDisplay, urlCount: uniqueUrls.length, changed: sitemapChanged };
    }

    const copiedAssets: Array<{ sourcePath: string; outputPath: string; changed: boolean }> = [];
    const assetIncludePatterns = Array.isArray(project.assets?.include)
      ? project.assets!.include.map((pattern) => String(pattern || "").trim()).filter((pattern) => pattern.length > 0)
      : [];

    if (assetIncludePatterns.length > 0) {
      const orgSet = new Set(sourceFiles.map((file) => path.resolve(file)));
      const baseIgnore = Array.isArray(project.ignore)
        ? project.ignore.map((pattern) => String(pattern || "").trim()).filter((pattern) => pattern.length > 0)
        : [];
      const assetIgnore = Array.isArray(project.assets?.ignore)
        ? project.assets!.ignore.map((pattern) => String(pattern || "").trim()).filter((pattern) => pattern.length > 0)
        : [];
      const mergedIgnore = Array.from(new Set([...baseIgnore, ...assetIgnore]));

      const assetFiles = resolveFilesFromDir(sourceDir, assetIncludePatterns, mergedIgnore, publishRecursive)
        .map((file) => path.resolve(file))
        .filter((file) => !orgSet.has(file));

      for (const assetPath of assetFiles) {
        const relativeAssetPath = path.relative(sourceDir, assetPath);
        if (!relativeAssetPath || relativeAssetPath.startsWith("..")) continue;
        const outputAssetPathAbsolute = path.resolve(outputRoot, relativeAssetPath);
        const outputAssetPathDisplay = path.join(outputRootInput, relativeAssetPath);
        const assetBuffer = fs.readFileSync(assetPath);
        const existingAssetBuffer = fs.existsSync(outputAssetPathAbsolute) ? fs.readFileSync(outputAssetPathAbsolute) : null;
        const changed = !existingAssetBuffer || !existingAssetBuffer.equals(assetBuffer);

        if (!publishPreview) {
          fs.mkdirSync(path.dirname(outputAssetPathAbsolute), { recursive: true });
          fs.writeFileSync(outputAssetPathAbsolute, assetBuffer);
        }

        copiedAssets.push({
          sourcePath: toDisplayPath(assetPath),
          outputPath: outputAssetPathDisplay,
          changed,
        });
      }
    }

    if (publishFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "publish-html",
            project: publishProject,
            configPath: toDisplayPath(configPathResolved),
            sourceDir: sourceDirInput,
            outputDir: outputRootInput,
            recursive: publishRecursive,
            preview: publishPreview,
            count: exportedForOutput.length,
            exported: exportedForOutput,
            index: indexOutput,
            sitemapXml: sitemapXmlOutput,
            assets: copiedAssets,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(`${publishPreview ? "Previewed" : "Published"} ${exportedForOutput.length} file(s) for project ${publishProject} to ${outputRootInput}\n`);
    for (const item of exportedForOutput) process.stdout.write(`${item.sourcePath} -> ${item.outputPath}${item.changed ? "" : " (unchanged)"}\n`);
    if (indexOutput) process.stdout.write(`index -> ${indexOutput.outputPath}${indexOutput.changed ? "" : " (unchanged)"}\n`);
    if (sitemapXmlOutput) process.stdout.write(`sitemap -> ${sitemapXmlOutput.outputPath}${sitemapXmlOutput.changed ? "" : " (unchanged)"}\n`);
    for (const asset of copiedAssets) process.stdout.write(`${asset.sourcePath} -> ${asset.outputPath}${asset.changed ? "" : " (unchanged)"}\n`);
    return;
  }

  if (command === "export") {
    if (exportAction === "beamer") {
      if (!exportFile) {
        console.error("Error: export beamer requires --file FILE");
        process.exit(1);
      }
      if (String(dir || "").trim()) {
        console.error("Error: export beamer currently supports one --file at a time");
        process.exit(1);
      }
      if (exportOutDir || exportIndex || exportIndexTitle) {
        console.error("Error: --out-dir and --index options are only supported by export html");
        process.exit(1);
      }

      const sourcePathInput = exportFile;
      const sourcePath = path.resolve(sourcePathInput);
      const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
      const sourceAst = parseOrgToCanonicalAst(sourceRaw, { sourceRanges: true, sourcePath });
      const rendered = renderPresentationToBeamer(sourceAst);
      const fatalDiagnostics = rendered.diagnostics.filter((diagnostic) => diagnostic.severity === "error");
      if (fatalDiagnostics.length > 0) {
        for (const diagnostic of fatalDiagnostics) {
          console.error(
            `Error${diagnostic.line ? `:${diagnostic.line}` : ""}: ${diagnostic.message} (${diagnostic.code})`,
          );
        }
        process.exit(1);
      }

      const defaultOutputPath = (() => {
        const extension = exportPdf ? ".pdf" : ".tex";
        if (/\.(org|org2)$/i.test(sourcePathInput)) {
          return sourcePathInput.replace(/\.(org|org2)$/i, extension);
        }
        return `${sourcePathInput}${extension}`;
      })();
      const outputPathInput = exportOut || defaultOutputPath;
      const outputPath = path.resolve(outputPathInput);
      let changed = true;
      let pdfBytes: number | undefined;

      if (exportPdf) {
        if (exportApply) {
          const compiled = compileBeamerPdf(rendered.tex, {
            sourcePath,
            engine: exportLatexEngine,
          });
          if (!compiled.ok) {
            console.error(`Error: ${compiled.message}`);
            if (exportFormat !== "json" && compiled.log.trim()) console.error(compiled.log.trim());
            process.exit(1);
          }
          const existing = fs.existsSync(outputPath) ? fs.readFileSync(outputPath) : null;
          changed = !existing || !existing.equals(compiled.pdf);
          fs.mkdirSync(path.dirname(outputPath), { recursive: true });
          fs.writeFileSync(outputPath, compiled.pdf);
          pdfBytes = compiled.pdf.byteLength;
        }
      } else {
        const existing = fs.existsSync(outputPath)
          ? fs.readFileSync(outputPath, "utf8").replace(/\r\n/g, "\n")
          : "";
        changed = existing !== rendered.tex;
        if (exportApply) {
          fs.mkdirSync(path.dirname(outputPath), { recursive: true });
          fs.writeFileSync(outputPath, rendered.tex, "utf8");
        }
      }

      const warningDiagnostics = rendered.diagnostics.filter((diagnostic) => diagnostic.severity === "warning");
      if (exportFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              kind: exportPdf ? "export-beamer-pdf" : "export-beamer-tex",
              sourcePath: sourcePathInput,
              outputPath: outputPathInput,
              apply: exportApply,
              changed,
              title: rendered.presentation.metadata.title,
              sectionCount: rendered.presentation.sections.filter((section) => section.title.length > 0).length,
              slideCount: rendered.presentation.sections.reduce((count, section) => count + section.slides.length, 0),
              engine: exportPdf ? exportLatexEngine : undefined,
              pdfBytes,
              diagnostics: rendered.diagnostics,
            },
            null,
            2,
          ) + "\n",
        );
        return;
      }

      for (const diagnostic of warningDiagnostics) {
        console.error(
          `Warning${diagnostic.line ? `:${diagnostic.line}` : ""}: ${diagnostic.message} (${diagnostic.code})`,
        );
      }
      const verb = exportApply ? "Exported" : "Previewed";
      const formatName = exportPdf ? "Beamer PDF" : "Beamer TeX";
      process.stdout.write(
        `${verb} ${formatName}: ${sourcePathInput} -> ${outputPathInput}${exportApply && !changed ? " (unchanged)" : ""}\n`,
      );
      return;
    }

    if (exportAction !== "html") {
      console.error("Error: export currently supports only `html`");
      process.exit(1);
    }

    const hasSingleSource = Boolean(exportFile);
    const hasDirSource = Boolean(String(dir || "").trim());
    const exportStylesheetsNormalized = Array.from(
      new Set(exportStylesheets.map((href) => String(href || "").trim()).filter((href) => href.length > 0)),
    );

    let exportTocDepth: number | undefined;
    if (exportTocDepthRaw.trim().length > 0) {
      const rawDepth = exportTocDepthRaw.trim();
      if (!/^\d+$/.test(rawDepth)) {
        console.error(`Error: invalid export --toc-depth value: ${exportTocDepthRaw}. Expected a positive integer.`);
        process.exit(1);
      }
      const parsedDepth = Number.parseInt(rawDepth, 10);
      if (!Number.isFinite(parsedDepth) || parsedDepth < 1) {
        console.error(`Error: invalid export --toc-depth value: ${exportTocDepthRaw}. Expected a positive integer.`);
        process.exit(1);
      }
      exportTocDepth = parsedDepth;
    }

    let exportHeadlineNumberDepth: number | undefined;
    if (exportHeadlineNumberDepthRaw.trim().length > 0) {
      const rawDepth = exportHeadlineNumberDepthRaw.trim();
      if (!/^\d+$/.test(rawDepth)) {
        console.error(
          `Error: invalid export --number-headings-depth value: ${exportHeadlineNumberDepthRaw}. Expected a positive integer.`,
        );
        process.exit(1);
      }
      const parsedDepth = Number.parseInt(rawDepth, 10);
      if (!Number.isFinite(parsedDepth) || parsedDepth < 1) {
        console.error(
          `Error: invalid export --number-headings-depth value: ${exportHeadlineNumberDepthRaw}. Expected a positive integer.`,
        );
        process.exit(1);
      }
      exportHeadlineNumberDepth = parsedDepth;
    }

    if (hasSingleSource && hasDirSource) {
      console.error("Error: export html does not support combining --file with --dir");
      process.exit(1);
    }

    if (hasSingleSource && exportOutDir) {
      console.error("Error: --out-dir is only supported with export html --dir");
      process.exit(1);
    }

    if (hasSingleSource && exportIndex) {
      console.error("Error: --index is only supported with export html --dir");
      process.exit(1);
    }

    if (hasSingleSource && exportIndexTitle) {
      console.error("Error: --index-title is only supported with export html --dir --index");
      process.exit(1);
    }

    if (hasDirSource && exportOut) {
      console.error("Error: --out is only supported with export html --file");
      process.exit(1);
    }

    if (hasDirSource && exportTitle) {
      console.error("Error: --title is only supported with export html --file");
      process.exit(1);
    }

    if (hasDirSource && exportIndexTitle && !exportIndex) {
      console.error("Error: --index-title requires --index for export html --dir");
      process.exit(1);
    }

    if (!hasSingleSource && !hasDirSource) {
      console.error("Error: export html requires --file FILE or --dir DIR");
      process.exit(1);
    }

    let exportConfigLinkAbbreviations: Record<string, string> | undefined;
    let exportConfigLinearTeam: string | undefined;
    const exportConfigLookupStart = hasDirSource ? path.resolve(String(dir || "").trim()) : path.dirname(path.resolve(exportFile));
    const exportConfigPath = findConfigFile(exportConfigLookupStart);
    if (exportConfigPath) {
      try {
        const cfg = loadConfig(exportConfigPath);
        exportConfigLinkAbbreviations = cfg.links?.abbreviations;
        exportConfigLinearTeam = cfg.links?.linearTeam;
      } catch {
        // Ignore config errors for ad-hoc export flows.
      }
    }

    if (hasDirSource) {
      const sourceDirInput = String(dir || "").trim();
      const sourceDir = path.resolve(sourceDirInput);
      const sourceFiles = listOrgLikeFiles(sourceDir, recursive, includeArchives).sort((a, b) => a.localeCompare(b));
      const outputRootInput = String(exportOutDir || sourceDirInput).trim();
      const outputRoot = path.resolve(outputRootInput);

      const toDisplayPath = (absolutePath: string): string => {
        const relative = path.relative(process.cwd(), absolutePath);
        if (!relative || (!relative.startsWith("..") && !path.isAbsolute(relative))) {
          return relative || path.basename(absolutePath);
        }
        return absolutePath;
      };

      const exported: Array<{
        sourcePath: string;
        outputPath: string;
        outputPathAbsolute: string;
        title: string;
        changed: boolean;
        metadata?: ExportMetadataPayload;
      }> = [];

      for (const sourcePath of sourceFiles) {
        const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
        const sourceAst = parseOrgToCanonicalAst(sourceRaw, { sourceRanges: true, sourcePath });
        const sourceCharts = embeddedChartsForSource(sourceRaw, sourcePath);
        const sourcePluginRenders = await pluginRendersForDocument(sourceAst, sourcePath);
        const rendered = renderOrgDocumentToHtml(sourceAst, {
          sourcePath: toDisplayPath(sourcePath),
          stylesheets: exportStylesheetsNormalized,
          includeDefaultStyle: exportIncludeDefaultStyle,
          includeToc: exportIncludeToc,
          includeTocDepth: exportTocDepth,
          includeHeadlineNumbers: exportIncludeHeadlineNumbers,
          includeHeadlineNumberDepth: exportHeadlineNumberDepth,
          rewriteFileLinks: exportRewriteFileLinks,
          linkAbbreviations: exportConfigLinkAbbreviations,
          linearTeam: exportConfigLinearTeam,
          charts: sourceCharts,
          pluginRenders: sourcePluginRenders,
        });

        const relativeSourcePath = path.relative(sourceDir, sourcePath);
        const outputRelativePath = /\.(org|org2)$/i.test(relativeSourcePath)
          ? relativeSourcePath.replace(/\.(org|org2)$/i, ".html")
          : `${relativeSourcePath}.html`;

        const outputPathAbsolute = path.resolve(outputRoot, outputRelativePath);
        const outputPathDisplay = path.join(outputRootInput, outputRelativePath);
        const existingOutput = fs.existsSync(outputPathAbsolute)
          ? fs.readFileSync(outputPathAbsolute, "utf8").replace(/\r\n/g, "\n")
          : "";
        const changed = existingOutput !== rendered.html;

        if (exportApply) {
          fs.mkdirSync(path.dirname(outputPathAbsolute), { recursive: true });
          fs.writeFileSync(outputPathAbsolute, rendered.html, "utf8");
        }

        exported.push({
          sourcePath: toDisplayPath(sourcePath),
          outputPath: outputPathDisplay,
          outputPathAbsolute,
          title: rendered.title,
          changed,
          ...(hasExportMetadata(rendered.metadata) ? { metadata: rendered.metadata } : {}),
        });
      }

      const exportedForOutput = exported.map(({ sourcePath, outputPath, title, changed, metadata }) => ({
        sourcePath,
        outputPath,
        title,
        changed,
        ...(hasExportMetadata(metadata) ? { metadata } : {}),
      }));

      let indexOutput: { outputPath: string; title: string; changed: boolean } | null = null;
      const indexRaw = String(exportIndex || "").trim();
      if (indexRaw) {
        const indexPathAbsolute = path.isAbsolute(indexRaw) ? path.resolve(indexRaw) : path.resolve(outputRoot, indexRaw);
        const indexPathDisplay = path.isAbsolute(indexRaw) ? toDisplayPath(indexPathAbsolute) : path.join(outputRootInput, indexRaw);
        const indexRendered = renderOrgExportIndexToHtml({
          title: exportIndexTitle || undefined,
          sourcePath: indexRaw,
          stylesheets: exportStylesheetsNormalized,
          includeDefaultStyle: exportIncludeDefaultStyle,
          items: exported.map((item) => {
            const hrefRaw = path.relative(path.dirname(indexPathAbsolute), item.outputPathAbsolute);
            const href = String(hrefRaw || path.basename(item.outputPathAbsolute)).split(path.sep).join("/");
            return {
              title: item.title,
              href,
              sourcePath: item.sourcePath,
            };
          }),
        });

        const existingIndex = fs.existsSync(indexPathAbsolute)
          ? fs.readFileSync(indexPathAbsolute, "utf8").replace(/\r\n/g, "\n")
          : "";
        const indexChanged = existingIndex !== indexRendered.html;

        if (exportApply) {
          fs.mkdirSync(path.dirname(indexPathAbsolute), { recursive: true });
          fs.writeFileSync(indexPathAbsolute, indexRendered.html, "utf8");
        }

        indexOutput = {
          outputPath: indexPathDisplay,
          title: indexRendered.title,
          changed: indexChanged,
        };
      }

      if (exportFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              kind: "export-html-batch",
              sourceDir: sourceDirInput,
              outputDir: outputRootInput,
              recursive,
              apply: exportApply,
              count: exportedForOutput.length,
              exported: exportedForOutput,
              index: indexOutput,
            },
            null,
            2,
          ) + "\n",
        );
        return;
      }

      if (exportedForOutput.length === 0 && !indexOutput) {
        process.stdout.write(`No Org files found under ${sourceDirInput}\n`);
        return;
      }

      if (exportApply) {
        process.stdout.write(`Exported ${exportedForOutput.length} file(s) to ${outputRootInput}\n`);
      } else {
        process.stdout.write(`Previewed ${exportedForOutput.length} file(s) from ${sourceDirInput}\n`);
      }

      for (const item of exportedForOutput) {
        process.stdout.write(
          `${item.sourcePath} -> ${item.outputPath}${item.changed ? "" : " (unchanged)"}\n`,
        );
      }

      if (indexOutput) {
        process.stdout.write(`index -> ${indexOutput.outputPath}${indexOutput.changed ? "" : " (unchanged)"}\n`);
      }
      return;
    }

    const sourcePathInput = exportFile;
    const sourcePath = path.resolve(sourcePathInput);
    const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
    const sourceAst = parseOrgToCanonicalAst(sourceRaw, { sourceRanges: true, sourcePath });
    const sourceCharts = embeddedChartsForSource(sourceRaw, sourcePath);
    const sourcePluginRenders = await pluginRendersForDocument(sourceAst, sourcePath);
    const rendered = renderOrgDocumentToHtml(sourceAst, {
      title: exportTitle || undefined,
      sourcePath: sourcePathInput,
      stylesheets: exportStylesheetsNormalized,
      includeDefaultStyle: exportIncludeDefaultStyle,
      includeToc: exportIncludeToc,
      includeTocDepth: exportTocDepth,
      includeHeadlineNumbers: exportIncludeHeadlineNumbers,
      includeHeadlineNumberDepth: exportHeadlineNumberDepth,
      rewriteFileLinks: exportRewriteFileLinks,
      linkAbbreviations: exportConfigLinkAbbreviations,
      linearTeam: exportConfigLinearTeam,
      charts: sourceCharts,
      pluginRenders: sourcePluginRenders,
    });

    const defaultOutputPath = (() => {
      if (/\.(org|org2)$/i.test(sourcePathInput)) {
        return sourcePathInput.replace(/\.(org|org2)$/i, ".html");
      }
      return `${sourcePathInput}.html`;
    })();

    const outputPathInput = exportOut || defaultOutputPath;
    const outputPath = path.resolve(outputPathInput);
    const existingOutput = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, "utf8").replace(/\r\n/g, "\n") : "";
    const changed = existingOutput !== rendered.html;

    if (exportApply) {
      fs.mkdirSync(path.dirname(outputPath), { recursive: true });
      fs.writeFileSync(outputPath, rendered.html, "utf8");
    }

    if (exportFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "export-html",
            sourcePath: sourcePathInput,
            outputPath: outputPathInput,
            title: rendered.title,
            ...(hasExportMetadata(rendered.metadata) ? { metadata: rendered.metadata } : {}),
            apply: exportApply,
            changed,
            html: rendered.html,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (!exportApply) {
      process.stdout.write(rendered.html);
      return;
    }

    process.stdout.write(`Exported HTML to ${outputPathInput}\n`);
    return;
  }

  if (command === "capture") {
    const targetFile = captureTargetFile || captureFile;
    if (!targetFile) {
      console.error("Error: capture requires --file FILE (or --to FILE for source captures)");
      process.exit(1);
    }

    const sourceInputs = [captureTextRaw ? "text" : "", captureUrl ? "url" : "", captureSourceFile ? "file" : "", captureReadStdin ? "stdin" : ""].filter(Boolean);
    if (sourceInputs.length > 1) {
      console.error("Error: capture accepts only one of --text, --stdin, --url, or --file SOURCE with --to");
      process.exit(1);
    }

    const normalizedTemplateRaw = captureTemplateRaw.trim().toLowerCase();
    if (normalizedTemplateRaw !== "note" && normalizedTemplateRaw !== "task") {
      console.error(`Error: invalid --template ${captureTemplateRaw}. Allowed: note, task`);
      process.exit(1);
    }
    const normalizedTemplate = normalizedTemplateRaw as "note" | "task";

    if (captureTodoKeywordFlagSet && normalizedTemplate !== "task") {
      console.error("Error: --todo is only supported with --template task");
      process.exit(1);
    }

    const normalizedTodoKeyword = normalizeTodoKeyword(captureTodoKeywordRaw);
    let captureTodoKeyword: string | null = null;
    if (normalizedTemplate === "task") {
      if (!normalizedTodoKeyword) {
        console.error(
          `Error: invalid capture --todo value ${captureTodoKeywordRaw}. Allowed: ${TODO_KEYWORDS.join(", ")}`,
        );
        process.exit(1);
      }
      captureTodoKeyword = normalizedTodoKeyword;
    }

    let captureNowDate = new Date();
    if (captureNow) {
      const parsedNow = new Date(captureNow);
      if (isNaN(parsedNow.getTime())) {
        console.error(`Error: invalid --now ${captureNow}`);
        process.exit(1);
      }
      captureNowDate = parsedNow;
    }

    let normalizedBody = captureBodyRaw.replace(/\r\n/g, "\n").trim();
    let source: { type: string; origin: string; timestamp: string; title: string | null; author: string | null; contentHash: string; provenance: string | null } | null = null;
    if (sourceInputs.length === 1) {
      const inputSourceType = sourceInputs[0]!;
      let sourceType = inputSourceType;
      let origin = captureOrigin.trim();
      let provenance: string | null = null;
      if (inputSourceType === "text") {
        normalizedBody = captureTextRaw.replace(/\r\n/g, "\n").trim();
        origin ||= "literal:text";
      } else if (inputSourceType === "stdin") {
        normalizedBody = (await readStdinText()).replace(/\r\n/g, "\n").trim();
        origin ||= "stdin";
      } else if (inputSourceType === "file") {
        const stat = fs.statSync(captureSourceFile);
        if (stat.isDirectory()) {
          console.error("Error: capture --file SOURCE currently supports files, not directories");
          process.exit(1);
        }
        normalizedBody = fs.readFileSync(captureSourceFile, "utf8").replace(/\r\n/g, "\n").trim();
        origin ||= path.resolve(captureSourceFile);
        provenance = `file:${path.resolve(captureSourceFile)}`;
      } else if (inputSourceType === "url") {
        const res = await fetch(captureUrl);
        if (!res.ok) {
          console.error(`Error: failed to fetch --url ${captureUrl}: HTTP ${res.status}`);
          process.exit(1);
        }
        normalizedBody = (await res.text()).replace(/\r\n/g, "\n").trim();
        origin ||= captureUrl;
        provenance = `url:${captureUrl}`;
      }
      if (captureSourceTypeRaw && captureSourceTypeRaw !== "stdin") sourceType = captureSourceTypeRaw.trim().toLowerCase();
      const inferredTitle = captureTitle.trim() || (inputSourceType === "file" ? path.basename(captureSourceFile) : inputSourceType === "url" ? captureUrl : "Captured text");
      source = { type: sourceType, origin, timestamp: captureNowDate.toISOString(), title: inferredTitle, author: captureAuthor.trim() || null, contentHash: sha256Hex(normalizedBody), provenance };
    }

    const normalizedTitle = (captureTitle.trim() || source?.title || "").trim();
    if (!normalizedTitle) {
      console.error("Error: capture requires --title TITLE");
      process.exit(1);
    }

    const { text: captureEntryText, capturedAt } = renderCaptureEntry({
      title: normalizedTitle, template: normalizedTemplate, todoKeyword: captureTodoKeyword,
      body: normalizedBody, now: captureNowDate, source,
    });

    const beforeText = fs.existsSync(targetFile)
      ? fs.readFileSync(targetFile, "utf8").replace(/\r\n/g, "\n")
      : "";
    const beforeTrimmed = beforeText.trimEnd();
    const outText =
      beforeTrimmed.length > 0
        ? `${beforeTrimmed}\n\n${captureEntryText}`
        : captureEntryText;

    const changed = outText !== beforeText;
    const headingLine1 = beforeTrimmed.length === 0 ? 1 : beforeTrimmed.split("\n").length + 2;

    if (captureApply && changed) {
      fs.mkdirSync(path.dirname(targetFile), { recursive: true });
      fs.writeFileSync(targetFile, outText, "utf8");
    }

    if (captureFormat === "diff") {
      if (changed) {
        process.stdout.write(buildUnifiedDiff(beforeText, outText, {
          targetPath: targetFile,
          temporaryDirectoryPrefix: "org2-capture-diff-",
        }));
      }
      return;
    }

    if (captureFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "capture",
            file: targetFile,
            template: normalizedTemplate,
            title: normalizedTitle,
            todoKeyword: captureTodoKeyword,
            body: normalizedBody || null,
            ...(source ? { source } : {}),
            capturedAt,
            headingLine1,
            apply: captureApply,
            changed,
            outText,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(outText);
    return;
  }

  if (command === "id") {
    if (!idFile) {
      console.error("Error: id requires --file FILE");
      process.exit(1);
    }

    const raw = fs.readFileSync(idFile, "utf8").replace(/\r\n/g, "\n");
    const lines = raw.split("\n");

    if (idAction === "get" && idFormat === "diff") {
      console.error("Error: celorga id get does not support --format diff");
      process.exit(1);
    }

    const getHeadlineIdAtOrAboveLine = (
      line1: number,
    ):
      | { id: string; idLine1: number; headingLine1: number; changed: boolean; outText: string }
      | null => {
      if (!line1 || line1 < 1) return null;

      const startIdx = Math.min(Math.max(line1 - 1, 0), lines.length - 1);

      let headingIdx = -1;
      let headingLevel = 0;
      for (let idx = startIdx; idx >= 0; idx -= 1) {
        const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
        if (m) {
          headingIdx = idx;
          headingLevel = m[1]!.length;
          break;
        }
      }

      if (headingIdx === -1) return null;

      // Search within this subtree (until the next heading at same-or-higher level).
      let subtreeEnd = lines.length;
      for (let idx = headingIdx + 1; idx < lines.length; idx += 1) {
        const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
        if (m && m[1]!.length <= headingLevel) {
          subtreeEnd = idx;
          break;
        }
      }

      const idLineRe = /^\s*:ID:\s*(\S+)\s*$/;

      // Best-effort: allow blank lines between heading and drawer.
      let scanStart = headingIdx + 1;
      while (scanStart < subtreeEnd && (lines[scanStart] ?? "").trim() === "") scanStart += 1;

      // If there's a :PROPERTIES: drawer, use/extend it.
      if (((lines[scanStart] ?? "").trim() || "").toUpperCase() === ":PROPERTIES:") {
        let drawerEnd = -1;
        for (let j = scanStart + 1; j < subtreeEnd; j += 1) {
          const t = (lines[j] ?? "").trim();
          const m = idLineRe.exec(t);
          if (m) {
            return {
              id: m[1]!,
              idLine1: j + 1,
              headingLine1: headingIdx + 1,
              changed: false,
              outText: raw,
            };
          }
          if (t.toUpperCase() === ":END:") {
            drawerEnd = j;
            break;
          }
        }

        if (drawerEnd !== -1 && idAction === "ensure") {
          const newId = idForced || crypto.randomUUID();
          lines.splice(scanStart + 1, 0, `:ID: ${newId}`);
          const outText = lines.join("\n");
          return {
            id: newId,
            idLine1: scanStart + 2,
            headingLine1: headingIdx + 1,
            changed: true,
            outText,
          };
        }

        return null;
      }

      // No drawer: insert one directly under the heading.
      if (idAction === "ensure") {
        const newId = idForced || crypto.randomUUID();
        const drawer = [":PROPERTIES:", `:ID: ${newId}`, ":END:", ""];
        lines.splice(headingIdx + 1, 0, ...drawer);
        const outText = lines.join("\n");
        return {
          id: newId,
          idLine1: headingIdx + 3,
          headingLine1: headingIdx + 1,
          changed: true,
          outText,
        };
      }

      return null;
    };

    if (idLine > 0) {
      const headlineRes = getHeadlineIdAtOrAboveLine(idLine);
      if (headlineRes) {
        if (idAction === "get") {
          if (idFormat === "json") {
            process.stdout.write(
              JSON.stringify(
                {
                  id: headlineRes.id,
                  kind: "headline",
                  file: idFile,
                  line: headlineRes.idLine1,
                  headingLine: headlineRes.headingLine1,
                },
                null,
                2,
              ) + "\n",
            );
          } else {
            process.stdout.write(headlineRes.id + "\n");
          }
          return;
        }

        // ensure
        if (headlineRes.changed && idApply) {
          fs.writeFileSync(idFile, headlineRes.outText, "utf8");
        }

        if (idFormat === "json") {
          process.stdout.write(
            JSON.stringify(
              {
                id: headlineRes.id,
                kind: "headline",
                file: idFile,
                line: headlineRes.idLine1,
                headingLine: headlineRes.headingLine1,
                applied: idApply,
                changed: headlineRes.changed,
              },
              null,
              2,
            ) + "\n",
          );
        } else if (idFormat === "diff") {
          if (headlineRes.changed && !idApply) {
            process.stdout.write(buildUnifiedDiff(raw, headlineRes.outText, {
              targetPath: idFile,
              temporaryDirectoryPrefix: "org2-id-diff-",
            }));
          }
        } else if (idApply || !headlineRes.changed) {
          process.stdout.write(headlineRes.id + "\n");
        } else {
          process.stdout.write(headlineRes.outText);
        }

        return;
      }
      // If no heading context found (or malformed drawer), fall back to file-level.
    }

    const getFileId = (): { id: string; line: number } | null => {
      // Accept `#+id: <uuid>` anywhere near top, but prefer a file-level property drawer.
      for (let j = 0; j < Math.min(lines.length, 30); j += 1) {
        const l = lines[j] ?? "";
        const m = /^#\+id:\s*(\S+)\s*$/i.exec(l.trim());
        if (m) return { id: m[1]!, line: j + 1 };
      }

      // Look for any file-level :PROPERTIES: drawer before the first headline.
      // This supports both common layouts: drawer-before-title and title-before-drawer.
      for (let idx = 0; idx < lines.length; idx += 1) {
        if (/^(\*+)\s+/.test(lines[idx] ?? "")) break;
        const l = (lines[idx] ?? "").trim();
        if (l !== ":PROPERTIES:") continue;

        for (let j = idx + 1; j < lines.length; j += 1) {
          const inner = (lines[j] ?? "").trim();
          if (inner === ":END:") break;
          const m = /^:ID:\s*(\S+)\s*$/.exec(inner);
          if (m) return { id: m[1]!, line: j + 1 };
        }
      }

      return null;
    };

    const existing = getFileId();

    if (idAction === "get") {
      if (!existing) {
        console.error("Error: no file-level ID found");
        process.exit(1);
      }

      if (idFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              id: existing.id,
              kind: "file",
              file: idFile,
              line: existing.line,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(existing.id + "\n");
      }

      return;
    }

    // ensure
    if (existing) {
      if (idFormat === "json") {
        process.stdout.write(
          JSON.stringify(
            {
              id: existing.id,
              kind: "file",
              file: idFile,
              line: existing.line,
              applied: idApply,
              changed: false,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        process.stdout.write(existing.id + "\n");
      }
      return;
    }

    const newId = idForced || crypto.randomUUID();
    const drawer = `:PROPERTIES:
:ID: ${newId}
:END:
`;
    let insertAt = 0;
    while (insertAt < lines.length) {
      const l = (lines[insertAt] ?? "").trim();
      if (l === "" || l.startsWith("#")) {
        insertAt += 1;
        continue;
      }
      break;
    }
    const outLines = [...lines];
    outLines.splice(insertAt, 0, ...drawer.split("\n"));
    const out = outLines.join("\n");

    if (idApply) {
      fs.writeFileSync(idFile, out, "utf8");
    }

    if (idFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            id: newId,
            kind: "file",
            file: idFile,
            line: 2,
            applied: idApply,
            changed: true,
          },
          null,
          2,
        ) + "\n",
      );
    } else if (idFormat === "diff") {
      if (!idApply) {
        process.stdout.write(buildUnifiedDiff(raw, out, {
          targetPath: idFile,
          temporaryDirectoryPrefix: "org2-id-diff-",
        }));
      }
    } else if (idApply) {
      process.stdout.write(newId + "\n");
    } else {
      process.stdout.write(out);
    }

    return;
  }

  if (command === "index") {
    let rootDir = dir ? path.resolve(dir) : "";
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          rootDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, rootDir);
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (indexIncremental && files.length === 0) {
      console.error("Error: celorga index --incremental requires --file or --files");
      process.exit(1);
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);
    if (!rootDir) rootDir = files.length ? path.dirname(path.resolve(files[0]!)) : process.cwd();

    const incrementalResult = indexIncremental
      ? updateSearchIndex({ rootDir, changedFiles: files, recursive, includeArchives })
      : null;
    const incrementalApplied = incrementalResult !== null;
    const result: Org2SearchIndexBuildResult = incrementalResult
      ?? buildSearchIndex({
        rootDir,
        files: indexIncremental && dir
          ? listOrgLikeFiles(dir, recursive, includeArchives)
          : files,
        recursive,
        includeArchives,
      });
    const updatedFileCount = incrementalResult?.updatedFiles;
    writeSearchIndex(result);

    if (indexFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:index:v1",
            kind: "search",
            path: result.path,
            rootDir: result.index.rootDir,
            recursive: result.index.recursive,
            includeArchives: result.index.includeArchives,
            builtAt: result.index.builtAt,
            fileCount: result.fileCount,
            lineCount: result.lineCount,
            byteCount: result.byteCount,
            skippedFiles: result.skippedFiles,
            incremental: incrementalApplied,
            updatedFiles: updatedFileCount,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(
      `${incrementalApplied ? "Updated index for" : "Indexed"} ${updatedFileCount ?? result.fileCount} file${(updatedFileCount ?? result.fileCount) === 1 ? "" : "s"} (${result.lineCount} lines total) -> ${result.path}\n`,
    );
    if (result.skippedFiles > 0) {
      process.stderr.write(`Skipped ${result.skippedFiles} file${result.skippedFiles === 1 ? "" : "s"}.\n`);
    }
    return;
  }

  if (command === "approvals") {
    let rootDir = dir ? path.resolve(dir) : "";
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          rootDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, rootDir);
          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (!rootDir) rootDir = files.length ? path.dirname(path.resolve(files[0]!)) : process.cwd();
    const runs = listAgentRunsWithApprovals(rootDir);
    if (dir && files.length === 0) files = listOrgLikeFiles(rootDir, recursive, includeArchives);
    files = Array.from(
      new Set(
        files
          .map((file) => path.resolve(file))
          .filter((file) => isApprovalIndexableFilePath(file, includeArchives)),
      ),
    ).sort((a, b) => a.localeCompare(b));
    if (files.length === 0 && runs.length === 0) {
      console.error("Error: no Org files found for celorga approvals");
      process.exit(1);
    }

    let indexStatus: ApprovalQueuePayload["index"];
    let candidates: ApprovalCandidateSource[] = [];
    let skippedCandidates = 0;

    if (files.length === 0) {
      indexStatus = { mode: searchIndexMode, used: false };
    } else if (searchIndexMode === "never") {
      const scanned = approvalCandidateSourcesByScanningFiles(files, includeArchives);
      candidates = scanned.candidates;
      skippedCandidates += scanned.skippedFiles;
      indexStatus = { mode: searchIndexMode, used: false };
    } else if (searchIndexMode === "rebuild") {
      const result = buildSearchIndex({ rootDir, files, recursive, includeArchives });
      writeSearchIndex(result);
      candidates = approvalCandidateSourcesFromIndex(result.index, includeArchives);
      skippedCandidates += result.skippedFiles;
      indexStatus = { mode: searchIndexMode, used: true, path: result.path, builtAt: result.index.builtAt };
    } else {
      const loaded = loadFreshSearchIndex({ rootDir, files, recursive, includeArchives });
      if (loaded) {
        candidates = approvalCandidateSourcesFromIndex(loaded.index, includeArchives);
        indexStatus = { mode: searchIndexMode, used: true, path: loaded.path, builtAt: loaded.index.builtAt };
      } else {
        const result = buildSearchIndex({ rootDir, files, recursive, includeArchives });
        writeSearchIndex(result);
        candidates = approvalCandidateSourcesFromIndex(result.index, includeArchives);
        skippedCandidates += result.skippedFiles;
        indexStatus = {
          mode: searchIndexMode,
          used: true,
          path: result.path,
          builtAt: result.index.builtAt,
          stale: true,
          rebuilt: true,
        };
      }
    }

    const approvalCandidates = approvalCandidatesFromRuns(rootDir, runs);
    for (const candidate of candidates) {
      try {
        const document = parseOrgToCanonicalAst(candidate.parseText, {
          sourceRanges: true,
          sourceLineOffset: candidate.sourceLineOffset,
          sourcePath: candidate.file,
        });
        approvalCandidates.push(...approvalCandidatesInDocument(document, candidate.file, candidate.sourceText));
      } catch (err) {
        skippedCandidates += 1;
        if (verboseErrors) {
          console.error(`Error processing approval candidate ${candidate.file}: ${err instanceof Error ? err.message : String(err)}`);
        }
      }
    }

    const sortedItems = unifiedPendingApprovalItems(approvalCandidates);
    const runByID = new Map(runs.map((run) => [run.id, run]));
    const runDetails = Array.from(new Set(approvalRunDetailIDs))
      .map((runID) => runByID.get(runID) || loadAgentRun(rootDir, runID));
    const payload: ApprovalQueuePayload = {
      $schema: "org2:approvals:v2",
      count: sortedItems.length,
      index: indexStatus,
      ...(skippedCandidates > 0 ? { skippedCandidates } : {}),
      items: sortedItems,
      ...(runDetails.length > 0 ? { runDetails } : {}),
    };

    if (approvalsFormat === "json") {
      process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
      return;
    }

    if (sortedItems.length === 0) {
      process.stdout.write("No approvals found.\n");
      return;
    }

    for (const item of sortedItems) {
      if (item.kind === "run") {
        process.stdout.write(`run:${item.runId}:${item.approvalId} ${item.title} [${item.status}; ${item.runPendingApprovalCount} pending for run]\n`);
        continue;
      }
      const todo = item.todo ? `${item.todo} ` : "";
      process.stdout.write(`${item.file}:${item.line} ${todo}${item.title} [${item.status}]\n`);
    }
    return;
  }

  if (command === "backlinks") {
    if (!backlinksId) {
      console.error("Error: backlinks requires --id UUID");
      process.exit(1);
    }

    // Determine files to search (same as agenda)
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);

          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0) {
      const listOrgFiles = (dirPath: string): string[] => {
        const out: string[] = [];
        const entries = fs.readdirSync(dirPath, { withFileTypes: true });
        for (const entry of entries) {
          const fullPath = path.join(dirPath, entry.name);
          if (entry.isDirectory()) {
            if (!recursive) continue;
            if (entry.name.startsWith(".")) continue;
            out.push(...listOrgFiles(fullPath));
            continue;
          }
          if (!entry.isFile()) continue;
          if (!(entry.name.endsWith(".org") || entry.name.endsWith(".org2"))) continue;
          if (entry.name.startsWith(".#")) continue;
          out.push(fullPath);
        }
        return out;
      };

      files = listOrgFiles(dir);
    }

    const backlinks: Backlink[] = [];
    const titleIndex = buildRoamTitleIndex(files);
    const resolveWikiLinkIds = (label: string): string[] => {
      const key = normalizeRoamLinkLabel(label);
      if (!key) return [];

      const ids = titleIndex.get(key);
      if (!ids || ids.size === 0) return [];
      return Array.from(ids);
    };
    let skippedFileCount = 0;

    for (const filePath of files) {
      try {
        const content = fs.readFileSync(filePath, "utf8");
        backlinks.push(
          ...findBacklinksInText(content, filePath, backlinksId, {
            resolveWikiLinkIds,
          }),
        );
      } catch (err) {
        skippedFileCount += 1;
        if (verboseErrors) {
          console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
        }
      }
    }

    if (skippedFileCount > 0 && !verboseErrors) {
      console.error(
        `Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`,
      );
    }

    // Stable sort for tests/readability
    backlinks.sort((a, b) => (a.file + ":" + a.line).localeCompare(b.file + ":" + b.line));

    if (backlinksFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:backlinks:v1",
            id: backlinksId.toLowerCase(),
            backlinks: backlinks.map((b) => ({
              srcId: b.srcId,
              srcTitle: b.srcTitle,
              file: b.file,
              line: b.line,
              context: b.context,
            })),
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (backlinks.length === 0) {
      process.stdout.write("No backlinks found.\n");
      return;
    }

    for (const b of backlinks) {
      process.stdout.write(`${b.srcTitle} (${b.srcId ?? ""}) ${b.file}:${b.line + 1} ${b.context}\n`);
    }

    return;
  }

  if (command === "query" && queryClocks) {
    command = "clock";
    clockFormat = queryFormat;
  }

  if (command === "query" && queryActions) {
    if (!queryRelationObject) {
      console.error("Error: celorga query actions requires --object ID|TITLE|LINK");
      process.exit(1);
    }

    const parseNonnegativeInteger = (raw: string, flag: string): number => {
      if (!/^\d+$/.test(String(raw || "").trim())) {
        console.error(`Error: ${flag} requires a nonnegative integer`);
        process.exit(1);
      }
      return Number.parseInt(raw, 10);
    };
    const recentDays = parseNonnegativeInteger(queryRecentDaysRaw, "--recent-days");
    const openLimit = parseNonnegativeInteger(queryOpenLimitRaw, "--open-limit");
    const completedLimit = parseNonnegativeInteger(queryCompletedLimitRaw, "--completed-limit");

    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          files = resolveFilesFromConfig(config, path.dirname(configPath));
          if (files.length === 0) {
            console.error(`Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`);
            process.exit(1);
          }
          dir = path.dirname(configPath);
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);
    files = Array.from(new Set(files)).sort((a, b) => a.localeCompare(b));
    if (files.length === 0) {
      console.error("Error: no Org files found for celorga query actions");
      process.exit(1);
    }

    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const corpus = compileCorpusIncremental(files, {
      rootDir,
      cacheFile: defaultCorpusCachePath(rootDir),
    });
    let payload: ReturnType<typeof queryNodeActions>;
    try {
      payload = queryNodeActions(corpus, {
        object: queryRelationObject,
        today: brandEnv("ORG2_TODAY"),
        recentDays,
        openLimit,
        completedLimit,
      });
    } catch (err) {
      console.error(`Error: ${err instanceof Error ? err.message : String(err)}`);
      process.exit(1);
    }

    if (queryFormat === "json") {
      process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
      return;
    }

    process.stdout.write(`${payload.target.title}: ${payload.counts.open} open, ${payload.counts.recentlyCompleted} recently completed\n`);
    for (const item of payload.open) {
      const origin = item.meeting ? ` · from ${item.meeting.title}` : "";
      const date = item.date ? ` · ${item.dateKind}: ${item.date}` : "";
      process.stdout.write(`- ${item.todo} ${item.title}${date}${origin} (${item.file}:${item.line})\n`);
    }
    if (payload.recentlyCompleted.length > 0) {
      process.stdout.write("Recently completed:\n");
      for (const item of payload.recentlyCompleted) {
        const origin = item.meeting ? ` · from ${item.meeting.title}` : "";
        process.stdout.write(`- DONE ${item.title} · ${item.date}${origin} (${item.file}:${item.line})\n`);
      }
    }
    return;
  }

  if (command === "query" && queryRelations) {
    if (!queryRelationObject) {
      console.error("Error: celorga query relations requires --object ID|TITLE|LINK");
      process.exit(1);
    }

    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          files = resolveFilesFromConfig(config, path.dirname(configPath));
          if (files.length === 0) {
            console.error(`Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`);
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);

    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const corpus = compileCorpus(files, { rootDir });
    const objectRaw = queryRelationObject.trim();
    const objectLinkMatch = /^\[\[([^\]\n]+?)(?:\]\[([^\]\n]*))?\]\]$/.exec(objectRaw);
    const objectTarget = objectLinkMatch ? String(objectLinkMatch[1] || "").trim() : objectRaw;
    const objectDescription = objectLinkMatch ? String(objectLinkMatch[2] || "").trim().toLowerCase() : "";
    const objectIdMatch = /^(?:id:)?([0-9a-fA-F-]{36})$/.exec(objectTarget);
    const objectId = objectIdMatch ? objectIdMatch[1]!.toLowerCase() : "";
    const objectLabel = objectId ? "" : objectTarget.toLowerCase();
    const predicate = queryRelationPredicate.trim().toLowerCase().replace(/[^a-z0-9_-]+/g, "_");
    const relations = corpus.relations.filter((relation) => {
      if (predicate && relation.predicate !== predicate) return false;
      if (objectId) return relation.objectId === objectId || relation.objectRef.toLowerCase() === `id:${objectId}`;
      return relation.objectRef.toLowerCase() === objectLabel || (relation.objectTitle || "").toLowerCase() === objectLabel || (!!objectDescription && (relation.objectTitle || "").toLowerCase() === objectDescription);
    });

    if (queryFormat === "json") {
      process.stdout.write(JSON.stringify({ $schema: "org2:relation-query:v1", object: queryRelationObject, ...(predicate ? { predicate } : {}), count: relations.length, relations }, null, 2) + "\n");
      return;
    }

    if (relations.length === 0) {
      process.stdout.write("No relations found.\n");
      return;
    }
    const bucketLabel = (confidence: string) => confidence === "explicit" ? "explicit/confirmed" : "inferred/likely";
    for (const confidence of ["explicit", "inferred-pattern"] as const) {
      const bucket = relations.filter((relation) => relation.confidence === confidence);
      if (!bucket.length) continue;
      process.stdout.write(`${bucketLabel(confidence)}:\n`);
      for (const relation of bucket) {
        process.stdout.write(`- ${relation.subjectTitle} --${relation.predicate}--> ${relation.objectTitle || relation.objectRef} (${relation.file}:${relation.line}) ${relation.evidence}\n`);
      }
    }
    return;
  }

  if (command === "search" || (command === "query" && searchTerm)) {
    if (!searchTerm) {
      console.error(`Error: ${command} requires a search term`);
      process.exit(1);
    }

    let searchRootDir = dir ? path.resolve(dir) : "";
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          searchRootDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, searchRootDir);
          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0 && searchIndexMode !== "current") {
      files = listOrgLikeFiles(dir, recursive, includeArchives);
    }
    if (!searchRootDir && files.length > 0) searchRootDir = path.dirname(path.resolve(files[0]!));

    const context = Math.max(0, Number.parseInt(searchContextRaw, 10) || 0);
    const limit = Math.max(1, Number.parseInt(searchLimitRaw, 10) || 50);
    const todoFilters = new Set(searchTodoFiltersRaw.map((t) => t.toUpperCase()));
    const tagFilters = new Set(searchTagFiltersRaw.map((t) => t.replace(/^:/, "").replace(/:$/, "").toLowerCase()));
    const fileZoneFilters = searchFileZoneFiltersRaw.map((t) => t.toLowerCase()).filter(Boolean);
    const headingNeedle = searchHeadingFilter.toLowerCase();
    const normalizeSearchDate = (raw: string): string => {
      const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(raw || "").trim());
      return m ? `${m[1]}-${m[2]}-${m[3]}` : "";
    };
    const dateFrom = normalizeSearchDate(searchDateFrom);
    const dateTo = normalizeSearchDate(searchDateTo);

    if (searchDateFrom && !dateFrom) {
      console.error(`Error: invalid --date-from/--from value '${searchDateFrom}' (expected YYYY-MM-DD)`);
      process.exit(1);
    }
    if (searchDateTo && !dateTo) {
      console.error(`Error: invalid --date-to/--to value '${searchDateTo}' (expected YYYY-MM-DD)`);
      process.exit(1);
    }

    const searchOptions: Org2SearchOptions = {
      query: searchTerm,
      context,
      limit,
      todoFilters,
      tagFilters,
      fileZoneFilters,
      headingNeedle,
      sort: searchSort,
      dateFrom,
      dateTo,
      subtree: querySubtree,
      answerContext: queryAnswerContext,
    };

    let skippedFileCount = 0;
    let indexStatus: Org2SearchResultPayload["index"] | undefined;
    let hits: Org2SearchHit[] = [];
    const canUseIndex = Boolean(searchRootDir) && !querySubtree;

    if (canUseIndex && searchIndexMode === "rebuild") {
      const result = buildSearchIndex({ rootDir: searchRootDir, files, recursive, includeArchives });
      writeSearchIndex(result);
      hits = searchIndexedCorpus(result.index, searchOptions);
      indexStatus = { mode: searchIndexMode, used: true, path: result.path, builtAt: result.index.builtAt };
    } else if (canUseIndex && searchIndexMode === "current") {
      const loaded = loadCompatibleSearchIndex({ rootDir: searchRootDir, recursive, includeArchives });
      if (loaded) {
        hits = searchIndexedCorpus(loaded.index, searchOptions);
        indexStatus = { mode: searchIndexMode, used: true, path: loaded.path, builtAt: loaded.index.builtAt };
      } else {
        files = listOrgLikeFiles(searchRootDir, recursive, includeArchives);
        const scanned = searchFilesByScan(files, searchOptions);
        hits = scanned.hits;
        skippedFileCount = scanned.skippedFileCount;
        indexStatus = { mode: searchIndexMode, used: false, stale: true };
      }
    } else if (canUseIndex && searchIndexMode === "auto") {
      const loaded = loadFreshSearchIndex({ rootDir: searchRootDir, files, recursive, includeArchives });
      if (loaded) {
        hits = searchIndexedCorpus(loaded.index, searchOptions);
        indexStatus = { mode: searchIndexMode, used: true, path: loaded.path, builtAt: loaded.index.builtAt };
      } else {
        const scanned = searchFilesByScan(files, searchOptions);
        hits = scanned.hits;
        skippedFileCount = scanned.skippedFileCount;
        indexStatus = { mode: searchIndexMode, used: false, stale: true };
      }
    } else {
      const scanned = searchFilesByScan(files, searchOptions);
      hits = scanned.hits;
      skippedFileCount = scanned.skippedFileCount;
      indexStatus = canUseIndex ? { mode: searchIndexMode, used: false } : undefined;
    }

    if (skippedFileCount > 0 && !verboseErrors) {
      console.error(`Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`);
    }

    const normalizedSort = String(searchSort || "scan").toLowerCase();
    const limitedHits = hits;

    if (searchFormat === "json") {
      process.stdout.write(
        JSON.stringify(searchPayload({
          query: searchTerm,
          subtree: querySubtree,
          sort: normalizedSort,
          dateFrom,
          dateTo,
          fileZones: searchFileZoneFiltersRaw,
          index: indexStatus,
          results: limitedHits,
        }), null, 2) + "\n",
      );
      return;
    }
    if (limitedHits.length === 0) {
      process.stdout.write("No matches found.\n");
      return;
    }
    for (const h of limitedHits) {
      const meta = [h.todo, ...(h.tags || []).map((t) => `:${t}:`)].filter(Boolean).join(" ");
      process.stdout.write(`${h.file}:${h.line}${h.heading ? ` ${h.heading}` : ""}${meta ? ` [${meta}]` : ""}\n  ${h.snippet}\n`);
    }
    return;
  }

  if (command === "query") {
    if (queryRelations || queryActions) return;
    if (!queryId && !queryText) {
      console.error("Error: query requires --id UUID or --text TEXT");
      process.exit(1);
    }
    if (queryId && queryText) {
      console.error("Error: query accepts either --id UUID or --text TEXT, not both");
      process.exit(1);
    }

    const needle = queryId.toLowerCase();
    const textNeedle = queryText.toLowerCase();

    // Determine files to search (same logic as backlinks/agenda)
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);

          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0) {
      const listOrgFiles = (dirPath: string): string[] => {
        const out: string[] = [];
        const entries = fs.readdirSync(dirPath, { withFileTypes: true });
        for (const entry of entries) {
          const fullPath = path.join(dirPath, entry.name);
          if (entry.isDirectory()) {
            if (!recursive) continue;
            if (entry.name.startsWith(".")) continue;
            out.push(...listOrgFiles(fullPath));
            continue;
          }
          if (!entry.isFile()) continue;
          if (!(entry.name.endsWith(".org") || entry.name.endsWith(".org2"))) continue;
          if (entry.name.startsWith(".#")) continue;
          out.push(fullPath);
        }
        return out;
      };

      files = listOrgFiles(dir);
    }

    type QueryHit = {
      kind: "file" | "headline" | "text";
      id?: string;
      file: string;
      line: number; // 0-based
      title: string;
      headingLine?: number; // 0-based
      snippet?: string;
    };

    const hits: QueryHit[] = [];
    let skippedFileCount = 0;

    const findFileTitle = (lines: string[]): string | null => {
      for (let j = 0; j < Math.min(lines.length, 50); j += 1) {
        const m = /^#\+title:\s*(.*?)\s*$/i.exec((lines[j] ?? "").trim());
        if (m) return m[1] || null;
      }
      return null;
    };

    const parseHeadlineTitle = (headlineLine: string): string => parseHeadlineTitleForRoam(headlineLine);

    for (const filePath of files) {
      try {
        const raw = fs.readFileSync(filePath, "utf8").replace(/\r\n/g, "\n");
        const lines = raw.split("\n");

        let inProps = false;
        let propsStart = -1; // 0-based
        let currentHeadingLine = -1;
        let currentHeadingTitle = findFileTitle(lines) ?? path.basename(filePath);

        for (let j = 0; j < lines.length; j += 1) {
          const rawLine = lines[j] ?? "";
          const l = rawLine.trim();

          if (/^\*+\s+/.test(rawLine)) {
            currentHeadingLine = j;
            currentHeadingTitle = parseHeadlineTitle(rawLine);
          }

          if (queryText && rawLine.toLowerCase().includes(textNeedle)) {
            hits.push({
              kind: "text",
              file: filePath,
              line: j,
              title: currentHeadingTitle,
              ...(currentHeadingLine >= 0 ? { headingLine: currentHeadingLine } : {}),
              snippet: rawLine.trim(),
            });
          }

          if (l === ":PROPERTIES:") {
            inProps = true;
            propsStart = j;
            continue;
          }
          if (l === ":END:") {
            inProps = false;
            propsStart = -1;
            continue;
          }

          if (!inProps) continue;

          if (!queryId) continue;

          const m = /^:ID:\s*(\S+)\s*$/.exec(l);
          if (!m) continue;

          const found = (m[1] ?? "").toLowerCase();
          if (found !== needle) continue;

          // Determine whether this is file-level or headline-level by checking if
          // the drawer is at the top of file (allowing leading blanks/comments).
          let idx = 0;
          while (idx < lines.length) {
            const t = (lines[idx] ?? "").trim();
            if (t === "" || t.startsWith("#")) {
              idx += 1;
              continue;
            }
            break;
          }

          const isFile = propsStart === idx;

          if (isFile) {
            hits.push({
              kind: "file",
              id: found,
              file: filePath,
              line: j,
              title: findFileTitle(lines) ?? path.basename(filePath),
            });
          } else {
            // Find the headline for this drawer by scanning upward.
            let headlineLine = -1;
            let headlineText = "";
            for (let k = propsStart - 1; k >= 0; k -= 1) {
              const s = lines[k] ?? "";
              if (/^\*+\s+/.test(s)) {
                headlineLine = k;
                headlineText = s;
                break;
              }
            }

            hits.push({
              kind: "headline",
              id: found,
              file: filePath,
              line: j,
              headingLine: headlineLine >= 0 ? headlineLine : undefined,
              title: headlineText ? parseHeadlineTitle(headlineText) : path.basename(filePath),
            });
          }
        }
      } catch (err) {
        skippedFileCount += 1;
        if (verboseErrors) {
          console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
        }
      }
    }

    if (skippedFileCount > 0 && !verboseErrors) {
      console.error(
        `Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`,
      );
    }

    hits.sort((a, b) => (a.file + ":" + a.line).localeCompare(b.file + ":" + b.line));

    if (queryFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:query:v1",
            ...(queryId ? { id: needle } : { text: queryText }),
            results: hits.map((h) => ({
              kind: h.kind,
              ...(h.id !== undefined ? { id: h.id } : {}),
              file: h.file,
              line: h.line,
              lineNumber: h.line + 1,
              title: h.title,
              ...(h.headingLine !== undefined ? { headingLine: h.headingLine, headingLineNumber: h.headingLine + 1 } : {}),
              ...(h.snippet !== undefined ? { snippet: h.snippet } : {}),
              citation: `${h.file}:${h.line + 1}`,
            })),
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (hits.length === 0) {
      process.stdout.write("No matches found.\n");
      return;
    }

    for (const h of hits) {
      // Print 1-based line for humans
      const suffix = h.snippet ? ` — ${h.snippet}` : "";
      process.stdout.write(`${h.kind} ${h.title} ${h.file}:${h.line + 1}${suffix}\n`);
    }

    return;
  }

  if (command === "clock") {
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);
          dir = configDir;
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);
    if (files.length === 0) {
      console.error("Error: no Org files found for clock report");
      process.exit(1);
    }
    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const report = extractClockReport(files, { rootDir });
    if (clockFormat === "json") {
      process.stdout.write(JSON.stringify({ schemaVersion: "org2-clock-report/v1", ...report }, null, 2) + "\n");
    } else {
      const renderGroup = (title: string, rows: Record<string, number>): string[] => {
        const out = [title];
        for (const [key, minutes] of Object.entries(rows).sort()) out.push(`  ${key}: ${formatClockMinutes(minutes)}`);
        if (out.length === 1) out.push("  (none)");
        return out;
      };
      const lines = [`Total: ${formatClockMinutes(report.summary.totalMinutes)}`];
      lines.push(...renderGroup("By day:", report.summary.byDay));
      lines.push(...renderGroup("By heading:", report.summary.byHeading));
      lines.push(...renderGroup("By tag:", report.summary.byTag));
      lines.push(...renderGroup("By project:", report.summary.byProject));
      lines.push(...renderGroup("By file:", report.summary.byFile));
      if (report.issues.length > 0) {
        lines.push("Issues:");
        for (const issue of report.issues) lines.push(`  ${issue.severity}: ${issue.file}:${issue.line}: ${issue.message}`);
      }
      process.stdout.write(lines.join("\n") + "\n");
    }
    return;
  }

  if (command === "compile") {
    if (compileAction !== "corpus") {
      console.error("Error: celorga compile requires a subcommand (corpus)");
      process.exit(1);
    }

    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);

          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
          dir = configDir;
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0) {
      files = listOrgLikeFiles(dir, recursive, includeArchives);
    }

    if (files.length === 0) {
      console.error("Error: no Org files found to compile");
      process.exit(1);
    }

    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const defaultCache = defaultCorpusCachePath(rootDir);
    const corpus = compileIncremental
      ? compileCorpusIncremental(files, { rootDir, cacheFile: compileCache || defaultCache })
      : compileCorpus(files, { rootDir });
    const outText = renderCompiledCorpus(corpus, compileFormat);

    if (compileOut) {
      const outPath = path.resolve(compileOut);
      fs.mkdirSync(path.dirname(outPath), { recursive: true });
      fs.writeFileSync(outPath, outText, "utf8");
      process.stdout.write(outPath + "\n");
    } else {
      process.stdout.write(outText);
    }

    return;
  }


  if (command === "entity") {
    if (entityAction !== "show") { console.error("Error: celorga entity requires subcommand show"); process.exit(1); }
    if (!entityName.trim()) { console.error("Error: celorga entity show requires an entity name/id/alias"); process.exit(1); }
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);
          dir = configDir;
        } catch (err) { console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`); process.exit(1); }
      } else { console.error("Error: provide either --dir, --files, or celorga.json config"); process.exit(1); }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);
    if (files.length === 0) { console.error("Error: no Org files found to compile"); process.exit(1); }
    const rootDir = dir ? path.resolve(dir) : path.dirname(path.resolve(files[0]!));
    const corpus = compileCorpus(files, { rootDir });
    const needle = entityName.trim().toLowerCase().replace(/\s+/g, " ");
    const profile = (corpus.entityProfiles || []).find((p) => p.entityId.toLowerCase() === needle || p.canonicalName.toLowerCase() === needle || p.aliases.some((alias) => alias.toLowerCase() === needle));
    if (!profile) { console.error(`Error: no entity profile found for '${entityName}'`); process.exit(1); }
    if (entityFormat === "json") process.stdout.write(JSON.stringify(profile, null, 2) + "\n");
    else {
      const lines = [`${profile.canonicalName} (${profile.type})`, `ID: ${profile.entityId}`];
      if (profile.aliases.length) lines.push(`Aliases: ${profile.aliases.join(", ")}`);
      lines.push(`Nodes: ${profile.nodeKeys.length}`, `Backlinks: ${profile.backlinks.length}`, `Mentions: ${profile.mentions.length}`, `Relations: ${profile.relations.length}`);
      if (profile.facts.length) { lines.push("Facts:"); for (const fact of profile.facts) lines.push(`  - ${fact.key}: ${fact.value} (${fact.provenance.map((p) => `${p.file}:${p.line}`).join(", ")})`); }
      if (profile.reviewNeeded.length) { lines.push("Review needed:"); for (const item of profile.reviewNeeded) lines.push(`  - ${item.message}`); }
      process.stdout.write(lines.join("\n") + "\n");
    }
    return;
  }

  if (command === "graph") {
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);
          if (files.length === 0) {
            console.error(`Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`);
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }
    if (dir && files.length === 0) files = listOrgLikeFiles(dir, recursive, includeArchives);

    const report = buildGraphAuditReport(files);
    if (graphFormat === "json" || graphAction === "repair-candidates") {
      const payload = graphAction === "repair-candidates"
        ? { $schema: "org2:graph-repair-candidates:v1", candidates: report.findings.filter((finding) => finding.deterministicFix || finding.reviewSuggestion), summary: report.summary }
        : report;
      process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
    } else {
      process.stdout.write(renderGraphAuditReportText(report));
    }
    return;
  }

  if (command === "lint") {
    // Determine files to lint (same fallback logic as agenda/backlinks/query).
    if (!dir && files.length === 0) {
      const configPath = findConfigFile(process.cwd());
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          const configDir = path.dirname(configPath);
          files = resolveFilesFromConfig(config, configDir);

          if (files.length === 0) {
            console.error(
              `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
            );
            process.exit(1);
          }
        } catch (err) {
          console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
          process.exit(1);
        }
      } else {
        console.error("Error: provide either --dir, --files, or celorga.json config");
        process.exit(1);
      }
    }

    if (dir && files.length === 0) {
      files = listOrgLikeFiles(dir, recursive, includeArchives);
    }

    const issues: ArtifactLintIssue[] = [];
    let skippedFileCount = 0;
    const allArtifactIds = new Set<string>();
    const artifactIdRefs = [] as ReturnType<typeof collectArtifactIdsInText>;
    const fileContents = new Map<string, string>();

    for (const filePath of files) {
      try {
        const raw = fs.readFileSync(filePath, "utf8");
        fileContents.set(filePath, raw);
        for (const ref of collectArtifactIdsInText(raw, filePath)) {
          allArtifactIds.add(ref.id);
          artifactIdRefs.push(ref);
        }
      } catch (err) {
        skippedFileCount += 1;
        if (verboseErrors) {
          console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
        }
      }
    }

    for (const duplicate of findDuplicateArtifactIds(artifactIdRefs)) {
      const primary = duplicate.refs[0];
      const alsoSeen = duplicate.refs
        .slice(1)
        .map((ref) => `${ref.file}:${ref.line}`)
        .join(", ");

      issues.push({
        severity: "error",
        rule: "artifact-id-duplicate",
        file: primary.file,
        line: primary.line,
        message: `ID '${duplicate.id}' appears multiple times in the scanned corpus (also at ${alsoSeen}).`,
      });
    }

    for (const filePath of files) {
      const raw = fileContents.get(filePath);
      if (typeof raw !== "string") continue;

      issues.push(...lintArtifactMetadataInText(raw, filePath));
      appendArtifactFreshnessLintIssues(raw, filePath, issues);
      appendHabitLintIssues(raw, filePath, issues);
      appendCheckboxProgressLintIssues(raw, filePath, issues);
      appendEffortLintIssues(raw, filePath, issues);

      for (const ref of collectArtifactProvenanceRefsInText(raw, filePath)) {
        if (ref.kind === "file") {
          const resolvedPath = path.resolve(path.dirname(filePath), ref.value);
          if (fs.existsSync(resolvedPath)) continue;

          issues.push({
            severity: "error",
            rule: "artifact-provenance-file-missing",
            file: ref.file,
            line: ref.line,
            message: `ORG2_PROVENANCE file reference '${ref.value}' does not exist relative to ${path.dirname(filePath) || "."}.`,
          });
          continue;
        }

        if (ref.kind === "id" || ref.kind === "artifact") {
          const normalizedId = String(ref.value || "").trim().toLowerCase();
          if (!normalizedId || allArtifactIds.has(normalizedId)) continue;

          const rule = ref.kind === "artifact" ? "artifact-provenance-artifact-missing" : "artifact-provenance-id-missing";
          const label = ref.kind === "artifact" ? "artifact" : "id";

          issues.push({
            severity: "error",
            rule,
            file: ref.file,
            line: ref.line,
            message: `ORG2_PROVENANCE ${label} reference '${ref.value}' was not found in the scanned corpus.`,
          });
        }
      }
    }

    appendRoamGraphLintIssues(files, issues);

    issues.sort((a, b) => {
      const fileCmp = a.file.localeCompare(b.file);
      if (fileCmp !== 0) return fileCmp;
      return a.line - b.line;
    });

    if (lintFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:lint:v1",
            checkedFiles: files.length,
            skippedFiles: skippedFileCount,
            issueCount: issues.length,
            issues,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    if (issues.length === 0) {
      process.stdout.write(`OK: checked ${files.length} file(s), no graph/artifact health issues found.\n`);
    } else {
      for (const issue of issues) {
        process.stdout.write(
          `${issue.severity.toUpperCase()} ${issue.rule} ${issue.file}:${issue.line} ${issue.message}\n`,
        );
      }
      process.stdout.write(`\nFound ${issues.length} issue(s) across ${files.length} file(s).\n`);
    }

    if (skippedFileCount > 0) {
      process.stderr.write(
        `Skipped ${skippedFileCount} file(s) due to read/parse errors (use --verbose-errors to see details).\n`,
      );
    }

    return;
  }

  if (command === "todo") {
    if (!todoFile) {
      console.error("Error: todo requires --file FILE");
      process.exit(1);
    }
    if (!Number.isFinite(todoLine) || todoLine < 1) {
      console.error("Error: todo requires --line N (1-based) or --pos LINE[:COL]");
      process.exit(1);
    }

    if (todoAction === "approve") {
      todoStatus = "done";
    }

    if (todoAction === "set") {
      if (!todoKeyword && (!todoStatus || (todoStatus !== "todo" && todoStatus !== "in_progress" && todoStatus !== "done" && todoStatus !== "canceled"))) {
        console.error("Error: todo set requires --status todo|in_progress|done|canceled (aliases: open/backlog, in-progress/in progress/prog/doing/started/waiting/blocked/next/wip, complete/completed/finish/finished/closed/resolved, cancel/cancelled)");
        process.exit(1);
      }
    }
    if (todoAction === "assign" && !todoAssignee.trim()) {
      console.error("Error: todo assign requires --assignee NAME");
      process.exit(1);
    }

    let nowDate: Date | undefined;
    if (todoNow) {
      const d = new Date(todoNow);
      if (isNaN(d.getTime())) {
        console.error(`Error: invalid --now ${todoNow}`);
        process.exit(1);
      }
      nowDate = d;
    }

    let todoLogbookEffective = todoLogbook;
    if (!todoLogbookFlagSet) {
      const configPath = findConfigFile(path.dirname(path.resolve(todoFile)));
      if (configPath) {
        try {
          const config = loadConfig(configPath);
          if (config.todo?.writeTransitionLogbook === true) {
            todoLogbookEffective = true;
          }
        } catch (err) {
          console.error(
            `Error: failed to load config from ${configPath}: ${err instanceof Error ? err.message : String(err)}`
          );
          process.exit(1);
        }
      }
    }

    const beforeRaw = fs.readFileSync(todoFile, "utf8").replace(/\r\n/g, "\n");

    let res = todoAction === "assign"
      ? assignTodoInText(beforeRaw, {
          filePath: todoFile,
          lineNumber: todoLine,
          assignee: todoAssignee,
          ...(todoAgentRef ? { agentRef: todoAgentRef } : {}),
          ...(todoGoalRef ? { goalRef: todoGoalRef } : {}),
        })
      : updateTodoInText(beforeRaw, {
          filePath: todoFile,
          lineNumber: todoLine,
          ...(todoAction === "toggle" ? { toggle: true } : { status: todoStatus as TodoStatus }),
          ...(todoKeyword ? { keyword: todoKeyword } : {}),
          ...(nowDate ? { now: nowDate } : {}),
          ...(todoLogbookEffective ? { logbook: true } : {}),
        });

    if (todoAction !== "assign" && "newStatus" in res && res.newStatus === "done") {
      const handoff = applyNestedApprovalHandoffInText(res.text, res.headingLineNumber, formatOrgTimestamp(nowDate || new Date()));
      if (handoff.changed) {
        res = { ...res, changed: true, text: handoff.text };
      }
    }

    if (todoApply) {
      fs.writeFileSync(todoFile, res.text, "utf8");
    }

    if (todoFormat === "diff") {
      if (!res.changed) return;
      process.stdout.write(buildUnifiedDiff(beforeRaw, res.text, {
        targetPath: todoFile,
        temporaryDirectoryPrefix: "org2-todo-diff-",
      }));
      return;
    }

    if (todoFormat === "text") {
      process.stdout.write(res.text + (res.text.endsWith("\n") ? "" : "\n"));
    } else {
      process.stdout.write(
        JSON.stringify(
          {
            file: res.filePath,
            headingLine: res.headingLineNumber,
            ...(todoAction === "assign"
              ? {
                  property: "ASSIGNEE",
                  ...("oldAssignee" in res && res.oldAssignee ? { oldAssignee: res.oldAssignee } : {}),
                  newAssignee: "newAssignee" in res ? res.newAssignee : todoAssignee,
                  ...("newAgentRef" in res && res.newAgentRef ? { agentRef: res.newAgentRef } : {}),
                  ...("newGoalRef" in res && res.newGoalRef ? { goalRef: res.newGoalRef } : {}),
                }
              : {
                  oldStatus: "oldStatus" in res ? res.oldStatus : undefined,
                  newStatus: "newStatus" in res ? res.newStatus : undefined,
                  oldKeyword: "oldKeyword" in res ? res.oldKeyword : undefined,
                  newKeyword: "newKeyword" in res ? res.newKeyword : undefined,
                  ...("closedAt" in res && res.closedAt ? { closedAt: res.closedAt } : {}),
                }),
            applied: todoApply,
            changed: res.changed,
          },
          null,
          2,
        ) + "\n",
      );
    }

    return;
  }

  if (command === "plan") {
    if (!planFile) {
      console.error("Error: plan requires --file FILE");
      process.exit(1);
    }
    if (!Number.isFinite(planLine) || planLine < 1) {
      console.error("Error: plan requires --line N (1-based) or --pos LINE[:COL]");
      process.exit(1);
    }
    if (!planKind || (planKind !== "scheduled" && planKind !== "deadline")) {
      console.error("Error: plan requires --kind scheduled|deadline");
      process.exit(1);
    }
    if (planAction === "today") {
      planDate = today;
    }

    planDate = planDate.trim();
    if (!planDate) {
      console.error("Error: plan requires --date YYYY-MM-DD (or use `plan today`)");
      process.exit(1);
    }

    const beforeRaw = fs.readFileSync(planFile, "utf8").replace(/\r\n/g, "\n");

    const res = updatePlanningInText(beforeRaw, {
      filePath: planFile,
      lineNumber: planLine,
      kind: planningKindFromArg(planKind as PlanningKindArg),
      date: planDate,
    });

    if (planApply) {
      fs.writeFileSync(planFile, res.text, "utf8");
    }

    if (planFormat === "diff") {
      if (!res.changed) return;
      process.stdout.write(buildUnifiedDiff(beforeRaw, res.text, {
        targetPath: planFile,
        temporaryDirectoryPrefix: "org2-plan-diff-",
      }));
      return;
    }

    if (planFormat === "text") {
      process.stdout.write(res.text + (res.text.endsWith("\n") ? "" : "\n"));
    } else {
      process.stdout.write(
        JSON.stringify(
          {
            file: res.filePath,
            headingLine: res.headingLineNumber,
            kind: res.kind,
            date: res.date,
            applied: planApply,
            changed: res.changed,
          },
          null,
          2,
        ) + "\n",
      );
    }

    return;
  }

  if (command === "crypt") {
    if (!cryptFile) {
      console.error("Error: crypt requires --file FILE");
      process.exit(1);
    }
    if (!Number.isFinite(cryptLine) || cryptLine < 1) {
      console.error("Error: crypt requires --line N (1-based) or --pos LINE[:COL]");
      process.exit(1);
    }
    if (!cryptGpgProgram.trim()) {
      console.error("Error: crypt requires --gpg-program PATH");
      process.exit(1);
    }

    const beforeRaw = fs.readFileSync(cryptFile, "utf8").replace(/\r\n/g, "\n");
    const lines = beforeRaw.split("\n");
    const targetIdx = Math.min(Math.max(cryptLine - 1, 0), Math.max(lines.length - 1, 0));

    let headingIdx = -1;
    let headingLevel = 0;
    for (let idx = targetIdx; idx >= 0; idx -= 1) {
      const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
      if (!m) continue;
      headingIdx = idx;
      headingLevel = m[1]!.length;
      break;
    }
    if (headingIdx < 0) {
      console.error("Error: no headline found at or above --line/--pos");
      process.exit(1);
    }

    let subtreeEnd = lines.length;
    for (let idx = headingIdx + 1; idx < lines.length; idx += 1) {
      const m = /^(\*+)\s+/.exec(lines[idx] ?? "");
      if (m && m[1]!.length <= headingLevel) {
        subtreeEnd = idx;
        break;
      }
    }

    const splitCryptPropertyValues = (raw: string): string[] =>
      String(raw || "")
        .split(/[,\n]/)
        .map((v) => v.trim())
        .filter(Boolean);

    const parseCryptProperties = (sourceLines: string[], sourceHeadingIdx: number, sourceSubtreeEnd: number) => {
      const recipients: string[] = [];
      const recipientFiles: string[] = [];
      let inDrawer = false;
      for (let idx = sourceHeadingIdx + 1; idx < sourceSubtreeEnd; idx += 1) {
        const line = sourceLines[idx] ?? "";
        if (!inDrawer) {
          if (/^\s*:PROPERTIES:\s*$/i.test(line)) {
            inDrawer = true;
          } else if (line.trim()) {
            break;
          }
          continue;
        }
        if (/^\s*:END:\s*$/i.test(line)) break;
        const m = /^\s*:([^:]+):\s*(.*?)\s*$/.exec(line);
        if (!m) continue;
        const key = m[1]!.trim().toUpperCase().replace(/-/g, "_");
        const values = splitCryptPropertyValues(m[2] ?? "");
        if (key === "CRYPT_RECIPIENT" || key === "CRYPT_RECIPIENTS") {
          recipients.push(...values);
        } else if (key === "CRYPT_RECIPIENT_FILE" || key === "CRYPT_RECIPIENT_FILES") {
          recipientFiles.push(
            ...values.map((value) => (path.isAbsolute(value) ? value : path.resolve(path.dirname(cryptFile), value))),
          );
        }
      }
      return { recipients, recipientFiles };
    };

    const applyCryptProperties = (sourceLines: string[], sourceHeadingIdx: number, sourceSubtreeEnd: number) => {
      const props = parseCryptProperties(sourceLines, sourceHeadingIdx, sourceSubtreeEnd);
      for (const recipient of props.recipients) {
        if (!cryptRecipients.includes(recipient)) cryptRecipients.push(recipient);
      }
      for (const recipientFile of props.recipientFiles) {
        if (!cryptRecipientFiles.includes(recipientFile)) cryptRecipientFiles.push(recipientFile);
      }
    };

    applyCryptProperties(lines, headingIdx, subtreeEnd);

    const resolveDefaultGpgRecipient = (): string | null => {
      const candidates: string[] = [];
      if (cryptGpgProgram.includes("/") || cryptGpgProgram.includes(path.sep)) {
        candidates.push(path.join(path.dirname(cryptGpgProgram), "gpgconf"));
      }
      candidates.push("gpgconf");

      for (const candidate of candidates) {
        const res = spawnSync(candidate, ["--list-options", "gpg"], {
          encoding: "utf8",
          timeout: 5_000,
        });
        if (res.error || res.status !== 0) continue;
        const line = String(res.stdout || "")
          .split(/\r?\n/)
          .find((entry) => entry.startsWith("default-key:"));
        if (!line) continue;
        const fields = line.split(":");
        const value = String(fields[9] || "")
          .replace(/^"+|"+$/g, "")
          .trim();
        if (value) return value;
      }

      return null;
    };

    const defaultGpgRecipient = cryptUseDefaultRecipientSelf ? resolveDefaultGpgRecipient() : null;

    if (cryptAction !== "decrypt" && cryptUseDefaultRecipientSelf && !defaultGpgRecipient) {
      console.error("Error: crypt could not resolve GPG's configured default key as a recipient");
      process.exit(1);
    }

    if (cryptAction !== "decrypt" && !cryptPassphrase && !defaultGpgRecipient && cryptRecipients.length === 0 && cryptRecipientFiles.length === 0) {
      console.error(
        "Error: crypt encrypt/reencrypt requires --passphrase PASS, --default-recipient-self, at least one --recipient/--recipient-file, or CRYPT_RECIPIENT(S)/CRYPT_RECIPIENT_FILE(S) properties",
      );
      process.exit(1);
    }

    const beginRe = /^\s*-----BEGIN PGP MESSAGE-----\s*$/;
    const endRe = /^\s*-----END PGP MESSAGE-----\s*$/;
    let blockStart = -1;
    let blockEnd = -1;
    for (let idx = headingIdx + 1; idx < subtreeEnd; idx += 1) {
      if (blockStart === -1 && beginRe.test(lines[idx] ?? "")) {
        blockStart = idx;
        continue;
      }
      if (blockStart !== -1 && endRe.test(lines[idx] ?? "")) {
        blockEnd = idx;
        break;
      }
    }

    const runGpg = (
      action: "encrypt" | "decrypt",
      inputText: string,
    ): { ok: boolean; stdout: string; stderr: string; error?: string } => {
      const commonArgs = ["--yes", "--trust-model", "always"];
      if (action !== "decrypt" || cryptPassphrase) {
        commonArgs.unshift("--batch");
        commonArgs.push("--pinentry-mode", "loopback");
      }
      if (cryptPassphrase) commonArgs.push("--passphrase", cryptPassphrase);
      const defaultRecipientArgs = defaultGpgRecipient ? ["--recipient", defaultGpgRecipient] : [];
      const recipientArgs = cryptRecipients.flatMap((recipient) => ["--recipient", recipient]);
      const recipientFileArgs = cryptRecipientFiles.flatMap((recipientFile) => ["--recipient-file", recipientFile]);
      const commandArgs =
        action === "decrypt"
          ? [...commonArgs, "--decrypt"]
          : defaultRecipientArgs.length > 0 || recipientArgs.length > 0 || recipientFileArgs.length > 0
            ? [...commonArgs, "--armor", "--encrypt", ...defaultRecipientArgs, ...recipientArgs, ...recipientFileArgs]
            : [...commonArgs, "--armor", "--symmetric", "--cipher-algo", "AES256"];

      const res = spawnSync(cryptGpgProgram, commandArgs, {
        input: inputText,
        encoding: "utf8",
        timeout: cryptGpgTimeoutMs,
      });

      if (res.error) {
        return {
          ok: false,
          stdout: String(res.stdout || ""),
          stderr: String(res.stderr || ""),
          error: String(res.error.message || res.error),
        };
      }

      return {
        ok: res.status === 0,
        stdout: String(res.stdout || ""),
        stderr: String(res.stderr || ""),
      };
    };

    const splitPreservingTrailing = (raw: string): string[] => {
      const normalized = String(raw || "").replace(/\r\n/g, "\n");
      if (normalized.length === 0) return [];
      const noTrailing = normalized.endsWith("\n") ? normalized.slice(0, -1) : normalized;
      if (noTrailing.length === 0) return [];
      return noTrailing.split("\n");
    };

    let outText = beforeRaw;
    let changed = false;

    const decryptSubtree = (): string[] => {
      if (blockStart < 0 || blockEnd < blockStart) {
        console.error("Error: crypt decrypt found no armored PGP block in target subtree");
        process.exit(1);
      }

      const encryptedText = lines.slice(blockStart, blockEnd + 1).join("\n") + "\n";
      const normalizedEncryptedText = normalizePgpArmorForDecrypt(encryptedText);
      const gpg = runGpg("decrypt", normalizedEncryptedText);
      if (!gpg.ok) {
        const detail = [gpg.error, gpg.stderr.trim()].filter(Boolean).join(" | ");
        console.error(`Error: crypt decrypt failed${detail ? `: ${detail}` : ""}`);
        process.exit(1);
      }

      const plainLines = splitPreservingTrailing(gpg.stdout);
      return [...lines.slice(0, blockStart), ...plainLines, ...lines.slice(blockEnd + 1)];
    };

    const encryptSubtree = (sourceLines: string[], sourceHeadingIdx: number, sourceSubtreeEnd: number): string[] => {
      applyCryptProperties(sourceLines, sourceHeadingIdx, sourceSubtreeEnd);
      let encryptedBodyStart = sourceHeadingIdx + 1;
      if (/^\s*:PROPERTIES:\s*$/i.test(sourceLines[encryptedBodyStart] ?? "")) {
        for (let idx = encryptedBodyStart + 1; idx < sourceSubtreeEnd; idx += 1) {
          if (/^\s*:END:\s*$/i.test(sourceLines[idx] ?? "")) {
            encryptedBodyStart = idx + 1;
            break;
          }
        }
      }
      const plainBodyLines = sourceLines.slice(encryptedBodyStart, sourceSubtreeEnd);
      const plainBody = plainBodyLines.join("\n").trim();
      if (!plainBody) {
        console.error("Error: crypt encrypt found no plaintext body in target subtree");
        process.exit(1);
      }

      const gpgInput = plainBodyLines.join("\n") + "\n";
      const gpg = runGpg("encrypt", gpgInput);
      if (!gpg.ok) {
        const detail = [gpg.error, gpg.stderr.trim()].filter(Boolean).join(" | ");
        console.error(`Error: crypt encrypt failed${detail ? `: ${detail}` : ""}`);
        process.exit(1);
      }

      const encryptedLines = splitPreservingTrailing(gpg.stdout);
      return [...sourceLines.slice(0, encryptedBodyStart), ...encryptedLines, ...sourceLines.slice(sourceSubtreeEnd)];
    };

    if (cryptAction === "decrypt") {
      outText = decryptSubtree().join("\n");
      changed = outText !== beforeRaw;
    } else if (cryptAction === "encrypt") {
      if (blockStart >= 0 && blockEnd >= blockStart) {
        console.error("Error: crypt encrypt target subtree already contains an armored PGP block");
        process.exit(1);
      }
      outText = encryptSubtree(lines, headingIdx, subtreeEnd).join("\n");
      changed = outText !== beforeRaw;
    } else {
      const decryptedLines = decryptSubtree();
      let newSubtreeEnd = decryptedLines.length;
      for (let idx = headingIdx + 1; idx < decryptedLines.length; idx += 1) {
        const m = /^(\*+)\s+/.exec(decryptedLines[idx] ?? "");
        if (m && m[1]!.length <= headingLevel) {
          newSubtreeEnd = idx;
          break;
        }
      }
      outText = encryptSubtree(decryptedLines, headingIdx, newSubtreeEnd).join("\n");
      changed = outText !== beforeRaw;
    }

    if (cryptApply && changed) {
      fs.writeFileSync(cryptFile, outText, "utf8");
    }

    if (cryptFormat === "diff") {
      if (changed) {
        process.stdout.write(buildUnifiedDiff(beforeRaw, outText, {
          targetPath: cryptFile,
          temporaryDirectoryPrefix: "org2-crypt-diff-",
        }));
      }
      return;
    }

    if (cryptFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:crypt:v1",
            action: cryptAction,
            file: cryptFile,
            headingLine: headingIdx + 1,
            applied: cryptApply,
            changed,
            gpgProgram: cryptGpgProgram,
            defaultRecipientSelf: cryptUseDefaultRecipientSelf,
            recipients: cryptRecipients,
            recipientFiles: cryptRecipientFiles,
          },
          null,
          2,
        ) + "\n",
      );
      return;
    }

    process.stdout.write(outText + (outText.endsWith("\n") ? "" : "\n"));
    return;
  }

  if (command === "fmt") {
    const formatOne = (rawIn: string, canonicalOrgSyntax = fmtCanonicalOrg, sourcePath?: string): string => {
      const normalized = rawIn.replace(/\r\n/g, "\n");
      const { text: protectedText, blocks } = protectPgpBlocks(normalized);
      const ast = parseOrgToCanonicalAst(protectedText, { sourcePath });
      if (canonicalOrgSyntax) canonicalizeOrgSyntaxSugar(ast);
      const formatted = printCanonicalAstToOrg(ast);
      return restorePgpBlocks(formatted, blocks);
    };

    const shouldCanonicalizeFmtFile = (file: string): boolean =>
      fmtCanonicalOrg || path.extname(file).toLowerCase() === ".org";

    const emitFmtCheckJson = (checkedFiles: string[], changedFiles: string[]): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-check:v1",
            changed: changedFiles.length > 0,
            checkedFiles,
            changedFiles,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const emitFmtPreviewJson = (file: string, formattedText: string, changed: boolean): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-preview:v1",
            file,
            changed,
            formattedText,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const emitFmtApplyJson = (processedFiles: string[], changedFiles: string[]): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-apply:v1",
            changed: changedFiles.length > 0,
            processedFiles,
            changedFiles,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const emitFmtStdinJson = (formattedText: string, changed: boolean): void => {
      process.stdout.write(
        JSON.stringify(
          {
            $schema: "org2:fmt-stdin:v1",
            changed,
            formattedText,
          },
          null,
          2,
        ) + "\n",
      );
    };

    const parsedFmtFile = parseAgendaFileFilterArgs(fmtFileFiltersRaw);
    const parsedFmtExcludeFile = parseAgendaExcludeFileFilterArgs(fmtExcludeFileFiltersRaw);

    if (fmtStdin) {
      if (fmtConfigPath) {
        console.error("Error: fmt --stdin cannot be combined with --config");
        process.exit(1);
      }
      if (parsedFmtFile || parsedFmtExcludeFile) {
        console.error("Error: fmt --stdin cannot be combined with --file-match/--exclude-file");
        process.exit(1);
      }
      if (fmtCheck) {
        console.error("Error: fmt --check does not support --stdin");
        process.exit(1);
      }
      if (dir || files.length > 0) {
        console.error("Error: fmt --stdin cannot be combined with --dir/--file/--files");
        process.exit(1);
      }
      const stdinRaw = await readStdinText();
      const normalizedStdinRaw = stdinRaw.replace(/\r\n/g, "\n");
      const formattedText = formatOne(stdinRaw, fmtCanonicalOrg);

      if (fmtFormat === "json") {
        emitFmtStdinJson(formattedText, formattedText !== normalizedStdinRaw);
        return;
      }

      process.stdout.write(formattedText);
      return;
    }

    if (fmtConfigPath && (dir || files.length > 0)) {
      console.error("Error: fmt --config cannot be combined with --dir/--file/--files");
      process.exit(1);
    }

    const fmtFiles: string[] = [];
    const seenFmtFiles = new Set<string>();

    const normalizeFmtPathFromConfig = (resolvedPath: string): string => {
      const rel = path.relative(process.cwd(), resolvedPath);
      if (!rel) return resolvedPath;
      if (rel === ".." || rel.startsWith(`..${path.sep}`)) return resolvedPath;
      return rel;
    };

    const addFmtFile = (filePath: string): void => {
      if (!matchesAgendaFileFilter(filePath, parsedFmtFile)) return;
      if (!matchesAgendaExcludeFileFilter(filePath, parsedFmtExcludeFile)) return;

      const dedupeKey = path.resolve(filePath);
      if (seenFmtFiles.has(dedupeKey)) return;
      seenFmtFiles.add(dedupeKey);
      fmtFiles.push(filePath);
    };

    for (const file of files) {
      addFmtFile(file);
    }

    if (dir) {
      const scanned = listOrgLikeFiles(dir, recursive, includeArchives);
      for (const filePath of scanned) {
        addFmtFile(filePath);
      }
    }

    if (fmtConfigPath) {
      const configPathResolved = path.resolve(fmtConfigPath);

      try {
        const cfg = loadConfig(configPathResolved);
        const configDir = path.dirname(configPathResolved);
        const resolvedFromConfig = resolveFilesFromConfig(cfg, configDir);

        for (const resolvedFile of resolvedFromConfig) {
          addFmtFile(normalizeFmtPathFromConfig(resolvedFile));
        }
      } catch (err) {
        console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
        process.exit(1);
      }
    }

    fmtFiles.sort((a, b) => a.localeCompare(b));

    if (fmtFiles.length === 0) {
      console.error(
        "Error: fmt found no matching files (provide --stdin, --dir DIR, --config PATH, or at least one file via --file/--files; check --file-match/--exclude-file filters)",
      );
      process.exit(1);
    }

    if (fmtCheck) {
      const changedFiles: string[] = [];
      for (const file of fmtFiles) {
        const raw = fs.readFileSync(file, "utf8");
        const out = formatOne(raw, shouldCanonicalizeFmtFile(file), file);
        if (out !== raw.replace(/\r\n/g, "\n")) {
          changedFiles.push(file);
        }
      }

      if (fmtFormat === "json") {
        emitFmtCheckJson(fmtFiles, changedFiles);
        if (changedFiles.length > 0) {
          process.exit(1);
        }
        return;
      }

      if (changedFiles.length > 0) {
        process.stdout.write(changedFiles.join("\n") + "\n");
        process.exit(1);
      }
      return;
    }

    if (!fmtApply) {
      if (fmtFiles.length !== 1) {
        console.error("Error: fmt without --apply requires exactly one file (use --check/--apply for multiple)");
        process.exit(1);
      }
      const targetFile = fmtFiles[0]!;
      const raw = fs.readFileSync(targetFile, "utf8");
      const out = formatOne(raw, shouldCanonicalizeFmtFile(targetFile), targetFile);

      if (fmtFormat === "json") {
        emitFmtPreviewJson(targetFile, out, out !== raw.replace(/\r\n/g, "\n"));
        return;
      }

      process.stdout.write(out);
      return;
    }

    const changedFiles: string[] = [];
    for (const file of fmtFiles) {
      const raw = fs.readFileSync(file, "utf8");
      const normalizedRaw = raw.replace(/\r\n/g, "\n");
      const out = formatOne(raw, shouldCanonicalizeFmtFile(file), file);
      if (out !== normalizedRaw) {
        fs.writeFileSync(file, out, "utf8");
        changedFiles.push(file);
      }
    }

    if (fmtFormat === "json") {
      emitFmtApplyJson(fmtFiles, changedFiles);
    }

    return;
  }

  if (command === "refile") {
    if (!refileFile) {
      console.error("Error: refile requires --file FILE");
      process.exit(1);
    }
    if (!refilePos) {
      console.error("Error: refile requires --pos LINE[:COL]");
      process.exit(1);
    }
    if (!refileToFile) {
      console.error("Error: refile requires --to-file FILE");
      process.exit(1);
    }

    const parsePosLine = (rawPos: string, flagName: string): number => {
      const line = parseInt(String(rawPos || "").split(":")[0] || "", 10);
      if (!Number.isFinite(line) || line < 1) {
        console.error(`Error: invalid ${flagName} ${rawPos}`);
        process.exit(1);
      }
      return line;
    };

    const normalizeOutText = (lines: string[]): string => {
      const text = lines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd();
      return text.length > 0 ? `${text}\n` : "";
    };

    const sourcePathInput = refileFile;
    const destinationPathInput = refileToFile;
    const sourcePath = path.resolve(sourcePathInput);
    const destinationPath = path.resolve(destinationPathInput);
    const sameFile = sourcePath === destinationPath;

    const sourceRaw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
    const sourceLines = sourceRaw.split("\n");

    const sourcePosLine1 = parsePosLine(refilePos, "--pos");
    let sourceHeadingIndex: number;
    try {
      sourceHeadingIndex = findHeadingAtOrAbove(sourceLines, sourcePosLine1);
    } catch {
      console.error("Error: no source headline found at or above --pos");
      process.exit(1);
    }
    const sourceHeadingLine = sourceLines[sourceHeadingIndex] ?? "";

    const sourceRange = computeSubtreeRange(sourceLines, sourceHeadingIndex);
    const sourceEndExclusive = sourceRange.endExclusive;
    const sourceSubtreeLines = sourceLines.slice(sourceHeadingIndex, sourceEndExclusive);
    const sourceSubtreeText = sourceSubtreeLines.join("\n").trimEnd() + "\n";

    const sourceRemainingLines = [
      ...sourceLines.slice(0, sourceHeadingIndex),
      ...sourceLines.slice(sourceEndExclusive),
    ];
    const sourceOutText = normalizeOutText(sourceRemainingLines);

    const destinationRaw = sameFile
      ? sourceRaw
      : fs.existsSync(destinationPath)
        ? fs.readFileSync(destinationPath, "utf8").replace(/\r\n/g, "\n")
        : "";

    const destinationBaseText = sameFile ? sourceOutText : destinationRaw;
    const destinationLines = destinationBaseText.length > 0 ? destinationBaseText.split("\n") : [];

    let destinationInsertIndex = destinationLines.length;
    let destinationHeadingLine1: number | null = null;
    let movedSubtreeLines = [...sourceSubtreeLines];
    let headingLevelDelta = 0;

    if (refileToPos) {
      const toPosLine1Raw = parsePosLine(refileToPos, "--to-pos");
      if (
        sameFile &&
        toPosLine1Raw >= sourceHeadingIndex + 1 &&
        toPosLine1Raw <= sourceEndExclusive
      ) {
        console.error("Error: --to-pos cannot point inside the subtree being moved");
        process.exit(1);
      }

      const removedLineCount = sourceEndExclusive - sourceHeadingIndex;
      const toPosLine1Adjusted =
        sameFile && toPosLine1Raw > sourceHeadingIndex + 1
          ? Math.max(1, toPosLine1Raw - removedLineCount)
          : toPosLine1Raw;

      let destinationHeadingIndex: number;
      try {
        destinationHeadingIndex = findHeadingAtOrAbove(destinationLines, toPosLine1Adjusted);
      } catch {
        console.error("Error: no destination headline found at or above --to-pos");
        process.exit(1);
      }

      const destinationRange = computeSubtreeRange(destinationLines, destinationHeadingIndex);
      destinationHeadingLine1 = destinationHeadingIndex + 1;
      destinationInsertIndex = destinationRange.endExclusive;

      headingLevelDelta = destinationRange.level + 1 - sourceRange.level;
      if (headingLevelDelta !== 0) {
        movedSubtreeLines = sourceSubtreeLines.map((line) => {
          const m = /^(\*+)(\s+.*)$/.exec(line);
          if (!m) return line;
          const nextLevel = Math.max(1, m[1]!.length + headingLevelDelta);
          return `${"*".repeat(nextLevel)}${m[2]!}`;
        });
      }
    }

    const movedBlockText = movedSubtreeLines.join("\n").trimEnd();
    const movedBlockLines = movedBlockText.length > 0 ? movedBlockText.split("\n") : [];
    const beforeDestination = destinationLines.slice(0, destinationInsertIndex);
    const afterDestination = destinationLines.slice(destinationInsertIndex);

    const destinationOutLines = [...beforeDestination];
    if (
      destinationOutLines.length > 0 &&
      (destinationOutLines[destinationOutLines.length - 1] ?? "").trim() !== ""
    ) {
      destinationOutLines.push("");
    }
    destinationOutLines.push(...movedBlockLines);
    if (afterDestination.length > 0 && (afterDestination[0] ?? "").trim() !== "") {
      destinationOutLines.push("");
    }
    destinationOutLines.push(...afterDestination);

    const destinationOutText = normalizeOutText(destinationOutLines);

    const sourceChanged = sameFile ? destinationOutText !== sourceRaw : sourceOutText !== sourceRaw;
    const destinationChanged = sameFile ? destinationOutText !== sourceRaw : destinationOutText !== destinationRaw;
    const changed = sameFile ? sourceChanged : sourceChanged || destinationChanged;

    const sourceDiff = buildUnifiedDiff(sourceRaw, sameFile ? destinationOutText : sourceOutText, {
      targetPath: sourcePathInput,
      temporaryDirectoryPrefix: "org2-refile-source-diff-",
      useLabels: true,
    });
    const destinationDiff = sameFile
      ? ""
      : buildUnifiedDiff(destinationRaw, destinationOutText, {
          targetPath: destinationPathInput,
          temporaryDirectoryPrefix: "org2-refile-destination-diff-",
          useLabels: true,
        });
    const combinedDiff = [sourceDiff, destinationDiff].filter((part) => part.length > 0).join("\n");

    if (refileFormat === "diff") {
      if (combinedDiff) process.stdout.write(combinedDiff);
      return;
    }

    if (refileFormat === "json") {
      process.stdout.write(
        JSON.stringify(
          {
            kind: "refile",
            apply: refileApply,
            changed,
            sourceChanged,
            destinationChanged,
            sourcePath: sourcePathInput,
            destinationPath: destinationPathInput,
            sourceHeadlineLine1: sourceHeadingIndex + 1,
            sourceHeadline: sourceHeadingLine,
            destinationHeadingLine1,
            headingLevelDelta,
            sourceSubtreeText,
            newSourceText: sameFile ? destinationOutText : sourceOutText,
            newDestinationText: destinationOutText,
            diff: combinedDiff,
          },
          null,
          2,
        ) + "\n",
      );

      if (!refileApply) return;
    }

    if (!refileApply) {
      process.stdout.write(
        `Would refile subtree starting at ${sourcePathInput}:${sourceHeadingIndex + 1} to ${destinationPathInput}` +
          (destinationHeadingLine1 ? ` under heading line ${destinationHeadingLine1}` : " (file end)") +
          "\nUse --apply to write changes.\n",
      );
      return;
    }

    if (!sameFile) {
      fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
      fs.writeFileSync(sourcePath, sourceOutText, "utf8");
      fs.writeFileSync(destinationPath, destinationOutText, "utf8");
    } else {
      fs.writeFileSync(sourcePath, destinationOutText, "utf8");
    }

    if (refileFormat === "text") {
      process.stdout.write(
        `Refiled subtree from ${sourcePathInput}:${sourceHeadingIndex + 1} to ${destinationPathInput}` +
          (destinationHeadingLine1 ? ` under heading line ${destinationHeadingLine1}.` : ".") +
          "\n",
      );
    }

    return;
  }

  if (command === "archive") {
    if (files.length !== 1) {
      console.error("Error: archive requires exactly one file via --file/--files");
      process.exit(1);
    }
    if (!archivePos) {
      console.error("Error: archive requires --pos LINE[:COL]");
      process.exit(1);
    }

    const sourcePath = files[0]!;
    const raw = fs.readFileSync(sourcePath, "utf8").replace(/\r\n/g, "\n");
    const posLine = parseInt(archivePos.split(":")[0]!, 10);
    if (!Number.isFinite(posLine) || posLine < 1) {
      console.error(`Error: invalid --pos ${archivePos}`);
      process.exit(1);
    }

    const defaultArchivePath = defaultArchivePathForSource(sourcePath);
    const archivePath = archiveFile || defaultArchivePath;

    const lines = raw.split("\n");
    let headlineLineIndex = -1;
    for (let idx = Math.min(posLine - 1, lines.length - 1); idx >= 0; idx -= 1) {
      const line = lines[idx] ?? "";
      if (/^\*+\s+/.test(line)) {
        headlineLineIndex = idx;
        break;
      }
    }

    if (headlineLineIndex === -1) {
      console.error("Error: no headline found at or above --pos");
      process.exit(1);
    }

    const headlineLine = lines[headlineLineIndex] ?? "";
    const levelMatch = /^(\*+)\s+/.exec(headlineLine);
    const level = levelMatch ? levelMatch[1].length : 1;

    let endIndexExclusive = lines.length;
    for (let idx = headlineLineIndex + 1; idx < lines.length; idx += 1) {
      const line = lines[idx] ?? "";
      const m = /^(\*+)\s+/.exec(line);
      if (m && m[1].length <= level) {
        endIndexExclusive = idx;
        break;
      }
    }

    const rawSubtreeLines = lines.slice(headlineLineIndex, endIndexExclusive);
    const remainingLines = [...lines.slice(0, headlineLineIndex), ...lines.slice(endIndexExclusive)];
    const provenance = {
      archivedAt: brandEnv("ORG2_ARCHIVED_AT") || new Date().toISOString(),
      sourcePath,
      sourceLine: String(headlineLineIndex + 1),
      originalId: findArchiveOriginalId(rawSubtreeLines),
      headingPath: buildArchiveHeadingPath(lines, headlineLineIndex).join("/"),
    };
    const subtreeLines = addArchiveProvenanceDrawer(rawSubtreeLines, provenance);

    const subtreeText = subtreeLines.join("\n").trimEnd() + "\n";
    const newSourceText = remainingLines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";

    // Handle --format diff
    if (archiveFormat === "diff") {
      const diffOutput = formatArchiveDiff(sourcePath, archivePath, subtreeText);
      process.stdout.write(diffOutput);
      return;
    }

    // Handle --format json (safe-edit primitive)
    if (archiveFormat === "json") {
      if (!archiveApply) {
        const payload = {
          kind: "archive",
          apply: false,
          sourcePath,
          archivePath,
          headlineLine1: headlineLineIndex + 1,
          headline: headlineLine,
          provenance,
          subtreeText,
          newSourceText,
          diff: formatArchiveDiff(sourcePath, archivePath, subtreeText),
        };
        process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
        return;
      }

      const existingArchive = fs.existsSync(archivePath)
        ? fs.readFileSync(archivePath, "utf8").replace(/\r\n/g, "\n")
        : "";
      const archiveOut = appendSubtreeToArchiveText(existingArchive, subtreeText);

      fs.writeFileSync(sourcePath, newSourceText, "utf8");
      fs.writeFileSync(archivePath, archiveOut, "utf8");

      const payload = {
        kind: "archive",
        apply: true,
        wrote: true,
        sourcePath,
        archivePath,
        headlineLine1: headlineLineIndex + 1,
        headline: headlineLine,
        provenance,
        subtreeText,
        newSourceText,
        diff: formatArchiveDiff(sourcePath, archivePath, subtreeText),
      };
      process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
      return;
    }

    if (!archiveApply) {
      process.stdout.write(
        `Would archive subtree starting at ${sourcePath}:${headlineLineIndex + 1} to ${archivePath}\n` +
          `Subtree first line: ${headlineLine}\n` +
          `Use --apply to write changes.\n`,
      );
      return;
    }

    const existingArchive = fs.existsSync(archivePath) ? fs.readFileSync(archivePath, "utf8").replace(/\r\n/g, "\n") : "";
    const archiveOut = appendSubtreeToArchiveText(existingArchive, subtreeText);

    fs.writeFileSync(sourcePath, newSourceText, "utf8");
    fs.writeFileSync(archivePath, archiveOut, "utf8");
    process.stdout.write(`Archived to ${archivePath}\n`);
    return;
  }

  // agenda
  let agendaConfig: Org2Config | null = null;
  let agendaConfigBaseDir = process.cwd();

  // Determine files to process
  if (!dir && files.length === 0) {
    // Try to load from config
    const configPath = findConfigFile(process.cwd());
    if (configPath) {
      try {
        const config = loadConfig(configPath);
        const configDir = path.dirname(configPath);
        agendaConfig = config;
        agendaConfigBaseDir = configDir;
        files = resolveFilesFromConfig(config, configDir);

        if (files.length === 0) {
          console.error(
            `Error: config found at ${configPath} but no matching files for patterns: ${config.agendaFiles?.join(", ") || "*.org"}`,
          );
          process.exit(1);
        }
      } catch (err) {
        console.error(`Error loading config: ${err instanceof Error ? err.message : String(err)}`);
        process.exit(1);
      }
    } else {
      console.error("Error: provide either --dir, --files, or celorga.json config");
      process.exit(1);
    }
  }

  if (!agendaConfig) {
    const configLookupStart = dir ? path.resolve(dir) : process.cwd();
    const configPath = findConfigFile(configLookupStart);
    if (configPath) {
      try {
        agendaConfig = loadConfig(configPath);
        agendaConfigBaseDir = path.dirname(configPath);
      } catch {}
    }
  }

  if (dir && files.length === 0) {
    files = agendaConfig
      ? resolveFilesFromConfig(agendaConfig, agendaConfigBaseDir)
      : listAgendaFiles(dir, recursive, includeArchives);
  }

  if (dir && files.length > 0 && !agendaConfig) agendaConfigBaseDir = path.resolve(dir);

  const parsedAgendaStatus = parseAgendaStatusFilterArgs(agendaStatusFiltersRaw);
  if (parsedAgendaStatus.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --status value(s): ${parsedAgendaStatus.invalid.join(", ")}. Allowed: ${AGENDA_STATUS_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeStatus = parseAgendaExcludeStatusFilterArgs(agendaExcludeStatusFiltersRaw);
  if (parsedAgendaExcludeStatus.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-status value(s): ${parsedAgendaExcludeStatus.invalid.join(", ")}. Allowed: ${AGENDA_STATUS_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaKind = parseAgendaKindFilterArgs(agendaKindFiltersRaw);
  if (parsedAgendaKind.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --kind value(s): ${parsedAgendaKind.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeKind = parseAgendaExcludeKindFilterArgs(agendaExcludeKindFiltersRaw);
  if (parsedAgendaExcludeKind.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-kind value(s): ${parsedAgendaExcludeKind.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaWhen = parseAgendaWhenFilterArgs(agendaWhenFiltersRaw);
  if (parsedAgendaWhen.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --when value(s): ${parsedAgendaWhen.invalid.join(", ")}. Allowed: ${AGENDA_WHEN_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeWhen = parseAgendaExcludeWhenFilterArgs(agendaExcludeWhenFiltersRaw);
  if (parsedAgendaExcludeWhen.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-when value(s): ${parsedAgendaExcludeWhen.invalid.join(", ")}. Allowed: ${AGENDA_WHEN_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaWeekday = parseAgendaWeekdayFilterArgs(agendaWeekdayFiltersRaw);
  if (parsedAgendaWeekday.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --weekday value(s): ${parsedAgendaWeekday.invalid.join(", ")}. Allowed: ${AGENDA_WEEKDAY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeWeekday = parseAgendaExcludeWeekdayFilterArgs(agendaExcludeWeekdayFiltersRaw);
  if (parsedAgendaExcludeWeekday.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-weekday value(s): ${parsedAgendaExcludeWeekday.invalid.join(", ")}. Allowed: ${AGENDA_WEEKDAY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaWeek = parseAgendaWeekFilterArgs(agendaWeekFiltersRaw);
  if (parsedAgendaWeek.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --week value(s): ${parsedAgendaWeek.invalid.join(", ")}. Allowed: ${AGENDA_WEEK_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeWeek = parseAgendaExcludeWeekFilterArgs(agendaExcludeWeekFiltersRaw);
  if (parsedAgendaExcludeWeek.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-week value(s): ${parsedAgendaExcludeWeek.invalid.join(", ")}. Allowed: ${AGENDA_WEEK_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaDayOfMonth = parseAgendaDayOfMonthFilterArgs(agendaDayOfMonthFiltersRaw);
  if (parsedAgendaDayOfMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --day-of-month value(s): ${parsedAgendaDayOfMonth.invalid.join(", ")}. Allowed: ${AGENDA_DAY_OF_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeDayOfMonth = parseAgendaExcludeDayOfMonthFilterArgs(
    agendaExcludeDayOfMonthFiltersRaw,
  );
  if (parsedAgendaExcludeDayOfMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-day-of-month value(s): ${parsedAgendaExcludeDayOfMonth.invalid.join(", ")}. Allowed: ${AGENDA_DAY_OF_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaMonth = parseAgendaMonthFilterArgs(agendaMonthFiltersRaw);
  if (parsedAgendaMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --month value(s): ${parsedAgendaMonth.invalid.join(", ")}. Allowed: ${AGENDA_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeMonth = parseAgendaExcludeMonthFilterArgs(agendaExcludeMonthFiltersRaw);
  if (parsedAgendaExcludeMonth.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-month value(s): ${parsedAgendaExcludeMonth.invalid.join(", ")}. Allowed: ${AGENDA_MONTH_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaQuarter = parseAgendaQuarterFilterArgs(agendaQuarterFiltersRaw);
  if (parsedAgendaQuarter.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --quarter value(s): ${parsedAgendaQuarter.invalid.join(", ")}. Allowed: ${AGENDA_QUARTER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeQuarter = parseAgendaExcludeQuarterFilterArgs(agendaExcludeQuarterFiltersRaw);
  if (parsedAgendaExcludeQuarter.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-quarter value(s): ${parsedAgendaExcludeQuarter.invalid.join(", ")}. Allowed: ${AGENDA_QUARTER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaYear = parseAgendaYearFilterArgs(agendaYearFiltersRaw);
  if (parsedAgendaYear.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --year value(s): ${parsedAgendaYear.invalid.join(", ")}. Allowed: ${AGENDA_YEAR_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeYear = parseAgendaExcludeYearFilterArgs(agendaExcludeYearFiltersRaw);
  if (parsedAgendaExcludeYear.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-year value(s): ${parsedAgendaExcludeYear.invalid.join(", ")}. Allowed: ${AGENDA_YEAR_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaDate = parseAgendaDateFilterArgs(agendaDateFiltersRaw);
  if (parsedAgendaDate.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --date value(s): ${parsedAgendaDate.invalid.join(", ")}. Allowed: ${AGENDA_DATE_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeDate = parseAgendaExcludeDateFilterArgs(agendaExcludeDateFiltersRaw);
  if (parsedAgendaExcludeDate.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-date value(s): ${parsedAgendaExcludeDate.invalid.join(", ")}. Allowed: ${AGENDA_DATE_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaLevel = parseAgendaLevelFilterArgs(agendaLevelFiltersRaw);
  if (parsedAgendaLevel.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --level value(s): ${parsedAgendaLevel.invalid.join(", ")}. Allowed: ${AGENDA_LEVEL_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaExcludeLevel = parseAgendaExcludeLevelFilterArgs(agendaExcludeLevelFiltersRaw);
  if (parsedAgendaExcludeLevel.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-level value(s): ${parsedAgendaExcludeLevel.invalid.join(", ")}. Allowed: ${AGENDA_LEVEL_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaMatch = parseAgendaMatchFilterArgs(agendaMatchFiltersRaw);
  const parsedAgendaExcludeMatch = parseAgendaExcludeMatchFilterArgs(agendaExcludeMatchFiltersRaw);
  const parsedAgendaTag = parseAgendaTagFilterArgs(agendaTagFiltersRaw);
  const parsedAgendaId = parseAgendaIdFilterArgs(agendaIdFiltersRaw);
  if (parsedAgendaId.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --id value(s): ${parsedAgendaId.invalid.join(", ")}. Allowed: ${AGENDA_ID_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaTodo = parseAgendaTodoFilterArgs(agendaTodoFiltersRaw);
  const parsedAgendaTodoOrder = parseAgendaTodoOrderArgs(agendaTodoOrderRaw);
  const parsedAgendaStatusOrder = parseAgendaStatusOrderArgs(agendaStatusOrderRaw);
  if (parsedAgendaStatusOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --status-order value(s): ${parsedAgendaStatusOrder.invalid.join(", ")}. Allowed: ${AGENDA_STATUS_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaKindOrder = parseAgendaKindOrderArgs(agendaKindOrderRaw);
  if (parsedAgendaKindOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --kind-order value(s): ${parsedAgendaKindOrder.invalid.join(", ")}. Allowed: ${AGENDA_KIND_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaPriorityOrder = parseAgendaPriorityOrderArgs(agendaPriorityOrderRaw);
  if (parsedAgendaPriorityOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --priority-order value(s): ${parsedAgendaPriorityOrder.invalid.join(", ")}. Allowed: ${AGENDA_PRIORITY_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaTagOrder = parseAgendaTagOrderArgs(agendaTagOrderRaw);
  const parsedAgendaEffortOrder = parseAgendaEffortOrderArgs(agendaEffortOrderRaw);
  const parsedAgendaPriority = parseAgendaPriorityFilterArgs(agendaPriorityFiltersRaw);
  if (parsedAgendaPriority.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --priority value(s): ${parsedAgendaPriority.invalid.join(", ")}. Allowed: ${AGENDA_PRIORITY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaTime = parseAgendaTimeFilterArgs(agendaTimeFiltersRaw);
  if (parsedAgendaTime.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --time value(s): ${parsedAgendaTime.invalid.join(", ")}. Allowed: ${AGENDA_TIME_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaEffort = parseAgendaEffortFilterArgs(agendaEffortFiltersRaw);
  const parsedAgendaProperty = parseAgendaPropertyFilterArgs(agendaPropertyFiltersRaw);
  if (parsedAgendaProperty.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --property value(s): ${parsedAgendaProperty.invalid.join(", ")}. Allowed: ${AGENDA_PROPERTY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeTag = parseAgendaExcludeTagFilterArgs(agendaExcludeTagFiltersRaw);
  const parsedAgendaExcludeId = parseAgendaExcludeIdFilterArgs(agendaExcludeIdFiltersRaw);
  if (parsedAgendaExcludeId.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-id value(s): ${parsedAgendaExcludeId.invalid.join(", ")}. Allowed: ${AGENDA_ID_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeTodo = parseAgendaExcludeTodoFilterArgs(agendaExcludeTodoFiltersRaw);
  const parsedAgendaExcludePriority = parseAgendaExcludePriorityFilterArgs(agendaExcludePriorityFiltersRaw);
  if (parsedAgendaExcludePriority.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-priority value(s): ${parsedAgendaExcludePriority.invalid.join(", ")}. Allowed: ${AGENDA_PRIORITY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeTime = parseAgendaExcludeTimeFilterArgs(agendaExcludeTimeFiltersRaw);
  if (parsedAgendaExcludeTime.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-time value(s): ${parsedAgendaExcludeTime.invalid.join(", ")}. Allowed: ${AGENDA_TIME_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaExcludeEffort = parseAgendaExcludeEffortFilterArgs(agendaExcludeEffortFiltersRaw);
  const parsedAgendaExcludeProperty = parseAgendaExcludePropertyFilterArgs(agendaExcludePropertyFiltersRaw);
  if (parsedAgendaExcludeProperty.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --exclude-property value(s): ${parsedAgendaExcludeProperty.invalid.join(", ")}. Allowed: ${AGENDA_PROPERTY_ALLOWED_HINT}`,
    );
    process.exit(1);
  }
  const parsedAgendaFile = parseAgendaFileFilterArgs(agendaFileFiltersRaw);
  const parsedAgendaExcludeFile = parseAgendaExcludeFileFilterArgs(agendaExcludeFileFiltersRaw);
  const parsedAgendaSort = parseAgendaSortArgs(agendaSortRaw);
  if (parsedAgendaSort.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --sort value(s): ${parsedAgendaSort.invalid.join(", ")}. Allowed: ${AGENDA_SORT_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaGroup = parseAgendaGroupArgs(agendaGroupRaw);
  if (parsedAgendaGroup.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --group value(s): ${parsedAgendaGroup.invalid.join(", ")}. Allowed: ${AGENDA_GROUP_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  const parsedAgendaDateOrder = parseAgendaDateOrderArgs(agendaDateOrderRaw);
  if (parsedAgendaDateOrder.invalid.length > 0) {
    console.error(
      `Error: invalid agenda --date-order value(s): ${parsedAgendaDateOrder.invalid.join(", ")}. Allowed: ${AGENDA_DATE_ORDER_ALLOWED_HINT}`,
    );
    process.exit(1);
  }

  let agendaLimit: number | null = null;
  if (agendaLimitRaw.trim().length > 0) {
    const rawLimit = agendaLimitRaw.trim();
    if (!/^\d+$/.test(rawLimit)) {
      console.error(`Error: invalid agenda --limit value: ${agendaLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    const parsedLimit = Number.parseInt(rawLimit, 10);
    if (!Number.isFinite(parsedLimit) || parsedLimit < 1) {
      console.error(`Error: invalid agenda --limit value: ${agendaLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    agendaLimit = parsedLimit;
  }

  let agendaDayLimit: number | null = null;
  if (agendaDayLimitRaw.trim().length > 0) {
    const rawDayLimit = agendaDayLimitRaw.trim();
    if (!/^\d+$/.test(rawDayLimit)) {
      console.error(`Error: invalid agenda --day-limit value: ${agendaDayLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    const parsedDayLimit = Number.parseInt(rawDayLimit, 10);
    if (!Number.isFinite(parsedDayLimit) || parsedDayLimit < 1) {
      console.error(`Error: invalid agenda --day-limit value: ${agendaDayLimitRaw}. Expected a positive integer.`);
      process.exit(1);
    }
    agendaDayLimit = parsedDayLimit;
  }

  let agendaGroupLimit: number | null = null;
  if (agendaGroupLimitRaw.trim().length > 0) {
    const rawGroupLimit = agendaGroupLimitRaw.trim();
    if (!/^\d+$/.test(rawGroupLimit)) {
      console.error(
        `Error: invalid agenda --group-limit value: ${agendaGroupLimitRaw}. Expected a positive integer.`,
      );
      process.exit(1);
    }
    const parsedGroupLimit = Number.parseInt(rawGroupLimit, 10);
    if (!Number.isFinite(parsedGroupLimit) || parsedGroupLimit < 1) {
      console.error(
        `Error: invalid agenda --group-limit value: ${agendaGroupLimitRaw}. Expected a positive integer.`,
      );
      process.exit(1);
    }
    agendaGroupLimit = parsedGroupLimit;
  }

  let agendaDeadlineWarningDays = DEFAULT_AGENDA_DEADLINE_WARNING_DAYS;
  if (agendaDeadlineWarningDaysRaw.trim().length > 0) {
    const rawWarningDays = agendaDeadlineWarningDaysRaw.trim();
    if (!/^\d+$/.test(rawWarningDays)) {
      console.error(
        `Error: invalid agenda --deadline-warning-days value: ${agendaDeadlineWarningDaysRaw}. Expected 0 or a positive integer.`,
      );
      process.exit(1);
    }
    agendaDeadlineWarningDays = Number.parseInt(rawWarningDays, 10);
  }

  let agendaFromDate: Date | null = null;
  if (agendaFromRaw.trim().length > 0) {
    const rawFrom = agendaFromRaw.trim();
    try {
      agendaFromDate = parseIsoDate(rawFrom);
    } catch {
      console.error(`Error: invalid agenda --from value: ${agendaFromRaw}. Expected YYYY-MM-DD.`);
      process.exit(1);
    }
  }

  let agendaToDate: Date | null = null;
  if (agendaToRaw.trim().length > 0) {
    const rawTo = agendaToRaw.trim();
    try {
      agendaToDate = parseIsoDate(rawTo);
    } catch {
      console.error(`Error: invalid agenda --to value: ${agendaToRaw}. Expected YYYY-MM-DD.`);
      process.exit(1);
    }
  }

  // Parse date range
  const startDate = agendaFromDate ?? parseIsoDate(today);
  const endDate = agendaToDate ? new Date(agendaToDate) : new Date(startDate);
  if (!agendaToDate) {
    endDate.setUTCDate(endDate.getUTCDate() + days - 1);
  }

  if (endDate < startDate) {
    console.error(
      `Error: invalid agenda date range: --to ${agendaToRaw || endDate.toISOString().slice(0, 10)} is before --from ${agendaFromRaw || startDate.toISOString().slice(0, 10)}.`,
    );
    process.exit(1);
  }

  const rangeDays = Math.floor((endDate.getTime() - startDate.getTime()) / (24 * 60 * 60 * 1000)) + 1;

  const agendaUsesExplicitFiles = args.includes("--file") || args.includes("--files");
  const collectAgendaFiles = (): string[] => {
    if (agendaUsesExplicitFiles) return files;
    if (agendaConfig) return resolveFilesFromConfig(agendaConfig, agendaConfigBaseDir);
    if (dir) return listAgendaFiles(dir, recursive, includeArchives);
    return files;
  };

  // Process files
  const startIso = startDate.toISOString().slice(0, 10);
  const endIso = endDate.toISOString().slice(0, 10);
  const agendaCacheRootDir = agendaUsesExplicitFiles
    ? agendaCacheRootForFiles(files, process.cwd())
    : agendaConfig
      ? path.resolve(agendaConfigBaseDir)
      : dir
        ? path.resolve(dir)
        : agendaCacheRootForFiles(files, agendaConfigBaseDir);
  const agendaCacheFile = path.join(org2CorpusIndexDir(agendaCacheRootDir), "agenda-v1.json");
  const agendaCache = readAgendaCache(agendaCacheFile, agendaCacheRootDir);

  const agendaQueryKey = (runtimeStartDate: Date, runtimeEndDate: Date): string => crypto
    .createHash("sha256")
    .update(JSON.stringify({
      schemaVersion: AGENDA_CACHE_SCHEMA_VERSION,
      packageVersion: org2PackageVersion(),
      cwd: process.cwd(),
      args,
      start: runtimeStartDate.toISOString().slice(0, 10),
      end: runtimeEndDate.toISOString().slice(0, 10),
    }))
    .digest("hex");

  // Like Emacs Org, upcoming deadline warnings are shown only on today's date.
  const agendaDeadlineWarningDateFor = (runtimeStartDate: Date, runtimeEndDate: Date): Date | null => {
    if (agendaDeadlineWarningDays <= 0) return null;
    const todayDate = parseIsoDate(today);
    return todayDate >= runtimeStartDate && todayDate <= runtimeEndDate ? todayDate : null;
  };

  const scanAgendaFile = (filePath: string, runtimeStartDate: Date, runtimeEndDate: Date): ScheduledItem[] => {
    const content = fs.readFileSync(filePath, "utf8");
    const normalized = content.replace(/\r?\n/g, "\n");

    // Agenda intentionally uses a lightweight line-based scan so we can provide
    // stable 0-based line numbers for editor integrations (VS Code agenda → open file).
    // The canonical parser does not currently preserve source locations.
    return findScheduledItemsInText(
      normalized,
      filePath,
      runtimeStartDate,
      runtimeEndDate,
      includeOverdue,
      parsedAgendaStatus.filter,
      parsedAgendaExcludeStatus.filter,
      parsedAgendaKind.filter,
      parsedAgendaExcludeKind.filter,
      parsedAgendaWhen.filter,
      parsedAgendaExcludeWhen.filter,
      parsedAgendaWeekday.filter,
      parsedAgendaExcludeWeekday.filter,
      parsedAgendaWeek.filter,
      parsedAgendaExcludeWeek.filter,
      parsedAgendaDayOfMonth.filter,
      parsedAgendaExcludeDayOfMonth.filter,
      parsedAgendaMonth.filter,
      parsedAgendaExcludeMonth.filter,
      parsedAgendaQuarter.filter,
      parsedAgendaExcludeQuarter.filter,
      parsedAgendaYear.filter,
      parsedAgendaExcludeYear.filter,
      parsedAgendaDate.filter,
      parsedAgendaExcludeDate.filter,
      parsedAgendaLevel.filter,
      parsedAgendaExcludeLevel.filter,
      parsedAgendaMatch,
      parsedAgendaExcludeMatch,
      parsedAgendaTag,
      parsedAgendaId.filter,
      parsedAgendaTodo,
      parsedAgendaPriority.filter,
      parsedAgendaTime.filter,
      parsedAgendaEffort,
      parsedAgendaProperty.filter,
      parsedAgendaExcludeTag,
      parsedAgendaExcludeId.filter,
      parsedAgendaExcludeTodo,
      parsedAgendaExcludePriority.filter,
      parsedAgendaExcludeTime.filter,
      parsedAgendaExcludeEffort,
      parsedAgendaExcludeProperty.filter,
      agendaDeadlineWarningDays,
      agendaDeadlineWarningDateFor(runtimeStartDate, runtimeEndDate),
    );
  };

  const collectAgendaOutput = (
    targetFiles: string[],
    runtimeStartDate: Date,
    runtimeEndDate: Date,
  ): { outputItems: ScheduledItem[]; skippedFileCount: number } => {
    const allItems: ScheduledItem[] = [];
    let skippedFileCount = 0;
    const queryKey = agendaQueryKey(runtimeStartDate, runtimeEndDate);
    const previousQuery = agendaCache.queries[queryKey];
    const previousFiles = previousQuery?.files || {};
    const nextFiles: Record<string, AgendaCacheFileEntry> = {};
    let cacheDirty = !previousQuery;

    for (const filePath of targetFiles) {
      if (!matchesAgendaFileFilter(filePath, parsedAgendaFile)) continue;
      if (!matchesAgendaExcludeFileFilter(filePath, parsedAgendaExcludeFile)) continue;

      try {
        const absolutePath = path.resolve(filePath);
        const statBefore = fs.statSync(filePath);
        const cached = previousFiles[absolutePath];
        if (agendaCacheFileEntryMatches(cached, statBefore) && (cached?.todoConfiguration ?? "[]") === todoConfigurationKey(filePath)) {
          nextFiles[absolutePath] = cached!;
          allItems.push(...cached!.items);
          continue;
        }

        const items = scanAgendaFile(filePath, runtimeStartDate, runtimeEndDate);
        allItems.push(...items);
        const statAfter = fs.statSync(filePath);
        if (
          statBefore.size === statAfter.size
          && statBefore.mtimeMs === statAfter.mtimeMs
          && statBefore.ctimeMs === statAfter.ctimeMs
        ) {
          nextFiles[absolutePath] = {
            todoConfiguration: todoConfigurationKey(filePath),
            size: statAfter.size,
            mtimeMs: statAfter.mtimeMs,
            ctimeMs: statAfter.ctimeMs,
            items,
          };
        }
        cacheDirty = true;
      } catch (err) {
        skippedFileCount += 1;
        cacheDirty = true;
        if (verboseErrors) {
          console.error(`Error processing ${filePath}:`, err instanceof Error ? err.message : err);
        }
      }
    }

    const previousFileKeys = Object.keys(previousFiles);
    if (
      previousFileKeys.length !== Object.keys(nextFiles).length
      || previousFileKeys.some((filePath) => !nextFiles[filePath])
    ) {
      cacheDirty = true;
    }

    if (cacheDirty) {
      agendaCache.queries[queryKey] = {
        updatedAt: new Date().toISOString(),
        files: nextFiles,
      };
      pruneAgendaCacheQueries(agendaCache, queryKey);
      writeAgendaCache(agendaCacheFile, agendaCache);
    }

    allItems.sort((a, b) =>
      compareAgendaItems(
        a,
        b,
        parsedAgendaGroup.groupOrder,
        parsedAgendaSort.sortOrder,
        parsedAgendaDateOrder.dateOrder,
        parsedAgendaTodoOrder,
        parsedAgendaStatusOrder.statusOrder,
        parsedAgendaKindOrder.kindOrder,
        parsedAgendaPriorityOrder.priorityOrder,
        parsedAgendaEffortOrder,
        parsedAgendaTagOrder,
      ),
    );

    const groupLimitedItems = applyAgendaGroupLimit(
      allItems,
      parsedAgendaGroup.groupOrder,
      agendaGroupLimit,
      parsedAgendaTagOrder,
    );
    const dayLimitedItems = applyAgendaDayLimit(groupLimitedItems, agendaDayLimit);
    const outputItems = agendaLimit ? dayLimitedItems.slice(0, agendaLimit) : dayLimitedItems;

    return { outputItems, skippedFileCount };
  };

  const { outputItems, skippedFileCount } = collectAgendaOutput(files, startDate, endDate);

  if (skippedFileCount > 0 && !verboseErrors) {
    console.error(
      `Skipped ${skippedFileCount} file(s) due to parse errors (use --verbose-errors to see details).`,
    );
  }

  if (agendaTui) {
    const explicitRange = args.includes("--from") || args.includes("--to") || args.includes("--days");
    await runAgendaTui({
      startIso,
      rangeLabel: explicitRange ? `${startIso} → ${endIso}` : `${startIso} (today-first)`,
      refreshMs: agendaTuiRefreshSeconds * 1000,
      getTodayDailyNotePath: () => resolveAgendaTuiTodayDailyNotePath(agendaConfig, agendaConfigBaseDir),
      collect: (runtime) => {
        const runtimeStartDate = parseIsoDate(runtime.startIso);
        const runtimeEndDate = agendaToDate ? new Date(agendaToDate) : new Date(runtimeStartDate);
        if (!agendaToDate) {
          runtimeEndDate.setUTCDate(runtimeEndDate.getUTCDate() + days - 1);
        }
        const refreshed = collectAgendaOutput(collectAgendaFiles(), runtimeStartDate, runtimeEndDate);
        return { items: refreshed.outputItems, skippedFiles: refreshed.skippedFileCount };
      },
    });
    return;
  }

  if (format === "json") {
    const overdue = outputItems.filter((it) => it.date < startIso);
    const upcoming = outputItems.filter((it) => it.date >= startIso);

    const group = (items: ScheduledItem[]) => {
      const byDate: Record<string, ScheduledItem[]> = {};
      for (const item of items) {
        (byDate[item.date] ??= []).push(item);
      }

      const serializeAgendaItem = (it: ScheduledItem) => ({
        todo: it.todo,
        ...(it.todoTerminal !== undefined ? { todoTerminal: it.todoTerminal } : {}),
        headline: it.headline,
        kind: it.kind,
        file: it.filePath,
        line: it.lineNumber,
        body: it.body,
        level: it.level,
        tags: it.tags,
        properties: it.properties,
        ...(it.priority ? { priority: it.priority } : {}),
        ...(it.time ? { time: it.time } : {}),
        ...(it.effort ? { effort: it.effort } : {}),
        ...(it.id ? { id: it.id } : {}),
        ...(it.habit ? { habit: it.habit } : {}),
        ...(it.deadlineWarning ? { deadlineWarning: it.deadlineWarning } : {}),
      });

      return Object.keys(byDate)
        .sort((a, b) => {
          const cmp = a.localeCompare(b);
          return parsedAgendaDateOrder.dateOrder === "desc" ? -cmp : cmp;
        })
        .map((date) => {
          const dayItems = byDate[date] ?? [];
          const dayPayload: {
            date: string;
            weekday: string;
            items: ReturnType<typeof serializeAgendaItem>[];
            groups?: Array<{ label: string; items: ReturnType<typeof serializeAgendaItem>[] }>;
          } = {
            date,
            weekday: formatDateHeader(date).split(" ").slice(1).join(" "),
            items: dayItems.map(serializeAgendaItem),
          };

          if (parsedAgendaGroup.groupOrder && parsedAgendaGroup.groupOrder.length > 0) {
            const groupedRows: Array<{ key: string; label: string; items: ReturnType<typeof serializeAgendaItem>[] }> = [];
            for (const row of dayItems) {
              const key = agendaGroupKeyForItem(row, parsedAgendaGroup.groupOrder, parsedAgendaTagOrder);
              const label = agendaGroupLabelForItem(row, parsedAgendaGroup.groupOrder, parsedAgendaTagOrder);
              const serialized = serializeAgendaItem(row);
              const previous = groupedRows[groupedRows.length - 1];

              if (!previous || previous.key !== key) {
                groupedRows.push({ key, label, items: [serialized] });
              } else {
                previous.items.push(serialized);
              }
            }

            dayPayload.groups = groupedRows.map(({ label, items: groupedItems }) => ({
              label,
              items: groupedItems,
            }));
          }

          return dayPayload;
        });
    };

    // A deadline warning is a second view of a task that is counted on its due date.
    const workload = agendaWorkloadSummaryForItems(
      outputItems.filter((item) => !item.deadlineWarning),
      parsedAgendaGroup.groupOrder,
      parsedAgendaTagOrder,
    );
    const payload = {
      $schema: "org2:agenda:v1",
      range: { start: startIso, end: endIso, days: rangeDays },
      overdue: group(overdue),
      days: group(upcoming),
      skippedFiles: skippedFileCount,
      ...(agendaWorkload ? { workload } : {}),
    };

    process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
    return;
  }

  // Output text
  const output = formatOutput(
    outputItems,
    startDate,
    parsedAgendaDateOrder.dateOrder,
    parsedAgendaGroup.groupOrder,
    parsedAgendaTagOrder,
  );
  process.stdout.write(output);
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : err);
  process.exit(1);
});
