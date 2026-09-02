#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, scripts/lib/git-remote.sh
# Tags: scope:issue-specific, layer:TL2, client-launcher, auto-pull, git, idempotency
#
# Continuation of test-code-ccgw-auto-pull.sh past the 500-line limit of
# rules/coding/file-split.md; shared fixture in code-ccgw-auto-pull/fixture.sh,
# case numbering continues from 13. Subject: where the opt-out is read FROM,
# what a tree too dirty to touch looks like, and what a repeat launch may change.
# TL3 gap: as in the sibling suite -- a real remote (DNS, TLS, ssh, a credential
# helper that prompts), a merge that leaves conflict markers, and the operator's
# own git config. Mitigated by the docs/ops.md cutover run at USER_VERIFIED.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/code-ccgw-auto-pull/fixture.sh"

# --- Harness self-test (not a product case) ----------------------------------
# assert_env is the assertion cases 16 and 17 rest on, and it was once called
# here without being defined in this file or its fixture. Neither carries
# `set -e`, so the undefined call wrote "command not found" to stderr and the
# case continued -- green, with its central assertion never made. This proves
# the helper exists, that a matching value passes, and -- the half that matters
# -- that a mismatched one aborts. It is driven off a hand-written dump, so it
# depends on no product behaviour and stays meaningful while the launcher is
# still unimplemented.
printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=harness-probe\n' > "$DUMP"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL harness-probe \
    "harness self-test: a matching value must pass"
( assert_env ANTHROPIC_DEFAULT_OPUS_MODEL harness-probe-WRONG "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_env returned success for a value that does not match; every assert_env below is asserting nothing"
( assert_env NO_SUCH_VARIABLE_AT_ALL anything "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_env returned success for a variable the dump never exported"
rm -f "$DUMP"

# --- Case 13: the opt-out works from the .env file, not just from the shell --
# Case 2 sets CCGW_AUTO_PULL in the process environment, which proves the branch
# reads the variable but says nothing about WHEN. .env is where an operator
# actually writes it, and it is loaded by the launcher itself -- so a pull placed
# before the loader would ignore the file entirely and still pass case 2. Here
# the shell hands over nothing at all and the file is the only source.
new_ops
publish_upstream pulled-opus
snapshot_repo "$OPS" dotenv-off-before
printf 'CCGW_AUTO_PULL=off\n' > "$DOTENV"
run_launcher
printf '# intentionally empty\n' > "$DOTENV"
[ "$RC" -eq 0 ] || fail "case 13: exited $RC: $(cat "$WORK/err")"
assert_launched "case 13"
snapshot_repo "$OPS" dotenv-off-after
assert_repo_unchanged dotenv-off-before dotenv-off-after \
    "case 13: .env said off, so nothing may have been pulled -- the loader has to run first"
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "lite-opus" ] \
    || fail "case 13: the child got '$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)', not the pre-pull 'lite-opus' -- .env said off"

# --- Case 14: every shape of a dirty tree defers the pull --------------------
# Case 3 dirties config.yaml itself, which any implementation notices because it
# is the file the merge would rewrite. These four dirty something else, and
# `git merge --ff-only` succeeds against all of them -- so an implementation
# that asks git whether the merge is possible, rather than asking whether the
# tree is clean, walks straight over the operator's work in progress.
while IFS='|' read -r name dirt; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    dirt="${dirt//[[:space:]]/}"
    new_ops
    publish_upstream pulled-opus
    case "$dirt" in
        *staged*)    printf 'staged but not committed\n' > "$OPS/notes.txt"
                     git -C "$OPS" add notes.txt ;;&
        *modified*)  printf 'edited in place\n' >> "$OPS/README.md" ;;&
        *untracked*) printf 'scratch\n' > "$OPS/scratch.txt" ;;
    esac
    snapshot_repo "$OPS" "dirty-$name-before"
    run_launcher
    [ "$RC" -eq 0 ] || fail "case 14/$name: exited $RC on a dirty tree: $(cat "$WORK/err")"
    assert_launched "case 14/$name"
    snapshot_repo "$OPS" "dirty-$name-after"
    assert_repo_unchanged "dirty-$name-before" "dirty-$name-after" \
        "case 14/$name: work the operator has not committed must outrank a background convenience"
    assert_stderr 'dirty\|uncommitted\|local change' \
        "case 14/$name: skipping the pull silently leaves the host quietly stale"
