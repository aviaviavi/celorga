import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Walkie-talkie audio approvals. Off unless the person turns it on in Settings.
///
/// This file is pure policy with no UIKit, PushToTalk, or network dependency, so the
/// same source is compiled and exercised on macOS by `test/test-ios-audio-approval-core.mjs`.
/// It mirrors `src/audioApprovalBroker.ts`. The paired Mac remains the only decision
/// authority; nothing here records a decision.
enum AudioApprovalFeature {
  /// Off by default. Turned on from Settings › Audio approvals.
  static let defaultsKey = "celorga.audioApprovals.enabled"
  /// Quiet or snoozed until this time. `Date.distantFuture` is quiet mode.
  static let quietUntilDefaultsKey = "celorga.audioApprovals.quietUntil"
  static let snoozeInterval: TimeInterval = 30 * 60
  /// A reply binds only to a prompt heard this recently.
  static let replyWindow: TimeInterval = 120

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }
}

enum AudioApprovalError: LocalizedError {
  case approvalIdentityMissing

  var errorDescription: String? {
    switch self {
    case .approvalIdentityMissing: "This approval is missing its run, approval, or fingerprint."
    }
  }
}

/// The exact identity a spoken decision is bound to.
struct AudioApprovalTarget: Hashable, Sendable {
  let runID: String
  let approvalID: String
  let fingerprint: String

  /// Stable per-prompt key. Matches the Mac host's prompt key.
  var promptKey: String {
    "\(runID)|\(approvalID)|\(fingerprint)"
  }
}

/// The part of an approval the audio flow needs. Built from `ApprovalEntry` by the controller.
struct AudioApprovalCandidate: Hashable, Sendable {
  let id: String
  let title: String
  let action: String?
  let body: String
  let riskClass: String?
  let requestedFrom: String?
  let requestedAt: String?
  let status: String
  let isRunApproval: Bool
  let runID: String?
  let approvalID: String?
  let fingerprint: String?

  var target: AudioApprovalTarget? {
    guard isRunApproval, status == "pending",
          let runID, !runID.isEmpty,
          let approvalID, !approvalID.isEmpty,
          let fingerprint, !fingerprint.isEmpty
    else { return nil }
    return AudioApprovalTarget(runID: runID, approvalID: approvalID, fingerprint: fingerprint)
  }
}

enum AudioSpokenIntent: String, Sendable {
  case approve, reject, why, read, snooze, unclear
}

enum AudioSpokenReplyParser {
  static let approvePhrases: Set<String> = ["yes", "yeah", "yep", "approve"]
  static let rejectPhrases: Set<String> = ["no", "nope", "reject", "deny"]
  static let readPhrases: Set<String> = ["read it to me", "read it", "read to me"]
  static let snoozePhrases: Set<String> = ["later", "not now"]

  /// Whole-utterance matching only. Mixed, partial, or empty speech is `unclear`
  /// and authorizes nothing.
  static func intent(for transcript: String) -> AudioSpokenIntent {
    let kept = transcript.lowercased().map { character -> Character in
      (character.isASCII && (character.isLetter || character == "'")) ? character : " "
    }
    let normalized = String(kept).split(separator: " ").joined(separator: " ")
    if normalized == "why" { return .why }
    if approvePhrases.contains(normalized) { return .approve }
    if rejectPhrases.contains(normalized) { return .reject }
    if readPhrases.contains(normalized) { return .read }
    if snoozePhrases.contains(normalized) { return .snooze }
    return .unclear
  }
}

enum AudioRouteClass: Sendable, Equatable {
  case headset
  /// Built-in speaker, receiver, AirPlay, or any output that is not a private headset.
  case nonHeadset
  case none
}

#if os(iOS)
enum AudioRouteClassifier {
  static let headsetPorts: Set<AVAudioSession.Port> = [
    .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio,
  ]

  /// A route is headset only when every output is a private headset port.
  static func classify(outputPorts: [AVAudioSession.Port]) -> AudioRouteClass {
    guard !outputPorts.isEmpty else { return .none }
    return outputPorts.allSatisfy { headsetPorts.contains($0) } ? .headset : .nonHeadset
  }
}
#endif

struct AudioRouteSnapshot: Sendable, Equatable {
  let route: AudioRouteClass
  let inCall: Bool
  let mediaPlaying: Bool
  /// True only while the Push to Talk framework has activated an audio session for us.
  let pushToTalkSessionActive: Bool
}

