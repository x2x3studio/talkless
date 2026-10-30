#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-api-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/LLMProtocol.swift" \
  "$ROOT/Sources/Talkless/LLMAPITransport.swift" \
  "$ROOT/Sources/Talkless/LLMClient.swift" \
  "$ROOT/Tests/APITests/APITests.swift" \
  -o "$WORK/api-tests"
"$WORK/api-tests"
