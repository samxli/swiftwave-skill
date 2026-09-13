#!/usr/bin/env bash
# Destroy one app and its exclusive ingress wiring.
# Usage: ./sw-destroy-app.sh [<token>] <app-id|name> [--yes]
# Token may be passed as first arg or via SW_TOKEN env (preferred).
#
# Order (rule deletion is async): delete ingress rules -> poll until the
# app's ingressRules list is empty -> deleteApplication (retried once if
# the server still sees rules) -> remove captured domains ONLY when they
# have zero ingressRules AND zero redirectRules left (domains are
# shareable). Volumes are NEVER touched (permanent data loss) — bindings
# are printed and the script stops there.
# Destructive: requires --yes or an interactive [y/N] confirm.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

if [[ "${1:-}" == eyJ* ]]; then
  SW_TOKEN="$1"; shift
fi
export SW_TOKEN="${SW_TOKEN:?usage: sw-destroy-app.sh [<token>] <app-id|name> [--yes] (or set SW_TOKEN)}"
IDENT="${1:?usage: sw-destroy-app.sh [<token>] <app-id|name> [--yes]}"; shift
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    *) echo "sw-destroy-app: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

gql() { "${SCRIPT_DIR}/sw-graphql.sh" "$1" "${2:-null}"; }

# 1. Resolve id-or-name; capture rules, domains, bindings BEFORE deleting.
APP_JSON="$(gql '{ applications(includeGroupedApplications: true) { id name ingressRules { id domainId } persistentVolumeBindings { persistentVolumeID mountingPath } } }' \
  | IDENT="$IDENT" python3 -c 'import json,os,sys
ident = os.environ["IDENT"]
apps = json.load(sys.stdin)["data"]["applications"] or []
hit = [a for a in apps if a["id"] == ident or a["name"] == ident]
if not hit:
    sys.exit("no app matches %r" % ident)
if len(hit) > 1:
    sys.exit("multiple apps match %r" % ident)
print(json.dumps(hit[0]))')"
APP_ID="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
APP_NAME="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
RULE_IDS="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; print(" ".join(str(r["id"]) for r in json.load(sys.stdin)["ingressRules"]))')"
DOMAIN_IDS="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; print(" ".join(str(r["domainId"]) for r in json.load(sys.stdin)["ingressRules"] if r.get("domainId") is not None))')"
BINDINGS="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys
for b in json.load(sys.stdin)["persistentVolumeBindings"]:
    print("volume %s at %s" % (b["persistentVolumeID"], b["mountingPath"]))')"

echo "app: $APP_NAME (id $APP_ID)"
echo "ingress rules: ${RULE_IDS:-none}"
echo "domains via rules: ${DOMAIN_IDS:-none}"
if [ -n "$BINDINGS" ]; then
  echo "$BINDINGS (volumes are NEVER deleted by this script)"
fi

if [ "$YES" != "1" ]; then
  if [ ! -t 0 ]; then
    echo "sw-destroy-app: refusing without --yes on a non-interactive stdin" >&2; exit 2
  fi
  printf 'destroy app %s and its rules above? [y/N] ' "$APP_NAME"
  read -r ans
  case "$ans" in [yY][eE][sS]|[yY]) ;; *) echo "aborted"; exit 1 ;; esac
fi

# 2. Delete rules, then poll until the app's list is empty (async).
# shellcheck disable=SC2086
for rid in $RULE_IDS; do
  gql "mutation { deleteIngressRule(id: $rid) }" >/dev/null
  echo "deleteIngressRule($rid) sent"
done
if [ -n "$RULE_IDS" ]; then
  for _ in $(seq 1 12); do
    LEFT="$(gql "{ application(id: \"$APP_ID\") { ingressRules { id } } }" \
      | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["application"]["ingressRules"]))')"
    [ "$LEFT" = "0" ] && break
    sleep 5
  done
  [ "$LEFT" = "0" ] || { echo "sw-destroy-app: rules still present after ~60s — retry later" >&2; exit 1; }
  echo "ingress rules gone"
fi

# 3. Delete the app (one retry: the server may still see draining rules).
# GraphQL errors arrive as HTTP 200, so inspect the body, not the exit code.
STATE="$(gql "{ application(id: \"$APP_ID\") { id } }" 2>&1 || true)"
if printf '%s' "$STATE" | grep -q '"errors"'; then
  echo "app already gone (skipping to domain cleanup)"
else
  DEL="$(gql "mutation { deleteApplication(id: \"$APP_ID\") }" 2>&1 || true)"
  if printf '%s' "$DEL" | grep -q '"deleteApplication": *true'; then
    echo "deleteApplication($APP_ID) done"
  else
    sleep 10
    gql "mutation { deleteApplication(id: \"$APP_ID\") }" >/dev/null
    echo "deleteApplication($APP_ID) done on retry"
  fi
fi

# 4. Orphaned domains only: remove when zero ingress AND zero redirect rules.
# shellcheck disable=SC2086
for did in $DOMAIN_IDS; do
  INFO="$(gql "{ domain(id: $did) { id name ingressRules { id } redirectRules { id } } }" 2>/dev/null || true)"
  [ -n "$INFO" ] || continue
  DNAME="$(printf '%s' "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["domain"]["name"])' 2>/dev/null || true)"
  [ -n "$DNAME" ] || continue  # domain already gone
  NREFS="$(printf '%s' "$INFO" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["domain"]; print(len(d["ingressRules"]) + len(d["redirectRules"]))')"
  if [ "$NREFS" = "0" ]; then
    if [ "$YES" = "1" ]; then
      gql "mutation { removeDomain(id: $did) }" >/dev/null
      echo "removeDomain($did $DNAME): orphaned, removed"
    else
      echo "domain $DNAME (id $did) is now orphaned — re-run with --yes to remove it"
    fi
  else
    echo "domain $DNAME (id $did) still referenced ($NREFS rules) — kept"
  fi
done
echo "done"
