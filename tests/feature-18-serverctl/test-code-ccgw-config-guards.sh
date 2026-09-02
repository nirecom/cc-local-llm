#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, client-launcher, config, security, robustness
#
# Scenario (issue #89): config.yaml became the launcher's only source of routing
# keys, so its parser now reads a file the operator edits by hand and hands the
# result to a child process. This suite is the hostile and degenerate half of
# that contract -- collisions, shell metacharacters, and unreadable input --
# while test-code-ccgw-config-tiers.sh owns the well-formed map.
set -u

# TL3 gap: nothing here proves what a real LiteLLM does with the same file --
# whether it accepts `ccgw_tiers` as an extra key, and whether a rejected route
# would have resolved anyway. Only the live stack answers that; the mitigation
# is the docs/ops.md cutover smoke run at USER_VERIFIED.

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LAUNCHER="$REPO/scripts/code-ccgw.sh"

[ -f "$LAUNCHER" ] || { echo "SKIP: $LAUNCHER not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # assert_eq <name> <want> <got> -- fail-fast; see config-tiers case 3
    [ "$2" = "$3" ] || fail "$1: want='$2' got='$3'"
}

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

DUMP="$WORK/env.dump"
ARGV="$WORK/argv.dump"
OPS="$WORK/ops"
CONFIG="$OPS/litellm-server/config.yaml"
mkdir -p "$OPS/litellm-server"

# The file every injection case watches. Its absence is the assertion: if any
# candidate model_name reached a shell, `touch` would have created it.
MARKER="$WORK/pwned"

DOTENV="$WORK/dotenv"
printf '# intentionally empty: no case here reads a routing key from .env\n' > "$DOTENV"

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/code" <<'EOF'
#!/bin/bash
env > "$CCGW_TEST_DUMP"
printf '%s\n' "$@" > "$CCGW_TEST_ARGV"
EOF
chmod +x "$STUB/code"
printf '#!/bin/bash\nprintf %%s\\\\n Darwin\n' > "$STUB/uname"
chmod +x "$STUB/uname"
STUB_PATH="$STUB:/usr/bin:/bin"