enum AudioHoldReason: String, Sendable, Equatable {
  case quiet
  case noPushToTalkSession = "no-push-to-talk-session"
  case noHeadset = "no-headset"
  case callActive = "call-active"
  case mediaActive = "media-active"
}

enum AudioPlaybackPlan: Sendable, Equatable {
  case play
  case hold(AudioHoldReason)
}

/// Headset-only playback, evaluated at the moment of playback. Never falls back to a speaker.
func planAudioPlayback(quiet: Bool, snapshot: AudioRouteSnapshot) -> AudioPlaybackPlan {
  if quiet { return .hold(.quiet) }
  if !snapshot.pushToTalkSessionActive { return .hold(.noPushToTalkSession) }
  if snapshot.route != .headset { return .hold(.noHeadset) }
  if snapshot.inCall { return .hold(.callActive) }
  if snapshot.mediaPlaying { return .hold(.mediaActive) }
  return .play
}

/// Oldest pending run approval with a complete identity, minus snoozed and answered prompts.
/// Same order as the Mac host, so a pushed prompt and a locally chosen one agree.
func selectAudioApprovalCandidate(
  from candidates: [AudioApprovalCandidate],
  snoozedUntil: [String: Date],
  answeredKeys: Set<String>,
  now: Date
) -> (target: AudioApprovalTarget, candidate: AudioApprovalCandidate)? {
  candidates
    .compactMap { candidate in candidate.target.map { ($0, candidate) } }
    .filter { target, _ in
      (snoozedUntil[target.promptKey] ?? .distantPast) <= now && !answeredKeys.contains(target.promptKey)
    }
    .sorted { lhs, rhs in
      let left = lhs.1.requestedAt ?? "~"
      let right = rhs.1.requestedAt ?? "~"
      if left != right { return left < right }
      if lhs.0.runID != rhs.0.runID { return lhs.0.runID < rhs.0.runID }
      return lhs.0.approvalID < rhs.0.approvalID
    }
    .first
    .map { (target: $0.0, candidate: $0.1) }
}

enum AudioApprovalSpeech {
  static func prompt(for candidate: AudioApprovalCandidate) -> String {
    let requester = candidate.requestedFrom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let opening = requester.isEmpty ? "Approval request" : "Approval request from \(requester)"
    let action = candidate.action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let detail = action.isEmpty || action == candidate.title ? "" : " \(bounded(action, 240))."
    return "\(opening): \(bounded(candidate.title, 200)).\(detail) Say yes, no, why, read it to me, or later."
  }

  static func why(for candidate: AudioApprovalCandidate) -> String {
    let requester = candidate.requestedFrom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let who = requester.isEmpty ? "The agent" : requester
    let action = candidate.action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? candidate.title
    let risk = candidate.riskClass.map { " Risk: \($0.replacingOccurrences(of: "-", with: " "))." } ?? ""
    return "\(who) wants to \(bounded(action, 400)).\(risk) Say yes, no, or later."
  }

  static func read(for candidate: AudioApprovalCandidate) -> String {
    let body = candidate.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = body.isEmpty ? (candidate.action ?? candidate.title) : body
    return "\(bounded(text, 900)) Say yes, no, or later."
  }

  static func acknowledgement(_ outcome: AudioDecisionOutcome) -> String {
    let decided = outcome.decision == "approved" ? "Approved" : "Rejected"
    if outcome.duplicate {
      return "That was already recorded: \(decided.lowercased())."
    }
    switch outcome.continuation {
    case "continued": return "\(decided). The agent is continuing."
    case "already-continuing": return "\(decided). The agent was already continuing."
    case "awaiting-other-approvals":
      let count = outcome.pendingApprovalCount
      return "\(decided). The run still needs \(count) more approval\(count == 1 ? "" : "s")."
    case "continuation-failed-blocked": return "\(decided), but the agent could not be resumed. The run is blocked; check the Mac."
    case "continuation-failed": return "\(decided), but resuming the agent failed. Check the Mac."
    case "revision-continuing": return "\(decided). The agent is revising."
    default: return "\(decided). Recorded for the agent."
    }
  }

  static func bounded(_ text: String, _ limit: Int) -> String {
    let compact = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    guard compact.count > limit else { return compact }
    return String(compact.prefix(limit)) + "…"
  }
}

