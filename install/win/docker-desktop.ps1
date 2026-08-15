# docker-desktop.ps1 - Install Docker Desktop (runs the LiteLLM container via WSL2)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "Docker is already installed: $(docker --version)" -ForegroundColor DarkGray
    return
}

Write-Host "Installing Docker Desktop..."
winget install Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
if ($LASTEXITCODE -ne 0) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Host "Docker already present (winget returned $LASTEXITCODE)." -ForegroundColor DarkGray
    } else {
        Write-Warning "Docker Desktop installation failed (exit code $LASTEXITCODE). Re-run install.ps1 to retry."
        exit 1
    }
} else {
    Write-Host "Docker Desktop installed. Launch it once and enable WSL2 integration before continuing." -ForegroundColor Green
}
