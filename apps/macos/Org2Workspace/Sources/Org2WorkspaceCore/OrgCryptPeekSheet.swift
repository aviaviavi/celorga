import AppKit
import SwiftUI

/// Temporary, read-only view of a decrypted subtree. The plaintext exists only
/// in `WorkspaceStore.orgCryptPeek`; closing the sheet drops it, and the file
/// keeps its ciphertext, so nothing ever needs to be re-encrypted.
struct OrgCryptPeekSheet: View {
  @Environment(WorkspaceStore.self) private var store
  let peek: OrgCryptPeek
  @State private var didCopy = false

  /// Read live state from the store: the sheet item keeps its identity while
  /// gpg runs, so `peek` alone could show a stale "Decrypting…" state.
  private var current: OrgCryptPeek {
    if let live = store.orgCryptPeek, live.id == peek.id { return live }
    return peek
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      content
      footer
    }
    .padding(20)
    .frame(minWidth: 520, idealWidth: 620, maxWidth: 900, minHeight: 240, idealHeight: 380)
    // Losing the window (another app, screen lock) closes the peek too.
    .onExitCommand { store.dismissOrgCryptPeek() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
      store.dismissOrgCryptPeek()
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      WorkspaceIconBadge(systemImage: "lock.open.fill", tint: .accentColor, fill: Color.accentColor.opacity(0.10))
      VStack(alignment: .leading, spacing: 3) {
        Text(peek.title)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
        Text("Viewing only. The file stays encrypted, and this closes without saving anything.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch current.state {
    case .decrypting:
      VStack(spacing: 10) {
        ProgressView()
        Text("Decrypting…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .decrypted(let plaintext):
      ScrollView {
        Text(displayText(plaintext))
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(12)
      }
      .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )
      .accessibilityLabel("Decrypted text")
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label("Could not decrypt", systemImage: "exclamationmark.triangle")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.red)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("Decrypt in File to Edit") {
        Task { await store.decryptPeekedSubtreeInFile() }
      }
      .help("Replace the ciphertext in the file with plaintext so you can edit it. It is re-encrypted on save.")
      .disabled(isDecrypting || store.selectedEntrySource?.isEditable == false)

      Spacer(minLength: 0)

      if case .decrypted(let plaintext) = current.state {
        Button(didCopy ? "Copied" : "Copy") {
          Self.copyConcealed(plaintext)
          didCopy = true
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help("Copy the decrypted text. Marked as concealed so clipboard history tools skip it.")
      }

      Button("Done") {
        store.dismissOrgCryptPeek()
      }
      .keyboardShortcut(.defaultAction)
    }
  }

  private var isDecrypting: Bool {
    if case .decrypting = current.state { return true }
    return false
  }

  private func displayText(_ plaintext: String) -> String {
    var text = plaintext
    while text.hasSuffix("\n") { text.removeLast() }
    return text.isEmpty ? " " : text
  }

  static func copyConcealed(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    // nspasteboard.org convention: clipboard managers do not record these.
    item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pasteboard.writeObjects([item])
  }
}
