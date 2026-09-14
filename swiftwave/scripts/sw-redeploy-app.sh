#!/usr/bin/env bash
# Redeploy an existing app with new code: re-upload the source, then
# updateApplication with the app's EXISTING config (env vars, volumes,
# replicas, caps, proxy config, health check) and only the code fields
# swapped. Ingress and domains are untouched.
# Usage: ./sw-redeploy-app.sh [<token>] <app-id|name> <dir|tar> [--no-wait] [timeout-secs]
# Token may be passed as first arg or via SW_TOKEN env (preferred).
#
# <dir|tar> is required for sourceCode apps (the new code). Git apps are
# refused — use rebuildApplication (the builder re-clones the branch; their
# updateApplication input fields are not reliably round-trippable).
# Image apps are refused too — rebuildApplication re-pulls the same tag.
# Waits up to <timeout-secs> (default 600) unless --no-wait / SW_NO_WAIT=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

USAGE='usage: sw-redeploy-app.sh [<token>] <app-id|name> <dir|tar> [--no-wait] [timeout-secs] (or set SW_TOKEN)'
if [[ "${1:-}" == eyJ* ]]; then
  SW_TOKEN="$1"; shift
fi
export SW_TOKEN="${SW_TOKEN:?$USAGE}"
IDENT="${1:?$USAGE}"; shift

SRC=""
TIMEOUT=600
NO_WAIT="${SW_NO_WAIT:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-wait) NO_WAIT=1; shift ;;
    --) shift; break ;;
    -*)
      echo "sw-redeploy-app: unknown flag '$1'" >&2; exit 2 ;;
    ''|*[!0-9]*)
      if [ -n "$SRC" ]; then
        echo "sw-redeploy-app: unexpected second source '$1'" >&2; exit 2
      fi
      SRC="$1"; shift ;;
    *) TIMEOUT="$1"; shift ;;
  esac
done

# 1. Resolve id-or-name and capture the live config (everything below is
# resubmitted as-is; only the code fields change later). configMounts
# content is included because ConfigMountInput.content is String! — it is
# secret-bearing, so never echo APP_JSON. buildArgs live on Deployment
# (not Application), hence via latestDeployment.
APP_JSON="$("${SCRIPT_DIR}/sw-graphql.sh" '{ applications(includeGroupedApplications: true) { id name hostname command latestDeployment { id upstreamType buildArgs { key value } } environmentVariables { key value } persistentVolumeBindings { persistentVolumeID mountingPath } configMounts { content mountingPath uid gid } capabilities sysctls resourceLimit { memoryMb } reservedResource { memoryMb } deploymentMode replicas preferredServerHostnames dockerProxyConfig { enabled permission { ping version info events auth secrets build commit configs containers distribution exec grpc images networks nodes plugins services session swarm system tasks volumes } } customHealthCheck { enabled test_command interval_seconds timeout_seconds start_period_seconds start_interval_seconds retries } } }' \
  | IDENT="$IDENT" python3 -c 'import json,os,sys
ident = os.environ["IDENT"]
d = json.load(sys.stdin)
if d.get("errors"):
    sys.exit("GraphQL error: %s" % d["errors"])
apps = (d.get("data") or {}).get("applications") or []
hit = [a for a in apps if a["id"] == ident or a["name"] == ident]
if not hit:
    sys.exit("no app matches %r" % ident)
if len(hit) > 1:
    sys.exit("multiple apps match %r" % ident)
print(json.dumps(hit[0]))')"

APP_ID="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
APP_NAME="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
UPSTREAM="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["latestDeployment"]; print(d["upstreamType"] if d else "none")')"
OLD_DEP="$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["latestDeployment"]; print(d["id"] if d else "")')"

case "$UPSTREAM" in
  image)
    echo "sw-redeploy-app: '$APP_NAME' is an image app — use: mutation { rebuildApplication(id: \"$APP_ID\") }" >&2
    exit 2 ;;
  sourceCode)
    if [ -z "$SRC" ]; then
      echo "sw-redeploy-app: sourceCode app needs the new code: sw-redeploy-app.sh $IDENT <dir|tar>" >&2
      exit 2
    fi ;;
  git)
    echo "sw-redeploy-app: '$APP_NAME' deploys from git — use: mutation { rebuildApplication(id: \"$APP_ID\") } (the builder re-clones the branch; updateApplication would need repositoryUrl/Branch/gitCredentialID, which are not reliably round-trippable)" >&2
    exit 2 ;;
  none)
    echo "sw-redeploy-app: '$APP_NAME' has no deployments yet — create it with sw-create-app.sh first" >&2
    exit 2 ;;
  *)
    echo "sw-redeploy-app: unknown upstreamType '$UPSTREAM'" >&2; exit 2 ;;
esac

echo "redeploying $APP_NAME ($APP_ID, upstreamType=$UPSTREAM; ingress/domains untouched)"

