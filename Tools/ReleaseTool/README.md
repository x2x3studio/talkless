# ReleaseTool

One standalone Swift 6 command-line package for structured release operations. It has no external package dependencies and is not linked into Talkless.

The existing Shell entrypoints remain unchanged:

```sh
bash scripts/build-app.sh
bash scripts/install-local.sh
bash scripts/release-macos.sh VERSION BUILD_NUMBER
bash scripts/publish-release.sh dist/releases/VERSION-BUILD_NUMBER --publish
```

They call `scripts/release-tool.sh`, which builds this tool once and passes the executable path to nested build steps. Shell orchestrates Xcode/Metal commands; Swift owns plist/JSON/XML handling, calendar versions, hashes, Ed25519 verification, secret-session lifetime, publication policy and local rollback. No Python is used by build/sign/install/publish paths.

```sh
bash scripts/release-tool.sh --help
bash scripts/release-tool.sh check-repository
swift test --package-path Tools/ReleaseTool
```

The package manifest uses Swift tools 6.0 for compatibility with hosted macOS validation runners; release builds still use the project's selected Swift 6.4 toolchain. Pull-request validation stays on GitHub-hosted runners without signing credentials. Trusted release jobs remain on the dedicated self-hosted runner.

Credential command output is never printed. The temporary keychain is never added to global search lists. SIGINT/SIGTERM request cancellation of the active subprocess and unwind cleanup; cleanup commands ignore the cancellation latch. As with all process cleanup, SIGKILL/power loss cannot run deferred cleanup. Local installation keeps the previous application only until a successful replacement; failed rollback preserves the only original rather than deleting it.

Tests mock 1Password, signing, notarization and GitHub publication. Real release verification is separate; running unit tests never publishes a release.

## Human-written release notes

Before **every beta or stable release**, update both root changelogs: `CHANGELOG.md` (English) and `CHANGELOG.zh-Hans.md` (Simplified Chinese). Each must have a single `## Unreleased` section with human-written user-facing changes for that release. Keep this structural heading in English in both files; section titles and bullets use the corresponding language. Each accepts optional `###` section headings and single-line `- ` plain-text bullets; at least one bullet is required in each language. Inline Markdown, links, images and HTML are not rendered. Move older notes below another `##` heading when preparing the next release; only `Unreleased` is published. Do not copy the same generic notes forward.

Release builds read both notes sources before accessing signing credentials and reject unchanged pending notes in either language compared with the most recent other local release tag containing that source. Use a full checkout with release tags (the release workflow already uses `fetch-depth: 0`); this check makes no network requests and cannot detect tags absent from the checkout. The first notes-enabled release supports older tags without a changelog. Stable releases also require reviewed, updated pending notes rather than silently reusing beta text.

Each build snapshots both languages with its version, channel and build into one bilingual `release-notes.md` and one safely escaped, self-contained `release-notes.html`. The HTML has English and Simplified Chinese sections marked with `lang`, plus local language-navigation links; it uses no JavaScript or remote resources. Schema 2 metadata and `SHA256SUMS` include both files in the exact artifact allowlist. Publication verifies their hashes, canonical safe rendering and the appcast's tagged HTML link before making any network request. Previously built schema 1 artifacts remain supported without notes; new builds always require schema 2 notes.

Both stable and beta appcasts use `sparkle:releaseNotesLink` to the immutable HTML asset under that release's download URL, not a GitHub Markdown page or mutable `Unreleased` file. The GitHub release body uses the same snapshot with Markdown/HTML metacharacters escaped. All immutable assets, including notes, are uploaded to the new draft before it is made public; only then are mutable appcasts uploaded to `updates`. Existing release assets are never overwritten. Notes are not fetched during build or publication. Archive signing, notarization, public-release acknowledgement and feed monotonicity checks are unchanged.
