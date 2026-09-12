#!/usr/bin/env bash
# Login to SwiftWave REST auth and print JWT to stdout (nothing else).
# Usage: SW_USER=admin SW_PASS='...' ./sw-login.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

: "${SW_USER:?set SW_USER}"
: "${SW_PASS:?set SW_PASS}"

# shellcheck disable=SC2046
curl -fsS $(_sw_curl_flags) --max-time 30 -X POST "${SW_BASE_URL}/auth/login" \
  -F "username=${SW_USER}" -F "password=${SW_PASS}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
