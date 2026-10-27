import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseSwiftTestOptions, runSwiftSuite, swiftInvocation, swiftTestPlan,
  SWIFT_TIMING_TESTS,
} from "../tools/run-swift-tests.mjs";

const options = parseSwiftTestOptions([], 8);
assert.equal(options.jobs, 4);
assert.equal(parseSwiftTestOptions([], 2).jobs, 1);
assert.equal(parseSwiftTestOptions([], 64).jobs, 4);
for (const args of [["--jobs", "0"], ["--jobs", "1.5"], ["--jobs"], ["--report"], ["--configuration", "fast"], ["--unknown"]]) {
  assert.throws(() => parseSwiftTestOptions(args));
}

const plan = swiftTestPlan(options);
assert.deepEqual(plan.map((p) => p.phase), ["build", "correctness", "timing"]);
assert.ok(plan[0].args.includes("--build-tests"));
const [correctness, timing] = plan.slice(1).map((p) => p.args);
assert.ok(correctness.includes("--parallel"));
assert.equal(correctness[correctness.indexOf("--num-workers") + 1], "4");
assert.ok(timing.includes("--no-parallel"));
assert.equal(correctness[correctness.indexOf("--skip") + 1], timing[timing.indexOf("--filter") + 1],
  "complementary selections cover discovery once without omitting timing cases");
assert.ok([correctness, timing].every((args) => args.includes("--skip-build")), "both lanes reuse one build");
const selection = new RegExp(SWIFT_TIMING_TESTS);
for (const id of [
  "Org2WorkspaceCoreTests.WorkspacePerformanceRegressionTests/testWarmRefresh",
  "Org2WorkspaceCoreTests.OrgEditorInteractionTests/testKeyboardReturnAtEndOfExistingParagraphCreatesParagraphAfterCurrentText",
  "Org2WorkspaceCoreTests.CorpusFileCatalogTests/testProjectionPreparationHasLinearMultiSizeSlopeBudget",
  "Org2WorkspaceCoreTests.OrgSyntaxTextBufferSessionTests/testTenThousandUninterruptedCharactersStayExactAndLateEditsRemainBounded",
]) assert.ok(selection.test(id), `${id} must run without concurrent load`);
assert.ok(!selection.test("Org2WorkspaceCoreTests.Org2ModelsTests/testLoadsAndSavesSelectedEntrySource"));
assert.ok(!selection.test("Org2WorkspaceCoreTests.Org2ModelsTests/testOrg2CLIReusesWarmAppHTMLRendererWithinInteractiveBudgetExtra"),
  "individual timing selections match whole method names");

const custom = parseSwiftTestOptions(["--jobs", "2", "--configuration", "release", "--scratch-path", "/tmp/swift-cache"]);
for (const { args } of swiftTestPlan(custom)) {
  assert.equal(args[args.indexOf("--scratch-path") + 1], "/tmp/swift-cache");
  assert.equal(args[args.indexOf("--configuration") + 1], "release");
}
const serial = swiftTestPlan({ ...options, serial: true, skipBuild: true });
assert.equal(serial.length, 1);
assert.ok(serial[0].args.includes("--no-parallel"));
assert.ok(!serial[0].args.includes("--filter") && !serial[0].args.includes("--skip"), "serial debugging runs every test");

const calls = [];
let running = false;
const failed = await runSwiftSuite(options, async (args) => {
  assert.equal(running, false, "timing cannot overlap correctness or compilation");
  running = true;
  calls.push(args);
  await new Promise(setImmediate);
  running = false;
  return { code: calls.length === 2 ? 1 : 0, durationMs: 1 };
});
assert.equal(calls.length, 3, "correctness failures are not retried and do not leave timing unmeasured");
assert.equal(failed.ok, false, "passing timing checks cannot hide a correctness failure");
assert.equal(failed.phases[1].code, 1);
let buildCalls = 0;
const buildFailure = await runSwiftSuite(options, async () => {
  buildCalls += 1;
  return { code: 1, durationMs: 1 };
});
assert.equal(buildCalls, 1, "failed compilation must not execute stale test binaries");
assert.equal(buildFailure.ok, false);

const watched = [];
await runSwiftSuite({ ...options, idleTimeoutSeconds: 42 }, async (args, settings) => {
  watched.push(settings?.idleTimeoutSeconds);
  return { code: 0, durationMs: 1 };
});
assert.deepEqual(watched, [undefined, 42, 42], "only test phases are stopped when they go quiet");
assert.equal(parseSwiftTestOptions([]).idleTimeoutSeconds, 600);
assert.equal(parseSwiftTestOptions(["--idle-timeout", "90"]).idleTimeoutSeconds, 90);
assert.throws(() => parseSwiftTestOptions(["--idle-timeout", "0"]), /idle-timeout/);
const hungCalls = [];
const hung = await runSwiftSuite(options, async (args) => {
  hungCalls.push(args);
  return hungCalls.length === 2
    ? { code: 1, signal: "SIGKILL", hungTests: ["Suite/testHangs"], durationMs: 1 }
    : { code: 0, durationMs: 1 };
});
assert.equal(hungCalls.length, 3, "a hung correctness phase still leaves timing measured");
assert.equal(hung.ok, false);
assert.deepEqual(hung.phases[1].hungTests, ["Suite/testHangs"]);

assert.deepEqual(swiftInvocation("darwin", true), { command: "/usr/bin/arch", prefix: ["-arm64", "swift"] });
assert.deepEqual(swiftInvocation("darwin", false), { command: "swift", prefix: [] });
assert.deepEqual(swiftInvocation("linux", true), { command: "swift", prefix: [] });
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scripts = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).scripts;
assert.equal(scripts["test:macos"], "npm run build && node tools/run-swift-tests.mjs");
assert.equal(scripts["test:macos:serial"], "npm run test:macos -- --serial");
assert.ok(scripts["test:suite:built"].includes("node test/test-run-swift-tests.mjs"));
assert.ok(readFileSync(join(repoRoot, ".github/workflows/macos-performance.yml"), "utf8")
  .includes("run: node tools/run-swift-tests.mjs"));
console.log("Swift test runner tests passed");
