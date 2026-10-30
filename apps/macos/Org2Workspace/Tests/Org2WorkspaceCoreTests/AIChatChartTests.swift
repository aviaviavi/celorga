import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatChartTests: XCTestCase {
  private let markdownReply = """
  Revenue by month:

  | Month | Revenue | Cost |
  |-------|:-------:|-----:|
  | Jan   | 10      | 4    |
  | Feb   | 14      | 6    |

  ```chart
  type: line
  x: Month
  y: Revenue, Cost
  ```
  """

  func testMarkdownDelimiterRowsBecomeOrgHlinesAtTheChatBoundary() {
    let normalized = AIChatMessageOrgNormalizer.normalized(markdownReply)
    let lines = normalized.components(separatedBy: "\n")
    XCTAssertEqual(lines[3], "|-------+---------+------|")
    XCTAssertTrue(normalized.contains("```chart\ntype: line"), "chart fences pass through unchanged")
    // Org hlines and placeholder data rows are left alone.
    XCTAssertEqual(AIChatMessageOrgNormalizer.normalized("| a | b |\n|---+---|"), "| a | b |\n|---+---|")
    XCTAssertEqual(AIChatMessageOrgNormalizer.normalized("| a | b |\n| - | - |"), "| a | b |\n| - | - |")
  }

  func testAgentsAreToldNativeChartsHaveTooltipsAndInlineData() {
    // Agents reached for hand-built HTML charts because the contract did not
    // say chart blocks already have tooltips and can carry their own rows.
    let contract = AIChatWorkspaceContext.responseFormattingContract
    XCTAssertTrue(contract.contains("put the Org table rows inside the chart block"))
    XCTAssertTrue(contract.contains("hover and tap tooltips"))
    XCTAssertTrue(contract.contains("use a chart block, not an html block"))
  }

  func testChartInteractionScriptIsExtractedOnlyFromRendererOutput() {
    let script = "(() => { window.__org2InstallCharts = function () {}; })();"
    let html = "<html><head><script id=\"org2-app-document-script\">x</script><script id=\"org2-chart-interaction\">\n\(script)\n</script></head></html>"
    XCTAssertEqual(AIChatChartInteraction.script(inRenderedHTML: html), script)
    XCTAssertNil(AIChatChartInteraction.script(inRenderedHTML: "<html><body><p>No charts.</p></body></html>"))
    XCTAssertNil(AIChatChartInteraction.script(inRenderedHTML: "<script id=\"org2-chart-interaction\">alert(1)</script>"))
    XCTAssertNil(AIChatChartInteraction.script(inRenderedHTML: "<script id=\"org2-chart-interaction\">unterminated"))
    XCTAssertTrue(AIChatDocumentHTML.updateScript.contains("window.__org2InstallCharts(document)"))
  }

  func testChatRendersInteractiveChartsThroughTheSharedRenderer() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(AIChatMessageOrgNormalizer.normalized(markdownReply), sourcePath: "/tmp/chat-test.org")
    let chartScript = try XCTUnwrap(AIChatChartInteraction.script(inRenderedHTML: html))

    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 800))
    view.loadHTMLString("<html><head><style>\(AIChatDocumentHTML.style)</style></head><body><main></main></body></html>", baseURL: nil)
    for _ in 0..<100 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await view.evaluateJavaScript("window.webkit = {messageHandlers: {chatHeight: {postMessage: function() {}}}}; null;")
    try await view.evaluateJavaScript(AIChatDocumentHTML.updateScript)
    try await view.evaluateJavaScript(chartScript + "; null;")
    view.callAsyncJavaScript("window.__chatUpdate(html)", arguments: ["html": html], in: nil, in: .page)

    let result = try await view.evaluateJavaScript("""
      (() => {
        const figure = document.querySelector('figure.org2-chart');
        const rows = document.querySelectorAll('table tr').length;
        const legend = figure.querySelector('.org2-chart-legend-item[data-series="Cost"]');
        legend.dispatchEvent(new MouseEvent('click', {bubbles: true}));
        const hidden = figure.querySelectorAll('.org2-chart-series-hidden[data-series="Cost"]').length;
        const revenue = figure.querySelector('.org2-chart-legend-item[data-series="Revenue"]');
        revenue.dispatchEvent(new MouseEvent('click', {bubbles: true}));
        const revenueHidden = figure.querySelectorAll('.org2-chart-series-hidden[data-series="Revenue"]').length;
        const mark = figure.querySelector('[data-org2-chart-mark="true"][data-series="Revenue"]');
        mark.dispatchEvent(new FocusEvent('focus'));
        const tooltip = figure.querySelector('.org2-chart-tooltip');
        return {
          enhanced: figure.dataset.org2ChartEnhanced,
          rows, hidden, revenueHidden,
          pressed: legend.getAttribute('aria-pressed'),
          tooltipVisible: !tooltip.hidden,
          tooltip: tooltip.textContent,
          code: document.querySelectorAll('code.language-chart, .chat-code').length
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["enhanced"] as? String, "true")
    XCTAssertEqual(result?["rows"] as? Int, 3, "the Markdown delimiter row is not a data row")
    XCTAssertGreaterThan(result?["hidden"] as? Int ?? 0, 0, "legend click hides that series")
    XCTAssertEqual(result?["pressed"] as? String, "false")
    XCTAssertEqual(result?["revenueHidden"] as? Int, 0, "the last visible series cannot be hidden")
    XCTAssertEqual(result?["tooltipVisible"] as? Bool, true)
    XCTAssertEqual(result?["tooltip"] as? String, "JanRevenue: 10")
    XCTAssertEqual(result?["code"] as? Int, 0, "the chart block is not shown as code")
  }

  func testThemeChartPaletteMapsDistinctSeriesColorsForEveryTheme() throws {
    for theme in WorkspaceThemeCatalog.all {
      let colors = WorkspaceThemeDocumentStyle.chartSeriesColors(for: theme)
      XCTAssertEqual(colors.count, 7, theme.id)
      XCTAssertEqual(Set(colors).count, 7, "\(theme.id) series colors are distinct")
      let mark = WorkspaceThemeDocumentStyle.cssColor(theme.resolvedColor(.structural))
      XCTAssertFalse(colors.contains(mark), "\(theme.id) series 2+ differ from the accent mark")
      let rules = WorkspaceThemeDocumentStyle.rules(for: theme, selectorPrefix: ":root")
      XCTAssertTrue(rules.contains("--org2-chart-mark: \(mark);"), theme.id)
      for (offset, color) in colors.enumerated() {
        XCTAssertTrue(rules.contains("--org2-chart-series-\(offset + 2): \(color);"), "\(theme.id) series \(offset + 2)")
      }
    }
  }

  func testThemeChartPaletteFollowsRolesThenFallsBackPerAppearance() throws {
    let base = WorkspaceThemeCatalog.theme(id: WorkspaceThemeCatalog.defaultDarkID, for: .dark)
    let first = WorkspaceThemeDocumentStyle.chartSeriesColors(for: base).first
    XCTAssertEqual(first, WorkspaceThemeDocumentStyle.cssColor(base.resolvedColor(.signal)), "series 2 is the theme's signal color")

    var palette = base.palette
    for keyPath in [\WorkspaceThemePalette.signal, \.done, \.tag, \.link, \.priority, \.planning, \.todo, \.keyword] {
      palette[keyPath: keyPath] = palette.structural
    }
    palette.heading2 = palette.structural
    let monochrome = WorkspaceTheme(id: "mono", name: "Mono", origin: "test", appearance: .dark, palette: palette)
    XCTAssertEqual(
      WorkspaceThemeDocumentStyle.chartSeriesColors(for: monochrome),
      WorkspaceThemeDocumentStyle.defaultChartSeries[.dark],
      "a theme without distinct roles uses the renderer's dark defaults"
    )
  }
}
