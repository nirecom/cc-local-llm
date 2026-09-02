#!/usr/bin/env bash
# Tests: scripts/set-model.sh, scripts/code-ccgw.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, set-model, config, ssot, publish, git
# Continuation of test-set-model-config-ssot.sh past the 500-line limit of
# rules/coding/file-split.md; shared fixture in set-model-config-ssot/fixture.sh,
# case numbering continues from 19. Subject: the haiku tier, which no successful
# switch in the sibling suite drives; the annotation-only subagent slot; and the
# Format-F comment form an operator writes when a strict validator rejects keys.
# TL3 gap: as in the sibling suite -- a real LiteLLM accepting the rewritten
# file, a real llama-swap holding the model, a real remote. See docs/ops.md.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/set-model-config-ssot/fixture.sh"

# The launcher is the OTHER reader of this file, and case 21 is the only place
# the writer and a reader meet. `uname` is stubbed to Darwin so the launcher
# takes one fixed platform branch rather than the host's.
LAUNCH_STUB="$WORK/launch-stub"
mkdir -p "$LAUNCH_STUB"
printf '#!/bin/sh\nenv > "$CCGW_TEST_DUMP"\n' > "$LAUNCH_STUB/code"
chmod +x "$LAUNCH_STUB/code"
printf '#!/bin/sh\nprintf %%s\\\\n Darwin\n' > "$LAUNCH_STUB/uname"
chmod +x "$LAUNCH_STUB/uname"
LAUNCH_DUMP="$WORK/launch.dump"

run_launcher_on() { # run_launcher_on <fixture>
    rm -f "$LAUNCH_DUMP"
    env -i \
        HOME="$1/home" PATH="$LAUNCH_STUB:/usr/bin:/bin" \
        DOTENV_FILE="$1/.env" CCGW_OPS_ROOT="$1" \
        CCGW_AUTO_PULL=off CCGW_TEST_DUMP="$LAUNCH_DUMP" \
        LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
        bash "$1/scripts/code-ccgw.sh" >"$WORK/lout" 2>"$WORK/lerr"
    LRC=$?
}
launch_get() { grep -m1 "^$1=" "$LAUNCH_DUMP" | cut -d= -f2-; }

# --- Case 19: the haiku tier switches, end to end ----------------------------
# Cases 1-18 drive opus and fable. haiku is neither: it is the tier that shares
# a route with sonnet, so a writer that resolves "which route serves this tier"
# by scanning for the FIRST name in an annotation would move sonnet and leave
# haiku pointing nowhere -- and nothing above would notice.
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" haiku qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 19: exited $RC on a same-shape haiku swap: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 19: model_name was not rewritten:
$(cfg "$FIX")"
cfg "$FIX" | grep -q '^      model: openai/qwen3.8-next-80b-4bit$' \
    || fail "case 19: litellm_params.model was not rewritten, or lost its provider prefix"
cfg "$FIX" | grep -q 'ccgw_tiers: \[haiku, sonnet\]' \
    || fail "case 19: the tier annotation was lost while rewriting the haiku route"
out_err | grep -q 'sonnet' \
    || fail "case 19: sonnet rides the same route and also moved, but the output never said so: $(out_err)"
[ "$(cfg "$FIX" | grep -cE '^  - model_name: (deepseek-v4-flash|qwen3\.8-flash-next-3bit-mtp)$')" -eq 2 ] \
    || fail "case 19: a neighbouring route was rewritten by a haiku switch:
$(cfg "$FIX")"
[ "$(cat "$FIX/.env")" = "LITELLM_MASTER_KEY=fixture-master-key" ] \
    || fail "case 19: .env was modified; routing keys belong to config.yaml now"
restarted "$FIX" || fail "case 19: the gateway was never restarted, so the edit is not serving yet"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 19: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 19: the edit was never published, so the other hosts stay on the old key"

