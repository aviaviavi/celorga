import Foundation
import LocalAuthentication
import Security

public enum OrgCryptAction: String, CaseIterable, Sendable {
  case decrypt
  case encrypt
  case reencrypt

  public var title: String {
    switch self {
    case .decrypt: "Decrypt"
    case .encrypt: "Encrypt"
    case .reencrypt: "Re-encrypt"
    }
  }
}

/// A temporary, in-memory view of one decrypted subtree. Never persisted.
public struct OrgCryptPeek: Identifiable, Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case decrypting
    case decrypted(String)
    case failed(String)
  }

  public let id: UUID
  public let file: String
  public let headingLine: Int
  public let title: String
  public var state: State

  public init(id: UUID = UUID(), file: String, headingLine: Int, title: String, state: State) {
    self.id = id
    self.file = file
    self.headingLine = headingLine
    self.title = title
    self.state = state
  }
}

public struct OrgCryptRunResult: Equatable, Sendable {
  public let succeeded: Bool
  public let changed: Bool
  public let headingLine: Int?
  public let message: String

  public static func success(changed: Bool, headingLine: Int?, message: String) -> OrgCryptRunResult {
    OrgCryptRunResult(succeeded: true, changed: changed, headingLine: headingLine, message: message)
  }

  public static func failure(message: String, headingLine: Int? = nil) -> OrgCryptRunResult {
    OrgCryptRunResult(succeeded: false, changed: false, headingLine: headingLine, message: message)
  }
}

public struct OrgCryptSettings: Equatable, Sendable {
  public var encryptOnSave: Bool
  public var recipients: [String]
  public var recipientFiles: [String]
  public var gpgProgram: String
  public var passphrase: String?
  public var gpgTimeout: TimeInterval
  public var useDefaultGpgKey: Bool

  public init(
    encryptOnSave: Bool = true,
    recipients: [String] = [],
    recipientFiles: [String] = [],
    gpgProgram: String = "gpg",
    passphrase: String? = nil,
    gpgTimeout: TimeInterval = 30,
    useDefaultGpgKey: Bool = true
  ) {
    self.encryptOnSave = encryptOnSave
    self.recipients = recipients
    self.recipientFiles = recipientFiles
    self.gpgProgram = gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpg" : gpgProgram
    self.passphrase = passphrase?.isEmpty == false ? passphrase : nil
    self.gpgTimeout = max(0.1, gpgTimeout)
    self.useDefaultGpgKey = useDefaultGpgKey
  }

  public var canEncryptWithoutSubtreeProperties: Bool {
    passphrase != nil || useDefaultGpgKey || !recipients.isEmpty || !recipientFiles.isEmpty
  }

  public static func splitListText(_ raw: String) -> [String] {
    raw
      .split { character in
        character == "," || character == "\n"
      }
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  public static func listText(_ values: [String]) -> String {
    values.joined(separator: "\n")
  }
}

public enum OrgCrypt {
  public struct PlaintextTarget: Equatable, Sendable {
    public let headingLine: Int
    public let bodyStartLine: Int
    public let endLine: Int
    public let recipients: [String]
    public let recipientFiles: [String]
  }

  public struct PGPArmorSummary: Equatable, Sendable {
    public let lineCount: Int
    public let payloadLineCount: Int
    public let byteCount: Int
  }

  public struct EncryptionResult: Equatable, Sendable {
    public let text: String
    public let encryptedCount: Int
  }

  /// An armored block located for read-only viewing ("peek").
  public struct PeekTarget: Equatable, Sendable {
    /// 1-based line of the owning heading, or of the armor itself when the
    /// block sits above the first heading.
    public let headingLine: Int
    public let title: String
    public let armor: String
  }

