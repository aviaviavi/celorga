#!/usr/bin/env node
// Source contracts for walkie-talkie audio approvals across the TypeScript broker, the iOS
// client, and the Mac host. Behavior is covered by test-ios-audio-approval-core.mjs (iOS policy),
// test-audio-approval-broker.mjs (broker), and AudioApprovalHostTests (Mac host, end to end).
// None of these exercise real audio routes, Push to Talk delivery, or a locked phone.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");
const ios = "apps/ios/Org2Mobile/Org2Mobile";
const mac = "apps/macos/Org2Workspace/Sources/Org2WorkspaceCore";

const core = read(`${ios}/AudioApprovalCore.swift`);
const ptt = read(`${ios}/AudioApprovalPushToTalk.swift`);
const controller = read(`${ios}/AudioApprovalController.swift`);
const settings = read(`${ios}/AudioApprovalSettingsSection.swift`);
const transcriber = read(`${ios}/MobileVoiceTranscriber.swift`);
const iosStore = read(`${ios}/MobileRemoteStore.swift`);
const iosModels = read(`${ios}/MobileRemoteModels.swift`);
const iosViews = read(`${ios}/MobileRemoteViews.swift`);
const app = read(`${ios}/Org2MobileApp.swift`);
const pushToTalk = read(`${ios}/AudioApprovalPushToTalk.swift`);
const infoPlist = read(`${ios}/Info.plist`);
const entitlements = read(`${ios}/Org2Mobile.entitlements`);
const broker = read("src/audioApprovalBroker.ts");
const macProtocol = read(`${mac}/MobileRemoteProtocol.swift`);
const macCoordinator = read(`${mac}/MobileRemoteCoordinator.swift`);
const macPush = read(`${mac}/MobileRemotePushNotifications.swift`);
const macStore = read(`${mac}/WorkspaceStore.swift`);
const pbxproj = read("apps/ios/Org2Mobile/Org2Mobile.xcodeproj/project.pbxproj");

