#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/paths.sh, scripts/lib/lifecycle.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: Laguna S 2.1 / llama-swap migration — 'all' expands to
# proxy+llama-swap (NOT server, which llama-swap now owns exclusively);
# 'server' remains individually reachable as a manual-debug-only target;
# paths.sh/lifecycle.sh helpers resolve correct llama-swap paths and command.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
#
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real llama-swap binary presence.
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
mkdir -p "$HOME"
trap 'rm -rf "$WORK"' EXIT

# --- 1. `serverctl status all` includes proxy + llama-swap, excludes server --
OUT="$(bash "$SERVERCTL" status all 2>"$WORK/err")" || fail "status all failed: $(cat "$WORK/err")"
echo "$OUT" | grep -q '^proxy:' || fail "status all: no 'proxy' line in output:
$OUT"
echo "$OUT" | grep -q '^llama-swap:' || fail "status all: no 'llama-swap' line in output:
$OUT"
echo "$OUT" | grep -q '^server:' && fail "status all: unexpectedly printed a 'server' line (server must be excluded from 'all'):
$OUT"

# --- 2. `serverctl status server` (direct target) still works -------------
OUT="$(bash "$SERVERCTL" status server 2>"$WORK/err")" || fail "status server failed: $(cat "$WORK/err")"
echo "$OUT" | grep -q '^server:' || fail "status server: no 'server' line in output (manual-debug target unreachable):
$OUT"

# --- 3. paths.sh helpers resolve llama-swap correctly ----------------------
DS4_SCRIPT_DIR="$REPO/scripts"
export DS4_SCRIPT_DIR
# shellcheck source=scripts/lib/root.sh
. "$DS4_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/paths.sh
. "$DS4_SCRIPT_DIR/lib/paths.sh"

_ds4_valid_svc llama-swap || fail "_ds4_valid_svc llama-swap: expected success"

GOT="$(_ds4_log_dir llama-swap)"
EXPECT="$HOME/Library/Logs/llama-swap"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_log_dir llama-swap: expected '$EXPECT', got '$GOT'"

GOT="$(_ds4_log_file llama-swap)"
EXPECT="$HOME/Library/Logs/llama-swap/llama-swap.log"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_log_file llama-swap: expected '$EXPECT', got '$GOT'"

GOT="$(_ds4_pgrep_pattern llama-swap)"
EXPECT="llama-swap.*config.yaml"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_pgrep_pattern llama-swap: expected '$EXPECT', got '$GOT'"

GOT="$(_ds4_wrapper_script llama-swap)"
EXPECT="llama-swap.sh"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_wrapper_script llama-swap: expected '$EXPECT', got '$GOT'"

# --- 4. lifecycle.sh _ds4_cmd builds the correct llama-swap invocation -----
# shellcheck source=scripts/lib/launchd.sh
. "$DS4_SCRIPT_DIR/lib/launchd.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$DS4_SCRIPT_DIR/lib/lifecycle.sh"

unset LLAMA_SWAP_HOST LLAMA_SWAP_PORT
CMD="$(_ds4_cmd llama-swap)"
case "$CMD" in
    *"$LLAMA_SWAP_ROOT/config.yaml"*) ;;
    *) fail "_ds4_cmd llama-swap (defaults): missing config.yaml path reference (expected '$LLAMA_SWAP_ROOT/config.yaml'): $CMD" ;;
esac
case "$CMD" in
    *127.0.0.1:18080*) ;;
    *) fail "_ds4_cmd llama-swap (defaults): expected 127.0.0.1:18080, got: $CMD" ;;
esac

LLAMA_SWAP_HOST=0.0.0.0 LLAMA_SWAP_PORT=9999
export LLAMA_SWAP_HOST LLAMA_SWAP_PORT
CMD="$(_ds4_cmd llama-swap)"
case "$CMD" in
    *0.0.0.0:9999*) ;;
    *) fail "_ds4_cmd llama-swap (overridden host/port): expected 0.0.0.0:9999, got: $CMD" ;;
esac
case "$CMD" in
    *127.0.0.1:18080*) fail "_ds4_cmd llama-swap (overridden host/port): still contains default 127.0.0.1:18080: $CMD" ;;
    *) ;;
esac

echo "PASS: test-llama-swap-target"
