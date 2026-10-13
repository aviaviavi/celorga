#!/usr/bin/env node
// Source-contract checks for the feature-gated walkie-talkie audio approval slice.
// These verify invariants that must hold across the TypeScript broker, the iOS client,
// and the Mac host. They do NOT exercise audio routes, Push to Talk, or a locked phone;
// those behaviours are unverified until tested on a physical device.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (rel) => fs.readFileSync(path.join(root, rel), "utf8");
const ios = "apps/ios/Org2Mobile/Org2Mobile";

const core = read(`${ios}/AudioApprovalCore.swift`);
const ptt = read(`${ios}/AudioApprovalPushToTalk.swift`);
const controller = read(`${ios}/AudioApprovalController.swift`);
const settings = read(`${ios}/AudioApprovalSettingsSection.swift`);
const broker = read("src/audioApprovalBroker.ts");
const iosModels = read(`${ios}/MobileRemoteModels.swift`);
const macProtocol = read("apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/MobileRemoteProtocol.swift");
const macStore = read("apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/WorkspaceStore.swift");
const pbxproj = read("apps/ios/Org2Mobile/Org2Mobile.xcodeproj/project.pbxproj");

// 1. Spoken phrase tables are identical to the TypeScript broker.
function swiftSet(name) {
  const match = core.match(new RegExp(`static let ${name}: Set<String> = \\[([^\\]]*)\\]`));
  assert.ok(match, `Swift phrase table ${name} missing`);
  return match[1].split(",").map((s) => s.trim().replace(/"/g, "")).filter(Boolean).sort();
}
assert.deepEqual(swiftSet("approvePhrases"), ["approve", "yeah", "yep", "yes"]);
assert.deepEqual(swiftSet("rejectPhrases"), ["deny", "no", "nope", "reject"]);
assert.deepEqual(swiftSet("readPhrases"), ["read it", "read it to me", "read to me"]);
assert.deepEqual(swiftSet("snoozePhrases"), ["later", "not now"]);
// The TypeScript broker must accept the same phrases.
for (const phrase of ["yes", "yeah", "yep", "approve", "no", "nope", "reject", "deny", "later", "not now", "read it to me"]) {
  assert.ok(broker.includes(`"${phrase}"`), `TypeScript broker lacks phrase ${phrase}`);
}
assert.ok(core.includes(`if normalized == "why" { return .why }`), "why intent is whole-utterance");

// 2. Feature is off by default and only enabled explicitly.
assert.ok(core.includes(`static let defaultsKey = "celorga.audioApprovals.enabled"`));
assert.ok(core.includes("UserDefaults.standard.bool(forKey: defaultsKey)"), "flag reads without a default-true registration");
assert.ok(!/registerDefaults[\s\S]{0,200}audioApprovals/.test(read(`${ios}/Org2MobileApp.swift`)), "no default registration for the flag");

// 3. Headset-only, no speaker fallback, no speaker override anywhere in the slice.
for (const [name, source] of Object.entries({ core, ptt, controller })) {
  assert.ok(!/defaultToSpeaker/.test(source), `${name} must not use defaultToSpeaker`);
  assert.ok(!/overrideOutputAudioPort\(\s*\.speaker/.test(source), `${name} must not force the speaker`);
}
assert.match(core, /if snapshot\.route != \.headset \{ return \.hold\(\.noHeadset\) \}/);
assert.match(core, /if quiet \{ return \.hold\(\.quiet\) \}/);
assert.match(core, /if !snapshot\.pushToTalkSessionActive \{ return \.hold\(\.noPushToTalkSession\) \}/);
assert.match(core, /if snapshot\.inCall \{ return \.hold\(\.callActive\) \}/);
assert.match(core, /if snapshot\.mediaPlaying \{ return \.hold\(\.mediaActive\) \}/);
assert.match(core, /allSatisfy \{ headsetPorts\.contains\(\$0\) \}/, "route is headset only when every output is headset");

// 4. Only user-initiated transmissions can authorize a reply.
assert.match(ptt, /source == \.userRequest \|\| source == \.handsfreeButton/);
assert.ok(!/source == \.developerRequest/.test(ptt), "developer-requested transmission must not be treated as initiated");
assert.match(controller, /guard initiated, active != nil, !isQuiet else \{ return \}/);

// 5. Exact identity: iOS request, Mac request, and Mac guard use the same fields.
for (const field of ["runID", "approvalID", "fingerprint"]) {
  assert.ok(iosModels.includes(`var ${field}: String?`), `iOS request carries ${field}`);
  assert.ok(macProtocol.includes(`public let ${field}: String?`), `Mac request carries ${field}`);
}
assert.match(macStore, /Nothing was changed; review it again\./, "Mac refuses a changed approval");
assert.match(macStore, /no longer pending\. Nothing was changed\./, "Mac refuses an exact decision with no pending approval");
assert.match(read(`${ios}/MobileRemoteStore.swift`), /runID: runID,\s*approvalID: approvalID,\s*fingerprint: fingerprint/);

// 6. Receipts are keyed by the exact prompt identity, and the decision goes through the host.
assert.match(core, /"\\\(runID\)\|\\\(approvalID\)\|\\\(fingerprint\)"/);
assert.match(controller, /if let prior = receipts\[key\]/);

// 7. Every new Swift file is in the Xcode target.
for (const file of ["AudioApprovalCore.swift", "AudioApprovalPushToTalk.swift", "AudioApprovalController.swift", "AudioApprovalSettingsSection.swift"]) {
  const count = pbxproj.split(file).length - 1;
  assert.ok(count >= 4, `${file} must be in the file reference, group, build file, and sources phase (saw ${count})`);
}

// 8. The Push to Talk entitlement is not added by default; device signing will need it.
const entitlements = read(`${ios}/Org2Mobile.entitlements`);
assert.ok(!entitlements.includes("com.apple.developer.push-to-talk"), "PTT entitlement is a signing dependency, not default");

console.log("ios audio approval contract tests passed");
