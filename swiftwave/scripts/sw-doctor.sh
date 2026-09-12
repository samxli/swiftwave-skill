#!/usr/bin/env bash
# Read-only health check for a co-located SwiftWave instance.
# Checks API reachability and validates the derived image-registry URL that
# the in-cluster builder tags images with. A broken registry URL makes every
# git/sourceCode build fail INSTANTLY with "Failed to build docker image"
# and zero stream lines in deployment_logs.
# Usage: ./sw-doctor.sh
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
  fail "API not reachable at ${SW_BASE_URL} (check service + SW_SCHEME)"
fi

# 2. Derived registry URL valid (mirrors GetRegistryURL + tunnelling logic)
CONFIG="/var/lib/swiftwave/config.yml"
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
  elif [ -z "${REG_URL%%:*}" ] || [ "${REG_URL##*:}" = "0" ]; then
    fail "derived registry URL is '$REG_URL' (empty host or port 0). With management_node_tunnelling enabled, set management_node_tunnelling.local_image_registry_node_address/port in $CONFIG — otherwise every git/sourceCode build tags the image ':0/<app>:<dep>', the daemon rejects it instantly ('invalid reference format'), and the deployment fails with zero build-log lines"
  else
    pass "derived registry URL is '$REG_URL'"
    # The local registry speaks HTTPS (self-signed) + htpasswd auth, so a
    # healthy registry answers 401 (auth challenge) — accept 200/401.
    # Anything else (notably connection failure) means builds can't push.
    CODE="$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" "https://${REG_URL}/v2/" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ] || [ "$CODE" = "401" ]; then
      pass "registry answers at https://${REG_URL}/v2/ (HTTP $CODE)"
    else
      fail "registry not healthy at https://${REG_URL}/v2/ (HTTP $CODE). Source builds can tag but not push — use a loopback address (127.0.0.1) with the local registry port"
    fi
  fi
else
  echo "SKIP: $CONFIG not readable (run as root for registry-URL check)"
fi

exit "$FAIL"
