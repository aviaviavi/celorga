import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Fixture tokens are assembled from obviously fake parts so no complete
/// credential-shaped literal appears in source.
final class AIChatSecretRedactionTests: XCTestCase {
  private let marker = AIChatSecretRedactor.marker

  private func fake(_ prefix: String, _ unit: String, count: Int) -> String {
    prefix + String(repeating: unit, count: count)
  }

  func testRedactsKnownTokenShapesAndKeepsSurroundingText() {
    let cases: [(String, String)] = [
      ("OpenAI-style key", fake("sk-", "Fak3", count: 12)),
      ("OpenAI project key", fake("sk-" + "proj-", "x9Yz", count: 12)),
      ("Anthropic-style key", fake("sk-" + "ant-" + "api03-", "Fak3K3y_", count: 10)),
      ("DeepSeek-style key", fake("sk-", "0a1b", count: 8)),
      ("GitHub personal token", fake("gh" + "p_", "Ab1C", count: 9)),
      ("GitHub OAuth token", fake("gh" + "o_", "Zz9y", count: 9)),
      ("GitHub fine-grained token", fake("github" + "_pat_", "11AB_cd", count: 6)),
      ("AWS access key ID", "AK" + "IA" + "IOSFODNN7EXAMPLE"),
      ("AWS session key ID", "AS" + "IA" + "ZZZZEXAMPLE12345"),
      ("Slack bot token", "xo" + "xb-" + "123456789012-1234567890123-" + String(repeating: "FakeTok", count: 3)),
      ("Slack app token", "xa" + "pp-" + "1-A0FAKE-1234567890-" + String(repeating: "ab12", count: 4)),
      ("Google API key", "AI" + "za" + String(repeating: "Fa1k", count: 8) + "e_-"),
      ("Stripe secret key", fake("sk" + "_live_", "Fak3", count: 6)),
      (
        "JWT",
        "ey" + "JhbGciOiJIUzI1NiJ9" + "." + "ey" + "JzdWIiOiJkYW5hIn0" + "." + "c2lnbmF0dXJlLWZha2U"
      ),
    ]
    for (name, secret) in cases {
      let input = "Use \(secret) for the staging deploy."
      let output = AIChatSecretRedactor.redacted(input)
      XCTAssertEqual(output, "Use \(marker) for the staging deploy.", name)
    }
  }

