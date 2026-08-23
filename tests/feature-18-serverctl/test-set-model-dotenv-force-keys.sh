#!/usr/bin/env bash
# Tests: scripts/lib/load-dotenv.sh, scripts/set-model.sh
# Tags: scope:issue-specific, layer:TL2, dotenv, load-dotenv, set-model, regression
# Scenario (issue #68): _dotenv_force_key() dereferenced $DOTENV_FORCE_KEYS
# unconditionally, crashing `set -eu` callers that left the opt-in list unset.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SCRIPT="$REPO/scripts/set-model.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

# One KEY=VALUE line is required: the crash site is the loader's per-line loop.
export DOTENV_FILE="$WORK/dotenv"
printf 'LITELLM_OPUS_MODEL=fixture-opus\n' > "$DOTENV_FILE"

run_loader() { # run_loader <env-args...>
    env "$@" HOME="$HOME" DOTENV_FILE="$DOTENV_FILE" CCGW_SCRIPT_DIR="$REPO/scripts" \
        sh -c 'set -eu
               . "$CCGW_SCRIPT_DIR/lib/root.sh"
               . "$CCGW_SCRIPT_DIR/lib/load-dotenv.sh"
               printenv LITELLM_OPUS_MODEL' 2>"$WORK/err"
}

# --- Case 1: DOTENV_FORCE_KEYS unset (the reported crash) -------------------
OUT="$(run_loader -u DOTENV_FORCE_KEYS)" || OUT=""
grep -q 'unbound variable' "$WORK/err" && fail "case 1: unbound variable regression:
$(cat "$WORK/err")"
[ "$OUT" = "fixture-opus" ] || fail "case 1: .env value not exported (got '$OUT')"

# --- Case 2: set -- keeps case 1 from being satisfied by deleting the feature
OUT="$(run_loader LITELLM_OPUS_MODEL=stale DOTENV_FORCE_KEYS=LITELLM_OPUS_MODEL)" || OUT=""
[ "$OUT" = "fixture-opus" ] || fail "case 2: forced key did not beat the stale shell value (got '$OUT')"

# --- Case 3: set but empty -- what a conditionally-built list leaves behind --
OUT="$(run_loader LITELLM_OPUS_MODEL=stale DOTENV_FORCE_KEYS=)" || OUT=""
grep -q 'unbound variable' "$WORK/err" && fail "case 3: unbound variable on empty list"
[ "$OUT" = "stale" ] || fail "case 3: empty list forced anyway (got '$OUT')"

# --- Case 4: set-model.sh's force-list matches code-ccgw.sh's ---------------
# The two are the same list of routing keys, declared twice; nothing but this
# case stops them drifting when a fifth key is added to one of them. Cases 1-3
# prove the loader honors whatever list it is handed, so a complete, matching
# list here is what makes set-model.sh's own behavior guaranteed -- there is no
# read-only way to observe the resolved value through the script itself.
force_list_of() { sed -n 's/^DOTENV_FORCE_KEYS="\(.*\)"$/\1/p' "$1"; }
CCGW="$REPO/scripts/code-ccgw.sh"
for f in "$SCRIPT" "$CCGW"; do [ -f "$f" ] || fail "case 4: $f not found"; done
SET_MODEL_LIST="$(force_list_of "$SCRIPT")"
CCGW_LIST="$(force_list_of "$CCGW")"
[ -n "$CCGW_LIST" ] || fail "case 4: code-ccgw.sh no longer declares a DOTENV_FORCE_KEYS list"
[ "$SET_MODEL_LIST" = "$CCGW_LIST" ] \
    || fail "case 4: force-list drift between the two declarations:
  set-model.sh: $SET_MODEL_LIST
  code-ccgw.sh: $CCGW_LIST"

echo "PASS: test-set-model-dotenv-force-keys"
