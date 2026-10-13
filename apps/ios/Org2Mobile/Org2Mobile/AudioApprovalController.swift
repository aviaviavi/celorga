import AVFoundation
import CallKit
import Combine
import Foundation

/// Speech completion callback. Delegate calls arrive on AVFoundation threads.
final class AudioApprovalSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let finished: @MainActor @Sendable (_ completed: Bool) -> Void

  init(finished: @escaping @MainActor @Sendable (_ completed: Bool) -> Void) {
    self.finished = finished
    super.init()
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let finished = self.finished
    Task { @MainActor in finished(true) }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let finished = self.finished
    Task { @MainActor in finished(false) }
  }
}

/// Runs walkie-talkie audio approvals on the phone.
///
/// Policy lives in `AudioApprovalSession`; this class only performs its effects. It never stores
/// a decision. Prompts come from the paired Mac (woken by a Push to Talk notification), play
/// only on a headset inside a system-activated Push to Talk audio session, and replies are
/// captured only during a transmission the person started. Decisions go to the Mac's approval
/// gate with the exact run, approval, fingerprint, and a receipt key; the Mac's receipt is
/// what gets spoken back.
@MainActor
final class AudioApprovalController: ObservableObject {
  @Published private(set) var isEnabled = AudioApprovalFeature.isEnabled
  @Published private(set) var channelJoined = false
  @Published private(set) var quietUntil: Date?
  @Published private(set) var phase = "Off"
  @Published private(set) var promptText: String?
  @Published private(set) var acknowledgement: String?
  @Published private(set) var registrationText = "Not registered with the Mac"
  @Published private(set) var pushToTalkAvailable = false
  #if DEBUG
  @Published private(set) var isDemo = false
  /// What the demo would have spoken on the headset.
  @Published private(set) var demoSpoken: String?
  private var demoTranscript = ""
  #endif

  private weak var remote: MobileRemoteStore?
  private var bridge: AudioApprovalPushToTalkBridge?
  private var session = AudioApprovalSession()
  private var speechDelegate: AudioApprovalSpeechDelegate?
  private let synthesizer = AVSpeechSynthesizer()
  private let callObserver = CXCallObserver()
  private let transcriber = MobileVoiceTranscriber()
  private var observers: [NSObjectProtocol] = []
  private var approvalsSubscription: AnyCancellable?
  private var pushToken: Data?
  private var pushToTalkSessionActive = false

  init() {
    let stored = UserDefaults.standard.object(forKey: AudioApprovalFeature.quietUntilDefaultsKey) as? Date
    quietUntil = stored.flatMap { $0 > Date() ? $0 : nil }
    synthesizer.usesApplicationAudioSession = true
  }

  var isQuiet: Bool { (quietUntil ?? .distantPast) > Date() }

  /// Called once from the app root. Creates nothing unless the person turned the feature on.
  func attach(remote: MobileRemoteStore) {
    self.remote = remote
    approvalsSubscription = remote.$workspaceApprovals
      .receive(on: DispatchQueue.main)
      .sink { [weak self] approvals in
        self?.send(.approvalsUpdated(approvals.map(Self.candidate), now: Date()))
      }
    send(.quietChanged(until: quietUntil, now: Date()))
    if isEnabled { startPushToTalk() }
  }

  // MARK: Enrollment

