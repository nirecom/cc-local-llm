#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/launchd.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl stop refuses when launchd-managed — exit 1, uninstall guidance, no manual kill.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_PROXY_AUTH_TOKEN auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVERCTL="$REPO/scripts/serverctl.sh"
LAUNCHD_LIB="$REPO/scripts/lib/launchd.sh"

[ -f "$SERVERCTL" ] || { echo "SKIP: $SERVERCTL not found (implementation pending)"; exit 77; }

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

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" stop proxy 2>&1)"; rc=$?

[ "$rc" = "1" ] || fail "expected exit 1 when launchd-managed, got $rc (out: $out)"
echo "$out" | grep -qi "uninstall" || fail "no uninstall guidance in output (got: $out)"
# The managed process must be left untouched.
kill -0 "$LIVE" 2>/dev/null || fail "managed process $LIVE was killed — guard failed"
[ -f "$PID_DIR/proxy.pid" ] || fail "PID file was removed despite refusal"

echo "PASS: test-launchd-stop"
