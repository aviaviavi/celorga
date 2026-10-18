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

let t0 = ISO8601DateFormatter().date(from: "2026-10-13T10:05:00Z")!
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

// Voice selection upgrades the right language and keeps an explicit preference stable.
do {
  let compact = AudioApprovalVoiceOption(id: "us-basic", name: "Basic", language: "en-US", quality: .standard)
  let enhanced = AudioApprovalVoiceOption(id: "us-enhanced", name: "Enhanced", language: "en-US", quality: .enhanced)
  let premium = AudioApprovalVoiceOption(id: "us-premium", name: "Premium", language: "en-US", quality: .premium)
  let british = AudioApprovalVoiceOption(id: "gb-premium", name: "British", language: "en-GB", quality: .premium)
  let french = AudioApprovalVoiceOption(id: "fr-premium", name: "French", language: "fr-FR", quality: .premium)
  func selected(_ voices: [AudioApprovalVoiceOption], _ preferred: String? = nil, _ language: String = "en-US") -> AudioApprovalVoiceOption? {
    AudioApprovalVoiceOption.select(from: voices, preferredIdentifier: preferred, language: language)
  }
  expect(selected([compact, enhanced, premium]) == premium, "automatically selects installed premium voice")
  expect(selected([compact, enhanced]) == enhanced, "upgrades to enhanced when no premium is installed")
  expect(selected([compact]) == compact, "standard remains usable without downloaded voices")
  expect(selected([compact, british]) == compact, "automatic preserves the preferred region")
  expect(selected([british, french]) == british, "another region of the same language is a fallback")
  expect(selected([french]) == nil, "never automatically picks an unrelated language")
  expect(selected([compact, premium], compact.id) == compact, "explicit voice wins over automatic quality")
  expect(selected([compact, premium, british], british.id) == british, "explicit accent wins over the preferred region")
  expect(selected([enhanced], "removed-voice") == enhanced, "removed voice falls back to automatic")
  expect(selected([premium], nil, "en_US") == premium, "normalizes locale separators")
  expect(selected([]) == nil, "empty voice catalog leaves the system fallback available")
  let tie = AudioApprovalVoiceOption(id: "aaa", name: "Another", language: "en-US", quality: .premium)
  expect(selected([premium, tie]) == selected([tie, premium]), "voice catalog order cannot change automatic selection")
}

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

// A podcast is precisely when a joined walkie-talkie channel should interrupt with a prompt.
do {
  let podcast = AudioRouteSnapshot(route: .headset, inCall: false, mediaPlaying: true, pushToTalkSessionActive: true)
  expect(planAudioPlayback(quiet: false, snapshot: podcast) == .play, "podcast playback does not veto a system-activated headset prompt")
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  let play = session.handle(.sessionActivated(podcast, now: t0))
  expect(!spoken(play).isEmpty, "a fresh verified approval is spoken while other media is playing")
  expect(session.handle(.playbackFinished(completed: true, now: t0)) == [.releaseAudioSession], "completion releases the system session so media can resume")
  expect(planAudioPlayback(quiet: true, snapshot: podcast) == .hold(.quiet), "quiet still holds over media")
  expect(planAudioPlayback(quiet: false, snapshot: AudioRouteSnapshot(route: .nonHeadset, inCall: false, mediaPlaying: true, pushToTalkSessionActive: true)) == .hold(.noHeadset), "media never permits speaker output")
  expect(planAudioPlayback(quiet: false, snapshot: AudioRouteSnapshot(route: .headset, inCall: true, mediaPlaying: true, pushToTalkSessionActive: true)) == .hold(.callActive), "calls keep priority over approval prompts")
}

// 3. Selection mirrors the host: oldest pending with exact identity, skipping snoozed and answered.
do {
  let incomplete = AudioApprovalCandidate(id: "x", title: "x", action: nil, body: "", riskClass: nil, requestedFrom: nil,
    requestedAt: "2026-10-13T09:00:00Z", status: "pending", isRunApproval: true, runID: "run-x", approvalID: "x", fingerprint: nil)
  expect(selectAudioApprovalCandidate(from: [b, incomplete, a], snoozedUntil: [:], answeredKeys: [], now: t0)?.target == targetA, "oldest exact pending wins")
  expect(selectAudioApprovalCandidate(from: [b, a], snoozedUntil: [targetA.promptKey: t0.addingTimeInterval(60)], answeredKeys: [], now: t0)?.target == targetB, "snoozed prompt is skipped")
  expect(selectAudioApprovalCandidate(from: [b, a], snoozedUntil: [:], answeredKeys: [targetA.promptKey], now: t0)?.target == targetB, "answered prompt is skipped")
}

