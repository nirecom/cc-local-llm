#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, scripts/lib/git-remote.sh
# Tags: scope:issue-specific, layer:TL2, client-launcher, auto-pull, git, precedence
#
# Third continuation of test-code-ccgw-auto-pull.sh (rules/coding/file-split.md);
# shared fixture in code-ccgw-auto-pull/fixture.sh, case numbering continues
# from 20. Subject: the two questions the earlier files leave open because every
# case there sets at most one of the switch's two sources, and every case there
# runs against a tree that IS a checkout.
# TL3 gap: as in the sibling suites -- a real remote and the operator's own git
# config. Mitigated by the docs/ops.md cutover run at USER_VERIFIED.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/code-ccgw-auto-pull/fixture.sh"

# --- Shared spy git ----------------------------------------------------------
# Both cases below turn on whether a network verb ran at all, so the stub logs
# every invocation and then hands the call to the real git. Passing through
# rather than blocking is what lets the same stub serve the "must fetch" row: a
# blocking stub could only ever prove the negative half.
SPYGIT="$WORK/stub-passthrough-git"
GIT_CALLS="$WORK/git-calls.log"
mkdir -p "$SPYGIT"
{
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "$GIT_CALLS"
    printf 'exec %s "$@"\n' "$GIT_BIN_DIR/git"
} > "$SPYGIT/git"
chmod +x "$SPYGIT/git"

NETWORK_VERBS='(^| )(fetch|pull|ls-remote)( |$)'
SPY_PATH="$SPYGIT:$STUB:$GIT_BIN_DIR:/usr/bin:/bin"

assert_fetched() { # assert_fetched <context>
    grep -Eq "$NETWORK_VERBS" "$GIT_CALLS" \
        || fail "$1: no network verb reached git at all: $(cat "$GIT_CALLS")"
}

assert_not_fetched() { # assert_not_fetched <context>
    grep -Eq "$NETWORK_VERBS" "$GIT_CALLS" \
        && fail "$1: the launcher reached the network: $(grep -E "$NETWORK_VERBS" "$GIT_CALLS")"
    return 0
}

