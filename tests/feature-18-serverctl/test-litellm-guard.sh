#!/usr/bin/env bash
# Tests: scripts/lib/lifecycle.sh, scripts/serverctl.sh
# Tags: lifecycle, serverctl, litellm, guard, scope:issue-specific
#
# Scenario (issue #41 / detail plan D6): `start litellm` must refuse before
# launching anything when its required configuration is missing, symmetrically
# with the existing CCGW_PROXY_AUTH_TOKEN guard on proxy.
#
# Why refusal beats "start and fail": a LaunchAgent has KeepAlive set, so a
# LiteLLM that starts and then dies on a missing master key respawns forever
# and buries the real cause in the log. Refusing at the guard surfaces the
# variable name once, on stderr, at the moment the user asked for it.
#
# Every case pins the environment explicitly (dotenv rewritten per case, and
# the variables scrubbed from the inherited environment): whether the
# developer happens to have a real .env exported must never decide the verdict.
#
# A separate file rather than a case inside test-double-start.sh: that suite is
# failing at baseline, so a guard case added there could not be distinguished
# from the pre-existing failure.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
#
# TL3 gap: whether the real litellm binary rejects the same configurations at
#   runtime. Covered by the manual cutover procedure in docs/ops.md.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVERCTL="$REPO/scripts/serverctl.sh"

[ -f "$SERVERCTL" ] || { echo "SKIP: $SERVERCTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
export DOTENV_FILE="$WORK/dotenv"
export HOME="$WORK/home"
mkdir -p "$HOME"
trap 'rm -rf "$WORK"' EXIT

# --- Stubs: nothing loaded, nothing running, launches recorded --------------
STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pgrep"
printf '#!/bin/sh\nexit 0\n' > "$STUB/pkill"
cat > "$STUB/nohup" <<EOF
#!/bin/sh
echo "NOHUP \$*" >> "$WORK/nohup.log"
exit 0
EOF
chmod +x "$STUB/launchctl" "$STUB/pgrep" "$STUB/pkill" "$STUB/nohup"

# Writes the dotenv from the arguments, then runs `serverctl start litellm`
# with the guarded variables scrubbed from the inherited environment.
start_litellm() {
    : > "$DOTENV_FILE"
    printf 'CCGW_PROXY_AUTH_TOKEN=test-token\n' >> "$DOTENV_FILE"
    for kv in "$@"; do
        printf '%s\n' "$kv" >> "$DOTENV_FILE"
    done
    : > "$WORK/nohup.log"
    rm -f "$HOME/Library/Application Support/cc-local-llm/run/litellm.pid"
    env -u LITELLM_MASTER_KEY -u LITELLM_CCGW_PROXY_URL \
        -u LITELLM_TLS -u LITELLM_TLS_CERT -u LITELLM_TLS_KEY \
        PATH="$STUB:$PATH" HOME="$HOME" DOTENV_FILE="$DOTENV_FILE" \
        bash "$SERVERCTL" start litellm >"$WORK/out" 2>"$WORK/err"
    echo $?
}

assert_refused() {
    _case="$1"; _rc="$2"; _needle="$3"
    [ "$_rc" != "0" ] || fail "$_case: expected a non-zero exit, got 0
  stdout: $(cat "$WORK/out")
  stderr: $(cat "$WORK/err")"
    grep -q "$_needle" "$WORK/err" || fail "$_case: stderr does not name the missing variable '$_needle' — the user cannot act on the message:
$(cat "$WORK/err")"
    [ -s "$WORK/nohup.log" ] && fail "$_case: a process was launched despite the guard (nohup invoked: $(cat "$WORK/nohup.log"))"
    [ -f "$HOME/Library/Application Support/cc-local-llm/run/litellm.pid" ] && fail "$_case: a PID file was written despite the guard"
    return 0
}

# --- 1. LITELLM_MASTER_KEY missing -----------------------------------------
rc="$(start_litellm 'LITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443' 'LITELLM_TLS=off')"
assert_refused "start litellm (no LITELLM_MASTER_KEY)" "$rc" "LITELLM_MASTER_KEY"

# --- 2. LITELLM_CCGW_PROXY_URL missing --------------------------------------
rc="$(start_litellm 'LITELLM_MASTER_KEY=test-master-key' 'LITELLM_TLS=off')"
assert_refused "start litellm (no LITELLM_CCGW_PROXY_URL)" "$rc" "LITELLM_CCGW_PROXY_URL"

# --- 3. Both missing --------------------------------------------------------
rc="$(start_litellm 'LITELLM_TLS=off')"
[ "$rc" != "0" ] || fail "start litellm (nothing configured): expected a non-zero exit, got 0"
[ -s "$WORK/nohup.log" ] && fail "start litellm (nothing configured): a process was launched despite the guard"

# --- 4. TLS enabled but certificate paths unset ----------------------------
rc="$(start_litellm 'LITELLM_MASTER_KEY=test-master-key' 'LITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443' 'LITELLM_TLS=on')"
assert_refused "start litellm (TLS on, no cert/key)" "$rc" "LITELLM_TLS"

# --- 5. Fully configured -> the guard lets it through ----------------------
# Negative control for cases 1-4: without this, an implementation that refuses
# unconditionally would pass every assertion above.
rc="$(start_litellm 'LITELLM_MASTER_KEY=test-master-key' 'LITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443' 'LITELLM_TLS=off')"
[ "$rc" = "0" ] || fail "start litellm (fully configured): expected exit 0, got $rc
  stdout: $(cat "$WORK/out")
  stderr: $(cat "$WORK/err")"
grep -q "started litellm" "$WORK/out" || fail "start litellm (fully configured): no start message in output:
$(cat "$WORK/out")"
[ -s "$WORK/nohup.log" ] || fail "start litellm (fully configured): nothing was launched — the guard refused a valid configuration"

# --- 6. The guard is litellm-specific --------------------------------------
# proxy must still start with no LiteLLM variables set at all, or the guard has
# been placed on the shared path instead of the litellm branch.
: > "$DOTENV_FILE"
printf 'CCGW_PROXY_AUTH_TOKEN=test-token\n' > "$DOTENV_FILE"
: > "$WORK/nohup.log"
rc=0
env -u LITELLM_MASTER_KEY -u LITELLM_CCGW_PROXY_URL \
    PATH="$STUB:$PATH" HOME="$HOME" DOTENV_FILE="$DOTENV_FILE" \
    bash "$SERVERCTL" start proxy >"$WORK/out" 2>"$WORK/err" || rc=$?
[ "$rc" = "0" ] || fail "start proxy: the litellm guard leaked onto the proxy path (exit $rc)
  stderr: $(cat "$WORK/err")"

echo "PASS: test-litellm-guard"
