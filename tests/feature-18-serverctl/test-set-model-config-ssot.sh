#!/usr/bin/env bash
# Tests: scripts/set-model.sh, scripts/lib/git-remote.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, set-model, config, ssot, publish, git
#
# Scenario (issue #89): a tier's routing key used to live in each machine's own
# .env, so `set-model.sh opus <key>` on the Mac left the Windows PC addressing
# the model it had been told weeks earlier. config.yaml owns both halves now --
# `model_name` and the backend -- and set-model.sh publishes the edit so the
# other host picks it up. Replaces test-set-model-dotenv-force-keys.sh; cases 19
# onward and the fixture both suites share sit beside this file.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/set-model-config-ssot/fixture.sh"

# TL3 gap (what this suite does NOT catch): whether LiteLLM accepts the
# rewritten file, `ccgw_tiers` key and all, and serves the new key after the
# restart; whether llama-swap has a model by that name; a real remote, with its
# credentials, server-side hooks and protected branches. The restart is a stub
# and the remote a local bare repo, so the mitigation is the docs/ops.md cutover
# smoke run at USER_VERIFIED: one real set-model.sh, then a /model switch.

# --- Case 1: both halves of the route move together, .env is left alone ------
# Cases 1-3 are about the rewrite, so they get a remote to take publishing out
# of the picture: with none, the run ends at "no upstream" and exits 3 (14b).
new_fixture default --remote
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 1: exited $RC: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 1: model_name was not rewritten -- the client still has to send the old key:
$(cfg "$FIX")"
cfg "$FIX" | grep -q '^      model: openai/qwen3.8-next-80b-4bit$' \
    || fail "case 1: litellm_params.model was not rewritten:
$(cfg "$FIX")"
[ "$(cat "$FIX/.env")" = "LITELLM_MASTER_KEY=fixture-master-key" ] \
    || fail "case 1: .env was modified; routing keys belong to config.yaml now:
$(cat "$FIX/.env")"
cfg "$FIX" | grep -q 'ccgw_tiers: \[opus, subagent\]' \
    || fail "case 1: the tier annotation was lost while rewriting the route"

# --- Case 2: the tier is found by annotation, not by position ----------------
new_fixture reordered --remote
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 2: exited $RC on a reordered config: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 2: the opus route was not found once it was no longer the last block"
cfg "$FIX" | grep -q '^  - model_name: deepseek-v4-flash$' \
    || fail "case 2: a different route was rewritten instead:
$(cfg "$FIX")"

# --- Case 3: the sonnet route end to end, two tiers on it, and the warning ---
# haiku and sonnet share a backend today. Moving both is correct; NOT saying so
# is what makes the next surprising `/model haiku` land far from here. Carried
# to the same depth as cases 18 and 19 (CPR-ORTH): the shared route is the one
# where a half-done rewrite is least visible, so every side effect the fable and
# haiku runs assert is asserted here too.
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" sonnet qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 3: exited $RC: $(out_err)"
out_err | grep -q 'haiku' \
    || fail "case 3: changing sonnet also moved haiku, but the output never said so: $(out_err)"
[ "$(cfg "$FIX" | grep -c '^  - model_name: qwen3.8-next-80b-4bit$')" = "1" ] \
    || fail "case 3: the shared route was duplicated instead of rewritten in place"
cfg "$FIX" | grep -q '^      model: openai/qwen3.8-next-80b-4bit$' \
    || fail "case 3: litellm_params.model was not rewritten, so the client key and the backend disagree:
$(cfg "$FIX")"
cfg "$FIX" | grep -q 'ccgw_tiers: \[haiku, sonnet\]' \
    || fail "case 3: the tier annotation was lost while rewriting the shared route -- the next run would not find sonnet at all"
[ "$(cfg "$FIX" | grep -cE '^  - model_name: (deepseek-v4-flash|qwen3\.8-flash-next-3bit-mtp)$')" -eq 2 ] \
    || fail "case 3: a neighbouring route was rewritten by a sonnet switch:
