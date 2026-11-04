import type { CompiledCorpus, CompiledCorpusLink, CompiledCorpusNode } from "./corpusCompile.js";
import { isActiveTodoKeyword, normalizeTodoKeyword } from "./todo.js";
import { brandProperty } from "./brandNames.js";
import { idLinkTargetId } from "./linkSearch.js";

export type NodeActionRelationship = "direct" | "meeting";

export type NodeActionMeeting = {
  id: string | null;
  title: string;
  file: string;
  line: number;
};

export type NodeActionItem = {
  id: string;
  title: string;
  todo: string;
  file: string;
  line: number;
  lineEnd: number;
  relationship: NodeActionRelationship;
  meeting?: NodeActionMeeting;
  date?: string;
  dateKind?: "deadline" | "scheduled" | "closed" | "meeting" | "file";
  snippet?: string;
};

export type NodeActionsPayload = {
  $schema: "org2:node-actions:v1";
  target: {
    id: string | null;
    title: string;
    entityType?: string;
    file: string;
    line: number;
  };
  policy: {
    recentDays: number;
    openLimit: number;
    completedLimit: number;
  };
  counts: {
    open: number;
    recentlyCompleted: number;
  };
  open: NodeActionItem[];
  recentlyCompleted: NodeActionItem[];
};

export type NodeActionsOptions = {
  object: string;
  today?: string;
  recentDays?: number;
  openLimit?: number;
  completedLimit?: number;
};

function normalizedLabel(raw: string): string {
  return String(raw || "").trim().toLowerCase().replace(/\s+/g, " ");
}

function objectTarget(raw: string): string {
  const value = String(raw || "").trim();
  const link = /^\[\[([^\]\n]+?)(?:\]\[[^\]\n]*)?\]\]$/.exec(value);
  return String(link?.[1] || value).trim();
}

function resolveTarget(corpus: CompiledCorpus, rawObject: string): CompiledCorpusNode {
  const target = objectTarget(rawObject);
  const idValue = idLinkTargetId(target) ?? target.trim().toLowerCase();
  const looksLikeID = /^id:/i.test(target) || /^[0-9a-f-]{36}$/i.test(target);
  if (looksLikeID) {
    const matches = corpus.nodes.filter((node) => node.id?.toLowerCase() === idValue);
    if (matches.length === 1) return matches[0]!;
    if (matches.length === 0) throw new Error(`No node found for ${rawObject}`);
    throw new Error(`Multiple nodes found for ${rawObject}`);
  }

  const label = normalizedLabel(target);
  const matches = corpus.nodes.filter((node) => (
    normalizedLabel(node.title) === label
    || node.aliases.some((alias) => normalizedLabel(alias) === label)
  ));
  if (matches.length === 1) return matches[0]!;
  if (matches.length === 0) throw new Error(`No node found for ${rawObject}`);
  throw new Error(`Multiple nodes found for ${rawObject}; use an ID`);
}

function linkTargetsNode(link: CompiledCorpusLink, target: CompiledCorpusNode): boolean {
  if (link.type === "id" && target.id) {
    return idLinkTargetId(link.target) === target.id.toLowerCase();
  }
  if (link.type !== "wiki") return false;
  const labels = new Set([target.title, ...target.aliases].map(normalizedLabel));
  return labels.has(normalizedLabel(link.target));
}

function titleTargetsNode(title: string, target: CompiledCorpusNode): boolean {
  const labels = new Set([target.title, ...target.aliases].map(normalizedLabel));
  for (const match of title.matchAll(/\[\[([^\]\n]+?)(?:\]\[([^\]\n]*))?\]\]/g)) {
    const ref = String(match[1] || "").trim();
    const description = normalizedLabel(String(match[2] || ""));
    if (target.id && /^id:/i.test(ref)) {
      if (idLinkTargetId(ref) === target.id.toLowerCase()) return true;
    } else if (labels.has(normalizedLabel(ref)) || (description && labels.has(description))) {
      return true;
    }
  }
  return false;
}

function relationshipPropertyTargetsNode(node: CompiledCorpusNode, target: CompiledCorpusNode): boolean {
  const keys = [
    "PERSON", "PEOPLE",
    "COMPANY", "COMPANIES", "ORGANIZATION", "ORGANIZATIONS", "ACCOUNT", "ACCOUNTS",
    "PROJECT", "PROJECTS", "ENTITY", "ENTITIES",
    "ASSIGNEE", "OWNER", "ATTENDEES", "PARTICIPANTS",
  ];
  const values = keys.map((key) => node.effectiveProperties[key]).filter(Boolean) as string[];
  const labels = [target.title, ...target.aliases].map(normalizedLabel).filter(Boolean);
  const targetID = target.id?.toLowerCase();
  return values.some((raw) => {
    const value = String(raw || "");
    const normalized = normalizedLabel(value);
    if (targetID && value.toLowerCase().includes(targetID)) return true;
    return labels.some((label) => (
      normalized === label
      || normalized.split(/[,;|]/).map(normalizedLabel).includes(label)
    ));
  });
}

