@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
@preconcurrency import Speech

public enum MeetingTranscriptionStatus: String, Sendable {
  case complete
  case unavailable
  case failed

  public var label: String {
    switch self {
    case .complete: "complete"
    case .unavailable: "local transcriber unavailable"
    case .failed: "failed"
    }
  }
}

public struct MeetingArtifactPaths: Sendable {
  public let meetingID: String
  public let title: String
  public let recordedAt: Date
  public let baseName: String
  public let noteURL: URL
  public let audioURL: URL
  public let systemAudioURL: URL
  public let transcriptURL: URL
  /// The synced calendar event this recording belongs to, when known.
  public var calendar: MeetingCalendarContext? = nil
}

public struct MeetingTranscriptResult: Sendable {
  public let text: String
  public let status: MeetingTranscriptionStatus
  public let engine: String
  public let errorMessage: String?

  public init(
    text: String,
    status: MeetingTranscriptionStatus,
    engine: String,
    errorMessage: String? = nil
  ) {
    self.text = text
    self.status = status
    self.engine = engine
    self.errorMessage = errorMessage
  }

  public static func combined(
    microphone: MeetingTranscriptResult,
    systemAudio: MeetingTranscriptResult?,
    systemAudioCaptureError: String? = nil
  ) -> MeetingTranscriptResult {
    guard systemAudio != nil || systemAudioCaptureError != nil else {
      return microphone
    }

    var sections = [
      transcriptSection(title: "Microphone", transcript: microphone)
    ]
    if let systemAudio {
      sections.append(transcriptSection(title: "System Audio", transcript: systemAudio))
    } else if let systemAudioCaptureError {
      sections.append("""
      ** System Audio

      System audio was not captured: \(systemAudioCaptureError)
      """)
    }

    let status: MeetingTranscriptionStatus
    if microphone.status == .complete || systemAudio?.status == .complete {
      status = .complete
    } else if microphone.status == .unavailable && (systemAudio?.status == .unavailable || systemAudio == nil) {
      status = .unavailable
    } else {
      status = .failed
    }

    let engine = [
      "microphone: \(microphone.engine)",
      systemAudio.map { "system: \($0.engine)" }
    ].compactMap { $0 }.joined(separator: "; ")
    let errorMessage = [
      microphone.errorMessage.map { "microphone: \($0)" },
      systemAudio?.errorMessage.map { "system: \($0)" },
      systemAudioCaptureError.map { "system capture: \($0)" }
    ].compactMap { $0 }.joined(separator: "; ").nilIfEmpty

    return MeetingTranscriptResult(
      text: sections.joined(separator: "\n\n"),
      status: status,
      engine: engine,
      errorMessage: errorMessage
    )
  }

  private static func transcriptSection(title: String, transcript: MeetingTranscriptResult) -> String {
    let body = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = body.isEmpty
      ? "Transcription \(transcript.status.label). \(transcript.errorMessage ?? "")"
        .trimmingCharacters(in: .whitespacesAndNewlines)
      : body
    return """
    ** \(title)

    \(text)
    """
  }
}

public struct MeetingArtifactBundle: Sendable {
  public let item: MeetingWorkspaceItem
  public let noteURL: URL
  public let audioURL: URL
  public let systemAudioURL: URL?
  public let transcriptURL: URL
}

public struct MeetingInputMeterSnapshot: Equatable, Sendable {
  public let averageLevel: Double
  public let peakLevel: Double
  public let averagePowerDecibels: Float
  public let peakPowerDecibels: Float

  public static let silent = MeetingInputMeterSnapshot(
    averageLevel: 0,
    peakLevel: 0,
    averagePowerDecibels: -160,
    peakPowerDecibels: -160
  )
}

struct MeetingSystemAudioCaptureState: Equatable, Sendable {
  private(set) var isRunning = false
  private(set) var firstFailureDescription: String?
  private(set) var interruptionCount = 0
  private(set) var needsRecovery = false

  mutating func reset() {
    isRunning = false
    firstFailureDescription = nil
    interruptionCount = 0
    needsRecovery = false
  }

  mutating func didStart() {
    // An immediate delegate failure can arrive before startCapture's
    // completion handler. Do not revive a stream that has already failed.
    guard firstFailureDescription == nil else { return }
    isRunning = true
    needsRecovery = false
  }

  mutating func didRecover(afterInterruptionCount expectedInterruptionCount: Int) -> Bool {
    // Retain the interruption so the final meeting artifact can disclose a
    // possible gap, while allowing the replacement stream to remain active.
    guard interruptionCount == expectedInterruptionCount else { return false }
    isRunning = true
    needsRecovery = false
    return true
  }

  mutating func didStopNormally() {
    isRunning = false
    needsRecovery = false
  }

  mutating func didStopUnexpectedly(_ description: String) {
    isRunning = false
    interruptionCount += 1
    needsRecovery = true
    if firstFailureDescription == nil {
      firstFailureDescription = description
    }
  }

  func resolvedFailure(explicitStopFailure: String?) -> String? {
    firstFailureDescription ?? explicitStopFailure
  }
}

public struct MeetingSystemAudioRecordingResult: Equatable, Sendable {
  public let duration: TimeInterval?
  public let capturedSampleCount: Int
  public let captureErrorDescription: String?

  public var hasCapturedAudio: Bool {
    capturedSampleCount > 0
  }
}

public enum MeetingArtifactWriter {
  public static func preparePaths(
    corpusRoot: URL,
    title rawTitle: String,
    recordedAt: Date,
    audioExtension: String = "wav",
    systemAudioExtension: String = "m4a"
  ) throws -> MeetingArtifactPaths {
    let fileManager = FileManager.default
    let title = normalizedTitle(rawTitle)
    let baseDirectory = corpusRoot
      .appendingPathComponent("meetings", isDirectory: true)
    try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

    let basePrefix = "\(timestampSlug(recordedAt))-\(slug(title))"
    var baseName = basePrefix
    var suffix = 2
    while (OrgDocumentDefaults.candidateURLs(in: baseDirectory, baseName: baseName)
      + OrgDocumentDefaults.candidateURLs(in: baseDirectory, baseName: "\(baseName).transcript"))
      .contains(where: { fileManager.fileExists(atPath: $0.path) })
      || fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).\(audioExtension)").path)
      || fileManager.fileExists(atPath: baseDirectory.appendingPathComponent("\(baseName).system.\(systemAudioExtension)").path) {
      baseName = "\(basePrefix)-\(suffix)"
      suffix += 1
    }

