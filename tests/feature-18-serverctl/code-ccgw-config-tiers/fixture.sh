#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, client-launcher, config, ssot, fixture
#
# Not a suite: sourced by test-code-ccgw-config-tiers.sh and its `-2` sibling,
# which together exceeded the 500-line hard limit of rules/coding/file-split.md.
# Everything both need lives here exactly once (CPR-SSOT) -- the ops root the
# launcher reads, the `code` stub that dumps what it inherited, the tier -> child
# variable map, the assertions, and the two grammar-probe builders. Sourcing it
# also arms the skip gate and the temp-directory cleanup for the caller.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LAUNCHER="$REPO/scripts/code-ccgw.sh"

[ -f "$LAUNCHER" ] || { echo "SKIP: $LAUNCHER not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

DUMP="$WORK/env.dump"
ARGV="$WORK/argv.dump"
OPS="$WORK/ops"
CONFIG="$OPS/litellm-server/config.yaml"
mkdir -p "$OPS/litellm-server"

# The .env is pinned into this tmpdir so the developer's real one -- which
# still carries the retired routing keys until they migrate -- is never read.
DOTENV="$WORK/dotenv"
printf '# intentionally empty unless a case rewrites it\n' > "$DOTENV"

# `code` is stubbed on PATH and dumps its inherited env, so assertions are made
# against what the launcher actually hands to Claude Code.
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
STUB_PATH="$STUB:/usr/bin:/bin"

set_config() { cat > "$CONFIG"; }   # reads the fixture body from stdin
drop_config() { rm -f "$CONFIG"; }

RC=0
# The child runs under `env -i` with CCGW_AUTO_PULL pinned off: an ambient
# value in the developer's shell can never satisfy an assertion, and no case
# here reaches a git remote (the pull is test-code-ccgw-auto-pull.sh's subject).
run_launcher() { # run_launcher [KEY=VAL ...]
    rm -f "$DUMP" "$ARGV"
    env -i \
        HOME="$HOME" PATH="$STUB_PATH" DOTENV_FILE="$DOTENV" \
        CCGW_OPS_ROOT="$OPS" CCGW_AUTO_PULL=off \
        CCGW_TEST_DUMP="$DUMP" CCGW_TEST_ARGV="$ARGV" \
        LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
        "$@" \
        bash "$LAUNCHER" >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

dump_get() { grep -m1 "^$1=" "$DUMP" | cut -d= -f2-; }

assert_env() { # assert_env <var> <expected> <context>
    [ -f "$DUMP" ] || fail "$3: stub 'code' was never reached (no env dump); stderr: $(cat "$WORK/err")"
    grep -q "^$1=" "$DUMP" || fail "$3: $1 was not exported at all (expected '$2')"
    local got; got="$(dump_get "$1")"
    [ "$got" = "$2" ] || fail "$3: $1='$got', expected '$2'"
}

# The reject half of every grammar row. `dump_get` returns "" both for a name
# that was never exported and for one exported as the empty string, so an
# assertion written against its value cannot tell a refused annotation from a
# tier handed to Claude Code as a model that resolves to nothing -- only the
# presence of the LINE separates them. The dump's own existence is checked
# first: grep over a file the launcher never wrote returns "no match" as well,
# which would let a run that started no child at all satisfy every reject row.
assert_unset() { # assert_unset <var> <context>
    [ -f "$DUMP" ] || fail "$2: stub 'code' was never reached (no env dump); stderr: $(cat "$WORK/err" 2>/dev/null)"
    ! grep -q "^$1=" "$DUMP" || fail "$2: $1 was exported as '$(dump_get "$1")' but must not be set at all"
}

assert_nonempty() { # assert_nonempty <var> <context>
    local got; got="$(dump_get "$1")"
    [ -n "$got" ] || fail "$2: $1 is empty; the tier would resolve to no model at all"
}

assert_stderr() { # assert_stderr <pattern> <context>
    grep -q "$1" "$WORK/err" || fail "$2: expected stderr to match '$1', got: $(cat "$WORK/err")"
}

# Fail-fast rather than the counter form of the shared table-driven template:
# every other case in these two suites aborts on the first fail(), and two exit
# conventions in one script make a red run's status unreadable. The row name
# still reaches every message, which is the property the template is after.
assert_eq() { # assert_eq <name> <want> <got>
    [ "$2" = "$3" ] || fail "$1: want='$2' got='$3'"
}

# The tier -> child-variable map, named once (CPR-SSOT): the cases read it
# rather than repeating five pairs, so a renamed variable fails everywhere.
TIER_ROWS="haiku:ANTHROPIC_DEFAULT_HAIKU_MODEL sonnet:ANTHROPIC_DEFAULT_SONNET_MODEL fable:ANTHROPIC_DEFAULT_FABLE_MODEL opus:ANTHROPIC_DEFAULT_OPUS_MODEL subagent:CLAUDE_CODE_SUBAGENT_MODEL"
var_for() { # var_for <tier>
    local row
    for row in $TIER_ROWS; do
        case "$row" in "$1:"*) printf '%s' "${row#*:}"; return 0 ;; esac
    done
    fail "var_for: no child variable is declared for tier '$1'"
}

# The default fixture. The two-space `# --- ... ---` separators are the real
# file's shape, not decoration: they are what a naive block scanner mistakes
# for the end of a route (case 10).
write_default_config() {
    set_config <<'EOF'
model_list:
  # --- Haiku, sonnet and the subagent route share one backend ---
  - model_name: lite-shared
    litellm_params:
      model: openai/Qwen3.8-27B
      api_base: os.environ/LITELLM_LLAMASWAP_URL
      ccgw_tiers: [haiku, sonnet, subagent]

  # --- Fable tier ---
  - model_name: lite-fable
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier ---
  - model_name: lite-opus
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus]
EOF
}

# The two grammar probes, stated together because they are two spellings of one
# thing: one route claiming opus next to a fixed neighbour claiming haiku, so a
# single run says both "this spelling was (not) adopted" and "a rejected line
# took nothing else down with it". Leading @ = one space in both.
#
# Format P (`^      ccgw_tiers:[ ]*\[([^]]*)\][ ]*$`) may sit anywhere in the
# block, so its probe line goes LAST -- where a hand-edit lands.
grammar_probe() { # grammar_probe <annotation-line>
    local line; line="$(printf '%s' "$1" | tr '@' ' ')"
    {
        printf 'model_list:\n'
        printf '  - model_name: grammar-neighbour\n    litellm_params:\n'
        printf '      model: openai/Backend-N\n      ccgw_tiers: [haiku]\n\n'
        printf '  - model_name: grammar-probe\n    litellm_params:\n'
        printf '      model: openai/Backend-P\n'
        printf '%s\n' "$line"
    } > "$CONFIG"
}

# Format F (`^    # ccgw-tiers:[ ]+(.+)$`) is placement-sensitive: its probe
# line goes on the block's SECOND line, the only place it is read.
grammar_probe_comment() { # grammar_probe_comment <annotation-line>
    local line; line="$(printf '%s' "$1" | tr '@' ' ')"
    {
        printf 'model_list:\n'
        printf '  - model_name: grammar-neighbour\n    litellm_params:\n'
        printf '      model: openai/Backend-N\n      ccgw_tiers: [haiku]\n\n'
        printf '  - model_name: grammar-probe\n'
        printf '%s\n' "$line"
        printf '    litellm_params:\n'
        printf '      model: openai/Backend-P\n'
    } > "$CONFIG"
}
