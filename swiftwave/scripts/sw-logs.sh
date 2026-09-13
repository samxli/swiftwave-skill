#!/usr/bin/env bash
# Stream deployment or runtime logs via GraphQL subscriptions (websocket).
# Works co-located AND remote — the only API-based replacement for reading
# the deployment_logs DB table or `docker logs` on the server.
#
# Usage:
#   ./sw-logs.sh deployment <deployment-id> [overall-timeout-secs]
#       Replays all logs of the deployment, then tails it if still
#       pending/deploying. Exits when the server completes the stream
#       (terminal deployment) or after the overall timeout (default 300,
#       0 = wait forever).
#   ./sw-logs.sh runtime <application-id> [timeframe] [idle-timeout-secs]
#       timeframe: live|last_1_hour|last_3_hours|last_6_hours|
#                  last_12_hours|last_24_hours|lifetime  (default last_1_hour)
#       Dumps service logs for the timeframe ('live' keeps tailing). Exits
#       after idle-timeout seconds without data (default 30).
# Token via SW_TOKEN env (preferred) or first arg (eyJ...). Logs go to
# stdout only; diagnostics to stderr.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/sw-env.sh"

if [[ "${1:-}" == eyJ* ]]; then
  TOKEN="$1"; shift
else
  TOKEN="${SW_TOKEN:?usage: sw-logs.sh [<token>] deployment|runtime ... (or set SW_TOKEN)}"
fi
KIND="${1:?usage: sw-logs.sh [<token>] deployment <id> [timeout] | runtime <app-id> [timeframe] [idle-timeout]}"
case "$KIND" in
  deployment)
    SW_KIND=deployment
    SW_ID="${2:?usage: sw-logs.sh deployment <deployment-id> [overall-timeout-secs]}"
    SW_TIMEOUT="${3:-300}"
    SW_TIMEFRAME=""
    ;;
  runtime)
    SW_KIND=runtime
    SW_ID="${2:?usage: sw-logs.sh runtime <application-id> [timeframe] [idle-timeout-secs]}"
    SW_TIMEFRAME="${3:-last_1_hour}"
    SW_TIMEOUT="${4:-30}"
    ;;
  *)
    echo "sw-logs.sh: unknown kind '$KIND' (deployment|runtime)" >&2
    exit 2
    ;;
esac
export SW_KIND SW_ID SW_TIMEFRAME SW_TIMEOUT
export SW_TOKEN="$TOKEN" SW_BASE_URL SW_SCHEME SW_INSECURE

echo "sw-logs: streaming ${SW_KIND} logs for ${SW_ID} (Ctrl+C to stop)" >&2

exec python3 <<'PYEOF'
import base64, json, os, socket, ssl, struct, sys

BASE = os.environ["SW_BASE_URL"]
SCHEME, _, rest = BASE.partition("://")
HOST, _, PORT = rest.rpartition(":")
TOKEN = os.environ["SW_TOKEN"]
KIND = os.environ["SW_KIND"]
TARGET = os.environ["SW_ID"]
TIMEFRAME = os.environ["SW_TIMEFRAME"]
try:
    TIMEOUT = float(os.environ["SW_TIMEOUT"])
except ValueError:
    TIMEOUT = 0.0
IDLE_LIMIT = 90.0 if KIND == "deployment" else 30.0

if KIND == "deployment":
    QUERY = 'subscription($id: String!) { fetchDeploymentLog(id: $id) { content createdAt } }'
    VARS = {"id": TARGET}
    FIELD = "fetchDeploymentLog"
else:
    QUERY = ('subscription($app: String!, $tf: RuntimeLogTimeframe!) '
             '{ fetchRuntimeLog(applicationId: $app, timeframe: $tf) { content createdAt } }')
    VARS = {"app": TARGET, "tf": TIMEFRAME}
    FIELD = "fetchRuntimeLog"

def die(msg, code=1):
    print(f"sw-logs: {msg}", file=sys.stderr)
    sys.exit(code)

try:
    sock = socket.create_connection((HOST, int(PORT)), timeout=15)
except OSError as e:
    die(f"cannot connect to {HOST}:{PORT} ({e})")

if SCHEME == "https":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if os.environ.get("SW_INSECURE", "1") == "1":
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        sock = ctx.wrap_socket(sock, server_hostname=HOST)
    except ssl.SSLError as e:
        die(f"TLS handshake failed ({e}) — check use_tls/SW_SCHEME")

key = base64.b64encode(os.urandom(16)).decode()
req = (f"GET /graphql HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
       "Upgrade: websocket\r\nConnection: Upgrade\r\n"
       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
       "Sec-WebSocket-Protocol: graphql-transport-ws, graphql-ws\r\n"
       "User-Agent: sw-logs/1.0\r\n\r\n")
sock.sendall(req.encode())

buf = bytearray()
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(4096)
    if not chunk:
        die("connection closed during websocket handshake")
    buf += chunk
head, _, buf = buf.partition(b"\r\n\r\n")
lines = head.decode("latin-1").split("\r\n")
if " 101" not in lines[0]:
    die(f"websocket upgrade refused: {lines[0].strip()} "
        f"(wrong token/expired JWT, or the endpoint is not the GraphQL server)")
proto = ""
for ln in lines[1:]:
    if ln.lower().startswith("sec-websocket-protocol:"):
        proto = ln.split(":", 1)[1].strip()
