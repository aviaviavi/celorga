import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { releaseBuildCacheRoot } from "../tools/openorg-build-cache.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(repoRoot, "tools", "package-openorg-macos.mjs");
const nodeEntitlements = readFileSync(join(
  repoRoot,
  "apps", "macos", "Org2Workspace", "OpenOrgNode.entitlements"
), "utf8");
const intelNodeEntitlements = readFileSync(join(
  repoRoot,
  "apps", "macos", "Org2Workspace", "OpenOrgNodeIntel.entitlements"
), "utf8");
const packagingTestEnvironment = { ...process.env };
delete packagingTestEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_JSON;
delete packagingTestEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_ID;
delete packagingTestEnvironment.ORG2_GOOGLE_OAUTH_CLIENT_SECRET;
delete packagingTestEnvironment.CELORGA_GOOGLE_OAUTH_CLIENT_JSON;
delete packagingTestEnvironment.CELORGA_GOOGLE_OAUTH_CLIENT_ID;
delete packagingTestEnvironment.CELORGA_GOOGLE_OAUTH_CLIENT_SECRET;
// A developer's machine-local default client must not satisfy these checks.
packagingTestEnvironment.XDG_CONFIG_HOME = join(tmpdir(), `celorga-packaging-config-${process.pid}`);
delete packagingTestEnvironment.OPENORG_RELEASE_BUILD_CACHE;
// Release credentials must never turn these plan/negative checks into a real build.
for (const key of [
  "OPENORG_NOTARY_KEYCHAIN_PROFILE",
  "OPENORG_NOTARY_PRIVATE_KEY_PATH",
  "OPENORG_NOTARY_KEY_ID",
  "OPENORG_NOTARY_ISSUER_ID",
]) delete packagingTestEnvironment[key];

assert.match(nodeEntitlements, /<key>com\.apple\.security\.cs\.allow-jit<\/key>\s*<true\/>/);
assert.doesNotMatch(nodeEntitlements, /com\.apple\.security\.cs\.allow-unsigned-executable-memory/);
assert.match(intelNodeEntitlements, /<key>com\.apple\.security\.cs\.allow-jit<\/key>\s*<true\/>/);
assert.match(
  intelNodeEntitlements,
  /<key>com\.apple\.security\.cs\.allow-unsigned-executable-memory<\/key>\s*<true\/>/
);

const defaultPlanResult = spawnSync(process.execPath, [script, "--plan"], {
  cwd: repoRoot,
  encoding: "utf8",
  env: packagingTestEnvironment,
});
assert.equal(defaultPlanResult.status, 0, defaultPlanResult.stderr);
const defaultPlan = JSON.parse(defaultPlanResult.stdout);
if (process.platform === "darwin") {
  const arm64Probe = spawnSync("sysctl", ["-n", "hw.optional.arm64"], { encoding: "utf8" });
  if (arm64Probe.status === 0 && arm64Probe.stdout.trim() === "1") {
    assert.equal(defaultPlan.architecture, "arm64", "Rosetta must not default packaging to Intel");
  }
}

const planResult = spawnSync(process.execPath, [script, "--plan", "--architecture", "arm64"], {
  cwd: repoRoot,
  encoding: "utf8",
  env: packagingTestEnvironment,
});
assert.equal(planResult.status, 0, planResult.stderr);
const plan = JSON.parse(planResult.stdout);
assert.equal(plan.appName, "OpenOrg");
assert.equal(plan.displayName, "Celorga");
assert.equal(plan.architecture, "arm64");
assert.equal(plan.bundleIdentifier, "org.org2.workspace");
assert.equal(plan.dailyAppUntouched, "/Users/avi/Applications/Org2Workspace.app");
assert.equal(plan.executableName, "Org2Workspace");
assert.equal(plan.googleOAuthClientSource, null);
assert.equal(plan.hardenedRuntime, true);
assert.equal(plan.swiftBuild, "persistent architecture-specific cache");
assert.equal(plan.swiftScratch, join(releaseBuildCacheRoot(packagingTestEnvironment), "swift-release-arm64"));
assert.equal(plan.targetRuntimeSelection, "architecture-verified at execution");
assert.equal(plan.staging, "isolated temporary directory");
assert.equal(plan.volumeName, "Celorga");
assert.match(plan.output, /\/Celorga\.dmg$/);

