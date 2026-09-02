#!/usr/bin/env bash
# Tests: scripts/lib/git-remote.sh
# Tags: scope:issue-specific, layer:TL2, git, publish, auto-pull, timeout
#
# Scenario (issue #89): set-model.sh now commits and pushes the config it
# rewrites, and code-ccgw pulls it before launching. Both need the same two
# primitives, so they live in one lib -- resolve where "publish" actually goes
# (_git_publish_target) and run a git command that cannot hang the caller
# (_git_run_deadline). Each function's contract is stated above its own cases.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LIB="$REPO/scripts/lib/git-remote.sh"
SET_MODEL="$REPO/scripts/set-model.sh"
LAUNCHER_SH="$REPO/scripts/code-ccgw.sh"
LAUNCHER_PS1="$REPO/scripts/code-ccgw.ps1"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # assert_eq <name> <want> <got> -- fail-fast, name in the message
    [ "$2" = "$3" ] || fail "$1: want='$2' got='$3'"
}

# --- The library's absence is a failure, not a skip --------------------------
# Every other suite in this feature gates on a script that already exists and is
# being rewritten, so its skip can only fire on a checkout without the file at
# all. This one is different: scripts/lib/git-remote.sh is NEW (detail.md 70),
# and nothing else in the plan forces it into existence. An implementer who
# inlines upstream resolution and the deadline runner into each caller instead
# of extracting them leaves a repository where every other suite is green and
# this one has skipped since the day it was written -- the two primitives then
# exist twice, diverge, and every case below covers neither copy. Red is the
# only report that says that out loud.
[ -f "$LIB" ] || fail "$LIB does not exist. detail.md 70/394 makes it the shared home of _git_publish_target and _git_run_deadline; if the logic was inlined into the launchers instead, extract it -- this suite is the only coverage those two primitives have"

# --- Case 0 (static): the callers use the library rather than their own copy --
# The runtime cases below prove the library behaves; they say nothing about
# whether anything CALLS it. Both POSIX callers resolve the same upstream and
# run git under the same deadline (detail.md 394), so a second hand-rolled copy
# in either of them is a copy this suite never sees -- and the symptom is the
# quiet one this whole issue is about: the publisher and the puller disagreeing
# about where "publish" goes. code-ccgw.ps1 is deliberately not required to
# source it (PowerShell cannot dot-source a POSIX lib); its symmetric contract
# lives in the Pester suite, and it is asserted here only to be a launcher that
# still exists to be checked against (CPR-ORTH).
assert_sources_lib() { # assert_sources_lib <file> <label>
    [ -f "$1" ] || fail "case 0/$2: $1 does not exist, so nothing proves the library has a caller at all"
    grep -Eq '(^|[[:space:]])(\.|source)[[:space:]]+[^#]*lib/git-remote\.sh' "$1" \
        || fail "case 0/$2: $1 never sources lib/git-remote.sh -- if it resolves the upstream or bounds git on its own, that copy is untested and free to drift from the one every case below pins"
}
assert_sources_lib "$SET_MODEL" set-model
assert_sources_lib "$LAUNCHER_SH" code-ccgw.sh
[ -f "$LAUNCHER_PS1" ] \
    || fail "case 0/code-ccgw.ps1: $LAUNCHER_PS1 does not exist; the Windows half of the same contract has no file to hold it"

# TL3 gap (what this suite does NOT catch):
# - a real network remote: DNS, TLS, an ssh agent, or a credential helper that
#   prompts, all of which change what a deadline actually has to interrupt
# - a push refused by a server-side hook, and what git prints when it is
# - whether a credential helper of the operator's own writes the secret this
#   suite proves the lib does not print
# All fixtures here are local bare repos, so the mitigation is the docs/ops.md
# publish smoke run at USER_VERIFIED, against the real origin.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The developer's own git identity, hooks and credential helpers must have no
# say in what these cases observe (rules/test/fixture-isolation.md).
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/xdg"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig-global"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
: > "$GIT_CONFIG_GLOBAL"

