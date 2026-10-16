#!/usr/bin/env node
// iOS TestFlight beta tool: offline preflight, exact commands, and no side effects without --execute.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { IOS_BETA, audioBackgroundModeChecks, displayCommand, exportOptionsPlist, parseArguments, plan, preflight, verifyAudioBackgroundModes } from "../tools/ios-beta.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

assert.throws(() => parseArguments(["archive"]), /--build N is required/);
assert.throws(() => parseArguments(["upload", "--build", "0"]), /positive integer/);
assert.throws(() => parseArguments(["publish"]), /Usage/);
assert.equal(parseArguments(["upload", "--build", "48"]).execute, false, "read-only unless --execute");

// The repository satisfies every signing, entitlement, and bundle prerequisite.
const result = preflight({ build: 1_000_000, environment: {} });
const byName = Object.fromEntries(result.checks.map((check) => [check.name, check]));
for (const name of [
  "team", "automatic-signing", "bundle-ids", "release-aps-environment", "entitlement-push-to-talk",
  "entitlement-push", "entitlement-app-group", "background-push-to-talk", "background-audio", "microphone-usage", "build-number",
]) {
  assert.equal(byName[name]?.status, "pass", `${name}: ${byName[name]?.detail}`);
}
assert.ok(["pass", "warn"].includes(byName.xcode.status), "the Xcode check reports but never hard-fails preflight");
assert.equal(preflight({ build: 1, environment: {} }).checks.find((c) => c.name === "build-number").status, "fail",
  "a build number at or below the project's is refused");

// Build 55 accepted PTT pushes but could not activate audio in the background. Both modes
// must be checked on the actual built product before simulator tests or TestFlight upload.
for (const modes of [[], ["push-to-talk"], ["audio"]]) {
  assert.ok(audioBackgroundModeChecks(modes).some(check => check.status === "fail"), `${modes}: incomplete capabilities must fail`);
  assert.throws(() => verifyAudioBackgroundModes("/tmp/Packaged.app", () => ({ ok: true, stdout: JSON.stringify(modes) })), /Built app cannot run background audio approvals/);
}
assert.deepEqual(verifyAudioBackgroundModes("/tmp/Packaged.app", (command, args) => {
  assert.equal(command, "/usr/bin/plutil");
  assert.equal(args.at(-1), "/tmp/Packaged.app/Info.plist");
  return { ok: true, stdout: '["fetch","push-to-talk","audio"]' };
}), ["fetch", "push-to-talk", "audio"]);
assert.throws(() => verifyAudioBackgroundModes("/tmp/Unreadable.app", () => ({ ok: false })), /Could not inspect built app/);

// Commands match the existing release automation and Apple's App Store Connect export.
const steps = plan({ build: 48, artifactsDir: "/tmp/ios-beta-test", marketingVersion: "" }, {});
assert.deepEqual(steps.commands.archive.slice(0, 9), [
  "xcodebuild", "-project", path.join(root, "apps/ios/Org2Mobile/Org2Mobile.xcodeproj"),
  "-scheme", "Org2Mobile", "-configuration", "Release", "-destination", "generic/platform=iOS",
]);
assert.ok(steps.commands.archive.includes("CURRENT_PROJECT_VERSION=48"));
assert.ok(steps.commands.archive.includes("-allowProvisioningUpdates"));
assert.ok(steps.commands.upload.includes("/tmp/ios-beta-test/ExportOptions-upload.plist"));
assert.ok(steps.commands.export.includes("/tmp/ios-beta-test/ExportOptions-export.plist"));
assert.match(exportOptionsPlist("upload"), /<key>destination<\/key><string>upload<\/string>/);
assert.match(exportOptionsPlist("export"), /<key>destination<\/key><string>export<\/string>/);
assert.match(exportOptionsPlist("upload"), new RegExp(`<key>teamID</key><string>${IOS_BETA.teamID}</string>`));
assert.match(exportOptionsPlist("upload"), /<key>method<\/key><string>app-store-connect<\/string>/);

// An App Store Connect API key is used when configured, and its identifiers are never printed.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-ios-beta-"));
const keyPath = path.join(tmp, "AuthKey_TEST.p8");
fs.writeFileSync(keyPath, "not a real key", "utf8");
const env = { OPENORG_ASC_PRIVATE_KEY_PATH: keyPath, OPENORG_ASC_KEY_ID: "KEYID12345", OPENORG_ASC_ISSUER_ID: "issuer-uuid" };
const keyed = plan({ build: 48, artifactsDir: tmp, marketingVersion: "" }, env);
assert.ok(keyed.commands.upload.includes("-authenticationKeyID"));
const shown = displayCommand(keyed.commands.upload);
for (const secretish of ["KEYID12345", "issuer-uuid", keyPath]) assert.ok(!shown.includes(secretish), `${secretish} is masked`);

// The CLI without --execute writes nothing and runs no xcodebuild.
const dryRun = spawnSync(process.execPath, ["tools/ios-beta.mjs", "archive", "--build", "1000000", "--artifacts-dir", path.join(tmp, "out")], { cwd: root, encoding: "utf8" });
assert.equal(dryRun.status, 0, dryRun.stderr);
assert.match(dryRun.stdout, /Read-only\. Add --execute/);
assert.equal(fs.existsSync(path.join(tmp, "out")), false, "no artifacts directory without --execute");
fs.rmSync(tmp, { recursive: true, force: true });

console.log("ios beta tool tests passed");
