#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-dictionary-highlight-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/DictionaryHighlight.swift" \
  "$ROOT/Tests/DictionaryHighlightTests/DictionaryHighlightTests.swift" \
  -o "$WORK/dictionary-highlight-tests"
"$WORK/dictionary-highlight-tests"