# Both helpers read a log the launcher may simply never have written -- the
# shape that passes while testing nothing. Prove each direction against a
# hand-written log before trusting either on a real run.
: > "$GIT_CALLS"
( assert_fetched "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_fetched passed an empty log; every 'must fetch' row below asserts nothing"
printf 'fetch origin refs/heads/main\n' > "$GIT_CALLS"
( assert_not_fetched "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_not_fetched passed a log that plainly names a fetch; every 'must not fetch' row below asserts nothing"
assert_fetched "harness self-test: a log naming a fetch must satisfy assert_fetched"

# --- Case 21: shell and .env disagree, and the shell decides -----------------
# Every earlier case sets exactly one of the two sources and leaves the other
# absent, which cannot tell "the shell wins" apart from "whichever one is set
# wins". The conflict is the operator's own escape hatch: CCGW_AUTO_PULL=off in
# front of one launch is how someone on a slow link gets their editor back
# without editing a tracked-adjacent file, and it only works if the resolved
# value -- not a second read of .env -- is what the pull branch consults
# (detail.md:258, the ordinary non-routing rule: the shell's value wins).
while IFS='|' read -r name shellv dotenvv expect; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    shellv="${shellv//[[:space:]]/}"
    dotenvv="${dotenvv//[[:space:]]/}"
    expect="${expect//[[:space:]]/}"
    new_ops
    publish_upstream pulled-opus
    : > "$GIT_CALLS"
    printf 'CCGW_AUTO_PULL=%s\n' "$dotenvv" > "$DOTENV"
    SAVED_PATH="$CHILD_PATH"
    CHILD_PATH="$SPY_PATH"
    run_launcher CCGW_AUTO_PULL="$shellv"
    CHILD_PATH="$SAVED_PATH"
    printf '# intentionally empty\n' > "$DOTENV"

    [ "$RC" -eq 0 ] || fail "case 21/$name: exited $RC: $(cat "$WORK/err")"
    assert_launched "case 21/$name"
    if [ "$expect" = fetch ]; then
        assert_fetched "case 21/$name: shell said on and .env said off, so the shell's on must reach the network"
        assert_env ANTHROPIC_DEFAULT_OPUS_MODEL pulled-opus \
            "case 21/$name: the shell turned the pull on, so the published lineup must be the one delivered"
    else
        assert_not_fetched "case 21/$name: shell said off and .env said on; re-reading .env here spends the wait the operator opted out of"
        assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus \
            "case 21/$name: opting out must still route from the checkout as it stands"
        [ "$ELAPSED" -lt 15 ] \
            || fail "case 21/$name: took ${ELAPSED}s with the pull opted out in the shell"
    fi
done <<'TABLE'
shell-off-beats-dotenv-on | off | on  | no-fetch
shell-on-beats-dotenv-off | on  | off | fetch
TABLE

# --- Case 22: a config tree that was never a checkout ------------------------
# Distinct from "no upstream" and "detached HEAD", which both presuppose a .git.
# Here there is none -- an operator copied litellm-server/ out of the repo, or
# unpacked a release tarball. The hazard is that `git rev-parse
# --is-inside-work-tree` (detail.md:265) WALKS UP: with the tree sitting inside
# some unrelated repository, the precondition reads as satisfied and a naive
# launcher fetches and fast-forwards a repo that has nothing to do with the
# gateway. So the ancestor here is a real repository with a real upstream
# holding a different lineup -- everything a wrong fetch would need to succeed.
ANCESTOR="$WORK/ancestor-repo"
ANCESTOR_BARE="$WORK/ancestor-bare.git"
NESTED="$ANCESTOR/vendor/ccgw-ops"
git init --quiet --bare --initial-branch=main "$ANCESTOR_BARE" >/dev/null 2>&1 \
    || fail "case 22: ancestor bare init failed"
git init --quiet --initial-branch=main "$ANCESTOR" >/dev/null 2>&1 \
    || fail "case 22: ancestor init failed"
identify "$ANCESTOR"
printf 'an unrelated repository that merely contains the directory\n' > "$ANCESTOR/README.md"
git -C "$ANCESTOR" add -A
git -C "$ANCESTOR" commit --quiet -m 'ancestor seed'
git -C "$ANCESTOR" remote add origin "$ANCESTOR_BARE"
git -C "$ANCESTOR" push --quiet -u origin main >/dev/null 2>&1 \
    || fail "case 22: seeding the ancestor remote failed"

# A commit the ancestor's upstream has and the ancestor does not, carrying a
# lineup that is visibly not the local one. If the launcher fast-forwards the
# ancestor, the tier assertions below name the key it would have picked up.
ANCESTOR_UP="$WORK/ancestor-upstream"
git clone --quiet "$ANCESTOR_BARE" "$ANCESTOR_UP" >/dev/null 2>&1 \
    || fail "case 22: ancestor upstream clone failed"
identify "$ANCESTOR_UP"
mkdir -p "$ANCESTOR_UP/vendor/ccgw-ops/litellm-server"
config_body wrong-repo-opus > "$ANCESTOR_UP/vendor/ccgw-ops/litellm-server/config.yaml"
git -C "$ANCESTOR_UP" add -A
git -C "$ANCESTOR_UP" commit --quiet -m 'the ancestor upstream carries a different lineup'
git -C "$ANCESTOR_UP" push --quiet origin main >/dev/null 2>&1 \
    || fail "case 22: ancestor upstream push failed"

mkdir -p "$NESTED/litellm-server"
config_body lite-opus > "$NESTED/litellm-server/config.yaml"
cp "$NESTED/litellm-server/config.yaml" "$WORK/case22.config.expected"
[ ! -e "$NESTED/.git" ] || fail "case 22: the fixture tree has a .git of its own, so it is not the case this asserts"

# The precondition really does walk up here -- otherwise the branch under test
# is never entered and the case passes for the wrong reason.
git -C "$NESTED" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "case 22: git does not see $NESTED as inside a work tree, so the walk-up hazard this case exists for is not present"

ANCESTOR_HEAD_BEFORE="$(head_sha "$ANCESTOR")"
: > "$GIT_CALLS"
OPS="$NESTED"
SAVED_PATH="$CHILD_PATH"
CHILD_PATH="$SPY_PATH"
run_launcher
CHILD_PATH="$SAVED_PATH"

[ "$RC" -eq 0 ] \
    || fail "case 22: exited $RC on a tree that is not a checkout; a missing .git is a reason to skip the pull, never to withhold the editor: $(cat "$WORK/err")"
assert_launched "case 22"
assert_stderr 'git\|checkout\|repositor\|update' \
    "case 22: skipping the update silently leaves the operator believing they are current"
assert_not_fetched "case 22: the tree is not a checkout, so there is no upstream of ITS OWN to reach -- anything fetched here belongs to a repository that merely contains it"
[ "$(head_sha "$ANCESTOR")" = "$ANCESTOR_HEAD_BEFORE" ] \
    || fail "case 22: the surrounding repository was fast-forwarded; the launcher moved a checkout that is not the gateway's"
cmp -s "$WORK/case22.config.expected" "$NESTED/litellm-server/config.yaml" \
    || fail "case 22: config.yaml is no longer the file that was written: $(diff "$WORK/case22.config.expected" "$NESTED/litellm-server/config.yaml")"

# And the whole point of continuing: the local file still drives all five tiers.
assert_env ANTHROPIC_DEFAULT_HAIKU_MODEL lite-shared "case 22: haiku from the local file"
assert_env ANTHROPIC_DEFAULT_SONNET_MODEL lite-shared "case 22: sonnet from the local file"
assert_env ANTHROPIC_DEFAULT_FABLE_MODEL lite-fable "case 22: fable from the local file"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "case 22: opus from the local file"
assert_env CLAUDE_CODE_SUBAGENT_MODEL lite-shared "case 22: subagent from the local file"

echo "PASS: test-code-ccgw-auto-pull-3"
