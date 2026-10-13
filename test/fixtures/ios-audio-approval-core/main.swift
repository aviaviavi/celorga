// Behavioral checks for apps/ios/Org2Mobile/Org2Mobile/AudioApprovalCore.swift.
// Compiled together with that file on macOS by test/test-ios-audio-approval-core.mjs.
// The state machine is the iOS policy itself; only hardware events are simulated here.
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
  checks += 1
  if !condition() {
    failures += 1
    print("FAIL line \(line): \(message)")
  }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let headset = AudioRouteSnapshot(route: .headset, inCall: false, mediaPlaying: false, pushToTalkSessionActive: true)
let speaker = AudioRouteSnapshot(route: .nonHeadset, inCall: false, mediaPlaying: false, pushToTalkSessionActive: true)

func candidate(_ run: String, _ approval: String, _ fingerprint: String = "sha256:f", requestedAt: String, status: String = "pending") -> AudioApprovalCandidate {
  AudioApprovalCandidate(
    id: approval, title: "Send reply for \(run)", action: "send the reply", body: "Full detail for \(run)",
    riskClass: "external-action", requestedFrom: "OpenCode", requestedAt: requestedAt, status: status,
    isRunApproval: true, runID: run, approvalID: approval, fingerprint: fingerprint
  )
}

let a = candidate("run-a", "appr-a", requestedAt: "2026-10-13T10:00:00Z")
let b = candidate("run-b", "appr-b", requestedAt: "2026-10-13T10:05:00Z")
let targetA = a.target!
let targetB = b.target!

func receipts() -> @Sendable () -> String {
  final class Counter: @unchecked Sendable { var value = 0 }
  let counter = Counter()
  return { counter.value += 1; return "audio-approval:r\(counter.value)" }
}

func joinedSession() -> AudioApprovalSession {
  var session = AudioApprovalSession(makeReceipt: receipts())
  _ = session.handle(.enrollmentChanged(joined: true))
  return session
}

/// Push → host check → system session → prompt fully heard → initiated transmission → microphone.
func heardAndCapturing(_ session: inout AudioApprovalSession, approvals: [AudioApprovalCandidate] = [a], push: AudioApprovalTarget = targetA, at now: Date = t0) {
  _ = session.handle(.pushReceived(push, now: now))
  _ = session.handle(.approvalsUpdated(approvals, now: now))
  _ = session.handle(.sessionActivated(headset, now: now))
  _ = session.handle(.playbackFinished(completed: true, now: now))
  _ = session.handle(.sessionDeactivated)
  _ = session.handle(.transmitBegan(initiated: true, now: now.addingTimeInterval(5)))
  _ = session.handle(.sessionActivated(headset, now: now.addingTimeInterval(5)))
}

func decisions(_ effects: [AudioApprovalEffect]) -> [(AudioApprovalCandidate, String, String)] {
  effects.compactMap {
    if case .sendDecision(let c, let decision, _, let receipt) = $0 { return (c, decision, receipt) }
    return nil
  }
}

func spoken(_ effects: [AudioApprovalEffect]) -> [String] {
  effects.compactMap { if case .speak(let text, _) = $0 { return text }; return nil }
}

// 1. Whole-utterance intents only.
expect(AudioSpokenReplyParser.intent(for: "Yes.") == .approve, "yes approves")
expect(AudioSpokenReplyParser.intent(for: "nope") == .reject, "nope rejects")
expect(AudioSpokenReplyParser.intent(for: "yes no") == .unclear, "mixed speech is unclear")
expect(AudioSpokenReplyParser.intent(for: "yeah but wait") == .unclear, "a longer sentence is unclear")
expect(AudioSpokenReplyParser.intent(for: "") == .unclear, "silence is unclear")
expect(AudioSpokenReplyParser.intent(for: "Not now!") == .snooze, "not now snoozes")

