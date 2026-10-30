#!/bin/bash
# Install a local, Developer ID signed build without publishing or notarizing.
# Quit Talkless first. Existing permissions and application data are not reset.
# Signing references and public updater settings default to GitHub repository variables.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/scripts/release-tool.sh" local-install "$@"
