import AVFoundation
import Foundation

/// Walkie-talkie audio approvals (prototype). Off unless explicitly enabled on this device.
///
/// This file holds pure policy only: spoken intent, headset-only playback, and
/// prompt selection. It mirrors `src/audioApprovalBroker.ts`. The paired Mac
/// remains the only decision authority; nothing here records a decision.
enum AudioApprovalFeature {
  /// Off by default. Enable on a test device with:
  /// `defaults write org.org2.mobile celorga.audioApprovals.enabled -bool YES`
  static let defaultsKey = "celorga.audioApprovals.enabled"
  static let quietDefaultsKey = "celorga.audioApprovals.quiet"
  static let snoozeInterval: TimeInterval = 30 * 60

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

  /// Stable per-prompt key used for idempotent receipts.
  var promptKey: String {
    "\(runID)|\(approvalID)|\(fingerprint)"
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

/// Pending run approvals the host reports, minus snoozed and already-answered ones.
/// The host list order is kept; the first eligible entry becomes the one active prompt.
func selectAudioApprovalTarget(
  from approvals: [ApprovalEntry],
  snoozedUntil: [AudioApprovalTarget: Date],
  answeredKeys: Set<String>,
  now: Date
) -> (target: AudioApprovalTarget, entry: ApprovalEntry)? {
  for entry in approvals where entry.isRunApproval && entry.status == "pending" {
    guard let runID = entry.runID, let approvalID = entry.approvalID, let fingerprint = entry.fingerprint else {
      continue
    }
    let target = AudioApprovalTarget(runID: runID, approvalID: approvalID, fingerprint: fingerprint)
    if let until = snoozedUntil[target], until > now { continue }
    if answeredKeys.contains(target.promptKey) { continue }
    return (target, entry)
  }
  return nil
}

/// The spoken prompt. Short by design; full details stay on the Mac.
func audioApprovalPromptText(for entry: ApprovalEntry) -> String {
  let action = entry.action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let detail = action.isEmpty ? "" : " \(action)."
  return "Hey Avi, \(entry.title).\(detail) Say yes, no, why, read it to me, or later."
}
