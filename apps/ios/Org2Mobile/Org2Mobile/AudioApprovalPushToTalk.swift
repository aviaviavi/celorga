import AVFoundation
import Foundation
import PushToTalk

/// Plain events the Push to Talk framework produces, forwarded to the main actor.
enum AudioApprovalChannelEvent: Sendable {
  /// `restored` is true when iOS restored the previously joined channel during launch.
  case managerReady(failure: String?, restored: Bool)
  case joined
  case left
  case transmitBegan(initiated: Bool)
  /// `interrupted` is true when this bridge ended the transmission to accept an incoming push.
  case transmitEnded(initiated: Bool, interrupted: Bool)
  case incomingPush(AudioApprovalTarget?, deliveryID: UUID? = nil)
  case ephemeralToken(Data)
  case audioSessionActivated
  case audioSessionDeactivated
  case failed(String)
}

enum AudioApprovalChannel {
  /// Stable channel identity. Derived from the approvals task ID in notes/celorga.org.
  static let channelUUID = UUID(uuidString: "5C63891E-48AE-49DD-B79D-77932360F017")!
  static let channelName = "Celorga approvals"
  static let participantName = "Celorga"
}

/// Thread-safe state the framework reads synchronously from its own threads.
private final class AudioApprovalBridgeState: @unchecked Sendable {
  private let lock = NSLock()
  private var enrolled = false
  private var transmitting = false
  private var interruptedTransmission = false

  var isEnrolled: Bool {
    get { lock.withLock { enrolled } }
    set { lock.withLock { enrolled = newValue } }
  }

  var isTransmitting: Bool {
    get { lock.withLock { transmitting } }
    set { lock.withLock { transmitting = newValue } }
  }

  /// Marks the current transmission as ended by the bridge, not by the person.
  func markInterrupted() {
    lock.withLock { interruptedTransmission = true }
  }

  /// Returns whether the transmission that just ended was interrupted, and clears the flag.
  func takeInterrupted() -> Bool {
    lock.withLock {
      defer { interruptedTransmission = false }
      return interruptedTransmission
    }
  }
}

/// Owns the single PTChannelManager. Delegate callbacks arrive on framework threads,
/// so each one is converted to an `AudioApprovalChannelEvent` and delivered on the main actor.
final class AudioApprovalPushToTalkBridge: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate, @unchecked Sendable {
  private let deliver: @MainActor @Sendable (AudioApprovalChannelEvent) -> Void
  private let state = AudioApprovalBridgeState()
  private var manager: PTChannelManager?

  init(deliver: @escaping @MainActor @Sendable (AudioApprovalChannelEvent) -> Void) {
    self.deliver = deliver
    super.init()
  }

  /// Creates the manager. Call as early as possible after launch, but only when the person has
  /// turned the feature on, so the framework can restore a joined channel and deliver pushes.
  func start() {
    Self.configureAudioSessionCategory()
    PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { [weak self] channelManager, error in
      guard let self else { return }
      self.manager = channelManager
      let restored = channelManager?.activeChannelUUID == AudioApprovalChannel.channelUUID
      self.state.isEnrolled = restored
      self.post(.managerReady(failure: error?.localizedDescription, restored: restored))
    }
  }

  /// Explicit user action only. Joining is a foreground request.
  func join() {
    guard let manager else { return post(.failed("Push to Talk is not ready.")) }
    let descriptor = PTChannelDescriptor(name: AudioApprovalChannel.channelName, image: nil)
    manager.requestJoinChannel(channelUUID: AudioApprovalChannel.channelUUID, descriptor: descriptor)
  }

  func leave() {
    state.isEnrolled = false
    manager?.leaveChannel(channelUUID: AudioApprovalChannel.channelUUID)
  }

