#!/usr/bin/env bash
# Tests: scripts/ds4ctl.sh
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Scenario: ds4ctl dispatch — unknown subcommand/target exit 2 + usage; `all` expands to proxy+server.
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
# Uses a trace hook + PATH stubs so no real service is launched.
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
trap 'rm -rf "$WORK"' EXIT

# --- Stub PATH so any launchd / process probe is inert -----------------------
STUB="$WORK/stub"
mkdir -p "$STUB"
for cmd in launchctl pgrep pkill caffeinate; do
    printf '#!/bin/sh\nexit 0\n' > "$STUB/$cmd"
    chmod +x "$STUB/$cmd"
done

# ds4ctl exposes an exec-capture hook: when DS4CTL_TRACE points at a file, each
# resolved target is appended instead of acting, letting the dispatch layer be
# tested without launching services.
TRACE="$WORK/trace"
export DS4CTL_TRACE="$TRACE"
export HOME="$WORK/home"
mkdir -p "$HOME"

run() {
    PATH="$STUB:$PATH" bash "$DS4CTL" "$@" >"$WORK/out" 2>"$WORK/err"
    echo $?
}

# 1a. Unknown subcommand -> exit 2 + usage.
rc="$(run bogus proxy)"
[ "$rc" = "2" ] || fail "unknown subcommand: expected exit 2, got $rc"
grep -qi "usage" "$WORK/out" "$WORK/err" || fail "unknown subcommand: no usage text"

# 1b. Unknown target -> exit 2 + usage.
rc="$(run start bogus)"
[ "$rc" = "2" ] || fail "unknown target: expected exit 2, got $rc"
grep -qi "usage" "$WORK/out" "$WORK/err" || fail "unknown target: no usage text"

# 1c. Missing target -> exit 2 + usage.
rc="$(run start)"
[ "$rc" = "2" ] || fail "missing target: expected exit 2, got $rc"

# 1d. `all` expands to both proxy and server (trace records each).
: > "$TRACE"
rc="$(run start all)"
[ "$rc" = "0" ] || fail "start all: expected exit 0, got $rc (err: $(cat "$WORK/err"))"
grep -q "proxy" "$TRACE" || fail "start all: proxy not dispatched"
grep -q "server" "$TRACE" || fail "start all: server not dispatched"

echo "PASS: test-dispatch"