  /// Locates the armored PGP block that a click or command at `line` refers
  /// to. A line inside an armored block selects that block; otherwise the
  /// first block in the subtree of the nearest heading at or above `line` is
  /// used, matching `celorga crypt decrypt --line`.
  public static func peekTarget(in text: String, line: Int, baseLine: Int = 1) -> PeekTarget? {
    let lines = normalizedLines(text)
    guard !lines.isEmpty else { return nil }
    let index = min(max(line - baseLine, 0), lines.count - 1)

    let headingIndex = (0...index).reversed().first { lineIsHeading(lines[$0]) }
    let title = headingIndex.map { headingTitle(lines[$0]) } ?? "Encrypted text"

    if let block = enclosingPGPBlock(lines: lines, index: index) {
      return PeekTarget(
        headingLine: (headingIndex ?? block.lowerBound) + baseLine,
        title: title,
        armor: lines[block].joined(separator: "\n") + "\n"
      )
    }

    guard let headingIndex else { return nil }
    let endLine = subtreeEndLine(lines: lines, headingLine: headingIndex)
    var start: Int?
    for candidate in (headingIndex + 1)..<max(headingIndex + 1, endLine) {
      if start == nil, isPGPBegin(lines[candidate]) {
        start = candidate
      } else if let begin = start, isPGPEnd(lines[candidate]) {
        return PeekTarget(
          headingLine: headingIndex + baseLine,
          title: title,
          armor: lines[begin...candidate].joined(separator: "\n") + "\n"
        )
      }
    }
    return nil
  }

  /// Decrypts armored text entirely in memory. The plaintext is never written
  /// to disk or to the document; callers own its lifetime.
  public static func decryptArmor(_ armor: String, settings: OrgCryptSettings) throws -> String {
    var arguments = [settings.gpgProgram, "--yes", "--trust-model", "always"]
    if let passphrase = settings.passphrase {
      arguments = [settings.gpgProgram, "--batch", "--yes", "--trust-model", "always", "--pinentry-mode", "loopback", "--passphrase", passphrase]
    }
    arguments.append("--decrypt")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.environment = Org2CLI.processEnvironment()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    let outputCapture = PipeCapture()
    let errorCapture = PipeCapture()
    let readers = DispatchGroup()
    for (handle, capture) in [(stdout.fileHandleForReading, outputCapture), (stderr.fileHandleForReading, errorCapture)] {
      readers.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        capture.set(handle.readDataToEndOfFile())
        readers.leave()
      }
    }

    do {
      try process.run()
    } catch {
      throw OrgCryptError.decryptFailed(error.localizedDescription)
    }
    let input = Data(normalizedArmorForDecrypt(armor).utf8)
    DispatchQueue.global(qos: .userInitiated).async {
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
    }

    // Without a stored passphrase gpg-agent may show pinentry; give the user
    // time to type it.
    let timeout = settings.passphrase == nil ? max(settings.gpgTimeout, 120) : settings.gpgTimeout
    if finished.wait(timeout: .now() + .milliseconds(Int(timeout * 1000))) == .timedOut {
      if process.isRunning { process.terminate() }
      _ = finished.wait(timeout: .now() + .seconds(2))
      _ = readers.wait(timeout: .now() + .seconds(2))
      throw OrgCryptError.decryptTimedOut(timeout)
    }
    _ = readers.wait(timeout: .now() + .seconds(5))

    let output = outputCapture.data
    let errorOutput = errorCapture.data
    guard process.terminationStatus == 0 else {
      let message = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw OrgCryptError.decryptFailed(message.isEmpty ? "gpg exited with status \(process.terminationStatus)" : message)
    }
    return String(decoding: output, as: UTF8.self)
  }

