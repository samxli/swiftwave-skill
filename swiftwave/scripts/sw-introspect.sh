#!/usr/bin/env bash
# Live GraphQL introspection snapshot. Re-run after SwiftWave upgrades.
# NOTE: stock SwiftWave v2 disables introspection ("introspection disabled").
# In that case this script exits non-zero and prints where to get the schema
# instead: the versioned *.graphqls files in the upstream repo, e.g.
#   https://github.com/swiftwave-org/swiftwave/tree/v2/swiftwave_service/graphql/schema
# Usage: ./sw-introspect.sh [<token>] [out.json]
# Token may be passed as first arg or via SW_TOKEN env (preferred).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == eyJ* ]]; then
  TOKEN="$1"; shift
else
  TOKEN="${SW_TOKEN:?usage: sw-introspect.sh [<token>] [out.json] (or set SW_TOKEN)}"
fi
OUT="${1:-schema.json}"

QUERY='{ __schema { queryType { name fields { name } } mutationType { name fields { name } } types { kind name } } }'

export SW_TOKEN="$TOKEN"
if ! "${SCRIPT_DIR}/sw-graphql.sh" "$QUERY" > "$OUT"; then
  echo "sw-introspect: query failed" >&2
  exit 1
fi
if grep -q "introspection disabled" "$OUT"; then
  echo "sw-introspect: server has introspection disabled." >&2
  echo "sw-introspect: use the versioned schema instead:" >&2
  echo "sw-introspect: https://github.com/swiftwave-org/swiftwave/tree/v2/swiftwave_service/graphql/schema" >&2
  exit 2
fi
echo "wrote $OUT"