# --- Case 20: the subagent slot moves with its route, and is not a CLI tier --
# subagent is an annotation-only slot: it has no route of its own, so the CLI
# vocabulary stays haiku|sonnet|fable|opus and `set-model.sh subagent <key>` is
# a usage error (detail.md 334, and 523 lists the tier as out of scope). The
# slot still has to be reachable -- it moves when the route carrying it moves --
# so the two halves are asserted together: refuse the argument, then prove the
# switch that DOES move it says so, which is the only notice the operator gets
# that a tier they never named just changed model.
new_fixture default --remote
BEFORE="$(cfg "$FIX")"
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" subagent qwen3.8-next-80b-4bit
[ "$RC" -eq 2 ] || fail "case 20: exited $RC for the tier 'subagent', expected the usage code 2 -- it names no route of its own: $(out_err)"
out_err | grep -q 'haiku|sonnet|fable|opus\|haiku, sonnet, fable, opus' \
    || fail "case 20: the refusal never showed the accepted tiers, so the operator cannot tell what to type instead: $(out_err)"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 20: the config was rewritten by a tier the CLI does not accept"
restarted "$FIX" && fail "case 20: the gateway was restarted by a refused argument"
[ "$(commits "$FIX")" -eq "$BEFORE_COMMITS" ] || fail "case 20: a commit was made for a refused argument"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 20: the remote advanced for a refused argument"

# The slot's real switch: opus carries subagent in this fixture, so moving opus
# moves subagent, and both names must appear in the report.
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 20: exited $RC on the same-shape opus swap that carries subagent: $(out_err)"
cfg "$FIX" | grep -q 'ccgw_tiers: \[opus, subagent\]' \
    || fail "case 20: the tier annotation was lost while rewriting the route:
$(cfg "$FIX")"
out_err | grep -q 'subagent' \
    || fail "case 20: subagent rides this route and also moved, but the output never said so: $(out_err)"
[ "$(cfg "$FIX" | grep -cE '^  - model_name: (win-sonnet-key|deepseek-v4-flash)$')" -eq 2 ] \
    || fail "case 20: a neighbouring route was rewritten:
$(cfg "$FIX")"
restarted "$FIX" || fail "case 20: the gateway was never restarted, so the edit is not serving yet"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 20: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 20: the edit was never published, so the other hosts stay on the old key"

# --- Case 21: a file written entirely in Format F is a first-class file ------
# F exists for the operator whose YAML validator rejects an unknown key inside
# litellm_params, so their file has no key-form annotation anywhere -- and the
# two forms are never mixed (detail.md S1), which is why this fixture is F on
# all three routes rather than one. Being comments, they are what a writer that
# rebuilds a block from parsed YAML drops, leaving the route in no tier with the
# file still valid and the launcher still exiting 0. Verbatim is the contract:
# rewriting any of them into the key form hands that operator's validator back
# the error they chose this form to avoid.
new_fixture commentform --remote
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 21: exited $RC on a comment-annotated route: $(out_err)"
cfg "$FIX" | grep -q '^    # ccgw-tiers: opus subagent$' \
    || fail "case 21: the comment annotation was dropped or reworded; the route now belongs to no tier:
$(cfg "$FIX")"
[ "$(cfg "$FIX" | grep -c '^    # ccgw-tiers: ')" -eq 3 ] \
    || fail "case 21: expected all three routes to keep their comment annotation, found $(cfg "$FIX" | grep -c '^    # ccgw-tiers: '):
$(cfg "$FIX")"
[ "$(cfg "$FIX" | grep -c 'ccgw_tiers:')" -eq 0 ] \
    || fail "case 21: an annotation was written out in the key form, which is both the error the operator chose Format F to avoid and a P/F mix in one file:
$(cfg "$FIX")"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 21: model_name was not rewritten:
$(cfg "$FIX")"
cfg "$FIX" | grep -q '^      model: openai/qwen3.8-next-80b-4bit$' \
    || fail "case 21: litellm_params.model was not rewritten"