done <<'TABLE'
staged     | staged
modified   | modified
untracked  | untracked
combined   | staged-modified-untracked
TABLE

# --- Case 15: a second launch against an up-to-date checkout changes nothing -
# The launcher runs on every VS Code start, so the already-current path is the
# one it takes almost every time. An implementation that merges unconditionally,
# or that writes the index to find out whether it needs to, leaves a different
# tree behind on each launch -- which case 14 then reads as dirty, and the host
# stops updating for good.
new_ops
publish_upstream pulled-opus
run_launcher
[ "$RC" -eq 0 ] || fail "case 15: the first run exited $RC: $(cat "$WORK/err")"
snapshot_repo "$OPS" idem-first
FIRST_OPUS="$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
[ "$FIRST_OPUS" = "pulled-opus" ] || fail "case 15: the first run did not pull; the second proves nothing"
run_launcher
[ "$RC" -eq 0 ] || fail "case 15: the second run exited $RC: $(cat "$WORK/err")"
assert_launched "case 15"
snapshot_repo "$OPS" idem-second
assert_repo_unchanged idem-first idem-second \
    "case 15: pulling an already-current checkout must be a no-op"
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" = "$FIRST_OPUS" ] \
    || fail "case 15: the child's opus key changed between two identical launches"

# --- Case 16: the opt-out stops the network call, not just the merge ---------
# Cases 2 and 13 assert that nothing in the repository moved, which a `git
# fetch` on its own satisfies: it writes remote-tracking refs, never HEAD, the
# index or the worktree. But the delay is the whole reason the opt-out exists
# -- an operator on a slow link opts out to get their editor back, not to keep
# a SHA still -- so a launcher that fetches and declines to merge passes both
# earlier cases while costing exactly what they were meant to prevent.
# The stub records every git invocation and blocks on the network verbs, so a
# still-fetching launcher is caught twice over: the log names the call, and
# the elapsed time overruns even the launcher's own fetch deadline.
LOGGING_GIT="$WORK/stub-logging-git"
GIT_CALLS="$WORK/git-calls.log"
mkdir -p "$LOGGING_GIT"
{
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "$GIT_CALLS"
    printf 'for a in "$@"; do\n'
    printf '    case "$a" in\n'
    printf '        fetch|pull|ls-remote) sleep 300; exit 1 ;;\n'
    printf '    esac\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$GIT_BIN_DIR/git"
} > "$LOGGING_GIT/git"
chmod +x "$LOGGING_GIT/git"

NETWORK_VERBS='(^| )(fetch|pull|ls-remote)( |$)'
while IFS='|' read -r name source; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    source="${source//[[:space:]]/}"
    new_ops
    publish_upstream pulled-opus
    : > "$GIT_CALLS"
    SAVED_PATH="$CHILD_PATH"
    CHILD_PATH="$LOGGING_GIT:$STUB:$GIT_BIN_DIR:/usr/bin:/bin"
    if [ "$source" = dotenv ]; then
        printf 'CCGW_AUTO_PULL=off\n' > "$DOTENV"
        run_launcher
        printf '# intentionally empty\n' > "$DOTENV"
    else
        run_launcher CCGW_AUTO_PULL=off
    fi
    CHILD_PATH="$SAVED_PATH"

    [ "$RC" -eq 0 ] || fail "case 16/$name: exited $RC: $(cat "$WORK/err")"
    assert_launched "case 16/$name"
    assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus \
        "case 16/$name: opting out of the pull must still route from the checkout as it stands"
    grep -Eq "$NETWORK_VERBS" "$GIT_CALLS" \
        && fail "case 16/$name: the opt-out still reached the network: $(grep -E "$NETWORK_VERBS" "$GIT_CALLS")"
    [ "$ELAPSED" -lt 15 ] \
        || fail "case 16/$name: took ${ELAPSED}s with the pull opted out; the wait it exists to avoid is still being paid"
