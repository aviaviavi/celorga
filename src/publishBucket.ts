import crypto from "node:crypto";

/**
 * Public links in a user-owned S3-compatible bucket (Cloudflare R2, Amazon S3,
 * and compatible stores). Celorga uploads one sealed artifact per link under an
 * unguessable object ID and deletes it to revoke the link; no Celorga backend
 * and no inbound connection to the user's Mac are involved.
 */

export const BUCKET_DEFAULT_REGION = "auto";
export const BUCKET_DEFAULT_KEY_PREFIX = "p/";
export const BUCKET_MAX_ARTIFACT_BYTES = 100 * 1024 * 1024;
/** Deleting an object must stop the link, so neither browsers nor CDNs may keep a copy. */
export const BUCKET_CACHE_CONTROL = "no-store, max-age=0";
export const BUCKET_ACCESS_KEY_ID_ENV = "CELORGA_BUCKET_ACCESS_KEY_ID";
export const BUCKET_SECRET_ACCESS_KEY_ENV = "CELORGA_BUCKET_SECRET_ACCESS_KEY";

const ARTIFACT_FILE_NAMES: Record<string, string> = {
  "text/html": "index.html",
  "application/pdf": "document.pdf",
};

export type BucketTarget = {
  endpoint: string;
  bucket: string;
  region: string;
  publicBaseUrl: string;
  keyPrefix: string;
};

export type BucketTargetInput = {
  endpoint: string;
  bucket?: string | undefined;
  region?: string | undefined;
  publicBaseUrl: string;
  keyPrefix?: string | undefined;
};

export type BucketCredentials = {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string | undefined;
};

export type BucketFetch = (url: string, init: { method: string; headers: Record<string, string>; body?: Uint8Array }) => Promise<Response>;

function isLoopbackHost(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]" || hostname === "::1";
}

function parseHttpsUrl(value: string, option: string): URL {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error(`${option} must be an absolute https:// URL`);
  }
  if (url.protocol !== "https:" && !(url.protocol === "http:" && isLoopbackHost(url.hostname))) {
    throw new Error(`${option} must use https://`);
  }
  if (url.username || url.password) throw new Error(`${option} must not contain credentials`);
  if (url.search || url.hash) throw new Error(`${option} must not contain a query or fragment`);
  return url;
}

const BUCKET_NAME = /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/;
const KEY_PREFIX = /^(?:[A-Za-z0-9._-]+\/)*$/;
const OBJECT_ID = /^[A-Za-z0-9_-]{22,128}$/;
const REGION = /^[a-z0-9-]{1,32}$/;

/**
 * Validates a bucket target. The endpoint may be the S3 API URL that R2 shows
 * for a bucket (`https://ACCOUNT.r2.cloudflarestorage.com/BUCKET`); its single
 * path segment then names the bucket.
 */
export function normalizeBucketTarget(input: BucketTargetInput): BucketTarget {
  const endpointUrl = parseHttpsUrl(input.endpoint, "--endpoint");
  const segments = endpointUrl.pathname.split("/").filter(Boolean);
  if (segments.length > 1) throw new Error("--endpoint must be the storage origin, optionally followed by the bucket name");
  const pathBucket = segments[0] ? decodeURIComponent(segments[0]) : undefined;
  const bucket = (input.bucket ?? pathBucket ?? "").trim();
  if (!bucket) throw new Error("bucket publishing requires --bucket NAME (or an --endpoint URL ending in the bucket name)");
  if (pathBucket && pathBucket !== bucket) throw new Error(`--bucket ${bucket} does not match the bucket in --endpoint (${pathBucket})`);
  if (!BUCKET_NAME.test(bucket) || bucket.includes("..")) throw new Error(`Invalid bucket name: ${bucket}`);
  const region = (input.region ?? BUCKET_DEFAULT_REGION).trim() || BUCKET_DEFAULT_REGION;
  if (!REGION.test(region)) throw new Error(`Invalid --region: ${region}`);
  const publicUrl = parseHttpsUrl(input.publicBaseUrl, "--public-base-url");
  const publicBaseUrl = `${publicUrl.origin}${publicUrl.pathname.replace(/\/+$/, "")}`;
  let keyPrefix = (input.keyPrefix ?? BUCKET_DEFAULT_KEY_PREFIX).trim().replace(/^\/+/, "");
  if (keyPrefix && !keyPrefix.endsWith("/")) keyPrefix += "/";
  if (!KEY_PREFIX.test(keyPrefix) || keyPrefix.split("/").some((segment) => segment === "." || segment === "..")) {
    throw new Error(`Invalid --key-prefix: ${input.keyPrefix}`);
  }
  return { endpoint: endpointUrl.origin, bucket, region, publicBaseUrl, keyPrefix };
}

