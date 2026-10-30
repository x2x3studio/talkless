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
