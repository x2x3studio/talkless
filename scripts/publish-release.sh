#!/bin/bash
# Default: draft only. Public uploads require PUBLIC_RELEASE_ACK; publishing also requires --publish.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 ]]; then
    printf '%s\n' 'Usage: scripts/publish-release.sh dist/releases/VERSION-BUILD_NUMBER [--publish]' >&2
    exit 2
fi
exec python3 -I "$ROOT/scripts/signing-session.py" publish "$@"
