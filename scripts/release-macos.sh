#!/bin/bash
# Build local release artifacts. This does not publish anything.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 2 ]]; then
    printf '%s\n' 'Usage: scripts/release-macos.sh VERSION BUILD_NUMBER' >&2
    exit 2
fi
exec bash "$ROOT/scripts/release-tool.sh" release "$@"
