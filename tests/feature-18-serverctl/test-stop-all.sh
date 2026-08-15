#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/launchd.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl `stop all` partial-failure continuation — proxy launchd-managed (refused), server still stopped.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
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
printf 'DS4_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/cc-local-llm/run"
mkdir -p "$PID_DIR"

cleanup() {
    [ -n "${PROXY:-}" ] && kill "$PROXY" 2>/dev/null
    [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# launchctl stub: proxy label is managed (running); server label is unmanaged.
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/launchctl" <<'EOF'
#!/bin/sh
case "$*" in
    *proxy*) echo "com.nire.ds4-proxy = { state = running }"; exit 0 ;;
    *server*) exit 1 ;;   # not loaded -> manual
esac
exit 0
EOF
chmod +x "$STUB/launchctl"

# Live processes for each target.
sleep 300 & PROXY=$!
sleep 300 & SERVER=$!
printf '%s\n' "$PROXY" > "$PID_DIR/proxy.pid"
printf '%s\n' "$SERVER" > "$PID_DIR/server.pid"

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" stop all 2>&1)"; rc=$?

# Proxy (managed) must be left running and its PID file kept.
kill -0 "$PROXY" 2>/dev/null || fail "stop all: managed proxy $PROXY was killed"
[ -f "$PID_DIR/proxy.pid" ] || fail "stop all: proxy.pid removed despite managed refusal"
echo "$out" | grep -qi "uninstall" || fail "stop all: no uninstall guidance for the managed proxy (out: $out)"

# Server (manual) must be stopped despite the proxy failure — continuation.
perl -e 'select undef,undef,undef,0.5'
kill -0 "$SERVER" 2>/dev/null && fail "stop all: manual server $SERVER not stopped (no continuation)"
[ -f "$PID_DIR/server.pid" ] && fail "stop all: server.pid not removed"

# A partial failure should surface as a non-zero overall exit.
[ "$rc" != "0" ] || fail "stop all: expected non-zero exit on partial failure, got 0"

echo "PASS: test-stop-all"
