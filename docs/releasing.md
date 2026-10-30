# Releasing Talkless for macOS

Talkless is distributed directly, not through the Mac App Store. Releases contain Developer ID signed, notarized, stapled Apple Silicon ZIP and DMG artifacts. The authorized distribution repository is **`x2x3studio/talkless`**, the same repository as the source; no separate downloads repository is used or created.

## Release policy

These are the configured release paths, not a guarantee that the latest source changes have been published. A release requires successful validation, tests, signing, notarization and publication.

- A trusted push to `main` triggers the workflow to build and publish a **beta** prerelease.
- An explicit calendar-version tag (`v2026.1030.45296`) builds and publishes a **stable** release. Beta tags (`v2026.1030.45296-beta.BUILD`) are not stable triggers.
- `RELEASE_CHANNEL` defaults to `beta`; stable builds require `RELEASE_CHANNEL=stable`.
- Local `release-macos.sh` builds artifacts only. Local `publish-release.sh` defaults to a draft; the trusted workflow explicitly passes `--publish` and `PUBLIC_RELEASE_ACK=x2x3studio/talkless`.
- Self-hosted release jobs never execute pull-request code. The unique `talkless-macos-arm64` runner serializes full release jobs and preserves every queued main/tag request. Do not add another runner with this release label without a publication lock. GitHub concurrency groups are deliberately not used: they replace older pending runs even with cancellation disabled. Build numbers are assigned when a job actually starts.

## Required bilingual release notes

Before every beta or stable release, update both root changelogs: [CHANGELOG.md](../CHANGELOG.md) in English and [CHANGELOG.zh-Hans.md](../CHANGELOG.zh-Hans.md) in Simplified Chinese. Each must contain exactly one literal `## Unreleased` heading, kept in English in both files. Its body accepts only blank lines, optional `### ` headings and single-line `- ` plain-text bullets. Each heading must be followed by at least one bullet before another heading or the section end; each language needs at least one bullet. Inline Markdown, links, images and HTML are not rendered. Move older entries below another `## ` heading; only Unreleased is published.

Notes must be human-written and specific to the release. Before accessing signing credentials, the build rejects unchanged pending notes in either language against the most recent other local release tag containing that changelog. Keep local release tags available (CI uses `fetch-depth: 0`); this offline check cannot detect missing tags. Stable releases also need updated notes, not an unchanged beta copy.

Each build snapshots both languages into version/build/channel-specific `release-notes.md` and safely escaped `release-notes.html`. The HTML includes both language sections and local navigation, with no scripts or remote resources. GitHub's release body uses the same snapshot. Sparkle's standard update window loads the HTML through `sparkle:releaseNotesLink` at the immutable version-tag asset URL, not a mutable source changelog. Publication validates hashes, snapshot identity, HTML rendering and appcast links before network access. Previously built schema 1 artifacts remain supported; new schema 2 builds require both note files.

Source, tests and documentation remain English except the approved `en.lproj`/`zh-Hans.lproj` app string catalogs and root `CHANGELOG.zh-Hans.md`; do not put translations inline in Swift or English documentation.

## Prerequisites and current setup

An Apple Silicon Mac needs Xcode command-line tools, Swift compatible with `Package.swift`, 1Password CLI (`op`), and GitHub CLI (`gh`). Build/sign/install/publish tooling uses Shell plus the standalone Swift package in `Tools/ReleaseTool`, without Python. Separate audio regression tests and optional fixture generation still use Python. Use pinned package dependencies and a clean, committed checkout. Do not run another app build against the same checkout during a release.

The dedicated `talkless-mac-mini-arm64` runner is registered with labels `self-hosted`, `macOS`, `ARM64`, `talkless-macos-arm64`. It runs as a user LaunchAgent with its standard bundled Node runtime. Work directories, temporary files and caches use the internal disk. An external-SSD migration was reverted; no fixed-Node launcher or additional Full Disk Access grant is required. Mateo keeps its separate runner installation and service. Do not share working directories or move global developer caches.

The `validate` release job and the separate `Source checks` workflow run on GitHub-hosted `macos-15`; only the full `release` job runs on the dedicated Mac. A hosted-runner capacity notice does not indicate a problem with the self-hosted machine. Workflow actions use Node 24 (`actions/checkout@v7.0.1` and `actions/upload-artifact@v7.0.2`); keep the self-hosted Actions runner updated (at least 2.327.1 for Node 24).

Release configuration:

- Signing/notarization reference variables are configured to reuse the existing Developer ID and notarization account. Private material must never enter the repository or artifact uploads.
- A dedicated Talkless Sparkle key is stored in 1Password; its public key and private-key reference are configured as repository variables. Builds never generate or rotate update keys.
- The source repository is public by explicit owner authorization. Release scripts never change repository visibility.
- The stable and beta appcast assets are hosted on a published `updates` release. When bootstrapping distribution, the feeds can start as valid empty channels until the first application release is published. The script never creates this mutable feed release implicitly.

