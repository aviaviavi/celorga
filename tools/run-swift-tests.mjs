#!/usr/bin/env node

import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// Keep wall-clock budgets off the worker pool. Add new timing cases here;
// correctness tests remain selected by SwiftPM discovery, not a saved list.
// The editor interaction class asserts frame budgets inside shared helpers.
export const SWIFT_TIMING_CLASSES = [
  "PerformanceGateTests", "PerformanceRegressionTests", "PerformanceTests",
  "OrgEditorInteractionTests",
];
export const SWIFT_TIMING_CASES = [
  "AIChatLargePasteTests/testRestoredMegabyteDraftSizingRemainsBounded",
  "AIChatLayoutTests/testLargeSharedRoomTranscriptGroupingRemainsResponsive",
  "AIChatThreadCreationTests/testCreatingThreadInsertsIncrementallyWithoutFullSidebarRebuild",
  "AIChatTranscriptStoreTests/testCorpusSelectionDoesNotSynchronouslyDecodeLegacyMonolith",
  "AIChatTranscriptStoreTests/testLongHistoryThreadSwitchDoesNotRebuildEverySidebarSummary",
  "AgentRunModelsTests/testRunCenterBuildsLargeUngroupedSectionWithinInteractiveBudget",
  "BlockingIOTests/testCancellingCLICommandStopsTheChildPromptly",
  "BlockingIOTests/testParkedPipeReadsDoNotStarveDetachedTasks",
  "BlockingIOTests/testSlowCLICommandsDoNotStarveDetachedTasks",
  "BundledAgentTests/testCancellationTerminatesAWaitingChild",
  "CorpusFileCatalogTests/testProjectionPreparationHasLinearMultiSizeSlopeBudget",
  "Org2ModelsTests/testApprovalFallbackScanDoesNotBlockMainActor",
  "Org2ModelsTests/testLocalCorpusApprovalsRefreshWhenConfigured",
  "Org2ModelsTests/testOrg2CLIAppHTMLRendererRecoversAfterCancellationBurst",
  "Org2ModelsTests/testOrg2CLIDoesNotWaitForeverWhenDescendantKeepsOutputPipeOpen",
  "Org2ModelsTests/testOrg2CLIReusesWarmAppHTMLRendererWithinInteractiveBudget",
  "Org2ModelsTests/testSavingRenderedBlockSchedulesAgendaRefreshWithoutBlocking",
  "OrgSyntaxTextBufferSessionTests/testTenThousandUninterruptedCharactersStayExactAndLateEditsRemainBounded",
  "OrgSyntaxTextEditorLifecycleTests/testDeepCursorStructuralCommandUsesLineIndexAndMutableStorage",
  "OrgSyntaxTextEditorLifecycleTests/testLargeDirtyExternalReplacementCheckpointsWithoutMainActorSnapshot",
  "OrgSyntaxTextEditorLifecycleTests/testLargeSemanticPresentationAppliesOnlyVisibleViewport",
  "OrgSyntaxTextEditorLifecycleTests/testPassiveResignCheckpointsLargeDraftOffMain",
  "OrgSyntaxTextEditorLifecycleTests/testStaleLargeSemanticCommandDefersWithoutSnapshotOrScan",
  "WorkspaceDisplayCacheTests/testCorpusAssignmentsStayFlatAcrossMultiSizeMainActorBudget",
  "WorkspaceDisplayCacheTests/testRunCenterFiltersLargeCachedCatalogWithinInteractiveBudget",
  "WorkspaceDisplayCacheTests/testRunCenterRebuildsLargeDisplayCacheOffMainWithinRefreshBudget",
  "WorkspaceDisplayCacheTests/testRunDetailLookupsStayIndexedAcrossALargeArchive",
  "WorkspaceRefreshTests/testFullRefreshStagesBatchQueriesAndReuseNativeParses",
];
export const SWIFT_TIMING_TESTS = [
  ...SWIFT_TIMING_CLASSES,
  ...SWIFT_TIMING_CASES.map((id) => `${id}$`),
].join("|");

// A test phase that prints nothing for this long is treated as hung: one stuck
// test otherwise blocks the whole run until CI's job timeout.
export const SWIFT_TEST_IDLE_TIMEOUT_SECONDS = 600;

