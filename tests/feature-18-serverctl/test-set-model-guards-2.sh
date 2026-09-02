#!/usr/bin/env bash
# Tests: scripts/set-model.sh
# Tags: scope:issue-specific, layer:TL2, set-model, cli, usage, guards
# Second file of test-set-model-guards.sh, which is at the split threshold of
# rules/coding/file-split.md. Subject: argument LISTS the sibling never poses --
# one too many, one too few, and a flag given an operand it has no use for.
# It sources the shared ops-root fixture rather than the sibling's inline one
# (CPR-SSOT): everything a usage refusal has to be checked against is already
# there -- the git repository, its bare remote, and the restart stub.
# TL3 gap: as in the sibling suites -- a real remote, a real LiteLLM restart.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/set-model-config-ssot/fixture.sh"

# --- Case 1: argument lists that are not a valid invocation ------------------
# A tier and a model key are the whole grammar, so anything past the second word
# is a word the operator meant to be doing something. Dropping it silently is
# the failure that matters here: `set-model.sh opus qwen3.8-next-80b-4bit
# --no-publish` reads to its writer as a switch that will NOT be published, and
# a run that ignores the trailing word publishes it to every host instead. The
# missing-operand rows are the same defect from the other side -- a flag parsed
# as though the tier after it were its argument leaves the tier unset, and
# "which tier" is the one thing this command must never guess.
while IFS='|' read -r name args why; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    args="$(printf '%s' "$args" | sed 's/^ *//; s/ *$//')"
    why="$(printf '%s' "$why" | sed 's/^ *//; s/ *$//')"
    new_fixture default --remote
    BEFORE_CFG="$(cfg "$FIX")"
    BEFORE_COMMITS="$(commits "$FIX")"
    BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
    # Unquoted on purpose: the row IS the argument list, word for word.
    # shellcheck disable=SC2086
    run_set_model "$FIX" $args
    [ "$RC" -eq 2 ] \
        || fail "case 1/$name: exited $RC for \`set-model.sh $args\`, which $why; a usage error is code 2: $(out_err)"
    [ "$(cfg "$FIX")" = "$BEFORE_CFG" ] \
        || fail "case 1/$name: config.yaml was rewritten by an invocation the script could not read:
$(diff <(printf '%s\n' "$BEFORE_CFG") <(cfg "$FIX"))"
    restarted "$FIX" \
        && fail "case 1/$name: the gateway was restarted for an invocation that was never valid"
    [ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] \
        || fail "case 1/$name: a commit was made from a rejected invocation"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
        || fail "case 1/$name: the remote advanced from a rejected invocation"
    out_err | grep -q 'Usage' \
        || fail "case 1/$name: nothing told the operator what the accepted form is: $(out_err)"
done <<'TABLE'
trailing-word    | opus qwen3.8-next-80b-4bit extra-token   | carries a third word the grammar has no place for
trailing-flag    | opus qwen3.8-next-80b-4bit --no-publish  | puts the flag where it is no longer read, so the switch is published anyway
no-publish-bare  | --no-publish                             | names no tier and no model at all
no-publish-tier  | --no-publish opus                        | names a tier with no model key to move it to
list-extra-arg   | --list opus extra-arg                    | asks to list one tier and hands over a second word as well
TABLE

echo "PASS: test-set-model-guards-2"
