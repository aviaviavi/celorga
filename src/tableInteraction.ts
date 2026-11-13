/**
 * Interactive behaviour for rendered Org tables: column resizing, sorting,
 * filtering, and paging. Documents and AI chat messages share this script, so
 * a table offers the same controls wherever it is rendered.
 *
 * The script defines `window.__org2InstallTables(root)`, which is idempotent
 * per table. Chat pages block page scripts, so their host evaluates this
 * script itself and calls the installer after each message update.
 */
export const TABLE_INTERACTION_SCRIPT = `(() => {
  const minimumColumnWidth = 72;

  function installTableResizers(scope) {
    scope.querySelectorAll(".org2-table-scroll table").forEach((table) => {
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

  function installInteractiveTables(scope) {
    const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
    scope.querySelectorAll(".org2-table-scroll table").forEach((table) => {
      if (table.dataset.org2Interactive === "true") return;
      // A live table is generated from app data, not source rows, so it has
      // nothing to save or recalculate.
      const live = Boolean(table.dataset.org2LiveTable);
      const requestedLimit = Number(table.dataset.org2InitialRowLimit);
      const initialVisibleRowLimit = Number.isInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : 100;
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

      if (live) controls.append(filter, count, showMore, reset);
      else controls.append(filter, count, showMore, reset, recalculate, save);
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
  }

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

  window.__org2InstallTables = (root) => {
    const scope = root || document;
    installTableResizers(scope);
    installInteractiveTables(scope);
  };
})();`;
