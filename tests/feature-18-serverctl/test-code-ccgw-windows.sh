#!/usr/bin/env bash
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Scenario: bash driver for the Pester suite that covers the Windows client
# launcher (code-ccgw-windows.Tests.ps1), including the issue #66 env-isolation
# and cmd.exe-metacharacter contracts. Runs the suite on pwsh 7 always, and also
# on Windows PowerShell 5.1 when RUN_TL3 asks for it (CCGW_TEST_LAUNCHER_HOST) --
# see the .Tests.ps1 header for what each contract covers and why.
#
# This file only makes the suite reachable from the `bash tests/.../test-*.sh`
# convention; skips (exit 0) when pwsh is unavailable (Windows-only launcher).
#
# TL3 gap: a real Windows host — real VS Code, a real mkcert CA in the Windows
#   trust store, a writable LOCALAPPDATA profile path.
# TL3 gap: Windows PowerShell 5.1 as the launcher host (RUN_TL3=on), the only
#   way to catch .NET Framework-only breakage the default pwsh-7 run cannot.
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

# Under Git Bash $SUITE is a POSIX path (/c/git/...), which pwsh resolves against
# the current drive as C:\c\git\... — Pester then finds no test file, and because
# `exit $r.FailedCount` never runs after that throw the driver used to report PASS
# for a suite it had not executed. Hand pwsh a real Windows path, and make "the run
# did not happen" an explicit failure rather than a silent zero.
SUITE_PS="$SUITE"
command -v cygpath >/dev/null 2>&1 && SUITE_PS="$(cygpath -m -- "$SUITE")"

# -PassThru + explicit exit: Invoke-Pester on its own returns 0 even when cases
# fail, so the failure count has to be turned into the process exit status here.
run_suite() {
    pwsh -NoProfile -Command "\$ErrorActionPreference = 'Stop'; \$r = \$null; try { \$r = Invoke-Pester '$SUITE_PS' -Output Detailed -PassThru } catch { [Console]::Error.WriteLine('Invoke-Pester failed: ' + \$_); exit 99 }; if (\$null -eq \$r -or \$r.TotalCount -eq 0) { [Console]::Error.WriteLine('Invoke-Pester ran no cases'); exit 98 }; exit \$r.FailedCount"
}

# The first run is the pwsh-7-host run, and it has to be that whatever the
# caller's environment already contains: CCGW_TEST_LAUNCHER_HOST inherited from
# the shell would silently retarget it. That is not a cosmetic risk here — the
# TL3 block below re-runs the SAME suite with the variable set, so an inherited
# value collapses the two runs into one host, and the pwsh-7 half of the contract
# would go unasserted while the driver still printed PASS. Subshell, so the unset
# scopes to this run only (bash leaks a var prefix on a *function* call into the
# rest of the shell, which is why neither run uses that form).
( unset CCGW_TEST_LAUNCHER_HOST; run_suite )
RC=$?

# Second host: Windows PowerShell 5.1 as the launcher's host. The launcher
# supports it (#Requires -Version 5.1) but only pwsh 7 ever ran it, and the #66
# work lands on APIs whose 5.1 behavior differs — so the same suite is re-run with
# only the host of the process under test swapped. Opt-in because it doubles an
# already slow suite and only a Windows host can satisfy it: a missing
# powershell.exe or an unset RUN_TL3 reports a skip and leaves RC alone, so the
# default run still decides the overall result.
if [ "${RUN_TL3:-}" != "on" ]; then
    echo "SKIP: RUN_TL3 is not 'on' - the Windows PowerShell 5.1 launcher-host run was not executed."
    echo "      Run it with: RUN_TL3=on bash $0"
elif ! command -v powershell.exe >/dev/null 2>&1; then
    echo "SKIP: powershell.exe not on PATH - the Windows PowerShell 5.1 launcher-host run was not executed."
    echo "      It exists only on Windows; the run above already covered the assertions under pwsh 7."
else
    echo "--- launcher on Windows PowerShell 5.1 (RUN_TL3=on) ---"
    # An explicitly requested host that is missing makes the suite throw rather
    # than skip, which is why the availability gate has to be here, not in Pester.
    # Subshell: a var prefix on a *function* call leaks into the rest of the shell
    # in bash, and this override must not outlive the run it configures.
    ( export CCGW_TEST_LAUNCHER_HOST=powershell.exe; run_suite )
    RC51=$?
    if [ "$RC51" -ne 0 ]; then
        echo "FAIL: the suite failed with the launcher on Windows PowerShell 5.1 ($RC51 case(s))." >&2
        [ "$RC" -eq 0 ] && RC="$RC51"
    fi
fi

[ "$RC" -eq 0 ] && echo "PASS: test-code-ccgw-windows"
exit "$RC"
