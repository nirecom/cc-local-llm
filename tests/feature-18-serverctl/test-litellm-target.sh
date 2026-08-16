#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/paths.sh, scripts/lib/lifecycle.sh
# Tags: lifecycle, serverctl, litellm, scope:issue-specific
#
# Scenario (issue #41): LiteLLM moves off Windows/Docker and becomes the fourth
# serverctl-managed Mac service. 'all' expands to proxy+llama-swap+litellm
# ('server' stays excluded — llama-swap owns its lifecycle), and every paths.sh
# / lifecycle.sh helper resolves a litellm value.
#
# The pgrep pattern is directory-qualified on purpose: a bare `litellm.*config`
# would match a litellm the user runs by hand against their own config, and
# `serverctl stop litellm` would kill it. Both verdicts are pinned below.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
#
# TL3 gap: whether the pinned `litellm` binary actually accepts these flags,
#   whether launchd loads the agent across reboots, and whether LiteLLM serves
#   the four routes. Only a real host answers those; covered by the manual
#   cutover procedure in docs/ops.md at user_verification.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVERCTL="$REPO/scripts/serverctl.sh"

[ -f "$SERVERCTL" ] || { echo "SKIP: $SERVERCTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with the stub values the start guards look for.
export DOTENV_FILE="$WORK/dotenv"
printf 'CCGW_PROXY_AUTH_TOKEN=test-token\nLITELLM_MASTER_KEY=test-master-key\nLITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443\n' > "$DOTENV_FILE"
export HOME="$WORK/home"
mkdir -p "$HOME"
trap 'rm -rf "$WORK"' EXIT

# --- 1. `serverctl status all` covers proxy + llama-swap + litellm ----------
OUT="$(bash "$SERVERCTL" status all 2>"$WORK/err")" || fail "status all failed: $(cat "$WORK/err")"
echo "$OUT" | grep -q '^proxy:' || fail "status all: no 'proxy' line in output:
$OUT"
echo "$OUT" | grep -q '^llama-swap:' || fail "status all: no 'llama-swap' line in output:
$OUT"
echo "$OUT" | grep -q '^litellm:' || fail "status all: no 'litellm' line in output (litellm must join the 'all' group):
$OUT"
echo "$OUT" | grep -q '^server:' && fail "status all: unexpectedly printed a 'server' line (server must stay excluded from 'all'):
$OUT"

# --- 2. `serverctl status litellm` (direct target) works --------------------
OUT="$(bash "$SERVERCTL" status litellm 2>"$WORK/err")" || fail "status litellm failed: $(cat "$WORK/err")"
echo "$OUT" | grep -q '^litellm:' || fail "status litellm: no 'litellm' line in output:
$OUT"

# --- 3. paths.sh helpers resolve litellm correctly --------------------------
CCGW_SCRIPT_DIR="$REPO/scripts"
export CCGW_SCRIPT_DIR
# shellcheck source=scripts/lib/root.sh
. "$CCGW_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/paths.sh
. "$CCGW_SCRIPT_DIR/lib/paths.sh"

_ds4_valid_svc litellm || fail "_ds4_valid_svc litellm: expected success"
# Negative control: the classifier must still reject a non-service.
_ds4_valid_svc litellm-server && fail "_ds4_valid_svc litellm-server: expected failure (only the exact service name is a target)"

[ -n "${LITELLM_ROOT:-}" ] || fail "LITELLM_ROOT is not defined by paths.sh"
EXPECT="$CCGW_OPS_ROOT/litellm-server"
[ "$LITELLM_ROOT" = "$EXPECT" ] || fail "LITELLM_ROOT: expected '$EXPECT', got '$LITELLM_ROOT'"

GOT="$(_ds4_log_dir litellm)"
EXPECT="$HOME/Library/Logs/litellm"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_log_dir litellm: expected '$EXPECT', got '$GOT'"

GOT="$(_ds4_log_file litellm)"
EXPECT="$HOME/Library/Logs/litellm/litellm.log"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_log_file litellm: expected '$EXPECT', got '$GOT'"

GOT="$(_ds4_wrapper_script litellm)"
EXPECT="litellm.sh"
[ "$GOT" = "$EXPECT" ] || fail "_ds4_wrapper_script litellm: expected '$EXPECT', got '$GOT'"

# --- 4. pgrep pattern: directory-qualified, both verdicts pinned ------------
PATTERN="$(_ds4_pgrep_pattern litellm)"
EXPECT="litellm.*/litellm-server/config.yaml"
[ "$PATTERN" = "$EXPECT" ] || fail "_ds4_pgrep_pattern litellm: expected '$EXPECT', got '$PATTERN'"

# Positive: our own managed process must match, or stop/status never work.
OURS="/Users/dev/.local/bin/litellm --config /Users/dev/git/cc-local-llm/litellm-server/config.yaml --port 8445"
echo "$OURS" | grep -Eq "$PATTERN" || fail "_ds4_pgrep_pattern litellm does not match the managed process line — status/stop would never find it:
  pattern: $PATTERN
  line:    $OURS"

# Negative: a litellm the user runs against their own config must NOT match,
# otherwise `serverctl stop litellm` kills an unrelated process.
THEIRS="/Users/dev/.local/bin/litellm --config /Users/dev/scratch/my-litellm/config.yaml --port 9999"
echo "$THEIRS" | grep -Eq "$PATTERN" && fail "_ds4_pgrep_pattern litellm matches an unrelated litellm process — 'serverctl stop litellm' would kill it:
  pattern: $PATTERN
  line:    $THEIRS"

# --- 5. lifecycle.sh _ds4_cwd / _ds4_cmd -----------------------------------
# shellcheck source=scripts/lib/launchd.sh
. "$CCGW_SCRIPT_DIR/lib/launchd.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$CCGW_SCRIPT_DIR/lib/lifecycle.sh"

GOT="$(_ds4_cwd litellm)"
[ "$GOT" = "$LITELLM_ROOT" ] || fail "_ds4_cwd litellm: expected '$LITELLM_ROOT', got '$GOT'"

# 5a. Plaintext (no TLS): full-string equality lock, same style as
# test-server-flags.sh — catches flag addition, removal, reordering and value
# drift in one assertion. Every input is pinned explicitly so the developer's
# ambient .env cannot decide the verdict.
unset LITELLM_HOST LITELLM_PORT LITELLM_TLS_CERT LITELLM_TLS_KEY
export LITELLM_TLS=off
CMD="$(_ds4_cmd litellm)" || fail "_ds4_cmd litellm exited non-zero"
EXPECT="litellm --config \"$LITELLM_ROOT/config.yaml\" --host \"0.0.0.0\" --port \"8445\""
[ "$CMD" = "$EXPECT" ] || fail "_ds4_cmd litellm (defaults, TLS off) does not match the expected launch flags
  expected: $EXPECT
  actual:   $CMD
  If the litellm flags were changed intentionally, update this expected value too."

# 5b. Host/port overrides are honored and the defaults are gone.
export LITELLM_HOST=127.0.0.1 LITELLM_PORT=9445
CMD="$(_ds4_cmd litellm)" || fail "_ds4_cmd litellm (overrides) exited non-zero"
case "$CMD" in
    *'--host "127.0.0.1"'*) ;;
    *) fail "_ds4_cmd litellm (overridden host): expected --host \"127.0.0.1\", got: $CMD" ;;
