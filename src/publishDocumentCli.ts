import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { findConfigFile, loadConfig } from "./config.js";
import {
  GOOGLE_DOCS_MIME_TYPE,
  GOOGLE_SHEETS_MIME_TYPE,
  GOOGLE_SLIDES_MIME_TYPE,
  PDF_MEDIA_TYPE,
  GOOGLE_DRIVE_MULTIPART_MAX_BYTES,
  GOOGLE_DRIVE_FILE_SCOPE,
  prepareGoogleWorkspaceUpload,
  preparePublishedDocument,
  publishToGoogleWorkspace,
  writeWebPublicationBundle,
  type GoogleWorkspaceDestination,
  type PreparedPublishedDocument,
} from "./publishDocument.js";
import {
  compilePublishedBeamerPdf,
  preparePublishedBeamer,
} from "./publishedDocumentBeamer.js";
import { brandEnv } from "./brandNames.js";
import {
  BUCKET_ACCESS_KEY_ID_ENV,
  BUCKET_CACHE_CONTROL,
  BUCKET_SECRET_ACCESS_KEY_ENV,
  bucketObjectKey,
  bucketPublicUrl,
  checkBucketTarget,
  normalizeBucketTarget,
  publishArtifactToBucket,
  revokeBucketPublication,
  validateBucketObjectId,
  type BucketCredentials,
  type BucketTarget,
} from "./publishBucket.js";

type PublishDestination = "web" | "beamer-pdf" | "bucket" | GoogleWorkspaceDestination;
type OutputFormat = "text" | "json";

type PublishDocumentArguments = {
  file: string;
  line?: number;
  title?: string;
  destination: PublishDestination;
  outDir?: string;
  outFile?: string;
  pdfFile?: string;
  documentId?: string;
  folderId?: string;
  expectedVersion?: string;
  accessTokenEnv: string;
  bucket?: BucketArguments;
  configPath?: string;
  allowIndexing: boolean;
  replaceExisting: boolean;
  apply: boolean;
  format: OutputFormat;
};

type BucketArguments = {
  endpoint?: string;
  bucket?: string;
  region?: string;
  publicBaseUrl?: string;
  keyPrefix?: string;
  objectId?: string;
  accessKeyEnv: string;
  secretKeyEnv: string;
};

const BUCKET_USAGE = `  celorga publish document --file FILE --to bucket --endpoint URL [--bucket NAME] --public-base-url URL [--region auto] [--key-prefix p/] [--pdf-file FILE.pdf] [--line N] [--apply] [--format text|json]
  celorga publish document --file FILE --to bucket ... --object-id ID --replace-existing [--apply]
  celorga publish bucket check --endpoint URL [--bucket NAME] --public-base-url URL [--region auto] [--key-prefix p/] [--apply] [--format text|json]
  celorga publish bucket revoke --endpoint URL [--bucket NAME] --public-base-url URL --object-id ID [--region auto] [--key-prefix p/] [--apply] [--format text|json]`;

/** Parses one bucket option at args[index]; returns the next index, or undefined when the option is not a bucket option. */
function parseBucketOption(args: string[], index: number, bucket: BucketArguments): number | undefined {
  const argument = args[index];
  if (argument === "--endpoint") bucket.endpoint = requiredValue(args, index, argument);
  else if (argument === "--bucket") bucket.bucket = requiredValue(args, index, argument);
  else if (argument === "--region") bucket.region = requiredValue(args, index, argument);
  else if (argument === "--public-base-url") bucket.publicBaseUrl = requiredValue(args, index, argument);
  else if (argument === "--key-prefix") {
    const value = args[index + 1];
    if (value === undefined || value.startsWith("--")) throw new Error("--key-prefix requires a value (use \"\" for none)");
    bucket.keyPrefix = value;
  }
  else if (argument === "--object-id") bucket.objectId = validateBucketObjectId(requiredValue(args, index, argument));
  else if (argument === "--access-key-env") bucket.accessKeyEnv = requiredValue(args, index, argument);
  else if (argument === "--secret-key-env") bucket.secretKeyEnv = requiredValue(args, index, argument);
  else return undefined;
  return index + 1;
}

