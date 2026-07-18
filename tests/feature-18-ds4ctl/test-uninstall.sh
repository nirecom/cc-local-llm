#!/usr/bin/env bash
# Tests: ds4ctl uninstall — removes the LaunchAgents plist and calls `launchctl unload -w`.
# Tags: lifecycle, ds4ctl, scope:issue-specific
#
# Skips (exit 77) until scripts/ds4ctl.sh exists (implementation pending).
# launchctl is stubbed to record its argv so the unload call can be asserted.
#
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

REPO="/Users/example/git/ds4-ops"
DS4CTL="$REPO/scripts/ds4ctl.sh"

[ -f "$DS4CTL" ] || { echo "SKIP: $DS4CTL not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
export HOME="$WORK/home"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"
trap 'rm -rf "$WORK"' EXIT

PLIST="$LAUNCH_AGENTS/com.nire.ds4-proxy.plist"

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
  <key>Label</key><string>com.nire.ds4-proxy</string>
</dict></plist>
EOF

out="$(PATH="$STUB:$PATH" bash "$DS4CTL" uninstall proxy 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "uninstall proxy failed: rc=$rc (out: $out)"

# 1. The plist must be removed.
[ ! -f "$PLIST" ] || fail "uninstall: plist $PLIST was not removed"

# 2. launchctl unload -w must have been called.
[ -f "$LAUNCHCTL_LOG" ] || fail "uninstall: launchctl was never invoked"
grep -q "unload" "$LAUNCHCTL_LOG" || fail "uninstall: launchctl unload not called (log: $(cat "$LAUNCHCTL_LOG"))"
grep -- "-w" "$LAUNCHCTL_LOG" | grep -q "unload" || fail "uninstall: launchctl unload missing -w (log: $(cat "$LAUNCHCTL_LOG"))"

echo "PASS: test-uninstall"
