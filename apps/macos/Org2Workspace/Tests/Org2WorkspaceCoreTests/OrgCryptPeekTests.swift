import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OrgCryptPeekTests: XCTestCase {
  private let document = """
  #+title: Notes
  * [[id:abc][Scarf ]]run command :crypt:
  :PROPERTIES:
  :ID: 1
  :END:

  -----BEGIN PGP MESSAGE-----

  abc
  def
  -----END PGP MESSAGE-----
  * Public
  Body
  """

  func testPeekTargetFromArmorLineHeadingLineAndOffsetSource() throws {
    let fromArmor = try XCTUnwrap(OrgCrypt.peekTarget(in: document, line: 9))
    XCTAssertEqual(fromArmor.headingLine, 2)
    XCTAssertEqual(fromArmor.title, "Scarf run command")
    XCTAssertEqual(fromArmor.armor, "-----BEGIN PGP MESSAGE-----\n\nabc\ndef\n-----END PGP MESSAGE-----\n")

    let fromHeading = try XCTUnwrap(OrgCrypt.peekTarget(in: document, line: 2))
    XCTAssertEqual(fromHeading, fromArmor)

    // An entry view whose text starts at file line 40.
    let offset = try XCTUnwrap(OrgCrypt.peekTarget(in: document, line: 46, baseLine: 39))
    XCTAssertEqual(offset.headingLine, 40)
    XCTAssertEqual(offset.armor, fromArmor.armor)
  }

  func testPeekTargetIsNilOutsideEncryptedSubtrees() {
    XCTAssertNil(OrgCrypt.peekTarget(in: document, line: 12))
    XCTAssertNil(OrgCrypt.peekTarget(in: document, line: 1))
    XCTAssertNil(OrgCrypt.peekTarget(in: "* Open\n-----BEGIN PGP MESSAGE-----\nabc\n", line: 2))
  }

  func testNormalizedArmorRestoresBlankLineAfterBeginAndHeaders() {
    XCTAssertEqual(
      OrgCrypt.normalizedArmorForDecrypt("-----BEGIN PGP MESSAGE-----\nabc\n-----END PGP MESSAGE-----\n"),
      "-----BEGIN PGP MESSAGE-----\n\nabc\n-----END PGP MESSAGE-----\n"
    )
    XCTAssertEqual(
      OrgCrypt.normalizedArmorForDecrypt("-----BEGIN PGP MESSAGE-----\nVersion: 1\nabc\n-----END PGP MESSAGE-----"),
      "-----BEGIN PGP MESSAGE-----\nVersion: 1\n\nabc\n-----END PGP MESSAGE-----"
    )
  }

  func testDecryptArmorReturnsPlaintextInMemoryWithoutTouchingTheFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-crypt-peek-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("secret.org")
    try document.write(to: note, atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: note)

    let argsLog = root.appendingPathComponent("args.txt")
    let stdinLog = root.appendingPathComponent("stdin.txt")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    echo "$@" > '\(argsLog.path)'
    cat > '\(stdinLog.path)'
    printf 'password: hunter2\\n'
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    let target = try XCTUnwrap(OrgCrypt.peekTarget(in: document, line: 2))
    let plaintext = try OrgCrypt.decryptArmor(
      target.armor,
      settings: OrgCryptSettings(gpgProgram: fakeGPG.path, passphrase: "pw", gpgTimeout: 5)
    )

    XCTAssertEqual(plaintext, "password: hunter2\n")
    XCTAssertEqual(try Data(contentsOf: note), before, "peeking never writes the document")
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--batch"))
    XCTAssertTrue(args.contains("--decrypt"))
    XCTAssertFalse(args.contains("--output"))
    XCTAssertEqual(try String(contentsOf: stdinLog, encoding: .utf8), target.armor)
  }

  func testDecryptArmorSurfacesGPGFailure() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-crypt-peek-fail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat > /dev/null
    echo 'gpg: decryption failed: No secret key' >&2
    exit 2
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    XCTAssertThrowsError(try OrgCrypt.decryptArmor(
      "-----BEGIN PGP MESSAGE-----\n\nabc\n-----END PGP MESSAGE-----\n",
      settings: OrgCryptSettings(gpgProgram: fakeGPG.path, passphrase: "pw", gpgTimeout: 5)
    )) { error in
      XCTAssertEqual(error as? OrgCryptError, .decryptFailed("gpg: decryption failed: No secret key"))
    }
  }

  func testDecryptArmorRoundTripsWithRealGPGWhenAvailable() throws {
    let candidates = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg"]
    guard let gpg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("gpg is not installed")
    }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-crypt-peek-gpg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Run gpg with an isolated, throwaway home so the user's agent and keys
    // are never involved.
    // The agent socket path must stay short, so the home lives in /tmp.
    let home = "/tmp/o2pk-\(UUID().uuidString.prefix(8))"
    defer {
      // gpgconf lives beside the real gpg binary, which is often behind a
      // symlink (for example /usr/local/bin/gpg -> /usr/local/MacGPG2/bin/gpg2).
      // A missing gpgconf leaves this throwaway agent running.
      let gpgconf = URL(fileURLWithPath: gpg).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("gpgconf")
      let kill = Process()
      kill.executableURL = gpgconf
      kill.arguments = ["--kill", "gpg-agent"]
      kill.environment = ["GNUPGHOME": home]
      if (try? kill.run()) != nil { kill.waitForExit(timeout: 10) }
      try? FileManager.default.removeItem(atPath: home)
    }
    let wrapper = root.appendingPathComponent("gpg-isolated.sh")
    try """
    #!/bin/sh
    export GNUPGHOME='\(home)'
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
    exec '\(gpg)' "$@"
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let settings = OrgCryptSettings(gpgProgram: wrapper.path, passphrase: "peek-test", gpgTimeout: 20, useDefaultGpgKey: false)

    let encrypted = try OrgCrypt.encryptPlaintextCryptSubtrees(
      in: "* Secret :crypt:\nthe vault code is 4512\n",
      file: root.appendingPathComponent("note.org").path,
      settings: settings
    )
    XCTAssertEqual(encrypted.encryptedCount, 1)
    let target = try XCTUnwrap(OrgCrypt.peekTarget(in: encrypted.text, line: 1))
    let plaintext = try OrgCrypt.decryptArmor(target.armor, settings: settings)
    XCTAssertEqual(plaintext.trimmingCharacters(in: .whitespacesAndNewlines), "the vault code is 4512")
  }

  @MainActor
  func testStorePeekShowsPlaintextTemporarilyAndLeavesFileEncrypted() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-crypt-peek-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("secret.org")
    try document.write(to: file, atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: file)
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat > /dev/null
    printf 'peeked secret\\n'
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    let suiteName = "org2-crypt-peek-store-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: root.appendingPathComponent("missing-runtime", isDirectory: true)),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectedEntrySource = EntrySource(
      file: file.path,
      startLine: 1,
      endLineExclusive: 14,
      text: document,
      isSubtree: false
    )

    await store.peekOrgCrypt(line: 9)

    let peek = try XCTUnwrap(store.orgCryptPeek)
    XCTAssertEqual(peek.title, "Scarf run command")
    XCTAssertEqual(peek.headingLine, 2)
    XCTAssertEqual(peek.state, .decrypted("peeked secret\n"))
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(store.selectedEntrySource?.text, document)

    store.dismissOrgCryptPeek()
    XCTAssertNil(store.orgCryptPeek)
    XCTAssertEqual(try Data(contentsOf: file), before)

    await store.peekOrgCrypt(line: 2)
    XCTAssertNotNil(store.orgCryptPeek)
    let other = root.appendingPathComponent("other.org")
    store.selectedEntrySource = EntrySource(file: other.path, startLine: 1, endLineExclusive: 2, text: "x\n", isSubtree: false)
    XCTAssertNil(store.orgCryptPeek, "switching documents drops peeked plaintext")
  }
}