// An exact still-pending identity is insufficient: delayed delivery must not revive a backlog.
do {
  let old = candidate("example-reviewer", "old-review", requestedAt: "2026-10-01T15:41:53.321Z")
  var session = joinedSession()
  _ = session.handle(.pushReceived(old.target, now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  let verified = session.handle(.approvalsUpdated([old, b], now: t0))
  expect(spoken(verified).isEmpty, "a delayed exact Example Reviewer push must not speak an old pending request")
  expect(session.active == nil, "a stale pushed identity must not fall back to another pending approval")
  expect(verified.contains(.releaseAudioSession), "a stale push releases the receive session")
  expect(selectAudioApprovalCandidate(from: [old, b], snoozedUntil: [:], answeredKeys: [], now: t0)?.target == targetB,
         "Play next skips a dated backlog and selects a fresh request")
  for timestamp in ["", "unreadable", "2026-10-13T10:07:01Z", "2026-10-13T09:54:59Z"] {
    let invalid = candidate("invalid", "invalid", requestedAt: timestamp)
    var phone = joinedSession()
    _ = phone.handle(.pushReceived(invalid.target, now: t0))
    _ = phone.handle(.approvalsUpdated([invalid], now: t0))
    expect(spoken(phone.handle(.sessionActivated(headset, now: t0))).isEmpty && phone.active == nil,
           "missing, malformed, future, or expired request time cannot speak: \(timestamp)")
  }
}

// Recheck at playback: verification and Bluetooth routing may outlive the real-time window.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  let activation = session.handle(.sessionActivated(headset, now: t0.addingTimeInterval(301)))
  expect(spoken(activation).isEmpty && session.active == nil, "a request that ages out before activation stays silent")
  expect(activation.contains(.releaseAudioSession), "expiration before playback releases the channel")
  var routed = joinedSession()
  _ = routed.handle(.pushReceived(targetA, now: t0.addingTimeInterval(299)))
  _ = routed.handle(.sessionActivated(speaker, now: t0.addingTimeInterval(299)))
  _ = routed.handle(.approvalsUpdated([a], now: t0.addingTimeInterval(299)))
  expect(spoken(routed.handle(.routeChanged(headset, now: t0.addingTimeInterval(301)))).isEmpty, "a delayed headset route cannot revive an expired request")
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
  let lost = session.handle(.routeChanged(speaker, now: t0))
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
  expect(session.handle(.routeChanged(speaker, now: t0)).contains(.cancelCapture), "headset loss cancels capture")
  expect(decisions(session.handle(.transcriptReady("yes", now: t0))).isEmpty, "a cancelled reply decides nothing")
}

// 8b. Push to Talk may activate before an already-selected Bluetooth route settles.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  let activating = session.handle(.sessionActivated(speaker, now: t0))
  expect(
    activating == [
      .scheduleTick(after: AudioApprovalFeature.headsetRouteSettleInterval),
      .checkRoute(after: AudioApprovalFeature.routeCheckInterval),
    ],
    "an intermediate receiver route gets a bounded Bluetooth-settling grace and route polling"
  )
  expect(session.status == "Connecting the headset…", "the route transition is visible in Settings")
  let settled = session.handle(.routeChanged(headset, now: t0))
  expect(spoken(settled).first?.contains("Approval request") == true, "the prompt starts when Bluetooth becomes the active route")
  let staleTick = session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.headsetRouteSettleInterval)))
  expect(!staleTick.contains(.releaseAudioSession), "the old settling timer cannot stop headset playback")
}
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(speaker, now: t0))
  expect(session.handle(.routeChanged(speaker, now: t0)).isEmpty, "intermediate non-headset route changes keep waiting")
  let timedOut = session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.headsetRouteSettleInterval)))
  expect(timedOut == [.releaseAudioSession], "a missing headset still releases the session after the bounded grace")
  expect(session.status.contains("Held (no-headset)"), "a real missing headset remains explicit")
  expect(session.active?.target == targetA, "a route timeout keeps the prompt for replay")
}
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(speaker, now: t0))
  let oldDeadline = session.handle(.tick(now: t0.addingTimeInterval(2.5)))
  expect(
    !oldDeadline.contains(.releaseAudioSession),
    "a connected Bluetooth headset gets longer than the old two-second route transition"
  )
  let settled = session.handle(.routeChanged(headset, now: t0))
  expect(
    spoken(settled).first?.contains("Approval request") == true,
    "a slower Bluetooth HFP route can still begin private playback"
  )
}

