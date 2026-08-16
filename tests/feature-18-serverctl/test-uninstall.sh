#!/usr/bin/env bash
# Tests: scripts/serverctl.sh, scripts/lib/launchd.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: serverctl uninstall — removes the LaunchAgents plist and calls `launchctl unload -w`.
#
# Skips (exit 77) until scripts/serverctl.sh exists (implementation pending).
# launchctl is stubbed to record its argv so the unload call can be asserted.
#
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
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"
trap 'rm -rf "$WORK"' EXIT

PLIST="$LAUNCH_AGENTS/com.nire.ccgw-proxy.plist"

# launchctl stub: record every invocation's argv for later assertion.
STUB="$WORK/stub"
mkdir -p "$STUB"
LAUNCHCTL_LOG="$WORK/launchctl.log"
export LAUNCHCTL_LOG
cat > "$STUB/launchctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$LAUNCHCTL_LOG"
exit 0
EOF
chmod +x "$STUB/launchctl"

# Seed an installed plist so uninstall has something to remove.
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.nire.ccgw-proxy</string>
</dict></plist>
EOF

out="$(PATH="$STUB:$PATH" bash "$SERVERCTL" uninstall proxy 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "uninstall proxy failed: rc=$rc (out: $out)"

# 1. The plist must be removed.
[ ! -f "$PLIST" ] || fail "uninstall: plist $PLIST was not removed"

# 2. launchctl unload -w must have been called.
[ -f "$LAUNCHCTL_LOG" ] || fail "uninstall: launchctl was never invoked"
grep -q "unload" "$LAUNCHCTL_LOG" || fail "uninstall: launchctl unload not called (log: $(cat "$LAUNCHCTL_LOG"))"
grep -- "-w" "$LAUNCHCTL_LOG" | grep -q "unload" || fail "uninstall: launchctl unload missing -w (log: $(cat "$LAUNCHCTL_LOG"))"

echo "PASS: test-uninstall"
