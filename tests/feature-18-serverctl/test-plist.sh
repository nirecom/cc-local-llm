#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/launchd.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl launchd plist — Label, KeepAlive=true, RunAtLoad=true, ProgramArguments, StandardOutPath present; reinstall overwrites without duplicating.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
#
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
mkdir -p "$HOME/Library/LaunchAgents"
trap 'rm -rf "$WORK"' EXIT

# Stub launchctl so `install` cannot actually load the agent.
STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/launchctl"
chmod +x "$STUB/launchctl"

PATH="$STUB:$PATH" bash "$SERVERCTL" install proxy >"$WORK/out" 2>&1 || fail "install proxy failed: $(cat "$WORK/out")"

PLIST="$(ls "$HOME/Library/LaunchAgents"/*.plist 2>/dev/null | head -n1 || true)"
[ -n "$PLIST" ] || fail "no plist written under ~/Library/LaunchAgents"

need_key() { grep -q "<key>$1</key>" "$PLIST" || fail "plist missing <key>$1</key>"; }
need_key "Label"
need_key "ProgramArguments"
need_key "StandardOutPath"
need_key "KeepAlive"
need_key "RunAtLoad"

# KeepAlive and RunAtLoad must be boolean true.
grep -A1 "<key>KeepAlive</key>" "$PLIST" | grep -q "<true/>" || fail "KeepAlive is not <true/>"
grep -A1 "<key>RunAtLoad</key>" "$PLIST" | grep -q "<true/>" || fail "RunAtLoad is not <true/>"

# Label should identify the proxy target.
grep -A1 "<key>Label</key>" "$PLIST" | grep -qi "proxy" || fail "Label does not reference the proxy target"

# --- Reinstall overwrites in place, no duplicate plist ----------------------
PLIST_BASENAME="$(basename "$PLIST")"
PATH="$STUB:$PATH" bash "$SERVERCTL" install proxy >"$WORK/out2" 2>&1 || fail "second install proxy failed: $(cat "$WORK/out2")"

# Exactly one plist for the proxy target must exist after reinstall.
COUNT=$(ls "$HOME/Library/LaunchAgents"/*.plist 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT" = "1" ] || fail "reinstall: expected 1 plist, found $COUNT (duplicate written)"
[ -f "$HOME/Library/LaunchAgents/$PLIST_BASENAME" ] || fail "reinstall: plist $PLIST_BASENAME missing after overwrite"

# Overwritten plist must still be valid (keys intact, not appended/corrupted).
need_key "Label"
need_key "ProgramArguments"
# A single <plist> root — appending rather than overwriting would duplicate it.
PLIST_ROOTS=$(grep -c "<plist" "$HOME/Library/LaunchAgents/$PLIST_BASENAME")
[ "$PLIST_ROOTS" = "1" ] || fail "reinstall: plist has $PLIST_ROOTS <plist> roots — content duplicated, not overwritten"

echo "PASS: test-plist"