# Run from the temp tree, never from the worktree: `git rev-parse` inside the
# lib would otherwise resolve this checkout.
cd "$WORK" || fail "setup: cannot enter $WORK"

new_bare() { # new_bare <name> -> path
    local p="$WORK/$1.git"
    git init --quiet --bare --initial-branch=main "$p" >/dev/null 2>&1 || return 1
    printf '%s\n' "$p"
}

new_repo() { # new_repo <name> -> path (one commit on main, no remote yet)
    local p="$WORK/$1"
    git init --quiet --initial-branch=main "$p" >/dev/null 2>&1 || return 1
    git -C "$p" config core.hooksPath /dev/null
    git -C "$p" config user.email 'fixture@example.com'
    git -C "$p" config user.name 'Fixture'
    git -C "$p" config commit.gpgsign false
    printf 'seed\n' > "$p/seed.txt"
    git -C "$p" add seed.txt
    git -C "$p" commit --quiet -m 'seed'
    printf '%s\n' "$p"
}

OUT=""; ERR=""; RC=0; ELAPSED=0
call_target() { # call_target <repo-dir>
    OUT="$(cd "$1" && . "$LIB" && _git_publish_target 2>"$WORK/err")"
    RC=$?
    ERR="$(cat "$WORK/err")"
}

field() { # field <NAME> -- reads the last call_target's stdout
    printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n1
}

# --- _git_publish_target ------------------------------------------------------
# Contract: print `REMOTE=<name>` and `MERGE_REF=<refs/heads/...>`, exit 0; on
# any unresolvable condition exit non-zero and name WHICH condition on stderr.
# It must read branch.<b>.remote / branch.<b>.merge rather than splitting the
# `@{u}` rendering -- see case 6 for why that split is not decodable.

# --- Case 1: the ordinary shape -- main tracking origin/main -----------------
R1="$(new_repo repo1)" || fail "case 1: fixture repo could not be created"
B1="$(new_bare bare1)" || fail "case 1: bare remote could not be created"
git -C "$R1" remote add origin "$B1"
git -C "$R1" push --quiet -u origin main >/dev/null 2>&1 \
    || fail "case 1: seeding the bare remote failed"
call_target "$R1"
[ "$RC" -eq 0 ] || fail "case 1: exited $RC on a normally-tracking branch: $ERR"
[ "$(field REMOTE)" = "origin" ] || fail "case 1: REMOTE='$(field REMOTE)', expected 'origin'"
[ "$(field MERGE_REF)" = "refs/heads/main" ] \
    || fail "case 1: MERGE_REF='$(field MERGE_REF)', expected 'refs/heads/main'"

# --- Case 2: the branch's own name is not the ref it publishes to ------------
# The refspec has to come from branch.<b>.merge: pushing `wip` to
# `refs/heads/wip` would create a stray remote branch and leave main untouched,
# which reads as "published" while changing nothing anyone else fetches.
git -C "$R1" checkout --quiet -b wip
git -C "$R1" config branch.wip.remote origin
git -C "$R1" config branch.wip.merge refs/heads/main
call_target "$R1"
[ "$RC" -eq 0 ] || fail "case 2: exited $RC: $ERR"
[ "$(field REMOTE)" = "origin" ] || fail "case 2: REMOTE='$(field REMOTE)'"
[ "$(field MERGE_REF)" = "refs/heads/main" ] \
    || fail "case 2: MERGE_REF='$(field MERGE_REF)' -- the upstream ref, not the local branch name, decides"
git -C "$R1" checkout --quiet main

# --- Case 3: detached HEAD ---------------------------------------------------
R3="$(new_repo repo3)" || fail "case 3: fixture repo could not be created"
git -C "$R3" checkout --quiet --detach HEAD
call_target "$R3"
[ "$RC" -ne 0 ] || fail "case 3: exited 0 on a detached HEAD; there is no branch to publish"
printf '%s' "$ERR" | grep -qi 'detach' \
    || fail "case 3: the refusal must name the condition ('detached'), got: $ERR"

