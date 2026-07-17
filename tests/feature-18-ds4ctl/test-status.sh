#!/usr/bin/env bash
# Tests: ds4ctl status — running reports "running (pid N)"; stopped reports "stopped".
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
#
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

REPO="/Users/example/git/ds4-ops"
DS4CTL="$REPO/scripts/ds4ctl.sh"

[ -f "$DS4CTL" ] || { echo "SKIP: $DS4CTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/ds4-ops/run"
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

out="$(PATH="$STUB:$PATH" bash "$DS4CTL" status proxy 2>&1)"; rc=$?
echo "$out" | grep -qi "running" || fail "status (running): missing 'running' (got: $out)"
echo "$out" | grep -q "$LIVE" || fail "status (running): pid $LIVE not shown (got: $out)"

# --- stopped -> "stopped" ----------------------------------------------------
kill "$LIVE" 2>/dev/null
wait "$LIVE" 2>/dev/null
LIVE=""
rm -f "$PID_DIR/proxy.pid"

out="$(PATH="$STUB:$PATH" bash "$DS4CTL" status proxy 2>&1)"; rc=$?
echo "$out" | grep -qi "stopped" || fail "status (stopped): missing 'stopped' (got: $out)"

echo "PASS: test-status"
