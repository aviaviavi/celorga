import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatBackgroundJobsTests: XCTestCase {
  private let threadID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!

  private func listJSON(_ jobs: String, schema: String = "celorga:background-jobs:v1") -> Data {
    Data(#"{"schema":"\#(schema)","directory":"/tmp/example-index/jobs","jobs":[\#(jobs)]}"#.utf8)
  }

  private func job(
    id: String,
    label: String,
    state: String = "running",
    running: Bool = true,
    thread: String? = "00000000-0000-4000-8000-0000000000a1",
    createdAt: String
  ) -> String {
    let threadField = thread.map { #","threadID":"\#($0)""# } ?? ""
    return #"{"schema":"celorga:background-job:v1","id":"\#(id)","label":"\#(label)","command":["npm","run","build"],"cwd":"/tmp/example","corpusRoot":"/tmp/example-corpus","host":"example-host","authorLabel":"Background job","logFile":"/tmp/example-index/jobs/\#(id)/output.log","createdAt":"\#(createdAt)","state":"\#(state)","running":\#(running),"durationMs":1200\#(threadField)}"#
  }

  func testRunningJobsKeepOnlyThisThreadsRunningJobsOldestFirst() throws {
    let data = listJSON([
      job(id: "20261104-120500-bbbbbb", label: "Dev server", createdAt: "2026-11-04T12:05:00.000Z"),
      job(id: "20261104-120000-aaaaaa", label: "Example build", createdAt: "2026-11-04T12:00:00.000Z"),
      job(id: "20261104-110000-cccccc", label: "Finished", state: "succeeded", running: false, createdAt: "2026-11-04T11:00:00.000Z"),
      job(id: "20261104-100000-dddddd", label: "Lost", state: "lost", running: false, createdAt: "2026-11-04T10:00:00.000Z"),
      job(id: "20261104-090000-eeeeee", label: "Other chat", thread: "00000000-0000-4000-8000-0000000000ff", createdAt: "2026-11-04T09:00:00.000Z"),
      job(id: "20261104-080000-ffffff", label: "No chat", thread: nil, createdAt: "2026-11-04T08:00:00.000Z"),
    ].joined(separator: ","))

    let jobs = try AIChatBackgroundJobs.runningJobs(from: data, threadID: threadID)

    XCTAssertEqual(jobs.map(\.id), ["20261104-120000-aaaaaa", "20261104-120500-bbbbbb"])
    XCTAssertEqual(jobs.first?.label, "Example build")
    XCTAssertEqual(AIChatBackgroundJobs.summary(for: jobs), "2 jobs running · Example build and 1 more")
    XCTAssertEqual(AIChatBackgroundJobs.summary(for: Array(jobs.prefix(1))), "1 job running · Example build")
    XCTAssertNil(AIChatBackgroundJobs.summary(for: []))
  }

  func testLegacySchemaSpellingIsAcceptedAndUnknownSchemasAreRejected() throws {
    let legacy = listJSON(job(id: "20261104-120000-aaaaaa", label: "Example build", createdAt: "2026-11-04T12:00:00.000Z"), schema: "org2:background-jobs:v1")
    XCTAssertEqual(try AIChatBackgroundJobs.runningJobs(from: legacy, threadID: threadID).count, 1)

    let unknown = listJSON("", schema: "celorga:something-else:v1")
    XCTAssertThrowsError(try AIChatBackgroundJobs.runningJobs(from: unknown, threadID: threadID)) { error in
      XCTAssertEqual(error as? AIChatBackgroundJobsError, .unsupportedSchema("celorga:something-else:v1"))
    }
    XCTAssertThrowsError(try AIChatBackgroundJobs.runningJobs(from: Data("Error: unknown command".utf8), threadID: threadID))
  }

  func testCLIArgumentsTargetTheThreadAndCorpus() {
    let corpus = URL(fileURLWithPath: "/tmp/example-corpus/./")
    XCTAssertEqual(
      AIChatBackgroundJobs.listArguments(threadID: threadID, corpusRoot: corpus),
      ["job", "list", "--thread", "00000000-0000-4000-8000-0000000000a1", "--dir", "/tmp/example-corpus", "--json"]
    )
    XCTAssertEqual(
      AIChatBackgroundJobs.stopArguments(jobID: "20261104-120000-aaaaaa", corpusRoot: corpus),
      ["job", "stop", "20261104-120000-aaaaaa", "--apply", "--json", "--dir", "/tmp/example-corpus"]
    )
  }
}
