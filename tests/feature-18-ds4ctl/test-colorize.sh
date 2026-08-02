#!/usr/bin/env bash
# Tests: scripts/lib/colorize.sh
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Scenario: ds4ctl colorize — adds ANSI to ds4-server log lines; non-server lines pass through uncolored; tee'd log file stays ANSI-free (colorize is downstream of tee).
#
# Skips (exit 77) until scripts/lib/colorize.sh exists (implementation pending).
#
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
COLORIZE="$REPO/scripts/lib/colorize.sh"

[ -f "$COLORIZE" ] || { echo "SKIP: $COLORIZE not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ESC="$(printf '\033')"

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with a stub auth token so the start guard sees a value.
export DOTENV_FILE="$WORK/dotenv"
printf 'DS4_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
trap 'rm -rf "$WORK"' EXIT

# A representative ds4-server log line (kv-cache activity).
LINE='kv-cache: hit 90000 tokens, evict 25000'

# --- Terminal path: colorize wraps the line in ANSI -------------------------
out="$(printf '%s\n' "$LINE" | bash "$COLORIZE")"
case "$out" in
    *"$ESC"*) : ;;
    *) fail "colorize did not add ANSI escape to a ds4-server line (got: $out)" ;;
esac
# The visible text must survive colorization.
echo "$out" | grep -q "kv-cache" || fail "colorize dropped the original text"

# --- Non-server line: no ANSI added (only ds4-server lines are colorized) ----
PLAIN='2026-07-18 12:00:00 [INFO] proxy started'
plainout="$(printf '%s\n' "$PLAIN" | bash "$COLORIZE")"
case "$plainout" in
    *"$ESC"*) fail "colorize added ANSI to a non-ds4-server line (got: $plainout)" ;;
    *) : ;;
esac
# The original text must pass through untouched.
[ "$plainout" = "$PLAIN" ] || fail "colorize altered a non-server line (got: $plainout)"

# --- File path: colorize sits downstream of tee, so the file is ANSI-free ---
FILE="$WORK/kvcache.log"
printf '%s\n' "$LINE" | tee "$FILE" | bash "$COLORIZE" >/dev/null
if grep -q "$ESC" "$FILE"; then
    fail "tee'd log file contains ANSI escapes — colorize must be downstream of tee"
fi
grep -q "kv-cache" "$FILE" || fail "tee'd log file missing the raw line"

echo "PASS: test-colorize"
