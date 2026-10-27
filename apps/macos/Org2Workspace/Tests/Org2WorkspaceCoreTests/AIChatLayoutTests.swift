import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
private final class TranscriptLayoutProbeCounter {
  var realizedRows = 0
}

private struct TranscriptLayoutProbe: NSViewRepresentable {
  let counter: TranscriptLayoutProbeCounter

  func makeNSView(context: Context) -> NSView {
    counter.realizedRows += 1
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct SidebarControlBoundsProbe: NSViewRepresentable {
  let identifier: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.setAccessibilityIdentifier(identifier)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private enum ChatAccessibilityNode {
  case view(NSView)
  case element(NSAccessibilityElement)

  var identity: ObjectIdentifier {
    switch self {
    case .view(let value): ObjectIdentifier(value)
    case .element(let value): ObjectIdentifier(value)
    }
  }

  var accessibilityIdentifier: String? {
    switch self {
    case .view(let value): value.accessibilityIdentifier()
    case .element(let value): value.accessibilityIdentifier()
    }
  }

  var accessibilityLabel: String? {
    switch self {
    case .view(let value): value.accessibilityLabel()
    case .element(let value): value.accessibilityLabel()
    }
  }

  var accessibilityRole: NSAccessibility.Role? {
    switch self {
    case .view(let value): value.accessibilityRole()
    case .element(let value): value.accessibilityRole()
    }
  }

  var children: [Any] {
    switch self {
    case .view(let value):
      // SwiftUI may expose a native accessibility element through either the
      // AppKit view hierarchy or the synthesized accessibility hierarchy,
      // depending on when the hosting view first lays out. Traverse both so
      // this assertion always exercises the real native action rather than a
      // backend-specific tree shape.
      return value.subviews + (value.accessibilityChildren() ?? [])
    case .element(let value): return value.accessibilityChildren() ?? []
    }
  }

  func performPress() -> Bool {
    switch self {
    case .view(let value): value.accessibilityPerformPress()
    case .element(let value): value.accessibilityPerformPress()
    }
  }
}

@MainActor
private func chatAccessibilityNodes(in root: NSView) -> [ChatAccessibilityNode] {
  var result: [ChatAccessibilityNode] = []
  var pending: [ChatAccessibilityNode] = [.view(root)]
  var visited = Set<ObjectIdentifier>()
  while let node = pending.popLast(), result.count < 2_000 {
    guard visited.insert(node.identity).inserted else { continue }
    result.append(node)
    for child in node.children {
      if let view = child as? NSView {
        pending.append(.view(view))
      } else if let element = child as? NSAccessibilityElement {
        pending.append(.element(element))
      }
    }
  }
  return result
}

@MainActor
final class AIChatLayoutTests: XCTestCase {
  func testChatThreadSubtreeUsesCompactLeadingPadding() {
    XCTAssertEqual(AIChatSidebarThreadLayout.leadingPadding, 12)
  }

  func testSidebarSettlementButtonKeepsItsSpaceAtNarrowWidths() async throws {
    for enabled in [false, true] {
      for width: CGFloat in [160, 220, 320] {
        for settled in [false, true] {
          var previousTitleFrame: NSRect?
          for visible in [false, true] {
            let row = HStack(spacing: 2) {
              Button {} label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text("A long conversation title that fills the sidebar")
                    .font(.callout).lineLimit(1)
                  Text("7 messages · Codex · 55m")
                    .font(.caption2.monospaced()).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
                .padding(.vertical, 6)
              }
              .buttonStyle(.plain)
              .background(SidebarControlBoundsProbe(identifier: "sidebar-title"))
              AIChatSidebarThreadSettlementButton(isSettled: settled, isVisible: visible) {}
                .background(SidebarControlBoundsProbe(identifier: "sidebar-settlement"))
            }
            .padding(.trailing, 6)
            .frame(width: width, height: 44)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: row.disabled(!enabled))
            let window = NSWindow(
              contentRect: NSRect(x: 0, y: 0, width: width, height: 44),
              styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.contentView = nil; window.close() }
            for _ in 0..<3 {
              host.layoutSubtreeIfNeeded()
              try await Task.sleep(for: .milliseconds(20))
            }
            let probes = chatAccessibilityNodes(in: host).compactMap { node -> NSView? in
              guard case .view(let view) = node else { return nil }
              return view
            }
            let title = try XCTUnwrap(probes.first { $0.accessibilityIdentifier() == "sidebar-title" })
            let titleFrame = title.convert(title.bounds, to: host)
            if let previousTitleFrame {
              XCTAssertEqual(titleFrame, previousTitleFrame, "Hover must not move or compress the title")
            }
            previousTitleFrame = titleFrame
            let action = try XCTUnwrap(probes.first { $0.accessibilityIdentifier() == "sidebar-settlement" })
            let frame = action.convert(action.bounds, to: host)
            XCTAssertEqual(frame.width, 28, accuracy: 0.5)
            XCTAssertEqual(frame.height, 28, accuracy: 0.5)
            XCTAssertLessThanOrEqual(titleFrame.maxX + 2, frame.minX + 0.5)
            XCTAssertTrue(host.bounds.contains(frame), "The entire action must remain inside the row")
            if visible, let directory = ProcessInfo.processInfo.environment["OPENORG_LAYOUT_SNAPSHOT_DIR"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
              host.cacheDisplay(in: host.bounds, to: bitmap)
              let output = URL(fileURLWithPath: directory, isDirectory: true)
              try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
              try bitmap.representation(using: .png, properties: [:])?.write(
                to: output.appendingPathComponent("sidebar-settlement-\(Int(width))-\(settled).png")
              )
            }
          }
        }
      }
    }
  }

  func testComposerKeepsModelControlsVisibleAcrossPaneWidths() async throws {
    let suiteName = "ChatComposerLayout.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    let screenshotEnvironment = "ORG2_WORKSPACE_SCREENSHOT_CORPUS"
    let previousScreenshotCorpus = ProcessInfo.processInfo.environment[screenshotEnvironment]
    setenv(screenshotEnvironment, root.path, 1)
    defer {
      if let previousScreenshotCorpus {
        setenv(screenshotEnvironment, previousScreenshotCorpus, 1)
      } else {
        unsetenv(screenshotEnvironment)
      }
    }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.createAIChatThread(runtime: .codex)
    store.setSelectedAIChatModel("a-model-with-a-long-display-name")

    for compact in [false, true] {
      for width: CGFloat in [280, 360, 460, 900] {
        let footer = AIChatComposerView(focusOnAppear: false, compact: compact)
          .environment(store)
          .frame(width: width)
        let host = NSHostingView(rootView: footer)
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: 220),
          styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 220)
        window.orderFrontRegardless()
        for _ in 0..<5 {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(20))
        }
        // The combined picker is a SwiftUI button, whose synthesized accessibility
        // tree is only exposed out of process. Keep the host's width/height
        // contract here; Preview verification exercises the actual control.
        XCTAssertLessThanOrEqual(host.fittingSize.width, width)
        XCTAssertLessThan(host.fittingSize.height, 220)
        window.contentView = nil
        window.close()
      }
    }
  }

  func testDefaultSplitProtectsAUsableChatPaneAtLaptopWidth() {
    XCTAssertGreaterThanOrEqual(WorkspaceMainSplitLayout.surfaceMinimumWidth, 300)
    XCTAssertLessThanOrEqual(
      WorkspaceMainSplitLayout.surfaceMinimumWidth + WorkspaceMainSplitLayout.detailMinimumWidth,
      720,
      "The two-pane minimum must fit inside the default compact workspace after navigation chrome"
    )
  }

  func testComposerPreservesNewerNativeTextAcrossDelayedModelUpdates() {
    var synchronization = AIChatComposerTextSynchronization(initialModelText: "")

    synchronization.nativeTextDidChange("ok")
    synchronization.nativeTextDidChange("ok ")
    synchronization.nativeTextDidChange("ok -")

    XCTAssertEqual(
      synchronization.modelTextUpdate(""),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("ok"),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("ok "),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("ok -"),
      .preserveNativeText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("Externally restored draft"),
      .applyModelText
    )
  }

  func testComposerForcedModelUpdateSupersedesPendingNativeText() {
    var synchronization = AIChatComposerTextSynchronization()
    synchronization.nativeTextDidChange("Send this")

    XCTAssertEqual(
      synchronization.modelTextUpdate("", forced: true),
      .applyModelText
    )
    XCTAssertEqual(
      synchronization.modelTextUpdate("Send this"),
      .applyModelText
    )
  }

  func testLiveProgressFeedShowsOnlyCurrentActivityUntilExpanded() {
    let completed = AIChatActivityFeedItem(
      id: "completed",
      title: "17 shell commands",
      detail: "17 completed",
      latestDetail: nil,
      status: .succeeded,
      count: 17,
      updatedAt: Date()
    )
    let failed = AIChatActivityFeedItem(
      id: "failed",
      title: "Memory search",
      detail: "Tool call failed",
      latestDetail: nil,
      status: .failed,
      count: 1,
      updatedAt: Date()
    )
    let items = [completed, failed]

    XCTAssertEqual(
      AIChatProgressFeedPresentation.visibleItems(
        items,
        isLive: true,
        isExpanded: false,
        collapsedItemLimit: 3
      ),
      [failed]
    )
    XCTAssertFalse(AIChatProgressFeedPresentation.showsReasoning(isLive: true, isExpanded: false))
    XCTAssertTrue(AIChatProgressFeedPresentation.canExpand(
      itemCount: items.count,
      reasoningLength: 0,
      isLive: true,
      collapsedItemLimit: 3
    ))
    XCTAssertEqual(
      AIChatProgressFeedPresentation.disclosureTitle(isLive: true, isExpanded: false),
      "Show all activity"
    )
    // The live card has one disclosure for the earlier reply text and the
    // activity feed; earlier text alone is enough to offer it.
    XCTAssertTrue(AIChatLiveProgressDisclosure.isAvailable(hasEarlierText: true, activityCount: 0, hasReasoning: false))
    XCTAssertTrue(AIChatLiveProgressDisclosure.isAvailable(hasEarlierText: false, activityCount: 0, hasReasoning: true))
    XCTAssertFalse(AIChatLiveProgressDisclosure.isAvailable(hasEarlierText: false, activityCount: 0, hasReasoning: false))
    XCTAssertEqual(AIChatLiveProgressDisclosure.title(isExpanded: true), "Hide activity")
    XCTAssertEqual(
      AIChatProgressFeedPresentation.visibleItems(
        items,
        isLive: true,
        isExpanded: true,
        collapsedItemLimit: 3
      ),
      items
    )
    XCTAssertTrue(AIChatProgressFeedPresentation.showsReasoning(isLive: true, isExpanded: true))

    let running = AIChatActivityFeedItem(
      id: "running",
      title: "Editing file",
      detail: "Updating the selected document",
      latestDetail: nil,
      status: .running,
      count: 1,
      updatedAt: Date()
    )
    XCTAssertEqual(
      AIChatProgressFeedPresentation.visibleItems(
        [running, completed, failed],
        isLive: true,
        isExpanded: false,
        collapsedItemLimit: 3
      ),
      [running]
    )
  }

  func testExpandedProgressFeedKeepsMountedRowsStrictlyBounded() {
    let items = (0..<10_000).map { index in
      AIChatActivityFeedItem(
        id: "activity-\(index)",
        title: "Activity \(index)",
        detail: nil,
        latestDetail: nil,
        status: .succeeded,
        count: 1,
        updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let visible = AIChatProgressFeedPresentation.visibleItems(
      items,
      isLive: false,
      isExpanded: true,
      collapsedItemLimit: 3
    )

    XCTAssertEqual(visible.count, AIChatProgressFeedPresentation.maximumExpandedItemCount)
    XCTAssertEqual(visible.first?.id, "activity-9904")
    XCTAssertEqual(visible.last?.id, "activity-9999")
    XCTAssertEqual(
      AIChatProgressFeedPresentation.omittedExpandedItemCount(
        itemCount: items.count,
        isExpanded: true
      ),
      10_000 - AIChatProgressFeedPresentation.maximumExpandedItemCount
    )
  }

  func testMessagePresentationCacheReusesParsedContentAndInvalidatesEdits() {
    AIChatMessagePresentationCache.removeAllForTesting()
    let messageID = UUID()
    let original = AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Result\n| Name | Value |\n|------+-------|\n| Alpha | 1 |",
      responseTrace: AIChatResponseTrace(activities: [
        AIChatRunActivity(
          id: "tool-1",
          runID: "run-1",
          kind: .tool,
          title: "Shell command",
          status: .succeeded
        )
      ])
    )

    let first = AIChatMessagePresentationCache.presentation(for: original)
    let second = AIChatMessagePresentationCache.presentation(for: original)
    XCTAssertTrue(first === second)
    XCTAssertTrue(first.org?.usesStructuredRendering == true)
    XCTAssertEqual(first.activityFeedItems.count, 1)

    let edited = AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Changed result"
    )
    let editedPresentation = AIChatMessagePresentationCache.presentation(for: edited)
    XCTAssertFalse(first === editedPresentation)
    XCTAssertEqual(editedPresentation.context.userText, "* Changed result")
  }

  func testDetachedMessagePresentationMatchesMainActorFallback() async {
    AIChatMessagePresentationCache.removeAllForTesting()
    let message = AIChatMessage(
      role: .assistant,
      content: "* Result\n| Name | Value |\n|------+-------|\n| Alpha | *one* |",
      responseTrace: AIChatResponseTrace(
        reasoning: "Checked the source",
        activities: [
          AIChatRunActivity(
            id: "tool-1",
            runID: "run-1",
            kind: .tool,
            title: "Read file",
            detail: "Loaded the selected source",
            status: .succeeded
          ),
        ]
      )
    )
    let input = AIChatMessagePresentationInput(message)
    let prepared = await Task.detached {
      AIChatMessagePresentationBuilder.prepare(input)
    }.value

    XCTAssertEqual(prepared.messageID, message.id)
    XCTAssertTrue(prepared.value.matches(input))
    XCTAssertEqual(prepared.value.context.userText, message.content)
    XCTAssertTrue(prepared.value.body.org?.usesStructuredRendering == true)
    XCTAssertEqual(prepared.value.activityFeedItems.count, 1)
    XCTAssertGreaterThan(prepared.estimatedCost, message.content.utf8.count)

    AIChatMessagePresentationCache.install(prepared)
    XCTAssertTrue(AIChatMessagePresentationCache.presentation(for: message) === prepared.value)
  }

  func testMessagePresentationInputAndCostDoNotDependOnAttachments() {
    let messageID = UUID()
    let content = "A response with [[notes/example.org2][a link]]."
    let smallAttachmentMessage = AIChatMessage(
      id: messageID,
      role: .assistant,
      content: content,
      attachments: [
        AIChatAttachment(
          fileName: "small.bin",
          mimeType: "application/octet-stream",
          data: Data([0x01])
        ),
      ]
    )
    let largeAttachmentMessage = AIChatMessage(
      id: messageID,
      role: .assistant,
      content: content,
      attachments: [
        AIChatAttachment(
          fileName: "large.bin",
          mimeType: "application/octet-stream",
          data: Data(repeating: 0x42, count: 512 * 1_024)
        ),
      ]
    )

    let smallInput = AIChatMessagePresentationInput(smallAttachmentMessage)
    let largeInput = AIChatMessagePresentationInput(largeAttachmentMessage)
    XCTAssertEqual(smallInput, largeInput)

    let smallPrepared = AIChatMessagePresentationBuilder.prepare(smallInput)
    let largePrepared = AIChatMessagePresentationBuilder.prepare(largeInput)
    XCTAssertEqual(smallPrepared.estimatedCost, largePrepared.estimatedCost)
    XCTAssertEqual(smallPrepared.value.body, largePrepared.value.body)
  }

  func testLargeMessagePresentationUsesUnicodeSafeBoundedPreviewAndFullClipboardText() throws {
    let boundary = AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
    let suffix = "🧪 FULL-CONTENT-SENTINEL"
    let content = String(repeating: "a", count: boundary - 1) + suffix
    let message = AIChatMessage(role: .assistant, content: content)
    let prepared = AIChatMessagePresentationBuilder.prepare(
      AIChatMessagePresentationInput(message)
    )

    XCTAssertTrue(prepared.value.body.isTruncated)
    XCTAssertLessThanOrEqual(
      prepared.value.body.displayedText.utf8.count,
      AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
    XCTAssertFalse(prepared.value.body.displayedText.contains("🧪"))
    XCTAssertTrue(String(data: Data(prepared.value.body.displayedText.utf8), encoding: .utf8) != nil)
    XCTAssertEqual(AIChatMessageClipboard.text(for: message), content)

    let expanded = try XCTUnwrap(AIChatMessagePresentationBuilder.prepareExpandedBody(
      sourceText: prepared.value.body.sourceText,
      role: .assistant
    ))
    XCTAssertFalse(expanded.isTruncated)
    XCTAssertEqual(expanded.displayedText, content)
    XCTAssertTrue(expanded.containsInlineSyntax == false)
  }

  func testMultiMegabyteExpandedMessageUsesBoundedNavigablePages() throws {
    let pageLimit = AIChatExpandedMessageBodyInput.pageCharacterLimit
    let source = String(repeating: "a", count: pageLimit)
      + String(repeating: "b", count: pageLimit)
      + "FINAL-PAGE-SENTINEL"

    let first = try XCTUnwrap(AIChatMessagePresentationBuilder.prepareExpandedBody(
      sourceText: source,
      role: .assistant,
      pageIndex: 0
    ))
    let second = try XCTUnwrap(AIChatMessagePresentationBuilder.prepareExpandedBody(
      sourceText: source,
      role: .assistant,
      pageIndex: 1
    ))
    let final = try XCTUnwrap(AIChatMessagePresentationBuilder.prepareExpandedBody(
      sourceText: source,
      role: .assistant,
      pageIndex: 2
    ))

    XCTAssertEqual(first.displayedText.count, pageLimit)
    XCTAssertEqual(second.displayedText.count, pageLimit)
    XCTAssertTrue(first.isTruncated)
    XCTAssertTrue(second.isTruncated)
    XCTAssertFalse(first.displayedText.contains("FINAL-PAGE-SENTINEL"))
    XCTAssertFalse(second.displayedText.contains("FINAL-PAGE-SENTINEL"))
    XCTAssertEqual(final.displayedText, "FINAL-PAGE-SENTINEL")
    XCTAssertFalse(final.isTruncated)
  }

  func testOffMainPresentationRevisionInvalidatesSameLengthMiddleEdit() async throws {
    let messageID = UUID()
    let originalInput = AIChatMessagePresentationInput(AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "prefix-ORIGINAL-suffix"
    ))
    let editedInput = AIChatMessagePresentationInput(AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "prefix-CHANGED!-suffix"
    ))
    XCTAssertEqual(originalInput.rawText.count, editedInput.rawText.count)

    let (originalRevision, editedRevision) = await Task.detached {
      (
        AIChatMessagePresentationRevision(originalInput),
        AIChatMessagePresentationRevision(editedInput)
      )
    }.value
    XCTAssertNotEqual(originalRevision, editedRevision)

    let original = AIChatMessagePresentationBuilder.prepare(
      originalInput,
      revision: originalRevision
    )
    let resolved = await AIChatMessagePresentationPreparationCoordinator.shared.resolve(
      editedInput,
      cachedCandidate: original.value
    )
    XCTAssertEqual(resolved.revision, editedRevision)
    XCTAssertEqual(resolved.value.body.displayedText, editedInput.rawText)
    XCTAssertNotNil(resolved.preparedForCacheInstall)
  }

  func testLargeMessagePreviewExposesNativeShowFullActionAndFindReveal() async throws {
    AIChatMessagePresentationCache.removeAllForTesting()
    let message = AIChatMessage(
      role: .assistant,
      content: String(
        repeating: "large response ",
        count: AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit / 8
      )
    )
    let messageIdentifier = message.id.uuidString.lowercased()
    let showFullID = "openclaw-message-show-full-\(messageIdentifier)"
    let showLessID = "openclaw-message-show-less-\(messageIdentifier)"
    let hostingView = NSHostingView(rootView: ChatBubbleView(message: message))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
      window.contentView = nil
      window.close()
    }

    var showFullNode: ChatAccessibilityNode?
    for _ in 0..<1_000 {
      hostingView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      showFullNode = chatAccessibilityNodes(in: hostingView).first {
        $0.accessibilityIdentifier == showFullID
      }
      if showFullNode != nil { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let showFull = try XCTUnwrap(
      showFullNode,
      chatAccessibilityNodes(in: hostingView)
        .compactMap { node -> String? in
          guard node.accessibilityIdentifier != nil || node.accessibilityLabel != nil else {
            return nil
          }
          let identifier = node.accessibilityIdentifier ?? "nil"
          let label = node.accessibilityLabel ?? "nil"
          let role = node.accessibilityRole?.rawValue ?? "nil"
          return "id=\(identifier) label=\(label) role=\(role)"
        }
        .joined(separator: "\n")
    )
    XCTAssertTrue(showFull.performPress())

    var didExposeShowLess = false
    for _ in 0..<1_000 {
      hostingView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if chatAccessibilityNodes(in: hostingView).contains(where: {
        $0.accessibilityIdentifier == showLessID
      }) {
        didExposeShowLess = true
        break
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(didExposeShowLess)

    hostingView.rootView = ChatBubbleView(
      message: message,
      isSelectedSearchMatch: true
    )
    let revealedID = "openclaw-message-full-revealed-\(messageIdentifier)"
    var didRevealSelectedMatch = false
    for _ in 0..<1_000 {
      hostingView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if chatAccessibilityNodes(in: hostingView).contains(where: {
        $0.accessibilityIdentifier == revealedID
      }) {
        didRevealSelectedMatch = true
        break
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(didRevealSelectedMatch)
  }

  func testInstalledPreparedPresentationStillInvalidatesAnEditedSameIDMessage() {
    AIChatMessagePresentationCache.removeAllForTesting()
    let messageID = UUID()
    let original = AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "Original"
    )
    let prepared = AIChatMessagePresentationBuilder.prepare(
      AIChatMessagePresentationInput(original)
    )
    AIChatMessagePresentationCache.install(prepared)

    let edited = AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "Edited"
    )
    let editedPresentation = AIChatMessagePresentationCache.presentation(for: edited)

    XCTAssertFalse(editedPresentation === prepared.value)
    XCTAssertEqual(editedPresentation.body.displayedText, "Edited")
  }

  func testConcurrentColdAndExpandedPreparationDeduplicatesWork() async throws {
    let presentationCoordinator = AIChatMessagePresentationPreparationCoordinator.shared
    let expansionCoordinator = AIChatExpandedMessageBodyPreparationCoordinator.shared
    await presentationCoordinator.resetForTesting()
    await expansionCoordinator.resetForTesting()
    let message = AIChatMessage(
      role: .assistant,
      content: String(repeating: "long response ", count: 4_000)
    )
    let input = AIChatMessagePresentationInput(message)

    async let first = presentationCoordinator.prepare(input)
    async let second = presentationCoordinator.prepare(input)
    let (firstPrepared, secondPrepared) = await (first, second)

    XCTAssertTrue(firstPrepared.value === secondPrepared.value)
    let presentationPreparationCount = await presentationCoordinator.countForTesting()
    XCTAssertEqual(presentationPreparationCount, 1)

    let expandedInput = AIChatExpandedMessageBodyInput(
      messageID: input.messageID,
      role: input.role,
      sourceText: firstPrepared.value.body.sourceText
    )
    async let firstExpanded = expansionCoordinator.prepare(expandedInput)
    async let secondExpanded = expansionCoordinator.prepare(expandedInput)
    let expandedBodies = await (firstExpanded, secondExpanded)

    XCTAssertEqual(try XCTUnwrap(expandedBodies.0), try XCTUnwrap(expandedBodies.1))
    let expansionPreparationCount = await expansionCoordinator.countForTesting()
    XCTAssertEqual(expansionPreparationCount, 1)

    let userExpandedInput = AIChatExpandedMessageBodyInput(
      messageID: expandedInput.messageID,
      role: .user,
      sourceText: expandedInput.sourceText
    )
    XCTAssertNotEqual(userExpandedInput, expandedInput)
    let userExpandedResult = await expansionCoordinator.prepare(userExpandedInput)
    let userExpanded = try XCTUnwrap(userExpandedResult)
    XCTAssertNil(userExpanded.org)
    let roleSensitivePreparationCount = await expansionCoordinator.countForTesting()
    XCTAssertEqual(roleSensitivePreparationCount, 2)

    await expansionCoordinator.resetForTesting()
    let cancellationTask = Task {
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {}
      return await expansionCoordinator.prepare(expandedInput)
    }
    cancellationTask.cancel()
    let cancelledExpansion = await cancellationTask.value
    XCTAssertNil(cancelledExpansion)
  }

  func testStandardPreparationGloballyBoundsWorkersAndSerializesSameMessageEdits() async throws {
    let coordinator = AIChatMessagePresentationPreparationCoordinator.shared
    await coordinator.resetForTesting()
    await coordinator.setWorkersPausedForTesting(true)
    let messageID = UUID()
    let originalInput = AIChatMessagePresentationInput(AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Original\nOriginal body"
    ))
    let changedInput = AIChatMessagePresentationInput(AIChatMessage(
      id: messageID,
      role: .assistant,
      content: "* Changed\nChanged body"
    ))
    let secondInput = AIChatMessagePresentationInput(AIChatMessage(
      role: .assistant,
      content: "Second message"
    ))
    let thirdInput = AIChatMessagePresentationInput(AIChatMessage(
      role: .assistant,
      content: "Third message"
    ))

    let originalTask = Task { await coordinator.prepare(originalInput) }
    for _ in 0..<100 {
      if await coordinator.activeWorkerCountForTesting() == 1 { break }
      await Task.yield()
    }
    let changedTask = Task { await coordinator.prepare(changedInput) }
    let secondTask = Task { await coordinator.prepare(secondInput) }
    let thirdTask = Task { await coordinator.prepare(thirdInput) }
    var allPreparationsWereScheduled = false
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 4,
         await coordinator.activeWorkerCountForTesting() == 2 {
        allPreparationsWereScheduled = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(allPreparationsWereScheduled)
    let workerLimit = await coordinator.maximumConcurrentWorkerCountForTesting()
    let peakWhilePaused = await coordinator.peakConcurrentWorkerCountForTesting()
    let sameMessagePeakWhilePaused = await coordinator.peakWorkerCountForTesting(
      messageID: messageID
    )
    XCTAssertEqual(workerLimit, 2)
    XCTAssertEqual(peakWhilePaused, workerLimit)
    XCTAssertEqual(sameMessagePeakWhilePaused, 1)

    await coordinator.setWorkersPausedForTesting(false)
    let original = await originalTask.value
    let changed = await changedTask.value
    _ = await secondTask.value
    _ = await thirdTask.value
    XCTAssertEqual(original.value.rawText, originalInput.rawText)
    XCTAssertEqual(changed.value.rawText, changedInput.rawText)
    let preparationCount = await coordinator.countForTesting()
    let finalActiveWorkerCount = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCount = await coordinator.peakConcurrentWorkerCountForTesting()
    let sameMessagePeakWorkerCount = await coordinator.peakWorkerCountForTesting(
      messageID: messageID
    )
    XCTAssertEqual(preparationCount, 4)
    XCTAssertEqual(finalActiveWorkerCount, 0)
    XCTAssertEqual(peakWorkerCount, workerLimit)
    XCTAssertEqual(sameMessagePeakWorkerCount, 1)
  }

  func testExpandedPreparationSerializesRapidCancelRerequestAndChangedInput() async throws {
    let coordinator = AIChatExpandedMessageBodyPreparationCoordinator.shared
    await coordinator.resetForTesting()
    await coordinator.setWorkersPausedForTesting(true)
    let messageID = UUID()
    let originalInput = AIChatExpandedMessageBodyInput(
      messageID: messageID,
      role: .assistant,
      sourceText: "* Original\nOriginal body"
    )
    let changedInput = AIChatExpandedMessageBodyInput(
      messageID: messageID,
      role: .user,
      sourceText: "Changed body"
    )

    let canceledWaiter = Task {
      await coordinator.prepare(originalInput)
    }
    var originalWorkerDidStart = false
    for _ in 0..<100 {
      if await coordinator.activeWorkerCountForTesting() == 1 {
        originalWorkerDidStart = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(originalWorkerDidStart)

    canceledWaiter.cancel()
    async let repeatedResult = coordinator.prepare(originalInput)
    async let changedResult = coordinator.prepare(changedInput)
    var bothRequestsWereQueued = false
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 2 {
        bothRequestsWereQueued = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(bothRequestsWereQueued)
    let activeWorkerCountWhilePaused = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCountWhilePaused = await coordinator.peakConcurrentWorkerCountForTesting()
    XCTAssertEqual(activeWorkerCountWhilePaused, 1)
    XCTAssertEqual(peakWorkerCountWhilePaused, 1)

    await coordinator.setWorkersPausedForTesting(false)
    let canceledResult = await canceledWaiter.value
    let (repeated, changed) = await (repeatedResult, changedResult)
    XCTAssertNil(canceledResult)
    XCTAssertEqual(try XCTUnwrap(repeated).sourceText, originalInput.sourceText)
    XCTAssertEqual(try XCTUnwrap(changed).sourceText, changedInput.sourceText)
    let preparationCount = await coordinator.countForTesting()
    let finalActiveWorkerCount = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCount = await coordinator.peakConcurrentWorkerCountForTesting()
    XCTAssertEqual(preparationCount, 2)
    XCTAssertEqual(finalActiveWorkerCount, 0)
    XCTAssertEqual(peakWorkerCount, 1)
  }

  func testChatBubbleColdPathUsesBoundedAsyncPlaceholderInsteadOfSynchronousCacheMiss() throws {
    let message = AIChatMessage(
      role: .assistant,
      content: String(repeating: "L", count: 1_694_760)
    )
    let input = AIChatMessagePresentationInput(message)
    let placeholder = AIChatMessagePresentationBuilder.placeholder(input)

    XCTAssertLessThanOrEqual(placeholder.body.displayedText.utf8.count, 2 * 1_024)
    XCTAssertTrue(placeholder.body.isTruncated)
    XCTAssertNil(placeholder.body.org)
    XCTAssertFalse(placeholder.body.containsInlineSyntax)

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/AIChatViews.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let bubbleStart = try XCTUnwrap(source.range(of: "struct ChatBubbleView: View"))
    let bubbleEnd = try XCTUnwrap(
      source.range(of: "private var copyButton: some View", range: bubbleStart.upperBound..<source.endIndex)
    )
    let bubbleBody = source[bubbleStart.lowerBound..<bubbleEnd.lowerBound]
    XCTAssertFalse(bubbleBody.contains("AIChatMessagePresentationCache.presentation(for: message)"))
    XCTAssertTrue(bubbleBody.contains("AIChatMessagePresentationResolver(input: presentationInput)"))
    XCTAssertFalse(bubbleBody.contains("Org2DocumentPresentation.parse("))
  }

  func testColdUserPlaceholderNeverExposesAutomaticContextPromptOrUserExcerpt() {
    let secretPrompt = "PRIVATE-AUTOMATIC-CONTEXT-SENTINEL"
    let userText = "PRIVATE-USER-TEXT-SENTINEL"
    let message = AIChatMessage(
      role: .user,
      content: """
      Use selected file “Private” at notes/private.org as context.
      #+begin_org2_ai_context
      \(secretPrompt)
      #+end_org2_ai_context

      \(userText)
      """
    )
    let placeholder = AIChatMessagePresentationBuilder.placeholder(
      AIChatMessagePresentationInput(message)
    )

    XCTAssertTrue(placeholder.context.contexts.isEmpty)
    XCTAssertTrue(placeholder.context.userText.isEmpty)
    XCTAssertTrue(placeholder.body.sourceText.isEmpty)
    XCTAssertEqual(placeholder.body.displayedText, "Preparing message…")
    XCTAssertFalse(placeholder.body.displayedText.contains(secretPrompt))
    XCTAssertFalse(placeholder.body.displayedText.contains(userText))
  }

  func testLiveStreamingPresentationIsSerialOffMainAndNeverFallsBackToSynchronousParsing() async throws {
    let coordinator = AIChatLiveTextPreparationCoordinator.shared
    await coordinator.resetForTesting()
    await coordinator.setWorkersPausedForTesting(true)
    let streamID = UUID()
    let firstInput = AIChatLiveTextPreparationInput(
      rawText: "First update",
      showsAll: false
    )
    let obsoleteInput = AIChatLiveTextPreparationInput(
      rawText: "Obsolete queued update",
      showsAll: false
    )
    let latestInput = AIChatLiveTextPreparationInput(
      rawText: "Latest update",
      showsAll: false
    )
    let firstTask = Task {
      await coordinator.prepare(streamID: streamID, input: firstInput)
    }
    var firstWorkerDidStart = false
    for _ in 0..<100 {
      if await coordinator.activeWorkerCountForTesting() == 1 {
        firstWorkerDidStart = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(firstWorkerDidStart)
    let obsoleteTask = Task {
      await coordinator.prepare(streamID: streamID, input: obsoleteInput)
    }
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 2 { break }
      await Task.yield()
    }
    let latestTask = Task {
      await coordinator.prepare(streamID: streamID, input: latestInput)
    }
    var allInputsWereScheduled = false
    for _ in 0..<100 {
      if await coordinator.countForTesting() == 3 {
        allInputsWereScheduled = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(allInputsWereScheduled)
    await coordinator.setWorkersPausedForTesting(false)
    let first = await firstTask.value
    let obsolete = await obsoleteTask.value
    let latest = await latestTask.value

    XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(first).body).displayedText, firstInput.rawText)
    XCTAssertNil(obsolete)
    XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(latest).body).displayedText, latestInput.rawText)
    let parserInputs = await coordinator.parserInputsForTestingSnapshot()
    XCTAssertEqual(parserInputs, [firstInput, latestInput])
    let preparationCount = await coordinator.countForTesting()
    let finalActiveWorkerCount = await coordinator.activeWorkerCountForTesting()
    let peakWorkerCount = await coordinator.peakConcurrentWorkerCountForTesting()
    XCTAssertEqual(preparationCount, 3)
    XCTAssertEqual(finalActiveWorkerCount, 0)
    XCTAssertEqual(peakWorkerCount, 1)

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/AIChatViews.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let viewStart = try XCTUnwrap(source.range(of: "struct AIChatTypingIndicatorView: View"))
    let viewEnd = try XCTUnwrap(
      source.range(of: "  func statusTitle(now: Date)", range: viewStart.upperBound..<source.endIndex)
    )
    let viewSource = source[viewStart.lowerBound..<viewEnd.lowerBound]
    XCTAssertFalse(viewSource.contains("AIChatProgressPresentation.liveTextPresentation("))
    XCTAssertTrue(viewSource.contains("Task.sleep(for: .milliseconds(24))"))
    XCTAssertTrue(viewSource.contains("AIChatLiveTextPreparationCoordinator.shared.prepare"))
    XCTAssertFalse(viewSource.contains("Org2DocumentPresentation.parse("))
  }

  func testLivePreparationBoundsReasoningActivitiesAndRawDetailsBeforeGrouping() async throws {
    let oversizedDetail = String(repeating: "detail ", count: 200_000)
    let activities = (0..<200).map { index in
      AIChatRunActivity(
        id: "activity-\(index)",
        runID: "run",
        kind: .tool,
        title: "tool",
        detail: oversizedDetail,
        status: index == 199 ? .running : .succeeded
      )
    }
    let input = AIChatLiveTextPreparationInput(
      rawText: String(repeating: "stream ", count: 100_000),
      showsAll: false,
      hasOmittedPrefix: true,
      reasoning: String(repeating: "reasoning ", count: 100_000),
      reasoningHasOmittedPrefix: true,
      activities: activities
    )

    XCTAssertEqual(input.activities.count, AIChatLiveTextPreparationInput.maximumActivityCount)
    XCTAssertTrue(input.activities.allSatisfy {
      ($0.detail?.utf8.count ?? 0)
        <= AIChatLiveTextPreparationInput.maximumActivityDetailUTF8ByteCount
    })
    let preparedResult = await AIChatLiveTextPreparationCoordinator.shared.prepare(
      streamID: UUID(),
      input: input
    )
    let prepared = try XCTUnwrap(preparedResult)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(prepared.body).displayedText.count,
      AIChatProgressPresentation.maximumLiveNormalizationInputCharacterCount
    )
    XCTAssertLessThanOrEqual(prepared.reasoning?.count ?? .max, 1_200)
    XCTAssertLessThanOrEqual(prepared.activityFeedItems.count, input.activities.count)
  }

  func testLiveTypingViewReadsOneBoundedSnapshotAndNeverMaterializesFullRopes() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/AIChatViews.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "struct AIChatLiveTypingIndicatorView: View"))
    let end = try XCTUnwrap(source.range(
      of: "struct AIChatLiveTextPreparationInput",
      range: start.upperBound..<source.endIndex
    ))
    let viewSource = source[start.lowerBound..<end.lowerBound]

    XCTAssertEqual(viewSource.components(separatedBy: "presentationSnapshot(for:").count - 1, 1)
    XCTAssertFalse(viewSource.contains("streamingReply(for:"))
    XCTAssertFalse(viewSource.contains("reasoning(for:"))
  }

  func testChatTimestampsIncludeUsefulDateContext() throws {
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let locale = Locale(identifier: "en_US_POSIX")
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
      try XCTUnwrap(calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute
      )))
    }
    let now = try date(2026, 8, 17, 15, 0)

    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2026, 8, 17, 9, 15),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Today at 9:15\u{202F}AM"
    )
    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2026, 8, 16, 21, 5),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Yesterday at 9:05\u{202F}PM"
    )
    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2026, 7, 4, 12, 30),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Jul 4 at 12:30\u{202F}PM"
    )
    XCTAssertEqual(
      AIChatMessageTimestampPresentation.displayText(
        for: try date(2025, 12, 31, 23, 59),
        relativeTo: now,
        calendar: calendar,
        locale: locale,
        timeZone: timeZone
      ),
      "Dec 31, 2025 at 11:59\u{202F}PM"
    )
  }

  func testSidebarThreadActivityIndicatorIsExplicitWithoutDominatingTheRow() {
    let view = AIChatSidebarThreadActivityView()
    XCTAssertEqual(view.statusTitle, "Working")

    let hostingView = NSHostingView(rootView: view)
    hostingView.layoutSubtreeIfNeeded()
    let size = hostingView.fittingSize

    XCTAssertGreaterThan(size.width, 40, "The indicator should include a visible status label")
    XCTAssertLessThan(size.width, 80, "The status should remain compact in the sidebar")
    XCTAssertLessThan(size.height, 28)
  }

  func testSidebarThreadActivityAnimationFollowsSelection() {
    XCTAssertTrue(AIChatSidebarThreadActivityView(isSelected: true).shouldAnimate)
    XCTAssertFalse(AIChatSidebarThreadActivityView(isSelected: false).shouldAnimate)
  }

  func testActivityPulseRunsOnCoreAnimationInsteadOfSwiftUIFrameClock() {
    let view = CoreAnimationActivityDotNSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5))

    view.configure(animates: true, color: .controlAccentColor)
    XCTAssertTrue(view.isAnimatingForTesting)

    view.configure(animates: false, color: .controlAccentColor)
    XCTAssertFalse(view.isAnimatingForTesting)
  }

  func testWorkingStatusKeepsElapsedTimeSeparateFromLongDestinationNames() async throws {
    for compact in [false, true] {
      for width: CGFloat in [280, 360, 560] {
        let view = AIChatTypingIndicatorView(
          startedAt: Date().addingTimeInterval(-75),
          lastEventAt: Date(),
          runtime: .codex,
          destinationTitle: "Remote Codex",
          connectionState: .connected,
          connectionDetail: nil,
          runID: "layout-test",
          streamingReply: "",
          reasoning: "",
          activities: [],
          compact: compact,
          onStop: {}
        )
        .frame(width: width, height: 100)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
          styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
          window.contentView = nil
          window.close()
        }
        for _ in 0..<5 {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(20))
        }
        let labels = chatAccessibilityNodes(in: host).compactMap { node -> AppKitPeriodicTextField? in
          guard case .view(let view) = node else { return nil }
          return view as? AppKitPeriodicTextField
        }
        let title = try XCTUnwrap(labels.first { $0.stringValue == "Remote Codex is working" })
        let elapsed = try XCTUnwrap(labels.first { $0 !== title })
        let titleFrame = title.convert(title.bounds, to: host)
        let elapsedFrame = elapsed.convert(elapsed.bounds, to: host)
        XCTAssertLessThanOrEqual(titleFrame.maxX + 4, elapsedFrame.minX,
          "The status title must not overlap elapsed time at \(width) points")
        XCTAssertEqual(titleFrame.midY, elapsedFrame.midY, accuracy: 2,
          "The title and timer must stay vertically aligned")
        XCTAssertGreaterThanOrEqual(elapsedFrame.width, 48)
        XCTAssertTrue(host.bounds.contains(elapsedFrame))
        XCTAssertLessThanOrEqual(host.fittingSize.width, width)
        if let directory = ProcessInfo.processInfo.environment["OPENORG_LAYOUT_SNAPSHOT_DIR"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.displayIfNeeded()
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let output = URL(fileURLWithPath: directory, isDirectory: true)
          try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
          try bitmap.representation(using: .png, properties: [:])?.write(
            to: output.appendingPathComponent("working-status-\(Int(width))-\(compact).png")
          )
        }
      }
    }
  }

  func testPeriodicStatusTextUsesAnAppKitLocalTimer() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let view = AppKitPeriodicTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 20))
    window.contentView = view

    view.configure(
      interval: 1,
      font: .systemFont(ofSize: 11),
      color: .secondaryLabelColor,
      textProvider: { _ in "Working locally" }
    )

    XCTAssertEqual(view.stringValue, "Working locally")
    XCTAssertTrue(view.isUpdatingForTesting)

    view.stopUpdating()
    XCTAssertFalse(view.isUpdatingForTesting)
  }

  func testChatThreadSwitchDoesNotRequestAutomaticScrolling() {
    let previous = AIChatScrollUpdate(
      threadID: UUID(),
      messageCount: 3,
      isSending: false
    )
    let next = AIChatScrollUpdate(
      threadID: UUID(),
      messageCount: 12,
      isSending: true
    )

    XCTAssertNil(next.automaticTarget(after: previous))
  }

  func testChatActivityWithinAThreadStillRequestsAutomaticScrolling() {
    let threadID = UUID()
    let idle = AIChatScrollUpdate(
      threadID: threadID,
      messageCount: 3,
      isSending: false
    )
    let appended = AIChatScrollUpdate(
      threadID: threadID,
      messageCount: 4,
      isSending: false
    )
    let sending = AIChatScrollUpdate(
      threadID: threadID,
      messageCount: 4,
      isSending: true
    )

    XCTAssertEqual(appended.automaticTarget(after: idle), .latestMessage)
    XCTAssertEqual(sending.automaticTarget(after: appended), .typingIndicator)
  }

  func testThreadFindMatchesVisibleMessageTextCaseInsensitively() {
    let first = AIChatMessage(role: .user, content: "Review the launch checklist")
    let second = AIChatMessage(role: .assistant, content: "The LAUNCH is ready.")
    let unrelated = AIChatMessage(role: .assistant, content: "No blockers remain.")
    let items = AIChatRoomTranscriptPresentation.items(
      messages: [first, second, unrelated],
      isSharedRoom: false
    )

    XCTAssertEqual(
      AIChatThreadSearch.matches(query: "launch", in: items),
      [
        AIChatThreadSearchMatch(
          messageID: first.id,
          scrollTargetID: first.id,
          rawMessageIndex: 0,
          anchorRawMessageIndex: 0
        ),
        AIChatThreadSearchMatch(
          messageID: second.id,
          scrollTargetID: second.id,
          rawMessageIndex: 1,
          anchorRawMessageIndex: 1
        ),
      ]
    )
    XCTAssertTrue(AIChatThreadSearch.matches(query: "   ", in: items).isEmpty)
  }

  func testThreadFindTargetsTheContainingSharedRoomRound() {
    let roundID = UUID()
    let trigger = AIChatMessage(
      role: .user,
      content: "Ask both agents",
      audienceDestinationIDs: ["codex", "openclaw"],
      roomRoundID: roundID
    )
    let codex = AIChatMessage(
      role: .assistant,
      content: "Codex found the migration detail.",
      authorDestinationID: "codex",
      roomRoundID: roundID
    )
    let openClaw = AIChatMessage(
      role: .assistant,
      content: "OpenClaw found another detail.",
      authorDestinationID: "openclaw",
      roomRoundID: roundID
    )
    let items = AIChatRoomTranscriptPresentation.items(
      messages: [trigger, codex, openClaw],
      isSharedRoom: true
    )

    XCTAssertEqual(
      AIChatThreadSearch.matches(query: "migration", in: items),
      [AIChatThreadSearchMatch(messageID: codex.id, scrollTargetID: roundID)]
    )
  }

  func testThreadFindComputesBoundedExpandedPageForLateLargeMessageMatch() async throws {
    let pageLimit = AIChatExpandedMessageBodyInput.pageCharacterLimit
    let message = AIChatMessage(
      role: .assistant,
      content: String(repeating: "x", count: pageLimit + 100)
        + " LATE-FIND-SENTINEL"
    )
    let inputs = [AIChatThreadSearchMessageInput(message)]
    let matches = await Task.detached {
      let candidates = AIChatThreadSearch.candidates(
        in: inputs,
        isSharedRoom: false
      )
      return AIChatThreadSearch.matches(query: "LATE-FIND-SENTINEL", in: candidates)
    }.value

    let match = try XCTUnwrap(matches.first)
    XCTAssertEqual(match.messageID, message.id)
    XCTAssertEqual(match.expandedBodyPageIndex, 1)
  }

  func testThreadFindProjectsLargeTranscriptInsideDetachedWorker() async throws {
    let messages = (0..<8_000).map { index in
      AIChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: index == 7_999 ? "LATE-PROJECTION-SENTINEL" : "Message \(index)",
        attachments: [AIChatAttachment(
          fileName: "attachment-\(index).txt",
          mimeType: "text/plain",
          data: Data()
        )]
      )
    }

    let matches = await Task.detached {
      let candidates = AIChatThreadSearch.candidates(in: messages, isSharedRoom: false)
      return AIChatThreadSearch.matches(query: "LATE-PROJECTION-SENTINEL", in: candidates)
    }.value

    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?.rawMessageIndex, 7_999)
  }

  func testLargeSharedRoomTranscriptGroupingRemainsResponsive() {
    var messages: [AIChatMessage] = []
    messages.reserveCapacity(6_000)
    for index in 0..<2_000 {
      let roundID = UUID()
      messages.append(AIChatMessage(
        role: .user,
        content: "Question \(index)",
        audienceDestinationIDs: ["codex", "openclaw"],
        roomRoundID: roundID
      ))
      messages.append(AIChatMessage(
        role: .assistant,
        content: "Codex response \(index)",
        authorDestinationID: "codex",
        roomRoundID: roundID
      ))
      messages.append(AIChatMessage(
        role: .assistant,
        content: "OpenClaw response \(index)",
        authorDestinationID: "openclaw",
        roomRoundID: roundID
      ))
    }

    let startedAt = CFAbsoluteTimeGetCurrent()
    let items = AIChatRoomTranscriptPresentation.items(
      messages: messages,
      isSharedRoom: true
    )
    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

    XCTAssertEqual(items.count, 2_000)
    XCTAssertLessThan(elapsed, 1)
  }

  func testChatScrollRestorationDefaultsUnsavedThreadsToMostRecentMessage() {
    let threadID = UUID()
    let unsaved = AIChatScrollRestoration(
      threadID: threadID,
      selectionGeneration: 1,
      savedPosition: nil
    )
    let saved = AIChatScrollRestoration(
      threadID: threadID,
      selectionGeneration: 1,
      savedPosition: 0.42
    )

    XCTAssertEqual(unsaved.position, 1)
    XCTAssertEqual(saved.position, 0.42, accuracy: 0.001)
  }

  func testChatScrollRestorationRestartsWhenThreadOrSelectionChanges() {
    let firstThreadID = UUID()
    let secondThreadID = UUID()
    let initial = AIChatScrollRestoration(
      threadID: firstThreadID,
      selectionGeneration: 1,
      savedPosition: nil
    )
    let sameSelection = AIChatScrollRestoration(
      threadID: firstThreadID,
      selectionGeneration: 1,
      savedPosition: 0.42
    )
    let reselectedThread = AIChatScrollRestoration(
      threadID: firstThreadID,
      selectionGeneration: 2,
      savedPosition: nil
    )
    let nextThread = AIChatScrollRestoration(
      threadID: secondThreadID,
      selectionGeneration: 3,
      savedPosition: nil
    )

    XCTAssertFalse(sameSelection.requiresNewRestoration(after: initial))
    XCTAssertTrue(reselectedThread.requiresNewRestoration(after: initial))
    XCTAssertTrue(nextThread.requiresNewRestoration(after: initial))
  }

  func testChatScrollGeometryClampsViewportBelowAResizedTranscript() throws {
    let scrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300)
    )
    let transcript = NSView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 350)
    )
    scrollView.documentView = transcript
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 700))

    let constrained = try XCTUnwrap(
      AIChatScrollGeometry.constrainedBounds(in: scrollView)
    )

    XCTAssertEqual(constrained.origin.y, 50, accuracy: 0.5)
  }

  func testJumpToBottomAppearsOnlyAboveLatestContent() {
    XCTAssertFalse(AIChatScrollVisibility(position: 0.4, hasContent: false).showsJumpToBottom)
    XCTAssertTrue(AIChatScrollVisibility(position: 0.4, hasContent: true).showsJumpToBottom)
    XCTAssertFalse(AIChatScrollVisibility(position: 0.99, hasContent: true).showsJumpToBottom)
    XCTAssertFalse(AIChatScrollVisibility(position: 1, hasContent: true).showsJumpToBottom)
  }

  func testScrollPositionOnlyUpdatesPresentationAcrossNearBottomBoundary() {
    let aboveLatest = AIChatScrollVisibility(position: 0.4, hasContent: true)
    let stillAboveLatest = AIChatScrollVisibility(position: 0.8, hasContent: true)
    let nearLatest = AIChatScrollVisibility(position: 0.99, hasContent: true)

    XCTAssertNil(aboveLatest.updatedNearBottomState(after: false))
    XCTAssertNil(stillAboveLatest.updatedNearBottomState(after: false))
    XCTAssertEqual(nearLatest.updatedNearBottomState(after: false), true)
    XCTAssertNil(nearLatest.updatedNearBottomState(after: true))
  }

  func testLargeTranscriptWindowOnlyMaterializesNewestPage() {
    let messages = (0..<1_000).map { index in
      AIChatMessage(role: .assistant, content: "Message \(index)")
    }

    let firstWindow = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: AIChatTranscriptWindow.initialLimit
    )

    XCTAssertEqual(firstWindow.visibleItems.count, 24)
    XCTAssertEqual(firstWindow.visibleChatBubbleCount, 24)
    XCTAssertEqual(firstWindow.visibleItems.first?.id, messages[976].id)
    XCTAssertEqual(firstWindow.visibleItems.last?.id, messages[999].id)
    XCTAssertEqual(firstWindow.earlierBatchCount, 40)
    XCTAssertTrue(firstWindow.hasEarlierMessages)
    XCTAssertFalse(firstWindow.contains(messages[0].id))
    XCTAssertTrue(firstWindow.contains(messages[999].id))

    let expandedWindow = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: firstWindow.nextDisplayLimit
    )
    XCTAssertEqual(firstWindow.nextDisplayLimit, 64)
    XCTAssertEqual(expandedWindow.visibleItems.count, 64)
    XCTAssertEqual(expandedWindow.visibleItems.first?.id, messages[936].id)
  }

  func testOffWindowFindRevealUsesCenteredBoundedTranscriptWindow() {
    let messages = (0..<10_000).map { index in
      AIChatMessage(role: .assistant, content: "Message \(index)")
    }
    let targetIndex = 1_234
    let window = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: AIChatTranscriptWindow.maximumDisplayLimit,
      anchor: AIChatTranscriptAnchor(
        itemID: messages[targetIndex].id,
        rawMessageIndex: targetIndex
      )
    )

    XCTAssertTrue(window.contains(messages[targetIndex].id))
    XCTAssertLessThanOrEqual(
      window.visibleChatBubbleCount,
      AIChatTranscriptWindow.maximumDisplayLimit
    )
    XCTAssertEqual(
      window.nextDisplayLimit,
      AIChatTranscriptWindow.maximumDisplayLimit
    )
    XCTAssertNotNil(window.earlierPageAnchor)
  }

  func testSharedRoomWindowBoundsRawGroupingAndDestinationsBeforeMount() {
    var messages: [AIChatMessage] = []
    let destinationIDs = (0..<100).map { "agent-\($0)" }
    for roundIndex in 0..<60 {
      let roundID = UUID()
      messages.append(AIChatMessage(
        role: .user,
        content: "Question \(roundIndex)",
        audienceDestinationIDs: destinationIDs,
        roomRoundID: roundID
      ))
      for destinationID in destinationIDs {
        messages.append(AIChatMessage(
          role: .assistant,
          content: "Response",
          authorDestinationID: destinationID,
          roomRoundID: roundID
        ))
      }
    }

    let window = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: true,
      displayLimit: AIChatTranscriptWindow.initialLimit
    )

    XCTAssertLessThanOrEqual(
      window.visibleChatBubbleCount,
      AIChatTranscriptWindow.initialLimit
    )
    XCTAssertTrue(window.hasEarlierMessages)
    XCTAssertTrue(window.visibleItems.allSatisfy {
      $0.visibleChatBubbleCount <= AIChatRoomRoundView.maximumVisibleDestinationCount + 1
    })
    XCTAssertEqual(AIChatTranscriptWindow.maximumRawMessageScanCount, 416)
  }

  func testLargeTranscriptWindowAlsoBoundsDisplayedContentBytes() {
    let largeBody = String(
      repeating: "x",
      count: AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit * 2
    )
    let messages = (0..<80).map { _ in
      AIChatMessage(role: .assistant, content: largeBody)
    }

    let firstWindow = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: AIChatTranscriptWindow.initialLimit
    )

    XCTAssertEqual(firstWindow.visibleChatBubbleCount, 8)
    XCTAssertEqual(
      firstWindow.displayedContentUTF8ByteCount,
      AIChatTranscriptWindow.initialDisplayedContentUTF8ByteLimit
    )
    XCTAssertEqual(firstWindow.visibleItems.first?.id, messages[72].id)
    XCTAssertEqual(firstWindow.earlierBatchCount, 40)

    let expandedWindow = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: firstWindow.nextDisplayLimit
    )
    XCTAssertEqual(expandedWindow.visibleChatBubbleCount, 48)
    XCTAssertEqual(expandedWindow.visibleItems.first?.id, messages[32].id)
    XCTAssertEqual(
      AIChatTranscriptWindow.displayedContentUTF8ByteLimit(
        forDisplayLimit: firstWindow.nextDisplayLimit
      ),
      AIChatTranscriptWindow.initialDisplayedContentUTF8ByteLimit
        + AIChatTranscriptWindow.pageSize
          * AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
  }

  func testLargeTranscriptWindowBoundsExactRowRealization() {
    let messages = (0..<1_000).map { index in
      AIChatMessage(role: .assistant, content: "Message \(index)")
    }
    let window = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: false,
      displayLimit: AIChatTranscriptWindow.initialLimit
    )
    let counter = TranscriptLayoutProbeCounter()
    let view = ScrollView {
      AIChatTranscriptStack(spacing: 0) {
        ForEach(window.visibleItems) { _ in
          TranscriptLayoutProbe(counter: counter)
            .frame(height: 24)
        }
      }
    }
    .frame(width: 500, height: 240)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 240)

    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(counter.realizedRows, 24)
  }

  func testTranscriptUsesExactGeometryForRowsBeyondTheViewport() {
    let counter = TranscriptLayoutProbeCounter()
    let view = ScrollView {
      AIChatTranscriptStack(spacing: 0) {
        ForEach(0..<120, id: \.self) { _ in
          TranscriptLayoutProbe(counter: counter)
            .frame(height: 24)
        }
      }
    }
    .frame(width: 500, height: 240)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 240)

    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(counter.realizedRows, 120)
  }

  func testMessageClipboardCopiesContentWithoutRoleChrome() {
    let message = AIChatMessage(
      role: .assistant,
      content: "First paragraph.\n\nSecond paragraph."
    )
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-chat-copy-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    XCTAssertTrue(AIChatMessageClipboard.copy(message, to: pasteboard))

    XCTAssertEqual(pasteboard.string(forType: .string), "First paragraph.\n\nSecond paragraph.")
  }

  func testCodeSnippetClipboardCopiesOnlyTheSnippetBody() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-chat-code-copy-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    XCTAssertTrue(AIChatMessageClipboard.copyCodeSnippet(
      lines: ["let answer = 42", "print(answer)"],
      to: pasteboard
    ))

    XCTAssertEqual(pasteboard.string(forType: .string), "let answer = 42\nprint(answer)")
  }

  func testAssistantMessagesRenderStructuredOrg2AndRepairCommonFormattingMistakes() {
    let raw = """
    * Does Codex have server mode?

    | Mode | Best use | Recommendation |
    |-------------------------------|
    | Codex Remote | Interactive work | Best starting point |

    ##+begin_src sh
    codex app-server --listen ws://127.0.0.1:4500
    ##+end_src
    """
    let presentation = AIChatMessageOrgPresentation(raw)

    XCTAssertTrue(presentation.usesStructuredRendering)
    XCTAssertTrue(presentation.normalizedText.contains("#+begin_src sh"))
    XCTAssertTrue(presentation.normalizedText.contains("#+end_src"))
    XCTAssertFalse(presentation.normalizedText.contains("##+begin_src"))
    let hline = presentation.normalizedText
      .split(separator: "\n")
      .map(String.init)
      .first(where: { $0.contains("+") && $0.allSatisfy { $0 == "|" || $0 == "+" || $0 == "-" } })
    XCTAssertEqual(hline?.filter { $0 == "+" }.count, 2)
    XCTAssertTrue(presentation.blocks.contains { block in
      if case .heading = block.rendered { return true }
      return false
    })
    XCTAssertTrue(presentation.blocks.contains { block in
      if case .table = block.rendered { return true }
      return false
    })
    XCTAssertTrue(presentation.blocks.contains { block in
      if case .source = block.rendered { return true }
      return false
    })

    let message = AIChatMessage(role: .assistant, content: raw)
    XCTAssertEqual(AIChatMessageClipboard.text(for: message), AIChatRichClipboard.alignedMessage(presentation.normalizedText))
  }

  func testVerticalWheelGesturesInsideRenderedTableRouteToTranscript() {
    let outerScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
    outerScrollView.hasVerticalScroller = true
    let transcript = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 1_200))
    outerScrollView.documentView = transcript

    let tableScrollView = NSScrollView(frame: NSRect(x: 20, y: 100, width: 600, height: 180))
    tableScrollView.hasHorizontalScroller = true
    tableScrollView.hasVerticalScroller = false
    let table = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 160))
    let cell = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
    table.addSubview(cell)
    tableScrollView.documentView = table
    transcript.addSubview(tableScrollView)

    XCTAssertIdentical(
      AIChatNestedScrollWheelRouting.outerScrollView(
        for: cell,
        deltaX: 0,
        deltaY: 12
      ),
      outerScrollView
    )
    XCTAssertNil(AIChatNestedScrollWheelRouting.outerScrollView(
      for: cell,
      deltaX: 12,
      deltaY: 0
    ))
    tableScrollView.hasVerticalScroller = true
    XCTAssertNil(AIChatNestedScrollWheelRouting.outerScrollView(
      for: cell,
      deltaX: 0,
      deltaY: 12
    ))
  }

  func testAssistantTableCellsFillTheTallestWrappedCellInEachRow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let tableSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/OrgDocumentRenderedBlocks.swift")
    let source = try String(contentsOf: tableSource, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        """
        .fixedSize(horizontal: false, vertical: true)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .background(cellBackground(
        """
      ),
      "Every cell background and divider must fill the GridRow height when a neighboring cell wraps"
    )
  }

  func testAssistantTablesOnlyDrawExplicitOrgHorizontalRules() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let tableSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/OrgDocumentRenderedBlocks.swift")
    let source = try String(contentsOf: tableSource, encoding: .utf8)
    let tableStart = try XCTUnwrap(source.range(of: "private struct RenderedTableView: View"))
    let tableEnd = try XCTUnwrap(
      source.range(of: "private struct RenderedTableAvailableWidthKey", range: tableStart.upperBound..<source.endIndex)
    )
    let renderedTableSource = source[tableStart.lowerBound..<tableEnd.lowerBound]

    XCTAssertFalse(
      renderedTableSource.contains(".overlay(alignment: .bottom)"),
      "Cell rows must not paint implicit horizontal dividers through AI chat table text"
    )
    XCTAssertFalse(
      renderedTableSource.contains("Divider()"),
      "Table cell separators must declare a vertical shape instead of relying on Divider orientation"
    )
    XCTAssertTrue(
      renderedTableSource.contains(".frame(width: 1)"),
      "Table columns should retain an explicitly vertical separator"
    )
    XCTAssertTrue(
      renderedTableSource.contains("case .separator:"),
      "Explicit Org table hlines should remain visible"
    )
  }

  func testAssistantTableColumnsFitOrdinaryFourColumnChatTables() {
    let rows: [OrgTableRow] = [
      .cells(["Line item", "Monthly quantity", "Unit price", "Annual reference"]),
      .cells([
        "Additional Company Unlocks, units 1,001–2,500",
        "1,500",
        "$0.96/unlock-month",
        "$17,280",
      ]),
    ]
    let widths = RenderedTableColumnWidths.make(
      rows: rows,
      visibleColumns: [0, 1, 2, 3]
    )

    XCTAssertEqual(widths.values.reduce(0, +), RenderedTableColumnWidths.preferredTotal, accuracy: 0.01)
    XCTAssertTrue(widths.values.allSatisfy { $0 >= RenderedTableColumnWidths.minimum })
    XCTAssertTrue(widths.values.allSatisfy { $0 <= RenderedTableColumnWidths.maximum })
  }

  func testAssistantTableKeepsCompactNaturalWidths() {
    let rows: [OrgTableRow] = [
      .cells(["Issue", "State"]),
      .cells(["APP-21298", "Deployed"]),
    ]
    let widths = RenderedTableColumnWidths.make(rows: rows, visibleColumns: [0, 1])

    XCTAssertEqual(widths[0], RenderedTableColumnWidths.minimum)
    XCTAssertEqual(widths[1], RenderedTableColumnWidths.minimum)
  }

  func testAssistantTableUsesWiderAvailableSpaceBeforeScrolling() {
    let rows: [OrgTableRow] = [
      .cells(["", "Annual quantity", "Unit price"]),
      .cells([
        "Company Unlocks with the corrected annual allowance and renewal reference",
        "26,400",
        "$1.1636/unlock-month",
      ]),
    ]
    let narrowWidths = RenderedTableColumnWidths.make(
      rows: rows,
      visibleColumns: [0, 1, 2],
      availableWidth: 360
    )
    let wideWidths = RenderedTableColumnWidths.make(
      rows: rows,
      visibleColumns: [0, 1, 2],
      availableWidth: 900
    )

    XCTAssertEqual(narrowWidths.values.reduce(0, +), 360, accuracy: 0.01)
    XCTAssertGreaterThan(wideWidths.values.reduce(0, +), 360)
    XCTAssertLessThanOrEqual(wideWidths.values.reduce(0, +), 900)
    XCTAssertGreaterThan(wideWidths[0] ?? 0, 260)
  }

  func testAssistantImageRepliesChooseTheMediaRendererWithoutOtherOrgBlocks() {
    for raw in [
      "[[file:/tmp/qr.png][QR code]]",
      "[[file:qr.png][QR code]]",
      "Scan this QR code:\n[[file:/tmp/qr.png][QR code]]",
      "![QR code](/tmp/qr.png)",
      "[[https://example.com/chart.png?version=2][Chart]]",
    ] {
      let prepared = AIChatMessagePresentationBuilder.prepare(
        AIChatMessagePresentationInput(.init(role: .assistant, content: raw))
      )
      XCTAssertTrue(prepared.value.org?.usesStructuredRendering == true, raw)
    }
    let code = AIChatMessageOrgPresentation("#+begin_src text\n[[file:/tmp/qr.png][QR code]]\n#+end_src")
    XCTAssertEqual(code.blocks.count, 1)
    guard case .source = code.blocks[0].rendered else { return XCTFail("Image examples in code must remain code") }
  }

  func testPlainAssistantMessagesKeepLightweightInlineRendering() {
    let presentation = AIChatMessageOrgPresentation("A short answer with *emphasis* and [[recipes.org2][a link]].")

    XCTAssertFalse(presentation.usesStructuredRendering)
    XCTAssertEqual(presentation.blocks.count, 1)
  }

  func testAttachmentOnlyMessageHasCopyableFallbackText() {
    let message = AIChatMessage(
      role: .user,
      content: "",
      attachments: [
        AIChatAttachment(
          fileName: "diagram.png",
          mimeType: "image/png",
          data: Data([0x01])
        )
      ]
    )

    XCTAssertEqual(AIChatMessageClipboard.text(for: message), "[Attachment: diagram.png]")
  }

  func testChatAttachmentPreviewClassifiesImagesPDFsAndTextDocuments() throws {
    let image = AIChatAttachment(
      fileName: "diagram.png",
      mimeType: "image/png",
      data: Data([0x01])
    )
    let pdf = AIChatAttachment(
      fileName: "report.bin",
      mimeType: "application/pdf",
      data: Data("%PDF-1.4".utf8)
    )
    let text = AIChatAttachment(
      fileName: "results.csv",
      mimeType: "application/octet-stream",
      data: Data("name,value\nalpha,1".utf8)
    )
    let binary = AIChatAttachment(
      fileName: "archive.zip",
      mimeType: "application/zip",
      data: Data([0x50, 0x4b, 0x03, 0x04, 0xff])
    )

    XCTAssertEqual(AIChatAttachmentPresentation.previewKind(for: image), .image)
    XCTAssertEqual(AIChatAttachmentPresentation.previewKind(for: pdf), .pdf)
    XCTAssertEqual(AIChatAttachmentPresentation.previewKind(for: text), .text)
    XCTAssertEqual(
      AIChatAttachmentPresentation.decodedText(data: try text.loadData()),
      "name,value\nalpha,1"
    )
    XCTAssertEqual(AIChatAttachmentPresentation.previewKind(for: binary), .unsupported)
  }

  func testAIChatStatusCardUsesOneDynamicStatusLine() {
    let activeRun = AIChatTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )
    let startingRun = AIChatTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: nil,
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(activeRun.statusTitle, "OpenClaw is working")
    XCTAssertEqual(startingRun.statusTitle, "Starting OpenClaw")

    let runningTool = AIChatTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [
        AIChatRunActivity(
          id: "tool-1",
          runID: "run-123",
          kind: .tool,
          title: "bash",
          status: .running
        )
      ],
      compact: false,
      onStop: {}
    )
    XCTAssertEqual(runningTool.statusTitle, "Running shell command")
  }

  func testStatusCardUsesConfiguredDirectProviderName() {
    let view = AIChatTypingIndicatorView(
      startedAt: Date(),
      runtime: .openClaw,
      destinationTitle: "Anthropic",
      connectionState: .connected,
      connectionDetail: nil,
      runID: nil,
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(view.statusTitle, "Starting Anthropic")
  }

  func testAIChatStatusCardSurfacesQuietAndStalledRuns() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let recentlyActive = AIChatTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-30),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )
    let quiet = AIChatTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-3 * 60),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )
    let stalled = AIChatTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-12 * 60),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(recentlyActive.statusTitle(now: now), "OpenClaw is working")
    XCTAssertNil(recentlyActive.statusDetail(now: now))
    XCTAssertEqual(quiet.statusTitle(now: now), "Waiting for OpenClaw")
    XCTAssertEqual(quiet.statusDetail(now: now), "No new activity for 3m. It may still be working.")
    XCTAssertEqual(stalled.statusTitle(now: now), "OpenClaw may be stalled")
    XCTAssertEqual(
      stalled.statusDetail(now: now),
      "No new activity for 12m. The run is saved; the connection or agent may be stalled."
    )
  }

  func testOpenCodeStatusCardDoesNotCallALiveQuietProcessStalled() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let view = AIChatTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now.addingTimeInterval(-12 * 60),
      runtime: .openCode,
      destinationTitle: "OpenCode on press.local",
      connectionState: .connected,
      connectionDetail: nil,
      runID: "ses_123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(view.statusTitle(now: now), "Waiting for OpenCode on press.local")
    XCTAssertEqual(
      view.statusDetail(now: now),
      "No new output for 12m. OpenCode is still running; long tool calls can be quiet."
    )
  }

  func testAIChatStatusCardExplainsSavedRunWhileReconnecting() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let reconnecting = AIChatTypingIndicatorView(
      startedAt: now.addingTimeInterval(-30 * 60),
      lastEventAt: now,
      connectionState: .reconnecting,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertEqual(reconnecting.statusTitle(now: now), "Reconnecting to OpenClaw")
    XCTAssertEqual(
      reconnecting.statusDetail(now: now),
      "The run is saved and will reconnect without being sent twice."
    )
    XCTAssertTrue(reconnecting.canStop)
  }

  func testAIChatStatusCardAllowsStoppingBeforeAConnectionOrRunIDExists() {
    let connecting = AIChatTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connecting,
      connectionDetail: nil,
      runID: nil,
      streamingReply: "",
      reasoning: "",
      activities: [],
      compact: false,
      onStop: {}
    )

    XCTAssertTrue(connecting.canStop)
  }

  func testAIChatStatusCardStaysBoundedWithStructuredToolOutput() {
    let result = #"{"content":[{"text":"{\"results\":[{\"path\":\"memory/2026-04-01.md\",\"text\":\""#
      + String(repeating: "unformatted result ", count: 100)
      + #"\"}]}"}]}"#
    let view = AIChatTypingIndicatorView(
      startedAt: Date(),
      connectionState: .connected,
      connectionDetail: nil,
      runID: "run-123",
      streamingReply: "",
      reasoning: "Checking recent notes before answering.",
      activities: [
        AIChatRunActivity(
          id: "tool-1",
          runID: "run-123",
          kind: .tool,
          title: "memory_search",
          detail: result,
          status: .succeeded
        )
      ],
      compact: false,
      onStop: {}
    )
    .frame(width: 540, alignment: .leading)
    let hostingView = NSHostingView(rootView: view)

    hostingView.frame = NSRect(x: 0, y: 0, width: 540, height: 1)
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertLessThanOrEqual(hostingView.fittingSize.width, 540)
    XCTAssertLessThan(hostingView.fittingSize.height, 260)
  }

  func testActivityFeedGroupsRepeatedShellEventsAndHidesRawCompletionMetadata() throws {
    let activities = (0..<10).map { index in
      AIChatRunActivity(
        id: "tool-\(index)",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: index == 0
          ? #"{"durationMs":963,"exitCode":5,"status":"failed"}"#
          : #"{"durationMs":121,"exitCode":0,"status":"completed"}"#,
        status: index == 0 ? .failed : .succeeded
      )
    }

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.title, "10 shell commands")
    XCTAssertEqual(item.detail, "9 completed · 1 failed")
    XCTAssertNil(item.latestDetail)
    XCTAssertEqual(item.status, .succeeded)
    XCTAssertFalse(item.detail?.contains("durationMs") == true)
  }

  func testActivityFeedPreservesTheLatestRunningCommandInsideAGroup() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let activities = [
      AIChatRunActivity(
        id: "tool-1",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"npm run build"}"#,
        status: .succeeded,
        updatedAt: now.addingTimeInterval(-5)
      ),
      AIChatRunActivity(
        id: "tool-2",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"swift test --filter OpenClawChatLayoutTests"}"#,
        status: .running,
        updatedAt: now
      )
    ]

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.title, "2 shell commands")
    XCTAssertEqual(item.detail, "1 completed · 1 running")
    XCTAssertEqual(item.latestDetail, "swift test --filter OpenClawChatLayoutTests")
    XCTAssertEqual(item.status, .running)
    XCTAssertEqual(item.updatedAt, now)
  }

  func testActivityFeedPrefersRunningDetailOverANewerCompletedCommand() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let activities = [
      AIChatRunActivity(
        id: "tool-1",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"long-running verification"}"#,
        status: .running,
        updatedAt: now.addingTimeInterval(-10)
      ),
      AIChatRunActivity(
        id: "tool-2",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        detail: #"{"cmd":"quick status check"}"#,
        status: .succeeded,
        updatedAt: now
      )
    ]

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.latestDetail, "long-running verification")
    XCTAssertEqual(item.status, .running)
    XCTAssertEqual(item.updatedAt, now.addingTimeInterval(-10))
  }

  func testActivityFeedOnlyMarksAGroupFailedWhenFailuresAreTheMajority() throws {
    let activities = (0..<10).map { index in
      AIChatRunActivity(
        id: "tool-\(index)",
        runID: "run-1",
        kind: .tool,
        title: "bash",
        status: index < 6 ? .failed : .succeeded
      )
    }

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: activities).first)
    XCTAssertEqual(item.detail, "4 completed · 6 failed")
    XCTAssertEqual(item.status, .failed)
  }

  func testActivityUpdateKeepsUsefulArgumentsWhenResultOnlyContainsMetadata() {
    let started = AIChatRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "bash",
      detail: #"{"cmd":"rg -n TODO notes"}"#,
      status: .running
    )
    let finished = AIChatRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "bash",
      detail: #"{"durationMs":42,"exitCode":0,"status":"completed"}"#,
      status: .succeeded
    )

    let merged = AIChatActivityFeed.merging(started, with: finished)
    XCTAssertEqual(merged.detail, "rg -n TODO notes")
    XCTAssertEqual(merged.status, .succeeded)
  }

  func testGatewayPreambleItemsBecomeReplaceableProgressActivities() throws {
    let initial = try XCTUnwrap(OpenClawGatewayClient.activity(from: [
      "runId": "run-1",
      "stream": "item",
      "data": [
        "kind": "preamble",
        "itemId": "item-1",
        "progressText": "Checking the relevant files."
      ]
    ]))
    let update = try XCTUnwrap(OpenClawGatewayClient.activity(from: [
      "runId": "run-1",
      "stream": "item",
      "data": [
        "kind": "preamble",
        "itemId": "item-1",
        "progressText": "Checking the relevant files and tests."
      ]
    ]))

    XCTAssertEqual(initial.id, "preamble:item-1")
    XCTAssertEqual(initial.kind, .reasoning)
    XCTAssertEqual(initial.title, "Progress update")
    XCTAssertEqual(initial.detail, "Checking the relevant files.")
    XCTAssertEqual(initial.status, .succeeded)
    XCTAssertEqual(update.id, initial.id)

    let merged = AIChatActivityFeed.merging(initial, with: update)
    XCTAssertEqual(merged.detail, "Checking the relevant files and tests.")

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: [merged]).first)
    XCTAssertEqual(item.kind, .reasoning)
    XCTAssertEqual(item.title, "Progress update")
    XCTAssertEqual(item.detail, "Checking the relevant files and tests.")
  }

  func testGatewayAssistantCommentaryAccumulatesAsPreambleProgress() throws {
    var accumulatedTextByItemID: [String: String] = [:]
    let first = try XCTUnwrap(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "commentary",
          "itemId": "item-1",
          "text": "",
          "delta": "Checking the relevant "
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))
    let second = try XCTUnwrap(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "commentary",
          "itemId": "item-1",
          "text": "",
          "delta": "files and tests."
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))

    XCTAssertEqual(first.id, "preamble:item-1")
    XCTAssertEqual(first.kind, .reasoning)
    XCTAssertEqual(first.detail, "Checking the relevant")
    XCTAssertEqual(second.id, first.id)
    XCTAssertEqual(second.detail, "Checking the relevant files and tests.")
  }

  func testGatewayAssistantCommentaryAcceptsCumulativeReplacementSnapshots() throws {
    var accumulatedTextByItemID = ["run-1:item-1": "Old progress"]
    let replacement = try XCTUnwrap(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "commentary",
          "itemId": "item-1",
          "text": "A corrected progress update.",
          "delta": "",
          "replace": true
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))

    XCTAssertEqual(replacement.detail, "A corrected progress update.")
    XCTAssertEqual(accumulatedTextByItemID["run-1:item-1"], "A corrected progress update.")
  }

  func testGatewayIgnoresNonProgressAssistantText() {
    var accumulatedTextByItemID: [String: String] = [:]
    XCTAssertNil(OpenClawGatewayClient.commentaryActivity(
      from: [
        "runId": "run-1",
        "stream": "assistant",
        "data": [
          "phase": "final_answer",
          "itemId": "item-1",
          "delta": "This belongs in the final answer."
        ]
      ],
      accumulatedTextByItemID: &accumulatedTextByItemID
    ))
    XCTAssertTrue(accumulatedTextByItemID.isEmpty)
  }

  func testGatewayExtractsProviderTokenUsageFromFinalMessage() throws {
    let usage = try XCTUnwrap(OpenClawGatewayClient.tokenUsage(from: [
      "message": [
        "content": "Done",
        "usage": [
          "input": 450,
          "cacheRead": 300,
          "output": 25,
          "totalTokens": 475,
        ],
      ],
    ]))
    XCTAssertEqual(usage.inputTokens, 450)
    XCTAssertEqual(usage.cachedInputTokens, 300)
    XCTAssertEqual(usage.outputTokens, 25)
    XCTAssertEqual(usage.totalTokens, 475)
  }

  func testGatewayRecognizesContextCompactionLifecycleEvents() {
    XCTAssertTrue(OpenClawGatewayClient.isContextCompaction([
      "stream": "compaction",
      "data": ["phase": "start"],
    ]))
    XCTAssertTrue(OpenClawGatewayClient.isContextCompaction([
      "stream": "compaction",
      "data": ["phase": "end", "completed": true],
    ]))
    XCTAssertFalse(OpenClawGatewayClient.isContextCompaction([
      "stream": "lifecycle",
      "data": ["phase": "finishing"],
    ]))
  }

  func testActivityFeedHidesOversizedStructuredToolResults() throws {
    let payload = """
      {"content":[{"text":"\(String(repeating: "Fetched page content. ", count: 30))"}],"status":200,"contentType":"text/html"}
      """
    let activity = AIChatRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "web_fetch",
      detail: payload,
      status: .succeeded
    )

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: [activity]).first)
    XCTAssertEqual(item.title, "Web fetch")
    XCTAssertNil(item.detail)
  }

  func testActivityFeedNeverShowsSmallStructuredToolResultsAsRawJSON() throws {
    let activity = AIChatRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "memory_search",
      detail: #"{"content":[{"text":"{\"results\":[{\"path\":\"memory.org\"}]}"}]}"#,
      status: .succeeded
    )

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: [activity]).first)
    XCTAssertEqual(item.title, "Memory search")
    XCTAssertNil(item.detail)
  }

  func testActivityFeedFormatsSearchArgumentsForPeople() throws {
    let activity = AIChatRunActivity(
      id: "tool-1",
      runID: "run-1",
      kind: .tool,
      title: "memory_search",
      detail: #"{"query":"monthly revenue"}"#,
      status: .running
    )

    let item = try XCTUnwrap(AIChatActivityFeed.items(from: [activity]).first)
    XCTAssertEqual(item.detail, "Searching for \u{201c}monthly revenue\u{201d}")
  }

  func testProgressPresentationHidesStructuredReasoningAndBoundsProse() {
    XCTAssertNil(AIChatProgressPresentation.reasoningText(from: #"{"results":[1,2,3]}"#))

    let prose = String(repeating: "Checking relevant context. ", count: 100)
    let presented = AIChatProgressPresentation.reasoningText(from: prose)
    XCTAssertNotNil(presented)
    XCTAssertLessThanOrEqual(presented?.count ?? .max, 1_200)

    let omittedSentinel = "OMITTED-LARGE-REASONING-SENTINEL"
    let largeReasoning = String(repeating: "Working through bounded context. ", count: 100_000)
      + omittedSentinel
    let bounded = AIChatProgressPresentation.reasoningText(from: largeReasoning)
    XCTAssertEqual(AIChatProgressPresentation.maximumReasoningInputUTF8ByteCount, 8 * 1_024)
    XCTAssertLessThanOrEqual(bounded?.count ?? .max, 1_200)
    XCTAssertTrue(bounded?.hasSuffix("…") == true)
    XCTAssertFalse(bounded?.contains(omittedSentinel) == true)
    XCTAssertNil(AIChatProgressPresentation.reasoningText(
      from: "{\"results\":[" + String(repeating: "0,", count: 100_000) + "0]}"
    ))
    XCTAssertFalse(AIChatProgressPresentation.containsNonWhitespace(
      String(repeating: " \n\t", count: 100_000)
    ))
  }

  func testLiveProgressShowsLatestReadableUpdateByDefault() throws {
    let progress = """
      I’ll inspect the current delivery model and locate the relevant code.

      The source repository is available. I’m checking the Mac app package now.

      The implementation is taking shape as an append-only inbox.
      """

    XCTAssertEqual(
      AIChatProgressPresentation.liveText(from: progress, showsAll: false),
      "The implementation is taking shape as an append-only inbox."
    )
    XCTAssertEqual(
      AIChatProgressPresentation.liveText(from: progress, showsAll: true),
      progress
    )
    XCTAssertTrue(AIChatProgressPresentation.hasEarlierLiveText(progress))
  }

  func testLiveProgressBoundsOneOversizedUpdate() throws {
    let progress = String(repeating: "Validating the implementation. ", count: 40)
    let collapsed = try XCTUnwrap(
      AIChatProgressPresentation.liveText(from: progress, showsAll: false)
    )

    XCTAssertLessThanOrEqual(collapsed.count, 320)
    XCTAssertTrue(collapsed.hasSuffix("\u{2026}"))
    XCTAssertTrue(AIChatProgressPresentation.hasEarlierLiveText(progress))
  }

  func testLiveProgressPresentationComputesTextAndDisclosureTogether() throws {
    let progress = "First update.\n\nSecond update."
    let presentation = try XCTUnwrap(
      AIChatProgressPresentation.liveTextPresentation(from: progress, showsAll: false)
    )

    XCTAssertEqual(presentation.text, "Second update.")
    XCTAssertTrue(presentation.hasEarlierText)
  }

  func testAssistantResponseTraceRoundTripsWithTranscriptMessage() throws {
    let trace = AIChatResponseTrace(
      reasoning: "Checking the relevant files.",
      activities: [
        AIChatRunActivity(
          id: "tool-1",
          runID: "run-1",
          kind: .tool,
          title: "read_file",
          detail: "notes/plan.org2",
          status: .succeeded
        )
      ]
    )
    let message = AIChatMessage(
      role: .assistant,
      content: "The plan is ready.",
      responseTrace: trace
    )

    let decoded = try JSONDecoder().decode(
      AIChatMessage.self,
      from: JSONEncoder().encode(message)
    )
    XCTAssertEqual(decoded.responseTrace, trace)
  }
}
