import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OpenAIDotMirrorTests: XCTestCase {
  private let roomID = "room-juniper"
  private let selfMember = "user-self"
  private let dotMember = "member-juniper"
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func room(_ index: Int, member: String? = nil, text: String? = nil, requestID: String? = nil) -> OpenAIDotMessage {
    OpenAIDotMessage(
      id: "m\(index)",
      memberID: member ?? (index.isMultiple(of: 2) ? dotMember : selfMember),
      text: text ?? "Message \(index)",
      createdAt: start.addingTimeInterval(TimeInterval(index)),
      requestID: requestID
    )
  }

  private func merge(_ existing: [AIChatMessage], _ incoming: [OpenAIDotMessage]) -> OpenAIDotMirror.Merge {
    OpenAIDotMirror.merge(existing: existing, incoming: incoming, roomID: roomID, selfMemberID: selfMember)
  }

  func testMergeShowsEveryMessageOnceInConversationOrder() {
    let sentFromCelorga = AIChatMessage(
      role: .user,
      content: "Plan the trip",
      createdAt: start.addingTimeInterval(3)
    )
    let queued = AIChatMessage(
      role: .user,
      content: "Queued",
      createdAt: start.addingTimeInterval(100),
      deliveryStatus: .sending
    )
    let first = merge([sentFromCelorga, queued], [
      room(1, text: "Sent from my phone"),
      room(2, text: "See [the plan](https://example.test/plan)"),
      // The echo of the message Celorga sent.
      room(3, member: selfMember, text: "Plan the trip", requestID: sentFromCelorga.id.uuidString.lowercased()),
      room(4, text: "Done"),
      room(5, member: selfMember, text: "   "),
    ])
    XCTAssertEqual(first.addedCount, 3)
    XCTAssertEqual(first.trimmedCount, 0)
    XCTAssertEqual(
      first.messages.map(\.content),
      ["Sent from my phone", "See [[https://example.test/plan][the plan]]", "Plan the trip", "Done", "Queued"]
    )
    XCTAssertEqual(first.messages.map(\.role), [.user, .assistant, .user, .assistant, .user])
    XCTAssertEqual(first.messages[0].id, OpenAIDotMirror.messageID(roomID: roomID, messageID: "m1"))
    XCTAssertEqual(first.messages[0].createdAt, start.addingTimeInterval(1))

    // Reading the same messages again, here or on another Mac, adds nothing.
    let again = merge(first.messages, [room(1, text: "Sent from my phone"), room(4, text: "Done")])
    XCTAssertFalse(again.changed)
    XCTAssertEqual(again.messages, first.messages)
  }

  func testMergeTrimsInBatchesAndNeverBringsTrimmedMessagesBack() {
    let filled = merge([], (1...299).map { room($0) })
    XCTAssertEqual(filled.messages.count, 299)
    XCTAssertEqual(filled.trimmedCount, 0)

    let trimmed = merge(filled.messages, [room(300)])
    XCTAssertEqual(trimmed.addedCount, 1)
    XCTAssertEqual(trimmed.trimmedCount, 100)
    XCTAssertEqual(trimmed.messages.count, OpenAIDotMirror.retainedMessageLimit)
    XCTAssertEqual(trimmed.messages.first?.content, "Message 101")
    XCTAssertEqual(trimmed.messages.last?.content, "Message 300")

    // A stale position elsewhere rereads trimmed messages; they stay trimmed.
    let reread = merge(trimmed.messages, (90...301).map { room($0) })
    XCTAssertEqual(reread.addedCount, 1)
    XCTAssertEqual(reread.messages.first?.content, "Message 101")
    XCTAssertEqual(reread.messages.last?.content, "Message 301")
  }

  func testEarlierMessagesSkipWhatIsAlreadyShown() {
    let shown = merge([], (40...60).map { room($0) }).messages
    let page = (30...45).map { room($0) }
    let earlier = OpenAIDotMirror.earlierMessages(page, shown: shown, roomID: roomID, selfMemberID: selfMember)
    XCTAssertEqual(earlier.map(\.content), (30...39).map { "Message \($0)" })
  }

  func testAttachmentsAndPollingPace() {
    let call = OpenAIDotMessage(
      id: "m9",
      memberID: dotMember,
      text: "",
      attachments: [OpenAIDotAttachment(type: "call", durationMilliseconds: 125_000)]
    )
    XCTAssertEqual(
      OpenAIDotMirror.transcriptMessage(call, roomID: roomID, selfMemberID: selfMember)?.content,
      "/Call · 2 min/"
    )
    XCTAssertNil(OpenAIDotMirror.transcriptMessage(
      OpenAIDotMessage(id: "m10", memberID: dotMember, text: "Hidden", isDeleted: true),
      roomID: roomID,
      selfMemberID: selfMember
    ))
    XCTAssertEqual(OpenAIDotMirror.pollInterval(sinceActivity: 10), 3)
    XCTAssertEqual(OpenAIDotMirror.pollInterval(sinceActivity: 600), 10)
    XCTAssertEqual(OpenAIDotMirror.pollInterval(sinceActivity: 7_200), 45)
    XCTAssertEqual(OpenAIDotMirror.retryInterval(after: OpenAIDotChatError.transport("offline"), previous: 0), 5)
    XCTAssertEqual(OpenAIDotMirror.retryInterval(after: OpenAIDotChatError.transport("offline"), previous: 160), 300)
    XCTAssertEqual(OpenAIDotMirror.retryInterval(after: OpenAIDotChatError.signInExpired, previous: 0), 300)
  }

  @MainActor
  func testStoreOpensOneMirrorAndMergesTheConversationIntoIt() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-dot-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "OpenAIDot.Mirror.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let store = WorkspaceStore(defaults: defaults, aiChatTranscriptURL: transcriptURL, legacyDefaultsDomains: [])
    store.setCorpusRoot(root, persistsDefault: false)
    // No network in tests: watches cannot start without a client.
    store.openAIDotClientFactoryForTesting = { _ in throw OpenAIDotChatError.notSignedIn }
    let destination = AIChatDestinationConfiguration(name: "Juniper", mention: "juniper", adapter: .openAIDot)
    store.aiChatDestinations.append(destination)

    let threadID = try XCTUnwrap(store.openOpenAIDotConversation(destinationID: destination.id))
    XCTAssertEqual(store.openOpenAIDotConversation(destinationID: destination.id), threadID)
    let thread = try XCTUnwrap(store.aiChatThread(threadID, transcriptURL: transcriptURL))
    XCTAssertEqual(thread.openAIDotMirrorDestinationID, destination.id)
    XCTAssertTrue(thread.isPinned)
    XCTAssertTrue(store.selectedAIChatCanLoadEarlierOpenAIDotMessages)

    let dotRoom = OpenAIDotRoom(
      dot: OpenAIDotProfile(id: "dot-juniper", displayName: "Juniper", messagingRoomID: roomID, isPaused: false),
      roomID: roomID,
      selfMemberID: selfMember
    )
    let added = store.mergeOpenAIDotMirrorMessages(
      [room(1), room(2)],
      cursor: "m2",
      room: dotRoom,
      threadID: threadID,
      transcriptURL: transcriptURL,
      notifies: false
    )
    XCTAssertEqual(added, 2)
    XCTAssertEqual(store.aiChatMessages(for: threadID, transcriptURL: transcriptURL).map(\.content), ["Message 1", "Message 2"])
    let updated = try XCTUnwrap(store.aiChatThread(threadID, transcriptURL: transcriptURL))
    XCTAssertEqual(updated.openAIDotMirrorCursor(roomID: roomID), "m2")
    XCTAssertNil(updated.openAIDotMirrorCursor(roomID: "another-room"))
    XCTAssertEqual(updated.openAIDotMirrorDestinationID, destination.id)

    // A message sent from the mirror is marked sent without a reply of its
    // own; the dot's answers arrive through the mirror.
    let sent = AIChatMessage(role: .user, content: "Next?", createdAt: start.addingTimeInterval(3), deliveryStatus: .sending)
    store.updateAIChatThread(
      threadID,
      messages: store.aiChatMessages(for: threadID, transcriptURL: transcriptURL) + [sent],
      transcriptURL: transcriptURL
    )
    store.settleAIChatUserMessageWithoutReply(sent.id, in: threadID, transcriptURL: transcriptURL)
    store.mergeOpenAIDotMirrorMessages(
      [room(3, member: selfMember, text: "Next?", requestID: sent.id.uuidString.lowercased()), room(4, text: "Here")],
      cursor: "m4",
      room: dotRoom,
      threadID: threadID,
      transcriptURL: transcriptURL,
      notifies: true
    )
    let messages = store.aiChatMessages(for: threadID, transcriptURL: transcriptURL)
    XCTAssertEqual(messages.map(\.content), ["Message 1", "Message 2", "Next?", "Here"])
    XCTAssertEqual(messages[2].deliveryStatus, .sent)

    // An ordinary chat is never treated as a mirror.
    let ordinary = store.createAIChatThread(destinationID: destination.id)
    XCTAssertEqual(
      store.mergeOpenAIDotMirrorMessages([room(5)], cursor: "m5", room: dotRoom, threadID: ordinary, transcriptURL: transcriptURL, notifies: false),
      0
    )
  }
}
