#!/bin/bash
set -euo pipefail

# Explicit opt-in only. The default path does not compile or send requests.
if [[ "${TALKLESS_RUN_LIVE_TESTS:-}" != "1" ]]; then
  printf '%s\n' 'SKIP: live polishing tests require TALKLESS_RUN_LIVE_TESTS=1.'
  exit 0
fi
if [[ -z "${TALKLESS_TEST_BASE_URL:-${ANTHROPIC_BASE_URL:-}}" || -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  printf '%s\n' 'ERROR: set TALKLESS_TEST_BASE_URL or ANTHROPIC_BASE_URL, and ANTHROPIC_AUTH_TOKEN.' >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/.build/PolishIntegration"
umask 077
mkdir -p "$WORK"
REPORT="${TALKLESS_LIVE_REPORT:-results.json}"
if [[ ! "$REPORT" =~ ^[A-Za-z0-9_-]+\.json$ || -e "$WORK/$REPORT" ]]; then
  printf '%s\n' 'ERROR: TALKLESS_LIVE_REPORT must be a new simple .json filename; existing reports are never overwritten.' >&2
  exit 2
fi
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/LLMProtocol.swift" \
  "$ROOT/Sources/Talkless/LLMAPITransport.swift" \
  "$ROOT/Sources/Talkless/LLMClient.swift" \
  "$ROOT/Sources/Talkless/Prompts.swift" \
  "$ROOT/Tests/PolishIntegration/main.swift" \
  -o "$WORK/polish-integration"
"$WORK/polish-integration" "$WORK/$REPORT"
