import AVFoundation
import CallKit
import Combine
import Foundation
import UIKit

/// AVFoundation delivers synthesis buffers off the main actor. A buffer is transferred once
/// to the playback queue and is immutable thereafter.
private final class AudioApprovalSpeechBuffer: @unchecked Sendable {
  let pcm: AVAudioPCMBuffer
  init(_ pcm: AVAudioPCMBuffer) { self.pcm = pcm }
}

private final class AudioApprovalSpeechSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var nextIndex = 0
  func take() -> Int { lock.withLock { defer { nextIndex += 1 }; return nextIndex } }
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
  @Published private(set) var replyHistory: [AudioApprovalReplyRecord] = []
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
  private var speechProgress = AudioSpeechPlaybackProgress()
  private var speechBuffers = AudioSpeechBufferOrdering<AudioApprovalSpeechBuffer>()
  private var speechEngine: AVAudioEngine?
  private var speechPlayer: AVAudioPlayerNode?
  private var historyKey: String?
  private var historySubscription: AnyCancellable?
  private var speechWatchdog: Task<Void, Never>?
  private var synthesizer: AVSpeechSynthesizer?
  private let callObserver = CXCallObserver()
  private let transcriber = MobileVoiceTranscriber()
  private var observers: [NSObjectProtocol] = []
  private var approvalsSubscription: AnyCancellable?
  private var deliveryIDs: [AudioApprovalTarget: UUID] = [:]
  private var playbackDelivery: (target: AudioApprovalTarget, id: UUID)?
  private var deliveryReportTask: Task<Void, Never>?
  private var deliveryReportID: UUID?
  private var deliveryReportBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var promptCheckID: UUID?
  private var pushToken: Data?
  private var pushToTalkSessionActive = false
  private var replyBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  init() {
    let stored = UserDefaults.standard.object(forKey: AudioApprovalFeature.quietUntilDefaultsKey) as? Date
    quietUntil = stored.flatMap { $0 > Date() ? $0 : nil }
  }

  var isQuiet: Bool { (quietUntil ?? .distantPast) > Date() }

  /// Called once from the app root. Creates nothing unless the person turned the feature on.
  func attach(remote: MobileRemoteStore) {
    self.remote = remote
    historySubscription = remote.$activeHostID.removeDuplicates().sink { [weak self] hostID in
      self?.loadReplyHistory(hostID: hostID)
    }
    approvalsSubscription = remote.$workspaceApprovals
      .receive(on: DispatchQueue.main)
      .sink { [weak self] approvals in
        // An older foreground response is not the confirmation of a just-pushed target.
        guard let self, self.promptCheckID == nil else { return }
        self.send(.approvalsUpdated(approvals.map(Self.candidate), now: Date()))
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
      phase = "Checking microphone and speech permissions…"
      Task {
        let allowed = await transcriber.preparePermissions()
        guard isEnabled else { return }
        if allowed {
          startPushToTalk()
        } else {
          setEnabled(false)
          phase = transcriber.errorMessage ?? "Microphone and Speech Recognition permissions are required."
        }
      }
    } else {
      leave()
      phase = "Off"
    }
  }

  func join() {
    guard isEnabled else { return }
    guard let bridge else { return startPushToTalk() }
    phase = "Checking microphone and speech permissions…"
    Task {
      guard await transcriber.preparePermissions(), isEnabled else {
        phase = transcriber.errorMessage ?? "Audio approvals are off."
        return
      }
      phase = "Joining the approvals channel…"
      bridge.join()
    }
  }

  func leave() {
    endReplyBackgroundTask()
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
    case .managerReady(let failure, let restored):
      pushToTalkAvailable = failure == nil
      if restored {
        // A push may already have established enrollment.
        guard !channelJoined else { return }
        channelJoined = true
        send(.enrollmentChanged(joined: true))
        Task { await registerWithMac(enabled: true) }
      } else {
        phase = failure.map { "Push to Talk unavailable: \($0)" } ?? "Ready. Join the approvals channel to allow prompts."
      }
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
      if initiated { beginReplyBackgroundTask() }
      send(.transmitEnded(initiated: initiated, interrupted: interrupted))
    case .incomingPush(let target, let deliveryID):
      if let target, let deliveryID {
        if deliveryIDs.count >= 64 { deliveryIDs.removeAll() }
        deliveryIDs[target] = deliveryID
        reportDelivery(stage: "push-received", target: target, deliveryID: deliveryID)
      }
      // The bridge accepts a push only for the joined channel. On a background launch the push
      // can arrive before the restored-channel callback; without this the state machine would
      // ignore it and leave Celorga as the active speaker, which disables the Talk button.
      if !channelJoined {
        channelJoined = true
        send(.enrollmentChanged(joined: true))
        Task { await registerWithMac(enabled: true) }
      }
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
      endReplyBackgroundTask()
      phase = message
    }
  }

  // MARK: State machine

  private func send(_ event: AudioApprovalEvent) {
    switch event {
    case .playbackFinished(let completed, _):
      if case .speaking(.prompt) = session.playback, let delivery = playbackDelivery {
        reportDelivery(stage: completed ? "playback-completed" : "playback-failed", target: delivery.target, deliveryID: delivery.id)
      }
    case .playbackStalled:
      if case .speaking(.prompt) = session.playback, let delivery = playbackDelivery {
        reportDelivery(stage: "playback-failed", target: delivery.target, deliveryID: delivery.id)
      }
    case .sessionActivated:
      if let target = session.pushedTarget ?? session.activeTarget, let id = deliveryIDs[target] {
        reportDelivery(stage: "audio-session-active", target: target, deliveryID: id)
      }
    case .decisionSucceeded(let target, _):
      if let delivery = playbackDelivery, delivery.target == target {
        reportDelivery(stage: "decision-confirmed", target: target, deliveryID: delivery.id)
      }
    default: break
    }
    let effects = session.handle(event)
    publish()
    for effect in effects { perform(effect) }
  }

  private func publish() {
    phase = session.status
    promptText = session.active.map(AudioApprovalSpeech.prompt(for:))
    acknowledgement = session.lastAcknowledgement
    if replyHistory != session.replyHistory {
      replyHistory = session.replyHistory
      if let historyKey, let data = try? JSONEncoder().encode(replyHistory) {
        UserDefaults.standard.set(data, forKey: historyKey)
      }
    }
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
      stopSpeech()
    case .startCapture:
      Task {
        await transcriber.start(managesAudioSession: false)
        if let message = transcriber.errorMessage {
          send(.captureFailed(message))
        }
      }
    case .finishCapture:
      beginReplyBackgroundTask()
      Task {
        let transcript = await transcriber.finish()
        send(.transcriptReady(transcript, now: Date()))
      }
    case .cancelCapture:
      transcriber.cancel()
    case .refreshApprovals:
      let requestID = UUID()
      promptCheckID = requestID
      Task { [weak self] in
        guard let self, let remote = self.remote else { return }
        await remote.refreshWorkspace(reportsErrors: false, requiresNewSnapshot: true)
        guard self.promptCheckID == requestID else { return }
        self.promptCheckID = nil
        if let error = remote.workspaceConnectionError {
          self.send(.hostCheckFailed(error))
        } else {
          if let target = self.session.pushedTarget, let id = self.deliveryIDs[target],
             remote.workspaceApprovals.map(Self.candidate).contains(where: { $0.target == target }) {
            self.reportDelivery(stage: "prompt-verified", target: target, deliveryID: id)
          }
          self.send(.approvalsUpdated(remote.workspaceApprovals.map(Self.candidate), now: Date()))
        }
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
    if kind == .prompt { preparePlaybackDelivery() }
    switch planAudioPlayback(quiet: isQuiet, snapshot: currentRouteSnapshot()) {
    case .hold:
      // Report an incomplete playback: a prompt that was not heard cannot be answered.
      send(.playbackFinished(completed: false, now: Date()))
    case .play:
      stopSpeech()
      let playbackID = UUID()
      speechProgress.start(playbackID)
      let synthesizer = AVSpeechSynthesizer()
      synthesizer.usesApplicationAudioSession = true
      self.synthesizer = synthesizer
      armSpeechWatchdog()
      // Generate PCM locally; play it on our own engine in the PTT-owned session. Direct
      // synthesizer playback can stop when backgrounded without a finish/cancel callback.
      // Generation completion is not playback completion: the last buffer must be heard.
      let sequence = AudioApprovalSpeechSequence()
      synthesizer.write(AVSpeechUtterance(string: text)) { @Sendable [weak self] buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let index = sequence.take()
        let transferred = AudioApprovalSpeechBuffer(pcm)
        Task { @MainActor [weak self] in
          guard let self, self.speechProgress.id == playbackID else { return }
          for ordered in self.speechBuffers.insert(transferred, at: index) {
            self.playSpeechBuffer(ordered.pcm, playbackID: playbackID)
          }
        }
      }
    }
  }

  private func playSpeechBuffer(_ buffer: AVAudioPCMBuffer, playbackID: UUID) {
    guard speechProgress.id == playbackID else { return }
    if buffer.frameLength == 0 {
      if speechProgress.renderingFinished(playbackID) { completeSpeech(playbackID) }
      return
    }
    // Recheck the private output for every buffer, including background route transitions.
    guard case .play = planAudioPlayback(quiet: isQuiet, snapshot: currentRouteSnapshot()) else {
      stopSpeech()
      send(.playbackFinished(completed: false, now: Date()))
      return
    }
    do {
      if speechEngine == nil {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        speechEngine = engine
        speechPlayer = player
        engine.prepare()
        try engine.start()
      }
      guard let player = speechPlayer else { return }
      speechProgress.enqueued(playbackID)
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.speechProgress.id == playbackID else { return }
          if self.speechProgress.played(playbackID) {
            self.completeSpeech(playbackID)
          } else {
            self.armSpeechWatchdog()
          }
        }
      }
      if !player.isPlaying {
        player.play()
        if let delivery = playbackDelivery, case .speaking(.prompt) = session.playback {
          reportDelivery(stage: "playback-started", target: delivery.target, deliveryID: delivery.id)
        }
      }
      // Audible playback now has the framework's runtime assertion. Until this point the
      // reply's short background task covers final transcription, transport, and receipt.
      endReplyBackgroundTask()
    } catch {
      stopSpeech()
      send(.playbackFinished(completed: false, now: Date()))
    }
  }

  private func completeSpeech(_ playbackID: UUID) {
    guard speechProgress.id == playbackID else { return }
    stopSpeech()
    send(.playbackFinished(completed: true, now: Date()))
  }

  private func stopSpeech() {
    // Invalidate before stopping: queued callbacks from canceled audio are ignored.
    speechProgress.stop()
    speechBuffers = AudioSpeechBufferOrdering()
    cancelSpeechWatchdog()
    synthesizer?.stopSpeaking(at: .immediate)
    synthesizer = nil
    speechPlayer?.stop()
    speechEngine?.stop()
    speechPlayer = nil
    speechEngine = nil
  }

  private func beginReplyBackgroundTask() {
    guard replyBackgroundTask == .invalid else { return }
    replyBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish audio approval reply") { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.endReplyBackgroundTask()
        if let target = self.session.deciding {
          self.send(.decisionFailed(target, "Background time expired before the Mac confirmed this reply."))
        } else if self.session.capture != .idle {
          self.transcriber.cancel()
          self.send(.captureFailed("Background time expired."))
        }
      }
    }
  }

  private func endReplyBackgroundTask() {
    guard replyBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(replyBackgroundTask)
    replyBackgroundTask = .invalid
  }

  private func loadReplyHistory(hostID: UUID?) {
    let key = "celorga.audioApprovals.replyHistory.\(hostID?.uuidString ?? "local")"
    guard key != historyKey else { return }
    // A host switch invalidates the current prompt and its in-flight answer.
    if historyKey != nil {
      promptCheckID = nil
      deliveryIDs.removeAll()
      playbackDelivery = nil
      deliveryReportTask?.cancel()
      deliveryReportID = nil
      endDeliveryReportBackgroundTask()
      stopSpeech()
      endReplyBackgroundTask()
      transcriber.cancel()
      session = AudioApprovalSession()
      _ = session.handle(.enrollmentChanged(joined: channelJoined))
      _ = session.handle(.quietChanged(until: quietUntil, now: Date()))
    }
    historyKey = key
    replyHistory = []
    let stored = UserDefaults.standard.data(forKey: key)
      .flatMap { try? JSONDecoder().decode([AudioApprovalReplyRecord].self, from: $0) } ?? []
    // A crash or suspension must not leave an old attempt indefinitely saying "Sending".
    let restored = stored.map { record in
      var record = record
      if record.outcome == "Sending to the Mac…" || record.outcome == "Listening for your reply…"
        || record.outcome == "Waiting for the microphone…" || record.outcome == "Understanding your reply…" {
        record.outcome = "No confirmation received. Check the approval's current status before retrying."
      }
      return record
    }
    session.restoreReplyHistory(restored)
    publish()
  }

  /// AVSpeechSynthesizer can stop producing audible output under a Push to Talk session without
  /// delivering either completion callback. Progress continually resets this watchdog; a genuine
  /// stall clears the remote participant so Talk and ordinary dictation become available again.
  private func armSpeechWatchdog() {
    speechWatchdog?.cancel()
    speechWatchdog = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(8))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.endReplyBackgroundTask()
      self?.send(.playbackStalled)
    }
  }

  private func cancelSpeechWatchdog() {
    speechWatchdog?.cancel()
    speechWatchdog = nil
  }

  private func sendDecision(_ candidate: AudioApprovalCandidate, decision: String, note: String?, receipt: String) {
    beginReplyBackgroundTask()
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
           hostReceipt.approvalID == target.approvalID,
           hostReceipt.receipt == receipt,
           hostReceipt.decision == decision {
          send(.decisionSucceeded(target, AudioDecisionOutcome(
            decision: hostReceipt.decision,
            runStatus: hostReceipt.runStatus,
            pendingApprovalCount: hostReceipt.pendingApprovalCount,
            continuation: hostReceipt.continuation,
            duplicate: hostReceipt.duplicate ?? false
          )))
        } else {
          // Leaving the queue can also mean a cancellation elsewhere. Only our exact host
          // receipt confirms this reply; disappearance must never be announced as approval.
          send(.decisionFailed(target, "The Mac did not return a matching decision receipt. Check the request's status before retrying."))
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

  private func preparePlaybackDelivery() {
    playbackDelivery = session.activeTarget.flatMap { target in
      deliveryIDs[target].map { (target, $0) }
    }
  }

  /// Receipts are best-effort diagnostics, never decision authority. Keep them ordered and
  /// briefly retain background time after playback releases the PTT session.
  private func reportDelivery(stage: String, target: AudioApprovalTarget, deliveryID: UUID) {
    guard let remote else { return }
    let hostID = remote.activeHostID
    let simulated: Bool
    let headset: Bool
    #if DEBUG
    simulated = isDemo
    headset = isDemo || currentRouteSnapshot().route == .headset
    #else
    simulated = false
    headset = currentRouteSnapshot().route == .headset
    #endif
    let event = MobileRemoteAudioApprovalDeliveryRecord(
      deliveryID: deliveryID, runID: target.runID, approvalID: target.approvalID,
      fingerprint: target.fingerprint, stage: stage, simulated: simulated, headset: headset)
    if deliveryReportBackgroundTask == .invalid {
      deliveryReportBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Report approval playback") { [weak self] in
        Task { @MainActor [weak self] in
          self?.deliveryReportTask?.cancel()
          self?.endDeliveryReportBackgroundTask()
        }
      }
    }
    let previous = deliveryReportTask
    let reportID = UUID()
    deliveryReportID = reportID
    deliveryReportTask = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      defer {
        if self.deliveryReportID == reportID {
          self.deliveryReportTask = nil
          self.endDeliveryReportBackgroundTask()
        }
      }
      guard !Task.isCancelled, remote.activeHostID == hostID else { return }
      try? await remote.reportAudioApprovalDelivery(event)
    }
  }

  private func endDeliveryReportBackgroundTask() {
    guard deliveryReportBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(deliveryReportBackgroundTask)
    deliveryReportBackgroundTask = .invalid
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

  /// Injects only the external framework events; host refresh, policy, and decisions remain real.
  func demoReceivePush(_ payload: [String: Any]) {
    guard isDemo else { return }
    handle(.incomingPush(AudioApprovalPushToTalkBridge.target(from: payload), deliveryID: (payload["deliveryID"] as? String).flatMap(UUID.init(uuidString:))))
    send(.sessionActivated(Self.demoRoute, now: Date()))
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
    case .speak(let text, let kind):
      if kind == .prompt {
        preparePlaybackDelivery()
        if let delivery = playbackDelivery {
          reportDelivery(stage: "playback-started", target: delivery.target, deliveryID: delivery.id)
        }
      }
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
