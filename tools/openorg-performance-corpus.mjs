#!/usr/bin/env node

import {
  copyFile,
  lstat,
  mkdir,
  readFile,
  readdir,
  realpath,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createHash } from "node:crypto";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const allowedExtensions = new Set([".org", ".org2", ".md", ".csv"]);
const ignoredDirectories = new Set([
  ".git",
  ".hg",
  ".svn",
  ".stversions",
  ".trash",
  ".org2",
  "node_modules",
  "dist",
  "build",
  ".build",
  "DerivedData",
  "sync-conflicts",
]);

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--generate") options.generateShape = argv[++index];
    else if (argument === "--profile") options.profileRoot = argv[++index];
    else if (argument === "--output") options.output = argv[++index];
    else if (argument === "--help" || argument === "-h") options.help = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  return options;
}

function usage() {
  return [
    "Usage:",
    "  node tools/openorg-performance-corpus.mjs --generate SHAPE.json --output CORPUS_DIR",
    "  node tools/openorg-performance-corpus.mjs --profile CORPUS_DIR --output SHAPE.json",
    "",
    "Profiling records aggregate counts and size percentiles only. It never copies document",
    "contents, names, IDs, or source paths into the resulting shape file.",
  ].join("\n");
}

function percentile(values, percentileValue) {
  if (values.length === 0) return 0;
  const ordered = [...values].sort((left, right) => left - right);
  const index = Math.max(0, Math.ceil(ordered.length * percentileValue) - 1);
  return ordered[Math.min(index, ordered.length - 1)];
}

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function isSHA256(value) {
  return typeof value === "string" && /^[a-f0-9]{64}$/u.test(value);
}

function syntheticSize(index, count, sizes) {
  if (index === count - 1) return sizes.max;
  const rank = index + 1;
  const p50Rank = Math.ceil(count * 0.50);
  const p90Rank = Math.ceil(count * 0.90);
  const p95Rank = Math.ceil(count * 0.95);
  const p99Rank = Math.ceil(count * 0.99);
  const interpolate = (lower, upper, lowerRank, upperRank) => {
    if (upperRank <= lowerRank) return upper;
    const fraction = (rank - lowerRank) / (upperRank - lowerRank);
    return Math.round(lower + ((upper - lower) * fraction));
  };
  if (rank <= p50Rank) return sizes.p50;
  if (rank <= p90Rank) return interpolate(sizes.p50, sizes.p90, p50Rank, p90Rank);
  if (rank <= p95Rank) return interpolate(sizes.p90, sizes.p95, p90Rank, p95Rank);
  if (rank <= p99Rank) return interpolate(sizes.p95, sizes.p99, p95Rank, p99Rank);
  // Keep the one-percent tail representative without manufacturing hundreds of
  // megabytes that are absent from the aggregate profile. The final document
  // still exercises the observed maximum size exactly.
  const tailUpper = Math.min(sizes.max, sizes.p99 * 3);
  return interpolate(sizes.p99, tailUpper, p99Rank, count - 1);
}

function zoneRelativePaths(shape) {
  const paths = [];
  const extensionMix = shape.documents.extensionMix ?? {};
  const extensionSequence = [];
  const orderedExtensions = ["org", "org2", "md", "csv"];
  const counts = new Map(orderedExtensions.map((extension) => [
    extension,
    Number(extensionMix[extension] ?? 0),
  ]));
  if ((counts.get("org2") ?? 0) > 0) {
    counts.set("org2", counts.get("org2") - 1);
  }
  for (const extension of orderedExtensions) {
    extensionSequence.push(...Array(counts.get(extension) ?? 0).fill(extension));
  }
  if (Number(extensionMix.org2 ?? 0) > 0) {
    // Keep the maximum-size fixture on the large-file source-editor path.
    extensionSequence.push("org2");
  }
  if (extensionSequence.length !== Number(shape.documents.activeFileCount)) {
    throw new Error(
      `Shape declares ${shape.documents.activeFileCount} active files but its extension mix adds up to ${extensionSequence.length}`
    );
  }
  let globalIndex = 0;
  const add = (directory, count) => {
    for (let index = 0; index < count; index += 1) {
      const extension = extensionSequence[globalIndex];
      const fileName = `performance-${String(globalIndex + 1).padStart(5, "0")}.${extension}`;
      paths.push(directory ? join(directory, fileName) : fileName);
      globalIndex += 1;
    }
  };

  add("", Number(shape.documents.rootFileCount));
  for (const zone of shape.documents.zones ?? []) {
    const directory = zone.kind === "other" ? "reference" : zone.kind;
    add(directory, Number(zone.fileCount));
  }
  if (paths.length !== Number(shape.documents.activeFileCount)) {
    throw new Error(
      `Shape declares ${shape.documents.activeFileCount} active files but its root/zones add up to ${paths.length}`
    );
  }
  return paths;
}

