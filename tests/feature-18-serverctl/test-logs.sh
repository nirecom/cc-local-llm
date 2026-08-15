#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl logs — DS4_LOG=off errors; DS4_LOG=on tails an existing
# log; `logs all` enumerates every managed service, which since issue #41
# includes litellm ($HOME/Library/Logs/litellm/litellm.log).
#
# `logs all` returning 0 is not sufficient evidence on its own — it exits 0
# whether it tailed three logs or none. The tail stub therefore records the
# paths it was handed, and the per-service assertions run against that record.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# `tail` is stubbed to return immediately so the follow mode does not block.
#
# TL3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_PROXY_AUTH_TOKEN auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SERVERCTL="$REPO/scripts/serverctl.sh"

[ -f "$SERVERCTL" ] || { echo "SKIP: $SERVERCTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; seed it with a stub auth token so the start guard sees a value.
export DOTENV_FILE="$WORK/dotenv"
printf 'DS4_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
export HOME="$WORK/home"
mkdir -p "$HOME"
LOG_DIR="$HOME/Library/Logs/ds4-proxy"

trap 'rm -rf "$WORK"' EXIT

# Stub launchctl / pgrep inert, and stub `tail` so follow-mode exits at once.
STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
printf '#!/bin/sh\nexit 1\n' > "$STUB/pgrep"
# tail stub: echo a marker, record the arguments, return immediately (no
# blocking -f). The recording is what makes `logs all` assertable per service.
cat > "$STUB/tail" <<EOF
#!/bin/sh
echo "TAIL-INVOKED \$*"
echo "\$*" >> "$WORK/tail.log"
exit 0
EOF
chmod +x "$STUB/launchctl" "$STUB/pgrep" "$STUB/tail"

# --- DS4_LOG=off -> logs reports an error ------------------------------------
out="$(DS4_LOG=off PATH="$STUB:$PATH" bash "$SERVERCTL" logs proxy 2>&1)"; rc=$?
[ "$rc" != "0" ] || fail "logs (log off): expected non-zero exit, got 0 (out: $out)"
echo "$out" | grep -qi "error\|off\|disabled\|no log" || fail "logs (log off): no error message (got: $out)"

# --- DS4_LOG=on with an existing log file -> tail is invoked -----------------
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/proxy.log"
printf 'existing log line\n' > "$LOGFILE"

out="$(DS4_LOG=on PATH="$STUB:$PATH" bash "$SERVERCTL" logs proxy 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "logs (log on): expected exit 0, got $rc (out: $out)"
echo "$out" | grep -q "TAIL-INVOKED" || fail "logs (log on): tail was not invoked on the log file (got: $out)"

# --- logs all -> every managed service's log is tailed ----------------------
# Seed a log for each service in the `all` group so nothing is skipped merely
# for being absent — the assertion must be about enumeration, not about which
# files happen to exist on this machine.
mkdir -p "$HOME/Library/Logs/llama-swap" "$HOME/Library/Logs/litellm"
printf 'llama-swap log line\n' > "$HOME/Library/Logs/llama-swap/llama-swap.log"
printf 'litellm log line\n' > "$HOME/Library/Logs/litellm/litellm.log"

: > "$WORK/tail.log"
out="$(DS4_LOG=on PATH="$STUB:$PATH" bash "$SERVERCTL" logs all 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "logs all: expected exit 0, got $rc (out: $out)"

grep -q "ds4-proxy/proxy.log" "$WORK/tail.log" || fail "logs all: proxy log was not tailed (tailed: $(cat "$WORK/tail.log"))"
grep -q "llama-swap/llama-swap.log" "$WORK/tail.log" || fail "logs all: llama-swap log was not tailed (tailed: $(cat "$WORK/tail.log"))"
grep -q "litellm/litellm.log" "$WORK/tail.log" || fail "logs all: litellm log was not tailed — litellm must join the 'all' enumeration (tailed: $(cat "$WORK/tail.log"))"

# Negative side: `server` is excluded from `all` (llama-swap owns it), so its
# log must not be tailed even when the file exists.
mkdir -p "$HOME/Library/Logs/ds4-server"
printf 'server log line\n' > "$HOME/Library/Logs/ds4-server/kvcache.log"
: > "$WORK/tail.log"
out="$(DS4_LOG=on PATH="$STUB:$PATH" bash "$SERVERCTL" logs all 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "logs all (2nd run): expected exit 0, got $rc (out: $out)"
grep -q "ds4-server/kvcache.log" "$WORK/tail.log" && fail "logs all: server log was tailed — 'all' must exclude the server target (tailed: $(cat "$WORK/tail.log"))"

# --- logs litellm (direct target) ------------------------------------------
: > "$WORK/tail.log"
out="$(DS4_LOG=on PATH="$STUB:$PATH" bash "$SERVERCTL" logs litellm 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "logs litellm: expected exit 0, got $rc (out: $out)"
grep -q "litellm/litellm.log" "$WORK/tail.log" || fail "logs litellm: litellm log was not tailed (tailed: $(cat "$WORK/tail.log"))"

echo "PASS: test-logs"