$(cfg "$FIX")"
[ "$(cat "$FIX/.env")" = "LITELLM_MASTER_KEY=fixture-master-key" ] \
    || fail "case 3: .env was modified; routing keys belong to config.yaml now:
$(cat "$FIX/.env")"
restarted "$FIX" || fail "case 3: the gateway was never restarted, so the edit is not serving yet"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 3: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 3: the edit was never published, so the other hosts stay on the old key"

# --- Case 4: --list attributes every tier to the route that serves it --------
# Naming the five tiers somewhere in the output is not the same as saying which
# key each one sends -- and that mapping is the only reason to run --list. The
# two shared routes are the interesting rows: opus and subagent are one route,
# haiku and sonnet another.
new_fixture default --remote
LIST_CFG="$(cfg "$FIX")"
LIST_DOTENV="$(cat "$FIX/.env")"
LIST_COMMITS="$(commits "$FIX")"
LIST_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" --list
[ "$RC" -eq 0 ] || fail "case 4: --list exited $RC: $(out_err)"
ALL_KEYS="win-sonnet-key deepseek-v4-flash qwen3.8-flash-next-3bit-mtp"
while IFS='|' read -r input want; do
    [[ -z "$input" || "$input" =~ ^[[:space:]]*# ]] && continue
    input="${input//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    # Only key-bearing lines count: a usage banner listing every tier does not.
    LINES="$(out_err | grep -w "$input" | grep -E 'win-sonnet-key|deepseek-v4-flash|qwen3\.8-flash-next-3bit-mtp')"
    [ -n "$LINES" ] || fail "case 4/$input: --list never shows that tier against any routing key: $(out_err)"
    printf '%s\n' "$LINES" | grep -q "$want" \
        || fail "case 4/$input: the tier is listed without its routing key '$want': $LINES"
    for other in $ALL_KEYS; do
        [ "$other" = "$want" ] && continue
        printf '%s\n' "$LINES" | grep -q "$other" \
            && fail "case 4/$input: the tier is listed against '$other', another route's key: $LINES"
    done
done <<'TABLE'
haiku    | win-sonnet-key
sonnet   | win-sonnet-key
fable    | deepseek-v4-flash
opus     | qwen3.8-flash-next-3bit-mtp
subagent | qwen3.8-flash-next-3bit-mtp
TABLE
# --- and --list is a read: it may change nothing at all ----------------------
# The listing shares the whole config-reading path with the rewrite, so an
# implementation that reaches the write, the restart or the publish before it
# notices the read-only flag would still print a correct table. An operator who
# runs --list to find out where they stand must not thereby restart the gateway
# under a colleague's in-flight request, nor push a commit nobody asked for.
[ "$(cfg "$FIX")" = "$LIST_CFG" ] || fail "case 4: --list rewrote config.yaml:
$(cfg "$FIX")"
[ "$(cat "$FIX/.env")" = "$LIST_DOTENV" ] || fail "case 4: --list modified .env"
restarted "$FIX" && fail "case 4: --list restarted the gateway"
[ "$(commits "$FIX")" = "$LIST_COMMITS" ] || fail "case 4: --list committed"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$LIST_REMOTE" ] \
    || fail "case 4: --list pushed to the remote"

# --- Case 4b: --list <tier> answers for that tier and only that tier ---------
# The whole-table form above is what an operator reads; `--list sonnet` is what
# a script greps. Naming a second tier's key in the answer is what makes such a
# script set the wrong route -- and the shared haiku/sonnet route is where that
# is easiest to get wrong, since two tiers legitimately share one key. An
# unknown tier here must be refused with the same code 2 the setter uses, not
# answered with the full table (which a caller would read as "sonnet is not on
# any route") and not with an empty success.
new_fixture default
run_set_model "$FIX" --list sonnet
[ "$RC" -eq 0 ] || fail "case 4b: --list sonnet exited $RC: $(out_err)"
out_err | grep -q 'win-sonnet-key' \
    || fail "case 4b: --list sonnet never named the key that tier routes to: $(out_err)"
out_err | grep -qE 'deepseek-v4-flash|qwen3\.8-flash-next-3bit-mtp' \
    && fail "case 4b: --list sonnet also reported another tier's routing key: $(out_err)"
run_set_model "$FIX" --list no-such-tier
[ "$RC" -eq 2 ] || fail "case 4b: --list on an unknown tier exited $RC, expected the usage code 2: $(out_err)"
out_err | grep -q 'no-such-tier' \
    || fail "case 4b: the refusal never named the tier that was not understood: $(out_err)"
out_err | grep -q 'win-sonnet-key' \
    && fail "case 4b: an unknown tier was answered with the routing table instead of refused: $(out_err)"
restarted "$FIX" && fail "case 4b: a read-only listing restarted the gateway"

# --- Case 5: a cross-shape swap is still refused -----------------------------
# provider prefix and api_base both differ between the two shapes, so this needs
# a hand edit; performing it silently yields 400s at request time.
new_fixture default
BEFORE="$(cfg "$FIX")"
run_set_model "$FIX" opus ds4-alt
[ "$RC" -ne 0 ] || fail "case 5: exited 0 for an anthropic-shaped key on an openai-shaped route"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 5: the config was edited despite the refusal"
restarted "$FIX" && fail "case 5: litellm was restarted despite the refusal"

# --- Case 6: the new key must not collide with another route's name (C4) -----
# model_name is the client-visible routing key; two routes sharing one makes
# LiteLLM load-balance between them, so `/model opus` would answer from the
# sonnet backend on alternate requests -- with no error anywhere.
new_fixture default --remote
BEFORE="$(cfg "$FIX")"
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus win-sonnet-key
[ "$RC" -eq 2 ] || fail "case 6: exited $RC, expected the usage/validation code 2: $(out_err)"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 6: the config was edited despite the collision"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 6: a commit was made despite the collision"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 6: the remote advanced despite the collision"
restarted "$FIX" && fail "case 6: litellm was restarted despite the collision"
out_err | grep -q 'haiku' && out_err | grep -q 'sonnet' \
    || fail "case 6: the message must name the tiers already holding that key: $(out_err)"

# --- Case 7: a config that does not parse is refused before anything moves ---
new_fixture broken --remote
BEFORE="$(cfg "$FIX")"
BEFORE_COMMITS="$(commits "$FIX")"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 2 ] || fail "case 7: exited $RC on an out-of-block annotation, expected 2: $(out_err)"
[ "$(cfg "$FIX")" = "$BEFORE" ] || fail "case 7: the malformed config was edited anyway"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 7: a commit was made from a malformed config"

# --- Case 8: publishing is one commit, one file, one explicit refspec --------
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 8: exited $RC: $(out_err)"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 8: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
CHANGED="$(git -C "$FIX" show --name-only --format= HEAD)"
[ "$CHANGED" = "litellm-server/config.yaml" ] \
    || fail "case 8: the commit touched more than the config:
$CHANGED"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 8: the bare remote's refs/heads/main did not advance"
out_err | grep -q 'origin HEAD:refs/heads/main' \
    || fail "case 8: the output must show the explicit refspec it pushed: $(out_err)"

# --- Case 9: a push.default that refuses implicit pushes is not in the way ---
new_fixture default --remote
git -C "$FIX" config push.default nothing
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 9: exited $RC under push.default=nothing: $(out_err)"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 9: an explicit refspec must publish regardless of push.default"

# --- Case 10: the local branch name is not the ref that gets published -------
new_fixture default --remote
git -C "$FIX" checkout --quiet -b wip
git -C "$FIX" config branch.wip.remote origin
git -C "$FIX" config branch.wip.merge refs/heads/main
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 10: exited $RC from a differently-named branch: $(out_err)"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 10: refs/heads/main did not advance; the upstream ref decides, not the branch name"
[ "$(remote_sha "$BARE" refs/heads/wip)" = "MISSING" ] \
    || fail "case 10: a stray refs/heads/wip was created on the remote"

# --- Case 11: no other local branch is dragged along -------------------------
# push.default=matching is the setting under which an unqualified push ships
# every same-named branch, including one the operator never meant to publish.
new_fixture default --remote
git -C "$FIX" config push.default matching
git -C "$FIX" checkout --quiet -b stray
printf 'unrelated\n' > "$FIX/stray.txt"
git -C "$FIX" add stray.txt
git -C "$FIX" commit --quiet -m 'stray work'
git -C "$FIX" push --quiet origin stray:refs/heads/stray >/dev/null 2>&1
STRAY_BEFORE="$(remote_sha "$BARE" refs/heads/stray)"
printf 'more\n' >> "$FIX/stray.txt"
git -C "$FIX" add stray.txt
git -C "$FIX" commit --quiet -m 'more stray work'
git -C "$FIX" checkout --quiet main
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 11: exited $RC: $(out_err)"
[ "$(remote_sha "$BARE" refs/heads/stray)" = "$STRAY_BEFORE" ] \
    || fail "case 11: publishing the config also published the unrelated 'stray' branch"

# --- Case 12: someone else's staged work is neither committed nor unstaged ---
# "Absent from the commit" is only half of it: `git reset` before committing
# also keeps the file out, and quietly throws away the staging the operator did.
# The index entry for their file is therefore snapshotted and required to come
# back byte for byte -- the blob SHA and mode included, which is what makes the
# comparison sensitive to a re-add of different content.
new_fixture default --remote
printf 'staged by the operator\n' > "$FIX/unrelated.txt"
git -C "$FIX" add unrelated.txt
STAGED_BEFORE="$(git -C "$FIX" diff --cached --raw -- unrelated.txt)"
[ -n "$STAGED_BEFORE" ] \
    || fail "case 12: the fixture staged nothing, so the survival check below would pass vacuously"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 12: exited $RC: $(out_err)"
git -C "$FIX" show --name-only --format= HEAD | grep -q 'unrelated.txt' \
    && fail "case 12: a file the operator had staged was swept into the config commit"
STAGED_AFTER="$(git -C "$FIX" diff --cached --raw -- unrelated.txt)"
[ "$STAGED_AFTER" = "$STAGED_BEFORE" ] \
    || fail "case 12: the operator's staged work did not survive the run -- keeping it out of the commit must not mean unstaging it:
  before: $STAGED_BEFORE
  after:  $STAGED_AFTER"

# --- Case 13: a remote that moved on is never overwritten --------------------
new_fixture default --remote
OTHER="$WORK/other-clone"
git clone --quiet "$BARE" "$OTHER" >/dev/null 2>&1 || fail "case 13: clone failed"
git -C "$OTHER" config core.hooksPath /dev/null
git -C "$OTHER" config user.email 'other@example.com'
git -C "$OTHER" config user.name 'Other'
printf 'from elsewhere\n' > "$OTHER/elsewhere.txt"
git -C "$OTHER" add elsewhere.txt
git -C "$OTHER" commit --quiet -m 'from elsewhere'
git -C "$OTHER" push --quiet origin main >/dev/null 2>&1 || fail "case 13: seeding divergence failed"
DIVERGED="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 3 ] || fail "case 13: exited $RC on a non-fast-forward, expected the publish code 3: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 13: the local edit was rolled back; the operator's change must survive a publish failure"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$DIVERGED" ] \
    || fail "case 13: the remote was overwritten -- a publish must never force"
out_err | grep -qi 'behind\|diverg\|fast-forward\|non-fast' \
    || fail "case 13: the error must say the remote moved on: $(out_err)"

# --- Case 14: each unpublishable repository state names itself ---------------
# Three different remedies (check out a branch / set an upstream / add a real
# remote), so one generic "could not publish" leaves the operator guessing.
# Exit 3 and the message are only half of what each row owes. What separates
# these three from case 15 is WHERE the run stopped: an unresolvable publish
# target is discovered at the push, after the file was rewritten, the gateway
# restarted and the work committed (detail.md S7 e) -- so the operator is left
# with a running gateway whose config sits on a local commit, needing one
# `git push` once they have fixed the branch. Case 15's restart failure stops
# BEFORE the commit instead.
assert_committed_but_unpublished() { # <case> <before-commits> <before-remote>
    # The exit code alone cannot tell those two apart, and an implementation
    # that rolled the edit back, skipped the restart, or never committed would
    # satisfy every assertion this row used to make while leaving a gateway on
    # the old model and a change that exists nowhere.
    cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
        || fail "$1: the local rewrite did not survive; a repository that cannot publish must still keep the operator's edit"
    restarted "$FIX" \
        || fail "$1: the gateway was never restarted, so it is still serving the old model: $(out_err)"
    [ "$(commits "$FIX")" -eq $(( $2 + 1 )) ] \
        || fail "$1: expected exactly one new local commit (was $2, now $(commits "$FIX")) -- the push is what is blocked, not the commit"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$3" ] \
        || fail "$1: the remote moved although the publish target could not be resolved"
}

new_fixture default --remote
git -C "$FIX" checkout --quiet --detach HEAD
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 3 ] || fail "case 14a: exited $RC on a detached HEAD, expected 3: $(out_err)"
out_err | grep -qi 'detach' || fail "case 14a: the error must name the detached HEAD: $(out_err)"
assert_committed_but_unpublished "case 14a" "$BEFORE_COMMITS" "$BEFORE_REMOTE"

