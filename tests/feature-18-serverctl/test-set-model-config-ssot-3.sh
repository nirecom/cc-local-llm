#!/usr/bin/env bash
# Tests: scripts/set-model.sh, scripts/lib/git-remote.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, set-model, config, ssot, publish, git
# Third file of test-set-model-config-ssot.sh, split off at the 500-line limit
# of rules/coding/file-split.md; shared fixture in set-model-config-ssot/
# fixture.sh. Subject: the two states the sibling suites never put the
# repository in before the run -- config.yaml already carrying the operator's
# own uncommitted edit, and no remote configured at all -- which is why the
# cases are numbered after the ones they extend (12, 16) rather than after 27.
# TL3 gap: as in the sibling suites -- a real remote, a real LiteLLM restart.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/set-model-config-ssot/fixture.sh"

# --- Case 12b: an in-flight edit to config.yaml ITSELF stops the run ---------
# Case 12 protects a file the commit can simply leave out. This one cannot be:
# config.yaml IS the file being committed, so an operator mid-edit on another
# route -- the fable backend here, an uncommitted experiment -- has that
# half-finished line swept into the commit and pushed to every other host by a
# switch they made for opus, and cannot take it back. The run therefore refuses
# before touching anything, with the same code 2 and the same "nothing moved"
# evidence as the other pre-write guards (cases 6 and 7). Both index states are
# covered: a writer asking `git diff` without `--cached` sees only one of them.
while IFS='|' read -r name stage; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; stage="${stage//[[:space:]]/}"
    new_fixture default --remote
    awk '{ sub(/^      model: anthropic\/deepseek-v4-flash$/, "      model: anthropic/deepseek-v4-flash-EXPERIMENT"); print }' \
        "$FIX/litellm-server/config.yaml" > "$WORK/dirty.yaml"
    mv "$WORK/dirty.yaml" "$FIX/litellm-server/config.yaml"
    [ "$stage" = staged ] && git -C "$FIX" add litellm-server/config.yaml
    cfg "$FIX" | grep -q 'deepseek-v4-flash-EXPERIMENT' \
        || fail "case 12b/$name: the fixture's own edit did not take, so this case asserts nothing"
    DIRTY_CFG="$(cfg "$FIX")"
    DIRTY_INDEX="$(git -C "$FIX" diff --cached --raw -- litellm-server/config.yaml)"
    BEFORE_COMMITS="$(commits "$FIX")"
    BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
    run_set_model "$FIX" opus qwen3.8-next-80b-4bit
    [ "$RC" -eq 2 ] \
        || fail "case 12b/$name: exited $RC over an uncommitted config.yaml, expected the pre-write refusal code 2 -- publishing it ships the operator's unfinished fable edit to every host: $(out_err)"
    [ "$(cfg "$FIX")" = "$DIRTY_CFG" ] \
        || fail "case 12b/$name: the operator's in-flight file was rewritten by a run that must not have started:
