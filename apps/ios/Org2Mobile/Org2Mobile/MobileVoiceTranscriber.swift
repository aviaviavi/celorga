import AVFoundation
import Foundation
import Speech
import UIKit

@MainActor
protocol MobileVoiceAudioSessionManaging {
  func activateForDictation() throws
  func deactivate() throws
}

@MainActor
final class MobileVoiceAudioSession: MobileVoiceAudioSessionManaging {
  func configureForDictation() throws {
    let session = AVAudioSession.sharedInstance()
    if AudioApprovalFeature.isEnabled {
      // The category belongs to the whole app. A chat must not replace the
      // duplex headset route that the joined Push to Talk channel will reuse.
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
    } else {
      try session.setCategory(.record, mode: .measurement, options: [])
    }
  }

  func activateForDictation() throws {
    try configureForDictation()
    try AVAudioSession.sharedInstance().setActive(true)
  }

  func deactivate() throws {
    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

@MainActor
final class MobileVoiceTranscriber: ObservableObject {
  /// `AVAudioEngine` invokes input taps on its real-time audio queue. Keeping
  /// the request behind an explicitly Sendable, nonisolated boundary prevents
  /// Swift from inheriting `MobileVoiceTranscriber`'s main-actor isolation for
  /// that callback. An inherited actor check traps the process before the first
  /// audio buffer can be appended.
  private final class AudioBufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
      self.request = request
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
      request.append(buffer)
    }
  }

  @Published private(set) var isRecording = false
  @Published private(set) var transcript = ""
  @Published var errorMessage: String?

  private let recognizer = SFSpeechRecognizer(locale: .current)
  private var audioEngine: AVAudioEngine?
  private var tappedInputNode: AVAudioInputNode?
  private var hasInstalledInputTap = false
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var pendingStartID: UUID?
  private var recognitionID: UUID?
  private var idleTimerWasDisabled: Bool?
  /// Cancel is also called for idle chats. Release only an activation this
  /// transcriber actually acquired, never the shared session owned by PTT.
  private var ownsAudioSession = false
  private let audioSession: any MobileVoiceAudioSessionManaging

  init(audioSession: any MobileVoiceAudioSessionManaging = MobileVoiceAudioSession()) {
    self.audioSession = audioSession
  }

  /// Audio approvals request these while Settings is onscreen, before a background reply.
  func preparePermissions() async -> Bool {
    guard await requestSpeechAuthorization() == .authorized else {
      errorMessage = "Allow Speech Recognition in Settings to understand approval replies."
      return false
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      errorMessage = "Allow Microphone access in Settings to capture approval replies."
      return false
    }
    errorMessage = nil
    return true
  }

