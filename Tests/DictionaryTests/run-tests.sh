#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/talkless-dictionary-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Talkless/L10n.swift" \
  "$ROOT/Sources/Talkless/LLMProtocol.swift" \
  "$ROOT/Sources/Talkless/LLMAPITransport.swift" \
  "$ROOT/Sources/Talkless/LLMClient.swift" \
  "$ROOT/Sources/Talkless/PolishProvider.swift" \
  "$ROOT/Sources/Talkless/CredentialStore.swift" \
  "$ROOT/Sources/Talkless/HUDAppearance.swift" \
  "$ROOT/Sources/Talkless/TranslationShortcut.swift" \
  "$ROOT/Sources/Talkless/TranslationLanguages.swift" \
  "$ROOT/Sources/Talkless/Settings.swift" \
  "$ROOT/Sources/Talkless/DictionaryTerms.swift" \
  "$ROOT/Sources/Talkless/History.swift" \
  "$ROOT/Sources/Talkless/DictationActivity.swift" \
  "$ROOT/Sources/Talkless/DictionaryReview.swift" \
  "$ROOT/Sources/Talkless/DictionaryView.swift" \
  "$ROOT/Tests/DictionaryTests/DictionaryTests.swift" \
  -o "$WORK/dictionary-tests"
"$WORK/dictionary-tests" "$@"
