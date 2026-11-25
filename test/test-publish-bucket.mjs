import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  normalizeBucketTarget,
  signS3Request,
} from "../dist/publishBucket.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = path.join(repoRoot, "dist", "cli.js");

// AWS Signature Version 4 reference vector (S3 "GET Object" example).
{
  const headers = signS3Request({
    method: "GET",
    url: "https://examplebucket.s3.amazonaws.com/test.txt",
    headers: { Range: "bytes=0-9" },
    payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    credentials: { accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" },
    region: "us-east-1",
    now: new Date("2013-05-24T00:00:00Z"),
  });
  assert.equal(
    headers.authorization,
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
  );
}

// Target validation: R2's per-bucket S3 API URL names the bucket; plain HTTP
// is accepted only for loopback test servers.
{
  const target = normalizeBucketTarget({
    endpoint: "https://0123456789abcdef.r2.cloudflarestorage.com/team-links",
    publicBaseUrl: "https://pub-example.r2.dev/",
  });
  assert.deepEqual(target, {
    endpoint: "https://0123456789abcdef.r2.cloudflarestorage.com",
    bucket: "team-links",
    region: "auto",
    publicBaseUrl: "https://pub-example.r2.dev",
    keyPrefix: "p/",
  });
  assert.throws(() => normalizeBucketTarget({ endpoint: "http://storage.example.com", bucket: "team-links", publicBaseUrl: "https://x.example" }), /https/);
  assert.throws(() => normalizeBucketTarget({ endpoint: "https://storage.example.com", bucket: "Bad_Name", publicBaseUrl: "https://x.example" }), /Invalid bucket name/);
  assert.throws(() => normalizeBucketTarget({ endpoint: "https://storage.example.com/a", bucket: "b-bucket", publicBaseUrl: "https://x.example" }), /does not match/);
  assert.throws(() => normalizeBucketTarget({ endpoint: "https://storage.example.com", bucket: "team-links", publicBaseUrl: "https://x.example", keyPrefix: "../up/" }), /key-prefix/);
}

// A minimal S3-compatible store: signed PUT/DELETE under /BUCKET/KEY and
// anonymous GET under /public/KEY.
const objects = new Map();
const requests = [];
const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    const body = Buffer.concat(chunks);
    const url = new URL(request.url, "http://127.0.0.1");
    requests.push({ method: request.method, path: url.pathname, headers: request.headers });
    if (url.pathname.startsWith("/public/")) {
      const object = objects.get(decodeURIComponent(url.pathname.slice("/public/".length)));
      if (!object || request.method !== "GET") {
        response.writeHead(404).end("missing");
        return;
      }
      response.writeHead(200, { "content-type": object.contentType, "cache-control": object.cacheControl }).end(object.body);
      return;
    }
    const authorization = String(request.headers.authorization || "");
    if (!authorization.startsWith("AWS4-HMAC-SHA256 Credential=AKIDTESTONLY/") || !authorization.includes("/auto/s3/aws4_request")) {
      response.writeHead(403).end("<Error><Code>AccessDenied</Code><Message>bad signature</Message></Error>");
      return;
    }
    assert.equal(request.headers["x-amz-content-sha256"], crypto.createHash("sha256").update(body).digest("hex"));
    assert.ok(!authorization.includes("secret-test-only"));
    if (!url.pathname.startsWith("/test-bucket/")) {
      response.writeHead(404).end("<Error><Code>NoSuchBucket</Code></Error>");
      return;
    }
    const key = decodeURIComponent(url.pathname.slice("/test-bucket/".length));
    if (request.method === "PUT") {
      objects.set(key, { body, contentType: request.headers["content-type"], cacheControl: request.headers["cache-control"] });
      response.writeHead(200, { etag: '"abc123"' }).end();
    } else if (request.method === "DELETE") {
      objects.delete(key);
      response.writeHead(204).end();
    } else {
      response.writeHead(405).end();
    }
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const endpoint = `http://127.0.0.1:${port}`;
const publicBaseUrl = `${endpoint}/public`;

function runCli(args, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [cliPath, ...args], {
      cwd: repoRoot,
      env: { ...process.env, CELORGA_BUCKET_ACCESS_KEY_ID: "", CELORGA_BUCKET_SECRET_ACCESS_KEY: "", ...env },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

const credentials = { CELORGA_BUCKET_ACCESS_KEY_ID: "AKIDTESTONLY", CELORGA_BUCKET_SECRET_ACCESS_KEY: "secret-test-only" };
const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "celorga-publish-bucket-"));
const sourcePath = path.join(fixtureRoot, "brief.org");
fs.writeFileSync(sourcePath, `#+TITLE: Field Notes\n\n* Summary\n:PROPERTIES:\n:ID: 0f0b5a7e-3a1c-4a52-9a8e-111111111111\n:SECRET: NEVER-PUBLISH\n:END:\nPublic findings.\n`);
const bucketArgs = ["--to", "bucket", "--endpoint", endpoint, "--bucket", "test-bucket", "--public-base-url", publicBaseUrl];

try {
  // Preview never contacts the bucket or needs keys.
  const preview = await runCli(["publish", "document", "--file", sourcePath, ...bucketArgs, "--format", "json"]);
  assert.equal(preview.status, 0, preview.stderr);
  const previewPayload = JSON.parse(preview.stdout);
  assert.equal(previewPayload.applied, false);
  assert.equal(previewPayload.destination.destination, "bucket");
  assert.equal(previewPayload.destination.mediaType, "text/html");
  assert.equal(requests.length, 0);

  // Applying without keys fails before any request.
  const missingKeys = await runCli(["publish", "document", "--file", sourcePath, ...bucketArgs, "--apply", "--format", "json"]);
  assert.notEqual(missingKeys.status, 0);
  assert.match(missingKeys.stderr, /CELORGA_BUCKET_ACCESS_KEY_ID/);
  assert.equal(requests.length, 0);

  // Publish the sealed web page under a new unguessable object ID.
  const published = await runCli(["publish", "document", "--file", sourcePath, ...bucketArgs, "--apply", "--format", "json"], credentials);
  assert.equal(published.status, 0, published.stderr);
  const result = JSON.parse(published.stdout).destination;
  assert.equal(result.action, "create");
  assert.match(result.objectId, /^[A-Za-z0-9_-]{32}$/);
  assert.equal(result.key, `p/${result.objectId}/index.html`);
  assert.equal(result.url, `${publicBaseUrl}/p/${result.objectId}/index.html`);
  const page = await fetch(result.url);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get("cache-control"), "no-store, max-age=0");
  assert.equal(page.headers.get("content-type"), "text/html; charset=utf-8");
  const html = await page.text();
  assert.match(html, /Public findings/);
  assert.doesNotMatch(html, /NEVER-PUBLISH/);
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /noindex/);

  // Republishing the same object as a PDF keeps the link ID and removes the web page.
  const pdfPath = path.join(fixtureRoot, "brief.pdf");
  fs.writeFileSync(pdfPath, "%PDF-1.4\n% synthetic\n%%EOF\n");
  const replaceWithoutFlag = await runCli(["publish", "document", "--file", sourcePath, ...bucketArgs, "--object-id", result.objectId, "--apply"], credentials);
  assert.notEqual(replaceWithoutFlag.status, 0);
  assert.match(replaceWithoutFlag.stderr, /--replace-existing/);
  const replaced = await runCli([
    "publish", "document", "--file", sourcePath, ...bucketArgs,
    "--object-id", result.objectId, "--replace-existing", "--pdf-file", pdfPath, "--apply", "--format", "json",
  ], credentials);
  assert.equal(replaced.status, 0, replaced.stderr);
  const replacedResult = JSON.parse(replaced.stdout).destination;
  assert.equal(replacedResult.action, "replace");
  assert.equal(replacedResult.objectId, result.objectId);
  assert.equal(replacedResult.url, `${publicBaseUrl}/p/${result.objectId}/document.pdf`);
  assert.equal((await fetch(result.url)).status, 404);
  assert.equal((await fetch(replacedResult.url)).status, 200);

  // Revoke previews, then deletes every artifact for the link.
  const revokeArgs = ["publish", "bucket", "revoke", "--endpoint", endpoint, "--bucket", "test-bucket", "--public-base-url", publicBaseUrl, "--object-id", result.objectId];
  const revokePreview = await runCli([...revokeArgs, "--format", "json"]);
  assert.equal(revokePreview.status, 0, revokePreview.stderr);
  assert.equal((await fetch(replacedResult.url)).status, 200);
  const revoked = await runCli([...revokeArgs, "--apply", "--format", "json"], credentials);
  assert.equal(revoked.status, 0, revoked.stderr);
  assert.deepEqual(JSON.parse(revoked.stdout).result.deletedKeys, [`p/${result.objectId}/index.html`, `p/${result.objectId}/document.pdf`]);
  assert.equal((await fetch(replacedResult.url)).status, 404);

  // Check proves write, public read, and delete; a wrong public URL fails clearly.
  const checkArgs = ["publish", "bucket", "check", "--endpoint", `${endpoint}/test-bucket`, "--public-base-url", publicBaseUrl, "--apply", "--format", "json"];
  const checked = await runCli(checkArgs, credentials);
  assert.equal(checked.status, 0, checked.stderr);
  assert.equal(JSON.parse(checked.stdout).result.publiclyReadable, true);
  assert.equal(objects.size, 0);
  const wrongPublic = await runCli(["publish", "bucket", "check", "--endpoint", endpoint, "--bucket", "test-bucket", "--public-base-url", `${endpoint}/elsewhere`, "--apply", "--format", "json"], credentials);
  assert.equal(wrongPublic.status, 0, wrongPublic.stderr);
  assert.equal(JSON.parse(wrongPublic.stdout).result.publiclyReadable, false);
  assert.match(JSON.parse(wrongPublic.stdout).result.detail, /HTTP 403/);
  assert.equal(objects.size, 0);
  const wrongPublicText = await runCli(["publish", "bucket", "check", "--endpoint", endpoint, "--bucket", "test-bucket", "--public-base-url", `${endpoint}/elsewhere`, "--apply"], credentials);
  assert.equal(wrongPublicText.status, 1);
  assert.match(wrongPublicText.stdout, /NOT readable/);

  // Storage errors surface the provider's code without leaking the secret.
  const denied = await runCli(["publish", "document", "--file", sourcePath, ...bucketArgs, "--apply"], { ...credentials, CELORGA_BUCKET_ACCESS_KEY_ID: "WRONGKEY" });
  assert.notEqual(denied.status, 0);
  assert.match(denied.stderr, /HTTP 403\): AccessDenied/);
  assert.doesNotMatch(denied.stderr + denied.stdout, /secret-test-only/);

  // Bucket options are rejected for other destinations.
  const mixed = await runCli(["publish", "document", "--file", sourcePath, "--to", "web", "--out-dir", path.join(fixtureRoot, "web"), "--endpoint", endpoint]);
  assert.notEqual(mixed.status, 0);
  assert.match(mixed.stderr, /require --to bucket/);
} finally {
  server.close();
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log("publish bucket tests passed");
