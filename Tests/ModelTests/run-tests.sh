#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-model-core.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/ModelCatalog.swift" \
  "$ROOT/Sources/Talkless/ModelDownloader.swift" \
  "$ROOT/Sources/Talkless/ModelManager.swift" \
  "$ROOT/Tests/ModelTests/ModelCoreTests.swift" \
  -o "$WORK/model-core-tests"
"$WORK/model-core-tests"
