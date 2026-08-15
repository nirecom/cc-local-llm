#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/launchd.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl `stop all` partial-failure continuation — the first
# target in the group is launchd-managed and refuses, and every remaining
# target must still be stopped.
#
# Issue #41 grows the `all` group from two services to three
# (proxy + llama-swap + litellm). Continuation is exactly the property that a
# larger group can break silently: an implementation that aborts on the first
# refusal still looked correct when only one service came after it. The
# refused target is therefore placed first, and BOTH survivors are asserted.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# TL3 gap: real launchctl load/unload persistence across reboots; actual
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
export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/cc-local-llm/run"
mkdir -p "$PID_DIR"

cleanup() {
    [ -n "${PROXY:-}" ] && kill "$PROXY" 2>/dev/null
    [ -n "${SWAP:-}" ] && kill "$SWAP" 2>/dev/null
    [ -n "${LITELLM:-}" ] && kill "$LITELLM" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# "Managed by launchd" is two conditions, not one: _ds4_launchd_active requires
# BOTH the plist file to exist AND `launchctl list <label>` to succeed. Seeding
# only the stub — as the previous revision of this file did — left the proxy
# looking unmanaged, so the refusal under test never happened.
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"
: > "$LAUNCH_AGENTS/com.nire.ds4-proxy.plist"

# launchctl stub: the proxy label is managed (running); llama-swap and litellm
# are unmanaged, so they take the manual stop path.
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/launchctl" <<'EOF'
#!/bin/sh
case "$*" in
    *proxy*) echo "com.nire.ds4-proxy = { state = running }"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB/launchctl"

# Live processes for each target in the `all` group.
sleep 300 & PROXY=$!
sleep 300 & SWAP=$!
sleep 300 & LITELLM=$!
printf '%s\n' "$PROXY" > "$PID_DIR/proxy.pid"
printf '%s\n' "$SWAP" > "$PID_DIR/llama-swap.pid"
printf '%s\n' "$LITELLM" > "$PID_DIR/litellm.pid"

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" stop all 2>&1)"; rc=$?

# Proxy (managed) must be left running and its PID file kept.
kill -0 "$PROXY" 2>/dev/null || fail "stop all: managed proxy $PROXY was killed"
[ -f "$PID_DIR/proxy.pid" ] || fail "stop all: proxy.pid removed despite managed refusal"
echo "$out" | grep -qi "uninstall" || fail "stop all: no uninstall guidance for the managed proxy (out: $out)"

# Both remaining targets must be stopped despite the proxy refusal.
# The last one in the group is the case a first-failure abort would miss.
perl -e 'select undef,undef,undef,0.5'
kill -0 "$SWAP" 2>/dev/null && fail "stop all: manual llama-swap $SWAP not stopped (no continuation past the refused proxy)"
[ -f "$PID_DIR/llama-swap.pid" ] && fail "stop all: llama-swap.pid not removed"
kill -0 "$LITELLM" 2>/dev/null && fail "stop all: manual litellm $LITELLM not stopped — continuation stops short of the last service in the group"
[ -f "$PID_DIR/litellm.pid" ] && fail "stop all: litellm.pid not removed"

# A partial failure should surface as a non-zero overall exit.
[ "$rc" != "0" ] || fail "stop all: expected non-zero exit on partial failure, got 0"

# --- All-clean run: a group with nothing to refuse must exit 0 -------------
# Negative control for the assertion above: the non-zero exit must come from
# the refusal, not from `stop all` being unconditionally non-zero.
cat > "$STUB/launchctl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STUB/launchctl"
sleep 300 & SWAP=$!
sleep 300 & LITELLM=$!
printf '%s\n' "$SWAP" > "$PID_DIR/llama-swap.pid"
printf '%s\n' "$LITELLM" > "$PID_DIR/litellm.pid"
rm -f "$PID_DIR/proxy.pid"

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" stop all 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "stop all (nothing refused): expected exit 0, got $rc (out: $out)"

echo "PASS: test-stop-all"