NEW = proto == "graphql-transport-ws"

def send_text(text):
    payload = text.encode()
    mask = os.urandom(4)
    first = 0x80 | 0x1  # FIN + text
    n = len(payload)
    if n < 126:
        hdr = bytes([first, 0x80 | n])
    elif n < 65536:
        hdr = bytes([first, 0x80 | 126]) + struct.pack(">H", n)
    else:
        hdr = bytes([first, 0x80 | 127]) + struct.pack(">Q", n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(hdr + mask + masked)

send_text(json.dumps({"type": "connection_init",
                      "payload": {"Authorization": TOKEN,
                                  "authorization": TOKEN}}))

def need(n):
    while len(buf) < n:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            return False
        if not chunk:
            die("connection closed by server mid-frame")
        buf.extend(chunk)
    return True

def read_frame():
    """Returns (opcode, payload); handles ping/pong/close and continuation."""
    global buf, _frag_opcode, _frag
    if not need(2):
        return None, None
    b1, b2 = buf[0], buf[1]
    opcode, masked, ln = b1 & 0x0F, b2 & 0x80, b2 & 0x7F
    idx = 2
    if ln == 126:
        if not need(4): return None, None
        ln = struct.unpack(">H", bytes(buf[2:4]))[0]; idx = 4
    elif ln == 127:
        if not need(10): return None, None
        ln = struct.unpack(">Q", bytes(buf[2:10]))[0]; idx = 10
    if ln > 64 * 1024 * 1024:
        die(f"oversized frame ({ln} bytes) — aborting")
    if masked:
        if not need(idx + 4): return None, None
        mask = bytes(buf[idx:idx + 4]); idx += 4
    else:
        mask = b""
    if not need(idx + ln): return None, None
    payload = bytes(buf[idx:idx + ln])
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    del buf[:idx + ln]
    if opcode == 0x9:  # ping -> pong
        m = os.urandom(4)
        pl = payload
        hdr = bytes([0x8A, 0x80 | len(pl)]) if len(pl) < 126 else None
        if hdr:
            sock.sendall(hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(pl)))
        return None, None
    if opcode == 0x8:  # close
        return 0x8, payload
    if opcode == 0x0 and _frag_opcode is not None:  # continuation
        _frag += payload
        if b1 & 0x80:
            op, data = _frag_opcode, _frag
            _frag_opcode, _frag = None, b""
            return op, data
        return None, None
    if b1 & 0x80:
        return opcode, payload
    _frag_opcode, _frag = opcode, payload  # fragmented start
    return None, None

_frag_opcode, _frag = None, b""
acked = False
got_any = False
sock.settimeout(min(IDLE_LIMIT, TIMEOUT) if TIMEOUT > 0 else IDLE_LIMIT)
start = None
if TIMEOUT > 0:
    import time
    start = time.monotonic()

T_START, T_NEXT, T_COMPLETE = ("start", "data", "complete") if not NEW \
    else ("subscribe", "next", "complete")

try:
    while True:
        if TIMEOUT > 0 and time.monotonic() - start > TIMEOUT:
            # runtime logs tail forever (docker follow mode) — silence on a
            # quiet app is normal, so a timeout there is a clean stop
            if KIND == "runtime":
                print("sw-logs: timeout, stopping", file=sys.stderr)
                sys.exit(0)
            print(f"sw-logs: overall timeout reached", file=sys.stderr)
            sys.exit(0 if got_any else 1)
        try:
            opcode, payload = read_frame()
        except socket.timeout:
            if not got_any and KIND != "runtime":
                die("no data received (wrong id, silent deployment, or server not streaming) — verify the id and retry")
            print("sw-logs: idle timeout, stopping", file=sys.stderr)
            sys.exit(0)
        if opcode is None:
            continue
        if opcode == 0x8:
            if not acked:
                die("server closed before accepting the subscription (auth failure?)")
            sys.exit(0)
        try:
            msg = json.loads(payload.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            continue
        mtype = msg.get("type", "")
        if mtype == "connection_error" or (mtype == "error" and not acked):
            die(f"subscription rejected: {json.dumps(msg.get('payload', msg))[:500]}")
        if mtype == "connection_ack":
            acked = True
            send_text(json.dumps({"id": "1", "type": T_START,
                                  "payload": {"query": QUERY, "variables": VARS}}))
            continue
        if mtype == "ka" or mtype == "ping":
            if NEW:
                send_text(json.dumps({"type": "pong"}))
            continue
        if mtype == "error":
            print(f"sw-logs: stream error: {json.dumps(msg.get('payload', msg))[:500]}",
                  file=sys.stderr)
            sys.exit(1)
        if mtype in (T_NEXT, "data"):
            data = (msg.get("payload") or {}).get("data") or {}
            entry = data.get(FIELD) or {}
            content = entry.get("content")
            if content is not None:
                got_any = True
                sys.stdout.write(content)
                sys.stdout.flush()
            errs = (msg.get("payload") or {}).get("errors")
            if errs and content is None:
                print(f"sw-logs: GraphQL error: {json.dumps(errs)[:500]}", file=sys.stderr)
                sys.exit(1)
        elif mtype == T_COMPLETE:
            sys.exit(0)
except KeyboardInterrupt:
    sys.exit(130)
PYEOF
