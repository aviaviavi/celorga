import AppKit
import QuartzCore
import SwiftUI
import WebKit
import XCTest
@testable import Org2WorkspaceCore

private struct OpenOrgPerformanceShape: Decodable {
  struct Documents: Decodable {
    struct Sizes: Decodable {
      let max: Int
    }

    struct Zone: Decodable {
      let kind: String
      let fileCount: Int
    }

    let activeFileCount: Int
    let extensionMix: [String: Int]
    let zones: [Zone]
    let sizeBytes: Sizes
  }

  struct Chat: Decodable {
    let threadCount: Int
    let activeThreadCount: Int
    let archivedThreadCount: Int
    let messageCount: Int
    let maxMessagesPerThread: Int
    let attachmentBytes: Int
    let largestMessageBodyBytes: Int

    private enum CodingKeys: String, CodingKey {
      case threadCount
      case activeThreadCount
      case archivedThreadCount
      case messageCount
      case maxMessagesPerThread
      case attachmentBytes
      case largestMessageBodyBytes = "largestMessageBytes"
    }
  }

  struct Events: Decodable {
    let burstFileCount: Int
  }

  struct WorkspaceScale: Decodable {
    let agentRunCount: Int
    let approvalItemCount: Int
    let externalThreadCount: Int
    let sourceProfileCount: Int
  }

  let version: Int
  let documents: Documents
  let chat: Chat
  let workspaceScale: WorkspaceScale
  let events: Events
}

private struct OpenOrgPerformanceBudgets: Decodable {
  struct Threshold: Decodable {
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
  }

  struct Budget: Decodable {
    let minimumSamples: Int
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let targets: [String: Threshold]?

    func threshold(for target: String) -> Threshold {
      targets?[target] ?? Threshold(
        p95Milliseconds: p95Milliseconds,
        maximumMilliseconds: maximumMilliseconds
      )
    }
  }

  let version: Int
  let scenarios: [String: Budget]
}

private struct GeneratedCorpusManifest: Decodable {
  let activeFileCount: Int
  let largestDocumentRelativePath: String
  let sampleDocumentRelativePaths: [String]
}

private struct OpenOrgChatFixture {
  let selectedThreadID: UUID
  let coldAttachmentThreadIDs: [UUID]
  let heavyThreadID: UUID
  let largestMessageID: UUID
  let largeMessageSearchQuery: String
}

private struct OpenOrgLargeLiveUpdateResult {
  let presentationMilliseconds: Double
  let maximumMainActorGapMilliseconds: Double
}

private struct OpenOrgPerformanceResult: Codable {
  struct Target: Codable {
    let label: String
    let sampleCount: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
  }

  let schema: String
  let scenario: String
  let sampleCount: Int
  let p50Milliseconds: Double
  let p95Milliseconds: Double
  let p99Milliseconds: Double
  let maximumMilliseconds: Double
  let budgetP95Milliseconds: Double
  let budgetMaximumMilliseconds: Double
  let shapeVersion: Int
  let budgetVersion: Int
  let buildConfiguration: String
  let architecture: String
  let targets: [Target]?
}

private struct OpenOrgScrollGeometry {
  let documentHeight: CGFloat
  let viewportHeight: CGFloat
  let originY: CGFloat
  let isFlipped: Bool

  var isAtBottom: Bool {
    let maximumY = max(0, documentHeight - viewportHeight)
    if maximumY <= 1 { return true }
    return isFlipped ? originY >= maximumY - 2 : originY <= 2
  }

  func isApproximatelyEqual(to other: OpenOrgScrollGeometry) -> Bool {
    abs(documentHeight - other.documentHeight) <= 1
      && abs(viewportHeight - other.viewportHeight) <= 1
      && abs(originY - other.originY) <= 1
      && isFlipped == other.isFlipped
  }
}

@MainActor
private enum OpenOrgPerformanceResults {
  static func record(
    scenario: String,
    samples: [Double],
    sampleLabels: [String]? = nil,
    shapeVersion: Int,
    budgets: OpenOrgPerformanceBudgets,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard let budget = budgets.scenarios[scenario] else {
      XCTFail("Missing performance budget for \(scenario)", file: file, line: line)
      return
    }
    let p50 = percentile(samples, fraction: 0.50)
    let p95 = percentile(samples, fraction: 0.95)
    let p99 = percentile(samples, fraction: 0.99)
    let maximum = samples.max() ?? 0
    let targets = targetResults(
      samples: samples,
      labels: sampleLabels,
      file: file,
      line: line
    )
    XCTAssertGreaterThanOrEqual(
      samples.count,
      budget.minimumSamples,
      "\(scenario) did not collect enough samples",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      p95,
      budget.p95Milliseconds,
      "\(scenario) p95 \(format(p95)) ms exceeded \(format(budget.p95Milliseconds)) ms",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      maximum,
      budget.maximumMilliseconds,
      "\(scenario) max \(format(maximum)) ms exceeded \(format(budget.maximumMilliseconds)) ms",
      file: file,
      line: line
    )
    for target in targets ?? [] {
      let targetBudget = budget.threshold(for: target.label)
      XCTAssertLessThanOrEqual(
        target.p95Milliseconds,
        targetBudget.p95Milliseconds,
        "\(scenario) target \(target.label) p95 \(format(target.p95Milliseconds)) ms exceeded \(format(targetBudget.p95Milliseconds)) ms",
        file: file,
        line: line
      )
      XCTAssertLessThanOrEqual(
        target.maximumMilliseconds,
        targetBudget.maximumMilliseconds,
        "\(scenario) target \(target.label) max \(format(target.maximumMilliseconds)) ms exceeded \(format(targetBudget.maximumMilliseconds)) ms",
        file: file,
        line: line
      )
    }

    try write(
      scenario: scenario,
      sampleCount: samples.count,
      p50: p50,
      p95: p95,
      p99: p99,
      maximum: maximum,
      budget: budget,
      targets: targets,
      shapeVersion: shapeVersion,
      budgets: budgets
    )
  }

  static func record(
    scenario: String,
    snapshot: WorkspaceInteractionLatency.Snapshot,
    shapeVersion: Int,
    budgets: OpenOrgPerformanceBudgets,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard let budget = budgets.scenarios[scenario] else {
      XCTFail("Missing performance budget for \(scenario)", file: file, line: line)
      return
    }
    XCTAssertGreaterThanOrEqual(
      snapshot.sampleCount,
      budget.minimumSamples,
      "\(scenario) did not collect enough runtime samples",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      snapshot.p95Milliseconds,
      budget.p95Milliseconds,
      "\(scenario) p95 \(format(snapshot.p95Milliseconds)) ms exceeded \(format(budget.p95Milliseconds)) ms",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      snapshot.maximumMilliseconds,
      budget.maximumMilliseconds,
      "\(scenario) max \(format(snapshot.maximumMilliseconds)) ms exceeded \(format(budget.maximumMilliseconds)) ms",
      file: file,
      line: line
    )
    try write(
      scenario: scenario,
      sampleCount: snapshot.sampleCount,
      p50: snapshot.p50Milliseconds,
      p95: snapshot.p95Milliseconds,
      p99: snapshot.p99Milliseconds,
      maximum: snapshot.maximumMilliseconds,
      budget: budget,
      targets: nil,
      shapeVersion: shapeVersion,
      budgets: budgets
    )
  }

  private static func write(
    scenario: String,
    sampleCount: Int,
    p50: Double,
    p95: Double,
    p99: Double,
    maximum: Double,
    budget: OpenOrgPerformanceBudgets.Budget,
    targets: [OpenOrgPerformanceResult.Target]?,
    shapeVersion: Int,
    budgets: OpenOrgPerformanceBudgets
  ) throws {
    guard let outputPath = ProcessInfo.processInfo.environment["OPENORG_PERFORMANCE_RESULTS_PATH"],
          !outputPath.isEmpty
    else { return }
    let result = OpenOrgPerformanceResult(
      schema: "org2:openorg-performance-result:v1",
      scenario: scenario,
      sampleCount: sampleCount,
      p50Milliseconds: p50,
      p95Milliseconds: p95,
      p99Milliseconds: p99,
      maximumMilliseconds: maximum,
      budgetP95Milliseconds: budget.p95Milliseconds,
      budgetMaximumMilliseconds: budget.maximumMilliseconds,
      shapeVersion: shapeVersion,
      budgetVersion: budgets.version,
      buildConfiguration: WorkspaceRuntimeIdentity.compiledBuildConfiguration,
      architecture: runtimeArchitecture,
      targets: targets
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(result)
    data.append(0x0a)
    let url = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    print(
      "PERFORMANCE \(scenario): p50=\(format(p50)) ms " +
      "p95=\(format(p95)) ms p99=\(format(p99)) ms max=\(format(maximum)) ms"
    )
    for target in targets ?? [] {
      print(
        "PERFORMANCE-TARGET \(scenario) target=\(target.label): "
          + "samples=\(target.sampleCount) p50=\(format(target.p50Milliseconds)) ms "
          + "p95=\(format(target.p95Milliseconds)) ms "
          + "p99=\(format(target.p99Milliseconds)) ms "
          + "max=\(format(target.maximumMilliseconds)) ms"
      )
    }
  }

  private static func targetResults(
    samples: [Double],
    labels: [String]?,
    file: StaticString,
    line: UInt
  ) -> [OpenOrgPerformanceResult.Target]? {
    guard let labels else { return nil }
    guard labels.count == samples.count else {
      XCTFail(
        "Performance sample labels must correspond one-to-one with samples",
        file: file,
        line: line
      )
      return nil
    }
    var orderedLabels: [String] = []
    var groupedSamples: [String: [Double]] = [:]
    for (label, sample) in zip(labels, samples) {
      if groupedSamples[label] == nil { orderedLabels.append(label) }
      groupedSamples[label, default: []].append(sample)
    }
    return orderedLabels.compactMap { label in
      guard let targetSamples = groupedSamples[label] else { return nil }
      return OpenOrgPerformanceResult.Target(
        label: label,
        sampleCount: targetSamples.count,
        p50Milliseconds: percentile(targetSamples, fraction: 0.50),
        p95Milliseconds: percentile(targetSamples, fraction: 0.95),
        p99Milliseconds: percentile(targetSamples, fraction: 0.99),
        maximumMilliseconds: targetSamples.max() ?? 0
      )
    }
  }

  static func percentile(_ samples: [Double], fraction: Double) -> Double {
    guard !samples.isEmpty else { return 0 }
    let ordered = samples.sorted()
    let index = min(
      ordered.count - 1,
      max(0, Int(ceil(Double(ordered.count) * min(1, max(0, fraction)))) - 1)
    )
    return ordered[index]
  }

  private static var runtimeArchitecture: String {
#if arch(arm64)
    "arm64"
#elseif arch(x86_64)
    "x86_64"
#else
    "unknown"
#endif
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.1f", value)
  }
}

@MainActor
private final class WorkspaceRenderPerformanceHarness {
  @MainActor
  private enum AccessibilityNode {
    case view(NSView)
    case element(NSAccessibilityElement)

    var identifier: ObjectIdentifier {
      switch self {
      case .view(let value): ObjectIdentifier(value)
      case .element(let value): ObjectIdentifier(value)
      }
    }

    var label: String? {
      switch self {
      case .view(let value): value.accessibilityLabel()
      case .element(let value): value.accessibilityLabel()
      }
    }

    var accessibilityIdentifier: String? {
      switch self {
      case .view(let value): value.accessibilityIdentifier()
      case .element(let value): value.accessibilityIdentifier()
      }
    }

    var children: [Any] {
      switch self {
      case .view(let value): value.accessibilityChildren() ?? []
      case .element(let value): value.accessibilityChildren() ?? []
      }
    }

    func performPress() -> Bool {
      switch self {
      case .view(let value): value.accessibilityPerformPress()
      case .element(let value): value.accessibilityPerformPress()
      }
    }
  }

  let window: NSWindow
  let hostingView: NSHostingView<AnyView>
  private weak var mountedSurfaceHost: NSHostingView<AnyView>?
  private var mountedSurfaceHostID: ObjectIdentifier?
  private var didExpandSettledAIThreads = false

  init(store: WorkspaceStore) {
    _ = NSApplication.shared
    hostingView = NSHostingView(
      rootView: AnyView(ContentView().environment(store))
    )
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 820),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
    draw()
  }

  func draw() {
    hostingView.needsLayout = true
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    window.update()
    CATransaction.flush()
  }

  func drawAfterDeferredViewUpdates() async {
    // Untimed correctness checks exercise multiple turns so delayed SwiftUI
    // publications cannot masquerade as a stable destination.
    await nextMainQueueTurn()
    draw()
    await nextMainQueueTurn()
    draw()
    await Task.yield()
    draw()
  }

  func drawFirstUsableFrame() async {
    await nextMainQueueTurn()
    draw()
  }

