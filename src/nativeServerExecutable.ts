import fs from "node:fs";
import path from "node:path";

/**
 * The native OpenOrgServer worker built from a checkout. Prefer the optimized
 * release build (what `npm run build:server` produces); unoptimized debug Swift
 * is several times slower at chat-index and projection work on large corpora.
 * A debug build is used only when no release build exists.
 */
export function defaultNativeServerExecutable(packageRoot: string): string {
  const build = path.join(packageRoot, "apps/macos/Org2Workspace/.build");
  const release = path.join(build, "release/OpenOrgServer");
  const debug = path.join(build, "debug/OpenOrgServer");
  try {
    fs.accessSync(release, fs.constants.X_OK);
    return release;
  } catch {
    try {
      fs.accessSync(debug, fs.constants.X_OK);
      return debug;
    } catch {
      return release;
    }
  }
}