/// What the Mac reported after an exact decision.
struct AudioDecisionOutcome: Sendable, Equatable {
  let decision: String
  let runStatus: String
  let pendingApprovalCount: Int
  let continuation: String
  let duplicate: Bool
}

enum AudioSpeechKind: Sendable, Equatable {
  /// The approval prompt. Only a completely played prompt can be answered.
  case prompt
  case info
  case acknowledgement
}

enum AudioApprovalEvent: Sendable, Equatable {
  case enrollmentChanged(joined: Bool)
  case quietChanged(until: Date?, now: Date)
  case approvalsUpdated([AudioApprovalCandidate], now: Date)
  /// A Push to Talk notification. `nil` means the payload had no complete identity.
  case pushReceived(AudioApprovalTarget?, now: Date)
  /// The person asked to hear the next prompt, or the current one again.
  case playRequested(now: Date)
  case sessionActivated(AudioRouteSnapshot, now: Date)
  case sessionDeactivated
  case playbackFinished(completed: Bool, now: Date)
  case transmitBegan(initiated: Bool, now: Date)
  /// `interrupted` is true when the system ended the transmission, for example for an incoming push.
  case transmitEnded(initiated: Bool, interrupted: Bool)
  case transcriptReady(String, now: Date)
  case captureFailed(String)
  case routeChanged(AudioRouteSnapshot)
  case interrupted
  case decisionSucceeded(AudioApprovalTarget, AudioDecisionOutcome)
  case decisionFailed(AudioApprovalTarget, String)
}

enum AudioApprovalEffect: Sendable, Equatable {
  /// Ask the system for an audio session (set the active remote participant).
  case requestAudioSession
  /// Clear the active remote participant so the system can end the session and allow a reply.
  case releaseAudioSession
  case speak(String, AudioSpeechKind)
  case stopSpeaking
  case startCapture
  case finishCapture
  case cancelCapture
  case refreshApprovals
  case sendDecision(AudioApprovalCandidate, decision: String, note: String?, receipt: String)
  case sendSnooze(AudioApprovalTarget, until: Date)
}

/// The audio approval state machine. Pure: every input is an event, every output an effect.
///
/// Safety rules it enforces:
/// - Only a completely heard prompt can be answered, and only for `replyWindow` seconds.
/// - Only initiated transmissions (system button or headset button) capture a reply.
/// - A push never switches the prompt being answered; it waits until the current one settles.
/// - A push whose exact identity is no longer pending is stale and plays nothing.
/// - Headset loss, interruption, or quiet cancels playback and capture. Nothing moves to the
///   speaker and nothing is decided.
/// - One decision in flight at a time; a replay of the same prompt reuses its receipt.
struct AudioApprovalSession: Sendable, Equatable {
  enum Playback: Sendable, Equatable { case idle, speaking(AudioSpeechKind) }
  enum Capture: Sendable, Equatable { case idle, awaitingSession, capturing, finishing }

  private(set) var joined = false
  private(set) var quietUntil: Date?
  private(set) var candidates: [AudioApprovalCandidate] = []
  private(set) var pushedTarget: AudioApprovalTarget?
  private(set) var active: AudioApprovalCandidate?
  /// Receipt key for the current presentation of `active`.
  private(set) var activeReceipt: String?
  private(set) var heardTarget: AudioApprovalTarget?
  private(set) var heardAt: Date?
  private(set) var sessionActive = false
  private(set) var playback: Playback = .idle
  private(set) var capture: Capture = .idle
  private(set) var deciding: AudioApprovalTarget?
  private(set) var queuedSpeech: (text: String, kind: AudioSpeechKind)?
  private(set) var answered: [String: String] = [:]
  private(set) var snoozedUntil: [String: Date] = [:]
  private(set) var status = "Off"
  private(set) var lastAcknowledgement: String?

  private let makeReceipt: @Sendable () -> String

  init(makeReceipt: @escaping @Sendable () -> String = { "audio-approval:\(UUID().uuidString.lowercased())" }) {
    self.makeReceipt = makeReceipt
  }

  static func == (lhs: AudioApprovalSession, rhs: AudioApprovalSession) -> Bool {
    lhs.status == rhs.status && lhs.active == rhs.active && lhs.heardTarget == rhs.heardTarget
      && lhs.capture == rhs.capture && lhs.playback == rhs.playback && lhs.deciding == rhs.deciding
  }

  var activeTarget: AudioApprovalTarget? { active?.target }