# The launcher run is what makes this an integration case rather than a string
# check: every tier of a pure-F file has to reach the child, not just the pair
# on the route that moved.
run_launcher_on "$FIX"
[ "$LRC" -eq 0 ] || fail "case 21: the launcher exited $LRC on the rewritten file: $(cat "$WORK/lerr")"
[ -f "$LAUNCH_DUMP" ] || fail "case 21: the launcher never reached 'code': $(cat "$WORK/lerr")"
while IFS='|' read -r var want; do
    [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
    var="${var//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    [ "$(launch_get "$var")" = "$want" ] \
        || fail "case 21: the launcher read $var as '$(launch_get "$var")', expected '$want' -- writer and reader disagree about the whitespace-separated comment form"
done <<'TABLE'
ANTHROPIC_DEFAULT_OPUS_MODEL   | qwen3.8-next-80b-4bit
CLAUDE_CODE_SUBAGENT_MODEL     | qwen3.8-next-80b-4bit
ANTHROPIC_DEFAULT_HAIKU_MODEL  | win-sonnet-key
ANTHROPIC_DEFAULT_SONNET_MODEL | win-sonnet-key
ANTHROPIC_DEFAULT_FABLE_MODEL  | deepseek-v4-flash
TABLE

# --- Case 22: a failed publish must not print the remote's credential --------
# The entrypoint's half of the leak test-git-remote-lib.sh case 13 covers one
# layer down. An https origin may carry userinfo, and the one moment set-model
# has to print git's own words is exactly the moment the URL is in them -- into
# a terminal the operator is about to paste into an issue. The string is a
# fixed fake, so any appearance of it is the failure, and the sweep covers the
# files the run leaves behind as well as the two streams: a diagnostic written
# to a log is shared just as readily as a screenshot.
SECRET='n0t-a-real-token-c5a-7be2'
new_fixture default --remote
git -C "$FIX" remote set-url origin "https://ccgw-user:$SECRET@127.0.0.1:9/ops.git"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 3 ] || fail "case 22: exited $RC for an unreachable remote, expected the publish-incomplete code 3: $(out_err)"
LEAK="$(cat "$WORK/out" "$WORK/err" 2>/dev/null; cat "$FIX/restart.log" 2>/dev/null; find "$WORK/tmp" -type f -exec cat {} + 2>/dev/null)"
case "$LEAK" in
    *"$SECRET"*) fail "case 22: the remote's credential reached the operator's output: $LEAK" ;;
esac
out_err | grep -qi 'push\|publish\|remote' \
    || fail "case 22: the failure was reported without saying publishing is what failed: $(out_err)"