# --- Case 4: a branch with no upstream at all --------------------------------
R4="$(new_repo repo4)" || fail "case 4: fixture repo could not be created"
call_target "$R4"
[ "$RC" -ne 0 ] || fail "case 4: exited 0 with no upstream configured"
[ -n "$ERR" ] || fail "case 4: refused silently; the operator must be told why"
printf '%s' "$ERR" | grep -qi 'upstream\|tracking' \
    || fail "case 4: the refusal must name the missing upstream, got: $ERR"

# --- Case 5: an upstream that is the local repository itself -----------------
# `branch.<b>.remote = .` is legal git and means "track a local branch". There
# is no remote to publish to, and a naive resolver hands back "." and then
# pushes into the repository it is already standing in.
R5="$(new_repo repo5)" || fail "case 5: fixture repo could not be created"
git -C "$R5" branch other
git -C "$R5" config branch.main.remote .
git -C "$R5" config branch.main.merge refs/heads/other
call_target "$R5"
[ "$RC" -ne 0 ] || fail "case 5: exited 0 for a local-only upstream (branch.main.remote='.')"
printf '%s' "$ERR" | grep -qi 'publish remote\|no remote\|local' \
    || fail "case 5: the refusal must say there is no publish remote, got: $ERR"

# --- Case 6: a remote whose NAME contains a slash ----------------------------
# `git rev-parse --abbrev-ref @{u}` renders this as `up/stream/main`; splitting
# on the first '/' yields remote 'up' and ref 'stream/main', both wrong, and
# the push then fails naming a remote nobody ever configured.
R6="$(new_repo repo6)" || fail "case 6: fixture repo could not be created"
B6="$(new_bare bare6)" || fail "case 6: bare remote could not be created"
# Whether the name is accepted is a property of this git build, so the skip is
# scoped to this case's assertions with the if/else shape used by
# test-code-ccgw-auto-pull.sh case 10 (CPR-ORTH). A bare `exit 77` would end the
# script mid-sequence and take cases 7-15 with it, reported as a clean skip.
if ! git -C "$R6" remote add up/stream "$B6" 2>/dev/null; then
    echo "note: case 6 skipped -- this git build rejects a slash in a remote name"
else
    git -C "$R6" push --quiet -u up/stream main >/dev/null 2>&1 \
        || fail "case 6: seeding through the slashed remote failed"
    call_target "$R6"
    [ "$RC" -eq 0 ] || fail "case 6: exited $RC on a slash-bearing remote name: $ERR"
    [ "$(field REMOTE)" = "up/stream" ] \
        || fail "case 6: REMOTE='$(field REMOTE)' -- the @{u} rendering was mis-split"
    [ "$(field MERGE_REF)" = "refs/heads/main" ] \
        || fail "case 6: MERGE_REF='$(field MERGE_REF)' -- the @{u} rendering was mis-split"
fi

# --- _git_run_deadline <seconds> <cmd> [args...] ------------------------------
# Contract: return the command's own status when it finishes in time, non-zero
# after <seconds> otherwise, and take the whole process TREE with it -- a `git
# fetch` that spawned ssh or a credential helper must not outlive the deadline
# (concern C5), or the launcher appears to hang after it already gave up.
PIDFILE="$WORK/child.pid"

run_deadline() { # run_deadline <seconds> <cmd...> -> sets RC, ELAPSED
    local start end
    start="$(date +%s)"
    ( . "$LIB" && _git_run_deadline "$@" ) >"$WORK/dl.out" 2>"$WORK/dl.err"
    RC=$?
    end="$(date +%s)"
    ELAPSED=$(( end - start ))
}