done <<'TABLE'
process-env | env
dotenv-file | dotenv
TABLE

# --- Case 17: a failing fetch must not print the remote's credential ---------
# The entrypoint's half of the leak that test-git-remote-lib.sh case 13 covers
# one layer down. An https remote can carry userinfo, and the launcher's whole
# contract on a failed pull is to say so and carry on -- so the failure message
# is exactly where a URL gets echoed, and it lands in the terminal the operator
# is about to share a screenshot of. Nothing here needs the credential to be
# real: the string is a fixed fake, and any appearance of it is the failure.
LEAK_SECRET='n0t-a-real-token-c5b-4f21'

# The sweep below is a negative assertion over a directory that is very often
# empty, which is exactly the shape that passes while testing nothing. Prove it
# fails on a tree that plainly holds the secret before trusting it on the real
# one (same reason as the self-test at the top of this file).
mkdir -p "$WORK/leak-selftest"
printf 'https://ccgw-user:%s@127.0.0.1:9/ops.git\n' "$LEAK_SECRET" > "$WORK/leak-selftest/probe.log"
( assert_no_secret_in_tree "$WORK/leak-selftest" "$LEAK_SECRET" "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_no_secret_in_tree passed a tree that plainly contains the secret; the sweep in case 17 asserts nothing"
rm -rf "$WORK/leak-selftest"

# A temp directory of this case's own, created empty, so every file found in it
# afterwards was written during this run -- by the launcher, or by the git it
# invoked. All three spellings are handed over because the launcher runs on
# macOS and under Git-for-Windows bash, which do not read the same one.
LEAK_TMP="$WORK/leak-tmp"
rm -rf "$LEAK_TMP"
mkdir -p "$LEAK_TMP"
new_ops
publish_upstream pulled-opus
git -C "$OPS" remote set-url origin "https://ccgw-user:$LEAK_SECRET@127.0.0.1:9/ops.git"
BEFORE_LEAK="$(head_sha "$OPS")"
run_launcher TMPDIR="$LEAK_TMP" TEMP="$LEAK_TMP" TMP="$LEAK_TMP"
[ "$RC" -eq 0 ] || fail "case 17: exited $RC after an unreachable remote; the launch must survive it: $(cat "$WORK/err")"
assert_launched "case 17"
[ "$(head_sha "$OPS")" = "$BEFORE_LEAK" ] || fail "case 17: the checkout advanced although the remote is unreachable"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus \
    "case 17: an unreachable remote must still leave the checkout's own tier map delivered"
assert_stderr 'pull\|fetch\|remote\|git' \
    "case 17: the failed pull must be reported -- and that report is the line the credential would ride out on"
case "$(cat "$WORK/out" "$WORK/err")" in
    *"$LEAK_SECRET"*) fail "case 17: the remote's credential reached the terminal: $(cat "$WORK/err")" ;;
esac
assert_no_secret_in_tree "$LEAK_TMP" "$LEAK_SECRET" \
    "case 17: the failed pull spilled the remote's credential into a temp file, which outlives the terminal it was kept out of"

# .git/ is the copy the two sweeps above cannot reach and nobody empties: it is
# handed on with the checkout. It gets the same treatment -- prove the one
# exclusion is actually load-bearing, then prove the sweep reaches past it.
grep -qF -- "$LEAK_SECRET" "$OPS/.git/config" \
    || fail "case 17: .git/config no longer carries the credential, so the sweep's single exclusion is not being exercised"
