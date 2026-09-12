#!/usr/bin/env bash
# Authenticated GraphQL POST.
# Usage: ./sw-graphql.sh [<token>] <query> [vars-json]
# Token may be passed as first arg or via SW_TOKEN env (preferred — avoids
# leaking the JWT through the process list).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

# A JWT starts with "eyJ" (base64 header); a query starts with {, query, mutation.
if [[ "${1:-}" == eyJ* ]]; then
  TOKEN="$1"; shift
else
  TOKEN="${SW_TOKEN:?usage: sw-graphql.sh [<token>] <query> [vars-json] (or set SW_TOKEN)}"
fi
QUERY="${1:?usage: sw-graphql.sh [<token>] <query> [vars-json]}"
VARS="${2:-null}"

# python3 is guaranteed by sw-env.sh dep check; avoids a hard jq dependency.
PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1], "variables": json.loads(sys.argv[2]) if sys.argv[2] != "null" else None}))' "$QUERY" "$VARS")"

# --fail-with-body (curl 7.76+): non-zero exit on HTTP errors but still
# prints the server's error body — essential for diagnosing 401s
# (expired JWT) and 400s server-side. (Do NOT combine with -f.)
# shellcheck disable=SC2046
curl -sS --fail-with-body $(_sw_curl_flags) --max-time 30 -X POST "${SW_BASE_URL}/graphql" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"