child_alive() { # child_alive -> 0 while the recorded descendant still exists
    [ -s "$PIDFILE" ] || return 1
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

await_child_exit() { # poll rather than sleep once: teardown is asynchronous
    local i=0
    while [ "$i" -lt 10 ]; do
        child_alive || return 0
        sleep 1
        i=$(( i + 1 ))
    done
    return 1
}

make_spawner() { # make_spawner <path> <parent-behaviour-line>
    {
        printf '#!/bin/bash\n'
        printf 'sleep 300 &\n'
        printf 'printf %%s "$!" > "%s"\n' "$PIDFILE"
        printf '%s\n' "$2"
    } > "$1"
    chmod +x "$1"
}

# --- Case 7: a command that finishes in time keeps its own exit status -------
# Collapsing every outcome onto 0/1 would leave the caller unable to tell "the
# push was rejected" from "the push timed out" -- different remedies entirely.
run_deadline 10 sh -c 'exit 7'
[ "$RC" -eq 7 ] || fail "case 7: a fast command's status was rewritten to $RC, expected 7"
run_deadline 10 sh -c 'exit 0'
[ "$RC" -eq 0 ] || fail "case 7: a successful command reported $RC"

# --- Case 8: a hanging command is cut off and control comes back -------------
run_deadline 3 sleep 300
[ "$RC" -ne 0 ] || fail "case 8: a command that never finished reported success"
[ "$ELAPSED" -lt 30 ] \
    || fail "case 8: the 3s deadline did not fire -- the call took ${ELAPSED}s"

# --- Case 9: descendants do not survive the deadline (C5) --------------------
rm -f "$PIDFILE"
SPAWNER="$WORK/spawn-and-wait.sh"
make_spawner "$SPAWNER" 'sleep 300'
run_deadline 3 "$SPAWNER"
[ "$RC" -ne 0 ] || fail "case 9: the hanging spawner reported success"
[ -s "$PIDFILE" ] || fail "case 9: the fixture never recorded a descendant PID; nothing was proven"
await_child_exit \
    || fail "case 9: descendant PID $(cat "$PIDFILE") outlived the deadline; the whole process tree must go"

# --- Case 10: the runner does not wait on an inherited pipe ------------------
# The parent exits at once but the descendant holds the pipe open. A runner
# that reads to EOF blocks for the descendant's full lifetime even though the
# command it was asked to run was already finished.
rm -f "$PIDFILE"
SPAWNER2="$WORK/spawn-and-exit.sh"
make_spawner "$SPAWNER2" 'exit 0'
run_deadline 30 "$SPAWNER2"
[ "$RC" -eq 0 ] || fail "case 10: the spawner exited 0 but the runner reported $RC: $(cat "$WORK/dl.err")"
[ "$ELAPSED" -lt 20 ] \
    || fail "case 10: the call took ${ELAPSED}s although the command exited at once -- it waited on the descendant's pipe"
[ -s "$PIDFILE" ] || fail "case 10: the fixture never recorded a descendant PID; nothing was proven"
await_child_exit \
    || fail "case 10: descendant PID $(cat "$PIDFILE") survived a command that had already exited"

# --- _git_publish_target, adversarial input -----------------------------------
# Cases 1-6 read a config git itself wrote. This section reads one a human (or a
# merge) wrote: `.git/config` is a plain file in a repo people pull, so both
# fields below arrive as untrusted strings that the lib then hands to `git push`.
# The marker file is the probe -- it exists only if a value was executed rather
# than passed as an argument (CWE-78).
MARKER="$WORK/pwned"
R11="$(new_repo repo11)" || fail "case 11: fixture repo could not be created"
B11="$(new_bare bare11)" || fail "case 11: bare remote could not be created"
git -C "$R11" remote add origin "$B11"
git -C "$R11" push --quiet -u origin main >/dev/null 2>&1 \
    || fail "case 11: seeding the bare remote failed"
REFS_BEFORE="$(git -C "$B11" for-each-ref)"

# --- Case 11: a hostile remote NAME is data, never a command -----------------
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    input="${input//@MARKER@/$MARKER}"

    rm -f "$MARKER"
    git -C "$R11" config branch.main.remote "$input"
    call_target "$R11"
    [ ! -e "$MARKER" ] || fail "case 11/$name: the remote name was executed -- '$input' created $MARKER"
    if [ "$want" = refuse ]; then
        [ "$RC" -ne 0 ] || fail "case 11/$name: exited 0 for a remote that is not configured ('$input')"
    else
        [ "$RC" -eq 0 ] || fail "case 11/$name: exited $RC on the honest control row: $ERR"
        assert_eq "case 11/$name: REMOTE must be the configured name verbatim" "$want" "$(field REMOTE)"
    fi
    assert_eq "case 11/$name: the remote's refs must be untouched by a resolve" \
        "$REFS_BEFORE" "$(git -C "$B11" for-each-ref)"
done <<'TABLE'
control        | origin                 | origin
semicolon      | origin;touch @MARKER@  | refuse
dollar-paren   | $(touch @MARKER@)      | refuse
backtick       | `touch @MARKER@`       | refuse
dollar-brace   | ${IFS}touch @MARKER@   | refuse
leading-dash   | --upload-pack=touch    | refuse
inner-space    | origin touch @MARKER@  | refuse
glob           | orig*                  | refuse
TABLE
git -C "$R11" config branch.main.remote origin

# --- Case 12: a merge ref outside refs/heads/ is refused ---------------------
# set-model.sh publishes with `git push <remote> HEAD:$MERGE_REF`. A merge ref
# naming a tag would create a tag out of a commit, one naming refs/remotes/
# would write a tracking ref nobody fetches, and either reads to the operator as
# a successful publish. Only a branch ref is a publish target.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    input="${input//@MARKER@/$MARKER}"

    rm -f "$MARKER"
    git -C "$R11" config branch.main.merge "$input"
    call_target "$R11"
    [ ! -e "$MARKER" ] || fail "case 12/$name: the merge ref was executed -- '$input' created $MARKER"
    if [ "$want" = refuse ]; then
        [ "$RC" -ne 0 ] || fail "case 12/$name: exited 0 for '$input', which is not a branch to publish to"
    else
        [ "$RC" -eq 0 ] || fail "case 12/$name: exited $RC on the honest control row: $ERR"
        assert_eq "case 12/$name: MERGE_REF must be the configured ref verbatim" "$want" "$(field MERGE_REF)"
    fi
    assert_eq "case 12/$name: the remote's refs must be untouched by a resolve" \
        "$REFS_BEFORE" "$(git -C "$B11" for-each-ref)"
done <<'TABLE'
control         | refs/heads/main                 | refs/heads/main
tag             | refs/tags/v1                    | refuse
remote-tracking | refs/remotes/origin/main        | refuse
notes           | refs/notes/commits              | refuse
bare-head       | HEAD                            | refuse
traversal       | refs/heads/../../hooks/pre-push | refuse
injected        | refs/heads/main;touch @MARKER@  | refuse
TABLE
git -C "$R11" config branch.main.merge refs/heads/main

# --- Case 13: a failing push never prints the credential in the URL ----------
# `https://user:token@host/...` in a remote URL is what a personal access token
# looks like once someone runs `git remote set-url` with one. The push here is
# aimed at the discard port so it fails immediately, which is exactly the path
# that prints a URL -- and the launcher's stderr is what an operator pastes into
# an issue (OWASP ASVS V8: secrets must not reach logs or error messages).
SECRET='tok3n-do-not-leak-9df3'
# Stdout and stderr are only the copy the operator sees go past. The deadline
# wrapper has to put the command somewhere while it watches it -- a spool file,
# a status file, a log -- and git writes its own scratch under TMPDIR too. A
# credential kept out of the terminal and left in a file under /tmp is still
# leaked, and that copy outlives the terminal. So this case owns an empty
# temp directory: whatever is found in it afterwards was written by this run.
LEAK_TMP="$WORK/leak-tmp13"
rm -rf "$LEAK_TMP"
mkdir -p "$LEAK_TMP"
export TMPDIR="$LEAK_TMP" TEMP="$LEAK_TMP" TMP="$LEAK_TMP"
git -C "$R11" remote set-url origin "https://ccgw-user:$SECRET@127.0.0.1:9/repo.git"
run_deadline 20 git -C "$R11" push origin HEAD:refs/heads/main
[ "$RC" -ne 0 ] || fail "case 13: the push to the discard port reported success"
[ "$ELAPSED" -lt 40 ] || fail "case 13: the failing push took ${ELAPSED}s; the deadline did not bound it"
LEAK="$(cat "$WORK/dl.out" "$WORK/dl.err" 2>/dev/null; printf '%s%s' "$OUT" "$ERR")"
case "$LEAK" in
    *"$SECRET"*) fail "case 13: the credential appeared in the captured output: $LEAK" ;;
