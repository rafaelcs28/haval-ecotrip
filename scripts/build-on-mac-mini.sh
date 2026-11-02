#!/usr/bin/env bash
set -euo pipefail
build_client=/usr/local/bin/mac-mini-build
test -x "$build_client" || { echo 'mac-mini-build is unavailable on this authorized coordinator.' >&2; exit 69; }
repo=$(git rev-parse --show-toplevel)
ref=${1:-HEAD}
commit=$(git -C "$repo" rev-parse "$ref^{commit}")
exec "$build_client" submit-git "$repo" android-debug "$commit"
