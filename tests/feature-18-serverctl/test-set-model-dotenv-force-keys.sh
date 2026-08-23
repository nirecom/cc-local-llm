#!/usr/bin/env bash
# Tests: scripts/set-model.sh, scripts/lib/load-dotenv.sh
# Tags: scope:issue-specific, layer:TL2, set-model, dotenv, load-dotenv, regression
# Scenario (issue #68): load-dotenv.sh's _dotenv_force_key() dereferences
# $DOTENV_FORCE_KEYS unconditionally, so every scripts/ entrypoint sourcing the
# loader under `set -eu` aborted with "DOTENV_FORCE_KEYS: unbound variable" on
# the first KEY=VALUE line of .env -- DOTENV_FORCE_KEYS being a NON-exported
# opt-in most callers never set. Reported symptom: `./scripts/set-model --list`,
# a read-only command, crashing before it printed anything.
set -u

# --list is the cheapest entry point that reaches the crash site: loader plus
# two config.yaml reads for display -- no backend, no daemon, no writes. The
# daemon launchers (litellm.sh, llama-swap.sh, ds4-server.sh, ccgw-proxy.sh)
# share the crash but are deliberately not executed here. Run as `sh "$SCRIPT"`
# to match the #!/bin/sh shebang, so the fatal `set -eu` is the real one.

# TL3 gap: whether litellm-server actually restarts and re-resolves the new
#   os.environ/LITELLM_<TIER>_MODEL after a real `set-model <tier> <key>` write.
#   Only a real host answers that; --list is read-only by design and this file
#   stays side-effect-free. Covered by docs/ops.md at user_verification.

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SCRIPT="$REPO/scripts/set-model.sh"
LOADER="$REPO/scripts/lib/load-dotenv.sh"

