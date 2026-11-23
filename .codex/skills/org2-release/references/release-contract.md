# Celorga release contract

## Public channels

- Repository: `aviaviavi/celorga`
- npm: `celorga`
- VS Code Marketplace: `AviPress.org2-vscode`
- Git tag: unprefixed SemVer, for example `0.4.1`
- GitHub Release assets:
  - `celorga-{version}.tgz`
  - `org2-vscode-{version}.vsix` (named after the Marketplace extension ID)
  - `Celorga.dmg` and `Celorga-Intel.dmg`

Releases before the Celorga rename used the pre-rename artifact names (`@aviaviavi/org2` on npm, `OpenOrg*.dmg`, `Org2Workspace*.dmg`); leave those historical assets and their download rows unchanged.

The iOS client is distributed separately through TestFlight. Its marketing version is coordinated with the desktop/CLI release, while its monotonically increasing build number remains separate.

## TestFlight

- App Store Connect app ID: `6797133238`
- Internal group: `Org2 Internal` (`f7462891-5b0e-4ccf-a3bc-2c2ea2f2540d`)
- External group: `OpenOrg Alpha` (`566e8d38-3c80-442c-8b9a-4f7916181149`)
- Public beta link: `https://testflight.apple.com/join/Yp3hfBng`

Run `tools/release-openorg.mjs` with `--skip-testflight-groups` for a normal iOS release. The orchestrator archives and uploads the client while Mac publication proceeds. Finish distribution in an existing signed-in App Store Connect browser session: wait for the exact version/build to process, set the English `What to Test` text, attach all existing TestFlight groups (including `Org2 Internal` and `OpenOrg Alpha`), enable automatic tester notifications unless the user specifies otherwise, and submit external beta review. Avi has given standing authorization for these TestFlight steps as part of a release; do not request a separate TestFlight approval.

Do not use API automation for TestFlight review details, external-group assignment, or beta-review submission. App Store Connect API roles can permit binary upload, build reads, localization updates, and internal assignment while returning security-forbidden errors for external distribution. The browser flow is the release contract, not an exceptional fallback.

Existing API credentials for binary upload and build-status reads use these non-committed environment variables:

- `OPENORG_ASC_ISSUER_ID`
- `OPENORG_ASC_KEY_ID`
- `OPENORG_ASC_PRIVATE_KEY_PATH`

When these existing-key references are configured, the orchestrator passes them to Xcode for archive signing and binary upload, including with `--skip-testflight-groups`. It checks for an already uploaded build before retrying publication; browser distribution remains separate. Partial key configuration fails during preflight instead of falling back to an unavailable saved Xcode login.

The private key stays outside the repository. Do not log it, copy it into release state, or add it to a corpus. The orchestrator stores only the resulting non-secret build ID and group IDs in its temporary checkpoint directory.

## Scarf Gateway

- Scarf owner: `org2`
- File Package: `org2-direct-download-artifacts`
- Package ID: `8f4f86e1-5e31-4c52-a6c7-ceae5b64913f`
- Default domain: `org2.gateway.scarf.sh`
- Route ID: `X3Eyp83Kad`
- Incoming path: `/downloads/{version}/{artifact}`
- Outgoing URL: `https://github.com/aviaviavi/celorga/releases/download/{version}/{artifact}`
- Public template: `https://org2.gateway.scarf.sh/downloads/{version}/{artifact}`

Scarf Gateway is a redirect and measurement layer only. GitHub Releases remains the underlying file host. Do not upload release binaries to Scarf or create a new Scarf package per version.

Use `SCARF_API_TOKEN` only for authenticated API reads or an explicitly authorized configuration repair. Never log, persist, or place the token in release files, docs, fixtures, or skill resources. The normal release workflow does not need the token because the route is already templated.

## Signing and hosting constraints

Configure macOS release inputs outside the repository:

