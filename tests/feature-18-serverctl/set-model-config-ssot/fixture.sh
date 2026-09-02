#!/usr/bin/env bash
# Tests: scripts/set-model.sh, scripts/lib/git-remote.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, set-model, config, ssot, publish, fixture
#
# Not a suite: sourced by test-set-model-config-ssot.sh and its `-2` sibling,
# which together exceeded the 500-line hard limit of rules/coding/file-split.md.
# Everything both need to stand up an ops root -- the two config shapes, the
# llama-swap lineup, the git repository and its optional bare remote, the stub
# restart -- lives here exactly once (CPR-SSOT). Sourcing it also arms the skip
# gate and the temp-directory cleanup for the caller.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SRC_SCRIPTS="$REPO/scripts"

[ -f "$SRC_SCRIPTS/set-model.sh" ] || { echo "SKIP: scripts/set-model.sh not found"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Neither the developer's git identity, hooks and credential helpers nor their
# launchd agents may reach these cases: HOME is pinned per fixture below, so
# lib/launchd.sh finds no plist and the restart goes through the stub
# serverctl.sh (rules/test/fixture-isolation.md). Run from the temp tree, never
# from the worktree: a `git` call walking up from the CWD would find this
# checkout.
export GIT_CONFIG_GLOBAL="$WORK/gitconfig-global"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export XDG_CONFIG_HOME="$WORK/xdg"
mkdir -p "$XDG_CONFIG_HOME" "$WORK/tmp"
: > "$GIT_CONFIG_GLOBAL"
cd "$WORK" || fail "setup: cannot enter $WORK"

# --- fixture material: two provider shapes on purpose, so that the same-shape
# swap can be allowed and the cross-shape one refused (case 5) ----------------
write_llamaswap() { # write_llamaswap <path>
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
models:
  win-sonnet-key:
    cmd: mlx_lm.server --model win-sonnet
  deepseek-v4-flash:
    cmd: ds4-server --model ds4
  ds4-alt:
    cmd: ds4-server --model ds4-alt
  qwen3.8-flash-next-3bit-mtp:
    cmd: mlx_lm.server --model mtp
  qwen3.8-next-80b-4bit:
    cmd: mlx_lm.server --model 80b

healthCheckTimeout: 300
EOF
}

# The two-space `# --- ... ---` separators are the real file's shape, and are
# what lets a misplaced annotation land inside the previous route's block
# rather than failing loudly (case 7). `commentform` is the Format-F fallback,
# for the operator whose strict YAML validator rejects an unknown key inside
# litellm_params: a comment on the line immediately after the block start, its
# tiers separated by whitespace. It is written in F throughout on purpose --
# the two forms are never mixed in one file (detail.md S1), and a variant that
# mixed them would be asserting the opposite of the contract every reader of
# this file has to implement.
write_config() { # write_config <path> <variant> -- see the case list below
    # dupname, mixedforms and doubleannot are files already malformed BEFORE
    # the run: each breaks one S2 schema rule and nothing else, so a refusal is
    # attributable to the rule it names rather than to whatever else a broken
    # file also happens to be.
    #
    # envleftover, missingname and quotedname break the OTHER half of the same
    # schema -- what a `model_name` value may be (detail.md:191: a bare literal,
    # no `os.environ/`, no quotes) -- and they break it on a route this run is
    # not switching, which is the half a writer that only validates its own
    # target never looks at.
    mkdir -p "$(dirname "$1")"
    case "$2" in
        default)
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      api_base: os.environ/LITELLM_LLAMASWAP_URL
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier: the ds4-server backend ---
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
            ;;
        reordered)
            cat > "$1" <<'EOF'
