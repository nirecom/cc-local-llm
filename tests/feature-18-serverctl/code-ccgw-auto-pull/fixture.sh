#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, scripts/lib/git-remote.sh
# Tags: scope:issue-specific, layer:TL2, client-launcher, auto-pull, git, fixture
#
# Not a suite: sourced by test-code-ccgw-auto-pull.sh and its `-2` sibling,
# which together exceeded the 500-line hard limit of rules/coding/file-split.md.
# Everything both need to build a repository and run the launcher against it
# lives here exactly once (CPR-SSOT) -- the seeded bare remote, the clone that
# tracks it, the stub PATH, and the four-way "nothing moved" snapshot. Sourcing
# it also arms the skip gate and the temp-directory cleanup for the caller.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LAUNCHER="$REPO/scripts/code-ccgw.sh"

[ -f "$LAUNCHER" ] || { echo "SKIP: $LAUNCHER not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Neither the developer's git identity, hooks nor credential helpers may reach
# these cases, and no case may prompt for a password
# (rules/test/fixture-isolation.md).
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/xdg"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig-global"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
: > "$GIT_CONFIG_GLOBAL"
cd "$WORK" || fail "setup: cannot enter $WORK"

DUMP="$WORK/env.dump"
ARGV="$WORK/argv.dump"
DOTENV="$WORK/dotenv"
printf '# intentionally empty\n' > "$DOTENV"

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

# The child gets a real git for the ordinary cases; the hang cases prepend a
# stub directory that shadows it.
GIT_BIN_DIR="$(dirname "$(command -v git)")"
CHILD_PATH="$STUB:$GIT_BIN_DIR:/usr/bin:/bin"

# Each case gets its own clone of a freshly seeded bare remote, so nothing one
# case pushes or dirties can decide what the next one observes.
config_body() { # config_body <opus-key>
    printf 'model_list:\n'
    printf '  # --- Haiku, sonnet and the subagent route ---\n'
    printf '  - model_name: lite-shared\n'
    printf '    litellm_params:\n'
    printf '      model: openai/Qwen3.8-27B\n'
    printf '      ccgw_tiers: [haiku, sonnet, subagent]\n\n'
    printf '  # --- Fable tier ---\n'
    printf '  - model_name: lite-fable\n'
    printf '    litellm_params:\n'
    printf '      model: anthropic/deepseek-v4-flash\n'
    printf '      ccgw_tiers: [fable]\n\n'
    printf '  # --- Opus tier ---\n'
    printf '  - model_name: %s\n' "$1"
    printf '    litellm_params:\n'
    printf '      model: openai/%s\n' "$1"
    printf '      ccgw_tiers: [opus]\n'
}

identify() { # identify <repo> -- fixture-local identity, hooks disabled
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config user.email 'fixture@example.com'
    git -C "$1" config user.name 'Fixture'
    git -C "$1" config commit.gpgsign false
}

N=0
OPS=""
BARE=""
new_ops() { # new_ops -- a clone tracking a seeded bare remote, in $OPS/$BARE
    N=$(( N + 1 ))
    BARE="$WORK/bare$N.git"
    OPS="$WORK/ops$N"
    local seed="$WORK/seed$N"
    git init --quiet --bare --initial-branch=main "$BARE" >/dev/null 2>&1 \
        || fail "fixture: bare init failed"
    git init --quiet --initial-branch=main "$seed" >/dev/null 2>&1 \
        || fail "fixture: seed init failed"
    identify "$seed"
    mkdir -p "$seed/litellm-server"
    config_body lite-opus > "$seed/litellm-server/config.yaml"
    # A second tracked file the pull never touches, so a dirty-tree case can
    # dirty something OTHER than the file under contention.
    printf 'fixture checkout\n' > "$seed/README.md"
    git -C "$seed" add -A
    git -C "$seed" commit --quiet -m 'seed config'
    git -C "$seed" remote add origin "$BARE"
    git -C "$seed" push --quiet -u origin main >/dev/null 2>&1 \
        || fail "fixture: seeding the bare remote failed"
    git clone --quiet "$BARE" "$OPS" >/dev/null 2>&1 || fail "fixture: clone failed"
    identify "$OPS"
}

publish_upstream() { # publish_upstream <opus-key> -- a commit only the remote has
    local w="$WORK/upstream$N"
    git clone --quiet "$BARE" "$w" >/dev/null 2>&1 || fail "fixture: upstream clone failed"
    identify "$w"
    config_body "$1" > "$w/litellm-server/config.yaml"
    git -C "$w" add -A
    git -C "$w" commit --quiet -m "upstream moves opus to $1"
    git -C "$w" push --quiet origin main >/dev/null 2>&1 || fail "fixture: upstream push failed"
}

RC=0
ELAPSED=0
run_launcher() { # run_launcher [KEY=VAL ...]
    local start end
    rm -f "$DUMP" "$ARGV"
    start="$(date +%s)"
    env -i \
        HOME="$HOME" PATH="$CHILD_PATH" DOTENV_FILE="$DOTENV" \
        GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        CCGW_OPS_ROOT="$OPS" \
        CCGW_TEST_DUMP="$DUMP" CCGW_TEST_ARGV="$ARGV" \
        LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
        "$@" \
        bash "$LAUNCHER" >"$WORK/out" 2>"$WORK/err"
    RC=$?
    end="$(date +%s)"
    ELAPSED=$(( end - start ))
}

dump_get() { grep -m1 "^$1=" "$DUMP" | cut -d= -f2-; }
head_sha() { git -C "$1" rev-parse HEAD; }

# The exact shape used by code-ccgw-config-tiers/fixture.sh and
# test-code-ccgw-posix.sh (CPR-ORTH). Stated here because neither suite sources
# the other: this file was calling assert_env without defining it anywhere, and
# with no `set -e` an undefined function only writes to stderr -- the case went
# on to pass with its central assertion never made. The harness self-test at the
# top of test-code-ccgw-auto-pull-2.sh is what keeps that from recurring.
assert_env() { # assert_env <var> <expected> <context>
    [ -f "$DUMP" ] || fail "$3: stub 'code' was never reached (no env dump); stderr: $(cat "$WORK/err" 2>/dev/null)"
    grep -q "^$1=" "$DUMP" || fail "$3: $1 was not exported at all (expected '$2')"
    local got; got="$(dump_get "$1")"
    [ "$got" = "$2" ] || fail "$3: $1='$got', expected '$2'"
}

# "Nothing moved" needs all four of the things a fetch/merge can move, named
# separately: HEAD alone stays put while `git merge --ff-only` still rewrites
# the index, and the index stays put while a checkout rewrites the file.
snapshot_repo() { # snapshot_repo <repo> <tag>
    git -C "$1" rev-parse HEAD          > "$WORK/$2.head"
    git -C "$1" ls-files --stage        > "$WORK/$2.index"
    git -C "$1" status --porcelain      > "$WORK/$2.status"
    cat "$1/litellm-server/config.yaml" > "$WORK/$2.config"
}

assert_repo_unchanged() { # assert_repo_unchanged <before-tag> <after-tag> <context>
    local k
    for k in head index status config; do
        cmp -s "$WORK/$1.$k" "$WORK/$2.$k" \
            || fail "$3: the repository's $k moved: $(diff "$WORK/$1.$k" "$WORK/$2.$k" | head -5)"
    done
}

assert_launched() { # assert_launched <context>
    [ -f "$DUMP" ] || fail "$1: the launcher never reached 'code'; a pull problem must never cost the operator their client. stderr: $(cat "$WORK/err")"
}

assert_stderr() { # assert_stderr <pattern> <context>
    grep -q "$1" "$WORK/err" || fail "$2: expected stderr to match '$1', got: $(cat "$WORK/err")"
}

# The terminal is only the leak the operator can see. git writes lock files,
# error reports and scratch under TMPDIR, and a launcher that redacts its own
# message while spilling the remote URL into one of those has leaked the
# credential into a file that OUTLIVES the run -- onto a shared box, into a
# backup, or into the next `grep -r` someone runs over /tmp. `-a` because a
# temp file need not be text, and the name is swept as well: git derives
# temp-file names from what it was handed.
assert_no_secret_in_tree() { # assert_no_secret_in_tree <dir> <secret> <context>
    local hits
    hits="$(grep -rlaF -- "$2" "$1" 2>/dev/null)"
    [ -z "$hits" ] || fail "$3: the credential was written into: $hits"
    hits="$(find "$1" -name "*$2*" 2>/dev/null)"
    [ -z "$hits" ] || fail "$3: the credential appears in the NAME of: $hits"
}

# The third copy is the one nobody clears. A failing fetch writes FETCH_HEAD,
# reflogs and its own error reports INSIDE .git/, and a deadline wrapper that
# spools a command line beside the repository leaves it there too. TMPDIR gets
# emptied; .git/ is handed on with the checkout and rides into every archive and
# backup taken of it. `.git/config` is the single exclusion: the URL is in it
# because the operator put it there with `git remote set-url`, so that copy is
# their own record rather than a spill -- which is why the caller is expected to
# prove the secret is still IN it, and to plant a probe elsewhere under .git/,
# before trusting a silent sweep.
git_state_hits() { # git_state_hits <repo> <secret> -- .git files carrying it
    find "$1/.git" -type f ! -name config ! -name 'config.worktree' \
        -exec grep -laF -- "$2" {} + 2>/dev/null
    find "$1/.git" -name "*$2*" 2>/dev/null
}

assert_no_secret_in_git_state() { # assert_no_secret_in_git_state <repo> <secret> <context>
    local hits
    hits="$(git_state_hits "$1" "$2")"
    [ -z "$hits" ] || fail "$3: the credential was written into the repository's own git state: $hits"
}