function isMeetingNode(node: CompiledCorpusNode): boolean {
  const kind = String(
    node.entityType
      || node.properties.KIND
      || brandProperty(node.properties, "ORG2_KIND")
      || "",
  ).trim().toLowerCase().replace(/_/g, "-");
  const pathLooksLikeMeeting = node.kind === "file" && /(^|\/)meetings?\//i.test(node.file);
  return kind === "meeting" || pathLooksLikeMeeting || /^meeting:\s*/i.test(node.title);
}

function containingMeeting(
  meetings: CompiledCorpusNode[],
  file: string,
  line: number,
): CompiledCorpusNode | undefined {
  return meetings
    .filter((node) => (
      node.file === file
      && (
        node.kind === "file"
        || (node.sourceRange.startLine <= line && node.sourceRange.endLine >= line)
      )
    ))
    .sort((left, right) => {
      if (left.kind !== right.kind) return left.kind === "heading" ? -1 : 1;
      if ((left.level ?? 0) !== (right.level ?? 0)) return (right.level ?? 0) - (left.level ?? 0);
      const leftSpan = left.sourceRange.endLine - left.sourceRange.startLine;
      const rightSpan = right.sourceRange.endLine - right.sourceRange.startLine;
      return leftSpan - rightSpan || right.sourceRange.startLine - left.sourceRange.startLine;
    })[0];
}

function resolvedLinkedNode(
  link: CompiledCorpusLink,
  nodesByID: Map<string, CompiledCorpusNode>,
  nodesByLabel: Map<string, CompiledCorpusNode[]>,
): CompiledCorpusNode | undefined {
  if (link.type === "id") {
    return nodesByID.get(idLinkTargetId(link.target) ?? "");
  }
  if (link.type !== "wiki") return undefined;
  const matches = nodesByLabel.get(normalizedLabel(link.target)) || [];
  return matches.length === 1 ? matches[0] : undefined;
}

function isoDate(raw: string | undefined): string | undefined {
  return String(raw || "").match(/\d{4}-\d{2}-\d{2}/)?.[0];
}

function meetingDate(node: CompiledCorpusNode): { date?: string; kind?: NodeActionItem["dateKind"] } {
  const propertyDate = isoDate(
    node.effectiveProperties.RECORDED_AT
      || node.effectiveProperties.DATE
      || node.effectiveProperties.CREATED,
  );
  if (propertyDate) return { date: propertyDate, kind: "meeting" };
  const pathDate = isoDate(node.file);
  return pathDate ? { date: pathDate, kind: "file" } : {};
}

function planningDate(
  node: CompiledCorpusNode,
  kinds: Array<"CLOSED" | "DEADLINE" | "SCHEDULED">,
): { date?: string; kind?: NodeActionItem["dateKind"] } {
  for (const planningKind of kinds) {
    const planning = node.planning.find((entry) => entry.kind === planningKind);
    const date = isoDate(planning?.raw);
    if (!date) continue;
    return { date, kind: planningKind.toLowerCase() as NodeActionItem["dateKind"] };
  }
  return {};
}

function calendarDayNumber(raw: string): number {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  if (!match) return Number.NaN;
  return Math.floor(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])) / 86_400_000);
}

function actionItem(
  node: CompiledCorpusNode,
  relationship: NodeActionRelationship,
  meeting: CompiledCorpusNode | undefined,
  terminal: boolean,
): NodeActionItem {
  const dateInfo = terminal
    ? planningDate(node, ["CLOSED"])
    : planningDate(node, ["DEADLINE", "SCHEDULED"]);
  const fallbackDate = terminal && !dateInfo.date && meeting ? meetingDate(meeting) : {};
  const date = dateInfo.date || fallbackDate.date;
  const dateKind = dateInfo.kind || fallbackDate.kind;
  return {
    id: node.id || `${node.file}:${node.sourceRange.startLine}`,
    title: node.title,
    todo: String(node.todo || "TODO"),
    file: node.file,
    line: node.sourceRange.startLine,
    lineEnd: node.sourceRange.endLine,
    relationship,
    ...(meeting ? {
      meeting: {
        id: meeting.id,
        title: meeting.title.replace(/^Meeting:\s*/i, ""),
        file: meeting.file,
        line: meeting.sourceRange.startLine,
      },
    } : {}),
    ...(date ? { date } : {}),
    ...(dateKind ? { dateKind } : {}),
    ...(node.snippet ? { snippet: node.snippet } : {}),
  };
}