$(diff <(printf '%s\n' "$DIRTY_CFG") <(cfg "$FIX"))"
    [ "$(git -C "$FIX" diff --cached --raw -- litellm-server/config.yaml)" = "$DIRTY_INDEX" ] \
        || fail "case 12b/$name: the refusal changed what was staged; declining to commit must not mean staging or unstaging on the operator's behalf"
    restarted "$FIX" && fail "case 12b/$name: the gateway was restarted by a refused run"
    [ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 12b/$name: a commit was made from a refused run"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
        || fail "case 12b/$name: the remote advanced from a refused run"
    out_err | grep -q 'config.yaml' \
        || fail "case 12b/$name: the refusal never named the file that is in the way: $(out_err)"
    out_err | grep -qi 'uncommitted\|unstaged\|staged\|local change\|not committed\|dirty' \
        || fail "case 12b/$name: the refusal never says WHY -- the operator has to be told to commit or stash their own edit: $(out_err)"
done <<'TABLE'
unstaged | worktree
staged   | staged
TABLE

# --- Case 16c: --no-publish on a repository with no remote at all ------------
# 16 and 16b both run in a --remote fixture, so a --no-publish that still
# resolves the upstream before honouring the flag passes them both and then
# fails for the operator who has not wired a remote up yet -- 14b is exit 3 for
# exactly that state -- turning "just switch my machine" into a switch that
# never happens. The stub below records every git the run makes, so the absence
# of publishing is asserted as no network verb ATTEMPTED rather than as a
# remote that did not move: there is no remote here to move.
GITLOG="$WORK/stub-gitlog"
GITCALLS="$WORK/git-calls.log"
mkdir -p "$GITLOG"
{
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "'$GITCALLS'"
    printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$GITLOG/git"
chmod +x "$GITLOG/git"

# A recorder that records nothing reports every run as clean, so it is made to
# record one call of its own before it is trusted with the run's.
: > "$GITCALLS"
"$GITLOG/git" --version >/dev/null 2>&1 \
    || fail "case 16c: the logging git stub cannot run at all"
grep -q -- '--version' "$GITCALLS" \
    || fail "case 16c: the stub ran without recording the call, so an unrecorded push below would read as no push"
: > "$GITCALLS"

new_fixture default
BEFORE_COMMITS="$(commits "$FIX")"
PATH_PREFIX="$GITLOG:"
run_set_model "$FIX" --no-publish opus qwen3.8-next-80b-4bit
PATH_PREFIX=""
[ "$RC" -eq 0 ] \
    || fail "case 16c: exited $RC in a repository with no remote; --no-publish is the flag that must not need one: $(out_err)"
cfg "$FIX" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 16c: the local edit was not made:
$(cfg "$FIX")"
cfg "$FIX" | grep -q '^      model: openai/qwen3.8-next-80b-4bit$' \
    || fail "case 16c: litellm_params.model was not rewritten:
$(cfg "$FIX")"
restarted "$FIX" \
    || fail "case 16c: the gateway was never restarted, so the file says one thing and the gateway serves another"
[ "$(wc -l < "$FIX/restart.log")" -eq 1 ] \
    || fail "case 16c: the gateway was restarted $(wc -l < "$FIX/restart.log") times for one switch: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 16c: --no-publish committed anyway"

# Reading the git config is not what is forbidden -- finding no upstream there
# is how the flag can be honoured at all. Only the verbs that would open a
# connection are, and every one of them fails outright in this fixture, so one
# reaching git means the remote was consulted before the flag was.
NETVERBS="$(grep -nE '(^| )(push|fetch|pull|ls-remote|clone)( |$)' "$GITCALLS")"
[ -z "$NETVERBS" ] \
    || fail "case 16c: --no-publish went to the network in a repository that has no remote: $NETVERBS"

# --- Case 7b: a candidate file that was ALREADY malformed before the run -----
# Case 7 covers the one malformed shape the run itself can produce. These six
# arrive that way: someone hand-edited config.yaml and committed it, or a
# migration stopped halfway, and the next `set-model.sh` inherits the result.
# Committing on top of such a file publishes it to every host, so the same
# pre-write refusal (code 2, nothing moved) is owed here -- and each row breaks
# exactly one schema rule, so the message can be held to naming that rule.
# The last three break theirs on a route this invocation is NOT switching: a
# writer that validates only the block it rewrites ships all three onward, and
# the operator finds out when the route they never touched stops answering.
while IFS='|' read -r variant hint why; do
    [[ -z "$variant" || "$variant" =~ ^[[:space:]]*# ]] && continue
    variant="${variant//[[:space:]]/}"
    # The hint column is a list of words, any one of which counts as naming the
    # broken rule. It cannot hold a `\|` regex: `|` is the field separator, so
    # `read` would cut the alternation in half and leave a trailing backslash.
    hint="$(printf '%s' "$hint" | sed 's/^ *//; s/ *$//; s/  */\\|/g')"
    why="$(printf '%s' "$why" | sed 's/^ *//; s/ *$//')"
    new_fixture "$variant" --remote
    BEFORE_CFG="$(cfg "$FIX")"
    BEFORE_INDEX="$(git -C "$FIX" diff --cached --raw)"
    BEFORE_COMMITS="$(commits "$FIX")"
    BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
    run_set_model "$FIX" opus qwen3.8-next-80b-4bit
    [ "$RC" -eq 2 ] \
        || fail "case 7b/$variant: exited $RC on a config.yaml that $why; a pre-write refusal is code 2, and anything else here commits the malformed file onward: $(out_err)"
    [ "$(cfg "$FIX")" = "$BEFORE_CFG" ] \
        || fail "case 7b/$variant: the refused run still rewrote config.yaml:
$(diff <(printf '%s\n' "$BEFORE_CFG") <(cfg "$FIX"))"
    [ "$(git -C "$FIX" diff --cached --raw)" = "$BEFORE_INDEX" ] \
        || fail "case 7b/$variant: the refusal staged something; declining to commit must not mean leaving work in the index"
    restarted "$FIX" && fail "case 7b/$variant: the gateway was restarted by a refused run"
    [ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] || fail "case 7b/$variant: a commit was made from a refused run"
    [ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
        || fail "case 7b/$variant: the remote advanced from a refused run"
    out_err | grep -q 'config.yaml' \
        || fail "case 7b/$variant: the refusal never named the file the operator has to go and fix: $(out_err)"
    out_err | grep -qi "$hint" \
        || fail "case 7b/$variant: the refusal never says the file $why -- an operator told only that something is wrong has to diff the whole file to find out what: $(out_err)"
done <<'TABLE'
dupname     | duplicate twice already repeated | answers to one routing name twice, so which backend serves it is whatever the router picks
mixedforms  | mix both format                  | annotates one route in both spellings at once, which two readers resolve differently
doubleannot | duplicate twice second repeated  | carries two annotation lines on one route, so first-wins and last-wins disagree
envleftover | os.environ literal environment   | still delegates the fable route's routing name to an environment variable, which is the pre-migration shape this whole change exists to remove
missingname | empty missing blank unset        | leaves the fable route's routing name empty, so the tier annotated on it maps to a record no client can address
quotedname  | quote quoted literal             | writes the fable route's routing name in quotes, which a YAML reader and a line reader resolve to different strings
TABLE

# --- Case 28: publishing from a working branch whose name contains slashes ---
# The library-level half of this is test-git-remote-lib.sh case 15; this is what
# the operator actually experiences when it is wrong. Every host in this repo
# works on a branch named after its issue, so a resolver that keeps only the
# last component pushes to `refs/heads/issue-89` -- a branch that did not exist
# a moment ago, that no other host tracks, and that leaves the operator's own
# upstream exactly where it was while the run reports success.
new_fixture default --remote
git -C "$FIX" checkout --quiet -b feature/issue-89 \
    || fail "case 28: this git build rejects a slash-bearing branch name, so the case cannot be posed"
git -C "$FIX" push --quiet -u origin feature/issue-89 >/dev/null 2>&1 \
    || fail "case 28: seeding the nested branch on the remote failed"
BEFORE_MAIN="$(remote_sha "$BARE" refs/heads/main)"
BEFORE_BRANCH="$(remote_sha "$BARE" refs/heads/feature/issue-89)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] \
    || fail "case 28: exited $RC publishing from feature/issue-89, an ordinary tracked branch under refs/heads/: $(out_err)"
[ "$(remote_sha "$BARE" refs/heads/feature/issue-89)" = "$(git -C "$FIX" rev-parse HEAD)" ] \
    || fail "case 28: the operator's own branch did not receive the commit; the run published somewhere else"
[ "$(remote_sha "$BARE" refs/heads/feature/issue-89)" != "$BEFORE_BRANCH" ] \
    || fail "case 28: the remote branch never moved, so nothing was published at all"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_MAIN" ] \
    || fail "case 28: main advanced from a run made on feature/issue-89; publish follows the tracked ref, never a hardcoded branch"
git -C "$BARE" show-ref --verify --quiet refs/heads/issue-89 \
    && fail "case 28: a stray refs/heads/issue-89 was created -- the nested ref was truncated to its last component and the push landed on a branch nobody tracks"

# --- Case 29: a failed publish must not spill either credential it handles ---
# set-model.sh handles two: the master key it reads out of .env to talk to the
# gateway, and whatever the operator embedded in the remote URL. A push that
# fails is exactly when a script starts echoing the command it tried, and the
# operator is at a terminal that scrolls into a paste, a screenshot or a bug
# report. The sweep covers the two copies that outlive the run as well -- git's
# scratch under TMPDIR and the repository's own .git/ state, which travels with
# the checkout into every archive taken of it.
MASTER_SECRET='ccgw-master-Zk7Qv2ttl'
URL_SECRET='ccgw-url-Rm4Xb9wwp'
new_fixture default --remote
printf 'LITELLM_MASTER_KEY=%s\n' "$MASTER_SECRET" > "$FIX/.env"
git -C "$FIX" remote set-url origin "https://ccgw-user:$URL_SECRET@127.0.0.1:9/repo.git"
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 3 ] \
    || fail "case 29: exited $RC on an unreachable remote, expected the publish-failure code 3: $(out_err)"

# A sweep that cannot see a secret it is standing on reports every run as clean,
# so each of the three is made to find a planted one before its silence counts.
for s in "$MASTER_SECRET" "$URL_SECRET"; do
    printf 'probe %s\n' "$s" > "$WORK/out.probe"
    grep -qF -- "$s" "$WORK/out.probe" \
        || fail "case 29: the terminal sweep cannot match a plain string, so its silence asserts nothing"
    rm -f "$WORK/out.probe"
    out_err | grep -qF -- "$s" \
        && fail "case 29: a credential was printed to the operator's terminal by a failed publish: $(out_err)"
done

git_state_hits() { # git_state_hits <repo> <secret> -- .git files carrying it
    find "$1/.git" -type f ! -name config ! -name 'config.worktree' \
        -exec grep -laF -- "$2" {} + 2>/dev/null
    find "$1/.git" -name "*$2*" 2>/dev/null
}

# .git/config is the single exclusion: the URL is in it because the operator put
# it there, so that copy is their own record rather than a spill -- which is why
# it has to be proven still present, and a probe planted beside it, before the
# sweep's silence about everything else means anything.
grep -qF -- "$URL_SECRET" "$FIX/.git/config" \
    || fail "case 29: .git/config no longer carries the remote URL, so the one exclusion the sweep makes is not being exercised"
printf 'https://ccgw-user:%s@127.0.0.1:9/repo.git\n' "$URL_SECRET" > "$FIX/.git/ccgw-leak-probe"
[ -n "$(git_state_hits "$FIX" "$URL_SECRET")" ] \
    || fail "case 29: the .git sweep cannot find a secret in a file under .git/ that plainly contains it"
rm -f "$FIX/.git/ccgw-leak-probe"
printf 'probe %s\n' "$MASTER_SECRET" > "$WORK/tmp/ccgw-leak-probe"
[ -n "$(grep -rlaF -- "$MASTER_SECRET" "$WORK/tmp" 2>/dev/null)" ] \
    || fail "case 29: the TMPDIR sweep cannot find a secret in a file it plainly contains"
rm -f "$WORK/tmp/ccgw-leak-probe"

for s in "$MASTER_SECRET" "$URL_SECRET"; do
    HITS="$(grep -rlaF -- "$s" "$WORK/tmp" 2>/dev/null)"
    [ -z "$HITS" ] || fail "case 29: a credential was written into TMPDIR, where it outlives the run: $HITS"
    HITS="$(find "$WORK/tmp" -name "*$s*" 2>/dev/null)"
    [ -z "$HITS" ] || fail "case 29: a credential appears in the NAME of a temp file: $HITS"
    HITS="$(git_state_hits "$FIX" "$s")"
    [ -z "$HITS" ] \
        || fail "case 29: a credential was written into the repository's own git state, which travels with the checkout: $HITS"
done

# --- Case 15b: the run after a failed restart finishes it, and redoes nothing -
# Case 25 retries the LAST step; the documented order is rewrite -> restart ->
# commit -> push (detail.md:337), so each earlier step owes the same retry. Case
# 15 leaves the host switched on disk and nowhere else: not serving, not
# committed, not pushed. The operator fixes the gateway and runs the same
# command again, and that run has to do the three steps that did not happen --
# once each. Restarting twice drops live requests to re-apply a switch that is
# already up; committing twice puts an empty change in the history every other
# host then pulls.
new_fixture default --remote
printf '#!/bin/sh\nexit 1\n' > "$FIX/scripts/serverctl.sh"
chmod +x "$FIX/scripts/serverctl.sh"
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -ne 0 ] || fail "case 15b: the first run exited 0 although the restart failed, so there is nothing left to retry: $(out_err)"
PENDING_CFG="$(cfg "$FIX")"
printf '%s\n' "$PENDING_CFG" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 15b: the first run left no rewritten file behind, so the retry below cannot show it being rewritten a second time:
$PENDING_CFG"
restarted "$FIX" && fail "case 15b: the failing stub recorded a restart, so a second restart below would be indistinguishable from the first"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] \
    || fail "case 15b: the first run committed although the gateway never picked the change up"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 15b: the first run published although the gateway never picked the change up"

# The retry meets a config.yaml that is dirty against HEAD -- its own output
# from the run above. Case 12b refuses exactly that state when the edit is the
# OPERATOR's, so the two cases together pin the distinction: refuse when the
# uncommitted file differs from what this run would write, resume when it is
# byte-for-byte what this run would write.
write_restart_stub "$FIX"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] \
    || fail "case 15b: the retry against a working gateway exited $RC; the switch is on disk and nowhere else, and this run is what was supposed to finish it: $(out_err)"
[ "$(cfg "$FIX")" = "$PENDING_CFG" ] \
    || fail "case 15b: the retry rewrote a file that already said what it was asked to say:
$(diff <(printf '%s\n' "$PENDING_CFG") <(cfg "$FIX"))"
restarted "$FIX" \
    || fail "case 15b: the retry never restarted the gateway, so the file says one thing and the gateway still serves another: $(out_err)"
[ "$(wc -l < "$FIX/restart.log")" -eq 1 ] \
    || fail "case 15b: the working gateway was restarted $(wc -l < "$FIX/restart.log") times for one switch: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 15b: the retry left $(commits "$FIX") commits, expected $(( BEFORE_COMMITS + 1 )) -- one switch is one commit however many attempts it took"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$(git -C "$FIX" rev-parse HEAD)" ] \
    || fail "case 15b: the retry did not publish -- the remote is at $(remote_sha "$BARE" refs/heads/main), the local HEAD at $(git -C "$FIX" rev-parse HEAD)"

# --- Case 11b: the run after a failed commit finishes it, and redoes nothing --
# The middle step, and the one where a fresh start is most expensive: by the
# time `.git/index.lock` stops the commit (test-set-model-guards.sh case 11) the
# gateway is already serving the new key, so a retry that begins again restarts
# a live gateway for a switch that took effect minutes ago. The lock is the
# realistic cause -- a crashed editor, a concurrent git -- and it clears by
# itself or by the operator deleting it, after which they run the same command.
new_fixture default --remote
BEFORE_COMMITS="$(commits "$FIX")"
BEFORE_REMOTE="$(remote_sha "$BARE" refs/heads/main)"
: > "$FIX/.git/index.lock"
run_set_model "$FIX" opus qwen3.8-next-80b-4bit
rm -f "$FIX/.git/index.lock"
[ "$RC" -ne 0 ] || fail "case 11b: the first run exited 0 although the index was locked, so there is nothing left to retry: $(out_err)"
PENDING_CFG="$(cfg "$FIX")"
printf '%s\n' "$PENDING_CFG" | grep -q '^  - model_name: qwen3.8-next-80b-4bit$' \
    || fail "case 11b: the first run left no rewritten file behind, so the retry cannot be shown to leave it alone:
$PENDING_CFG"
restarted "$FIX" \
    || fail "case 11b: the first run never restarted, so the commit it then failed to make was for a change nothing was serving -- and the retry below can no longer prove the gateway is left alone"
PENDING_RESTARTS="$(wc -l < "$FIX/restart.log")"
[ "$PENDING_RESTARTS" -eq 1 ] \
    || fail "case 11b: the first run restarted $PENDING_RESTARTS times: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" = "$BEFORE_COMMITS" ] \
    || fail "case 11b: a commit was recorded despite the locked index"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$BEFORE_REMOTE" ] \
    || fail "case 11b: the remote advanced from a commit that was never made"

