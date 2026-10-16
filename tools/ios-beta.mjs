#!/usr/bin/env node
// iOS-only TestFlight beta: preflight, archive, local export, and upload for Org2Mobile.
//
// This is separate from tools/release-openorg.mjs, which releases the whole product
// (npm, DMGs, tags, TestFlight groups, and beta review). It reuses the same team,
// TestFlight app, and App Store Connect settings.
//
// Every command is read-only unless --execute is given. Archive and upload use Xcode
// automatic signing with -allowProvisioningUpdates. That uses the Apple account signed
// into Xcode (or an App Store Connect API key given through OPENORG_ASC_* variables),
// and Xcode may add capabilities such as Push to Talk to the App ID. Run them only on the
// build Mac, by or for the account holder. The tool never reads, stores, or prints credentials.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { TESTFLIGHT, appStoreConnectAuthenticationArguments } from "./release-openorg.mjs";

const repoRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const iosRoot = join(repoRoot, "apps", "ios", "Org2Mobile");
const projectPath = join(iosRoot, "Org2Mobile.xcodeproj");
const pbxprojPath = join(projectPath, "project.pbxproj");
const appEntitlementsPath = join(iosRoot, "Org2Mobile", "Org2Mobile.entitlements");
const extensionEntitlementsPath = join(iosRoot, "Org2ShareExtension", "Org2ShareExtension.entitlements");
const infoPlistPath = join(iosRoot, "Org2Mobile", "Info.plist");

export const IOS_BETA = Object.freeze({
  teamID: "9MW3N969TR",
  scheme: "Org2Mobile",
  appBundleID: "org.org2.mobile",
  extensionBundleID: "org.org2.mobile.ShareExtension",
  appGroup: "group.org.org2.mobile",
  pushToTalkTopic: "org.org2.mobile.voip-ptt",
  minimumXcodeMajor: 26,
  testFlightAppID: TESTFLIGHT.appId,
  internalGroupName: TESTFLIGHT.internalGroupName,
});

function usage() {
  return `Usage:
  node tools/ios-beta.mjs check   [--build N] [--json]
  node tools/ios-beta.mjs archive --build N [--artifacts-dir DIR] [--execute]
  node tools/ios-beta.mjs export  --build N [--artifacts-dir DIR] [--execute]
  node tools/ios-beta.mjs upload  --build N [--artifacts-dir DIR] [--execute]

check    Offline preflight: toolchain, clean commit, bundle IDs, team, entitlements, background modes.
archive  Signed Release archive (automatic signing, -allowProvisioningUpdates).
export   Local .ipa from the archive for inspection; nothing leaves the Mac.
upload   Export straight to App Store Connect (TestFlight). Needs the account holder.

Without --execute, archive, export, and upload print the exact commands and change nothing.
--build must be higher than every build already uploaded for app ${TESTFLIGHT.appId}.`;
}

export function parseArguments(argv) {
  const options = { command: argv[0], build: null, artifactsDir: "", execute: false, json: false, marketingVersion: "" };
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--build") options.build = Number(argv[++index]);
    else if (arg === "--artifacts-dir") options.artifactsDir = argv[++index] ?? "";
    else if (arg === "--marketing-version") options.marketingVersion = argv[++index] ?? "";
    else if (arg === "--execute") options.execute = true;
    else if (arg === "--json") options.json = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!["check", "archive", "export", "upload"].includes(options.command)) throw new Error(usage());
  if (options.build !== null && (!Number.isInteger(options.build) || options.build <= 0)) {
    throw new Error("--build must be a positive integer");
  }
  if (options.command !== "check" && options.build === null) throw new Error("--build N is required");
  return options;
}

function capture(command, args, cwd = repoRoot) {
  const result = spawnSync(command, args, { cwd, encoding: "utf8" });
  return { ok: result.status === 0, stdout: String(result.stdout || "").trim(), stderr: String(result.stderr || "").trim() };
}