# --- Case 23: a push that just fails is still a publish failure --------------
# Sibling case 13 covers a real non-fast-forward, and guards case 4 covers a
# push that never returns. Between them sits everything else: a denied
# permission, a refused connection, a server-side hook saying no. Those return
# at once, with a message that matches none of the divergence wording -- so an
# implementation that recognises "behind" and treats every other non-zero exit
# as success would pass both existing cases and tell this operator their
# routing change is live on every host when it is live on none (CPR-UNV).
PUSHFAIL="$WORK/stub-pushfail"
mkdir -p "$PUSHFAIL"
{
    printf '#!/bin/bash\n'
    printf 'for a in "$@"; do\n'
    printf '    if [ "$a" = push ]; then\n'
    printf '        printf "remote: ccgw-fixture: pre-receive hook declined\\n" >&2\n'
    printf '        exit 128\n'
    printf '    fi\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$PUSHFAIL/git"
chmod +x "$PUSHFAIL/git"

new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
PATH_PREFIX="$PUSHFAIL:"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
PATH_PREFIX=""
[ "$RC" -eq 3 ] || fail "case 23: exited $RC after a rejected push, expected the publish-incomplete code 3: $(out_err)"
out_err | grep -q 'pre-receive hook declined' \
    || fail "case 23: git's own explanation was swallowed, leaving nothing to act on: $(out_err)"
out_err | grep -qi 'push\|publish' \
    || fail "case 23: the operator is not told that publishing is the part that failed: $(out_err)"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 23: the remote advanced although every push was rejected"

# Exit 3 means "published nothing", never "did nothing": the local switch has
# already happened and is already serving, so rolling it back would leave the
# host running a model its own config.yaml no longer names.
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 23: the local edit was rolled back by a publish failure:
$(cfg "$FIX")"
restarted "$FIX" || fail "case 23: the gateway restart was undone by a publish failure"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 23: the local commit was dropped by a publish failure; it went from $BEFORE_COMMITS to $(commits "$FIX")"

# --- Case 24: a CRLF-saved config.yaml survives a switch and still reads -----
# config.yaml is edited from Windows now, so it reaches this writer with a CR
# on every line. The CR sits exactly where both annotation forms end, so a
# writer that matches without allowing for it rewrites nothing, and one that
# matches but copies the CR into the value writes a key no /model entry can
# name. Line endings have no stated contract, so nothing here asserts which
# one survives -- only that the switch succeeds and that the launcher, the
# other reader of this file, still gets every tier out of the result.
new_fixture default --remote
awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$FIX/litellm-server/config.yaml" > "$WORK/crlf.yaml"
mv "$WORK/crlf.yaml" "$FIX/litellm-server/config.yaml"
git -C "$FIX" commit --quiet -am 'saved from a Windows editor'
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 24: exited $RC on a CRLF-saved config: $(out_err)"
cfg "$FIX" | tr -d '\r' | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 24: model_name was not rewritten in a CRLF-saved file:
$(cfg "$FIX")"
cfg "$FIX" | tr -d '\r' | grep -q 'ccgw_tiers: \[opus, subagent\]' \
    || fail "case 24: the tier annotation was lost while rewriting a CRLF-saved file"
restarted "$FIX" || fail "case 24: the gateway was never restarted, so the edit is not serving yet"

run_launcher_on "$FIX"
[ "$LRC" -eq 0 ] || fail "case 24: the launcher exited $LRC on the rewritten CRLF file: $(cat "$WORK/lerr")"
[ -f "$LAUNCH_DUMP" ] || fail "case 24: the launcher never reached 'code': $(cat "$WORK/lerr")"
[ "$(launch_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "qwen3.8-next-80b-4bit" ] \
    || fail "case 24: the launcher read opus as '$(launch_get ANTHROPIC_DEFAULT_OPUS_MODEL)' -- a CR survived into the routing key"
[ "$(launch_get ANTHROPIC_DEFAULT_HAIKU_MODEL)" = "win-sonnet-key" ] \
    || fail "case 24: the launcher read haiku as '$(launch_get ANTHROPIC_DEFAULT_HAIKU_MODEL)' -- an untouched route lost its mapping"
[ "$(launch_get ANTHROPIC_DEFAULT_FABLE_MODEL)" = "deepseek-v4-flash" ] \
    || fail "case 24: the launcher read fable as '$(launch_get ANTHROPIC_DEFAULT_FABLE_MODEL)' -- an untouched route lost its mapping"

# --- Case 25: the run after a failed publish finishes it, and redoes nothing --
# Exit 3 leaves the host in a real state -- switched, restarted, committed, not
# pushed -- and the operator's next move is to run the same command again once
# the remote is reachable. That run must recognise the work as already done: an
# implementation that starts from scratch commits an empty second change and
# restarts the gateway a second time, dropping every in-flight request to
# re-apply a switch that is already live. It must also still push, since the
# whole reason the operator ran it again is the half that did not happen.
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
PATH_PREFIX="$PUSHFAIL:"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
PATH_PREFIX=""
[ "$RC" -eq 3 ] || fail "case 25: the first run exited $RC, expected the publish-incomplete code 3: $(out_err)"
restarted "$FIX" || fail "case 25: the first run never restarted, so the retry below cannot show a SECOND restart"
PENDING_CFG="$(cfg "$FIX")"
PENDING_HEAD="$(git -C "$FIX" rev-parse HEAD)"
PENDING_RESTARTS="$(wc -l < "$FIX/restart.log")"
[ "$PENDING_RESTARTS" -eq 1 ] \
    || fail "case 25: the first run restarted $PENDING_RESTARTS times: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 25: the first run left $(commits "$FIX") commits, expected $(( BEFORE_COMMITS + 1 ))"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 25: the remote advanced although the push was rejected"

run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 25: the retry against a reachable remote exited $RC; the pending commit is still unpublished: $(out_err)"
[ "$(cfg "$FIX")" = "$PENDING_CFG" ] \
    || fail "case 25: the retry rewrote a file that already said what it was asked to say:
$(diff <(printf '%s\n' "$PENDING_CFG") <(cfg "$FIX"))"
[ "$(git -C "$FIX" rev-parse HEAD)" = "$PENDING_HEAD" ] \
    || fail "case 25: the retry made a second commit for a change that had already been committed"
[ "$(wc -l < "$FIX/restart.log")" -eq "$PENDING_RESTARTS" ] \
    || fail "case 25: the retry restarted the gateway again, dropping live requests to re-apply a switch that was already serving: $(cat "$FIX/restart.log")"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$PENDING_HEAD" ] \
    || fail "case 25: the retry did not publish the pending commit -- the remote is at $(remote_sha "$BARE" refs/heads/main), the local HEAD at $PENDING_HEAD"

# --- Case 26: the writer's own grammar, row for row with the other two readers
# The writer parses this file too, and it is the reader that then REWRITES it.
# Every case above hands it one well-formed shape, so an implementation that
# matches `ccgw.tiers` loosely and splits on anything passes them all -- and
# then adopts an annotation the launchers read differently, or edits a line
# that is not one, with the operator's next `code` run the first sign. The rows
# mirror test-code-ccgw-config-tiers-2.sh case 14 and the Python validator's
# case 9 (CPR-ORTH): P is comma-separated and may sit anywhere in the block, F
# is whitespace-separated and only on the line after the block start, and
# neither is readable when written in the other's spelling.
probe_config() { # probe_config <path> <form: P|F> <annotation> <placement> <neighbour-tiers>
    local out="$1" form="$2" ann="$3" place="$4" ntok="$5" njoin
    if [ "$form" = P ]; then njoin="      ccgw_tiers: [${ntok// /, }]"
    else njoin="    # ccgw-tiers: $ntok"; fi
    mkdir -p "$(dirname "$out")"
    {
        printf 'model_list:\n'
        printf '  # --- Haiku and sonnet tiers ---\n'
        printf '  - model_name: win-sonnet-key\n'
        [ "$form" = F ] && printf '%s\n' "$njoin"
        printf '    litellm_params:\n'
        printf '      model: openai/Qwen3.8-27B\n'
        [ "$form" = P ] && printf '%s\n' "$njoin"
        printf '\n  # --- Fable tier ---\n'
        printf '  - model_name: deepseek-v4-flash\n'
        [ "$form" = F ] && printf '    # ccgw-tiers: fable\n'
        printf '    litellm_params:\n'
        printf '      model: anthropic/deepseek-v4-flash\n'
        [ "$form" = P ] && printf '      ccgw_tiers: [fable]\n'
        printf '\n  # --- Opus tier: the annotation under test ---\n'
        [ "$place" = above ] && printf '%s\n' "$ann"
        printf '  - model_name: qwen3.8-flash-next-3bit-mtp\n'
        [ "$place" = head ] && printf '%s\n' "$ann"
        printf '    litellm_params:\n'
        printf '      model: openai/qwen3.8-flash-next-3bit-mtp\n'
        [ "$place" = inblock ] && printf '%s\n' "$ann"
        printf '\ngeneral_settings:\n'
        printf '  master_key: os.environ/LITELLM_MASTER_KEY\n'
    } > "$out"
}

# `@` stands for a space so the table stays readable; the annotation column is
# the opus route's line verbatim, indentation included.
while IFS='|' read -r name form place expect ntok ann; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; form="${form//[[:space:]]/}"
    place="${place//[[:space:]]/}"; expect="${expect//[[:space:]]/}"
    ntok="${ntok//[[:space:]]/}"; ntok="${ntok//@/ }"
    ann="${ann//[[:space:]]/}"; ann="${ann//@/ }"
    new_fixture default --remote
    probe_config "$FIX/litellm-server/config.yaml" "$form" "$ann" "$place" "$ntok"
    git -C "$FIX" commit --quiet -am "probe $name" || fail "case 26/$name: the probe fixture is identical to the baseline, so nothing is under test"
    BEFORE="$(cfg "$FIX")"
    BEFORE_COMMITS="$(commits "$FIX")"
    BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
    run_set_model "$FIX" opus qwen3.8-next-80b-4bit
    if [ "$expect" = ok ]; then
        [ "$RC" -eq 0 ] || fail "case 26/$name: exited $RC on an annotation the grammar accepts: $(out_err)"
        cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
            || fail "case 26/$name: accepted the annotation but rewrote no model_name:
$(cfg "$FIX")"
        restarted "$FIX" || fail "case 26/$name: the switch was accepted but never restarted, so it is not serving"
        [ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
            || fail "case 26/$name: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
        [ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
            || fail "case 26/$name: the accepted switch was never published"
    else
        [ "$RC" -eq 2 ] || fail "case 26/$name: exited $RC for '$ann' at $place, expected the validation code 2 -- this annotation is not readable and must not be acted on: $(out_err)"
        [ "$(cfg "$FIX")" = "$BEFORE" ] \
            || fail "case 26/$name: a refused file was edited anyway:
$(diff <(printf '%s\n' "$BEFORE") <(cfg "$FIX"))"
        restarted "$FIX" && fail "case 26/$name: the gateway was restarted for a refused file"
        [ "$(commits "$FIX")" -eq "$BEFORE_COMMITS" ] \
            || fail "case 26/$name: a refused file was committed"
        [ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
            || fail "case 26/$name: a refused file was published"
    fi
done <<'TABLE'
p-pair        | P | inblock | ok     | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus,@subagent]
p-tight-comma | P | inblock | ok     | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus,subagent]
p-single      | P | inblock | ok     | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus]
p-at-head     | P | head    | ok     | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus,@subagent]
p-space-sep   | P | inblock | reject | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus@subagent]
# p-empty is the one row the static validator scores differently, and on purpose:
# `[]` breaks no grammar rule, it just claims nothing. The writer is being ASKED
# for opus, so a file where no route claims it is a request it cannot carry out.
p-empty       | P | inblock | reject | haiku@sonnet      | @@@@@@ccgw_tiers:@[]
p-dup-token   | P | inblock | reject | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus,@opus]
p-garbage     | P | inblock | reject | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus,@banana]
p-shallow     | P | inblock | reject | haiku@sonnet      | @@ccgw_tiers:@[opus,@subagent]
p-above-block | P | above   | reject | haiku@sonnet      | @@@@@@ccgw_tiers:@[opus,@subagent]
p-dup-tier    | P | inblock | reject | haiku@sonnet@opus | @@@@@@ccgw_tiers:@[opus]
f-pair        | F | head    | ok     | haiku@sonnet      | @@@@#@ccgw-tiers:@opus@subagent
f-single      | F | head    | ok     | haiku@sonnet      | @@@@#@ccgw-tiers:@opus
f-comma-sep   | F | head    | reject | haiku@sonnet      | @@@@#@ccgw-tiers:@opus,@subagent
f-in-block    | F | inblock | reject | haiku@sonnet      | @@@@#@ccgw-tiers:@opus@subagent
f-key-only    | F | head    | reject | haiku@sonnet      | @@@@#@ccgw-tiers:
f-shallow     | F | head    | reject | haiku@sonnet      | @@#@ccgw-tiers:@opus@subagent
f-deep        | F | head    | reject | haiku@sonnet      | @@@@@@#@ccgw-tiers:@opus@subagent
f-garbage     | F | head    | reject | haiku@sonnet      | @@@@#@ccgw-tiers:@opus@banana
f-dup-token   | F | head    | reject | haiku@sonnet      | @@@@#@ccgw-tiers:@opus@opus
TABLE

