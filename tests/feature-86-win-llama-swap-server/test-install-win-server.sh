#!/usr/bin/env bash
# Tests: install.ps1, install/win/lib/roles.ps1, install/win/lib/nssm-args.ps1, install/win/lib/native.ps1, install/win/llama-swap-service.ps1, install/win/certs.ps1
# Tags: installer, windows, pwsh-required, pester, layer:TL2, scope:common
# scope:common despite the feature-86- dir: it drives permanent coverage, so it must survive the retirement sweep with the suites it runs.
# Bash driver for every *.Tests.ps1 in this directory -- makes the Pester suites reachable from the `bash tests/.../test-*.sh` convention and owns the two things Pester cannot express: skip gating (exit 77) and the skip profile (lib/assert-pester-profile.sh). Mirrors tests/feature-18-serverctl/test-code-ccgw-windows.sh.
# The suites only dot-source install/win/lib/*.ps1 (function definitions only) and read the rest through the AST, so running them touches neither NSSM nor any service.
# Either the implementation is absent and every suite is gated off here (77), or it is present and a skipped case is a failure -- there is no third state where a skip is merely informational.
# TL3 gap (what this driver does NOT catch):
# - whether the installer, run for real on the Windows host, registers and starts both services
# - whether nssm/caddy/mkcert are installable there at all
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh categories: installer, pwsh-required
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROFILE="$HERE/lib/assert-pester-profile.sh"

[ -f "$PROFILE" ] || { echo "FAIL: $PROFILE not found" >&2; exit 1; }

SUITES=""
COUNT=0
for s in "$HERE"/*.Tests.ps1; do
    [ -f "$s" ] || continue
    SUITES="$SUITES $s"
    COUNT=$((COUNT + 1))
done
[ "$COUNT" -gt 0 ] || { echo "FAIL: no *.Tests.ps1 beside $0" >&2; exit 1; }

# The gate is "every file any suite reads", not just the libs: a suite whose
# subject is missing would report Skipped, and the profile check below refuses
# to call that a pass. Missing implementation is a skip for the whole driver.
for f in \
    install/win/lib/roles.ps1 \
    install/win/lib/nssm-args.ps1 \
    install/win/lib/native.ps1 \
    install/win/llama-swap-service.ps1 \
    install/win/certs.ps1 \
    install/win/mkcert.ps1 \
    install.ps1
do
    [ -f "$REPO/$f" ] || { echo "SKIP: $REPO/$f not found (implementation pending)"; exit 77; }
done

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
    *) echo "SKIP: not a Windows host - the server-role installer suites are Windows-only"; exit 77 ;;
esac

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH - install PowerShell 7+ and Pester 5 to run these suites"; exit 77; }

if ! pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 })) { exit 1 }' >/dev/null 2>&1; then
    echo "SKIP: Pester 5+ not installed for this pwsh."
    echo "      Install it with: pwsh -NoProfile -Command \"Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force\""
    exit 77
fi

# Under Git Bash the paths above are POSIX (/c/git/...), which pwsh resolves
# against the current drive as C:\c\git\... -- Pester then finds no test file.
# Hand pwsh real Windows paths (same trap documented in test-code-ccgw-windows.sh).
to_win() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s' "$1"; fi
}

SUITE_LIST=""
for s in $SUITES; do
    SUITE_LIST="$SUITE_LIST,'$(to_win "$s")'"
done
SUITE_LIST="${SUITE_LIST#,}"

# The suites derive their own repo root from $PSScriptRoot, which ignores a $REPO
# override and would then check a different checkout than the gates above. Hand
# them the same root, in the Windows form pwsh can resolve.
CCLL_REPO="$(to_win "$REPO")"
export CCLL_REPO

# Counts, not just the exit status: Invoke-Pester returns 0 even when cases fail,
# and returns 0 just as happily when every case was skipped.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pwsh -NoProfile -Command "\$ErrorActionPreference = 'Stop'; \$r = \$null; try { \$r = Invoke-Pester -Path @($SUITE_LIST) -Output Detailed -PassThru } catch { [Console]::Error.WriteLine('Invoke-Pester failed: ' + \$_); exit 99 }; if (\$null -eq \$r) { [Console]::Error.WriteLine('Invoke-Pester returned nothing'); exit 98 }; [Console]::Out.WriteLine(\"CCLL_PROFILE total=\$(\$r.TotalCount) failed=\$(\$r.FailedCount) skipped=\$(\$r.SkippedCount)\"); exit 0" | tee "$WORK/pester.out"
RC="${PIPESTATUS[0]}"

if [ "$RC" -ne 0 ]; then
    echo "FAIL: pwsh exited $RC before reporting counts" >&2
    exit "$RC"
fi

PROFILE_LINE="$(sed -n 's/^CCLL_PROFILE //p' "$WORK/pester.out" | tail -n 1)"
[ -n "$PROFILE_LINE" ] || { echo "FAIL: Invoke-Pester produced no CCLL_PROFILE line - the run did not complete" >&2; exit 1; }

TOTAL=""; FAILED=""; SKIPPED=""
for kv in $PROFILE_LINE; do
    case "$kv" in
        total=*)   TOTAL="${kv#total=}" ;;
        failed=*)  FAILED="${kv#failed=}" ;;
        skipped=*) SKIPPED="${kv#skipped=}" ;;
    esac
done

bash "$PROFILE" --total "$TOTAL" --failed "$FAILED" --skipped "$SKIPPED" \
    --context "the $COUNT Pester suite(s) beside $(basename -- "$0")" || exit 1

echo "PASS: test-install-win-server ($COUNT suite(s), $TOTAL cases, 0 failed, 0 skipped)"