// 2. Headset-only playback gate.
expect(planAudioPlayback(quiet: false, snapshot: headset) == .play, "headset plays")
expect(planAudioPlayback(quiet: false, snapshot: speaker) == .hold(.noHeadset), "speaker never plays")
expect(planAudioPlayback(quiet: true, snapshot: headset) == .hold(.quiet), "quiet holds")
expect(planAudioPlayback(quiet: false, snapshot: AudioRouteSnapshot(route: .headset, inCall: true, mediaPlaying: false, pushToTalkSessionActive: true)) == .hold(.callActive), "calls hold")
expect(planAudioPlayback(quiet: false, snapshot: AudioRouteSnapshot(route: .headset, inCall: false, mediaPlaying: false, pushToTalkSessionActive: false)) == .hold(.noPushToTalkSession), "no system session holds")

// 3. Selection mirrors the host: oldest pending with exact identity, skipping snoozed and answered.
do {
  let incomplete = AudioApprovalCandidate(id: "x", title: "x", action: nil, body: "", riskClass: nil, requestedFrom: nil,
    requestedAt: "2026-10-13T09:00:00Z", status: "pending", isRunApproval: true, runID: "run-x", approvalID: "x", fingerprint: nil)
  expect(selectAudioApprovalCandidate(from: [b, incomplete, a], snoozedUntil: [:], answeredKeys: [], now: t0)?.target == targetA, "oldest exact pending wins")
  expect(selectAudioApprovalCandidate(from: [b, a], snoozedUntil: [targetA.promptKey: t0.addingTimeInterval(60)], answeredKeys: [], now: t0)?.target == targetB, "snoozed prompt is skipped")
  expect(selectAudioApprovalCandidate(from: [b, a], snoozedUntil: [:], answeredKeys: [targetA.promptKey], now: t0)?.target == targetB, "answered prompt is skipped")
}

// 4. Happy path: the decision carries the exact heard identity and a receipt; the host receipt is spoken.
do {
  var session = joinedSession()
  let pushEffects = session.handle(.pushReceived(targetA, now: t0))
  expect(pushEffects.contains(.refreshApprovals), "a push is checked against the Mac before anything plays")
  expect(spoken(pushEffects).isEmpty, "nothing plays before the host check")
  let hostEffects = session.handle(.approvalsUpdated([a, b], now: t0))
  expect(hostEffects == [.requestAudioSession], "a verified push requests the system audio session")
  let play = session.handle(.sessionActivated(headset, now: t0))
  expect(play.count == 1 && spoken(play).first?.contains("Approval request from OpenCode") == true, "prompt plays once the session is active")
  expect(session.handle(.playbackFinished(completed: true, now: t0)) == [.releaseAudioSession], "finishing the prompt releases the session so a reply can start")
  _ = session.handle(.sessionDeactivated)
  expect(session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(3))).isEmpty, "capture waits for the system session")
  expect(session.handle(.sessionActivated(headset, now: t0.addingTimeInterval(3))) == [.startCapture], "capture starts only after didActivate")
  expect(session.handle(.transmitEnded(initiated: true, interrupted: false)) == [.finishCapture], "release finishes capture")
  let decided = decisions(session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(4))))
  expect(decided.count == 1 && decided[0].0.target == targetA && decided[0].1 == "approved" && decided[0].2 == "audio-approval:r1", "approves exactly the heard prompt with a receipt")
  let ack = session.handle(.decisionSucceeded(targetA, AudioDecisionOutcome(decision: "approved", runStatus: "running", pendingApprovalCount: 0, continuation: "continued", duplicate: false)))
  expect(spoken(ack) == ["Approved. The agent is continuing."] || ack == [.requestAudioSession], "the host receipt is acknowledged")
  expect(session.active == nil, "the answered prompt is cleared")
}

// 5. Only initiated transmissions capture.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  expect(session.handle(.transmitBegan(initiated: false, now: t0)).isEmpty, "a developer or unknown transmission captures nothing")
  expect(session.capture == .idle, "no capture after a passive transmission")
}