# --- Case 27: an ops root whose path is hostile to an unquoted expansion ------
# lang-check: ignore -- EDGE below deliberately embeds Japanese as a real path exercise.
# Every fixture above sits under mktemp's tame path, so an unquoted "$CCGW_OPS_ROOT"
# or a path interpolated into a `sh -c` string behaves identically to a quoted
# one -- and the operator who keeps their checkout under "Google Drive" or a
# Japanese folder name is the one who finds out. The name carries a space, an
# ampersand, parentheses, non-ASCII and a command substitution; the substitution
# would create `marker` if the path ever reached a shell as code, so the sweep
# at the end is the injection assertion. `[`, `]`, `;`, a backtick and a single
# quote are deliberately absent -- Git for Windows mangles them in a `git -C` arg.
EDGE="$WORK/edge cases & (parens) 日本語 \$(touch marker)"
new_fixture default --remote
mkdir -p "$EDGE" || fail "case 27: the host filesystem rejected the edge-case directory name"
mv "$FIX" "$EDGE/ops root" || fail "case 27: could not move the fixture under the edge-case path"
mv "$BARE" "$EDGE/bare remote.git" || fail "case 27: could not move the bare remote"
FIX="$EDGE/ops root"
BARE="$EDGE/bare remote.git"
# The stub's log path is baked in at write time and the origin URL is absolute;
# both were written for the old location.
write_restart_stub "$FIX"
git -C "$FIX" remote set-url origin "$BARE" \
    || fail "case 27: could not repoint origin at the moved bare remote"
