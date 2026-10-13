#!/usr/bin/env node
// Compiles the iOS audio approval policy (AudioApprovalCore.swift) for macOS and runs its
// behavioral checks. Hardware (Push to Talk, AirPods, locked phone) is simulated as events;
// physical-device behavior still needs a device.
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const core = path.join(root, "apps/ios/Org2Mobile/Org2Mobile/AudioApprovalCore.swift");
const harness = path.join(root, "test/fixtures/ios-audio-approval-core/main.swift");

if (process.platform !== "darwin" || spawnSync("xcrun", ["--find", "swiftc"]).status !== 0) {
  console.log("ios audio approval core tests skipped (needs macOS with swiftc)");
  process.exit(0);
}

const out = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-audio-core-"));
try {
  const binary = path.join(out, "audio-approval-core-tests");
  execFileSync("xcrun", ["swiftc", "-swift-version", "6", "-o", binary, core, harness], { stdio: "inherit" });
  execFileSync(binary, { stdio: "inherit" });
  console.log("ios audio approval core tests passed");
} finally {
  fs.rmSync(out, { recursive: true, force: true });
}
