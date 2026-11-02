import Foundation

// The phone keeps no corpus: a capture is an Org entry queued on the phone
// until the paired host stores it. The host accepts exactly one top-level
// entry that carries its own `:ID: mobile-ENTRY_ID` property.

func check(_ condition: Bool, _ message: String) {
  if !condition {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

func hostAccepts(_ item: MobileCaptureOutbox.Item) -> Bool {
  let lines = item.content.trimmingCharacters(in: .newlines)
    .split(separator: "\n", omittingEmptySubsequences: false)
  guard let first = lines.first, first.hasPrefix("* ") else { return false }
  guard lines.filter({ $0.hasPrefix("* ") || $0 == "*" }).count == 1 else { return false }
  return lines.contains { $0.trimmingCharacters(in: .whitespaces) == ":ID: mobile-\(item.entryID)" }
}

@main
struct CaptureRegression {
  static func main() throws {
    let now = Date(timeIntervalSince1970: 1_793_620_800)
    let note = MobileCaptureWriter.noteCapture(
      title: "Call the\nroaster",
      body: "Ask about beans.\n* Not a heading\n** Nor this",
      attachments: [NoteAttachment(filename: "photo-1.jpg", data: Data([1, 2, 3]))],
      scheduledDate: now,
      now: now
    )
    check(note.content.hasPrefix("* TODO Call the roaster\nSCHEDULED: <"), note.content)
    check(note.content.contains("\n,* Not a heading\n,** Nor this\n"), "Body lines that look like headings must stay body text")
    check(note.content.contains("[[file:mobile-inbox-assets/\(note.entryID)/photo-1.jpg][photo-1.jpg]]"), note.content)
    check(note.attachments.first?.data == Data([1, 2, 3]), "Attachments travel with the queued note")
    check(hostAccepts(note), "The host must accept the phone's note entry")
    check(note.entryID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }, "Entry IDs stay path-safe for attachments")

    let plain = MobileCaptureWriter.noteCapture(title: "", body: "", now: now)
    check(plain.content.hasPrefix("* Phone note\n:PROPERTIES:"), plain.content)
    check(hostAccepts(plain), "An empty note is still one valid entry")

    // The outbox keeps captures in order and drops one only when told to.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let later = MobileCaptureWriter.noteCapture(title: "Second", body: "", now: now.addingTimeInterval(60))
    try MobileCaptureOutbox.enqueue(later, in: directory)
    try MobileCaptureOutbox.enqueue(note, in: directory)
    try MobileCaptureOutbox.enqueue(note, in: directory)
    check(MobileCaptureOutbox.pending(in: directory).map(\.entryID) == [note.entryID, later.entryID], "Queued captures send oldest first, once each")
    MobileCaptureOutbox.remove(entryID: note.entryID, in: directory)
    check(MobileCaptureOutbox.pending(in: directory).map(\.entryID) == [later.entryID], "Only the stored capture leaves the queue")
    print("Mobile capture entries and outbox ordering passed")
  }
}
