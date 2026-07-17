#!/usr/bin/env bash
# Tests: ds4ctl restart — stops the running process, starts a fresh one, PID changes.
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
# A fake service stands in for the real backend via the DS4CTL_EXEC_OVERRIDE
# seam so no real ds4 process is launched.
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
    [ -f "$PID_DIR/proxy.pid" ] && kill "$(cat "$PID_DIR/proxy.pid")" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# launchctl stub: report "not managed" so the manual daemon route runs.
STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
chmod +x "$STUB/launchctl"

# Fake service: block so the parent PID stays alive until stopped.
FAKE="$WORK/fake-service.sh"
cat > "$FAKE" <<'EOF'
#!/bin/sh
exec sleep 300
EOF
chmod +x "$FAKE"
export DS4CTL_EXEC_OVERRIDE="$FAKE"

wait_for() { _i=0; while [ ! -s "$1" ] && [ "$_i" -lt "${2}0" ]; do perl -e 'select undef,undef,undef,0.1'; _i=$((_i+1)); done; [ -s "$1" ]; }

# --- start -> record the original PID ---------------------------------------
PATH="$STUB:$PATH" bash "$DS4CTL" start proxy >"$WORK/out" 2>&1 || fail "start proxy failed: $(cat "$WORK/out")"
wait_for "$PID_DIR/proxy.pid" 5 || fail "start: proxy.pid not created"
OLDPID="$(cat "$PID_DIR/proxy.pid")"
kill -0 "$OLDPID" 2>/dev/null || fail "start: parent $OLDPID not alive"

# --- restart -> old process stopped, new process started, PID changed -------
PATH="$STUB:$PATH" bash "$DS4CTL" restart proxy >"$WORK/out" 2>&1 || fail "restart proxy failed: $(cat "$WORK/out")"
wait_for "$PID_DIR/proxy.pid" 5 || fail "restart: proxy.pid not created"
NEWPID="$(cat "$PID_DIR/proxy.pid")"

# 1. Old process must be gone.
perl -e 'select undef,undef,undef,0.5'
kill -0 "$OLDPID" 2>/dev/null && fail "restart: old process $OLDPID still alive (not stopped)"
# 2. New process must be alive.
kill -0 "$NEWPID" 2>/dev/null || fail "restart: new process $NEWPID not alive"
# 3. PID must have changed.
[ "$NEWPID" != "$OLDPID" ] || fail "restart: PID did not change ($NEWPID == $OLDPID)"

echo "PASS: test-restart"