function bucketTarget(bucket: BucketArguments): BucketTarget {
  if (!bucket.endpoint) throw new Error("bucket publishing requires --endpoint URL");
  if (!bucket.publicBaseUrl) throw new Error("bucket publishing requires --public-base-url URL");
  return normalizeBucketTarget({
    endpoint: bucket.endpoint,
    bucket: bucket.bucket,
    region: bucket.region,
    publicBaseUrl: bucket.publicBaseUrl,
    keyPrefix: bucket.keyPrefix,
  });
}

function bucketCredentials(bucket: BucketArguments): BucketCredentials {
  for (const name of [bucket.accessKeyEnv, bucket.secretKeyEnv]) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) throw new Error("--access-key-env and --secret-key-env must name environment variables");
  }
  const accessKeyId = String(brandEnv(bucket.accessKeyEnv) || "").trim();
  const secretAccessKey = String(brandEnv(bucket.secretKeyEnv) || "").trim();
  if (!accessKeyId || !secretAccessKey) {
    throw new Error(`Bucket publishing requires ${bucket.accessKeyEnv} and ${bucket.secretKeyEnv} in the environment`);
  }
  const sessionToken = String(brandEnv("CELORGA_BUCKET_SESSION_TOKEN") || "").trim();
  return { accessKeyId, secretAccessKey, ...(sessionToken ? { sessionToken } : {}) };
}

function newBucketArguments(): BucketArguments {
  return { accessKeyEnv: BUCKET_ACCESS_KEY_ID_ENV, secretKeyEnv: BUCKET_SECRET_ACCESS_KEY_ENV };
}

function googleDestinationLabel(destination: GoogleWorkspaceDestination): string {
  if (destination === "google-slides") return "Google Slides";
  if (destination === "google-sheets") return "Google Sheets";
  if (destination === "google-drive-pdf") return "Google Drive PDF";
  return "Google Docs";
}

function googleTargetMediaType(destination: GoogleWorkspaceDestination): string {
  if (destination === "google-slides") return GOOGLE_SLIDES_MIME_TYPE;
  if (destination === "google-sheets") return GOOGLE_SHEETS_MIME_TYPE;
  if (destination === "google-drive-pdf") return PDF_MEDIA_TYPE;
  return GOOGLE_DOCS_MIME_TYPE;
}

function usage(exitCode: number): never {
  console.error(`Usage:
  celorga publish document --file FILE --to web --out-dir DIR [--line N] [--allow-indexing] [--replace-existing] [--apply] [--format text|json]
  celorga publish document --file FILE --to beamer-pdf --out-file FILE.pdf [--line N] [--replace-existing] [--apply] [--format text|json]
  celorga publish document --file FILE --to google-docs [--folder-id ID] [--line N] [--apply] [--format text|json]
  celorga publish document --file FILE --to google-slides [--folder-id ID] [--line N] [--apply] [--format text|json]
  celorga publish document --file FILE --to google-sheets [--folder-id ID] [--line N] [--apply] [--format text|json]
  celorga publish document --file FILE --to google-drive-pdf --pdf-file FILE.pdf [--folder-id ID] [--line N] [--apply] [--format text|json]
  celorga publish document --file FILE --to google-docs|google-slides|google-sheets --document-id ID [--if-version VERSION] --replace-existing [--apply] [--format text|json]
${BUCKET_USAGE}

Publishes a disclosure-safe document or subtree. Commands preview by default.
Google credentials are read from ORG2_GOOGLE_DRIVE_ACCESS_TOKEN (or the
environment variable named by --access-token-env), never from an argument.
Bucket destinations are S3-compatible storage you own, such as Cloudflare R2
or Amazon S3. Keys are read from ${BUCKET_ACCESS_KEY_ID_ENV} and
${BUCKET_SECRET_ACCESS_KEY_ENV} (or --access-key-env/--secret-key-env).
Each link is an unguessable object ID; revoking deletes the object.`);
  process.exit(exitCode);
}

