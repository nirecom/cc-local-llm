#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl status — running reports "running (pid N)"; stopped reports "stopped".
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
#
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real CCGW_PROXY_AUTH_TOKEN auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVERCTL="$REPO/scripts/serverctl.sh"

[ -f "$SERVERCTL" ] || { echo "SKIP: $SERVERCTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with a stub auth token so the start guard sees a value.
export DOTENV_FILE="$WORK/dotenv"
printf 'CCGW_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/cc-local-llm/run"
mkdir -p "$PID_DIR"

cleanup() {
    [ -n "${LIVE:-}" ] && kill "$LIVE" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# launchctl stub: report "not managed" so status reflects the manual PID file.
STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
chmod +x "$STUB/launchctl"

# pgrep stub: no unsupervised match, so status depends solely on the PID file.
printf '#!/bin/sh\nexit 1\n' > "$STUB/pgrep"
chmod +x "$STUB/pgrep"

# --- running -> "running (pid N)" -------------------------------------------
sleep 300 &
LIVE=$!
printf '%s\n' "$LIVE" > "$PID_DIR/proxy.pid"

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" status proxy 2>&1)"; rc=$?
echo "$out" | grep -qi "running" || fail "status (running): missing 'running' (got: $out)"
echo "$out" | grep -q "$LIVE" || fail "status (running): pid $LIVE not shown (got: $out)"

# --- stopped -> "stopped" ----------------------------------------------------
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
LIVE=""
rm -f "$PID_DIR/proxy.pid"

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" status proxy 2>&1)"; rc=$?
echo "$out" | grep -qi "stopped" || fail "status (stopped): missing 'stopped' (got: $out)"

echo "PASS: test-status"
