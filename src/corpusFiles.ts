import fs from "node:fs";
import path from "node:path";

const DEFAULT_IGNORED_CORPUS_DIRECTORIES = new Set([
  ".git",
  ".hg",
  ".svn",
  ".stversions",
  ".trash",
  ".org2",
  ".celorga",
  "node_modules",
  "dist",
  "build",
  ".build",
  "DerivedData",
  "sync-conflicts",
]);

export function isDefaultArchivePath(filePath: string): boolean {
  const normalized = filePath.replace(/\\/g, "/").toLowerCase();
  const base = path.basename(normalized);
  return (
    normalized.includes("/archive/") ||
    normalized.includes("/archives/") ||
    base.endsWith(".org_archive") ||
    base.endsWith(".org2_archive") ||
    base.endsWith(".archive") ||
    base.includes(".archive.") ||
    base.endsWith("_archive")
  );
}

function isDefaultIgnoredCorpusDirectoryName(name: string): boolean {
  return name.startsWith(".") || DEFAULT_IGNORED_CORPUS_DIRECTORIES.has(name);
}

function hasDefaultIgnoredCorpusPathComponent(filePath: string): boolean {
  return path.normalize(filePath)
    .split(path.sep)
    .some((component) => DEFAULT_IGNORED_CORPUS_DIRECTORIES.has(component));
}

export function isDefaultIgnoredSyncArtifactPath(filePath: string): boolean {
  const base = path.basename(filePath);
  return hasDefaultIgnoredCorpusPathComponent(filePath)
    || base.startsWith(".syncthing.")
    || base.includes(".sync-conflict-")
    || base.endsWith(".tmp");
}

export function isOrgLikeFileName(fileName: string, includeArchives = false): boolean {
  if (fileName.startsWith(".")) return false;
  if (isDefaultIgnoredSyncArtifactPath(fileName)) return false;
  if (fileName.endsWith(".org") || fileName.endsWith(".org2")) return true;
  return includeArchives && isDefaultArchivePath(fileName);
}

export function listOrgLikeFiles(rootDir: string, recursiveScan: boolean, includeArchives = false): string[] {
  const out: string[] = [];

  const walk = (directory: string): void => {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (isDefaultIgnoredCorpusDirectoryName(entry.name)) continue;
        if (recursiveScan) walk(full);
        continue;
      }

      if (!entry.isFile()) continue;
      if (!isOrgLikeFileName(entry.name, includeArchives)) continue;
      if (!includeArchives && isDefaultArchivePath(full)) continue;
      out.push(full);
    }
  };

  walk(rootDir);
  if (recursiveScan) scannedRoots.set(path.resolve(rootDir), (scannedRoots.get(path.resolve(rootDir)) ?? 0) + out.length);
  return out;
}

// Org files found per recursively scanned root in this process.
const scannedRoots = new Map<string, number>();
const reportedHiddenRoots = new Set<string>();
// Knowledge-base tools that keep their whole Org wiki in a hidden folder.
const KNOWN_HIDDEN_KNOWLEDGE_BASES = new Set([".crucible"]);

/**
 * Hidden folders directly under `rootDir` that hold Org files, such as a
 * crucible project's `.crucible/`. Corpus scans skip hidden folders, so a
 * corpus kept entirely inside one looks empty from the folder above it.
 */
export function findHiddenOrgDirectories(rootDir: string, maxEntries = 5000): string[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(rootDir, { withFileTypes: true });
  } catch {
    return [];
  }
  const found: string[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith(".") || DEFAULT_IGNORED_CORPUS_DIRECTORIES.has(entry.name)) continue;
    let budget = maxEntries;
    const stack = [path.join(rootDir, entry.name)];
    let hasOrg = false;
    while (stack.length && !hasOrg && budget > 0) {
      const directory = stack.pop()!;
      let children: fs.Dirent[];
      try {
        children = fs.readdirSync(directory, { withFileTypes: true });
      } catch {
        continue;
      }
      for (const child of children) {
        budget -= 1;
        if (child.isDirectory()) {
          if (!isDefaultIgnoredCorpusDirectoryName(child.name)) stack.push(path.join(directory, child.name));
        } else if (child.isFile() && isOrgLikeFileName(child.name)) {
          hasOrg = true;
          break;
        }
      }
    }
    if (hasOrg) found.push(path.join(rootDir, entry.name));
  }
  return found.sort();
}

export function hiddenOrgDirectoriesHint(rootDir: string, hidden: string[]): string {
  const names = hidden.map((dir) => path.relative(rootDir, dir) || dir);
  const first = path.join(rootDir, names[0]!);
  return `celorga: ${names.join(", ")} under ${rootDir} ${names.length === 1 ? "holds" : "hold"} Org files that corpus scans skip, because they skip hidden folders. `
    + `Use --dir ${first}, or make it a corpus with celorga corpus init --dir ${first} --id ID --name NAME --apply and open that folder.`;
}

/**
 * Prints the hidden-folder hint once per root: for `rootDir`, or for every
 * root scanned in this process that found no Org files or sits above a known
 * hidden knowledge base such as `.crucible/`.
 */
export function reportHiddenOrgDirectories(rootDir?: string): void {
  const roots = rootDir ? [path.resolve(rootDir)] : [...scannedRoots.keys()];
  for (const root of roots) {
    if (reportedHiddenRoots.has(root)) continue;
    reportedHiddenRoots.add(root);
    const hidden = findHiddenOrgDirectories(root);
    if (hidden.length === 0) continue;
    const visible = rootDir ? listOrgLikeFiles(root, true).length : scannedRoots.get(root) ?? 0;
    const known = hidden.filter((dir) => KNOWN_HIDDEN_KNOWLEDGE_BASES.has(path.basename(dir)));
    if (visible === 0) process.stderr.write(hiddenOrgDirectoriesHint(root, hidden) + "\n");
    else if (known.length) process.stderr.write(hiddenOrgDirectoriesHint(root, known) + "\n");
  }
}