  func waitForFirstUsableDestination(
    _ surface: WorkspaceSurface,
    runPage: RunsAndReviewPage? = nil,
    store: WorkspaceStore,
    timeout: TimeInterval = 3
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      // One queued main turn and one explicit draw represent the first frame a
      // user can consume. Multi-frame stability remains an untimed assertion.
      await drawFirstUsableFrame()
      if let host = usableDestinationHost(surface, runPage: runPage, store: store) {
        try validateSingleSurfaceHostIdentity(host)
        return
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw destinationEvidenceError(surface, runPage: runPage, store: store)
  }

  func waitForVisibleDestination(
    _ surface: WorkspaceSurface,
    runPage: RunsAndReviewPage? = nil,
    store: WorkspaceStore,
    timeout: TimeInterval = 3
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    var stableHostID: ObjectIdentifier?
    var stableFrameCount = 0
    while CACurrentMediaTime() < deadline {
      await drawAfterDeferredViewUpdates()
      guard let host = usableDestinationHost(surface, runPage: runPage, store: store) else {
        stableHostID = nil
        stableFrameCount = 0
        try await Task.sleep(nanoseconds: 5_000_000)
        continue
      }

      let hostID = ObjectIdentifier(host)
      try validateSingleSurfaceHostIdentity(host)

      if stableHostID == hostID {
        stableFrameCount += 1
      } else {
        stableHostID = hostID
        stableFrameCount = 1
      }
      if stableFrameCount >= 2 { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw destinationEvidenceError(surface, runPage: runPage, store: store)
  }

  private func usableDestinationHost(
    _ surface: WorkspaceSurface,
    runPage: RunsAndReviewPage?,
    store: WorkspaceStore
  ) -> NSHostingView<AnyView>? {
    guard store.selectedSurface == surface,
          runPage == nil || store.runsAndReviewPage == runPage,
          window.isVisible,
          let host = activeSurfaceHost(for: surface),
          host.window === window,
          Self.isEffectivelyExposed(host),
          host.bounds.width > 0,
          host.bounds.height > 0,
          host.visibleRect.width > 0,
          host.visibleRect.height > 0,
          hasDestinationEvidence(surface, runPage: runPage, in: host)
    else { return nil }
    return host
  }

  private func validateSingleSurfaceHostIdentity(
    _ host: NSHostingView<AnyView>
  ) throws {
    let hostID = ObjectIdentifier(host)
    if let mountedSurfaceHostID, mountedSurfaceHostID != hostID {
      throw PerformanceHarnessError.destinationEvidenceMissing(
        "workspace surface host identity changed"
      )
    }
    if mountedSurfaceHostID == nil {
      guard workspaceSurfaceHosts().count == 1 else {
        throw PerformanceHarnessError.destinationEvidenceMissing(
          "the workspace must expose exactly one attached surface host"
        )
      }
    }
    mountedSurfaceHost = host
    mountedSurfaceHostID = hostID
  }

  private func destinationEvidenceError(
    _ surface: WorkspaceSurface,
    runPage: RunsAndReviewPage?,
    store: WorkspaceStore
  ) -> PerformanceHarnessError {
    let currentHost = workspaceSurfaceHost()
    let responderType = window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil"
    return .destinationEvidenceMissing(
      "\(surface.rawValue) did not mount destination-specific visible content; "
        + "selected=\(store.selectedSurface.rawValue) "
        + "page=\(runPage?.rawValue ?? "none") "
        + "host=\(currentHost != nil) "
        + "hostID=\(currentHost?.accessibilityIdentifier() ?? "nil") "
        + "hidden=\(currentHost?.isHidden.description ?? "nil") "
        + "axHidden=\(currentHost?.isAccessibilityHidden().description ?? "nil") "
        + "windowMatch=\((currentHost?.window === window).description) "
        + "exposed=\(currentHost.map(Self.isEffectivelyExposed)?.description ?? "nil") "
        + "firstResponder=\(responderType)"
    )
  }

  func performNavigationAction(to surface: WorkspaceSurface) throws {
    window.makeKeyAndOrderFront(nil)
    if let shortcut = Self.commandShortcut(for: surface) {
      let event = try Self.keyEvent(
        character: shortcut.character,
        modifiers: shortcut.modifiers,
        keyCode: shortcut.keyCode,
        windowNumber: window.windowNumber
      )
      NSApplication.shared.sendEvent(event)
      return
    }
    guard surface == .externalThreads,
          clickAccessibilityElement(
            identifier: WorkspaceSurfaceNavigationIdentity.accessibilityIdentifier(for: surface)
          )
    else {
      throw PerformanceHarnessError.actionUnavailable(
        "no real navigation action for \(surface.rawValue)"
      )
    }
  }

  func performRunsAndReviewPageAction(
    _ page: RunsAndReviewPage,
    store: WorkspaceStore
  ) async throws {
    // A keyboard navigation event can update WorkspaceStore before SwiftUI
    // exposes the Approvals page control. Wait only for its first usable frame;
    // the caller performs the untimed multi-frame stability assertion.
    try await waitForFirstUsableDestination(.approvals, store: store)
    let identifier = RunsAndReviewPageAccessibilityIdentity.accessibilityIdentifier(for: page)
    guard clickAccessibilityElement(identifier: identifier) else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted Agent Work page did not publish its native press target"
      )
    }
  }

  func performCorpusFileRowAction(_ file: CorpusFile) throws {
    let identifier = CorpusFileRowAccessibilityIdentity.accessibilityIdentifier(for: file.id)
    guard clickAccessibilityElement(identifier: identifier) else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted corpus file row did not publish its native press target"
      )
    }
  }

  func prepareAIThreadRowAction(_ threadID: UUID) async throws {
    let identifier = AIChatSidebarThreadAccessibilityIdentity.accessibilityIdentifier(
      for: threadID
    )
    if await revealSidebarAccessibilityElement(identifier: identifier) { return }

    if !didExpandSettledAIThreads {
      let disclosureID = AIChatSidebarThreadAccessibilityIdentity.settledDisclosure
      guard await revealSidebarAccessibilityElement(identifier: disclosureID),
            let previousRowCount = sidebarTableView()?.numberOfRows,
            clickAccessibilityElement(identifier: disclosureID)
      else {
        throw PerformanceHarnessError.actionUnavailable(
          "the settled AI-thread disclosure did not publish its native press target"
        )
      }
      guard await waitForSidebarRowPublication(after: previousRowCount) else {
        throw PerformanceHarnessError.actionUnavailable(
          "the settled AI-thread disclosure did not publish its native rows"
        )
      }
      didExpandSettledAIThreads = true
    }

    // Settled transcripts are deliberately paginated. Reveal and invoke the
    // shipping Show More button until the requested real row has actually been
    // mounted; the timed action below is always that row's own native press.
    for _ in 0..<64 {
      if await revealSidebarAccessibilityElement(identifier: identifier) { return }
      let showMoreID = AIChatSidebarThreadAccessibilityIdentity.settledShowMore
      guard await revealSidebarAccessibilityElement(identifier: showMoreID),
            let previousRowCount = sidebarTableView()?.numberOfRows,
            clickAccessibilityElement(identifier: showMoreID)
      else { break }
      guard await waitForSidebarRowPublication(after: previousRowCount) else {
        throw PerformanceHarnessError.actionUnavailable(
          "the settled AI-thread Show More action did not publish additional native rows"
        )
      }
    }

    throw PerformanceHarnessError.actionUnavailable(
      "the requested settled AI-thread row could not be mounted through the visible sidebar controls"
    )
  }

  func performAIThreadRowAction(_ threadID: UUID) throws {
    let identifier = AIChatSidebarThreadAccessibilityIdentity.accessibilityIdentifier(
      for: threadID
    )
    guard clickAccessibilityElement(identifier: identifier) else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted AI-thread row did not publish its native press target"
      )
    }
  }

  func orderOut() {
    window.orderOut(nil)
  }

  func orderFront() {
    window.makeKeyAndOrderFront(nil)
  }

  private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume(returning: ())
      }
    }
  }

  func resize(width: CGFloat, height: CGFloat) {
    window.setContentSize(NSSize(width: width, height: height))
  }

  func sidebarNativeListRowCount() -> Int? {
    sidebarTableView()?.numberOfRows
  }

  func cachedSurfaceHost(for surface: WorkspaceSurface) -> NSHostingView<AnyView>? {
    let expectedIdentifier = WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: surface)
    if let mountedSurfaceHost,
       mountedSurfaceHost.accessibilityIdentifier() == expectedIdentifier {
      return mountedSurfaceHost
    }
    return workspaceSurfaceHosts()
      .first { $0.accessibilityIdentifier() == expectedIdentifier }
  }

  func workspaceSurfaceHost() -> NSHostingView<AnyView>? {
    mountedSurfaceHost ?? workspaceSurfaceHosts().first
  }

  func workspaceSurfaceHostCount() -> Int {
    workspaceSurfaceHosts().count
  }

  func hostContainsFirstResponder(_ host: NSView) -> Bool {
    guard let firstResponder = window.firstResponder else { return false }
    if let responderView = firstResponder as? NSView,
       responderView === host || responderView.isDescendant(of: host) {
      return true
    }
    if let fieldEditor = firstResponder as? NSTextView,
       let delegateView = fieldEditor.delegate as? NSView {
      return delegateView === host || delegateView.isDescendant(of: host)
    }
    return false
  }

  func exposesAccessibilityElement(identifier: String) -> Bool {
    hasAccessibilityElement(identifier: identifier)
  }

  func activeCollectionStructure(
    for surface: WorkspaceSurface
  ) -> (scrollViewCount: Int, tableViewCount: Int)? {
    guard let host = activeSurfaceHost(for: surface) else { return nil }
    let views = [host] + Self.descendantViews(in: host)
    let scrollViewCount = views.compactMap { $0 as? NSScrollView }.filter {
      !($0.documentView is NSTextView)
    }.count
    let tableViewCount = views.compactMap { $0 as? NSTableView }.count
    return (scrollViewCount, tableViewCount)
  }

  func performCollectionRowAction<ID>(kind: String, id: ID) throws {
    let identifier = WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
      kind: kind,
      id: id
    )
    guard clickAccessibilityElement(identifier: identifier) else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted \(kind) row did not publish its native press target"
      )
    }
  }

  func prepareCollectionRowAction<ID>(
    kind: String,
    id: ID,
    on surface: WorkspaceSurface
  ) async throws {
    let identifier = WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
      kind: kind,
      id: id
    )
    guard await revealCollectionAccessibilityElement(
      identifier: identifier,
      on: surface
    ) else {
      throw PerformanceHarnessError.actionUnavailable(
        "the requested \(kind) row could not be revealed through its visible lazy collection"
      )
    }
  }

  func collectionRowAccessibilitySelection<ID>(kind: String, id: ID) -> Bool? {
    let identifier = WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
      kind: kind,
      id: id
    )
    let mountedViews: [NSView] = [hostingView] + Self.descendantViews(in: hostingView)
    return mountedViews.first(where: {
      $0.accessibilityIdentifier() == identifier
        && $0.window === window
        && Self.isEffectivelyExposed($0)
    })?.isAccessibilitySelected()
  }

  func firstEditableTextView() -> NSTextView? {
    Self.firstEditableTextView(in: hostingView)
  }

  func firstEditableTextView(in host: NSView) -> NSTextView? {
    Self.firstEditableTextView(in: host)
  }

  func firstTextField(in host: NSView) -> NSTextField? {
    Self.firstTextField(in: host)
  }

  func textField(accessibilityIdentifier: String) -> NSTextField? {
    ([hostingView] + Self.descendantViews(in: hostingView))
      .compactMap { $0 as? NSTextField }
      .first {
        $0.accessibilityIdentifier() == accessibilityIdentifier
          && $0.window === window
          && Self.isEffectivelyExposed($0)
      }
  }

  func accessibilityElementCount(identifierPrefix: String) -> Int {
    let nativeIdentifiers = ([hostingView] + Self.descendantViews(in: hostingView))
      .filter {
        $0.window === window
          && Self.isEffectivelyExposed($0)
          && $0.accessibilityIdentifier().hasPrefix(identifierPrefix)
      }
      .map { ObjectIdentifier($0) }
    let synthesizedIdentifiers = Self.accessibilityElements(in: hostingView)
      .filter { $0.accessibilityIdentifier?.hasPrefix(identifierPrefix) == true }
      .map(\.identifier)
    return Set(nativeIdentifiers + synthesizedIdentifiers).count
  }

  func waitForSyntaxTextView(timeout: TimeInterval = 10) async throws -> OrgSyntaxTextView {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      await drawAfterDeferredViewUpdates()
      if let textView = Self.firstSyntaxTextView(in: hostingView),
         textView.window === window,
         textView.bounds.width > 0,
         textView.bounds.height > 0,
         textView.visibleRect.width > 0,
         textView.visibleRect.height > 0 {
        return textView
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw PerformanceHarnessError.destinationEvidenceMissing(
      "the actual workspace source editor did not mount visible AppKit content"
    )
  }

  func waitForFirstUsableSyntaxTextView(
    timeout: TimeInterval = 10
  ) async throws -> OrgSyntaxTextView {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      await drawFirstUsableFrame()
      if let textView = Self.firstSyntaxTextView(in: hostingView),
         textView.window === window,
         textView.bounds.width > 0,
         textView.bounds.height > 0,
         textView.visibleRect.width > 0,
         textView.visibleRect.height > 0 {
        return textView
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw PerformanceHarnessError.destinationEvidenceMissing(
      "the actual workspace source editor did not publish a first usable AppKit frame"
    )
  }

  func primaryTranscriptScrollGeometry() async -> OpenOrgScrollGeometry? {
    let views = [hostingView] + Self.descendantViews(in: hostingView)
    guard let webView = views.first(where: {
      $0.accessibilityIdentifier() == AIChatAccessibilityIdentity.transcriptScrollBridge
        && $0.window === window
    }) as? WKWebView,
          let value = try? await webView.evaluateJavaScript(
            "({height:document.documentElement.scrollHeight,viewport:innerHeight,origin:scrollY})"
          ) as? [String: Any],
          let documentHeight = value["height"] as? NSNumber,
          let viewportHeight = value["viewport"] as? NSNumber,
          let originY = value["origin"] as? NSNumber else {
      return nil
    }
    return OpenOrgScrollGeometry(
      documentHeight: CGFloat(truncating: documentHeight),
      viewportHeight: CGFloat(truncating: viewportHeight),
      originY: CGFloat(truncating: originY),
      isFlipped: true
    )
  }

  func close() {
    window.contentView = nil
    window.close()
  }

  private static func firstEditableTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView,
       textView.isEditable,
       !(textView is OrgSyntaxTextView) {
      return textView
    }
    if let scrollView = view as? NSScrollView,
       let documentView = scrollView.documentView,
       let textView = firstEditableTextView(in: documentView) {
      return textView
    }
    for subview in view.subviews {
      if let textView = firstEditableTextView(in: subview) { return textView }
    }
    return nil
  }

  private static func firstTextField(in view: NSView) -> NSTextField? {
    if let textField = view as? NSTextField, textField.isEditable {
      return textField
    }
    for subview in view.subviews {
      if let textField = firstTextField(in: subview) { return textField }
    }
    return nil
  }

  private static func firstSyntaxTextView(in view: NSView) -> OrgSyntaxTextView? {
    if let textView = view as? OrgSyntaxTextView { return textView }
    if let scrollView = view as? NSScrollView,
       let documentView = scrollView.documentView,
       let textView = firstSyntaxTextView(in: documentView) {
      return textView
    }
    for subview in view.subviews {
      if let textView = firstSyntaxTextView(in: subview) { return textView }
    }
    return nil
  }

  private static func scrollViews(in view: NSView) -> [NSScrollView] {
    var result = view is NSScrollView ? [view as! NSScrollView] : []
    for subview in view.subviews {
      result.append(contentsOf: scrollViews(in: subview))
    }
    return result
  }

  private func workspaceSurfaceHosts() -> [NSHostingView<AnyView>] {
    let surfaceIdentifiers = Set(WorkspaceSurface.allCases.map {
      WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: $0)
    })
    return Self.descendantViews(in: hostingView)
      .compactMap { $0 as? NSHostingView<AnyView> }
      .filter { host in
        surfaceIdentifiers.contains(host.accessibilityIdentifier())
      }
  }

  private func activeSurfaceHost(for surface: WorkspaceSurface) -> NSHostingView<AnyView>? {
    let expectedIdentifier = WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: surface)
    if let mountedSurfaceHost,
       mountedSurfaceHost.accessibilityIdentifier() == expectedIdentifier,
       mountedSurfaceHost.superview != nil,
       mountedSurfaceHost.window === window,
       Self.isEffectivelyExposed(mountedSurfaceHost) {
      return mountedSurfaceHost
    }
    if let identifiedHost = cachedSurfaceHost(for: surface),
       Self.isEffectivelyExposed(identifiedHost) {
      return identifiedHost
    }
    let candidates = Self.descendantViews(in: hostingView)
      .compactMap { $0 as? NSHostingView<AnyView> }
      .filter {
        $0 !== hostingView
          && $0.superview != nil
          && $0.window === window
          && Self.isEffectivelyExposed($0)
      }
    return candidates
      .max { left, right in
        left.bounds.width * left.bounds.height < right.bounds.width * right.bounds.height
      }
  }

  private func hasDestinationEvidence(
    _ surface: WorkspaceSurface,
    runPage: RunsAndReviewPage?,
    in host: NSView
  ) -> Bool {
    if surface == .approvals, let runPage {
      let identifier = RunsAndReviewPageAccessibilityIdentity.accessibilityIdentifier(for: runPage)
      return ([host] + Self.descendantViews(in: host)).contains { view in
        view.accessibilityIdentifier() == identifier
          && view.window === window
          && view.isAccessibilitySelected()
      }
    }
    if host.accessibilityIdentifier()
      == WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: surface) {
      return true
    }
    let markers: [String]
    switch surface {
    case .home: markers = ["AI Chat"]
    case .aiChat: markers = ["Codex Chat", "OpenClaw Chat", "Claude Chat", "Shared AI Room"]
    default: markers = [surface.title]
    }
    let labels = Self.accessibilityElements(in: host).compactMap(\.label)
    return markers.contains { marker in
      labels.contains { $0.localizedCaseInsensitiveContains(marker) }
    }
  }

  private func clickAccessibilityElement(identifier: String) -> Bool {
    if let nativeView = ([hostingView] + Self.descendantViews(in: hostingView)).first(where: {
      $0.accessibilityIdentifier() == identifier
        && $0.window === window
        && Self.isEffectivelyExposed($0)
    }), nativeView.accessibilityPerformPress() {
      return true
    }
    let candidates = Self.accessibilityElements(in: hostingView).filter {
      $0.accessibilityIdentifier == identifier
    }
    for candidate in candidates {
      if candidate.performPress() { return true }
    }
    return false
  }

  private func hasAccessibilityElement(identifier: String) -> Bool {
    if ([hostingView] + Self.descendantViews(in: hostingView)).contains(where: {
      $0.accessibilityIdentifier() == identifier
        && $0.window === window
        && Self.isEffectivelyExposed($0)
    }) {
      return true
    }
    return Self.accessibilityElements(in: hostingView).contains {
      $0.accessibilityIdentifier == identifier
    }
  }

  private func revealSidebarAccessibilityElement(identifier: String) async -> Bool {
    if hasAccessibilityElement(identifier: identifier) { return true }
    guard let tableView = sidebarTableView(), tableView.numberOfRows > 0 else {
      return false
    }

    // SwiftUI's sidebar List realizes only the native rows around the visible
    // viewport. Drive its NSTableView directly so every candidate row gets a
    // chance to publish its exact accessibility identity. Settled targets and
    // the Show More control live at the bottom, while the disclosure is near
    // the top, so choose the scan direction that avoids needless full redraws.
    let rowIndices: [Int]
    if identifier == AIChatSidebarThreadAccessibilityIdentity.settledDisclosure {
      rowIndices = Array(0..<tableView.numberOfRows)
    } else {
      rowIndices = Array((0..<tableView.numberOfRows).reversed())
    }
    for row in rowIndices {
      tableView.scrollRowToVisible(row)
      await nextMainQueueTurn()
      draw()
      if hasAccessibilityElement(identifier: identifier) { return true }
    }
    return false
  }

  private func revealCollectionAccessibilityElement(
    identifier: String,
    on surface: WorkspaceSurface
  ) async -> Bool {
    if hasAccessibilityElement(identifier: identifier) { return true }
    guard let host = activeSurfaceHost(for: surface) else { return false }
    let scrollViews = Self.scrollViews(in: host)
      .filter { scrollView in
        scrollView.window === window
          && Self.isEffectivelyExposed(scrollView)
          && !(scrollView.documentView is NSTextView)
          && scrollView.documentView != nil
      }
      .sorted {
        $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height
      }

    // LazyVStack only publishes accessibility elements around the visible
    // viewport. Scan the shipping collection itself to realize the requested
    // row; the timed interaction remains the row's own native AX press.
    for scrollView in scrollViews {
      guard let documentView = scrollView.documentView else { continue }
      var targetY = documentView.bounds.minY
      for _ in 0..<256 {
        documentView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let minimumY = documentView.bounds.minY
        let maximumY = max(minimumY, documentView.bounds.maxY - clipView.bounds.height)
        targetY = min(maximumY, max(minimumY, targetY))
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        await nextMainQueueTurn()
        draw()
        if hasAccessibilityElement(identifier: identifier) { return true }
        if targetY >= maximumY { break }
        targetY += max(1, clipView.bounds.height * 0.75)
      }
    }
    return false
  }

  private func sidebarTableView() -> NSTableView? {
    Self.descendantViews(in: hostingView)
      .compactMap { $0 as? NSTableView }
      .filter { tableView in
        guard tableView.window === window,
              !tableView.isHidden,
              let scrollView = tableView.enclosingScrollView,
              scrollView.documentView === tableView,
              scrollView.bounds.width >= 140,
              scrollView.bounds.height >= 200
        else { return false }
        let frame = scrollView.convert(scrollView.bounds, to: hostingView)
        return frame.intersects(hostingView.bounds)
      }
      .min { left, right in
        guard let leftScrollView = left.enclosingScrollView,
              let rightScrollView = right.enclosingScrollView
        else { return false }
        let leftFrame = leftScrollView.convert(leftScrollView.bounds, to: hostingView)
        let rightFrame = rightScrollView.convert(rightScrollView.bounds, to: hostingView)
        if abs(leftFrame.minX - rightFrame.minX) > 0.5 {
          return leftFrame.minX < rightFrame.minX
        }
        return leftFrame.height > rightFrame.height
      }
  }

  private func waitForSidebarRowPublication(
    after previousRowCount: Int,
    timeout: TimeInterval = 3
  ) async -> Bool {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      await nextMainQueueTurn()
      draw()
      if let tableView = sidebarTableView(), tableView.numberOfRows > previousRowCount {
        return true
      }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
  }

  private static func commandShortcut(
    for surface: WorkspaceSurface
  ) -> (character: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16)? {
    switch surface {
    case .home: ("1", [.command], 18)
    case .agenda: ("2", [.command], 19)
    case .savedViews, .canvases: nil
    case .files: ("3", [.command], 20)
    case .approvals: ("4", [.command], 21)
    case .meetings: ("5", [.command], 23)
    case .aiChat: ("6", [.command], 22)
    case .sources: ("0", [.command], 29)
    case .search: ("f", [.command, .shift], 3)
    case .skills: ("k", [.command, .shift], 40)
    case .externalThreads, .activity, .calendar: nil
    case .people, .companies, .pluginApp: nil
    }
  }

  private static func keyEvent(
    character: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    windowNumber: Int
  ) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      characters: character,
      charactersIgnoringModifiers: character,
      isARepeat: false,
      keyCode: keyCode
    ))
  }

  private static func descendantViews(in view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendantViews(in: $0) }
  }

  private static func isEffectivelyExposed(_ view: NSView) -> Bool {
    var candidate: NSView? = view
    while let current = candidate {
      if current.isHidden || current.isAccessibilityHidden() { return false }
      candidate = current.superview
    }
    return true
  }

  private static func accessibilityElements(in root: NSView) -> [AccessibilityNode] {
    var result: [AccessibilityNode] = []
    var pending: [(AccessibilityNode, Int)] = [(.view(root), 0)]
    var visited = Set<ObjectIdentifier>()
    while let (element, depth) = pending.popLast(), result.count < 10_000 {
      guard visited.insert(element.identifier).inserted else { continue }
      switch element {
      case .view(let view):
        // Hidden cached hosts stay attached to preserve native and SwiftUI
        // identity. Do not let UI automation discover or invoke descendants
        // through that retained subtree.
        guard isEffectivelyExposed(view) else { continue }
      case .element(let value):
        guard !value.isAccessibilityHidden() else { continue }
      }
      result.append(element)
      guard depth < 40 else { continue }
      for child in element.children {
        if let view = child as? NSView {
          pending.append((.view(view), depth + 1))
        } else if let accessible = child as? NSAccessibilityElement {
          pending.append((.element(accessible), depth + 1))
        }
      }
    }
    return result
  }
}

@MainActor
private final class MountedAIChatPerformanceHarness {
  let window: NSWindow
  let hostingView: NSHostingView<AnyView>

  init(rootView: AnyView, width: CGFloat = 760, height: CGFloat = 560) {
    hostingView = NSHostingView(rootView: rootView)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
  }

  func draw() {
    hostingView.needsLayout = true
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    window.update()
    CATransaction.flush()
  }

  func drawFirstUsableFrame() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume(returning: ())
      }
    }
    draw()
  }

  func waitForFirstUsableAccessibilityElement(
    identifier: String,
    timeout: TimeInterval = 3
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      await drawFirstUsableFrame()
      if exposesAccessibilityElement(identifier: identifier) { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw PerformanceHarnessError.destinationEvidenceMissing(
      "the mounted OpenClaw probe did not expose \(identifier)"
    )
  }

  func exposesAccessibilityElement(identifier: String) -> Bool {
    ([hostingView] + Self.descendantViews(in: hostingView)).contains {
      $0.window === window
        && !$0.isHidden
        && $0.accessibilityIdentifier() == identifier
    }
  }

  func accessibilityElementCount(identifierPrefix: String) -> Int {
    ([hostingView] + Self.descendantViews(in: hostingView)).filter {
      $0.window === window
        && !$0.isHidden
        && $0.accessibilityIdentifier().hasPrefix(identifierPrefix)
    }.count
  }

  func close() {
    window.contentView = nil
    window.close()
  }

  private static func descendantViews(in view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendantViews(in: $0) }
  }
}

/// Drives the source editor as mounted by `ContentView` and `WorkspaceStore`.
/// This deliberately does not construct an editor in isolation: selection,
/// source loading, bindings, navigation checkpoints, and persistence all stay
/// on the same path as the shipping workspace.
@MainActor
private final class WorkspaceEditorPerformanceHarness {
  private unowned let workspace: WorkspaceRenderPerformanceHarness
  let textView: OrgSyntaxTextView

  init(workspace: WorkspaceRenderPerformanceHarness, textView: OrgSyntaxTextView) {
    self.workspace = workspace
    self.textView = textView
  }

  var gutterView: OrgSourceEditorGutterView? {
    textView.enclosingScrollView?.verticalRulerView as? OrgSourceEditorGutterView
  }

  var textLength: Int {
    textView.textStorage?.length ?? 0
  }

  func text(in range: NSRange) throws -> String {
    let storage = try XCTUnwrap(textView.textStorage)
    guard range.location >= 0, NSMaxRange(range) <= storage.length else {
      throw PerformanceHarnessError.actionUnavailable("requested editor text range was unavailable")
    }
    return storage.attributedSubstring(from: range).string
  }

  func drawAfterDeferredViewUpdates() async {
    await workspace.drawAfterDeferredViewUpdates()
  }

  func scrollCaretToVisible(at requestedLocation: Int) async {
    let length = (textView.string as NSString).length
    let location = min(max(0, requestedLocation), max(0, length - 1))
    let range = NSRange(location: location, length: 0)
    workspace.window.makeFirstResponder(textView)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    await drawAfterDeferredViewUpdates()
  }

  func scrollGlyphToVisible(at requestedLocation: Int) async {
    let length = (textView.string as NSString).length
    let location = min(max(0, requestedLocation), max(0, length - 1))
    textView.scrollRangeToVisible(NSRange(location: location, length: min(1, length)))
    await drawAfterDeferredViewUpdates()
  }

  @discardableResult
  func scrollDocument(to fraction: Double) throws -> CGFloat {
    let scrollView = try XCTUnwrap(textView.enclosingScrollView)
    let documentView = try XCTUnwrap(scrollView.documentView)
    let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    guard maximumY > scrollView.contentView.bounds.height else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted editor document was not tall enough for deep scrolling"
      )
    }
    let clampedFraction = min(1, max(0, fraction))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY * clampedFraction))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    return scrollView.contentView.bounds.origin.y
  }

  func clickFoldGutterMarker(_ item: OrgSourceEditorGutterItem) throws {
    let gutter = try XCTUnwrap(gutterView)
    guard item.isFoldable, let y = gutter.markerY(for: item, in: textView) else {
      throw PerformanceHarnessError.actionUnavailable(
        "the requested foldable gutter marker was not visible"
      )
    }
    let windowPoint = gutter.convert(NSPoint(x: 8, y: y), to: nil)
    let event = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: windowPoint,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: workspace.window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    ))
    gutter.mouseDown(with: event)
  }

  var isSelectionVisible: Bool {
    let selection = textView.selectedRange()
    guard selection.location != NSNotFound,
          let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return false }
    let characterLength = (textView.string as NSString).length
    guard characterLength > 0 else { return true }
    let characterRange = NSRange(
      location: min(selection.location, characterLength - 1),
      length: 1
    )
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: characterRange,
      actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    let origin = textView.textContainerOrigin
    rect.origin.x += origin.x
    rect.origin.y += origin.y
    return textView.visibleRect.intersects(rect.insetBy(dx: -2, dy: -2))
  }

  func performHitTestedDragSelection(at requestedLocation: Int) throws {
    let length = (textView.string as NSString).length
    let startLocation = min(max(0, requestedLocation), max(0, length - 10))
    let endLocation = min(max(0, length - 1), startLocation + 8)
    let startPoint = try windowPoint(forCharacterAt: startLocation)
    let endPoint = try windowPoint(forCharacterAt: endLocation)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let makeEvent: (NSEvent.EventType, NSPoint, Float) throws -> NSEvent = { type, point, pressure in
      try XCTUnwrap(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: self.workspace.window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: pressure
      ))
    }
    textView.mouseDown(with: try makeEvent(.leftMouseDown, startPoint, 1))
    textView.mouseDragged(with: try makeEvent(.leftMouseDragged, endPoint, 1))
    textView.mouseUp(with: try makeEvent(.leftMouseUp, endPoint, 0))
    let selection = textView.selectedRange()
    guard selection.location <= startLocation,
          NSMaxRange(selection) >= endLocation,
          selection.length > 0
    else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted workspace editor did not select the hit-tested glyph range"
      )
    }
  }

  @discardableResult
  func performHitTestedCaretClick(at requestedLocation: Int) throws -> Int {
    let length = (textView.string as NSString).length
    guard length > 0 else { throw PerformanceHarnessError.missingEditor }
    let location = min(max(0, requestedLocation), length - 1)
    let point = try windowPoint(forCharacterAt: location)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let makeEvent: (NSEvent.EventType, Float) throws -> NSEvent = { type, pressure in
      try XCTUnwrap(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: self.workspace.window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: pressure
      ))
    }
    workspace.window.makeFirstResponder(textView)
    textView.mouseDown(with: try makeEvent(.leftMouseDown, 1))
    textView.mouseUp(with: try makeEvent(.leftMouseUp, 0))
    let selection = textView.selectedRange()
    guard selection.length == 0,
          selection.location != NSNotFound,
          abs(selection.location - location) <= 1
    else {
      throw PerformanceHarnessError.actionUnavailable(
        "the mounted workspace editor click did not move the caret to the hit-tested glyph"
      )
    }
    return selection.location
  }

  private func windowPoint(forCharacterAt location: Int) throws -> NSPoint {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { throw PerformanceHarnessError.missingEditor }
    let characterRange = NSRange(location: location, length: 1)
    layoutManager.ensureLayout(forCharacterRange: characterRange)
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: characterRange,
      actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    guard !rect.isEmpty else { throw PerformanceHarnessError.missingEditor }
    let localPoint = NSPoint(x: rect.midX, y: rect.midY)
    guard textView.visibleRect.insetBy(dx: -2, dy: -2).contains(localPoint) else {
      throw PerformanceHarnessError.destinationEvidenceMissing(
        "the mounted editor glyph selected for dragging was not visible"
      )
    }
    return textView.convert(localPoint, to: nil)
  }
}