case "$FIX" in
    *'$(touch marker)'*) : ;;
    *) fail "case 27: the fixture path lost its command substitution, so the injection sweep below proves nothing: $FIX" ;;
esac

BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 27: exited $RC from an ops root whose path needs quoting: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 27: model_name was not rewritten under an awkward path:
$(cfg "$FIX")"
cfg "$FIX" | grep -q 'ccgw_tiers: \[opus, subagent\]' \
    || fail "case 27: the tier annotation was lost under an awkward path"
restarted "$FIX" || fail "case 27: the gateway was never restarted; a path with a space in it must not silently skip the restart"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 27: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 27: the switch was never published from an awkward path"

run_launcher_on "$FIX"
[ "$LRC" -eq 0 ] || fail "case 27: the launcher exited $LRC under an awkward path: $(cat "$WORK/lerr")"
[ -f "$LAUNCH_DUMP" ] || fail "case 27: the launcher never reached 'code': $(cat "$WORK/lerr")"
while IFS='|' read -r var want; do
    [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
    var="${var//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    [ "$(launch_get "$var")" = "$want" ] \
        || fail "case 27: the launcher read $var as '$(launch_get "$var")', expected '$want' -- the path, not the file, is what changed"
done <<'TABLE'
ANTHROPIC_DEFAULT_OPUS_MODEL   | qwen3.8-next-80b-4bit
CLAUDE_CODE_SUBAGENT_MODEL     | qwen3.8-next-80b-4bit
ANTHROPIC_DEFAULT_HAIKU_MODEL  | win-sonnet-key
ANTHROPIC_DEFAULT_SONNET_MODEL | win-sonnet-key
ANTHROPIC_DEFAULT_FABLE_MODEL  | deepseek-v4-flash
TABLE

# The sweep must be able to reach into the awkward directory before its silence
# means anything, so it is asked for a file that is certainly there first.
[ -n "$(find "$WORK" -name 'config.yaml' 2>/dev/null)" ] \
    || fail "case 27: the sweep cannot traverse the edge-case path at all, so finding no marker below proves nothing"
INJECTED="$(find "$WORK" -name marker 2>/dev/null)"
[ -z "$INJECTED" ] \
    || fail "case 27: the ops-root path was executed rather than quoted -- the substitution in it ran and left: $INJECTED"

echo "PASS: test-set-model-config-ssot-2"
