#!/usr/bin/env bash
# Tests: scripts/ds4ctl.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Scenario: ds4ctl PID lifecycle — start writes PID; stop kills parent+child and removes PID; stale PID is swept.
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
# A fake service (parent that forks a child) stands in for the real backend via
# the DS4CTL_EXEC_OVERRIDE seam so no real ds4 process is launched.
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
DS4CTL="$REPO/scripts/ds4ctl.sh"

[ -f "$DS4CTL" ] || { echo "SKIP: $DS4CTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with a stub auth token so the start guard sees a value.
export DOTENV_FILE="$WORK/dotenv"
printf 'DS4_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/cc-local-llm/run"
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

# Fake service: fork a long-lived child, record its PID, then block. Killing the
# process group (or parent+child) must take both down.
FAKE="$WORK/fake-service.sh"
cat > "$FAKE" <<EOF
#!/bin/sh
sleep 300 &
echo \$! > "$WORK/child.pid"
exec sleep 300
EOF
chmod +x "$FAKE"
export DS4CTL_EXEC_OVERRIDE="$FAKE"

wait_for() { # wait_for <file> <timeout-sec>
    _i=0
    while [ ! -s "$1" ] && [ "$_i" -lt "${2}0" ]; do
        perl -e 'select undef,undef,undef,0.1'
        _i=$((_i + 1))
    done
    [ -s "$1" ]
}

# --- start -> PID file created, parent+child alive --------------------------
PATH="$STUB:$PATH" bash "$DS4CTL" start proxy >"$WORK/out" 2>&1 || fail "start proxy failed: $(cat "$WORK/out")"
wait_for "$PID_DIR/proxy.pid" 5 || fail "start: proxy.pid not created"
wait_for "$WORK/child.pid" 5 || fail "start: fake child never spawned"
PARENT="$(cat "$PID_DIR/proxy.pid")"
CHILD="$(cat "$WORK/child.pid")"
kill -0 "$PARENT" 2>/dev/null || fail "start: parent $PARENT not alive"
kill -0 "$CHILD" 2>/dev/null || fail "start: child $CHILD not alive"

# --- stop -> parent+child gone, PID file removed ----------------------------
PATH="$STUB:$PATH" bash "$DS4CTL" stop proxy >"$WORK/out" 2>&1 || fail "stop proxy failed: $(cat "$WORK/out")"
perl -e 'select undef,undef,undef,0.5'
kill -0 "$PARENT" 2>/dev/null && fail "stop: parent $PARENT still alive"
kill -0 "$CHILD" 2>/dev/null && fail "stop: child $CHILD still alive (not reaped)"
[ -f "$PID_DIR/proxy.pid" ] && fail "stop: proxy.pid not removed"

# --- stale PID -> swept on next start ---------------------------------------
echo "999999" > "$PID_DIR/proxy.pid"   # a PID that is not running
rm -f "$WORK/child.pid"
PATH="$STUB:$PATH" bash "$DS4CTL" start proxy >"$WORK/out" 2>&1 || fail "start after stale PID failed: $(cat "$WORK/out")"
wait_for "$WORK/child.pid" 5 || fail "stale PID: service did not (re)start"
NEWPID="$(cat "$PID_DIR/proxy.pid")"
[ "$NEWPID" != "999999" ] || fail "stale PID: proxy.pid still holds the dead 999999"
kill -0 "$NEWPID" 2>/dev/null || fail "stale PID: new parent $NEWPID not alive"

echo "PASS: test-pid-lifecycle"