esac
# Proven against a planted copy first: this is a negative assertion over a
# directory that is usually empty, which passes just as well when the sweep is
# broken.
printf 'https://ccgw-user:%s@127.0.0.1:9/repo.git\n' "$SECRET" > "$WORK/leak-probe.log"
grep -rlaF -- "$SECRET" "$WORK/leak-probe.log" >/dev/null 2>&1 \
    || fail "case 13: the sweep cannot find the secret in a file that plainly contains it, so the sweep below asserts nothing"
rm -f "$WORK/leak-probe.log"
TMP_HITS="$(grep -rlaF -- "$SECRET" "$LEAK_TMP" 2>/dev/null; find "$LEAK_TMP" -name "*$SECRET*" 2>/dev/null)"
[ -z "$TMP_HITS" ] \
    || fail "case 13: the credential was written into a temp file that outlives the run: $TMP_HITS"

# The third copy is the one nobody clears: a failing fetch or push writes
# FETCH_HEAD, reflogs and its own error reports INSIDE .git/, and a deadline
# wrapper that spools the command line or git's output next to the repository
# leaves it there too. TMPDIR gets emptied; .git/ is handed to whoever gets the
# checkout, and rides into any archive or backup taken of it.
# `.git/config` is excluded, and it is the only exclusion: the URL is in it
# because the operator put it there with `git remote set-url`, so that copy is
# their own record rather than a spill. It holds the secret right now, which is
# what makes the exclusion load-bearing rather than decorative -- and the
# planted probe below proves the sweep still reaches everything else.
git_state_hits() { # git_state_hits <repo> <secret> -- files under .git/ carrying it
    find "$1/.git" -type f ! -name config ! -name 'config.worktree' \
        -exec grep -laF -- "$2" {} + 2>/dev/null
    find "$1/.git" -name "*$2*" 2>/dev/null
}
grep -qF -- "$SECRET" "$R11/.git/config" \
    || fail "case 13: .git/config no longer carries the credential, so the one exclusion the sweep makes is not being exercised"
