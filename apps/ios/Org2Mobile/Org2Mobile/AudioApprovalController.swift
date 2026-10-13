import AVFoundation
import CallKit
import Foundation

/// Speech completion callback. Delegate calls arrive on AVFoundation threads.
final class AudioApprovalSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let finished: @MainActor @Sendable () -> Void

  init(finished: @escaping @MainActor @Sendable () -> Void) {
    self.finished = finished
    super.init()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let finished = self.finished
    Task { @MainActor in finished() }
  }
}

/// Feature-gated controller for the walkie-talkie approval prototype.
///
/// It never stores a decision. It reads pending approvals from the paired Mac, speaks
/// one prompt at a time on a headset, captures an initiated Push to Talk reply, and sends
/// the decision through the Mac's existing approval gate with the exact run, approval, and
/// fingerprint. The host's answer is what gets acknowledged.
@MainActor
final class AudioApprovalController: ObservableObject {
  @Published private(set) var isEnabled = AudioApprovalFeature.isEnabled
  @Published private(set) var channelJoined = false
  @Published private(set) var isQuiet = UserDefaults.standard.bool(forKey: AudioApprovalFeature.quietDefaultsKey)
  @Published private(set) var phase = "Off"
  @Published private(set) var promptText: String?
  @Published private(set) var acknowledgement: String?

  private weak var remote: MobileRemoteStore?
  private var bridge: AudioApprovalPushToTalkBridge?
  private var speechDelegate: AudioApprovalSpeechDelegate?
  private let synthesizer = AVSpeechSynthesizer()
  private let callObserver = CXCallObserver()
  private let transcriber = MobileVoiceTranscriber()
  private var routeObserver: NSObjectProtocol?
  private var pushToTalkSessionActive = false
  private var isSpeaking = false
  private var isCapturingReply = false
  private var active: (target: AudioApprovalTarget, entry: ApprovalEntry)?
  private var snoozedUntil: [AudioApprovalTarget: Date] = [:]
  /// Idempotent receipts for this app session, keyed by the exact prompt identity.
  private var receipts: [String: String] = [:]

  /// Called once from the app root. Creates nothing unless the feature is enabled on this device.
  func attach(remote: MobileRemoteStore) {
    self.remote = remote
    guard isEnabled, bridge == nil else { return }
    let bridge = AudioApprovalPushToTalkBridge { [weak self] event in
      self?.handle(event)
    }
    self.bridge = bridge
    bridge.start()
    phase = "Starting Push to Talk…"
    observeRouteChanges()
  }

  func join() {
    guard isEnabled, let bridge else { return }
    phase = "Joining channel…"
    bridge.join()
  }

  func leave() {
    bridge?.leave()
    channelJoined = false
    stopSpeaking()
    phase = "Left channel. No prompts will reach the headset."
  }

  func setQuiet(_ quiet: Bool) {
    isQuiet = quiet
    UserDefaults.standard.set(quiet, forKey: AudioApprovalFeature.quietDefaultsKey)
    if quiet {
      stopSpeaking()
      phase = "Quiet: prompts are held on the Mac until you turn quiet off."
    }
  }

  // MARK: Channel events

  private func handle(_ event: AudioApprovalChannelEvent) {
    switch event {
    case .managerReady(let failure):
      phase = failure.map { "Push to Talk unavailable: \($0)" } ?? "Ready. Join the channel to allow prompts."
    case .joined:
      channelJoined = true
      phase = "Joined. Prompts can reach a connected headset."
    case .left:
      channelJoined = false
      phase = "Not joined."
    case .transmitBegan(let initiated):
      // Only a user-initiated press starts a reply. Other transmissions are ignored.
      guard initiated, active != nil, !isQuiet else { return }
      beginReplyCapture()
    case .transmitEnded(let initiated):
      guard initiated, isCapturingReply else { return }
      endReplyCapture()
    case .incomingPush:
      Task { await offerPendingApproval(refreshFirst: true) }
    case .ephemeralToken:
      // The token is not yet sent to the Mac. Server registration is a remaining dependency.
      phase = "Push token received. Server registration is not wired in this build."
    case .audioSessionActivated:
      pushToTalkSessionActive = true
      Task { await offerPendingApproval(refreshFirst: false) }
    case .audioSessionDeactivated:
      pushToTalkSessionActive = false
      stopSpeaking()
      phase = "Audio session ended. The prompt is kept and not moved to another output."
    case .failed(let message):
      phase = message
    }
  }

  // MARK: Prompts

  private func offerPendingApproval(refreshFirst: Bool) async {
    guard isEnabled, let remote else { return }
    if refreshFirst {
      await remote.refreshWorkspace(reportsErrors: false)
    }
    let answered = Set(receipts.keys)
    guard let selected = selectAudioApprovalTarget(
      from: remote.workspaceApprovals,
      snoozedUntil: snoozedUntil,
      answeredKeys: answered,
      now: Date()
    ) else {
      active = nil
      promptText = nil
      if phase.hasPrefix("Playing") || phase.hasPrefix("Waiting") { phase = "No pending approvals." }
      return
    }
    if active?.target != selected.target {
      active = selected
      promptText = audioApprovalPromptText(for: selected.entry)
      acknowledgement = nil
    }
    speak(promptText ?? "", isPrompt: true)
  }

