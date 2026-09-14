#!/usr/bin/env bash
# One-shot source-code deploy: upload tar -> dockerConfigGenerator ->
# createApplication -> wait for deployment.
# Usage: ./sw-create-app.sh [<token>] <name> <dir|tar> [-e KEY=VALUE|@file]... [--no-wait] [timeout-secs]
# Token may be passed as first arg or via SW_TOKEN env (preferred).
# -e flags become environmentVariables (repeatable, KEY=VALUE, split on first =).
# -e @<file> reads KEY=VALUE lines from a file instead — use it for secrets
# so passwords never appear in the process list (only the file path does).
# Default: waits up to 600s via sw-wait-deployment.sh; --no-wait skips and
# prints the wait command instead.
# Defaults: replicated / 1 replica / 512 MB limit / 128 MB reserved (flags
# for these can be added when a real deployment needs different values).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

if [[ "${1:-}" == eyJ* ]]; then
  SW_TOKEN="$1"; shift
fi
export SW_TOKEN="${SW_TOKEN:?usage: sw-create-app.sh [<token>] <name> <dir|tar> [-e KEY=VALUE|@file]... [--no-wait] [timeout-secs] (or set SW_TOKEN)}"
NAME="${1:?usage: sw-create-app.sh [<token>] <name> <dir|tar> [-e KEY=VALUE|@file]... [--no-wait] [timeout-secs]}"; shift
SRC="${1:?usage: sw-create-app.sh [<token>] <name> <dir|tar> [-e KEY=VALUE|@file]... [--no-wait] [timeout-secs]}"; shift

NO_WAIT=0
TIMEOUT=600
ENV_LIST=""
# Append KEY=VALUE lines from a file (blank lines, #-comments, and lines
# without = skipped; surrounding quotes stripped) — same style as sw-env.sh.
load_env_file() {
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    case "$line" in *=*) ;; *) continue ;; esac
    _val="${line#*=}"
    case "$_val" in
      \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
      \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
    esac
    ENV_LIST="${ENV_LIST}${line%%=*}=$_val"$'\n'
  done < "$1"
  unset _val 2>/dev/null || true
}
load_env_arg() {
  case "$1" in
    @*)
      _ef="${1#@}"
      if [ ! -f "$_ef" ]; then
        echo "sw-create-app: env file '$_ef' not found" >&2; exit 2
      fi
      load_env_file "$_ef"
      unset _ef 2>/dev/null || true ;;
    *)
      ENV_LIST="${ENV_LIST}$1"$'\n' ;;
  esac
}
while [ $# -gt 0 ]; do
  case "$1" in
    -e)
      load_env_arg "${2:?usage: -e KEY=VALUE|@file}"; shift 2 ;;
    -e?*)
      load_env_arg "${1#-e}"; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --) shift; break ;;
    -*)
      echo "sw-create-app: unknown flag '$1'" >&2; exit 2 ;;
    *)
      case "$1" in
        ''|*[!0-9]*) echo "sw-create-app: unexpected arg '$1' (timeout must be seconds)" >&2; exit 2 ;;
        *) TIMEOUT="$1"; shift ;;
      esac ;;
  esac
done

# 1. Upload — stdout is {"file":"<uuid>.tar"}.
UPLOAD_JSON="$("${SCRIPT_DIR}/sw-upload-code.sh" "$SRC")"
TAR_FILE="$(printf '%s' "$UPLOAD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["file"])')"

# 2. Dockerfile text round trip (server echoes the effective Dockerfile).
GEN_VARS="$(python3 -c 'import json,sys; print(json.dumps({"in": {"sourceType": "sourceCode", "sourceCodeCompressedFileName": sys.argv[1]}}))' "$TAR_FILE")"
GEN_RESP="$("${SCRIPT_DIR}/sw-graphql.sh" 'query ($in: DockerConfigGeneratorInput!) { dockerConfigGenerator(input: $in) { dockerFile } }' "$GEN_VARS")"
DOCKERFILE="$(printf '%s' "$GEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["dockerConfigGenerator"]["dockerFile"])')"

# 3. Create — variables JSON built in python3 (never string interpolation:
# the Dockerfile text holds quotes/newlines). See references/application-input.md.
PAYLOAD="$(DOCKERFILE_TEXT="$DOCKERFILE" python3 - "$NAME" "$TAR_FILE" "$ENV_LIST" <<'EOF'
import json, os, sys
name, tar_file, env_list = sys.argv[1], sys.argv[2], sys.argv[3]
dockerfile = os.environ["DOCKERFILE_TEXT"]
envs = []
for line in env_list.splitlines():
    if not line.strip():
        continue
    k, _, v = line.partition("=")
    envs.append({"key": k, "value": v})
permission = {k: "none" for k in (
    "ping", "version", "info", "events", "auth", "secrets", "build",
    "commit", "configs", "containers", "distribution", "exec", "grpc",
    "images", "networks", "nodes", "plugins", "services", "session",
    "swarm", "system", "tasks", "volumes")}
variables = {"input": {
    "name": name,
    "hostname": name,
    "environmentVariables": envs,
    "persistentVolumeBindings": [],
    "configMounts": [],
    "capabilities": [],
    "sysctls": [],
    "dockerfile": dockerfile,
    "buildArgs": [],
    "deploymentMode": "replicated",
    "replicas": 1,
    "resourceLimit": {"memoryMb": 512},
    "reservedResource": {"memoryMb": 128},
    "upstreamType": "sourceCode",
    "command": "",
    "sourceCodeCompressedFileName": tar_file,
    "preferredServerHostnames": [],
    "dockerProxyConfig": {"enabled": False, "permission": permission},
    "customHealthCheck": {"enabled": False, "test_command": "",
        "interval_seconds": 30, "timeout_seconds": 10,
        "start_period_seconds": 10, "start_interval_seconds": 5,
        "retries": 3},
}}
print(json.dumps({
    "query": "mutation CreateApp($input: ApplicationInput!) { createApplication(input: $input) { id name latestDeployment { id status } } }",
    "variables": variables,
}))
EOF
)"
# shellcheck disable=SC2046
RESP="$(curl -sS --fail-with-body $(_sw_curl_flags) --max-time 60 -X POST "${SW_BASE_URL}/graphql" \
  -H "Authorization: Bearer ${SW_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")"
APP_ID="$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["createApplication"]["id"])')"
DEP_ID="$(printf '%s' "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["createApplication"]["latestDeployment"]; print(d["id"] if d else "")')"
echo "app $APP_ID deployment $DEP_ID"

# 4. Wait (default) or print the wait command.
if [ "$NO_WAIT" = "1" ]; then
  echo "${SCRIPT_DIR}/sw-wait-deployment.sh \"$APP_ID\" \"$TIMEOUT\" \"$DEP_ID\""
else
  exec "${SCRIPT_DIR}/sw-wait-deployment.sh" "$APP_ID" "$TIMEOUT" "$DEP_ID"
fi