- `OPENORG_NOTARY_KEYCHAIN_PROFILE`: the existing notarytool Keychain profile. The orchestrator and packager validate access with a read-only history request before compilation. Do not export or recreate stored credentials during a release.
- For an existing Apple API key in a protected file, use `OPENORG_NOTARY_PRIVATE_KEY_PATH` and `OPENORG_NOTARY_KEY_ID`, plus `OPENORG_NOTARY_ISSUER_ID` for a team key. These explicit references take precedence over a Keychain profile and allow a release when interactive Keychain access is unavailable. Key contents never enter plans, logs, source, or checkpoint files. This configures an existing credential; it does not create or rotate a key.
- `OPENORG_ARM64_NODE_PATH` and `OPENORG_X86_64_NODE_PATH`: native Node executables for each target architecture. Verify each with `process.arch` instead of inferring architecture from its filesystem location.
- `OPENORG_ARM64_WHISPER_CPP_PATH` and `OPENORG_X86_64_WHISPER_CPP_PATH`: target-native whisper.cpp executables when they are not discoverable automatically.
- `OPENORG_WHISPER_MODEL_PATH`: the verified shared `ggml-base.en.bin` model when it is not discoverable automatically.
- `ORG2_GOOGLE_OAUTH_CLIENT_JSON`: a protected Google OAuth Desktop client JSON path (default: `~/.config/celorga/google-oauth-client.json` with mode 0600 when present), or the paired `ORG2_GOOGLE_OAUTH_CLIENT_ID` and `ORG2_GOOGLE_OAUTH_CLIENT_SECRET` values. Never print the JSON or secret, commit it, or copy it into a release checkpoint.

Environment variable names and non-secret paths may be recorded in local operator configuration; secret contents stay in the Keychain or protected files. The release command must receive the configuration explicitly rather than guessing or logging candidate secrets.

- Build `Celorga.dmg` for Apple Silicon and `Celorga-Intel.dmg` for Intel (`x86_64`) with `tools/package-openorg-macos.mjs`.
- Bundle a native whisper.cpp executable and the verified English `base.en` model so dictation does not require Homebrew, a model download, or runtime environment variables. Keep macOS Speech only as a fallback.
- Require Developer ID signing, hardened runtime, Apple notarization, ticket stapling, and Gatekeeper verification for every Celorga DMG. The package command fails closed without a configured notarytool Keychain profile.
- Historical pre-notarization DMGs remain developer-signed but not notarized; say so plainly on their download page.
- Never build into, replace, or relaunch the daily app in `~/Applications` as part of release packaging.
- Build each macOS architecture with a distinct `CELORGA_WORKSPACE_SWIFT_SCRATCH_PATH`; parallel release builds must never share SwiftPM's mutable build directory.
- Preserve `/usr/bin`, `/bin`, `/usr/sbin`, and `/sbin` when customizing `PATH`; Gatekeeper verification requires `/usr/sbin/spctl`. A missing executable is an environment failure, not evidence that notarization failed.
- Attach all distributable files to the matching GitHub Release before synchronizing downloads.

## Publication recovery

The tag workflow treats VS Code Marketplace publication as non-blocking so npm or Marketplace outages cannot prevent GitHub Release asset attachment. If the Marketplace submission itself fails and the version is still absent, dispatch `.github/workflows/release-packages.yml` with `dry_run=false`, the existing `release_version`, and `publish_only=true`. This repair checks out the version tag and skips both the full test gate and npm publication. Do not use it to rebuild a changed candidate or to republish an existing registry version.

## Download synchronization

`tools/sync-release-downloads.mjs` reads published GitHub Releases and their assets. It manages:

1. `docs/site/downloads.org`, including the current release and historical artifact table.
2. A marker-delimited `Direct downloads` block in GitHub release bodies.

Default execution is preview-only. Use `--apply-page` for the repository source, `--apply-release-notes` for GitHub mutations, `--release VERSION` to restrict release-note updates, and `--check` for a no-drift gate.

The tag workflow applies the release-note block after npm and VSIX assets are attached. Run the tool again after uploading the DMG so the final block includes every artifact.

## Authoritative documentation

- Scarf File Packages and URL templates: https://docs.scarf.sh/packages/
- Scarf Gateway variables and redirect behavior: https://docs.scarf.sh/gateway/
- GitHub Release assets: https://docs.github.com/en/rest/releases/assets
- App Store Connect builds: https://developer.apple.com/documentation/appstoreconnectapi/builds
- Add builds to beta groups: https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betagroups-_id_-relationships-builds
- Submit beta app review: https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betaappreviewsubmissions