RC=0
run_launcher() {
    rm -f "$DUMP" "$ARGV"
    env -i \
        HOME="$HOME" PATH="$STUB_PATH" DOTENV_FILE="$DOTENV" \
        CCGW_OPS_ROOT="$OPS" CCGW_AUTO_PULL=off \
        CCGW_TEST_DUMP="$DUMP" CCGW_TEST_ARGV="$ARGV" \
        LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
        bash "$LAUNCHER" >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

dump_get() { grep -m1 "^$1=" "$DUMP" | cut -d= -f2-; }

# `dump_get` cannot tell "never exported" from "exported as the empty string":
# the dump is `env` output, which lists exported names only, so both read back
# as "". A refused route has to be the FIRST of those -- an exported-but-empty
# ANTHROPIC_DEFAULT_OPUS_MODEL is precisely the failure case 3's `empty` row
# exists to forbid, and asserting `"" = "$(dump_get ...)"` would call it a pass.
# Asking whether the LINE is present is the only assertion that separates them.
# Same shape as test-code-ccgw-posix.sh and code-ccgw-config-tiers/fixture.sh
# (CPR-ORTH). The dump's own existence is checked first: grep over a file that
# was never written returns "no match" too, and a launcher that started no child
# at all would otherwise satisfy every reject row here for the wrong reason.
assert_unset() { # assert_unset <var> <context>
    [ -f "$DUMP" ] || fail "$2: stub 'code' was never reached (no env dump); stderr: $(cat "$WORK/err" 2>/dev/null)"
    ! grep -q "^$1=" "$DUMP" \
        || fail "$2: $1 was exported as '$(dump_get "$1")' but must not be set at all"
}

assert_stderr() { grep -q "$1" "$WORK/err" || fail "$2: expected stderr to match '$1', got: $(cat "$WORK/err")"; }
assert_no_child() { [ ! -f "$DUMP" ] || fail "$1: the client was launched anyway (env dump written)"; }

# Every reject row below rests on assert_unset, and the whole point of the
# helper is that it says no where assert_eq "" said yes -- so prove it against a
# dump that plainly exports the name empty before trusting a quiet pass. The
# subshell keeps `fail`'s exit inside the check.
(
    DUMP="$WORK/selftest.dump"
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=\n' > "$DUMP"
    assert_unset ANTHROPIC_DEFAULT_OPUS_MODEL "harness self-test"
) 2>/dev/null \
    && fail "harness: assert_unset accepted a dump exporting the name as the empty string; every reject row below is vacuous"
rm -f "$WORK/selftest.dump"

# One route claiming opus, next to a fixed neighbour claiming haiku: every case
# below can then say both "the bad route was refused" and "its neighbour was
# not" from the same run (CPR-ORTH).
probe_config() { # probe_config <model_name-for-the-opus-route>
    {
        printf 'model_list:\n'
        printf '  - model_name: guard-neighbour\n    litellm_params:\n'
        printf '      model: openai/Backend-N\n      ccgw_tiers: [haiku]\n\n'
        printf '  - model_name: %s\n    litellm_params:\n' "$1"
        printf '      model: openai/Backend-P\n      ccgw_tiers: [opus]\n'
    } > "$CONFIG"
}

# --- Case 1: two routes claiming one tier is reported, not silently resolved -
# Whichever route wins, the operator's file says two things at once and one of
# them is not happening. Refusing to launch would strand them with no client,
# so the contract is: warn naming the tier, take the FIRST claimant, keep going,
# and leave the tiers nobody duplicated exactly as they were. First-wins rather
# than "either one" because a resolution that depends on the reader's iteration
# order is one that can differ between the two launchers on the same file.
cat > "$CONFIG" <<'EOF'
model_list:
  - model_name: dup-first
    litellm_params:
      model: openai/Backend-A
      ccgw_tiers: [haiku, opus]

  - model_name: dup-second
    litellm_params:
      model: openai/Backend-B
      ccgw_tiers: [opus]

  - model_name: dup-bystander
    litellm_params:
      model: anthropic/Backend-C
      ccgw_tiers: [fable]
EOF
run_launcher
[ "$RC" -eq 0 ] || fail "case 1: exited $RC over a duplicate claim; the other tiers are still usable: $(cat "$WORK/err")"
assert_stderr 'opus' "case 1: the collision warning must name the tier that was claimed twice"
assert_eq "case 1: the first claimant in document order wins" \
    dup-first "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
assert_eq "case 1: the tier claimed once on a colliding route still maps" \
    dup-first "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
assert_eq "case 1: a route in no collision at all is untouched" \
    dup-bystander "$(dump_get ANTHROPIC_DEFAULT_FABLE_MODEL)"

# --- Case 2: a model_name carrying shell syntax is refused, not executed -----
# config.yaml is hand-edited and version-controlled, so a hostile value arrives
# through a pull, not a prompt. The value flows from the parser into a child's
# environment; any implementation that builds a command string on the way --
# eval, sh -c, unquoted expansion -- runs it. The marker file is the probe:
# it exists only if something got executed. @MARKER@/@PIPE@ stand in for the
# path and for `|`, which is this table's field separator.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    input="${input//@MARKER@/$MARKER}"
    input="${input//@PIPE@/|}"

    rm -f "$MARKER"
    probe_config "$input"
    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 2/$name: exited $RC although the neighbour route is well-formed: $(cat "$WORK/err")"
    [ ! -e "$MARKER" ] || fail "case 2/$name: the model_name was executed -- '$input' created $MARKER"
    if [ -z "$want" ]; then
        assert_unset ANTHROPIC_DEFAULT_OPUS_MODEL \
            "case 2/$name: the refused model_name must leave the opus tier unset, not exported empty"
    else
        assert_eq "case 2/$name: opus mapping" "$want" "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
    fi
    assert_eq "case 2/$name: the neighbour route must survive its bad sibling" \
        guard-neighbour "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
done <<'TABLE'
control-valid  | safe-route.v1                | safe-route.v1
semicolon      | a;touch @MARKER@             |
ampersand      | a&touch @MARKER@             |
pipe           | a@PIPE@touch @MARKER@        |
backtick       | `touch @MARKER@`             |
dollar-paren   | $(touch @MARKER@)            |
dollar-brace   | ${IFS}touch @MARKER@         |
redirect       | a>@MARKER@                   |
newline-escape | a\ntouch @MARKER@            |
inner-space    | a touch @MARKER@             |
quote          | a"b                          |
path-traversal | ../../../etc/passwd          |
TABLE

# --- Case 3: model_name length boundaries ------------------------------------
# The empty name is the one that matters: exporting it would hand Claude Code a
# tier that resolves to nothing, which reads at the far end as a model that
# stopped existing. One character is the shortest legal name, and a long one
# must arrive whole -- a truncating parser would route to a key LiteLLM has
# never heard of, silently.
LONG_NAME="$(printf 'x%.0s' $(seq 1 200))"
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    input="${input//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    [ "$input" = "@LONG@" ] && input="$LONG_NAME"
    [ "$want" = "@LONG@" ] && want="$LONG_NAME"

    probe_config "$input"
    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 3/$name: exited $RC: $(cat "$WORK/err")"
    if [ -z "$want" ]; then
        assert_unset ANTHROPIC_DEFAULT_OPUS_MODEL \
            "case 3/$name: an unusable name must leave the tier unset -- exported-and-empty is the exact shape this row forbids"
    else
        assert_eq "case 3/$name: opus mapping" "$want" "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
    fi
    assert_eq "case 3/$name: the neighbour route is unaffected" \
        guard-neighbour "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
done <<'TABLE'
empty       |         |
one-char    | a       | a
two-hundred | @LONG@  | @LONG@
TABLE

# --- Case 4: an empty config.yaml is a hard failure --------------------------
# The file exists, so the "cannot read it" path never fires; it simply claims
# no tiers, which is case 7 of the tiers suite arriving by a different route.
: > "$CONFIG"
run_launcher
[ "$RC" -ne 0 ] || fail "case 4: exited 0 on an empty config.yaml, which maps no tier at all"
assert_stderr 'config.yaml\|ccgw_tiers\|ccgw-tiers' "case 4: the error must name the file or the annotation it found nothing of"
assert_no_child "case 4"

# --- Case 5: a config.yaml with a model_list and nothing under it ------------
# The degenerate shape a half-finished edit leaves behind, and the one a parser
# that trusts `model_list:` to be followed by items can crash on.
printf 'model_list:\n' > "$CONFIG"
run_launcher
[ "$RC" -ne 0 ] || fail "case 5: exited 0 on a model_list with no routes"
assert_no_child "case 5"

# --- Case 6: an unreadable config.yaml fails loudly --------------------------
# Distinct from "missing": a `chmod 600` file owned by root, or a repo checked
# out with the wrong umask, must not read as "no annotations" and must not read
# as an empty map either. Skipped where the filesystem does not enforce the
# mode (Windows, or running as root), since the case would not be exercised.
probe_config unreadable-probe
chmod 000 "$CONFIG" 2>/dev/null
if [ -r "$CONFIG" ]; then
    echo "note: case 6 skipped -- this filesystem/user ignores mode 000"
else
    run_launcher
    [ "$RC" -ne 0 ] || fail "case 6: exited 0 although config.yaml could not be read"
    assert_stderr 'config.yaml' "case 6: the error must name the file it could not read"
    assert_no_child "case 6"
fi
chmod 644 "$CONFIG" 2>/dev/null

# --- Case 7: a model_name that reads as a YAML scalar ------------------------
# `null`, `true`, `no`, `123` are ordinary names to `[A-Za-z0-9._-]+` and
# reserved literals to a YAML reader. The launcher matches lines, so the only
# answer it may give is the raw token -- byte for byte, the same one the Python
# mirror (case 10c of test_route_tier_annotations_2.py) and the PowerShell
# sibling (It '16k') give. A reader that normalises `no` to `false` exports a
# routing key the file does not contain, and the operator sees a /model entry
# that resolves nowhere while both files still read as correct. What a real
# LiteLLM makes of these rows is the TL3 gap at the top of this file.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    input="${input//[[:space:]]/}"
    want="${want//[[:space:]]/}"

    probe_config "$input"
    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 7/$name: exited $RC although the neighbour route is well-formed: $(cat "$WORK/err")"
    # `~` is the single row outside the name class, and it is refused like any
    # other illegal character: left unset, never exported empty.
    if [ -z "$want" ]; then
        assert_unset ANTHROPIC_DEFAULT_OPUS_MODEL \
            "case 7/$name: '$input' is outside the name class, so the opus tier must be left unset"
    else
        assert_eq "case 7/$name: the raw token must reach the child unchanged" \
            "$want" "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
    fi
    assert_eq "case 7/$name: the neighbour route is unaffected" \
        guard-neighbour "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
done <<'TABLE'
null-literal  | null  | null
tilde-null    | ~     |
true-literal  | true  | true
false-literal | false | false
yes-literal   | yes   | yes
no-literal    | no    | no
integer       | 123   | 123
float         | 1.5   | 1.5
TABLE

echo "PASS: test-code-ccgw-config-guards"