  /// Plays only when the route, session, call, and quiet checks all allow it. Otherwise the prompt stays queued.
  private func speak(_ text: String, isPrompt: Bool) {
    guard !text.isEmpty else { return }
    switch planAudioPlayback(quiet: isQuiet, snapshot: currentRouteSnapshot()) {
    case .hold(let reason):
      phase = "Held (\(reason.rawValue)). Nothing was played on another output."
    case .play:
      let delegate = AudioApprovalSpeechDelegate { [weak self] in
        self?.isSpeaking = false
        self?.phase = isPrompt ? "Waiting for a Push to Talk reply." : "Done."
      }
      speechDelegate = delegate
      synthesizer.delegate = delegate
      isSpeaking = true
      phase = "Playing on headset…"
      synthesizer.speak(AVSpeechUtterance(string: text))
    }
  }

  private func stopSpeaking() {
    if isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    isSpeaking = false
  }

  private func currentRouteSnapshot() -> AudioRouteSnapshot {
    let session = AVAudioSession.sharedInstance()
    return AudioRouteSnapshot(
      route: AudioRouteClassifier.classify(outputPorts: session.currentRoute.outputs.map(\.portType)),
      inCall: callObserver.calls.contains { !$0.hasEnded },
      mediaPlaying: session.isOtherAudioPlaying,
      pushToTalkSessionActive: pushToTalkSessionActive
    )
  }

  private func observeRouteChanges() {
    guard routeObserver == nil else { return }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.routeChanged() }
    }
  }

  private func routeChanged() {
    guard currentRouteSnapshot().route != .headset else { return }
    guard isSpeaking || active != nil else { return }
    stopSpeaking()
    phase = "Headset disconnected. The prompt is kept; nothing moved to the speaker."
  }

  // MARK: Replies

  private func beginReplyCapture() {
    isCapturingReply = true
    phase = "Listening for your reply…"
    Task {
      await transcriber.start()
      if let message = transcriber.errorMessage {
        isCapturingReply = false
        phase = "Reply not captured: \(message). Nothing was decided."
      }
    }
  }

  private func endReplyCapture() {
    isCapturingReply = false
    Task {
      let transcript = await transcriber.finish()
      await handleReply(transcript)
    }
  }

  func handleReply(_ transcript: String) async {
    guard let selected = active else { return }
    let target = selected.target
    switch AudioSpokenReplyParser.intent(for: transcript) {
    case .unclear:
      acknowledgement = "Did not understand. Nothing was decided."
    case .why:
      speak(selected.entry.action ?? selected.entry.title, isPrompt: false)
    case .read:
      speak(selected.entry.body.isEmpty ? (selected.entry.action ?? selected.entry.title) : selected.entry.body, isPrompt: false)
    case .snooze:
      snoozedUntil[target] = Date().addingTimeInterval(AudioApprovalFeature.snoozeInterval)
      active = nil
      promptText = nil
      acknowledgement = "Snoozed for 30 minutes. Nothing was decided."
    case .approve, .reject:
      await sendDecision(selected, intent: AudioSpokenReplyParser.intent(for: transcript))
    }
  }

  private func sendDecision(_ selected: (target: AudioApprovalTarget, entry: ApprovalEntry), intent: AudioSpokenIntent) async {
    let key = selected.target.promptKey
    if let prior = receipts[key] {
      acknowledgement = "Already answered: \(prior)"
      return
    }
    guard let remote else { return }
    let decision = intent == .approve ? "approved" : "rejected"
    // The Mac requires a reason to reject. A spoken "no" records that fact rather than inventing one.
    let note = decision == "rejected" ? "Rejected by spoken reply (audio approval prototype)." : nil
    phase = "Sending decision to the Mac…"
    do {
      let snapshot = try await remote.decideApprovalExactly(selected.entry, decision: decision, note: note)
      let ack = Self.decisionAcknowledgement(
        snapshot: snapshot,
        approvalID: selected.target.approvalID,
        runID: selected.target.runID,
        decision: decision
      )
      receipts[key] = ack
      acknowledgement = ack
      active = nil
      promptText = nil
      phase = "Decision sent."
      speak("Recorded.", isPrompt: false)
    } catch {
      acknowledgement = "Not applied: \(error.localizedDescription) Nothing was changed."
      phase = "Decision not applied."
    }
  }

  /// Decision acknowledgment comes from the host's returned state. Execution acknowledgment is a
  /// remaining dependency: the snapshot does not yet carry the run's status after a decision.
  static func decisionAcknowledgement(
    snapshot: MobileRemoteWorkspaceSnapshot,
    approvalID: String,
    runID: String,
    decision: String
  ) -> String {
    let stillPending = snapshot.approvals.contains { $0.approvalID == approvalID && $0.status == "pending" }
    if stillPending {
      return "The Mac has not confirmed the \(decision) decision yet."
    }
    return "Decision recorded on the Mac: \(decision) for run \(runID), approval \(approvalID). Execution is not yet acknowledged."
  }
}