printf 'https://ccgw-user:%s@127.0.0.1:9/ops.git\n' "$LEAK_SECRET" > "$OPS/.git/ccgw-leak-probe"
( assert_no_secret_in_git_state "$OPS" "$LEAK_SECRET" "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_no_secret_in_git_state passed a .git that plainly contains the secret; the sweep below asserts nothing"
rm -f "$OPS/.git/ccgw-leak-probe"
assert_no_secret_in_git_state "$OPS" "$LEAK_SECRET" \
    "case 17: the failed pull wrote the credential into .git/, which outlives TMPDIR and travels with the checkout"

# --- Case 18: a failing pull must not print the CLIENT credential either -----
# Case 17 covers the credential the launcher read OUT of git. This is the other
# one in the same process: LITELLM_CLIENT_KEY is the LiteLLM master key itself
# (no virtual keys without a database), and it sits in the environment the whole
# time the pull is failing. A launcher that reports that failure by showing its
# own state -- `set -x` left on, an `env` in a diagnostic, a git error report
# that inherits it -- spills the key that opens the gateway, on a path nothing
# else about credentials runs through. The stub refuses the network verbs
# immediately, so the failure is reported rather than waited out.
CLIENT_SECRET='n0t-a-real-client-key-8ae-1d07'
FAILGIT="$WORK/stub-failgit"
mkdir -p "$FAILGIT"
{
    printf '#!/bin/bash\n'
    printf 'for a in "$@"; do\n'
    printf '    case "$a" in\n'
    printf '        fetch|pull|ls-remote)\n'
    printf '            printf "fatal: ccgw-fixture: the remote refused the connection\\n" >&2\n'
    printf '            exit 128 ;;\n'
    printf '    esac\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$GIT_BIN_DIR/git"
} > "$FAILGIT/git"
chmod +x "$FAILGIT/git"

CLIENT_TMP="$WORK/client-leak-tmp"
rm -rf "$CLIENT_TMP"
mkdir -p "$CLIENT_TMP"
new_ops
publish_upstream pulled-opus
SAVED_PATH="$CHILD_PATH"
CHILD_PATH="$FAILGIT:$STUB:$GIT_BIN_DIR:/usr/bin:/bin"
run_launcher LITELLM_CLIENT_KEY="$CLIENT_SECRET" \
    TMPDIR="$CLIENT_TMP" TEMP="$CLIENT_TMP" TMP="$CLIENT_TMP"
CHILD_PATH="$SAVED_PATH"
[ "$RC" -eq 0 ] || fail "case 18: exited $RC after a refused fetch; a pull problem must never cost the operator their client: $(cat "$WORK/err")"
assert_launched "case 18"
assert_env ANTHROPIC_AUTH_TOKEN "$CLIENT_SECRET" \
    "case 18: the credential must still reach the child verbatim; dropping it to stay quiet is not the fix"
assert_stderr 'refused\|pull\|fetch\|git' \
    "case 18: the failed pull must be reported -- and that report is the line the environment would ride out on"
case "$(cat "$WORK/out" "$WORK/err")" in
    *"$CLIENT_SECRET"*) fail "case 18: the gateway credential reached the terminal while a git failure was being reported: $(cat "$WORK/out" "$WORK/err")" ;;
esac
assert_no_secret_in_tree "$CLIENT_TMP" "$CLIENT_SECRET" \
    "case 18: the failed pull spilled the gateway credential into a temp file (the sweep itself is proven by case 17's self-test)"
assert_no_secret_in_git_state "$OPS" "$CLIENT_SECRET" \
    "case 18: the gateway credential was written into the repository's own git state by a failed pull"

