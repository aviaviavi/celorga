import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export type UnifiedDiffOptions = {
  targetPath: string;
  temporaryDirectoryPrefix: string;
  useLabels?: boolean;
};

export function buildUnifiedDiff(
  before: string,
  after: string,
  options: UnifiedDiffOptions,
): string {
  if (before === after) return "";

  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), options.temporaryDirectoryPrefix),
  );
  try {
    const beforePath = path.join(temporaryDirectory, "before.org");
    const afterPath = path.join(temporaryDirectory, "after.org");
    fs.writeFileSync(beforePath, before, "utf8");
    fs.writeFileSync(afterPath, after, "utf8");

    const labelArgs = options.useLabels
      ? ["--label", options.targetPath, "--label", options.targetPath]
      : [];
    const result = spawnSync(
      "diff",
      ["-u", ...labelArgs, beforePath, afterPath],
      { encoding: "utf8" },
    );
    if (result.error) throw result.error;
    if (result.status !== 0 && result.status !== 1) {
      throw new Error(result.stderr || `diff exited with status ${result.status}`);
    }

    if (options.useLabels) return result.stdout || "";
    return (result.stdout || "")
      .split(beforePath).join(options.targetPath)
      .split(afterPath).join(options.targetPath);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
