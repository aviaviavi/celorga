import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  GOOGLE_DRIVE_FILE_SCOPE,
  GOOGLE_SHEETS_MIME_TYPE,
  GOOGLE_SLIDES_MIME_TYPE,
  prepareGoogleDocsUpload,
  prepareGoogleDrivePdfUpload,
  prepareGoogleSheetsUpload,
  prepareGoogleSlidesUpload,
  preparePublishedDocument,
  publishToGoogleDocs,
  publishToGoogleWorkspace,
} from "../dist/publishDocument.js";
import { preparePublishedBeamer } from "../dist/publishedDocumentBeamer.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = path.join(repoRoot, "dist", "cli.js");
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "org2-publish-document-"));
const sourcePath = path.join(fixtureRoot, "research.org2");
const webOut = path.join(fixtureRoot, "published");
const privateId = "92ba16ea-a2cb-4c2a-895f-6096a23dfaed";
const secretValue = "NEVER-PUBLISH-THIS";
const source = `#+TITLE: Quantum Sensing Brief
#+DESCRIPTION: A disclosure-safe market brief.
#+HTML_HEAD: <script>window.privateValue = "${secretValue}"</script>
#+LINK: unsafe javascript:%s

Document preface.

# internal author note
* TODO Research findings :private:internal:
SCHEDULED: <2026-09-01 Tue>
:PROPERTIES:
:ID: ${privateId}
:SECRET: ${secretValue}
:END:
The cited market is growing. [[id:${privateId}][Internal source]] [[https://example.com/report][External source]] [[unsafe:alert(1)][Unsafe alias]].
Formatting: *bold*, /italic/, _underlined_, +struck+, =setting=value=, and ~code()~.
Inline export must disappear: @@html:<script>${secretValue}</script>@@

[[file:chart.png]]
[[file:chart.png]]

| Claim | Source |
|-------+--------|
| Public evidence | [[id:${privateId}][Private evidence row]] |
| Unsafe cell | @@html:<script>${secretValue}</script>@@ |
#+TBLFM: $1='(identity remote-code)

#+begin_export html
<script>${secretValue}</script>
#+end_export

** COMMENT Hidden working notes
${secretValue}
`;

function runCli(extraArgs, options = {}) {
  return runCliFor(sourcePath, extraArgs, options);
}

function runCliFor(file, extraArgs, options = {}) {
  return spawnSync(process.execPath, [cliPath, "publish", "document", "--file", file, ...extraArgs], {
    cwd: fixtureRoot,
    encoding: "utf8",
    env: { ...process.env, ORG2_GOOGLE_DRIVE_ACCESS_TOKEN: "", ...(options.env || {}) },
  });
}

function storedZipEntries(bytes) {
  const entries = new Map();
  let offset = 0;
  while (offset + 30 <= bytes.length && bytes.readUInt32LE(offset) === 0x04034b50) {
    const compression = bytes.readUInt16LE(offset + 8);
    assert.equal(compression, 0, "test reader expects deterministic stored DOCX entries");
    const size = bytes.readUInt32LE(offset + 18);
    const nameLength = bytes.readUInt16LE(offset + 26);
    const extraLength = bytes.readUInt16LE(offset + 28);
    const nameStart = offset + 30;
    const dataStart = nameStart + nameLength + extraLength;
    const name = bytes.subarray(nameStart, nameStart + nameLength).toString("utf8");
    entries.set(name, bytes.subarray(dataStart, dataStart + size));
    offset = dataStart + size;
  }
  return entries;
}