  /// Discoverable opt-in from Settings. Turning it off leaves the channel and removes the token from the Mac.
  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: AudioApprovalFeature.defaultsKey)
    if enabled {
      startPushToTalk()
    } else {
      leave()
      phase = "Off"
    }
  }

  func join() {
    guard isEnabled else { return }
    guard let bridge else { return startPushToTalk() }
    phase = "Joining the approvals channel…"
    bridge.join()
  }

  func leave() {
    bridge?.leave()
    channelJoined = false
    send(.enrollmentChanged(joined: false))
    Task { await registerWithMac(enabled: false) }
  }

  /// Quiet mode (`.distantFuture`), a timed snooze, or `nil` to allow prompts. The Mac holds pushes too.
  func setQuiet(until: Date?) {
    let value = until.flatMap { $0 > Date() ? $0 : nil }
    quietUntil = value
    UserDefaults.standard.set(value, forKey: AudioApprovalFeature.quietUntilDefaultsKey)
    send(.quietChanged(until: value, now: Date()))
    Task { await registerWithMac(enabled: channelJoined) }
  }

  func playNextPrompt() {
    send(.playRequested(now: Date()))
  }

  func refreshRegistration() async {
    guard channelJoined else { return }
    await registerWithMac(enabled: true)
  }

  private func startPushToTalk() {
    guard bridge == nil else { return }
    let bridge = AudioApprovalPushToTalkBridge { [weak self] event in
      self?.handle(event)
    }
    self.bridge = bridge
    bridge.start()
    phase = "Starting Push to Talk…"
    observeAudioSession()
  }

  private func registerWithMac(enabled: Bool) async {
    guard let remote, remote.isPairedForAudioApprovals else {
      registrationText = "Pair this phone with a Mac to receive prompts"
      return
    }
    if enabled, pushToken == nil {
      registrationText = "Waiting for the Push to Talk token"
      return
    }
    do {
      let response = try await remote.setAudioApprovalPushRegistration(
        token: enabled ? pushToken : nil,
        enabled: enabled,
        quietUntil: quietUntil
      )
      if !response.enabled {
        registrationText = "Not registered with the Mac"
      } else if !response.providerConfigured {
        registrationText = "Registered, but the Mac has no APNs key; prompts arrive only while Celorga is open"
      } else if let quietUntil, quietUntil > Date() {
        registrationText = quietUntil == .distantFuture
          ? "Registered; the Mac holds prompts while quiet"
          : "Registered; the Mac holds prompts until \(quietUntil.formatted(date: .omitted, time: .shortened))"
      } else {
        registrationText = "Registered with the Mac"
      }
    } catch {
      registrationText = "Mac registration failed: \(error.localizedDescription)"
    }
  }

  // MARK: Push to Talk events

  private func handle(_ event: AudioApprovalChannelEvent) {
    switch event {
    case .managerReady(let failure):
      pushToTalkAvailable = failure == nil
      phase = failure.map { "Push to Talk unavailable: \($0)" } ?? "Ready. Join the approvals channel to allow prompts."
    case .joined:
      channelJoined = true
      send(.enrollmentChanged(joined: true))
      Task { await registerWithMac(enabled: true) }
    case .left:
      channelJoined = false
      send(.enrollmentChanged(joined: false))
      Task { await registerWithMac(enabled: false) }
    case .transmitBegan(let initiated):
      send(.transmitBegan(initiated: initiated, now: Date()))
    case .transmitEnded(let initiated, let interrupted):
      send(.transmitEnded(initiated: initiated, interrupted: interrupted))
    case .incomingPush(let target):
      send(.pushReceived(target, now: Date()))
    case .ephemeralToken(let token):
      // Ephemeral and in memory only; valid while joined.
      pushToken = token
      Task { await registerWithMac(enabled: channelJoined) }
    case .audioSessionActivated:
      pushToTalkSessionActive = true
      send(.sessionActivated(currentRouteSnapshot(), now: Date()))
    case .audioSessionDeactivated:
      pushToTalkSessionActive = false
      send(.sessionDeactivated)
    case .failed(let message):
      phase = message
    }
  }

  // MARK: State machine

  private func send(_ event: AudioApprovalEvent) {
    let effects = session.handle(event)
    publish()
    for effect in effects { perform(effect) }
  }

  private func publish() {
    phase = session.status
    promptText = session.active.map(AudioApprovalSpeech.prompt(for:))
    acknowledgement = session.lastAcknowledgement
  }

  private func perform(_ effect: AudioApprovalEffect) {
    #if DEBUG
    if isDemo { return performDemo(effect) }
    #endif
    switch effect {
    case .requestAudioSession:
      bridge?.beginReceiving()
    case .releaseAudioSession:
      bridge?.finishReceiving()
    case .speak(let text, let kind):
      speak(text, kind: kind)
    case .stopSpeaking:
      if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    case .startCapture:
      Task {
        await transcriber.start(managesAudioSession: false)
        if let message = transcriber.errorMessage {
          send(.captureFailed(message))
        }
      }
    case .finishCapture:
      Task {
        let transcript = await transcriber.finish()
        send(.transcriptReady(transcript, now: Date()))
      }
    case .cancelCapture:
      transcriber.cancel()
    case .refreshApprovals:
      Task {
        await remote?.refreshWorkspace(reportsErrors: false)
        // Deliver the current list even when the refresh failed, so a push never waits forever.
        send(.approvalsUpdated((remote?.workspaceApprovals ?? []).map(Self.candidate), now: Date()))
      }
    case .sendDecision(let candidate, let decision, let note, let receipt):
      sendDecision(candidate, decision: decision, note: note, receipt: receipt)
    case .scheduleTick(let delay):
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        self?.send(.tick(now: Date()))
      }
    case .sendSnooze(let target, let until):
      Task {
        do {
          _ = try await remote?.snoozeAudioApproval(target, until: until)
        } catch {
          acknowledgement = "Snoozed on this phone; the Mac could not be told: \(error.localizedDescription)"
        }
      }
    }
  }

  /// Plays only when the route, session, call, and quiet checks pass at this moment.
  private func speak(_ text: String, kind: AudioSpeechKind) {
    switch planAudioPlayback(quiet: isQuiet, snapshot: currentRouteSnapshot()) {
    case .hold:
      // Report an incomplete playback: a prompt that was not heard cannot be answered.
      send(.playbackFinished(completed: false, now: Date()))
    case .play:
      let delegate = AudioApprovalSpeechDelegate { [weak self] completed in
        self?.send(.playbackFinished(completed: completed, now: Date()))
      }
      speechDelegate = delegate
      synthesizer.delegate = delegate
      synthesizer.speak(AVSpeechUtterance(string: text))
    }
  }

  private func sendDecision(_ candidate: AudioApprovalCandidate, decision: String, note: String?, receipt: String) {
    guard let target = candidate.target else { return }
    guard let remote, let entry = remote.workspaceApprovals.first(where: { $0.id == candidate.id }) else {
      send(.decisionFailed(target, "The approval is no longer listed by the Mac."))
      return
    }
    Task {
      do {
        let snapshot = try await remote.decideApprovalExactly(entry, decision: decision, note: note, receipt: receipt)
        if let hostReceipt = snapshot.approvalDecisionReceipt,
           hostReceipt.runID == target.runID,
           hostReceipt.approvalID == target.approvalID {
          send(.decisionSucceeded(target, AudioDecisionOutcome(
            decision: hostReceipt.decision,
            runStatus: hostReceipt.runStatus,
            pendingApprovalCount: hostReceipt.pendingApprovalCount,
            continuation: hostReceipt.continuation,
            duplicate: hostReceipt.duplicate ?? false
          )))
        } else if snapshot.approvals.contains(where: { $0.approvalID == target.approvalID && $0.status == "pending" }) {
          send(.decisionFailed(target, "The Mac did not confirm the decision."))
        } else {
          // An older Mac without receipts: the approval left the pending queue.
          send(.decisionSucceeded(target, AudioDecisionOutcome(
            decision: decision, runStatus: "unknown", pendingApprovalCount: 0, continuation: "recorded", duplicate: false
          )))
        }
      } catch {
        send(.decisionFailed(target, error.localizedDescription))
      }
    }
  }

  // MARK: Audio session observation

  private func currentRouteSnapshot() -> AudioRouteSnapshot {
    let audioSession = AVAudioSession.sharedInstance()
    return AudioRouteSnapshot(
      route: AudioRouteClassifier.classify(outputPorts: audioSession.currentRoute.outputs.map(\.portType)),
      inCall: callObserver.calls.contains { !$0.hasEnded },
      mediaPlaying: audioSession.isOtherAudioPlaying,
      pushToTalkSessionActive: pushToTalkSessionActive
    )
  }

  private func observeAudioSession() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        #if DEBUG
        if self.isDemo { return }
        #endif
        self.send(.routeChanged(self.currentRouteSnapshot()))
      }
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
      Task { @MainActor in self?.send(.interrupted) }
    })
  }

  // MARK: Mapping

  static func candidate(_ entry: ApprovalEntry) -> AudioApprovalCandidate {
    AudioApprovalCandidate(
      id: entry.id,
      title: entry.title,
      action: entry.action,
      body: entry.body,
      riskClass: entry.riskClass,
      requestedFrom: entry.requestedFrom,
      requestedAt: entry.requestedAt,
      priority: entry.priority,
      status: entry.status,
      isRunApproval: entry.isRunApproval,
      runID: entry.runID,
      approvalID: entry.approvalID,
      fingerprint: entry.fingerprint
    )
  }

  // MARK: Simulator demo

  #if DEBUG
  /// Debug builds only. Runs the same state machine and the same exact-identity decision on the
  /// paired Mac, with simulated headset, session, and speech so it works in the Simulator.
  /// Prompts and acknowledgements are shown as text instead of spoken.
  func setDemo(_ on: Bool) {
    isDemo = on
    if on {
      phase = "Demo: simulated headset and Push to Talk"
      send(.enrollmentChanged(joined: true))
    } else {
      send(.enrollmentChanged(joined: false))
    }
  }

  func demoPlayNext() {
    guard isDemo else { return }
    send(.playRequested(now: Date()))
  }

  func demoReply(_ transcript: String) {
    guard isDemo else { return }
    demoTranscript = transcript
    send(.transmitBegan(initiated: true, now: Date()))
    send(.sessionActivated(Self.demoRoute, now: Date()))
    send(.transmitEnded(initiated: true, interrupted: false))
  }

  private static let demoRoute = AudioRouteSnapshot(route: .headset, inCall: false, mediaPlaying: false, pushToTalkSessionActive: true)

  /// Simulated hardware events are delivered synchronously so their order is deterministic.
  private func performDemo(_ effect: AudioApprovalEffect) {
    switch effect {
    case .requestAudioSession:
      send(.sessionActivated(Self.demoRoute, now: Date()))
    case .releaseAudioSession:
      send(.sessionDeactivated)
    case .speak(let text, _):
      demoSpoken = text
      send(.playbackFinished(completed: true, now: Date()))
    case .stopSpeaking, .startCapture, .cancelCapture:
      break
    case .finishCapture:
      send(.transcriptReady(demoTranscript, now: Date()))
    case .refreshApprovals, .sendDecision, .sendSnooze, .scheduleTick:
      isDemo = false
      perform(effect)
      isDemo = true
    }
  }
  #endif
}