// 8b-2. Physical order (build 56/57 trace): the bridge answers the push with a remote participant,
// so Push to Talk activates on the receiver before the Mac verifies the prompt. Verification
// during the Bluetooth switch must wait for the headset instead of speaking into the receiver.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  let activating = session.handle(.sessionActivated(speaker, now: t0))
  expect(activating.contains(.checkRoute(after: AudioApprovalFeature.routeCheckInterval)), "activation on the receiver polls the route")
  let verified = session.handle(.approvalsUpdated([a], now: t0.addingTimeInterval(0.3)))
  expect(spoken(verified).isEmpty, "a prompt verified while the route is still the receiver is not spoken")
  expect(!verified.contains(.releaseAudioSession), "verification during Bluetooth settling keeps the session")
  expect(session.handle(.routeChecked(speaker, now: t0)) == [.checkRoute(after: AudioApprovalFeature.routeCheckInterval)], "a receiver reading keeps polling")
  // Six seconds after activation, past the former five-second grace, HFP arrives with no notification.
  expect(!session.handle(.tick(now: t0.addingTimeInterval(6))).contains(.releaseAudioSession), "a six-second HFP switch is still within the grace")
  let polled = session.handle(.routeChecked(headset, now: t0))
  expect(spoken(polled).first?.contains("Approval request") == true, "a polled headset route starts the verified prompt without a route-change notification")
  expect(session.handle(.routeChecked(headset, now: t0)).isEmpty, "polling stops once playback begins")
}
do {
  // Activation reported the headset, but HFP switching moved the route away before the Mac answered.
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  expect(session.handle(.sessionActivated(headset, now: t0)).isEmpty, "a headset activation waits for the Mac")
  _ = session.handle(.routeChanged(speaker, now: t0))
  let verified = session.handle(.approvalsUpdated([a], now: t0.addingTimeInterval(1)))
  expect(spoken(verified).isEmpty, "verification after the route left the headset does not speak")
  expect(verified.contains(.checkRoute(after: AudioApprovalFeature.routeCheckInterval)), "verification after the route left the headset waits for it")
  expect(spoken(session.handle(.routeChecked(headset, now: t0))).first?.contains("Approval request") == true, "the prompt plays once the headset returns")
}
do {
  // The bounded grace still ends, and late readings after it do nothing.
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.sessionActivated(speaker, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  let timedOut = session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.headsetRouteSettleInterval)))
  expect(timedOut == [.releaseAudioSession], "no headset within the grace releases the session")
  expect(session.handle(.routeChecked(headset, now: t0)).isEmpty, "a route reading after the grace cannot start playback")
  expect(session.handle(.routeChecked(speaker, now: t0)).isEmpty, "a route reading after the grace never abandons the prompt")
  expect(session.active?.target == targetA, "the timed-out prompt is kept for replay")
}
do {
  // A spoken acknowledgement must not be attempted on the receiver either.
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let sending = session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(6)))
  expect(decisions(sending).count == 1, "spoken yes sends one decision")
  _ = session.handle(.routeChanged(speaker, now: t0))
  let ack = session.handle(.decisionSucceeded(targetA, AudioDecisionOutcome(decision: "approved", runStatus: "running", pendingApprovalCount: 0, continuation: "continued", duplicate: false)))
  expect(spoken(ack).isEmpty, "the acknowledgement waits while the route is not a headset")
  expect(spoken(session.handle(.routeChecked(headset, now: t0))) == ["Approved. The agent is continuing."], "the acknowledgement plays on the returning headset")
}