// 6. A prompt that did not finish cannot be answered.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: false, now: t0))
  expect(session.handle(.transmitBegan(initiated: true, now: t0)).isEmpty, "partial prompt: nothing to answer")
}

// 7. Headset loss mid-prompt stops it, moves nothing to the speaker, and voids the prompt.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  let lost = session.handle(.routeChanged(speaker))
  expect(lost.contains(.stopSpeaking) && lost.contains(.releaseAudioSession), "headset loss stops playback and releases audio")
  expect(spoken(lost).isEmpty, "headset loss never speaks elsewhere")
  _ = session.handle(.playbackFinished(completed: false, now: t0))
  expect(session.handle(.transmitBegan(initiated: true, now: t0)).isEmpty, "a voided prompt cannot be answered")
  expect(session.active?.target == targetA, "the prompt is kept for later")
  // Speaking it again while still on the speaker route is held.
  _ = session.handle(.playRequested(now: t0))
  expect(spoken(session.handle(.sessionActivated(speaker, now: t0))).isEmpty, "no headset: the replay is held")
}

// 8. Headset loss during a reply cancels it; nothing is decided.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  expect(session.handle(.routeChanged(speaker)).contains(.cancelCapture), "headset loss cancels capture")
  expect(decisions(session.handle(.transcriptReady("yes", now: t0))).isEmpty, "a cancelled reply decides nothing")
}

// 9. A stale push plays nothing.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetB, now: t0))
  let stale = session.handle(.approvalsUpdated([a], now: t0))
  expect(stale == [.releaseAudioSession], "a push no longer pending is released without playback")
  expect(session.active == nil, "a stale push does not select another prompt by itself")
  _ = session.handle(.pushReceived(nil, now: t0))
  expect(session.active == nil, "a push without identity is ignored")
}

// 10. Competing agents: a new push never switches the prompt being answered.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  _ = session.handle(.sessionDeactivated)
  _ = session.handle(.pushReceived(targetB, now: t0.addingTimeInterval(1)))
  let competing = session.handle(.approvalsUpdated([a, b], now: t0.addingTimeInterval(1)))
  expect(spoken(competing).isEmpty && session.active?.target == targetA, "prompt A stays active while B waits")
  _ = session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(2)))
  _ = session.handle(.sessionActivated(headset, now: t0.addingTimeInterval(2)))
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let decided = decisions(session.handle(.transcriptReady("no", now: t0.addingTimeInterval(3))))
  expect(decided.first?.0.target == targetA && decided.first?.1 == "rejected", "the reply decides A, the prompt that was heard")
  expect(session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(3))).isEmpty, "one decision in flight at a time")
  _ = session.handle(.decisionSucceeded(targetA, AudioDecisionOutcome(decision: "rejected", runStatus: "running", pendingApprovalCount: 0, continuation: "recorded", duplicate: false)))
  _ = session.handle(.sessionDeactivated)
  let next = session.handle(.approvalsUpdated([b], now: t0.addingTimeInterval(4)))
  expect(next == [.requestAudioSession] && session.active?.target == targetB, "B is offered only after A settles")
}

// 11. A push during a reply discards the partial reply.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  expect(session.handle(.pushReceived(targetB, now: t0)).contains(.cancelCapture), "a push cancels the capture")
  expect(session.handle(.transmitEnded(initiated: true, interrupted: true)).isEmpty, "the interrupted transmission finishes nothing")
  expect(decisions(session.handle(.transcriptReady("yeah", now: t0))).isEmpty, "a partial reply never decides")
}
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  expect(session.handle(.transmitEnded(initiated: true, interrupted: true)) == [.cancelCapture], "an interrupted transmission cancels capture")
}

