#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, scripts/lib/git-remote.sh
# Tags: scope:issue-specific, layer:TL2, client-launcher, auto-pull, git, timeout
# Scenario (issue #89): config.yaml owns the routing keys now, so a backend
# swapped on the Mac reaches this host only once the repository does. The
# launcher pulls before starting Claude Code -- a network operation on an
# interactive command's critical path -- so no upstream, a dirty tree, diverged
# history and an unreachable remote must each end in a launch anyway. Cases 13
# onward and the shared fixture sit beside this file (rules/coding/file-split).
# TL3 gap: a real remote (DNS, TLS, ssh, a prompting credential helper), a merge
# leaving conflict markers, and the operator's git config -- see docs/ops.md.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/code-ccgw-auto-pull/fixture.sh"


# --- Case 1: on by default, and the pulled value is what the child gets ------
# Ordering is the point: pulling after reading config.yaml would hand this run
# the old key and only take effect on the next launch.
new_ops
publish_upstream pulled-opus
BEFORE="$(head_sha "$OPS")"
run_launcher
[ "$RC" -eq 0 ] || fail "case 1: exited $RC: $(cat "$WORK/err")"
[ "$(head_sha "$OPS")" != "$BEFORE" ] \
    || fail "case 1: the working copy did not advance; auto-pull must be on by default"
assert_launched "case 1"
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "pulled-opus" ] \
    || fail "case 1: the child got '$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)'; config.yaml must be read after the pull, not before"

# --- Case 2: CCGW_AUTO_PULL=off means no network at all ----------------------
new_ops
publish_upstream pulled-opus
BEFORE="$(head_sha "$OPS")"
run_launcher CCGW_AUTO_PULL=off
[ "$RC" -eq 0 ] || fail "case 2: exited $RC: $(cat "$WORK/err")"
[ "$(head_sha "$OPS")" = "$BEFORE" ] || fail "case 2: the working copy advanced although the pull was switched off"
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "lite-opus" ] \
    || fail "case 2: the child got the upstream value although the pull was switched off"

# --- Case 3: an edit in progress is never touched ----------------------------
# The operator may be mid-change in the very file the pull would rewrite.
# Losing that to a background convenience is the worst outcome available here.
new_ops
publish_upstream pulled-opus
printf '\n# uncommitted local work\n' >> "$OPS/litellm-server/config.yaml"
BEFORE="$(head_sha "$OPS")"
run_launcher
[ "$RC" -eq 0 ] || fail "case 3: exited $RC on a dirty tree: $(cat "$WORK/err")"
[ "$(head_sha "$OPS")" = "$BEFORE" ] || fail "case 3: the pull ran over uncommitted work"
grep -q '# uncommitted local work' "$OPS/litellm-server/config.yaml" \
    || fail "case 3: the operator's uncommitted edit is gone"
assert_stderr 'dirty\|uncommitted\|local change' "case 3: skipping the pull silently leaves the host quietly stale"
assert_launched "case 3"

# --- Case 4: diverged history is reported, never resolved by force -----------
# Reachability alone is too weak a contract here: `git reset --hard @{u}` and
# `git rebase` both leave the old commit reachable through the reflog, and a
# merge that succeeds leaves it reachable as a parent -- yet all three have
# rewritten the operator's checkout. So the assertion is that NOTHING moved:
# not HEAD, not the index, not the working tree, not the file itself.
new_ops
publish_upstream pulled-opus
config_body local-opus > "$OPS/litellm-server/config.yaml"
git -C "$OPS" add -A
git -C "$OPS" commit --quiet -m 'local work not yet pushed'
LOCAL_SHA="$(head_sha "$OPS")"
snapshot_repo "$OPS" div-before
run_launcher
[ "$RC" -eq 0 ] || fail "case 4: exited $RC on diverged history: $(cat "$WORK/err")"
snapshot_repo "$OPS" div-after
assert_repo_unchanged div-before div-after "case 4: a diverged history must be reported, not resolved"
git -C "$OPS" merge-base --is-ancestor "$LOCAL_SHA" HEAD \
    || fail "case 4: the local commit $LOCAL_SHA is no longer reachable -- the pull discarded it"
