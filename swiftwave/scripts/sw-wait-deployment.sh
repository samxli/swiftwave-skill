#!/usr/bin/env bash
# Poll an application's deployment until it reaches a terminal state.
# Usage: ./sw-wait-deployment.sh [<token>] <application-id> [timeout-secs] [expected-deployment-id]
# Token may be passed as first arg or via SW_TOKEN env (preferred).
#
# Pass the new deployment id from the create/update mutation response as
# expected-deployment-id. Without it, the script waits for latestDeployment
# to CHANGE first (the pointer still references the previous deployment
# right after an update) and then waits for the new one to go terminal.
# Exits 0 on "deployed", 1 on failed/stalled/stopped/cancelled/timeout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == eyJ* ]]; then
  export SW_TOKEN="$1"; shift
fi
APP_ID="${1:?usage: sw-wait-deployment.sh [<token>] <application-id> [timeout-secs] [expected-deployment-id]}"
TIMEOUT="${2:-600}"
EXPECTED="${3:-}"
INTERVAL=15
ELAPSED=0

fetch_state() {
  "${SCRIPT_DIR}/sw-graphql.sh" \
    "{ application(id: \"$APP_ID\") { latestDeployment { id status } } }" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["application"]["latestDeployment"]; print(d["id"], d["status"])'
}

# fetch_state with failure detection: an API failure (expired token,
# connectivity, app deleted mid-wait) must fail fast with one clear
# message, not spew tracebacks and silently retry until timeout.
fetch_state_or_die() {
  local state
  state="$(fetch_state 2>/dev/null || true)"
  if [ -z "$state" ]; then
    echo "sw-wait-deployment: API query failed (expired SW_TOKEN, connectivity, or app deleted) — re-login and retry" >&2
    exit 1
  fi
  printf '%s\n' "$state"
}

# Without an expected id, a terminal status on the first poll is
# ambiguous (likely the PREVIOUS deployment — the pointer flips
# asynchronously). Refuse to guess; ask for the deployment id.
if [ -z "$EXPECTED" ]; then
  read -r INIT_ID INIT_STATUS < <(fetch_state_or_die)
  case "$INIT_STATUS" in
    deployed|failed|stalled|stopped|cancelled)
      echo "sw-wait-deployment: latestDeployment is already '$INIT_STATUS' —" >&2
      echo "sw-wait-deployment: pass the new deployment id to wait for it explicitly" >&2
      exit 2
      ;;
  esac
fi

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  read -r DEP_ID STATUS < <(fetch_state_or_die)
  echo "deployment $DEP_ID status: $STATUS (${ELAPSED}s)"
  if [ -n "$EXPECTED" ]; then
    if [ "$DEP_ID" = "$EXPECTED" ]; then
      case "$STATUS" in
        deployed) exit 0 ;;
        failed|stalled|stopped|cancelled) exit 1 ;;
      esac
    fi
  else
    # No expected id (and first poll was non-terminal, so a transition is
    # in flight): only trust a terminal status once we have seen a
    # non-terminal state or the id change.
    case "$STATUS" in
      pending|deployPending|deploying) SEEN_ACTIVE=1 ;;
      deployed|failed|stalled|stopped|cancelled)
        if [ "${SEEN_ACTIVE:-0}" = "1" ] || [ "$DEP_ID" != "$INIT_ID" ]; then
          [ "$STATUS" = "deployed" ] && exit 0 || exit 1
        fi
        ;;
    esac
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo "sw-wait-deployment: timed out after ${TIMEOUT}s" >&2
exit 1
