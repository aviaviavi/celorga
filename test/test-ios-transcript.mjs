import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { runInNewContext } from "node:vm";

// Exercise the actual shipped bundle with its strict filesystem shim on every
// platform. A source path supplies provenance, not permission to resolve files.
const mobileContext = {};
runInNewContext(readFileSync(resolve("apps/ios/Org2Mobile/Org2Mobile/Org2MobileDocument.js"), "utf8"), mobileContext);
const mobileRuntime = mobileContext.Org2MobileDocument;
const ordinaryNote = mobileRuntime.renderDocument("* Mobile note\nReadable offline content.\n", "notes/mobile.org");
assert.match(ordinaryNote.html, /Readable offline content/);
const embedReference = mobileRuntime.renderDocument("* Mobile host\n#+EMBED: file:source.org\n#+EMBED: id:source-heading\n", "notes/host.org");
assert.match(embedReference.html, /Live content is not included in this rendering/);
assert.match(embedReference.html, /target=file%3Asource.org/);
assert.match(embedReference.html, /target=id%3Asource-heading/);
assert.doesNotMatch(embedReference.html, /<iframe/);
console.log("Mobile document bundle renders source paths and embed references without filesystem access");

// Compile the actual iOS document, search, and markup policies without rebuilding the Mac app.
if (process.platform === "darwin") {
  const directory = mkdtempSync(join(tmpdir(), "org2-ios-transcript-test-"));
  try {
    const executable = join(directory, "transcript-regression");
    copyFileSync(resolve("apps/ios/Org2Mobile/Org2Mobile/Org2MobileDocument.js"), join(directory, "Org2MobileDocument.js"));
    const views = readFileSync(resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift"), "utf8");
    const citation = views.slice(views.indexOf("private struct MobileRemoteFileCitation:"), views.indexOf("struct CorpusFileBrowserView:"));
    const markup = views.slice(views.indexOf("private enum MobileRemoteMessageMarkup"), views.indexOf("private struct MobileRemoteRenderedMessageText:"));
    const markupTest = join(directory, "markup.swift");
    writeFileSync(markupTest, "import Foundation\nimport SwiftUI\n" + citation + markup + readFileSync(resolve("test/ios-link-markup-regression.swift"), "utf8"));
    for (const [command, args] of [
      ["xcrun", ["swiftc", "-parse-as-library", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileCorpusSearch.swift"), markupTest, "-o", executable]],
      [executable, []],
      ["xcrun", ["swiftc", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteTranscriptPage.swift"),
        resolve("test/ios-transcript-regression.swift"), "-o", executable]],
      [executable, []],
      ["xcrun", ["swiftc", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileCorpusSearch.swift"),
        resolve("test/ios-search-regression.swift"), "-o", executable]],
      [executable, []],
      ["xcrun", ["swiftc", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileCorpusSearch.swift"),
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileDocumentRuntime.swift"),
        resolve("test/ios-document-regression.swift"), "-o", executable]],
      [executable, []],
      ["xcrun", ["swiftc", "-parse-as-library", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileCaptureSupport.swift"),
        resolve("test/ios-capture-regression.swift"), "-o", executable]],
      [executable, []],
      ["xcrun", ["swiftc", "-swift-version", "6", "-O",
        resolve("apps/ios/Org2Mobile/Org2Mobile/MobileNotificationRouting.swift"),
        resolve("test/ios-notification-routing-regression.swift"), "-o", executable]],
      [executable, []],
    ]) {
      const result = spawnSync(command, args, { encoding: "utf8", timeout: command === "xcrun" ? 180_000 : 60_000 });
      assert.equal(result.status, 0, result.error?.message ?? `${result.stdout}\n${result.stderr}`);
      if (result.stdout) process.stdout.write(result.stdout);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
} else {
  console.log("iOS transcript runtime regressions require the macOS Swift toolchain");
}
