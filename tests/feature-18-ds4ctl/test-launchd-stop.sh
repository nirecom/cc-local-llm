#!/usr/bin/env bash
# Tests: ds4ctl stop refuses when launchd-managed — exit 1, uninstall guidance, no manual kill.
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

REPO="/Users/example/git/ds4-ops"
DS4CTL="$REPO/scripts/ds4ctl.sh"
LAUNCHD_LIB="$REPO/scripts/lib/launchd.sh"

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

# launchctl stub: report the label as loaded (managed) for `print`/`list`.
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/launchctl" <<'EOF'
#!/bin/sh
# Any query about a ds4 label reports it as loaded -> managed.
case "$*" in
    *ds4*) echo "com.nire.ds4-proxy = { state = running }"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB/launchctl"

# A live process with a matching PID file — the guard must NOT kill it, because
# launchd owns the lifecycle and manual stop is refused.
sleep 300 &
LIVE=$!
printf '%s\n' "$LIVE" > "$PID_DIR/proxy.pid"

out="$(PATH="$STUB:$PATH" bash "$DS4CTL" stop proxy 2>&1)"; rc=$?

[ "$rc" = "1" ] || fail "expected exit 1 when launchd-managed, got $rc (out: $out)"
echo "$out" | grep -qi "uninstall" || fail "no uninstall guidance in output (got: $out)"
# The managed process must be left untouched.
kill -0 "$LIVE" 2>/dev/null || fail "managed process $LIVE was killed — guard failed"
[ -f "$PID_DIR/proxy.pid" ] || fail "PID file was removed despite refusal"

echo "PASS: test-launchd-stop"