function ordinaryDocumentBytes(relativePath, index, targetByteCount) {
  const identifier = `performance-${String(index + 1).padStart(5, "0")}`;
  const now = new Date();
  const scheduledDate = now.toISOString().slice(0, 10);
  const weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][now.getUTCDay()];
  const isMeeting = relativePath.split(sep)[0] === "meetings";
  const header = Buffer.from(
    `${isMeeting ? "#+ORG2_KIND: meeting\n" : ""}` +
      `* TODO Synthetic performance fixture ${index + 1}\n` +
      `SCHEDULED: <${scheduledDate} ${weekday}>\n` +
      `:PROPERTIES:\n:ID: ${identifier}\n` +
      `${isMeeting ? `:KIND: meeting\n:RECORDED_AT: ${scheduledDate}T12:00:00Z\n` : ""}` +
      `:END:\n` +
      `This document is generated from aggregate corpus shape metadata.\n` +
      `[[id:performance-${String(((index + 1) % 100) + 1).padStart(5, "0")}][Synthetic link]]\n`
  );
  const target = Math.max(header.length, targetByteCount);
  const line = Buffer.from("Deterministic generated text for OpenOrg performance measurement.\n");
  const buffer = Buffer.allocUnsafe(target);
  header.copy(buffer, 0);
  let offset = header.length;
  while (offset < target) {
    const copied = line.copy(buffer, offset, 0, Math.min(line.length, target - offset));
    offset += copied;
  }
  return buffer;
}

function adversarialOrgDocumentBytes(relativePath, index, targetByteCount, workload = {}) {
  const identifier = `performance-${String(index + 1).padStart(5, "0")}`;
  const target = Math.max(1, targetByteCount);
  const longLineBytes = Math.max(512, Number(workload.longLineBytes ?? 4_096));
  const blockTargetBytes = Math.max(384, Number(workload.headlineIntervalBytes ?? 896));
  const longLineEvery = Math.max(2, Number(workload.longLineEvery ?? 11));
  const crlfEvery = Math.max(2, Number(workload.crlfEvery ?? 3));
  const chunks = [];
  let generatedBytes = 0;
  let section = 0;

  const appendWhole = (value) => {
    const chunk = Buffer.from(value, "utf8");
    if (generatedBytes + chunk.length > target) return false;
    chunks.push(chunk);
    generatedBytes += chunk.length;
    return true;
  };

  appendWhole(
    `#+TITLE: Structurally adversarial OpenOrg performance fixture\n` +
      `#+PROPERTY: header-args :results replace\r\n` +
      `#+FILETAGS: :performance:unicode:\n` +
      `* TODO [#A] Synthetic maximum document — λ 東京 🚀\r\n` +
      `:PROPERTIES:\n:ID: ${identifier}\r\n:OWNER: performance-gate\n:END:\r\n`
  );

  while (generatedBytes + blockTargetBytes <= target) {
    section += 1;
    const newline = section % crlfEvery === 0 ? "\r\n" : "\n";
    const level = 2 + (section % 4);
    const todo = ["TODO", "IN_PROGRESS", "WAIT", "DONE"][section % 4];
    const diagnosticLike = section === 1 || section % 7 === 0
      ? `Malformed-looking fixture token [[id:performance-${section}][review ${section}${newline}`
      : `[[id:performance-${String((section % 100) + 1).padStart(5, "0")}][Synthetic link ${section}]]${newline}`;
    const longLine = section % longLineEvery === 0
      ? `Long-line-${section}: ${"x".repeat(longLineBytes)} Ω${newline}`
      : "";
    const block =
      `${"*".repeat(level)} ${todo} [#${["A", "B", "C"][section % 3]}] ` +
      `Section ${section} — café 漢字 🧪${newline}` +
      `SCHEDULED: <2026-08-${String((section % 28) + 1).padStart(2, "0")} Mon> ` +
      `DEADLINE: <2026-09-${String((section % 28) + 1).padStart(2, "0")} Tue>${newline}` +
      `:PROPERTIES:${newline}:ID: ${identifier}-section-${section}${newline}` +
      `:EFFORT: ${String((section % 8) + 1)}:00${newline}:UNICODE: naïve/東京/🚀${newline}:END:${newline}` +
      `- [${section % 3 === 0 ? "X" : " "}] Nested list item ${section}${newline}` +
      `  - Child item with =inline code= and *emphasis*${newline}` +
      `| column | value | status |${newline}| ${section} | αβγ | ${todo} |${newline}` +
      `#+BEGIN_SRC swift${newline}let syntheticValue${section} = ${section}${newline}#+END_SRC${newline}` +
      diagnosticLike +
      longLine;
    if (!appendWhole(block)) break;
  }

  const remaining = target - generatedBytes;
  if (remaining > 0) {
    // End with single-byte ASCII so the exact aggregate maximum is preserved
    // without truncating one of the Unicode scalars above.
    chunks.push(Buffer.from("z".repeat(remaining), "ascii"));
  }
  return Buffer.concat(chunks, target);
}

