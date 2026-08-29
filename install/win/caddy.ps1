# caddy.ps1 - install Caddy, the TLS front end for llama-swap and the other local services.
#
# Same idempotence contract as nssm.ps1 (CPR-ORTH): -1978335189 means "already installed".

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:SYSTEM_OPS_APPROVED = '1'

. "$PSScriptRoot\lib\native.ps1"

if (Get-Command caddy -ErrorAction SilentlyContinue) {
    Write-Host "caddy is already installed." -ForegroundColor DarkGray
    return
}

Write-Host "Installing caddy..."
Invoke-Native -FilePath 'winget' `
    -Arguments @('install', '--exact', '--id', 'CaddyServer.Caddy', '--accept-source-agreements', '--accept-package-agreements') `
    -AllowExitCodes (-1978335189) `
    -Context 'caddy installation via winget'

if (-not (Get-Command caddy -ErrorAction SilentlyContinue)) {
    throw "caddy is still not on PATH after winget reported success. Open a new shell (winget updates PATH for new processes only) and re-run .\install.ps1 -Server."
}

Write-Host "caddy installed." -ForegroundColor Green
