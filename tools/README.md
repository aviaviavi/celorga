# Celorga tools

## Coordinated Celorga releases

`release-openorg.mjs` is the resumable release orchestrator for npm, VS Code, notarized Apple Silicon and Intel DMGs, GitHub Releases, TestFlight, Scarf-backed downloads, and the generated site. It prints a read-only plan by default:

```bash
npm run release:openorg -- patch \
  --ios-build 25 \
  --notes /absolute/path/to/release-notes.md
```

Add `--execute` only after reviewing the plan. Long validation and packaging lanes run concurrently, each writes its own log under a per-version release directory under `/tmp/`, and successful phases are checkpointed in `state.json`. Validation jobs are checkpointed individually against a fingerprint of the release source tree, so retrying a failed lane preserves the successful build, docs, Node, VS Code, Swift, generated-artifact, and pack checks. Changing tracked or untracked release inputs invalidates those job checkpoints. `--restart` clears both phase and job checkpoints.

Release validation builds the shared runtime once, then uses the `*:built` checks to avoid rebuilding identical output between the docs, Node, and generated-artifact gates. Packaging needs only that build, so the arm64 DMG, Intel DMG, and iOS archive run concurrently with validation; nothing is tagged or published until both phases pass. Docs, Node, VS Code, and Swift validation run concurrently. The Node lane uses `run-tests-parallel.mjs`, and Swift test and release builds reuse persistent per-architecture SwiftPM scratch directories under `~/Library/Caches/` (override with `CELORGA_RELEASE_BUILD_CACHE`; discard with `--clean-build-cache`). Each DMG upload retries with backoff and is checkpointed separately, as is the TestFlight upload, so a resumed release never repeats a completed upload. The tag workflow still runs one independent `npm test` publication gate, but publishes the already-packed tarball with lifecycle scripts disabled so `prepublishOnly` does not repeat that full suite.

The normal iOS path passes `--skip-testflight-groups`: the orchestrator uploads the build, then the release operator uses the signed-in App Store Connect browser to set `What to Test`, attach both tester groups, and submit external beta review. API keys are not used for those distribution actions because App Store Connect may permit upload and reads while forbidding external-group or review mutations. macOS publication requires the existing `OPENORG_NOTARY_KEYCHAIN_PROFILE`, the Sparkle EdDSA signing key stored under the `org.org2.workspace` Keychain account, and `ORG2_GOOGLE_OAUTH_CLIENT_JSON` pointing at the protected Desktop OAuth client JSON. The release build reads that JSON without copying it into source and fails closed if the shared Google client is absent. Each release signs architecture-specific update feeds and publishes them with the site. Run `npm run release:openorg -- --help` for repair and partial-run options.

## iOS-only TestFlight beta

`ios-beta.mjs` archives and uploads only the iOS app, for example a feature-branch beta, without the npm, DMG, tag, or tester-group steps of the full release. It uses the same team (`9MW3N969TR`), TestFlight app, and ExportOptions as `release-openorg.mjs`, and it is read-only unless `--execute` is given:

```bash
node tools/ios-beta.mjs check --build 48            # offline preflight
node tools/ios-beta.mjs archive --build 48 --execute
node tools/ios-beta.mjs export  --build 48 --execute   # optional local .ipa, nothing uploaded
node tools/ios-beta.mjs upload  --build 48 --execute   # App Store Connect / TestFlight
```

Run archive and upload on the build Mac with Xcode 26 or later. Use the Apple account signed in under Xcode › Settings › Accounts, or an App Store Connect API key through `OPENORG_ASC_*`. Automatic signing with `-allowProvisioningUpdates` may enable App ID capabilities that the entitlements request, such as Push to Talk; that is an account change, so it is made by or for the account holder. The build number must be higher than every build already uploaded. After the upload, attach the build to a tester group in the App Store Connect browser. Printed commands mask API key identifiers.

## Parallel test runner

`npm test` builds once and uses `run-tests-parallel.mjs` with automatic retries disabled. The runner expands the leaves of `test:built` on a bounded worker pool, starts known-slow tests first, then runs wall-clock performance tests one at a time after the pool drains. The `&&` chains in `package.json` remain the canonical test list; `npm run test:serial` builds and runs that same list sequentially for debugging. `--report FILE` writes per-test timings.

The explicit `test:parallel` command and release validation retain one isolated retry for a failed leaf and report a passing retry as `FLAKY`; `--no-retry` disables that behavior.

```bash
npm test -- --jobs 4 --report /tmp/celorga-tests.json
npm run test:serial
```

## Native macOS test runner

