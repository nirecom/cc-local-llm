#!/usr/bin/env bash
# Tests: ds4ctl double-start prevention — PID-file route and pgrep-fallback route both report `already running`.
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

REPO="/Users/example/git/ds4-ops"
DS4CTL="$REPO/scripts/ds4ctl.sh"

[ -f "$DS4CTL" ] || { echo "SKIP: $DS4CTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${LIVE:-}" ] && kill "$LIVE" 2>/dev/null' EXIT

export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/ds4-ops/run"
mkdir -p "$PID_DIR"

# Stub launchctl to report "not managed" so the manual route is exercised.
STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
chmod +x "$STUB/launchctl"

# --- Route A: live PID file pointing at a running process --------------------
sleep 300 &
LIVE=$!
printf '%s\n' "$LIVE" > "$PID_DIR/proxy.pid"

out="$(PATH="$STUB:$PATH" bash "$DS4CTL" start proxy 2>&1)"; rc=$?
[ "$rc" != "0" ] || fail "PID-file route: expected non-zero exit, got 0"
echo "$out" | grep -qi "already running" || fail "PID-file route: missing 'already running' (got: $out)"
# Existing process must not be killed by a rejected start.
kill -0 "$LIVE" 2>/dev/null || fail "PID-file route: live process was killed"

# --- Route B: no PID file, pgrep fallback finds the process ------------------
rm -f "$PID_DIR/proxy.pid"

# pgrep stub reports a live match for the proxy pattern.
cat > "$STUB/pgrep" <<EOF
#!/bin/sh
# Emit a PID for any query, simulating a running unsupervised process.
echo $LIVE
exit 0
EOF
chmod +x "$STUB/pgrep"

out="$(PATH="$STUB:$PATH" bash "$DS4CTL" start proxy 2>&1)"; rc=$?
[ "$rc" != "0" ] || fail "pgrep fallback: expected non-zero exit, got 0"
echo "$out" | grep -qi "already running" || fail "pgrep fallback: missing 'already running' (got: $out)"

echo "PASS: test-double-start"