export function queryNodeActions(corpus: CompiledCorpus, options: NodeActionsOptions): NodeActionsPayload {
  const target = resolveTarget(corpus, options.object);
  const recentDays = Math.max(0, Math.floor(options.recentDays ?? 30));
  const openLimit = Math.max(0, Math.floor(options.openLimit ?? 8));
  const completedLimit = Math.max(0, Math.floor(options.completedLimit ?? 4));
  const today = isoDate(options.today) || new Date().toISOString().slice(0, 10);

  const nodesByKey = new Map(corpus.nodes.map((node) => [node.key, node]));
  const nodesByID = new Map(
    corpus.nodes.filter((node) => node.id).map((node) => [node.id!.toLowerCase(), node]),
  );
  const nodesByLabel = new Map<string, CompiledCorpusNode[]>();
  const meetings = corpus.nodes.filter(isMeetingNode);
  const directlyRelatedKeys = new Set<string>();
  const directlyRelatedMeetingKeys = new Set<string>();
  for (const node of corpus.nodes) {
    for (const label of [node.title, ...node.aliases]) {
      const normalized = normalizedLabel(label);
      if (!normalized) continue;
      nodesByLabel.set(normalized, [...(nodesByLabel.get(normalized) || []), node]);
    }
  }
  for (const meeting of meetings) {
    if (
      titleTargetsNode(meeting.title, target)
      || relationshipPropertyTargetsNode(meeting, target)
    ) directlyRelatedMeetingKeys.add(meeting.key);
  }

  for (const backlink of target.backlinks) {
    directlyRelatedKeys.add(backlink.sourceKey);
    const source = nodesByKey.get(backlink.sourceKey);
    const meeting = containingMeeting(
      meetings,
      source?.file || backlink.file,
      backlink.line || source?.sourceRange.startLine || 1,
    );
    if (meeting && !source?.todo) directlyRelatedMeetingKeys.add(meeting.key);
  }

  for (const link of target.links) {
    const linked = resolvedLinkedNode(link, nodesByID, nodesByLabel);
    if (!linked) continue;
    if (linked.todo) directlyRelatedKeys.add(linked.key);
    const meeting = containingMeeting(meetings, linked.file, linked.sourceRange.startLine);
    if (meeting) directlyRelatedMeetingKeys.add(meeting.key);
  }

  const todos = corpus.nodes.filter((node) => node.kind === "heading" && node.todo);
  for (const node of todos) {
    const containedInProject = target.entityType === "project" && node.file === target.file
      && (target.kind === "file" || (node.sourceRange.startLine > target.sourceRange.startLine
        && node.sourceRange.endLine <= target.sourceRange.endLine));
    if (
      containedInProject ||
      node.links.some((link) => linkTargetsNode(link, target))
      || titleTargetsNode(node.title, target)
      || relationshipPropertyTargetsNode(node, target)
    ) {
      directlyRelatedKeys.add(node.key);
    }
  }

  const candidates = todos.flatMap((node) => {
    const direct = directlyRelatedKeys.has(node.key);
    const meeting = containingMeeting(meetings, node.file, node.sourceRange.startLine);
    const inherited = Boolean(meeting && directlyRelatedMeetingKeys.has(meeting.key));
    if (!direct && !inherited) return [];
    const relationship: NodeActionRelationship = direct ? "direct" : "meeting";
    return [{ node, relationship, meeting: relationship === "meeting" ? meeting : undefined }];
  });

  const openAll = candidates
    .filter(({ node }) => node.todoTerminal === undefined ? isActiveTodoKeyword(node.todo) : !node.todoTerminal)
    .map(({ node, relationship, meeting }) => actionItem(node, relationship, meeting, false))
    .sort((left, right) => {
      const statusRank = (item: NodeActionItem) => item.todo === "IN_PROGRESS" ? 0 : 1;
      if (statusRank(left) !== statusRank(right)) return statusRank(left) - statusRank(right);
      if ((left.date || "9999-99-99") !== (right.date || "9999-99-99")) {
        return (left.date || "9999-99-99").localeCompare(right.date || "9999-99-99");
      }
      if (left.relationship !== right.relationship) return left.relationship === "direct" ? -1 : 1;
      return left.file.localeCompare(right.file) || left.line - right.line;
    });

  const todayDay = calendarDayNumber(today);
  const completedAll = candidates
    .filter(({ node }) => {
      const keyword = normalizeTodoKeyword(node.todo);
      return (node.todoTerminal ?? (keyword === "DONE")) && keyword !== "CANCELED" && keyword !== "CANCELLED";
    })
    .map(({ node, relationship, meeting }) => actionItem(node, relationship, meeting, true))
    .filter((item) => {
      if (!item.date) return false;
      const itemDay = calendarDayNumber(item.date);
      return Number.isFinite(itemDay) && itemDay <= todayDay && (todayDay - itemDay) <= recentDays;
    })
    .sort((left, right) => (
      (right.date || "").localeCompare(left.date || "")
      || left.file.localeCompare(right.file)
      || left.line - right.line
    ));

  return {
    $schema: "org2:node-actions:v1",
    target: {
      id: target.id,
      title: target.title,
      ...(target.entityType ? { entityType: target.entityType } : {}),
      file: target.file,
      line: target.sourceRange.startLine,
    },
    policy: { recentDays, openLimit, completedLimit },
    counts: { open: openAll.length, recentlyCompleted: completedAll.length },
    open: openAll.slice(0, openLimit),
    recentlyCompleted: completedAll.slice(0, completedLimit),
  };
}
