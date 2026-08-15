#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl double-start prevention — PID-file route and pgrep-fallback route both report `already running`.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_PROXY_AUTH_TOKEN auth check.
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
trap 'rm -rf "$WORK"; [ -n "${LIVE:-}" ] && kill "$LIVE" 2>/dev/null' EXIT

export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/cc-local-llm/run"
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

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" start proxy 2>&1)"; rc=$?
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

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" start proxy 2>&1)"; rc=$?
[ "$rc" != "0" ] || fail "pgrep fallback: expected non-zero exit, got 0"
echo "$out" | grep -qi "already running" || fail "pgrep fallback: missing 'already running' (got: $out)"

echo "PASS: test-double-start"