    return MeetingArtifactPaths(
      meetingID: UUID().uuidString.lowercased(),
      title: title,
      recordedAt: recordedAt,
      baseName: baseName,
      noteURL: baseDirectory.appendingPathComponent("\(baseName).\(OrgDocumentDefaults.preferredExtension)"),
      audioURL: baseDirectory.appendingPathComponent("\(baseName).\(audioExtension)"),
      systemAudioURL: baseDirectory.appendingPathComponent("\(baseName).system.\(systemAudioExtension)"),
      transcriptURL: baseDirectory.appendingPathComponent("\(baseName).transcript.\(OrgDocumentDefaults.preferredExtension)")
    )
  }

  public static func writeArtifacts(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
  ) throws -> MeetingArtifactBundle {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: paths.noteURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let transcriptText = buildTranscriptArtifact(
      paths: paths,
      corpusRoot: corpusRoot,
      duration: duration,
      transcript: transcript,
      systemAudioURL: systemAudioURL,
      captureSources: captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL)
    )
    try transcriptText.write(to: paths.transcriptURL, atomically: true, encoding: .utf8)

    let generatedNote = buildMeetingNote(
      paths: paths,
      corpusRoot: corpusRoot,
      duration: duration,
      transcript: transcript,
      systemAudioURL: systemAudioURL,
      captureSources: captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL)
    )
    // A live recording already has a note the user may have written in.
    // Update only its generated metadata and transcript section.
    let noteText: String
    if let existingNote = try? String(contentsOf: paths.noteURL, encoding: .utf8) {
      noteText = mergeMeetingNote(existing: existingNote, generated: generatedNote)
    } else {
      noteText = generatedNote
    }
    try noteText.write(to: paths.noteURL, atomically: true, encoding: .utf8)

    let item = MeetingWorkspaceItem(
      title: paths.title,
      file: paths.noteURL.path,
      line: 1,
      recordedAt: isoTimestamp(paths.recordedAt),
      modifiedAt: Date(),
      audioArtifact: relativePath(from: corpusRoot, to: paths.audioURL),
      systemAudioArtifact: systemAudioURL.map { relativePath(from: corpusRoot, to: $0) },
      transcriptArtifact: relativePath(from: corpusRoot, to: paths.transcriptURL),
      transcriptionStatus: transcript.status.rawValue,
      idValue: paths.meetingID
    )
    return MeetingArtifactBundle(
      item: item,
      noteURL: paths.noteURL,
      audioURL: paths.audioURL,
      systemAudioURL: systemAudioURL,
      transcriptURL: paths.transcriptURL
    )
  }

  /// Transcription status of a meeting note created when recording starts,
  /// before any transcript exists.
  public static let liveRecordingStatus = "recording"

  /// Creates the meeting note when recording starts, so the user can take
  /// notes while the meeting is recorded. Never replaces an existing file.
  public static func writeLiveMeetingNote(
    paths: MeetingArtifactPaths,
    corpusRoot: URL
  ) throws -> MeetingWorkspaceItem {
    try FileManager.default.createDirectory(
      at: paths.noteURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let text = buildLiveMeetingNote(paths: paths, corpusRoot: corpusRoot)
    try Data(text.utf8).write(to: paths.noteURL, options: [.withoutOverwriting])
    return MeetingWorkspaceItem(
      title: paths.title,
      file: paths.noteURL.path,
      line: 1,
      recordedAt: isoTimestamp(paths.recordedAt),
      modifiedAt: Date(),
      audioArtifact: relativePath(from: corpusRoot, to: paths.audioURL),
      transcriptArtifact: relativePath(from: corpusRoot, to: paths.transcriptURL),
      transcriptionStatus: liveRecordingStatus,
      idValue: paths.meetingID
    )
  }

  public static func buildLiveMeetingNote(
    paths: MeetingArtifactPaths,
    corpusRoot: URL
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let transcriptPath = relativePath(from: corpusRoot, to: paths.transcriptURL)
    let calendarLines = paths.calendar.map(calendarPropertyLines) ?? ""
    let attendeesSection = paths.calendar.map(attendeesSection) ?? ""

    return """
    #+TITLE: Meeting: \(paths.title)
    #+ORG2_KIND: meeting

    * Meeting: \(paths.title)
    :PROPERTIES:
    :ID: \(paths.meetingID)
    :kind: meeting
    :recorded_at: \(isoTimestamp(paths.recordedAt))
    :audio_artifact: \(audioPath)
    :transcript_artifact: \(transcriptPath)
    :transcription_status: \(liveRecordingStatus)
    \(calendarLines):source: org2-workspace
    :END:
    \(attendeesSection)
    ** Notes


    ** Summary
    - Pending OpenClaw processing.

    ** Decisions
    - [ ] Review transcript and extract decisions.

    ** TODOs
    - [ ] Review this meeting transcript.

    ** Transcript
    [[file:\(transcriptPath)][Open transcript artifact]]

    - Recording in progress. The transcript appears here after the recording stops.

    """
  }

  /// Property keys the writer owns that may be absent from a later write.
  /// Existing values for them are dropped rather than left stale.
  private static let writerOwnedOptionalProperties: Set<String> = [
    "duration_seconds", "system_audio_artifact", "transcription_error",
  ]

  /// Applies a freshly generated meeting note to the note that already exists
  /// for the recording. The first heading's property drawer and the
  /// `** Transcript` section come from `generated`; everything else, including
  /// notes written during the recording, stays as it is in `existing`.
  public static func mergeMeetingNote(existing: String, generated: String) -> String {
    let generatedLines = generated.components(separatedBy: "\n")
    guard let generatedDrawer = firstHeadingDrawer(in: generatedLines),
          let generatedTranscript = sectionRange(named: "** Transcript", in: generatedLines)
    else {
      return existing
    }
    var lines = existing.components(separatedBy: "\n")
    let generatedTranscriptLines = trimmingTrailingBlankLines(Array(generatedLines[generatedTranscript]))

    if let transcript = sectionRange(named: "** Transcript", in: lines) {
      lines.replaceSubrange(transcript, with: generatedTranscriptLines)
    } else {
      lines = trimmingTrailingBlankLines(lines)
      lines.append("")
      lines.append(contentsOf: generatedTranscriptLines)
    }

    if let drawer = firstHeadingDrawer(in: lines) {
      let body = (drawer.lowerBound + 1)..<(drawer.upperBound - 1)
      let generatedBody = (generatedDrawer.lowerBound + 1)..<(generatedDrawer.upperBound - 1)
      let generatedProperties = Array(generatedLines[generatedBody])
      let generatedKeys = Set(generatedProperties.compactMap(propertyKey))
      let preserved = lines[body].filter { line in
        guard let key = propertyKey(line) else { return true }
        return !generatedKeys.contains(key) && !writerOwnedOptionalProperties.contains(key)
      }
      lines.replaceSubrange(body, with: generatedProperties + preserved)
    }
    var merged = trimmingTrailingBlankLines(lines).joined(separator: "\n")
    merged += "\n"
    return merged
  }

  /// The line range of the property drawer directly under the first
  /// top-level heading, including its `:PROPERTIES:` and `:END:` lines.
  private static func firstHeadingDrawer(in lines: [String]) -> Range<Int>? {
    guard let heading = lines.firstIndex(where: { $0.hasPrefix("* ") }) else { return nil }
    var index = heading + 1
    while index < lines.count, isPlanningLine(lines[index]) { index += 1 }
    guard index < lines.count,
          lines[index].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:"
    else {
      return nil
    }
    guard let end = lines[(index + 1)...].firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces).uppercased() == ":END:"
    }) else {
      return nil
    }
    return index..<(end + 1)
  }

  private static func isPlanningLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("SCHEDULED:") || trimmed.hasPrefix("DEADLINE:") || trimmed.hasPrefix("CLOSED:")
  }

  /// A level-two section from its heading through its last non-blank line
  /// before the next heading at level one or two.
  private static func sectionRange(named heading: String, in lines: [String]) -> Range<Int>? {
    // Prefer the generated section, which links the transcript artifact, over
    // a heading of the same name the user wrote.
    let candidates = lines.indices.filter {
      lines[$0].trimmingCharacters(in: .whitespaces) == heading
    }
    let generated = candidates.first { index in
      index + 1 < lines.count && lines[index + 1].contains("][Open transcript artifact]]")
    }
    guard let start = generated ?? candidates.first else {
      return nil
    }
    // Transcript text inside a block may itself start with stars.
    var end = lines.count
    var inBlock = false
    for index in (start + 1)..<lines.count {
      let lowered = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
      if lowered.hasPrefix("#+begin_") { inBlock = true; continue }
      if lowered.hasPrefix("#+end_") { inBlock = false; continue }
      if !inBlock, lines[index].hasPrefix("* ") || lines[index].hasPrefix("** ") {
        end = index
        break
      }
    }
    while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
      end -= 1
    }
    return start..<end
  }

  private static func propertyKey(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let close = trimmed.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }
    let key = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
    return key.isEmpty ? nil : key.lowercased()
  }

  private static func trimmingTrailingBlankLines(_ lines: [String]) -> [String] {
    var result = lines
    while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      result.removeLast()
    }
    return result
  }

  public static func buildMeetingNote(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let systemAudioLine = systemAudioURL.map {
      ":system_audio_artifact: \(relativePath(from: corpusRoot, to: $0))\n"
    } ?? ""
    let transcriptPath = relativePath(from: corpusRoot, to: paths.transcriptURL)
    let durationLine = duration.map { ":duration_seconds: \(String(format: "%.1f", $0))\n" } ?? ""
    let errorLine = transcript.errorMessage.map { ":transcription_error: \(propertyValue($0))\n" } ?? ""
    let preview = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let previewBlock = preview.isEmpty
      ? "- Transcript text is pending. See the transcript artifact for status.\n"
      : transcriptPreview(preview)
    let calendarLines = paths.calendar.map(calendarPropertyLines) ?? ""
    let attendeesSection = paths.calendar.map(attendeesSection) ?? ""

    return """
    #+TITLE: Meeting: \(paths.title)
    #+ORG2_KIND: meeting

    * Meeting: \(paths.title)
    :PROPERTIES:
    :ID: \(paths.meetingID)
    :kind: meeting
    :recorded_at: \(isoTimestamp(paths.recordedAt))
    \(durationLine):audio_artifact: \(audioPath)
    \(systemAudioLine):capture_sources: \(captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL))
    :transcript_artifact: \(transcriptPath)
    :transcription_engine: \(transcript.engine)
    :transcription_status: \(transcript.status.rawValue)
    \(errorLine)\(calendarLines):source: org2-workspace
    :END:
    \(attendeesSection)
    ** Summary
    - Pending OpenClaw processing.

    ** Decisions
    - [ ] Review transcript and extract decisions.

    ** TODOs
    - [ ] Review this meeting transcript.

    ** Transcript
    [[file:\(transcriptPath)][Open transcript artifact]]

    \(previewBlock)
    """
  }

  static func calendarPropertyLines(_ context: MeetingCalendarContext) -> String {
    let event = context.event
    var lines = [
      ":calendar_event_id: \(propertyValue(event.eventId))",
      ":calendar_id: \(propertyValue(event.calendarId))",
      ":calendar_source: \(propertyValue(event.sourceProfileID))",
      ":scheduled_start: \(isoTimestamp(event.start))",
      ":scheduled_end: \(isoTimestamp(event.end))",
    ]
    if let link = event.htmlLink { lines.append(":calendar_link: \(propertyValue(link))") }
    if let url = event.meetingUrl { lines.append(":meeting_url: \(propertyValue(url))") }
    let names = context.attendees.map { propertyValue($0.label.replacingOccurrences(of: ",", with: " ")) }
    if !names.isEmpty { lines.append(":ATTENDEES: \(names.joined(separator: ", "))") }
    return lines.joined(separator: "\n") + "\n"
  }

  static func attendeesSection(_ context: MeetingCalendarContext) -> String {
    guard !context.attendees.isEmpty else { return "" }
    return "\n** Attendees\n" + context.attendees.map(\.orgListItem).joined(separator: "\n") + "\n"
  }

  public static func buildTranscriptArtifact(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
  ) -> String {
    let audioPath = relativePath(from: corpusRoot, to: paths.audioURL)
    let systemAudioLine = systemAudioURL.map {
      ":system_audio_artifact: \(relativePath(from: corpusRoot, to: $0))\n"
    } ?? ""
    let durationLine = duration.map { ":duration_seconds: \(String(format: "%.1f", $0))\n" } ?? ""
    let errorLine = transcript.errorMessage.map { ":transcription_error: \(propertyValue($0))\n" } ?? ""
    let body = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcriptBody = body.isEmpty
      ? "Local transcription did not produce text. \(transcript.errorMessage ?? "Install whisper.cpp or OpenAI Whisper locally and retranscribe the audio artifact.")"
      : body

    return """
    #+TITLE: Transcript: \(paths.title)
    #+ORG2_KIND: meeting-transcript

    * Transcript: \(paths.title)
    :PROPERTIES:
    :ID: \(UUID().uuidString.lowercased())
    :kind: meeting_transcript
    :meeting_id: \(paths.meetingID)
    :recorded_at: \(isoTimestamp(paths.recordedAt))
    \(durationLine):audio_artifact: \(audioPath)
    \(systemAudioLine):capture_sources: \(captureSources ?? defaultCaptureSources(systemAudioURL: systemAudioURL))
    :transcription_engine: \(transcript.engine)
    :transcription_status: \(transcript.status.rawValue)
    \(errorLine):source: org2-workspace
    :END:

    \(transcriptBody)
    """
  }

  public static func normalizedTitle(_ raw: String) -> String {
    let title = raw
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled Meeting" : title
  }

  public static func slug(_ raw: String) -> String {
    let lowercased = raw.lowercased()
    let scalars = lowercased.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) {
        return Character(scalar)
      }
      return "-"
    }
    let collapsed = String(scalars)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    return collapsed.isEmpty ? "meeting" : String(collapsed.prefix(64))
  }

  public static func relativePath(from root: URL, to url: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath { return "." }
    if path.hasPrefix(rootPath + "/") {
      return String(path.dropFirst(rootPath.count + 1))
    }
    return path
  }

  public static func audioDuration(at url: URL) -> TimeInterval? {
    guard let audioFile = try? AVAudioFile(forReading: url),
          audioFile.processingFormat.sampleRate > 0
    else {
      return nil
    }
    let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
    guard seconds.isFinite, seconds > 0 else { return nil }
    return seconds
  }

  public static func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func timestampSlug(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: date)
  }

  private static func transcriptPreview(_ text: String) -> String {
    let limit = 4_000
    if text.count <= limit {
      return """
      #+begin_quote
      \(text)
      #+end_quote
      """
    }
    let index = text.index(text.startIndex, offsetBy: limit)
    return """
    #+begin_quote
    \(String(text[..<index]))
    ...[transcript truncated in meeting note; see artifact]
    #+end_quote
    """
  }

  private static func defaultCaptureSources(systemAudioURL: URL?) -> String {
    systemAudioURL == nil ? "microphone" : "microphone, system_audio"
  }

  private static func propertyValue(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum MeetingTranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case localWhisper = "local-whisper"
  case fluidVoice = "fluid-voice"
  case macOSSpeech = "macos-speech"
  case customCommand = "custom-command"

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .automatic: "Automatic"
    case .localWhisper: "Local Whisper"
    case .fluidVoice: "Fluid Voice"
    case .macOSSpeech: "macOS Speech"
    case .customCommand: "Custom Command"
    }
  }

  public var detailText: String {
    switch self {
    case .automatic:
      "Uses local Whisper when available, then falls back to macOS Speech with a visible diagnostic."
    case .localWhisper:
      "Uses the bundled or installed whisper.cpp runtime without silently changing providers."
    case .fluidVoice:
      "Uses Fluid Voice's selected speech model through its local API."
    case .macOSSpeech:
      "Uses Apple's built-in Speech recognizer."
    case .customCommand:
      "Runs a local command that writes the transcript to standard output."
    }
  }

  public var serializesMeetingSources: Bool {
    switch self {
    case .localWhisper, .customCommand:
      true
    case .automatic, .fluidVoice, .macOSSpeech:
      false
    }
  }
}