# --- Case 19: the fetch lands and the merge is the step that fails -----------
# Every partial-success case so far fails at the same place: the fetch works,
# and the merge is refused because the branches diverged (case 4). That is the
# one the launcher was written against. This is the other half -- the merge
# fails for a reason that has nothing to do with what either side committed, so
# the branches are still fast-forwardable and the operation still is not going
# to happen. A stale .git/index.lock is the everyday way in: an editor's git
# integration crashed, a previous command was killed, a network drive left it
# behind.
new_ops
publish_upstream pulled-opus
snapshot_repo "$OPS" case19-before
cp "$OPS/.git/config" "$WORK/case19.gitconfig"
: > "$OPS/.git/index.lock"

# `git status` reads clean through the lock, so the dirty-tree guard waves the
# run past and the merge is the first step that touches the index -- which is
# what makes this a merge-step case rather than a second copy of case 14.
git -C "$OPS" status --porcelain | grep -q . \
    && fail "case 19: the fixture's own lock made the tree read as dirty, so this case would exercise the dirty-tree guard instead of the merge step"
run_launcher
rm -f "$OPS/.git/index.lock"
[ "$RC" -eq 0 ] \
    || fail "case 19: exited $RC after a merge the launcher could not perform; a pull problem must never cost the operator their client: $(cat "$WORK/err")"
assert_launched "case 19"

# What must not follow is a half-applied pull: the checkout stays exactly where
# it was, the launcher says so, and the client still starts on the local config
# -- which still maps opus to lite-opus, not to the pulled-opus the remote is
# holding. That last assertion is what separates "the merge was refused" from
# "the merge half-succeeded and nobody noticed".
snapshot_repo "$OPS" case19-after
assert_repo_unchanged case19-before case19-after \
    "case 19: the merge could not run, so nothing about the checkout may have moved"
cmp -s "$WORK/case19.gitconfig" "$OPS/.git/config" \
    || fail "case 19: a failed merge rewrote .git/config: $(diff "$WORK/case19.gitconfig" "$OPS/.git/config")"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus \
    "case 19: the tier map must come from the checkout as it stands; taking it from a merge that did not complete is how a host ends up addressing a name only the remote knows"
assert_stderr 'merge\|pull\|lock\|git' \
    "case 19: a pull that silently did nothing leaves the operator believing they are on the published config"

# --- Case 20: what the git subprocess is HANDED, not what it leaves behind ----
# Cases 17 and 18 sweep the places a secret can come to rest -- the terminal,
# TMPDIR, .git/. All three are post-hoc: they see a leak only once something
# wrote it down. The command line is the copy that is never written down and is
# readable by every other user on the box for as long as the call runs (`ps`,
# /proc, an audit log, a shell history if a wrapper is involved), so a `git
# fetch https://user:key@host/ops.git` leaks in full while leaving all three
# sweeps above perfectly clean.
SPYGIT="$WORK/stub-spygit"
SPY_ARGV="$WORK/spy-argv.log"
SPY_ENV="$WORK/spy-env.log"
mkdir -p "$SPYGIT"
{
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "$SPY_ARGV"
    printf 'env >> %s\n' "$SPY_ENV"
    printf 'for a in "$@"; do\n'
    printf '    case "$a" in\n'
    printf '        fetch|pull|ls-remote)\n'
    printf '            printf "fatal: ccgw-fixture: the remote refused the connection\\n" >&2\n'
    printf '            exit 128 ;;\n'
    printf '    esac\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$GIT_BIN_DIR/git"
} > "$SPYGIT/git"
chmod +x "$SPYGIT/git"

# The convention case 18 set: a variable the parent legitimately holds is
# INHERITED by every child it spawns, and that is not the leak. What is: the
# same value under a name nobody set, or on the command line. So each secret is
# swept everywhere except the one variable it is supposed to live in.
assert_argv_clean() { # assert_argv_clean <secret> <context>
    local hits
    hits="$(grep -naF -- "$1" "$SPY_ARGV")"
    [ -z "$hits" ] || fail "$2: the secret was passed to git on the command line, where every other user on the host can read it: $hits"
}