// 8c. If iOS stops audible speech without a finish/cancel callback, playback must not keep
// the Push to Talk receive session forever and block both Talk and ordinary dictation.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  let started = session.handle(.sessionActivated(headset, now: t0))
  expect(spoken(started).first?.contains("Approval request") == true, "the stalled prompt starts normally")
  let stalled = session.handle(.playbackStalled)
  expect(
    stalled.contains(.stopSpeaking) && stalled.contains(.releaseAudioSession),
    "a prompt with no speech progress releases the system audio session"
  )
  expect(session.playback == .idle, "a stalled prompt no longer leaves Settings stuck on playing")
  expect(session.heardTarget == nil, "a stalled prompt is not answerable until replayed")
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
  expect(spoken(session.handle(.transmitEnded(initiated: true, interrupted: false))).first?.hasPrefix("Still sending") == true, "the rejected press is announced on release")
  _ = session.handle(.playbackFinished(completed: true, now: t0.addingTimeInterval(3)))
  _ = session.handle(.decisionSucceeded(targetA, AudioDecisionOutcome(decision: "rejected", runStatus: "running", pendingApprovalCount: 0, continuation: "recorded", duplicate: false)))
  _ = session.handle(.sessionDeactivated)
  let next = session.handle(.approvalsUpdated([b], now: t0.addingTimeInterval(4)))
  expect(next == [.requestAudioSession, .scheduleTick(after: AudioApprovalFeature.remoteParticipantHoldLimit)] && session.active?.target == targetB, "B is offered only after A settles")
}

// 11. A push during a reply never interrupts it; the new prompt waits until the answer ends.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  let pushed = session.handle(.pushReceived(targetB, now: t0.addingTimeInterval(6)))
  expect(!pushed.contains(.cancelCapture) && session.capture == .capturing, "a push does not cancel the reply in progress")
  expect(session.deferredPush == targetB && session.active?.target == targetA, "B waits while A is answered")
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let decided = decisions(session.handle(.transcriptReady("yeah", now: t0.addingTimeInterval(7))))
  expect(decided.first?.0.target == targetA && decided.first?.1 == "approved", "the reply still decides A")
  let settled = session.handle(.decisionSucceeded(targetA, AudioDecisionOutcome(decision: "approved", runStatus: "running", pendingApprovalCount: 0, continuation: "continued", duplicate: false)))
  expect(spoken(settled) == ["Approved. The agent is continuing."], "the result is spoken")
  let afterAck = session.handle(.playbackFinished(completed: true, now: t0.addingTimeInterval(8)))
  expect(afterAck.contains(.refreshApprovals) && session.deferredPush == nil && session.pushedTarget == targetB, "B is taken up once the answer ends")
}
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  let interrupted = session.handle(.transmitEnded(initiated: true, interrupted: true))
  expect(interrupted.contains(.cancelCapture), "an interrupted transmission cancels capture")
  expect(spoken(interrupted).first?.contains("Nothing was decided") == true, "an interrupted reply is announced")
  expect(decisions(session.handle(.transcriptReady("yeah", now: t0))).isEmpty, "a partial reply never decides")
}

// 11b. A prompt heard but left unanswered does not monopolize audio.
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  _ = session.handle(.sessionDeactivated)
  let early = session.handle(.pushReceived(targetB, now: t0.addingTimeInterval(5)))
  expect(session.deferredPush == targetB && session.active?.target == targetA, "within the answer grace B waits")
  expect(early.contains(.scheduleTick(after: AudioApprovalFeature.answerGrace - 5)), "a tick is scheduled for the end of the grace")
  let tick = session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.answerGrace + 1)))
  expect(tick.contains(.refreshApprovals) && session.active == nil && session.pushedTarget == targetB, "after the grace B replaces the unanswered A")
  let played = session.handle(.approvalsUpdated([a, b], now: t0.addingTimeInterval(AudioApprovalFeature.answerGrace + 2)))
  expect(played == [.requestAudioSession, .scheduleTick(after: AudioApprovalFeature.remoteParticipantHoldLimit)] && session.active?.target == targetB, "B is offered even though A is still pending")
}
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  _ = session.handle(.sessionDeactivated)
  let late = session.handle(.pushReceived(targetB, now: t0.addingTimeInterval(AudioApprovalFeature.answerGrace + 30)))
  expect(late.contains(.refreshApprovals) && session.active == nil && session.heardTarget == nil, "a push after the grace replaces the stale prompt at once")
}

// 11c. Explicit urgency orders prompts; age alone does not.
do {
  let urgentNewer = AudioApprovalCandidate(
    id: "appr-u", title: "Urgent", action: "send", body: "", riskClass: nil, requestedFrom: nil,
    requestedAt: "2026-10-13T10:06:00Z", priority: "urgent", status: "pending",
    isRunApproval: true, runID: "run-u", approvalID: "appr-u", fingerprint: "sha256:u"
  )
  expect(selectAudioApprovalCandidate(from: [a, b, urgentNewer], snoozedUntil: [:], answeredKeys: [], now: t0)?.target.approvalID == "appr-u", "an urgent approval goes first")
  expect(selectAudioApprovalCandidate(from: [b, a], snoozedUntil: [:], answeredKeys: [], now: t0)?.target == targetA, "without urgency the oldest goes first")
}

