#!/usr/bin/env bash
# Shared env for SwiftWave co-located access. Source only: `source sw-env.sh`.
# Env overrides: SW_HOST (default 127.0.0.1), SW_PORT (3333),
# SW_SCHEME (auto-detected unless explicitly set), SW_INSECURE (1 adds
# curl -k for self-signed daemon cert when using https).
set -u

SW_HOST="${SW_HOST:-127.0.0.1}"
SW_PORT="${SW_PORT:-3333}"
SW_INSECURE="${SW_INSECURE:-1}"

# Dependency check: fail fast with a clear message instead of obscure errors.
for _dep in curl python3; do
  if ! command -v "$_dep" >/dev/null 2>&1; then
    echo "sw-env: required command '$_dep' not found" >&2
    return 1 2>/dev/null || exit 1
  fi
done
# jq is NOT required — all JSON handling uses python3. Informational only.
command -v jq >/dev/null 2>&1 || true

# Auto-detect scheme unless explicitly set: the daemon serves https only
# when use_tls is true in /var/lib/swiftwave/config.yml, otherwise http.
# Probing is cheap (localhost) and avoids breakage when TLS is toggled.
if [ -z "${SW_SCHEME:-}" ]; then
  if curl -sk --max-time 3 -o /dev/null "https://${SW_HOST}:${SW_PORT}/" 2>/dev/null; then
    # https responded at TLS level; verify it is really the API (not a
    # wrong-version-number failure, which curl reports as failure already)
    SW_SCHEME="https"
  else
    SW_SCHEME="http"
  fi
fi

SW_BASE_URL="${SW_SCHEME}://${SW_HOST}:${SW_PORT}"

_sw_curl_flags() {
  if [ "${SW_SCHEME}" = "https" ] && [ "${SW_INSECURE}" = "1" ]; then
    printf '%s' "-k"
  fi
}
