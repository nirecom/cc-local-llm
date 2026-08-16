#!/usr/bin/env bash
# Tests: scripts/lib/launchd.sh, scripts/lib/paths.sh, scripts/ccgw-proxy.sh
# Tags: lifecycle, serverctl, launchd, path, scope:issue-specific
#
# Scenario (issue #41 / detail plan D6): launchd hands a LaunchAgent a minimal
# PATH, so _ds4_write_plist has to state where the service binaries live. It
# currently prepends only uv's directory, which means llama-swap
# (/opt/homebrew/bin) and litellm ($HOME/.local/bin) are unresolvable under
# launchd even though they work fine in an interactive shell — the failure
# only shows up after `serverctl install`, as a KeepAlive respawn loop.
#
# The generalization resolves uv, llama-swap and litellm through `command -v`
# and prepends each distinct directory. This test drives that with three stub
# directories, so it never depends on what is installed on the host.
#
# Deduplication is asserted separately: the three binaries usually share a
# directory in real life, and a naive implementation would emit it three times.
#
# Skips (exit 77) until scripts/lib/launchd.sh exists (implementation pending).
#
# TL3 gap: whether launchd actually resolves the binaries from the emitted PATH
#   at load time. Only a real `launchctl load` on macOS answers that; covered by
#   the post-merge restart check in docs/ops.md at user_verification.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LAUNCHD="$REPO/scripts/lib/launchd.sh"

[ -f "$LAUNCHD" ] || { echo "SKIP: $LAUNCHD not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
export DOTENV_FILE="$WORK/dotenv"
printf 'CCGW_PROXY_AUTH_TOKEN=test-token\n' > "$DOTENV_FILE"
export HOME="$WORK/home"
mkdir -p "$HOME/Library/LaunchAgents"
trap 'rm -rf "$WORK"' EXIT

CCGW_SCRIPT_DIR="$REPO/scripts"
export CCGW_SCRIPT_DIR
PLIST="$HOME/Library/LaunchAgents/com.nire.ccgw-proxy.plist"

# lifecycle.sh / launchd.sh carry `set -eu`, so the plist is generated in an
# isolated subshell rather than by sourcing into this shell.
write_plist() {
    rm -f "$PLIST"
    env PATH="$1" HOME="$HOME" CCGW_SCRIPT_DIR="$CCGW_SCRIPT_DIR" DOTENV_FILE="$DOTENV_FILE" \
        sh -c '
            . "$CCGW_SCRIPT_DIR/lib/root.sh"
            . "$CCGW_SCRIPT_DIR/lib/paths.sh"
            . "$CCGW_SCRIPT_DIR/lib/launchd.sh"
            . "$CCGW_SCRIPT_DIR/lib/lifecycle.sh"
            _ds4_write_plist proxy
        ' || fail "_ds4_write_plist proxy exited non-zero (PATH=$1)"
    [ -f "$PLIST" ] || fail "_ds4_write_plist proxy did not write $PLIST"
}

# Extract the single PATH <string> that follows the PATH <key> in the plist.
plist_path_value() {
    grep -A1 '<key>PATH</key>' "$PLIST" | grep '<string>' \
        | sed -e 's/.*<string>//' -e 's|</string>.*||'
}

# Extract the second <string> entry under ProgramArguments — the wrapper
# script path launchd actually execs (the first entry is always /bin/sh).
plist_program_argument() {
    grep -A3 '<key>ProgramArguments</key>' "$PLIST" | tail -1 \
        | sed -e 's/.*<string>//' -e 's|</string>.*||'
}

# --- Stub binaries in three distinct directories ----------------------------
UVDIR="$WORK/bin-uv"
SWAPDIR="$WORK/bin-swap"
LLMDIR="$WORK/bin-litellm"
mkdir -p "$UVDIR" "$SWAPDIR" "$LLMDIR"
printf '#!/bin/sh\nexit 0\n' > "$UVDIR/uv"
printf '#!/bin/sh\nexit 0\n' > "$SWAPDIR/llama-swap"
printf '#!/bin/sh\nexit 0\n' > "$LLMDIR/litellm"
chmod +x "$UVDIR/uv" "$SWAPDIR/llama-swap" "$LLMDIR/litellm"

BASE_PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- 1. All three directories are present in the emitted PATH ---------------
write_plist "$UVDIR:$SWAPDIR:$LLMDIR:$BASE_PATH"
VAL="$(plist_path_value)"
[ -n "$VAL" ] || fail "no PATH value found in $PLIST"

case ":$VAL:" in
    *":$UVDIR:"*) ;;
    *) fail "uv's directory is missing from the launchd PATH: $VAL" ;;
