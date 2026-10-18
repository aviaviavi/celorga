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
  static let voiceIdentifierDefaultsKey = "celorga.audioApprovals.voiceIdentifier"
  static let snoozeInterval: TimeInterval = 30 * 60
  /// A reply binds only to a prompt heard this recently.
  static let replyWindow: TimeInterval = 120
  /// Match the host's real-time window even when iOS restores an old push or an older host
  /// delivers a backlog. Pending approvals remain available for review in the app.
  static let realtimeWindow: TimeInterval = 10 * 60
  /// After a prompt finishes playing, a newly pushed prompt waits this long before it may
  /// replace it, so it cannot cut in while the person starts to answer. The Mac separately
  /// spaces pushes to one device (`AudioApprovalPromptPolicy.answerWindow`).
  static let answerGrace: TimeInterval = 20
  /// Push to Talk can activate before Bluetooth has finished changing `currentRoute` from the
  /// receiver to an already-selected headset. Keep the system session briefly so that route
  /// change can arrive; never play during this grace unless the route becomes a headset.
  /// Physical traces from a backgrounded phone show AirPods HFP taking about six seconds, and
  /// the route-change notification alone did not reliably reach the app in that time.
  static let headsetRouteSettleInterval: TimeInterval = 10
  /// While the route settles, the phone rereads `currentRoute` this often instead of relying
  /// only on route-change notifications.
  static let routeCheckInterval: TimeInterval = 0.25
  /// While Celorga is the active remote participant, iOS disables the Talk button. A push or
  /// audio request that has not produced playback within this time releases it.
  static let remoteParticipantHoldLimit: TimeInterval = 15

  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: defaultsKey)
  }
}

enum AudioApprovalVoiceQuality: Int, Sendable {
  case standard = 1, enhanced = 2, premium = 3

  var label: String {
    switch self {
    case .standard: "Standard"
    case .enhanced: "Enhanced"
    case .premium: "Premium"
    }
  }
}

/// Installed voices only. Identifiers survive list ordering changes and new voice downloads.
struct AudioApprovalVoiceOption: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let language: String
  let quality: AudioApprovalVoiceQuality

  /// Respect a chosen voice, otherwise upgrade within the preferred region before trying
  /// another region of the same language. Never automatically switch to another language.
  static func select(from voices: [Self], preferredIdentifier: String?, language: String) -> Self? {
    if let preferredIdentifier, let chosen = voices.first(where: { $0.id == preferredIdentifier }) {
      return chosen
    }
    let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
    let base = normalized.split(separator: "-").first
    let matching = voices.filter {
      $0.language.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first == base
    }
    let regional = matching.filter {
      $0.language.replacingOccurrences(of: "_", with: "-").lowercased() == normalized
    }
    return (regional.isEmpty ? matching : regional).sorted {
      if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
      return $0.id < $1.id
    }.first
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
struct AudioApprovalTarget: Codable, Hashable, Sendable {
  let runID: String
  let approvalID: String
  let fingerprint: String

  /// Stable per-prompt key. Matches the Mac host's prompt key.
  var promptKey: String {
    "\(runID)|\(approvalID)|\(fingerprint)"
  }
}

/// Recognition and server acceptance are separate facts. This local receipt never authorizes work.
struct AudioApprovalReplyRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let createdAt: Date
  let title: String
  let target: AudioApprovalTarget?
  var transcript: String?
  var interpretation: String?
  var outcome: String
}

/// Speech synthesis can finish before its buffered audio has reached the headset.
/// Every callback is scoped to one playback so canceled speech cannot finish its replacement.
struct AudioSpeechPlaybackProgress {
  private(set) var id: UUID?
  private var pendingBuffers = 0
  private var renderingEnded = false
  private var playedAudio = false

  mutating func start(_ id: UUID) {
    self.id = id
    pendingBuffers = 0
    renderingEnded = false
    playedAudio = false
  }

