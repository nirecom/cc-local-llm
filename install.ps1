# cc-local-llm installer for Windows (client + LiteLLM proxy)
# Usage: .\install.ps1
# Mac-side (ds4-server / Laguna S 2.1 / llama-swap) setup uses install.sh instead.

if ($IsWindows -eq $false) {
    Write-Host "Error: install.ps1 must not run on Linux/macOS. Use install.sh instead." -ForegroundColor Red
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$RepoRoot = $PSScriptRoot

Write-Host "=== cc-local-llm installer (Windows) ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- Installing Docker Desktop ---"
& "$RepoRoot\install\win\docker-desktop.ps1"

Write-Host ""
Write-Host "--- Installing mkcert ---"
& "$RepoRoot\install\win\mkcert.ps1"

Write-Host ""
Write-Host "--- Setting up .env ---"
$EnvPath = "$RepoRoot\.env"
if (Test-Path $EnvPath) {
    Write-Host ".env already exists -- leaving it as-is." -ForegroundColor DarkGray
} else {
    Copy-Item "$RepoRoot\.env.example" $EnvPath
    Write-Host "Created .env from .env.example -- fill in CCGW_ANTHROPIC_BASE_URL / CCGW_API_KEY / CCGW_CA_CERT (and the LITELLM_* vars if routing through LiteLLM)." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Remaining steps are interactive (TLS cert issuance, LiteLLM master key, container startup)"
Write-Host "and are documented in docs/ops.md#run-the-proxy-mac and docs/ops.md#litellm-windows-docker-desktop-wsl2."
