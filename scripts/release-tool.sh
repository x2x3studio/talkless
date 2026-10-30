#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${TALKLESS_RELEASE_TOOL:-}" ]]; then
    swift build --package-path "$ROOT/Tools/ReleaseTool" --build-system native -c release >&2
    BIN="$(swift build --package-path "$ROOT/Tools/ReleaseTool" --build-system native -c release --show-bin-path)"
    export TALKLESS_RELEASE_TOOL="$BIN/ReleaseTool"
fi
exec "$TALKLESS_RELEASE_TOOL" --root "$ROOT" "$@"
