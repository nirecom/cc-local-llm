#!/usr/bin/env bash
# Tests: scripts/lib/load-dotenv.sh
# Tags: scope:issue-specific, layer:TL1
# Scenario (issue #56): an #@if windows / #@if posix / #@endif marker filter
# (_dotenv_filter_os_blocks) is being added to the loader so a single .env can
# carry platform-specific lines. It does NOT exist yet in the source as of
# this writing -- written FIRST against the 13-case reference spec in the
# issue #56 detail plan, so implementation has a red suite to turn green.
# Method: see test-code-ccgw-posix.sh's env -i sh -c + uname-stub pattern.

set -u

REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LOADER="$REPO/scripts/lib/load-dotenv.sh"

[ -f "$LOADER" ] || { echo "SKIP: $LOADER not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

DUMP="$WORK/env.dump"

# --- uname stubs -------------------------------------------------------------
# Reused/adapted from test-code-ccgw-posix.sh's make_uname (around its line 69).
make_uname() { # make_uname <dir> <sysname>
    mkdir -p "$1"
    printf '#!/bin/bash\nprintf %%s\\\\n %s\n' "$2" > "$1/uname"
    chmod +x "$1/uname"
}
WIN_STUB="$WORK/stub-win"
make_uname "$WIN_STUB" "MINGW64_NT-10.0-19045"
POSIX_STUB="$WORK/stub-posix"
make_uname "$POSIX_STUB" "Darwin"

# --- fixture writers -----------------------------------------------------
write_fixture() { # write_fixture <path> <line>...
    local f="$1"; shift
    : > "$f"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$f"
    done
}
write_fixture_crlf() { # write_fixture_crlf <path> <line>...
    local f="$1"; shift
    : > "$f"
    local line
    for line in "$@"; do
        printf '%s\r\n' "$line" >> "$f"
    done
}

# --- loader runner -------------------------------------------------------
# `env` (the second/final one, printing the resulting environment) is what we
# assert against: it captures exactly what the loader exported, without
# re-implementing any of the loader's own parsing here.
run_dotenv() { # run_dotenv <dotenv-file> <uname-stub-dir>
    rm -f "$DUMP"
    env -i \
        PATH="$2:/usr/bin:/bin" \
        HOME="$WORK/home" \
        DOTENV_FILE="$1" \
        LOADER="$LOADER" \
        sh -c '. "$LOADER"; env' > "$DUMP" 2>"$WORK/err"
    RC=$?
}

dump_get() { grep -m1 "^$1=" "$DUMP" | cut -d= -f2-; }

assert_env() { # assert_env <var> <expected> <context>
    [ -f "$DUMP" ] || fail "$3: loader child produced no env dump; stderr: $(cat "$WORK/err")"
    grep -q "^$1=" "$DUMP" || fail "$3: $1 was not exported at all (expected '$2')"
    local got; got="$(dump_get "$1")"
    [ "$got" = "$2" ] || fail "$3: $1='$got', expected '$2'"
}

assert_unset() { # assert_unset <var> <context>
    ! grep -q "^$1=" "$DUMP" || fail "$2: $1 was exported as '$(dump_get "$1")' but must not be set at all"
}

assert_no_marker_leak() { # assert_no_marker_leak <context>
    local hit
    hit="$(grep -E '#@if|#@endif' "$DUMP" || true)"
    [ -z "$hit" ] || fail "$1: marker syntax leaked into the loaded environment: $hit"
}

# =============================================================================
# --- Case 1: basic branching ------------------------------------------------
# [env-conditional-blocks: case 1]
write_fixture "$WORK/case1.env" \
    '#@if windows' \
    'BASIC_KEY=win_value' \
    '#@endif' \
    '#@if posix' \
    'BASIC_KEY=posix_value' \
    '#@endif'

run_dotenv "$WORK/case1.env" "$WIN_STUB"
assert_env BASIC_KEY win_value "case 1 (windows): only the windows block's value must survive"
# --- Case 2: marker lines never appear in output (explicit on top of case 1) -
# [env-conditional-blocks: case 2]
assert_no_marker_leak "case 2 (windows)"

run_dotenv "$WORK/case1.env" "$POSIX_STUB"
assert_env BASIC_KEY posix_value "case 1 (posix): only the posix block's value must survive"
assert_no_marker_leak "case 2 (posix)"

# --- Case 3: normal lines outside any block are unconditional --------------
# [env-conditional-blocks: case 3]
write_fixture "$WORK/case3.env" \
    '# a plain comment' \
    'PLAIN_KEY=plain_value'
run_dotenv "$WORK/case3.env" "$WIN_STUB"
assert_env PLAIN_KEY plain_value "case 3 (windows): plain KEY=VALUE outside any block always loads"
run_dotenv "$WORK/case3.env" "$POSIX_STUB"
assert_env PLAIN_KEY plain_value "case 3 (posix): plain KEY=VALUE outside any block always loads"

# --- Case 4: blank lines outside marker blocks are preserved ---------------
# [env-conditional-blocks: case 4]
# A filter bug that fused a blank line into the line before/after it (instead
# of passing it through untouched) would surface here as AFTER_KEY going
# missing even though it sits outside every block.
write_fixture "$WORK/case4.env" \
    'BEFORE_KEY=before_value' \
    '' \
    'AFTER_KEY=after_value'
run_dotenv "$WORK/case4.env" "$WIN_STUB"
assert_env BEFORE_KEY before_value "case 4 (windows): line before a blank line loads"
assert_env AFTER_KEY after_value "case 4 (windows): line after a blank line still loads"
run_dotenv "$WORK/case4.env" "$POSIX_STUB"
assert_env BEFORE_KEY before_value "case 4 (posix): line before a blank line loads"
assert_env AFTER_KEY after_value "case 4 (posix): line after a blank line still loads"

# --- Case 5: nesting doesn't leak -- inactive outer swallows a would-be-active
#             nested block ---------------------------------------------------
# [env-conditional-blocks: case 5]
write_fixture "$WORK/case5.env" \
    '#@if windows' \
    'OUTER_KEY=outer_should_not_appear' \
    '#@if posix' \
    'INNER_KEY=inner_should_not_appear' \
    '#@endif' \
    '#@endif'
run_dotenv "$WORK/case5.env" "$POSIX_STUB"
assert_unset OUTER_KEY "case 5 (posix): outer #@if windows is inactive; its content must stay suppressed"
assert_unset INNER_KEY "case 5 (posix): nested #@if posix must NOT reactivate inside an inactive outer block (suppressDepth pins at the outer depth)"

# --- Case 6: nesting doesn't leak the other way -- active outer only removes
#             the nested inactive block --------------------------------------
# [env-conditional-blocks: case 6]
write_fixture "$WORK/case6.env" \
    '#@if posix' \
    'BEFORE_KEY=before_value' \
    '#@if windows' \
    'NESTED_KEY=nested_should_not_appear' \
    '#@endif' \
    'AFTER_KEY=after_value' \
    '#@endif'
run_dotenv "$WORK/case6.env" "$POSIX_STUB"
assert_env BEFORE_KEY before_value "case 6 (posix): outer #@if posix is active; lines before the nested block load"
assert_unset NESTED_KEY "case 6 (posix): nested #@if windows is inactive on posix and must be removed"
assert_env AFTER_KEY after_value "case 6 (posix): lines after the nested block, still inside the active outer block, load"

# --- Case 7: unknown token -- suppressed on both platforms, marker removed --
# [env-conditional-blocks: case 7]
write_fixture "$WORK/case7.env" \
    '#@if darwin' \
    'UNKNOWN_TOKEN_KEY=should_never_appear' \
    '#@endif'
run_dotenv "$WORK/case7.env" "$WIN_STUB"
assert_unset UNKNOWN_TOKEN_KEY "case 7 (windows): an unrecognized token must suppress its block"
run_dotenv "$WORK/case7.env" "$POSIX_STUB"
assert_unset UNKNOWN_TOKEN_KEY "case 7 (posix): an unrecognized token must suppress its block on posix too"

# --- Case 8: non-strict spelling ("#@ifwindows", no space) opens no block --
# [env-conditional-blocks: case 8]
write_fixture "$WORK/case8.env" \
    '#@ifwindows' \
    'FOLLOW_KEY=should_always_appear' \
    '#@endif'
run_dotenv "$WORK/case8.env" "$WIN_STUB"
assert_env FOLLOW_KEY should_always_appear "case 8 (windows): '#@ifwindows' (no space) is an unknown marker, not #@if -- it opens no block"
run_dotenv "$WORK/case8.env" "$POSIX_STUB"
assert_env FOLLOW_KEY should_always_appear "case 8 (posix): same -- the following line is a normal line, not suppressed"

# --- Case 9: an orphan #@endif is ignored -----------------------------------
# [env-conditional-blocks: case 9]
write_fixture "$WORK/case9.env" \
    'BEFORE_KEY=before_value' \
    '#@endif' \
    'AFTER_KEY=after_value'
run_dotenv "$WORK/case9.env" "$WIN_STUB"
assert_env BEFORE_KEY before_value "case 9 (windows): line before an orphan #@endif loads"
assert_env AFTER_KEY after_value "case 9 (windows): line after an orphan #@endif still loads (no state change)"
run_dotenv "$WORK/case9.env" "$POSIX_STUB"
assert_env BEFORE_KEY before_value "case 9 (posix): line before an orphan #@endif loads"
assert_env AFTER_KEY after_value "case 9 (posix): line after an orphan #@endif still loads"

# --- Case 10: "#@endif foo" (trailing text) never closes the block ---------
# [env-conditional-blocks: case 10]
# Deliberately non-lenient: only an EXACT "#@endif" line closes a block. This
# is the documented contract, not a bug to soften -- the case must fail if a
# future change makes trailing text after #@endif forgiving.
write_fixture "$WORK/case10.env" \
    '#@if posix' \
    'INSIDE_KEY=inside_value' \
    '#@endif foo' \
    'AFTER_KEY=after_value'
run_dotenv "$WORK/case10.env" "$WIN_STUB"
assert_unset INSIDE_KEY "case 10 (windows): #@if posix is inactive on windows"
assert_unset AFTER_KEY "case 10 (windows): '#@endif foo' does not close the block (trailing text disqualifies it as #@endif), so suppression never lifts and AFTER_KEY stays swallowed"
run_dotenv "$WORK/case10.env" "$POSIX_STUB"
assert_env INSIDE_KEY inside_value "case 10 (posix): #@if posix is active, so its content loads"
assert_env AFTER_KEY after_value "case 10 (posix): still inside the (never formally closed) active block at EOF, so this line loads too -- the never-closes effect is invisible here because the block was never suppressing to begin with"

# --- Case 11: CRLF resilience -- identical to case 1's content, CRLF-saved -
# [env-conditional-blocks: case 11]
write_fixture_crlf "$WORK/case11.env" \
    '#@if windows' \
    'BASIC_KEY=win_value' \
    '#@endif' \
    '#@if posix' \
    'BASIC_KEY=posix_value' \
    '#@endif'
run_dotenv "$WORK/case11.env" "$WIN_STUB"
assert_env BASIC_KEY win_value "case 11 (windows, CRLF): CRLF-saved markers must resolve identically to LF"
run_dotenv "$WORK/case11.env" "$POSIX_STUB"
assert_env BASIC_KEY posix_value "case 11 (posix, CRLF): CRLF-saved markers must resolve identically to LF"

# --- Case 12: whitespace-padded marker lines are still recognized ----------
# [env-conditional-blocks: case 12]
write_fixture "$WORK/case12.env" \
    '  #@if windows  ' \
    'PAD_KEY=win_value' \
    '  #@endif  ' \
    '  #@if posix  ' \
    'PAD_KEY=posix_value' \
    '  #@endif  '
run_dotenv "$WORK/case12.env" "$WIN_STUB"
assert_env PAD_KEY win_value "case 12 (windows): leading/trailing whitespace around marker lines must not prevent recognition"
run_dotenv "$WORK/case12.env" "$POSIX_STUB"
assert_env PAD_KEY posix_value "case 12 (posix): same, on the posix branch"

# --- Case 13: duplicate keys -- first occurrence wins ----------------------
# [env-conditional-blocks: case 13]
# This documents the loader's own asymmetry (it skips re-setting an
# already-non-empty env var, so whichever physical line reaches it FIRST after
# filtering wins) -- it is not a statement that this behavior should be
# unified with anything else.
write_fixture "$WORK/case13.env" \
    'DUP_KEY=first_value' \
    '#@if posix' \
    'DUP_KEY=second_value_inside_posix' \
    '#@endif'
run_dotenv "$WORK/case13.env" "$POSIX_STUB"
assert_env DUP_KEY first_value "case 13 (posix): the first physical occurrence wins; the loader skips re-setting an already-set var"

echo "PASS: test-load-dotenv-os-blocks"