function documentBytes(relativePath, index, targetByteCount, options = {}) {
  if (options.adversarial === true && /\.org2?$/iu.test(relativePath)) {
    return adversarialOrgDocumentBytes(
      relativePath,
      index,
      targetByteCount,
      options.workload
    );
  }
  return ordinaryDocumentBytes(relativePath, index, targetByteCount);
}

async function runPool(items, concurrency, operation) {
  let nextIndex = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      await operation(items[index], index);
    }
  });
  await Promise.all(workers);
}

export async function generatePerformanceCorpus(shapePath, outputDirectory) {
  const shape = JSON.parse(await readFile(resolve(shapePath), "utf8"));
  if (shape.$schema !== "org2:openorg-performance-corpus-shape:v1") {
    throw new Error(`Unsupported performance shape schema: ${shape.$schema ?? "missing"}`);
  }
  if (shape.privacy?.containsCorpusContent !== false || shape.privacy?.containsSourcePaths !== false) {
    throw new Error("Performance shapes must explicitly declare that they contain no corpus contents or source paths");
  }

  const root = resolve(outputDirectory);
  await mkdir(root, { recursive: true });
  const relativePaths = zoneRelativePaths(shape);
  const directories = new Set(relativePaths.map((path) => dirname(path)).filter((path) => path !== "."));
  await Promise.all([...directories].map((directory) => mkdir(join(root, directory), { recursive: true })));

  const largestIndex = relativePaths.length - 1;
  await runPool(relativePaths, 24, async (relativePath, index) => {
    const targetSize = syntheticSize(index, relativePaths.length, shape.documents.sizeBytes);
    await writeFile(
      join(root, relativePath),
      documentBytes(relativePath, index, targetSize, {
        adversarial: index === largestIndex,
        workload: shape.documents.largeDocumentWorkload,
      }),
      { mode: 0o600 }
    );
  });

  // Exercise agenda and roam work across the full corpus shape. Restricting
  // the generated fixture to notes/ and daily/ left the 1,934 root documents
  // (and other populated zones) out of one of the app's most expensive
  // projections, even though the real corpus includes them.
  const agendaFiles = ["**/*.org", "**/*.org2"];
  const sourceProfileCount = Number(shape.workspaceScale?.sourceProfileCount ?? 12);
  const externalSources = Object.fromEntries(
    Array.from({ length: sourceProfileCount }, (_, index) => [
      `synthetic-performance-${String(index + 1).padStart(2, "0")}`,
      {
        type: index % 2 === 0 ? "slack" : "notion",
        enabled: true,
        scopes: [`fixture-${index % 4}`],
        media: "metadata-only",
        rawZone: `raw/performance/source-${index + 1}`,
        ingestion: {
          reviewZone: `views/performance/source-${index + 1}`,
          maxItems: 500,
        },
      },
    ])
  );
  await writeFile(
    join(root, "celorga.json"),
    `${JSON.stringify({
      agendaFiles,
      recursive: true,
      roam: {
        indexDir: "notes",
        nodesDir: "notes",
        dailiesDir: "daily",
      },
      externalSources,
    }, null, 2)}\n`,
    { mode: 0o600 }
  );

  const manifest = {
    $schema: "org2:openorg-performance-generated-corpus:v1",
    shapeVersion: shape.version,
    activeFileCount: relativePaths.length,
    largestDocumentRelativePath: relativePaths[largestIndex],
    sampleDocumentRelativePaths: relativePaths.slice(0, Number(shape.events?.burstFileCount ?? 100)),
  };
  await writeFile(
    join(root, ".openorg-performance-generated.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
    { mode: 0o600 }
  );
  return { root, shape, manifest };
}

function classifiedZone(relativePath) {
  const components = relativePath.split(sep);
  if (components.length === 1) return "root";
  const topLevel = components[0];
  return new Set(["notes", "daily", "agents", "meetings", "views"]).has(topLevel)
    ? topLevel
    : "other";
}

async function inventoryDocuments(root) {
  const documents = [];
  const visit = async (directory) => {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (entry.name.startsWith(".") || ignoredDirectories.has(entry.name)) continue;
        await visit(join(directory, entry.name));
        continue;
      }
      if (!entry.isFile() || entry.name.startsWith(".")) continue;
      const extension = extname(entry.name).toLowerCase();
      if (!allowedExtensions.has(extension)) continue;
      const absolutePath = join(directory, entry.name);
      let info;
      try {
        info = await stat(absolutePath);
      } catch (error) {
        if (error?.code === "ENOENT") continue;
        throw error;
      }
      documents.push({
        extension: extension.slice(1),
        zone: classifiedZone(relative(root, absolutePath)),
        byteCount: info.size,
      });
    }
  };
  await visit(root);
  return documents;
}