export function newBucketObjectId(): string {
  return crypto.randomBytes(24).toString("base64url");
}

export function validateBucketObjectId(objectId: string): string {
  if (!OBJECT_ID.test(objectId)) throw new Error("--object-id must be 22-128 URL-safe characters (A-Z, a-z, 0-9, _ and -)");
  return objectId;
}

export function bucketArtifactFileName(mediaType: string): string {
  const name = ARTIFACT_FILE_NAMES[mediaType];
  if (!name) throw new Error(`Unsupported bucket artifact media type: ${mediaType}`);
  return name;
}

export function bucketObjectKey(target: BucketTarget, objectId: string, mediaType: string): string {
  return `${target.keyPrefix}${validateBucketObjectId(objectId)}/${bucketArtifactFileName(mediaType)}`;
}

export function bucketPublicUrl(target: BucketTarget, key: string): string {
  return `${target.publicBaseUrl}/${encodeKey(key)}`;
}

function encodeRfc3986(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
}

function encodeKey(key: string): string {
  return key.split("/").map(encodeRfc3986).join("/");
}

function bucketObjectUrl(target: BucketTarget, key: string): string {
  return `${target.endpoint}/${encodeRfc3986(target.bucket)}/${encodeKey(key)}`;
}

function sha256Hex(value: Uint8Array | string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function hmac(key: crypto.BinaryLike, value: string): Buffer {
  return crypto.createHmac("sha256", key).update(value).digest();
}

function amzDate(now: Date): string {
  return now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

/**
 * AWS Signature Version 4 for an S3 request. Returns the headers to send:
 * the caller's headers plus x-amz-date, x-amz-content-sha256, and
 * Authorization. Host is signed from the URL; fetch sends the same value.
 */
export function signS3Request(options: {
  method: string;
  url: string;
  headers?: Record<string, string>;
  payloadHash: string;
  credentials: BucketCredentials;
  region: string;
  now?: Date;
}): Record<string, string> {
  const url = new URL(options.url);
  const timestamp = amzDate(options.now ?? new Date());
  const day = timestamp.slice(0, 8);
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(options.headers ?? {})) headers[name.toLowerCase()] = String(value).trim();
  headers["x-amz-date"] = timestamp;
  headers["x-amz-content-sha256"] = options.payloadHash;
  if (options.credentials.sessionToken) headers["x-amz-security-token"] = options.credentials.sessionToken;
  const signed: Record<string, string> = { ...headers, host: url.host };
  const names = Object.keys(signed).sort();
  const canonicalQuery = [...url.searchParams.entries()]
    .map(([key, value]) => [encodeRfc3986(key), encodeRfc3986(value)] as const)
    .sort(([a, av], [b, bv]) => (a === b ? (av < bv ? -1 : av > bv ? 1 : 0) : a < b ? -1 : 1))
    .map(([key, value]) => `${key}=${value}`)
    .join("&");
  const canonicalRequest = [
    options.method.toUpperCase(),
    url.pathname || "/",
    canonicalQuery,
    names.map((name) => `${name}:${signed[name]}\n`).join(""),
    names.join(";"),
    options.payloadHash,
  ].join("\n");
  const scope = `${day}/${options.region}/s3/aws4_request`;
  const stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, sha256Hex(canonicalRequest)].join("\n");
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${options.credentials.secretAccessKey}`, day), options.region), "s3"), "aws4_request");
  const signature = crypto.createHmac("sha256", signingKey).update(stringToSign).digest("hex");
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${options.credentials.accessKeyId}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}`;
  return headers;
}