// 12. The reply window expires.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  expect(session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(AudioApprovalFeature.replyWindow + 1))).isEmpty, "an old prompt cannot be answered")
  expect(session.heardTarget == nil, "the expired prompt must be heard again")
}

// 13. Quiet and snooze hold everything and decide nothing.
do {
  var session = joinedSession()
  _ = session.handle(.quietChanged(until: .distantFuture, now: t0))
  expect(session.handle(.pushReceived(targetA, now: t0)) == [.releaseAudioSession], "quiet releases a push without playback")
  expect(session.handle(.playRequested(now: t0)).isEmpty, "quiet refuses manual playback")
  _ = session.handle(.quietChanged(until: t0.addingTimeInterval(60), now: t0))
  expect(session.isQuiet(at: t0) && !session.isQuiet(at: t0.addingTimeInterval(61)), "a timed snooze ends")
}
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let later = session.handle(.transcriptReady("later", now: t0.addingTimeInterval(6)))
  expect(later.contains(.sendSnooze(targetA, until: t0.addingTimeInterval(6 + AudioApprovalFeature.snoozeInterval))), "later snoozes this exact prompt on the Mac")
  expect(decisions(later).isEmpty, "later decides nothing")
}

// 14. Withdrawn or changed approvals void the prompt.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  let changed = candidate("run-a", "appr-a", "sha256:changed", requestedAt: "2026-10-13T10:00:00Z")
  _ = session.handle(.approvalsUpdated([changed], now: t0.addingTimeInterval(1)))
  expect(session.active == nil && session.heardTarget == nil, "a changed fingerprint withdraws the heard prompt")
  expect(session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(2))).isEmpty, "the old prompt cannot be answered")
}

// 15. Why, read, and unclear explain without deciding; the prompt stays answerable.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let why = session.handle(.transcriptReady("why", now: t0.addingTimeInterval(6)))
  expect(spoken(why).first?.hasPrefix("OpenCode wants to send the reply.") == true, "why explains the request")
  _ = session.handle(.playbackFinished(completed: true, now: t0.addingTimeInterval(8)))
  _ = session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(9)))
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let unclear = session.handle(.transcriptReady("maybe later today", now: t0.addingTimeInterval(10)))
  expect(decisions(unclear).isEmpty, "unclear speech decides nothing")
}

// 16. A failed decision keeps its receipt, so a retry cannot apply twice.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let first = decisions(session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(6))))
  _ = session.handle(.decisionFailed(targetA, "The Mac was unreachable."))
  _ = session.handle(.sessionDeactivated)
  _ = session.handle(.playRequested(now: t0.addingTimeInterval(10)))
  _ = session.handle(.sessionActivated(headset, now: t0.addingTimeInterval(10)))
  _ = session.handle(.playbackFinished(completed: true, now: t0.addingTimeInterval(11)))
  _ = session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(12)))
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let retry = decisions(session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(13))))
  expect(first.first?.2 == retry.first?.2 && retry.first?.2 != nil, "the retry reuses the receipt; the Mac answers it idempotently")
}

// 17. Acknowledgements describe how the requesting agent continues.
expect(AudioApprovalSpeech.acknowledgement(AudioDecisionOutcome(decision: "approved", runStatus: "running", pendingApprovalCount: 2, continuation: "awaiting-other-approvals", duplicate: false))
  == "Approved. The run still needs 2 more approvals.", "pending approvals are announced")
expect(AudioApprovalSpeech.acknowledgement(AudioDecisionOutcome(decision: "approved", runStatus: "blocked", pendingApprovalCount: 0, continuation: "continuation-failed-blocked", duplicate: false))
  .contains("blocked"), "a failed continuation is not reported as success")
expect(AudioApprovalSpeech.acknowledgement(AudioDecisionOutcome(decision: "rejected", runStatus: "running", pendingApprovalCount: 0, continuation: "recorded", duplicate: true))
  == "That was already recorded: rejected.", "a replay is announced as a duplicate")

print("ios audio approval core: \(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
