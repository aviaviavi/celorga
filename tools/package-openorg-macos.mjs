#!/usr/bin/env node

import "./celorga-env.mjs";
import { spawnSync } from "node:child_process";
import { notarizationAuthentication } from "./openorg-notarization.mjs";
import {
  copyFileSync,
  existsSync,
  realpathSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { detectNodeArchitecture } from "./macos-runtime-node.mjs";
import { configuredGoogleOAuthClientJSON, googleOAuthEnvironmentValue } from "./google-oauth-client.mjs";
import { MAC_DMG_ARM64, MAC_DMG_INTEL, MAC_DMG_VOLUME_NAME } from "./openorg-sparkle.mjs";
import { releaseBuildCacheRoot } from "./openorg-build-cache.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageVersion = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;
const options = parseOptions(process.argv.slice(2));

function defaultArchitecture() {
  if (process.platform === "darwin") {
    const result = spawnSync("sysctl", ["-n", "hw.optional.arm64"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (result.status === 0 && result.stdout.trim() === "1") return "arm64";
  }
  return process.arch === "x64" ? "x86_64" : "arm64";
}

function parseOptions(args) {
  const parsed = {
    architecture: defaultArchitecture(),
    force: false,
    help: false,
    notaryProfile: process.env.OPENORG_NOTARY_KEYCHAIN_PROFILE?.trim() ?? "",
    output: "",
    plan: false,
    requireNotarization: false,
    skipRuntimeBuild: false,
    swiftScratchPath: "",
  };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    switch (argument) {
      case "--architecture":
        parsed.architecture = args[++index] ?? "";
        break;
      case "--output":
        parsed.output = args[++index] ?? "";
        break;
      case "--notary-profile":
        parsed.notaryProfile = args[++index] ?? "";
        break;
      case "--require-notarization":
        parsed.requireNotarization = true;
        break;
      case "--skip-runtime-build":
        parsed.skipRuntimeBuild = true;
        break;
      case "--swift-scratch-path":
        parsed.swiftScratchPath = args[++index] ?? "";
        break;
      case "--force":
        parsed.force = true;
        break;
      case "--plan":
        parsed.plan = true;
        break;
      case "--help":
      case "-h":
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown option: ${argument}`);
    }
  }
  if (!["arm64", "x86_64"].includes(parsed.architecture)) {
    throw new Error("--architecture must be arm64 or x86_64");
  }
  const defaultDMG = parsed.architecture === "arm64" ? MAC_DMG_ARM64 : MAC_DMG_INTEL;
  parsed.output = resolve(parsed.output || join(repoRoot, "artifacts", defaultDMG));
  parsed.swiftScratchPath = resolve(parsed.swiftScratchPath
    || join(releaseBuildCacheRoot(), `swift-release-${parsed.architecture}`));
  return parsed;
}

function usage() {
  return `Usage: node tools/package-openorg-macos.mjs [options]

Build, Developer-ID sign, package, and optionally notarize an isolated Celorga DMG
(the app inside keeps the OpenOrg.app file name so Sparkle updates in place).

Options:
  --architecture ARCH       arm64 or x86_64
  --output PATH             DMG output path
  --notary-profile NAME     notarytool Keychain profile (or OPENORG_NOTARY_KEYCHAIN_PROFILE)
  --require-notarization    fail instead of producing an unstapled local candidate
  --skip-runtime-build      reuse a shared runtime already built and validated
  --swift-scratch-path DIR  persistent architecture-specific SwiftPM scratch
                            directory for incremental release builds (default:
                            OpenOrg's shared release cache for the architecture)
  --force                   replace an existing output artifact
  --plan                    print the resolved non-secret packaging plan
  --help                    show this help`;
}

function run(command, args, runOptions = {}) {
  const result = spawnSync(command, args, {
    cwd: runOptions.cwd ?? repoRoot,
    encoding: "utf8",
    env: runOptions.env ?? process.env,
    stdio: runOptions.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });
  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
    throw new Error(detail || `${command} ${args.join(" ")} failed`);
  }
  return result.stdout?.trim() ?? "";
}

function developerIDApplicationIdentity() {
  const configured = process.env.ORG2_WORKSPACE_CODE_SIGN_IDENTITY?.trim();
  if (configured) {
    if (!configured.startsWith("Developer ID Application:")) {
      throw new Error("Release packaging requires a Developer ID Application signing identity");
    }
    return configured;
  }
  const output = run("security", ["find-identity", "-v", "-p", "codesigning"], { capture: true });
  const match = output.match(/"(Developer ID Application:[^"]+)"/);
  if (!match) {
    throw new Error("No Developer ID Application signing identity is installed");
  }
  return match[1];
}

function artifactManifestPath(dmgPath) {
  return dmgPath.slice(0, -extname(dmgPath).length) + ".json";
}

function firstMatchingNodePath(architecture) {
  const expected = architecture === "x86_64" ? "x64" : "arm64";
  const suffix = architecture === "x86_64" ? "X86_64" : "ARM64";
  const configured = process.env[`OPENORG_${suffix}_NODE_PATH`]?.trim();
  const candidates = [
    configured,
    process.env.ORG2_WORKSPACE_NODE_PATH?.trim(),
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    process.execPath,
  ].filter(Boolean);
  for (const candidate of [...new Set(candidates)]) {
    if (!existsSync(candidate)) continue;
    try {
      if (detectNodeArchitecture(candidate) === expected) return candidate;
    } catch {
      // Keep looking; execution reports the complete target-specific error below.
    }
  }
  throw new Error(
    `No ${expected} Node.js runtime was found. Set OPENORG_${suffix}_NODE_PATH to a target-architecture Node binary.`
  );
}

function binaryArchitectures(path) {
  const result = spawnSync("lipo", ["-archs", path], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  return result.status === 0 ? result.stdout.trim().split(/\s+/).filter(Boolean) : [];
}

function firstMatchingWhisperPath(architecture) {
  const suffix = architecture === "x86_64" ? "X86_64" : "ARM64";
  const candidates = [
    process.env[`OPENORG_${suffix}_WHISPER_CPP_PATH`]?.trim(),
    process.env.ORG2_WORKSPACE_WHISPER_CPP_PATH?.trim(),
    "/opt/homebrew/bin/whisper-cli",
    "/usr/local/bin/whisper-cli",
  ].filter(Boolean);
  const match = [...new Set(candidates)].find((candidate) => (
    existsSync(candidate) && binaryArchitectures(candidate).includes(architecture)
  ));
  if (match) return match;
  throw new Error(
    `No ${architecture} whisper-cli was found. Set OPENORG_${suffix}_WHISPER_CPP_PATH to a target-architecture executable.`
  );
}

function whisperModelPath() {
  const candidates = [
    process.env.OPENORG_WHISPER_MODEL_PATH?.trim(),
    process.env.ORG2_WORKSPACE_WHISPER_MODEL_PATH?.trim(),
    join(process.env.HOME ?? "", "Library", "Application Support", "org2", "whisper", "ggml-base.en.bin"),
  ].filter(Boolean);
  const match = candidates.find((candidate) => existsSync(candidate));
  if (match) return match;
  throw new Error("No ggml-base.en.bin model was found. Set OPENORG_WHISPER_MODEL_PATH.");
}

function googleOAuthClientSource() {
  const configured = configuredGoogleOAuthClientJSON();
  if (configured.source) return configured.source;
  const clientID = googleOAuthEnvironmentValue("GOOGLE_OAUTH_CLIENT_ID");
  const clientSecret = googleOAuthEnvironmentValue("GOOGLE_OAUTH_CLIENT_SECRET");
  return clientID && clientSecret ? "environment-pair" : null;
}

function printPlan() {
  console.log(JSON.stringify({
    appName: "OpenOrg",
    displayName: "Celorga",
    volumeName: MAC_DMG_VOLUME_NAME,
    architecture: options.architecture,
    bundleIdentifier: "org.org2.workspace",
    dailyAppUntouched: "/Users/avi/Applications/Org2Workspace.app",
    executableName: "Org2Workspace",
    googleOAuthClientSource: googleOAuthClientSource(),
    hardenedRuntime: true,
    notarization: notarizationAuthentication(options.notaryProfile)?.label ?? "not configured",
    output: options.output,
    swiftBuild: "persistent architecture-specific cache",
    swiftScratch: options.swiftScratchPath,
    runtimeDependencies: "locked install under target Node in isolated staging",
    targetRuntimeSelection: "architecture-verified at execution",
    staging: "isolated temporary directory",
    version: packageVersion,
  }, null, 2));
}

function main() {
  if (options.help) {
    console.log(usage());
    return;
  }
  if (options.plan) {
    printPlan();
    return;
  }
  const notarization = notarizationAuthentication(options.notaryProfile);
  if (options.requireNotarization && !notarization) {
    throw new Error("--require-notarization needs --notary-profile, OPENORG_NOTARY_KEYCHAIN_PROFILE, or existing OPENORG_NOTARY_PRIVATE_KEY_PATH / OPENORG_NOTARY_KEY_ID credentials");
  }
  if (process.platform !== "darwin") {
    throw new Error("OpenOrg DMG packaging requires macOS");
  }
  if (!googleOAuthClientSource()) {
    throw new Error(
      "OpenOrg DMG packaging requires the shared Google OAuth Desktop client. Save its protected JSON at ~/.config/celorga/google-oauth-client.json, set ORG2_GOOGLE_OAUTH_CLIENT_JSON to its path, or set the paired ORG2_GOOGLE_OAUTH_CLIENT_ID and ORG2_GOOGLE_OAUTH_CLIENT_SECRET values."
    );
  }
  if (existsSync(options.output) && !options.force) {
    throw new Error(`Refusing to replace existing artifact: ${options.output}`);
  }

  if (notarization) {
    // Validate in the same process environment before expensive compilation.
    run("xcrun", ["notarytool", "history", ...notarization.args, "--output-format", "json"], { capture: true });
  }
  const signingIdentity = developerIDApplicationIdentity();
  const nodePath = firstMatchingNodePath(options.architecture);
  const whisperCppPath = firstMatchingWhisperPath(options.architecture);
  const modelPath = whisperModelPath();
  const workingDirectory = mkdtempSync(join(tmpdir(), "openorg-release-"));
  const builtApp = join(workingDirectory, "OpenOrg.app");
  const dmgRoot = join(workingDirectory, "dmg-root");
  const unsignedDMG = join(workingDirectory, `${MAC_DMG_VOLUME_NAME}.dmg`);
  let completed = false;

  try {
    // Never race architecture-specific npm installs in the shared checkout.
    // Resolve and load the target binding before spending time compiling Swift.
    const dependencies = join(workingDirectory, "runtime-dependencies");
    mkdirSync(dependencies);
    for (const file of ["package.json", "package-lock.json"]) {
      copyFileSync(join(repoRoot, file), join(dependencies, file));
    }
    const targetEnvironment = { ...process.env, PATH: `${dirname(nodePath)}:${process.env.PATH}` };
    const npmCLI = realpathSync(run("which", ["npm"], { capture: true }));
    run(nodePath, [npmCLI, "ci", "--omit=dev", "--no-audit", "--no-fund"], { cwd: dependencies, env: targetEnvironment });
    run(nodePath, ["-e", "require('@duckdb/node-bindings')"], { cwd: dependencies, env: targetEnvironment });
    run(nodePath, [
      join(repoRoot, "tools", "build-macos-app.mjs"),
      "--configuration", "release",
      "--require-google-oauth-client",
      ...(options.skipRuntimeBuild ? ["--skip-runtime-build"] : []),
    ], {
      env: {
        ...targetEnvironment,
        ORG2_WORKSPACE_RUNTIME_DEPENDENCIES: dependencies,
        ORG2_WORKSPACE_APP_NAME: "OpenOrg",
        ORG2_WORKSPACE_DISPLAY_NAME: "Celorga",
        ORG2_WORKSPACE_APP_PATH: builtApp,
        ORG2_WORKSPACE_BUNDLE_ID: "org.org2.workspace",
        ORG2_WORKSPACE_CODE_SIGN_IDENTITY: signingIdentity,
        ORG2_WORKSPACE_NODE_PATH: nodePath,
        ORG2_WORKSPACE_SWIFT_ARCH: options.architecture,
        ORG2_WORKSPACE_SWIFT_SCRATCH_PATH: options.swiftScratchPath,
        ORG2_WORKSPACE_WHISPER_CPP_PATH: whisperCppPath,
        ORG2_WORKSPACE_WHISPER_MODEL_PATH: modelPath,
      },
    });

    run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", builtApp]);

    mkdirSync(dmgRoot, { recursive: true });
    run("ditto", [builtApp, join(dmgRoot, "OpenOrg.app")]);
    symlinkSync("/Applications", join(dmgRoot, "Applications"));
    run("hdiutil", [
      "create",
      "-volname", MAC_DMG_VOLUME_NAME,
      "-srcfolder", dmgRoot,
      "-ov",
      "-format", "UDZO",
      unsignedDMG,
    ]);
    run("codesign", ["--force", "--timestamp", "--sign", signingIdentity, unsignedDMG]);
    run("hdiutil", ["verify", unsignedDMG]);

    let notarized = false;
    if (notarization) {
      run("xcrun", [
        "notarytool", "submit", unsignedDMG,
        ...notarization.args,
        "--wait",
      ]);
      run("xcrun", ["stapler", "staple", unsignedDMG]);
      run("xcrun", ["stapler", "validate", unsignedDMG]);
      run("/usr/sbin/spctl", [
        "--assess", "--type", "open",
        "--context", "context:primary-signature",
        "--verbose=2", unsignedDMG,
      ]);
      notarized = true;
    }

    mkdirSync(dirname(options.output), { recursive: true });
    if (existsSync(options.output)) rmSync(options.output, { force: true });
    run("ditto", [unsignedDMG, options.output]);
    const sha256 = run("shasum", ["-a", "256", options.output], { capture: true }).split(/\s+/)[0];
    const manifestPath = artifactManifestPath(options.output);
    writeFileSync(manifestPath, JSON.stringify({
      architecture: options.architecture,
      artifact: options.output,
      bundleIdentifier: "org.org2.workspace",
      displayName: "Celorga",
      notarized,
      sha256,
      version: packageVersion,
    }, null, 2) + "\n");
    completed = true;
    console.log(`Packaged ${options.output}`);
    console.log(`SHA-256 ${sha256}`);
    console.log(notarized ? "Notarization ticket stapled" : "Local candidate only; notarization was not requested");
  } finally {
    if (completed) rmSync(workingDirectory, { recursive: true, force: true });
    else console.error(`Failed release staging retained for repair: ${workingDirectory}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