  /// - Parameter managesAudioSession: Pass false inside a Push to Talk transmission,
  ///   after `channelManager(_:didActivate:)`. The session is then left untouched.
  func start(managesAudioSession: Bool = true) async {
    guard !isRecording else { return }
    let startID = UUID()
    pendingStartID = startID
    guard await requestSpeechAuthorization() == .authorized else {
      guard pendingStartID == startID else { return }
      pendingStartID = nil
      errorMessage = "Allow Speech Recognition in Settings to transcribe a message."
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      guard pendingStartID == startID else { return }
      pendingStartID = nil
      errorMessage = "Allow Microphone access in Settings to transcribe a message."
      return
    }
    guard pendingStartID == startID else { return }
    pendingStartID = nil
    guard let recognizer, recognizer.isAvailable else {
      errorMessage = "Speech recognition is not currently available."
      return
    }

    reset(cancelRecognition: true)
    transcript = ""
    errorMessage = nil

    do {
      if managesAudioSession {
        try audioSession.activateForDictation()
        ownsAudioSession = true
      }

      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.taskHint = .dictation
      recognitionRequest = request
      let bufferSink = AudioBufferSink(request: request)

      // Recreate the engine for every capture. A stale input graph after an
      // interruption can retain a tap or expose an unavailable hardware
      // format, both of which AVAudioEngine reports as an Objective-C exception
      // instead of a catchable Swift error.
      let engine = AVAudioEngine()
      let inputNode = engine.inputNode
      let hardwareFormat = inputNode.inputFormat(forBus: 0)
      guard Self.isUsableInputFormat(hardwareFormat) else {
        reset(cancelRecognition: true)
        errorMessage = "The microphone is temporarily unavailable. Try again after ending any call or other audio session."
        return
      }
      audioEngine = engine
      tappedInputNode = inputNode
      inputNode.installTap(
        onBus: 0,
        bufferSize: 1_024,
        format: hardwareFormat
      ) { @Sendable buffer, _ in
        bufferSink.append(buffer)
      }
      hasInstalledInputTap = true

      engine.prepare()
      try engine.start()
      isRecording = true
      // Keep the live transcript visible during hands-free dictation. Only
      // hold the screen awake once microphone capture has actually started.
      idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      let recognitionID = UUID()
      self.recognitionID = recognitionID

      // Speech invokes this callback on an arbitrary queue. Mark it Sendable so
      // Swift does not inherit MobileVoiceTranscriber's main-actor isolation.
      recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
        let nextTranscript = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal == true
        let errorText = error?.localizedDescription
        Task { @MainActor [weak self] in
          guard let self else { return }
          guard self.recognitionID == recognitionID else { return }
          if let nextTranscript {
            self.transcript = nextTranscript
          }
          if isFinal || errorText != nil {
            self.finishRecognition(
              id: recognitionID,
              errorText: isFinal ? nil : errorText
            )
          }
        }
      }
    } catch {
      reset(cancelRecognition: true)
      errorMessage = "Could not start transcription: \(error.localizedDescription)"
    }
  }

  func stop() {
    pendingStartID = nil
    guard isRecording else { return }
    stopAudioCapture()
    recognitionRequest?.endAudio()
    isRecording = false
  }

  func finish() async -> String {
    let finishingID = recognitionID
    stop()
    guard let finishingID else { return transcript }

    // Give Speech a bounded window to turn the final buffered audio into its
    // final result. Sending the latest partial result immediately can clip the
    // last few words, while waiting without a bound can leave the composer
    // stuck indefinitely if the recognizer never delivers a terminal event.
    for _ in 0..<40 {
      guard recognitionID == finishingID else { return transcript }
      try? await Task.sleep(for: .milliseconds(50))
    }

    if recognitionID == finishingID {
      recognitionTask?.cancel()
      finishRecognition(id: finishingID, errorText: nil)
    }
    return transcript
  }

  func cancel() {
    pendingStartID = nil
    reset(cancelRecognition: true)
    transcript = ""
  }

  private func finishRecognition(id: UUID, errorText: String?) {
    guard recognitionID == id else { return }
    stopAudioCapture()
    isRecording = false
    recognitionRequest = nil
    recognitionTask = nil
    recognitionID = nil
    releaseOwnedAudioSession()
    if let errorText, transcript.isEmpty {
      errorMessage = "Transcription stopped: \(errorText)"
    }
  }

  private func reset(cancelRecognition: Bool) {
    recognitionID = nil
    stopAudioCapture()
    if cancelRecognition {
      recognitionTask?.cancel()
    } else {
      recognitionRequest?.endAudio()
    }
    recognitionRequest = nil
    recognitionTask = nil
    isRecording = false
    releaseOwnedAudioSession()
  }

  private func releaseOwnedAudioSession() {
    guard ownsAudioSession else { return }
    ownsAudioSession = false
    try? audioSession.deactivate()
  }

  private func stopAudioCapture() {
    // All terminal paths (stop, send, cancellation, and recognition failure)
    // release the same hold, without changing a pre-existing idle policy.
    if let idleTimerWasDisabled {
      UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
      self.idleTimerWasDisabled = nil
    }
    audioEngine?.stop()
    if hasInstalledInputTap {
      tappedInputNode?.removeTap(onBus: 0)
    }
    hasInstalledInputTap = false
    tappedInputNode = nil
    audioEngine = nil
  }

  nonisolated static func isUsableInputFormat(_ format: AVAudioFormat) -> Bool {
    format.sampleRate.isFinite
      && format.sampleRate > 0
      && format.channelCount > 0
  }

  private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      // TCC also responds on an arbitrary queue. Without an explicitly
      // nonisolated callback, Swift 6 traps while checking the main actor.
      SFSpeechRecognizer.requestAuthorization { @Sendable status in
        continuation.resume(returning: status)
      }
    }
  }
}