try {
  fs.writeFileSync(sourcePath, source);
  fs.writeFileSync(
    path.join(fixtureRoot, "chart.png"),
    Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64"),
  );

  const preview = runCli(["--to", "web", "--out-dir", webOut, "--format", "json"]);
  assert.equal(preview.status, 0, preview.stderr || preview.stdout);
  const previewPayload = JSON.parse(preview.stdout);
  assert.equal(previewPayload.applied, false);
  assert.equal(previewPayload.destination.destination, "web");
  assert.equal(previewPayload.destination.requiresHosting, true);
  assert.equal(previewPayload.artifact.assets.length, 1);
  assert.equal(previewPayload.artifact.assets[0].name, "chart.png");
  assert.ok(Object.values(previewPayload.disclosure.redactions).reduce((sum, count) => sum + count, 0) >= 8);
  assert.equal(fs.existsSync(webOut), false, "preview must not write a web bundle");

  const publish = runCli(["--to", "web", "--out-dir", webOut, "--apply", "--format", "json"]);
  assert.equal(publish.status, 0, publish.stderr || publish.stdout);
  const publishPayload = JSON.parse(publish.stdout);
  assert.equal(publishPayload.applied, true);
  const html = fs.readFileSync(path.join(webOut, "index.html"), "utf8");
  const manifestText = fs.readFileSync(path.join(webOut, "manifest.json"), "utf8");
  const manifest = JSON.parse(manifestText);

  assert.match(html, /<meta name="referrer" content="no-referrer" \/>/);
  assert.match(html, /<meta name="robots" content="noindex, nofollow, noarchive" \/>/);
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /id="org2-publish-document-style"/);
  assert.match(html, /--org2-content-width: 960px/);
  assert.match(html, /html, body \{[^}]*overflow-x: hidden/);
  assert.match(html, /padding: 22px clamp\(16px, 5vw, var\(--org2-page-padding\)\) 64px/);
  assert.match(html, /details\.org2-headline,/);
  assert.match(html, /<div class="org2-table-scroll">/);
  assert.match(html, /\.org2-table-scroll \{[^}]*min-width: 0;[^}]*overflow-x: auto;/);
  assert.doesNotMatch(html, /margin: 2rem auto; max-width: 860px/);
  assert.match(html, /data:image\/png;base64,/);
  assert.match(html, /<a rel="noopener noreferrer" href="https:\/\/example\.com\/report">External source<\/a>/);
  assert.match(html, /Internal source/);
  assert.match(html, /Private evidence row/);
  assert.doesNotMatch(html, /<span class="org2-todo|<span class="org2-tags|private:internal/);
  assert.doesNotMatch(html, new RegExp(privateId));
  assert.doesNotMatch(html, new RegExp(secretValue));
  assert.doesNotMatch(html, /javascript:|file:|TBLFM|remote-code|<script>/i);
  assert.doesNotMatch(html, new RegExp(fixtureRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.doesNotMatch(manifestText, new RegExp(fixtureRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  assert.equal(manifest.$schema, "org2:published-document:v1");
  assert.equal(manifest.artifactHash, publishPayload.artifact.artifactHash);
  assert.equal(publishPayload.artifact.assets[0].mediaType, "image/png");
  assert.equal("sourceHash" in manifest, false, "public manifests must not expose the private source revision");
  assert.equal("redactions" in manifest, false, "public manifests must not expose private disclosure details");
  assert.equal("assets" in manifest, false, "public manifests must not expose local asset names");

  const subtreeLine = source.slice(0, source.indexOf("* TODO Research findings")).split("\n").length;
  const subtree = preparePublishedDocument({ sourceText: source, sourcePath, line: subtreeLine });
  assert.equal(subtree.manifest.selection, "subtree");
  assert.match(subtree.html, /<h1>Research findings<\/h1>/);
  assert.doesNotMatch(subtree.html, /Document preface|<header class="org2-document-header"/);

  const chartSource = `#+TITLE: Published Dashboard
* Dashboard
#+name: growth_chart
\`\`\`chart line
title: Monthly growth
source: growth_series
x: month
y: value
interactive: true
\`\`\`

#+name: growth_series
| month | value |
|-------+-------|
| Jan   | 10    |
| Feb   | 14    |
`;
  const chartPublication = preparePublishedDocument({ sourceText: chartSource });
  assert.match(chartPublication.html, /<figure class="org2-chart org2-chart-medium celorga-chart"/);
  assert.match(chartPublication.html, /<svg\b[^>]*class="org2-chart-svg"/);
  assert.match(chartPublication.html, /Monthly growth/);
  assert.match(chartPublication.html, /--org2-chart-title: #24262a/);
  assert.match(chartPublication.html, /--org2-chart-title: #e9eaed/);
  assert.doesNotMatch(chartPublication.html, /language-chart|source: growth_series/);
  assert.doesNotMatch(JSON.stringify(chartPublication.document), /sourceRange/);

  const sanitizedChartSource = `* Shared dashboard
#+name: safe_series
| label | rolling_7d |
|-------+------------|
| [[file:/private/customer-list.csv][Public total]] | 12 |

\`\`\`chart bar
source: safe_series
x: label
y: rolling_7d
\`\`\`
`;
  const sanitizedChartPublication = preparePublishedDocument({ sourceText: sanitizedChartSource });
  assert.match(sanitizedChartPublication.html, /<svg\b[^>]*class="org2-chart-svg"/);
  assert.match(sanitizedChartPublication.html, /Public total/);
  assert.doesNotMatch(sanitizedChartPublication.html, /private\/customer-list/);

  const commentedChartSource = `* COMMENT Private data
#+name: commented_series
| month | value |
|-------+-------|
| Jan   | 98765 |

* Shared chart
\`\`\`chart line
source: commented_series
x: month
y: value
\`\`\`
`;
  const commentedChartPublication = preparePublishedDocument({ sourceText: commentedChartSource });
  // Shared styles name the SVG class even when no chart is rendered. Check
  // rendered elements and private data, not the presence of a CSS selector.
  assert.doesNotMatch(commentedChartPublication.html, /<svg\b[^>]*class="org2-chart-svg"|98765/);
  assert.match(commentedChartPublication.warnings.join("\n"), /No table found for chart source "commented_series"/);

  const scopedChartSource = `#+name: private_series
| month | value |
|-------+-------|
| Jan   | 98765 |

* Shared chart
\`\`\`chart line
source: private_series
x: month
y: value
\`\`\`
`;
  const scopedChartLine = scopedChartSource.slice(0, scopedChartSource.indexOf("* Shared chart")).split("\n").length;
  const scopedChartPublication = preparePublishedDocument({ sourceText: scopedChartSource, line: scopedChartLine });
  assert.doesNotMatch(scopedChartPublication.html, /<svg\b[^>]*class="org2-chart-svg"|98765/);
  assert.match(scopedChartPublication.warnings.join("\n"), /No table found for chart source "private_series"/);

  const repeat = runCli(["--to", "web", "--out-dir", webOut, "--replace-existing", "--apply", "--format", "json"]);
  assert.equal(repeat.status, 0, repeat.stderr || repeat.stdout);
  assert.equal(JSON.parse(repeat.stdout).artifact.artifactHash, manifest.artifactHash, "same source should produce the same artifact");
  assert.equal(fs.readFileSync(path.join(webOut, "manifest.json"), "utf8"), manifestText);

  const guardedWeb = runCli(["--to", "web", "--out-dir", webOut, "--apply"]);
  assert.notEqual(guardedWeb.status, 0);
  assert.match(guardedWeb.stderr, /--replace-existing/);

  const googlePreview = runCli(["--to", "google-docs", "--folder-id", "folder-123", "--format", "json"]);
  assert.equal(googlePreview.status, 0, googlePreview.stderr || googlePreview.stdout);
  const googlePreviewPayload = JSON.parse(googlePreview.stdout);
  assert.equal(googlePreviewPayload.applied, false);
  assert.equal(googlePreviewPayload.destination.action, "create");
  assert.equal(googlePreviewPayload.destination.requiredOAuthScope, GOOGLE_DRIVE_FILE_SCOPE);
  assert.equal(googlePreviewPayload.destination.folderId, "folder-123");
  assert.equal(googlePreviewPayload.destination.inputMediaType, "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
  assert.ok(googlePreviewPayload.destination.uploadBytes > 0);
  assert.doesNotMatch(googlePreview.stdout, /Bearer|access.?token/i);

  const googleUpdatePreview = runCli([
    "--to", "google-docs",
    "--document-id", "doc-created",
    "--replace-existing",
    "--format", "json",
  ]);
  assert.equal(googleUpdatePreview.status, 0, googleUpdatePreview.stderr || googleUpdatePreview.stdout);
  const googleUpdatePreviewPayload = JSON.parse(googleUpdatePreview.stdout);
  assert.equal(googleUpdatePreviewPayload.destination.action, "update");
  assert.equal(googleUpdatePreviewPayload.destination.documentId, "doc-created");
  assert.equal(googleUpdatePreviewPayload.destination.expectedVersion, undefined);
  assert.match(googleUpdatePreviewPayload.destination.updateGuards, /ETag/);

  const missingCredential = runCli(["--to", "google-docs", "--apply"]);
  assert.notEqual(missingCredential.status, 0);
  assert.match(missingCredential.stderr, /ORG2_GOOGLE_DRIVE_ACCESS_TOKEN/);

  const prepared = preparePublishedDocument({ sourceText: source, sourcePath });
  const docx = prepareGoogleDocsUpload(prepared);
  assert.deepEqual(docx.bytes.subarray(0, 2), Buffer.from("PK"));
  assert.deepEqual(prepareGoogleDocsUpload(prepared).bytes, docx.bytes, "Google Docs media should be deterministic");
  const docxEntries = storedZipEntries(docx.bytes);
  assert.ok(docxEntries.has("[Content_Types].xml"));
  assert.ok(docxEntries.has("word/document.xml"));
  assert.ok(docxEntries.has("word/_rels/document.xml.rels"));
  assert.ok(docxEntries.has("word/media/image1.png"));
  const documentXml = docxEntries.get("word/document.xml").toString("utf8");
  assert.match(documentXml, /Quantum Sensing Brief/);
  assert.match(documentXml, /Private evidence row/);
  assert.match(documentXml, /<w:tbl>/);
  assert.match(documentXml, /r:embed="rId/);
  assert.match(documentXml, /<w:rPr><w:b\/><\/w:rPr><w:t[^>]*>bold<\/w:t>/);
  assert.match(documentXml, /<w:rPr><w:i\/><\/w:rPr><w:t[^>]*>italic<\/w:t>/);
  assert.match(documentXml, /<w:rPr><w:u w:val="single"\/><\/w:rPr><w:t[^>]*>underlined<\/w:t>/);
  assert.match(documentXml, /<w:rPr><w:strike\/><\/w:rPr><w:t[^>]*>struck<\/w:t>/);
  assert.match(documentXml, /<w:rPr><w:rStyle w:val="CodeChar"\/><\/w:rPr><w:t[^>]*>setting=value<\/w:t>/);
  assert.match(documentXml, /<w:rPr><w:rStyle w:val="CodeChar"\/><\/w:rPr><w:t[^>]*>code\(\)<\/w:t>/);
  assert.deepEqual([...documentXml.matchAll(/<wp:docPr id="(\d+)"/g)].map((match) => match[1]), ["1", "2"]);
  assert.doesNotMatch(documentXml, new RegExp(privateId));
  assert.doesNotMatch(documentXml, new RegExp(secretValue));
  assert.doesNotMatch(documentXml, /javascript:|TBLFM|remote-code/i);
  const createCalls = [];
  const created = await publishToGoogleDocs(prepared, {
    accessToken: "ephemeral-test-token",
    folderId: "folder-123",
    fetchImpl: async (url, init) => {
      createCalls.push({ url: String(url), init });
      return new Response(JSON.stringify({
        id: "doc-created",
        name: "Quantum Sensing Brief",
        mimeType: "application/vnd.google-apps.document",
        version: "7",
        webViewLink: "https://docs.google.com/document/d/doc-created/edit",
      }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });
  assert.equal(createCalls.length, 1);
  assert.equal(createCalls[0].init.method, "POST");
  assert.match(createCalls[0].url, /\/upload\/drive\/v3\/files\?/);
  assert.match(String(createCalls[0].init.headers["content-type"]), /multipart\/related/);
  const createBody = Buffer.from(createCalls[0].init.body);
  assert.match(createBody.toString("latin1"), /application\/vnd\.google-apps\.document/);
  assert.match(createBody.toString("latin1"), /application\/vnd\.openxmlformats-officedocument\.wordprocessingml\.document/);
  assert.match(createBody.toString("latin1"), /"parents":\["folder-123"\]/);
  assert.ok(createBody.indexOf(Buffer.from("PK")) > 0, "multipart upload should contain a DOCX package");
  assert.equal(created.fileId, "doc-created");
  assert.equal(created.version, "7");
  assert.doesNotMatch(JSON.stringify(created), /ephemeral-test-token/);

  await assert.rejects(
    () => publishToGoogleDocs(prepared, {
      accessToken: "ephemeral-test-token",
      fetchImpl: async () => new Response("provider echoed ephemeral-test-token", { status: 403 }),
    }),
    (error) => {
      assert.match(String(error), /\[redacted\]/);
      assert.doesNotMatch(String(error), /ephemeral-test-token/);
      return true;
    },
  );

  const updateCalls = [];
  const updated = await publishToGoogleDocs(prepared, {
    accessToken: "ephemeral-test-token",
    documentId: "doc-created",
    expectedVersion: "7",
    replaceExisting: true,
    fetchImpl: async (url, init) => {
      updateCalls.push({ url: String(url), init });
      if (init?.method === "GET") {
        if (String(url).includes("/comments?")) {
          return new Response(JSON.stringify({ comments: [] }), { status: 200 });
        }
        return new Response(JSON.stringify({
          id: "doc-created",
          title: "Quantum Sensing Brief",
          mimeType: "application/vnd.google-apps.document",
          version: "7",
          etag: '"remote-etag"',
          capabilities: { canEdit: true },
        }), { status: 200 });
      }
      return new Response(JSON.stringify({
        id: "doc-created",
        title: "Quantum Sensing Brief",
        mimeType: "application/vnd.google-apps.document",
        version: "8",
        alternateLink: "https://docs.google.com/document/d/doc-created/edit",
      }), { status: 200 });
    },
  });
  assert.deepEqual(updateCalls.map((call) => call.init.method), ["GET", "GET", "PUT"]);
  assert.match(updateCalls[0].url, /\/drive\/v2\/files\/doc-created\?/);
  assert.match(updateCalls[1].url, /\/comments\?/);
  assert.match(updateCalls[2].url, /\/upload\/drive\/v2\/files\/doc-created\?/);
  assert.equal(updateCalls[2].init.headers["if-match"], '"remote-etag"');
  assert.match(Buffer.from(updateCalls[2].init.body).toString("latin1"), /"visibility":"PRIVATE"/);
  assert.equal(updated.action, "update");
  assert.equal(updated.version, "8");

  const driftedVersionCalls = [];
  const driftedVersionUpdate = await publishToGoogleDocs(prepared, {
    accessToken: "ephemeral-test-token",
    documentId: "doc-created",
    expectedVersion: "6",
    replaceExisting: true,
    fetchImpl: async (url, init) => {
      driftedVersionCalls.push({ url: String(url), init });
      if (init?.method === "GET") {
        if (String(url).includes("/comments?")) {
          return new Response(JSON.stringify({ comments: [] }), { status: 200 });
        }
        return new Response(JSON.stringify({
          id: "doc-created",
          mimeType: "application/vnd.google-apps.document",
          version: "13",
          etag: '"drifted-etag"',
          capabilities: { canEdit: true },
        }), { status: 200 });
      }
      return new Response(JSON.stringify({
        id: "doc-created",
        mimeType: "application/vnd.google-apps.document",
        version: "14",
        alternateLink: "https://docs.google.com/document/d/doc-created/edit",
      }), { status: 200 });
    },
  });
  assert.deepEqual(driftedVersionCalls.map((call) => call.init.method), ["GET", "GET", "PUT"]);
  assert.equal(driftedVersionCalls[2].init.headers["if-match"], '"drifted-etag"');
  assert.equal(driftedVersionUpdate.version, "14", "Google-side version drift must not strand a linked publication");

  const missingEtagCalls = [];
  await assert.rejects(
    () => publishToGoogleDocs(prepared, {
      accessToken: "ephemeral-test-token",
      documentId: "doc-created",
      replaceExisting: true,
      fetchImpl: async (url, init) => {
        missingEtagCalls.push({ url: String(url), init });
        return new Response(JSON.stringify({
          id: "doc-created",
          mimeType: "application/vnd.google-apps.document",
          version: "13",
          capabilities: { canEdit: true },
        }), { status: 200 });
      },
    }),
    /did not return an ETag.*refusing an unguarded replacement/i,
  );
  assert.deepEqual(missingEtagCalls.map((call) => call.init.method), ["GET"]);

  const commentedCalls = [];
  await assert.rejects(
    () => publishToGoogleDocs(prepared, {
      accessToken: "ephemeral-test-token",
      documentId: "doc-created",
      expectedVersion: "7",
      replaceExisting: true,
      fetchImpl: async (url, init) => {
        commentedCalls.push({ url: String(url), init });
        if (String(url).includes("/comments?")) {
          return new Response(JSON.stringify({ comments: [{ id: "comment-1" }] }), { status: 200 });
        }
        return new Response(JSON.stringify({
          id: "doc-created",
          mimeType: "application/vnd.google-apps.document",
          version: "7",
          etag: '"remote-etag"',
          capabilities: { canEdit: true },
        }), { status: 200 });
      },
    }),
    /has comments.*publish as a new copy/i,
  );
  assert.deepEqual(commentedCalls.map((call) => call.init.method), ["GET", "GET"], "comments must stop the replacement upload");

  const workspaceSourcePath = path.join(fixtureRoot, "workspace-formats.org2");
  const workspaceSource = `#+TITLE: Publication Formats
#+ORG2_SLIDE_LEVEL: 2
#+LATEX_HEADER: \\input{/private/should-never-run}
* Findings
** Market signal
The market is growing.

- Cited research
- Repeatable method

| Company | Score |
|---------+-------|
| Alpha | 42 |

* Appendix
** Evidence
The evidence is reproducible.

| Source | URL |
|--------+-----|
| Public report | https://example.com/report |
`;
  fs.writeFileSync(workspaceSourcePath, workspaceSource);
  const workspacePublication = preparePublishedDocument({
    sourceText: workspaceSource,
    sourcePath: workspaceSourcePath,
  });

  const odp = prepareGoogleSlidesUpload(workspacePublication);
  assert.deepEqual(odp.bytes.subarray(0, 2), Buffer.from("PK"));
  assert.deepEqual(prepareGoogleSlidesUpload(workspacePublication).bytes, odp.bytes, "ODP media should be deterministic");
  assert.equal(odp.itemCount, 3, "a full-document deck should include a title page and two slides");
  const odpEntries = storedZipEntries(odp.bytes);
  assert.equal([...odpEntries.keys()][0], "mimetype", "ODF requires the uncompressed mimetype entry first");
  assert.equal(odpEntries.get("mimetype").toString("utf8"), "application/vnd.oasis.opendocument.presentation");
  assert.ok(odpEntries.has("content.xml"));
  assert.ok(odpEntries.has("styles.xml"));
  assert.ok(odpEntries.has("META-INF/manifest.xml"));
  const odpContent = odpEntries.get("content.xml").toString("utf8");
  assert.match(odpContent, /Market signal/);
  assert.match(odpContent, /Evidence/);
  assert.match(odpContent, /<table:table/);
  assert.doesNotMatch(odpContent, /private\/should-never-run/);

  const ods = prepareGoogleSheetsUpload(workspacePublication);
  assert.deepEqual(ods.bytes.subarray(0, 2), Buffer.from("PK"));
  assert.deepEqual(prepareGoogleSheetsUpload(workspacePublication).bytes, ods.bytes, "ODS media should be deterministic");
  assert.equal(ods.itemCount, 2);
  const odsEntries = storedZipEntries(ods.bytes);
  assert.equal(odsEntries.get("mimetype").toString("utf8"), "application/vnd.oasis.opendocument.spreadsheet");
  const odsContent = odsEntries.get("content.xml").toString("utf8");
  assert.match(odsContent, /table:name="Market signal"/);
  assert.match(odsContent, /table:name="Evidence"/);
  assert.match(odsContent, /office:value="42"/);
  assert.doesNotMatch(odsContent, /private\/should-never-run/);

  const beamer = preparePublishedBeamer(workspacePublication.document);
  assert.equal(beamer.slideCount, 2);
  assert.match(beamer.tex, /\\begin\{frame\}.*Market signal/s);
  assert.doesNotMatch(beamer.tex, /\\input\{\/private\/should-never-run\}/);

  const beamerPreview = runCliFor(workspaceSourcePath, [
    "--to", "beamer-pdf",
    "--out-file", path.join(fixtureRoot, "formats.pdf"),
    "--format", "json",
  ]);
  assert.equal(beamerPreview.status, 0, beamerPreview.stderr || beamerPreview.stdout);
  assert.equal(JSON.parse(beamerPreview.stdout).destination.slideCount, 2);

  const slidesPreview = runCliFor(workspaceSourcePath, ["--to", "google-slides", "--format", "json"]);
  assert.equal(slidesPreview.status, 0, slidesPreview.stderr || slidesPreview.stdout);
  const slidesPreviewPayload = JSON.parse(slidesPreview.stdout);
  assert.equal(slidesPreviewPayload.destination.mimeType, GOOGLE_SLIDES_MIME_TYPE);
  assert.equal(slidesPreviewPayload.destination.inputMediaType, "application/vnd.oasis.opendocument.presentation");

  const sheetsPreview = runCliFor(workspaceSourcePath, ["--to", "google-sheets", "--format", "json"]);
  assert.equal(sheetsPreview.status, 0, sheetsPreview.stderr || sheetsPreview.stdout);
  const sheetsPreviewPayload = JSON.parse(sheetsPreview.stdout);
  assert.equal(sheetsPreviewPayload.destination.mimeType, GOOGLE_SHEETS_MIME_TYPE);
  assert.equal(sheetsPreviewPayload.destination.inputMediaType, "application/vnd.oasis.opendocument.spreadsheet");

  const pdfPreview = runCliFor(workspaceSourcePath, ["--to", "google-drive-pdf", "--format", "json"]);
  assert.equal(pdfPreview.status, 0, pdfPreview.stderr || pdfPreview.stdout);
  assert.equal(JSON.parse(pdfPreview.stdout).destination.renderingRequired, true);

  for (const [destination, targetMediaType, inputMediaType] of [
    ["google-slides", GOOGLE_SLIDES_MIME_TYPE, "application/vnd.oasis.opendocument.presentation"],
    ["google-sheets", GOOGLE_SHEETS_MIME_TYPE, "application/vnd.oasis.opendocument.spreadsheet"],
  ]) {
    const calls = [];
    const result = await publishToGoogleWorkspace(workspacePublication, destination, {
      accessToken: "ephemeral-test-token",
      fetchImpl: async (url, init) => {
        calls.push({ url: String(url), init });
        return new Response(JSON.stringify({
          id: `${destination}-created`,
          name: "Publication Formats",
          mimeType: targetMediaType,
          version: "1",
        }), { status: 200 });
      },
    });
    assert.equal(calls.length, 1);
    const body = Buffer.from(calls[0].init.body).toString("latin1");
    assert.match(body, new RegExp(targetMediaType.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(body, new RegExp(inputMediaType.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.equal(result.destination, destination);
    assert.match(result.webViewLink, destination === "google-slides" ? /presentation/ : /spreadsheets/);
  }

  const pdfBytes = Buffer.from("%PDF-1.7\nsealed-publication\n%%EOF");
  assert.equal(prepareGoogleDrivePdfUpload(pdfBytes).mediaType, "application/pdf");
  assert.throws(() => prepareGoogleDrivePdfUpload(Buffer.from("not a pdf")), /valid PDF/);
  const pdfCalls = [];
  const pdfResult = await publishToGoogleWorkspace(workspacePublication, "google-drive-pdf", {
    accessToken: "ephemeral-test-token",
    pdfBytes,
    fetchImpl: async (url, init) => {
      pdfCalls.push({ url: String(url), init });
      return new Response(JSON.stringify({
        id: "pdf-created",
        name: "Publication Formats",
        mimeType: "application/pdf",
        version: "1",
      }), { status: 200 });
    },
  });
  assert.equal(pdfResult.destination, "google-drive-pdf");
  assert.match(pdfResult.webViewLink, /drive\.google\.com\/file/);
  assert.ok(Buffer.from(pdfCalls[0].init.body).indexOf(pdfBytes) > 0);
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log("single-document multi-format local and Google publishing tests passed");
