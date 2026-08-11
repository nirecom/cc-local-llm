#!/usr/bin/env bash
# Tests: scripts/lib/lifecycle.sh
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Scenario: _ds4_cmd server emits the exact ds4-server launch flag string
# (issue #34: --batched-session 2 added, --kv-cache-continued-interval-tokens
# raised 25000 -> 50000); _ds4_cmd proxy is locked symmetrically.
#
# Skips (exit 77) until scripts/lib/lifecycle.sh exists.
# TL3 gap (what this test does NOT catch):
# - whether the real ds4-server binary actually accepts `--batched-session 2` (an unknown option exits 2)
# - whether the running launchd LaunchAgent picks up the new flags
# Closest-to-action mitigation: verified at user_verification via a non-destructive
# `ds4-server --help`-based flag-acceptance check before commit, and via `ps -o args=`
# after the post-merge restart.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LIFECYCLE="$REPO/scripts/lib/lifecycle.sh"

[ -f "$LIFECYCLE" ] || { echo "SKIP: $LIFECYCLE not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with a stub auth token so the start guard sees a value.
export DOTENV_FILE="$WORK/dotenv"
printf 'DS4_PROXY_AUTH_TOKEN=test-token\n' > "$DOTENV_FILE"
trap 'rm -rf "$WORK"' EXIT

# _ds4_cmd server interpolates $HOME (--kv-disk-dir) and $HOST (from
# DS4_SERVER_HOST, default 127.0.0.1). Pin both so the expected literal below is
# deterministic; unsetting DS4_SERVER_HOST exercises the default branch.
export HOME="$WORK/home"
mkdir -p "$HOME"
unset DS4_SERVER_HOST

# lifecycle.sh starts with `set -eu`, which would leak into this shell if sourced
# directly — isolate it in a subshell and capture only the command string.
CMD="$(bash -c '. "$1"; _ds4_cmd server' _ "$LIFECYCLE")" || fail "_ds4_cmd server exited non-zero"

EXPECT="caffeinate -ism ./ds4-server --metal --quality --ctx 393216 --kv-disk-dir \"$HOME/Library/Caches/ds4-server/kv\" --kv-disk-space-mb 32768 --kv-cache-cold-max-tokens 90000 --kv-cache-continued-interval-tokens 50000 --warm-weights --batched-session 2 --host \"127.0.0.1\""

# --- A. Full-string equality lock (primary) ---------------------------------
# Catches flag addition, removal, reordering, and value changes in one shot.
[ "$CMD" = "$EXPECT" ] || fail "_ds4_cmd server command string does not match the expected launch flags
  expected: $EXPECT
  actual:   $CMD
  If the ds4-server flags were changed intentionally, this test's expected value must be updated too."

# --- B. Per-flag diagnostic assertions --------------------------------------
# Deliberately overlapping with A: A reports the whole diff, B names the flag.
case "$CMD" in
    *"--batched-session 2"*) ;;
    *) fail "--batched-session 2 is missing from the ds4-server launch command" ;;
esac

case "$CMD" in
    *"--kv-cache-continued-interval-tokens 50000"*) ;;
    *) fail "--kv-cache-continued-interval-tokens 50000 is missing from the ds4-server launch command" ;;
esac

case "$CMD" in
    *"--kv-cache-continued-interval-tokens 25000"*)
        fail "--kv-cache-continued-interval-tokens is still 25000 (expected 50000)" ;;
esac

# --- C. Sibling lock: the proxy branch (CPR-ORTH) ---------------------------
# _ds4_cmd has exactly two branches; locking only `server` would be asymmetric.
PROXY_CMD="$(bash -c '. "$1"; _ds4_cmd proxy' _ "$LIFECYCLE")" || fail "_ds4_cmd proxy exited non-zero"
PROXY_EXPECT="env PYTHONUNBUFFERED=1 uv run python -m proxy.server"
[ "$PROXY_CMD" = "$PROXY_EXPECT" ] || fail "_ds4_cmd proxy command string changed
  expected: $PROXY_EXPECT
  actual:   $PROXY_CMD
  If the proxy launch command was changed intentionally, this test's expected value must be updated too."

echo "PASS: test-server-flags"