`npm run test:macos` builds the shared runtime and Swift test binaries once,
then uses `run-swift-tests.mjs` to run SwiftPM's discovered correctness tests
on up to four workers. After the pool drains, the same timing selection runs
serially with `--skip-build`. These complementary `--skip` and `--filter`
selections preserve the full discovered suite. Failures remain failures;
there are no automatic retries. A failed build stops before testing.

```bash
npm run test:macos -- --jobs 4 --report /tmp/celorga-swift-tests.json
npm run test:macos:serial
node tools/run-swift-tests.mjs --skip-build --configuration debug
```

The JSON report records build and test phase durations separately. SwiftPM
retains its incremental debug cache; the runner uses native arm64 Swift on
Apple Silicon even when npm uses Intel Node under Rosetta. `--scratch-path`
and `--configuration release` select other caches without changing the test
partition. Add new wall-clock assertions to `SWIFT_TIMING_CASES` or
`SWIFT_TIMING_CLASSES` in the runner, including budgets hidden in helpers.
macOS CI uses this runner. Release validation shares its timing policy and
uses a smaller correctness pool while packaging and Node checks are active;
its timing phase still waits until concurrent work has finished.

## Documentation coverage check

`npm run docs:check` builds the CLI, verifies that every top-level help family is represented in `celorga agent capabilities`, and checks that the canonical agent/documentation entry points exist. GitHub Pages CI runs the same check before publishing.

## Generated artifact check

Verifies that source-controlled generated artifacts are current.

```bash
cd /path/to/celorga
npm run check:generated
```

The check rebuilds `dist/`, validates spec fixtures end-to-end, republishes the docs site, then fails if tracked generated outputs changed:

- `dist/` is TypeScript build output and is source-controlled for the npm CLI/package entrypoints.
- `site/` is the published HTML docs site generated from `docs/site/*.org` and source-controlled for static hosting.
- `spec/v0/tests/*.json` are compiled expected AST fixtures paired with `*.org` inputs and are source-controlled as executable spec data.

Disposable generated output should stay outside the repository, be ignored, or live in local corpus zones such as `compiled/` / `views/` unless it is intentionally promoted into a reviewed fixture or published artifact.

## Release download synchronization

`sync-release-downloads.mjs` reads GitHub Release assets, generates the canonical downloads page with Scarf Gateway links for Celorga disk images and registry links for the VS Code and npm packages, and maintains an idempotent direct-download block in GitHub release notes. Its default mode is read-only:

```bash
node tools/sync-release-downloads.mjs
```

Use `--apply-page` to update `docs/site/downloads.org`, `--apply-release-notes` for the authorized GitHub write, or `--check` as a no-drift gate. GitHub Releases remains the underlying artifact host.

## Fixture runner (spec v0)

Validates that each fixture pair exists and that the expected JSON conforms to the canonical AST schema.

Before fixture validation, `npm run fixtures` also runs
`tools/check-language-spec.mjs`. That check validates the normative
`GRAMMAR.ebnf` production graph, required contextual-rule sections in
`PARSING.org`, canonical AST references, and the shape of
`parsing-cases.json`. `test/test-language-spec.mjs` then runs every focused
ambiguity case against the production parser.

Run the language-contract checks independently with:

```bash
npm run check:language-spec
npm run test:language-spec
```

### Run (default: auto)

Auto mode will run end-to-end validation if the reference parser is available at `dist/parse.js`; otherwise it runs schema-only.

```bash
cd /path/to/celorga
npm test
```

### Run (schema-only)

```bash
cd /path/to/celorga
node tools/fixture-runner.mjs --schema-only
```

### Run (force end-to-end)

```bash
cd /path/to/celorga
npm install
npm run build
node tools/fixture-runner.mjs --e2e
```

Notes:
- Always validates:
  - every `spec/v0/tests/*.org` has a sibling `*.json` fixture (and vice versa)
  - each `*.json` conforms to `spec/v0/canonical-ast.schema.json`
- With `--e2e` it also parses `.org` → AST using the reference parser and compares it to the sibling `*.json` (exact match).

## Interactive performance regressions

`node test/test-cli-startup.mjs` checks that lightweight command families do not load the document/agenda CLI. `node test/test-inline-performance.mjs` exercises large plain and mixed-syntax paragraphs in the shared parser; `node test/test-ios-transcript.mjs` covers the same runtime through native JavaScriptCore plus mobile renderer/cache lifecycles. These tests are included in the normal suite.

Record the Node architecture with CLI timings. Intel Node under Rosetta has process-start overhead that does not measure the parser or command dispatcher itself. Compare before/after runs using the same executable and corpus.