  /// Mirrors `normalizePgpArmorForDecrypt` in src/pgp.ts: Org formatting can
  /// drop the blank line gpg requires after the BEGIN line and armor headers.
  static func normalizedArmorForDecrypt(_ raw: String) -> String {
    let lines = normalizedLines(raw)
    var output: [String] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      output.append(line)
      index += 1
      guard isPGPBegin(line) else { continue }
      let next = index < lines.count ? lines[index] : ""
      if next.trimmingCharacters(in: .whitespaces).isEmpty || isPGPEnd(next) { continue }
      if isArmorHeader(next) {
        var cursor = index
        while cursor < lines.count, isArmorHeader(lines[cursor]) {
          output.append(lines[cursor])
          cursor += 1
        }
        index = cursor
        if cursor < lines.count, !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
          output.append("")
        }
        continue
      }
      output.append("")
    }
    return output.joined(separator: "\n")
  }

  private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var data: Data {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }

    func set(_ data: Data) {
      lock.lock()
      stored = data
      lock.unlock()
    }
  }

  private static func isArmorHeader(_ line: String) -> Bool {
    line.range(of: #"^[A-Za-z0-9-]+:\s*"#, options: .regularExpression) != nil
  }

  private static func enclosingPGPBlock(lines: [String], index: Int) -> ClosedRange<Int>? {
    var begin: Int?
    for candidate in stride(from: index, through: 0, by: -1) {
      if isPGPBegin(lines[candidate]) { begin = candidate; break }
      if candidate != index, isPGPEnd(lines[candidate]) || lineIsHeading(lines[candidate]) { return nil }
      if candidate == index, lineIsHeading(lines[candidate]) { return nil }
    }
    guard let begin else { return nil }
    for candidate in max(begin + 1, index)..<lines.count {
      if isPGPEnd(lines[candidate]) { return begin...candidate }
      if lineIsHeading(lines[candidate]) { return nil }
    }
    return nil
  }

  private static func headingTitle(_ line: String) -> String {
    var title = line.replacingOccurrences(of: #"^\*+\s+"#, with: "", options: .regularExpression)
    title = title.replacingOccurrences(of: #"\s+:[\w@#%:]+:\s*$"#, with: "", options: .regularExpression)
    title = title.replacingOccurrences(of: #"\[\[[^\]]*\]\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
    title = title.replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Encrypted subtree" : trimmed
  }

  public static func findPlaintextCryptSubtrees(in text: String, file: String? = nil) -> [PlaintextTarget] {
    let lines = normalizedLines(text)
    var targets: [PlaintextTarget] = []

    var index = 0
    while index < lines.count {
      guard headingHasCryptTag(lines[index]) else {
        index += 1
        continue
      }

      let endLine = subtreeEndLine(lines: lines, headingLine: index)
      let bodyStart = encryptedBodyStartLine(lines: lines, headingLine: index, endLine: endLine)
      defer {
        index = max(index + 1, endLine)
      }

      guard !subtreeContainsPGPBlock(lines: lines, startLine: bodyStart, endLine: endLine) else {
        continue
      }

      let plainBody = lines[bodyStart..<endLine].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !plainBody.isEmpty else { continue }

      let properties = cryptProperties(lines: lines, headingLine: index, endLine: endLine, file: file)
      targets.append(PlaintextTarget(
        headingLine: index + 1,
        bodyStartLine: bodyStart,
        endLine: endLine,
        recipients: properties.recipients,
        recipientFiles: properties.recipientFiles
      ))
    }

    return targets
  }

  public static func hasUnclosedPGPBlock(_ text: String) -> Bool {
    var inBlock = false
    for line in normalizedLines(text) {
      if isPGPBegin(line) { inBlock = true }
      if isPGPEnd(line) { inBlock = false }
    }
    return inBlock
  }

  public static func armorSummary(_ raw: String) -> PGPArmorSummary? {
    let lines = normalizedLines(raw).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard let first = lines.first,
          let last = lines.last,
          isPGPBegin(first),
          isPGPEnd(last)
    else {
      return nil
    }

    return PGPArmorSummary(
      lineCount: lines.count,
      payloadLineCount: max(0, lines.count - 2),
      byteCount: Data(raw.utf8).count
    )
  }

  public static func encryptPlaintextCryptSubtrees(
    in text: String,
    file: String,
    settings: OrgCryptSettings
  ) throws -> EncryptionResult {
    guard settings.encryptOnSave else {
      return EncryptionResult(text: text, encryptedCount: 0)
    }
    guard !hasUnclosedPGPBlock(text) else {
      return EncryptionResult(text: text, encryptedCount: 0)
    }

    let targets = findPlaintextCryptSubtrees(in: text, file: file)
    guard !targets.isEmpty else {
      return EncryptionResult(text: text, encryptedCount: 0)
    }

    var replacements: [LineReplacement] = []
    let lines = normalizedLines(text)
    let cwd = URL(fileURLWithPath: file).deletingLastPathComponent()

    for target in targets {
      let recipients = unique(settings.recipients + target.recipients)
      let recipientFiles = unique(settings.recipientFiles + target.recipientFiles)
      let targetSettings = OrgCryptSettings(
        encryptOnSave: settings.encryptOnSave,
        recipients: recipients,
        recipientFiles: recipientFiles,
        gpgProgram: settings.gpgProgram,
        passphrase: settings.passphrase,
        gpgTimeout: settings.gpgTimeout,
        useDefaultGpgKey: settings.useDefaultGpgKey
      )
      guard targetSettings.canEncryptWithoutSubtreeProperties else {
        throw OrgCryptError.missingEncryptionConfiguration
      }

      let plainBody = lines[target.bodyStartLine..<target.endLine].joined(separator: "\n") + "\n"
      let encrypted = try runGPGEncrypt(plainBody, cwd: cwd, settings: targetSettings)
      replacements.append(LineReplacement(startLine: target.bodyStartLine, endLine: target.endLine, text: encrypted))
    }

    return EncryptionResult(text: replaceLineRanges(in: text, replacements: replacements), encryptedCount: replacements.count)
  }

  private struct LineReplacement {
    let startLine: Int
    let endLine: Int
    let text: String
  }

  private static func runGPGEncrypt(_ input: String, cwd: URL, settings: OrgCryptSettings) throws -> String {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("org2-crypt-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempDirectory) }

    let inputURL = tempDirectory.appendingPathComponent("input.txt")
    let outputURL = tempDirectory.appendingPathComponent("output.asc")
    let errorURL = tempDirectory.appendingPathComponent("stderr.txt")
    try Data(input.utf8).write(to: inputURL)
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)

    let stdin = try FileHandle(forReadingFrom: inputURL)
    let stdout = try FileHandle(forWritingTo: outputURL)
    let stderr = try FileHandle(forWritingTo: errorURL)
    defer {
      stdin.closeFile()
      stdout.closeFile()
      stderr.closeFile()
    }

    let process = Process()
    process.currentDirectoryURL = cwd
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

    let defaultRecipient = settings.useDefaultGpgKey ? resolveDefaultGPGRecipient(gpgProgram: settings.gpgProgram) : nil
    if settings.useDefaultGpgKey,
       defaultRecipient == nil,
       settings.recipients.isEmpty,
       settings.recipientFiles.isEmpty {
      throw OrgCryptError.gpgFailed("GPG default key is not configured as an encryption recipient.")
    }

    var arguments = [settings.gpgProgram, "--batch", "--yes", "--pinentry-mode", "loopback", "--trust-model", "always"]
    if let passphrase = settings.passphrase {
      arguments += ["--passphrase", passphrase]
    }

    if defaultRecipient != nil || !settings.recipients.isEmpty || !settings.recipientFiles.isEmpty {
      arguments += ["--armor", "--encrypt"]
      if let defaultRecipient {
        arguments += ["--recipient", defaultRecipient]
      }
      for recipient in settings.recipients {
        arguments += ["--recipient", recipient]
      }
      for recipientFile in settings.recipientFiles {
        arguments += ["--recipient-file", recipientFile]
      }
    } else {
      arguments += ["--armor", "--symmetric", "--cipher-algo", "AES256"]
    }
    process.arguments = arguments

    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
      semaphore.signal()
    }
    try process.run()

    if semaphore.wait(timeout: .now() + .milliseconds(Int(settings.gpgTimeout * 1000))) == .timedOut {
      if process.isRunning {
        process.terminate()
      }
      _ = semaphore.wait(timeout: .now() + .seconds(2))
      throw OrgCryptError.gpgTimedOut(settings.gpgTimeout, readTrimmedFile(errorURL))
    }

    guard process.terminationStatus == 0 else {
      let message = readTrimmedFile(errorURL)
      throw OrgCryptError.gpgFailed(message?.isEmpty == false ? message! : "gpg exited with status \(process.terminationStatus)")
    }

    return (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
  }

  private static func resolveDefaultGPGRecipient(gpgProgram: String) -> String? {
    for candidate in gpgConfCandidates(gpgProgram: gpgProgram) {
      guard let output = runGPGConf(candidate) else { continue }
      for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        guard line.hasPrefix("default-key:") else { continue }
        let fields = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 9 else { continue }
        let value = fields[9]
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        if !value.isEmpty {
          return value
        }
      }
    }
    return nil
  }

  private static func gpgConfCandidates(gpgProgram: String) -> [String] {
    var candidates: [String] = []
    let trimmed = gpgProgram.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed.contains("/") {
      let url = URL(fileURLWithPath: trimmed)
      candidates.append(url.deletingLastPathComponent().appendingPathComponent("gpgconf").path)
    }
    candidates.append(contentsOf: [
      "/opt/homebrew/bin/gpgconf",
      "/usr/local/bin/gpgconf",
      "/usr/local/MacGPG2/bin/gpgconf",
      "gpgconf"
    ])
    return unique(candidates)
  }

  private static func runGPGConf(_ candidate: String) -> String? {
    let output = Pipe()
    let error = Pipe()
    let process = Process()
    if candidate.contains("/") {
      process.executableURL = URL(fileURLWithPath: candidate)
      process.arguments = ["--list-options", "gpg"]
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [candidate, "--list-options", "gpg"]
    }
    process.standardOutput = output
    process.standardError = error

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  }

  private static func readTrimmedFile(_ url: URL) -> String? {
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replaceLineRanges(in text: String, replacements: [LineReplacement]) -> String {
    let hadTrailingNewline = text.hasSuffix("\n")
    var lines = normalizedLines(text)

    for replacement in replacements.sorted(by: { $0.startLine > $1.startLine }) {
      var newLines = replacement.text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingTrailingNewline()
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      if newLines == [""] {
        newLines = []
      }
      lines.replaceSubrange(replacement.startLine..<replacement.endLine, with: newLines)
    }

    let joined = lines.joined(separator: "\n")
    return hadTrailingNewline && !joined.hasSuffix("\n") ? joined + "\n" : joined
  }

  private static func cryptProperties(
    lines: [String],
    headingLine: Int,
    endLine: Int,
    file: String?
  ) -> (recipients: [String], recipientFiles: [String]) {
    var recipients: [String] = []
    var recipientFiles: [String] = []
    var inDrawer = false
    for index in (headingLine + 1)..<endLine {
      let line = lines[index]
      if !inDrawer {
        if line.range(of: #"^\s*:PROPERTIES:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
          inDrawer = true
        } else if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          break
        }
        continue
      }
      if line.range(of: #"^\s*:END:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
        break
      }
      guard let match = line.firstMatch(of: /^\s*:([^:]+):\s*(.*?)\s*$/) else { continue }
      let key = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "_")
      let values = OrgCryptSettings.splitListText(String(match.2))
      if key == "CRYPT_RECIPIENT" || key == "CRYPT_RECIPIENTS" {
        recipients.append(contentsOf: values)
      } else if key == "CRYPT_RECIPIENT_FILE" || key == "CRYPT_RECIPIENT_FILES" {
        recipientFiles.append(contentsOf: values.map { value in
          guard let file, !NSString(string: value).isAbsolutePath else { return value }
          return URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(value).standardizedFileURL.path
        })
      }
    }
    return (unique(recipients), unique(recipientFiles))
  }

  private static func headingHasCryptTag(_ line: String) -> Bool {
    guard let match = line.firstMatch(of: /^(\*+)\s+(.*)$/) else { return false }
    return String(match.2).range(of: #"(?:^|:)crypt(?::|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private static func lineIsHeading(_ line: String) -> Bool {
    line.firstMatch(of: /^(\*+)\s+/) != nil
  }

  private static func headingLevel(_ line: String) -> Int {
    guard let match = line.firstMatch(of: /^(\*+)\s+/) else { return 0 }
    return match.1.count
  }

  private static func subtreeEndLine(lines: [String], headingLine: Int) -> Int {
    let level = headingLevel(lines[headingLine])
    guard level > 0 else { return headingLine + 1 }
    for index in (headingLine + 1)..<lines.count {
      if lineIsHeading(lines[index]) && headingLevel(lines[index]) <= level {
        return index
      }
    }
    return lines.count
  }

  private static func encryptedBodyStartLine(lines: [String], headingLine: Int, endLine: Int) -> Int {
    let bodyStart = headingLine + 1
    guard bodyStart < endLine else { return bodyStart }
    if lines[bodyStart].range(of: #"^\s*:PROPERTIES:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      for index in (bodyStart + 1)..<endLine {
        if lines[index].range(of: #"^\s*:END:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
          return index + 1
        }
      }
    }
    return bodyStart
  }

  private static func subtreeContainsPGPBlock(lines: [String], startLine: Int, endLine: Int) -> Bool {
    guard startLine < endLine else { return false }
    for index in startLine..<endLine where isPGPBegin(lines[index]) {
      return true
    }
    return false
  }

  private static func isPGPBegin(_ line: String) -> Bool {
    line.range(of: #"^\s*-----BEGIN PGP MESSAGE-----\s*$"#, options: .regularExpression) != nil
  }

  private static func isPGPEnd(_ line: String) -> Bool {
    line.range(of: #"^\s*-----END PGP MESSAGE-----\s*$"#, options: .regularExpression) != nil
  }

  private static func normalizedLines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var output: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
      seen.insert(trimmed)
      output.append(trimmed)
    }
    return output
  }
}

public enum OrgCryptError: LocalizedError, Equatable {
  case missingEncryptionConfiguration
  case gpgFailed(String)
  case gpgTimedOut(TimeInterval, String?)
  case decryptFailed(String)
  case decryptTimedOut(TimeInterval)

  public var errorDescription: String? {
    switch self {
    case .decryptFailed(let message):
      "Decryption failed: \(message)"
    case .decryptTimedOut(let timeout):
      "Decryption timed out after \(Int(timeout)) seconds."
    case .missingEncryptionConfiguration:
      "Encryption needs a passphrase, the default GPG key option, configured recipients, recipient files, or CRYPT_RECIPIENT properties."
    case .gpgFailed(let message):
      "Encryption failed: \(message)"
    case .gpgTimedOut(let timeout, let message):
      if let message, !message.isEmpty {
        "Encryption timed out after \(Int(timeout)) seconds: \(message)"
      } else {
        "Encryption timed out after \(Int(timeout)) seconds."
      }
    }
  }
}

public enum OrgCryptPublicKeyImportError: LocalizedError, Equatable {
  case missingCorpusRoot
  case invalidSource

  public var errorDescription: String? {
    switch self {
    case .missingCorpusRoot:
      "Choose a corpus before adding an agent public key."
    case .invalidSource:
      "Choose a public key file to add."
    }
  }
}

public enum OrgCryptKeychain {
  public static let service = "Org2Workspace.OrgCrypt"
  public static let account = "passphrase"

  public static func containsPassphrase() -> Bool {
    var query: [String: Any] = baseQuery
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess
  }

  public static func readPassphrase(allowUserInteraction: Bool = false) -> String? {
    var query: [String: Any] = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    if !allowUserInteraction {
      query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    }

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let passphrase = String(data: data, encoding: .utf8),
          !passphrase.isEmpty
    else {
      return nil
    }
    return passphrase
  }

  public static func savePassphrase(_ passphrase: String) throws {
    let data = Data(passphrase.utf8)
    var query = baseQuery
    query[kSecValueData as String] = data
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem {
      var updateQuery = baseQuery
      updateQuery[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updateStatus == errSecSuccess else { throw OrgCryptKeychainError.status(updateStatus) }
      return
    }
    guard status == errSecSuccess else { throw OrgCryptKeychainError.status(status) }
  }

  public static func deletePassphrase() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw OrgCryptKeychainError.status(status)
    }
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }

  private static func noninteractiveAuthenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }
}

public enum OrgCryptKeychainError: LocalizedError, Equatable {
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .status(let status):
      "Encryption keychain operation failed with status \(status)."
    }
  }
}

private extension String {
  func trimmingTrailingNewline() -> String {
    if hasSuffix("\n") {
      return String(dropLast())
    }
    return self
  }
}