function requiredValue(args: string[], index: number, option: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${option} requires a value`);
  return value;
}

function parseArguments(args: string[]): PublishDocumentArguments {
  let file = "";
  let line: number | undefined;
  let title: string | undefined;
  let destination: PublishDestination = "web";
  let outDir: string | undefined;
  let outFile: string | undefined;
  let pdfFile: string | undefined;
  let documentId: string | undefined;
  let folderId: string | undefined;
  let expectedVersion: string | undefined;
  let accessTokenEnv = "ORG2_GOOGLE_DRIVE_ACCESS_TOKEN";
  const bucket = newBucketArguments();
  let usesBucketOptions = false;
  let configPath: string | undefined;
  let allowIndexing = false;
  let replaceExisting = false;
  let apply = false;
  let format: OutputFormat = "text";

  for (let index = 2; index < args.length; index += 1) {
    const argument = args[index];
    const bucketNext = parseBucketOption(args, index, bucket);
    if (bucketNext !== undefined) {
      index = bucketNext;
      usesBucketOptions = true;
      continue;
    }
    if (argument === "--file") file = requiredValue(args, index++, argument);
    else if (argument === "--line") line = Number(requiredValue(args, index++, argument));
    else if (argument === "--title") title = requiredValue(args, index++, argument);
    else if (argument === "--to") {
      const value = requiredValue(args, index++, argument);
      if (!["web", "beamer-pdf", "bucket", "google-docs", "google-slides", "google-sheets", "google-drive-pdf"].includes(value)) {
        throw new Error("--to must be web, beamer-pdf, bucket, google-docs, google-slides, google-sheets, or google-drive-pdf");
      }
      destination = value as PublishDestination;
    } else if (argument === "--out-dir") outDir = requiredValue(args, index++, argument);
    else if (argument === "--out-file") outFile = requiredValue(args, index++, argument);
    else if (argument === "--pdf-file") pdfFile = requiredValue(args, index++, argument);
    else if (argument === "--document-id") documentId = requiredValue(args, index++, argument);
    else if (argument === "--folder-id") folderId = requiredValue(args, index++, argument);
    else if (argument === "--if-version") expectedVersion = requiredValue(args, index++, argument);
    else if (argument === "--access-token-env") accessTokenEnv = requiredValue(args, index++, argument);
    else if (argument === "--config") configPath = requiredValue(args, index++, argument);
    else if (argument === "--allow-indexing") allowIndexing = true;
    else if (argument === "--replace-existing") replaceExisting = true;
    else if (argument === "--apply") apply = true;
    else if (argument === "--json") format = "json";
    else if (argument === "--format") {
      const value = requiredValue(args, index++, argument);
      if (value !== "text" && value !== "json") throw new Error("--format must be text or json");
      format = value;
    } else {
      throw new Error(`Unknown publish document option: ${argument}`);
    }
  }

  if (!file) throw new Error("publish document requires --file FILE");
  if (line !== undefined && (!Number.isInteger(line) || line < 1)) throw new Error("--line must be a positive integer");
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(accessTokenEnv)) throw new Error("--access-token-env must name an environment variable");
  if (usesBucketOptions && destination !== "bucket") throw new Error("bucket options require --to bucket");
  if (destination === "bucket") {
    if (outDir || outFile) throw new Error("--out-dir and --out-file do not apply to --to bucket");
    if (documentId || folderId || expectedVersion) throw new Error("Google Drive options require a Google destination");
    if (bucket.objectId && !replaceExisting) throw new Error("updating --object-id requires --replace-existing");
    if (!bucket.objectId && replaceExisting) throw new Error("--replace-existing requires --object-id for bucket publishing");
    bucketTarget(bucket);
  } else if (destination === "web") {
    if (!outDir) throw new Error("web publishing requires --out-dir DIR");
    if (outFile || pdfFile) throw new Error("--out-file and --pdf-file do not apply to --to web");
    if (documentId || folderId || expectedVersion) throw new Error("Google Drive options require a Google destination");
  } else if (destination === "beamer-pdf") {
    if (!outFile) throw new Error("Beamer PDF publishing requires --out-file FILE.pdf");
    if (outDir || pdfFile) throw new Error("--out-dir and --pdf-file do not apply to --to beamer-pdf");
    if (allowIndexing) throw new Error("--allow-indexing only applies to --to web");
    if (documentId || folderId || expectedVersion) throw new Error("Google Drive options require a Google destination");
  } else {
    if (outDir || outFile) throw new Error("--out-dir and --out-file only apply to local destinations");
    if (allowIndexing) throw new Error("--allow-indexing only applies to --to web");
    if (documentId && folderId) throw new Error("--folder-id cannot be used when updating --document-id");
    if (documentId && !replaceExisting) throw new Error("updating --document-id requires --replace-existing");
    if (!documentId && expectedVersion) throw new Error("--if-version requires --document-id");
    if (!documentId && replaceExisting) throw new Error("--replace-existing requires --document-id for Google publishing");
    if (destination === "google-drive-pdf" && apply && !pdfFile) {
      throw new Error("Google Drive PDF publishing requires --pdf-file FILE.pdf when applying");
    }
    if (destination !== "google-drive-pdf" && pdfFile) {
      throw new Error("--pdf-file only applies to --to google-drive-pdf");
    }
  }

  return {
    file,
    ...(line !== undefined ? { line } : {}),
    ...(title !== undefined ? { title } : {}),
    destination,
    ...(outDir !== undefined ? { outDir } : {}),
    ...(outFile !== undefined ? { outFile } : {}),
    ...(pdfFile !== undefined ? { pdfFile } : {}),
    ...(documentId !== undefined ? { documentId } : {}),
    ...(folderId !== undefined ? { folderId } : {}),
    ...(expectedVersion !== undefined ? { expectedVersion } : {}),
    accessTokenEnv,
    ...(destination === "bucket" ? { bucket } : {}),
    ...(configPath !== undefined ? { configPath } : {}),
    allowIndexing,
    replaceExisting,
    apply,
    format,
  };
}

function prepare(arguments_: PublishDocumentArguments): { publication: PreparedPublishedDocument; file: string; configPath?: string } {
  const file = path.resolve(arguments_.file);
  if (!fs.existsSync(file)) throw new Error(`File not found: ${file}`);
  const stat = fs.statSync(file);
  if (!stat.isFile()) throw new Error(`Not a file: ${file}`);
  const discoveredConfig = arguments_.configPath
    ? path.resolve(arguments_.configPath)
    : findConfigFile(path.dirname(file)) || undefined;
  const config = discoveredConfig ? loadConfig(discoveredConfig) : undefined;
  const sourceText = fs.readFileSync(file, "utf8");
  const publication = preparePublishedDocument({
    sourceText,
    sourcePath: file,
    ...(arguments_.line !== undefined ? { line: arguments_.line } : {}),
    ...(arguments_.title ? { title: arguments_.title } : {}),
    allowIndexing: arguments_.allowIndexing,
    linkAbbreviations: config?.links?.abbreviations,
    linearTeam: config?.links?.linearTeam,
  });
  return { publication, file, ...(discoveredConfig ? { configPath: discoveredConfig } : {}) };
}

function readPdfArtifact(pdfFile: string): Buffer {
  const bytes = fs.readFileSync(path.resolve(pdfFile));
  if (bytes.subarray(0, 5).toString("latin1") !== "%PDF-") throw new Error(`Not a PDF file: ${pdfFile}`);
  return bytes;
}

function redactionCount(publication: PreparedPublishedDocument): number {
  return Object.values(publication.redactions).reduce((sum, count) => sum + count, 0);
}

function atomicWriteBuffer(filePath: string, content: Buffer): void {
  const parent = path.dirname(filePath);
  fs.mkdirSync(parent, { recursive: true });
  const temporaryPath = path.join(
    parent,
    `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`,
  );
  try {
    fs.writeFileSync(temporaryPath, content, { mode: 0o644, flag: "wx" });
    fs.renameSync(temporaryPath, filePath);
  } finally {
    if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
  }
}

function printTextPreview(
  arguments_: PublishDocumentArguments,
  prepared: ReturnType<typeof prepare>,
  destination: Record<string, unknown>,
): void {
  const verb = arguments_.apply ? "published" : "would publish";
  console.log(`${verb}: ${prepared.publication.manifest.title}`);
  console.log(`source: ${prepared.file}${arguments_.line ? ` (subtree at line ${arguments_.line})` : ""}`);
  console.log(`artifact: ${prepared.publication.manifest.bytes} bytes, ${prepared.publication.assets.length} embedded image${prepared.publication.assets.length === 1 ? "" : "s"}`);
  console.log(`disclosure: ${redactionCount(prepared.publication)} private or unsafe element${redactionCount(prepared.publication) === 1 ? "" : "s"} removed`);
  if (arguments_.destination === "web") {
    console.log(`destination: web bundle at ${String(destination.outDir || arguments_.outDir)}`);
  } else if (arguments_.destination === "bucket") {
    const action = arguments_.bucket?.objectId ? "replace" : "new link in";
    console.log(`destination: ${action} bucket ${String(destination.bucket)} (${String(destination.mediaType)})`);
    if (destination.url) console.log(`url: ${String(destination.url)}`);
  } else if (arguments_.destination === "beamer-pdf") {
    console.log(`destination: Beamer PDF at ${String(destination.outFile || arguments_.outFile)}`);
  } else if (arguments_.documentId) {
    const lastObserved = arguments_.expectedVersion ? `; last observed Drive version ${arguments_.expectedVersion}` : "";
    console.log(`destination: ${googleDestinationLabel(arguments_.destination)} ${arguments_.documentId}; current ETag checked before replacement${lastObserved}`);
  } else {
    console.log(`destination: new ${googleDestinationLabel(arguments_.destination)}${arguments_.folderId ? ` in folder ${arguments_.folderId}` : ""}`);
  }
  for (const warning of prepared.publication.warnings) console.log(`warning: ${warning}`);
  if (!arguments_.apply) console.log("preview only; pass --apply to publish");
}

export async function runPublishDocumentCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "publish" || args[1] !== "document") return false;
  if (args.includes("--help") || args.includes("-h")) usage(0);
  const arguments_ = parseArguments(args);
  const prepared = prepare(arguments_);

  let destination: Record<string, unknown>;
  if (arguments_.destination === "bucket") {
    const bucket = arguments_.bucket ?? newBucketArguments();
    const target = bucketTarget(bucket);
    const pdfBytes = arguments_.pdfFile ? readPdfArtifact(arguments_.pdfFile) : undefined;
    const mediaType = pdfBytes ? PDF_MEDIA_TYPE : "text/html";
    const body = pdfBytes ?? Buffer.from(prepared.publication.html, "utf8");
    if (arguments_.apply) {
      destination = await publishArtifactToBucket({
        target,
        credentials: bucketCredentials(bucket),
        objectId: bucket.objectId,
        body,
        mediaType,
      });
    } else {
      const key = bucket.objectId ? bucketObjectKey(target, bucket.objectId, mediaType) : undefined;
      destination = {
        destination: "bucket",
        action: bucket.objectId ? "replace" : "create",
        ...(bucket.objectId ? { objectId: bucket.objectId } : {}),
        ...(key ? { key, url: bucketPublicUrl(target, key) } : { objectId: "assigned when published" }),
        mediaType,
        bytes: body.byteLength,
        bucket: target.bucket,
        endpoint: target.endpoint,
        publicBaseUrl: target.publicBaseUrl,
        cacheControl: BUCKET_CACHE_CONTROL,
        access: "anyone with the unguessable link; revoke by deleting the object",
      };
    }
  } else if (arguments_.destination === "web") {
    const outDir = path.resolve(arguments_.outDir || "");
    destination = arguments_.apply
      ? writeWebPublicationBundle(prepared.publication, { outDir, replaceExisting: arguments_.replaceExisting })
      : {
          destination: "web",
          action: fs.existsSync(outDir) && fs.readdirSync(outDir).length > 0 ? "replace" : "create",
          outDir,
          indexPath: path.join(outDir, "index.html"),
          manifestPath: path.join(outDir, "manifest.json"),
          requiresHosting: true,
          authentication: "enforced by the selected host; the bundle contains no corpus access",
        };
  } else if (arguments_.destination === "beamer-pdf") {
    const outFile = path.resolve(arguments_.outFile || "");
    const preparedBeamer = preparePublishedBeamer(prepared.publication.document);
    if (arguments_.apply) {
      const existed = fs.existsSync(outFile);
      if (existed && !arguments_.replaceExisting) {
        throw new Error(`Beamer PDF already exists: ${outFile}. Pass --replace-existing to update it.`);
      }
      const pdf = compilePublishedBeamerPdf(prepared.publication.document);
      atomicWriteBuffer(outFile, pdf.bytes);
      destination = {
        destination: "beamer-pdf",
        action: existed ? "replace" : "create",
        outFile,
        mediaType: pdf.mediaType,
        bytes: pdf.byteLength,
        artifactHash: pdf.sha256,
        slideCount: pdf.slideCount,
      };
    } else {
      destination = {
        destination: "beamer-pdf",
        action: fs.existsSync(outFile) ? "replace" : "create",
        outFile,
        mediaType: "application/pdf",
        sourceMediaType: "application/x-latex",
        sourceBytes: preparedBeamer.byteLength,
        sourceHash: preparedBeamer.sha256,
        slideCount: preparedBeamer.slideCount,
      };
    }
  } else {
    if (arguments_.apply) {
      const accessToken = String(brandEnv(arguments_.accessTokenEnv) || "").trim();
      if (!accessToken) throw new Error(`${googleDestinationLabel(arguments_.destination)} publishing requires ${arguments_.accessTokenEnv} in the environment`);
      destination = await publishToGoogleWorkspace(prepared.publication, arguments_.destination, {
        accessToken,
        ...(arguments_.pdfFile ? { pdfBytes: fs.readFileSync(path.resolve(arguments_.pdfFile)) } : {}),
        ...(arguments_.documentId ? { documentId: arguments_.documentId } : {}),
        ...(arguments_.folderId ? { folderId: arguments_.folderId } : {}),
        ...(arguments_.expectedVersion ? { expectedVersion: arguments_.expectedVersion } : {}),
        replaceExisting: arguments_.replaceExisting,
      });
    } else {
      const upload = arguments_.destination === "google-drive-pdf" && !arguments_.pdfFile
        ? undefined
        : prepareGoogleWorkspaceUpload(
            prepared.publication,
            arguments_.destination,
            arguments_.pdfFile ? fs.readFileSync(path.resolve(arguments_.pdfFile)) : undefined,
          );
      destination = {
        destination: arguments_.destination,
        action: arguments_.documentId ? "update" : "create",
        mimeType: googleTargetMediaType(arguments_.destination),
        ...(upload
          ? {
              inputMediaType: upload.mediaType,
              uploadBytes: upload.byteLength,
              artifactHash: upload.sha256,
            }
          : {
              inputMediaType: PDF_MEDIA_TYPE,
              renderingRequired: true,
            }),
        maxArtifactBytes: GOOGLE_DRIVE_MULTIPART_MAX_BYTES,
        requiredOAuthScope: GOOGLE_DRIVE_FILE_SCOPE,
        sharing: "Google Drive permissions are inherited and are not changed by this command",
        updateGuards: "the target must have no comments and its current ETag must still match when replacement begins",
        ...(arguments_.documentId ? { documentId: arguments_.documentId, expectedVersion: arguments_.expectedVersion } : {}),
        ...(arguments_.folderId ? { folderId: arguments_.folderId } : {}),
      };
    }
  }

  const payload = {
    $schema: "org2:publish-document-command-result:v1",
    applied: arguments_.apply,
    source: {
      file: prepared.file,
      selection: prepared.publication.manifest.selection,
      sourceHash: prepared.publication.sourceHash,
      ...(arguments_.line !== undefined ? { line: arguments_.line } : {}),
      ...(prepared.configPath ? { configPath: prepared.configPath } : {}),
    },
    artifact: {
      ...prepared.publication.manifest,
      projectionHash: prepared.publication.projectionHash,
      assets: prepared.publication.assets,
    },
    disclosure: {
      redactions: prepared.publication.redactions,
      warnings: prepared.publication.warnings,
    },
    destination,
  };
  if (arguments_.format === "json") console.log(JSON.stringify(payload, null, 2));
  else printTextPreview(arguments_, prepared, destination);
  return true;
}

/** `celorga publish bucket check|revoke`: verify a bucket target or delete a link's objects. */
export async function runPublishBucketCommand(args: string[]): Promise<boolean> {
  if (args[0] !== "publish" || args[1] !== "bucket") return false;
  const action = args[2];
  if (args.includes("--help") || args.includes("-h") || (action !== "check" && action !== "revoke")) {
    console.error(`Usage:\n${BUCKET_USAGE}\n\ncheck uploads a probe, reads it through --public-base-url, and deletes it.\nrevoke deletes every artifact stored for --object-id. Both preview by default.`);
    process.exit(action === undefined || args.includes("--help") || args.includes("-h") ? 0 : 1);
  }
  const bucket = newBucketArguments();
  let apply = false;
  let format: OutputFormat = "text";
  for (let index = 3; index < args.length; index += 1) {
    const next = parseBucketOption(args, index, bucket);
    if (next !== undefined) {
      index = next;
      continue;
    }
    const argument = args[index];
    if (argument === "--apply") apply = true;
    else if (argument === "--json") format = "json";
    else if (argument === "--format") {
      const value = requiredValue(args, index++, argument);
      if (value !== "text" && value !== "json") throw new Error("--format must be text or json");
      format = value;
    } else throw new Error(`Unknown publish bucket option: ${argument}`);
  }
  const target = bucketTarget(bucket);
  if (action === "revoke" && !bucket.objectId) throw new Error("publish bucket revoke requires --object-id ID");
  if (action === "check" && bucket.objectId) throw new Error("--object-id does not apply to publish bucket check");

  let result: Record<string, unknown>;
  if (!apply) {
    result = action === "check"
      ? { destination: "bucket", action: "check", plan: "upload a probe object, read it through the public base URL, then delete it" }
      : {
          destination: "bucket",
          action: "revoke",
          objectId: bucket.objectId,
          deletedKeys: [bucketObjectKey(target, bucket.objectId!, "text/html"), bucketObjectKey(target, bucket.objectId!, PDF_MEDIA_TYPE)],
        };
  } else if (action === "check") {
    result = await checkBucketTarget({ target, credentials: bucketCredentials(bucket) });
  } else {
    result = await revokeBucketPublication({ target, credentials: bucketCredentials(bucket), objectId: bucket.objectId! });
  }
  const payload = {
    $schema: "org2:publish-bucket-command-result:v1",
    applied: apply,
    target: { endpoint: target.endpoint, bucket: target.bucket, region: target.region, publicBaseUrl: target.publicBaseUrl, keyPrefix: target.keyPrefix },
    result,
  };
  if (format === "json") {
    console.log(JSON.stringify(payload, null, 2));
  } else if (!apply) {
    console.log(`would ${action === "check" ? "check" : "revoke"} bucket ${target.bucket} at ${target.endpoint}`);
    if (action === "revoke") console.log(`object: ${bucket.objectId}`);
    console.log("preview only; pass --apply to run");
  } else if (action === "check") {
    console.log(`bucket ${target.bucket}: writable`);
    console.log(result.publiclyReadable ? `public URL: readable (${target.publicBaseUrl})` : `public URL: NOT readable. ${String(result.detail || "")}`);
  } else {
    console.log(`revoked: ${bucket.objectId}`);
  }
  // JSON callers read publiclyReadable; text mode signals a failed check by exit status.
  if (apply && action === "check" && !result.publiclyReadable && format === "text") process.exitCode = 1;
  return true;
}
