#!/usr/bin/env bash
# Tests: scripts/set-model.sh, scripts/lib/git-remote.sh
# Tags: scope:issue-specific, layer:TL2, set-model, security, publish, timeout
#
# Scenario (issue #89): set-model.sh took on three new powers -- it rewrites a
# tracked file, restarts the gateway, and pushes. This suite is the half that
# says what it must NOT do: never execute an argument it was handed, and never
# hold the operator's terminal when the push does not come back.
# test-set-model-config-ssot.sh owns the well-formed switch.
set -u

# TL3 gap (what this suite does NOT catch):
# - a real `git push` blocking on a credential prompt or an ssh handshake,
#   which is the shape the deadline exists for
# - a real gateway restart, so "the edit is live" is never proven here
# - a filesystem that enforces modes: cases 8 and 10 skip themselves on Windows
#   and under root, where the unreadable/unwritable shapes cannot be staged
# Mitigation: the docs/ops.md cutover smoke run at USER_VERIFIED.

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SRC_SCRIPTS="$REPO/scripts"

[ -f "$SRC_SCRIPTS/set-model.sh" ] || { echo "SKIP: scripts/set-model.sh not found"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_GLOBAL="$WORK/gitconfig-global"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export XDG_CONFIG_HOME="$WORK/xdg"
mkdir -p "$XDG_CONFIG_HOME" "$WORK/tmp"
: > "$GIT_CONFIG_GLOBAL"
cd "$WORK" || fail "setup: cannot enter $WORK"

REAL_GIT="$(command -v git)" || fail "setup: git is not on PATH"

# The file every injection row watches: it exists only if an argument reached a
# shell. `touch` is the payload precisely because it is harmless.
MARKER="$WORK/pwned"

write_llamaswap() { # write_llamaswap <path>
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
models:
  win-sonnet-key:
    cmd: mlx_lm.server --model win-sonnet
  deepseek-v4-flash:
    cmd: ds4-server --model ds4
  qwen3.8-flash-next-3bit-mtp:
    cmd: mlx_lm.server --model mtp
  qwen3.8-next-80b-4bit:
    cmd: mlx_lm.server --model 80b

healthCheckTimeout: 300
EOF
}

write_config() { # write_config <path>
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      api_base: os.environ/LITELLM_LLAMASWAP_URL
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier ---
  - model_name: deepseek-v4-flash
    litellm_params:
      model: anthropic/deepseek-v4-flash
      api_base: os.environ/LITELLM_CCGW_PROXY_URL
      ccgw_tiers: [fable]

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      api_base: os.environ/LITELLM_CCGW_PROXY_OPENAI_URL
      ccgw_tiers: [opus, subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
}

FIXN=0
FIX=""
BARE=""
new_fixture() { # new_fixture -- an ops root that is a git repo with a bare remote
    FIXN=$(( FIXN + 1 ))
    FIX="$WORK/fix$FIXN"
    BARE="$WORK/bare$FIXN.git"
    mkdir -p "$FIX/home"
    cp -R "$SRC_SCRIPTS" "$FIX/scripts"
    # The restart is a side effect, not the subject: the stub records that it
    # ran, so the refusal rows can prove it did NOT.
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$FIX/restart.log" > "$FIX/scripts/serverctl.sh"
    chmod +x "$FIX/scripts/serverctl.sh"
    write_config "$FIX/litellm-server/config.yaml"
    write_llamaswap "$FIX/llama-swap/m5-max-128gb/config.yaml"
    printf 'LITELLM_MASTER_KEY=fixture-master-key\n' > "$FIX/.env"
    git init --quiet --initial-branch=main "$FIX" >/dev/null 2>&1 || fail "fixture: git init failed"
    git -C "$FIX" config core.hooksPath /dev/null
    git -C "$FIX" config user.email 'fixture@example.com'
    git -C "$FIX" config user.name 'Fixture'
    git -C "$FIX" config commit.gpgsign false
    printf '.env\nrestart.log\n' > "$FIX/.gitignore"
    git -C "$FIX" add -A
    git -C "$FIX" commit --quiet -m 'fixture baseline'
    git init --quiet --bare --initial-branch=main "$BARE" >/dev/null 2>&1 \
        || fail "fixture: bare init failed"
    git -C "$FIX" remote add origin "$BARE"
    git -C "$FIX" push --quiet -u origin main >/dev/null 2>&1 \
        || fail "fixture: seeding the bare remote failed"
}

RC=0
ELAPSED=0
PATH_PREFIX=""   # set by the deadline case to shadow git for the CHILD only
EXTRA_ENV=""
run_set_model() { # run_set_model <fixture> <args...>
    local fix="$1" start end; shift
    start="$(date +%s)"
    ( cd "$fix" && env PATH="$PATH_PREFIX$PATH" HOME="$fix/home" TMPDIR="$WORK/tmp" \
        CCGW_OPS_ROOT="$fix" DOTENV_FILE="$fix/.env" \
        GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 $EXTRA_ENV \
        sh "$fix/scripts/set-model.sh" "$@" ) >"$WORK/out" 2>"$WORK/err" </dev/null
    RC=$?
    end="$(date +%s)"
    ELAPSED=$(( end - start ))
}

out_err() { cat "$WORK/out" "$WORK/err"; }
cfg() { cat "$1/litellm-server/config.yaml"; }
commits() { git -C "$1" rev-list --count HEAD; }
remote_sha() { git -C "$1" rev-parse "$2" 2>/dev/null || echo MISSING; }

# --- Case 1: no argument at all is a usage error -----------------------------
new_fixture
BEFORE="$(cfg "$FIX")"
run_set_model "$FIX"
[ "$RC" -eq 2 ] || fail "case 1: exited $RC with no arguments, expected the usage code 2: $(out_err)"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 1: the config was rewritten by an invocation with no arguments"
[ -f "$FIX/restart.log" ] && fail "case 1: the gateway was restarted by a usage error"

# --- Case 2: every malformed argument is refused, and none of it runs --------
# set-model.sh is typed by hand and pasted from chat logs, and both of its
# arguments are interpolated into a file rewrite, a git pathspec and a restart.
# One fixture for the whole table: nothing here may change anything, so a row
# that does is visible in the next row's snapshot too (CWE-78).
new_fixture
BEFORE="$(cfg "$FIX")"
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
LONG_ARG="$(printf 'x%.0s' {1..300})"

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    input="${input//@MARKER@/$MARKER}"
    input="${input//@PIPE@/|}"
    [ "$input" = "@EMPTY@" ] && input=""
    [ "$input" = "@LONG@" ] && input="$LONG_ARG"

    rm -f "$MARKER"
    case "$want" in
        tier) run_set_model "$FIX" "$input" qwen3.8-next-80b-4bit ;;
        key)  run_set_model "$FIX" opus "$input" ;;
        *)    fail "case 2/$name: unknown argument slot '$want'" ;;
    esac

    [ ! -e "$MARKER" ] || fail "case 2/$name: the argument was executed -- '$input' created $MARKER"
    [ "$RC" -eq 2 ] || fail "case 2/$name: exited $RC, expected the validation code 2: $(out_err)"
    [ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 2/$name: the config was edited despite the refusal"
    [ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 2/$name: a commit was made despite the refusal"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
        || fail "case 2/$name: the remote advanced despite the refusal"
    [ -f "$FIX/restart.log" ] && fail "case 2/$name: the gateway was restarted despite the refusal"
done <<'TABLE'
empty-tier      | @EMPTY@                | tier
unknown-tier    | sonnetx                | tier
uppercase-tier  | OPUS                   | tier
tier-semicolon  | opus;touch @MARKER@    | tier
tier-option     | --publish-now          | tier
tier-long       | @LONG@                 | tier
empty-key       | @EMPTY@                | key
key-semicolon   | k;touch @MARKER@       | key
key-ampersand   | k&touch @MARKER@       | key
key-pipe        | k@PIPE@touch @MARKER@  | key
key-backtick    | `touch @MARKER@`       | key
key-dollar      | $(touch @MARKER@)      | key
key-redirect    | k>@MARKER@             | key
key-space       | k touch @MARKER@       | key
key-glob        | *                      | key
key-traversal   | ../../../etc/passwd    | key
key-long        | @LONG@                 | key
TABLE

# --- Case 3: the same fixture still accepts a well-formed switch -------------
# Without this the table above is satisfiable by a script that refuses
# everything, including the thing it exists to do (CPR-ORTH positive control).
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 3: the fixture refuses a valid switch too, so case 2 proved nothing: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 3: the valid switch did not rewrite the route:
$(cfg "$FIX")"

# --- Case 4: a push that never returns still ends the command ----------------
# The operator is sitting at a prompt. A `git push` that blocks on a credential
# prompt or a dead remote must cost them a bounded wait, leave nothing running,
# and say what did and did not happen -- the edit, the restart and the commit
# are all already done locally, so rolling them back would be the worse answer.
# The deadline is shortened through its documented default so this suite stays
# inside the repo's 120s per-suite budget.
PIDFILE="$WORK/push-descendant.pid"
rm -f "$PIDFILE"
GITWRAP="$WORK/gitwrap"
mkdir -p "$GITWRAP"
{
    printf '#!/bin/bash\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = push ]; then\n'
    printf '    sleep 300 &\n'
    printf '    printf %%s "$!" > "%s"\n' "$PIDFILE"
    printf '    sleep 300\n'
    printf '    exit 0\n'
    printf '  fi\n'
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$REAL_GIT"
} > "$GITWRAP/git"
chmod +x "$GITWRAP/git"

new_fixture
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
PATH_PREFIX="$GITWRAP:"
EXTRA_ENV="CCGW_PUBLISH_DEADLINE=5"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
PATH_PREFIX=""
EXTRA_ENV=""

# Both ends are bounded on purpose. An upper bound of 60s against a 5s deadline
# passes a publish that waits 55, which is the regression this case is for; 20s
# is four times the configured value, enough for process spawn and git overhead
# on a loaded CI host and no more. The lower bound is what says the deadline was
# WAITED OUT: without it a push that fails instantly for an unrelated reason --
# a broken stub, a git that never ran -- reports the same exit 3 and passes.
[ "$ELAPSED" -lt 20 ] \
    || fail "case 4: the command took ${ELAPSED}s against a 5s CCGW_PUBLISH_DEADLINE; a hanging push must be bounded by the knob, not merely bounded eventually"
[ "$ELAPSED" -ge 4 ] \
    || fail "case 4: the command returned after ${ELAPSED}s, before the 5s deadline it was given; the push cannot have been waited out, so this case is timing out on something other than the deadline: $(out_err)"
[ "$RC" -eq 3 ] || fail "case 4: exited $RC on an unfinished publish, expected 3: $(out_err)"
out_err | grep -qi 'time\|deadline\|publish' \
    || fail "case 4: the operator must be told the publish did not finish: $(out_err)"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 4: the remote advanced although the push never returned"

# Everything the local half had already done stays done: reverting it would
# leave the running gateway serving a key the file no longer names.
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 4: the local edit was rolled back when the push timed out:
$(cfg "$FIX")"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 4: the commit was withdrawn when the push timed out"
[ -f "$FIX/restart.log" ] || fail "case 4: the gateway was never restarted"

# --- Case 5: the timed-out push leaves no descendant behind ------------------
# A `git push` spawns ssh or a credential helper. Killing only the git process
# leaves those holding .git locks and the terminal, so the next set-model.sh
# fails for a reason nobody can see.
[ -s "$PIDFILE" ] || fail "case 5: the git wrapper never ran, so nothing about the kill was proven"
DESCENDANT="$(cat "$PIDFILE")"
i=0
while [ "$i" -lt 15 ]; do
    kill -0 "$DESCENDANT" 2>/dev/null || break
    sleep 1
    i=$(( i + 1 ))
done
kill -0 "$DESCENDANT" 2>/dev/null \
    && fail "case 5: descendant PID $DESCENDANT outlived the timed-out push; the whole process tree must go"

# --- Case 6: the file this tool rewrites is not there -------------------------
# CCGW_OPS_ROOT pointing at the wrong checkout, or a partial clone. The failure
# has to name the path that was looked at: with the routing keys gone from .env,
# config.yaml is the only file left, so "not found" is the whole diagnosis.
new_fixture
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
rm -f "$FIX/litellm-server/config.yaml"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -ne 0 ] || fail "case 6: exited 0 with no config.yaml to rewrite: $(out_err)"
out_err | grep -q 'config.yaml' || fail "case 6: the error never named the file it could not find: $(out_err)"
[ -f "$FIX/restart.log" ] && fail "case 6: the gateway was restarted although nothing was rewritten"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 6: a commit was made with no config.yaml"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 6: the remote advanced with no config.yaml"

# --- Case 7: an empty config.yaml is not an empty set of routes ---------------
# A truncated write leaves zero bytes. "No route claims opus" and "the file is
# empty" are the same string to a parser that greps, and the second must not
# publish an empty file to every client (CPR-SC).
new_fixture
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
: > "$FIX/litellm-server/config.yaml"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -ne 0 ] || fail "case 7: exited 0 on a zero-byte config.yaml: $(out_err)"
[ ! -s "$FIX/litellm-server/config.yaml" ] || fail "case 7: routes were invented into an empty file"
[ -f "$FIX/restart.log" ] && fail "case 7: the gateway was restarted from an empty config.yaml"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 7: the truncation was committed"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 7: the truncated file was published to every client"

