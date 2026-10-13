import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import "./test-ios-transcript.mjs";
import "./test-mobile-document.mjs";

const contentView = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/ContentView.swift"),
  "utf8",
);
const remoteViews = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift"),
  "utf8",
);
const remoteStore = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteStore.swift"),
  "utf8",
);
const corpusStore = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/CorpusStore.swift"),
  "utf8",
);
const mobileCaptureSupport = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/MobileCaptureSupport.swift"),
  "utf8",
);
const mobileCallTranscriptImport = readFileSync(
  resolve("apps/ios/Org2Mobile/Org2Mobile/MobileCallTranscriptImport.swift"),
  "utf8",
);
const remoteCoordinator = readFileSync(
  resolve("apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/MobileRemoteCoordinator.swift"),
  "utf8",
);

const workspaceTabs = contentView.slice(
  contentView.indexOf("private struct WorkspaceTabs"),
  contentView.indexOf("private struct AgendaView"),
);
assert.match(workspaceTabs, /Label\("Files", systemImage: "folder"\)/);
assert.doesNotMatch(workspaceTabs, /Label\("Remote"/);
assert.doesNotMatch(workspaceTabs, /Label\("Workflows"/);
assert.match(workspaceTabs, /case \.thread\(let threadID\):[\s\S]*MobileRemoteThreadView/);
assert.match(
  workspaceTabs,
  /MobileRemoteThreadView\(threadID: threadID\)[\s\S]*?\.id\(threadID\)/,
  "Each sidebar-selected chat should have a distinct SwiftUI view identity",
);
assert.match(
  workspaceTabs,
  /openWorkspace: \{\s*selection = \.newNote\s*route = \.workspace/,
);
assert.match(
  workspaceTabs,
  /\.simultaneousGesture\([\s\S]*DragGesture\([\s\S]*coordinateSpace: \.global[\s\S]*MobileSidebarEdgeSwipe\.shouldOpen/,
  "The workspace should recognize the sidebar reveal without replacing child gestures",
);
assert.match(
  workspaceTabs,
  /guard !isSidebarPresented,[\s\S]*startLocation: value\.startLocation,[\s\S]*translation: value\.translation/,
  "The edge swipe should only reveal a closed sidebar",
);

const sidebarEdgeSwipe = contentView.slice(
  contentView.indexOf("private enum MobileSidebarEdgeSwipe"),
  contentView.indexOf("private enum MobileWorkspaceRoute"),
);
assert.match(sidebarEdgeSwipe, /activationWidth: CGFloat = 24/);
assert.match(sidebarEdgeSwipe, /minimumHorizontalTravel: CGFloat = 44/);
assert.match(
  sidebarEdgeSwipe,
  /\(0\.\.\.activationWidth\)\.contains\(startLocation\.x\)/,
  "Sidebar reveal gestures must begin at the physical left edge",
);
assert.match(
  sidebarEdgeSwipe,
  /translation\.width >= abs\(translation\.height\) \* horizontalDominance/,
  "Vertical scrolling should not open the sidebar",
);

const newNote = contentView.slice(
  contentView.indexOf("private struct NewNoteView"),
  contentView.indexOf("private enum NewNoteFocusedField"),
);
assert.doesNotMatch(newNote, /Section\("Corpus"\)/);
assert.match(newNote, /Menu \{[\s\S]*Photo Library[\s\S]*Camera/);
assert.match(newNote, /Button\("Save"\)/);
assert.match(newNote, /Label\("Import Phone Call", systemImage: "phone\.arrow\.down\.left"\)/);
assert.match(newNote, /MobileCallTranscriptImportView/);
assert.match(mobileCallTranscriptImport, /PasteButton\(payloadType: String\.self\)/);
assert.match(mobileCallTranscriptImport, /accessibilityLabel\("Paste Apple Transcript"\)/);
assert.match(mobileCallTranscriptImport, /Make sure everyone is willing to be recorded/);
assert.match(mobileCallTranscriptImport, /Verify the transcript before saving it/);
assert.doesNotMatch(
  mobileCallTranscriptImport,
  /UIPasteboard/,
  "Explicit transcript paste must use PasteButton without an extra paste-permission alert",
);
assert.match(mobileCallTranscriptImport, /SFSpeechURLRecognitionRequest\(url: url\)/);
assert.match(mobileCallTranscriptImport, /allowedContentTypes: \[\.audio\]/);
assert.doesNotMatch(
  mobileCallTranscriptImport,
  /AVAudioEngine/,
  "Call ingestion must use a completed recording, not attempt to tap live Phone audio",
);

assert.match(remoteViews, /struct MobileAISidebarView/);
assert.match(remoteViews, /sidebarButton\([\s\S]*?"External Threads"/);
const mobileSidebar = remoteViews.slice(
  remoteViews.indexOf("struct MobileAISidebarView"),
  remoteViews.indexOf("struct MobileSettingsView"),
);
assert.ok(
  mobileSidebar.indexOf('sidebarButton("Settings"') < mobileSidebar.indexOf('Section("Threads")'),
  "Settings should stay in the sidebar's fixed navigation group above chat threads",
);
assert.equal(
  mobileSidebar.match(/sidebarButton\("Settings"/g)?.length,
  1,
  "Settings should appear once in the mobile sidebar",
);
assert.match(
  remoteViews,
  /Label\("New \\\(destination\.name\) Chat", systemImage: "plus\.bubble"\)/,
);
assert.match(remoteViews, /Section\("Projects"\)/);
assert.match(remoteViews, /Menu\("New Chat in Project", systemImage: "folder\.badge\.plus"\)/);
assert.match(remoteViews, /activeThreads\.filter \{ project\.contains\(\$0\.id\) \}/);
{
  const remoteModels = readFileSync(
    resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteModels.swift"),
    "utf8",
  );
  assert.match(
    remoteModels,
    /var runningFirst: \[MobileRemoteThreadSummary\] \{\s*filter\(\\\.isRunning\) \+ filter \{ !\$0\.isRunning \}/,
    "Running chats sort ahead of idle chats while keeping the host order",
  );
  const activeDefinitions = remoteViews.match(/remote\.threads\.filter \{ !\$0\.isSettled \}\.runningFirst/g) ?? [];
  assert.equal(activeDefinitions.length, 2, "Both the sidebar and the chat list order running chats first");
  assert.ok(
    remoteViews.indexOf('Section("Running")') < remoteViews.indexOf('Section("Threads")')
      && remoteViews.lastIndexOf('Section("Running")') < remoteViews.indexOf('Section("Chats")'),
    "A Running section sits above the idle chats in the sidebar and the chat list",
  );
}
assert.match(remoteViews, /remote\.setProjectMembership/);
assert.doesNotMatch(remoteViews, /New \(destination\.name\) Chat/);
assert.match(remoteViews, /struct MobileSettingsView/);
assert.match(remoteViews, /Text\("Reply Notifications"\)/);
assert.match(remoteViews, /Label\("Send Test Notification"/);
assert.match(remoteViews, /LabeledContent\("Endpoint", value: remote\.pairedEndpoint\)/);
assert.match(remoteViews, /Label\("Reconnect", systemImage: "arrow\.clockwise"\)/);
assert.match(remoteViews, /Button\("Pair Again", role: \.destructive\)/);

const mobileThreadView = remoteViews.slice(
  remoteViews.indexOf("struct MobileRemoteThreadView"),
  remoteViews.indexOf("private struct MobileRemotePhotoThumbnail"),
);
assert.match(
  mobileThreadView,
  /\.task\(id: threadID\) \{[\s\S]*remote\.beginPolling\(threadID: threadID\)/,
  "Changing the selected chat should restart transcript polling",
);
assert.doesNotMatch(
  mobileThreadView,
  /\.onAppear \{[\s\S]{0,180}remote\.beginPolling/,
  "Transcript polling must not depend only on onAppear",
);
const mobileThreadScrollView = mobileThreadView.slice(
  mobileThreadView.indexOf("private func chatScrollView"),
  mobileThreadView.indexOf("private var composer"),
);
assert.doesNotMatch(
  mobileThreadScrollView,
  /LazyVStack/,
  "Chat transcripts must use exact row geometry so changing message heights cannot leave phantom space below the final row",
);
assert.match(mobileThreadScrollView, /MobileRemoteTranscriptPage\.make/);
assert.match(mobileThreadScrollView, /ForEach\(messages\[page\]\)/);
assert.doesNotMatch(mobileThreadScrollView, /ForEach\(detail\.messages/);
assert.match(mobileThreadScrollView, /Earlier messages/);
assert.match(mobileThreadScrollView, /Newer messages/);
assert.match(remoteViews, /MobileRemoteTranscriptPage\.preview\(content\)/);
assert.match(remoteViews, /Read full message/);
assert.match(remoteViews, /UITextView\(usingTextLayoutManager: true\)/);
assert.match(
  mobileThreadView,
  /private func scrollToBottomIfFollowing[\s\S]*scrollToBottom\(proxy: proxy, animated: false\)/,
  "Automatic transcript following must not animate through simultaneous composer and message layout changes",
);
assert.match(
  mobileThreadView,
  /if !isNearChatBottom[\s\S]*Button \{[\s\S]*scrollToBottom\(proxy: proxy, animated: true\)/,
  "The explicit jump-to-latest control should retain animated scrolling",
);

const createThread = remoteStore.slice(
  remoteStore.indexOf("func createThread("),
  remoteStore.indexOf("func refreshExternalThreads()"),
);
assert.match(createThread, /guard let threadID = response\.threadID/);
assert.match(createThread, /guard isConnected else/);
assert.doesNotMatch(createThread, /await refresh\(\)/);
assert.match(createThread, /Task \{ \[weak self\][\s\S]*refresh\(reportsErrors: false\)/);
assert.match(createThread, /projectID: project\?\.id/);
assert.match(remoteStore, /projects = nextThreads\.projects \?\? \[\]/);
assert.match(remoteStore, /\/v1\/threads\/\\\(threadID\.uuidString\)\/project/);

assert.match(corpusStore, /content\.title = "Celorga due today"/);
assert.match(remoteCoordinator, /title: "Celorga reply notifications"/);
assert.doesNotMatch(corpusStore, /content\.title = "Org2/);
assert.doesNotMatch(remoteCoordinator, /title: "Org2 reply notifications"/);
assert.match(remoteStore, /serverName = "Celorga on Mac"/);
assert.match(remoteStore, /storedServerName == "Org2 on Mac" \|\| storedServerName == "OpenOrg on Mac"/);
assert.match(mobileCaptureSupport, /mobileInboxFilename = "mobile-inbox\.org"/);
assert.match(mobileCaptureSupport, /legacyMobileInboxFilename = "mobile-inbox\.org2"/);
assert.match(
  mobileCaptureSupport,
  /fileManager\.fileExists\(atPath: legacy\.path\) \? legacy : preferred/,
  "iOS capture should keep appending to an existing legacy mobile-inbox.org2 file",
);
assert.match(contentView, /Saved to mobile-inbox\.org for safe desktop sync\./);

console.log("iOS mobile navigation tests passed");

assert.match(remoteViews, /resultsIndexID == store.searchIndex.id/, "Results must belong to the current corpus index before they can be opened");
assert.match(remoteViews, /ForEach\(hasCurrentResults \? results : \[\]\)/);

// The thread outputs chip mirrors the Mac AI chat header chip.
const threadView = remoteViews.slice(
  remoteViews.indexOf("struct MobileRemoteThreadView: View"),
  remoteViews.indexOf("private struct MobileRemoteBoundedMessageText"),
);
assert.match(threadView, /MobileRemoteThreadOutputsChip\(outputs: outputs\)/, "The thread toolbar should show the outputs chip");
assert.match(threadView, /\.task\(id: outputsSignature\)/, "Outputs should refresh when a reply lands, not per streamed token");
assert.match(threadView, /MobileRemoteTranscriptPage\.reveal\(messageID, in: messages\)/, "Jumping to a reply must page it into view first");
assert.match(remoteStore, /guard status\?\.supportsThreadOutputs == true else \{ return nil \}/, "Older hosts without outputs must not be queried");
assert.match(remoteStore, /"\/v1\/threads\/\\\(threadID\.uuidString\)\/outputs"/);
assert.match(remoteCoordinator, /components\[3\] == "outputs"/);
assert.match(remoteViews, /\.quickLookPreview\(\$quickLookURL\)/, "Published PDFs open from the synced copy");
console.log("iOS thread outputs tests passed");