# The bare remote is kept and the TRACKING CONFIG removed, rather than building
# a fixture with no remote at all: without a $BARE there is no remote ref to
# assert stayed put, and "the push was not attempted somewhere else" is half of
# what this row claims.
new_fixture default --remote
git -C "$FIX" config --unset branch.main.remote
git -C "$FIX" config --unset branch.main.merge
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 3 ] || fail "case 14b: exited $RC with no upstream, expected 3: $(out_err)"
out_err | grep -qi 'upstream\|tracking' \
    || fail "case 14b: the error must name the missing upstream: $(out_err)"
assert_committed_but_unpublished "case 14b" "$BEFORE_COMMITS" "$BEFORE_REMOTE"

new_fixture default --remote
git -C "$FIX" branch other
git -C "$FIX" config branch.main.remote .
git -C "$FIX" config branch.main.merge refs/heads/other
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 3 ] || fail "case 14c: exited $RC for a local-only upstream, expected 3: $(out_err)"
out_err | grep -qi 'publish remote\|no remote\|local' \
    || fail "case 14c: the error must say there is no publish remote: $(out_err)"
assert_committed_but_unpublished "case 14c" "$BEFORE_COMMITS" "$BEFORE_REMOTE"

# --- Case 15: a restart that failed must not be published as if it worked ----
new_fixture default --remote
printf '#!/bin/sh\nexit 1\n' > "$FIX/scripts/serverctl.sh"
chmod +x "$FIX/scripts/serverctl.sh"
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -ne 0 ] || fail "case 15: exited 0 although the restart failed: $(out_err)"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] \
    || fail "case 15: the change was committed although the gateway never picked it up"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 15: the change was pushed although the gateway never picked it up"

