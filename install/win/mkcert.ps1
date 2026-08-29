# mkcert.ps1 - Install mkcert (local TLS CA), used to sign the CCGW Proxy and LiteLLM certs
#
# winget and mkcert run through Invoke-Native for the same reason every other native
# command here does: $ErrorActionPreference does not turn their non-zero exits into
# errors. -1978335189 (0x8A15002B) is winget's "already installed", which is success.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

. "$PSScriptRoot\lib\native.ps1"

if (Get-Command mkcert -ErrorAction SilentlyContinue) {
    Write-Host "mkcert is already installed: $((Get-Command mkcert).Source)" -ForegroundColor DarkGray
    return
}

Write-Host "Installing mkcert..."
Invoke-Native -FilePath 'winget' `
    -Arguments @('install', '--exact', '--id', 'FiloSottile.mkcert', '--accept-source-agreements', '--accept-package-agreements') `
    -AllowExitCodes (-1978335189) `
    -Context 'mkcert installation via winget'

if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    throw "mkcert is still not on PATH after winget reported success. Open a new shell (winget updates PATH for new processes only) and re-run .\install.ps1."
}

Write-Host "mkcert installed: $((Get-Command mkcert).Source)" -ForegroundColor Green
