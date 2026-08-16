#!/usr/bin/env bash
# Tests: scripts/serverctl.sh
# Tags: lifecycle, serverctl, dispatch, scope:issue-specific
#
# Scenario: serverctl dispatch — unknown subcommand/target exit 2 + usage;
# `all` expands to proxy + llama-swap + litellm (issue #41 adds litellm as the
# fourth managed service). `server` stays out of `all`: llama-swap owns its
# lifecycle, so dispatching both would double-manage the same process.
#
# Assertions are on OBSERVABLE OUTPUT (what serverctl prints), not on the
# DS4CTL_TRACE side channel the earlier version used. A trace hook only proves
# the dispatcher walked a list; it stays green even if every expansion after it
# is broken, and it tests an interface that exists solely for the test.
#
# The pgrep stub exits 1 ("not running") rather than 0. With `exit 0` the
# already-running short-circuit fires for every service and `start all` prints
# its skip message — which the old test happily accepted as a pass. Exiting 1
# forces the real start path, so the expansion is actually exercised; `nohup`
# is stubbed to keep it inert.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# TL3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real CCGW_PROXY_AUTH_TOKEN auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVERCTL="$REPO/scripts/serverctl.sh"

[ -f "$SERVERCTL" ] || { echo "SKIP: $SERVERCTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed every value the start guards require so a guard refusal can never
# masquerade as a dispatch result.
export DOTENV_FILE="$WORK/dotenv"
printf 'CCGW_PROXY_AUTH_TOKEN=test-token\nLITELLM_MASTER_KEY=test-master-key\nLITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443\nLITELLM_TLS=off\n' > "$DOTENV_FILE"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME"

# --- Stub PATH so nothing real is launched ----------------------------------
STUB="$WORK/stub"
mkdir -p "$STUB"
# launchctl: not loaded -> the launchd short-circuit in ds4_start stays off.
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
# pgrep: nothing running -> the "already running (untracked)" short-circuit
# stays off, so the start path is really taken. See header.
printf '#!/bin/sh\nexit 1\n' > "$STUB/pgrep"
printf '#!/bin/sh\nexit 0\n' > "$STUB/pkill"
printf '#!/bin/sh\nexit 0\n' > "$STUB/caffeinate"
# nohup: swallow the background launch; record it so we can prove inertness.
cat > "$STUB/nohup" <<EOF
#!/bin/sh
echo "NOHUP \$*" >> "$WORK/nohup.log"
exit 0
EOF
chmod +x "$STUB/launchctl" "$STUB/pgrep" "$STUB/pkill" "$STUB/caffeinate" "$STUB/nohup"

run() {
    PATH="$STUB:$PATH" bash "$SERVERCTL" "$@" >"$WORK/out" 2>"$WORK/err"
    echo $?
}

# --- 1. Argument validation -------------------------------------------------
rc="$(run bogus proxy)"
[ "$rc" = "2" ] || fail "unknown subcommand: expected exit 2, got $rc"
grep -qi "usage" "$WORK/out" "$WORK/err" || fail "unknown subcommand: no usage text"

rc="$(run start bogus)"
[ "$rc" = "2" ] || fail "unknown target: expected exit 2, got $rc"
grep -qi "usage" "$WORK/out" "$WORK/err" || fail "unknown target: no usage text"

# An omitted target is NOT an error: `target="${2:-all}"` makes it a synonym
# for `all`. The previous revision of this file asserted exit 2 here, which the
# implementation never did — a stale expectation, not a defect. It matters more
# now that `all` covers three services: the bare form is what a user types.
rc="$(run status)"
[ "$rc" = "0" ] || fail "omitted target: expected exit 0 (a bare target defaults to 'all'), got $rc (err: $(cat "$WORK/err"))"
for svc in proxy llama-swap litellm; do
    grep -q "^$svc:" "$WORK/out" || fail "omitted target: '$svc' missing — the default must expand exactly like 'all':
$(cat "$WORK/out")"
done

# --- 2. `litellm` is an accepted target ------------------------------------
# Negative control for case 1: `bogus` must fail *because it is unknown*, not
# because every target fails.
rc="$(run status litellm)"
[ "$rc" = "0" ] || fail "status litellm: expected exit 0, got $rc (err: $(cat "$WORK/err"))"
grep -q '^litellm:' "$WORK/out" || fail "status litellm: no 'litellm:' line in output:
$(cat "$WORK/out")"

# --- 3. Usage text advertises the litellm target ---------------------------
run bogus proxy >/dev/null
grep -q "litellm" "$WORK/out" "$WORK/err" || fail "usage text does not mention the litellm target:
$(cat "$WORK/out" "$WORK/err")"

# --- 4. `status all` expands to exactly proxy + llama-swap + litellm --------
rc="$(run status all)"
[ "$rc" = "0" ] || fail "status all: expected exit 0, got $rc (err: $(cat "$WORK/err"))"
for svc in proxy llama-swap litellm; do
    grep -q "^$svc:" "$WORK/out" || fail "status all: '$svc' missing from output:
$(cat "$WORK/out")"
done
grep -q '^server:' "$WORK/out" && fail "status all: 'server' present — llama-swap owns ds4-server's lifecycle, so 'all' must exclude it:
$(cat "$WORK/out")"

# --- 5. `start all` starts each of the three, and no more ------------------
: > "$WORK/nohup.log"
rc="$(run start all)"
[ "$rc" = "0" ] || fail "start all: expected exit 0, got $rc (err: $(cat "$WORK/err"))"
for svc in proxy llama-swap litellm; do
    grep -q "started $svc" "$WORK/out" || fail "start all: '$svc' was not started (observable output):
$(cat "$WORK/out")"
done
grep -q "started server" "$WORK/out" && fail "start all: 'server' was started — it must stay excluded from 'all':
$(cat "$WORK/out")"

# Inertness check: the launches went through the stub, not to a real process.
[ -s "$WORK/nohup.log" ] || fail "start all: nohup stub was never invoked — the test may have taken a short-circuit path instead of the real start path"

# --- 6. `start server` remains individually reachable ----------------------
# The exclusion in case 4/5 is about the `all` group only; the manual-debug
# target must not be removed.
: > "$WORK/nohup.log"
rc="$(run start server)"
[ "$rc" = "0" ] || fail "start server: expected exit 0, got $rc (err: $(cat "$WORK/err"))"
grep -q "started server" "$WORK/out" || fail "start server: manual-debug target unreachable:
$(cat "$WORK/out")"

echo "PASS: test-dispatch"