assert_stderr 'diverg\|behind\|ahead' "case 4: the operator must be told the histories parted"
assert_launched "case 4"
# The launch still runs on the LOCAL file: refusing to merge must not also mean
# refusing to read what is already on disk.
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "local-opus" ] \
    || fail "case 4: the child got '$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)'; the un-merged local config.yaml is still the one in effect"

# --- Case 4b: ahead of an upstream that never moved -- silence, and no push --
# The other half of case 4's classifier, and the shape the operator is in after
# every commit they have not pushed yet. Nothing to fetch, nothing to
# fast-forward to, so by S5 step 7 -- print only when HEAD actually moved -- the
# correct behaviour is silence. A classifier that reads "not equal to upstream"
# as "diverged" warns on every launch until case 4's real divergence goes
# unread; one that reads "ahead" as an invitation to publish ships work the
# operator had not chosen to share, so the bare remote is snapshotted too.
new_ops
config_body local-opus > "$OPS/litellm-server/config.yaml"
git -C "$OPS" add -A
git -C "$OPS" commit --quiet -m 'local commit not yet pushed'
AHEAD_SHA="$(head_sha "$OPS")"
AHEAD_REMOTE="$(git -C "$BARE" rev-parse refs/heads/main)"
snapshot_repo "$OPS" ahead-before
run_launcher
[ "$RC" -eq 0 ] || fail "case 4b: exited $RC while merely ahead of upstream: $(cat "$WORK/err")"
snapshot_repo "$OPS" ahead-after
assert_repo_unchanged ahead-before ahead-after \
    "case 4b: upstream moved nowhere, so there was nothing to fast-forward to"
[ "$(head_sha "$OPS")" = "$AHEAD_SHA" ] \
    || fail "case 4b: HEAD left the operator's own commit $AHEAD_SHA"
[ "$(git -C "$BARE" rev-parse refs/heads/main)" = "$AHEAD_REMOTE" ] \
    || fail "case 4b: the launcher published the operator's unpushed commit; auto-PULL may never push"
assert_launched "case 4b"
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "local-opus" ] \
    || fail "case 4b: the child got '$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)', not the local commit's 'local-opus'"
if grep -Eq 'diverg|behind|dirty|uncommitted' "$WORK/out" "$WORK/err"; then
    fail "case 4b: an unpushed commit was reported as a problem; this launch is the common one, so case 4's warning becomes noise: $(cat "$WORK/err")"
fi
if grep -Eq 'pulled|fast.?forward|updated' "$WORK/out" "$WORK/err"; then
    fail "case 4b: an update was announced although HEAD never moved: $(cat "$WORK/err")"
fi

# --- Case 5: no upstream is a warning, not a failure -------------------------
new_ops
git -C "$OPS" config --unset branch.main.remote
git -C "$OPS" config --unset branch.main.merge
run_launcher
[ "$RC" -eq 0 ] || fail "case 5: exited $RC with no upstream: $(cat "$WORK/err")"
assert_stderr 'upstream\|tracking' "case 5: the warning must name the missing upstream"
assert_launched "case 5"

# --- Case 6: an upstream that is the local repository itself -----------------
# `branch.<b>.remote = .` is legal git and means "track a local branch". There
# is nothing to fetch, and a resolver that hands back "." pulls from the
# repository it is already standing in.
new_ops
git -C "$OPS" branch other
git -C "$OPS" config branch.main.remote .
git -C "$OPS" config branch.main.merge refs/heads/other
run_launcher
[ "$RC" -eq 0 ] || fail "case 6: exited $RC for a local-only upstream: $(cat "$WORK/err")"
assert_stderr 'remote\|local' "case 6: the warning must say there is nothing to pull from"
assert_launched "case 6"

