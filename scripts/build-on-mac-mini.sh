#!/usr/bin/env bash
set -euo pipefail
command -v mac-mini-build >/dev/null 2>&1 || { echo 'mac-mini-build is unavailable on this authorized coordinator.' >&2; exit 69; }
repo=$(git rev-parse --show-toplevel)
ref=${1:-HEAD}
commit=$(git -C "$repo" rev-parse "$ref^{commit}")
exec mac-mini-build submit-git "$repo" android-debug "$commit"