// 1. Spoken phrase tables are identical in Swift and TypeScript.
function swiftSet(name) {
  const match = core.match(new RegExp(`static let ${name}: Set<String> = \\[([^\\]]*)\\]`));
  assert.ok(match, `Swift phrase table ${name} missing`);
  return match[1].split(",").map((s) => s.trim().replace(/"/g, "")).filter(Boolean).sort();
}
assert.deepEqual(swiftSet("approvePhrases"), ["approve", "yeah", "yep", "yes"]);
assert.deepEqual(swiftSet("rejectPhrases"), ["deny", "no", "nope", "reject"]);
assert.deepEqual(swiftSet("readPhrases"), ["read it", "read it to me", "read to me"]);
assert.deepEqual(swiftSet("snoozePhrases"), ["later", "not now"]);
for (const phrase of ["yes", "yeah", "yep", "approve", "no", "nope", "reject", "deny", "later", "not now", "read it to me"]) {
  assert.ok(broker.includes(`"${phrase}"`), `TypeScript broker lacks phrase ${phrase}`);
}

// 2. Off by default, but discoverable: Settings always lists the section with an opt-in toggle.
assert.ok(core.includes(`static let defaultsKey = "celorga.audioApprovals.enabled"`));
assert.ok(core.includes("UserDefaults.standard.bool(forKey: defaultsKey)"), "flag defaults to off");
assert.ok(!/register\(defaults[\s\S]{0,200}audioApprovals/.test(app), "no default-on registration");
assert.match(iosViews, /^\s*AudioApprovalSettingsSection\(\)\s*$/m, "the Settings section is always listed");
assert.ok(!/if AudioApprovalFeature\.isEnabled \{\s*AudioApprovalSettingsSection/.test(iosViews), "the section is not hidden behind the flag");
assert.match(settings, /Toggle\("Walkie-talkie approvals"/);
assert.match(settings, /Snooze 30 minutes/);
assert.match(settings, /Quiet until I turn it off/);
assert.match(app, /audioApprovals\.attach\(remote: mobileRemote\)/);
assert.match(app, /init\(\) \{[\s\S]*audioApprovals\.attach\(remote: mobileRemote\)[\s\S]*StateObject\(wrappedValue: audioApprovals\)/,
  "the Push to Talk controller is attached during app initialization, including background launches");
assert.doesNotMatch(app, /\.task\s*\{\s*audioApprovals\.attach/,
  "background Push to Talk launch cannot depend on a SwiftUI view task");

// 3. Headset only. No speaker fallback or override anywhere in the slice.
for (const [name, source] of Object.entries({ core, ptt, controller })) {
  assert.ok(!/defaultToSpeaker/.test(source), `${name} must not use defaultToSpeaker`);
  assert.ok(!/overrideOutputAudioPort/.test(source), `${name} must not override the output port`);
}
assert.match(core, /if snapshot\.route != \.headset \{ return \.hold\(\.noHeadset\) \}/);
assert.match(core, /allSatisfy \{ headsetPorts\.contains\(\$0\) \}/, "route is headset only when every output is headset");
assert.match(controller, /case \.hold:\s*\/\/[^\n]*\n\s*send\(\.playbackFinished\(completed: false/, "a held prompt is reported unheard, not rerouted");

// 4. Apple's Push to Talk audio-session rules: the system activates the session.
for (const [name, source] of Object.entries({ ptt, controller })) {
  assert.ok(!/\.setActive\(/.test(source), `${name} must not activate the audio session itself`);
}
assert.match(controller, /transcriber\.start\(managesAudioSession: false\)/, "replies are captured inside the system session");
assert.match(transcriber, /if managesAudioSession \{\s*try audioSession\.activateForDictation\(\)\s*ownsAudioSession = true/);
assert.match(ptt, /\.playAndRecord/);
assert.match(core, /if capture == \.awaitingSession \{\s*capture = \.capturing/, "capture starts only after didActivate");
assert.match(ptt, /state\.markInterrupted\(\)\s*channelManager\.stopTransmitting/, "a push mid-reply ends the transmission as interrupted");
assert.match(ptt, /channelManager\?\.activeChannelUUID == AudioApprovalChannel\.channelUUID/,
  "startup restores the framework-owned joined channel before accepting pushes");
assert.match(ptt, /if channelManager\.activeChannelUUID == channelUUID \{\s*state\.isEnrolled = true/,
  "a restoration callback race cannot make an incoming background push leave the channel");
assert.match(controller, /case \.managerReady\(let failure, let restored\):[\s\S]{0,400}send\(\.enrollmentChanged\(joined: true\)\)/,
  "restored framework enrollment reaches the approval state machine");

// 5. Only user-initiated transmissions authorize a reply.
assert.match(ptt, /source == \.userRequest \|\| source == \.handsfreeButton/);
assert.ok(!/source == \.developerRequest/.test(ptt));

// 6. Exact identity end to end, with a receipt key for idempotent replays.
for (const field of ["runID", "approvalID", "fingerprint", "receipt"]) {
  assert.ok(iosModels.includes(`var ${field}: String?`), `iOS decision request carries ${field}`);
  assert.ok(macProtocol.includes(`public let ${field}: String?`), `Mac decision request carries ${field}`);
}
assert.match(macStore, /Nothing was changed; review it again\./, "Mac refuses a changed approval");
assert.match(macStore, /no longer pending\. Nothing was changed\./, "Mac refuses an exact decision with no pending approval");
assert.match(macStore, /approval\.receipt == receipt/, "only the same receipt replays");
assert.match(iosStore, /fingerprint: fingerprint,\s*receipt: receipt/);
assert.match(core, /"\\\(runID\)\|\\\(approvalID\)\|\\\(fingerprint\)"/, "iOS prompt key");
assert.match(pushToTalk, /mode:\s*\.voiceChat/, "Push to Talk keeps a duplex voice route");
assert.match(pushToTalk, /options:\s*\[\.allowBluetooth\]/, "Push to Talk enables Bluetooth HFP");
assert.doesNotMatch(pushToTalk, /allowBluetoothA2DP/, "Push to Talk does not compete with output-only A2DP");
assert.match(pushToTalk, /setPreferredInput\(headset\)/, "Push to Talk selects the connected HFP input once activated");
assert.match(macCoordinator, /var key: String \{ "\\\(runID\)\|\\\(approvalID\)\|\\\(fingerprint\)" \}/, "Mac prompt key matches");

// 7. Push to Talk transport: token registration, APNs topic, identity-only payload, snooze endpoint.
assert.match(controller, /setAudioApprovalPushRegistration\(\s*token: enabled \? pushToken : nil/);
assert.match(iosStore, /"\/v1\/push-to-talk-registration"/);
assert.match(macCoordinator, /path == "\/v1\/push-to-talk-registration"/);
assert.match(iosStore, /"\/v1\/audio-approvals\/snooze"/);
assert.match(macCoordinator, /path == "\/v1\/audio-approvals\/snooze"/);
assert.match(macPush, /static let pushToTalkTopic = "org\.org2\.mobile\.voip-ptt"/);
assert.match(macPush, /"pushtotalk", forHTTPHeaderField: "apns-push-type"/);
assert.match(macPush, /"0", forHTTPHeaderField: "apns-expiration"/);
for (const key of ["runID", "approvalID", "fingerprint"]) {
  assert.ok(macPush.includes(`"${key}": envelope.${key}`), `APNs payload carries ${key}`);
  assert.ok(ptt.includes(`payload["${key}"] as? String`), `iOS reads ${key} from the push`);
}

// 8. Entitlement and background mode per Apple's Push to Talk guide.
assert.match(entitlements, /<key>com\.apple\.developer\.push-to-talk<\/key>\s*<true\/>/);
assert.match(entitlements, /<key>aps-environment<\/key>/);
assert.match(infoPlist, /<key>UIBackgroundModes<\/key>\s*<array>[\s\S]*?<string>push-to-talk<\/string>[\s\S]*?<\/array>/);
const backgroundModes = /<key>UIBackgroundModes<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(infoPlist)?.[1] ?? "";
assert.match(backgroundModes, /<string>audio<\/string>/,
  "PTT pushes alone cannot activate background playback; the packaged app also needs the audio background mode");
assert.match(infoPlist, /<key>NSMicrophoneUsageDescription<\/key>\s*<string>[^<]*approval[^<]*<\/string>/);

// 9. Every audio Swift file is in the Xcode target.
for (const file of ["AudioApprovalCore.swift", "AudioApprovalPushToTalk.swift", "AudioApprovalController.swift", "AudioApprovalSettingsSection.swift"]) {
  const count = pbxproj.split(file).length - 1;
  assert.ok(count >= 4, `${file} must be in the file reference, group, build file, and sources phase (saw ${count})`);
}

// 10. The TypeScript broker binds replies to a heard prompt too.
assert.match(broker, /reason: "prompt-not-heard"/);

// Hosts without audio approvals answer the registration with the thread-lookup 404.
// The phone must name that problem, and new hosts must not reuse the message.
assert.match(iosStore, /legacyUnknownRouteError = "Thread not found\."/);
assert.match(iosStore, /catch MobileRemoteClientError\.server\(let message\) where message == Self\.legacyUnknownRouteError/);
assert.match(macCoordinator, /This Celorga host does not support \\\(request\.method\) \\\(path\)/);

// Delivery: refresh canonical approvals before choosing and after every decision; a delivered,
// unanswered prompt never blocks newer ones; urgency is explicit; answers are never interrupted.
assert.match(macCoordinator, /await store\.refreshApprovals\(clearsError: false\)\s*\n\s*\}\s*\n\s*self\.enqueuePushToTalkApproval/);
assert.match(macCoordinator, /workspaceComponents\[4\] == "decision",[\s\S]{0,200}defer \{ requestPushToTalkEvaluation\(\) \}/);
assert.match(macCoordinator, /excluding: Set\(delivered\.keys\)/);
assert.match(macCoordinator, /if lhs\.urgent != rhs\.urgent \{ return lhs\.urgent \}/);
assert.match(core, /if leftUrgent != rightUrgent \{ return leftUrgent \}/);
assert.doesNotMatch(core, /A push must never complete a partial reply/);
assert.match(core, /deferredPush = target/);

assert.match(transcriber, /guard ownsAudioSession else \{ return \}\s*ownsAudioSession = false\s*try\? audioSession\.deactivate\(\)/,
  "idle chat cleanup and PTT replies must not deactivate a session the transcriber never acquired");
assert.match(controller, /synthesizer\.write\(AVSpeechUtterance/, "speech is rendered to audio buffers");
assert.match(controller, /completionCallbackType: \.dataPlayedBack/, "receive mode waits for audible playback completion");
assert.doesNotMatch(controller, /synthesizer\.speak\(/, "the background speech path uses the PTT-owned player");
assert.match(controller, /beginBackgroundTask\(withName: "Finish audio approval reply"/);
assert.match(controller, /endReplyBackgroundTask\(\)/);
assert.match(controller, /hostReceipt\.receipt == receipt/);
assert.match(settings, /Heard:/);
assert.match(settings, /Interpreted as:/);
assert.match(settings, /Recorded decisions on the Mac/);
assert.match(iosStore, /approvalHistory = snapshot\.approvalHistory \?\? \[\]/);

console.log("ios audio approval contract tests passed");