public struct MeetingTranscriptionConfiguration: Equatable, Sendable {
  public static let defaultFluidVoiceEndpoint = "http://127.0.0.1:47733"

  public let provider: MeetingTranscriptionProvider
  public let fluidVoiceEndpoint: String
  public let customCommand: String
  public let whisperModelPath: String
  public let language: String

  public init(
    provider: MeetingTranscriptionProvider = .automatic,
    fluidVoiceEndpoint: String = Self.defaultFluidVoiceEndpoint,
    customCommand: String = "",
    whisperModelPath: String = "",
    language: String = "en"
  ) {
    self.provider = provider
    self.fluidVoiceEndpoint = fluidVoiceEndpoint
    self.customCommand = customCommand
    self.whisperModelPath = whisperModelPath
    self.language = language
  }
}

public struct LocalWhisperConfiguration: Sendable {
  public let environment: [String: String]
  public let bundleResourceURL: URL?
  public let modelOverride: String?
  public let commandOverride: String?
  public let languageOverride: String?

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    modelOverride: String? = nil,
    commandOverride: String? = nil,
    languageOverride: String? = nil
  ) {
    self.environment = environment
    self.bundleResourceURL = bundleResourceURL
    self.modelOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.commandOverride = commandOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.languageOverride = languageOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  public var requestedModel: String? {
    modelOverride ?? CelorgaNames.environment("ORG2_WORKSPACE_WHISPER_MODEL", in: environment)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  public var overrideCommand: String? {
    commandOverride ?? CelorgaNames.environment("ORG2_WORKSPACE_WHISPER_COMMAND", in: environment)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  public var requestedLanguage: String {
    languageOverride ?? CelorgaNames.environment("ORG2_WORKSPACE_WHISPER_LANGUAGE", in: environment)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? "en"
  }

  public var requestedThreadCount: Int {
    if let raw = CelorgaNames.environment("ORG2_WORKSPACE_WHISPER_THREADS", in: environment)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let parsed = Int(raw),
      parsed > 0 {
      return parsed
    }
    return Self.defaultThreadCount(
      activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
    )
  }

  public static func defaultThreadCount(activeProcessorCount: Int) -> Int {
    min(4, max(1, activeProcessorCount / 2))
  }
}

public struct LocalWhisperInstallationStatus: Equatable, Sendable {
  public let backendDescription: String
  public let whisperCppExecutablePath: String?
  public let whisperCppModelPath: String?
  public let openAIWhisperExecutablePath: String?
  public let overrideCommand: String?
  public let whisperCppLaunchError: String?

  public init(
    backendDescription: String,
    whisperCppExecutablePath: String?,
    whisperCppModelPath: String?,
    openAIWhisperExecutablePath: String?,
    overrideCommand: String?,
    whisperCppLaunchError: String? = nil
  ) {
    self.backendDescription = backendDescription
    self.whisperCppExecutablePath = whisperCppExecutablePath
    self.whisperCppModelPath = whisperCppModelPath
    self.openAIWhisperExecutablePath = openAIWhisperExecutablePath
    self.overrideCommand = overrideCommand
    self.whisperCppLaunchError = whisperCppLaunchError
  }

  public var isWhisperCppReady: Bool {
    whisperCppExecutablePath != nil && whisperCppModelPath != nil
  }

  public var isAnyLocalTranscriberAvailable: Bool {
    true
  }

  public var statusLabel: String {
    if isWhisperCppReady { return "Fast local transcription ready" }
    if overrideCommand != nil { return "Custom transcriber configured" }
    if openAIWhisperExecutablePath != nil { return "Python Whisper available; whisper.cpp recommended" }
    if whisperCppExecutablePath != nil { return "whisper.cpp installed; model missing" }
    return "Built-in macOS transcription ready"
  }

  public var detailText: String {
    if isWhisperCppReady {
      return "Using whisper.cpp with \(whisperCppModelPath ?? "a GGML model")."
    }
    if whisperCppExecutablePath != nil {
      return "Install a GGML model to enable the fast whisper.cpp path."
    }
    if openAIWhisperExecutablePath != nil {
      return "Using Python Whisper. Install whisper.cpp for faster local transcription."
    }
    if let overrideCommand {
      return "Using custom command: \(overrideCommand)"
    }
    if let whisperCppLaunchError {
      return "whisper.cpp could not launch: \(whisperCppLaunchError)"
    }
    return "Uses macOS Speech out of the box. whisper.cpp remains an optional faster local backend."
  }
}

public enum FluidVoiceTranscriberError: LocalizedError {
  case invalidEndpoint
  case nonLocalEndpoint
  case unavailable(String)
  case rejected(String)
  case invalidResponse
  case emptyTranscript
  case audioPreparationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Enter a valid Fluid Voice endpoint, such as http://127.0.0.1:47733."
    case .nonLocalEndpoint:
      "Fluid Voice must use a loopback endpoint on localhost."
    case let .unavailable(message):
      "Fluid Voice Local API is unavailable\(message.isEmpty ? "." : ": \(message)")"
    case let .rejected(message):
      "Fluid Voice rejected the transcription\(message.isEmpty ? "." : ": \(message)")"
    case .invalidResponse:
      "Fluid Voice returned an invalid response."
    case .emptyTranscript:
      "Fluid Voice completed without producing text."
    case let .audioPreparationFailed(message):
      "Could not prepare meeting audio for Fluid Voice: \(message)"
    }
  }
}