// Standalone packaging shares the coordinated release cache, keeps target
// architectures separate, and preserves explicit scratch-directory overrides.
for (const architecture of ["arm64", "x86_64"]) {
  const cachedPlanResult = spawnSync(process.execPath, [script, "--plan", "--architecture", architecture], {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...packagingTestEnvironment, OPENORG_RELEASE_BUILD_CACHE: "/tmp/openorg-packaging-cache" },
  });
  assert.equal(cachedPlanResult.status, 0, cachedPlanResult.stderr);
  assert.equal(JSON.parse(cachedPlanResult.stdout).swiftScratch,
    `/tmp/openorg-packaging-cache/swift-release-${architecture}`);
}
const explicitScratchResult = spawnSync(process.execPath, [
  script, "--plan", "--swift-scratch-path", "/tmp/openorg-explicit-scratch",
], {
  cwd: repoRoot,
  encoding: "utf8",
  env: { ...packagingTestEnvironment, OPENORG_RELEASE_BUILD_CACHE: "/tmp/openorg-packaging-cache" },
});
assert.equal(explicitScratchResult.status, 0, explicitScratchResult.stderr);
assert.equal(JSON.parse(explicitScratchResult.stdout).swiftScratch, "/tmp/openorg-explicit-scratch");

const configuredPlanResult = spawnSync(
  process.execPath,
  [script, "--plan", "--architecture", "arm64"],
  {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...packagingTestEnvironment,
      ORG2_GOOGLE_OAUTH_CLIENT_JSON: "/protected/openorg-google-oauth-client.json",
    },
  }
);
assert.equal(configuredPlanResult.status, 0, configuredPlanResult.stderr);
assert.equal(
  JSON.parse(configuredPlanResult.stdout).googleOAuthClientSource,
  "desktop-client-json"
);

const missingProfile = spawnSync(
  process.execPath,
  [script, "--require-notarization", "--output", join(repoRoot, "artifacts", "unused.dmg")],
  {
    cwd: repoRoot,
    encoding: "utf8",
    env: packagingTestEnvironment,
    timeout: 10_000,
  }
);
assert.equal(missingProfile.status, 1);
assert.match(missingProfile.stderr, /needs --notary-profile/);

// Exercise the production range getter across the @Published ownership
// boundary with the release optimizer. Debug Swift tests cannot catch the
// Swift 6.2 CopyPropagation crash this small compilation reproduces.
if (process.platform === "darwin") {
  const compilerProbe = spawnSync("xcrun", ["--find", "swiftc"], { encoding: "utf8" });
  if (compilerProbe.status === 0) {
    const core = join(repoRoot, "apps", "macos", "Org2Workspace", "Sources", "Org2WorkspaceCore");
    const status = readFileSync(join(core, "OrgProseState.swift"), "utf8")
      .match(/enum OrgProseBlockStatus:[\s\S]*?\n\}/)?.[0];
    const getter = readFileSync(join(core, "OrgProseEngine.swift"), "utf8")
      .match(/  var blockRange: NSRange\? \{[\s\S]*?\n  \}/)?.[0];
    assert.ok(status && getter, "Production Prose range declarations must be found");
    const scratch = mkdtempSync(join(tmpdir(), "openorg-prose-release-regression-"));
    try {
      const source = join(scratch, "ProseReleaseRegression.swift");
      writeFileSync(source, `import AppKit
import Combine
${status}
struct OrgProseSnapshot {
  var status: OrgProseBlockStatus = .absent
${getter}
}
@MainActor
public final class ProseReleaseRegression: ObservableObject {
  @Published var snapshot = OrgProseSnapshot()
  public var textView: NSTextView?
  public var hiddenRange: NSRange?
  public func applyPresentation() {
    guard let textView, let layoutManager = textView.layoutManager,
          let length = textView.textStorage?.length else { return }
    let newHidden = snapshot.blockRange.map { clamp($0, length: length) }
    if newHidden != hiddenRange {
      let old = hiddenRange
      hiddenRange = newHidden
      for range in [old, newHidden].compactMap({ $0 }) {
        let valid = clamp(range, length: length)
        guard valid.length > 0 else { continue }
        layoutManager.invalidateGlyphs(forCharacterRange: valid, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: valid, actualCharacterRange: nil)
      }
    }
  }
  private func clamp(_ range: NSRange, length: Int) -> NSRange {
    let start = max(0, min(range.location, length))
    return NSRange(location: start, length: max(0, min(range.length, length - start)))
  }
}
`);
      for (const architecture of ["arm64", "x86_64"]) {
        const nativeArm = defaultPlan.architecture === "arm64";
        const result = spawnSync(nativeArm ? "/usr/bin/arch" : "xcrun", [
          ...(nativeArm ? ["-arm64", "xcrun"] : []), "swiftc", "-swift-version", "6",
          "-target", `${architecture}-apple-macosx14.0`, "-O", "-whole-module-optimization",
          "-emit-library", "-o", join(scratch, `${architecture}.dylib`), source,
        ], { encoding: "utf8", timeout: 60_000, maxBuffer: 4 * 1024 * 1024 });
        assert.equal(result.status, 0, `${architecture} optimized Prose getter failed: ${result.stderr}`);
      }
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
  } else {
    console.log("Skipping optimized Prose compilation: Swift compiler unavailable");
  }
}

console.log("OpenOrg macOS packaging tests passed");