@MainActor
private final class LargeEditorPerformanceHarness {
  final class State {
    var text: String
    var selection: NSRange

    init(text: String) {
      self.text = text
      selection = NSRange(location: (text as NSString).length, length: 0)
    }
  }

  let state: State
  let window: NSWindow
  let hostingView: NSHostingView<AnyView>
  let textView: OrgSyntaxTextView

  var gutterView: OrgSourceEditorGutterView? {
    textView.enclosingScrollView?.verticalRulerView as? OrgSourceEditorGutterView
  }

  init(text: String) throws {
    state = State(text: text)
    let state = state
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { state.text },
        set: { state.text = $0 }
      ),
      monospaced: true,
      showsScrollers: true,
      textInset: NSSize(width: 12, height: 12),
      focusOnAppear: false,
      textPublishing: .deferred(milliseconds: 500),
      liveHighlighting: true,
      incrementalHighlighting: true,
      incrementalHighlightingDelayMilliseconds: 120,
      concealsSyntax: false,
      orgWritingCommands: true,
      textChecking: .spellingAndGrammar,
      caretPublishingDelayMilliseconds: 180,
      semanticAnalysisDelayMilliseconds: 900,
      semanticAnalyzer: nil,
      selection: Binding(
        get: { state.selection },
        set: { state.selection = $0 }
      ),
      onLocalTextChange: { _ in }
    )
    hostingView = NSHostingView(rootView: AnyView(editor))
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 760),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
    hostingView.layoutSubtreeIfNeeded()
    guard let textView = Self.firstSyntaxTextView(in: hostingView) else {
      throw PerformanceHarnessError.missingEditor
    }
    self.textView = textView
    textView.setSelectedRange(state.selection)
    draw()
  }

  func draw() {
    hostingView.needsLayout = true
    hostingView.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()
    window.update()
    CATransaction.flush()
  }

  func drawAfterDeferredViewUpdates() async {
    await nextMainQueueTurn()
    draw()
    await nextMainQueueTurn()
    draw()
  }

  func scrollCaretToVisible(at requestedLocation: Int) async {
    let length = (textView.string as NSString).length
    let location = min(max(0, requestedLocation), max(0, length - 1))
    let range = NSRange(location: location, length: 0)
    window.makeFirstResponder(textView)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    await drawAfterDeferredViewUpdates()
  }

  var isSelectionVisible: Bool {
    let selection = textView.selectedRange()
    guard selection.location != NSNotFound,
          let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return false }
    let characterLength = (textView.string as NSString).length
    guard characterLength > 0 else { return true }
    let characterRange = NSRange(
      location: min(selection.location, characterLength - 1),
      length: 1
    )
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: characterRange,
      actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    let origin = textView.textContainerOrigin
    rect.origin.x += origin.x
    rect.origin.y += origin.y
    return textView.visibleRect.intersects(rect.insetBy(dx: -2, dy: -2))
  }

  func performHitTestedDragSelection(at requestedLocation: Int) throws {
    let length = (textView.string as NSString).length
    let startLocation = min(max(0, requestedLocation), max(0, length - 10))
    let endLocation = min(max(0, length - 1), startLocation + 8)
    let startPoint = try windowPoint(forCharacterAt: startLocation)
    let endPoint = try windowPoint(forCharacterAt: endLocation)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let makeEvent: (NSEvent.EventType, NSPoint, Float) throws -> NSEvent = { type, point, pressure in
      try XCTUnwrap(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: self.window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: pressure
      ))
    }
    textView.mouseDown(with: try makeEvent(.leftMouseDown, startPoint, 1))
    textView.mouseDragged(with: try makeEvent(.leftMouseDragged, endPoint, 1))
    textView.mouseUp(with: try makeEvent(.leftMouseUp, endPoint, 0))
    let selection = textView.selectedRange()
    guard selection.location <= startLocation,
          NSMaxRange(selection) >= endLocation,
          selection.length > 0
    else {
      throw PerformanceHarnessError.actionUnavailable(
        "the editor selection bridge did not select the hit-tested glyph range"
      )
    }
  }

  private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume(returning: ())
      }
    }
  }

  private func windowPoint(forCharacterAt location: Int) throws -> NSPoint {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { throw PerformanceHarnessError.missingEditor }
    let characterRange = NSRange(location: location, length: 1)
    layoutManager.ensureLayout(forCharacterRange: characterRange)
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: characterRange,
      actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    guard !rect.isEmpty else { throw PerformanceHarnessError.missingEditor }
    let localPoint = NSPoint(x: rect.midX, y: rect.midY)
    guard textView.visibleRect.insetBy(dx: -2, dy: -2).contains(localPoint) else {
      throw PerformanceHarnessError.destinationEvidenceMissing(
        "the editor glyph selected for dragging was not visible"
      )
    }
    return textView.convert(localPoint, to: nil)
  }

  func close() {
    window.contentView = nil
    window.close()
  }

  private static func firstSyntaxTextView(in view: NSView) -> OrgSyntaxTextView? {
    if let textView = view as? OrgSyntaxTextView { return textView }
    if let scrollView = view as? NSScrollView,
       let documentView = scrollView.documentView,
       let textView = firstSyntaxTextView(in: documentView) {
      return textView
    }
    for subview in view.subviews {
      if let textView = firstSyntaxTextView(in: subview) { return textView }
    }
    return nil
  }
}

private enum PerformanceHarnessError: Error {
  case missingEditor
  case missingComposer
  case memoryProbeFailed
  case timedOut
  case actionUnavailable(String)
  case destinationEvidenceMissing(String)
}

@MainActor
private final class WorkspaceApplicationLifecycleDriver: NSObject {
  private weak var store: WorkspaceStore?
  private var becameActiveCount = 0
  private var resignedActiveCount = 0

  init(store: WorkspaceStore) {
    self.store = store
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didBecomeActive(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: NSApplication.shared
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didResignActive(_:)),
      name: NSApplication.didResignActiveNotification,
      object: NSApplication.shared
    )
  }

  func stop() {
    NotificationCenter.default.removeObserver(self)
  }

  func deactivate(window: NSWindow) async throws {
    let previousCount = resignedActiveCount
    window.orderOut(nil)
    NSApplication.shared.deactivate()
    if resignedActiveCount == previousCount {
      // A command-line XCTest host is not always a foreground application.
      // Posting the lifecycle notification still drives the exact observer
      // semantics mounted by Org2WorkspaceApp, after a real deactivate call.
      NotificationCenter.default.post(
        name: NSApplication.didResignActiveNotification,
        object: NSApplication.shared
      )
    }
    await nextMainQueueTurn()
    guard resignedActiveCount > previousCount else {
      throw PerformanceHarnessError.actionUnavailable(
        "the application-resign lifecycle handler did not run"
      )
    }
  }

  func activate(window: NSWindow) async throws {
    let previousCount = becameActiveCount
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    if becameActiveCount == previousCount {
      NotificationCenter.default.post(
        name: NSApplication.didBecomeActiveNotification,
        object: NSApplication.shared
      )
    }
    await nextMainQueueTurn()
    guard becameActiveCount > previousCount else {
      throw PerformanceHarnessError.actionUnavailable(
        "the application-activation lifecycle handler did not run"
      )
    }
  }

  @objc private func didBecomeActive(_ notification: Notification) {
    guard notification.object as? NSApplication === NSApplication.shared else { return }
    becameActiveCount += 1
    store?.setWorkspaceRealtimeRefreshActive(true)
    store?.setRunReviewAutoRefreshActive(true, refreshImmediately: false)
  }

  @objc private func didResignActive(_ notification: Notification) {
    guard notification.object as? NSApplication === NSApplication.shared else { return }
    resignedActiveCount += 1
    store?.setWorkspaceRealtimeRefreshActive(false)
    store?.setRunReviewAutoRefreshActive(false, refreshImmediately: false)
  }

  private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume(returning: ()) }
    }
  }
}

private final class ProbeTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var ticks = 0
  func now() -> CFTimeInterval {
    lock.withLock { ticks += 1; return Double(ticks) / 1000 }
  }

  /// Model time that passes without a probe timestamp, such as a delayed
  /// background timer wake-up.
  func advance(milliseconds: Int) {
    lock.withLock { ticks += milliseconds }
  }
}

@MainActor
private final class MainActorGapProbe {
  typealias Cadence = @Sendable (UInt64) async throws -> Void

  private let intervalMilliseconds: Double
  private let cadence: Cadence
  private let now: @Sendable () -> CFTimeInterval
  private let didEnqueueForTesting: (@Sendable () -> Void)?
  private var task: Task<Double, Never>?

  init(
    intervalMilliseconds: Double = 5,
    cadence: @escaping Cadence = { intervalNanoseconds in
      try await Task.sleep(nanoseconds: intervalNanoseconds)
    },
    didEnqueueForTesting: (@Sendable () -> Void)? = nil,
    now: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }
  ) {
    self.intervalMilliseconds = intervalMilliseconds
    self.cadence = cadence
    self.now = now
    self.didEnqueueForTesting = didEnqueueForTesting
  }

  func start() {
    precondition(task == nil, "MainActorGapProbe must be stopped before it is restarted")
    let intervalNanoseconds = UInt64(intervalMilliseconds * 1_000_000)
    let cadence = cadence
    let now = now
    let didEnqueueForTesting = didEnqueueForTesting
    task = Task.detached(priority: .userInitiated) {
      var maximumGapMilliseconds: Double = 0
      while !Task.isCancelled {
        do {
          try await cadence(intervalNanoseconds)
        } catch {
          break
        }
        guard !Task.isCancelled else { break }

        // Timestamp only the interval during which work is actually queued on
        // the main thread. Background timer wake-up jitter, process suspension,
        // and profiler pauses before this point are intentionally excluded.
        let enqueuedAt = now()
        let gapMilliseconds: Double = await withCheckedContinuation { continuation in
          DispatchQueue.main.async {
            continuation.resume(returning: (now() - enqueuedAt) * 1_000)
          }
          didEnqueueForTesting?()
        }
        maximumGapMilliseconds = max(
          maximumGapMilliseconds,
          max(0, gapMilliseconds)
        )
      }
      return maximumGapMilliseconds
    }
  }

  func stop() async -> Double {
    guard let runningTask = task else { return 0 }
    runningTask.cancel()
    // The detached loop allows at most one outstanding main-queue callback and
    // awaits it before continuing. Awaiting the task therefore drains any
    // callback that raced with cancellation before this probe can be reused or
    // released by a subsequent test.
    let maximumGapMilliseconds = await runningTask.value
    task = nil
    return maximumGapMilliseconds
  }

  deinit {
    task?.cancel()
  }
}

@MainActor
final class OpenOrgPerformanceGateTests: XCTestCase {
  func testMainActorGapProbeMeasuresEnqueueToCallbackInterval() async throws {
    // Check the measuring code deterministically. Real UI performance gates
    // below still use the monotonic system clock and their original budgets.
    let clock = ProbeTestClock()
    let probe = MainActorGapProbe(intervalMilliseconds: 1, now: { clock.now() })
    probe.start()
    try await Task.sleep(nanoseconds: 75_000_000)

    let maximumGapMilliseconds = await probe.stop()

    XCTAssertEqual(maximumGapMilliseconds, 1, accuracy: 0.000_001)
  }

  func testMainActorGapProbeDoesNotCountBackgroundCadenceDelay() async {
    // Use the deterministic clock: on a loaded CI runner the real main queue
    // can legitimately take tens of milliseconds to service a callback, which
    // says nothing about whether cadence delay is excluded. Each cadence step
    // advances the clock by 50 ms without a probe timestamp; each timestamp
    // advances it by 1 ms. Counting the cadence delay would report >= 51 ms.
    let clock = ProbeTestClock()
    let callbackEnqueued = DispatchSemaphore(value: 0)
    let probe = MainActorGapProbe(
      intervalMilliseconds: 1,
      cadence: { _ in
        // Model delayed timer wake-up, profiler suspension, or background
        // scheduling pressure before a heartbeat reaches the main queue.
        clock.advance(milliseconds: 50)
        try await Task.sleep(nanoseconds: 1_000_000)
      },
      didEnqueueForTesting: { callbackEnqueued.signal() },
      now: { clock.now() }
    )
    probe.start()
    XCTAssertEqual(callbackEnqueued.wait(timeout: .now() + 5), .success)

    let maximumGapMilliseconds = await probe.stop()

    XCTAssertEqual(maximumGapMilliseconds, 1, accuracy: 0.000_001)
  }

  func testMainActorGapProbeDetectsThirtyMillisecondMainActorBlock() async {
    let callbackEnqueued = DispatchSemaphore(value: 0)
    let probe = MainActorGapProbe(
      intervalMilliseconds: 1,
      didEnqueueForTesting: { callbackEnqueued.signal() }
    )
    probe.start()
    XCTAssertEqual(callbackEnqueued.wait(timeout: .now() + 1), .success)

    let blockedUntil = CACurrentMediaTime() + 0.030
    while CACurrentMediaTime() < blockedUntil {}
    let maximumGapMilliseconds = await probe.stop()

    XCTAssertGreaterThanOrEqual(maximumGapMilliseconds, 25)
  }

  func testLatencyRecorderMakesRuntimeSamplesAssertable() {
    WorkspaceInteractionLatency.resetRecordedSamples()
    for sample in 1...100 {
      WorkspaceInteractionLatency.recordForTesting(
        Double(sample),
        for: .workspaceNavigationToDraw
      )
    }

    let snapshot = WorkspaceInteractionLatency.snapshot(for: .workspaceNavigationToDraw)
    XCTAssertEqual(snapshot.sampleCount, 100)
    XCTAssertEqual(snapshot.retainedSampleCount, 100)
    XCTAssertEqual(snapshot.p50Milliseconds, 50)
    XCTAssertEqual(snapshot.p95Milliseconds, 95)
    XCTAssertEqual(snapshot.p99Milliseconds, 99)
    XCTAssertEqual(snapshot.maximumMilliseconds, 100)
    XCTAssertEqual(snapshot.budgetViolationCount, 50)
    XCTAssertTrue(snapshot.exceedsBudget)
    WorkspaceInteractionLatency.resetRecordedSamples()
  }

  func testSurfaceCachePublishesStableNativeDestinationIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-surface-mount-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsSuite = "openorg-surface-mount-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let transcriptURL = root.appendingPathComponent("performance-chat.json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    store.aiChatTranscriptSaverForTesting = {}
    await store.waitForAIChatTranscriptLoadForTesting()
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    store.selectedSurface = .home

    let harness = WorkspaceRenderPerformanceHarness(store: store)
    defer { harness.close() }
    try await harness.waitForVisibleDestination(.home, store: store)