  func isQuiet(at now: Date) -> Bool {
    (quietUntil ?? .distantPast) > now
  }

  mutating func handle(_ event: AudioApprovalEvent) -> [AudioApprovalEffect] {
    switch event {
    case .enrollmentChanged(let joined):
      self.joined = joined
      if !joined {
        let effects = abandonTransientAudio()
        active = nil
        activeReceipt = nil
        pushedTarget = nil
        status = "Not joined. No prompts reach the headset."
        return effects
      }
      status = "Joined. Prompts can reach a connected headset."
      return []

    case .quietChanged(let until, let now):
      quietUntil = until
      guard isQuiet(at: now) else {
        status = joined ? "Prompts allowed." : status
        return []
      }
      var effects = abandonTransientAudio()
      effects.append(.releaseAudioSession)
      status = until == .distantFuture
        ? "Quiet: prompts wait on the Mac until you turn quiet off."
        : "Snoozed: prompts wait on the Mac until the snooze ends."
      return effects

    case .approvalsUpdated(let list, let now):
      candidates = list
      return reconcileWithHost(now: now)

    case .pushReceived(let target, let now):
      guard joined else { return [] }
      guard let target else {
        status = "Ignored a prompt without a complete identity."
        return [.releaseAudioSession]
      }
      if isQuiet(at: now) {
        status = "Quiet: a prompt arrived and was held. Nothing played."
        return [.releaseAudioSession]
      }
      var effects: [AudioApprovalEffect] = []
      if capture == .capturing || capture == .awaitingSession {
        // A push must never complete a partial reply.
        capture = .idle
        effects.append(.cancelCapture)
        lastAcknowledgement = "Reply interrupted by a new prompt. Nothing was decided."
      }
      pushedTarget = target
      status = "Prompt received. Checking it with the Mac…"
      effects.append(.refreshApprovals)
      return effects

    case .playRequested(let now):
      guard joined else {
        status = "Join the approvals channel first."
        return []
      }
      if isQuiet(at: now) {
        status = "Quiet is on. Turn it off to hear prompts."
        return []
      }
      guard deciding == nil, capture == .idle else { return [] }
      if active == nil, !selectNext(now: now, preferPushed: true) {
        status = "No pending approvals."
        return []
      }
      // Replaying means it must be heard again before it can be answered.
      heardTarget = nil
      heardAt = nil
      queuedSpeech = nil
      if sessionActive, playback == .idle {
        return speakPrompt()
      }
      status = "Requesting audio…"
      return [.requestAudioSession]

    case .sessionActivated(let route, let now):
      sessionActive = true
      if capture == .awaitingSession {
        capture = .capturing
        status = "Listening for your reply…"
        return [.startCapture]
      }
      guard playback == .idle, capture == .idle else { return [] }
      let snapshot = AudioRouteSnapshot(
        route: route.route, inCall: route.inCall, mediaPlaying: route.mediaPlaying, pushToTalkSessionActive: true
      )
      if let queued = queuedSpeech {
        queuedSpeech = nil
        if case .hold(let reason) = planAudioPlayback(quiet: isQuiet(at: now), snapshot: snapshot) {
          status = "Held (\(reason.rawValue)). Nothing was played on another output."
          return [.releaseAudioSession]
        }
        playback = .speaking(queued.kind)
        return [.speak(queued.text, queued.kind)]
      }
      guard let active, active.target != heardTarget else {
        return [.releaseAudioSession]
      }
      if case .hold(let reason) = planAudioPlayback(quiet: isQuiet(at: now), snapshot: snapshot) {
        status = "Held (\(reason.rawValue)). The prompt is kept; nothing was played on another output."
        return [.releaseAudioSession]
      }
      return speakPrompt()

    case .sessionDeactivated:
      sessionActive = false
      var effects: [AudioApprovalEffect] = []
      if case .speaking(let kind) = playback {
        playback = .idle
        effects.append(.stopSpeaking)
        if kind == .prompt { clearHeard() }
      }
      if capture == .capturing {
        // The session ended without the transmission ending normally.
        capture = .idle
        effects.append(.cancelCapture)
        status = "Audio ended during your reply. Nothing was decided."
      }
      return effects

    case .playbackFinished(let completed, let now):
      guard case .speaking(let kind) = playback else { return [] }
      playback = .idle
      if kind == .prompt {
        if completed, let target = active?.target {
          heardTarget = target
          heardAt = now
          status = "Waiting for a Push to Talk reply."
        } else {
          clearHeard()
          status = "The prompt did not finish playing. Replay it before answering."
        }
      } else if kind == .info, completed, heardTarget != nil {
        // More detail on the same prompt keeps the reply window open.
        heardAt = now
        status = "Waiting for a Push to Talk reply."
      }
      return [.releaseAudioSession]

    case .transmitBegan(let initiated, let now):
      guard initiated else {
        status = "Ignored a transmission that was not started by you."
        return []
      }
      guard !isQuiet(at: now) else { return [] }
      guard deciding == nil else {
        status = "Still sending the last decision."
        return []
      }
      guard let heardTarget, heardTarget == active?.target, let heardAt else {
        status = "Nothing to answer. Play the prompt first."
        return []
      }
      guard now.timeIntervalSince(heardAt) <= AudioApprovalFeature.replyWindow else {
        clearHeard()
        status = "The prompt expired. Play it again before answering."
        return []
      }
      var effects: [AudioApprovalEffect] = []
      if case .speaking = playback {
        playback = .idle
        effects.append(.stopSpeaking)
      }
      queuedSpeech = nil
      if sessionActive {
        capture = .capturing
        status = "Listening for your reply…"
        effects.append(.startCapture)
      } else {
        capture = .awaitingSession
        status = "Waiting for the microphone…"
      }
      return effects

    case .transmitEnded(_, let interrupted):
      switch capture {
      case .capturing:
        if interrupted {
          capture = .idle
          status = "Reply interrupted. Nothing was decided."
          return [.cancelCapture]
        }
        capture = .finishing
        status = "Understanding your reply…"
        return [.finishCapture]
      case .awaitingSession:
        capture = .idle
        status = "Reply ended before the microphone started. Nothing was decided."
        return []
      case .idle, .finishing:
        return []
      }

    case .captureFailed(let message):
      capture = .idle
      status = "Reply not captured: \(message) Nothing was decided."
      return []

    case .transcriptReady(let transcript, let now):
      guard capture == .finishing else { return [] }
      capture = .idle
      return handleReply(transcript, now: now)

    case .routeChanged(let route):
      guard route.route != .headset else { return [] }
      let wasBusy = playback != .idle || capture != .idle || heardTarget != nil
      var effects = abandonTransientAudio()
      guard wasBusy || active != nil else { return effects }
      effects.append(.releaseAudioSession)
      status = "Headset disconnected. The prompt is kept; nothing moved to the speaker and nothing was decided."
      return effects

    case .interrupted:
      var effects = abandonTransientAudio()
      effects.append(.releaseAudioSession)
      status = "Audio was interrupted. Nothing was decided; play the prompt again when ready."
      return effects

    case .decisionSucceeded(let target, let outcome):
      guard deciding == target else { return [] }
      deciding = nil
      let text = AudioApprovalSpeech.acknowledgement(outcome)
      answered[target.promptKey] = text
      lastAcknowledgement = text
      if active?.target == target {
        active = nil
        activeReceipt = nil
      }
      if pushedTarget == target { pushedTarget = nil }
      clearHeard()
      status = "Decision recorded on the Mac."
      return queueSpeech(text, .acknowledgement)

    case .decisionFailed(let target, let message):
      guard deciding == target else { return [] }
      deciding = nil
      clearHeard()
      let text = "Not applied. \(message) Nothing was changed."
      lastAcknowledgement = text
      status = "Decision not applied."
      return queueSpeech("Not applied. Nothing was changed.", .acknowledgement)
    }
  }