# --- Case 16: --no-publish skips publishing, not the live switch -------------
# The order is rewrite -> restart -> commit -> push (detail.md 337), and the
# flag names the last two. Dropping the restart with them would leave the
# operator a file that says one thing and a gateway serving another -- the
# quiet divergence this whole issue exists to end -- while every file, commit
# and remote assertion below still passed.
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" --no-publish opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 16: exited $RC: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 16: --no-publish must still make the local edit"
restarted "$FIX" \
    || fail "case 16: --no-publish never restarted the gateway; the edit is on disk but the old key is still the one being served"
[ "$(wc -l < "$FIX/restart.log")" -eq 1 ] \
    || fail "case 16: the gateway was restarted $(wc -l < "$FIX/restart.log") times for one switch: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 16: --no-publish committed anyway"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 16: --no-publish pushed anyway"

# --- Case 16b: a repeated --no-publish run restarts nothing ------------------
# Case 17 pins this for the publishing path. Without the same pin here, an
# implementation that decides "nothing changed" by comparing against the last
# COMMIT would find no commit to compare with under --no-publish and restart on
# every invocation -- dropping every in-flight request each time, for a file
# that already says what it is being asked to say.
FIRST_CFG="$(cfg "$FIX")"
run_set_model "$FIX" --no-publish opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 16b: the second --no-publish run exited $RC: $(out_err)"
[ "$(cfg "$FIX")" = "$FIRST_CFG" ] || fail "case 16b: the second run changed the file again"
[ "$(wc -l < "$FIX/restart.log")" -eq 1 ] \
    || fail "case 16b: the gateway was restarted again for a change that did not happen: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 16b: the second --no-publish run committed"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 16b: the second --no-publish run pushed"