  mutating func stop() { id = nil; pendingBuffers = 0; renderingEnded = false; playedAudio = false }

  mutating func enqueued(_ id: UUID) {
    guard self.id == id else { return }
    pendingBuffers += 1
  }

  mutating func played(_ id: UUID) -> Bool {
    guard self.id == id, pendingBuffers > 0 else { return false }
    pendingBuffers -= 1
    playedAudio = true
    return renderingEnded && pendingBuffers == 0
  }

  mutating func renderingFinished(_ id: UUID) -> Bool {
    guard self.id == id else { return false }
    renderingEnded = true
    return pendingBuffers == 0 && playedAudio
  }
}

/// Synthesis callbacks cross into the main actor asynchronously; preserve their audio order.
struct AudioSpeechBufferOrdering<Value> {
  private var nextIndex = 0
  private var waiting: [Int: Value] = [:]

  mutating func insert(_ value: Value, at index: Int) -> [Value] {
    guard index >= nextIndex else { return [] }
    waiting[index] = value
    var ready: [Value] = []
    while let value = waiting.removeValue(forKey: nextIndex) {
      ready.append(value)
      nextIndex += 1
    }
    return ready
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
  /// "urgent" or nil. Explicit only; age never implies urgency.
  var priority: String? = nil
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

  func isRealtime(at now: Date) -> Bool {
    guard let requestedAt else { return false }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let requested = fractional.date(from: requestedAt) ?? ISO8601DateFormatter().date(from: requestedAt) else {
      return false
    }
    return requested <= now.addingTimeInterval(120)
      && now.timeIntervalSince(requested) <= AudioApprovalFeature.realtimeWindow
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

/// Bounded, identity-free context attached to a delivery receipt: output port types, app
/// state, Push to Talk session state, and a failure reason. The host applies the same filter.
enum AudioApprovalDeliveryDetail {
  static let maxLength = 160

  static func make(outputs: String, appState: String, sessionActive: Bool, reason: String?) -> String {
    var parts = ["out=\(outputs)", "app=\(appState)", "ptt=\(sessionActive ? 1 : 0)"]
    if let reason { parts.append("reason=\(reason)") }
    return sanitize(parts.joined(separator: ";"))
  }

  static func sanitize(_ text: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=;+._-")
    return String(text.filter { allowed.contains($0) }.prefix(maxLength))
  }
}

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
  // A joined approvals channel interrupts media. The system-owned, nonmixing Push to Talk
  // session arbitrates with the other app; its media-playing hint is not a playback veto.
  return .play
}

/// Next pending run approval with a complete identity, minus snoozed and answered prompts:
/// explicitly urgent first, then oldest. Same order as the Mac host.
func selectAudioApprovalCandidate(
  from candidates: [AudioApprovalCandidate],
  snoozedUntil: [String: Date],
  answeredKeys: Set<String>,
  now: Date
) -> (target: AudioApprovalTarget, candidate: AudioApprovalCandidate)? {
  candidates
    .compactMap { candidate in candidate.target.map { ($0, candidate) } }
    .filter { target, candidate in
      candidate.isRealtime(at: now)
        && (snoozedUntil[target.promptKey] ?? .distantPast) <= now && !answeredKeys.contains(target.promptKey)
    }
    .sorted { lhs, rhs in
      let leftUrgent = lhs.1.priority == "urgent"
      let rightUrgent = rhs.1.priority == "urgent"
      if leftUrgent != rightUrgent { return leftUrgent }
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
  /// The approval prompt. It can be answered once it finishes, or by pressing Talk while it plays.
  case prompt
  case info
  case acknowledgement
}

enum AudioApprovalEvent: Sendable, Equatable {
  case enrollmentChanged(joined: Bool)
  case quietChanged(until: Date?, now: Date)
  case approvalsUpdated([AudioApprovalCandidate], now: Date)
  case hostCheckFailed(String)
  /// A Push to Talk notification. `nil` means the payload had no complete identity.
  case pushReceived(AudioApprovalTarget?, now: Date)
  /// The person asked to hear the next prompt, or the current one again.
  case playRequested(now: Date)
  case sessionActivated(AudioRouteSnapshot, now: Date)
  case sessionDeactivated
  /// The speech synthesizer stopped making progress without reporting finish or cancellation.
  case playbackStalled
  case playbackFinished(completed: Bool, now: Date)
  case transmitBegan(initiated: Bool, now: Date)
  /// `interrupted` is true when the system ended the transmission, for example for an incoming push.
  case transmitEnded(initiated: Bool, interrupted: Bool)
  case transcriptReady(String, now: Date)
  case captureFailed(String)
  case routeChanged(AudioRouteSnapshot, now: Date)
  /// The current route, reread on request (`.checkRoute`) while waiting for the headset.
  /// Unlike `.routeChanged`, a non-headset reading never abandons audio.
  case routeChecked(AudioRouteSnapshot, now: Date)
  case interrupted
  case decisionSucceeded(AudioApprovalTarget, AudioDecisionOutcome)
  case decisionFailed(AudioApprovalTarget, String)
  /// Clock tick requested through `.scheduleTick`, so a deferred prompt is not stranded.
  case tick(now: Date)
}

extension AudioApprovalEvent {
  var now: Date? {
    switch self {
    case .quietChanged(_, let now), .approvalsUpdated(_, let now), .pushReceived(_, let now),
         .playRequested(let now), .sessionActivated(_, let now), .playbackFinished(_, let now),
         .transmitBegan(_, let now), .transcriptReady(_, let now), .tick(let now),
         .routeChanged(_, let now), .routeChecked(_, let now):
      return now
    default:
      return nil
    }
  }
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
  /// Deliver `.tick` after this many seconds.
  case scheduleTick(after: TimeInterval)
  /// Deliver `.routeChecked` with the current route after this many seconds.
  case checkRoute(after: TimeInterval)
}

/// The audio approval state machine. Pure: every input is an event, every output an effect.
///
/// Safety rules it enforces:
/// - Only a prompt that finished playing, or that the person interrupted by pressing Talk while
///   it was being read, can be answered, and only for `replyWindow` seconds.
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
  private(set) var replyHistory: [AudioApprovalReplyRecord] = []
  private var currentReplyID: UUID?
  /// A prompt pushed while another was being answered. Taken up once the answer ends.
  private(set) var deferredPush: AudioApprovalTarget?
  /// The person is holding the Push to Talk button.
  private(set) var transmitting = false
  /// Spoken once the button is released, so feedback never talks over the person.
  private(set) var pendingTransmitNotice: (shown: String, spoken: String)?
  private var clock = Date.distantPast
  private var scheduledTick: Date?
  private var headsetRouteSettleUntil: Date?
  /// Last route reported with the active session. Bluetooth HFP commonly switches away from
  /// and back to the headset after activation, so a prompt verified later must not assume it.
  private(set) var knownRoute: AudioRouteClass?
  private var captureEndDeadline: Date?
  /// Celorga may be the system's active remote participant: a push was answered with one, or
  /// receive audio was requested and not yet released. While it is, iOS disables Talk.
  private(set) var holdsRemoteParticipant = false
  /// A pushed prompt is being checked with the Mac.
  private var awaitingHost = false
  /// Receive audio was requested and the system has not yet activated the session.
  private var awaitingAudio = false
  private var remoteHoldDeadline: Date?

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
    if let now = event.now { clock = max(clock, now) }
    // The bridge answers every push it accepts with an active remote participant.
    if case .pushReceived = event { holdsRemoteParticipant = true }
    var effects = handleEvent(event)
    if deferredPush != nil {
      if isAnswering(at: clock) {
        if let heardAt, capture == .idle, playback == .idle, deciding == nil, !transmitting {
          let due = heardAt.addingTimeInterval(AudioApprovalFeature.answerGrace)
          if scheduledTick != due {
            scheduledTick = due
            effects.append(.scheduleTick(after: max(1, due.timeIntervalSince(clock))))
          }
        }
      } else if let target = deferredPush {
        deferredPush = nil
        effects += takePush(target, now: clock)
      }
    }
    return effects + settleRemoteParticipant(after: effects)
  }

  /// Celorga must not remain the active remote participant without a reason: while it is, iOS
  /// shows Celorga as speaking and the Talk button cannot start a reply. Unless the session is
  /// playing, about to play, or checking a pushed prompt, release the participant.
  private mutating func settleRemoteParticipant(after effects: [AudioApprovalEffect]) -> [AudioApprovalEffect] {
    for effect in effects {
      switch effect {
      case .requestAudioSession:
        holdsRemoteParticipant = true
        awaitingAudio = true
      case .releaseAudioSession:
        holdsRemoteParticipant = false
        awaitingAudio = false
        awaitingHost = false
      default:
        break
      }
    }
    guard holdsRemoteParticipant else {
      remoteHoldDeadline = nil
      return []
    }
    // A transmission in progress already owns the channel.
    if transmitting || capture != .idle { return [] }
    let waiting = awaitingHost || awaitingAudio
    guard playback != .idle || headsetRouteSettleUntil != nil || waiting else {
      holdsRemoteParticipant = false
      remoteHoldDeadline = nil
      return [.releaseAudioSession]
    }
    guard waiting else {
      remoteHoldDeadline = nil
      return []
    }
    guard remoteHoldDeadline == nil else { return [] }
    remoteHoldDeadline = clock.addingTimeInterval(AudioApprovalFeature.remoteParticipantHoldLimit)
    return [.scheduleTick(after: AudioApprovalFeature.remoteParticipantHoldLimit)]
  }

  /// Playing, capturing, deciding, or just heard: a new prompt must not cut in.
  func isAnswering(at now: Date) -> Bool {
    if transmitting || playback != .idle || capture != .idle || deciding != nil { return true }
    if let heardAt, now.timeIntervalSince(heardAt) < AudioApprovalFeature.answerGrace { return true }
    return false
  }

  private mutating func handleEvent(_ event: AudioApprovalEvent) -> [AudioApprovalEffect] {
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
      awaitingHost = false
      return reconcileWithHost(now: now)

    case .hostCheckFailed(let message):
      awaitingHost = false
      status = "Could not verify the pushed approval with the Mac: \(message). Nothing was played or decided."
      return [.releaseAudioSession]

    case .pushReceived(let target, let now):
      guard joined else { return [.releaseAudioSession] }
      guard let target else {
        status = "Ignored a prompt without a complete identity."
        return [.releaseAudioSession]
      }
      if isQuiet(at: now) {
        status = "Quiet: a prompt arrived and was held. Nothing played."
        return [.releaseAudioSession]
      }
      if target == active?.target || target == deciding {
        awaitingHost = true
        return [.refreshApprovals]
      }
      if isAnswering(at: now) {
        // Never interrupt an answer in progress; take the new prompt up afterwards.
        deferredPush = target
        status = "Another approval is waiting until you finish this one."
        return []
      }
      return takePush(target, now: now)

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
        return speakPromptWhenHeadset(now: now)
      }
      status = "Requesting audio…"
      return [.requestAudioSession]

    case .sessionActivated(let route, let now):
      sessionActive = true
      awaitingAudio = false
      knownRoute = route.route
      if capture == .awaitingSession {
        capture = .capturing
        status = "Listening for your reply…"
        updateReply(outcome: status)
        return [.startCapture]
      }
      guard playback == .idle, capture == .idle else { return [] }
      if route.route != .headset {
        return waitForHeadset(now: now)
      }
      return beginPlayback(route: route, now: now)

    case .routeChecked(let route, _):
      guard sessionActive, headsetRouteSettleUntil != nil else { return [] }
      knownRoute = route.route
      guard playback == .idle, capture == .idle else { return [] }
      guard route.route == .headset else {
        return [.checkRoute(after: AudioApprovalFeature.routeCheckInterval)]
      }
      return beginPlayback(route: route, now: clock)

    case .sessionDeactivated:
      sessionActive = false
      knownRoute = nil
      headsetRouteSettleUntil = nil
      var effects: [AudioApprovalEffect] = []
      if case .speaking(let kind) = playback {
        playback = .idle
        effects.append(.stopSpeaking)
        if kind == .prompt {
          clearHeard()
          status = "The prompt did not finish playing. Replay it before answering."
        } else {
          status = "Audio ended. See the reply result in Approvals."
        }
      }
      if capture == .capturing {
        // didDeactivate and didEndTransmitting may arrive in either order. Keep recognition
        // alive briefly for the normal button-release event; the mic is already stopped by iOS.
        captureEndDeadline = clock.addingTimeInterval(0.5)
        effects.append(.scheduleTick(after: 0.5))
      } else if capture == .awaitingSession {
        // The session ended before the microphone could start.
        capture = .idle
        effects.append(.cancelCapture)
        effects += terminal("Audio ended during your reply. Nothing was decided.")
      }
      return effects

    case .playbackStalled:
      guard case .speaking(let kind) = playback else { return [] }
      playback = .idle
      if kind == .prompt { clearHeard() }
      status = kind == .prompt
        ? "Audio playback stopped unexpectedly. Replay the prompt before answering."
        : "Audio playback stopped unexpectedly. The audio session was released."
      return [.stopSpeaking, .releaseAudioSession]

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
      transmitting = true
      let record = AudioApprovalReplyRecord(
        id: UUID(), createdAt: now, title: active?.title ?? "No active approval",
        target: active?.target, outcome: "Waiting for the microphone…"
      )
      currentReplyID = record.id
      replyHistory.insert(record, at: 0)
      replyHistory = Array(replyHistory.prefix(50))
      pendingTransmitNotice = nil
      guard !isQuiet(at: now) else {
        return reject("Quiet is on. Nothing was decided.")
      }
      guard deciding == nil else {
        return reject("Still sending your last decision. Nothing new was decided.")
      }
      var effects: [AudioApprovalEffect] = []
      if case .speaking(.prompt) = playback, let target = active?.target {
        // Pressing Talk during the readout answers the prompt being read, so a long approval
        // never has to be heard to the end. The channel is full duplex for this reason.
        playback = .idle
        effects.append(.stopSpeaking)
        heardTarget = target
        heardAt = now
        updateReply(outcome: "Readout interrupted by your reply.")
      }
      guard let heardTarget, heardTarget == active?.target, let heardAt else {
        return reject("Nothing to answer. Nothing was decided. Play the prompt first.")
      }
      guard now.timeIntervalSince(heardAt) <= AudioApprovalFeature.replyWindow else {
        clearHeard()
        return reject("That prompt expired. Nothing was decided. Play it again before answering.")
      }
      if case .speaking = playback {
        playback = .idle
        effects.append(.stopSpeaking)
      }
      queuedSpeech = nil
      if sessionActive {
        capture = .capturing
        status = "Listening for your reply…"
        updateReply(outcome: status)
        effects.append(.startCapture)
      } else {
        capture = .awaitingSession
        status = "Waiting for the microphone…"
      }
      return effects

    case .transmitEnded(_, let interrupted):
      captureEndDeadline = nil
      transmitting = false
      switch capture {
      case .capturing:
        if interrupted {
          capture = .idle
          return [.cancelCapture] + terminal("Reply interrupted. Nothing was decided.")
        }
        capture = .finishing
        status = "Understanding your reply…"
        updateReply(outcome: status)
        return [.finishCapture]
      case .awaitingSession:
        capture = .idle
        return terminal("The microphone did not start. Nothing was decided.")
      case .idle, .finishing:
        guard let notice = pendingTransmitNotice else { return [] }
        pendingTransmitNotice = nil
        return terminal(notice.shown, spoken: notice.spoken)
      }

    case .captureFailed(let message):
      capture = .idle
      return terminal("Reply not captured: \(message) Nothing was decided.", spoken: "I couldn't hear your reply. Nothing was decided.")

    case .tick(let now):
      if let due = captureEndDeadline, now >= due, capture == .capturing {
        captureEndDeadline = nil
        capture = .idle
        transmitting = false
        return [.cancelCapture] + terminal("Audio ended during your reply. Nothing was decided.")
      }
      if let due = remoteHoldDeadline, now >= due, holdsRemoteParticipant,
         awaitingHost || awaitingAudio, playback == .idle, headsetRouteSettleUntil == nil {
        remoteHoldDeadline = nil
        status = active == nil
          ? "The Mac did not confirm the prompt in time. Talk is available; nothing was decided."
          : "Audio did not start in time. Talk is available; play the prompt again when ready."
        return [.releaseAudioSession]
      }
      if let due = headsetRouteSettleUntil, now >= due {
        headsetRouteSettleUntil = nil
        status = "Held (no-headset). The prompt is kept; nothing was played on another output."
        return [.releaseAudioSession]
      }
      return []

    case .transcriptReady(let transcript, let now):
      guard capture == .finishing else { return [] }
      capture = .idle
      return handleReply(transcript, now: now)

    case .routeChanged(let route, _):
      if sessionActive { knownRoute = route.route }
      if route.route == .headset {
        guard sessionActive, headsetRouteSettleUntil != nil,
              playback == .idle, capture == .idle else { return [] }
        return beginPlayback(route: route, now: clock)
      }
      // A Push to Talk activation commonly reports the old receiver route before Bluetooth
      // finishes switching. Keep waiting for the bounded grace instead of releasing at the
      // first intermediate route-change notification.
      if sessionActive, headsetRouteSettleUntil != nil { return [] }
      let wasBusy = playback != .idle || capture != .idle || heardTarget != nil
      var effects = abandonTransientAudio()
      guard wasBusy || active != nil else { return effects }
      effects.append(.releaseAudioSession)
      status = "Headset disconnected. The prompt is kept; nothing moved to the speaker and nothing was decided."
      updateReply(outcome: status)
      return effects

    case .interrupted:
      let wasReplying = capture != .idle
      var effects = abandonTransientAudio()
      effects.append(.releaseAudioSession)
      status = "Audio was interrupted. Nothing was decided; play the prompt again when ready."
      if wasReplying {
        lastAcknowledgement = "Audio was interrupted during your reply. Nothing was decided."
        updateReply(outcome: lastAcknowledgement!)
      }
      return effects

    case .decisionSucceeded(let target, let outcome):
      guard deciding == target else { return [] }
      deciding = nil
      let text = AudioApprovalSpeech.acknowledgement(outcome)
      answered[target.promptKey] = text
      lastAcknowledgement = text
      updateReply(outcome: text)
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
      let text = "Not confirmed. \(message) Check the request’s status before retrying."
      lastAcknowledgement = text
      status = "Decision not confirmed."
      updateReply(outcome: text)
      return queueSpeech("Not confirmed. Check the request’s status in Approvals.", .acknowledgement)
    }
  }

  // MARK: Internals

  mutating func restoreReplyHistory(_ history: [AudioApprovalReplyRecord]) {
    replyHistory = Array(history.prefix(50))
    currentReplyID = nil
  }

  private mutating func updateReply(outcome: String) {
    guard let index = replyHistory.firstIndex(where: { $0.id == currentReplyID }) else { return }
    replyHistory[index].outcome = outcome
  }

  /// Switches to a pushed prompt. An earlier prompt that was heard but left unanswered past the
  /// grace window stays pending on the Mac and in the list; it does not block newer prompts.
  private mutating func takePush(_ target: AudioApprovalTarget, now: Date) -> [AudioApprovalEffect] {
    var effects: [AudioApprovalEffect] = []
    if let current = active?.target, current != target {
      effects += abandonTransientAudio()
      active = nil
      activeReceipt = nil
    }
    pushedTarget = target
    awaitingHost = true
    status = "Prompt received. Checking it with the Mac…"
    effects.append(.refreshApprovals)
    return effects
  }

  /// A rejected Push to Talk press. Told once the button is released.
  private mutating func reject(_ text: String) -> [AudioApprovalEffect] {
    status = text
    lastAcknowledgement = text
    updateReply(outcome: text)
    pendingTransmitNotice = (text, text)
    return []
  }

  /// The visible and audible end of one reply attempt.
  private mutating func terminal(_ text: String, spoken: String? = nil) -> [AudioApprovalEffect] {
    status = text
    lastAcknowledgement = text
    updateReply(outcome: text)
    if transmitting {
      pendingTransmitNotice = (text, spoken ?? text)
      return []
    }
    return queueSpeech(spoken ?? text, .acknowledgement)
  }

  private mutating func handleReply(_ transcript: String, now: Date) -> [AudioApprovalEffect] {
    guard let active, let target = active.target, heardTarget == target else {
      return terminal("The prompt changed while you spoke. Nothing was decided.")
    }
    let intent = AudioSpokenReplyParser.intent(for: transcript)
    if let index = replyHistory.firstIndex(where: { $0.id == currentReplyID }) {
      replyHistory[index].transcript = transcript
      replyHistory[index].interpretation = switch intent {
      case .approve: "Approve"
      case .reject: "Reject"
      case .why: "Explain"
      case .read: "Read details"
      case .snooze: "Snooze for 30 minutes"
      case .unclear: "Not understood"
      }
    }
    switch intent {
    case .unclear:
      lastAcknowledgement = "Did not understand. Nothing was decided."
      updateReply(outcome: lastAcknowledgement!)
      heardAt = now
      return queueSpeech("Sorry, I didn't catch that. Nothing was decided. Say yes, no, why, or later.", .info)
    case .why:
      updateReply(outcome: "Explanation requested. Nothing was decided.")
      return queueSpeech(AudioApprovalSpeech.why(for: active), .info)
    case .read:
      updateReply(outcome: "Details requested. Nothing was decided.")
      return queueSpeech(AudioApprovalSpeech.read(for: active), .info)
    case .snooze:
      let until = now.addingTimeInterval(AudioApprovalFeature.snoozeInterval)
      snoozedUntil[target.promptKey] = until
      self.active = nil
      activeReceipt = nil
      if pushedTarget == target { pushedTarget = nil }
      clearHeard()
      lastAcknowledgement = "Snoozed for 30 minutes. Nothing was decided."
      updateReply(outcome: lastAcknowledgement!)
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
      updateReply(outcome: "Sending to the Mac…")
      // A reason is optional; record the fact of a spoken "no" so the history shows how it was decided.
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
    if !pending.contains(pushed) || !candidates.contains(where: { $0.target == pushed && $0.isRealtime(at: now) }) {
      pushedTarget = nil
      if active == nil {
        status = "Ignored an old or withdrawn audio prompt. Review pending requests in Approvals."
        effects.append(.releaseAudioSession)
      }
      return effects
    }
    // Never switch the prompt someone may be answering.
    guard active == nil, deciding == nil, capture == .idle else { return effects }
    guard joined, !isQuiet(at: now) else { return effects + [.releaseAudioSession] }
    guard selectNext(now: now, preferPushed: true) else { return effects }
    // A released session is about to end; ask for it again rather than speak into it.
    if sessionActive, holdsRemoteParticipant, playback == .idle {
      return effects + speakPromptWhenHeadset(now: now)
    }
    status = "Requesting audio…"
    return effects + [.requestAudioSession]
  }

  /// Selects the pushed target when it is pending, otherwise the oldest eligible prompt.
  private mutating func selectNext(now: Date, preferPushed: Bool) -> Bool {
    if preferPushed, let pushed = pushedTarget,
       let candidate = candidates.first(where: { $0.target == pushed }),
       candidate.isRealtime(at: now),
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

  /// The session is already active. Speak only when its last known route is a headset;
  /// otherwise keep the session and wait for Bluetooth to settle. Verification often arrives
  /// while Push to Talk is still on the receiver, and speaking then fails the playback gate.
  private mutating func speakPromptWhenHeadset(now: Date) -> [AudioApprovalEffect] {
    if headsetRouteSettleUntil != nil {
      status = "Connecting the headset…"
      return []
    }
    guard knownRoute == .headset else { return waitForHeadset(now: now) }
    return speakPrompt()
  }

  /// Keeps the system session for a bounded time and polls the route until it is a headset.
  private mutating func waitForHeadset(now: Date) -> [AudioApprovalEffect] {
    if headsetRouteSettleUntil != nil { return [] }
    headsetRouteSettleUntil = now.addingTimeInterval(AudioApprovalFeature.headsetRouteSettleInterval)
    status = "Connecting the headset…"
    return [
      .scheduleTick(after: AudioApprovalFeature.headsetRouteSettleInterval),
      .checkRoute(after: AudioApprovalFeature.routeCheckInterval),
    ]
  }

  private mutating func speakPrompt() -> [AudioApprovalEffect] {
    guard let active else { return [.releaseAudioSession] }
    guard active.isRealtime(at: clock) else {
      self.active = nil
      activeReceipt = nil
      if pushedTarget == active.target { pushedTarget = nil }
      clearHeard()
      status = "This audio prompt expired. Review the pending request in Approvals."
      return [.releaseAudioSession]
    }
    playback = .speaking(.prompt)
    clearHeard()
    status = "Playing the prompt on the headset…"
    return [.speak(AudioApprovalSpeech.prompt(for: active), .prompt)]
  }

  /// Re-evaluates every safety gate after Push to Talk has activated and Bluetooth has settled.
  private mutating func beginPlayback(route: AudioRouteSnapshot, now: Date) -> [AudioApprovalEffect] {
    headsetRouteSettleUntil = nil
    let snapshot = AudioRouteSnapshot(
      route: route.route, inCall: route.inCall, mediaPlaying: route.mediaPlaying,
      pushToTalkSessionActive: true
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
      // A push activates the session before the Mac has confirmed its prompt. Keep the
      // session for that check instead of releasing it and requesting it again.
      if active == nil, awaitingHost { return [] }
      return [.releaseAudioSession]
    }
    if case .hold(let reason) = planAudioPlayback(quiet: isQuiet(at: now), snapshot: snapshot) {
      status = "Held (\(reason.rawValue)). The prompt is kept; nothing was played on another output."
      return [.releaseAudioSession]
    }
    return speakPrompt()
  }

  private mutating func queueSpeech(_ text: String, _ kind: AudioSpeechKind) -> [AudioApprovalEffect] {
    if sessionActive, playback == .idle, capture == .idle {
      guard knownRoute == .headset, headsetRouteSettleUntil == nil else {
        queuedSpeech = (text, kind)
        return waitForHeadset(now: clock)
      }
      playback = .speaking(kind)
      return [.speak(text, kind)]
    }
    queuedSpeech = (text, kind)
    return [.requestAudioSession]
  }

  private mutating func abandonTransientAudio() -> [AudioApprovalEffect] {
    headsetRouteSettleUntil = nil
    captureEndDeadline = nil
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
