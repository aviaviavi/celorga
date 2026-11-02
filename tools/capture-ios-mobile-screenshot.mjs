#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const projectPath = join(repoRoot, "apps", "ios", "Org2Mobile", "Org2Mobile.xcodeproj");
const demoCorpus = join(repoRoot, "examples", "macos-workspace-demo");
const outputPath = join(repoRoot, "docs", "site", "assets", "screenshots", "ios-mobile-approvals.png");
const derivedDataPath = "/tmp/celorga-ios-site-screenshot-derived";
const bundleID = "org.org2.mobile";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    env: options.env ?? process.env,
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      detail ? `${command} ${args.join(" ")} failed:\n${detail}` : `${command} ${args.join(" ")} failed`
    );
  }
  return result.stdout?.trim() ?? "";
}

function simctlJSON(...args) {
  return JSON.parse(execFileSync("xcrun", ["simctl", "list", ...args, "--json"], { encoding: "utf8" }));
}

function screenshotIPhone() {
  const screenshotDeviceName = "Org2 Screenshot iPhone";
  const devices = simctlJSON("devices", "available").devices;
  for (const runtimeDevices of Object.values(devices)) {
    const existing = runtimeDevices.find((device) => device.isAvailable && device.name === screenshotDeviceName);
    if (existing) return existing;
  }

  const runtime = simctlJSON("runtimes").runtimes
    .filter((candidate) => candidate.isAvailable && candidate.platform === "iOS")
    .sort((left, right) => right.version.localeCompare(left.version, undefined, { numeric: true }))[0];
  const deviceTypes = simctlJSON("devicetypes").devicetypes;
  const deviceType = deviceTypes.find((candidate) => candidate.name === "iPhone 17 Pro")
    ?? deviceTypes.find((candidate) => candidate.name.startsWith("iPhone"));
  if (!runtime || !deviceType) {
    throw new Error("No available iPhone simulator runtime was found.");
  }

  const udid = run(
    "xcrun",
    ["simctl", "create", screenshotDeviceName, deviceType.identifier, runtime.identifier],
    { capture: true }
  );
  return { udid, name: screenshotDeviceName, state: "Shutdown", isAvailable: true };
}

function main() {
  if (process.platform !== "darwin") {
    throw new Error("Org2 Mobile screenshots can only be rendered on macOS.");
  }
  if (!existsSync(demoCorpus)) {
    throw new Error(`Demo corpus not found: ${demoCorpus}`);
  }
  // The iOS app no longer reads a corpus folder on the phone; Approvals come
  // from a paired host. Until a host fixture exists for the simulator, this
  // screenshot has to be captured from a simulator paired with a demo host.
  throw new Error(
    "The iOS app reads Approvals from a paired host, not a local corpus. " +
    "Pair a simulator with a host serving examples/macos-workspace-demo and capture " +
    "docs/site/assets/screenshots/ios-mobile-approvals.png with `xcrun simctl io booted screenshot`."
  );

  const device = screenshotIPhone();
  if (device.state !== "Booted") {
    run("xcrun", ["simctl", "boot", device.udid]);
  }
  run("xcrun", ["simctl", "bootstatus", device.udid, "-b"]);
  run("xcrun", ["simctl", "ui", device.udid, "appearance", "light"]);
  run("xcrun", [
    "simctl", "status_bar", device.udid, "override",
    "--time", "9:41",
    "--batteryState", "charged",
    "--batteryLevel", "100",
    "--wifiBars", "3",
    "--cellularBars", "4",
  ]);

  run("xcodebuild", [
    "-project", projectPath,
    "-scheme", "Org2Mobile",
    "-configuration", "Debug",
    "-destination", `platform=iOS Simulator,id=${device.udid}`,
    "-derivedDataPath", derivedDataPath,
    "CODE_SIGNING_ALLOWED=NO",
    "build",
  ]);

  const appPath = join(derivedDataPath, "Build", "Products", "Debug-iphonesimulator", "Org2Mobile.app");
  spawnSync("xcrun", ["simctl", "terminate", device.udid, bundleID], { stdio: "ignore" });
  spawnSync("xcrun", ["simctl", "uninstall", device.udid, bundleID], { stdio: "ignore" });
  run("xcrun", ["simctl", "install", device.udid, appPath]);
  run("xcrun", ["simctl", "launch", device.udid, bundleID], {
    env: {
      ...process.env,
      SIMCTL_CHILD_ORG2_DEBUG_CORPUS_PATH: demoCorpus,
      SIMCTL_CHILD_ORG2_DEBUG_INITIAL_TAB: "approvals",
      SIMCTL_CHILD_ORG2_DEBUG_SUPPRESS_NOTIFICATIONS: "1",
    },
  });

  // The first synthetic-corpus parse can take a few seconds on a clean simulator.
  // Wait for the approval cards rather than capturing the initial empty state.
  execFileSync("sleep", ["18"]);
  mkdirSync(dirname(outputPath), { recursive: true });
  run("xcrun", ["simctl", "io", device.udid, "screenshot", outputPath]);
  run("npm", ["run", "celorga", "--", "publish", "docs-site", "--config", "celorga.json"]);
  console.log(`Rendered ${outputPath}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