# 2. New dockerfile for sourceCode (the source may ship a changed one).
DOCKERFILE=""
TAR_FILE=""
if [ "$UPSTREAM" = "sourceCode" ]; then
  UPLOAD_JSON="$("${SCRIPT_DIR}/sw-upload-code.sh" "$SRC")"
  TAR_FILE="$(printf '%s' "$UPLOAD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["file"])')"
  GEN_VARS="$(python3 -c 'import json,sys; print(json.dumps({"in": {"sourceType": "sourceCode", "sourceCodeCompressedFileName": sys.argv[1]}}))' "$TAR_FILE")"
  GEN_RESP="$("${SCRIPT_DIR}/sw-graphql.sh" 'query ($in: DockerConfigGeneratorInput!) { dockerConfigGenerator(input: $in) { dockerFile } }' "$GEN_VARS")"
  DOCKERFILE="$(printf '%s' "$GEN_RESP" | python3 -c 'import json,sys
d = json.load(sys.stdin)
if d.get("errors"):
    sys.exit("GraphQL error: %s" % d["errors"])
print(d["data"]["dockerConfigGenerator"]["dockerFile"])')"
fi

# 3. updateApplication with the config round trip: reuse what the app has,
# swap sourceCodeCompressedFileName (+ dockerfile). Built in python3, never
# string interpolation (the Dockerfile text holds quotes/newlines).
PAYLOAD="$(APP_JSON="$APP_JSON" DOCKERFILE_TEXT="$DOCKERFILE" TAR_FILE="$TAR_FILE" UPSTREAM="$UPSTREAM" python3 <<'EOF'
import json, os
app = json.loads(os.environ["APP_JSON"])
dockerfile = os.environ["DOCKERFILE_TEXT"]
tar_file = os.environ["TAR_FILE"]
upstream = os.environ["UPSTREAM"]
inp = {
    "name": app["name"],
    "hostname": app["hostname"],
    "environmentVariables": app["environmentVariables"],
    "persistentVolumeBindings": app["persistentVolumeBindings"],
    "configMounts": app["configMounts"],
    "capabilities": app["capabilities"],
    "sysctls": app["sysctls"],
    "deploymentMode": app["deploymentMode"],
    "replicas": app["replicas"],
    "resourceLimit": app["resourceLimit"],
    "reservedResource": app["reservedResource"],
    "upstreamType": upstream,
    "command": app["command"],
    "preferredServerHostnames": app["preferredServerHostnames"],
    "dockerProxyConfig": app["dockerProxyConfig"],
    "customHealthCheck": app["customHealthCheck"],
    "buildArgs": (app.get("latestDeployment") or {}).get("buildArgs") or [],
}
if upstream == "sourceCode":
    inp["sourceCodeCompressedFileName"] = tar_file
    inp["dockerfile"] = dockerfile
print(json.dumps({
    "query": "mutation Redeploy($id: String!, $input: ApplicationInput!) { updateApplication(id: $id, input: $input) { id latestDeployment { id status } } }",
    "variables": {"id": app["id"], "input": inp},
}))
EOF
)"
# shellcheck disable=SC2046
RESP="$(curl -sS --fail-with-body $(_sw_curl_flags) --max-time 60 -X POST "${SW_BASE_URL}/graphql" \
  -H "Authorization: Bearer ${SW_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")"
DEP_ID="$(printf '%s' "$RESP" | python3 -c 'import json,sys
d = json.load(sys.stdin)
if d.get("errors"):
    sys.exit("GraphQL error: %s" % d["errors"])
dep = d["data"]["updateApplication"]["latestDeployment"]
print(dep["id"] if dep else "")')"
if [ -z "$DEP_ID" ]; then
  echo "sw-redeploy-app: updateApplication returned no deployment — response:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi
echo "app $APP_ID deployment $DEP_ID"

# 4. Wait — same trap as create: latestDeployment may still point at the
# previous deployment. If so, poll until the pointer moves, then wait on
# the new id (sw-wait-deployment refuses to guess terminal states itself).
if [ "$NO_WAIT" = "1" ]; then
  if [ "$DEP_ID" = "$OLD_DEP" ]; then
    # Pinning the wait to the old id would report instant false success.
    echo "sw-redeploy-app: warning: latestDeployment still points at the previous deployment — wait WITHOUT an expected id:" >&2
    echo "${SCRIPT_DIR}/sw-wait-deployment.sh \"$APP_ID\" \"$TIMEOUT\""
  else
    echo "${SCRIPT_DIR}/sw-wait-deployment.sh \"$APP_ID\" \"$TIMEOUT\" \"$DEP_ID\""
  fi
  exit 0
fi
if [ -n "$OLD_DEP" ] && [ "$DEP_ID" = "$OLD_DEP" ]; then
  echo "waiting for the new deployment pointer..." >&2
  ELAPSED=0
  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    DEP_ID="$("${SCRIPT_DIR}/sw-graphql.sh" "{ application(id: \"$APP_ID\") { latestDeployment { id } } }" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["application"]["latestDeployment"]; print(d["id"] if d else "")')"
    [ "$DEP_ID" != "$OLD_DEP" ] && break
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
  if [ "$DEP_ID" = "$OLD_DEP" ] || [ -z "$DEP_ID" ]; then
    echo "sw-redeploy-app: new deployment never appeared after ${TIMEOUT}s — check with sw-logs.sh runtime $APP_ID" >&2
    exit 1
  fi
  echo "new deployment $DEP_ID"
fi
exec "${SCRIPT_DIR}/sw-wait-deployment.sh" "$APP_ID" "$TIMEOUT" "$DEP_ID"