# --- Case 17: the second run is a no-op in every observable way --------------
# Not just "no commit": a gateway restarted again drops every in-flight request
# for nothing, and a re-push makes the other hosts pull nothing. All four side
# effects -- file, restart, commit, remote -- are snapshotted after the first
# run and required to be identical after the second (Idempotency).
new_fixture default --remote
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 17: the first run exited $RC: $(out_err)"
AFTER_FIRST="$(commits "$FIX")"
FIRST_CFG="$(cfg "$FIX")"
FIRST_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
restarted "$FIX" || fail "case 17: the first run never restarted the gateway; the no-op below would prove nothing"
FIRST_RESTARTS="$(wc -l < "$FIX/restart.log")"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] || fail "case 17: the second run exited $RC: $(out_err)"
[ "$(commits "$FIX")" = "$AFTER_FIRST" ] \
    || fail "case 17: re-setting the same value added a commit"
[ "$(cfg "$FIX")" = "$FIRST_CFG" ] || fail "case 17: the second run changed the file again"
[ "$(wc -l < "$FIX/restart.log")" = "$FIRST_RESTARTS" ] \
    || fail "case 17: the gateway was restarted again for a change that did not happen"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$FIRST_REMOTE" ] \
    || fail "case 17: the remote advanced on a run that changed nothing"