esac
case "$CMD" in
    *'--port "9445"'*) ;;
    *) fail "_ds4_cmd litellm (overridden port): expected --port \"9445\", got: $CMD" ;;
esac
case "$CMD" in
    *8445*) fail "_ds4_cmd litellm (overridden port): default 8445 still present: $CMD" ;;
    *) ;;
esac
unset LITELLM_HOST LITELLM_PORT

# 5c. TLS enabled: the cert/key flags appear with the configured paths.
export LITELLM_TLS=on
export LITELLM_TLS_CERT="$WORK/cert.pem"
export LITELLM_TLS_KEY="$WORK/key.pem"
CMD="$(_ds4_cmd litellm)" || fail "_ds4_cmd litellm (TLS on) exited non-zero"
case "$CMD" in
    *"--ssl_certfile_path \"$WORK/cert.pem\""*) ;;
    *) fail "_ds4_cmd litellm (TLS on): missing --ssl_certfile_path \"$WORK/cert.pem\", got: $CMD" ;;
esac
case "$CMD" in
    *"--ssl_keyfile_path \"$WORK/key.pem\""*) ;;
    *) fail "_ds4_cmd litellm (TLS on): missing --ssl_keyfile_path \"$WORK/key.pem\", got: $CMD" ;;
esac

# 5d. Negative control for 5c: with TLS off the flags must be absent, so 5c
# cannot pass against an implementation that emits them unconditionally.
export LITELLM_TLS=off
CMD="$(_ds4_cmd litellm)" || fail "_ds4_cmd litellm (TLS off, certs set) exited non-zero"
case "$CMD" in
    *--ssl_certfile_path*) fail "_ds4_cmd litellm (TLS off): --ssl_certfile_path emitted anyway: $CMD" ;;
    *) ;;
esac
case "$CMD" in
    *--ssl_keyfile_path*) fail "_ds4_cmd litellm (TLS off): --ssl_keyfile_path emitted anyway: $CMD" ;;
    *) ;;
esac

echo "PASS: test-litellm-target"
