import type { DocumentNode, Node } from "./ast.js";
import { isBrandName } from "./brandNames.js";

/**
 * A live table of a project's chats.
 *
 * A project note asks for it with an empty dynamic block:
 *
 *   #+begin: project-threads
 *   #+end:
 *
 * The block holds no data. Membership stays in the note's #+PROJECT_THREADS:
 * keyword; titles, status, and activity come from the chat store. Static
 * renderers list the member threads as links. The Mac reader replaces that
 * list with the current thread metadata through
 * `window.__celorgaSetProjectThreads(rows)`, and calls it again whenever a
 * thread changes, so the table is never written back to the note.
 */
export const PROJECT_THREADS_BLOCK_NAME = "project-threads";

export function isProjectThreadsBlock(node: Node): boolean {
  return node.type === "DynamicBlock" && node.nameRaw.trim().toLowerCase() === PROJECT_THREADS_BLOCK_NAME;
}

export function documentHasProjectThreadsBlock(nodes: readonly Node[]): boolean {
  return nodes.some((node) => isProjectThreadsBlock(node) || (node.type === "Headline" && documentHasProjectThreadsBlock(node.children)));
}

const threadUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Thread IDs from the document's #+PROJECT_THREADS: keyword, in order, without duplicates. */
export function projectThreadIDsFromDocument(doc: DocumentNode): string[] {
  const ids: string[] = [];
  for (const node of doc.children) {
    if (node.type !== "KeywordLine" || !isBrandName(node.keyRaw.trim().toUpperCase(), "PROJECT_THREADS")) continue;
    for (const raw of node.valueRaw.split(/\s+/)) {
      const id = raw.toLowerCase();
      if (threadUUID.test(id) && !ids.includes(id)) ids.push(id);
    }
  }
  return ids;
}

/** Source text for a new project note. */
export const PROJECT_THREADS_BLOCK_SOURCE = `#+begin: ${PROJECT_THREADS_BLOCK_NAME}\n#+end:`;

export const PROJECT_THREADS_STYLE = `.celorga-project-threads { margin: 0.8rem 0 1.4rem; }
.celorga-project-threads-header { display: flex; align-items: baseline; gap: 0.45rem; font-weight: 650; }
.celorga-project-threads-count { color: var(--org2-muted); font-weight: 500; font-size: 0.85em; }
.celorga-project-threads-empty { color: var(--org2-muted); }
.celorga-thread-status { display: inline-block; padding: 0.05rem 0.45rem; border-radius: 999px; font-size: 0.8em; font-weight: 600; white-space: nowrap;
  color: var(--org2-muted); background: color-mix(in srgb, var(--org2-muted) 12%, transparent); }
.celorga-thread-status.state-active { color: var(--org2-accent); background: color-mix(in srgb, var(--org2-accent) 11%, transparent); }
.celorga-thread-status.state-working { color: var(--org2-success); background: color-mix(in srgb, var(--org2-success) 12%, transparent); }
.celorga-thread-status.state-attention { color: var(--org2-warning); background: color-mix(in srgb, var(--org2-warning) 13%, transparent); }
.celorga-thread-status.state-missing { color: var(--org2-danger); background: color-mix(in srgb, var(--org2-danger) 10%, transparent); }
.celorga-project-threads td.celorga-thread-number { text-align: right; font-variant-numeric: tabular-nums; }
.celorga-project-threads td.celorga-thread-date { white-space: nowrap; font-variant-numeric: tabular-nums; }`;

/**
 * Rows are `{ id, title, status, statusKind, agent, messages, updated, created }`.
 * Dates are preformatted "YYYY-MM-DD HH:MM" strings so text sorting is
 * chronological. A replacement keeps the person's filter and sort.
 */
export const PROJECT_THREADS_SCRIPT = `(() => {
  const columns = [
    ["title", "Chat"], ["status", "Status"], ["agent", "Agent"],
    ["messages", "Messages"], ["updated", "Updated"], ["created", "Created"]
  ];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const kinds = new Set(["active", "working", "attention", "settled", "missing"]);

  function viewState(section) {
    const filter = section.querySelector(".org2-table-filter");
    const buttons = Array.from(section.querySelectorAll(".org2-table-sort-button"));
    const sorted = buttons.findIndex((button) => button.getAttribute("aria-pressed") === "true");
    return {
      filter: filter ? filter.value : "",
      sortColumn: sorted,
      descending: sorted >= 0 && buttons[sorted].parentElement?.getAttribute("aria-sort") === "descending"
    };
  }

  function restore(section, state) {
    const buttons = Array.from(section.querySelectorAll(".org2-table-sort-button"));
    const button = state.sortColumn >= 0 ? buttons[state.sortColumn] : null;
    if (button) {
      button.click();
      if (state.descending) button.click();
    }
    const filter = section.querySelector(".org2-table-filter");
    if (filter && state.filter) {
      filter.value = state.filter;
      filter.dispatchEvent(new Event("input"));
    }
  }

  function cell(row, key) {
    const td = document.createElement("td");
    const value = row[key] === undefined || row[key] === null ? "" : String(row[key]);
    if (key === "title") {
      const id = String(row.id || "");
      if (uuid.test(id)) {
        const link = document.createElement("a");
        link.href = "org2-workspace://open-thread?id=" + id.toLowerCase();
        link.textContent = value || id;
        link.title = "Open this chat";
        td.appendChild(link);
      } else {
        td.textContent = value;
      }
    } else if (key === "status") {
      const pill = document.createElement("span");
      const kind = kinds.has(row.statusKind) ? row.statusKind : "settled";
      pill.className = "celorga-thread-status state-" + kind;
      pill.textContent = value;
      td.appendChild(pill);
    } else {
      td.textContent = value;
      if (key === "messages") td.className = "celorga-thread-number";
      if (key === "updated" || key === "created") td.className = "celorga-thread-date";
    }
    return td;
  }

  function table(rows) {
    const scroll = document.createElement("div");
    scroll.className = "org2-table-scroll";
    const element = document.createElement("table");
    element.dataset.org2LiveTable = "project-threads";
    element.dataset.org2InitialRowLimit = "25";
    const head = element.createTHead().insertRow();
    columns.forEach(([, label]) => {
      const th = document.createElement("th");
      th.textContent = label;
      head.appendChild(th);
    });
    const body = element.createTBody();
    rows.forEach((row) => {
      const tr = body.insertRow();
      columns.forEach(([key]) => tr.appendChild(cell(row, key)));
    });
    scroll.appendChild(element);
    return scroll;
  }

  window.__celorgaSetProjectThreads = (rows) => {
    if (!Array.isArray(rows)) return;
    document.querySelectorAll("[data-celorga-project-threads]").forEach((section) => {
      const holder = section.querySelector(".celorga-project-threads-body");
      if (!holder) return;
      const state = viewState(section);
      if (rows.length === 0) {
        const empty = document.createElement("p");
        empty.className = "celorga-project-threads-empty";
        empty.textContent = "No chats in this project yet.";
        holder.replaceChildren(empty);
      } else {
        holder.replaceChildren(table(rows));
        window.__org2InstallTables?.(holder);
        restore(section, state);
      }
      const count = section.querySelector(".celorga-project-threads-count");
      if (count) count.textContent = String(rows.length);
      section.dataset.celorgaProjectThreadsLive = "true";
    });
  };
})();`;