# --- Case 18: the fable route, end to end ------------------------------------
# Every case above drives the opus route, so a rewrite hard-wired to it -- the
# last block, or the one read first -- would go unnoticed. Fable is the other
# provider shape and the other backend, and this is the whole contract in one
# run: both halves move, the annotation survives, .env is untouched, the gateway
# restarts, the edit ships.
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" fable ds4-alt
[ "$RC" -eq 0 ] || fail "case 18: exited $RC on a same-shape fable swap: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: ds4-alt$' \
    || fail "case 18: model_name was not rewritten:
$(cfg "$FIX")"
cfg "$FIX" | grep -q '^      model: anthropic/ds4-alt$' \
    || fail "case 18: litellm_params.model was not rewritten, or lost its provider prefix"
cfg "$FIX" | grep -q 'ccgw_tiers: \[fable\]' \
    || fail "case 18: the tier annotation was lost while rewriting the fable route"
[ "$(cfg "$FIX" | grep -cE '^  - model_name: (win-sonnet-key|qwen3\.8-flash-next-3bit-mtp)$')" -eq 2 ] \
    || fail "case 18: a neighbouring route was rewritten by a fable switch:
$(cfg "$FIX")"
[ "$(cat "$FIX/.env")" = "LITELLM_MASTER_KEY=fixture-master-key" ] \
    || fail "case 18: .env was modified; routing keys belong to config.yaml now:
$(cat "$FIX/.env")"
restarted "$FIX" || fail "case 18: the gateway was never restarted, so the edit is not serving yet"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 18: expected one new commit, went from $BEFORE_COMMITS to $(commits "$FIX")"
[ "$(remote_sha "$BARE" refs/heads/main)" != "$BEFORE_REMOTE" ] \
    || fail "case 18: the edit was never published, so the other hosts stay on the old key"

echo "PASS: test-set-model-config-ssot"
