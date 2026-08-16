#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/lifecycle.sh, scripts/lib/paths.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl CCGW_LOG toggle — on creates/appends a log file; off writes no file.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real CCGW_PROXY_AUTH_TOKEN auth check.
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
printf 'CCGW_PROXY_AUTH_TOKEN=test-token
' > "$DOTENV_FILE"
export HOME="$WORK/home"
PID_DIR="$HOME/Library/Application Support/cc-local-llm/run"
mkdir -p "$PID_DIR"
LOG_DIR="$HOME/Library/Logs/ccgw-proxy"

cleanup() {
    [ -f "$PID_DIR/proxy.pid" ] && kill "$(cat "$PID_DIR/proxy.pid")" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/launchctl"
chmod +x "$STUB/launchctl"

# Fake service emits a marker line to stdout so the log capture can be observed.
FAKE="$WORK/fake-service.sh"
cat > "$FAKE" <<'EOF'
#!/bin/sh
echo "FAKE-MARKER-LINE"
exec sleep 300
EOF
chmod +x "$FAKE"
export DS4CTL_EXEC_OVERRIDE="$FAKE"

wait_for() { _i=0; while [ ! -s "$1" ] && [ "$_i" -lt "${2}0" ]; do perl -e 'select undef,undef,undef,0.1'; _i=$((_i+1)); done; [ -s "$1" ]; }
stop_proxy() { PATH="$STUB:$PATH" bash "$SERVERCTL" stop proxy >/dev/null 2>&1 || true; perl -e 'select undef,undef,undef,0.3'; }

# --- CCGW_LOG=on -> log file created and receives service output -------------
rm -rf "$LOG_DIR"
CCGW_LOG=on PATH="$STUB:$PATH" bash "$SERVERCTL" start proxy >"$WORK/out" 2>&1 || fail "start (log on) failed: $(cat "$WORK/out")"
wait_for "$PID_DIR/proxy.pid" 5 || fail "log on: proxy did not start"
LOGFILE=""
_i=0
while [ "$_i" -lt 50 ]; do
    LOGFILE="$(ls "$LOG_DIR"/*.log 2>/dev/null | head -n1 || true)"
    [ -n "$LOGFILE" ] && [ -s "$LOGFILE" ] && break
    perl -e 'select undef,undef,undef,0.1'; _i=$((_i+1))
done
[ -n "$LOGFILE" ] || fail "log on: no *.log file created under $LOG_DIR"
grep -q "FAKE-MARKER-LINE" "$LOGFILE" || fail "log on: service output not captured in $LOGFILE"

# Append semantics: restart appends rather than truncating.
BEFORE_BYTES=$(wc -c < "$LOGFILE")
stop_proxy
CCGW_LOG=on PATH="$STUB:$PATH" bash "$SERVERCTL" start proxy >"$WORK/out" 2>&1 || fail "restart (log on) failed"
wait_for "$PID_DIR/proxy.pid" 5 || fail "log on restart: proxy did not start"
perl -e 'select undef,undef,undef,0.5'
AFTER_BYTES=$(wc -c < "$LOGFILE")
[ "$AFTER_BYTES" -ge "$BEFORE_BYTES" ] || fail "log on: file shrank ($AFTER_BYTES < $BEFORE_BYTES) — not appending"
stop_proxy

# --- CCGW_LOG=off -> no log file written -------------------------------------
rm -rf "$LOG_DIR"
CCGW_LOG=off PATH="$STUB:$PATH" bash "$SERVERCTL" start proxy >"$WORK/out" 2>&1 || fail "start (log off) failed: $(cat "$WORK/out")"
wait_for "$PID_DIR/proxy.pid" 5 || fail "log off: proxy did not start"
perl -e 'select undef,undef,undef,0.5'
if ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
    fail "log off: a log file was created under $LOG_DIR"
fi
stop_proxy

echo "PASS: test-log-toggle"