async function aggregateChatShape(root) {
  const transcriptPath = join(root, ".org2", "openclaw-chat.json");
  const sharded = await inspectShardedChatStore(transcriptPath);
  if (sharded) return sharded.shape;
  try {
    const transcriptInfo = await stat(transcriptPath);
    const payload = JSON.parse(await readFile(transcriptPath, "utf8"));
    const threads = Array.isArray(payload.threads) ? payload.threads : [];
    const messages = threads.flatMap((thread) => Array.isArray(thread.messages) ? thread.messages : []);
    let attachmentBytes = 0;
    let largestMessageBytes = 0;
    for (const message of messages) {
      // Body text and attachments are separate UI workloads. Legacy monoliths
      // encode attachment data inline (and can carry large response traces),
      // so sizing the complete message record here would turn those bytes into
      // synthetic body text while also counting the attachments below.
      const body = typeof message?.content === "string" ? message.content : "";
      largestMessageBytes = Math.max(largestMessageBytes, Buffer.byteLength(body));
      for (const attachment of Array.isArray(message.attachments) ? message.attachments : []) {
        if (typeof attachment.data === "string") {
          attachmentBytes += Buffer.byteLength(attachment.data, "base64");
        }
      }
    }
    const archivedThreadCount = threads.filter((thread) => thread.isArchived === true).length;
    return {
      storageLayout: "legacy-monolith",
      threadCount: threads.length,
      activeThreadCount: threads.length - archivedThreadCount,
      archivedThreadCount,
      messageCount: messages.length,
      maxMessagesPerThread: threads.reduce(
        (maximum, thread) => Math.max(maximum, Array.isArray(thread.messages) ? thread.messages.length : 0),
        0
      ),
      attachmentBytes,
      largestMessageBytes,
      encodedTranscriptBytes: transcriptInfo.size,
    };
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

// The live app rewrites the sharded store while it runs: a marker can name a
// manifest that is replaced moments later. Retry a torn read a few times.
async function inspectShardedChatStore(transcriptPath, attempts = 5) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await inspectShardedChatStoreOnce(transcriptPath);
    } catch (error) {
      if (attempt >= attempts || !isTornChatStoreRead(error)) throw error;
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 100 * attempt));
    }
  }
}

function isTornChatStoreRead(error) {
  return error?.code === "ENOENT"
    || /digest mismatch|Missing sharded AI chat thread/u.test(String(error?.message ?? ""));
}

