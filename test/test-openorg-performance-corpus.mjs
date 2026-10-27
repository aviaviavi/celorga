#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  assertOutputOutsideSourceCorpus,
  cloneReadOnlyPerformanceCorpus,
  generatePerformanceCorpus,
  profilePerformanceCorpus,
} from "../tools/openorg-performance-corpus.mjs";
import {
  assertRealCorpusIsCovered,
  describePerformanceChildFailure,
  makePerformanceChildEnvironment,
  performanceChildTimeoutMilliseconds,
  runPerformanceChild,
  withPerformanceWorkspaceCleanup,
} from "../tools/test-macos-performance.mjs";

const sha256 = (data) => createHash("sha256").update(data).digest("hex");

const temporaryRoot = await mkdtemp(join(tmpdir(), "openorg-performance-corpus-test-"));
try {
  const shapePath = join(temporaryRoot, "shape.json");
  const corpusRoot = join(temporaryRoot, "corpus");
  const profilePath = join(temporaryRoot, "profile.json");
  const shape = {
    $schema: "org2:openorg-performance-corpus-shape:v1",
    version: 1,
    privacy: {
      containsCorpusContent: false,
      containsFileNames: false,
      containsSourcePaths: false,
    },
    documents: {
      activeFileCount: 7,
      rootFileCount: 3,
      extensionMix: { org: 2, org2: 5 },
      zones: [
        { kind: "notes", fileCount: 2 },
        { kind: "daily", fileCount: 1 },
        { kind: "other", fileCount: 1 },
      ],
      sizeBytes: { p50: 500, p90: 700, p95: 800, p99: 900, max: 2_000 },
      largeDocumentWorkload: {
        headlineIntervalBytes: 420,
        longLineBytes: 600,
        longLineEvery: 2,
        crlfEvery: 2,
      },
    },
    chat: {
      threadCount: 2,
      activeThreadCount: 1,
      archivedThreadCount: 1,
      messageCount: 3,
      maxMessagesPerThread: 2,
      attachmentBytes: 10,
      largestMessageBytes: 20,
    },
    workspaceScale: {
      agentRunCount: 4_205,
      approvalItemCount: 500,
      externalThreadCount: 250,
      sourceProfileCount: 12,
    },
    events: { burstFileCount: 2 },
  };
  await writeFile(shapePath, `${JSON.stringify(shape)}\n`);
  const generated = await generatePerformanceCorpus(shapePath, corpusRoot);
  assert.equal(generated.manifest.activeFileCount, 7);
  assert.equal(generated.manifest.sampleDocumentRelativePaths.length, 2);
  const generatedLargestPath = join(corpusRoot, generated.manifest.largestDocumentRelativePath);
  const generatedLargestBytes = await readFile(generatedLargestPath);
  const generatedLargestText = generatedLargestBytes.toString("utf8");
  assert.equal((await stat(generatedLargestPath)).size, shape.documents.sizeBytes.max);
  assert.equal(generatedLargestText.includes("�"), false, "the exact-byte fixture must remain valid UTF-8");
  assert.match(generatedLargestText, /東京/u);
  assert.match(generatedLargestText, /\r\n/u);
  assert.ok((generatedLargestText.match(/^\*{2,} /gmu) ?? []).length >= 2);
  assert.ok((generatedLargestText.match(/^:PROPERTIES:/gmu) ?? []).length >= 2);
  assert.ok(generatedLargestText.split(/\r?\n/u).some((line) => line.length >= 600));
  assert.match(generatedLargestText, /Malformed-looking fixture token/u);
  const generatedConfig = JSON.parse(await readFile(join(corpusRoot, "celorga.json"), "utf8"));
  assert.deepEqual(generatedConfig.agendaFiles, ["**/*.org", "**/*.org2"]);
  assert.equal(generatedConfig.recursive, true);
  assert.deepEqual(generatedConfig.roam, {
    indexDir: "notes",
    nodesDir: "notes",
    dailiesDir: "daily",
  });
  assert.equal(Object.keys(generatedConfig.externalSources).length, 12);

  const profile = await profilePerformanceCorpus(corpusRoot, profilePath);
  assert.equal(profile.documents.activeFileCount, 7);
  assert.equal(profile.documents.rootFileCount, 3);
  assert.deepEqual(profile.documents.extensionMix, { org: 2, org2: 5 });
  assert.equal(profile.documents.sizeBytes.max, 2_000);
  assert.equal(profile.workspaceScale.agentRunCount, 4_205);
  const serializedProfile = await readFile(profilePath, "utf8");
  assert.equal(serializedProfile.includes(corpusRoot), false);
  assert.equal(serializedProfile.includes("performance-00001"), false);
  assert.equal(profile.privacy.containsCorpusContent, false);
  assert.equal(profile.privacy.containsFileNames, false);
  assert.equal(profile.privacy.containsSourcePaths, false);

  const legacyChatSource = join(temporaryRoot, "legacy-chat-source");
  const legacyBody = "Tokyo body: 東京";
  const largerLegacyBody = "body-only-size";
  const inlineAttachment = Buffer.alloc(256 * 1_024, 0x42);
  await mkdir(join(legacyChatSource, ".org2"), { recursive: true });
  await writeFile(
    join(legacyChatSource, ".org2", "openclaw-chat.json"),
    `${JSON.stringify({
      threads: [{
        isArchived: false,
        messages: [{
          content: legacyBody,
          responseTrace: { reasoning: "R".repeat(128 * 1_024) },
          attachments: [{ data: inlineAttachment.toString("base64") }],
        }, {
          content: largerLegacyBody,
          responseTrace: { reasoning: "T".repeat(192 * 1_024) },
          attachments: [],
        }],
      }],
    })}\n`
  );
  const legacyChatProfile = await profilePerformanceCorpus(
    legacyChatSource,
    join(temporaryRoot, "legacy-chat-profile.json")
  );
  assert.equal(legacyChatProfile.chat.storageLayout, "legacy-monolith");
  assert.equal(legacyChatProfile.chat.attachmentBytes, inlineAttachment.length);
  assert.equal(
    legacyChatProfile.chat.largestMessageBytes,
    Math.max(Buffer.byteLength(legacyBody), Buffer.byteLength(largerLegacyBody)),
    "inline attachment and response-trace bytes must not become synthetic message body bytes"
  );

  const privateSource = join(temporaryRoot, "private-source");
  const privateClone = join(temporaryRoot, "private-clone");
  await mkdir(join(privateSource, "notes"), { recursive: true });
  await mkdir(join(privateSource, ".org2", "runs"), { recursive: true });
  await mkdir(join(privateSource, ".org2", "openclaw-chat.store", "threads"), { recursive: true });
  await mkdir(join(privateSource, ".org2", "openclaw-chat.store", "attachments"), { recursive: true });
  await mkdir(join(privateSource, ".org2", "index"), { recursive: true });
  await mkdir(join(privateSource, "media"), { recursive: true });
  await writeFile(
    join(privateSource, "org2.json"),
    `${JSON.stringify({
      agendaFiles: [join(privateSource, "**", "*.org2"), "../../outside/*.org2"],
      recursive: false,
      roam: {
        indexDir: join(privateSource, "private-index"),
        nodesDir: "../../private-nodes",
        dailiesDir: "/tmp/private-dailies",
      },
      externalSources: {
        "private-profile-name": {
          type: "slack",
          enabled: true,
          scopes: [privateSource],
          workspaceId: "private-workspace-id",
          rawZone: join(privateSource, "raw"),
          syncArgs: ["--output", join(privateSource, "raw")],
          ingestion: {
            reviewZone: "../../private-review",
            maxItems: 42,
          },
          schedule: { enabled: true, kind: "interval", everyMinutes: 1 },
        },
      },
      plugins: [{ source: privateSource }],
      dataSources: { private: { type: "clickhouse", url: "https://private.invalid" } },
      publish: { projects: { private: { outputDir: privateSource } } },
    })}\n`
  );
  await writeFile(join(privateSource, "notes", "private-name.org2"), "* TODO private body\n");
  await writeFile(join(privateSource, ".org2", "runs", "private-run.org2"), "* Run\n");
  await writeFile(join(privateSource, ".org2", "openclaw-chat.json"), "{\"threads\":[]}\n");
  await writeFile(
    join(privateSource, ".org2", "openclaw-chat.store", "manifest.json"),
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-manifest:v1",
      threads: [
        { id: "00000000-0000-4000-8000-000000000001", storedMessageCount: 2, isArchived: false },
        { id: "00000000-0000-4000-8000-000000000002", storedMessageCount: 1, isArchived: true },
      ],
    })}\n`
  );
  await writeFile(
    join(privateSource, ".org2", "openclaw-chat.store", "threads", "00000000-0000-4000-8000-000000000001.json"),
    `${JSON.stringify({
      schema: "org2:ai-chat-thread:v1",
      messages: [
        {
          message: {
            content: "sharded wins",
            responseTrace: { reasoning: "R".repeat(128 * 1_024) },
          },
          attachments: [{ byteCount: 12 }],
        },
        { message: { content: "second" }, attachments: [] },
      ],
    })}\n`
  );
  await writeFile(
    join(privateSource, ".org2", "openclaw-chat.store", "threads", "00000000-0000-4000-8000-000000000002.json"),
    `${JSON.stringify({
      schema: "org2:ai-chat-thread:v1",
      messages: [{ message: { content: "archived" }, attachments: [{ byteCount: 8 }] }],
    })}\n`
  );
  await writeFile(join(privateSource, ".org2", "openclaw-chat.store", "attachments", "blob.bin"), "private");
  await writeFile(join(privateSource, ".org2", "index", "must-not-copy.json"), "private index\n");
  await writeFile(join(privateSource, "media", "must-not-copy.wav"), "private media\n");

  const shardedProfile = await profilePerformanceCorpus(
    privateSource,
    join(temporaryRoot, "sharded-profile.json")
  );
  assert.equal(shardedProfile.chat.storageLayout, "sharded-v1");
  assert.equal(shardedProfile.chat.threadCount, 2);
  assert.equal(shardedProfile.chat.messageCount, 3);
  assert.equal(shardedProfile.chat.attachmentBytes, 20);
  assert.equal(
    shardedProfile.chat.largestMessageBytes,
    Buffer.byteLength("sharded wins"),
    "sharded response-trace bytes must not become synthetic message body bytes"
  );

  await mkdir(join(privateSource, ".org2", "openclaw-chat.store", "manifests"), { recursive: true });
  const version2ShardData = Buffer.from(`${JSON.stringify({
      schema: "org2:ai-chat-thread:v1",
      messages: [
        { message: { content: "v2 current one" }, attachments: [{ byteCount: 33 }] },
        { message: { content: "v2 current two" }, attachments: [] },
        { message: { content: "v2 current three" }, attachments: [] },
        { message: { content: "v2 current four" }, attachments: [] },
      ],
    })}\n`);
  const version2ShardPath = join(
    privateSource,
    ".org2",
    "openclaw-chat.store",
    "threads",
    "00000000-0000-4000-8000-000000000003-digest.json"
  );
  await writeFile(version2ShardPath, version2ShardData);
  const version2ManifestData = Buffer.from(`${JSON.stringify({
      schema: "org2:ai-chat-transcript-manifest:v2",
      version: 2,
      threads: [{
        metadata: {
          id: "00000000-0000-4000-8000-000000000003",
          storedMessageCount: 4,
          isArchived: false,
        },
        shard: "threads/00000000-0000-4000-8000-000000000003-digest.json",
        shardDigest: sha256(version2ShardData),
      }],
    })}\n`);
  const version2ManifestPath = join(
    privateSource,
    ".org2",
    "openclaw-chat.store",
    "manifests",
    "commit-v2.json"
  );
  await writeFile(version2ManifestPath, version2ManifestData);
  const markerPath = join(
    privateSource,
    ".org2",
    "openclaw-chat.store",
    "migration-marker.json"
  );
  await writeFile(
    markerPath,
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-store-marker:v1",
      version: 1,
      currentManifest: "commit-v2.json",
      currentDigest: sha256(version2ManifestData),
    })}\n`
  );
  const version2Profile = await profilePerformanceCorpus(
    privateSource,
    join(temporaryRoot, "sharded-v2-profile.json")
  );
  assert.equal(version2Profile.chat.storageLayout, "sharded-v2");
  assert.equal(version2Profile.chat.threadCount, 1);
  assert.equal(version2Profile.chat.messageCount, 4);
  assert.equal(version2Profile.chat.attachmentBytes, 33);

  await writeFile(
    markerPath,
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-store-marker:v1",
      version: 1,
      currentManifest: "commit-v2.json",
      currentDigest: "0".repeat(64),
    })}\n`
  );
  await assert.rejects(
    profilePerformanceCorpus(privateSource, join(temporaryRoot, "corrupt-marker-profile.json")),
    /manifest digest mismatch/u
  );
  await writeFile(
    markerPath,
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-store-marker:v1",
      version: 1,
      currentManifest: "commit-v2.json",
      currentDigest: sha256(version2ManifestData),
    })}\n`
  );

  const corruptManifest = JSON.parse(version2ManifestData.toString("utf8"));
  corruptManifest.threads[0].shardDigest = "f".repeat(64);
  const corruptManifestData = Buffer.from(`${JSON.stringify(corruptManifest)}\n`);
  await writeFile(version2ManifestPath, corruptManifestData);
  await writeFile(
    markerPath,
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-store-marker:v1",
      version: 1,
      currentManifest: "commit-v2.json",
      currentDigest: sha256(corruptManifestData),
    })}\n`
  );
  await assert.rejects(
    profilePerformanceCorpus(privateSource, join(temporaryRoot, "corrupt-shard-profile.json")),
    /thread digest mismatch/u
  );
  await writeFile(version2ManifestPath, version2ManifestData);
  await writeFile(
    markerPath,
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-store-marker:v1",
      version: 1,
      currentManifest: "commit-v2.json",
      currentDigest: sha256(version2ManifestData),
    })}\n`
  );

  // A store with per-writer heads ignores a stale historical marker, and the
  // clone skips manifests no head or marker names.
  await writeFile(
    markerPath,
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-store-marker:v1",
      version: 1,
      currentManifest: "garbage-collected.json",
      currentDigest: "a".repeat(64),
    })}\n`
  );
  await mkdir(join(privateSource, ".org2", "openclaw-chat.store", "heads"), { recursive: true });
  await writeFile(
    join(privateSource, ".org2", "openclaw-chat.store", "heads", "writer-1.json"),
    `${JSON.stringify({
      schema: "org2:ai-chat-transcript-head:v1",
      version: 1,
      currentGeneration: 7,
      currentManifest: "commit-v2.json",
      currentDigest: sha256(version2ManifestData),
    })}\n`
  );
  await writeFile(
    join(privateSource, ".org2", "openclaw-chat.store", "manifests", "historical.json"),
    "{}\n"
  );
  const headProfile = await profilePerformanceCorpus(
    privateSource,
    join(temporaryRoot, "sharded-head-profile.json")
  );
  assert.equal(headProfile.chat.messageCount, 4, "the newest writer head names the current commit");

  const sourceDocumentPath = join(privateSource, "notes", "private-name.org2");
  const sourceTranscriptPath = join(privateSource, ".org2", "openclaw-chat.json");
  const sourceDocumentDigest = sha256(await readFile(sourceDocumentPath));
  const sourceTranscriptDigest = sha256(await readFile(sourceTranscriptPath));
  const clone = await cloneReadOnlyPerformanceCorpus(privateSource, privateClone);
  assert.equal(clone.documentCount, 1);
  assert.equal(clone.runFileCount, 1);
  assert.equal(clone.copiedChatTranscript, true);
  assert.equal(clone.chatStoreFileCount, 8);
  await assert.rejects(access(join(privateClone, ".org2", "openclaw-chat.store", "manifests", "historical.json")));
  await access(join(privateClone, ".org2", "openclaw-chat.store", "manifests", "commit-v2.json"));
  await access(join(privateClone, "notes", "private-name.org2"));
  await access(join(privateClone, ".org2", "runs", "private-run.org2"));
  await access(join(privateClone, ".org2", "openclaw-chat.store", "manifest.json"));
  await assert.rejects(access(join(privateClone, ".org2", "index", "must-not-copy.json")));
  await assert.rejects(access(join(privateClone, "media", "must-not-copy.wav")));
  const cloneConfigurationText = await readFile(join(privateClone, "celorga.json"), "utf8");
  const cloneConfiguration = JSON.parse(cloneConfigurationText);
  assert.deepEqual(cloneConfiguration.agendaFiles, ["**/*.org", "**/*.org2"]);
  assert.equal(cloneConfiguration.recursive, true);
  assert.deepEqual(cloneConfiguration.roam, {
    indexDir: "notes",
    nodesDir: "notes",
    dailiesDir: "daily",
  });
  assert.deepEqual(Object.keys(cloneConfiguration.externalSources), ["performance-source-001"]);
  assert.deepEqual(cloneConfiguration.externalSources["performance-source-001"], {
    type: "slack",
    enabled: false,
    scopes: [],
    media: "metadata-only",
    rawZone: "raw/performance/source-001",
    ingestion: {
      reviewZone: "views/performance/source-001",
      maxItems: 42,
    },
  });
  assert.equal(cloneConfigurationText.includes(privateSource), false);
  assert.equal(cloneConfigurationText.includes("private-profile-name"), false);
  assert.equal("plugins" in cloneConfiguration, false);
  assert.equal("dataSources" in cloneConfiguration, false);
  assert.equal("publish" in cloneConfiguration, false);
  assert.equal(sha256(await readFile(sourceDocumentPath)), sourceDocumentDigest);
  assert.equal(sha256(await readFile(sourceTranscriptPath)), sourceTranscriptDigest);

  const forbiddenClone = join(privateSource, "private-output");
  await assert.rejects(
    cloneReadOnlyPerformanceCorpus(privateSource, forbiddenClone),
    /clone must be outside the real corpus/u
  );
  await assert.rejects(access(forbiddenClone));
  await assert.rejects(
    cloneReadOnlyPerformanceCorpus(privateSource, temporaryRoot),
    /clone must not contain its source corpus/u
  );
  await assert.rejects(
    assertOutputOutsideSourceCorpus(
      privateSource,
      join(privateSource, "artifacts"),
      "Performance artifact directory"
    ),
    /artifact directory must be outside the real corpus/u
  );
  await assert.doesNotReject(
    assertOutputOutsideSourceCorpus(privateSource, privateClone, "Real-corpus clone")
  );
  const sourceSymlink = join(temporaryRoot, "private-source-link");
  await symlink(privateSource, sourceSymlink, "dir");
  await assert.rejects(
    assertOutputOutsideSourceCorpus(
      privateSource,
      join(sourceSymlink, "artifacts"),
      "Performance artifact directory"
    ),
    /artifact directory must be outside the real corpus/u
  );

  const childEnvironment = makePerformanceChildEnvironment(
    {
      PATH: "/usr/bin",
      OPENORG_REAL_CORPUS: privateSource,
      OPENORG_PERFORMANCE_REAL_CORPUS: privateSource,
      OPENORG_PERFORMANCE_REAL_CORPUS_ROOT: privateSource,
      OPENORG_PERFORMANCE_REAL_ATTACHMENT_THREAD_IDS: "private-thread-id",
      OPENORG_PERFORMANCE_REAL_CORPUS_CLONE: privateSource,
    },
    { OPENORG_PERFORMANCE_REAL_CORPUS_CLONE: privateClone }
  );
  assert.equal(childEnvironment.PATH, "/usr/bin");
  assert.equal(childEnvironment.OPENORG_PERFORMANCE_REAL_CORPUS_CLONE, privateClone);
  assert.equal("OPENORG_REAL_CORPUS" in childEnvironment, false);
  assert.equal("OPENORG_PERFORMANCE_REAL_CORPUS" in childEnvironment, false);
  assert.equal("OPENORG_PERFORMANCE_REAL_CORPUS_ROOT" in childEnvironment, false);
  assert.equal("OPENORG_PERFORMANCE_REAL_ATTACHMENT_THREAD_IDS" in childEnvironment, false);
  assert.equal(
    "OPENORG_PERFORMANCE_REAL_CORPUS_CLONE" in makePerformanceChildEnvironment({
      OPENORG_PERFORMANCE_REAL_CORPUS_CLONE: privateSource,
    }),
    false
  );

  assert.doesNotThrow(() => assertRealCorpusIsCovered(shape, shape));
  const largerShape = structuredClone(shape);
  largerShape.documents.sizeBytes.p95 = shape.documents.sizeBytes.p95 + 1;
  assert.throws(
    () => assertRealCorpusIsCovered(largerShape, shape),
    /document p95 bytes grew/u
  );

  // The checked-in fixture deliberately unions the current root-heavy layout
  // with the planned notes/daily layout. A migration must not make the
  // synthetic workload cheaper by merely moving the same documents between
  // zones: the union must cover either complete layout, while either layout by
  // itself must fail to cover the other.
  const unionShape = JSON.parse(await readFile(
    new URL("./fixtures/openorg-performance-corpus-shape-v1.json", import.meta.url),
    "utf8"
  ));
  assert.equal(unionShape.version, 5);
  assert.equal(unionShape.documents.activeFileCount, 7_534);
  assert.equal(unionShape.documents.rootFileCount, 1_934);
  assert.deepEqual(unionShape.documents.extensionMix, {
    csv: 360,
    md: 140,
    org: 4_634,
    org2: 2_400,
  });
  const unionZones = Object.fromEntries(
    unionShape.documents.zones.map((zone) => [zone.kind, zone.fileCount])
  );
  assert.deepEqual(unionZones, {
    notes: 1_500,
    daily: 1_600,
    agents: 100,
    meetings: 560,
    views: 1_500,
    other: 340,
  });
  assert.equal(
    unionShape.documents.rootFileCount
      + Object.values(unionZones).reduce((total, count) => total + count, 0),
    unionShape.documents.activeFileCount
  );
  assert.equal(
    Object.values(unionShape.documents.extensionMix)
      .reduce((total, count) => total + count, 0),
    unionShape.documents.activeFileCount
  );

  const rootHeavyShape = structuredClone(unionShape);
  rootHeavyShape.documents.activeFileCount = 3_530;
  rootHeavyShape.documents.extensionMix = { csv: 35, md: 127, org: 1_630, org2: 1_738 };
  const rootHeavyZones = {
    notes: 704,
    daily: 1,
    agents: 34,
    meetings: 274,
    views: 415,
    other: 168,
  };
  rootHeavyShape.documents.zones = rootHeavyShape.documents.zones.map((zone) => ({
    ...zone,
    fileCount: rootHeavyZones[zone.kind],
  }));

  const zonedShape = structuredClone(rootHeavyShape);
  zonedShape.documents.activeFileCount = 3_552;
  zonedShape.documents.rootFileCount = 11;
  zonedShape.documents.extensionMix = { csv: 35, md: 127, org: 1_635, org2: 1_755 };
  const zonedZones = {
    notes: 1_206,
    daily: 1_439,
    agents: 34,
    meetings: 276,
    views: 418,
    other: 168,
  };
  zonedShape.documents.zones = zonedShape.documents.zones.map((zone) => ({
    ...zone,
    fileCount: zonedZones[zone.kind],
  }));

  assert.doesNotThrow(() => assertRealCorpusIsCovered(rootHeavyShape, unionShape));
  assert.doesNotThrow(() => assertRealCorpusIsCovered(zonedShape, unionShape));
  assert.throws(
    () => assertRealCorpusIsCovered(zonedShape, rootHeavyShape),
    /notes zone documents grew|daily zone documents grew/u
  );
  assert.throws(
    () => assertRealCorpusIsCovered(rootHeavyShape, zonedShape),
    /root documents grew/u
  );

  assert.equal(performanceChildTimeoutMilliseconds, 25 * 60 * 1_000);
  const timeoutWorkspace = join(temporaryRoot, "timeout-workspace");
  await mkdir(join(timeoutWorkspace, "real-corpus-clone"), { recursive: true });
  await assert.rejects(
    withPerformanceWorkspaceCleanup({
      temporaryRoot: timeoutWorkspace,
      corpusRoot: join(timeoutWorkspace, "corpus"),
      realCorpusCloneRoot: join(timeoutWorkspace, "real-corpus-clone"),
      indexRoot: join(timeoutWorkspace, "index"),
      log: () => {},
    }, async () => {
      await writeFile(join(timeoutWorkspace, "real-corpus-clone", "private.txt"), "private\n");
      const result = runPerformanceChild(
        process.execPath,
        ["-e", "setTimeout(() => {}, 10_000)"],
        {
          cwd: timeoutWorkspace,
          stdio: "pipe",
          timeoutMilliseconds: 50,
        }
      );
      assert.equal(result.error?.code, "ETIMEDOUT");
      assert.match(describePerformanceChildFailure(result, 50), /timed out/u);
      throw new Error("simulated timed performance-child failure");
    }),
    /simulated timed performance-child failure/u
  );
  await assert.rejects(access(timeoutWorkspace));

  const failureWorkspace = join(temporaryRoot, "failure-workspace");
  await mkdir(join(failureWorkspace, "real-corpus-clone"), { recursive: true });
  await assert.rejects(
    withPerformanceWorkspaceCleanup({
      temporaryRoot: failureWorkspace,
      corpusRoot: join(failureWorkspace, "corpus"),
      realCorpusCloneRoot: join(failureWorkspace, "real-corpus-clone"),
      indexRoot: join(failureWorkspace, "index"),
      log: () => {},
    }, async () => {
      await writeFile(join(failureWorkspace, "real-corpus-clone", "private.txt"), "private\n");
      const result = runPerformanceChild(
        process.execPath,
        ["-e", "process.exit(7)"],
        { cwd: failureWorkspace, stdio: "pipe", timeoutMilliseconds: 1_000 }
      );
      assert.equal(result.status, 7);
      assert.match(describePerformanceChildFailure(result, 1_000), /status 7/u);
      throw new Error("simulated nonzero performance-child failure");
    }),
    /simulated nonzero performance-child failure/u
  );
  await assert.rejects(access(failureWorkspace));
} finally {
  await rm(temporaryRoot, { recursive: true, force: true });
}

console.log("openorg performance corpus fixture tests passed");