## Signing and secret references

The expected identity is:

```text
Developer ID Application: Shanghai Gotehab Information Technology Co., Ltd (AXJQF2CMF2)
Team ID: AXJQF2CMF2
```

Configure these **reference strings**, using GitHub Actions variables or a local, untracked environment. Their values point to the existing certificate/notarization items; no vault/item identifiers or credentials are hardcoded in the public scripts:

| Environment variable | Referenced field |
| --- | --- |
| `SIGNING_CERTIFICATE_REF` | `op://<vault>/<signing item>/p12_base64` |
| `SIGNING_PASSWORD_REF` | `op://<vault>/<signing item>/password` |
| `NOTARY_KEY_REF` | `op://<vault>/<notary item>/private_key` |
| `NOTARY_KEY_ID_REF` | `op://<vault>/<notary item>/key_id` |
| `NOTARY_ISSUER_REF` | `op://<vault>/<notary item>/issuer_id` |

The helper uses `OP_SERVICE_ACCOUNT_TOKEN` if already present. Otherwise it sources `$HOME/.config/secrets.zsh` in a separate noninteractive `zsh` process, capturing the token privately and discarding other output. It never edits that file. Credential-command output is suppressed, including on failure. Do not enable shell tracing around credentials.

Certificates, API keys, and any Sparkle key stay in a mode-restricted, uniquely owned temporary directory outside the project (`TMPDIR` is respected). A temporary keychain is passed explicitly with `codesign --keychain`; the user's keychain search list and default keychain are not changed. The imported certificate file is removed after import. Normal exit, exceptions, Ctrl-C, and SIGTERM clean up the session's keychain/directory. Forced termination or power loss may require manual cleanup of that session's `talkless-signing-*` directory/keychain and `dist/.release-lock`. Never delete unrelated keychains or temporary directories.

## Local signed build

Leave all five updater variables below unset to disable updater configuration:

```sh
unset UPDATE_FEED_URL BETA_UPDATE_FEED_URL SPARKLE_PUBLIC_KEY TALKLESS_SPARKLE_KEY_REF DOWNLOAD_BASE_URL
scripts/release-macos.sh 0.1.0 1
```

The workflow uses UTC calendar versions: `YEAR.(month * 100 + day).secondsSinceMidnight`, for example `2026.1030.45296`, generated by `bash scripts/release-tool.sh version`. This is not semantic versioning. The release helper accepts three non-negative numeric components (the small `0.1.0` values below are illustrative test inputs). `BUILD_NUMBER` is a positive integer of at most eighteen digits; the workflow uses an epoch-based number assigned when the serialized job starts. Version suffixes are not accepted: `RELEASE_CHANNEL` selects beta or stable. Actual tags look like `v2026.1030.45296-beta.1793363696` or `v2026.1030.45296`. Every build, including beta-to-stable promotion, needs a new, higher build number:

```sh
RELEASE_CHANNEL=stable scripts/release-macos.sh 0.1.0 2
```

The release helper passes this contract to the bundle-only `scripts/build-app.sh`:

```text
VERSION BUILD_NUMBER CONFIGURATION=release RELEASE_CHANNEL=beta|stable
CODE_SIGN_IDENTITY=<the Developer ID identity above>
SIGNING_KEYCHAIN=<temporary keychain path>
UPDATE_FEED_URL=<stable HTTPS feed URL or empty>
BETA_UPDATE_FEED_URL=<beta HTTPS feed URL or empty>
SPARKLE_PUBLIC_KEY=<base64 public key or empty>
output: dist/Talkless.app
```

The release helper then:

1. Verifies the app's signature, Developer ID authority, Team ID, secure timestamp, version/build, default update channel, and updater configuration.
2. Submits a temporary ZIP to Apple's notary service, requires `Accepted`, then staples/validates the app. Transient stapling failures retry up to 40 times.
3. Creates a DMG with the stapled app and `/Applications` shortcut, then signs, notarizes, staples, and validates it.
4. Creates the **final ZIP from the stapled app**, not from the pre-notarization archive. Only complete updater configuration enables Sparkle signing of this final ZIP.
5. Writes checksums and deterministic JSON metadata, then promotes the finished staging directory. Existing release output directories are never overwritten.

Artifacts in `dist/releases/0.1.0-1/` are:

- `Talkless-0.1.0-1-arm64.zip`
- `Talkless-0.1.0-1-arm64.dmg`
- `release-notes.md` and `release-notes.html` (bilingual snapshots for this version/build/channel)
- `SHA256SUMS` (ZIP, DMG, both note files, and generated feeds)
- `release-metadata.json` (schema 2; version/build/channel, commit, signing/notarization status, updater URLs, artifact sizes/hashes including both note files; no wall-clock fields or secrets)
- With updates enabled: `appcast-beta.xml` for beta; **both** `appcast.xml` and `appcast-beta.xml` for stable.

