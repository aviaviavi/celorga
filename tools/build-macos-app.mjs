#!/usr/bin/env node

import "./celorga-env.mjs";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  closeSync,
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { requestAppQuit } from "./macos-app-quit.mjs";
import { installStagedAppBundle } from "./atomic-app-bundle.mjs";
import {
  detectNodeArchitecture,
  duckDBBindingPackagesForRuntime,
} from "./macos-runtime-node.mjs";
import {
  OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS,
  OPENORG_SPARKLE_PUBLIC_KEY,
  openOrgSparkleFeedURL,
} from "./openorg-sparkle.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;
const packageDir = join(repoRoot, "apps", "macos", "Org2Workspace");
const buildOptions = parseBuildOptions(process.argv.slice(2));
const isTrustedLocalBuild = buildOptions.localFast || buildOptions.localOptimized;
const appName = process.env.ORG2_WORKSPACE_APP_NAME ?? "OpenOrg";
const displayName = process.env.ORG2_WORKSPACE_DISPLAY_NAME ?? "Celorga";
const appPath = resolve(
  process.env.ORG2_WORKSPACE_APP_PATH ?? join(homedir(), "Applications", `${appName}.app`)
);
const bundleIdentifier = process.env.ORG2_WORKSPACE_BUNDLE_ID ?? "org.org2.workspace";
const requestedSigningIdentity = process.env.ORG2_WORKSPACE_CODE_SIGN_IDENTITY?.trim();
const executableName = "Org2Workspace";
const iconPath = resolve(
  process.env.ORG2_WORKSPACE_ICON_PATH
    ?? join(packageDir, "Sources", "Org2Workspace", "Resources", "OpenOrgAppIcon.png")
);
const swiftBuildArch = process.env.ORG2_WORKSPACE_SWIFT_ARCH ?? defaultSwiftBuildArch();
const configuredSwiftScratchPath = process.env.ORG2_WORKSPACE_SWIFT_SCRATCH_PATH?.trim();
const swiftScratchPath = configuredSwiftScratchPath
  ? resolve(configuredSwiftScratchPath)
  : buildOptions.localOptimized
    ? join(repoRoot, ".build", "macos-local-optimized")
    : "";
const swiftBuildConfiguration = resolveBuildConfiguration();
const includesBundledRuntimes = swiftBuildConfiguration === "release" || buildOptions.localFast;
const bundledNodePath = process.env.ORG2_WORKSPACE_NODE_PATH?.trim()
  || (includesBundledRuntimes ? discoverNodePath() : "");
const bundledNodeArchitecture = bundledNodePath
  ? detectNodeArchitecture(bundledNodePath)
  : null;
const bundledWhisperCppPath = process.env.ORG2_WORKSPACE_WHISPER_CPP_PATH?.trim()
  || (includesBundledRuntimes ? discoverWhisperCppPath() : "");
const bundledWhisperModelPath = process.env.ORG2_WORKSPACE_WHISPER_MODEL_PATH?.trim()
  || (includesBundledRuntimes ? discoverWhisperModelPath() : "");
const googleOAuthConfiguration = resolveGoogleOAuthConfiguration();
const googleOAuthClientID = googleOAuthConfiguration.clientID;
const googleOAuthClientSecret = googleOAuthConfiguration.clientSecret;
const appEntitlementsPath = resolve(
  process.env.ORG2_WORKSPACE_APP_ENTITLEMENTS
    ?? join(packageDir, "OpenOrg.entitlements")
);
const nodeEntitlementsPath = resolve(
  process.env.ORG2_WORKSPACE_NODE_ENTITLEMENTS
    ?? join(
      packageDir,
      bundledNodeArchitecture === "x64"
        ? "OpenOrgNodeIntel.entitlements"
        : "OpenOrgNode.entitlements"
    )
);
function sparkleUpdateConfiguration() {
  const architecture = swiftBuildArch || (process.arch === "x64" ? "x86_64" : "arm64");
  return {
    architecture,
    enabled: bundleIdentifier === "org.org2.workspace",
    feedURL: openOrgSparkleFeedURL(architecture),
    intervalSeconds: OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS,
  };
}

function parseBuildOptions(arguments_) {
  const options = {
    allowDailyDebug: false,
    configuration: "",
    googleOAuthClientJSON: "",
    help: false,
    localFast: false,
    localOptimized: false,
    printConfiguration: false,
    requireGoogleOAuthClient: false,
    restart: false,
    skipRuntimeBuild: false,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    switch (argument) {
      case "--allow-daily-debug":
        options.allowDailyDebug = true;
        break;
      case "--configuration":
        index += 1;
        if (index >= arguments_.length) {
          throw new Error("--configuration requires debug or release");
        }
        options.configuration = arguments_[index];
        break;
      case "--google-oauth-client-json":
        index += 1;
        if (index >= arguments_.length) {
          throw new Error("--google-oauth-client-json requires a path");
        }
        options.googleOAuthClientJSON = arguments_[index];
        break;
      case "--local-optimized":
        options.localOptimized = true;
        break;
      case "--local-fast":
        options.localFast = true;
        break;
      case "--print-configuration":
        options.printConfiguration = true;
        break;
      case "--require-google-oauth-client":
        options.requireGoogleOAuthClient = true;
        break;
      case "--skip-runtime-build":
        options.skipRuntimeBuild = true;
        break;
      case "--restart":
        options.restart = true;
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      default:
        throw new Error(`Unknown build option: ${argument}`);
    }
  }
  return options;
}

