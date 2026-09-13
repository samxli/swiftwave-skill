#!/usr/bin/env bash
# Shared env for SwiftWave access (co-located OR remote). Source only:
# `source sw-env.sh`.
# Env overrides: SW_HOST (default 127.0.0.1 — set the server IP/hostname
# to operate remotely), SW_PORT (3333), SW_SCHEME (auto-detected unless
# explicitly set), SW_INSECURE (1 adds curl -k for the self-signed daemon
# cert when using https), SW_USER/SW_PASS (login creds), SW_TOKEN (JWT).
# Remote mode (SW_HOST not loopback) is API-only: no local `swiftwave`
# CLI, no /var/lib/swiftwave/config.yml. Credentials cross the network —
# prefer https (use_tls) or an SSH tunnel; http+remote warns here.
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

# Remote mode: any non-loopback SW_HOST. Co-located ops (swiftwave CLI,
# local config) are unavailable; callers branch on SW_REMOTE.
case "$SW_HOST" in
  127.*|localhost|::1) SW_REMOTE=0 ;;
  *) SW_REMOTE=1 ;;
esac

# Auto-detect scheme unless explicitly set: the daemon serves https only
# when use_tls is true in the server's config.yml, otherwise http.
# Probing is cheap and avoids breakage when TLS is toggled. Timeout is
# generous to tolerate network latency in remote mode.
if [ -z "${SW_SCHEME:-}" ]; then
  if curl -sk --max-time 8 -o /dev/null "https://${SW_HOST}:${SW_PORT}/" 2>/dev/null; then
    # https responded at TLS level; verify it is really the API (not a
    # wrong-version-number failure, which curl reports as failure already)
    SW_SCHEME="https"
  else
    SW_SCHEME="http"
  fi
fi

if [ "$SW_REMOTE" = "1" ] && [ "$SW_SCHEME" = "http" ]; then
  echo "sw-env: WARNING: remote access over plain http — SW_USER/SW_PASS and the JWT cross the network unencrypted" >&2
  echo "sw-env: WARNING: prefer https (use_tls on the server) or an SSH tunnel (ssh -L ${SW_PORT}:127.0.0.1:${SW_PORT} ...)" >&2
fi

SW_BASE_URL="${SW_SCHEME}://${SW_HOST}:${SW_PORT}"

_sw_curl_flags() {
  if [ "${SW_SCHEME}" = "https" ] && [ "${SW_INSECURE}" = "1" ]; then
    printf '%s' "-k"
  fi
}
