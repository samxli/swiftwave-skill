#!/usr/bin/env bash
# Read-only health check for a SwiftWave instance (co-located OR remote).
# Checks API reachability, validates the image-registry URL that the
# in-cluster builder tags images with (a broken registry URL makes every
# git/sourceCode build fail INSTANTLY with "Failed to build docker image"
# and zero stream lines in deployment_logs), and — with SW_TOKEN set —
# reports server/swarm status via GraphQL.
# Usage: SW_TOKEN=... ./sw-doctor.sh   (token optional; enables server check)
# Remote mode is auto-detected from SW_HOST (see sw-env.sh). Override the
# registry address in remote mode with SW_REGISTRY_ADDR=<host:port>.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# 1. API reachable (daemon answers 302 redirect to /dashboard when healthy)
if curl -fsS $(_sw_curl_flags) --max-time 10 -o /dev/null "${SW_BASE_URL}/"; then
  pass "API reachable at ${SW_BASE_URL}"
else
  fail "API not reachable at ${SW_BASE_URL} (check service + SW_SCHEME + firewall on port ${SW_PORT})"
fi

# 2. Derived registry URL valid (mirrors GetRegistryURL + tunnelling logic).
#    Co-located root: derive from /var/lib/swiftwave/config.yml. Remote:
#    the config file is unreachable — probe SW_REGISTRY_ADDR (default
#    <SW_HOST>:3334) directly; that is the address a remote `docker push`
#    must reach and the builder tags against (when tunnelling is off).
CONFIG="${SW_CONFIG:-/var/lib/swiftwave/config.yml}"
REG_URL=""
if [ -r "$CONFIG" ]; then
  REG_URL="$(python3 - "$CONFIG" <<'EOF'
import sys
try:
    import yaml
except ImportError:
    print("NO_PYYAML"); raise SystemExit
cfg = yaml.safe_load(open(sys.argv[1]))
tun = cfg.get("management_node_tunnelling", {}) or {}
svc = cfg.get("service", {}) or {}
loc = cfg.get("local_image_registry", {}) or {}
if tun.get("enabled"):
    addr = tun.get("local_image_registry_node_address", "") or ""
    port = tun.get("local_image_registry_node_port", 0) or 0
else:
    addr = svc.get("management_node_address", "") or ""
    port = loc.get("port", 0) or 0
print(f"{addr}:{port}")
EOF
)"
  if [ "$REG_URL" = "NO_PYYAML" ]; then
    echo "SKIP: registry-URL check needs python3-yaml"
    REG_URL=""
  elif [ -z "${REG_URL%%:*}" ] || [ "${REG_URL##*:}" = "0" ]; then
    fail "derived registry URL is '$REG_URL' (empty host or port 0). With management_node_tunnelling enabled, set management_node_tunnelling.local_image_registry_node_address/port in $CONFIG — otherwise every git/sourceCode build tags the image ':0/<app>:<dep>', the daemon rejects it instantly ('invalid reference format'), and the deployment fails with zero build-log lines"
    REG_URL=""
  fi
elif [ "$SW_REMOTE" = "1" ]; then
  REG_URL="${SW_REGISTRY_ADDR:-${SW_HOST}:3334}"
  echo "NOTE: remote mode — registry address defaulted to ${REG_URL} (override with SW_REGISTRY_ADDR; must match what the builder derives: service.management_node_address + local_image_registry.port, or the tunnelling node address:port)"
else
  echo "SKIP: $CONFIG not readable (run as root for registry-URL check)"
fi

if [ -n "$REG_URL" ]; then
  pass "derived registry URL is '$REG_URL'"
  # The local registry speaks HTTPS (self-signed) + htpasswd auth, so a
  # healthy registry answers 401 (auth challenge) — accept 200/401.
  # Anything else (notably connection failure) means builds can't push.
  CODE="$(curl -sk --max-time 8 -o /dev/null -w "%{http_code}" "https://${REG_URL}/v2/" 2>/dev/null || echo 000)"
  if [ "$CODE" = "200" ] || [ "$CODE" = "401" ]; then
    pass "registry answers at https://${REG_URL}/v2/ (HTTP $CODE)"
  else
    if [ "$SW_REMOTE" = "1" ]; then
      fail "registry not reachable at https://${REG_URL}/v2/ (HTTP $CODE) from here. Remote cause differs from co-located: check port 3334 firewall/security-group, whether the registry binds a non-loopback interface, and that SW_REGISTRY_ADDR matches the builder's derived URL — else docker push (or the in-cluster build) cannot reach it"
    else
      fail "registry not healthy at https://${REG_URL}/v2/ (HTTP $CODE). Source builds can tag but not push — use a loopback address (127.0.0.1) with the local registry port"
    fi
  fi
fi

# 3. Server/swarm status via GraphQL (any mode; needs SW_TOKEN).
#    Remote replacement for `swiftwave service status`: server.status is
#    the daemon-reported readiness (online/offline) of each managed node.
if [ -n "${SW_TOKEN:-}" ]; then
  SRV="$(curl -fsS $(_sw_curl_flags) --max-time 15 -X POST "${SW_BASE_URL}/graphql" \
    -H "Authorization: Bearer ${SW_TOKEN}" -H "Content-Type: application/json" \
    -d '{"query":"{ servers { hostname status swarmNodeStatus proxyEnabled } }"}' 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
svrs=(d.get("data") or {}).get("servers") or []
for s in svrs:
    print(s.get("hostname") or "?", s.get("status") or "unknown",
          s.get("swarmNodeStatus") or "unknown",
          "proxy" if s.get("proxyEnabled") else "noproxy")' 2>/dev/null || true)"
  if [ -z "$SRV" ]; then
    echo "SKIP: server status query failed (expired SW_TOKEN or GraphQL error) — re-login and retry"
  else
    # Herestring (not `echo | while`): the loop must run in THIS shell or
    # fail()'s FAIL=1 is lost to a pipeline subshell and doctor exits 0.
    while read -r _h st _s _p; do
      # 'unknown' (field absent) and 'preparing' (setup in progress) are
      # not failures; 'needs_setup' is — that server takes no deployments.
      case "$st" in
        online|unknown|preparing) pass "server $_h: $st" ;;
        *) fail "server $_h: $st" ;;
      esac
    done <<<"$SRV"
  fi
else
  echo "SKIP: server status check needs SW_TOKEN (set it for a full check)"
fi

exit "$FAIL"