async function referencedStoreManifests(storeRoot) {
  const pointers = [];
  for (const directory of ["heads", "."]) {
    let names;
    try {
      names = await readdir(join(storeRoot, directory));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    for (const name of names) {
      if (!name.endsWith(".json") || name.startsWith(".")) continue;
      if (directory === "." && !name.startsWith("migration-marker")) continue;
      try {
        pointers.push(JSON.parse(await readFile(join(storeRoot, directory, name), "utf8")));
      } catch {
        // A torn or foreign pointer names nothing worth keeping.
      }
    }
  }
  const names = new Set();
  for (const pointer of pointers) {
    for (const value of [pointer?.currentManifest, pointer?.previousManifest]) {
      if (typeof value === "string" && basename(value) === value) names.add(value);
    }
  }
  return names;
}

async function newestStoreHead(storeRoot) {
  let names;
  try {
    names = await readdir(join(storeRoot, "heads"));
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
  let newest;
  for (const name of names) {
    if (!name.endsWith(".json") || name.startsWith(".")) continue;
    let head;
    try {
      head = JSON.parse(await readFile(join(storeRoot, "heads", name), "utf8"));
    } catch {
      continue;
    }
    if (!/^(org2|celorga):ai-chat-transcript-head:v1$/u.test(String(head?.schema))
        || head.version !== 1
        || typeof head.currentManifest !== "string"
        || basename(head.currentManifest) !== head.currentManifest
        || !isSHA256(head.currentDigest)) {
      continue;
    }
    const generation = Number(head.currentGeneration ?? 0);
    if (!newest
        || generation > newest.generation
        || (generation === newest.generation && head.currentManifest > newest.currentManifest)) {
      newest = { ...head, generation };
    }
  }
  return newest;
}

async function inspectShardedChatStoreOnce(transcriptPath) {
  const storeRoot = join(dirname(transcriptPath), `${basename(transcriptPath, extname(transcriptPath))}.store`);
  const markerPath = join(storeRoot, "migration-marker.json");
  let markerBytes = 0;
  let manifestPath = join(storeRoot, "manifest.json");
  let expectedManifestDigest;
  try {
    const markerInfo = await stat(markerPath);
    const markerData = await readFile(markerPath);
    const marker = JSON.parse(markerData.toString("utf8"));
    if (marker?.schema !== "org2:ai-chat-transcript-store-marker:v1"
        || marker.version !== 1
        || typeof marker.currentManifest !== "string"
        || basename(marker.currentManifest) !== marker.currentManifest
        || !isSHA256(marker.currentDigest)) {
      throw new Error(`Invalid sharded AI chat marker at ${markerPath}`);
    }
    markerBytes = markerInfo.size;
    manifestPath = join(storeRoot, "manifests", marker.currentManifest);
    expectedManifestDigest = marker.currentDigest;
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  // Stores with per-writer heads ignore the historical marker; the newest
  // head generation is the current commit.
  const head = await newestStoreHead(storeRoot);
  if (head) {
    manifestPath = join(storeRoot, "manifests", head.currentManifest);
    expectedManifestDigest = head.currentDigest;
  }

  let manifestInfo;
  let manifest;
  try {
    manifestInfo = await stat(manifestPath);
    const manifestData = await readFile(manifestPath);
    if (expectedManifestDigest && sha256(manifestData) !== expectedManifestDigest) {
      throw new Error(`Sharded AI chat manifest digest mismatch at ${manifestPath}`);
    }
    manifest = JSON.parse(manifestData.toString("utf8"));
  } catch (error) {
    if (error?.code === "ENOENT" && manifestPath === join(storeRoot, "manifest.json")) {
      return undefined;
    }
    throw error;
  }
  const isVersion1 = manifest?.schema === "org2:ai-chat-transcript-manifest:v1";
  const isVersion2 = manifest?.schema === "org2:ai-chat-transcript-manifest:v2"
    && manifest.version === 2;
  if ((!isVersion1 && !isVersion2) || !Array.isArray(manifest.threads)) {
    throw new Error(`Invalid sharded AI chat manifest at ${manifestPath}`);
  }

  let messageCount = 0;
  let maxMessagesPerThread = 0;
  let attachmentBytes = 0;
  let largestMessageBytes = 0;
  let encodedTranscriptBytes = markerBytes + manifestInfo.size;
  for (const manifestThread of manifest.threads) {
    const thread = isVersion2 ? manifestThread?.metadata : manifestThread;
    if (!thread || typeof thread !== "object") {
      throw new Error(`Invalid sharded AI chat thread metadata at ${manifestPath}`);
    }
    const storedCount = Number(thread.storedMessageCount ?? 0);
    maxMessagesPerThread = Math.max(maxMessagesPerThread, storedCount);
    const threadID = typeof thread.id === "string" ? thread.id.toLowerCase() : "";
    if (!threadID) {
      messageCount += storedCount;
      continue;
    }
    const shardRelativePath = isVersion2
      ? String(manifestThread?.shard ?? "")
      : join("threads", `${threadID}.json`);
    const shardPath = resolve(storeRoot, shardRelativePath);
    const threadStoreRoot = resolve(storeRoot, "threads");
    if (!shardRelativePath || !shardPath.startsWith(`${threadStoreRoot}${sep}`)) {
      throw new Error(`Invalid sharded AI chat shard path in ${manifestPath}`);
    }
    try {
      const shardInfo = await stat(shardPath);
      const shardData = await readFile(shardPath);
      if (isVersion2) {
        const expectedShardDigest = manifestThread?.shardDigest;
        if (!isSHA256(expectedShardDigest) || sha256(shardData) !== expectedShardDigest) {
          throw new Error(`Sharded AI chat thread digest mismatch at ${shardPath}`);
        }
      }
      const shard = JSON.parse(shardData.toString("utf8"));
      if (shard?.schema !== "org2:ai-chat-thread:v1" || !Array.isArray(shard.messages)) {
        throw new Error(`Invalid sharded AI chat thread at ${shardPath}`);
      }
      encodedTranscriptBytes += shardInfo.size;
      messageCount += shard.messages.length;
      maxMessagesPerThread = Math.max(maxMessagesPerThread, shard.messages.length);
      for (const stored of shard.messages) {
        const body = typeof stored?.message?.content === "string"
          ? stored.message.content
          : "";
        largestMessageBytes = Math.max(largestMessageBytes, Buffer.byteLength(body));
        for (const attachment of Array.isArray(stored?.attachments) ? stored.attachments : []) {
          const byteCount = Number(attachment?.byteCount ?? 0);
          if (Number.isFinite(byteCount) && byteCount > 0) {
            attachmentBytes += byteCount;
          }
        }
      }
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      if (isVersion2) {
        throw new Error(`Missing sharded AI chat thread at ${shardPath}`);
      }
      messageCount += storedCount;
    }
  }
  const archivedThreadCount = manifest.threads.filter((entry) => {
    const thread = isVersion2 ? entry?.metadata : entry;
    return thread?.isArchived === true;
  }).length;
  return {
    shape: {
      storageLayout: isVersion2 ? "sharded-v2" : "sharded-v1",
      threadCount: manifest.threads.length,
      activeThreadCount: manifest.threads.length - archivedThreadCount,
      archivedThreadCount,
      messageCount,
      maxMessagesPerThread,
      attachmentBytes,
      largestMessageBytes,
      encodedTranscriptBytes,
    },
  };
}

async function copyFileIfPresent(source, destination) {
  try {
    const info = await lstat(source);
    if (!info.isFile()) return false;
    await mkdir(dirname(destination), { recursive: true });
    await copyFile(source, destination);
    return true;
  } catch (error) {
    // Corpora can change while the read-only snapshot is being assembled.
    // A concurrently moved note should not turn the source into a mutation
    // target or leave a half-copied private artifact.
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function collectRegularFiles(root, options = {}) {
  const files = [];
  const visit = async (directory, relativeDirectory = "") => {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      const relativePath = relativeDirectory ? join(relativeDirectory, entry.name) : entry.name;
      if (options.skipIgnoredDirectories && entry.name.startsWith(".")) continue;
      if (entry.isDirectory()) {
        if (options.skipIgnoredDirectories
            && (entry.name.startsWith(".") || ignoredDirectories.has(entry.name))) continue;
        await visit(join(directory, entry.name), relativePath);
      } else if (entry.isFile() && (!options.filter || options.filter(relativePath))) {
        files.push(relativePath);
      }
    }
  };
  await visit(root);
  return files;
}

async function copyRelativeFiles(sourceRoot, targetRoot, relativePaths) {
  let copied = 0;
  await runPool(relativePaths, 24, async (relativePath) => {
    if (await copyFileIfPresent(join(sourceRoot, relativePath), join(targetRoot, relativePath))) {
      copied += 1;
    }
  });
  return copied;
}

function isSameOrDescendant(candidatePath, rootPath) {
  const displacement = relative(rootPath, candidatePath);
  return displacement === ""
    || (displacement !== ".."
      && !displacement.startsWith(`..${sep}`)
      && !isAbsolute(displacement));
}

async function canonicalPathIncludingMissingLeaf(path) {
  let existingAncestor = resolve(path);
  const missingComponents = [];
  while (true) {
    try {
      const canonicalAncestor = await realpath(existingAncestor);
      return resolve(canonicalAncestor, ...missingComponents.reverse());
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      const parent = dirname(existingAncestor);
      if (parent === existingAncestor) throw error;
      missingComponents.push(basename(existingAncestor));
      existingAncestor = parent;
    }
  }
}

/**
 * Reject any derived output that could write into a real corpus, including
 * paths whose existing ancestor is a symlink into the corpus.
 */
export async function assertOutputOutsideSourceCorpus(
  corpusRoot,
  outputPath,
  label = "Performance output"
) {
  const sourceRoot = await realpath(resolve(corpusRoot));
  const targetPath = await canonicalPathIncludingMissingLeaf(outputPath);
  if (isSameOrDescendant(targetPath, sourceRoot)) {
    throw new Error(`${label} must be outside the real corpus: ${sourceRoot}`);
  }
  return { sourceRoot, targetPath };
}

/**
 * Build the only configuration handed to a real-corpus performance clone.
 *
 * The source config can legitimately contain machine-local absolute paths,
 * executable/provider arguments, mounts, schedules, and publishing targets.
 * None are needed to reproduce corpus-scale rendering. Keep the number and
 * provider mix of source rows, but replace every identifier and path with a
 * deterministic clone-relative value and disable external execution.
 */
export function sanitizePerformanceCloneConfiguration(sourceConfiguration = {}) {
  const sourceProfiles = sourceConfiguration?.externalSources;
  const profileValues = sourceProfiles
    && typeof sourceProfiles === "object"
    && !Array.isArray(sourceProfiles)
    ? Object.values(sourceProfiles)
    : [];
  const externalSources = Object.fromEntries(profileValues.map((profile, index) => {
    const ordinal = String(index + 1).padStart(3, "0");
    const type = profile?.type === "slack" ? "slack" : "notion";
    const requestedMaxItems = Number(profile?.ingestion?.maxItems);
    const maxItems = Number.isSafeInteger(requestedMaxItems) && requestedMaxItems > 0
      ? Math.min(requestedMaxItems, 100_000)
      : 500;
    return [
      `performance-source-${ordinal}`,
      {
        type,
        enabled: false,
        scopes: [],
        media: "metadata-only",
        rawZone: `raw/performance/source-${ordinal}`,
        ingestion: {
          reviewZone: `views/performance/source-${ordinal}`,
          maxItems,
        },
      },
    ];
  }));

  return {
    agendaFiles: ["**/*.org", "**/*.org2"],
    recursive: true,
    roam: {
      indexDir: "notes",
      nodesDir: "notes",
      dailiesDir: "daily",
    },
    ...(profileValues.length > 0 ? { externalSources } : {}),
  };
}

/**
 * Assemble a private, disposable real-corpus snapshot for the Swift UI gate.
 *
 * The source is read only. Only canonical documents, a sanitized clone-local
 * configuration, run records, and chat persistence are copied; indexes,
 * caches, credentials, media, and arbitrary hidden state are deliberately
 * excluded. The caller must keep the target out of artifacts and remove it
 * after the test.
 */
export async function cloneReadOnlyPerformanceCorpus(corpusRoot, outputDirectory) {
  const { sourceRoot, targetPath: targetRoot } = await assertOutputOutsideSourceCorpus(
    corpusRoot,
    outputDirectory,
    "Real-corpus clone"
  );
  if (isSameOrDescendant(sourceRoot, targetRoot)) {
    throw new Error(`Real-corpus clone must not contain its source corpus: ${sourceRoot}`);
  }
  await mkdir(targetRoot, { recursive: true, mode: 0o700 });

  const documentPaths = await collectRegularFiles(sourceRoot, {
    skipIgnoredDirectories: true,
    filter: (relativePath) => allowedExtensions.has(extname(relativePath).toLowerCase()),
  });
  const documentCount = await copyRelativeFiles(sourceRoot, targetRoot, documentPaths);
  const sourceConfiguration = (await readCorpusConfiguration(sourceRoot)) ?? {};

  const runsRoot = join(sourceRoot, ".org2", "runs");
  const runPaths = await collectRegularFiles(runsRoot, {
    filter: (relativePath) => extname(relativePath).toLowerCase() === ".org2",
  });
  const runFileCount = await copyRelativeFiles(
    runsRoot,
    join(targetRoot, ".org2", "runs"),
    runPaths
  );

  const sourceTranscript = join(sourceRoot, ".org2", "openclaw-chat.json");
  const targetTranscript = join(targetRoot, ".org2", "openclaw-chat.json");
  const copiedChatTranscript = await copyFileIfPresent(sourceTranscript, targetTranscript);
  const sourceStore = join(sourceRoot, ".org2", "openclaw-chat.store");
  const targetStore = join(targetRoot, ".org2", "openclaw-chat.store");
  // Copy a consistent snapshot of a store the live app may be rewriting.
  let chatStoreFileCount = 0;
  for (let attempt = 1; ; attempt += 1) {
    await rm(targetStore, { recursive: true, force: true });
    // Historical manifests (gigabytes on a long-lived store) are recovery
    // material; the app loads only the commits that heads and markers name.
    const referencedManifests = await referencedStoreManifests(sourceStore);
    const storePaths = (await collectRegularFiles(sourceStore)).filter((relativePath) => {
      const parts = relativePath.split(sep);
      if (parts[0] === "manifests" && parts.length === 2) return referencedManifests.has(parts[1]);
      return !parts[0].startsWith("recovery-backup-");
    });
    chatStoreFileCount = await copyRelativeFiles(sourceStore, targetStore, storePaths);
    try {
      await inspectShardedChatStoreOnce(targetTranscript);
      break;
    } catch (error) {
      if (attempt >= 5 || !isTornChatStoreRead(error)) throw error;
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 100 * attempt));
    }
  }

  const cloneConfiguration = sanitizePerformanceCloneConfiguration(sourceConfiguration);
  await writeFile(
    join(targetRoot, "celorga.json"),
    `${JSON.stringify(cloneConfiguration, null, 2)}\n`,
    { mode: 0o600 }
  );
  return {
    root: targetRoot,
    documentCount,
    runFileCount,
    copiedChatTranscript,
    chatStoreFileCount,
  };
}

export async function profilePerformanceCorpus(corpusRoot, outputPath) {
  const root = resolve(corpusRoot);
  const documents = await inventoryDocuments(root);
  const sizes = documents.map((document) => document.byteCount);
  const countsByZone = new Map();
  const countsByExtension = new Map();
  for (const document of documents) {
    countsByZone.set(document.zone, (countsByZone.get(document.zone) ?? 0) + 1);
    countsByExtension.set(document.extension, (countsByExtension.get(document.extension) ?? 0) + 1);
  }
  const chat = await aggregateChatShape(root);
  const workspaceScale = await aggregateWorkspaceScale(root);
  const shape = {
    $schema: "org2:openorg-performance-corpus-shape:v1",
    version: 1,
    description: "Aggregate, privacy-safe OpenOrg corpus scale profile. It contains no corpus text, file names, IDs, or source paths.",
    privacy: {
      containsCorpusContent: false,
      containsFileNames: false,
      containsSourcePaths: false,
    },
    documents: {
      activeFileCount: documents.length,
      rootFileCount: countsByZone.get("root") ?? 0,
      extensionMix: Object.fromEntries([...countsByExtension].sort(([left], [right]) => left.localeCompare(right))),
      zones: ["notes", "daily", "agents", "meetings", "views", "other"].map((kind) => ({
        kind,
        fileCount: countsByZone.get(kind) ?? 0,
      })),
      sizeBytes: {
        p50: percentile(sizes, 0.50),
        p90: percentile(sizes, 0.90),
        p95: percentile(sizes, 0.95),
        p99: percentile(sizes, 0.99),
        max: sizes.length === 0 ? 0 : Math.max(...sizes),
      },
    },
    ...(chat ? { chat } : {}),
    workspaceScale,
    events: { burstFileCount: 100 },
  };
  await mkdir(dirname(resolve(outputPath)), { recursive: true });
  await writeFile(resolve(outputPath), `${JSON.stringify(shape, null, 2)}\n`, { mode: 0o600 });
  return shape;
}

// celorga.json wins over the legacy org2.json in the same directory.
async function readCorpusConfiguration(root) {
  for (const name of ["celorga.json", "org2.json"]) {
    try {
      return JSON.parse(await readFile(join(root, name), "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  return undefined;
}

async function aggregateWorkspaceScale(root) {
  const runPaths = await collectRegularFiles(join(root, ".org2", "runs"), {
    filter: (relativePath) => extname(relativePath).toLowerCase() === ".org2",
  });
  let declaredSourceProfileCount = 0;
  const config = await readCorpusConfiguration(root);
  if (config?.externalSources && typeof config.externalSources === "object") {
    declaredSourceProfileCount = Object.keys(config.externalSources).length;
  }
  return {
    agentRunCount: Math.max(4_205, runPaths.length),
    approvalItemCount: 500,
    externalThreadCount: 250,
    sourceProfileCount: Math.max(12, declaredSourceProfileCount),
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  if (!options.output || Boolean(options.generateShape) === Boolean(options.profileRoot)) {
    throw new Error(`${usage()}\n\nChoose exactly one of --generate or --profile, and provide --output.`);
  }
  if (options.generateShape) {
    const generated = await generatePerformanceCorpus(options.generateShape, options.output);
    console.log(`Generated ${generated.manifest.activeFileCount} synthetic documents at ${generated.root}`);
  } else {
    const shape = await profilePerformanceCorpus(options.profileRoot, options.output);
    console.log(`Wrote a content-free shape for ${shape.documents.activeFileCount} documents to ${resolve(options.output)}`);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