  // MARK: Internals

  private mutating func handleReply(_ transcript: String, now: Date) -> [AudioApprovalEffect] {
    guard let active, let target = active.target, heardTarget == target else {
      status = "The prompt changed while you spoke. Nothing was decided."
      return []
    }
    switch AudioSpokenReplyParser.intent(for: transcript) {
    case .unclear:
      lastAcknowledgement = "Did not understand. Nothing was decided."
      heardAt = now
      return queueSpeech("Sorry, I didn't catch that. Nothing was decided. Say yes, no, why, or later.", .info)
    case .why:
      return queueSpeech(AudioApprovalSpeech.why(for: active), .info)
    case .read:
      return queueSpeech(AudioApprovalSpeech.read(for: active), .info)
    case .snooze:
      let until = now.addingTimeInterval(AudioApprovalFeature.snoozeInterval)
      snoozedUntil[target.promptKey] = until
      self.active = nil
      activeReceipt = nil
      if pushedTarget == target { pushedTarget = nil }
      clearHeard()
      lastAcknowledgement = "Snoozed for 30 minutes. Nothing was decided."
      status = "Snoozed this prompt."
      return [.sendSnooze(target, until: until)] + queueSpeech("Okay, later.", .acknowledgement)
    case .approve, .reject:
      let decision = AudioSpokenReplyParser.intent(for: transcript) == .approve ? "approved" : "rejected"
      if let prior = answered[target.promptKey] {
        lastAcknowledgement = prior
        return queueSpeech("Already answered.", .acknowledgement)
      }
      let receipt = activeReceipt ?? makeReceipt()
      activeReceipt = receipt
      deciding = target
      status = "Sending the decision to the Mac…"
      // The Mac requires a reason to reject. Record the fact of a spoken "no" rather than inventing one.
      let note = decision == "rejected" ? "Rejected by spoken reply (walkie-talkie approval)." : nil
      return [.sendDecision(active, decision: decision, note: note, receipt: receipt)]
    }
  }