  func testRedactsCredentialContextsButKeepsTheirLabels() {
    let token = fake("", "Fak3T0k", count: 4)
    XCTAssertEqual(
      AIChatSecretRedactor.redacted("Authorization: Bearer \(token)"),
      "Authorization: Bearer \(marker)"
    )
    XCTAssertEqual(
      AIChatSecretRedactor.redacted(#"{"Authorization": "Basic \#(token)=="}"#),
      #"{"Authorization": "Basic \#(marker)"}"#
    )
    XCTAssertEqual(
      AIChatSecretRedactor.redacted("curl -H 'X-Api: 1' -H \"Bearer \(token)\""),
      "curl -H 'X-Api: 1' -H \"Bearer \(marker)\""
    )
    let awsSecret = String(repeating: "wJalrFakeK", count: 4)
    XCTAssertEqual(
      AIChatSecretRedactor.redacted("aws_secret_access_key = \(awsSecret)"),
      "aws_secret_access_key = \(marker)"
    )
  }

  func testRedactsPrivateKeyBlocksAndCollapsesEncryptedMessages() {
    let begin = "-----BEGIN "
    let end = "-----END "
    let pem = "\(begin)RSA PRIVATE KEY-----\nMIIFAKEFAKEFAKE\nAAAAfake==\n\(end)RSA PRIVATE KEY-----"
    XCTAssertEqual(AIChatSecretRedactor.redacted("Key:\n\(pem)\nDone."), "Key:\n\(marker)\nDone.")

    let openSSH = "\(begin)OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEFAKE\n\(end)OPENSSH PRIVATE KEY-----"
    XCTAssertEqual(AIChatSecretRedactor.redacted(openSSH), marker)

    let pgpKey = "\(begin)PGP PRIVATE KEY BLOCK-----\n\nlQOYBFAKE\n=abcd\n\(end)PGP PRIVATE KEY BLOCK-----"
    XCTAssertEqual(AIChatSecretRedactor.redacted("a \(pgpKey) b"), "a \(marker) b")

    // A pasted key cut off before its footer is still removed.
    let truncated = "Here:\n\(begin)PRIVATE KEY-----\nMIIEvFAKE"
    XCTAssertEqual(AIChatSecretRedactor.redacted(truncated), "Here:\n\(marker)")

    let message = "\(begin)PGP MESSAGE-----\n\nhQEMAFAKE\n=wxyz\n\(end)PGP MESSAGE-----"
    XCTAssertEqual(
      AIChatSecretRedactor.redacted("Encrypted: \(message)"),
      "Encrypted: \(AIChatSecretRedactor.encryptedMessageMarker)"
    )
  }

  func testLeavesOrdinaryTextIdentifiersAndHashesUnchanged() {
    let begin = "-----BEGIN "
    let samples = [
      "Ask-me-anything sessions start at 10. Use sk-learn for the baseline.",
      "The risk-adjusted plan: task-0123456789abcdefghijklmnopqrstuv stays open.",
      "Thread 123e4567-e89b-12d3-a456-426614174000 links to run 9f86d081-884c-7d65-9a2f-eaa0c55ad015.",
      "Commit 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b fixed it.",
      "SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "Bearer tokens expire after an hour; use Bearer authentication over TLS.",
      "Send Authorization: Bearer <token> or Authorization: Bearer $TOKEN.",
      "The AKIA prefix marks AWS access keys; AKIAshort is not one.",
      "Prefixes such as ghp_ and github_pat_ identify GitHub tokens.",
      "Hugs xoxo-love and xoxb-short.",
      "AIza alone is not a key.",
      "The header starts with eyJ but this is prose.",
      "\(begin)PUBLIC KEY-----\nMIIBFAKE\n-----END PUBLIC KEY-----",
      "\(begin)CERTIFICATE-----\nMIIDFAKE\n-----END CERTIFICATE-----",
      "pk_live_ keys are publishable. Use [redacted secret] as the marker.",
      "Version v1.2.3-beta+build.42, path notes/2026/plan.org, email dana@example.com.",
    ]
    for sample in samples {
      XCTAssertEqual(AIChatSecretRedactor.redacted(sample), sample)
    }
  }

  func testRedactionIsDeterministicAndIdempotent() {
    let input = "Keys: \(fake("sk-", "Fak3", count: 12)) and \(fake("gh" + "p_", "Ab1C", count: 9))"
    let once = AIChatSecretRedactor.redacted(input)
    XCTAssertEqual(once, "Keys: \(marker) and \(marker)")
    XCTAssertEqual(AIChatSecretRedactor.redacted(once), once)
    XCTAssertEqual(AIChatSecretRedactor.redacted(input), once)
  }

  func testPublishedMessagesAndPageCarryNoKnownSecrets() {
    let key = fake("sk-", "Fak3", count: 12)
    let token = fake("gh" + "p_", "Ab1C", count: 9)
    let messages = [
      AIChatMessage(role: .user, content: "Deploy with \(key) please."),
      AIChatMessage(role: .assistant, content: "Rotated \(token) as well.", authorLabel: "Assistant"),
    ]

    let published = AIChatThreadPublicationSnapshot.publishableMessages(messages, userName: "Dana")

    XCTAssertEqual(published.count, 2)
    XCTAssertTrue(published[0].text.contains(marker))
    XCTAssertTrue(published[1].text.contains(marker))
    let snapshot = AIChatThreadPublicationSnapshot(
      threadID: UUID(),
      title: "Launch",
      messages: published,
      respondingStatus: nil,
      appearanceMode: .system,
      lightTheme: WorkspaceThemeCatalog.theme(id: nil, for: .light),
      darkTheme: WorkspaceThemeCatalog.theme(id: nil, for: .dark)
    )
    let html = AIChatThreadPublicationPage.html(snapshot: snapshot, bodies: [:], rendererStylesheet: nil)
    XCTAssertFalse(html.contains(key))
    XCTAssertFalse(html.contains(token))
  }
}