# Skips until the scripts/set-model -> scripts/set-model.sh rename lands.
[ -f "$SCRIPT" ] || { echo "SKIP: $SCRIPT not found (implementation pending)"; exit 77; }
[ -f "$LOADER" ] || { echo "SKIP: $LOADER not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

# Pin DOTENV_FILE into this test's tmpdir so the real repo .env is never read
# (its secrets must not enter this process, and its key set must not decide the
# verdict). At least one KEY=VALUE line is required: the crash site lives in the
# loader's per-line loop, so an empty fixture makes every case vacuous -- case 0
# asserts that line is genuinely consumed.
export DOTENV_FILE="$WORK/dotenv"
cat > "$DOTENV_FILE" <<'EOF'
CCGW_DOTENV_PROBE=probe-value
LITELLM_HAIKU_MODEL=fixture-haiku
LITELLM_SONNET_MODEL=fixture-sonnet
LITELLM_FABLE_MODEL=fixture-fable
LITELLM_OPUS_MODEL=fixture-opus
EOF

# Fixture ops root: paths.sh derives LLAMA_SWAP_ROOT/LITELLM_ROOT from
# CCGW_OPS_ROOT, so seeding one tmpdir pins both configs --list reads.
FIXTURE_ROOT="$WORK/ops"
mkdir -p "$FIXTURE_ROOT/llama-swap" "$FIXTURE_ROOT/litellm-server"
cat > "$FIXTURE_ROOT/litellm-server/config.yaml" <<'EOF'
model_list:
  - model_name: os.environ/LITELLM_HAIKU_MODEL
    litellm_params:
      model: openai/fixture-haiku-backend
  - model_name: os.environ/LITELLM_SONNET_MODEL
    litellm_params:
      model: openai/fixture-sonnet-backend
  - model_name: os.environ/LITELLM_FABLE_MODEL
    litellm_params:
      model: anthropic/fixture-fable-backend
  - model_name: os.environ/LITELLM_OPUS_MODEL
    litellm_params:
      model: openai/fixture-opus-backend
EOF
cat > "$FIXTURE_ROOT/llama-swap/config.yaml" <<'EOF'
healthCheckTimeout: 600
models:
  fixture-model-a:
    cmd: mlx_lm.server --host 127.0.0.1
    proxy: http://127.0.0.1:8080
  fixture-model-b:
    cmd: ds4-server --host 127.0.0.1
    proxy: http://127.0.0.1:8081
EOF

assert_no_unbound() { # assert_no_unbound <label> <status> <stderr-file>
    if grep -q 'unbound variable' "$3"; then
        fail "$1: crashed on an unbound variable (issue #68 regression):
$(cat "$3")"
    fi
    [ "$2" -eq 0 ] || fail "$1: exited $2 (expected 0). stderr:
$(cat "$3")"
}

# --- Case 0: the fixture .env line really reaches the loader's loop ---------
# False-green guard for every case below: proves the per-line loop (where
# _dotenv_force_key is called) executes with DOTENV_FORCE_KEYS unset under
# `set -eu`, rather than being skipped over an empty fixture.
PROBE="$(env -u DOTENV_FORCE_KEYS HOME="$HOME" DOTENV_FILE="$DOTENV_FILE" \
    CCGW_SCRIPT_DIR="$REPO/scripts" \
    sh -c 'set -eu
           . "$CCGW_SCRIPT_DIR/lib/root.sh"
           . "$CCGW_SCRIPT_DIR/lib/load-dotenv.sh"
           printenv CCGW_DOTENV_PROBE' 2>"$WORK/probe.err")" || PROBE=""
assert_no_unbound "case 0 (loader sourced, DOTENV_FORCE_KEYS unset)" 0 "$WORK/probe.err"
[ "$PROBE" = "probe-value" ] || fail "case 0: loader did not export CCGW_DOTENV_PROBE from the fixture .env (got '$PROBE') -- the crash site is never reached, so every case below would be vacuous"

# --- Case 1: `set-model.sh --list` with DOTENV_FORCE_KEYS unset -------------
# The exact originally-reported crash, post-rename. `env -u` pins the branch
# explicitly so an ambient DOTENV_FORCE_KEYS cannot mask the regression.
OUT="$(env -u DOTENV_FORCE_KEYS CCGW_OPS_ROOT="$FIXTURE_ROOT" \
    sh "$SCRIPT" --list 2>"$WORK/err")" && STATUS=0 || STATUS=$?
assert_no_unbound "case 1 (--list, DOTENV_FORCE_KEYS unset)" "$STATUS" "$WORK/err"
for TIER in haiku sonnet fable opus; do
    echo "$OUT" | grep -q "^$TIER " || fail "case 1: --list printed no '$TIER' line:
$OUT"
done
# Assert the fixture's own values, so the case fails if --list silently stops
# reading the configs instead of merely not crashing.
echo "$OUT" | grep -q 'fixture-opus-backend' || fail "case 1: --list did not report the fixture opus backend:
$OUT"
echo "$OUT" | grep -q 'fixture-model-a' || fail "case 1: --list did not enumerate the fixture llama-swap model keys:
$OUT"

# --- Case 2: same command with DOTENV_FORCE_KEYS SET ------------------------
# Symmetric branch (CPR-ORTH): the opt-in _dotenv_force_key exists for must keep
# working, so case 1 cannot be satisfied by deleting the feature.
OUT="$(env CCGW_OPS_ROOT="$FIXTURE_ROOT" DOTENV_FORCE_KEYS='LITELLM_OPUS_MODEL LITELLM_FABLE_MODEL' \
    sh "$SCRIPT" --list 2>"$WORK/err")" && STATUS=0 || STATUS=$?
assert_no_unbound "case 2 (--list, DOTENV_FORCE_KEYS set)" "$STATUS" "$WORK/err"
echo "$OUT" | grep -q 'fixture-opus-backend' || fail "case 2: --list did not report the fixture opus backend:
$OUT"

# --- Case 3: DOTENV_FORCE_KEYS set but empty --------------------------------
# Edge case between the two branches above -- what a caller that builds the list
# conditionally leaves behind. Must read as "no forced keys": no crash, and no
# forcing of everything.
OUT="$(env CCGW_OPS_ROOT="$FIXTURE_ROOT" DOTENV_FORCE_KEYS='' \
    sh "$SCRIPT" --list 2>"$WORK/err")" && STATUS=0 || STATUS=$?
assert_no_unbound "case 3 (--list, DOTENV_FORCE_KEYS empty)" "$STATUS" "$WORK/err"
echo "$OUT" | grep -q 'fixture-opus-backend' || fail "case 3: --list did not report the fixture opus backend:
$OUT"

# --- Case 4: single-tier `--list <tier>` ------------------------------------
# The other --list arm; also a negative control on case 1's per-tier assertion,
# which would pass against an implementation that always prints all four.
OUT="$(env -u DOTENV_FORCE_KEYS CCGW_OPS_ROOT="$FIXTURE_ROOT" \
    sh "$SCRIPT" --list opus 2>"$WORK/err")" && STATUS=0 || STATUS=$?
assert_no_unbound "case 4 (--list opus)" "$STATUS" "$WORK/err"
echo "$OUT" | grep -q '^opus ' || fail "case 4: --list opus printed no 'opus' line:
$OUT"
echo "$OUT" | grep -q '^haiku ' && fail "case 4: --list opus also printed a 'haiku' line (the single-tier form must show one tier):
$OUT"

# --- Case 5: the real repo configs, as the issue reporter ran it ------------
# Read-only: CCGW_OPS_ROOT is left to paths.sh's own derivation so --list parses
# the shipped configs, while DOTENV_FILE stays pinned to the fixture (the real
# .env, and its secrets, are never read). Catches a crash only the real config
# content would trigger.
OUT="$(env -u DOTENV_FORCE_KEYS sh "$SCRIPT" --list 2>"$WORK/err")" && STATUS=0 || STATUS=$?
assert_no_unbound "case 5 (--list against the shipped configs)" "$STATUS" "$WORK/err"
for TIER in haiku sonnet fable opus; do
    echo "$OUT" | grep -q "^$TIER " || fail "case 5: --list printed no '$TIER' line:
$OUT"
done

echo "PASS: test-set-model-dotenv-force-keys"
