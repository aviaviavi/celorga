#!/usr/bin/env node
// Real CLI corpus → native host TCP/APNs payload → shipped iOS controller/client →
// canonical decision + receipt. Apple's hardware callbacks are the sole simulated boundary.
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
assert.equal(process.platform, "darwin", "The cross-process iOS test requires macOS and Xcode; it must not silently skip.");
const artifacts = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-audio-e2e-"));
const derived = process.env.CELORGA_AUDIO_E2E_DERIVED_DATA || path.join(os.tmpdir(), "celorga-audio-e2e-ios");
const simulator = process.env.CELORGA_AUDIO_E2E_SIMULATOR || (() => {
  const list = JSON.parse(execFileSync("xcrun", ["simctl", "list", "-j"], { encoding: "utf8" }));
  const existing = Object.values(list.devices).flat().find(d => d.name === "Celorga Audio E2E" && d.isAvailable);
  if (existing) return existing.udid;
  const runtime = list.runtimes.filter(r => r.isAvailable && r.identifier.includes("iOS")).at(-1);
  const type = list.devicetypes.find(t => t.identifier.endsWith("iPhone-16-Pro"));
  assert.ok(runtime && type, "An iOS Simulator runtime and iPhone device type are required.");
  return execFileSync("xcrun", ["simctl", "create", "Celorga Audio E2E", type.identifier, runtime.identifier], { encoding: "utf8" }).trim();
})();
const arm64Host = execFileSync("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], { encoding: "utf8" }).trim() === "1";
const nativeCommand = (command, args) => arm64Host && ["swift", "xcodebuild", "xcrun"].includes(command)
  ? ["/usr/bin/arch", ["-arm64", command, ...args]] : [command, args];
let host;
let hostDone;
async function run(command, args, logName, extraEnvironment = {}) {
  const log = fs.openSync(path.join(artifacts, logName), "w");
  try {
    const [executable, arguments_] = nativeCommand(command, args);
    const child = spawn(executable, arguments_, { cwd: root, env: { ...process.env, ...extraEnvironment }, stdio: ["ignore", log, log] });
    const code = await new Promise((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); });
    assert.equal(code, 0, `${command} failed (${code}); see ${path.join(artifacts, logName)}`);
  } finally { fs.closeSync(log); }
}
const xcode = ["-project", "apps/ios/Org2Mobile/Org2Mobile.xcodeproj", "-scheme", "AudioApprovalEndToEnd", "-configuration", "Debug", "-destination", `platform=iOS Simulator,id=${simulator}`, "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"];
try {
  console.log(`Audio end-to-end evidence: ${artifacts}`);
  if (!process.argv.includes("--skip-build")) {
    console.log("Building the compiler and native phone/host test targets…");
    await run("npm", ["run", "build"], "compiler.log");
    await run("xcodebuild", ["build-for-testing", ...xcode], "ios-build.log");
    await run("swift", ["test", "--package-path", "apps/macos/Org2Workspace", "--filter", "AudioApprovalHostTests"], "host-tests.log");
  }
  await run("xcrun", ["simctl", "bootstatus", simulator, "-b"], "simulator-boot.log");
  console.log("Starting an isolated native host and temporary approval corpus…");
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  const hostLog = fs.openSync(path.join(artifacts, "host.log"), "w");
  const [hostExecutable, hostArguments] = nativeCommand("swift", ["test", "--skip-build", "--package-path", "apps/macos/Org2Workspace", "--filter", "AudioApprovalHostTests/testPhoneControllerEndToEndFixture"]);
  host = spawn(hostExecutable, hostArguments, {
    cwd: root, detached: true, env: { ...process.env, CELORGA_AUDIO_E2E_DIR: artifacts, CELORGA_AUDIO_E2E_PORT: String(port) }, stdio: ["ignore", hostLog, hostLog]
  });
  fs.closeSync(hostLog);
  hostDone = new Promise(resolve => host.once("exit", resolve));
  const deadline = Date.now() + 60_000;
  const readyPath = path.join(artifacts, "ready.json");
  while (!fs.existsSync(readyPath) && Date.now() < deadline && host.exitCode === null) await new Promise(resolve => setTimeout(resolve, 100));
  assert.ok(fs.existsSync(readyPath), `The native fixture did not start; see ${artifacts}/host.log`);
  const { endpoint } = JSON.parse(fs.readFileSync(readyPath, "utf8"));
  const productDir = path.join(derived, "Build", "Products");
  const testRun = fs.readdirSync(productDir).find(f => f.endsWith(".xctestrun") && !f.includes(".configured."));
  assert.ok(testRun, "Missing build-for-testing .xctestrun");
  const configured = path.join(productDir, "AudioApprovalEndToEnd.configured.xctestrun");
  execFileSync("python3", ["-c", `import plistlib,sys
p=plistlib.load(open(sys.argv[1],'rb'))
def configure(x):
 if isinstance(x,dict):
  if x.get('BlueprintName')=='Org2MobileTests' or 'TestBundlePath' in x:
   x.setdefault('EnvironmentVariables',{})['CELORGA_AUDIO_E2E_ENDPOINT']=sys.argv[3]
  for v in x.values(): configure(v)
 elif isinstance(x,list):
  for v in x: configure(v)
configure(p)
plistlib.dump(p,open(sys.argv[2],'wb'))`, path.join(productDir, testRun), configured, endpoint]);
  console.log("Running the iOS controller round trip…");
  await run("xcodebuild", ["test-without-building", "-xctestrun", configured, "-destination", `platform=iOS Simulator,id=${simulator}`, "-resultBundlePath", path.join(artifacts, "Phone.xcresult"), "-parallel-testing-enabled", "NO"], "phone.log");
  assert.equal(await hostDone, 0, `The host's canonical-state assertions failed; see ${artifacts}/host.log`);
  fs.writeFileSync(path.join(artifacts, "result.json"), JSON.stringify({ passed: true, simulator, boundary: "Apple PTT/headset/microphone callbacks simulated; production phone controller, TCP client, host and CLI executed", scenario: "Fresh push during stale in-flight workspace refresh; exact spoken yes and canonical receipt; older approval unchanged" }, null, 2));
  console.log(`PASS: native host ↔ iOS controller ↔ canonical decision. Evidence: ${artifacts}`);
} catch (error) {
  console.error(error.message);
  console.error(`FAIL. Evidence retained at ${artifacts}`);
  process.exitCode = 1;
} finally {
  if (host?.pid) {
    try { process.kill(-host.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
}