function settingValues(pbxproj, key) {
  return [...pbxproj.matchAll(new RegExp(`\\b${key} = ([^;]+);`, "g"))].map((match) => match[1].replace(/"/g, "").trim());
}

export function audioBackgroundModeChecks(modes) {
  return [
    ["push-to-talk", "background-push-to-talk", "receive Push to Talk pushes"],
    ["audio", "background-audio", "activate the Push to Talk audio session while backgrounded"],
  ].map(([mode, name, purpose]) => ({
    name, status: Array.isArray(modes) && modes.includes(mode) ? "pass" : "fail",
    detail: `UIBackgroundModes must contain ${mode} to ${purpose}`,
  }));
}

/** Check the built product too: simulator callbacks do not enforce background capabilities. */
export function verifyAudioBackgroundModes(appPath, captureCommand = capture) {
  const result = captureCommand("/usr/bin/plutil", ["-extract", "UIBackgroundModes", "json", "-o", "-", join(appPath, "Info.plist")]);
  if (!result.ok) throw new Error(`Could not inspect built app background modes: ${appPath}`);
  const modes = JSON.parse(result.stdout);
  const failed = audioBackgroundModeChecks(modes).filter(check => check.status === "fail");
  if (failed.length) throw new Error(`Built app cannot run background audio approvals: ${failed.map(check => check.detail).join("; ")}`);
  return modes;
}

/** Offline checks. Each entry is { name, status: "pass"|"warn"|"fail", detail }. */
export function preflight({ build = null, marketingVersion = "", environment = process.env } = {}) {
  const checks = [];
  const add = (name, ok, detail, severity = "fail") => checks.push({ name, status: ok ? "pass" : severity, detail });
  const pbxproj = readFileSync(pbxprojPath, "utf8");
  const appEntitlements = readFileSync(appEntitlementsPath, "utf8");
  const extensionEntitlements = readFileSync(extensionEntitlementsPath, "utf8");
  const infoPlist = readFileSync(infoPlistPath, "utf8");

  const xcode = capture("xcodebuild", ["-version"]);
  const xcodeMajor = Number((/Xcode (\d+)/.exec(xcode.stdout) || [])[1] || 0);
  add("xcode", xcodeMajor >= IOS_BETA.minimumXcodeMajor,
    xcode.ok ? `${xcode.stdout.split("\n").join(" ")}; App Store Connect uploads need Xcode ${IOS_BETA.minimumXcodeMajor}+ and the iOS ${IOS_BETA.minimumXcodeMajor} SDK` : "xcodebuild not found",
    "warn");

  const head = capture("git", ["rev-parse", "HEAD"]);
  const branch = capture("git", ["rev-parse", "--abbrev-ref", "HEAD"]);
  const dirty = capture("git", ["status", "--porcelain", "--untracked-files=no"]);
  add("clean-commit", head.ok && dirty.ok && dirty.stdout === "",
    head.ok ? `${branch.stdout} @ ${head.stdout.slice(0, 12)}${dirty.stdout ? " with uncommitted tracked changes" : ""}` : "not a git checkout");

  const teams = new Set(settingValues(pbxproj, "DEVELOPMENT_TEAM"));
  add("team", teams.size === 1 && teams.has(IOS_BETA.teamID), `DEVELOPMENT_TEAM ${[...teams].join(", ") || "missing"}`);
  const styles = new Set(settingValues(pbxproj, "CODE_SIGN_STYLE"));
  add("automatic-signing", styles.size === 1 && styles.has("Automatic"), `CODE_SIGN_STYLE ${[...styles].join(", ") || "missing"}`);
  const bundleIDs = new Set(settingValues(pbxproj, "PRODUCT_BUNDLE_IDENTIFIER"));
  add("bundle-ids", bundleIDs.has(IOS_BETA.appBundleID) && bundleIDs.has(IOS_BETA.extensionBundleID), [...bundleIDs].join(", "));
  add("release-aps-environment", settingValues(pbxproj, "APS_ENVIRONMENT").includes("production"),
    "Release builds sign aps-environment=production (TestFlight push and Push to Talk tokens use production APNs)");

  add("entitlement-push-to-talk", /<key>com\.apple\.developer\.push-to-talk<\/key>\s*<true\/>/.test(appEntitlements),
    "com.apple.developer.push-to-talk (App ID capability: Push to Talk)");
  add("entitlement-push", /<key>aps-environment<\/key>\s*<string>\$\(APS_ENVIRONMENT\)<\/string>/.test(appEntitlements),
    "aps-environment (App ID capability: Push Notifications)");
  add("entitlement-app-group", appEntitlements.includes(IOS_BETA.appGroup) && extensionEntitlements.includes(IOS_BETA.appGroup),
    `${IOS_BETA.appGroup} on the app and the share extension (App ID capability: App Groups)`);
  const backgroundArray = /<key>UIBackgroundModes<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(infoPlist)?.[1] ?? "";
  const backgroundModes = [...backgroundArray.matchAll(/<string>([^<]+)<\/string>/g)].map(match => match[1]);
  checks.push(...audioBackgroundModeChecks(backgroundModes));
  add("microphone-usage", /<key>NSMicrophoneUsageDescription<\/key>\s*<string>[^<]+<\/string>/.test(infoPlist),
    "NSMicrophoneUsageDescription present");

  const projectBuild = Number(settingValues(pbxproj, "CURRENT_PROJECT_VERSION")[0] || 0);
  const projectVersion = settingValues(pbxproj, "MARKETING_VERSION")[0] || "";
  if (build !== null) {
    add("build-number", build > projectBuild,
      `build ${build} (project ${projectBuild}); it must also be higher than the latest build uploaded to App Store Connect, which this offline check cannot see`);
  } else {
    add("build-number", false, `no --build given; the project is at ${projectBuild}`, "warn");
  }

  let ascKey = "not configured: Xcode uses the Apple account signed in under Settings › Accounts";
  try {
    if (appStoreConnectAuthenticationArguments(environment).length) ascKey = "configured through OPENORG_ASC_* (values not shown)";
  } catch (error) {
    add("asc-api-key", false, error instanceof Error ? error.message : String(error));
  }
  checks.push({ name: "signing-account", status: "info", detail: ascKey });

  return {
    version: marketingVersion || projectVersion,
    build,
    commit: head.ok ? head.stdout : null,
    branch: branch.ok ? branch.stdout : null,
    checks,
    ok: checks.every((check) => check.status !== "fail"),
  };
}

export function exportOptionsPlist(destination) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>destination</key><string>${destination}</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>method</key><string>app-store-connect</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>${IOS_BETA.teamID}</string>
<key>uploadSymbols</key><true/>
</dict></plist>
`;
}

export function plan(options, environment = process.env) {
  const version = options.marketingVersion || settingValues(readFileSync(pbxprojPath, "utf8"), "MARKETING_VERSION")[0];
  const artifactsDir = resolve(options.artifactsDir || join("/tmp", `celorga-ios-beta-${version}-${options.build}`));
  const archivePath = join(artifactsDir, "Celorga.xcarchive");
  const authentication = appStoreConnectAuthenticationArguments(environment);
  const archive = ["xcodebuild",
    "-project", projectPath,
    "-scheme", IOS_BETA.scheme,
    "-configuration", "Release",
    "-destination", "generic/platform=iOS",
    "-archivePath", archivePath,
    "-derivedDataPath", join(artifactsDir, "derived-data"),
    "archive",
    `MARKETING_VERSION=${version}`,
    `CURRENT_PROJECT_VERSION=${options.build}`,
    "-allowProvisioningUpdates",
    ...authentication,
  ];
  const exportCommand = (destination, folder) => ["xcodebuild",
    "-exportArchive",
    "-archivePath", archivePath,
    "-exportPath", join(artifactsDir, folder),
    "-exportOptionsPlist", join(artifactsDir, `ExportOptions-${destination}.plist`),
    "-allowProvisioningUpdates",
    ...authentication,
  ];
  return {
    version,
    build: options.build,
    artifactsDir,
    archivePath,
    commands: {
      archive,
      export: exportCommand("export", "ipa"),
      upload: exportCommand("upload", "upload"),
    },
  };
}

/** Commands are printed for review; App Store Connect key identifiers and paths are masked. */
export function displayCommand(command) {
  const masked = new Set(["-authenticationKeyPath", "-authenticationKeyID", "-authenticationKeyIssuerID"]);
  return command.map((argument, index) => (masked.has(command[index - 1]) ? "<redacted>" : quote(argument))).join(" ");
}

function quote(argument) {
  return /^[\w./:=@+-]+$/.test(argument) ? argument : `'${argument.replace(/'/g, "'\\''")}'`;
}

