import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor DocumentMutationTestGate {
  private var isOpen = false
  private var arrivals = 0
  private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func arriveAndWait() async {
    arrivals += 1
    resumeArrivalWaiters()
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      openWaiters.append(continuation)
    }
  }

  func waitForArrivals(_ count: Int) async {
    guard arrivals < count else { return }
    await withCheckedContinuation { continuation in
      arrivalWaiters.append((count, continuation))
    }
  }

  func open() {
    isOpen = true
    openWaiters.forEach { $0.resume() }
    openWaiters = []
  }

  private func resumeArrivalWaiters() {
    var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
    for (count, continuation) in arrivalWaiters {
      if arrivals >= count {
        continuation.resume()
      } else {
        remaining.append((count, continuation))
      }
    }
    arrivalWaiters = remaining
  }
}

private actor DocumentMutationOrderRecorder {
  private var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }

  var snapshot: [String] { values }
}

final class WorkspaceDocumentMutationLaneTests: XCTestCase {
  func testSameDocumentMutationsRemainFIFOAcrossSuspension() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = fixture.root.appendingPathComponent("notes/shared.org")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "base\n".write(to: file, atomically: true, encoding: .utf8)

    let lane = WorkspaceDocumentMutationLane()
    let gate = DocumentMutationTestGate()
    let order = DocumentMutationOrderRecorder()
    let first: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [file.path]
    ) { execution in
      await order.append("first-start")
      let snapshot = try await execution.readSnapshot(at: file)
      await gate.arriveAndWait()
      try await execution.commit("first\n", over: snapshot, writer: Self.writer)
      await order.append("first-finish")
    }
    await gate.waitForArrivals(1)
    let second: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [file.path]
    ) { execution in
      await order.append("second-start")
      let snapshot = try await execution.readSnapshot(at: file)
      try await execution.commit(snapshot.text + "second\n", over: snapshot, writer: Self.writer)
      await order.append("second-finish")
    }

    await Task.yield()
    let orderWhileFirstSuspended = await order.snapshot
    XCTAssertEqual(orderWhileFirstSuspended, ["first-start"])
    await gate.open()
    try await first.value
    try await second.value
    let finalOrder = await order.snapshot
    XCTAssertEqual(
      finalOrder,
      ["first-start", "first-finish", "second-start", "second-finish"]
    )
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\nsecond\n")
  }

  func testDifferentDocumentsRunConcurrentlyButRootReservationOrdersDescendants() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstURL = fixture.root.appendingPathComponent("a.org")
    let secondURL = fixture.root.appendingPathComponent("b.org")
    try "a\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "b\n".write(to: secondURL, atomically: true, encoding: .utf8)

    let lane = WorkspaceDocumentMutationLane()
    let parallelGate = DocumentMutationTestGate()
    let first: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [firstURL.path]
    ) { _ in
      await parallelGate.arriveAndWait()
    }
    let second: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [secondURL.path]
    ) { _ in
      await parallelGate.arriveAndWait()
    }
    await parallelGate.waitForArrivals(2)
    await parallelGate.open()
    try await first.value
    try await second.value

    let rootGate = DocumentMutationTestGate()
    let order = DocumentMutationOrderRecorder()
    let rootOperation: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [fixture.root.path]
    ) { _ in
      await order.append("root")
      await rootGate.arriveAndWait()
    }
    await rootGate.waitForArrivals(1)
    let descendant: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [firstURL.path]
    ) { _ in
      await order.append("file")
    }
    await Task.yield()
    let orderWhileRootSuspended = await order.snapshot
    XCTAssertEqual(orderWhileRootSuspended, ["root"])
    await rootGate.open()
    try await rootOperation.value
    try await descendant.value
    let finalOrder = await order.snapshot
    XCTAssertEqual(finalOrder, ["root", "file"])
  }

  func testCommitRejectsExternalReplacementAfterSnapshot() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let file = fixture.root.appendingPathComponent("conflict.org")
    try "original\n".write(to: file, atomically: true, encoding: .utf8)

    let lane = WorkspaceDocumentMutationLane()
    await lane.setEventHookForTesting { event in
      guard case .willCommit(_, let path, _) = event, path == file.path else { return }
      try? "external\n".write(to: file, atomically: true, encoding: .utf8)
    }

    do {
      try await lane.perform(rootPath: fixture.root.path, resourcePaths: [file.path]) { execution in
        let snapshot = try await execution.readSnapshot(at: file)
        try await execution.commit("ours\n", over: snapshot, writer: Self.writer)
      }
      XCTFail("Expected exact-digest CAS conflict")
    } catch let error as WorkspaceDocumentMutationError {
      XCTAssertEqual(error, .fileChanged(file: file.path))
    }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external\n")
  }

  func testExecutionRejectsUndeclaredDocument() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let declared = fixture.root.appendingPathComponent("declared.org")
    let undeclared = fixture.root.appendingPathComponent("undeclared.org")
    try "declared\n".write(to: declared, atomically: true, encoding: .utf8)
    try "undeclared\n".write(to: undeclared, atomically: true, encoding: .utf8)

    let lane = WorkspaceDocumentMutationLane()
    do {
      try await lane.perform(rootPath: fixture.root.path, resourcePaths: [declared.path]) { execution in
        _ = try await execution.readSnapshot(at: undeclared)
      }
      XCTFail("Expected undeclared-resource rejection")
    } catch let error as WorkspaceDocumentMutationError {
      XCTAssertEqual(error, .undeclaredResource(file: undeclared.path))
    }
  }

  func testSymlinkSwapAfterAdmissionFailsClosed() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.container) }
    let insideDirectory = fixture.root.appendingPathComponent("inside", isDirectory: true)
    let outsideDirectory = fixture.container.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: insideDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let insideFile = insideDirectory.appendingPathComponent("note.org")
    let outsideFile = outsideDirectory.appendingPathComponent("note.org")
    try "inside\n".write(to: insideFile, atomically: true, encoding: .utf8)
    try "outside\n".write(to: outsideFile, atomically: true, encoding: .utf8)
    let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: insideDirectory)
    let aliasedFile = alias.appendingPathComponent("note.org")

    let lane = WorkspaceDocumentMutationLane()
    let gate = DocumentMutationTestGate()
    let operation: Task<Void, Error> = try await lane.enqueue(
      rootPath: fixture.root.path,
      resourcePaths: [aliasedFile.path]
    ) { execution in
      await gate.arriveAndWait()
      _ = try await execution.readSnapshot(at: aliasedFile)
    }
    await gate.waitForArrivals(1)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outsideDirectory)
    await gate.open()

    do {
      try await operation.value
      XCTFail("Expected symlink escape rejection")
    } catch let error as WorkspaceDocumentMutationError {
      guard case .outsideCorpus(let path, let root) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, outsideFile.path)
      XCTAssertEqual(root, fixture.root.path)
    }
    XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside\n")
  }

  func testCanonicalWriterArchitectureKeepsOrdinaryDocumentsBehindTheLane() throws {
    let testURL = URL(fileURLWithPath: #filePath)
    let packageRoot = testURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let storeURL = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/WorkspaceStore.swift")
    let source = try SplitSourceText.read(storeURL)

    for forbidden in [
      "updatedSource.write(to:",
      "content.write(to: destination",
      "result.text.write(to:",
      "Self.writeFileText(",
      "try Self.replaceSourceRange(",
      "try Self.swapSourceRanges(",
      "try Self.deleteSourceRangeCleaningAdjacentBlank(",
    ] {
      XCTAssertFalse(source.contains(forbidden), "Direct canonical writer escaped the lane: \(forbidden)")
    }

    let directWriteLines = source.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { $0.contains(".write(") }
    let classifiedDirectWriteMarkers = [
      // One-shot starter-corpus initialization. It is admitted only after the
      // destination has been proven empty, before that corpus can be opened.
      "(configData + Data(",
      "(inbox + \"\\n\").write(",
      "(welcome + \"\\n\").write(",
      // User-selected publication/export artifacts, never canonical corpus
      // Org source.
      "Org2PDFExporter.validated(pdf).write(",
      "Data(html.utf8).write(",
      // Capture attachment staging is a unique hidden temporary file; its
      // promotion and daily-note commit occur while the lane is held.
      "data.write(to: temporaryURL",
      // Non-Org app stylesheet customization.
      "template.write(to: stylesheetURL",
      // AI chat JSON machine state, explicitly outside the ordinary document
      // mutation lane.
      "data.write(to: url, options: [.atomic])",
      // Per-host chat presence records (heartbeat and live turn progress),
      // machine state beside the AI chat store rather than corpus documents.
      "AIChatLiveHostDirectory.write(record, transcriptURL:",
      // Ephemeral plugin script in a unique temporary directory.
      "source.body.write(to: scriptURL",
      // Workspace-authored agent skill source. This is non-Org Markdown,
      // restricted to a validated .agents/skills descendant, and refuses to
      // replace an existing file.
      "Data(source.utf8).write(to: destination, options: .withoutOverwriting)",
      // The sole ordinary-document writer and its recovery backup sink.
      "text.write(to: url, atomically: true, encoding: .utf8)",
      "previousText.write(to: backupURL",
    ]
    XCTAssertEqual(directWriteLines.count, 15, "Classify every new direct filesystem write")
    for line in directWriteLines {
      XCTAssertTrue(
        classifiedDirectWriteMarkers.contains(where: line.contains),
        "Unclassified direct filesystem write: \(line)"
      )
    }

    // These commands mutate ordinary corpus documents through the TypeScript
    // implementation. Their enclosing Store flows must reserve the same lane;
    // durable .org2 machine-state/chat commands are intentionally out of scope.
    for functionName in [
      "refileRenderedEntry",
      "archiveRenderedEntry",
      "performSyncAndStageSource",
      "refreshSelectedDataNotebook",
      "linkifyCurrentFile",
      "requestRecalculateRenderedTableFormulas",
      "runOrgCrypt",
      "persistGoogleDrivePublication",
      "saveExternalThreadToOrg2",
      "applyAIChatLocalEditReplacements",
      "encryptOrgCryptSubtreesAfterExplicitSave",
    ] {
      let body = try XCTUnwrap(functionBody(named: functionName, in: source))
      XCTAssertTrue(
        body.contains("performDocumentMutation"),
        "\(functionName) must reserve WorkspaceDocumentMutationLane"
      )
    }
  }

  private static let writer: WorkspaceDocumentMutationExecution.SafeWriter = {
    replacement, url, _ in
    try replacement.write(to: url, atomically: true, encoding: .utf8)
  }

  private func makeFixture() throws -> (container: URL, root: URL) {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("workspace-document-lane-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (container, root)
  }

  private func functionBody(named name: String, in source: String) -> String? {
    guard let start = source.range(of: "func \(name)(") else { return nil }
    var depth = 0
    var sawOpeningBrace = false
    var index = start.lowerBound
    while index < source.endIndex {
      let character = source[index]
      if character == "{" {
        depth += 1
        sawOpeningBrace = true
      } else if character == "}" {
        depth -= 1
        if sawOpeningBrace, depth == 0 {
          return String(source[start.lowerBound...index])
        }
      }
      index = source.index(after: index)
    }
    return nil
  }
}