assert_env_clean_except() { # assert_env_clean_except <secret> <allowed-var> <context>
    local hits
    hits="$(grep -aF -- "$1" "$SPY_ENV" | grep -v "^$2=")"
    [ -z "$hits" ] || fail "$3: git's own environment carries the secret under a name other than $2, so something copied it there: $hits"
}

MASTER_SECRET='n0t-a-real-master-key-77c-2b90'
URL_SECRET='n0t-a-real-url-token-31d-6fa4'
SPY_CLIENT_SECRET='n0t-a-real-client-key-40b-9c15'
: > "$SPY_ARGV"
: > "$SPY_ENV"
new_ops
publish_upstream pulled-opus
git -C "$OPS" remote set-url origin "https://ccgw-user:$URL_SECRET@127.0.0.1:9/ops.git"
SAVED_PATH="$CHILD_PATH"
CHILD_PATH="$SPYGIT:$STUB:$GIT_BIN_DIR:/usr/bin:/bin"
run_launcher LITELLM_CLIENT_KEY="$SPY_CLIENT_SECRET" LITELLM_MASTER_KEY="$MASTER_SECRET"
CHILD_PATH="$SAVED_PATH"
[ "$RC" -eq 0 ] || fail "case 20: exited $RC after a refused fetch: $(cat "$WORK/err")"
assert_launched "case 20"

# Both logs are negative assertions over files the launcher may simply never
# have written -- the shape that passes while testing nothing. So: prove the
# spy ran at all, then prove each sweep fails on a line that plainly carries
# the secret, before believing the quiet answer on the real logs.
[ -s "$SPY_ARGV" ] || fail "case 20: the spy git was never invoked, so neither sweep below is asserting anything"
[ -s "$SPY_ENV" ] || fail "case 20: the spy git recorded no environment, so the env sweep below is asserting nothing"
printf 'fetch https://ccgw-user:%s@127.0.0.1:9/ops.git\n' "$URL_SECRET" >> "$SPY_ARGV"
( assert_argv_clean "$URL_SECRET" "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_argv_clean passed a log that plainly carries the secret"
printf 'SOME_COPIED_NAME=%s\n' "$MASTER_SECRET" >> "$SPY_ENV"
( assert_env_clean_except "$MASTER_SECRET" LITELLM_MASTER_KEY "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_env_clean_except passed an env carrying the secret under a name nobody set"
grep -v "^SOME_COPIED_NAME=" "$SPY_ENV" > "$SPY_ENV.clean" && mv "$SPY_ENV.clean" "$SPY_ENV"
grep -v '^fetch https://ccgw-user:' "$SPY_ARGV" > "$SPY_ARGV.clean" && mv "$SPY_ARGV.clean" "$SPY_ARGV"

assert_argv_clean "$URL_SECRET" \
    "case 20: the remote's credential was spelled out in git's argv; .git/config already holds it, so nothing needs to put it there"
assert_argv_clean "$MASTER_SECRET" \
    "case 20: the gateway's master key reached a git command line, which is the one place no sweep can clean up after"
assert_argv_clean "$SPY_CLIENT_SECRET" \
    "case 20: the client key reached a git command line"
assert_env_clean_except "$MASTER_SECRET" LITELLM_MASTER_KEY \
    "case 20: inheriting LITELLM_MASTER_KEY is expected; a second copy of it under another name is not"
assert_env_clean_except "$SPY_CLIENT_SECRET" LITELLM_CLIENT_KEY \
    "case 20: inheriting LITELLM_CLIENT_KEY is expected; a second copy of it under another name is not"
assert_env_clean_except "$URL_SECRET" NO_SUCH_VARIABLE \
    "case 20: the remote URL's credential appeared in git's environment, which no variable here is supposed to hold"

echo "PASS: test-code-ccgw-auto-pull-2"
