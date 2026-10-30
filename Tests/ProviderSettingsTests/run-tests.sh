#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-provider-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/LLMProtocol.swift" \
  "$ROOT/Sources/Talkless/LLMAPITransport.swift" \
  "$ROOT/Sources/Talkless/LLMClient.swift" \
  "$ROOT/Sources/Talkless/PolishProvider.swift" \
  "$ROOT/Sources/Talkless/CredentialStore.swift" \
  "$ROOT/Sources/Talkless/HUDAppearance.swift" \
  "$ROOT/Sources/Talkless/Settings.swift" \
  "$ROOT/Tests/ProviderSettingsTests/HUDAppearanceTests.swift" \
  "$ROOT/Tests/ProviderSettingsTests/ProviderSettingsTests.swift" \
  -o "$WORK/provider-settings-tests"
"$WORK/provider-settings-tests"