esac
case ":$VAL:" in
    *":$SWAPDIR:"*) ;;
    *) fail "llama-swap's directory is missing from the launchd PATH — the LaunchAgent cannot start it: $VAL" ;;
esac
case ":$VAL:" in
    *":$LLMDIR:"*) ;;
    *) fail "litellm's directory is missing from the launchd PATH — the LaunchAgent cannot start it: $VAL" ;;
esac

# --- 1b. ProgramArguments points at the renamed ccgw-proxy.sh wrapper -------
# issue #51: the proxy service's launcher script and wrapper-filename lookup
# (_ds4_wrapper_script) move from the old proxy launcher script to
# ccgw-proxy.sh. If write-code renamed the file but forgot to update
# _ds4_wrapper_script (or vice versa),
# the LaunchAgent would exec a nonexistent path and fail silently at load
# time — nothing else in this suite pins the actual exec target.
ARG="$(plist_program_argument)"
EXPECT_WRAPPER="$CCGW_SCRIPT_DIR/ccgw-proxy.sh"
[ "$ARG" = "$EXPECT_WRAPPER" ] || fail "ProgramArguments for proxy: expected '$EXPECT_WRAPPER', got '$ARG'"
[ -f "$EXPECT_WRAPPER" ] || fail "the renamed launcher script does not exist on disk: $EXPECT_WRAPPER (the old proxy launcher script under scripts/ must be git mv'd to scripts/ccgw-proxy.sh)"

# --- 2. The system defaults survive, and the resolved dirs come first -------
case ":$VAL:" in
    *":/usr/bin:"*) ;;
    *) fail "the system default PATH segment was dropped: $VAL" ;;
esac

FIRST="${VAL%%:*}"
case "$FIRST" in
    "$UVDIR"|"$SWAPDIR"|"$LLMDIR") ;;
    *) fail "a resolved binary directory must be prepended, but PATH starts with '$FIRST': $VAL" ;;
esac

# --- 3. No duplicate entries ------------------------------------------------
DUPES="$(printf '%s\n' "$VAL" | tr ':' '\n' | grep -v '^$' | sort | uniq -d)"
[ -z "$DUPES" ] || fail "launchd PATH contains duplicate entries:
$DUPES
  full value: $VAL"

# --- 4. Shared directory case: emitted once, not three times ---------------
# The realistic layout (all three under one prefix) is exactly where a naive
# concatenation repeats itself.
SHARED="$WORK/bin-shared"
mkdir -p "$SHARED"
for b in uv llama-swap litellm; do
    printf '#!/bin/sh\nexit 0\n' > "$SHARED/$b"
    chmod +x "$SHARED/$b"
done

write_plist "$SHARED:$BASE_PATH"
VAL="$(plist_path_value)"
COUNT="$(printf '%s\n' "$VAL" | tr ':' '\n' | grep -c "^$SHARED$")"
[ "$COUNT" = "1" ] || fail "the shared binary directory appears $COUNT time(s) in the launchd PATH (expected exactly 1): $VAL"

# --- 5. Missing binary: degrade, never emit an empty entry -----------------
# On a host where litellm is not installed yet, the PATH must stay well-formed
# (no leading/trailing/double colon, which would put CWD on launchd's PATH).
write_plist "$UVDIR:$BASE_PATH"
VAL="$(plist_path_value)"
case "$VAL" in
    :*) fail "launchd PATH starts with an empty entry (CWD would be searched): $VAL" ;;
    *:) fail "launchd PATH ends with an empty entry (CWD would be searched): $VAL" ;;
esac
case "$VAL" in
    *::*) fail "launchd PATH contains an empty entry (CWD would be searched): $VAL" ;;
    *) ;;
esac
case ":$VAL:" in
    *":$UVDIR:"*) ;;
    *) fail "uv's directory was dropped when the other binaries were absent: $VAL" ;;
esac

echo "PASS: test-launchd-path"