printf 'https://ccgw-user:%s@127.0.0.1:9/repo.git\n' "$SECRET" > "$R11/.git/ccgw-leak-probe"
[ -n "$(git_state_hits "$R11" "$SECRET")" ] \
    || fail "case 13: the .git sweep cannot find the secret in a file under .git/ that plainly contains it, so its silence below asserts nothing"
rm -f "$R11/.git/ccgw-leak-probe"
GIT_HITS="$(git_state_hits "$R11" "$SECRET")"
[ -z "$GIT_HITS" ] \
    || fail "case 13: the credential was written into the repository's own git state, which travels with the checkout: $GIT_HITS"

unset TMPDIR TEMP TMP
git -C "$R11" remote set-url origin "$B11"

# --- Case 14: the deadline argument itself is validated ----------------------
# Every row here is a value `timeout(1)` or `$(( ))` would read as something
# other than what it says: coreutils reads `0` as "no limit at all", `$(( ))`
# turns `abc` and `` into 0, and `5s` is the habit a timeout(1) user brings.
# All three land on the same outcome -- an unbounded wait wearing a deadline's
# name -- which is the one thing this primitive exists to prevent. Refusing
# before the command starts is what makes that visible: the caller passes a
# literal here, so a bad value is a defect in the caller, not the operator's
# typo (that path is the env knob, exercised in test-set-model-guards.sh).
DL_MARKER="$WORK/deadline-ran"
while IFS='|' read -r name secs want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    secs="${secs#"${secs%%[![:space:]]*}"}"
    secs="${secs%"${secs##*[![:space:]]}"}"
    [ "$secs" = "@EMPTY@" ] && secs=""

    rm -f "$DL_MARKER"
    run_deadline "$secs" sh -c "touch '$DL_MARKER'; exit 7"
    [ "$ELAPSED" -lt 30 ] \
        || fail "case 14/$name: the call took ${ELAPSED}s for the deadline '$secs'; no value of it may become an unbounded wait"
    if [ "$want" = refuse ]; then
        [ "$RC" -ne 0 ] \
            || fail "case 14/$name: exited 0 for the deadline '$secs', so the caller believes a limit was applied"
        [ ! -e "$DL_MARKER" ] \
            || fail "case 14/$name: the command ran under the unusable deadline '$secs'; a git push started this way is bounded by nothing"
        [ -s "$WORK/dl.err" ] \
            || fail "case 14/$name: the deadline '$secs' was refused silently, so nothing points at the caller that passed it"
    else
        [ "$RC" -eq 7 ] \
            || fail "case 14/$name: reported $RC for the deadline '$secs', expected the command's own 7 -- a large but well-formed limit must not wrap into an expired one"
        [ -e "$DL_MARKER" ] || fail "case 14/$name: the command never ran under the deadline '$secs'"
    fi
done <<'TABLE'
zero        | 0                     | refuse
negative    | -1                    | refuse
non-numeric | abc                   | refuse
suffixed    | 5s                    | refuse
empty       | @EMPTY@               | refuse
huge        | 999999999999999999    | run
TABLE

# --- Case 15: a sanctioned branch ref that contains slashes of its own -------
# Case 12 refuses everything OUTSIDE refs/heads/, which a resolver can satisfy
# by keeping only the last path component -- and `refs/heads/feature/issue-89`
# then publishes to `refs/heads/issue-89`, a branch nobody tracks, while the one
# the operator is on never moves. Every host in this repo publishes from a
# working branch of exactly that shape, so the accepted half of the boundary
# needs its own evidence: sanctioned AND intact, character for character.
NESTED_N=0
while IFS='|' read -r name ref; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; ref="${ref//[[:space:]]/}"
    NESTED_N=$(( NESTED_N + 1 ))
    RN="$(new_repo "repo15-$NESTED_N")" || fail "case 15/$name: fixture repo could not be created"
    BN="$(new_bare "bare15-$NESTED_N")" || fail "case 15/$name: bare remote could not be created"
    git -C "$RN" remote add origin "$BN"
    LOCAL_BRANCH="${ref#refs/heads/}"
    git -C "$RN" checkout --quiet -b "$LOCAL_BRANCH" \
        || fail "case 15/$name: this git build rejects the branch name '$LOCAL_BRANCH', so the fixture cannot pose the case"
    git -C "$RN" push --quiet -u origin "$LOCAL_BRANCH" >/dev/null 2>&1 \
        || fail "case 15/$name: seeding the bare remote failed"
    call_target "$RN"
    [ "$RC" -eq 0 ] \
        || fail "case 15/$name: exited $RC on '$ref', which IS under refs/heads/ and is the shape this repo's own work branches take: $ERR"
    assert_eq "case 15/$name REMOTE" origin "$(field REMOTE)"
    assert_eq "case 15/$name MERGE_REF" "$ref" "$(field MERGE_REF)"
done <<'TABLE'
one-slash  | refs/heads/feature/issue-89
two-slash  | refs/heads/feature/89/litellm-env
dotted     | refs/heads/release/v1.2.3
TABLE

echo "PASS: test-git-remote-lib"