# --- Case 8: an unreadable config.yaml fails loudly, not silently -------------
# Wrong umask on a fresh clone, or a file owned by the launchd user. Reading it
# as "no route claims this tier" would send the operator hunting the annotation.
new_fixture
BEFORE="$(cfg "$FIX")"
chmod 000 "$FIX/litellm-server/config.yaml" 2>/dev/null
if [ -r "$FIX/litellm-server/config.yaml" ]; then
    echo "note: case 8 skipped -- this filesystem/user ignores mode 000"
else
    run_set_model "$FIX" opus qwen3.8-next-80b-4bit
    [ "$RC" -ne 0 ] || fail "case 8: exited 0 although config.yaml could not be read: $(out_err)"
    out_err | grep -q 'config.yaml' || fail "case 8: the error must name the file it could not read: $(out_err)"
    [ -f "$FIX/restart.log" ] && fail "case 8: the gateway was restarted on an unreadable config.yaml"
fi
chmod 644 "$FIX/litellm-server/config.yaml" 2>/dev/null
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 8: the unreadable file was rewritten anyway"

# --- Case 9: the backend lineup is what makes a model-key real ----------------
# config.yaml names the routing key; llama-swap's config.yaml is the list of
# keys that actually resolve to a running process. A key absent from it, or a
# lineup file that is not there at all, both mean "this switch would leave the
# tier pointing at nothing" -- and the tool cannot enumerate the choices to say
# so, which is exactly when it must name the file it was reading instead.
new_fixture
BEFORE="$(cfg "$FIX")"
run_set_model "$FIX" opus not-in-the-lineup
[ "$RC" -eq 2 ] || fail "case 9/absent-key: exited $RC for a key no backend serves, expected 2: $(out_err)"
out_err | grep -q 'qwen3.8-next-80b-4bit' \
    || fail "case 9/absent-key: the refusal did not list the keys that do resolve: $(out_err)"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 9/absent-key: the config was rewritten for a key no backend serves"
