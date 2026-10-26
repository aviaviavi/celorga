import Foundation

/// Removes well-known credential shapes from text before it leaves this Mac
/// on a shared thread page.
///
/// The rules are deliberately narrow: each matches a documented token prefix
/// or an explicit credential context, so ordinary prose, UUIDs, and hex hashes
/// pass through unchanged. Redaction is best effort; the owner still reviews
/// what they share.
enum AIChatSecretRedactor {
  static let marker = "[redacted secret]"
  static let encryptedMessageMarker = "[encrypted PGP message]"

  private struct Rule {
    let expression: NSRegularExpression
    let template: String
  }

  private static func rule(_ pattern: String, keepingPrefix: Bool = false, replacement: String = marker) -> Rule {
    let escaped = NSRegularExpression.escapedTemplate(for: replacement)
    return Rule(
      // The patterns are constants covered by tests.
      expression: try! NSRegularExpression(pattern: pattern),
      template: keepingPrefix ? "$1" + escaped : escaped
    )
  }

  /// Applied in order. Block rules run first so their bodies are not split
  /// by the token rules.
  private static let rules: [Rule] = [
    // PEM, OpenSSH, and PGP private keys. An unterminated block is redacted
    // through the end of the text.
    rule(
      #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|\z)"#
    ),
    // Encrypted PGP messages are not secrets, but their armor is noise.
    rule(
      #"-----BEGIN PGP MESSAGE-----[\s\S]*?(?:-----END PGP MESSAGE-----|\z)"#,
      replacement: encryptedMessageMarker
    ),
    // Authorization header values, including JSON and assignment forms.
    rule(
      #"(?i)(\bauthorization["']?\s*[:=]\s*["']?(?:bearer|basic|token)\s+)[A-Za-z0-9\-._~+/]+=*"#,
      keepingPrefix: true
    ),
    // Other bearer tokens; requiring a digit keeps phrases such as
    // "Bearer authentication" intact.
    rule(#"\b(Bearer\s+)(?=[A-Za-z0-9\-._~+/]*[0-9])[A-Za-z0-9\-._~+/]{16,}=*"#, keepingPrefix: true),
    // JSON Web Tokens.
    rule(#"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#),
    // OpenAI, Anthropic, DeepSeek, and similar `sk-` API keys.
    rule(#"(?<![A-Za-z0-9_-])sk-(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{32,}"#),
    // Stripe-style secret and restricted keys.
    rule(#"(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
    // GitHub personal, OAuth, user, server, and refresh tokens.
    rule(#"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{30,}"#),
    rule(#"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{30,}"#),
    // AWS access key IDs and secret access key assignments.
    rule(#"(?<![A-Z0-9])(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}(?![A-Z0-9])"#),
    rule(#"(?i)(\baws_secret_access_key["']?\s*[:=]\s*["']?)[A-Za-z0-9/+=]{40}"#, keepingPrefix: true),
    // Slack bot, user, and app tokens.
    rule(#"(?<![A-Za-z0-9])xox[abeprs]-[A-Za-z0-9-]{10,}"#),
    rule(#"(?<![A-Za-z0-9])xapp-[0-9]-[A-Za-z0-9-]{10,}"#),
    // Google API keys.
    rule(#"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])"#),
  ]

  static func redacted(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var result = text
    for rule in rules {
      result = rule.expression.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: rule.template
      )
    }
    return result
  }
}