// 11d. Every Push to Talk attempt ends with a spoken result.
do {
  var session = joinedSession()
  _ = session.handle(.transmitBegan(initiated: true, now: t0))
  let nothing = session.handle(.transmitEnded(initiated: true, interrupted: false))
  expect(spoken(nothing).isEmpty && nothing == [.requestAudioSession, .scheduleTick(after: AudioApprovalFeature.remoteParticipantHoldLimit)] && session.lastAcknowledgement?.contains("Nothing to answer") == true, "a press with no prompt is announced after release")
  expect(spoken(session.handle(.sessionActivated(headset, now: t0))).first?.contains("Nothing to answer") == true, "and spoken once audio is available")
}
do {
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  _ = session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(AudioApprovalFeature.replyWindow + 1)))
  let expired = session.handle(.transmitEnded(initiated: true, interrupted: false))
  expect(spoken(expired).first?.contains("expired") == true, "an expired prompt is announced")
}
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  expect(session.handle(.captureFailed("Microphone unavailable.")).isEmpty, "a capture failure waits for the release")
  let failed = session.handle(.transmitEnded(initiated: true, interrupted: false))
  expect(spoken(failed) == ["I couldn't hear your reply. Nothing was decided."], "a capture failure is spoken")
  expect(session.lastAcknowledgement?.contains("Microphone unavailable.") == true, "and shown with its reason")
}
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  _ = session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(6)))
  let rejected = session.handle(.decisionFailed(targetA, "The approval changed on the Mac."))
  expect(spoken(rejected) == ["Not confirmed. Check the request’s status in Approvals."], "a server rejection is spoken")
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

// Reply feedback survives failed capture and records interpretation separately from host acceptance.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  _ = session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(6)))
  expect(session.replyHistory.first?.transcript == "yes", "feedback retains recognized speech")
  expect(session.replyHistory.first?.interpretation == "Approve", "feedback shows the parsed command")
  expect(session.replyHistory.first?.outcome == "Sending to the Mac…", "local recognition is not host acceptance")
  _ = session.handle(.decisionFailed(targetA, "Mac unreachable"))
  expect(session.replyHistory.first?.outcome.contains("Mac unreachable") == true, "failed submission remains inspectable")
  expect(session.replyHistory.first?.outcome.contains("Nothing was changed") == false, "a missing host receipt must not claim the Mac made no change")
  let restored = try! JSONDecoder().decode([AudioApprovalReplyRecord].self, from: JSONEncoder().encode(session.replyHistory))
  expect(restored == session.replyHistory, "reply history persists across app launches")
}
do {
  var session = joinedSession()
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.playRequested(now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.sessionDeactivated)
  expect(session.status.contains("did not finish"), "background session loss must not leave UI saying playing")
  _ = session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(2)))
  expect(session.replyHistory.first?.outcome.contains("Nothing was decided") == true, "reply after truncated playback gets visible feedback")
  expect(session.replyHistory.first?.interpretation == nil, "uncaptured speech is never claimed interpreted")
}
// PTT may deactivate the session before reporting the normal button release.
do {
  var session = joinedSession()
  heardAndCapturing(&session)
  _ = session.handle(.sessionDeactivated)
  expect(session.capture == .capturing, "deactivation waits briefly for the transmission-end callback")
  _ = session.handle(.transmitEnded(initiated: true, interrupted: false))
  let result = decisions(session.handle(.transcriptReady("yes", now: t0.addingTimeInterval(6))))
  expect(result.first?.1 == "approved", "normal button release survives reversed framework callback order")
}
// Dispatching buffer callbacks to an actor must not reorder audio or deliver EOF early.
do {
  var ordering = AudioSpeechBufferOrdering<String>()
  expect(ordering.insert("EOF", at: 2).isEmpty, "EOF waits for earlier buffers")
  expect(ordering.insert("second", at: 1).isEmpty, "later buffers wait for their predecessors")
  expect(ordering.insert("first", at: 0) == ["first", "second", "EOF"], "audio drains in synthesis order")
  expect(ordering.insert("duplicate", at: 0).isEmpty, "late duplicates cannot replay old audio")
}
// A synthesizer that only emits EOF has not played any audio.
do {
  var empty = AudioSpeechPlaybackProgress()
  let id = UUID()
  empty.start(id)
  expect(!empty.renderingFinished(id), "empty synthesis must not mark a prompt heard")
}