[ -f "$FIX/restart.log" ] && fail "case 9/absent-key: the gateway was restarted for a key no backend serves"

rm -f "$FIX/llama-swap/m5-max-128gb/config.yaml"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 2 ] || fail "case 9/no-lineup: exited $RC with no llama-swap config.yaml to validate against, expected 2: $(out_err)"
out_err | grep -q 'llama-swap' \
    || fail "case 9/no-lineup: 'no such key' and 'no lineup file' read alike unless the message names the missing file: $(out_err)"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 9/no-lineup: the config was rewritten with nothing to validate against"

# --- Case 10: a config.yaml that cannot be replaced is not half-replaced ------
# The atomic write stages a temp file beside the target, so a read-only
# litellm-server/ is where it fails. The failure must be total: no truncated
# file, no restart onto it, and nothing published.
new_fixture
BEFORE="$(cfg "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
chmod 500 "$FIX/litellm-server" 2>/dev/null
if touch "$FIX/litellm-server/.probe" 2>/dev/null; then
    rm -f "$FIX/litellm-server/.probe"
    echo "note: case 10 skipped -- this filesystem/user ignores a read-only directory"
else
    run_set_model "$FIX" opus qwen3.8-next-80b-4bit
    [ "$RC" -ne 0 ] || fail "case 10: exited 0 although config.yaml could not be replaced: $(out_err)"
    [ -f "$FIX/restart.log" ] && fail "case 10: the gateway was restarted although the edit never landed"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
        || fail "case 10: the remote moved although the edit never landed"