    let surfaceHost = try XCTUnwrap(harness.workspaceSurfaceHost())
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertNotNil(surfaceHost.superview)
    XCTAssertTrue(surfaceHost.window === harness.window)
    XCTAssertFalse(surfaceHost.isHidden)
    XCTAssertFalse(surfaceHost.isAccessibilityHidden())
    XCTAssertTrue(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .home)
    ))

    let composer = try XCTUnwrap(harness.firstEditableTextView(in: surfaceHost))
    XCTAssertTrue(harness.window.makeFirstResponder(composer))
    XCTAssertTrue(harness.hostContainsFirstResponder(composer))

    try harness.performNavigationAction(to: .agenda)
    try await harness.waitForVisibleDestination(.agenda, store: store)
    let agendaHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .agenda))
    XCTAssertTrue(agendaHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertNotNil(agendaHost.superview)
    XCTAssertTrue(agendaHost.window === harness.window)
    XCTAssertFalse(agendaHost.isHidden)
    XCTAssertFalse(agendaHost.isAccessibilityHidden())
    XCTAssertTrue(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .agenda)
    ))
    XCTAssertNil(composer.window)
    XCTAssertFalse(harness.hostContainsFirstResponder(composer))
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .home)
    ))
    store.isAgendaFilterFocused = true
    await harness.drawAfterDeferredViewUpdates()
    XCTAssertTrue(store.isAgendaFilterFocused)

    try harness.performNavigationAction(to: .search)
    try await harness.waitForVisibleDestination(.search, store: store)
    let searchHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .search))
    XCTAssertTrue(searchHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .agenda)
    ))
    XCTAssertFalse(
      store.isAgendaFilterFocused,
      "Replacing the active root must deliver the outgoing surface's onDisappear"
    )
    let searchField = try XCTUnwrap(harness.firstTextField(in: searchHost))
    XCTAssertTrue(harness.window.makeFirstResponder(searchField))
    searchField.selectText(nil)
    XCTAssertTrue(harness.window.firstResponder is NSTextView)
    XCTAssertTrue(harness.hostContainsFirstResponder(searchField))

    try harness.performNavigationAction(to: .files)
    try await harness.waitForVisibleDestination(.files, store: store)
    let filesHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .files))
    XCTAssertTrue(filesHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertNil(searchField.window)
    XCTAssertFalse(harness.hostContainsFirstResponder(searchField))
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .search)
    ))

    var previousSurface = WorkspaceSurface.files
    for surface in [
      WorkspaceSurface.meetings,
      WorkspaceSurface.sources,
      WorkspaceSurface.skills,
      WorkspaceSurface.externalThreads,
    ] {
      try harness.performNavigationAction(to: surface)
      try await harness.waitForVisibleDestination(surface, store: store)
      let currentHost = try XCTUnwrap(harness.cachedSurfaceHost(for: surface))
      XCTAssertTrue(currentHost === surfaceHost)
      XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
      XCTAssertNotNil(currentHost.superview)
      XCTAssertTrue(currentHost.window === harness.window)
      XCTAssertFalse(currentHost.isHidden)
      XCTAssertFalse(currentHost.isAccessibilityHidden())
      XCTAssertFalse(harness.exposesAccessibilityElement(
        identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: previousSurface)
      ))
      previousSurface = surface
    }

    try harness.performNavigationAction(to: .aiChat)
    try await harness.waitForVisibleDestination(.aiChat, store: store)
    let openClawHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .aiChat))
    XCTAssertTrue(openClawHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertTrue(openClawHost.window === harness.window)
    XCTAssertFalse(openClawHost.isHidden)
    XCTAssertFalse(openClawHost.isAccessibilityHidden())
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: previousSurface)
    ))

    store.runsAndReviewPage = .runs
    try harness.performNavigationAction(to: .approvals)
    try await harness.waitForVisibleDestination(.approvals, runPage: .runs, store: store)
    let approvalsHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .approvals))
    XCTAssertTrue(approvalsHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertTrue(approvalsHost.window === harness.window)
    XCTAssertFalse(approvalsHost.isHidden)
    XCTAssertFalse(approvalsHost.isAccessibilityHidden())
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .aiChat)
    ))
    XCTAssertTrue(harness.exposesAccessibilityElement(
      identifier: RunsAndReviewPageAccessibilityIdentity.accessibilityIdentifier(for: .runs)
    ))
    XCTAssertTrue(harness.exposesAccessibilityElement(
      identifier: RunsAndReviewPageAccessibilityIdentity.accessibilityIdentifier(for: .review)
    ))

    let runSearch = try XCTUnwrap(harness.firstTextField(in: approvalsHost))
    XCTAssertTrue(harness.window.makeFirstResponder(runSearch))
    runSearch.selectText(nil)
    XCTAssertTrue(harness.window.firstResponder is NSTextView)
    XCTAssertTrue(harness.hostContainsFirstResponder(approvalsHost))

    try await harness.performRunsAndReviewPageAction(.review, store: store)
    try await harness.waitForVisibleDestination(.approvals, runPage: .review, store: store)
    XCTAssertTrue(harness.cachedSurfaceHost(for: .approvals) === approvalsHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertEqual(store.runsAndReviewPage, .review)
    XCTAssertNil(runSearch.window)
    XCTAssertFalse(harness.hostContainsFirstResponder(runSearch))

    try harness.performNavigationAction(to: .home)
    try await harness.waitForVisibleDestination(.home, store: store)
    let restoredHomeHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .home))
    XCTAssertTrue(restoredHomeHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertNotNil(restoredHomeHost.superview)
    XCTAssertTrue(restoredHomeHost.window === harness.window)
    XCTAssertFalse(restoredHomeHost.isHidden)
    XCTAssertFalse(restoredHomeHost.isAccessibilityHidden())
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: .approvals)
    ))
    XCTAssertFalse(harness.exposesAccessibilityElement(
      identifier: RunsAndReviewPageAccessibilityIdentity.accessibilityIdentifier(for: .review)
    ))

    try harness.performNavigationAction(to: .approvals)
    try await harness.waitForVisibleDestination(.approvals, runPage: .review, store: store)
    let restoredApprovalsHost = try XCTUnwrap(harness.cachedSurfaceHost(for: .approvals))
    XCTAssertTrue(restoredApprovalsHost === surfaceHost)
    XCTAssertEqual(harness.workspaceSurfaceHostCount(), 1)
    XCTAssertNotNil(restoredApprovalsHost.superview)
    XCTAssertTrue(restoredApprovalsHost.window === harness.window)
    XCTAssertFalse(restoredApprovalsHost.isHidden)
    XCTAssertFalse(restoredApprovalsHost.isAccessibilityHidden())
  }

  func testSidebarPublishesStableExternalThreadsPressIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-sidebar-action-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsSuite = "openorg-sidebar-action-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("performance-chat.json"),
      legacyDefaultsDomains: []
    )
    store.aiChatTranscriptSaverForTesting = {}
    await store.waitForAIChatTranscriptLoadForTesting()
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    store.replaceExternalThreadsForTesting(syntheticExternalThreads(count: 1))
    store.selectedSurface = .home

    let harness = WorkspaceRenderPerformanceHarness(store: store)
    defer { harness.close() }
    try await harness.waitForVisibleDestination(.home, store: store)

    try harness.performNavigationAction(to: .externalThreads)
    try await harness.waitForVisibleDestination(.externalThreads, store: store)
    XCTAssertEqual(store.selectedSurface, .externalThreads)
  }

  func testChatThreadsRemainIndividuallyVirtualizedNativeSidebarRows() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-sidebar-thread-rows-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaultsSuite = "openorg-sidebar-thread-rows-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("performance-chat.json"),
      legacyDefaultsDomains: []
    )
    store.aiChatTranscriptSaverForTesting = {}
    await store.waitForAIChatTranscriptLoadForTesting()
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    _ = store.createAIChatThread(runtime: .openClaw)
    store.selectedSurface = .home

    let harness = WorkspaceRenderPerformanceHarness(store: store)
    defer { harness.close() }
    try await harness.waitForVisibleDestination(.home, store: store)
    let baselineRowCount = try XCTUnwrap(harness.sidebarNativeListRowCount())

    for _ in 0..<8 {
      _ = store.createAIChatThread(runtime: .openClaw)
    }
    await harness.drawAfterDeferredViewUpdates()

    let expandedRowCount = try XCTUnwrap(harness.sidebarNativeListRowCount())
    XCTAssertGreaterThanOrEqual(
      expandedRowCount - baselineRowCount,
      8,
      "Each chat thread must remain its own native List row; nesting the whole thread stack in one automatic-height table row regresses activation and resize latency"
    )
  }

  /// The Review page re-renders as each of a bulk selection's approvals
  /// starts and finishes snoozing. No single frame may stall long enough for
  /// the spinning cursor.
  func testBulkSnoozeOnTheReviewPageKeepsFramesShort() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-bulk-snooze-ui-\(UUID().uuidString)", isDirectory: true)
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    let runs = try ApprovalBulkSnoozePerformanceTests.runs(count: 12_600)
    store.replaceAgentRunsForTesting(runs)
    let queue = (0..<24).map { ApprovalBulkSnoozePerformanceTests.queueItem(run: runs[$0], index: $0) }
    store.replaceApprovalItemsForTesting(queue)
    let snoozeUntil = Date().addingTimeInterval(3 * 3600)
    // The follow-up rescan reports the batch as snoozed, as the CLI does. A
    // rescan that returned them as pending would re-insert 15 rows, which is
    // a different interaction from the one this gate measures.
    let rescannedQueue = ApprovalBulkSnoozePerformanceTests.queue(queue, snoozingFirst: 15, until: snoozeUntil)
    store.approvalQueueLoaderForTesting = { (rescannedQueue, []) }
    let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
    store.agentRunApprovalSnoozeForTesting = { runID, _, _ in
      try await Task.sleep(nanoseconds: 20_000_000)
      return try XCTUnwrap(runsByID[runID])
    }
    store.selectedSurface = .approvals
    store.runsAndReviewPage = .review

    let harness = WorkspaceRenderPerformanceHarness(store: store)
    defer { harness.close() }
    try await harness.waitForVisibleDestination(.approvals, runPage: .review, store: store)
    // Review always shows a selected approval's detail. Build it before the
    // measurement so the first-ever detail layout is not charged to the
    // batch; snoozing the selected row still moves the selection mid-batch.
    store.selectApprovalItem(queue[0])
    await harness.drawAfterDeferredViewUpdates()
    for item in queue.prefix(15) {
      store.toggleApprovalItemBulkSelection(item)
    }
    await harness.drawAfterDeferredViewUpdates()

    var frames: [Double] = []
    let snooze = Task { @MainActor in
      await store.snoozeSelectedApprovals(until: snoozeUntil)
    }
    let deadline = CACurrentMediaTime() + 1.5
    while CACurrentMediaTime() < deadline {
      try await Task.sleep(nanoseconds: 4_000_000)
      let start = CACurrentMediaTime()
      harness.draw()
      frames.append((CACurrentMediaTime() - start) * 1_000)
    }
    await snooze.value
    XCTAssertEqual(store.bulkApprovalSelectionCount, 0)
    let longest = frames.max() ?? 0
    let total = frames.reduce(0, +)
    print("PERFORMANCE bulk-snooze-review-frames: count=\(frames.count) max=\(String(format: "%.1f", longest)) ms total=\(String(format: "%.1f", total)) ms")
    XCTAssertLessThan(longest, 250, "a Review frame took \(longest) ms during bulk snooze")
  }

  func testReleaseBuildStaysResponsiveAtRealCorpusShape() async throws {
    guard let environment = try performanceEnvironment() else {
      throw XCTSkip("Run through npm run test:macos-performance to generate the scale fixture")
    }
#if DEBUG
    XCTFail("The performance gate must run an optimized release build")
#endif
    XCTAssertEqual(WorkspaceRuntimeIdentity.compiledBuildConfiguration, "release")
    XCTAssertEqual(environment.manifest.activeFileCount, environment.shape.documents.activeFileCount)

    let transcriptURL = environment.corpusRoot
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("performance-chat.json")
    let chatFixture = try writeShardedChatTranscript(
      shape: environment.shape.chat,
      to: transcriptURL
    )
    let defaultsSuite = "openorg-performance-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }

    let transcriptLoadStart = CACurrentMediaTime()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    store.aiChatTranscriptSaverForTesting = {}
    await store.waitForAIChatTranscriptLoadForTesting()
    let transcriptLoadMilliseconds = (CACurrentMediaTime() - transcriptLoadStart) * 1_000
    XCTAssertEqual(store.aiChatThreads.count, environment.shape.chat.threadCount)
    XCTAssertEqual(store.selectedAIChatThreadID, chatFixture.selectedThreadID)
    XCTAssertTrue(
      Set(chatFixture.coldAttachmentThreadIDs).isSubset(
        of: store.unloadedAIChatThreadIDsForTesting
      ),
      "The synthetic switch workload must start as settled, unloaded sharded threads"
    )
    try OpenOrgPerformanceResults.record(
      scenario: "chat-transcript-load",
      samples: [transcriptLoadMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    store.setCorpusRoot(environment.corpusRoot, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    let corpusRefreshStart = CACurrentMediaTime()
    await store.refreshCorpusFiles()
    let corpusRefreshMilliseconds = (CACurrentMediaTime() - corpusRefreshStart) * 1_000
    XCTAssertEqual(store.corpusFiles.count, environment.shape.documents.activeFileCount)
    try OpenOrgPerformanceResults.record(
      scenario: "corpus-catalog-refresh",
      samples: [corpusRefreshMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let expectedResolverNodes = environment.shape.documents.activeFileCount
      - (environment.shape.documents.extensionMix["csv"] ?? 0)
    try await waitUntil(
      timeout: 30,
      description: "the initial resolver/search projection",
      diagnostics: {
        "building=\(store.isBuildingSearchIndex) nodes=\(store.orgRoamLinkResolver.nodes.count) expected>=\(expectedResolverNodes) files=\(store.corpusFiles.count)"
      }
    ) {
      !store.isBuildingSearchIndex
        && store.orgRoamLinkResolver.nodes.count >= (
          environment.shape.documents.activeFileCount
            - (environment.shape.documents.extensionMix["csv"] ?? 0)
        )
    }

    // Populate every corpus-scale destination before timing navigation. Empty
    // placeholders are materially cheaper than the screens users interact
    // with and previously let broad invalidation regressions pass unnoticed.
    await store.refreshAgenda(updatesStatus: false)
    await store.refreshMeetings()
    await store.refreshSourceConnections()
    let syntheticRuns = try syntheticAgentRuns(count: environment.shape.workspaceScale.agentRunCount)
    store.replaceAgentRunsForTesting(syntheticRuns)
    store.replaceApprovalItemsForTesting(
      syntheticApprovalItems(
        runs: Array(syntheticRuns.prefix(environment.shape.workspaceScale.approvalItemCount))
      )
    )
    store.replaceExternalThreadsForTesting(
      syntheticExternalThreads(count: environment.shape.workspaceScale.externalThreadCount)
    )
    store.searchQuery = "Synthetic performance fixture"
    await store.runSearch()
    XCTAssertGreaterThan(store.agenda?.totalItemCount ?? 0, 0)
    XCTAssertEqual(store.agentRuns.count, environment.shape.workspaceScale.agentRunCount)
    XCTAssertEqual(store.approvalItems.count, environment.shape.workspaceScale.approvalItemCount)
    let expectedMeetingCount = try XCTUnwrap(
      environment.shape.documents.zones.first { $0.kind == "meetings" }?.fileCount
    )
    XCTAssertEqual(store.meetings.count, expectedMeetingCount)
    XCTAssertEqual(store.sourceProfiles.count, environment.shape.workspaceScale.sourceProfileCount)
    XCTAssertEqual(store.externalThreads.count, environment.shape.workspaceScale.externalThreadCount)
    XCTAssertGreaterThan(store.workspaceTextSearchResultCount, 0)

    store.selectedSurface = .home
    let workspaceHarness = WorkspaceRenderPerformanceHarness(store: store)
    defer { workspaceHarness.close() }
    try await workspaceHarness.waitForVisibleDestination(.home, store: store)

    // A real Cmd-Tab activation checks the selected document and drains any
    // FSEvents received while inactive after the first frame. Select the final
    // catalog entry so a linear selected-file lookup cannot hide behind an
    // early match, prove the production watcher is mounted, and explicitly
    // queue one watcher event while inactive in every measured sample.
    let activationFile = try XCTUnwrap(store.corpusFiles.last)
    XCTAssertEqual(store.corpusFiles.last?.id, activationFile.id)
    XCTAssertTrue(
      store.corpusFileWatcherRootPathsForTesting.contains(
        environment.corpusRoot.standardizedFileURL.path
      ),
      "Cmd-Tab coverage requires the production corpus watcher to be active"
    )
    store.selectCorpusFile(activationFile)
    try await workspaceHarness.waitForVisibleDestination(.files, store: store)
    try await waitUntil(timeout: 5) {
      store.selectedLocation?.file == activationFile.path
        && store.selectedEntrySource != nil
        && !store.isRenderingEntrySource
    }

    WorkspaceInteractionLatency.resetRecordedSamples()
    var activationSamples: [Double] = []
    var postActivationGapSamples: [Double] = []
    let lifecycle = WorkspaceApplicationLifecycleDriver(store: store)
    defer { lifecycle.stop() }
    let mainThreadProjectionBuildsBeforeActivation =
      store.orgRoamSearchProjectionMainThreadBuildCountForTesting
    let mainThreadProjectionReleasesBeforeActivation =
      store.orgRoamSearchProjectionMainThreadReleaseCountForTesting
    for _ in 0..<20 {
      try await lifecycle.deactivate(window: workspaceHarness.window)
      let projectionBuildsBeforeActivation =
        store.orgRoamSearchProjectionBuildCountForTesting
      store.handleCorpusFileEvents(
        [activationFile.path],
        corpusRoot: environment.corpusRoot,
        requiresFullScan: false
      )
      let token = WorkspaceInteractionLatency.begin(.applicationActivationToDraw)
      try await lifecycle.activate(window: workspaceHarness.window)
      try await workspaceHarness.waitForFirstUsableDestination(.files, store: store)
      activationSamples.append(WorkspaceInteractionLatency.finish(token))
      try await workspaceHarness.waitForVisibleDestination(.files, store: store)

      let postActivationProbe = MainActorGapProbe()
      postActivationProbe.start()
      try await Task.sleep(nanoseconds: 550_000_000)
      try await waitUntil(
        timeout: 30,
        description: "the post-activation corpus event pipeline for sample \(activationSamples.count)"
      ) {
        store.orgRoamSearchProjectionBuildCountForTesting > projectionBuildsBeforeActivation
          && self.corpusEventPipelineIsIdle(store)
      }
      postActivationGapSamples.append(await postActivationProbe.stop())
      try await workspaceHarness.waitForVisibleDestination(.files, store: store)
    }
    XCTAssertEqual(
      store.orgRoamSearchProjectionMainThreadBuildCountForTesting,
      mainThreadProjectionBuildsBeforeActivation,
      "Pending watcher events after Cmd-Tab must never rebuild resolver/search projections on the main thread"
    )
    XCTAssertEqual(
      store.orgRoamSearchProjectionMainThreadReleaseCountForTesting,
      mainThreadProjectionReleasesBeforeActivation,
      "Pending watcher events after Cmd-Tab must never tear down rejected/replaced projection graphs on the main thread"
    )
    try OpenOrgPerformanceResults.record(
      scenario: "application-activation-to-draw",
      samples: activationSamples,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "post-activation-main-actor-gap",
      samples: postActivationGapSamples,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    lifecycle.stop()

    XCTAssertTrue(corpusEventPipelineIsIdle(store))

    // The activation workload intentionally invalidates agenda, Agent Work,
    // and search. Drain those refreshes outside navigation timing, then restore
    // the deterministic scale projections so a screen-switch sample measures
    // mounting/drawing rather than an earlier watcher event's deferred I/O.
    let watcherInvalidatedTargets: [(WorkspaceSurface, RunsAndReviewPage?)] = [
      (.agenda, nil), (.approvals, .runs), (.search, nil),
    ]
    for (surface, runPage) in watcherInvalidatedTargets {
      if store.selectedSurface != surface {
        try workspaceHarness.performNavigationAction(to: surface)
      }
      if let runPage, store.runsAndReviewPage != runPage {
        try await workspaceHarness.performRunsAndReviewPageAction(runPage, store: store)
      }
      try await workspaceHarness.waitForVisibleDestination(
        surface,
        runPage: runPage,
        store: store
      )
      try await waitUntil(timeout: 30) {
        !store.isWorkspaceSurfaceDirty(surface)
          && !store.hasWorkspaceSurfaceRefreshTaskForTesting(surface)
      }
    }
    store.replaceAgentRunsForTesting(syntheticRuns)
    store.replaceApprovalItemsForTesting(
      syntheticApprovalItems(
        runs: Array(syntheticRuns.prefix(environment.shape.workspaceScale.approvalItemCount))
      )
    )
    store.searchQuery = "Synthetic performance fixture"
    await store.runSearch()
    XCTAssertFalse(store.isWorkspaceSurfaceDirty(.agenda))
    XCTAssertFalse(store.isWorkspaceSurfaceDirty(.approvals))
    XCTAssertFalse(store.isWorkspaceSurfaceDirty(.search))
    store.selectedSurface = .home
    try await workspaceHarness.waitForVisibleDestination(.home, store: store)

    var navigationTargetCycle: [(WorkspaceSurface, RunsAndReviewPage?)] = [
      (.agenda, nil), (.files, nil), (.approvals, .runs), (.approvals, .review),
      (.meetings, nil), (.sources, nil), (.externalThreads, nil), (.aiChat, nil),
      (.home, nil), (.search, nil),
    ]
    if ProcessInfo.processInfo.environment["OPENORG_PERFORMANCE_TRACE_NAV_TARGET"]
      == "approvals-review" {
      navigationTargetCycle = [(.approvals, .runs), (.approvals, .review)]
    }
    try await recordWorkspaceNavigationGate(
      scenario: "workspace-navigation-to-draw",
      targetCycle: navigationTargetCycle,
      store: store,
      harness: workspaceHarness,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try await verifyRepresentativeLazyCollectionActions(
      store: store,
      harness: workspaceHarness
    )

    if store.selectedSurface != .aiChat {
      try workspaceHarness.performNavigationAction(to: .aiChat)
    }
    try await workspaceHarness.waitForVisibleDestination(.aiChat, store: store)
    let threadIDs = chatFixture.coldAttachmentThreadIDs.filter {
      store.unloadedAIChatThreadIDsForTesting.contains($0)
    }
    XCTAssertEqual(threadIDs.count, chatFixture.coldAttachmentThreadIDs.count)
    XCTAssertGreaterThanOrEqual(threadIDs.count, 30)
    WorkspaceInteractionLatency.resetRecordedSamples()
    var threadSwitchSamples: [Double] = []
    var threadSwitchSampleLabels: [String] = []
    let tracesThreadSwitches = ProcessInfo.processInfo.environment[
      "OPENORG_PERFORMANCE_TRACE_CHAT"
    ] == "1"
    var tracedThreadID: UUID?
    var tracedThreadStart = CACurrentMediaTime()
    var tracedHydrationMilliseconds: Double?
    store.aiChatThreadHydrationDidLoadForTesting = { threadID in
      guard tracesThreadSwitches, threadID == tracedThreadID else { return }
      tracedHydrationMilliseconds = (CACurrentMediaTime() - tracedThreadStart) * 1_000
    }
    for index in 0..<30 {
      let targetID = threadIDs[index]
      XCTAssertTrue(
        store.unloadedAIChatThreadIDsForTesting.contains(targetID),
        "Every measured synthetic switch must begin with a cold settled shard"
      )
      try await workspaceHarness.prepareAIThreadRowAction(targetID)
      tracedThreadID = targetID
      tracedThreadStart = CACurrentMediaTime()
      tracedHydrationMilliseconds = nil
      let token = WorkspaceInteractionLatency.begin(.threadSwitchToDraw)
      try workspaceHarness.performAIThreadRowAction(targetID)
      let actionMilliseconds = (CACurrentMediaTime() - tracedThreadStart) * 1_000
      try await waitForFirstUsableThreadRestoration(
        targetID: targetID,
        store: store,
        harness: workspaceHarness,
        requiresVisibleAttachment: true
      )
      let firstUsableMilliseconds = WorkspaceInteractionLatency.finish(token)
      threadSwitchSamples.append(firstUsableMilliseconds)
      if tracesThreadSwitches {
        print(
          "PERFORMANCE-TRACE chat-switch index=\(index) "
            + "action=\(String(format: "%.1f", actionMilliseconds)) ms "
            + "hydration=\(tracedHydrationMilliseconds.map { String(format: "%.1f", $0) } ?? "pending") ms "
            + "first-usable=\(String(format: "%.1f", firstUsableMilliseconds)) ms"
        )
      }
      try await waitForThreadRestoration(
        targetID: targetID,
        store: store,
        harness: workspaceHarness,
        requiresVisibleAttachment: true
      )
      threadSwitchSampleLabels.append(
        index == 0 ? "heavy-largest-message-with-attachment" : "attachment-thread"
      )
    }
    try OpenOrgPerformanceResults.record(
      scenario: "thread-switch-to-draw",
      samples: threadSwitchSamples,
      sampleLabels: threadSwitchSampleLabels,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let largeThreadFindMilliseconds = try await exerciseLargeThreadFind(
      fixture: chatFixture,
      store: store,
      harness: workspaceHarness
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-thread-find-query-to-reveal",
      samples: [largeThreadFindMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let sharedRoomMountSamples = try await exerciseBoundedSharedRoomMount(
      store: store
    )
    try OpenOrgPerformanceResults.record(
      scenario: "shared-room-bounded-mount-to-draw",
      samples: sharedRoomMountSamples,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let largeLiveUpdate = try await exerciseCollapsedLargeLiveUpdate()
    try OpenOrgPerformanceResults.record(
      scenario: "large-live-update-to-draw",
      samples: [largeLiveUpdate.presentationMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-live-update-main-actor-gap",
      samples: [largeLiveUpdate.maximumMainActorGapMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    workspaceHarness.orderFront()
    try await workspaceHarness.waitForVisibleDestination(.aiChat, store: store)

    let composer = try XCTUnwrap(
      workspaceHarness.firstEditableTextView(),
      "The populated AI chat destination must mount its native composer"
    )
    workspaceHarness.window.makeFirstResponder(composer)
    WorkspaceInteractionLatency.resetRecordedSamples()
    for index in 0..<20 {
      let event = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: workspaceHarness.window.windowNumber,
        context: nil,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0
      ))
      composer.keyDown(with: event)
      await workspaceHarness.drawAfterDeferredViewUpdates()
      try await waitUntil(timeout: 1) {
        WorkspaceInteractionLatency.snapshot(for: .composerKeyToDraw).sampleCount >= index + 1
      }
    }
    try OpenOrgPerformanceResults.record(
      scenario: "composer-key-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .composerKeyToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    if store.selectedSurface != .approvals {
      try workspaceHarness.performNavigationAction(to: .approvals)
    }
    if store.runsAndReviewPage != .runs {
      try await workspaceHarness.performRunsAndReviewPageAction(.runs, store: store)
    }
    try await workspaceHarness.waitForVisibleDestination(
      .approvals,
      runPage: .runs,
      store: store
    )
    WorkspaceInteractionLatency.resetRecordedSamples()
    var pointerSamples: [Double] = []
    let pointerTargetRunIndices = (0..<20).map { 1 + ($0 * 12) }
    for targetRunIndex in pointerTargetRunIndices {
      let targetRun = syntheticRuns[targetRunIndex]
      try await workspaceHarness.prepareCollectionRowAction(
        kind: "run",
        id: targetRun.id,
        on: .approvals
      )
      let token = WorkspaceInteractionLatency.begin(.pointerToWindowUpdate)
      try workspaceHarness.performCollectionRowAction(kind: "run", id: targetRun.id)
      try await workspaceHarness.waitForFirstUsableDestination(
        .approvals,
        runPage: .runs,
        store: store
      )
      guard store.selectedAgentRunID == targetRun.id else {
        throw PerformanceHarnessError.destinationEvidenceMissing(
          "the pressed Run Center row did not publish its exact selection by the first draw"
        )
      }
      pointerSamples.append(WorkspaceInteractionLatency.finish(token))
      try await waitUntil(timeout: 2) {
        store.selectedAgentRunID == targetRun.id
      }
      try await workspaceHarness.waitForVisibleDestination(
        .approvals,
        runPage: .runs,
        store: store
      )
    }
    try OpenOrgPerformanceResults.record(
      scenario: "pointer-to-window-update",
      samples: pointerSamples,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    WorkspaceInteractionLatency.resetRecordedSamples()
    var resizeSamples: [Double] = []
    var resizeSampleLabels: [String] = []
    workspaceHarness.hostingView.viewWillStartLiveResize()
    // Keep the corpus-scale Run Center mounted and drive a continuous 60-frame
    // gesture through both axes. This catches choppy repeated layout under a
    // populated list/detail workload instead of isolated resize snapshots.
    for index in 0..<60 {
      let phase = Double(index) / 59.0
      let width = 760 + CGFloat((sin(phase * .pi * 3) + 1) * 440)
      let height = 700 + CGFloat((cos(phase * .pi * 4) + 1) * 100)
      let token = WorkspaceInteractionLatency.begin(.windowResizeToDraw)
      workspaceHarness.resize(width: width, height: height)
      await workspaceHarness.drawFirstUsableFrame()
      resizeSamples.append(WorkspaceInteractionLatency.finish(token))
      resizeSampleLabels.append("approvals:runs")
    }
    workspaceHarness.hostingView.viewDidEndLiveResize()
    try await workspaceHarness.waitForVisibleDestination(
      .approvals,
      runPage: .runs,
      store: store
    )

    // Keep the original continuous Run Center gesture above, then exercise
    // every other top-level destination under the same unchanged resize
    // budget. Target labels make any surface-specific regression explicit.
    let additionalResizeTargets: [(WorkspaceSurface, RunsAndReviewPage?)] = [
      (.home, nil), (.agenda, nil), (.files, nil), (.approvals, .review),
      (.meetings, nil), (.sources, nil), (.externalThreads, nil),
      (.aiChat, nil), (.search, nil),
    ]
    for (targetIndex, target) in additionalResizeTargets.enumerated() {
      let (surface, runPage) = target
      if store.selectedSurface != surface {
        try workspaceHarness.performNavigationAction(to: surface)
      }
      if let runPage, store.runsAndReviewPage != runPage {
        try await workspaceHarness.performRunsAndReviewPageAction(runPage, store: store)
      }
      try await workspaceHarness.waitForVisibleDestination(
        surface,
        runPage: runPage,
        store: store
      )
      workspaceHarness.hostingView.viewWillStartLiveResize()
      for frameIndex in 0..<6 {
        let phase = Double((targetIndex * 6) + frameIndex) / 53.0
        let width = 780 + CGFloat((sin(phase * .pi * 3) + 1) * 420)
        let height = 700 + CGFloat((cos(phase * .pi * 4) + 1) * 100)
        let token = WorkspaceInteractionLatency.begin(.windowResizeToDraw)
        workspaceHarness.resize(width: width, height: height)
        await workspaceHarness.drawFirstUsableFrame()
        resizeSamples.append(WorkspaceInteractionLatency.finish(token))
        resizeSampleLabels.append(
          "\(surface.rawValue):\(runPage?.rawValue.lowercased() ?? "default")"
        )
      }
      workspaceHarness.hostingView.viewDidEndLiveResize()
      try await workspaceHarness.waitForVisibleDestination(
        surface,
        runPage: runPage,
        store: store
      )
    }
    let expectedResizeLabels = Set(
      ["approvals:runs"] + additionalResizeTargets.map { target in
        let (surface, runPage) = target
        return "\(surface.rawValue):\(runPage?.rawValue.lowercased() ?? "default")"
      }
    )
    XCTAssertEqual(resizeSamples.count, 60 + (additionalResizeTargets.count * 6))
    XCTAssertEqual(Set(resizeSampleLabels), expectedResizeLabels)
    try OpenOrgPerformanceResults.record(
      scenario: "window-resize-to-draw",
      samples: resizeSamples,
      sampleLabels: resizeSampleLabels,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let largeDocumentURL = environment.corpusRoot
      .appendingPathComponent(environment.manifest.largestDocumentRelativePath)
    let largeFile = try XCTUnwrap(store.corpusFiles.first {
      URL(fileURLWithPath: $0.path).standardizedFileURL == largeDocumentURL.standardizedFileURL
    })
    XCTAssertGreaterThanOrEqual(
      largeFile.byteCount ?? 0,
      Int64(environment.shape.documents.sizeBytes.max)
    )

    // Include actual workspace selection, detached source loading, SwiftUI
    // detail mounting, and the production WorkspaceStore bindings in the open
    // metric. A direct OrgSyntaxTextEditor harness previously let regressions
    // in those layers escape this gate.
    try await prepareMeasuredCorpusFileRow(
      largeFile,
      store: store,
      harness: workspaceHarness
    )
    let editorOpenStartedAt = CACurrentMediaTime()
    try workspaceHarness.performCorpusFileRowAction(largeFile)
    try await waitUntil(timeout: 20) {
      store.selectedEntrySource?.file == largeFile.path
        && store.selectedEntrySource?.isEditable == true
        && !store.isLoadingEntrySource
    }
    let largeSource = try XCTUnwrap(store.selectedEntrySource)
    let restoredNearEOFLine = max(
      largeSource.startLine,
      largeSource.endLineExclusive - 2
    )
    XCTAssertGreaterThan(
      restoredNearEOFLine,
      largeSource.startLine + 100,
      "The generated editor workload must have a genuinely deep restoration target"
    )
    store.recordDocumentViewportSourceLine(restoredNearEOFLine, for: largeSource)
    store.sourceEditorPresentation = .split
    store.beginEditingSelectedEntry()
    let editorHarness = WorkspaceEditorPerformanceHarness(
      workspace: workspaceHarness,
      textView: try await workspaceHarness.waitForFirstUsableSyntaxTextView(timeout: 10)
    )
    let editorOpenMilliseconds = (CACurrentMediaTime() - editorOpenStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-open-to-first-visible-frame",
      samples: [editorOpenMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    await editorHarness.drawAfterDeferredViewUpdates()
    let editorLength = (editorHarness.textView.string as NSString).length
    XCTAssertGreaterThan(
      store.sourceEditorSelection.location,
      editorLength * 9 / 10,
      "Large editor open must restore a saved viewport near EOF"
    )
    XCTAssertTrue(
      editorHarness.isSelectionVisible,
      "Near-EOF source restoration must scroll the real editor caret into view"
    )
    XCTAssertEqual(store.sourceEditorPresentation, .split)
    XCTAssertLessThan(
      try XCTUnwrap(editorHarness.textView.enclosingScrollView).frame.width,
      workspaceHarness.hostingView.bounds.width * 0.65,
      "The deep-restoration workload must keep the actual split source/preview presentation mounted"
    )
    let initialViewportSourceLine = store.currentDocumentViewportSourceLine
    await editorHarness.scrollCaretToVisible(at: editorLength / 2)
    XCTAssertTrue(editorHarness.isSelectionVisible, "Large-file typing must exercise a visible caret")
    try await waitUntil(timeout: 5) {
      guard let publishedLine = store.currentDocumentViewportSourceLine else { return false }
      return publishedLine != initialViewportSourceLine && publishedLine > 1
    }

    WorkspaceInteractionLatency.resetRecordedSamples()
    let persistenceMarker = "qzxvjkperformance123"
    XCTAssertEqual(persistenceMarker.count, 20)
    _ = try await typeMarker(
      persistenceMarker,
      editor: editorHarness,
      workspace: workspaceHarness,
      waitsForLatencySamples: true
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-key-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .sourceEditorKeyToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let editorResignStartedAt = CACurrentMediaTime()
    workspaceHarness.window.makeFirstResponder(nil)
    let editorResignMilliseconds = (CACurrentMediaTime() - editorResignStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-focus-resign",
      samples: [editorResignMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let postInputGapProbe = MainActorGapProbe()
    postInputGapProbe.start()
    try await waitForEditorSemanticAndGutterConvergence(
      editor: editorHarness,
      timeout: 10
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-post-input-main-actor-gap",
      samples: [await postInputGapProbe.stop()],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let gutter = try XCTUnwrap(editorHarness.gutterView)
    try await waitUntil(timeout: 10) { gutter.items.count > 20 }
    await editorHarness.drawAfterDeferredViewUpdates()
    XCTAssertLessThan(
      gutter.lastDrawnItemCount,
      gutter.items.count,
      "Large-editor gutter drawing must stay bounded to visible headings"
    )

    let editorGestureSamples = try await exerciseLargeEditorGestures(
      editor: editorHarness,
      workspace: workspaceHarness,
      store: store
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-window-resize-to-draw",
      samples: editorGestureSamples.resize,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-continuous-scroll-to-draw",
      samples: editorGestureSamples.scroll,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-post-scroll-main-actor-gap",
      samples: [editorGestureSamples.postScrollMainActorGap],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-gutter-action-to-draw",
      samples: editorGestureSamples.gutter,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-structural-command-to-draw",
      samples: editorGestureSamples.structural,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    WorkspaceInteractionLatency.resetRecordedSamples()
    let caretClickSampleCount = 10
    var editorCaretClickSamples: [Double] = []
    var editorDragSelectionSamples: [Double] = []
    var editorSelectionSamples: [Double] = []
    var editorSelectionSampleLabels: [String] = []
    for index in 1...caretClickSampleCount {
      let location = min(editorLength - 1, (editorLength * index) / caretClickSampleCount)
      await editorHarness.scrollGlyphToVisible(at: location)
      let setupLocation = location >= 4 ? location - 4 : min(editorLength - 1, location + 4)
      editorHarness.textView.setSelectedRange(NSRange(location: setupLocation, length: 0))
      await editorHarness.drawAfterDeferredViewUpdates()

      let clickStartedAt = CACurrentMediaTime()
      let clickedLocation = try editorHarness.performHitTestedCaretClick(at: location)
      await workspaceHarness.drawFirstUsableFrame()
      let clickMilliseconds = (CACurrentMediaTime() - clickStartedAt) * 1_000
      editorCaretClickSamples.append(clickMilliseconds)
      editorSelectionSamples.append(clickMilliseconds)
      editorSelectionSampleLabels.append("caret-click")
      try await waitUntil(timeout: 1) {
        WorkspaceInteractionLatency.snapshot(for: .sourceEditorPointerToDraw).sampleCount
          >= index
      }
      XCTAssertNotEqual(clickedLocation, setupLocation)
      XCTAssertTrue(editorHarness.isSelectionVisible)
      try await waitUntil(timeout: 1) {
        store.sourceEditorSelection.location == clickedLocation
          && store.sourceEditorSelection.length == 0
      }
      await editorHarness.drawAfterDeferredViewUpdates()
    }
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-caret-click-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .sourceEditorPointerToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    WorkspaceInteractionLatency.resetRecordedSamples()
    for index in 1...10 {
      let location = min(editorLength - 1, (editorLength * index) / 10)
      await editorHarness.scrollCaretToVisible(at: location)
      let dragStartedAt = CACurrentMediaTime()
      try editorHarness.performHitTestedDragSelection(at: location)
      await workspaceHarness.drawFirstUsableFrame()
      let dragMilliseconds = (CACurrentMediaTime() - dragStartedAt) * 1_000
      editorDragSelectionSamples.append(dragMilliseconds)
      editorSelectionSamples.append(dragMilliseconds)
      editorSelectionSampleLabels.append("drag-selection")
      XCTAssertTrue(editorHarness.isSelectionVisible)
      try await waitUntil(timeout: 1) {
        WorkspaceInteractionLatency.snapshot(for: .sourceEditorDragToDraw).sampleCount
          >= index
      }
      await editorHarness.drawAfterDeferredViewUpdates()
    }
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-drag-selection-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .sourceEditorDragToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    XCTAssertEqual(editorCaretClickSamples.count, caretClickSampleCount)
    XCTAssertEqual(editorDragSelectionSamples.count, 10)
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-selection-to-draw",
      samples: editorSelectionSamples,
      sampleLabels: editorSelectionSampleLabels,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let explicitSaveMilliseconds = try await explicitlySaveLargeEditor(
      store: store,
      editor: editorHarness,
      workspace: workspaceHarness,
      documentURL: largeDocumentURL,
      requiredMarkers: [persistenceMarker]
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-explicit-save-persistence",
      samples: [explicitSaveMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let menuSaveMarker = "qzxvjkmenusave890123"
    let menuSaveMilliseconds = try await menuSaveLargeEditorBeforeDeferredPublication(
      marker: menuSaveMarker,
      store: store,
      editor: editorHarness,
      workspace: workspaceHarness,
      documentURL: largeDocumentURL
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-menu-save-persistence",
      samples: [menuSaveMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let dirtyNavigationMarker = "qzxvjkdirtyroute456"
    await editorHarness.scrollCaretToVisible(at: max(0, editorHarness.textLength - 1))
    _ = try await typeMarker(
      dirtyNavigationMarker,
      editor: editorHarness,
      workspace: workspaceHarness,
      waitsForLatencySamples: false
    )

    // Navigating with a dirty multi-megabyte source must not synchronously
    // rewrite the document, but the queued persistence barrier must still make
    // the exact editor contents durable before the test proceeds.
    let nextFile = try XCTUnwrap(store.corpusFiles.first { $0.path != largeFile.path })
    try await prepareCorpusFileRow(nextFile, store: store, harness: workspaceHarness)
    let persistenceStartedAt = CACurrentMediaTime()
    try workspaceHarness.performCorpusFileRowAction(nextFile)
    try await waitForFirstUsableRenderedCorpusFileDestination(
      nextFile,
      store: store,
      harness: workspaceHarness
    )
    let dirtyNavigationMilliseconds = (CACurrentMediaTime() - persistenceStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-dirty-navigation-to-draw",
      samples: [dirtyNavigationMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try await waitForRenderedCorpusFileDestination(
      nextFile,
      store: store,
      harness: workspaceHarness
    )
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    let didDrainEditorPersistence = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(
      didDrainEditorPersistence,
      "The actual workspace navigation path must durably drain the editor persistence lane"
    )
    let persistenceMilliseconds = (CACurrentMediaTime() - persistenceStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-draft-persistence",
      samples: [persistenceMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let persistedLargeDocument = try await Task.detached(priority: .utility) {
      try String(contentsOf: largeDocumentURL, encoding: .utf8)
    }.value
    XCTAssertTrue(
      persistedLargeDocument.contains(persistenceMarker)
        && persistedLargeDocument.contains(menuSaveMarker)
        && persistedLargeDocument.contains(dirtyNavigationMarker),
      "The disposable corpus must contain the text entered through the mounted editor"
    )

    let residentBytesBeforeSoak = try residentMemoryBytes()
    var soakMainActorGapSamples: [Double] = []
    var soakMainActorGapLabels: [String] = []
    let soakSurfaces: [WorkspaceSurface] = [
      .files, .agenda, .approvals, .meetings, .sources, .externalThreads,
    ]
    for index in 0..<60 {
      let interactionGapProbe = MainActorGapProbe()
      interactionGapProbe.start()
      // Let the detached cadence enqueue once before the measured interaction;
      // otherwise a fresh per-target probe could miss synchronous work that
      // begins before its first five-millisecond tick.
      try await Task.sleep(nanoseconds: 6_000_000)
      let interactionLabel: String
      switch index % 3 {
      case 0:
        let surface = soakSurfaces[(index / 3) % soakSurfaces.count]
        if surface == .approvals {
          store.runsAndReviewPage = (index / 3).isMultiple(of: 2) ? .runs : .review
        }
        interactionLabel = "navigation:\(surface.rawValue):" + (
          surface == .approvals ? store.runsAndReviewPage.rawValue.lowercased() : "default"
        )
        store.selectedSurface = surface
        await workspaceHarness.drawAfterDeferredViewUpdates()
      case 1:
        interactionLabel = "resize:\(store.selectedSurface.rawValue):" + (
          store.selectedSurface == .approvals
            ? store.runsAndReviewPage.rawValue.lowercased()
            : "default"
        )
        workspaceHarness.resize(
          width: 900 + CGFloat((index % 7) * 90),
          height: 720 + CGFloat((index % 3) * 70)
        )
        await workspaceHarness.drawAfterDeferredViewUpdates()
      default:
        store.selectedSurface = .aiChat
        await workspaceHarness.drawAfterDeferredViewUpdates()
        let targetIndex = (index / 3) % threadIDs.count
        let targetID = threadIDs[targetIndex]
        interactionLabel = targetIndex == 0
          ? "thread-switch:heavy-largest-message-with-attachment"
          : "thread-switch:attachment-thread"
        try await workspaceHarness.prepareAIThreadRowAction(targetID)
        try workspaceHarness.performAIThreadRowAction(targetID)
        try await waitForThreadRestoration(
          targetID: targetID,
          store: store,
          harness: workspaceHarness,
          requiresVisibleAttachment: true
        )
      }
      soakMainActorGapSamples.append(await interactionGapProbe.stop())
      soakMainActorGapLabels.append(interactionLabel)
    }
    let residentBytesAfterSoak = try residentMemoryBytes()
    let residentGrowth = max(0, residentBytesAfterSoak - residentBytesBeforeSoak)
    let residentGrowthLimit: Int64 = 128 * 1_024 * 1_024
    XCTAssertLessThanOrEqual(
      residentGrowth,
      residentGrowthLimit,
      "Repeated navigation/thread/resize interactions grew RSS by \(residentGrowth / 1_024 / 1_024) MiB"
    )
    print(
      "PERFORMANCE interaction-soak-resident-growth: " +
      "\(Double(residentGrowth) / 1_048_576) MiB (limit 128 MiB)"
    )
    try OpenOrgPerformanceResults.record(
      scenario: "interaction-soak-main-actor-gap",
      samples: soakMainActorGapSamples,
      sampleLabels: soakMainActorGapLabels,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    store.searchQuery = "PERFORMANCE_EVENT_BURST"
    await store.runSearch()
    if store.selectedSurface != .search {
      try workspaceHarness.performNavigationAction(to: .search)
    }
    try await workspaceHarness.waitForVisibleDestination(.search, store: store)
    let changedPaths = Array(
      environment.manifest.sampleDocumentRelativePaths
        .prefix(environment.shape.events.burstFileCount)
        .map { environment.corpusRoot.appendingPathComponent($0).path }
    )
    XCTAssertEqual(changedPaths.count, environment.shape.events.burstFileCount)
    let previousSizes = Dictionary(uniqueKeysWithValues: try changedPaths.map { path in
      (path, try XCTUnwrap(store.corpusFiles.first { $0.path == path }?.byteCount))
    })
    var appendedByteCounts: [String: Int64] = [:]
    let expectedNodeIDs = Set(changedPaths.indices.map { "performance-event-\($0)" })
    for (index, path) in changedPaths.enumerated() {
      let appended = Data(
        "\n* PERFORMANCE_EVENT_BURST \(index)\n:PROPERTIES:\n:ID: performance-event-\(index)\n:END:\n".utf8
      )
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.seekToEnd()
      try handle.write(contentsOf: appended)
      try handle.close()
      appendedByteCounts[path] = Int64(appended.count)
    }

    let gapProbe = MainActorGapProbe()
    gapProbe.start()
    store.setWorkspaceRealtimeRefreshActive(true)
    let eventStart = CACurrentMediaTime()
    store.handleCorpusFileEvents(
      changedPaths,
      corpusRoot: environment.corpusRoot,
      requiresFullScan: false
    )
    try await waitUntil(timeout: 5) {
      let allCatalogEntriesPublished = changedPaths.allSatisfy { path in
        store.corpusFiles.first { $0.path == path }?.byteCount
          == previousSizes[path, default: 0] + appendedByteCounts[path, default: 0]
      }
      let publishedNodeIDs = Set(store.orgRoamLinkResolver.nodes.compactMap(\.idValue))
      return allCatalogEntriesPublished
        && expectedNodeIDs.isSubset(of: publishedNodeIDs)
        && !store.isBuildingSearchIndex
        && !store.isSearching
        && store.workspaceTextSearchResultCount >= changedPaths.count
        && self.corpusEventPipelineIsIdle(store)
    }
    try await workspaceHarness.waitForVisibleDestination(.search, store: store)
    let convergenceMilliseconds = (CACurrentMediaTime() - eventStart) * 1_000
    let maximumMainActorGap = await gapProbe.stop()
    store.setWorkspaceRealtimeRefreshActive(false)
    try OpenOrgPerformanceResults.record(
      scenario: "corpus-event-burst-convergence",
      samples: [convergenceMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "corpus-event-burst-main-actor-gap",
      samples: [maximumMainActorGap],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let externalReloadMainActorGap = try await exerciseDirtyExternalReloadConflict(
      store: store,
      workspace: workspaceHarness,
      file: largeFile,
      documentURL: largeDocumentURL
    )
    try OpenOrgPerformanceResults.record(
      scenario: "large-editor-external-reload-main-actor-gap",
      samples: [externalReloadMainActorGap],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    if let realCorpusPath = ProcessInfo.processInfo.environment["OPENORG_PERFORMANCE_REAL_CORPUS_CLONE"],
       !realCorpusPath.isEmpty {
      try await runDisposableRealCorpusGate(
        root: URL(fileURLWithPath: realCorpusPath).standardizedFileURL,
        environment: environment
      )
    }
  }

  private struct Environment {
    let corpusRoot: URL
    let shape: OpenOrgPerformanceShape
    let budgets: OpenOrgPerformanceBudgets
    let manifest: GeneratedCorpusManifest
  }

  private struct WorkspaceNavigationMeasurement {
    let elapsedMilliseconds: Double
    let surfaceActionMilliseconds: Double
    let pageActionMilliseconds: Double
    let firstFrameMilliseconds: Double
    let stabilityMilliseconds: Double
  }

  private func performanceEnvironment() throws -> Environment? {
    let variables = ProcessInfo.processInfo.environment
    guard let corpusRootPath = variables["OPENORG_PERFORMANCE_CORPUS_ROOT"],
          let shapePath = variables["OPENORG_PERFORMANCE_SHAPE_PATH"],
          let budgetsPath = variables["OPENORG_PERFORMANCE_BUDGETS_PATH"]
    else {
      return nil
    }
    let decoder = JSONDecoder()
    let corpusRoot = URL(fileURLWithPath: corpusRootPath).standardizedFileURL
    return Environment(
      corpusRoot: corpusRoot,
      shape: try decoder.decode(
        OpenOrgPerformanceShape.self,
        from: Data(contentsOf: URL(fileURLWithPath: shapePath))
      ),
      budgets: try decoder.decode(
        OpenOrgPerformanceBudgets.self,
        from: Data(contentsOf: URL(fileURLWithPath: budgetsPath))
      ),
      manifest: try decoder.decode(
        GeneratedCorpusManifest.self,
        from: Data(contentsOf: corpusRoot.appendingPathComponent(".openorg-performance-generated.json"))
      )
    )
  }

  private func writeShardedChatTranscript(
    shape: OpenOrgPerformanceShape.Chat,
    to url: URL
  ) throws -> OpenOrgChatFixture {
    XCTAssertEqual(shape.threadCount, shape.activeThreadCount + shape.archivedThreadCount)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let largeMessageSearchQuery = "QZXVJK_LARGE_THREAD_FIND_SENTINEL"
    let heavyThreadIndex = min(shape.activeThreadCount, max(0, shape.threadCount - 1))
    let attachmentCount = min(30, max(0, shape.threadCount - heavyThreadIndex))
    XCTAssertGreaterThanOrEqual(attachmentCount, 30)
    let baseAttachmentBytes = shape.attachmentBytes / attachmentCount
    let attachmentRemainder = shape.attachmentBytes % attachmentCount
    var nextMessageID = 0
    let remainingMessageCount = shape.messageCount - shape.maxMessagesPerThread
    let remainingThreadCount = max(1, shape.threadCount - 1)
    let baseMessagesPerThread = remainingMessageCount / remainingThreadCount
    let extraMessageThreads = remainingMessageCount % remainingThreadCount
    var remainingThreadOrdinal = 0

    let threads = (0..<shape.threadCount).map { threadIndex in
      let messageCount: Int
      if threadIndex == heavyThreadIndex {
        messageCount = shape.maxMessagesPerThread
      } else {
        messageCount = baseMessagesPerThread
          + (remainingThreadOrdinal < extraMessageThreads ? 1 : 0)
        remainingThreadOrdinal += 1
      }
      let messages = (0..<messageCount).map { messageIndex in
        defer { nextMessageID += 1 }
        let isLargestMessage = threadIndex == heavyThreadIndex
          && messageIndex == messageCount - 1
        let content: String
        if isLargestMessage {
          let fillerByteCount = max(
            0,
            shape.largestMessageBodyBytes - largeMessageSearchQuery.utf8.count
          )
          content = String(repeating: "L", count: fillerByteCount)
            + largeMessageSearchQuery
        } else {
          content = "Synthetic performance message \(nextMessageID). "
            + String(repeating: "body ", count: 40)
        }
        let attachmentIndex = threadIndex - heavyThreadIndex
        let attachments: [AIChatAttachment]
        if messageIndex == messageCount - 1,
           attachmentIndex >= 0,
           attachmentIndex < attachmentCount {
          let byteCount = baseAttachmentBytes + (attachmentIndex < attachmentRemainder ? 1 : 0)
          attachments = [AIChatAttachment(
            id: deterministicUUID(900_000 + attachmentIndex),
            fileName: "synthetic-attachment-\(attachmentIndex).bin",
            mimeType: "application/octet-stream",
            data: Data(repeating: UInt8(attachmentIndex % 251), count: byteCount)
          )]
        } else {
          attachments = []
        }
        return AIChatMessage(
          id: deterministicUUID(100_000 + nextMessageID),
          role: messageIndex.isMultiple(of: 2) ? .user : .assistant,
          content: content,
          attachments: attachments,
          createdAt: createdAt.addingTimeInterval(Double(nextMessageID))
        )
      }
      let archived = threadIndex >= shape.activeThreadCount
      return AIChatThread(
        id: deterministicUUID(threadIndex + 1),
        title: "Synthetic thread \(threadIndex + 1)",
        createdAt: createdAt.addingTimeInterval(Double(threadIndex)),
        updatedAt: createdAt.addingTimeInterval(Double(threadIndex + messageCount)),
        runtime: .codex,
        sessionKey: "performance:thread:\(threadIndex + 1)",
        messages: messages,
        isArchived: archived,
        settledAt: archived ? createdAt.addingTimeInterval(Double(threadIndex + messageCount)) : nil
      )
    }
    XCTAssertEqual(threads.reduce(0) { $0 + $1.messages.count }, shape.messageCount)
    let selectedThreadID = threads[0].id
    let snapshot = AIChatTranscriptSnapshot(
      threads: threads,
      selectedThreadID: selectedThreadID,
      settlementSettings: AIChatThreadSettlementSettings()
    )
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: url)
    return OpenOrgChatFixture(
      selectedThreadID: selectedThreadID,
      coldAttachmentThreadIDs: (heavyThreadIndex..<(heavyThreadIndex + attachmentCount)).map {
        threads[$0].id
      },
      heavyThreadID: threads[heavyThreadIndex].id,
      largestMessageID: try XCTUnwrap(threads[heavyThreadIndex].messages.last?.id),
      largeMessageSearchQuery: largeMessageSearchQuery
    )
  }

  private func exerciseLargeThreadFind(
    fixture: OpenOrgChatFixture,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness
  ) async throws -> Double {
    if store.selectedAIChatThreadID != fixture.heavyThreadID {
      try await harness.prepareAIThreadRowAction(fixture.heavyThreadID)
      try harness.performAIThreadRowAction(fixture.heavyThreadID)
      try await waitForThreadRestoration(
        targetID: fixture.heavyThreadID,
        store: store,
        harness: harness,
        requiresVisibleAttachment: true
      )
    }
    XCTAssertLessThanOrEqual(
      harness.accessibilityElementCount(identifierPrefix: "openclaw-chat-message-"),
      AIChatTranscriptWindow.maximumDisplayLimit,
      "A large-thread find must begin from a bounded mounted transcript window"
    )

    store.presentAIChatThreadFind()
    let fieldIdentifier = "openclaw-chat-thread-find-field"
    let fieldDeadline = CACurrentMediaTime() + 3
    var searchField: NSTextField?
    while CACurrentMediaTime() < fieldDeadline {
      await harness.drawFirstUsableFrame()
      searchField = harness.textField(accessibilityIdentifier: fieldIdentifier)
        ?? harness.workspaceSurfaceHost().flatMap(harness.firstTextField(in:))
      if searchField != nil { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let field = try XCTUnwrap(
      searchField,
      "The real thread-find presentation must mount its native text field"
    )
    field.selectText(nil)
    let fieldEditor = try XCTUnwrap(
      harness.window.firstResponder as? NSTextView,
      "The real thread-find field must own AppKit's native field editor"
    )
    fieldEditor.setSelectedRange(NSRange(location: 0, length: fieldEditor.string.utf16.count))
    let keyEvent = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: harness.window.windowNumber,
      context: nil,
      characters: fixture.largeMessageSearchQuery,
      charactersIgnoringModifiers: fixture.largeMessageSearchQuery,
      isARepeat: false,
      keyCode: 0
    ))
    let revealedIdentifier = "openclaw-message-full-revealed-"
      + fixture.largestMessageID.uuidString.lowercased()
    let startedAt = CACurrentMediaTime()
    fieldEditor.keyDown(with: keyEvent)
    let revealDeadline = CACurrentMediaTime() + 10
    while CACurrentMediaTime() < revealDeadline {
      await harness.drawFirstUsableFrame()
      if harness.exposesAccessibilityElement(identifier: revealedIdentifier) {
        let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
        await harness.drawAfterDeferredViewUpdates()
        XCTAssertTrue(harness.exposesAccessibilityElement(identifier: revealedIdentifier))
        XCTAssertLessThanOrEqual(
          harness.accessibilityElementCount(identifierPrefix: "openclaw-chat-message-"),
          AIChatTranscriptWindow.maximumDisplayLimit,
          "Off-window find reveal must center a bounded transcript instead of mounting the full thread"
        )
        return elapsedMilliseconds
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw PerformanceHarnessError.destinationEvidenceMissing(
      "the native large-thread query did not reveal its exact late-message match"
    )
  }

  private func exerciseBoundedSharedRoomMount(
    store: WorkspaceStore
  ) async throws -> [Double] {
    let destinationCount = 500
    let body = String(repeating: "shared room body ", count: 256)
    var samples: [Double] = []
    for sampleIndex in 0..<5 {
      let roundID = deterministicUUID(2_000_000 + sampleIndex)
      let destinationIDs = (0..<destinationCount).map {
        "performance-destination-\(sampleIndex)-\($0)"
      }
      let trigger = AIChatMessage(
        id: deterministicUUID(2_100_000 + sampleIndex),
        role: .user,
        content: "Compare every configured destination",
        audienceDestinationIDs: destinationIDs,
        roomRoundID: roundID
      )
      let responses = Dictionary(uniqueKeysWithValues: destinationIDs.enumerated().map {
        index, destinationID in
        (destinationID, AIChatMessage(
          id: deterministicUUID(2_200_000 + (sampleIndex * destinationCount) + index),
          role: .assistant,
          content: body,
          authorDestinationID: destinationID,
          roomRoundID: roundID
        ))
      })
      let round = AIChatRoomRound(
        id: roundID,
        trigger: trigger,
        expectedDestinationIDs: destinationIDs,
        dispatchesByDestinationID: [:],
        responsesByDestinationID: responses
      )
      let startedAt = CACurrentMediaTime()
      let harness = MountedAIChatPerformanceHarness(
        rootView: AnyView(
          ScrollView {
            AIChatRoomRoundView(round: round, compact: false)
              .padding(16)
          }
          .environment(store)
        )
      )
      try await harness.waitForFirstUsableAccessibilityElement(
        identifier: "openclaw-room-round-omitted-destinations"
      )
      samples.append((CACurrentMediaTime() - startedAt) * 1_000)
      XCTAssertEqual(
        harness.accessibilityElementCount(identifierPrefix: "openclaw-chat-message-"),
        AIChatRoomRoundView.maximumVisibleDestinationCount + 1,
        "The mounted shared-room round must contain only its trigger and bounded visible responses"
      )
      XCTAssertTrue(harness.exposesAccessibilityElement(
        identifier: "openclaw-room-round-omitted-destinations"
      ))
      harness.close()
    }
    return samples
  }

  private func exerciseCollapsedLargeLiveUpdate() async throws -> OpenOrgLargeLiveUpdateResult {
    let liveState = AIChatLiveState()
    let threadID = deterministicUUID(3_000_000)
    let multiMegabyteReply = String(repeating: "live-update-segment ", count: 180_000)
    XCTAssertGreaterThan((multiMegabyteReply as NSString).length, 3_000_000)
    liveState.replaceStreamingReply(multiMegabyteReply, for: threadID, coalesced: false)
    let snapshot = liveState.presentationSnapshot(for: threadID)
    XCTAssertTrue(snapshot.isStreamingReplyTruncated)
    XCTAssertLessThanOrEqual(
      snapshot.streamingReply.count,
      AIChatLiveState.maximumPresentationCharacterCount
    )

    let startedAt = CACurrentMediaTime()
    let harness = MountedAIChatPerformanceHarness(
      rootView: AnyView(AIChatLiveTypingIndicatorView(
        liveState: liveState,
        threadID: threadID,
        startedAt: Date(),
        runtime: .codex,
        destinationTitle: "Codex",
        compact: false,
        onStop: {}
      ))
    )
    defer { harness.close() }
    try await harness.waitForFirstUsableAccessibilityElement(
      identifier: "openclaw-live-presentation-ready",
      timeout: 5
    )
    let presentationMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
    XCTAssertEqual(
      harness.accessibilityElementCount(identifierPrefix: "openclaw-live-presentation-ready"),
      1,
      "Collapsed live updates must mount one bounded prepared body"
    )
    XCTAssertEqual(
      liveState.fullTextMaterializationCountForTesting,
      0,
      "The collapsed typing view must never materialize the multi-megabyte live rope"
    )

    let gapProbe = MainActorGapProbe()
    gapProbe.start()
    liveState.appendStreamingDelta("\nLATEST_BOUNDED_LIVE_UPDATE", for: threadID)
    try await Task.sleep(nanoseconds: 180_000_000)
    await harness.drawFirstUsableFrame()
    let maximumMainActorGapMilliseconds = await gapProbe.stop()
    let updatedSnapshot = liveState.presentationSnapshot(for: threadID)
    XCTAssertTrue(updatedSnapshot.streamingReply.hasSuffix("LATEST_BOUNDED_LIVE_UPDATE"))
    XCTAssertLessThanOrEqual(
      liveState.maximumPresentationCharactersVisitedPerSnapshotForTesting,
      AIChatLiveState.maximumPresentationCharacterCount * 2
    )
    XCTAssertEqual(liveState.fullTextMaterializationCountForTesting, 0)
    return OpenOrgLargeLiveUpdateResult(
      presentationMilliseconds: presentationMilliseconds,
      maximumMainActorGapMilliseconds: maximumMainActorGapMilliseconds
    )
  }

  private func runDisposableRealCorpusGate(
    root: URL,
    environment: Environment
  ) async throws {
    let defaultsSuite = "openorg-real-performance-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    defaults.removePersistentDomain(forName: defaultsSuite)
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let transcriptURL = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    XCTAssertTrue(
      isPath(transcriptURL.path, containedIn: root),
      "The real performance transcript must be inside the disposable clone"
    )
    let realStore = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    // Selection/read-state changes remain memory-only. The disposable clone
    // also contains any load-time migration output, so the source corpus is
    // never a persistence target.
    realStore.aiChatTranscriptSaverForTesting = {}
    await realStore.waitForAIChatTranscriptLoadForTesting()
    XCTAssertFalse(realStore.aiChatThreads.isEmpty)
    realStore.setWorkspaceRealtimeRefreshActive(false)
    realStore.setCorpusRoot(root, persistsDefault: false)
    realStore.setWorkspaceRealtimeRefreshActive(false)
    realStore.selectedSurface = .files

    let refreshStartedAt = CACurrentMediaTime()
    await realStore.refreshCorpusFiles()
    XCTAssertFalse(realStore.corpusFiles.isEmpty)
    XCTAssertTrue(
      realStore.corpusFiles.allSatisfy { isPath($0.path, containedIn: root) },
      "The real performance catalog must never publish a path outside the disposable clone"
    )
    try await waitUntil(timeout: 30) {
      !realStore.isBuildingSearchIndex && !realStore.orgRoamLinkResolver.nodes.isEmpty
    }
    let realWorkspaceHarness = WorkspaceRenderPerformanceHarness(store: realStore)
    defer { realWorkspaceHarness.close() }
    try await realWorkspaceHarness.waitForVisibleDestination(.files, store: realStore)
    let refreshMilliseconds = (CACurrentMediaTime() - refreshStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "real-corpus-readonly-scan-and-publish",
      samples: [refreshMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let realActivationFile = try XCTUnwrap(realStore.corpusFiles.last)
    XCTAssertTrue(isPath(realActivationFile.path, containedIn: root))
    XCTAssertTrue(
      realStore.corpusFileWatcherRootPathsForTesting.contains(root.standardizedFileURL.path),
      "Real Cmd-Tab coverage requires the production corpus watcher to be active"
    )
    XCTAssertTrue(
      realStore.corpusFileWatcherRootPathsForTesting.allSatisfy {
        isPath($0, containedIn: root)
      },
      "The real performance watcher must never observe a path outside the disposable clone"
    )
    realStore.selectCorpusFile(realActivationFile)
    try await realWorkspaceHarness.waitForVisibleDestination(.files, store: realStore)
    try await waitUntil(timeout: 10) {
      realStore.selectedLocation?.file == realActivationFile.path
        && realStore.selectedEntrySource != nil
        && !realStore.isRenderingEntrySource
    }

    var realActivationSamples: [Double] = []
    var realPostActivationGapSamples: [Double] = []
    let realLifecycle = WorkspaceApplicationLifecycleDriver(store: realStore)
    for _ in 0..<20 {
      try await realLifecycle.deactivate(window: realWorkspaceHarness.window)
      let token = WorkspaceInteractionLatency.begin(.applicationActivationToDraw)
      try await realLifecycle.activate(window: realWorkspaceHarness.window)
      try await realWorkspaceHarness.waitForFirstUsableDestination(.files, store: realStore)
      realActivationSamples.append(WorkspaceInteractionLatency.finish(token))
      try await realWorkspaceHarness.waitForVisibleDestination(.files, store: realStore)

      let postActivationProbe = MainActorGapProbe()
      postActivationProbe.start()
      try await Task.sleep(nanoseconds: 550_000_000)
      realPostActivationGapSamples.append(await postActivationProbe.stop())
      try await realWorkspaceHarness.waitForVisibleDestination(.files, store: realStore)
    }
    realLifecycle.stop()
    try await waitUntil(timeout: 30) {
      self.corpusEventPipelineIsIdle(realStore)
    }
    try OpenOrgPerformanceResults.record(
      scenario: "real-application-activation-to-draw",
      samples: realActivationSamples,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-post-activation-main-actor-gap",
      samples: realPostActivationGapSamples,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    await realStore.refreshAgenda(updatesStatus: false)
    await realStore.refreshAgentRuns()
    await realStore.refreshApprovals()
    await realStore.refreshMeetings()
    await realStore.refreshSourceConnections()
    if realStore.agentRunEntries(for: .active).isEmpty {
      realStore.replaceAgentRunsForTesting(
        realStore.agentRuns + (try syntheticAgentRuns(count: 20))
      )
    }
    if realStore.approvalItems.isEmpty {
      realStore.replaceApprovalItemsForTesting(
        syntheticApprovalItems(runs: Array(realStore.agentRuns.prefix(20)))
      )
    }
    realStore.replaceExternalThreadsForTesting(
      syntheticExternalThreads(count: environment.shape.workspaceScale.externalThreadCount)
    )
    realStore.searchQuery = "TODO"
    await realStore.runSearch()
    XCTAssertFalse(realStore.agentRuns.isEmpty)
    XCTAssertFalse(realStore.approvalItems.isEmpty)
    XCTAssertFalse(realStore.meetings.isEmpty)
    XCTAssertFalse(realStore.sourceProfiles.isEmpty)
    XCTAssertGreaterThan(realStore.agenda?.totalItemCount ?? 0, 0)
    XCTAssertGreaterThan(realStore.workspaceTextSearchResultCount, 0)

    let navigationTargetCycle: [(WorkspaceSurface, RunsAndReviewPage?)] = [
      (.home, nil), (.files, nil), (.agenda, nil), (.approvals, .runs),
      (.approvals, .review), (.meetings, nil), (.sources, nil), (.externalThreads, nil),
      (.aiChat, nil), (.search, nil),
    ]
    try await recordWorkspaceNavigationGate(
      scenario: "real-workspace-navigation-to-draw",
      targetCycle: navigationTargetCycle,
      store: realStore,
      harness: realWorkspaceHarness,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    if realStore.selectedSurface != .aiChat {
      try realWorkspaceHarness.performNavigationAction(to: .aiChat)
    }
    try await realWorkspaceHarness.waitForVisibleDestination(.aiChat, store: realStore)
    // A legacy monolith is migrated inside the disposable clone before this
    // point. Select the largest settled metadata-only threads from the migrated
    // store itself so the real gate always measures distinct cold shard loads;
    // the synthetic gate above separately guarantees attachment rendering.
    let realThreadIDs = realStore.aiChatThreads
      .filter { thread in
        thread.isSettled
          && thread.storedMessageCount != nil
          && realStore.unloadedAIChatThreadIDsForTesting.contains(thread.id)
      }
      .sorted { left, right in
        let leftCount = left.storedMessageCount ?? 0
        let rightCount = right.storedMessageCount ?? 0
        if leftCount != rightCount { return leftCount > rightCount }
        return left.updatedAt > right.updatedAt
      }
      .prefix(20)
      .map(\.id)
    XCTAssertGreaterThanOrEqual(
      realThreadIDs.count,
      20,
      "The real-corpus gate requires 20 cold settled threads after clone-only migration"
    )
    if realThreadIDs.count >= 20 {
      var realThreadSwitchSamples: [Double] = []
      var realThreadSwitchSampleLabels: [String] = []
      for (index, targetID) in realThreadIDs.enumerated() {
        XCTAssertTrue(
          realStore.unloadedAIChatThreadIDsForTesting.contains(targetID),
          "Every measured real thread switch must begin with a cold migrated shard"
        )
        try await realWorkspaceHarness.prepareAIThreadRowAction(targetID)
        let token = WorkspaceInteractionLatency.begin(.threadSwitchToDraw)
        try realWorkspaceHarness.performAIThreadRowAction(targetID)
        try await waitForFirstUsableThreadRestoration(
          targetID: targetID,
          store: realStore,
          harness: realWorkspaceHarness,
          requiresVisibleAttachment: false
        )
        realThreadSwitchSamples.append(WorkspaceInteractionLatency.finish(token))
        try await waitForThreadRestoration(
          targetID: targetID,
          store: realStore,
          harness: realWorkspaceHarness,
          requiresVisibleAttachment: false
        )
        realThreadSwitchSampleLabels.append(
          index == 0 ? "largest-settled-thread" : "other-settled-thread"
        )
      }
      try OpenOrgPerformanceResults.record(
        scenario: "real-thread-switch-to-draw",
        samples: realThreadSwitchSamples,
        sampleLabels: realThreadSwitchSampleLabels,
        shapeVersion: environment.shape.version,
        budgets: environment.budgets
      )
    }

    let editableOrgFiles = realStore.corpusFiles.filter { file in
      ["org", "org2"].contains(
        URL(fileURLWithPath: file.path).pathExtension.lowercased()
      )
    }
    let largestFile = try XCTUnwrap(
      editableOrgFiles.max { ($0.byteCount ?? 0) < ($1.byteCount ?? 0) },
      "The real-corpus gate requires at least one editable Org or Org2 document"
    )
    XCTAssertTrue(
      isPath(largestFile.path, containedIn: root),
      "The writable performance editor target must be inside the disposable clone"
    )
    let realLargeDocumentURL = URL(fileURLWithPath: largestFile.path).standardizedFileURL
    try await prepareMeasuredCorpusFileRow(
      largestFile,
      store: realStore,
      harness: realWorkspaceHarness
    )
    let realEditorOpenStartedAt = CACurrentMediaTime()
    try realWorkspaceHarness.performCorpusFileRowAction(largestFile)
    try await waitUntil(timeout: 30) {
      realStore.selectedEntrySource?.file == largestFile.path
        && realStore.selectedEntrySource?.isEditable == true
        && !realStore.isLoadingEntrySource
    }
    let realLargeSource = try XCTUnwrap(realStore.selectedEntrySource)
    XCTAssertTrue(
      isPath(realLargeSource.file, containedIn: root),
      "The selected editor source must remain inside the disposable clone"
    )
    let realRestoredNearEOFLine = max(
      realLargeSource.startLine,
      realLargeSource.endLineExclusive - 2
    )
    realStore.recordDocumentViewportSourceLine(
      realRestoredNearEOFLine,
      for: realLargeSource
    )
    realStore.sourceEditorPresentation = .split
    realStore.beginEditingSelectedEntry()
    let realEditorHarness = WorkspaceEditorPerformanceHarness(
      workspace: realWorkspaceHarness,
      textView: try await realWorkspaceHarness.waitForFirstUsableSyntaxTextView(timeout: 15)
    )
    let realEditorOpenMilliseconds = (CACurrentMediaTime() - realEditorOpenStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-open-to-first-visible-frame",
      samples: [realEditorOpenMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    await realEditorHarness.drawAfterDeferredViewUpdates()
    let editorLength = (realEditorHarness.textView.string as NSString).length
    if realRestoredNearEOFLine > realLargeSource.startLine + 100 {
      XCTAssertGreaterThan(
        realStore.sourceEditorSelection.location,
        editorLength * 9 / 10,
        "Real large-editor open must restore a saved viewport near EOF"
      )
      XCTAssertTrue(realEditorHarness.isSelectionVisible)
    }
    XCTAssertEqual(realStore.sourceEditorPresentation, .split)
    XCTAssertLessThan(
      try XCTUnwrap(realEditorHarness.textView.enclosingScrollView).frame.width,
      realWorkspaceHarness.hostingView.bounds.width * 0.65,
      "The disposable real corpus must exercise the split editor with deep restoration"
    )
    let initialRealViewportSourceLine = realStore.currentDocumentViewportSourceLine
    await realEditorHarness.scrollCaretToVisible(at: editorLength / 2)
    XCTAssertTrue(realEditorHarness.isSelectionVisible)
    try await waitUntil(timeout: 5) {
      guard let publishedLine = realStore.currentDocumentViewportSourceLine else { return false }
      return publishedLine != initialRealViewportSourceLine && publishedLine > 1
    }

    WorkspaceInteractionLatency.resetRecordedSamples()
    let realPersistenceMarker = "qzxvjkrealmarker1234"
    XCTAssertEqual(realPersistenceMarker.count, 20)
    _ = try await typeMarker(
      realPersistenceMarker,
      editor: realEditorHarness,
      workspace: realWorkspaceHarness,
      waitsForLatencySamples: true
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-key-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .sourceEditorKeyToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let realEditorResignStartedAt = CACurrentMediaTime()
    realWorkspaceHarness.window.makeFirstResponder(nil)
    let realEditorResignMilliseconds = (CACurrentMediaTime() - realEditorResignStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-focus-resign",
      samples: [realEditorResignMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let realPostInputGapProbe = MainActorGapProbe()
    realPostInputGapProbe.start()
    try await waitForEditorSemanticAndGutterConvergence(
      editor: realEditorHarness,
      timeout: 15
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-post-input-main-actor-gap",
      samples: [await realPostInputGapProbe.stop()],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let realGutter = try XCTUnwrap(realEditorHarness.gutterView)
    try await waitUntil(timeout: 15) { realGutter.items.count > 20 }
    await realEditorHarness.drawAfterDeferredViewUpdates()
    XCTAssertLessThan(
      realGutter.lastDrawnItemCount,
      realGutter.items.count,
      "Real-corpus gutter drawing must stay bounded to visible headings"
    )

    let realEditorGestureSamples = try await exerciseLargeEditorGestures(
      editor: realEditorHarness,
      workspace: realWorkspaceHarness,
      store: realStore
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-window-resize-to-draw",
      samples: realEditorGestureSamples.resize,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-continuous-scroll-to-draw",
      samples: realEditorGestureSamples.scroll,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-post-scroll-main-actor-gap",
      samples: [realEditorGestureSamples.postScrollMainActorGap],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-gutter-action-to-draw",
      samples: realEditorGestureSamples.gutter,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-structural-command-to-draw",
      samples: realEditorGestureSamples.structural,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    WorkspaceInteractionLatency.resetRecordedSamples()
    let realCaretClickSampleCount = 10
    var realEditorCaretClickSamples: [Double] = []
    var realEditorDragSelectionSamples: [Double] = []
    var realEditorSelectionSamples: [Double] = []
    var realEditorSelectionSampleLabels: [String] = []
    for index in 1...realCaretClickSampleCount {
      let location = min(editorLength - 1, (editorLength * index) / realCaretClickSampleCount)
      await realEditorHarness.scrollGlyphToVisible(at: location)
      let setupLocation = location >= 4 ? location - 4 : min(editorLength - 1, location + 4)
      realEditorHarness.textView.setSelectedRange(NSRange(location: setupLocation, length: 0))
      await realEditorHarness.drawAfterDeferredViewUpdates()

      let clickStartedAt = CACurrentMediaTime()
      let clickedLocation = try realEditorHarness.performHitTestedCaretClick(at: location)
      await realWorkspaceHarness.drawFirstUsableFrame()
      let clickMilliseconds = (CACurrentMediaTime() - clickStartedAt) * 1_000
      realEditorCaretClickSamples.append(clickMilliseconds)
      realEditorSelectionSamples.append(clickMilliseconds)
      realEditorSelectionSampleLabels.append("caret-click")
      try await waitUntil(timeout: 1) {
        WorkspaceInteractionLatency.snapshot(for: .sourceEditorPointerToDraw).sampleCount
          >= index
      }
      XCTAssertNotEqual(clickedLocation, setupLocation)
      XCTAssertTrue(realEditorHarness.isSelectionVisible)
      try await waitUntil(timeout: 1) {
        realStore.sourceEditorSelection.location == clickedLocation
          && realStore.sourceEditorSelection.length == 0
      }
      await realEditorHarness.drawAfterDeferredViewUpdates()
    }
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-caret-click-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .sourceEditorPointerToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    WorkspaceInteractionLatency.resetRecordedSamples()
    for index in 1...10 {
      let location = min(editorLength - 1, (editorLength * index) / 10)
      await realEditorHarness.scrollCaretToVisible(at: location)
      let dragStartedAt = CACurrentMediaTime()
      try realEditorHarness.performHitTestedDragSelection(at: location)
      await realWorkspaceHarness.drawFirstUsableFrame()
      let dragMilliseconds = (CACurrentMediaTime() - dragStartedAt) * 1_000
      realEditorDragSelectionSamples.append(dragMilliseconds)
      realEditorSelectionSamples.append(dragMilliseconds)
      realEditorSelectionSampleLabels.append("drag-selection")
      XCTAssertTrue(realEditorHarness.isSelectionVisible)
      try await waitUntil(timeout: 1) {
        WorkspaceInteractionLatency.snapshot(for: .sourceEditorDragToDraw).sampleCount
          >= index
      }
      await realEditorHarness.drawAfterDeferredViewUpdates()
    }
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-drag-selection-to-draw",
      snapshot: WorkspaceInteractionLatency.snapshot(for: .sourceEditorDragToDraw),
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    XCTAssertEqual(realEditorCaretClickSamples.count, realCaretClickSampleCount)
    XCTAssertEqual(realEditorDragSelectionSamples.count, 10)
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-selection-to-draw",
      samples: realEditorSelectionSamples,
      sampleLabels: realEditorSelectionSampleLabels,
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let realExplicitSaveMilliseconds = try await explicitlySaveLargeEditor(
      store: realStore,
      editor: realEditorHarness,
      workspace: realWorkspaceHarness,
      documentURL: realLargeDocumentURL,
      requiredMarkers: [realPersistenceMarker]
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-explicit-save-persistence",
      samples: [realExplicitSaveMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let realMenuSaveMarker = "qzxvjkrealmenu890123"
    let realMenuSaveMilliseconds = try await menuSaveLargeEditorBeforeDeferredPublication(
      marker: realMenuSaveMarker,
      store: realStore,
      editor: realEditorHarness,
      workspace: realWorkspaceHarness,
      documentURL: realLargeDocumentURL
    )
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-menu-save-persistence",
      samples: [realMenuSaveMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )

    let realDirtyNavigationMarker = "qzxvjkrealroute567"
    await realEditorHarness.scrollCaretToVisible(at: max(0, realEditorHarness.textLength - 1))
    _ = try await typeMarker(
      realDirtyNavigationMarker,
      editor: realEditorHarness,
      workspace: realWorkspaceHarness,
      waitsForLatencySamples: false
    )

    let nextRealFile = try XCTUnwrap(realStore.corpusFiles.first { $0.path != largestFile.path })
    try await prepareCorpusFileRow(
      nextRealFile,
      store: realStore,
      harness: realWorkspaceHarness
    )
    let realPersistenceStartedAt = CACurrentMediaTime()
    try realWorkspaceHarness.performCorpusFileRowAction(nextRealFile)
    try await waitForFirstUsableRenderedCorpusFileDestination(
      nextRealFile,
      store: realStore,
      harness: realWorkspaceHarness
    )
    let realDirtyNavigationMilliseconds = (CACurrentMediaTime() - realPersistenceStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-dirty-navigation-to-draw",
      samples: [realDirtyNavigationMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    try await waitForRenderedCorpusFileDestination(
      nextRealFile,
      store: realStore,
      harness: realWorkspaceHarness
    )
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    let didDrainRealEditorPersistence = await realStore.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(
      didDrainRealEditorPersistence,
      "The disposable real-corpus clone must drain the production editor persistence lane"
    )
    let realPersistenceMilliseconds = (CACurrentMediaTime() - realPersistenceStartedAt) * 1_000
    try OpenOrgPerformanceResults.record(
      scenario: "real-large-editor-draft-persistence",
      samples: [realPersistenceMilliseconds],
      shapeVersion: environment.shape.version,
      budgets: environment.budgets
    )
    let persistedRealLargeDocument = try await Task.detached(priority: .utility) {
      try String(contentsOf: realLargeDocumentURL, encoding: .utf8)
    }.value
    XCTAssertTrue(
      persistedRealLargeDocument.contains(realPersistenceMarker)
        && persistedRealLargeDocument.contains(realMenuSaveMarker)
        && persistedRealLargeDocument.contains(realDirtyNavigationMarker),
      "Only the disposable real-corpus clone should contain the measured editor draft"
    )

    realStore.setWorkspaceRealtimeRefreshActive(false)
  }

  private func measureWorkspaceNavigation(
    to surface: WorkspaceSurface,
    runPage: RunsAndReviewPage?,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness
  ) async throws -> WorkspaceNavigationMeasurement {
    let token = WorkspaceInteractionLatency.begin(.workspaceNavigationToDraw)
    let sampleStartedAt = CACurrentMediaTime()
    if store.selectedSurface != surface {
      try harness.performNavigationAction(to: surface)
    }
    let surfaceActionFinishedAt = CACurrentMediaTime()
    if let runPage, store.runsAndReviewPage != runPage {
      try await harness.performRunsAndReviewPageAction(runPage, store: store)
    }
    let pageActionFinishedAt = CACurrentMediaTime()
    try await harness.waitForFirstUsableDestination(
      surface,
      runPage: runPage,
      store: store
    )
    let sample = WorkspaceInteractionLatency.finish(token)
    let firstFrameFinishedAt = CACurrentMediaTime()
    try await harness.waitForVisibleDestination(
      surface,
      runPage: runPage,
      store: store
    )
    let stabilityFinishedAt = CACurrentMediaTime()
    return WorkspaceNavigationMeasurement(
      elapsedMilliseconds: sample,
      surfaceActionMilliseconds: (surfaceActionFinishedAt - sampleStartedAt) * 1_000,
      pageActionMilliseconds: (pageActionFinishedAt - surfaceActionFinishedAt) * 1_000,
      firstFrameMilliseconds: (firstFrameFinishedAt - pageActionFinishedAt) * 1_000,
      stabilityMilliseconds: (stabilityFinishedAt - firstFrameFinishedAt) * 1_000
    )
  }

  private func recordWorkspaceNavigationGate(
    scenario: String,
    targetCycle: [(WorkspaceSurface, RunsAndReviewPage?)],
    warmCycleCount: Int = 20,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness,
    shapeVersion: Int,
    budgets: OpenOrgPerformanceBudgets
  ) async throws {
    guard warmCycleCount >= 20 else {
      XCTFail("Navigation p95 requires at least 20 warm observations per target")
      return
    }
    guard !targetCycle.isEmpty else {
      XCTFail("Navigation performance coverage requires at least one target")
      return
    }
    let budget = try XCTUnwrap(
      budgets.scenarios[scenario],
      "Missing performance budget for \(scenario)"
    )
    let traceNavigation = ProcessInfo.processInfo.environment["OPENORG_PERFORMANCE_TRACE_NAV"] == "1"

    // A fresh traversal retains one cold observation per destination, but cold
    // initialization is governed only by the scenario's maximum. Mixing these
    // one-off samples into a small p95 population made p95 identical to max.
    WorkspaceInteractionLatency.resetRecordedSamples()
    for (surface, runPage) in targetCycle {
      let measurement = try await measureWorkspaceNavigation(
        to: surface,
        runPage: runPage,
        store: store,
        harness: harness
      )
      let label = "\(surface.rawValue):\(runPage?.rawValue.lowercased() ?? "default")"
      let targetBudget = budget.threshold(for: label)
      XCTAssertLessThanOrEqual(
        measurement.elapsedMilliseconds,
        targetBudget.maximumMilliseconds,
        "\(scenario) cold target \(label) max \(String(format: "%.1f", measurement.elapsedMilliseconds)) ms exceeded \(String(format: "%.1f", targetBudget.maximumMilliseconds)) ms"
      )
      try assertLazyCollectionStructure(
        whenRequiredFor: surface,
        runPage: runPage,
        harness: harness
      )
      if traceNavigation {
        printNavigationMeasurement(
          measurement,
          phase: "cold",
          surface: surface,
          runPage: runPage
        )
      }
    }

    // Twenty observations per destination make nearest-rank p95 the nineteenth
    // sample instead of the maximum. Each destination therefore keeps its own
    // meaningful p95 and a separate hard maximum budget.
    WorkspaceInteractionLatency.resetRecordedSamples()
    var samples: [Double] = []
    var labels: [String] = []
    samples.reserveCapacity(targetCycle.count * warmCycleCount)
    labels.reserveCapacity(targetCycle.count * warmCycleCount)
    for _ in 0..<warmCycleCount {
      for (surface, runPage) in targetCycle {
        let measurement = try await measureWorkspaceNavigation(
          to: surface,
          runPage: runPage,
          store: store,
          harness: harness
        )
        samples.append(measurement.elapsedMilliseconds)
        labels.append("\(surface.rawValue):\(runPage?.rawValue.lowercased() ?? "default")")
        try assertLazyCollectionStructure(
          whenRequiredFor: surface,
          runPage: runPage,
          harness: harness
        )
        if traceNavigation {
          printNavigationMeasurement(
            measurement,
            phase: "warm",
            surface: surface,
            runPage: runPage
          )
        }
      }
    }

    let countsByLabel = labels.reduce(into: [String: Int]()) { counts, label in
      counts[label, default: 0] += 1
    }
    XCTAssertEqual(Set(countsByLabel.values), Set([warmCycleCount]))
    XCTAssertEqual(countsByLabel.count, targetCycle.count)
    try OpenOrgPerformanceResults.record(
      scenario: scenario,
      samples: samples,
      sampleLabels: labels,
      shapeVersion: shapeVersion,
      budgets: budgets
    )
  }

  private func printNavigationMeasurement(
    _ measurement: WorkspaceNavigationMeasurement,
    phase: String,
    surface: WorkspaceSurface,
    runPage: RunsAndReviewPage?
  ) {
    print(
      "PERFORMANCE-NAV phase=\(phase) surface=\(surface.rawValue) page=\(runPage?.rawValue ?? "none") "
        + "surface-action=\(String(format: "%.1f", measurement.surfaceActionMilliseconds))ms "
        + "page-action=\(String(format: "%.1f", measurement.pageActionMilliseconds))ms "
        + "first-frame=\(String(format: "%.1f", measurement.firstFrameMilliseconds))ms "
        + "stability=\(String(format: "%.1f", measurement.stabilityMilliseconds))ms "
        + "total-to-first-frame=\(String(format: "%.1f", measurement.elapsedMilliseconds))ms"
    )
  }

  private func assertLazyCollectionStructure(
    whenRequiredFor surface: WorkspaceSurface,
    runPage: RunsAndReviewPage?,
    harness: WorkspaceRenderPerformanceHarness,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let requiresLazyCollection = surface == .agenda
      || surface == .meetings
      || surface == .externalThreads
      || surface == .search
      || (surface == .approvals && [.runs, .review].contains(runPage))
    guard requiresLazyCollection else { return }
    let structure = try XCTUnwrap(
      harness.activeCollectionStructure(for: surface),
      "The visible \(surface.rawValue) host must be inspectable",
      file: file,
      line: line
    )
    XCTAssertGreaterThan(
      structure.scrollViewCount,
      0,
      "\(surface.rawValue) must render its populated collection in an NSScrollView",
      file: file,
      line: line
    )
    XCTAssertEqual(
      structure.tableViewCount,
      0,
      "\(surface.rawValue) must not mount an automatic-row-height NSTableView",
      file: file,
      line: line
    )
  }

  private func verifyRepresentativeLazyCollectionActions(
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness
  ) async throws {
    if store.selectedSurface != .agenda {
      try harness.performNavigationAction(to: .agenda)
    }
    try await harness.waitForVisibleDestination(.agenda, store: store)
    let agendaItems = store.agendaDisplaySections.flatMap(\.items)
    let agendaTarget = try XCTUnwrap(
      agendaItems.prefix(8).first { $0.id != store.selectedAgendaItemID }
        ?? agendaItems.first,
      "The populated performance agenda must expose a representative row"
    )
    try harness.performCollectionRowAction(kind: "agenda", id: agendaTarget.id)
    try await waitUntil(timeout: 3) {
      store.selectedAgendaItemID == agendaTarget.id
    }
    await harness.drawAfterDeferredViewUpdates()
    XCTAssertEqual(
      harness.collectionRowAccessibilitySelection(kind: "agenda", id: agendaTarget.id),
      true,
      "The real native agenda-row press must update visible selection state"
    )

    if store.selectedSurface != .approvals {
      try harness.performNavigationAction(to: .approvals)
    }
    if store.runsAndReviewPage != .review {
      try await harness.performRunsAndReviewPageAction(.review, store: store)
    }
    try await harness.waitForVisibleDestination(.approvals, runPage: .review, store: store)
    let approvalTarget = try XCTUnwrap(
      store.visibleApprovalItems.prefix(4).first {
        $0.id != store.selectedApprovalItemID
      } ?? store.visibleApprovalItems.first,
      "The populated performance approvals page must expose a representative row"
    )
    try harness.performCollectionRowAction(kind: "approval", id: approvalTarget.id)
    try await waitUntil(timeout: 3) {
      store.selectedApprovalItemID == approvalTarget.id
        && store.isApprovalItemSelectedForAIContext(approvalTarget)
    }
    await harness.drawAfterDeferredViewUpdates()
    XCTAssertEqual(
      harness.collectionRowAccessibilitySelection(kind: "approval", id: approvalTarget.id),
      true,
      "The real native approval-row press must preserve AI-context selection semantics"
    )

    if store.selectedSurface != .meetings {
      try harness.performNavigationAction(to: .meetings)
    }
    try await harness.waitForVisibleDestination(.meetings, store: store)
    let meetingTarget = try XCTUnwrap(
      store.meetingDisplaySections.lazy.flatMap(\.meetings).prefix(8).first {
        $0.id != store.selectedMeetingID
      } ?? store.meetings.first,
      "The populated performance meetings page must expose a representative row"
    )
    try harness.performCollectionRowAction(kind: "meeting", id: meetingTarget.id)
    try await waitUntil(timeout: 3) {
      store.selectedMeetingID == meetingTarget.id
    }
    await harness.drawAfterDeferredViewUpdates()
    XCTAssertEqual(
      harness.collectionRowAccessibilitySelection(kind: "meeting", id: meetingTarget.id),
      true,
      "The real native meeting-row press must update visible selection state"
    )
  }

  private func syntheticAgentRuns(count: Int) throws -> [AgentRunItem] {
    let objects: [[String: Any]] = (0..<count).map { index in
      [
        "schema": "org2:agent-run:v1",
        "id": "performance-run-\(index)",
        "goal": "Synthetic performance outcome \(index)",
        "acceptanceCriteria": [],
        "status": index < 250
          ? "running"
          : index < 750
            ? "waiting-approval"
            : "completed",
        "riskClass": "local-draft",
        "agentRef": "performance-agent-\(index % 12)",
        "goalRef": "performance-goal-\(index % 20)",
        "capabilities": [],
        "context": [],
        "plan": [],
        "artifacts": [],
        "approvals": [],
        "validations": [],
        "comments": [],
        "events": [],
        "createdAt": "2026-07-28T00:00:00.000Z",
        "updatedAt": "2026-07-28T00:01:00.000Z",
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: objects)
    return try JSONDecoder().decode([AgentRunItem].self, from: data)
  }

  private func syntheticApprovalItems(runs: [AgentRunItem]) -> [ApprovalItem] {
    runs.enumerated().map { index, run in
      ApprovalItem(
        title: "Review synthetic operation \(index)",
        status: "pending",
        todo: "TODO",
        level: 2,
        file: "performance-run-\(index).org2",
        line: index + 1,
        idValue: "performance-approval-node-\(index)",
        properties: ["OWNER": "performance-agent-\(index % 12)"],
        body: "Synthetic review payload used only by the generated performance corpus.",
        tags: ["review"],
        kind: "run",
        approvalId: "performance-approval-\(index)",
        fingerprint: "performance-fingerprint-\(index)",
        action: "Review generated operation \(index)",
        riskClass: "local-draft",
        requestedRole: "reviewer",
        requestedFrom: "performance-gate",
        requestedAt: "2026-07-28T00:00:30.000Z",
        runId: run.id,
        runGoal: run.goal,
        runStatus: run.status,
        runPendingApprovalCount: 1,
        runApprovalCount: 1
      )
    }
  }

  private func syntheticExternalThreads(count: Int) -> [ExternalThreadSummary] {
    (0..<count).map { index in
      ExternalThreadSummary(
        harness: .codex,
        externalID: "performance-thread-\(index)",
        title: "Synthetic external thread \(index)",
        preview: "Generated transcript summary for navigation performance.",
        workspacePath: "/private/tmp/openorg-performance",
        source: "codex",
        modelProvider: "openai",
        createdAt: Date(timeIntervalSince1970: 1_776_556_800 + Double(index)),
        updatedAt: Date(timeIntervalSince1970: 1_776_556_800 + Double(index)),
        status: index.isMultiple(of: 5) ? "completed" : "active",
        isPinned: index < 12
      )
    }
  }

  private func prepareMeasuredCorpusFileRow(
    _ file: CorpusFile,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness
  ) async throws {
    if store.selectedSurface != .files {
      try harness.performNavigationAction(to: .files)
    }
    try await harness.waitForVisibleDestination(.files, store: store)

    // A row press must produce an observable file transition. If activation
    // already selected the largest file, move away through another real row
    // before setting up the measured target.
    if store.selectedLocation?.file == file.path {
      let alternate = try XCTUnwrap(store.corpusFiles.first { candidate in
        candidate.id != file.id
          && ["org", "org2"].contains(
            URL(fileURLWithPath: candidate.path).pathExtension.lowercased()
          )
      })
      try await prepareCorpusFileRow(alternate, store: store, harness: harness)
      try harness.performCorpusFileRowAction(alternate)
      try await waitUntil(timeout: 10) {
        store.selectedLocation?.file == alternate.path
          && store.selectedEntrySource?.file == alternate.path
          && !store.isLoadingEntrySource
      }
    }

    try await prepareCorpusFileRow(file, store: store, harness: harness)
  }

  private func prepareCorpusFileRow(
    _ file: CorpusFile,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness
  ) async throws {
    store.corpusFileFilter = file.relativePath
    await store.waitForCorpusFilePublicationForTesting()
    try await waitUntil(timeout: 5) {
      store.filteredCorpusFiles.first?.id == file.id
    }
    await harness.drawAfterDeferredViewUpdates()
  }

  private func waitForRenderedCorpusFileDestination(
    _ file: CorpusFile,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness,
    timeout: TimeInterval = 20
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    var stableFrameCount = 0
    while CACurrentMediaTime() < deadline {
      await harness.drawAfterDeferredViewUpdates()
      if store.selectedSurface == .files,
         store.selectedLocation?.file == file.path,
         store.selectedEntrySource?.file == file.path,
         !store.isLoadingEntrySource,
         !store.isRenderingEntrySource {
        stableFrameCount += 1
        if stableFrameCount >= 2 { return }
      } else {
        stableFrameCount = 0
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw PerformanceHarnessError.destinationEvidenceMissing(
      "the selected corpus file did not publish a stable loaded and rendered destination"
    )
  }

  private func waitForFirstUsableRenderedCorpusFileDestination(
    _ file: CorpusFile,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness,
    timeout: TimeInterval = 20
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      await harness.drawFirstUsableFrame()
      if store.selectedSurface == .files,
         store.selectedLocation?.file == file.path,
         store.selectedEntrySource?.file == file.path,
         !store.isLoadingEntrySource,
         !store.isRenderingEntrySource {
        return
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw PerformanceHarnessError.destinationEvidenceMissing(
      "the selected corpus file did not publish its first loaded and rendered frame"
    )
  }

  private func waitForFirstUsableThreadRestoration(
    targetID: UUID,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness,
    requiresVisibleAttachment: Bool,
    timeout: TimeInterval = 6
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      await harness.drawFirstUsableFrame()
      let isSelected = store.selectedAIChatThreadID == targetID
      let visibleMessages = isSelected
        ? Array(store.aiChatMessages.suffix(AIChatTranscriptWindow.initialLimit))
        : []
      let hasRequiredAttachment = !requiresVisibleAttachment
        || visibleMessages.contains(where: { !$0.attachments.isEmpty })
      if isSelected,
         !store.unloadedAIChatThreadIDsForTesting.contains(targetID),
         hasRequiredAttachment,
         store.lastCompletedAIChatScrollRestorationThreadID == targetID {
        return
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for the first usable hydrated thread frame")
    throw PerformanceHarnessError.timedOut
  }

  private func waitForThreadRestoration(
    targetID: UUID,
    store: WorkspaceStore,
    harness: WorkspaceRenderPerformanceHarness,
    requiresVisibleAttachment: Bool
  ) async throws {
    let deadline = CACurrentMediaTime() + 6
    var previousGeometry: OpenOrgScrollGeometry?
    var lastGeometry: OpenOrgScrollGeometry?
    var lastHadHydratedThread = false
    var lastHadRequiredAttachment = false
    var stableGeometryCount = 0
    while CACurrentMediaTime() < deadline {
      await harness.drawAfterDeferredViewUpdates()
      let hydratedThread = store.aiChatThreads.first { thread in
        thread.id == targetID && thread.storedMessageCount == nil
      }
      let visibleMessages = hydratedThread?.messages
        .suffix(AIChatTranscriptWindow.initialLimit) ?? []
      let hasRequiredAttachment = !requiresVisibleAttachment
        || visibleMessages.contains(where: { !$0.attachments.isEmpty })
      lastHadHydratedThread = hydratedThread != nil
      lastHadRequiredAttachment = hasRequiredAttachment
      lastGeometry = await harness.primaryTranscriptScrollGeometry()
      if store.selectedAIChatThreadID == targetID,
         hydratedThread != nil,
         hasRequiredAttachment,
         let geometry = lastGeometry,
         geometry.isAtBottom {
        if let previousGeometry,
           geometry.isApproximatelyEqual(to: previousGeometry) {
          stableGeometryCount += 1
        } else {
          stableGeometryCount = 1
        }
        previousGeometry = geometry
        if stableGeometryCount >= 3 {
          return
        }
      } else {
        previousGeometry = nil
        stableGeometryCount = 0
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let geometryDescription = lastGeometry.map {
      "height=\($0.documentHeight), viewport=\($0.viewportHeight), originY=\($0.originY), flipped=\($0.isFlipped), atBottom=\($0.isAtBottom)"
    } ?? "nil"
    XCTFail(
      "Timed out waiting for thread hydration, bottom restoration, and a stable visible frame; "
        + "selected=\(store.selectedAIChatThreadID?.uuidString ?? "nil"), "
        + "hydrated=\(lastHadHydratedThread), attachment=\(lastHadRequiredAttachment), "
        + "stableFrames=\(stableGeometryCount), geometry=\(geometryDescription)"
    )
    throw PerformanceHarnessError.timedOut
  }

  private func corpusEventPipelineIsIdle(_ store: WorkspaceStore) -> Bool {
    let state = store.corpusEventPipelineStateForTesting
    return state.pendingChangedPathCount == 0
      && state.activeSourceSyncEventBatchCount == 0
      && !state.needsFullRefresh
      && !state.hasRefreshTask
  }

  private func reflectedValue(named name: String, in value: Any) -> Any? {
    var mirror: Mirror? = Mirror(reflecting: value)
    while let current = mirror {
      if let child = current.children.first(where: { $0.label == name }) {
        return child.value
      }
      mirror = current.superclassMirror
    }
    return nil
  }

  private func unwrappedOptionalValue(_ value: Any?) -> Any? {
    guard let value else { return nil }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else { return value }
    return mirror.children.first?.value
  }

  private func waitForEditorSemanticAndGutterConvergence(
    editor: WorkspaceEditorPerformanceHarness,
    timeout: TimeInterval
  ) async throws {
    let coordinator = try XCTUnwrap(
      editor.textView.textStorage?.delegate as? OrgSyntaxTextEditor.Coordinator,
      "The mounted production text storage must retain its editor coordinator"
    )
    let gutter = try XCTUnwrap(editor.gutterView)
    let deadline = CACurrentMediaTime() + timeout
    var previousSignature: [Int]?
    var stableFrameCount = 0

    while CACurrentMediaTime() < deadline {
      let localGeneration = reflectedValue(
        named: "localTextGeneration",
        in: coordinator
      ) as? Int
      let semanticGeneration = unwrappedOptionalValue(reflectedValue(
        named: "semanticSnapshotTextGeneration",
        in: coordinator
      )) as? Int
      let lineIndexIsReady = reflectedValue(
        named: "isLineIndexReady",
        in: coordinator
      ) as? Bool
      let signature = [
        gutter.items.count,
        gutter.items.first?.line ?? -1,
        gutter.items.last?.line ?? -1,
      ]
      if let localGeneration,
         let semanticGeneration,
         localGeneration == semanticGeneration,
         lineIndexIsReady == true,
         gutter.items.count > 20 {
        await editor.drawAfterDeferredViewUpdates()
        stableFrameCount = signature == previousSignature ? stableFrameCount + 1 : 1
        previousSignature = signature
        if stableFrameCount >= 3 { return }
      } else {
        previousSignature = nil
        stableFrameCount = 0
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTFail(
      "Timed out waiting for the latest large-editor semantics, line index, and gutter to converge"
    )
    throw PerformanceHarnessError.timedOut
  }

  private func typeMarker(
    _ marker: String,
    editor: WorkspaceEditorPerformanceHarness,
    workspace: WorkspaceRenderPerformanceHarness,
    waitsForLatencySamples: Bool
  ) async throws -> NSRange {
    let insertionLocation = editor.textView.selectedRange().location
    let initialLength = editor.textLength
    let markerLength = (marker as NSString).length
    XCTAssertNotEqual(insertionLocation, NSNotFound)
    XCTAssertEqual(editor.textView.selectedRange().length, 0)
    for (index, character) in marker.enumerated() {
      editor.textView.keyDown(with: try keyDownEvent(
        character: character,
        windowNumber: workspace.window.windowNumber
      ))
      await editor.drawAfterDeferredViewUpdates()
      if waitsForLatencySamples {
        try await waitUntil(timeout: 1) {
          WorkspaceInteractionLatency.snapshot(for: .sourceEditorKeyToDraw).sampleCount >= index + 1
        }
      }
    }
    let insertedRange = NSRange(location: insertionLocation, length: markerLength)
    XCTAssertEqual(editor.textLength, initialLength + markerLength)
    XCTAssertEqual(
      try editor.text(in: insertedRange),
      marker,
      "The mounted editor must apply every synthesized key event at the visible caret"
    )
    return insertedRange
  }

  private func menuSaveLargeEditorBeforeDeferredPublication(
    marker: String,
    store: WorkspaceStore,
    editor: WorkspaceEditorPerformanceHarness,
    workspace: WorkspaceRenderPerformanceHarness,
    documentURL: URL
  ) async throws -> Double {
    let originalFormatOnSave = store.formatOrgFilesOnSave
    store.formatOrgFilesOnSave = false
    defer { store.formatOrgFilesOnSave = originalFormatOnSave }
    await editor.drawAfterDeferredViewUpdates()
    workspace.window.makeFirstResponder(editor.textView)
    let insertionLocation = editor.textLength
    let initialLength = editor.textLength
    let initiallyPublishedText = store.sourceEditorInteraction.text
    XCTAssertEqual((initiallyPublishedText as NSString).length, initialLength)
    XCTAssertFalse(initiallyPublishedText.hasSuffix(marker))
    editor.textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
    editor.textView.insertText(
      marker,
      replacementRange: editor.textView.selectedRange()
    )
    XCTAssertEqual(
      try editor.text(in: NSRange(
        location: insertionLocation,
        length: (marker as NSString).length
      )),
      marker
    )
    XCTAssertFalse(store.sourceEditorInteraction.text.hasSuffix(marker))

    // Do not wait for the editor's 500 ms publication timer. This is the same
    // async path invoked by the application menu, and it must first checkpoint
    // the exact native buffer before it inspects the owner's dirty generation.
    let startedAt = CACurrentMediaTime()
    await store.saveActiveEdit()
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    let didDrainPersistence = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(didDrainPersistence)
    try await waitUntil(timeout: 30) {
      !store.isSavingEntry && !store.entryEditorHasUnsavedChanges
    }
    let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
    await editor.drawAfterDeferredViewUpdates()

    let persistedDocument = try await Task.detached(priority: .utility) {
      try String(contentsOf: documentURL, encoding: .utf8)
    }.value
    XCTAssertTrue(
      persistedDocument.hasSuffix(marker),
      "The app-menu Save path must persist native text before deferred publication fires"
    )
    XCTAssertEqual(
      (persistedDocument as NSString).length,
      initialLength + (marker as NSString).length,
      "Menu Save must persist the exact complete native buffer, not only its final marker"
    )
    XCTAssertTrue(store.sourceEditorInteraction.text.hasSuffix(marker))
    return elapsedMilliseconds
  }

  private func exerciseDirtyExternalReloadConflict(
    store: WorkspaceStore,
    workspace: WorkspaceRenderPerformanceHarness,
    file: CorpusFile,
    documentURL: URL
  ) async throws -> Double {
    store.selectCorpusFile(file)
    try await workspace.waitForVisibleDestination(.files, store: store)
    try await waitUntil(timeout: 20) {
      store.selectedEntrySource?.file == file.path
        && store.selectedEntrySource?.isEditable == true
        && !store.isLoadingEntrySource
    }
    store.sourceEditorPresentation = .split
    store.beginEditingSelectedEntry()
    let editor = WorkspaceEditorPerformanceHarness(
      workspace: workspace,
      textView: try await workspace.waitForSyntaxTextView(timeout: 10)
    )
    await editor.drawAfterDeferredViewUpdates()
    XCTAssertGreaterThanOrEqual(
      editor.textLength,
      5_800_000,
      "External reload coverage must use the adversarial 5.8 MB source, not a reduced fixture"
    )

    let baseline = try await Task.detached(priority: .utility) {
      try String(contentsOf: documentURL, encoding: .utf8)
    }.value
    XCTAssertEqual((baseline as NSString).length, editor.textLength)

    let localMarker = "qzxvjkdirtyreload345"
    workspace.window.makeFirstResponder(editor.textView)
    editor.textView.setSelectedRange(NSRange(location: editor.textLength, length: 0))
    editor.textView.insertText(
      localMarker,
      replacementRange: editor.textView.selectedRange()
    )
    XCTAssertFalse(
      store.sourceEditorInteraction.text.hasSuffix(localMarker),
      "The reload race must begin while the 500 ms native publication is still pending"
    )
    let expectedRecoveredDraft = await Task.detached(priority: .utility) {
      baseline + localMarker
    }.value
    XCTAssertEqual(editor.textLength, (expectedRecoveredDraft as NSString).length)

    let externalMarker = "\n* QZXVJK_EXTERNAL_AUTHORITATIVE_RELOAD\n"
    let authoritativeDiskText = await Task.detached(priority: .utility) {
      baseline + externalMarker
    }.value
    try await Task.detached(priority: .utility) {
      try authoritativeDiskText.write(to: documentURL, atomically: true, encoding: .utf8)
    }.value

    let gapProbe = MainActorGapProbe()
    gapProbe.start()
    await store.reloadSelectedEntrySource()
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    _ = await store.waitForPendingEditorPersistenceForTesting()
    await editor.drawAfterDeferredViewUpdates()
    let maximumMainActorGap = await gapProbe.stop()

    let conflict = try XCTUnwrap(
      store.editorSaveConflict,
      "A dirty native checkpoint must surface a recoverable conflict after an external disk edit"
    )
    XCTAssertEqual(
      URL(fileURLWithPath: conflict.file).standardizedFileURL,
      documentURL.standardizedFileURL
    )
    XCTAssertFalse(conflict.canOverwrite)
    let recoveredDraft = try XCTUnwrap(
      store.failedEditorPersistenceDraftForTesting(file: documentURL.path),
      "The exact outgoing 5.8 MB native draft must remain available for recovery"
    )
    let recoveredDraftIsExact = await Task.detached(priority: .utility) {
      recoveredDraft == expectedRecoveredDraft
    }.value
    XCTAssertTrue(
      recoveredDraftIsExact,
      "Reload must checkpoint the exact native buffer before observing authoritative disk state"
    )
    let diskAfterConflict = try await Task.detached(priority: .utility) {
      try String(contentsOf: documentURL, encoding: .utf8)
    }.value
    let authoritativeDiskWasPreserved = await Task.detached(priority: .utility) {
      diskAfterConflict == authoritativeDiskText
    }.value
    XCTAssertTrue(
      authoritativeDiskWasPreserved,
      "The failed checkpoint must never overwrite the external authoritative document"
    )
    XCTAssertTrue(store.isEditingEntry, "A conflicted reload must abort without discarding the editor")
    return maximumMainActorGap
  }

  private func exerciseLargeEditorGestures(
    editor: WorkspaceEditorPerformanceHarness,
    workspace: WorkspaceRenderPerformanceHarness,
    store: WorkspaceStore
  ) async throws -> (
    resize: [Double],
    scroll: [Double],
    postScrollMainActorGap: Double,
    gutter: [Double],
    structural: [Double]
  ) {
    var resizeSamples: [Double] = []
    workspace.hostingView.viewWillStartLiveResize()
    for index in 0..<60 {
      let phase = Double(index) / 59.0
      let width = 780 + CGFloat((sin(phase * .pi * 4) + 1) * 360)
      let height = 620 + CGFloat((cos(phase * .pi * 3) + 1) * 120)
      let startedAt = CACurrentMediaTime()
      workspace.resize(width: width, height: height)
      await workspace.drawFirstUsableFrame()
      resizeSamples.append((CACurrentMediaTime() - startedAt) * 1_000)
    }
    workspace.hostingView.viewDidEndLiveResize()
    await editor.drawAfterDeferredViewUpdates()
    XCTAssertTrue(editor.textView.window === workspace.window)

    _ = try editor.scrollDocument(to: 0)
    await editor.drawAfterDeferredViewUpdates()
    let initialScrollY = editor.textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
    var scrollSamples: [Double] = []
    var finalScrollY = initialScrollY
    for index in 1..<60 {
      let startedAt = CACurrentMediaTime()
      finalScrollY = try editor.scrollDocument(to: Double(index) / 60.0)
      await workspace.drawFirstUsableFrame()
      scrollSamples.append((CACurrentMediaTime() - startedAt) * 1_000)
    }

    let postScrollGapProbe = MainActorGapProbe()
    postScrollGapProbe.start()
    let finalScrollStartedAt = CACurrentMediaTime()
    finalScrollY = try editor.scrollDocument(to: 1)
    await workspace.drawFirstUsableFrame()
    scrollSamples.append((CACurrentMediaTime() - finalScrollStartedAt) * 1_000)
    XCTAssertGreaterThan(
      finalScrollY,
      initialScrollY + 1_000,
      "The continuous-scroll gate must reach deep into the multi-megabyte document"
    )

    // The production scroll path coalesces viewport work after 8 ms and then
    // publishes the persisted source line after an 80 ms idle window. Keep a
    // main-actor gap probe alive through that delayed callback; measuring only
    // the synchronous scroll/draw frame would miss regressions in the work that
    // users feel immediately after lifting their fingers from the gesture.
    let expectedLocalViewportLine = try XCTUnwrap(
      OrgSyntaxTextEditor.Coordinator.visibleSourceLine(of: editor.textView)
    )
    let source = try XCTUnwrap(store.selectedEntrySource)
    let expectedPersistedViewportLine = source.startLine + expectedLocalViewportLine - 1
    try await Task.sleep(nanoseconds: 100_000_000)
    try await waitUntil(timeout: 2) {
      store.currentDocumentViewportSourceLine == expectedPersistedViewportLine
    }
    await editor.drawAfterDeferredViewUpdates()
    let postScrollMainActorGap = await postScrollGapProbe.stop()

    let gutter = try XCTUnwrap(editor.gutterView)
    try await waitUntil(timeout: 15) { gutter.items.count > 20 }
    let target = try XCTUnwrap(
      gutter.items.reversed().first(where: { $0.isFoldable }),
      "The adversarial/real large document must expose a foldable gutter heading"
    )
    await editor.scrollCaretToVisible(at: target.utf16Offset)
    await editor.drawAfterDeferredViewUpdates()

    var gutterSamples: [Double] = []
    for _ in 0..<10 {
      let before = try XCTUnwrap(gutter.items.first { $0.line == target.line }).isFolded
      let startedAt = CACurrentMediaTime()
      try editor.clickFoldGutterMarker(
        try XCTUnwrap(gutter.items.first { $0.line == target.line })
      )
      await workspace.drawFirstUsableFrame()
      gutterSamples.append((CACurrentMediaTime() - startedAt) * 1_000)
      await editor.drawAfterDeferredViewUpdates()
      let after = try XCTUnwrap(gutter.items.first { $0.line == target.line }).isFolded
      XCTAssertNotEqual(after, before, "A real gutter click must toggle the visible fold marker")
    }

    var structuralSamples: [Double] = []
    await editor.scrollCaretToVisible(at: target.utf16Offset)
    for index in 0..<10 {
      let demoting = index.isMultiple(of: 2)
      let beforeLength = editor.textLength
      let startedAt = CACurrentMediaTime()
      editor.textView.keyDown(with: try keyDownEvent(
        characters: "",
        modifiers: [.command, .option],
        keyCode: demoting ? 124 : 123,
        windowNumber: workspace.window.windowNumber
      ))
      await workspace.drawFirstUsableFrame()
      structuralSamples.append((CACurrentMediaTime() - startedAt) * 1_000)
      await editor.drawAfterDeferredViewUpdates()
      XCTAssertEqual(
        editor.textLength,
        beforeLength + (demoting ? 1 : -1),
        "Command-Option-arrow must perform a structural heading edit through the mounted editor"
      )
    }
    return (
      resizeSamples,
      scrollSamples,
      postScrollMainActorGap,
      gutterSamples,
      structuralSamples
    )
  }

  private func explicitlySaveLargeEditor(
    store: WorkspaceStore,
    editor: WorkspaceEditorPerformanceHarness,
    workspace: WorkspaceRenderPerformanceHarness,
    documentURL: URL,
    requiredMarkers: [String]
  ) async throws -> Double {
    workspace.window.makeFirstResponder(editor.textView)
    let startedAt = CACurrentMediaTime()
    editor.textView.keyDown(with: try keyDownEvent(
      characters: "s",
      modifiers: [.command],
      keyCode: 1,
      windowNumber: workspace.window.windowNumber
    ))
    try await waitUntil(timeout: 30) {
      !store.isSavingEntry && !store.entryEditorHasUnsavedChanges
    }
    let didDrainPersistence = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(didDrainPersistence)
    let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
    let persistedDocument = try await Task.detached(priority: .utility) {
      try String(contentsOf: documentURL, encoding: .utf8)
    }.value
    for marker in requiredMarkers {
      XCTAssertTrue(
        persistedDocument.contains(marker),
        "Command-S must make the exact text entered through the mounted editor durable"
      )
    }
    return elapsedMilliseconds
  }

  private func keyDownEvent(character: Character, windowNumber: Int) throws -> NSEvent {
    try keyDownEvent(
      characters: String(character),
      modifiers: [],
      keyCode: 0,
      windowNumber: windowNumber
    )
  }

  private func keyDownEvent(
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    windowNumber: Int
  ) throws -> NSEvent {
    return try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    ))
  }

  private func residentMemoryBytes() throws -> Int64 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = [
      "-o", "rss=",
      "-p", String(ProcessInfo.processInfo.processIdentifier),
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitForExit()
    let output = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, let kilobytes = Int64(output) else {
      throw PerformanceHarnessError.memoryProbeFailed
    }
    return kilobytes * 1_024
  }

  private func deterministicUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))!
  }

  private func isPath(_ candidatePath: String, containedIn root: URL) -> Bool {
    let canonicalRoot = root
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    let canonicalCandidate = URL(fileURLWithPath: candidatePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    return canonicalCandidate == canonicalRoot
      || canonicalCandidate.hasPrefix(canonicalRoot + "/")
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    try await waitUntil(
      timeout: timeout,
      description: "performance fixture work to settle",
      condition: condition
    )
  }

  private func waitUntil(
    timeout: TimeInterval,
    description: String,
    diagnostics: @MainActor () -> String = { "" },
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let detail = diagnostics()
    XCTFail("Timed out waiting for \(description)\(detail.isEmpty ? "" : " (\(detail))")")
    throw PerformanceHarnessError.timedOut
  }
}
