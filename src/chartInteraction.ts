/**
 * Browser-side behavior for Celorga SVG charts, shared by every surface that
 * shows them: Celorga app documents, AI chat messages, and app HTML previews.
 *
 * The script defines `window.__org2InstallCharts(root)`, which is idempotent
 * per figure, and installs once for the current document. Hosts that replace
 * their DOM (chat streaming) call it again after each update.
 *
 * Interactions: hover, tap, and focus tooltips with a crosshair (touch drags
 * scrub horizontally while vertical swipes still scroll), arrow-key navigation
 * between marks, and legend toggling that hides or shows a series (the last
 * visible series cannot be hidden). Colors come from the `--org2-chart-*`
 * custom properties, so the active theme styles every chart.
 */
export const CHART_INTERACTION_SCRIPT = `(() => {
  function installInteractiveCharts(root) {
    (root || document).querySelectorAll("figure.org2-chart[data-org2-chart-interactive='true']").forEach((figure) => {
      if (figure.dataset.org2ChartEnhanced === "true") return;
      const svg = figure.querySelector("svg.org2-chart-svg");
      if (!svg || svg.dataset.org2ChartInteractive !== "true") return;
      const marks = Array.from(svg.querySelectorAll("[data-org2-chart-mark='true']"));
      if (marks.length === 0) return;

      figure.dataset.org2ChartEnhanced = "true";
      window.__org2ChartCount = (window.__org2ChartCount || 0) + 1;
      const tooltip = document.createElement("div");
      const tooltipID = "org2-chart-tooltip-" + window.__org2ChartCount;
      tooltip.id = tooltipID;
      tooltip.className = "org2-chart-tooltip";
      tooltip.setAttribute("role", "tooltip");
      tooltip.hidden = true;
      const tooltipLabel = document.createElement("span");
      tooltipLabel.className = "org2-chart-tooltip-label";
      const tooltipValue = document.createElement("span");
      tooltipValue.className = "org2-chart-tooltip-value";
      const tooltipSwatch = document.createElement("span");
      tooltipSwatch.className = "org2-chart-tooltip-swatch";
      const tooltipText = document.createElement("span");
      tooltipValue.append(tooltipSwatch, tooltipText);
      tooltip.append(tooltipLabel, tooltipValue);
      figure.appendChild(tooltip);

      const crosshair = svg.querySelector(".org2-chart-crosshair");
      const hiddenSeries = new Set();
      let activeMark = null;
      const isVisible = (mark) => !hiddenSeries.has(mark.dataset.series || "");
      const visibleMarks = () => marks.filter(isVisible);

      marks.forEach((mark) => {
        const nativeTitle = mark.querySelector(":scope > title");
        if (nativeTitle) nativeTitle.remove();
        mark.setAttribute("aria-describedby", tooltipID);
        mark.addEventListener("focus", () => showMark(mark));
        mark.addEventListener("blur", hideMark);
        mark.addEventListener("keydown", (event) => {
          if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
          event.preventDefault();
          const candidates = visibleMarks();
          const index = candidates.indexOf(mark);
          const direction = event.key === "ArrowRight" ? 1 : -1;
          const next = candidates[Math.max(0, Math.min(candidates.length - 1, index + direction))];
          if (next && typeof next.focus === "function") next.focus();
        });
      });

      function showMark(mark) {
        if (!mark || !isVisible(mark)) return;
        if (activeMark && activeMark !== mark) activeMark.classList.remove("org2-chart-mark-active");
        activeMark = mark;
        mark.classList.add("org2-chart-mark-active");
        tooltipLabel.textContent = mark.dataset.label || "";
        const yLabel = svg.dataset.org2ChartYLabel || "value";
        const seriesLabel = mark.dataset.series || yLabel;
        tooltipText.textContent = seriesLabel + ": " + (mark.dataset.display || mark.dataset.value || "");
        tooltipSwatch.style.background = mark.getAttribute("fill") || "currentColor";
        tooltip.hidden = false;

        if (crosshair) {
          const x = mark.dataset.chartX || "0";
          crosshair.setAttribute("x1", x);
          crosshair.setAttribute("x2", x);
          crosshair.setAttribute("visibility", "visible");
        }

        const figureRect = figure.getBoundingClientRect();
        const markRect = mark.getBoundingClientRect();
        const centerX = markRect.left - figureRect.left + markRect.width / 2;
        let left = centerX - tooltip.offsetWidth / 2;
        left = Math.max(10, Math.min(left, figure.clientWidth - tooltip.offsetWidth - 10));
        let top = markRect.top - figureRect.top - tooltip.offsetHeight - 10;
        if (top < 8) top = markRect.bottom - figureRect.top + 10;
        tooltip.style.left = left + "px";
        tooltip.style.top = top + "px";
      }

      function hideMark() {
        if (activeMark) activeMark.classList.remove("org2-chart-mark-active");
        activeMark = null;
        tooltip.hidden = true;
        if (crosshair) crosshair.setAttribute("visibility", "hidden");
      }

      const legendItems = Array.from(svg.querySelectorAll(".org2-chart-legend-item[data-series]"));
      const seriesCount = legendItems.length;
      function toggleSeries(item) {
        const series = item.dataset.series || "";
        if (!hiddenSeries.has(series) && hiddenSeries.size >= seriesCount - 1) return;
        if (hiddenSeries.has(series)) hiddenSeries.delete(series);
        else hiddenSeries.add(series);
        const hidden = hiddenSeries.has(series);
        item.setAttribute("aria-pressed", hidden ? "false" : "true");
        svg.querySelectorAll("[data-series]").forEach((element) => {
          if (element === item || element.classList.contains("org2-chart-legend-item")) return;
          if ((element.dataset.series || "") === series) element.classList.toggle("org2-chart-series-hidden", hidden);
        });
        if (activeMark && !isVisible(activeMark)) hideMark();
      }
      legendItems.forEach((item) => {
        item.setAttribute("role", "button");
        item.setAttribute("tabindex", "0");
        item.setAttribute("aria-pressed", "true");
        item.setAttribute("aria-label", "Show or hide " + (item.dataset.series || "series"));
        item.addEventListener("click", () => toggleSeries(item));
        item.addEventListener("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault();
          toggleSeries(item);
        });
      });

      // Pointer events cover mouse, pen, and touch: a tap or a horizontal
      // drag on a phone or trackpad-less display inspects the nearest mark.
      function inspectPointer(event) {
        if (event.target && event.target.closest && event.target.closest(".org2-chart-legend-item")) return;
        let nearest = null;
        let nearestDistance = Infinity;
        visibleMarks().forEach((mark) => {
          const rect = mark.getBoundingClientRect();
          const distance = Math.abs(event.clientX - (rect.left + rect.width / 2)) + Math.abs(event.clientY - (rect.top + rect.height / 2)) / 8;
          if (distance < nearestDistance) {
            nearest = mark;
            nearestDistance = distance;
          }
        });
        showMark(nearest);
      }
      figure.addEventListener("pointermove", inspectPointer);
      figure.addEventListener("pointerdown", inspectPointer);
      // A lifted finger leaves the tooltip up so it can be read; only a
      // mouse or pen moving away hides it. Tapping outside the chart hides it.
      figure.addEventListener("pointerleave", (event) => {
        if (event.pointerType === "touch") return;
        if (!marks.includes(document.activeElement)) hideMark();
      });
      document.addEventListener("pointerdown", (event) => {
        if (activeMark && !figure.contains(event.target)) hideMark();
      });
    });
  }

  window.__org2InstallCharts = installInteractiveCharts;
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => installInteractiveCharts(document), { once: true });
  } else {
    installInteractiveCharts(document);
  }
})();`;

/** Stylesheet rules for the interactions above; appended to the chart styles. */
export const CHART_INTERACTION_STYLE = `.org2-chart-legend-item { cursor: pointer; outline: none; }
.org2-chart-legend-item[aria-pressed="false"] { opacity: 0.38; }
.org2-chart-legend-item:focus-visible rect { stroke: var(--org2-text); stroke-width: 2; }
.org2-chart-series-hidden { display: none; }
figure.org2-chart[data-org2-chart-interactive="true"] svg.org2-chart-svg { touch-action: pan-y; }`;