public struct FluidVoiceTranscriber: Sendable {
  public static let maximumChunkDuration: TimeInterval = 285
  public static let chunkOverlap: TimeInterval = 1

  public let endpoint: URL
  private let session: URLSession
  private let maximumChunkDuration: TimeInterval
  private let chunkOverlap: TimeInterval

  public init(
    endpoint rawEndpoint: String = MeetingTranscriptionConfiguration.defaultFluidVoiceEndpoint,
    session: URLSession = .shared,
    maximumChunkDuration: TimeInterval = Self.maximumChunkDuration,
    chunkOverlap: TimeInterval = Self.chunkOverlap
  ) throws {
    guard let endpoint = Self.normalizedEndpoint(rawEndpoint) else {
      throw FluidVoiceTranscriberError.invalidEndpoint
    }
    guard Self.isLoopback(endpoint) else {
      throw FluidVoiceTranscriberError.nonLocalEndpoint
    }
    self.endpoint = endpoint
    self.session = session
    self.maximumChunkDuration = maximumChunkDuration
    self.chunkOverlap = max(0, min(chunkOverlap, maximumChunkDuration / 4))
  }

  public func healthDescription() async throws -> String {
    let healthURL = endpoint.appendingPathComponent("v1/health")
    var request = URLRequest(url: healthURL)
    request.timeoutInterval = 3
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw FluidVoiceTranscriberError.unavailable(Self.responseMessage(data))
      }
      let payload = try JSONDecoder().decode(HealthResponse.self, from: data)
      return "Fluid Voice \(payload.version) is ready"
    } catch let error as FluidVoiceTranscriberError {
      throw error
    } catch {
      throw FluidVoiceTranscriberError.unavailable(error.localizedDescription)
    }
  }

  public func transcribe(audioURL: URL) async throws -> MeetingTranscriptResult {
    let prepared = try await Self.preparedChunks(
      audioURL: audioURL,
      maximumDuration: maximumChunkDuration,
      overlap: chunkOverlap
    )
    defer {
      for url in prepared.temporaryURLs {
        try? FileManager.default.removeItem(at: url)
      }
    }

    var segments: [String] = []
    var providerNames: [String] = []
    for url in prepared.urls {
      let response = try await transcribeFile(at: url)
      segments.append(response.text)
      providerNames.append(response.provider)
    }
    let text = Self.mergedTranscriptSegments(segments)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw FluidVoiceTranscriberError.emptyTranscript }
    let provider = providerNames.first(where: { !$0.isEmpty }) ?? "selected model"
    let chunkSuffix = prepared.urls.count > 1 ? ", \(prepared.urls.count) chunks" : ""
    return MeetingTranscriptResult(
      text: text,
      status: .complete,
      engine: "Fluid Voice (\(provider)\(chunkSuffix))"
    )
  }

  public static func mergedTranscriptSegments(_ segments: [String]) -> String {
    var mergedWords: [String] = []
    for segment in segments {
      let words = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard !words.isEmpty else { continue }
      let maximumOverlap = min(24, mergedWords.count, words.count)
      var overlap = 0
      if maximumOverlap > 0 {
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
          let tail = mergedWords.suffix(count).map(Self.normalizedWord)
          let head = words.prefix(count).map(Self.normalizedWord)
          if tail == head {
            overlap = count
            break
          }
        }
      }
      mergedWords.append(contentsOf: words.dropFirst(overlap))
    }
    return mergedWords.joined(separator: " ")
  }

  private func transcribeFile(at audioURL: URL) async throws -> TranscriptionResponse {
    let url = endpoint.appendingPathComponent("v1/transcribe")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 300
    request.httpBody = try JSONEncoder().encode(TranscriptionRequest(path: audioURL.path))
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw FluidVoiceTranscriberError.invalidResponse
      }
      guard (200..<300).contains(http.statusCode) else {
        throw FluidVoiceTranscriberError.rejected(Self.responseMessage(data))
      }
      return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    } catch let error as FluidVoiceTranscriberError {
      throw error
    } catch is DecodingError {
      throw FluidVoiceTranscriberError.invalidResponse
    } catch {
      throw FluidVoiceTranscriberError.unavailable(error.localizedDescription)
    }
  }

  private static func preparedChunks(
    audioURL: URL,
    maximumDuration: TimeInterval,
    overlap: TimeInterval
  ) async throws -> (urls: [URL], temporaryURLs: [URL]) {
    guard let duration = MeetingArtifactWriter.audioDuration(at: audioURL), duration > maximumDuration else {
      return ([audioURL], [])
    }
    return try await Task.detached(priority: .utility) {
      let normalizedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("org2-fluid-voice-input-\(UUID().uuidString).wav")
      var temporaryURLs = [normalizedURL]
      do {
        try LocalWhisperTranscriber.convertAudioToWhisperWAV(sourceURL: audioURL, outputURL: normalizedURL)
        let source = try AVAudioFile(forReading: normalizedURL)
        let sampleRate = source.processingFormat.sampleRate
        guard sampleRate > 0 else {
          throw FluidVoiceTranscriberError.audioPreparationFailed("The audio sample rate is invalid.")
        }
        let framesPerChunk = AVAudioFramePosition(maximumDuration * sampleRate)
        let overlapFrames = AVAudioFramePosition(overlap * sampleRate)
        guard framesPerChunk > overlapFrames else {
          throw FluidVoiceTranscriberError.audioPreparationFailed("The chunk duration is too small.")
        }
        var start: AVAudioFramePosition = 0
        var chunks: [URL] = []
        while start < source.length {
          let frameCount = min(framesPerChunk, source.length - start)
          guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
          ) else {
            throw FluidVoiceTranscriberError.audioPreparationFailed("Could not allocate an audio chunk buffer.")
          }
          source.framePosition = start
          try source.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
          let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("org2-fluid-voice-chunk-\(UUID().uuidString).wav")
          let output = try AVAudioFile(forWriting: chunkURL, settings: source.fileFormat.settings)
          try output.write(from: buffer)
          chunks.append(chunkURL)
          temporaryURLs.append(chunkURL)
          if start + frameCount >= source.length { break }
          start += frameCount - overlapFrames
        }
        return (chunks, temporaryURLs)
      } catch let error as FluidVoiceTranscriberError {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        throw error
      } catch {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        throw FluidVoiceTranscriberError.audioPreparationFailed(error.localizedDescription)
      }
    }.value
  }

  private static func normalizedEndpoint(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == "http",
          components.host != nil,
          components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    else { return nil }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private static func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  private static func normalizedWord(_ raw: String) -> String {
    raw.trimmingCharacters(in: .punctuationCharacters).lowercased()
  }

  private static func responseMessage(_ data: Data) -> String {
    if let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
      return payload.error
    }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private struct HealthResponse: Decodable {
    let status: String
    let version: String
  }

  private struct TranscriptionRequest: Encodable {
    let path: String
  }

  private struct TranscriptionResponse: Decodable {
    let text: String
    let confidence: Float
    let sampleCount: Int
    let provider: String
  }

  private struct ErrorResponse: Decodable {
    let error: String
  }
}