# --- the hang cases -----------------------------------------------------------
# A stub `git` shadows the real one on PATH. What is being proven is not that
# git can hang, but that a hang costs the operator a bounded wait and leaves
# nothing running afterwards (concern C5).
PIDFILE="$WORK/child.pid"
HANG_DIR="$WORK/stub-hang"
mkdir -p "$HANG_DIR"

make_hanging_git() { # make_hanging_git <parent-behaviour-line>
    {
        printf '#!/bin/bash\n'
        printf 'sleep 300 &\n'
        printf 'printf %%s "$!" > "%s"\n' "$PIDFILE"
        printf '%s\n' "$1"
    } > "$HANG_DIR/git"
    chmod +x "$HANG_DIR/git"
}

child_alive() { [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

await_child_exit() { # teardown is asynchronous, so poll rather than sleep once
    local i=0
    while [ "$i" -lt 15 ]; do
        child_alive || return 0
        sleep 1
        i=$(( i + 1 ))
    done
    return 1
}

# --- Case 7: a hanging git costs a bounded wait ------------------------------
new_ops
rm -f "$PIDFILE"
make_hanging_git 'sleep 300'
SAVED_PATH="$CHILD_PATH"
CHILD_PATH="$HANG_DIR:$STUB:/usr/bin:/bin"
run_launcher
[ "$ELAPSED" -lt 90 ] \
    || fail "case 7: the launch took ${ELAPSED}s; an unreachable remote must not hold an interactive command open indefinitely"
assert_launched "case 7"

# --- Case 8: the whole process tree goes with the deadline -------------------
# A real `git fetch` spawns ssh or a credential helper. Killing only the git
# process leaves those holding the terminal, so the launch looks hung long
# after the launcher itself gave up.
[ -s "$PIDFILE" ] || fail "case 8: the stub never recorded a descendant PID; nothing was proven"
await_child_exit \
    || fail "case 8: descendant PID $(cat "$PIDFILE") outlived the deadline"

# --- Case 9: a git that exits at once is not waited on -------------------------
# The descendant still holds the inherited pipe open. A launcher that reads to
# EOF blocks for its full lifetime even though the command it ran is finished.
new_ops
rm -f "$PIDFILE"
make_hanging_git 'exit 0'
run_launcher
[ "$ELAPSED" -lt 20 ] \
    || fail "case 9: the launch took ${ELAPSED}s although git exited at once -- it waited on the descendant's pipe"
assert_launched "case 9"
[ -s "$PIDFILE" ] || fail "case 9: the stub never recorded a descendant PID; nothing was proven"
await_child_exit \
    || fail "case 9: descendant PID $(cat "$PIDFILE") survived a git that had already exited"

CHILD_PATH="$SAVED_PATH"

# --- Case 10: git is not installed at all ------------------------------------
# The pull is a convenience the launcher grew; a host without git (or with a
# PATH that lost it) still has a perfectly working client. Reaching for a
# missing binary must therefore read as a warning, not as a launch failure --
# and must not be silent either, or the host goes quietly stale forever.
NOGIT="$WORK/nogit"
mkdir -p "$NOGIT"
for u in sh bash env printf cat cut tr grep sed awk head tail sort uniq wc \
         date sleep mkdir rmdir rm cp mv ln chmod dirname basename readlink \
         mktemp find id kill expr test; do
    src="$(command -v "$u" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$NOGIT/$u" 2>/dev/null
done
if PATH="$STUB:$NOGIT" command -v git >/dev/null 2>&1; then
    echo "note: case 10 skipped -- git stays reachable even off this PATH"
elif ! PATH="$STUB:$NOGIT" sh -c 'command -v sed >/dev/null 2>&1' 2>/dev/null; then
    # Symlinked-out coreutils do not run everywhere (a Windows msys build loads
    # its DLLs from the binary's own directory), and a launcher that cannot
    # start says nothing about the missing-git path. The Windows half of this
    # case lives in code-ccgw-windows/context-17-auto-pull.ps1 (17i).
    echo "note: case 10 skipped -- this platform cannot run a symlinked PATH"
else
    new_ops
    publish_upstream pulled-opus
    BEFORE="$(head_sha "$OPS")"
    NOGIT_SAVED="$CHILD_PATH"
    CHILD_PATH="$STUB:$NOGIT"
    run_launcher
    CHILD_PATH="$NOGIT_SAVED"
    [ "$RC" -eq 0 ] || fail "case 10: exited $RC because git is missing; the client does not need it: $(cat "$WORK/err")"
    assert_launched "case 10"
    [ "$(head_sha "$OPS")" = "$BEFORE" ] || fail "case 10: the checkout advanced with no git on PATH"
    assert_stderr 'git' "case 10: the warning must name the binary it could not find"
fi

# --- Case 11: git is there but the very first call fails ---------------------
# The shape of an expired credential, a proxy that refuses CONNECT, or a remote
# that has gone away: git returns at once with a message. Distinct from the
# hang cases above -- nothing to time out, so nothing there would notice a
# launcher that treated a failed fetch as fatal.
FAILGIT="$WORK/stub-failgit"
mkdir -p "$FAILGIT"
{
    printf '#!/bin/bash\n'
    printf 'printf "fatal: could not read from remote repository\\n" >&2\n'
    printf 'exit 128\n'
} > "$FAILGIT/git"
chmod +x "$FAILGIT/git"
new_ops
publish_upstream pulled-opus
BEFORE="$(head_sha "$OPS")"
FAILGIT_SAVED="$CHILD_PATH"
CHILD_PATH="$FAILGIT:$STUB:/usr/bin:/bin"
run_launcher
CHILD_PATH="$FAILGIT_SAVED"
[ "$RC" -eq 0 ] || fail "case 11: exited $RC after a failed fetch; the launch must survive it: $(cat "$WORK/err")"
assert_launched "case 11"
[ "$ELAPSED" -lt 30 ] || fail "case 11: took ${ELAPSED}s although git returned at once -- a failure must not be retried into a wait"
[ "$(head_sha "$OPS")" = "$BEFORE" ] || fail "case 11: the checkout advanced although every git call failed"
assert_stderr 'pull\|fetch\|remote\|git' "case 11: a failed pull must be reported, not swallowed"

# --- Case 12: a CCGW_AUTO_PULL nobody defined ---------------------------------
# `on` is the only value that turns the pull on (the repo's boolean idiom), so
# every spelling below is off. Off silently would be the trap: the operator who
# wrote `CCGW_AUTO_PULL=true` believes their host self-updates, and it never
# does. Table-driven per skills/_shared/test-design/parser-regex-tests.md --
# one prose case would pin one spelling and leave the rest to chance.
new_ops
publish_upstream pulled-opus
BEFORE="$(head_sha "$OPS")"
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input//[[:space:]]/}"
    [ "$input" = "@EMPTY@" ] && input=""
    [ "$input" = "@SPACE@" ] && input=" "

    run_launcher "CCGW_AUTO_PULL=$input" </dev/null
    [ "$RC" -eq 0 ] || fail "case 12/$name: exited $RC: $(cat "$WORK/err")"
    assert_launched "case 12/$name"
    [ "$(head_sha "$OPS")" = "$BEFORE" ] \
        || fail "case 12/$name: '$input' pulled; only 'on' turns the pull on"
    [ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "lite-opus" ] \
        || fail "case 12/$name: the child got the upstream value, so the pull ran after all"
    if [ "$want" = warn ]; then
        assert_stderr 'CCGW_AUTO_PULL' "case 12/$name: a value that is neither on nor off must be named back to the operator"
    fi
done <<'TABLE'
misspelt   | onn      | warn
uppercase  | ON       | warn
boolean    | true     | warn
numeric    | 1        | warn
yes        | yes      | warn
space-only | @SPACE@  | warn
empty      | @EMPTY@  | quiet
TABLE

echo "PASS: test-code-ccgw-auto-pull"