run_set_model "$FIX" opus qwen3.8-next-80b-4bit
[ "$RC" -eq 0 ] \
    || fail "case 11b: the retry against an unlocked index exited $RC; the switch is live and uncommitted, which is the state this run exists to close: $(out_err)"
[ "$(cfg "$FIX")" = "$PENDING_CFG" ] \
    || fail "case 11b: the retry rewrote a file that already said what it was asked to say:
$(diff <(printf '%s\n' "$PENDING_CFG") <(cfg "$FIX"))"
[ "$(wc -l < "$FIX/restart.log")" -eq "$PENDING_RESTARTS" ] \
    || fail "case 11b: the retry restarted the gateway again, dropping live requests to re-apply a switch that was already serving: $(cat "$FIX/restart.log")"
[ "$(commits "$FIX")" -eq $(( BEFORE_COMMITS + 1 )) ] \
    || fail "case 11b: the retry left $(commits "$FIX") commits, expected $(( BEFORE_COMMITS + 1 )) -- the pending edit is one commit, not one per attempt"
[ "$(remote_sha "$BARE" refs/heads/main)" = "$(git -C "$FIX" rev-parse HEAD)" ] \
    || fail "case 11b: the retry did not publish the commit it had just made -- the remote is at $(remote_sha "$BARE" refs/heads/main), the local HEAD at $(git -C "$FIX" rev-parse HEAD)"

echo "PASS: test-set-model-config-ssot-3"