“Deterministic metadata” means stable serialization for the same inputs and final artifact bytes. Signing timestamps and notarization do not yield byte-for-byte reproducible archives. Never re-sign, repackage, staple, or otherwise modify final artifacts after checksums/appcast generation. Publishing rechecks hashes. Failed builds leave no promoted release directory; `dist/Talkless.app` may remain for diagnosis but is not itself a release artifact.

## Sparkle configuration

Set **all five** variables, or none. Partial configuration fails instead of silently shipping a broken updater:

```sh
export UPDATE_FEED_URL='https://github.com/x2x3studio/talkless/releases/download/updates/appcast.xml'
export BETA_UPDATE_FEED_URL='https://github.com/x2x3studio/talkless/releases/download/updates/appcast-beta.xml'
export SPARKLE_PUBLIC_KEY='<base64-encoded 32-byte Ed25519 public key>'
export TALKLESS_SPARKLE_KEY_REF='op://<vault>/<Talkless Sparkle item>/<private key field>'
export DOWNLOAD_BASE_URL='https://github.com/x2x3studio/talkless/releases/download/v0.1.0-beta.3'
scripts/release-macos.sh 0.1.0 3
```

URLs must use HTTPS without credentials, query strings, or fragments. Stable/beta feeds must be distinct. Do not use GitHub's `latest/download` for beta feeds: prereleases are excluded from latest-release selection. A draft's assets are not a functioning anonymous update feed.

The Sparkle secret must be its exported Ed25519 private-key text, not a PEM certificate/API key. `TALKLESS_SPARKLE_KEY_REF` has no default. The helper validates the public key's decoded 32-byte length and verifies the ZIP signature against that exact key using macOS CryptoKit. No keys are generated by builds.

Use `sign_update` from the pinned Sparkle distribution matching the app (currently 2.10.1). The helper searches `.build/artifacts/**/bin/sign_update`, or accepts `SPARKLE_SIGN_UPDATE=/absolute/path/to/bin/sign_update`. If SwiftPM's artifact omits CLI tools, separately obtain and verify the official pinned distribution and configure this path. Do not execute an unverified download or unrelated global Sparkle version. The signing interface is `sign_update --ed-key-file <temporary-key-file> -p <final-zip>`; private material is not passed inline on the command line. Each generated single-item feed includes version/build, minimum macOS version, ZIP URL, byte length, and EdDSA signature.

## Draft upload and explicit publication

The workflow supplies `GH_TOKEN` from the repository's `GITHUB_TOKEN` with `contents: write`; no cross-repository token is needed. Locally, authenticate `gh` for this repository. Even draft uploads to a public repository require the explicit acknowledgement:

```sh
PUBLIC_RELEASE_ACK=x2x3studio/talkless \
scripts/publish-release.sh dist/releases/0.1.0-1
```

To publish (the authorized trusted workflow does this explicitly):

```sh
RELEASE_REPOSITORY=x2x3studio/talkless \
PUBLIC_RELEASE_ACK=x2x3studio/talkless \
scripts/publish-release.sh dist/releases/0.1.0-1 --publish
```

`RELEASE_REPOSITORY` defaults to `x2x3studio/talkless` and no other repository is accepted. The script verifies hashes and repository visibility, creates/uploads a draft targeting the recorded commit, then publishes only with `--publish`. Beta releases have the prerelease flag and are not marked latest; stable releases are normal releases marked latest. Channel comes from immutable metadata, not a new environment override. Existing version releases are never overwritten.

For updater-enabled public releases, both feed URLs and the download base must match the same repository, the `updates` asset paths, and the exact version tag. The helper checks both existing feeds and rejects a build number not newer than either. Initially, both feeds may be valid RSS channels with zero items (treated as build zero), allowing stable-channel checks before the first stable release without a 404. It then:

1. Uploads and publishes the immutable version release/assets.
2. Replaces `updates/appcast-beta.xml` for beta, leaving stable untouched.
3. Replaces **both** feeds for stable, so beta subscribers also receive stable releases.

Feed manifests update last, after the download is publicly available. GitHub has no multi-asset atomic transaction: stable/beta feeds may briefly differ, and failure can leave only one advanced. Serialize publication and inspect both feeds on error. A rerun intentionally refuses to overwrite an existing immutable version release; finish only missing feed uploads manually after verifying hashes and build ordering. Interrupted publication may leave a draft or a published release with stale feeds; never rebuild different bytes under the same tag.

## Checks without credentials

```sh
bash -n scripts/release-macos.sh scripts/publish-release.sh
bash scripts/release-tool.sh --help
bash scripts/release-tool.sh check-repository
swift test --package-path Tools/ReleaseTool
```

A real release invocation is **not** a syntax test: it intentionally reads credentials, builds, and contacts Apple. Unit tests should mock subprocesses/1Password and cover version/channel validation, all-or-none updater configuration, XML escaping, hashes, and publication gates. Adding these tools does not by itself verify signing/notarization or publish a release.
