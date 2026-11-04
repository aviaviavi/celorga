import AppKit
import Foundation
import SwiftUI

/// One job from `celorga job list --json` (`celorga:background-job:v1`, see
/// src/backgroundJob.ts). Only the fields the composer row needs are decoded.
public struct AIChatBackgroundJob: Decodable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let state: String
  public let running: Bool
  public let threadID: String?
  public let createdAt: String
}

public enum AIChatBackgroundJobsError: LocalizedError, Equatable {
  case unsupportedSchema(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let schema): "Unsupported background job list: \(schema)."
    }
  }
}

/// Reads a thread's running jobs through the Celorga CLI, which owns job
/// state and process liveness; the app only presents the result.
public enum AIChatBackgroundJobs {
  static let listSchema = "celorga:background-jobs:v1"
  /// Refresh cadence while the chat is visible and the app is active.
  static let runningRefreshInterval: Duration = .seconds(5)
  static let idleRefreshInterval: Duration = .seconds(20)

  private struct ListEnvelope: Decodable {
    let schema: String
    let jobs: [AIChatBackgroundJob]
  }

  public static func listArguments(threadID: UUID, corpusRoot: URL) -> [String] {
    [
      "job", "list", "--thread", threadID.uuidString.lowercased(),
      "--dir", corpusRoot.standardizedFileURL.path, "--json",
    ]
  }

  public static func stopArguments(jobID: String, corpusRoot: URL) -> [String] {
    ["job", "stop", jobID, "--apply", "--json", "--dir", corpusRoot.standardizedFileURL.path]
  }

  /// Running jobs that report into `threadID`, oldest first.
  public static func runningJobs(from data: Data, threadID: UUID) throws -> [AIChatBackgroundJob] {
    let envelope = try JSONDecoder().decode(ListEnvelope.self, from: data)
    guard CelorgaNames.schemaMatches(envelope.schema, listSchema) else {
      throw AIChatBackgroundJobsError.unsupportedSchema(envelope.schema)
    }
    let thread = threadID.uuidString.lowercased()
    return envelope.jobs
      .filter { $0.running && $0.threadID?.lowercased() == thread }
      .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
  }

  /// "1 job running · Build" or "3 jobs running · Build and 2 more".
  public static func summary(for jobs: [AIChatBackgroundJob]) -> String? {
    guard let first = jobs.first else { return nil }
    let label = first.label.trimmingCharacters(in: .whitespacesAndNewlines)
    if jobs.count == 1 { return label.isEmpty ? "1 job running" : "1 job running · \(label)" }
    let others = jobs.count - 1
    return label.isEmpty
      ? "\(jobs.count) jobs running"
      : "\(jobs.count) jobs running · \(label) and \(others) more"
  }
}

/// A compact row above the composer while the selected chat has running jobs.
/// It polls the CLI off the main actor only while visible and the app is active.
struct AIChatBackgroundJobsBar: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var jobs: [AIChatBackgroundJob] = []
  @State private var jobsThreadID: UUID?
  @State private var stoppingJobIDs: Set<String> = []
  @State private var refreshGeneration = 0
  @State private var stopError: String?
  let compact: Bool

  private struct RefreshKey: Equatable {
    let threadID: UUID?
    let corpusRoot: String?
    let turnActive: Bool
    let generation: Int
  }

  var body: some View {
    let threadID = store.selectedAIChatThreadID
    let corpusRoot = store.corpusRoot
    let visibleJobs = jobsThreadID == threadID ? jobs : []
    Group {
      if let summary = AIChatBackgroundJobs.summary(for: visibleJobs), let corpusRoot {
        row(summary: summary, jobs: visibleJobs, corpusRoot: corpusRoot)
      }
    }
    .task(id: RefreshKey(
      threadID: threadID,
      corpusRoot: corpusRoot?.path,
      turnActive: threadID.map { store.aiChatSendingThreadIDs.contains($0) } ?? false,
      generation: refreshGeneration
    )) {
      await poll(threadID: threadID, corpusRoot: corpusRoot)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshGeneration &+= 1
    }
  }

  private func row(summary: String, jobs: [AIChatBackgroundJob], corpusRoot: URL) -> some View {
    HStack(spacing: 8) {
      // A static symbol: a spinner would redraw the chat for as long as a dev server runs.
      Image(systemName: "terminal")
        .imageScale(.small)
      Text(summary)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .help(jobs.map(\.label).joined(separator: "\n"))
      if let stopError {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .help(stopError)
      }
      Spacer(minLength: 4)
      if jobs.count == 1, let job = jobs.first {
        stopButton(jobs: [job], corpusRoot: corpusRoot)
      } else {
        Menu("Stop") {
          ForEach(jobs) { job in
            Button(job.label) { stop([job], corpusRoot: corpusRoot) }
          }
          Divider()
          Button("Stop All") { stop(jobs, corpusRoot: corpusRoot) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!stoppingJobIDs.isDisjoint(with: jobs.map(\.id)))
      }
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(WorkspaceDesign.surfaceBackground, in: Capsule())
    .overlay(Capsule().stroke(WorkspaceDesign.hairline))
    .padding(.horizontal, compact ? 10 : 16)
    .padding(.top, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-chat-background-jobs")
  }

  private func stopButton(jobs: [AIChatBackgroundJob], corpusRoot: URL) -> some View {
    let stopping = !stoppingJobIDs.isDisjoint(with: jobs.map(\.id))
    return Button(stopping ? "Stopping…" : "Stop") { stop(jobs, corpusRoot: corpusRoot) }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(stopping)
      .accessibilityIdentifier("ai-chat-background-job-stop")
  }

  private func stop(_ targets: [AIChatBackgroundJob], corpusRoot: URL) {
    let cli = store.cli
    stoppingJobIDs.formUnion(targets.map(\.id))
    stopError = nil
    Task {
      var failure: String?
      for job in targets {
        do {
          _ = try await cli.run(AIChatBackgroundJobs.stopArguments(jobID: job.id, corpusRoot: corpusRoot))
        } catch {
          failure = error.localizedDescription
        }
      }
      stoppingJobIDs.subtract(targets.map(\.id))
      stopError = failure
      refreshGeneration &+= 1
    }
  }

  private func poll(threadID: UUID?, corpusRoot: URL?) async {
    guard let threadID, let corpusRoot else {
      jobs = []
      jobsThreadID = threadID
      return
    }
    let cli = store.cli
    while !Task.isCancelled {
      if NSApplication.shared.isActive || jobsThreadID != threadID {
        let found: [AIChatBackgroundJob]
        do {
          let data = try await cli.run(AIChatBackgroundJobs.listArguments(threadID: threadID, corpusRoot: corpusRoot))
          found = try await Task.detached(priority: .utility) {
            try AIChatBackgroundJobs.runningJobs(from: data, threadID: threadID)
          }.value
        } catch {
          // An older CLI without `celorga job` or an unreadable list hides the row.
          found = []
        }
        guard !Task.isCancelled else { return }
        if jobs != found || jobsThreadID != threadID {
          jobs = found
          jobsThreadID = threadID
        }
      }
      let interval = jobs.isEmpty
        ? AIChatBackgroundJobs.idleRefreshInterval
        : AIChatBackgroundJobs.runningRefreshInterval
      try? await Task.sleep(for: interval)
    }
  }
}