export function parseSwiftTestOptions(argv, cpuCount = availableParallelism()) {
  const options = {
    jobs: Math.max(1, Math.min(4, Math.floor(cpuCount / 2))),
    configuration: "debug",
    idleTimeoutSeconds: SWIFT_TEST_IDLE_TIMEOUT_SECONDS,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (["--jobs", "--configuration", "--scratch-path", "--report", "--idle-timeout"].includes(arg)) {
      const value = argv[++i];
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value`);
      if (arg === "--jobs") options.jobs = Number(value);
      else if (arg === "--idle-timeout") options.idleTimeoutSeconds = Number(value);
      else if (arg === "--configuration") options.configuration = value;
      else if (arg === "--scratch-path") options.scratchPath = resolve(value);
      else options.report = resolve(value);
    } else if (arg === "--serial") options.serial = true;
    else if (arg === "--skip-build") options.skipBuild = true;
    else if (arg === "--help" || arg === "-h") options.help = true;
    else throw new Error(`Unknown option: ${arg}`);
  }
  if (!Number.isInteger(options.jobs) || options.jobs < 1) throw new Error("--jobs must be a positive integer");
  if (!["debug", "release"].includes(options.configuration)) throw new Error("--configuration must be debug or release");
  if (!(options.idleTimeoutSeconds > 0)) throw new Error("--idle-timeout must be a positive number of seconds");
  return options;
}

export function swiftTestPlan(options) {
  const common = ["--package-path", "apps/macos/Org2Workspace", "--configuration", options.configuration];
  if (options.scratchPath) common.push("--scratch-path", options.scratchPath);
  const phases = options.skipBuild ? [] : [{ phase: "build", args: ["build", ...common, "--build-tests"] }];
  if (options.serial) {
    phases.push({ phase: "serial", args: ["test", ...common, "--skip-build", "--no-parallel"] });
  } else {
    phases.push(
      { phase: "correctness", args: ["test", ...common, "--skip-build", "--parallel", "--num-workers", String(options.jobs), "--skip", SWIFT_TIMING_TESTS] },
      { phase: "timing", args: ["test", ...common, "--skip-build", "--no-parallel", "--filter", SWIFT_TIMING_TESTS] },
    );
  }
  return phases;
}

// npm may run an Intel Node under Rosetta. Use the host's native Swift cache
// and XCTest architecture even when process.arch reports x64.
export function swiftInvocation(platform, arm64) {
  return platform === "darwin" && arm64
    ? { command: "/usr/bin/arch", prefix: ["-arm64", "swift"] }
    : { command: "swift", prefix: [] };
}

// Names the XCTest cases still running on this machine.
function runningXCTests() {
  const ps = spawnSync("/bin/ps", ["-axo", "command="], { encoding: "utf8" });
  return (ps.stdout || "").split("\n")
    .map((line) => line.match(/xctest -XCTest (\S+)/)?.[1])
    .filter(Boolean);
}

function runSwift(args, { idleTimeoutSeconds } = {}) {
  const arm64 = process.platform === "darwin"
    && spawnSync("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], { encoding: "utf8" }).stdout?.trim() === "1";
  const { command, prefix } = swiftInvocation(process.platform, arm64);
  const started = performance.now();
  return new Promise((done) => {
    // Own process group, so a hung run can be stopped with every XCTest worker.
    const child = spawn(command, [...prefix, ...args], { cwd: repoRoot, stdio: ["ignore", "pipe", "pipe"], detached: true });
    let output = "";
    let hungTests;
    let watchdog;
    const armWatchdog = () => {
      if (!idleTimeoutSeconds) return;
      clearTimeout(watchdog);
      watchdog = setTimeout(() => {
        hungTests = runningXCTests();
        console.error(`No test output for ${idleTimeoutSeconds}s; stopping hung tests: ${hungTests.join(", ") || "(none found)"}`);
        try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); }
      }, idleTimeoutSeconds * 1000);
    };
    armWatchdog();
    child.stdout.on("data", (chunk) => { output += chunk; process.stdout.write(chunk); armWatchdog(); });
    child.stderr.on("data", (chunk) => { output += chunk; process.stderr.write(chunk); armWatchdog(); });
    child.once("error", (error) => { console.error(error.message); });
    child.once("close", (code, signal) => {
      clearTimeout(watchdog);
      done({
        code: hungTests ? 1 : code ?? 1, signal, durationMs: performance.now() - started,
        buildSeconds: Number(output.match(/Build complete! \(([\d.]+)s\)/)?.[1]) || 0,
        ...(hungTests ? { hungTests } : {}),
      });
    });
  });
}

export async function runSwiftSuite(options, run = runSwift) {
  const started = performance.now();
  const phases = [];
  for (const job of swiftTestPlan(options)) {
    // A build can stay quiet while one large file compiles, so only test
    // phases get the idle watchdog.
    const result = await run(job.args, {
      idleTimeoutSeconds: job.phase === "build" ? undefined : options.idleTimeoutSeconds,
    });
    phases.push({ ...job, ...result });
    // Never run stale binaries after a failed build. Correctness failures still
    // allow timing checks to run, but remain failures with no automatic retry.
    // A test phase stopped by the watchdog still lets the timing phase run.
    if ((job.phase === "build" && result.code !== 0) || (result.signal && !result.hungTests)) break;
  }
  return { jobs: options.jobs, durationMs: performance.now() - started, ok: phases.every((p) => p.code === 0), phases };
}

async function main() {
  const options = parseSwiftTestOptions(process.argv.slice(2));
  if (options.help) {
    console.log("Usage: node tools/run-swift-tests.mjs [--jobs N] [--serial] [--skip-build] [--configuration debug|release] [--scratch-path DIR] [--report FILE] [--idle-timeout SECONDS]");
    return;
  }
  console.log(options.serial ? "Running all Swift tests serially" : `Running Swift correctness on ${options.jobs} workers, then timing checks serially`);
  const report = await runSwiftSuite(options);
  if (options.report) {
    mkdirSync(dirname(options.report), { recursive: true });
    writeFileSync(options.report, JSON.stringify(report, null, 2) + "\n");
  }
  console.log(report.phases.map((p) => `${p.phase}: ${(p.durationMs / 1000).toFixed(1)}s (exit ${p.code})`).join("; "));
  process.exitCode = report.ok ? 0 : 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
