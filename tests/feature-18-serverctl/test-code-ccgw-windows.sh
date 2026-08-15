#!/usr/bin/env bash
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Scenario: bash driver for the Pester suite that covers the Windows client
# launcher (code-ccgw-windows.Tests.ps1) — base-URL / auth-token / TLS-CA
# precedence, the LiteLLM-vs-direct model branch, and CCGW_DEFAULT_MODEL moving
# only the startup-resident model while the /model tier map stays put.
#
# The assertions live in the .Tests.ps1; this file exists so the suite is
# reachable from the same `bash tests/.../test-*.sh` convention as its siblings.
# Skips (exit 0) when pwsh is unavailable — the launcher is Windows-only, and a
# Mac/Linux developer must not see a red run for a shell they do not have.
#
# L3 gap: everything a real Windows host provides — a real VS Code, a real
#   mkcert CA in the Windows trust store, and the LOCALAPPDATA profile path
#   actually being writable.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SUITE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/code-ccgw-windows.Tests.ps1"
LAUNCHER="$REPO/scripts/code-ccgw.ps1"

[ -f "$LAUNCHER" ] || { echo "SKIP: $LAUNCHER not found (implementation pending)"; exit 77; }
[ -f "$SUITE" ] || { echo "FAIL: $SUITE not found" >&2; exit 1; }

if ! command -v pwsh >/dev/null 2>&1; then
    echo "SKIP: pwsh not on PATH - the Windows launcher suite (code-ccgw-windows.Tests.ps1) cannot run on this host."
    echo "      Install PowerShell 7+ (and the Pester 5 module) to execute it; the POSIX counterpart is test-code-ccgw-posix.sh."
    exit 0
fi

if ! pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 })) { exit 1 }' >/dev/null 2>&1; then
    echo "SKIP: Pester 5+ module not installed for this pwsh."
    echo "      Install it with: pwsh -NoProfile -Command \"Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force\""
    exit 0
fi

# -PassThru + explicit exit: Invoke-Pester on its own returns 0 even when cases
# fail, so the failure count has to be turned into the process exit status here.
pwsh -NoProfile -Command "\$r = Invoke-Pester '$SUITE' -Output Detailed -PassThru; exit \$r.FailedCount"
RC=$?

[ "$RC" -eq 0 ] && echo "PASS: test-code-ccgw-windows"
exit "$RC"