fi
chmod 755 "$FIX/litellm-server" 2>/dev/null
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 10: the config was left partly rewritten"

# --- Case 11: a commit that cannot be made is reported, not stepped over ------
# A crashed editor or a concurrent git leaves .git/index.lock behind. The local
# half is already done by then -- rewritten and restarted, per the documented
# order -- so this is a publish failure: the operator must be told the change is
# theirs alone, and the remote must be untouched rather than pushed from a
# commit that was never made.
new_fixture
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
: > "$FIX/.git/index.lock"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
rm -f "$FIX/.git/index.lock"
[ "$RC" -ne 0 ] || fail "case 11: exited 0 although the commit could not be made: $(out_err)"
out_err | grep -qi 'commit\|publish\|lock' \
    || fail "case 11: the operator was never told the change stayed local: $(out_err)"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 11: a commit was recorded despite the locked index"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 11: the remote advanced from a commit that was never made"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 11: the local edit was rolled back because the commit failed; the running gateway would then serve a key the file no longer names:
$(cfg "$FIX")"

# --- Case 12: a mistyped deadline knob does not brick publishing -------------
# CCGW_PUBLISH_DEADLINE is a tuning knob an operator exports, so every value
# below arrives from a human: `0` from someone who meant "no limit", `-1` and
# `abc` from a typo, and the empty string from an `export` with nothing after
# the `=`. None of them may become the two failure modes that look like a bug
# in the tool -- a push killed the instant it starts, or a publish refused
# outright -- so the documented default stands in and the switch completes.
# Saying which value was ignored is what stops the knob from silently not
# working. Case 4 covers the other half: a value that IS usable is obeyed.
while IFS='|' read -r name value; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    value="${value//[[:space:]]/}"
    [ "$value" = "@EMPTY@" ] && value=""

    new_fixture
    BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
    EXTRA_ENV="CCGW_PUBLISH_DEADLINE=$value"
    run_set_model "$FIX" opus qwen3.8-next-80b-4bit
    EXTRA_ENV=""
    [ "$RC" -eq 0 ] \
        || fail "case 12/$name: exited $RC because CCGW_PUBLISH_DEADLINE was '$value'; an unusable knob must fall back, not stop the switch: $(out_err)"
    [ "$ELAPSED" -lt 60 ] \
        || fail "case 12/$name: took ${ELAPSED}s with CCGW_PUBLISH_DEADLINE='$value'; an unreadable value must not become an unbounded wait"
    [ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
        || fail "case 12/$name: nothing was published, so the knob's value silently disabled publish: $(out_err)"
    out_err | grep -q 'CCGW_PUBLISH_DEADLINE' \
        || fail "case 12/$name: the ignored value '$value' was never mentioned, so the operator keeps believing the knob is in effect: $(out_err)"
done <<'TABLE'
zero        | 0
negative    | -1
non-numeric | abc
empty       | @EMPTY@
TABLE

# --- Case 13: asking for help is a read, and it succeeds ---------------------
# `-h` is what an operator types when they cannot remember whether the tier or
# the key comes first, so it must reach them BEFORE anything is rewritten,
# restarted or pushed -- a help flag that falls through to the switch path is
# the one usage error that costs a gateway restart. Case 1 fixes the code for a
# usage ERROR at 2; an explicit request is not an error, so it exits 0, or every
# `set -e` wrapper around `set-model.sh -h` dies on the help text. Both spellings
# are asserted together: shipping only one is the more common miss (CPR-ORTH).
new_fixture
HELP_CFG="$(cfg "$FIX")"
HELP_COMMITS="$(commits "$FIX")"
HELP_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
for flag in -h --help; do
    run_set_model "$FIX" "$flag"
    [ "$RC" -eq 0 ] || fail "case 13/$flag: exited $RC; an explicit help request is not a usage error: $(out_err)"
    [ -s "$WORK/out" ] || fail "case 13/$flag: help printed nothing to stdout, so a pipe to a pager shows an empty screen: $(out_err)"
    for tier in haiku sonnet fable opus; do
        out_err | grep -q -- "$tier" \
            || fail "case 13/$flag: the help text never names the '$tier' tier, which is the one thing the operator came for: $(out_err)"
    done
    out_err | grep -q -- '--list' \
        || fail "case 13/$flag: the help text never mentions --list, so the read-only form stays undiscoverable: $(out_err)"
    [ "$(cfg "$FIX")" = "$HELP_CFG" ] || fail "case 13/$flag: the config was rewritten by a help request:
$(cfg "$FIX")"
    [ -f "$FIX/restart.log" ] && fail "case 13/$flag: the gateway was restarted by a help request"
    [ "$(commits "$FIX")" = "$HELP_COMMITS" ] || fail "case 13/$flag: a help request committed"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$HELP_REMOTE" ] \
        || fail "case 13/$flag: a help request pushed to the remote"
done

echo "PASS: test-set-model-guards"
