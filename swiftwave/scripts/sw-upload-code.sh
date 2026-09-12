#!/usr/bin/env bash
# Tar a directory (or reuse a .tar) and POST to /upload/code.
# Usage: ./sw-upload-code.sh [<token>] <dir|file.tar>
# Token may be passed as first arg or via SW_TOKEN env (preferred).
#
# IMPORTANT: SwiftWave expects the Dockerfile at the TAR ROOT. A directory
# is archived by its CONTENTS (tar -C dir .), never as a parent folder —
# archiving the folder itself nests everything one level deep and the
# build fails with "failed to build the image".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

if [[ "${1:-}" == eyJ* ]]; then
  TOKEN="$1"; shift
else
  TOKEN="${SW_TOKEN:?usage: sw-upload-code.sh [<token>] <dir|file.tar> (or set SW_TOKEN)}"
fi
SRC="${1:?usage: sw-upload-code.sh [<token>] <dir|file.tar> (or set SW_TOKEN)}"

TAR_FILE="$SRC"
TMP_TAR=""
if [ -d "$SRC" ]; then
  if [ ! -f "$SRC/Dockerfile" ]; then
    echo "sw-upload-code: warning: no Dockerfile at $SRC/Dockerfile" >&2
  fi
  TMP_TAR="$(mktemp --suffix=.tar)"
  tar -cf "$TMP_TAR" -C "$SRC" .
  TAR_FILE="$TMP_TAR"
fi

cleanup() { [ -n "$TMP_TAR" ] && rm -f "$TMP_TAR"; }
trap cleanup EXIT

# The server rejects the upload unless Content-Type is application/x-tar.
# shellcheck disable=SC2046
curl -fsS $(_sw_curl_flags) --max-time 60 -X POST "${SW_BASE_URL}/upload/code" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "file=@${TAR_FILE};type=application/x-tar"
