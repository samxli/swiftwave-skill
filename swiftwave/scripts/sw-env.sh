#!/usr/bin/env bash
# Shared env for SwiftWave access (co-located OR remote). Source only:
# `source sw-env.sh`.
# Env overrides: SW_HOST (default 127.0.0.1 — set the server IP/hostname
# to operate remotely), SW_PORT (3333), SW_SCHEME (auto-detected unless
# explicitly set), SW_INSECURE (1 adds curl -k for the self-signed daemon
# cert when using https), SW_USER/SW_PASS (login creds), SW_TOKEN (JWT).
# Config file: instead of exporting SW_* by hand, keep them in an env
# file (see env.example) — lookup order (first found wins):
#   1. $SW_ENV_FILE          (explicit path)
#   2. ./.env.swiftwave      (project-local)
#   3. ~/.config/swiftwave/env   (per-user)
#   4. <skill-dir>/.env.swiftwave (bundled with this skill, last resort)
# Only SW_* keys are read; quotes are optional; the real environment
# always wins over the file. chmod 600 the file — it holds secrets.
# Remote mode (SW_HOST not loopback) is API-only: no local `swiftwave`
# CLI, no /var/lib/swiftwave/config.yml. Credentials cross the network —
# prefer https (use_tls) or an SSH tunnel; http+remote warns here.
# Portable: sourceable from bash, zsh, and POSIX sh (no bashisms).
set -u

# --- optional config file (loaded BEFORE defaults so files can set any
# --- SW_* var; already-exported vars are never overwritten) -----------
_sw_load_env_file() {
  local f="$1" line key value perms
  if [ -n "${SW_ENV_FILE:-}" ] && [ ! -f "$f" ]; then
    echo "sw-env: SW_ENV_FILE is set but '$f' not found" >&2
    return 0
  fi
  # beginner-friendly security nudge: secrets in a world/group-readable file
  perms="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo 600)"
  case "$perms" in
    600|400|0400|0600) ;;
    *) echo "sw-env: WARNING: '$f' is mode $perms — it may hold SW_PASS/SW_TOKEN, run: chmod 600 '$f'" >&2 ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    case "$key" in
      SW_[A-Za-z_]*) ;;
      *) continue ;;            # only SW_* keys; ignore anything else
    esac
    case "$key" in
      *[!A-Za-z0-9_]* ) continue ;;  # strict identifier (also keeps the eval below safe)
    esac
    value="${line#*=}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    # Portable "set only when unset" (bash ${!key+x} / printf -v are
    # bash-only and break zsh sourcing — env file silently ignored).
    eval "_sw_exists=\${$key+x}" 2>/dev/null || _sw_exists=""
    if [ -z "${_sw_exists:-}" ]; then
      export "$key=$value"
    fi
    unset _sw_exists 2>/dev/null || true
  done < "$f"
}

if [ -n "${SW_ENV_FILE:-}" ]; then
  _sw_load_env_file "$SW_ENV_FILE"
else
  # Skill-dir fallback: locate this file portably (BASH_SOURCE is bash-only,
  # ${(%):-%x} is zsh-only — each hidden in eval so the other shell never
  # parses it). Project-local and user config still win; skill-dir is last.
  _sw_script_path=""
  eval '_sw_script_path="${BASH_SOURCE[0]:-}"' 2>/dev/null || true
  if [ -z "$_sw_script_path" ]; then
    eval '_sw_script_path="${(%):-%x}"' 2>/dev/null || true
  fi
  if [ -z "$_sw_script_path" ]; then
    _sw_script_path="$0"
  fi
  _sw_script_dir=""
  case "$_sw_script_path" in
    */*) _sw_script_dir="$(cd "$(dirname "$_sw_script_path")" && pwd)" ;;
  esac
  for _f in "./.env.swiftwave" "${HOME:-}/.config/swiftwave/env" "${_sw_script_dir}/.env.swiftwave"; do
    if [ -n "$_f" ] && [ -f "$_f" ]; then
      _sw_load_env_file "$_f"
      break
    fi
  done
  unset _sw_script_path _sw_script_dir 2>/dev/null || true
fi
unset -f _sw_load_env_file 2>/dev/null || true

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
