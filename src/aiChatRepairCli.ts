import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { defaultNativeServerExecutable } from "./nativeServerExecutable.js";

/** Use the same native transcript engine as the Celorga app, without launching an app or model. */
export async function runAIChatRepair(options: {
  corpusRoot: string; apply: boolean; watch: boolean; interval?: string;
  expectedRevision?: string; executable?: string;
}): Promise<void> {
  const interval = options.interval === undefined ? 120 : Number(options.interval);
  if (!Number.isFinite(interval) || interval < 10 || interval > 86_400) {
    throw new Error("--interval must be between 10 and 86400 seconds");
  }
  if (options.interval !== undefined && !options.watch) throw new Error("--interval requires --watch");
  if (options.watch && options.expectedRevision) throw new Error("--if-revision is only supported for a single repair");
  const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const executable = path.resolve(options.executable || defaultNativeServerExecutable(packageRoot));
  try { fs.accessSync(executable, fs.constants.X_OK); }
  catch { throw new Error("Native chat repair worker unavailable. On macOS, run npm run build:server in the checkout, or pass --executable PATH to a built OpenOrgServer."); }
  const args = ["--repair-transcript", path.resolve(options.corpusRoot)];
  if (options.apply) args.push("--apply");
  if (options.expectedRevision) args.push("--if-revision", options.expectedRevision);
  if (options.watch) args.push("--interval", String(interval));
  await new Promise<void>((resolve, reject) => {
    const child = spawn(executable, args, { stdio: "inherit" });
    const forward = (signal: NodeJS.Signals) => child.kill(signal);
    const interrupt = () => forward("SIGINT");
    const terminate = () => forward("SIGTERM");
    process.on("SIGINT", interrupt);
    process.on("SIGTERM", terminate);
    child.on("error", reject);
    child.on("close", (code, signal) => {
      process.removeListener("SIGINT", interrupt);
      process.removeListener("SIGTERM", terminate);
      if (code === 0 || signal === "SIGINT" || signal === "SIGTERM") resolve();
      else reject(new Error(`Native chat repair failed (exit ${code ?? signal})`));
    });
  });
}