  /// Category only. Push to Talk activates and deactivates the session itself; the app never
  /// calls `setActive`. Approval prompts and replies use one duplex Bluetooth HFP route instead of
  /// allowing iOS to alternate between output-only A2DP and HFP. Without a headset, output stays
  /// on the receiver, which the playback gate refuses.
  static func configureAudioSessionCategory() {
    try? AVAudioSession.sharedInstance().setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetooth]
    )
  }

  /// With a play-and-record session, selecting a Bluetooth HFP input also selects its matching
  /// private output. Do this when Push to Talk activates, and again while the controller waits
  /// for the headset: a backgrounded activation may not list the HFP input yet.
  static func preferConnectedBluetoothHeadset(on audioSession: AVAudioSession) {
    let outputs = audioSession.currentRoute.outputs.map(\.portType)
    if outputs.contains(.bluetoothHFP) { return }
    guard let headset = audioSession.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else { return }
    try? audioSession.setPreferredInput(headset)
  }

  /// Marks locally generated spoken detail as an active remote response so the
  /// framework, not the app, activates the audio session before playback.
  func beginReceiving() {
    guard let manager else { return post(.failed("Push to Talk is not ready.")) }
    manager.setActiveRemoteParticipant(
      PTParticipant(name: AudioApprovalChannel.participantName, image: nil),
      channelUUID: AudioApprovalChannel.channelUUID
    ) { [weak self] error in
      if let error { self?.post(.failed("Could not activate approval audio: \(error.localizedDescription)")) }
    }
  }

  /// Ends receive mode after speech stops so the system can deactivate the
  /// session and allow the headset button to begin a reply.
  func finishReceiving() {
    manager?.setActiveRemoteParticipant(
      nil,
      channelUUID: AudioApprovalChannel.channelUUID
    ) { [weak self] error in
      if let error { self?.post(.failed("Could not finish approval audio: \(error.localizedDescription)")) }
    }
  }

  // MARK: PTChannelRestorationDelegate

  func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
    PTChannelDescriptor(name: AudioApprovalChannel.channelName, image: nil)
  }

  // MARK: PTChannelManagerDelegate

  func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason) {
    state.isEnrolled = true
    post(.joined)
  }

  func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason) {
    state.isEnrolled = false
    post(.left)
  }

  func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
    state.isTransmitting = true
    post(.transmitBegan(initiated: Self.isInitiated(source)))
  }

  func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
    state.isTransmitting = false
    post(.transmitEnded(initiated: Self.isInitiated(source), interrupted: state.takeInterrupted()))
  }

  func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data) {
    post(.ephemeralToken(pushToken))
  }

  /// Must answer synchronously. Enrolled devices take the incoming audio so the
  /// framework activates a session; unenrolled devices leave the channel.
  func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult {
    let target = Self.target(from: pushPayload)
    // On a background launch, restoration can establish the active channel before the
    // didJoinChannel callback reaches this delegate. The manager is the authoritative state.
    if channelManager.activeChannelUUID == channelUUID {
      state.isEnrolled = true
    }
    guard state.isEnrolled else { return PTPushResult.leaveChannel }
    if state.isTransmitting {
      // Half duplex: Apple requires ending the local transmission before reporting a remote
      // participant. The partial reply is discarded, never decided.
      state.markInterrupted()
      channelManager.stopTransmitting(channelUUID: channelUUID)
    }
    post(.incomingPush(target, deliveryID: (pushPayload["deliveryID"] as? String).flatMap(UUID.init(uuidString:))))
    // The controller checks the identity against the Mac and releases the session if the
    // prompt is stale, quiet, or incomplete. Nothing plays before that check.
    return PTPushResult.activeRemoteParticipant(PTParticipant(name: AudioApprovalChannel.participantName, image: nil))
  }

  func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession) {
    Self.preferConnectedBluetoothHeadset(on: audioSession)
    post(.audioSessionActivated)
  }

  func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession) {
    post(.audioSessionDeactivated)
  }

  func channelManager(_ channelManager: PTChannelManager, failedToJoinChannel channelUUID: UUID, error: Error) {
    post(.failed("Join failed: \(error.localizedDescription)"))
  }

  func channelManager(_ channelManager: PTChannelManager, failedToLeaveChannel channelUUID: UUID, error: Error) {
    post(.failed("Leave failed: \(error.localizedDescription)"))
  }

  func channelManager(_ channelManager: PTChannelManager, failedToBeginTransmittingInChannel channelUUID: UUID, error: Error) {
    post(.failed("Transmit failed: \(error.localizedDescription)"))
  }

  func channelManager(_ channelManager: PTChannelManager, failedToStopTransmittingInChannel channelUUID: UUID, error: Error) {
    post(.failed("Stop transmit failed: \(error.localizedDescription)"))
  }

  /// Only a button press or accessory press initiates a reply. Developer-requested
  /// or unknown sources never authorize a decision.
  static func isInitiated(_ source: PTChannelTransmitRequestSource) -> Bool {
    source == .userRequest || source == .handsfreeButton
  }

  static func target(from payload: [String: Any]) -> AudioApprovalTarget? {
    guard let runID = payload["runID"] as? String, !runID.isEmpty,
          let approvalID = payload["approvalID"] as? String, !approvalID.isEmpty,
          let fingerprint = payload["fingerprint"] as? String, !fingerprint.isEmpty
    else { return nil }
    return AudioApprovalTarget(runID: runID, approvalID: approvalID, fingerprint: fingerprint)
  }

  private func post(_ event: AudioApprovalChannelEvent) {
    let deliver = self.deliver
    Task { @MainActor in deliver(event) }
  }
}