// Generation ending does not mean the queued audio has finished playing.
do {
  var progress = AudioSpeechPlaybackProgress()
  let first = UUID(), second = UUID()
  progress.start(first)
  progress.enqueued(first)
  progress.enqueued(first)
  expect(!progress.renderingFinished(first), "speech rendering cannot release receive mode early")
  expect(!progress.played(first), "first audio buffer cannot finish a longer prompt")
  expect(progress.played(first), "completion waits for the last audible buffer")
  progress.start(second)
  progress.enqueued(second)
  expect(!progress.played(first), "late callback from stopped speech cannot finish its replacement")
  expect(!progress.renderingFinished(first), "late generator cannot release a newer audio session")
  expect(!progress.played(second), "drained audio waits for rendering EOF")
  expect(progress.renderingFinished(second), "EOF completes an already drained utterance")
}

// Celorga must never stay the active remote participant: while it is, iOS disables Talk.
do {
  // A push for the prompt already heard (the Mac re-pushes it) must hand Talk back.
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  _ = session.handle(.sessionDeactivated)
  expect(!session.holdsRemoteParticipant, "a finished prompt releases the participant")
  let repush = session.handle(.pushReceived(targetA, now: t0.addingTimeInterval(40)))
  expect(repush == [.refreshApprovals, .scheduleTick(after: AudioApprovalFeature.remoteParticipantHoldLimit)], "a re-push of the heard prompt is checked with the Mac")
  let checked = session.handle(.approvalsUpdated([a], now: t0.addingTimeInterval(41)))
  expect(checked == [.releaseAudioSession] && !session.holdsRemoteParticipant, "the re-push releases Talk once the Mac confirms nothing new")
  let reply = session.handle(.transmitBegan(initiated: true, now: t0.addingTimeInterval(45)))
  expect(reply.isEmpty && session.capture == .awaitingSession, "the heard prompt can still be answered")
}
do {
  // A push during the answer grace is deferred; Talk must stay usable for the current prompt.
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  _ = session.handle(.playbackFinished(completed: true, now: t0))
  _ = session.handle(.sessionDeactivated)
  let deferred = session.handle(.pushReceived(targetB, now: t0.addingTimeInterval(3)))
  expect(deferred.contains(.releaseAudioSession) && session.deferredPush == targetB, "a deferred push releases Talk for the current answer")
}
do {
  // A push before enrollment is known (background launch) must not hold the participant.
  var session = AudioApprovalSession(makeReceipt: receipts())
  expect(session.handle(.pushReceived(targetA, now: t0)) == [.releaseAudioSession], "an unexpected push is released")
  expect(!session.holdsRemoteParticipant, "nothing holds Talk")
}
do {
  // The Mac never answers the check: Talk is released after the hold limit.
  var session = joinedSession()
  let pushed = session.handle(.pushReceived(targetA, now: t0))
  expect(pushed.contains(.scheduleTick(after: AudioApprovalFeature.remoteParticipantHoldLimit)), "a deadline is armed for the host check")
  _ = session.handle(.sessionActivated(headset, now: t0))
  expect(session.holdsRemoteParticipant, "the session is kept while the Mac checks the prompt")
  let expired = session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.remoteParticipantHoldLimit)))
  expect(expired == [.releaseAudioSession] && !session.holdsRemoteParticipant, "an unanswered host check releases Talk")
  // If the Mac answers late, the prompt is requested again rather than lost.
  let late = session.handle(.approvalsUpdated([a], now: t0.addingTimeInterval(20)))
  expect(late.contains(.requestAudioSession) && session.active?.target == targetA, "a late confirmation still offers the prompt")
}
do {
  // Audio requested but the system never activates it.
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0.addingTimeInterval(1)))
  let expired = session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.remoteParticipantHoldLimit + 1)))
  expect(expired == [.releaseAudioSession] && !session.holdsRemoteParticipant, "a session that never activates releases Talk")
}
do {
  // Playback in progress keeps the participant; the deadline does not cut a prompt.
  var session = joinedSession()
  _ = session.handle(.pushReceived(targetA, now: t0))
  _ = session.handle(.approvalsUpdated([a], now: t0))
  _ = session.handle(.sessionActivated(headset, now: t0))
  expect(session.handle(.tick(now: t0.addingTimeInterval(AudioApprovalFeature.remoteParticipantHoldLimit + 1))).isEmpty, "the deadline never interrupts playback")
  expect(session.holdsRemoteParticipant, "playing audio keeps the participant")
}

print("ios audio approval core: \(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