model_list:
  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      api_base: os.environ/LITELLM_CCGW_PROXY_OPENAI_URL
      ccgw_tiers: [opus, subagent]

  # --- Haiku and sonnet tiers ---
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

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        broken)
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Opus tier: annotation written ABOVE the item, as a heading would be ---
  ccgw_tiers: [opus, subagent]
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        commentform)
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    # ccgw-tiers: haiku sonnet
    litellm_params:
      model: openai/Qwen3.8-27B
      api_base: os.environ/LITELLM_LLAMASWAP_URL

  # --- Fable tier: the ds4-server backend ---
  - model_name: deepseek-v4-flash
    # ccgw-tiers: fable
    litellm_params:
      model: anthropic/deepseek-v4-flash
      api_base: os.environ/LITELLM_CCGW_PROXY_URL

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    # ccgw-tiers: opus subagent
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      api_base: os.environ/LITELLM_CCGW_PROXY_OPENAI_URL

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        dupname)
            # Two records answering to one routing name. The second carries no
            # annotation, so no tier is claimed twice and the ONLY thing wrong
            # with the file is the name -- which is what set-model.sh rewrites
            # by, and what LiteLLM shuffles between under `simple-shuffle`.
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier: the ds4-server backend ---
  - model_name: deepseek-v4-flash
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- The same routing name a second time, unannotated ---
  - model_name: deepseek-v4-flash
    litellm_params:
      model: anthropic/ds4-alt

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus, subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        mixedforms)
            # One route annotated in both spellings at once, each naming a
            # different tier so that the file still maps the whole vocabulary
            # exactly once: what is wrong here is the mixing itself, not a tier
            # left unowned or owned twice.
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    # ccgw-tiers: haiku
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [sonnet]

  # --- Fable tier: the ds4-server backend ---
  - model_name: deepseek-v4-flash
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus, subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        doubleannot)
            # One route, two annotation lines of the SAME form. Split across
            # them the tier map still reads as complete, so a reader that takes
            # the first line and a reader that takes the last both find an
            # answer -- and they find different ones.
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier: the ds4-server backend ---
  - model_name: deepseek-v4-flash
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier, annotated twice ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus]
      ccgw_tiers: [subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        envleftover)
            # The fable route's routing name is still delegated to an environment
            # variable -- the anti-pattern this issue removes.
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier: the routing name never migrated off the environment ---
  - model_name: os.environ/LITELLM_FABLE_MODEL
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus, subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        missingname)
            # The key is present and its value is not. A route with no routing
            # name answers to nothing, so the tier annotated on it is mapped to
            # a record no client can ever reach.
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier: the routing name was deleted, the key left behind ---
  - model_name:
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus, subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        quotedname)
            # A quoted value reads as the same string to a YAML parser and as a
            # different one to every line-oriented reader in this repo, so the
            # contract forbids the quotes rather than teaching four readers to
            # strip them.
            cat > "$1" <<'EOF'
model_list:
  # --- Haiku and sonnet tiers: the shared llama-swap backend ---
  - model_name: win-sonnet-key
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Fable tier: the routing name arrived quoted from an editor ---
  - model_name: "deepseek-v4-flash"
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier, shared with the subagent route ---
  - model_name: qwen3.8-flash-next-3bit-mtp
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus, subagent]

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
            ;;
        *) fail "write_config: unknown variant '$2'" ;;
    esac
}

# A stub restart that records it ran, so refusals can prove it did NOT. The log
# path is embedded SINGLE-quoted: an ops root whose own path contains a `$(...)`
# -- the point of case 27 -- would otherwise be expanded by the stub's own
# shell, and the case would report an injection the fixture, not the product,
# committed. Also called after a case moves a fixture, since the path is baked
# in at write time.
write_restart_stub() { # write_restart_stub <fixture-root>
    printf '#!/bin/sh\nLOG=%s\nprintf "%%s\\n" "$*" >> "$LOG"\n' "'$1/restart.log'" \
        > "$1/scripts/serverctl.sh"
    chmod +x "$1/scripts/serverctl.sh"
}

FIXN=0
FIX=""
BARE=""
# new_fixture <variant> [--remote] -- a self-contained ops root that is also a
# git repository; leaves its path in $FIX (and the bare remote in $BARE).
new_fixture() {
    local variant="$1"; shift
    FIXN=$(( FIXN + 1 ))
    FIX="$WORK/fix$FIXN"
    BARE=""
    mkdir -p "$FIX/home"
    cp -R "$SRC_SCRIPTS" "$FIX/scripts"
    write_restart_stub "$FIX"
    write_config "$FIX/litellm-server/config.yaml" "$variant"
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
    if [ "${1:-}" = "--remote" ]; then
        BARE="$WORK/bare$FIXN.git"
        git init --quiet --bare --initial-branch=main "$BARE" >/dev/null 2>&1 \
            || fail "fixture: bare init failed"
        git -C "$FIX" remote add origin "$BARE"
        git -C "$FIX" push --quiet -u origin main >/dev/null 2>&1 \
            || fail "fixture: seeding the bare remote failed"
    fi
}

RC=0
# PATH_PREFIX shadows a binary for the CHILD only: a case that needs `git push`
# to fail sets it and clears it again, so the fixture's own git calls -- which
# build the repository the case then asserts about -- keep using the real one.
PATH_PREFIX=""
REAL_GIT="$(command -v git)" || fail "setup: git is not on PATH"
run_set_model() { # run_set_model <fixture> <args...>
    local fix="$1"; shift
    ( cd "$fix" && env PATH="$PATH_PREFIX$PATH" HOME="$fix/home" TMPDIR="$WORK/tmp" \
        CCGW_OPS_ROOT="$fix" DOTENV_FILE="$fix/.env" \
        GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 \
        sh "$fix/scripts/set-model.sh" "$@" ) >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

out_err() { cat "$WORK/out" "$WORK/err"; }
cfg() { cat "$1/litellm-server/config.yaml"; }
commits() { git -C "$1" rev-list --count HEAD; }
remote_sha() { git -C "$1" rev-parse --verify --quiet "$2" 2>/dev/null || echo MISSING; }
restarted() { [ -f "$1/restart.log" ]; }