function requestBody(value: Uint8Array): ArrayBuffer {
  const bytes = new Uint8Array(value.byteLength);
  bytes.set(value);
  return bytes.buffer;
}

const defaultFetch: BucketFetch = (url, init) =>
  fetch(url, {
    method: init.method,
    headers: init.headers,
    ...(init.body ? { body: requestBody(init.body) } : {}),
    redirect: "error",
  });

async function bucketError(response: Response, operation: string, credentials: BucketCredentials): Promise<Error> {
  const body = (await response.text().catch(() => "")).slice(0, 2_000);
  const code = /<Code>([^<]*)<\/Code>/.exec(body)?.[1];
  const message = /<Message>([^<]*)<\/Message>/.exec(body)?.[1];
  let detail = [code, message].filter(Boolean).join(": ") || body.trim().slice(0, 300);
  for (const secret of [credentials.secretAccessKey, credentials.sessionToken]) {
    if (secret) detail = detail.split(secret).join("[redacted]");
  }
  return new Error(`Bucket ${operation} failed (HTTP ${response.status})${detail ? `: ${detail}` : ""}`);
}

export async function putBucketObject(
  target: BucketTarget,
  credentials: BucketCredentials,
  key: string,
  body: Uint8Array,
  mediaType: string,
  fetchImpl: BucketFetch = defaultFetch,
): Promise<{ key: string; etag?: string }> {
  if (body.byteLength > BUCKET_MAX_ARTIFACT_BYTES) throw new Error(`Bucket artifacts are limited to ${BUCKET_MAX_ARTIFACT_BYTES} bytes`);
  const url = bucketObjectUrl(target, key);
  const fileName = key.slice(key.lastIndexOf("/") + 1);
  const headers = signS3Request({
    method: "PUT",
    url,
    headers: {
      "cache-control": BUCKET_CACHE_CONTROL,
      "content-disposition": `inline; filename="${fileName}"`,
      "content-type": mediaType === "text/html" ? "text/html; charset=utf-8" : mediaType,
    },
    payloadHash: sha256Hex(body),
    credentials,
    region: target.region,
  });
  const response = await fetchImpl(url, { method: "PUT", headers, body });
  if (!response.ok) throw await bucketError(response, "upload", credentials);
  await response.arrayBuffer().catch(() => undefined);
  const etag = response.headers.get("etag")?.replace(/"/g, "") || undefined;
  return { key, ...(etag ? { etag } : {}) };
}

export async function deleteBucketObject(
  target: BucketTarget,
  credentials: BucketCredentials,
  key: string,
  fetchImpl: BucketFetch = defaultFetch,
): Promise<void> {
  const url = bucketObjectUrl(target, key);
  const headers = signS3Request({ method: "DELETE", url, payloadHash: sha256Hex(""), credentials, region: target.region });
  const response = await fetchImpl(url, { method: "DELETE", headers });
  // S3 and R2 answer 204 whether or not the object existed.
  if (!response.ok && response.status !== 404) throw await bucketError(response, "delete", credentials);
  await response.arrayBuffer().catch(() => undefined);
}

export type BucketPublishResult = {
  destination: "bucket";
  action: "create" | "replace";
  objectId: string;
  key: string;
  url: string;
  mediaType: string;
  bytes: number;
  artifactHash: string;
  bucket: string;
  endpoint: string;
  cacheControl: string;
  etag?: string;
};

export async function publishArtifactToBucket(options: {
  target: BucketTarget;
  credentials: BucketCredentials;
  objectId?: string | undefined;
  body: Uint8Array;
  mediaType: string;
  fetchImpl?: BucketFetch;
}): Promise<BucketPublishResult> {
  const objectId = options.objectId ? validateBucketObjectId(options.objectId) : newBucketObjectId();
  const key = bucketObjectKey(options.target, objectId, options.mediaType);
  const uploaded = await putBucketObject(options.target, options.credentials, key, options.body, options.mediaType, options.fetchImpl);
  // A link keeps one artifact: replacing a web page with a PDF (or the
  // reverse) must not leave the other format reachable.
  for (const other of Object.keys(ARTIFACT_FILE_NAMES)) {
    if (other !== options.mediaType) {
      await deleteBucketObject(options.target, options.credentials, bucketObjectKey(options.target, objectId, other), options.fetchImpl);
    }
  }
  return {
    destination: "bucket",
    action: options.objectId ? "replace" : "create",
    objectId,
    key,
    url: bucketPublicUrl(options.target, key),
    mediaType: options.mediaType,
    bytes: options.body.byteLength,
    artifactHash: `sha256:${sha256Hex(options.body)}`,
    bucket: options.target.bucket,
    endpoint: options.target.endpoint,
    cacheControl: BUCKET_CACHE_CONTROL,
    ...(uploaded.etag ? { etag: uploaded.etag } : {}),
  };
}

/** Deletes every artifact a link could hold. Deleting a missing object succeeds. */
export async function revokeBucketPublication(options: {
  target: BucketTarget;
  credentials: BucketCredentials;
  objectId: string;
  fetchImpl?: BucketFetch;
}): Promise<{ destination: "bucket"; action: "revoke"; objectId: string; deletedKeys: string[] }> {
  const objectId = validateBucketObjectId(options.objectId);
  const keys = Object.keys(ARTIFACT_FILE_NAMES).map((mediaType) => bucketObjectKey(options.target, objectId, mediaType));
  for (const key of keys) await deleteBucketObject(options.target, options.credentials, key, options.fetchImpl);
  return { destination: "bucket", action: "revoke", objectId, deletedKeys: keys };
}

/**
 * Proves the configuration end to end: upload a probe, read it back through
 * the public base URL, and delete it.
 */
export async function checkBucketTarget(options: {
  target: BucketTarget;
  credentials: BucketCredentials;
  fetchImpl?: BucketFetch;
}): Promise<{ destination: "bucket"; writable: true; publiclyReadable: boolean; deleted: true; probeUrl: string; detail?: string }> {
  const fetchImpl = options.fetchImpl ?? defaultFetch;
  const key = `${options.target.keyPrefix}${newBucketObjectId()}/index.html`;
  const marker = `celorga-bucket-check ${newBucketObjectId()}`;
  const body = new TextEncoder().encode(`<!doctype html><meta charset="utf-8"><meta name="robots" content="noindex"><title>Celorga check</title>${marker}`);
  await putBucketObject(options.target, options.credentials, key, body, "text/html", fetchImpl);
  const probeUrl = bucketPublicUrl(options.target, key);
  let publiclyReadable = false;
  let detail: string | undefined;
  try {
    const response = await fetchImpl(probeUrl, { method: "GET", headers: { "cache-control": "no-cache" } });
    const text = await response.text();
    publiclyReadable = response.ok && text.includes(marker);
    if (!publiclyReadable) {
      detail = response.ok
        ? "The public base URL answered, but not with the uploaded probe. Check that it points at this bucket."
        : `The public base URL answered HTTP ${response.status}. Turn on public access for the bucket (for R2, its r2.dev URL or a custom domain) and use that URL.`;
    }
  } catch (error) {
    detail = `Could not reach the public base URL: ${error instanceof Error ? error.message : String(error)}`;
  } finally {
    await deleteBucketObject(options.target, options.credentials, key, fetchImpl);
  }
  return { destination: "bucket", writable: true, publiclyReadable, deleted: true, probeUrl, ...(detail ? { detail } : {}) };
}