function resolveBuildConfiguration() {
  const configured = buildOptions.configuration
    || process.env.ORG2_WORKSPACE_SWIFT_CONFIGURATION?.trim()
    || (bundleIdentifier === "org.org2.workspace" ? "release" : "debug");
  if (configured !== "debug" && configured !== "release") {
    throw new Error(`Unsupported Swift build configuration: ${configured}. Use debug or release.`);
  }
  return configured;
}

function resolveGoogleOAuthConfiguration() {
  const jsonPath = buildOptions.googleOAuthClientJSON
    || process.env.ORG2_GOOGLE_OAUTH_CLIENT_JSON?.trim()
    || "";
  const environmentClientID = process.env.ORG2_GOOGLE_OAUTH_CLIENT_ID?.trim() || "";
  const environmentClientSecret = process.env.ORG2_GOOGLE_OAUTH_CLIENT_SECRET?.trim() || "";
  if (jsonPath && (environmentClientID || environmentClientSecret)) {
    throw new Error(
      "Configure Google OAuth with either a Desktop client JSON or the separate client environment variables, not both."
    );
  }
  if (!jsonPath) {
    if (Boolean(environmentClientID) !== Boolean(environmentClientSecret)) {
      throw new Error(
        "ORG2_GOOGLE_OAUTH_CLIENT_ID and ORG2_GOOGLE_OAUTH_CLIENT_SECRET must be configured together."
      );
    }
    return {
      clientID: environmentClientID,
      clientSecret: environmentClientSecret,
      source: environmentClientID || environmentClientSecret ? "environment" : null,
    };
  }

  const resolvedPath = resolve(jsonPath);
  let envelope;
  try {
    envelope = JSON.parse(readFileSync(resolvedPath, "utf8"));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Could not read Google OAuth Desktop client JSON at ${resolvedPath}: ${detail}`);
  }
  if (!envelope?.installed || envelope.web) {
    throw new Error(
      `Google OAuth client JSON at ${resolvedPath} must contain an installed Desktop client, not a Web application client.`
    );
  }
  const clientID = typeof envelope.installed.client_id === "string"
    ? envelope.installed.client_id.trim()
    : "";
  const clientSecret = typeof envelope.installed.client_secret === "string"
    ? envelope.installed.client_secret.trim()
    : "";
  if (!clientID.endsWith(".apps.googleusercontent.com")) {
    throw new Error(`Google OAuth Desktop client JSON at ${resolvedPath} has no valid client ID.`);
  }
  if (!clientSecret) {
    throw new Error(`Google OAuth Desktop client JSON at ${resolvedPath} has no client secret.`);
  }
  return { clientID, clientSecret, source: "desktop-client-json" };
}

function firstExistingPath(candidates) {
  return candidates.find((candidate) => candidate && existsSync(candidate)) ?? "";
}

function discoverNodePath() {
  return firstExistingPath([
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    process.execPath,
  ]);
}

function discoverWhisperCppPath() {
  return firstExistingPath([
    "/opt/homebrew/bin/whisper-cli",
    "/usr/local/bin/whisper-cli",
  ]);
}

function discoverWhisperModelPath() {
  return firstExistingPath([
    join(homedir(), "Library", "Application Support", "org2", "whisper", "ggml-base.en.bin"),
  ]);
}

function buildUsage() {
  return `Usage: node tools/build-macos-app.mjs [options]

Options:
  --configuration MODE    Build debug or release (daily app default: release)
  --allow-daily-debug     Explicitly allow a debug build at org.org2.workspace
  --google-oauth-client-json PATH
                          Bundle a Google OAuth Desktop client without copying its JSON into source
  --local-fast            Build the self-contained local app without Swift optimization, reusing
                          the debug cache shared by tests; distributable releases remain optimized
  --local-optimized       Keep -O optimization while enabling incremental Swift compilation; this
                          is slower than --local-fast but useful for local performance profiling
  --print-configuration   Print the resolved mode and paths without building
  --require-google-oauth-client
                          Fail unless a complete Google OAuth Desktop client is bundled
  --skip-runtime-build    Reuse the shared runtime already validated by the release command
  --restart               Build while the installed app runs, then quit, replace, and relaunch it
  --help                  Show this help`;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
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

function defaultSwiftBuildArch() {
  if (process.platform !== "darwin") {
    return "";
  }
  const result = spawnSync("sysctl", ["-n", "hw.optional.arm64"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return result.stdout?.trim() === "1" ? "arm64" : "";
}

function swiftBuildArgs(...args) {
  const scratchArgs = swiftScratchPath ? [...args, "--scratch-path", swiftScratchPath] : args;
  const architectureArgs = swiftBuildArch ? [...scratchArgs, "--arch", swiftBuildArch] : scratchArgs;
  const configurationArgs = swiftBuildConfiguration
    ? [...architectureArgs, "--configuration", swiftBuildConfiguration]
    : architectureArgs;
  if (!buildOptions.localOptimized) return configurationArgs;
  return [
    ...configurationArgs,
    "-Xswiftc", "-no-whole-module-optimization",
    "-Xswiftc", "-incremental",
    "-Xswiftc", "-enable-batch-mode",
  ];
}

function availableCodeSigningIdentities() {
  if (process.platform !== "darwin") {
    return [];
  }
  const result = spawnSync("security", ["find-identity", "-v", "-p", "codesigning"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return [];
  }
  return result.stdout
    .split(/\n/)
    .map((line) => {
      const match = line.match(/^\s*\d+\)\s+[A-Fa-f0-9]+\s+"([^"]+)"/);
      return match?.[1];
    })
    .filter(Boolean);
}

function defaultCodeSigningIdentity() {
  const identities = availableCodeSigningIdentities();
  return (
    identities.find((identity) => identity.startsWith("Apple Development:"))
    ?? identities.find((identity) => identity.startsWith("Developer ID Application:"))
    ?? identities[0]
    ?? "-"
  );
}

function codeSigningIdentity() {
  if (!requestedSigningIdentity) {
    return defaultCodeSigningIdentity();
  }
  if (requestedSigningIdentity === "adhoc" || requestedSigningIdentity === "ad-hoc") {
    return "-";
  }
  return requestedSigningIdentity;
}

function usesHardenedRuntime(identity) {
  return identity.startsWith("Developer ID Application:");
}

function codesignArgs(identity, path, options = {}) {
  const args = ["--force", "--sign", identity];
  if (usesHardenedRuntime(identity)) {
    args.push("--timestamp", "--options", "runtime");
    if (options.entitlements) {
      args.push("--entitlements", options.entitlements);
    }
  }
  if (options.identifier) {
    args.push("--identifier", options.identifier);
  }
  args.push(path);
  return args;
}

function verifyNodeRuntime(executable) {
  const result = spawnSync(executable, ["-e", "process.stdout.write(process.arch)"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      `Signed bundled Node.js failed its launch check${detail ? `:\n${detail}` : "."}`
    );
  }
  if (result.stdout.trim() !== bundledNodeArchitecture) {
    throw new Error(
      `Signed bundled Node.js reported ${result.stdout.trim() || "no architecture"}; expected ${bundledNodeArchitecture}`
    );
  }
}

const machOMagics = new Set([
  0xfeedface,
  0xcefaedfe,
  0xfeedfacf,
  0xcffaedfe,
  0xcafebabe,
  0xbebafeca,
  0xcafebabf,
  0xbfbafeca,
]);

function isMachOFile(path) {
  let descriptor;
  try {
    descriptor = openSync(path, "r");
    const header = Buffer.allocUnsafe(4);
    return readSync(descriptor, header, 0, header.length, 0) === header.length
      && machOMagics.has(header.readUInt32BE(0));
  } catch {
    return false;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function nestedMachOPaths(root) {
  const paths = [];
  function visit(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(path);
        continue;
      }
      if (!entry.isFile()) continue;
      if (isMachOFile(path)) {
        paths.push(path);
      }
    }
  }
  visit(root);
  return paths.sort((left, right) => right.length - left.length || left.localeCompare(right));
}

function xmlEscape(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function runningProcessesForBinary(binaryPath) {
  const result = spawnSync("pgrep", ["-f", binaryPath], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return [];
  }
  return result.stdout
    .trim()
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function assertInstalledAppIsStopped(binaryPath) {
  const runningPids = runningProcessesForBinary(binaryPath);
  if (runningPids.length > 0) {
    throw new Error(`${appName} is running from ${appPath}. Quit it and rerun this command.`);
  }
}

function waitForInstalledAppToStop(binaryPath, timeoutMilliseconds = 30_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  const waitSignal = new Int32Array(new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT));
  let runningPids = runningProcessesForBinary(binaryPath);
  while (runningPids.length > 0 && Date.now() < deadline) {
    Atomics.wait(waitSignal, 0, 0, 100);
    runningPids = runningProcessesForBinary(binaryPath);
  }
  return runningPids;
}

function quitRunningInstalledApp(binaryPath) {
  const runningPids = runningProcessesForBinary(binaryPath);
  if (runningPids.length === 0) return;

  console.log(`Build verified. Asking ${appName} to save and quit...`);
  // Do not wait for the Apple event reply: the app may be showing a quit
  // confirmation. A second event explicitly overrides pending shutdown.
  const quitScript = `ignoring application responses
 tell application id ${JSON.stringify(bundleIdentifier)} to quit
end ignoring`;
  requestAppQuit({
    sendQuit: () => spawnSync("osascript", ["-e", quitScript], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 5_000,
    }),
    waitForStop: (timeout) => waitForInstalledAppToStop(binaryPath, timeout),
    onRetry: () => console.log(`${appName} is still running. Sending Quit again to confirm restart...`),
  });
}

function launchInstalledApp() {
  console.log(`Opening the updated ${appName}...`);
  run("open", ["-n", appPath]);
}

function writeInfoPlist(bundlePath) {
  const contentsDir = join(bundlePath, "Contents");
  const updates = sparkleUpdateConfiguration();
  const sparkleConfiguration = updates.enabled
    ? `
  <key>SUFeedURL</key>
  <string>${updates.feedURL}</string>
  <key>SUPublicEDKey</key>
  <string>${OPENORG_SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>${OPENORG_SPARKLE_CHECK_INTERVAL_SECONDS}</integer>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUEnableSystemProfiling</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>`
    : "";
  const googleOAuthConfiguration = `${googleOAuthClientID
    ? `
  <key>OpenOrgGoogleOAuthClientID</key>
  <string>${xmlEscape(googleOAuthClientID)}</string>`
    : ""}${googleOAuthClientSecret
    ? `
  <key>OpenOrgGoogleOAuthClientSecret</key>
  <string>${xmlEscape(googleOAuthClientSecret)}</string>`
    : ""}`;
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${xmlEscape(displayName)}</string>
  <key>CFBundleExecutable</key>
  <string>${xmlEscape(executableName)}</string>
  <key>CFBundleIdentifier</key>
  <string>${xmlEscape(bundleIdentifier)}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${xmlEscape(displayName)}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${xmlEscape(packageVersion)}</string>
  <key>CFBundleVersion</key>
  <string>${xmlEscape(packageVersion)}</string>${sparkleConfiguration}${googleOAuthConfiguration}
  <key>Org2BuildConfiguration</key>
  <string>${xmlEscape(swiftBuildConfiguration)}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>${xmlEscape(displayName)} serves document links that you explicitly publish to your local network.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>${xmlEscape(displayName)} records microphone audio for meeting notes.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>${xmlEscape(displayName)} uses ScreenCaptureKit to capture system and call audio for meeting notes.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>${xmlEscape(displayName)} may use macOS Speech recognition as a fallback when its bundled local transcriber cannot run.</string>
</dict>
</plist>
`;
  writeFileSync(join(contentsDir, "Info.plist"), plist);
}

function copySparkleFramework(buildProductsDir, contentsDir) {
  const source = join(buildProductsDir, "Sparkle.framework");
  if (!existsSync(source)) {
    throw new Error(`Sparkle.framework was not produced in ${buildProductsDir}`);
  }
  const frameworksDir = join(contentsDir, "Frameworks");
  const destination = join(frameworksDir, "Sparkle.framework");
  mkdirSync(frameworksDir, { recursive: true });
  run("ditto", [source, destination], { capture: true });
  return destination;
}

function signSparkleFramework(frameworkPath, identity) {
  const versionRoot = join(frameworkPath, "Versions", "B");
  const nestedTargets = [
    { path: join(versionRoot, "XPCServices", "Installer.xpc") },
    { path: join(versionRoot, "XPCServices", "Downloader.xpc"), preserveEntitlements: true },
    { path: join(versionRoot, "Autoupdate") },
    { path: join(versionRoot, "Updater.app") },
  ];
  for (const target of nestedTargets) {
    if (!existsSync(target.path)) continue;
    const args = ["--force", "--sign", identity];
    if (usesHardenedRuntime(identity)) {
      args.push("--timestamp", "--options", "runtime");
    }
    if (target.preserveEntitlements) {
      args.push("--preserve-metadata=entitlements");
    }
    args.push(target.path);
    run("codesign", args);
  }
  run("codesign", codesignArgs(identity, frameworkPath));
}

// Org2WorkspaceCore resolves its resources through WorkspaceResources, which
// reads Contents/Resources first. Copy every file so no resource depends on the
// build machine's SwiftPM bundle path (issue #589: launch crash elsewhere).
function copyCoreResources(resourcesDir) {
  const coreResourcesDir = join(packageDir, "Sources", "Org2WorkspaceCore", "Resources");
  for (const entry of readdirSync(coreResourcesDir, { withFileTypes: true })) {
    if (!entry.isFile() || entry.name.startsWith(".")) continue;
    copyFileSync(join(coreResourcesDir, entry.name), join(resourcesDir, entry.name));
  }
}

function writeIconSet(sourcePngPath, resourcesDir) {
  if (!existsSync(sourcePngPath)) {
    return;
  }

  copyFileSync(sourcePngPath, join(resourcesDir, "AppIcon.png"));

  if (process.platform !== "darwin") {
    return;
  }

  const iconsetParentDir = mkdtempSync(join(tmpdir(), "org2-appicon-"));
  const iconsetDir = join(iconsetParentDir, "AppIcon.iconset");
  mkdirSync(iconsetDir, { recursive: true });
  try {
    const sizes = [
      [16, "icon_16x16.png"],
      [32, "icon_16x16@2x.png"],
      [32, "icon_32x32.png"],
      [64, "icon_32x32@2x.png"],
      [128, "icon_128x128.png"],
      [256, "icon_128x128@2x.png"],
      [256, "icon_256x256.png"],
      [512, "icon_256x256@2x.png"],
      [512, "icon_512x512.png"],
      [1024, "icon_512x512@2x.png"],
    ];
    for (const [size, name] of sizes) {
      run("sips", ["-z", String(size), String(size), sourcePngPath, "--out", join(iconsetDir, name)], {
        capture: true,
      });
    }
    run("iconutil", ["-c", "icns", iconsetDir, "-o", join(resourcesDir, "AppIcon.icns")], {
      capture: true,
    });
  } finally {
    rmSync(iconsetParentDir, { recursive: true, force: true });
  }
}

function copyOrg2Runtime(resourcesDir) {
  const distPath = join(repoRoot, "dist");
  if (!existsSync(join(distPath, "cli.js")) || !existsSync(join(distPath, "render-html.js"))) {
    throw new Error(`Org2 runtime not found in ${distPath}. Run npm run build first.`);
  }

  const runtimeDir = join(resourcesDir, "Org2Runtime");
  rmSync(runtimeDir, { recursive: true, force: true });
  mkdirSync(runtimeDir, { recursive: true });
  cpSync(distPath, join(runtimeDir, "dist"), { recursive: true });
  copyFileSync(join(repoRoot, "package.json"), join(runtimeDir, "package.json"));
  cpSync(join(repoRoot, "skills"), join(runtimeDir, "skills"), { recursive: true });

  if (bundledNodePath && !existsSync(bundledNodePath)) {
    throw new Error(`Bundled Node.js runtime not found at ${bundledNodePath}`);
  }
  if (!bundledNodePath && includesBundledRuntimes) {
    throw new Error(
      "Self-contained builds require Node.js. Install Node.js or set ORG2_WORKSPACE_NODE_PATH."
    );
  }

  const fallbackNodePath = [
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    "/usr/bin/node",
  ].find((candidate) => existsSync(candidate));
  const runtimeNodeSourcePath = bundledNodePath || fallbackNodePath;
  const runtimeNodeArchitecture = runtimeNodeSourcePath
    ? detectNodeArchitecture(runtimeNodeSourcePath)
    : null;
  // Node runs as a child process, so its architecture may differ from the Swift
  // app when Rosetta is available. Bundle the DuckDB binding for Node itself.
  const duckDBBindingPackages = duckDBBindingPackagesForRuntime({
    bundledNodePath,
    nodeArchitecture: runtimeNodeArchitecture,
  });
  const runtimeDependencyRoot = process.env.ORG2_WORKSPACE_RUNTIME_DEPENDENCIES || repoRoot;
  const runtimePackages = [
    "@duckdb/node-api",
    "@duckdb/node-bindings",
    ...duckDBBindingPackages,
    "detect-libc",
  ];
  for (const packageName of runtimePackages) {
    const source = join(runtimeDependencyRoot, "node_modules", ...packageName.split("/"));
    if (!existsSync(source)) {
      if (includesBundledRuntimes) {
        throw new Error(`Production runtime dependency ${packageName} is missing. Run npm ci for the target Node.js architecture.`);
      }
      continue;
    }
    const destination = join(runtimeDir, "node_modules", ...packageName.split("/"));
    mkdirSync(dirname(destination), { recursive: true });
    cpSync(source, destination, { recursive: true });
  }

  let runtimeNodePath = runtimeNodeSourcePath;
  if (bundledNodePath) {
    const binDir = join(runtimeDir, "bin");
    mkdirSync(binDir, { recursive: true });
    const destination = join(binDir, "node");
    copyFileSync(bundledNodePath, destination);
    chmodSync(destination, 0o755);
    runtimeNodePath = destination;
  }

  if (runtimeNodePath) {
    const verificationRoot = isTrustedLocalBuild ? runtimeDependencyRoot : runtimeDir;
    const verificationNodePath = isTrustedLocalBuild
      ? runtimeNodeSourcePath
      : runtimeNodePath;
    const bindingEntry = join(verificationRoot, "node_modules", "@duckdb", "node-bindings");
    const verification = spawnSync(verificationNodePath, ["-e", `require(${JSON.stringify(bindingEntry)})`], {
      cwd: verificationRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (verification.status !== 0) {
      const detail = [verification.stdout, verification.stderr].filter(Boolean).join("\n").trim();
      throw new Error(
        `Bundled DuckDB failed to load with ${runtimeNodeArchitecture || "the selected"} Node.js runtime${detail ? `:\n${detail}` : "."}`
      );
    }
  }
  return bundledNodePath ? runtimeNodePath : "";
}

function copyWhisperRuntime(resourcesDir) {
  if (!bundledWhisperCppPath || !bundledWhisperModelPath) {
    if (includesBundledRuntimes) {
      throw new Error(
        "Self-contained builds require whisper.cpp and its base English model. Install whisper-cpp and the Org2 model, or set ORG2_WORKSPACE_WHISPER_CPP_PATH and ORG2_WORKSPACE_WHISPER_MODEL_PATH."
      );
    }
    return { executable: "", libraries: [] };
  }
  if (!existsSync(bundledWhisperCppPath)) {
    throw new Error(`Bundled whisper.cpp executable not found at ${bundledWhisperCppPath}`);
  }
  if (!existsSync(bundledWhisperModelPath)) {
    throw new Error(`Bundled whisper.cpp model not found at ${bundledWhisperModelPath}`);
  }
  if (isTrustedLocalBuild) {
    verifyWhisperRuntime(bundledWhisperCppPath);
  }
  if (process.platform === "darwin" && swiftBuildArch) {
    const architectures = run("lipo", ["-archs", bundledWhisperCppPath], { capture: true }).split(/\s+/);
    if (!architectures.includes(swiftBuildArch)) {
      throw new Error(
        `Bundled whisper.cpp executable must include ${swiftBuildArch}; found ${architectures.join(", ") || "no Mach-O architecture"}.`
      );
    }
  }

  const whisperDir = join(resourcesDir, "Whisper");
  const binDir = join(whisperDir, "bin");
  const libDir = join(whisperDir, "lib");
  const modelsDir = join(whisperDir, "models");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(libDir, { recursive: true });
  mkdirSync(modelsDir, { recursive: true });
  const executableDestination = join(binDir, "whisper-cli");
  copyFileSync(bundledWhisperCppPath, executableDestination);
  chmodSync(executableDestination, 0o755);
  copyFileSync(bundledWhisperModelPath, join(modelsDir, "ggml-base.en.bin"));

  const libraries = process.platform === "darwin"
    ? copyMachODependencies(bundledWhisperCppPath, executableDestination, libDir)
    : [];

  const noticesDir = join(repoRoot, "third_party", "whisper");
  for (const noticeFile of ["LICENSE-whisper.cpp", "LICENSE-openai-whisper", "NOTICE.md"]) {
    const source = join(noticesDir, noticeFile);
    if (!existsSync(source)) {
      throw new Error(`Bundled whisper attribution file not found at ${source}`);
    }
    copyFileSync(source, join(whisperDir, noticeFile));
  }
  return { executable: executableDestination, libraries };
}

function machODependencies(path) {
  const installNameResult = spawnSync("otool", ["-D", path], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const installName = installNameResult.status === 0
    ? installNameResult.stdout.split(/\n/).slice(1).map((line) => line.trim()).find(Boolean)
    : "";
  return run("otool", ["-L", path], { capture: true })
    .split(/\n/)
    .slice(1)
    .map((line) => line.trim().split(/\s+/)[0])
    .filter((dependency) => dependency && dependency !== installName);
}

function copyMachODependencies(sourceExecutable, destinationExecutable, destinationLibDir) {
  const resolvedExecutable = realpathSync(sourceExecutable);
  const sourceLibDirs = [
    resolve(dirname(resolvedExecutable), "../lib"),
    resolve(dirname(sourceExecutable), "../lib"),
  ];
  const pending = [{ source: resolvedExecutable, destination: destinationExecutable }];
  const copiedByName = new Map();

  while (pending.length > 0) {
    const owner = pending.shift();
    for (const dependency of machODependencies(owner.source)) {
      if (dependency.startsWith("/usr/lib/") || dependency.startsWith("/System/Library/")) {
        continue;
      }
      const name = dependency.split("/").at(-1);
      const source = resolveMachODependency(dependency, owner.source, sourceLibDirs);
      if (!source) {
        throw new Error(`Could not resolve Whisper dependency ${dependency} for ${owner.source}`);
      }
      let destination = copiedByName.get(name);
      if (!destination) {
        destination = join(destinationLibDir, name);
        copyFileSync(source, destination);
        chmodSync(destination, 0o755);
        copiedByName.set(name, destination);
        pending.push({ source, destination });
      }
      if (dependency !== `@rpath/${name}`) {
        run("install_name_tool", ["-change", dependency, `@rpath/${name}`, owner.destination]);
      }
    }
  }

  for (const [name, destination] of copiedByName) {
    run("install_name_tool", ["-id", `@rpath/${name}`, destination]);
  }
  return [...copiedByName.values()];
}

function resolveMachODependency(dependency, ownerPath, sourceLibDirs) {
  const candidates = [];
  if (dependency.startsWith("@rpath/")) {
    const name = dependency.slice("@rpath/".length);
    candidates.push(...sourceLibDirs.map((directory) => join(directory, name)));
    candidates.push(resolve(dirname(ownerPath), "../lib", name));
  } else if (dependency.startsWith("@loader_path/")) {
    candidates.push(resolve(dirname(ownerPath), dependency.slice("@loader_path/".length)));
  } else if (dependency.startsWith("/")) {
    candidates.push(dependency);
  }
  const existing = candidates.find((candidate) => existsSync(candidate));
  return existing ? realpathSync(existing) : "";
}

function verifyWhisperRuntime(executable) {
  if (!executable) return;
  const verification = spawnSync(executable, ["--help"], {
    cwd: dirname(executable),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (verification.status !== 0) {
    const detail = [verification.stdout, verification.stderr].filter(Boolean).join("\n").trim();
    throw new Error(
      `Bundled whisper.cpp failed its launch check${detail ? `:\n${detail}` : "."}`
    );
  }
}

function main() {
  if (buildOptions.help) {
    console.log(buildUsage());
    return;
  }
  if (
    bundleIdentifier === "org.org2.workspace"
    && swiftBuildConfiguration === "debug"
    && !buildOptions.allowDailyDebug
    && !buildOptions.localFast
  ) {
    throw new Error(
      "Refusing to install an implicit debug build as the daily app. Use npm run build:macos-app:debug when that is intentional."
    );
  }
  if (buildOptions.localFast && buildOptions.localOptimized) {
    throw new Error("Use either --local-fast or --local-optimized, not both");
  }
  if (buildOptions.localFast && swiftBuildConfiguration !== "debug") {
    throw new Error("--local-fast requires --configuration debug");
  }
  if (buildOptions.localOptimized && swiftBuildConfiguration !== "release") {
    throw new Error("--local-optimized requires --configuration release");
  }
  if (
    buildOptions.requireGoogleOAuthClient
    && (!googleOAuthClientID || !googleOAuthClientSecret)
  ) {
    throw new Error(
      "This distributable build requires OpenOrg's Google OAuth Desktop client. Set ORG2_GOOGLE_OAUTH_CLIENT_JSON to its protected JSON path, or set the paired ORG2_GOOGLE_OAUTH_CLIENT_ID and ORG2_GOOGLE_OAUTH_CLIENT_SECRET values."
    );
  }
  if (buildOptions.printConfiguration) {
    console.log(JSON.stringify({
      appPath,
      appName,
      displayName,
      bundleIdentifier,
      configuration: swiftBuildConfiguration,
      iconPath,
      hardenedRuntime: requestedSigningIdentity?.startsWith("Developer ID Application:") ?? false,
      installStrategy: "verified staged replacement",
      optimizationMode: buildOptions.localFast
        ? "shared incremental debug (-Onone)"
        : buildOptions.localOptimized
          ? "incremental -O"
          : swiftBuildConfiguration === "release" ? "whole-module -O" : "debug",
      nodeArchitecture: bundledNodeArchitecture,
      nodeEntitlementsPath,
      nodePath: bundledNodePath || null,
      googleOAuthClientConfigured: googleOAuthClientID.length > 0,
      googleOAuthClientSecretConfigured: googleOAuthClientSecret.length > 0,
      googleOAuthClientSource: googleOAuthConfiguration.source,
      googleOAuthRequired: buildOptions.requireGoogleOAuthClient,
      restartAfterInstall: buildOptions.restart,
      swiftScratchPath: swiftScratchPath || null,
      updates: sparkleUpdateConfiguration(),
      whisperCppPath: bundledWhisperCppPath || null,
      whisperModelPath: bundledWhisperModelPath || null,
    }, null, 2));
    return;
  }

  const installedBinaryPath = join(appPath, "Contents", "MacOS", executableName);
  if (!buildOptions.restart) {
    assertInstalledAppIsStopped(installedBinaryPath);
  }

  if (!buildOptions.skipRuntimeBuild) {
    console.log("Building the shared Org2 runtime for the app bundle...");
    run("npm", ["run", "build"], { cwd: repoRoot });
  } else if (!existsSync(join(repoRoot, "dist", "cli.js"))) {
    throw new Error("--skip-runtime-build requires an already built shared runtime");
  }
  console.log(`Building ${executableName} (${swiftBuildConfiguration})...`);
  run("swift", swiftBuildArgs("build", "--product", executableName), { cwd: packageDir });
  const buildProductsDir = run("swift", swiftBuildArgs("build", "--show-bin-path"), {
    cwd: packageDir,
    capture: true,
  });

  const binaryPath = join(buildProductsDir, executableName);
  if (!existsSync(binaryPath)) {
    throw new Error(`Built binary not found at ${binaryPath}`);
  }

  mkdirSync(dirname(appPath), { recursive: true });
  const stagingRoot = mkdtempSync(join(dirname(appPath), `.${basename(appPath)}.staging-`));
  const stagedAppPath = join(stagingRoot, basename(appPath));
  try {
    const contentsDir = join(stagedAppPath, "Contents");
    const macOSDir = join(contentsDir, "MacOS");
    const resourcesDir = join(contentsDir, "Resources");
    mkdirSync(macOSDir, { recursive: true });
    mkdirSync(resourcesDir, { recursive: true });

    writeInfoPlist(stagedAppPath);
    const appBinaryPath = join(macOSDir, executableName);
    copyFileSync(binaryPath, appBinaryPath);
    chmodSync(appBinaryPath, 0o755);
    const sparkleFrameworkPath = copySparkleFramework(buildProductsDir, contentsDir);

    if (!existsSync(iconPath)) {
      throw new Error(`App icon not found at ${iconPath}`);
    }
    writeIconSet(iconPath, resourcesDir);
    copyCoreResources(resourcesDir);
    const runtimeNodePath = copyOrg2Runtime(resourcesDir);
    const whisperRuntime = copyWhisperRuntime(resourcesDir);

    const signingIdentity = codeSigningIdentity();
    const signingLabel = signingIdentity === "-" ? "ad-hoc" : signingIdentity;
    console.log(`Signing staged ${appName} as ${bundleIdentifier} with ${signingLabel}...`);
    if (usesHardenedRuntime(signingIdentity)) {
      for (const entitlementsPath of [appEntitlementsPath, nodeEntitlementsPath]) {
        if (!existsSync(entitlementsPath)) {
          throw new Error(`Hardened-runtime entitlements not found at ${entitlementsPath}`);
        }
      }
    }
    if (runtimeNodePath) {
      run("codesign", codesignArgs(signingIdentity, runtimeNodePath, {
        entitlements: nodeEntitlementsPath,
      }));
      if (!isTrustedLocalBuild) verifyNodeRuntime(runtimeNodePath);
    }
    for (const library of whisperRuntime.libraries) {
      run("codesign", codesignArgs(signingIdentity, library));
    }
    if (whisperRuntime.executable) {
      run("codesign", codesignArgs(signingIdentity, whisperRuntime.executable));
      if (!isTrustedLocalBuild) verifyWhisperRuntime(whisperRuntime.executable);
    }
    signSparkleFramework(sparkleFrameworkPath, signingIdentity);
    for (const nestedPath of nestedMachOPaths(resourcesDir)) {
      if (nestedPath === runtimeNodePath
          || nestedPath === whisperRuntime.executable
          || whisperRuntime.libraries.includes(nestedPath)) {
        continue;
      }
      run("codesign", codesignArgs(signingIdentity, nestedPath));
    }
    run("codesign", codesignArgs(signingIdentity, stagedAppPath, {
      entitlements: appEntitlementsPath,
      identifier: bundleIdentifier,
    }));
    run("codesign", ["--verify", "--deep", "--strict", stagedAppPath]);

    if (buildOptions.restart) {
      quitRunningInstalledApp(installedBinaryPath);
    } else {
      // A user may have launched the app while the build was running. Never
      // replace a bundle that became active after the initial guard.
      assertInstalledAppIsStopped(installedBinaryPath);
    }

    try {
      installStagedAppBundle({ stagedAppPath, targetAppPath: appPath });
    } catch (installError) {
      if (buildOptions.restart && existsSync(appPath)) {
        try {
          launchInstalledApp();
        } catch (relaunchError) {
          const installDetail = installError instanceof Error
            ? installError.message
            : String(installError);
          const relaunchDetail = relaunchError instanceof Error
            ? relaunchError.message
            : String(relaunchError);
          throw new Error(
            `${installDetail}\nThe previous app could not be reopened after rollback: ${relaunchDetail}`
          );
        }
      }
      throw installError;
    }
    if (buildOptions.restart) {
      launchInstalledApp();
    }
    if (signingIdentity === "-") {
      console.warn(
        "Warning: ad-hoc signing gives the app a cdhash-based TCC identity. macOS Screen/System Audio permission may reset after rebuilds. Set ORG2_WORKSPACE_CODE_SIGN_IDENTITY to a stable signing identity to avoid that."
      );
    }
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true });
  }

  console.log(`Built ${appPath}`);
  console.log(`Open with: open ${appPath}`);
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