public enum NativeSpeechTranscriberError: LocalizedError {
  case authorizationDenied
  case recognizerUnavailable
  case emptyTranscript

  public var errorDescription: String? {
    switch self {
    case .authorizationDenied:
      "Speech recognition permission is required for dictation. Allow Celorga under System Settings → Privacy & Security → Speech Recognition."
    case .recognizerUnavailable:
      "macOS Speech recognition is temporarily unavailable."
    case .emptyTranscript:
      "macOS Speech recognition completed without producing text."
    }
  }
}

private final class NativeSpeechRecognitionCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?

  init(_ continuation: CheckedContinuation<String, Error>) {
    self.continuation = continuation
  }

  func finish(_ result: Result<String, Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(with: result)
  }
}

public struct NativeSpeechTranscriber: Sendable {
  public init() {}

  public func transcribe(audioURL: URL) async throws -> MeetingTranscriptResult {
    let authorization = await authorizationStatus()
    guard authorization == .authorized else {
      throw NativeSpeechTranscriberError.authorizationDenied
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
      throw NativeSpeechTranscriberError.recognizerUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: audioURL)
    request.shouldReportPartialResults = false
    request.addsPunctuation = true
    let text = try await withCheckedThrowingContinuation { continuation in
      let completion = NativeSpeechRecognitionCompletion(continuation)
      recognizer.recognitionTask(with: request) { result, error in
        if let error {
          completion.finish(.failure(error))
          return
        }
        guard let result, result.isFinal else { return }
        let transcript = result.bestTranscription.formattedString
          .trimmingCharacters(in: .whitespacesAndNewlines)
        completion.finish(transcript.isEmpty
          ? .failure(NativeSpeechTranscriberError.emptyTranscript)
          : .success(transcript))
      }
    }
    return MeetingTranscriptResult(text: text, status: .complete, engine: "macOS Speech")
  }

  private func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
    let current = SFSpeechRecognizer.authorizationStatus()
    guard current == .notDetermined else { return current }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

public struct LocalWhisperTranscriber: Sendable {
  public let configuration: LocalWhisperConfiguration
  public static let defaultWhisperCppModelDownloadURL = URL(
    string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
  )!

  public static var defaultWhisperCppModelURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/org2/whisper", isDirectory: true)
      .appendingPathComponent("ggml-base.en.bin")
  }

  public init(configuration: LocalWhisperConfiguration = LocalWhisperConfiguration()) {
    self.configuration = configuration
  }

  public func transcribe(audioURL: URL) async throws -> MeetingTranscriptResult {
    let configuration = configuration
    return try await Task.detached(priority: .utility) {
      try Self.transcribeSync(audioURL: audioURL, configuration: configuration)
    }.value
  }

  /// `verifyExecutableLaunch: false` only checks that files exist. Status
  /// text uses it: launching whisper.cpp to prove it runs blocked app launch
  /// and meeting refreshes on the main thread for seconds.
  public static func resolvedBackendDescription(
    configuration: LocalWhisperConfiguration = LocalWhisperConfiguration(),
    verifyExecutableLaunch: Bool = true
  ) -> String {
    if let command = configuration.overrideCommand {
      return "custom local command: \(command)"
    }
    let whisperCpp = verifyExecutableLaunch
      ? resolveLaunchableWhisperCppExecutable(configuration: configuration).executable
      : resolveWhisperCppExecutables(configuration: configuration).first
    if whisperCpp != nil,
       resolveWhisperCppModel(configuration: configuration) != nil {
      return "whisper.cpp"
    }
    if resolveExecutable(named: "whisper", environment: configuration.environment) != nil {
      return "OpenAI Whisper CLI"
    }
    return "macOS Speech"
  }

  public static func installationStatus(
    configuration: LocalWhisperConfiguration = LocalWhisperConfiguration(),
    verifyExecutableLaunch: Bool = true
  ) -> LocalWhisperInstallationStatus {
    let whisperCppResolution: (executable: URL?, error: String?) = verifyExecutableLaunch
      ? resolveLaunchableWhisperCppExecutable(configuration: configuration)
      : (resolveWhisperCppExecutables(configuration: configuration).first, nil)
    let whisperCpp = whisperCppResolution.executable
    let model = resolveWhisperCppModel(configuration: configuration)
    let openAIWhisper = resolveExecutable(named: "whisper", environment: configuration.environment)
    let backendDescription: String
    if let command = configuration.overrideCommand {
      backendDescription = "custom local command: \(command)"
    } else if whisperCpp != nil, model != nil {
      backendDescription = "whisper.cpp"
    } else if openAIWhisper != nil {
      backendDescription = "OpenAI Whisper CLI"
    } else {
      backendDescription = "macOS Speech"
    }
    return LocalWhisperInstallationStatus(
      backendDescription: backendDescription,
      whisperCppExecutablePath: whisperCpp?.path,
      whisperCppModelPath: model,
      openAIWhisperExecutablePath: openAIWhisper?.path,
      overrideCommand: configuration.overrideCommand,
      whisperCppLaunchError: whisperCppResolution.error
    )
  }

  private static func transcribeSync(
    audioURL: URL,
    configuration: LocalWhisperConfiguration
  ) throws -> MeetingTranscriptResult {
    if let command = configuration.overrideCommand {
      let result = try runShellTranscriber(command: command, audioURL: audioURL)
      return MeetingTranscriptResult(text: result, status: .complete, engine: "local-whisper:custom")
    }

    var whisperCppErrors: [String] = []
    if let model = resolveWhisperCppModel(configuration: configuration) {
      for whisperCpp in resolveWhisperCppExecutables(configuration: configuration) {
        do {
          let result = try runWhisperCpp(
            executable: whisperCpp,
            model: model,
            audioURL: audioURL,
            language: configuration.requestedLanguage,
            threadCount: configuration.requestedThreadCount
          )
          return MeetingTranscriptResult(text: result, status: .complete, engine: "whisper.cpp")
        } catch {
          whisperCppErrors.append("\(whisperCpp.path): \(error.localizedDescription)")
        }
      }
    }

    if let whisper = resolveExecutable(named: "whisper", environment: configuration.environment) {
      let result = try runOpenAIWhisper(
        executable: whisper,
        audioURL: audioURL,
        model: configuration.requestedModel,
        language: configuration.requestedLanguage
      )
      return MeetingTranscriptResult(text: result, status: .complete, engine: "openai-whisper")
    }

    if !whisperCppErrors.isEmpty {
      throw LocalWhisperError.commandFailed(
        "whisper.cpp",
        -1,
        whisperCppErrors.joined(separator: "; ")
      )
    }
    throw LocalWhisperError.notConfigured
  }

  private static func runShellTranscriber(command: String, audioURL: URL) throws -> String {
    let quotedAudio = shellQuote(audioURL.path)
    let resolvedCommand = command.contains("{audio}")
      ? command.replacingOccurrences(of: "{audio}", with: quotedAudio)
      : "\(command) \(quotedAudio)"
    let result = try runProcess(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-lc", resolvedCommand],
      currentDirectoryURL: audioURL.deletingLastPathComponent()
    )
    return try transcriptText(stdout: result.stdout, stderr: result.stderr)
  }

