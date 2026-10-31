#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-text-revision-highlight-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/TextRevisionHighlight.swift" \
  "$ROOT/Tests/TextRevisionHighlightTests/TextRevisionHighlightTests.swift" \
  -o "$WORK/text-revision-highlight-tests"
"$WORK/text-revision-highlight-tests"