function printPreflight(result) {
  for (const check of result.checks) console.log(`${check.status.toUpperCase().padEnd(5)} ${check.name}: ${check.detail}`);
  console.log(result.ok ? "\nPreflight passed." : "\nPreflight failed.");
}

function main() {
  const options = parseArguments(process.argv.slice(2));
  const result = preflight(options);
  if (options.command === "check") {
    if (options.json) console.log(JSON.stringify(result, null, 2));
    else printPreflight(result);
    process.exit(result.ok ? 0 : 1);
  }
  const steps = plan(options);
  const command = steps.commands[options.command];
  if (!options.execute) {
    printPreflight(result);
    console.log(`\nWould run (${options.command}):\n  ${displayCommand(command)}`);
    console.log("\nRead-only. Add --execute on the build Mac to run it.");
    return;
  }
  if (!result.ok) throw new Error("Preflight failed; fix the failures above before archiving.");
  const xcodeCheck = result.checks.find((check) => check.name === "xcode");
  if (options.command !== "export" && xcodeCheck?.status !== "pass") {
    throw new Error(`Xcode ${IOS_BETA.minimumXcodeMajor}+ is required to archive or upload for TestFlight.`);
  }
  mkdirSync(steps.artifactsDir, { recursive: true });
  if (options.command !== "archive") {
    if (!existsSync(steps.archivePath)) throw new Error(`Archive missing: run archive --build ${options.build} first.`);
    verifyAudioBackgroundModes(join(steps.archivePath, "Products", "Applications", "Org2Mobile.app"));
    const destination = options.command === "upload" ? "upload" : "export";
    writeFileSync(join(steps.artifactsDir, `ExportOptions-${destination}.plist`), exportOptionsPlist(destination));
  }
  writeFileSync(join(steps.artifactsDir, "ios-beta.json"), JSON.stringify({
    version: steps.version, build: steps.build, commit: result.commit, branch: result.branch,
    lastCommand: options.command, at: new Date().toISOString(),
  }, null, 2));
  execFileSync(command[0], command.slice(1), { stdio: "inherit", cwd: repoRoot });
  if (options.command === "archive") {
    verifyAudioBackgroundModes(join(steps.archivePath, "Products", "Applications", "Org2Mobile.app"));
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