  /// Applies the latest host list: withdraws a prompt that is no longer pending, resolves a pushed
  /// identity, and rejects a stale push.
  private mutating func reconcileWithHost(now: Date) -> [AudioApprovalEffect] {
    snoozedUntil = snoozedUntil.filter { $0.value > now }
    let pending = Set(candidates.compactMap(\.target))
    var effects: [AudioApprovalEffect] = []
    if let target = active?.target, !pending.contains(target), deciding != target {
      effects += abandonTransientAudio()
      effects.append(.releaseAudioSession)
      active = nil
      activeReceipt = nil
      status = "That prompt was decided elsewhere or changed. Nothing was decided here."
    }
    guard let pushed = pushedTarget else { return effects }
    if !pending.contains(pushed) {
      pushedTarget = nil
      if active == nil {
        status = "Ignored a stale prompt that is no longer pending."
        effects.append(.releaseAudioSession)
      }
      return effects
    }
    // Never switch the prompt someone may be answering.
    guard active == nil, deciding == nil, capture == .idle else { return effects }
    guard joined, !isQuiet(at: now) else { return effects + [.releaseAudioSession] }
    guard selectNext(now: now, preferPushed: true) else { return effects }
    if sessionActive, playback == .idle {
      return effects + speakPrompt()
    }
    status = "Requesting audio…"
    return effects + [.requestAudioSession]
  }

  /// Selects the pushed target when it is pending, otherwise the oldest eligible prompt.
  private mutating func selectNext(now: Date, preferPushed: Bool) -> Bool {
    if preferPushed, let pushed = pushedTarget,
       let candidate = candidates.first(where: { $0.target == pushed }),
       answered[pushed.promptKey] == nil {
      setActive(candidate)
      return true
    }
    guard let next = selectAudioApprovalCandidate(
      from: candidates,
      snoozedUntil: snoozedUntil,
      answeredKeys: Set(answered.keys),
      now: now
    ) else { return false }
    setActive(next.candidate)
    return true
  }

  private mutating func setActive(_ candidate: AudioApprovalCandidate) {
    if active?.target != candidate.target {
      activeReceipt = nil
      clearHeard()
    }
    active = candidate
  }

  private mutating func speakPrompt() -> [AudioApprovalEffect] {
    guard let active else { return [.releaseAudioSession] }
    playback = .speaking(.prompt)
    clearHeard()
    status = "Playing the prompt on the headset…"
    return [.speak(AudioApprovalSpeech.prompt(for: active), .prompt)]
  }

  private mutating func queueSpeech(_ text: String, _ kind: AudioSpeechKind) -> [AudioApprovalEffect] {
    if sessionActive, playback == .idle, capture == .idle {
      playback = .speaking(kind)
      return [.speak(text, kind)]
    }
    queuedSpeech = (text, kind)
    return [.requestAudioSession]
  }

  private mutating func abandonTransientAudio() -> [AudioApprovalEffect] {
    var effects: [AudioApprovalEffect] = []
    if playback != .idle {
      playback = .idle
      effects.append(.stopSpeaking)
    }
    if capture != .idle {
      capture = .idle
      effects.append(.cancelCapture)
    }
    queuedSpeech = nil
    clearHeard()
    return effects
  }

  private mutating func clearHeard() {
    heardTarget = nil
    heardAt = nil
  }
}
