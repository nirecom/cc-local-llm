#!/usr/bin/env bash
# Tests: proxy/server.py
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: proxy SIGINT (Phase 1) — Ctrl-C stops proxy cleanly, no Python Traceback, normal exit.
#
# Runs against the EXISTING proxy/server.py (not serverctl). Before Phase 1 lands
# this is expected to FAIL (raw KeyboardInterrupt traceback); it is intentionally
# NOT skipped on missing implementation so the regression is recorded.
# Skips (exit 77) only when prerequisites (DS4_API_KEY / uv / openssl) are absent.
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVER="$REPO/proxy/server.py"

[ -f "$SERVER" ] || { echo "SKIP: $SERVER not found"; exit 77; }
printenv DS4_API_KEY >/dev/null 2>&1 || { echo "SKIP: DS4_API_KEY not set"; exit 77; }
command -v uv >/dev/null 2>&1 || { echo "SKIP: uv not available"; exit 77; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl not available"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# Signal only the process we started (uv) and its direct children (python) —
# never a broad `pkill -f proxy.server`, which could hit the user's real proxy.
signal_tree() { # signal_tree <sig> <pid>
    local sig="$1" p="$2" c
    kill "-$sig" "$p" 2>/dev/null
    for c in $(pgrep -P "$p" 2>/dev/null); do
        signal_tree "$sig" "$c"
    done
}

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with a stub auth token so the start guard sees a value.
export DOTENV_FILE="$WORK/dotenv"
printf 'DS4_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
PID=""; WATCH=""
cleanup() {
    [ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null
    [ -n "$PID" ] && signal_tree KILL "$PID"
    rm -rf "$WORK"
}
trap cleanup EXIT

# Self-signed TLS leaf so the proxy can bind TLS.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" \
    -out "$WORK/cert.pem" -days 1 -subj "/CN=localhost" >/dev/null 2>&1 \
    || { echo "SKIP: openssl cert generation failed"; exit 77; }

# Pick an ephemeral port.
PORT=$(( (RANDOM % 2000) + 18000 ))
LOG="$WORK/proxy.log"

export DS4_PROXY_AUTH_TOKEN="$DS4_API_KEY"
export DS4_PROXY_CERT="$WORK/cert.pem"
export DS4_PROXY_KEY="$WORK/key.pem"
export DS4_PROXY_PORT="$PORT"
export DS4_PROXY_TEE="off"

# Launch the proxy directly (NOT under a timeout wrapper — a wrapper would
# intercept the SIGINT we need to deliver to the proxy itself).
( cd "$REPO" && exec uv run python -m proxy.server ) >"$LOG" 2>&1 &
PID=$!

# Independent watchdog: hard-kill the whole tree if it ever hangs (30s cap).
( sleep 30; signal_tree KILL "$PID" ) &
WATCH=$!

# Wait for the listening banner (up to ~20s).
_i=0
while [ "$_i" -lt 200 ]; do
    grep -q "listening" "$LOG" 2>/dev/null && break
    kill -0 "$PID" 2>/dev/null || break
    perl -e 'select undef,undef,undef,0.1'
    _i=$((_i + 1))
done
grep -q "listening" "$LOG" 2>/dev/null || fail "proxy never reported listening (log: $(cat "$LOG"))"

# Deliver SIGINT (Ctrl-C) to the proxy launcher and its python child.
signal_tree INT "$PID"

# Wait for exit.
wait "$PID"; rc=$?
PID=""
[ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null; WATCH=""

# Phase 1 expectation: clean shutdown, no traceback, non-crash exit code.
if grep -q "Traceback" "$LOG"; then
    fail "proxy printed a Python Traceback on SIGINT:
$(cat "$LOG")"
fi
if grep -qi "KeyboardInterrupt" "$LOG"; then
    fail "proxy leaked KeyboardInterrupt on SIGINT (no handler installed)"
fi
# 0 = clean; 130 = SIGINT-terminated but not the target clean-exit contract.
[ "$rc" = "0" ] || fail "proxy did not exit cleanly on SIGINT (rc=$rc)"

echo "PASS: test-ctrlc"
