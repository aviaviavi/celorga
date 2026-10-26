import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AttentionDigestSchedulerTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func at(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
  }

  private let schedule = AttentionSchedule(
    morningBrief: AttentionClockTime("08:30"),
    checkIntervalMinutes: 120,
    quietStart: AttentionClockTime("22:00"),
    quietEnd: AttentionClockTime("07:00")
  )

  func testQuietHoursWrapMidnightAndBlockEverything() {
    XCTAssertTrue(AttentionScheduler.isQuiet(at("2026-10-26T23:15:00Z"), schedule: schedule, calendar: calendar))
    XCTAssertTrue(AttentionScheduler.isQuiet(at("2026-10-26T06:59:00Z"), schedule: schedule, calendar: calendar))
    XCTAssertFalse(AttentionScheduler.isQuiet(at("2026-10-26T07:00:00Z"), schedule: schedule, calendar: calendar))
    XCTAssertEqual(
      AttentionScheduler.decide(now: at("2026-10-26T02:00:00Z"), schedule: schedule, state: AttentionScheduleState(), calendar: calendar),
      .wait
    )
    let midday = AttentionSchedule(morningBrief: nil, checkIntervalMinutes: 60, quietStart: AttentionClockTime("12:00"), quietEnd: AttentionClockTime("13:00"))
    XCTAssertTrue(AttentionScheduler.isQuiet(at("2026-10-26T12:30:00Z"), schedule: midday, calendar: calendar))
    XCTAssertFalse(AttentionScheduler.isQuiet(at("2026-10-26T13:00:00Z"), schedule: midday, calendar: calendar))
  }

  func testMorningBriefRunsOncePerDayWithinItsWindow() {
    let empty = AttentionScheduleState()
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T08:29:00Z"), schedule: schedule, state: empty, calendar: calendar), .check)
    let beforeBrief = AttentionScheduleState(lastCheckAt: at("2026-10-26T08:00:00Z"))
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T08:29:00Z"), schedule: schedule, state: beforeBrief, calendar: calendar), .wait)
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T08:30:00Z"), schedule: schedule, state: beforeBrief, calendar: calendar), .brief)

    let afterBrief = AttentionScheduler.recording(.brief, at: at("2026-10-26T08:30:00Z"), in: beforeBrief, calendar: calendar)
    XCTAssertEqual(afterBrief.lastBriefDay, "2026-10-26")
    XCTAssertEqual(afterBrief.lastCheckAt, at("2026-10-26T08:30:00Z"))
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T09:00:00Z"), schedule: schedule, state: afterBrief, calendar: calendar), .wait)
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T10:30:00Z"), schedule: schedule, state: afterBrief, calendar: calendar), .check)
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-27T08:45:00Z"), schedule: schedule, state: afterBrief, calendar: calendar), .brief)

    // A brief missed by more than the window (the Mac slept) is skipped; checks continue.
    let late = AttentionScheduleState(lastCheckAt: at("2026-10-26T14:00:00Z"))
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T15:00:00Z"), schedule: schedule, state: late, calendar: calendar), .wait)
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T16:00:00Z"), schedule: schedule, state: late, calendar: calendar), .check)
  }

  func testZeroIntervalOnlyBriefs() {
    let briefOnly = AttentionSchedule(morningBrief: AttentionClockTime("08:00"), checkIntervalMinutes: 0, quietStart: nil, quietEnd: nil)
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T08:05:00Z"), schedule: briefOnly, state: AttentionScheduleState(), calendar: calendar), .brief)
    let briefed = AttentionScheduleState(lastBriefDay: "2026-10-26", lastCheckAt: at("2026-10-26T08:05:00Z"))
    XCTAssertEqual(AttentionScheduler.decide(now: at("2026-10-26T20:00:00Z"), schedule: briefOnly, state: briefed, calendar: calendar), .wait)
  }

  func testClockTimeParsingRejectsMalformedValues() {
    XCTAssertEqual(AttentionClockTime("07:05")?.minutesOfDay, 425)
    XCTAssertNil(AttentionClockTime("24:00"))
    XCTAssertNil(AttentionClockTime("7"))
    XCTAssertNil(AttentionClockTime(nil))
  }

  func testCommandArgumentsMarkExactlyTheNotifiedFingerprints() {
    XCTAssertEqual(
      AttentionDigestCommand.digestArguments(corpusRoot: "/tmp/notes", mode: .brief),
      ["workspace", "attention", "--dir", "/tmp/notes", "--mode", "brief", "--json"]
    )
    XCTAssertEqual(
      AttentionDigestCommand.markArguments(corpusRoot: "/tmp/notes", fingerprints: ["att_a", "att_b"], revision: nil),
      ["workspace", "attention", "--dir", "/tmp/notes", "--mark-delivered", "--fingerprint", "att_a", "--fingerprint", "att_b", "--if-revision", "absent", "--apply", "--json"]
    )
  }

  func testDecodesDigestEnvelopeAndSchedule() throws {
    let json = """
    {
      "schema": "org2:attention-digest:v1",
      "generatedAt": "2026-10-26T09:00:00.000Z",
      "mode": "check",
      "local": { "date": "2026-10-26", "time": "09:00", "timezone": "UTC" },
      "corpora": [],
      "issues": [],
      "preferences": { "categories": ["approval"], "excludeTags": [], "excludePaths": [], "quietHours": { "start": "22:00", "end": "07:00" }, "morningBrief": null, "checkIntervalMinutes": 60 },
      "preferencesFile": null,
      "quietHours": { "active": false, "start": "22:00", "end": "07:00" },
      "items": [{
        "fingerprint": "att_000000000000000000000001",
        "category": "today",
        "title": "TODO Water the ferns",
        "summary": "Scheduled today",
        "corpus": { "id": "demo", "root": "/tmp/notes" },
        "ref": "notes/tasks.org:6",
        "evidence": [{ "kind": "file", "ref": "notes/tasks.org:6", "path": "/tmp/notes/notes/tasks.org", "line": 6 }],
        "tags": [],
        "at": "2026-10-26",
        "delivered": false
      }],
      "summary": { "total": 1, "new": 1, "delivered": 0, "byCategory": {} },
      "interrupt": true,
      "interruptReason": "1 new item(s) need you",
      "notification": { "title": "Celorga: 1 new item needs you", "body": "Today: TODO Water the ferns", "fingerprints": ["att_000000000000000000000001"] },
      "delivery": { "file": null, "revision": null, "requested": false, "applied": false, "marked": [] }
    }
    """
    let payload = try JSONDecoder().decode(AttentionDigestPayload.self, from: Data(json.utf8))
    XCTAssertTrue(payload.interrupt)
    XCTAssertEqual(payload.items.first?.evidence.first?.line, 6)
    XCTAssertEqual(payload.notification?.fingerprints, ["att_000000000000000000000001"])
    let schedule = AttentionSchedule(preferences: payload.preferences)
    XCTAssertNil(schedule.morningBrief)
    XCTAssertEqual(schedule.checkIntervalMinutes, 60)
    XCTAssertEqual(schedule.quietStart, AttentionClockTime("22:00"))
  }
}
