import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func transientDraftBlock(
    from spec: SplitDraftSpec,
    sourceFile: String,
    originalBlock: OrgEditableBlock
  ) -> TransientDraftBlock {
    let insertionLine = originalBlock.startLine + spec.insertionLineOffset
    let displayLine = originalBlock.startLine + spec.displayLineOffset
    return TransientDraftBlock(
      file: sourceFile,
      insertionLine: insertionLine,
      replacementEndLineExclusive: insertionLine,
      replacementPrefix: spec.replacementPrefix,
      replacementSuffix: spec.replacementSuffix,
      selectionLineOffset: spec.selectionLineOffset,
      block: transientDraftEditableBlock(
        startLine: displayLine,
        endLineExclusive: displayLine,
        rawText: spec.rawText,
        rendered: spec.rendered
      ),
      coveredBlocks: []
    )
  }

  nonisolated static func normalizedTransientDraftText(
    _ raw: String,
    for block: OrgEditableBlock
  ) -> String? {
    let normalized = normalizeLineEndings(raw)
    switch block.rendered {
    case .paragraph:
      let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    case .heading:
      let text = normalized.trimmingCharacters(in: .newlines)
      guard headingDraftHasTitle(text) else { return nil }
      return text
    case .listItem:
      let text = normalized.trimmingCharacters(in: .newlines)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      guard let regex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-+]|[0-9]+[.)])\s+(?:\[(?: |X|x|-)\]\s*)?"#
      ) else {
        return text
      }
      let nsText = text as NSString
      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
      if let match,
         match.range.location == 0,
         match.range.length == nsText.length {
        return nil
      }
      return text
    default:
      let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
  }

  nonisolated private static func headingDraftHasTitle(_ raw: String) -> Bool {
    let line = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else {
      return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var rest = String(line.dropFirst(stars.count)).trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    return !tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  nonisolated static func sortEditableBlocksForDisplay(_ blocks: [OrgEditableBlock]) -> [OrgEditableBlock] {
    blocks.sorted { lhs, rhs in
      if lhs.startLine != rhs.startLine {
        return lhs.startLine < rhs.startLine
      }
      if lhs.endLineExclusive != rhs.endLineExclusive {
        return lhs.endLineExclusive < rhs.endLineExclusive
      }
      return lhs.id < rhs.id
    }
  }

  nonisolated static func replacingBlock(
    _ original: OrgEditableBlock?,
    with replacement: OrgEditableBlock?,
    in blocks: [OrgEditableBlock]
  ) -> [OrgEditableBlock] {
    guard let original, let replacement else { return blocks }
    return blocks.map { block in
      block.id == original.id ? replacement : block
    }
  }

  nonisolated static func locallyUpdatingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    replacing original: OrgEditableBlock,
    with replacement: String
  ) -> [OrgEditableBlock] {
    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementBlocks = OrgEntryRenderer.parseEditable(
      normalizedReplacement,
      baseLine: original.startLine
    )
    let oldLineCount = original.endLineExclusive - original.startLine
    let newLineCount = normalizedReplacement.isEmpty ? 0 : lineCount(in: normalizedReplacement)
    let lineDelta = newLineCount - oldLineCount

    if lineDelta == 0,
       replacementBlocks.count == 1,
       let originalIndex = blocks.firstIndex(where: { $0.id == original.id }) {
      var updated = blocks
      updated[originalIndex] = replacementBlocks[0]
      return updated
    }

    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count + max(0, replacementBlocks.count - 1))
    var insertedReplacement = false

    for block in blocks {
      if block.id == original.id {
        updated.append(contentsOf: replacementBlocks)
        insertedReplacement = true
        continue
      }

      if block.startLine >= original.endLineExclusive {
        updated.append(shiftedBlock(block, by: lineDelta))
      } else if block.endLineExclusive <= original.startLine {
        updated.append(block)
      } else {
        continue
      }
    }

    if !insertedReplacement {
      updated.append(contentsOf: replacementBlocks)
    }

    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated static func locallyInsertingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    atLine insertionLine: Int,
    replacement: String
  ) -> [OrgEditableBlock] {
    let normalizedReplacement = normalizeLineEndings(replacement)
    let insertedBlocks = OrgEntryRenderer.parseEditable(
      normalizedReplacement,
      baseLine: insertionLine
    )
    let lineDelta = normalizedReplacement.isEmpty ? 0 : lineCount(in: normalizedReplacement)

    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count + insertedBlocks.count)
    for block in blocks {
      if block.startLine >= insertionLine {
        updated.append(shiftedBlock(block, by: lineDelta))
      } else {
        updated.append(block)
      }
    }
    updated.append(contentsOf: insertedBlocks)
    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated static func locallyMovingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) -> [OrgEditableBlock] {
    let firstLineCount = firstEndLineExclusive - firstStartLine
    let secondLineCount = secondEndLineExclusive - secondStartLine
    let betweenLineCount = secondStartLine - firstEndLineExclusive
    let firstShift = secondLineCount + betweenLineCount
    let betweenShift = secondLineCount
    let secondShift = -(firstLineCount + betweenLineCount)

    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count)

    for block in blocks {
      if block.endLineExclusive <= firstStartLine || block.startLine >= secondEndLineExclusive {
        updated.append(block)
      } else if block.startLine >= firstStartLine && block.endLineExclusive <= firstEndLineExclusive {
        updated.append(shiftedBlock(block, by: firstShift))
      } else if block.startLine >= firstEndLineExclusive && block.endLineExclusive <= secondStartLine {
        updated.append(shiftedBlock(block, by: betweenShift))
      } else if block.startLine >= secondStartLine && block.endLineExclusive <= secondEndLineExclusive {
        updated.append(shiftedBlock(block, by: secondShift))
      }
    }

    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated static func locallyDeletingRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    startLine: Int,
    endLineExclusive: Int
  ) -> [OrgEditableBlock] {
    let lineDelta = startLine - endLineExclusive
    var updated: [OrgEditableBlock] = []
    updated.reserveCapacity(blocks.count)

    for block in blocks {
      if block.endLineExclusive <= startLine {
        updated.append(block)
      } else if block.startLine >= endLineExclusive {
        updated.append(shiftedBlock(block, by: lineDelta))
      }
    }

    return sortEditableBlocksForDisplay(updated)
  }

  nonisolated static func shiftedBlock(_ block: OrgEditableBlock, by lineDelta: Int) -> OrgEditableBlock {
    guard lineDelta != 0 else { return block }
    return OrgEditableBlock(
      id: "\(block.startLine + lineDelta):\(block.endLineExclusive + lineDelta):\(renderedBlockKindName(block.rendered))",
      startLine: block.startLine + lineDelta,
      endLineExclusive: block.endLineExclusive + lineDelta,
      rawText: block.rawText,
      rendered: block.rendered
    )
  }

  nonisolated private static func renderedBlockKindName(_ block: OrgRenderedBlock) -> String {
    switch block {
    case .heading: "heading"
    case .planning: "planning"
    case .properties: "properties"
    case .quote: "quote"
    case .source: "source"
    case .table: "table"
    case .horizontalRule: "horizontal-rule"
    case .listItem: "list"
    case .paragraph: "paragraph"
    case .keyword: "keyword"
    case .blank: "blank"
    }
  }

  nonisolated static func continuedListPrefix(
    draft: String,
    fallbackMarker: String,
    checkbox: OrgListCheckbox?
  ) -> String {
    let firstLine = draft.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let leadingWhitespace = String(firstLine.prefix { $0 == " " || $0 == "\t" })
    let withoutLeading = firstLine.dropFirst(leadingWhitespace.count)
    let marker = String(withoutLeading.prefix { !$0.isWhitespace })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let markerText = marker.isEmpty ? fallbackMarker : String(marker)
    let checkboxText = checkbox == nil ? "" : "[ ] "
    return "\(leadingWhitespace)\(markerText) \(checkboxText)"
  }

  nonisolated static func isMergeablePreviousTextBlock(_ block: OrgEditableBlock) -> Bool {
    switch block.rendered {
    case .heading, .paragraph, .listItem:
      return true
    default:
      return false
    }
  }

  nonisolated static func mergedTextBlockRawText(
    previous: OrgEditableBlock,
    current: OrgEditableBlock,
    currentDraft: String
  ) -> String? {
    guard isMergeablePreviousTextBlock(previous),
          let tail = mergeTailText(for: current, draft: currentDraft)
    else {
      return nil
    }

    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    if case .heading = previous.rendered {
      return headingRawTextAppending(previous.rawText, tail: trimmedTail)
    }

    let head = normalizeLineEndings(previous.rawText).trimmingCharacters(in: .whitespacesAndNewlines)
    if head.isEmpty { return trimmedTail }
    if trimmedTail.isEmpty { return head }
    return "\(head) \(trimmedTail)"
  }

  nonisolated private static func mergeTailText(for block: OrgEditableBlock, draft: String) -> String? {
    let normalizedDraft = normalizeLineEndings(draft)
    switch block.rendered {
    case .heading:
      let firstLine = normalizedDraft.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? normalizedDraft
      let title = headingTitle(from: firstLine)
      return title.isEmpty ? normalizedDraft : title
    case .paragraph:
      return normalizedDraft
    case .listItem:
      return listItemBodyText(from: normalizedDraft)
    default:
      return nil
    }
  }

  nonisolated private static func listItemBodyText(from rawText: String) -> String {
    let firstLine = rawText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawText
    guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:[-+*]|\d+[.)])\s+(?:\[[ Xx-]\]\s+)?"#) else {
      return rawText
    }
    let nsFirstLine = firstLine as NSString
    let fullRange = NSRange(location: 0, length: nsFirstLine.length)
    guard let match = regex.firstMatch(in: firstLine, range: fullRange),
          match.range.location == 0
    else {
      return rawText
    }
    let prefixLength = match.range.length
    let nsRawText = rawText as NSString
    guard prefixLength <= nsRawText.length else { return "" }
    return nsRawText.substring(from: prefixLength)
  }

  nonisolated private static func headingRawTextAppending(_ rawText: String, tail: String) -> String? {
    let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTail.isEmpty else {
      return normalizeLineEndings(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first,
          let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#)
    else {
      return nil
    }

    let nsFirst = first as NSString
    let fullRange = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: fullRange),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    var body = nsFirst.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespaces)
    var tagsSuffix = ""
    if let tagRange = body.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tagsSuffix = String(body[tagRange]).trimmingCharacters(in: .whitespaces)
      body.removeSubrange(tagRange)
      body = body.trimmingCharacters(in: .whitespaces)
    }

    let mergedBody = body.isEmpty ? trimmedTail : "\(body) \(trimmedTail)"
    lines[0] = "\(prefix)\(mergedBody)\(tagsSuffix.isEmpty ? "" : " \(tagsSuffix)")"
    return lines.joined(separator: "\n")
  }

  nonisolated static func splitText(_ text: String, atUTF16Offset offset: Int) -> (before: String, after: String) {
    let ns = text as NSString
    let clampedOffset = max(0, min(offset, ns.length))
    return (
      ns.substring(to: clampedOffset),
      ns.substring(from: clampedOffset)
    )
  }

  nonisolated static func toggledListItemCheckboxRawText(
    _ rawText: String,
    current: OrgListCheckbox
  ) -> String? {
    listItemCheckboxRawText(rawText, state: current.toggled)
  }

  nonisolated static func listItemCheckboxRawText(
    _ rawText: String,
    state: OrgListCheckbox
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\s*(?:[-+]|[0-9]+[.)])\s+)\[( |X|x|-)\](\s+)"#) else {
      return nil
    }

    let range = NSRange(location: 0, length: (first as NSString).length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = (first as NSString).substring(with: match.range(at: 1))
    let suffix = (first as NSString).substring(with: match.range(at: 3))
    let restLocation = match.range.location + match.range.length
    let restLength = max(0, (first as NSString).length - restLocation)
    let rest = (first as NSString).substring(with: NSRange(location: restLocation, length: restLength))
    lines[0] = "\(prefix)\(state.rawMarker)\(suffix)\(rest)"
    return lines.joined(separator: "\n")
  }

  nonisolated private static func toggledHeadingTodoRawText(
    _ rawText: String,
    current: String,
    next: String
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(\S+)(.*)$"#) else {
      return nil
    }

    let nsFirst = first as NSString
    let range = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let keyword = nsFirst.substring(with: match.range(at: 2)).uppercased()
    guard keyword == current.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    let suffix = nsFirst.substring(with: match.range(at: 3))
    lines[0] = "\(prefix)\(next)\(suffix)"
    return lines.joined(separator: "\n")
  }

  nonisolated static func headingRawTextSettingPriority(
    _ rawText: String,
    priority: String?
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#) else {
      return nil
    }

    let nsFirst = first as NSString
    let range = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    let rest = nsFirst.substring(with: match.range(at: 2))
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var outputTokens: [String] = []

    if let firstToken = tokens.first,
       allHeadingTodoKeywords.contains(firstToken.uppercased()) {
      outputTokens.append(firstToken.uppercased())
      tokens.removeFirst()
    }

    if let firstToken = tokens.first,
       firstToken.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }

    if let priority = normalizedHeadingPriority(priority) {
      outputTokens.append("[#\(priority)]")
    }
    outputTokens.append(contentsOf: tokens)

    lines[0] = "\(prefix)\(outputTokens.joined(separator: " "))"
    return lines.joined(separator: "\n")
  }

  nonisolated private static func normalizedHeadingPriority(_ priority: String?) -> String? {
    guard var priority = priority?.trimmingCharacters(in: .whitespacesAndNewlines),
          !priority.isEmpty
    else {
      return nil
    }
    priority = priority
      .replacingOccurrences(of: "[#", with: "")
      .replacingOccurrences(of: "]", with: "")
      .uppercased()
    guard priority.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil else {
      return nil
    }
    return priority
  }

  nonisolated static func headingRawTextSettingTags(
    _ rawText: String,
    tags: [String]
  ) -> String? {
    var lines = normalizeLineEndings(rawText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let first = lines.first else { return nil }
    guard let regex = try? NSRegularExpression(pattern: #"^(\*+\s+)(.*)$"#) else {
      return nil
    }

    let nsFirst = first as NSString
    let range = NSRange(location: 0, length: nsFirst.length)
    guard let match = regex.firstMatch(in: first, range: range),
          match.range.location == 0
    else {
      return nil
    }

    let prefix = nsFirst.substring(with: match.range(at: 1))
    var rest = nsFirst.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespaces)
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    let normalizedTags = normalizedHeadingTags(tags)
    let tagSuffix = normalizedTags.isEmpty ? "" : " :\(normalizedTags.joined(separator: ":")):"
    lines[0] = "\(prefix)\(rest)\(tagSuffix)"
    return lines.joined(separator: "\n")
  }

  func syncMeetingSelectionAfterRefresh() {
    guard selectedSurface == .meetings, !meetings.isEmpty else { return }
    if let selectedMeetingID,
       let meeting = meetings.first(where: { $0.id == selectedMeetingID }) {
      select(.meeting(meeting))
      return
    }
    selectMeeting(meetings[0])
  }

  func startMeetingInputMetering() {
    meetingMeterTask?.cancel()
    updateMeetingInputMeter(force: true)
    meetingMeterTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isRecordingMeeting else { return false }
          self.updateMeetingInputMeter()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: Self.meetingMeterPublishIntervalNanoseconds)
      }
    }
  }

  func stopMeetingInputMetering() {
    meetingMeterTask?.cancel()
    meetingMeterTask = nil
    meetingInputMeterState.reset()
  }

  private func updateMeetingInputMeter(force: Bool = false) {
    let snapshot = meetingRecorder.inputMeterSnapshot
    let systemSnapshot = meetingSystemAudioRecorder.inputMeterSnapshot
    if meetingSystemAudioRecorder.needsRecovery,
       let captureError = meetingSystemAudioRecorder.captureErrorDescription {
      isCapturingSystemAudio = false
      scheduleMeetingSystemAudioRecovery(after: captureError)
    }
    publishMeetingMeterLevels(microphone: snapshot, systemAudio: systemSnapshot, force: force)
  }

  func startMeetingSystemAudioRecordingWithRetry(to audioURL: URL) async throws {
    do {
      try await meetingSystemAudioRecorder.startRecording(to: audioURL)
    } catch {
      let initialFailure = error.localizedDescription
      guard Self.shouldRetryMeetingSystemAudioStart(after: initialFailure) else {
        throw error
      }
      await meetingSystemAudioRecorder.discardRecording()
      try? await Task.sleep(nanoseconds: 300_000_000)
      do {
        try await meetingSystemAudioRecorder.startRecording(to: audioURL)
      } catch {
        throw MeetingSystemAudioRecorderError.startFailed(
          "\(error.localizedDescription) Retried after: \(initialFailure)"
        )
      }
    }
  }

  nonisolated static func shouldRetryMeetingSystemAudioStart(after description: String) -> Bool {
    let normalized = description.lowercased()
    let terminalFragments = [
      "declined tcc",
      "permission",
      "not authorized",
      "not permitted",
      "no display is available"
    ]
    return !terminalFragments.contains(where: normalized.contains)
  }

  private func scheduleMeetingSystemAudioRecovery(after captureError: String) {
    guard meetingSystemAudioRecoveryTask == nil,
          !meetingSystemAudioRecoverySuppressed,
          isRecordingMeeting,
          !isMeetingRecordingPaused,
          let recordingPath = activeMeetingRecording?.paths.systemAudioURL.path
    else {
      return
    }

    meetingSystemAudioStatusText = "System audio interrupted; reconnecting..."
    meetingSystemAudioRecoveryTask = Task { [weak self] in
      guard let self else { return }
      var lastFailure = captureError

      for delay in Self.meetingSystemAudioRecoveryDelaysNanoseconds {
        if delay > 0 {
          do {
            try await Task.sleep(nanoseconds: delay)
          } catch {
            self.meetingSystemAudioRecoveryTask = nil
            return
          }
        }
        guard !Task.isCancelled,
              self.isRecordingMeeting,
              !self.isMeetingRecordingPaused,
              self.activeMeetingRecording?.paths.systemAudioURL.path == recordingPath
        else {
          self.meetingSystemAudioRecoveryTask = nil
          return
        }

        do {
          if try await self.meetingSystemAudioRecorder.recoverRecording() {
            self.isCapturingSystemAudio = true
            self.meetingSystemAudioStatusText = "System audio recording (recovered)"
            self.meetingSystemAudioRecoveryTask = nil
            return
          }
        } catch {
          lastFailure = error.localizedDescription
        }
      }

      self.meetingSystemAudioRecoverySuppressed = true
      self.meetingSystemAudioStatusText = "System audio stopped: \(lastFailure)"
      self.meetingSystemAudioRecoveryTask = nil
    }
  }

  func cancelMeetingSystemAudioRecovery() {
    meetingSystemAudioRecoveryTask?.cancel()
    meetingSystemAudioRecoveryTask = nil
  }

  nonisolated static func fileHasContent(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber
    else {
      return false
    }
    return size.int64Value > 0
  }

  private func publishMeetingMeterLevels(
    microphone: MeetingInputMeterSnapshot,
    systemAudio: MeetingInputMeterSnapshot,
    force: Bool
  ) {
    meetingInputMeterState.publish(
      primary: microphone,
      secondary: systemAudio,
      force: force
    )
  }

  nonisolated static func shouldPublishMeetingMeterLevelChange(current: Double, next: Double) -> Bool {
    if current == next { return false }
    if current == 0 || next == 0 { return true }
    if current >= 0.95 || next >= 0.95 { return true }
    return abs(current - next) >= meetingMeterPublishThreshold
  }

  func startAIChatVoiceMetering() {
    aiChatVoiceMeterTask?.cancel()
    updateAIChatVoiceMeter()
    aiChatVoiceMeterTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isRecordingAIChatVoiceNote else { return false }
          self.updateAIChatVoiceMeter()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  func stopAIChatVoiceMetering() {
    aiChatVoiceMeterTask?.cancel()
    aiChatVoiceMeterTask = nil
    aiChatVoiceMeterState.reset()
  }

  private func updateAIChatVoiceMeter() {
    let snapshot = aiChatVoiceRecorder.inputMeterSnapshot
    aiChatVoiceMeterState.publish(primary: snapshot)
  }

  func startMeetingTranscriptionProgress(title: String, audioDuration: TimeInterval?) -> UUID {
    meetingTranscriptionProgressTask?.cancel()
    let id = UUID()
    meetingTranscriptionProgressID = id
    meetingTranscriptionProgressTitle = title
    meetingTranscriptionStartedAt = Date()
    meetingTranscriptionEstimatedDuration = Self.estimatedMeetingTranscriptionDuration(for: audioDuration)
    updateMeetingTranscriptionProgress()
    meetingTranscriptionProgressTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self,
                self.isProcessingMeeting,
                self.meetingTranscriptionProgressID == id
          else { return false }
          self.updateMeetingTranscriptionProgress()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(
          nanoseconds: Self.meetingTranscriptionProgressPublishIntervalNanoseconds
        )
      }
    }
    return id
  }

  func stopMeetingTranscriptionProgress(id: UUID?) {
    if let id, meetingTranscriptionProgressID != id {
      return
    }
    meetingTranscriptionProgressTask?.cancel()
    meetingTranscriptionProgressTask = nil
    meetingTranscriptionProgressID = nil
    meetingTranscriptionProgressTitle = ""
    meetingTranscriptionStartedAt = nil
    meetingTranscriptionEstimatedDuration = 120
    meetingTranscriptionProgressState.reset()
  }

  private func updateMeetingTranscriptionProgress() {
    let elapsed = meetingTranscriptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let progress = Self.meetingTranscriptionProgress(
      elapsed: elapsed,
      estimatedDuration: meetingTranscriptionEstimatedDuration
    )
    meetingTranscriptionProgressState.publish(
      progress: progress,
      elapsedText: Self.aiChatVoiceTranscriptionElapsedText(elapsed: elapsed)
    )
    // The dedicated progress view observes the isolated state above. Keep the
    // workspace-wide status static while transcription runs so a changing
    // percentage does not invalidate every surface in the app.
  }

  nonisolated static func estimatedMeetingTranscriptionDuration(for audioDuration: TimeInterval?) -> TimeInterval {
    guard let audioDuration, audioDuration > 0 else { return 120 }
    return min(3_600, max(30, audioDuration * 2))
  }

  nonisolated static func meetingTranscriptionProgress(
    elapsed: TimeInterval,
    estimatedDuration: TimeInterval
  ) -> Double {
    guard estimatedDuration > 0 else { return 0 }
    return min(0.95, max(0.02, elapsed / estimatedDuration))
  }

  func startAIChatVoiceTranscriptionProgress(audioDuration: TimeInterval) {
    aiChatVoiceTranscriptionProgressTask?.cancel()
    aiChatVoiceTranscriptionStartedAt = Date()
    aiChatVoiceTranscriptionEstimatedDuration = Self.estimatedAIChatVoiceTranscriptionDuration(for: audioDuration)
    updateAIChatVoiceTranscriptionProgress()
    aiChatVoiceTranscriptionProgressTask = Task { [weak self] in
      while !Task.isCancelled {
        let shouldContinue = await MainActor.run { () -> Bool in
          guard let self, self.isTranscribingAIChatVoiceNote else { return false }
          self.updateAIChatVoiceTranscriptionProgress()
          return true
        }
        guard shouldContinue else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }

  func stopAIChatVoiceTranscriptionProgress() {
    aiChatVoiceTranscriptionProgressTask?.cancel()
    aiChatVoiceTranscriptionProgressTask = nil
    aiChatVoiceTranscriptionStartedAt = nil
    aiChatVoiceTranscriptionEstimatedDuration = 8
    aiChatVoiceTranscriptionProgress = 0
    aiChatVoiceTranscriptionElapsedText = ""
  }

  private func updateAIChatVoiceTranscriptionProgress() {
    let elapsed = aiChatVoiceTranscriptionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    let progress = Self.aiChatVoiceTranscriptionProgress(
      elapsed: elapsed,
      estimatedDuration: aiChatVoiceTranscriptionEstimatedDuration
    )
    aiChatVoiceTranscriptionProgress = progress
    aiChatVoiceTranscriptionElapsedText = Self.aiChatVoiceTranscriptionElapsedText(elapsed: elapsed)
    let target = activeAIChatDictationOrigin?.threadTitle ?? "the original AI chat"
    aiChatVoiceStatusText =
      "Transcribing dictation for \(target) locally... \(Int(progress * 100))%"
    aiChatStatusText = aiChatVoiceStatusText
  }

  nonisolated static func estimatedAIChatVoiceTranscriptionDuration(for audioDuration: TimeInterval) -> TimeInterval {
    min(180, max(8, audioDuration * 4))
  }

  nonisolated static func aiChatVoiceTranscriptionProgress(
    elapsed: TimeInterval,
    estimatedDuration: TimeInterval
  ) -> Double {
    guard estimatedDuration > 0 else { return 0 }
    return min(0.95, max(0.02, elapsed / estimatedDuration))
  }

  nonisolated static func aiChatVoiceTranscriptionElapsedText(elapsed: TimeInterval) -> String {
    let seconds = max(0, Int(elapsed.rounded(.down)))
    if seconds < 60 {
      return "\(seconds)s"
    }
    return "\(seconds / 60)m \(seconds % 60)s"
  }

  func transcribeRecordedMeetingAudio(
    microphoneAudioURL: URL,
    systemAudioURL: URL?,
    systemAudioCaptureError: String?
  ) async -> MeetingTranscriptResult {
    let configuration = meetingTranscriptionConfiguration()
    guard let systemAudioURL else {
      let microphone = await transcribeAudioForMeeting(
        microphoneAudioURL,
        configuration: configuration
      )
      return MeetingTranscriptResult.combined(
        microphone: microphone,
        systemAudio: nil,
        systemAudioCaptureError: systemAudioCaptureError
      )
    }

    let serializesSources: Bool
    if configuration.provider == .automatic {
      let localConfiguration = localWhisperConfiguration(includeCustomCommand: false)
      let whisperStatus = await Task.detached(priority: .utility) {
        LocalWhisperTranscriber.installationStatus(configuration: localConfiguration)
      }.value
      serializesSources = whisperStatus.isWhisperCppReady
        || whisperStatus.openAIWhisperExecutablePath != nil
        || whisperStatus.overrideCommand != nil
    } else {
      serializesSources = configuration.provider.serializesMeetingSources
    }

    let microphone: MeetingTranscriptResult
    let systemAudio: MeetingTranscriptResult
    if serializesSources {
      // Two Whisper processes can each create their own CPU thread pool. Keep
      // those providers on one background lane so the app stays responsive.
      microphone = await transcribeAudioForMeeting(
        microphoneAudioURL,
        configuration: configuration
      )
      systemAudio = await transcribeAudioForMeeting(
        systemAudioURL,
        configuration: configuration
      )
    } else {
      async let microphoneResult = transcribeAudioForMeeting(
        microphoneAudioURL,
        configuration: configuration
      )
      async let systemAudioResult = transcribeAudioForMeeting(
        systemAudioURL,
        configuration: configuration
      )
      (microphone, systemAudio) = await (microphoneResult, systemAudioResult)
    }
    return MeetingTranscriptResult.combined(
      microphone: microphone,
      systemAudio: systemAudio,
      systemAudioCaptureError: systemAudioCaptureError
    )
  }

  func transcribeAudioForMeeting(
    _ audioURL: URL,
    configuration: MeetingTranscriptionConfiguration? = nil
  ) async -> MeetingTranscriptResult {
    if let meetingTranscriptionForTesting {
      return await meetingTranscriptionForTesting(audioURL)
    }
    let configuration = configuration ?? meetingTranscriptionConfiguration()
    switch configuration.provider {
    case .automatic:
      let whisperConfiguration = LocalWhisperConfiguration(
        modelOverride: configuration.whisperModelPath,
        commandOverride: nil,
        languageOverride: configuration.language
      )
      let whisperFailure: Error
      do {
        return try await LocalWhisperTranscriber(configuration: whisperConfiguration)
          .transcribe(audioURL: audioURL)
      } catch {
        whisperFailure = error
      }
      do {
        let transcript = try await NativeSpeechTranscriber().transcribe(audioURL: audioURL)
        return MeetingTranscriptResult(
          text: transcript.text,
          status: transcript.status,
          engine: "macOS Speech (automatic fallback)",
          errorMessage: "Local Whisper failed: \(whisperFailure.localizedDescription)"
        )
      } catch {
        let messages = [
          "Local Whisper: \(whisperFailure.localizedDescription)",
          "macOS Speech: \(error.localizedDescription)"
        ].joined(separator: "; ")
        return failedTranscriptionResult(engine: "Automatic", error: messages)
      }
    case .localWhisper:
      let whisperConfiguration = LocalWhisperConfiguration(
        modelOverride: configuration.whisperModelPath,
        languageOverride: configuration.language
      )
      do {
        return try await LocalWhisperTranscriber(configuration: whisperConfiguration)
          .transcribe(audioURL: audioURL)
      } catch {
        return failedTranscriptionResult(engine: "Local Whisper", error: error.localizedDescription)
      }
    case .fluidVoice:
      do {
        return try await FluidVoiceTranscriber(endpoint: configuration.fluidVoiceEndpoint)
          .transcribe(audioURL: audioURL)
      } catch {
        return failedTranscriptionResult(engine: "Fluid Voice", error: error.localizedDescription)
      }
    case .macOSSpeech:
      do {
        return try await NativeSpeechTranscriber().transcribe(audioURL: audioURL)
      } catch {
        return MeetingTranscriptResult(
          text: "",
          status: error is NativeSpeechTranscriberError ? .unavailable : .failed,
          engine: "macOS Speech",
          errorMessage: error.localizedDescription
        )
      }
    case .customCommand:
      guard !configuration.customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return failedTranscriptionResult(
          engine: "Custom Command",
          error: "No custom transcription command is configured."
        )
      }
      do {
        let whisperConfiguration = LocalWhisperConfiguration(
          modelOverride: configuration.whisperModelPath,
          commandOverride: configuration.customCommand,
          languageOverride: configuration.language
        )
        return try await LocalWhisperTranscriber(configuration: whisperConfiguration)
          .transcribe(audioURL: audioURL)
      } catch {
        return failedTranscriptionResult(engine: "Custom Command", error: error.localizedDescription)
      }
    }
  }

  private func failedTranscriptionResult(engine: String, error: String) -> MeetingTranscriptResult {
    MeetingTranscriptResult(
      text: "",
      status: .failed,
      engine: engine,
      errorMessage: error
    )
  }

  func transcribeAudioForAIChatVoiceNote(_ audioURL: URL) async -> MeetingTranscriptResult {
    if let meetingTranscriptionForTesting {
      return await meetingTranscriptionForTesting(audioURL)
    }
    let configuration = meetingTranscriptionConfiguration()
    // Dictation has no second chance: if the chosen provider (for example a
    // Fluid Voice Local API that is not listening) fails, fall back to the
    // on-device chain instead of returning nothing.
    let fallbackConfiguration: MeetingTranscriptionConfiguration? =
      configuration.provider == .automatic
        ? nil
        : MeetingTranscriptionConfiguration(
            provider: .automatic,
            whisperModelPath: configuration.whisperModelPath,
            language: configuration.language
          )
    return await Self.transcribeAIChatDictation(
      primary: { await self.transcribeAudioForMeeting(audioURL, configuration: configuration) },
      fallback: fallbackConfiguration.map { fallbackConfiguration in
        { await self.transcribeAudioForMeeting(audioURL, configuration: fallbackConfiguration) }
      }
    )
  }

  /// Runs the configured dictation transcriber, then the fallback when the
  /// primary produced no usable text.
  static func transcribeAIChatDictation(
    primary: () async -> MeetingTranscriptResult,
    fallback: (() async -> MeetingTranscriptResult)?
  ) async -> MeetingTranscriptResult {
    let first = await primary()
    if first.status == .complete,
       !first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return first
    }
    guard let fallback else { return first }
    let second = await fallback()
    let firstFailure = "\(first.engine): \(first.errorMessage ?? first.status.label)"
    if second.status == .complete,
       !second.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return MeetingTranscriptResult(
        text: second.text,
        status: second.status,
        engine: "\(second.engine) (fallback)",
        errorMessage: firstFailure
      )
    }
    return MeetingTranscriptResult(
      text: "",
      status: .failed,
      engine: first.engine,
      errorMessage: [
        firstFailure,
        "\(second.engine): \(second.errorMessage ?? second.status.label)"
      ].joined(separator: "; ")
    )
  }

  func refreshAfterMeetingWrite(
    completed item: MeetingWorkspaceItem,
    context: AIChatCorpusContextToken
  ) async {
    guard isCurrentAIChatCorpusContext(context) else { return }
    if let existingIndex = meetings.firstIndex(where: { $0.file == item.file }) {
      meetings[existingIndex] = item
    } else {
      meetings.insert(item, at: 0)
    }
    meetingTranscriptionDidComplete(item)
    guard isCurrentAIChatCorpusContext(context) else { return }
    // A finished transcription is a background event. Refresh the meeting if
    // it is already on screen, but never navigate away from what the user is
    // doing; the meeting list and status text announce the new item.
    if case .meeting(let selected) = selectedLocation, selected.file == item.file {
      selectedLocation = .meeting(item)
      selectedMeetingID = item.id
    }
    // The file watcher incrementally updates indexes and marks dependent
    // surfaces dirty. Avoid immediately repeating full meeting, agenda, and
    // chat scans after the artifact writer has already produced the item.
    markWorkspaceSurfacesDirty([.agenda, .files, .search], refreshVisible: false)
  }

  func beginMeetingProcessing(paths: MeetingArtifactPaths, status: String) {
    let processingID = Self.meetingProcessingID(for: paths)
    activeMeetingProcessingIDs.insert(processingID)
    activeMeetingProcessingItems[processingID] = MeetingProcessingItem(
      id: processingID,
      title: paths.title,
      status: status,
      startedAt: Date()
    )
    activeMeetingProcessingCount = activeMeetingProcessingIDs.count
    publishMeetingProcessingItems()
    if !isRecordingMeeting {
      meetingStatusText = status
    }
    statusText = status
  }

  func beginMeetingProcessingForTesting(paths: MeetingArtifactPaths, status: String) {
    beginMeetingProcessing(paths: paths, status: status)
  }

  func endMeetingProcessing(paths: MeetingArtifactPaths) {
    let processingID = Self.meetingProcessingID(for: paths)
    activeMeetingProcessingIDs.remove(processingID)
    activeMeetingProcessingItems.removeValue(forKey: processingID)
    activeMeetingProcessingCount = activeMeetingProcessingIDs.count
    publishMeetingProcessingItems()
  }

  func reconcileMeetingProcessingState(with items: [MeetingWorkspaceItem]) {
    guard isProcessingMeeting else { return }

    let completedIDs = Set(items.compactMap { item -> String? in
      guard item.transcriptionStatus?.lowercased() == MeetingTranscriptionStatus.complete.rawValue else {
        return nil
      }
      return Self.meetingProcessingID(for: item)
    })

    if !activeMeetingProcessingIDs.isEmpty {
      for completedID in completedIDs {
        activeMeetingProcessingIDs.remove(completedID)
        activeMeetingProcessingItems.removeValue(forKey: completedID)
      }
      activeMeetingProcessingCount = activeMeetingProcessingIDs.count
      publishMeetingProcessingItems()
      if activeMeetingProcessingIDs.isEmpty {
        clearMeetingProcessingState()
      }
    } else if let staleTitle = Self.transcribingMeetingTitle(fromStatus: meetingStatusText),
              items.contains(where: { item in
                item.transcriptionStatus?.lowercased() == MeetingTranscriptionStatus.complete.rawValue
                  && Self.normalizedMeetingProcessingTitle(item.title) == Self.normalizedMeetingProcessingTitle(staleTitle)
              }) {
      clearMeetingProcessingState()
    }

    if !isProcessingMeeting,
       !isRecordingMeeting,
       meetingStatusText.lowercased().hasPrefix("transcribing ") {
      if let latest = items.first {
        meetingStatusText = "\(items.count) meeting\(items.count == 1 ? "" : "s"); latest: \(Org2Display.cleanInline(latest.title))"
      } else {
        meetingStatusText = Self.defaultMeetingStatusText()
      }
    }
  }

  nonisolated private static func normalizedMeetingProcessingTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  nonisolated static func meetingProcessingID(for paths: MeetingArtifactPaths) -> String {
    paths.noteURL.standardizedFileURL.path
  }

  nonisolated static func meetingProcessingID(for item: MeetingWorkspaceItem) -> String {
    URL(fileURLWithPath: item.file).standardizedFileURL.path
  }

  nonisolated static func shouldRecoverMeetingRecording(
    _ paths: MeetingArtifactPaths,
    activeRecordingPaths: MeetingArtifactPaths?
  ) -> Bool {
    guard let activeRecordingPaths else { return true }
    return meetingProcessingID(for: paths) != meetingProcessingID(for: activeRecordingPaths)
  }

  func clearMeetingProcessingState() {
    activeMeetingProcessingIDs = []
    activeMeetingProcessingItems = [:]
    activeMeetingProcessingCount = 0
    isProcessingMeeting = false
    processingMeetings = []
    stopMeetingTranscriptionProgress(id: nil)
  }

  private func publishMeetingProcessingItems() {
    processingMeetings = activeMeetingProcessingItems.values.sorted {
      if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  nonisolated private static func transcribingMeetingTitle(fromStatus status: String) -> String? {
    let prefix = "Transcribing "
    let suffix = " locally..."
    guard status.hasPrefix(prefix), status.hasSuffix(suffix) else { return nil }
    let start = status.index(status.startIndex, offsetBy: prefix.count)
    let end = status.index(status.endIndex, offsetBy: -suffix.count)
    let title = String(status[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  func meetingArtifactURLs(for meeting: MeetingWorkspaceItem, corpusRoot: URL) -> [URL] {
    var urls: [URL] = [URL(fileURLWithPath: meeting.file)]
    for artifact in [meeting.audioArtifact, meeting.systemAudioArtifact, meeting.transcriptArtifact].compactMap(\.self) {
      urls.append(url(forMeetingArtifact: artifact, corpusRoot: corpusRoot))
    }
    var seen: Set<String> = []
    return urls.filter { url in
      let key = url.standardizedFileURL.path
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
  }

  func url(forMeetingArtifact artifact: String, corpusRoot: URL) -> URL {
    if artifact.hasPrefix("/") {
      return URL(fileURLWithPath: artifact)
    }
    return corpusRoot.appendingPathComponent(artifact)
  }

  nonisolated private static func normalizedHeadingTags(_ tags: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for tag in tags {
      let normalized = tag
        .trimmingCharacters(in: CharacterSet(charactersIn: "#: \n\t"))
      guard !normalized.isEmpty,
            normalized.range(of: #"^[A-Za-z0-9_@#%.-]+$"#, options: .regularExpression) != nil,
            !seen.contains(normalized)
      else {
        continue
      }
      seen.insert(normalized)
      output.append(normalized)
    }
    return output
  }

  nonisolated static func propertyDrawerRawTextSettingValue(
    _ rawText: String,
    key: String,
    value: String
  ) -> String? {
    let normalizedKey = normalizedPropertyKey(key)
    guard !normalizedKey.isEmpty, normalizedKey != "PROPERTIES", normalizedKey != "END" else {
      return nil
    }

    var drawer = OrgEditablePropertyDrawer(rawText: rawText)
    guard let index = drawer.rows.firstIndex(where: { $0.normalizedKey == normalizedKey }) else {
      return nil
    }
    drawer.setValue(at: index, value: value)
    return drawer.formattedRawText
  }

  nonisolated static func normalizedPropertyKey(_ key: String) -> String {
    key
      .trimmingCharacters(in: CharacterSet(charactersIn: ": \t\r\n"))
      .uppercased()
  }

  nonisolated static func planningRawText(kind: String, value: String) -> String? {
    let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard planningKinds.contains(normalizedKind) else { return nil }
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedValue.isEmpty else { return nil }
    return "\(normalizedKind): \(normalizedValue)"
  }

  nonisolated static let activeHeadingTodoKeywords = Set([
    "TODO",
    "IN_PROGRESS",
    "PROG",
    "WAIT",
    "HOLD",
    "PAUSED"
  ])

  nonisolated static let doneHeadingTodoKeywords = Set([
    "DONE",
    "CANCELED",
    "CANCELLED"
  ])

  nonisolated static let allHeadingTodoKeywords = activeHeadingTodoKeywords.union(doneHeadingTodoKeywords)
  nonisolated private static let planningKinds = Set(["SCHEDULED", "DEADLINE", "CLOSED"])

  nonisolated static func textByDeletingSourceRangeCleaningAdjacentBlank(
    in raw: String,
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let range = try adjustedDeletionRangeCleaningAdjacentBlank(
      in: lines,
      baseLine: 1,
      file: file,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )

    lines.replaceSubrange(range.startIndex..<range.endIndex, with: [])
    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    return output
  }

  nonisolated static func adjustedDeletionRangeCleaningAdjacentBlank(
    in lines: [String],
    baseLine: Int,
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> (startIndex: Int, endIndex: Int, startLine: Int, endLineExclusive: Int) {
    var startIndex = startLine - baseLine
    var endIndex = endLineExclusive - baseLine
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: file, line: startLine)
    }

    if startIndex > 0,
       lines[startIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      startIndex -= 1
    } else if endIndex < lines.count,
              lines[endIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      endIndex += 1
    }

    return (
      startIndex: startIndex,
      endIndex: endIndex,
      startLine: baseLine + startIndex,
      endLineExclusive: baseLine + endIndex
    )
  }

  nonisolated static func textBySwappingSourceRanges(
    in raw: String,
    file: String,
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) throws -> String {
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let firstStartIndex = firstStartLine - 1
    let firstEndIndex = firstEndLineExclusive - 1
    let secondStartIndex = secondStartLine - 1
    let secondEndIndex = secondEndLineExclusive - 1
    guard firstStartIndex >= 0,
          firstStartIndex < firstEndIndex,
          firstEndIndex <= secondStartIndex,
          secondStartIndex < secondEndIndex,
          secondEndIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: file, line: firstStartLine)
    }

    let first = Array(lines[firstStartIndex..<firstEndIndex])
    let between = Array(lines[firstEndIndex..<secondStartIndex])
    let second = Array(lines[secondStartIndex..<secondEndIndex])
    lines.replaceSubrange(firstStartIndex..<secondEndIndex, with: second + between + first)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    return output
  }

  nonisolated static func assignedWorkItems(headings: [SimilarTodoCandidate]) -> [AssignedWorkItem] {
    headings.compactMap { heading in
      guard let assignee = heading.properties["ASSIGNEE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !assignee.isEmpty
      else {
        return nil
      }
      let status = heading.properties["STATUS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return AssignedWorkItem(
        file: heading.file,
        line: heading.line,
        headline: heading.headline,
        todo: heading.todo,
        assignee: assignee,
        status: status?.isEmpty == false ? status! : "ready",
        assignedAt: heading.properties["ASSIGNED_AT"],
        lastAgentUpdate: heading.properties["LAST_AGENT_UPDATE"],
        tags: heading.tags,
        properties: heading.properties
      )
    }.sorted {
      if $0.assignee == $1.assignee {
        if $0.status == $1.status {
          return $0.headline.localizedStandardCompare($1.headline) == .orderedAscending
        }
        return $0.status.localizedStandardCompare($1.status) == .orderedAscending
      }
      return $0.assignee.localizedStandardCompare($1.assignee) == .orderedAscending
    }
  }

  nonisolated static func scanTodoHeadings(files: [CorpusFile]) throws -> [SimilarTodoCandidate] {
    var candidates: [SimilarTodoCandidate] = []
    let allowedExtensions = Set(["org", "org2"])
    for file in files {
      guard allowedExtensions.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()),
            let raw = try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8)
      else {
        continue
      }
      let lines = normalizeLineEndings(raw)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      for (index, line) in lines.enumerated() {
        guard let heading = parseTodoHeading(line) else { continue }
        let properties = scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
        candidates.append(SimilarTodoCandidate(
          file: file.path,
          line: index + 1,
          headline: heading.title,
          todo: heading.todo,
          tags: heading.tags,
          properties: properties,
          score: 1
        ))
      }
    }
    return candidates
  }

  nonisolated private static let todoHeadingRegex = try! NSRegularExpression(pattern: #"^\*+\s+(.+)$"#)

  nonisolated static func parseTodoHeading(_ line: String) -> (todo: String, title: String, tags: [String])? {
    let regex = todoHeadingRegex
    let nsLine = line as NSString
    let range = NSRange(location: 0, length: nsLine.length)
    guard let match = regex.firstMatch(in: line, range: range) else { return nil }
    var rest = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
    var tags: [String] = []
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      let rawTags = String(rest[tagRange]).trimmingCharacters(in: .whitespacesAndNewlines)
      tags = rawTags
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = tokens.first,
          allHeadingTodoKeywords.contains(first.uppercased())
    else {
      return nil
    }
    let todo = first.uppercased()
    tokens.removeFirst()
    if let first = tokens.first,
       first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }
    let title = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return nil }
    return (todo, title, tags)
  }

  nonisolated static func pairedApprovalActionTitleCandidates(properties: [String: String]) -> [String] {
    [
      "PAIRED_SEND_TODO",
      "PAIRED_AGENT_TODO",
      "PAIRED_TODO",
      "NEXT_AGENT_TODO",
      "SEND_TODO"
    ]
    .compactMap { key in
      let title = properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      return title?.isEmpty == false ? title : nil
    }
  }

  nonisolated static func approvedAgentActionTitle(for title: String) -> String {
    let clean = Org2Display.cleanInline(title)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard !clean.isEmpty else { return "Continue approved task" }

    for prefix in ["Approve "] {
      if clean.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
        let rest = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "Continue approved task" : "Send approved \(rest)"
      }
    }
    return "Continue approved \(clean)"
  }

  nonisolated static func approvedAgentActionStatus(for title: String) -> String {
    normalizedApprovalActionTitle(title).hasPrefix("send approved ")
      ? "approved-to-send"
      : "ready-for-agent"
  }

  nonisolated private static func isApprovedAgentActionTitle(_ title: String) -> Bool {
    let normalized = normalizedApprovalActionTitle(title)
    return normalized.hasPrefix("send approved ") || normalized.hasPrefix("continue approved ")
  }

  nonisolated static func pairedApprovedAgentActionTarget(
    lines: [String],
    file: String,
    approvalHeadingIndex: Int,
    approvalProperties: [String: String],
    approvalTitle: String
  ) -> HeadlineMutationTarget? {
    var candidateTitles = pairedApprovalActionTitleCandidates(properties: approvalProperties)
    candidateTitles.append(approvedAgentActionTitle(for: approvalTitle))
    if let existing = findExistingApprovedAgentAction(
      lines: lines,
      file: file,
      excludingHeadingIndex: approvalHeadingIndex,
      candidateTitles: candidateTitles
    ) {
      return existing
    }

    guard let approvalLevel = headingLevel(lines[approvalHeadingIndex]), approvalLevel > 1 else {
      return nil
    }

    var index = approvalHeadingIndex - 1
    while index >= 0 {
      guard let level = headingLevel(lines[index]) else {
        index -= 1
        continue
      }
      if level < approvalLevel {
        let title = headingTitle(from: lines[index])
        guard isApprovedAgentActionTitle(title) else { return nil }
        return HeadlineMutationTarget(file: file, line: index + 1, title: title)
      }
      index -= 1
    }
    return nil
  }

  nonisolated static func findExistingApprovedAgentAction(
    lines: [String],
    file: String,
    excludingHeadingIndex excludedIndex: Int,
    candidateTitles: [String]
  ) -> HeadlineMutationTarget? {
    let normalizedCandidates = Set(candidateTitles
      .map(normalizedApprovalActionTitle)
      .filter { !$0.isEmpty })
    guard !normalizedCandidates.isEmpty else { return nil }

    for (index, line) in lines.enumerated() where index != excludedIndex {
      guard let heading = parseTodoHeading(line) else { continue }
      let normalizedTitle = normalizedApprovalActionTitle(heading.title)
      guard normalizedCandidates.contains(normalizedTitle) else { continue }
      return HeadlineMutationTarget(file: file, line: index + 1, title: heading.title)
    }
    return nil
  }

  nonisolated static func hasSentEvidence(in properties: [String: String]) -> Bool {
    for key in ["SENT_AT", "LAST_SENT_AT", "GMAIL_SENT_MESSAGE_ID", "FOLLOWUP_SENT_AT"] {
      if properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        return true
      }
    }
    if let status = properties["STATUS"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       ["sent", "bounced", "bounce", "contact-route", "contact-route-needed", "contact-route-missing"].contains(status) {
      return true
    }
    return false
  }

  nonisolated static func normalizedApprovalActionTitle(_ title: String) -> String {
    Org2Display.cleanInline(title)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  nonisolated static func sanitizeOrgPropertyValue(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The rejection reason is optional. Returns nil for blank input so no empty
  /// `REJECTION_REASON` property is written.
  nonisolated static func normalizedApprovalRejectionReason(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  nonisolated static func approvalRejectionProperties(
    timestamp: String,
    endStatus: TodoEditStatus,
    reason: String?
  ) -> [String: String] {
    var properties = [
      "STATUS": "rejected",
      "REJECTED_AT": timestamp,
      "REJECTION_END_STATUS": endStatus.label,
    ]
    if let reason = reason.map(sanitizeOrgPropertyValue), !reason.isEmpty {
      properties["REJECTION_REASON"] = reason
    }
    return properties
  }

  @MainActor
  static func promptForApprovalRejection() -> ApprovalRejectionChoice? {
    let alert = NSAlert()
    alert.messageText = "Reject Approval"
    alert.informativeText = "Choose the final TODO state and, optionally, record why this approval was rejected."
    alert.addButton(withTitle: "Reject")
    alert.addButton(withTitle: "Cancel")

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 124))

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false

    let statusLabel = NSTextField(labelWithString: "Final TODO state")
    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    statusLabel.textColor = .secondaryLabelColor

    let statusPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    statusPopup.addItem(withTitle: "Canceled")
    statusPopup.addItem(withTitle: "Done")
    statusPopup.translatesAutoresizingMaskIntoConstraints = false

    let reasonField = NSTextField()
    reasonField.placeholderString = "Reason (optional)"
    reasonField.translatesAutoresizingMaskIntoConstraints = false
    reasonField.lineBreakMode = .byWordWrapping
    reasonField.maximumNumberOfLines = 4

    accessoryView.addSubview(stack)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(statusPopup)
    stack.addArrangedSubview(reasonField)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor),
      statusPopup.widthAnchor.constraint(equalTo: stack.widthAnchor),
      statusPopup.heightAnchor.constraint(equalToConstant: 28),
      reasonField.widthAnchor.constraint(equalTo: stack.widthAnchor),
      reasonField.heightAnchor.constraint(equalToConstant: 50),
    ])
    alert.accessoryView = accessoryView

    alert.window.initialFirstResponder = reasonField
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let reason = normalizedApprovalRejectionReason(reasonField.stringValue) ?? ""
    let status: TodoEditStatus = statusPopup.indexOfSelectedItem == 1 ? .done : .canceled
    return ApprovalRejectionChoice(endStatus: status, reason: reason)
  }

  @MainActor
  static func promptForRunApprovalRejection() -> ApprovalRejectionChoice? {
    let alert = NSAlert()
    alert.messageText = "Reject Run Approval"
    alert.informativeText = "Optionally record why this action is rejected. The approval will be resolved and the run will be canceled automatically."
    alert.addButton(withTitle: "Reject")
    alert.addButton(withTitle: "Cancel")

    let reasonField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 50))
    reasonField.placeholderString = "Reason (optional)"
    reasonField.lineBreakMode = .byWordWrapping
    reasonField.maximumNumberOfLines = 4
    alert.accessoryView = reasonField

    alert.window.initialFirstResponder = reasonField
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let reason = normalizedApprovalRejectionReason(reasonField.stringValue) ?? ""
    return ApprovalRejectionChoice(endStatus: .canceled, reason: reason)
  }

  nonisolated static func scanPropertyDrawer(lines: [String], afterHeadingIndex headingIndex: Int) -> [String: String] {
    var index = headingIndex + 1
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("*") { return [:] }
      if trimmed == ":PROPERTIES:" { break }
      index += 1
    }
    guard index < lines.count else { return [:] }
    index += 1
    var properties: [String: String] = [:]
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed == ":END:" { break }
      if trimmed.hasPrefix(":"),
         let separator = trimmed.dropFirst().firstIndex(of: ":") {
        let keyStart = trimmed.index(after: trimmed.startIndex)
        let key = String(trimmed[keyStart..<separator]).uppercased()
        let valueStart = trimmed.index(after: separator)
        let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
          properties[key] = value
        }
      }
      index += 1
    }
    return properties
  }

  nonisolated static func scanAIChatThreadRecords(corpusRoot: URL) throws -> [AIChatThreadRecord] {
    let fileManager = FileManager.default
    let directories = aiChatThreadRecordDirectories(corpusRoot: corpusRoot)
    var threads: [AIChatThreadRecord] = []
    let allowedExtensions = Set(["org", "org2", "md", "txt", "log", "json", "jsonl"])

    for directory in directories where isDirectoryURL(directory) {
      guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        continue
      }

      for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { continue }

        let ext = fileURL.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { continue }
        if fileURL.lastPathComponent.hasSuffix(".transcript.org")
          || fileURL.lastPathComponent.hasSuffix(".transcript.org2") { continue }

        let prefix = (try? readPrefix(fileURL, maxBytes: 48 * 1024)) ?? ""
        let titleInfo = aiChatTitle(from: prefix, fallback: fileURL.deletingPathExtension().lastPathComponent)
        let zone = aiChatThreadRecordZone(fileURL: fileURL, corpusRoot: corpusRoot, directory: directory)
        threads.append(AIChatThreadRecord(
          title: titleInfo.title,
          file: fileURL.path,
          line: titleInfo.line,
          zone: zone,
          modifiedAt: values?.contentModificationDate,
          idValue: firstOrgID(in: prefix)
        ))
      }
    }

    return threads
      .sorted {
        let left = $0.modifiedAt ?? .distantPast
        let right = $1.modifiedAt ?? .distantPast
        if left != right { return left > right }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      .prefix(250)
      .map { $0 }
  }

  nonisolated static func scanMeetingItems(corpusRoot: URL) throws -> [MeetingWorkspaceItem] {
    let fileManager = FileManager.default
    let meetingsDirectory = corpusRoot.appendingPathComponent("meetings", isDirectory: true)
    guard isDirectoryURL(meetingsDirectory),
          let enumerator = fileManager.enumerator(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
          )
    else {
      return []
    }

    var items: [MeetingWorkspaceItem] = []
    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true,
            ["org", "org2"].contains(fileURL.pathExtension.lowercased()),
            !fileURL.lastPathComponent.hasSuffix(".transcript.org"),
            !fileURL.lastPathComponent.hasSuffix(".transcript.org2")
      else {
        continue
      }

      let prefix = (try? readPrefix(fileURL, maxBytes: 96 * 1024)) ?? ""
      guard meetingProperty("kind", in: prefix)?.lowercased() == "meeting"
        || prefix.contains("#+ORG2_KIND: meeting")
        || prefix.contains("#+CELORGA_KIND: meeting")
      else {
        continue
      }

      let titleInfo = aiChatTitle(from: prefix, fallback: fileURL.deletingPathExtension().lastPathComponent)
      items.append(MeetingWorkspaceItem(
        title: titleInfo.title.replacingOccurrences(of: #"^Meeting:\s*"#, with: "", options: .regularExpression),
        file: fileURL.path,
        line: titleInfo.line,
        recordedAt: meetingProperty("recorded_at", in: prefix),
        modifiedAt: values?.contentModificationDate,
        audioArtifact: meetingProperty("audio_artifact", in: prefix),
        systemAudioArtifact: meetingProperty("system_audio_artifact", in: prefix),
        transcriptArtifact: meetingProperty("transcript_artifact", in: prefix),
        transcriptionStatus: meetingProperty("transcription_status", in: prefix),
        idValue: meetingNodeID(in: prefix)
      ))
    }

    return items.sorted {
      let leftRecorded = $0.recordedAt ?? ""
      let rightRecorded = $1.recordedAt ?? ""
      if leftRecorded != rightRecorded { return leftRecorded > rightRecorded }
      let leftModified = $0.modifiedAt ?? .distantPast
      let rightModified = $1.modifiedAt ?? .distantPast
      if leftModified != rightModified { return leftModified > rightModified }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
  }

  nonisolated static func scanRecoverableMeetingRecordings(corpusRoot: URL) throws -> [RecoverableMeetingRecording] {
    let fileManager = FileManager.default
    let meetingsDirectory = corpusRoot.appendingPathComponent("meetings", isDirectory: true)
    guard isDirectoryURL(meetingsDirectory),
          let enumerator = fileManager.enumerator(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
          )
    else {
      return []
    }

    let audioExtensions = Set(["aif", "aiff", "flac", "m4a", "mp3", "ogg", "wav"])
    var primaryAudioFiles: [URL] = []
    var systemAudioFilesByBaseName: [String: URL] = [:]

    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      let ext = fileURL.pathExtension.lowercased()
      guard audioExtensions.contains(ext) else { continue }
      let baseName = fileURL.deletingPathExtension().lastPathComponent
      if let systemRange = baseName.range(of: ".system", options: [.caseInsensitive, .backwards]),
         systemRange.upperBound == baseName.endIndex {
        let primaryBaseName = String(baseName[..<systemRange.lowerBound])
        systemAudioFilesByBaseName[primaryBaseName] = fileURL
      } else {
        primaryAudioFiles.append(fileURL)
      }
    }

    var recoverable: [RecoverableMeetingRecording] = []
    for audioURL in primaryAudioFiles {
      let baseName = audioURL.deletingPathExtension().lastPathComponent
      let noteURL = OrgDocumentDefaults.url(in: meetingsDirectory, baseName: baseName, fileManager: fileManager)
      let transcriptURL = OrgDocumentDefaults.url(in: meetingsDirectory, baseName: "\(baseName).transcript", fileManager: fileManager)
      let existingTranscripts = OrgDocumentDefaults.candidateURLs(in: meetingsDirectory, baseName: "\(baseName).transcript")
      guard !existingTranscripts.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
        continue
      }
      // A note without a transcript is recoverable only when it is the live
      // note of a recording that never finished.
      let existingNotes = OrgDocumentDefaults.candidateURLs(in: meetingsDirectory, baseName: baseName)
        .filter { fileManager.fileExists(atPath: $0.path) }
      var liveNoteID: String?
      var liveNoteTitle: String?
      if !existingNotes.isEmpty {
        guard existingNotes.count == 1,
              existingNotes[0].path == noteURL.path,
              let prefix = try? readPrefix(noteURL, maxBytes: 96 * 1024),
              meetingProperty("transcription_status", in: prefix)?.lowercased()
                == MeetingArtifactWriter.liveRecordingStatus
        else {
          continue
        }
        liveNoteID = meetingNodeID(in: prefix)
        liveNoteTitle = aiChatTitle(from: prefix, fallback: "").title
          .replacingOccurrences(of: #"^Meeting:\s*"#, with: "", options: .regularExpression)
      }

      let values = try? audioURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
      let parsed = recoverableMeetingTitleAndDate(
        baseName: baseName,
        fallbackDate: values?.creationDate ?? values?.contentModificationDate ?? Date()
      )
      let systemAudioURL = systemAudioFilesByBaseName[baseName]
      let paths = MeetingArtifactPaths(
        meetingID: liveNoteID ?? UUID().uuidString.lowercased(),
        title: liveNoteTitle.flatMap { $0.isEmpty ? nil : $0 } ?? parsed.title,
        recordedAt: parsed.recordedAt,
        baseName: baseName,
        noteURL: noteURL,
        audioURL: audioURL,
        systemAudioURL: systemAudioURL ?? meetingsDirectory.appendingPathComponent("\(baseName).system.m4a"),
        transcriptURL: transcriptURL
      )
      recoverable.append(RecoverableMeetingRecording(
        paths: paths,
        duration: MeetingArtifactWriter.audioDuration(at: audioURL),
        systemAudioURL: systemAudioURL,
        systemAudioCaptureError: nil,
        captureSources: systemAudioURL == nil ? "recovered_audio" : "recovered_audio, system_audio"
      ))
    }

    return recoverable.sorted {
      if $0.paths.recordedAt != $1.paths.recordedAt {
        return $0.paths.recordedAt > $1.paths.recordedAt
      }
      return $0.paths.title.localizedCaseInsensitiveCompare($1.paths.title) == .orderedAscending
    }
  }

  nonisolated private static func recoverableMeetingTitleAndDate(
    baseName: String,
    fallbackDate: Date
  ) -> (title: String, recordedAt: Date) {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"

    if baseName.count > 18 {
      let timestampEnd = baseName.index(baseName.startIndex, offsetBy: 17)
      let timestamp = String(baseName[..<timestampEnd])
      let separator = baseName[timestampEnd]
      if separator == "-",
         let recordedAt = formatter.date(from: timestamp) {
        let titleSlugStart = baseName.index(after: timestampEnd)
        let title = titleFromMeetingSlug(String(baseName[titleSlugStart...]))
        return (title, recordedAt)
      }
    }

    return (titleFromMeetingSlug(baseName), fallbackDate)
  }

  nonisolated private static func titleFromMeetingSlug(_ slug: String) -> String {
    let words = slug
      .split(separator: "-", omittingEmptySubsequences: true)
      .map(String.init)
    let title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Recovered Meeting" : title.capitalized
  }

  func refreshOrgRoamLinkResolver(files: [CorpusFile]) {
    orgRoamLinkResolverGeneration &+= 1
    let generation = orgRoamLinkResolverGeneration
    let corpusRoot = corpusRoot
    let releaseMetrics = orgRoamSearchProjectionReleaseMetrics
    let releaseSink = orgRoamSearchProjectionReleaseSink
    orgRoamLinkResolverRefreshTask?.cancel()
    orgRoamLinkResolverRefreshTask = Task { @MainActor [weak self] in
      let projectionBox = await Task.detached(priority: .utility) {
        let resolver = Self.buildOrgRoamLinkResolver(files: files, corpusRoot: corpusRoot)
        return OrgRoamSearchProjectionBox(
          projection: Self.makeOrgRoamSearchProjection(
            resolver: resolver,
            files: files,
            corpusRoot: corpusRoot
          ),
          releaseMetrics: releaseMetrics
        )
      }.value
      guard let self else {
        releaseSink.enqueue([projectionBox])
        return
      }
      guard !Task.isCancelled,
            generation == self.orgRoamLinkResolverGeneration
      else {
        releaseSink.enqueue([projectionBox])
        return
      }
      self.publishOrgRoamSearchProjection(projectionBox)
      self.orgRoamLinkResolverRefreshTask = nil
    }
  }

  nonisolated static func buildOrgRoamLinkResolver(
    files: [CorpusFile],
    corpusRoot: URL? = nil
  ) -> OrgRoamLinkResolver {
    let links = corpusRoot.flatMap(workspaceConfig(corpusRoot:))?.links
    let abbreviations = OrgLinkAbbreviations(
      linearTeam: links?.linearTeam,
      configured: links?.abbreviations ?? [:]
    )
    return OrgRoamLinkResolver(
      nodes: files.flatMap(scanRoamNodes),
      linkAbbreviations: abbreviations
    )
  }

  nonisolated static func scanRoamNodes(file: CorpusFile) -> [OrgRoamNodeReference] {
    guard Set(["org", "org2", "md"]).contains(
      URL(fileURLWithPath: file.path).pathExtension.lowercased()
    ),
    let raw = try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8) else {
      return []
    }

    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var nodes: [OrgRoamNodeReference] = []
    var currentHeading: RoamHeadingDraft?

    func flushCurrentHeading() {
      guard let heading = currentHeading else { return }
      nodes.append(OrgRoamNodeReference(
        idValue: heading.idValue,
        title: heading.title,
        aliases: heading.aliases,
        file: file.path,
        line: heading.line
      ))
      currentHeading = nil
    }

    for (index, line) in lines.enumerated() {
      let lineNumber = index + 1

      if let headingTitle = roamHeadingTitle(line) {
        flushCurrentHeading()
        currentHeading = RoamHeadingDraft(title: headingTitle, line: lineNumber)
        continue
      }

      if let keyword = roamKeyword(line) {
        switch keyword.key {
        case "TITLE":
          break
        case "ID":
          break
        case "ROAM_ALIASES", "ROAM_ALIAS":
          if currentHeading != nil {
            currentHeading?.aliases.append(contentsOf: parseRoamAliases(keyword.value))
          }
        default:
          break
        }
        continue
      }

      if let property = roamProperty(line) {
        switch property.key {
        case "ID":
          if currentHeading != nil, currentHeading?.idValue == nil {
            currentHeading?.idValue = property.value
          }
        case "ROAM_ALIASES", "ROAM_ALIAS":
          if currentHeading != nil {
            currentHeading?.aliases.append(contentsOf: parseRoamAliases(property.value))
          }
        default:
          break
        }
      }
    }

    flushCurrentHeading()
    if let fileNode = scanRoamFileNode(file: file, lines: lines) {
      nodes.append(fileNode)
    }
    return nodes
  }

  nonisolated static func scanRoamFileNode(file: CorpusFile) -> OrgRoamNodeReference? {
    guard let raw = try? String(contentsOf: URL(fileURLWithPath: file.path), encoding: .utf8) else {
      return nil
    }

    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    return scanRoamFileNode(file: file, lines: lines)
  }

  nonisolated static func scanRoamFileNode(file: CorpusFile, lines: [String]) -> OrgRoamNodeReference? {
    var fileTitle: (value: String, line: Int)?
    var fileAliases: [String] = []
    var fileID: String?

    for (index, line) in lines.enumerated() {
      if roamHeadingTitle(line) != nil {
        break
      }
      let lineNumber = index + 1
      if let keyword = roamKeyword(line) {
        switch keyword.key {
        case "TITLE":
          if fileTitle == nil {
            fileTitle = (Org2Display.cleanInline(keyword.value), lineNumber)
          }
        case "ID":
          fileID = fileID ?? keyword.value
        case "ROAM_ALIASES", "ROAM_ALIAS":
          fileAliases.append(contentsOf: parseRoamAliases(keyword.value))
        default:
          break
        }
        continue
      }

      if let property = roamProperty(line) {
        switch property.key {
        case "ID":
          fileID = fileID ?? property.value
        case "ROAM_ALIASES", "ROAM_ALIAS":
          fileAliases.append(contentsOf: parseRoamAliases(property.value))
        default:
          break
        }
      }
    }

    let fallbackFileTitle = Self.titleFromFileStem(URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent)
    let resolvedFileTitle = fileTitle?.value ?? fallbackFileTitle
    return OrgRoamNodeReference(
      idValue: fileID,
      title: resolvedFileTitle,
      aliases: fileAliases,
      file: file.path,
      line: fileTitle?.line ?? 1,
      isPageNode: true
    )
  }

  nonisolated static func titleFromFileStem(_ stem: String) -> String {
    stem
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  private struct RoamHeadingDraft {
    var title: String
    var line: Int
    var idValue: String?
    var aliases: [String] = []
  }

  nonisolated private static func roamKeyword(_ line: String) -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#+"), let colon = trimmed.firstIndex(of: ":") else { return nil }
    let keyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let key = String(trimmed[keyStart..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let valueStart = trimmed.index(after: colon)
    let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else { return nil }
    return (key, value)
  }

  nonisolated private static func roamProperty(_ line: String) -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let keyEnd = trimmed.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }
    let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<keyEnd]).uppercased()
    let valueStart = trimmed.index(after: keyEnd)
    let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else { return nil }
    return (key, value)
  }

  nonisolated private static func roamHeadingTitle(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, first == "*" else { return nil }
    let starCount = trimmed.prefix { $0 == "*" }.count
    guard trimmed.count > starCount else { return nil }
    let afterStars = trimmed.dropFirst(starCount)
    guard afterStars.first?.isWhitespace == true else { return nil }

    var tokens = afterStars
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !tokens.isEmpty else { return nil }

    if let last = tokens.last, isTagSuffix(last) {
      tokens.removeLast()
    }
    if let first = tokens.first, roamTodoKeywords.contains(first.uppercased()) {
      tokens.removeFirst()
    }
    if let first = tokens.first, first.range(of: #"^\[#.\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }

    let title = Org2Display.cleanInline(tokens.joined(separator: " "))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  nonisolated private static func parseRoamAliases(_ raw: String) -> [String] {
    var aliases: [String] = []
    var current = ""
    var isQuoted = false
    var iterator = raw.makeIterator()

    while let character = iterator.next() {
      if character == "\"" {
        if isQuoted {
          let alias = current.trimmingCharacters(in: .whitespacesAndNewlines)
          if !alias.isEmpty { aliases.append(alias) }
          current = ""
          isQuoted = false
        } else {
          if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aliases.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
          }
          isQuoted = true
        }
        continue
      }

      if character.isWhitespace && !isQuoted {
        let alias = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty { aliases.append(alias) }
        current = ""
      } else {
        current.append(character)
      }
    }

    let alias = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !alias.isEmpty { aliases.append(alias) }
    return aliases
  }

  nonisolated private static func isTagSuffix(_ raw: String) -> Bool {
    raw.count > 2
      && raw.first == ":"
      && raw.last == ":"
      && raw.dropFirst().dropLast().allSatisfy { character in
        character.isLetter || character.isNumber || character == "_" || character == "@" || character == "#"
      }
  }

  nonisolated private static let roamTodoKeywords = Set([
    "TODO", "OPEN", "BACKLOG", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"
  ])

  nonisolated static let aiChatChangeSnapshotEagerReadMaxBytes = 16_000_000

  struct AIChatCorpusSnapshotListing: Sendable {
    struct Entry: Sendable {
      let url: URL
      let relativePath: String
    }

    var entries: [Entry] = []
    var totalBytes = 0
  }

  /// Text files eligible for the pre-turn snapshot, without reading them.
  nonisolated static func aiChatCorpusSnapshotListing(corpusRoot: URL) -> AIChatCorpusSnapshotListing {
    let root = corpusRoot.standardizedFileURL
    let rootPath = root.path
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    var listing = AIChatCorpusSnapshotListing()
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return listing }
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
      if values.isDirectory == true {
        if shouldSkipDefaultCorpusDirectory(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true,
            aiChatChangeSnapshotAllowedExtensions.contains(url.pathExtension.lowercased()),
            let byteCount = values.fileSize,
            byteCount <= aiChatChangeSnapshotMaxFileBytes
      else { continue }
      let path = url.standardizedFileURL.path
      let relativePath = path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1))
        : url.lastPathComponent
      listing.entries.append(.init(url: url, relativePath: relativePath))
      listing.totalBytes += byteCount
    }
    return listing
  }

  /// Reads the listed files. A file already modified after `modifiedBefore`
  /// when the read reaches it existed before the turn, but its pre-turn text
  /// is gone, so it is recorded as unknown instead.
  nonisolated static func aiChatCorpusSnapshot(
    corpusRoot: URL,
    listing: AIChatCorpusSnapshotListing,
    modifiedBefore: Date
  ) -> AIChatCorpusSnapshot {
    let rootPath = corpusRoot.standardizedFileURL.path
    var files: [String: AIChatSnapshotFile] = [:]
    var unknownPaths: Set<String> = []
    for entry in listing.entries {
      guard let data = try? Data(contentsOf: entry.url) else {
        // Removed or replaced during the turn.
        unknownPaths.insert(entry.relativePath)
        continue
      }
      let attributes = try? FileManager.default.attributesOfItem(atPath: entry.url.path)
      if let modified = attributes?[.modificationDate] as? Date, modified >= modifiedBefore {
        unknownPaths.insert(entry.relativePath)
        continue
      }
      guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { continue }
      files[entry.relativePath] = AIChatSnapshotFile(text: text)
    }
    return AIChatCorpusSnapshot(rootPath: rootPath, files: files, unknownPaths: unknownPaths)
  }

  nonisolated static func aiChatCorpusSnapshot(corpusRoot: URL) throws -> AIChatCorpusSnapshot {
    let root = corpusRoot.standardizedFileURL
    let rootPath = root.path
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return AIChatCorpusSnapshot(rootPath: rootPath, files: [:])
    }

    var files: [String: AIChatSnapshotFile] = [:]
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
        continue
      }
      if values.isDirectory == true {
        if shouldSkipDefaultCorpusDirectory(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard values.isRegularFile == true,
            aiChatChangeSnapshotAllowedExtensions.contains(url.pathExtension.lowercased()),
            let byteCount = values.fileSize,
            byteCount <= aiChatChangeSnapshotMaxFileBytes,
            let data = try? Data(contentsOf: url),
            !data.contains(0),
            let text = String(data: data, encoding: .utf8)
      else {
        continue
      }

      let path = url.standardizedFileURL.path
      let relativePath = path.hasPrefix(rootPath + "/")
        ? String(path.dropFirst(rootPath.count + 1))
        : url.lastPathComponent
      files[relativePath] = AIChatSnapshotFile(text: text)
    }

    return AIChatCorpusSnapshot(rootPath: rootPath, files: files)
  }

  nonisolated static func aiChatCorpusSnapshot(
    corpusRoot: URL,
    relativePaths: Set<String>
  ) throws -> AIChatCorpusSnapshot {
    let root = corpusRoot.standardizedFileURL
    let rootPath = root.path
    guard !relativePaths.isEmpty else {
      return AIChatCorpusSnapshot(rootPath: rootPath, files: [:])
    }

    var files: [String: AIChatSnapshotFile] = [:]
    for relativePath in relativePaths {
      guard let file = try aiChatSnapshotFile(corpusRoot: root, relativePath: relativePath) else {
        continue
      }
      files[relativePath] = file
    }
    return AIChatCorpusSnapshot(rootPath: rootPath, files: files)
  }

  nonisolated private static func aiChatSnapshotFile(
    corpusRoot root: URL,
    relativePath: String
  ) throws -> AIChatSnapshotFile? {
    let rootPath = root.standardizedFileURL.path
    let cleanRelativePath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanRelativePath.isEmpty,
          cleanRelativePath != ".",
          !cleanRelativePath.hasPrefix("/"),
          !cleanRelativePath.split(separator: "/").contains(where: { $0 == ".." })
    else {
      return nil
    }

    let url = root
      .appendingPathComponent(cleanRelativePath, isDirectory: false)
      .standardizedFileURL
    guard url.path.hasPrefix(rootPath + "/") else { return nil }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true,
          aiChatChangeSnapshotAllowedExtensions.contains(url.pathExtension.lowercased()),
          let byteCount = values.fileSize,
          byteCount <= aiChatChangeSnapshotMaxFileBytes,
          let data = try? Data(contentsOf: url),
          !data.contains(0),
          let text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return AIChatSnapshotFile(text: text)
  }

  nonisolated static func aiChatChangeSummary(
    before: AIChatCorpusSnapshot,
    after: AIChatCorpusSnapshot
  ) -> AIChatCorpusChangeSummary? {
    let changedFiles = Set(before.files.keys)
      .union(after.files.keys)
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .compactMap { relativePath -> AIChatCorpusFileChange? in
        switch (before.files[relativePath], after.files[relativePath]) {
        case let (oldFile?, newFile?):
          guard oldFile.text != newFile.text else { return nil }
          let counts = aiChatLineChangeCounts(before: oldFile.text, after: newFile.text)
          return AIChatCorpusFileChange(
            relativePath: relativePath,
            status: .modified,
            insertions: counts.insertions,
            deletions: counts.deletions
          )
        case let (nil, newFile?):
          return AIChatCorpusFileChange(
            relativePath: relativePath,
            status: .created,
            insertions: aiChatTextLines(newFile.text).count,
            deletions: 0
          )
        case let (oldFile?, nil):
          return AIChatCorpusFileChange(
            relativePath: relativePath,
            status: .deleted,
            insertions: 0,
            deletions: aiChatTextLines(oldFile.text).count
          )
        case (nil, nil):
          return nil
        }
      }

    return changedFiles.isEmpty ? nil : AIChatCorpusChangeSummary(files: changedFiles)
  }

  nonisolated private static func aiChatLineChangeCounts(before oldText: String, after newText: String) -> (insertions: Int, deletions: Int) {
    let oldLines = aiChatTextLines(oldText)
    let newLines = aiChatTextLines(newText)
    guard !oldLines.isEmpty || !newLines.isEmpty else {
      return (0, 0)
    }

    let canRunExactDiff = oldLines.count <= 1_000_000 / max(1, newLines.count)
    let commonLineCount = canRunExactDiff
      ? aiChatLongestCommonSubsequenceCount(oldLines, newLines)
      : aiChatPrefixSuffixCommonLineCount(oldLines, newLines)
    return (
      insertions: max(0, newLines.count - commonLineCount),
      deletions: max(0, oldLines.count - commonLineCount)
    )
  }

  nonisolated private static func aiChatTextLines(_ text: String) -> [String] {
    let normalized = normalizeLineEndings(text)
    guard !normalized.isEmpty else { return [] }
    var lines = normalized
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    if normalized.hasSuffix("\n") {
      lines.removeLast()
    }
    return lines
  }

  nonisolated private static func aiChatLongestCommonSubsequenceCount(_ oldLines: [String], _ newLines: [String]) -> Int {
    guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }
    var previous = Array(repeating: 0, count: newLines.count + 1)
    var current = previous

    for oldLine in oldLines {
      current[0] = 0
      for (newIndex, newLine) in newLines.enumerated() {
        if oldLine == newLine {
          current[newIndex + 1] = previous[newIndex] + 1
        } else {
          current[newIndex + 1] = max(previous[newIndex + 1], current[newIndex])
        }
      }
      swap(&previous, &current)
    }

    return previous[newLines.count]
  }

  nonisolated private static func aiChatPrefixSuffixCommonLineCount(_ oldLines: [String], _ newLines: [String]) -> Int {
    var prefixCount = 0
    while prefixCount < oldLines.count,
          prefixCount < newLines.count,
          oldLines[prefixCount] == newLines[prefixCount] {
      prefixCount += 1
    }

    var oldEnd = oldLines.count
    var newEnd = newLines.count
    var suffixCount = 0
    while oldEnd > prefixCount,
          newEnd > prefixCount,
          oldLines[oldEnd - 1] == newLines[newEnd - 1] {
      oldEnd -= 1
      newEnd -= 1
      suffixCount += 1
    }

    return prefixCount + suffixCount
  }

  nonisolated static func scanCorpusFiles(corpusRoot: URL) throws -> [CorpusFile] {
    let root = corpusRoot.standardizedFileURL
    let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    let allowedExtensions = Set(["org", "org2", "md", "csv", "canvas"])
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var files: [CorpusFile] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: resourceKeys)
      if values.isDirectory == true {
        if shouldSkipDefaultCorpusDirectory(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard values.isRegularFile == true,
            allowedExtensions.contains(url.pathExtension.lowercased()),
            !isDefaultIgnoredSyncArtifactPath(url.path)
      else {
        continue
      }

      let path = url.standardizedFileURL.path
      let relativePath = path.hasPrefix(root.path + "/")
        ? String(path.dropFirst(root.path.count + 1))
        : url.lastPathComponent
      files.append(CorpusFile(
        path: path,
        relativePath: relativePath,
        modifiedAt: values.contentModificationDate,
        byteCount: values.fileSize.map(Int64.init)
      ))
    }

    return files.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
  }

  nonisolated static func corpusFile(atPath path: String, corpusRoot: URL) -> CorpusFile? {
    let root = corpusRoot.standardizedFileURL
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.path.hasPrefix(root.path + "/"),
          Set(["org", "org2", "md", "csv", "canvas"]).contains(url.pathExtension.lowercased()),
          !isDefaultIgnoredSyncArtifactPath(url.path),
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
          values.isRegularFile == true
    else {
      return nil
    }
    let relativePath = String(url.path.dropFirst(root.path.count + 1))
    return CorpusFile(
      path: url.path,
      relativePath: relativePath,
      modifiedAt: values.contentModificationDate,
      byteCount: values.fileSize.map(Int64.init)
    )
  }

  nonisolated private static let defaultIgnoredCorpusDirectories = Set([
    ".git",
    ".hg",
    ".svn",
    ".stversions",
    ".trash",
    ".celorga",
    ".org2",
    "node_modules",
    "dist",
    "build",
    ".build",
    "DerivedData",
    "sync-conflicts"
  ])

  nonisolated private static func shouldSkipDefaultCorpusDirectory(_ name: String) -> Bool {
    name.hasPrefix(".") || defaultIgnoredCorpusDirectories.contains(name)
  }

  nonisolated private static func hasDefaultIgnoredCorpusPathComponent(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
      defaultIgnoredCorpusDirectories.contains(String(component))
    }
  }

  nonisolated static func isDefaultIgnoredSyncArtifactPath(_ path: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return hasDefaultIgnoredCorpusPathComponent(path)
      || name.hasPrefix(".syncthing.")
      || name.hasPrefix(".")
      || name.contains(".sync-conflict-")
      || name.hasSuffix(".tmp")
  }

  nonisolated static func fuzzyScore(query: String, candidate: String) -> Int? {
    fuzzyScore(
      normalizedQuery: normalizedQuickOpenQuery(query),
      normalizedCandidate: normalizedQuickOpenCandidate(candidate)
    )
  }

  nonisolated static func normalizedQuickOpenQuery(_ query: String) -> String {
    query.lowercased().filter { !$0.isWhitespace }
  }

  nonisolated static func normalizedQuickOpenCandidate(_ candidate: String) -> String {
    candidate.lowercased()
  }

  nonisolated static func fuzzyScore(normalizedQuery query: String, normalizedCandidate candidate: String) -> Int? {
    guard !query.isEmpty else { return 0 }

    var score = 0
    var queryIndex = query.startIndex
    var previousMatch: String.Index?

    for candidateIndex in candidate.indices {
      guard queryIndex < query.endIndex else { break }
      if candidate[candidateIndex] != query[queryIndex] { continue }

      score += 10
      if let previousMatch, candidate.index(after: previousMatch) == candidateIndex {
        score += 8
      }
      if candidateIndex == candidate.startIndex {
        score += 6
      } else {
        let previous = candidate[candidate.index(before: candidateIndex)]
        if ["/", "-", "_", ".", " "].contains(previous) {
          score += 6
        }
      }
      previousMatch = candidateIndex
      queryIndex = query.index(after: queryIndex)
    }

    guard queryIndex == query.endIndex else { return nil }
    if candidate.contains(query) { score += 30 }
    if candidate.hasSuffix(query) { score += 20 }
    score -= max(0, candidate.count - query.count) / 8
    return score
  }

  nonisolated static func normalizeLineEndings(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  nonisolated static func normalizedRenderedSearchHighlightQuery(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let scopedPrefixes = ["id:", "file:", "tag:", "todo:"]
    let lowercased = trimmed.lowercased()
    for prefix in scopedPrefixes where lowercased.hasPrefix(prefix) {
      let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count > 1 {
      let unquoted = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      return unquoted.isEmpty ? nil : unquoted
    }
    return trimmed
  }

  nonisolated static func countSearchOccurrences(in text: String, query: String) -> Int {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return 0 }

    let lowerText = text.lowercased()
    let lowerQuery = query.lowercased()
    var count = 0
    var index = lowerText.startIndex
    while index < lowerText.endIndex,
          let range = lowerText.range(of: lowerQuery, range: index..<lowerText.endIndex) {
      count += 1
      index = range.upperBound
    }
    return count
  }

  nonisolated static func renderedPageSearchMatches(
    in blocks: [OrgEditableBlock],
    query: String
  ) -> [PageSearchRenderedMatch] {
    blocks.enumerated().flatMap { index, block -> [PageSearchRenderedMatch] in
      let count = countSearchOccurrences(in: block.rawText, query: query)
      guard count > 0 else { return [] }
      return (0..<count).map { offset in
        PageSearchRenderedMatch(
          blockID: block.id,
          blockIndex: index,
          occurrenceOffsetInBlock: offset
        )
      }
    }
  }

  nonisolated public static func slug(_ raw: String) -> String {
    let lowercased = raw.lowercased()
    var output = ""
    var lastWasSeparator = false
    for scalar in lowercased.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        output.unicodeScalars.append(scalar)
        lastWasSeparator = false
      } else if !lastWasSeparator {
        output.append("-")
        lastWasSeparator = true
      }
    }
    let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "untitled" : String(trimmed.prefix(80))
  }

  nonisolated static func headingIndex(in lines: [String], atOrBefore targetIndex: Int) -> Int? {
    var cursor = targetIndex
    while cursor >= 0 {
      if headingLevel(lines[cursor]) != nil {
        return cursor
      }
      cursor -= 1
    }
    return nil
  }

  nonisolated static func headingLevel(_ line: String) -> Int? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return nil }
    let afterStars = line.dropFirst(stars.count)
    guard afterStars.first?.isWhitespace == true else { return nil }
    return stars.count
  }

  nonisolated static func subtreeEndIndex(lines: [String], headingIndex: Int, level: Int) -> Int {
    guard headingIndex + 1 < lines.count else { return lines.count }
    for index in (headingIndex + 1)..<lines.count {
      guard let candidateLevel = headingLevel(lines[index]) else { continue }
      if candidateLevel <= level {
        return index
      }
    }
    return lines.count
  }

  nonisolated static func aiChatThreadRecordDirectories(corpusRoot: URL) -> [URL] {
    let configured = workspaceConfig(corpusRoot: corpusRoot)?.openClaw?.threadDirs ?? []
    let rawDirectories = configured.isEmpty
      ? ["agents", "meetings", "notes/openclaw", "raw/openclaw", "views/openclaw", "views/node-briefs"]
      : configured

    return rawDirectories.map { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if NSString(string: trimmed).isAbsolutePath {
        return URL(fileURLWithPath: trimmed).standardizedFileURL
      }
      return corpusRoot.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
    }
  }

  nonisolated static func workspaceConfig(corpusRoot: URL) -> WorkspaceOrg2Config? {
    guard let configURL = CelorgaNames.configFile(in: corpusRoot),
          let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(WorkspaceOrg2Config.self, from: data)
  }

  nonisolated private static func isDirectoryURL(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  nonisolated static func readPrefix(_ url: URL, maxBytes: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
  }

  nonisolated static func aiChatTitle(from prefix: String, fallback: String) -> (title: String, line: Int) {
    let lines = normalizeLineEndings(String(prefix.prefix(131_072)))
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.uppercased().hasPrefix("#+TITLE:") {
        let title = String(trimmed.dropFirst("#+TITLE:".count)).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
          return (Org2Display.cleanInline(title), index + 1)
        }
      }
      if let heading = OrgEntryRenderer.parse(line).compactMap({ block -> OrgHeadingBlock? in
        if case .heading(let heading) = block { return heading }
        return nil
      }).first, !heading.title.isEmpty {
        return (heading.title, index + 1)
      }
    }

    return (fallback.replacingOccurrences(of: "-", with: " "), 1)
  }

  nonisolated private static func aiChatThreadRecordZone(fileURL: URL, corpusRoot: URL, directory: URL) -> String {
    let rootPath = corpusRoot.standardizedFileURL.path
    let directoryPath = directory.standardizedFileURL.path
    if directoryPath.hasPrefix(rootPath + "/") {
      return String(directoryPath.dropFirst(rootPath.count + 1))
    }
    return directory.lastPathComponent
  }

  nonisolated static func firstOrgID(in prefix: String) -> String? {
    let pattern = #"(?m)^\s*:ID:\s*([0-9a-fA-F-]{36})\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let boundedPrefix = String(prefix.prefix(262_144))
    let nsText = boundedPrefix as NSString
    guard let match = regex.firstMatch(
      in: boundedPrefix,
      range: NSRange(location: 0, length: nsText.length)
    ),
          match.numberOfRanges >= 2
    else {
      return nil
    }
    return nsText.substring(with: match.range(at: 1))
  }

  nonisolated private static func meetingNodeID(in prefix: String) -> String? {
    let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, line) in lines.enumerated() {
      guard line.range(of: #"^\*+\s+"#, options: .regularExpression) != nil else { continue }
      let properties = scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
      guard properties["KIND"]?.lowercased() == "meeting",
            let id = properties["ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
      else {
        continue
      }
      return id
    }
    return firstOrgID(in: prefix)
  }

  nonisolated private static func meetingProperty(_ key: String, in prefix: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: key)
    let pattern = "(?im)^\\s*:" + escaped + ":\\s*(.*?)\\s*$"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsText = prefix as NSString
    guard let match = regex.firstMatch(in: prefix, range: NSRange(location: 0, length: nsText.length)),
          match.numberOfRanges >= 2
    else {
      return nil
    }
    let value = nsText.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func upsertHeadlineProperties(file: String, line: Int, properties: [String: String]) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let output = try Self.textByUpsertingHeadlineProperties(
      raw,
      file: file,
      line: line,
      properties: properties
    )
    try Self.writeOrgTextSafely(
      output,
      to: url,
      replacing: raw,
      operation: "headline property update"
    )
  }

  nonisolated static func textByUpsertingHeadlineProperties(
    _ raw: String,
    file: String,
    line: Int,
    properties: [String: String]
  ) throws -> String {
    let normalizedRaw = raw.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = normalizedRaw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let targetIndex = max(0, min(lines.count - 1, line - 1))
    guard let headingIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex),
          lines[headingIndex].range(of: #"^\*+\s+"#, options: .regularExpression) != nil
    else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let headingLevel = lines[headingIndex].prefix { $0 == "*" }.count
    var subtreeEnd = lines.count
    if headingIndex + 1 < lines.count {
      for index in (headingIndex + 1)..<lines.count {
        let candidate = lines[index]
        guard candidate.range(of: #"^\*+\s+"#, options: .regularExpression) != nil else { continue }
        let level = candidate.prefix { $0 == "*" }.count
        if level <= headingLevel {
          subtreeEnd = index
          break
        }
      }
    }

    var insertAt = headingIndex + 1
    while insertAt < subtreeEnd {
      let trimmed = lines[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if trimmed.hasPrefix("SCHEDULED:") || trimmed.hasPrefix("DEADLINE:") || trimmed.hasPrefix("CLOSED:") {
        insertAt += 1
      } else {
        break
      }
    }

    var drawerStart: Int?
    var drawerEnd: Int?
    if insertAt < subtreeEnd,
       lines[insertAt].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":PROPERTIES:" {
      drawerStart = insertAt
      for index in (insertAt + 1)..<subtreeEnd {
        if lines[index].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == ":END:" {
          drawerEnd = index
          break
        }
      }
    }

    if let drawerStart, let drawerEnd {
      var end = drawerEnd
      for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
        var replaced = false
        // A branded key is updated under whichever spelling (CELORGA_ or
        // ORG2_) the drawer already uses; new properties keep the given key.
        if drawerStart + 1 < end {
          aliases: for alias in CelorgaNames.aliases(key) {
            let aliasPrefix = ":\(alias):"
            for index in (drawerStart + 1)..<end {
              if lines[index].uppercased().hasPrefix(aliasPrefix.uppercased()) {
                lines[index] = "\(aliasPrefix) \(value)"
                replaced = true
                break aliases
              }
            }
          }
        }
        if !replaced {
          lines.insert(":\(key): \(value)", at: end)
          end += 1
        }
      }
    } else {
      let drawerLines = [":PROPERTIES:"]
        + properties.sorted(by: { $0.key < $1.key }).map { ":\($0.key): \($0.value)" }
        + [":END:"]
      lines.insert(contentsOf: drawerLines, at: insertAt)
    }

    return lines.joined(separator: "\n")
  }
}