  private static func runWhisperCpp(
    executable: URL,
    model: String,
    audioURL: URL,
    language: String,
    threadCount: Int
  ) throws -> String {
    let whisperAudioURL = try whisperCppCompatibleAudioURL(for: audioURL)
    defer {
      if whisperAudioURL.standardizedFileURL.path != audioURL.standardizedFileURL.path {
        try? FileManager.default.removeItem(at: whisperAudioURL)
      }
    }
    let outputPrefix = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-whisper-\(UUID().uuidString)")
    let result = try runProcess(
      executableURL: executable,
      arguments: [
        "-m", model,
        "-f", whisperAudioURL.path,
        "-l", language,
        "-t", "\(threadCount)",
        "-nt",
        "-otxt",
        "-of", outputPrefix.path
      ],
      currentDirectoryURL: audioURL.deletingLastPathComponent()
    )
    let transcriptURL = URL(fileURLWithPath: outputPrefix.path + ".txt")
    if let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try? FileManager.default.removeItem(at: transcriptURL)
      return text
    }
    return try transcriptText(stdout: result.stdout, stderr: result.stderr)
  }

  private static func whisperCppCompatibleAudioURL(for audioURL: URL) throws -> URL {
    guard audioURL.pathExtension.lowercased() != "wav" else { return audioURL }
    let convertedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-whisper-input-\(UUID().uuidString).wav")
    do {
      try convertAudioToWhisperWAV(sourceURL: audioURL, outputURL: convertedURL)
      return convertedURL
    } catch {
      try? FileManager.default.removeItem(at: convertedURL)
      throw LocalWhisperError.audioConversionFailed(audioURL.lastPathComponent, error.localizedDescription)
    }
  }

  static func convertAudioToWhisperWAV(sourceURL: URL, outputURL: URL) throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    let converterURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    guard FileManager.default.isExecutableFile(atPath: converterURL.path) else {
      throw LocalWhisperError.audioConversionFailed(sourceURL.lastPathComponent, "afconvert is not available.")
    }
    let result = try runProcess(
      executableURL: converterURL,
      arguments: [
        "-f", "WAVE",
        "-d", "LEI16@16000",
        "-c", "1",
        sourceURL.path,
        outputURL.path
      ],
      currentDirectoryURL: sourceURL.deletingLastPathComponent()
    )
    guard FileManager.default.fileExists(atPath: outputURL.path) else {
      throw LocalWhisperError.audioConversionFailed(
        sourceURL.lastPathComponent,
        result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }

  private static func runOpenAIWhisper(
    executable: URL,
    audioURL: URL,
    model: String?,
    language: String
  ) throws -> String {
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openai-whisper-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var arguments = [
      audioURL.path,
      "--language", language,
      "--task", "transcribe",
      "--output_format", "txt",
      "--output_dir", outputDirectory.path
    ]
    if let model {
      arguments += ["--model", model]
    }
    let result = try runProcess(
      executableURL: executable,
      arguments: arguments,
      currentDirectoryURL: audioURL.deletingLastPathComponent()
    )
    let transcriptURL = outputDirectory.appendingPathComponent(audioURL.deletingPathExtension().lastPathComponent + ".txt")
    if let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try? FileManager.default.removeItem(at: outputDirectory)
      return text
    }
    return try transcriptText(stdout: result.stdout, stderr: result.stderr)
  }

  private static func resolveWhisperCppModel(configuration: LocalWhisperConfiguration) -> String? {
    if let requested = configuration.requestedModel {
      return FileManager.default.fileExists(atPath: requested) ? requested : nil
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var candidates: [String] = []
    if let bundledModel = configuration.bundleResourceURL?
      .appendingPathComponent("Whisper/models/ggml-base.en.bin")
      .path {
      candidates.append(bundledModel)
    }
    candidates += [
      "\(home)/Library/Application Support/org2/whisper/ggml-tiny.en.bin",
      "\(home)/Library/Application Support/org2/whisper/ggml-base.en.bin",
      "\(home)/.cache/whisper/ggml-tiny.en.bin",
      "\(home)/.cache/whisper/ggml-base.en.bin",
      "\(home)/.cache/whisper.cpp/ggml-tiny.en.bin",
      "\(home)/.cache/whisper.cpp/ggml-base.en.bin",
      "\(home)/dev/whisper.cpp/models/ggml-tiny.en.bin",
      "\(home)/dev/whisper.cpp/models/ggml-base.en.bin",
      "\(home)/openclaw/models/ggml-tiny.en.bin",
      "\(home)/openclaw/models/ggml-base.en.bin",
      "/opt/homebrew/share/whisper-cpp/models/ggml-tiny.en.bin",
      "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin",
      "/usr/local/share/whisper-cpp/models/ggml-tiny.en.bin",
      "/usr/local/share/whisper-cpp/models/ggml-base.en.bin"
    ]

    return candidates.first { FileManager.default.fileExists(atPath: $0) }
  }

  private static func resolveWhisperCppExecutables(configuration: LocalWhisperConfiguration) -> [URL] {
    var candidates: [URL] = []
    if let bundledExecutable = configuration.bundleResourceURL?
      .appendingPathComponent("Whisper/bin/whisper-cli"),
      FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
      candidates.append(bundledExecutable)
    }
    if let executable = resolveExecutable(named: "whisper-cli", environment: configuration.environment) {
      candidates.append(executable)
    }
    if let executable = resolveExecutable(named: "whisper-cpp", environment: configuration.environment) {
      candidates.append(executable)
    }
    var seen = Set<String>()
    return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private static func resolveLaunchableWhisperCppExecutable(
    configuration: LocalWhisperConfiguration
  ) -> (executable: URL?, error: String?) {
    var errors: [String] = []
    for executable in resolveWhisperCppExecutables(configuration: configuration) {
      do {
        _ = try runProcess(
          executableURL: executable,
          arguments: ["--help"],
          currentDirectoryURL: executable.deletingLastPathComponent()
        )
        return (executable, errors.isEmpty ? nil : errors.joined(separator: "; "))
      } catch {
        errors.append("\(executable.lastPathComponent): \(error.localizedDescription)")
      }
    }
    return (nil, errors.joined(separator: "; ").nilIfEmpty)
  }

  private static func resolveExecutable(named name: String, environment: [String: String]) -> URL? {
    if name.hasPrefix("/") {
      return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
    }
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let path = environment["PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      .map { "\($0):\(defaultPath)" } ?? defaultPath
    for directory in path.split(separator: ":").map(String.init) {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private static func transcriptText(stdout: String, stderr: String) throws -> String {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    throw LocalWhisperError.emptyTranscript(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func runProcess(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
  ) throws -> ProcessTextResult {
    let process = Process()
    let niceURL = URL(fileURLWithPath: "/usr/bin/nice")
    if FileManager.default.isExecutableFile(atPath: niceURL.path) {
      process.executableURL = niceURL
      process.arguments = ["-n", "10", executableURL.path] + arguments
    } else {
      process.executableURL = executableURL
      process.arguments = arguments
    }
    process.currentDirectoryURL = currentDirectoryURL

    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(defaultPath):\(existing)"
    } else {
      environment["PATH"] = defaultPath
    }
    let backgroundThreadLimit = String(LocalWhisperConfiguration.defaultThreadCount(
      activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
    ))
    for key in ["OMP_NUM_THREADS", "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"]
      where environment[key]?.isEmpty != false {
      environment[key] = backgroundThreadLimit
    }
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let stdoutCollector = TextPipeCollector()
    let stderrCollector = TextPipeCollector()
    let readGroup = DispatchGroup()

    try process.run()

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      stdoutCollector.set(stdout.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      stderrCollector.set(stderr.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }

    process.waitUntilExit()
    readGroup.wait()

    let output = ProcessTextResult(
      stdout: String(data: stdoutCollector.data, encoding: .utf8) ?? "",
      stderr: String(data: stderrCollector.data, encoding: .utf8) ?? ""
    )

    guard process.terminationStatus == 0 else {
      throw LocalWhisperError.commandFailed(
        executableURL.lastPathComponent,
        Int(process.terminationStatus),
        output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    return output
  }

  private static func shellQuote(_ raw: String) -> String {
    "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

public final class MeetingSystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let sampleQueue = DispatchQueue(label: "org2.workspace.meeting.system-audio.samples")
  private let stateLock = NSLock()
  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var firstPresentationTime: CMTime?
  private var lastPresentationTime: CMTime?
  private var lastMeterSnapshotTime: CMTime?
  private var sampleCount = 0
  private var latestSnapshot = MeetingInputMeterSnapshot.silent
  private var captureState = MeetingSystemAudioCaptureState()

  private static let meterSnapshotIntervalSeconds = 0.25

  public override init() {}

  public var inputMeterSnapshot: MeetingInputMeterSnapshot {
    stateLock.withLock { latestSnapshot }
  }

  public var captureErrorDescription: String? {
    stateLock.withLock { captureState.firstFailureDescription }
  }

  public var needsRecovery: Bool {
    stateLock.withLock { captureState.needsRecovery }
  }

  public func startRecording(to audioURL: URL) async throws {
    let alreadyRecording = stateLock.withLock { self.stream != nil }
    guard !alreadyRecording else { throw MeetingSystemAudioRecorderError.alreadyRecording }

    try FileManager.default.createDirectory(
      at: audioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: audioURL.path) {
      try FileManager.default.removeItem(at: audioURL)
    }

    let writer = try AVAssetWriter(outputURL: audioURL, fileType: .m4a)
    let writerInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000
      ]
    )
    writerInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(writerInput) else {
      throw MeetingSystemAudioRecorderError.writerSetupFailed("Cannot add audio writer input.")
    }
    writer.add(writerInput)

    let stream: SCStream
    do {
      stream = try await makeStream()
    } catch {
      writer.cancelWriting()
      throw error
    }

    stateLock.withLock {
      self.stream = stream
      self.writer = writer
      self.writerInput = writerInput
      firstPresentationTime = nil
      lastPresentationTime = nil
      lastMeterSnapshotTime = nil
      sampleCount = 0
      latestSnapshot = .silent
      captureState.reset()
    }

    do {
      try await startCapture(stream)
      stateLock.withLock {
        captureState.didStart()
      }
    } catch {
      resetState(cancelWriter: true)
      throw error
    }
  }

  public func stopRecording() async throws -> TimeInterval? {
    try await stopRecordingWithResult().duration
  }

  public func stopRecordingWithResult() async throws -> MeetingSystemAudioRecordingResult {
    let state = stateLock.withLock {
      (stream: stream, writer: writer, writerInput: writerInput, isCaptureRunning: captureState.isRunning)
    }

    guard let stream = state.stream,
          let writer = state.writer,
          let writerInput = state.writerInput
    else {
      throw MeetingSystemAudioRecorderError.notRecording
    }

    var explicitStopFailure: String?
    if state.isCaptureRunning {
      do {
        try await stopCapture(stream)
        stateLock.withLock {
          captureState.didStopNormally()
        }
      } catch {
        // ScreenCaptureKit can report an unexpected stop through the delegate
        // just before this completion handler says the stream is already
        // stopped. Preserve the delegate's original error and still finalize
        // every sample the writer received.
        explicitStopFailure = error.localizedDescription
      }
    }
    detachAudioOutput(from: stream)
    return try await finishWriting(
      writer: writer,
      writerInput: writerInput,
      explicitStopFailure: explicitStopFailure
    )
  }

  public func pauseRecording() async throws {
    let state = stateLock.withLock {
      (stream: stream, isCaptureRunning: captureState.isRunning)
    }
    guard let stream = state.stream else { throw MeetingSystemAudioRecorderError.notRecording }
    guard state.isCaptureRunning else { return }
    try await stopCapture(stream)
    stateLock.withLock {
      captureState.didStopNormally()
      latestSnapshot = .silent
    }
  }

  public func resumeRecording() async throws {
    let state = stateLock.withLock {
      (
        stream: stream,
        isCaptureRunning: captureState.isRunning,
        needsRecovery: captureState.needsRecovery
      )
    }
    guard let stream = state.stream else { throw MeetingSystemAudioRecorderError.notRecording }
    guard !state.isCaptureRunning else { return }
    if state.needsRecovery {
      guard try await recoverRecording() else {
        throw MeetingSystemAudioRecorderError.startFailed(
          "The interrupted system audio stream could not be recreated."
        )
      }
      return
    }
    try await startCapture(stream)
    stateLock.withLock {
      captureState.didStart()
    }
  }

  @discardableResult
  public func recoverRecording() async throws -> Bool {
    let state = stateLock.withLock {
      (
        stream: stream,
        writer: writer,
        shouldRecover: captureState.needsRecovery,
        interruptionCount: captureState.interruptionCount
      )
    }
    guard let writer = state.writer else {
      throw MeetingSystemAudioRecorderError.notRecording
    }
    guard state.shouldRecover else {
      return false
    }

    if let previousStream = state.stream {
      detachAudioOutput(from: previousStream)
    }

    let replacement = try await makeStream()
    let installed = stateLock.withLock {
      guard self.writer === writer, captureState.needsRecovery else { return false }
      stream = replacement
      return true
    }
    guard installed else {
      detachAudioOutput(from: replacement)
      return false
    }

    do {
      try await startCapture(replacement)
      let accepted = stateLock.withLock {
        guard self.writer === writer, stream === replacement else { return false }
        return captureState.didRecover(afterInterruptionCount: state.interruptionCount)
      }
      if !accepted {
        try? await stopCapture(replacement)
        detachAudioOutput(from: replacement)
      }
      return accepted
    } catch {
      detachAudioOutput(from: replacement)
      throw error
    }
  }

  public func discardRecording() async {
    let state = stateLock.withLock {
      (stream: stream, isCaptureRunning: captureState.isRunning)
    }
    if let stream = state.stream {
      if state.isCaptureRunning {
        try? await stopCapture(stream)
      }
      detachAudioOutput(from: stream)
    }
    resetState(cancelWriter: true)
  }

  public nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio,
          sampleBuffer.isValid,
          CMSampleBufferDataIsReady(sampleBuffer)
    else {
      return
    }

    stateLock.withLock {
      guard let writer, let writerInput else {
        return
      }

      if writer.status == .unknown {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard writer.startWriting() else {
          return
        }
        writer.startSession(atSourceTime: presentationTime)
        firstPresentationTime = presentationTime
      }

      if writer.status == .writing, writerInput.isReadyForMoreMediaData {
        if writerInput.append(sampleBuffer) {
          let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
          sampleCount += 1
          lastPresentationTime = presentationTime
          if shouldUpdateMeterSnapshot(at: presentationTime),
             let snapshot = Self.meterSnapshot(from: sampleBuffer) {
            lastMeterSnapshotTime = presentationTime
            latestSnapshot = snapshot
          }
        }
      }
    }
  }

  private func shouldUpdateMeterSnapshot(at presentationTime: CMTime) -> Bool {
    guard presentationTime.isValid, presentationTime.isNumeric else {
      return true
    }
    guard let lastMeterSnapshotTime,
          lastMeterSnapshotTime.isValid,
          lastMeterSnapshotTime.isNumeric
    else {
      return true
    }
    return CMTimeGetSeconds(presentationTime - lastMeterSnapshotTime) >= Self.meterSnapshotIntervalSeconds
  }

  public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    stateLock.withLock {
      guard self.stream === stream else { return }
      captureState.didStopUnexpectedly(error.localizedDescription)
      latestSnapshot = .silent
    }
  }

  private func startCapture(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.startCapture { error in
        if let error {
          continuation.resume(throwing: MeetingSystemAudioRecorderError.startFailed(error.localizedDescription))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func makeStream() async throws -> SCStream {
    // Fetch a fresh content snapshot for every stream. Reusing a snapshot
    // across display, sleep, or audio-device changes can leave ScreenCaptureKit
    // tied to a capture graph that no longer produces audio.
    let content = try await SCShareableContent.current
    guard let display = content.displays.first else {
      throw MeetingSystemAudioRecorderError.noDisplayAvailable
    }

    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    configuration.showsCursor = false
    configuration.capturesAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.excludesCurrentProcessAudio = true

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
    return stream
  }

  private func detachAudioOutput(from stream: SCStream) {
    try? stream.removeStreamOutput(self, type: .audio)
  }

  private func stopCapture(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.stopCapture { error in
        if let error {
          continuation.resume(throwing: MeetingSystemAudioRecorderError.stopFailed(error.localizedDescription))
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func finishWriting(
    writer: AVAssetWriter,
    writerInput: AVAssetWriterInput,
    explicitStopFailure: String?
  ) async throws -> MeetingSystemAudioRecordingResult {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MeetingSystemAudioRecordingResult, Error>) in
      sampleQueue.async {
        let state = self.stateLock.withLock {
          let state = (
            firstPresentationTime: self.firstPresentationTime,
            lastPresentationTime: self.lastPresentationTime,
            sampleCount: self.sampleCount,
            captureErrorDescription: self.captureState.resolvedFailure(
              explicitStopFailure: explicitStopFailure
            )
          )
          self.stream = nil
          self.writer = nil
          self.writerInput = nil
          self.firstPresentationTime = nil
          self.lastPresentationTime = nil
          self.lastMeterSnapshotTime = nil
          self.sampleCount = 0
          self.latestSnapshot = .silent
          self.captureState.reset()
          return state
        }

        guard state.sampleCount > 0, writer.status != .unknown else {
          writer.cancelWriting()
          continuation.resume(returning: MeetingSystemAudioRecordingResult(
            duration: nil,
            capturedSampleCount: 0,
            captureErrorDescription: state.captureErrorDescription
          ))
          return
        }

        writerInput.markAsFinished()
        writer.finishWriting {
          if let error = writer.error {
            continuation.resume(throwing: MeetingSystemAudioRecorderError.writerSetupFailed(error.localizedDescription))
            return
          }
          if let firstPresentationTime = state.firstPresentationTime,
             let lastPresentationTime = state.lastPresentationTime {
            continuation.resume(returning: MeetingSystemAudioRecordingResult(
              duration: max(0, CMTimeGetSeconds(lastPresentationTime - firstPresentationTime)),
              capturedSampleCount: state.sampleCount,
              captureErrorDescription: state.captureErrorDescription
            ))
          } else {
            continuation.resume(returning: MeetingSystemAudioRecordingResult(
              duration: nil,
              capturedSampleCount: state.sampleCount,
              captureErrorDescription: state.captureErrorDescription
            ))
          }
        }
      }
    }
  }

  private func resetState(cancelWriter: Bool) {
    let resources = stateLock.withLock {
      let writer = self.writer
      let stream = self.stream
      self.stream = nil
      self.writer = nil
      writerInput = nil
      firstPresentationTime = nil
      lastPresentationTime = nil
      lastMeterSnapshotTime = nil
      sampleCount = 0
      latestSnapshot = .silent
      captureState.reset()
      return (stream: stream, writer: writer)
    }

    if let stream = resources.stream {
      detachAudioOutput(from: stream)
    }
    if cancelWriter {
      resources.writer?.cancelWriting()
    }
  }

  private static func meterSnapshot(from sampleBuffer: CMSampleBuffer) -> MeetingInputMeterSnapshot? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    else {
      return nil
    }

    var audioBufferListSize = 0
    var blockBuffer: CMBlockBuffer?
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &audioBufferListSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr || audioBufferListSize > 0 else { return nil }

    let rawAudioBufferList = UnsafeMutableRawPointer.allocate(
      byteCount: audioBufferListSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawAudioBufferList.deallocate() }

    let audioBufferList = rawAudioBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &audioBufferListSize,
      bufferListOut: audioBufferList,
      bufferListSize: audioBufferListSize,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }

    return meterSnapshot(from: UnsafeMutableAudioBufferListPointer(audioBufferList), format: streamDescription.pointee)
  }

  private static func meterSnapshot(
    from audioBuffers: UnsafeMutableAudioBufferListPointer,
    format: AudioStreamBasicDescription
  ) -> MeetingInputMeterSnapshot? {
    let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
    let formatFlags = format.mFormatFlags
    let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0

    var sumSquares = 0.0
    var peak = 0.0
    var sampleCount = 0

    for audioBuffer in audioBuffers {
      guard let data = audioBuffer.mData else { continue }
      let byteCount = Int(audioBuffer.mDataByteSize)
      if isFloat && bytesPerSample == MemoryLayout<Float>.size {
        let values = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
        for index in 0..<(byteCount / MemoryLayout<Float>.size) {
          let value = min(1, max(-1, Double(values[index])))
          let magnitude = abs(value)
          sumSquares += value * value
          peak = max(peak, magnitude)
          sampleCount += 1
        }
      } else if isSignedInteger && bytesPerSample == MemoryLayout<Int16>.size {
        let values = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
        for index in 0..<(byteCount / MemoryLayout<Int16>.size) {
          let value = Double(values[index]) / Double(Int16.max)
          let magnitude = abs(value)
          sumSquares += value * value
          peak = max(peak, magnitude)
          sampleCount += 1
        }
      } else if isSignedInteger && bytesPerSample == MemoryLayout<Int32>.size {
        let values = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.size)
        for index in 0..<(byteCount / MemoryLayout<Int32>.size) {
          let value = Double(values[index]) / Double(Int32.max)
          let magnitude = abs(value)
          sumSquares += value * value
          peak = max(peak, magnitude)
          sampleCount += 1
        }
      }
    }

    guard sampleCount > 0 else { return nil }
    let rms = sqrt(sumSquares / Double(sampleCount))
    let averageDecibels = Float(20 * log10(max(rms, 0.000_001)))
    let peakDecibels = Float(20 * log10(max(peak, 0.000_001)))
    return MeetingInputMeterSnapshot(
      averageLevel: MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: averageDecibels),
      peakLevel: MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: peakDecibels),
      averagePowerDecibels: averageDecibels,
      peakPowerDecibels: peakDecibels
    )
  }
}

@MainActor
public final class MeetingAudioRecorder {
  private var recorder: AVAudioRecorder?
  private var startedAt: Date?

  public init() {}

  public func startRecording(to audioURL: URL) async throws {
    guard recorder == nil else { throw MeetingRecorderError.alreadyRecording }
    try await requestMicrophonePermission()
    try FileManager.default.createDirectory(
      at: audioURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]
    let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    guard recorder.record() else {
      throw MeetingRecorderError.startFailed
    }
    self.recorder = recorder
    self.startedAt = Date()
  }

  public var inputMeterSnapshot: MeetingInputMeterSnapshot {
    guard let recorder else { return .silent }
    recorder.updateMeters()
    let averagePower = recorder.averagePower(forChannel: 0)
    let peakPower = recorder.peakPower(forChannel: 0)
    return MeetingInputMeterSnapshot(
      averageLevel: Self.normalizedMeterLevel(fromDecibels: averagePower),
      peakLevel: Self.normalizedMeterLevel(fromDecibels: peakPower),
      averagePowerDecibels: averagePower,
      peakPowerDecibels: peakPower
    )
  }

  nonisolated public static func normalizedMeterLevel(fromDecibels decibels: Float) -> Double {
    guard decibels.isFinite else { return 0 }
    let floor: Double = -60
    let ceiling: Double = 0
    let clamped = min(ceiling, max(floor, Double(decibels)))
    return (clamped - floor) / (ceiling - floor)
  }

  public func stopRecording() throws -> TimeInterval {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    let duration = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    self.startedAt = nil
    return duration
  }

  public func pauseRecording() throws {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    recorder.pause()
  }

  public func resumeRecording() throws {
    guard let recorder else { throw MeetingRecorderError.notRecording }
    guard recorder.record() else {
      throw MeetingRecorderError.startFailed
    }
  }

  private func requestMicrophonePermission() async throws {
    switch Self.microphoneAuthorizationStatus() {
    case .authorized:
      return
    case .notDetermined:
      let granted = await Self.requestMicrophoneAccess()
      if granted { return }
      throw MeetingRecorderError.microphoneDenied
    case .denied, .restricted:
      throw MeetingRecorderError.microphoneDenied
    @unknown default:
      throw MeetingRecorderError.microphoneDenied
    }
  }

  nonisolated private static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  nonisolated private static func requestMicrophoneAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}

public enum LocalWhisperError: LocalizedError, Equatable {
  case notConfigured
  case commandFailed(String, Int, String)
  case emptyTranscript(String)
  case audioConversionFailed(String, String)

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      "No local Whisper transcriber found. Install whisper.cpp (`whisper-cli`) with a local ggml model, install the OpenAI Whisper CLI (`whisper`), or set ORG2_WORKSPACE_WHISPER_COMMAND."
    case .commandFailed(let command, let status, let stderr):
      "\(command) exited with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")"
    case .emptyTranscript(let stderr):
      stderr.isEmpty ? "Local Whisper did not return a transcript." : "Local Whisper did not return a transcript: \(stderr)"
    case .audioConversionFailed(let file, let message):
      "Could not convert \(file) to WAV for whisper.cpp\(message.isEmpty ? "" : ": \(message)")"
    }
  }
}

public enum MeetingRecorderError: LocalizedError, Equatable {
  case alreadyRecording
  case notRecording
  case microphoneDenied
  case startFailed

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "A meeting recording is already active."
    case .notRecording:
      "No meeting recording is active."
    case .microphoneDenied:
      "Microphone access is required to record meetings."
    case .startFailed:
      "Could not start the meeting recorder."
    }
  }
}

public enum MeetingSystemAudioRecorderError: LocalizedError, Equatable {
  case alreadyRecording
  case notRecording
  case noDisplayAvailable
  case writerSetupFailed(String)
  case startFailed(String)
  case stopFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      "System audio recording is already active."
    case .notRecording:
      "No system audio recording is active."
    case .noDisplayAvailable:
      "No display is available for system audio capture."
    case .writerSetupFailed(let message):
      "Could not prepare the system audio recorder: \(message)"
    case .startFailed(let message):
      "Could not start system audio capture: \(message)"
    case .stopFailed(let message):
      "Could not stop system audio capture: \(message)"
    }
  }
}

private struct ProcessTextResult {
  let stdout: String
  let stderr: String
}

private final class TextPipeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func set(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
  }

  var data: Data {
    lock.lock()
    let data = storage
    lock.unlock()
    return data
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
