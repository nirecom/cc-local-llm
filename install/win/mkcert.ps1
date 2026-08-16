# mkcert.ps1 - Install mkcert (local TLS CA), used to sign the CCGW Proxy and LiteLLM certs

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command mkcert -ErrorAction SilentlyContinue) {
    Write-Host "mkcert is already installed: $(mkcert -version)" -ForegroundColor DarkGray
    return
}

Write-Host "Installing mkcert..."
winget install FiloSottile.mkcert --accept-source-agreements --accept-package-agreements
if ($LASTEXITCODE -ne 0) {
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        Write-Host "mkcert already present (winget returned $LASTEXITCODE)." -ForegroundColor DarkGray
    } else {
        Write-Warning "mkcert installation failed (exit code $LASTEXITCODE). Re-run install.ps1 to retry."
        exit 1
    }
} else {
    Write-Host "mkcert installed: $(mkcert -version)" -ForegroundColor Green
}
