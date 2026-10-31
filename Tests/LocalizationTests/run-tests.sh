#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-localization-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Tests/LocalizationTests/LocalizationTests.swift" \
  -o "$WORK/localization-tests"
# Run away from the checkout to exercise the standalone source-relative resource lookup.
(cd "$WORK" && "$WORK/localization-tests" "$ROOT/Sources/Talkless")

# Build a tiny real SwiftPM target; never replace its generated Bundle.module.
python3 -I "$ROOT/Tests/LocalizationTests/run-bundle-tests.py"
