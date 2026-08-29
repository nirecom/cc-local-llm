# nssm.ps1 - install NSSM, the service manager both llama-swap services run under.
#
# Idempotent: winget reports "already installed" as -1978335189 (0x8A15002B), which is
# the outcome a re-run of the installer wants, so it is the one non-zero code allowed here.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:SYSTEM_OPS_APPROVED = '1'

. "$PSScriptRoot\lib\native.ps1"

if (Get-Command nssm -ErrorAction SilentlyContinue) {
    Write-Host "nssm is already installed." -ForegroundColor DarkGray
    return
}

Write-Host "Installing nssm..."
Invoke-Native -FilePath 'winget' `
    -Arguments @('install', '--exact', '--id', 'NSSM.NSSM', '--accept-source-agreements', '--accept-package-agreements') `
    -AllowExitCodes (-1978335189) `
    -Context 'nssm installation via winget'

if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
    throw "nssm is still not on PATH after winget reported success. Open a new shell (winget updates PATH for new processes only) and re-run .\install.ps1 -Server."
}

Write-Host "nssm installed." -ForegroundColor Green
