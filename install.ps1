# cc-local-llm installer for Windows (client only)
# The LiteLLM gateway now runs natively on the Mac, so this host needs client
# prerequisites only. Mac-side setup (gateway / ds4-server / Laguna S 2.1 /
# llama-swap) uses install.sh instead.
# Usage: .\install.ps1

if ($IsWindows -eq $false) {
    Write-Host "Error: install.ps1 must not run on Linux/macOS. Use install.sh instead." -ForegroundColor Red
    exit 1
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$RepoRoot = $PSScriptRoot

Write-Host "=== cc-local-llm installer (Windows, client) ===" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- Retiring obsolete Windows-side LiteLLM artifacts ---"
& "$RepoRoot\install\win\uninstall-obsolete.ps1"

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
    Write-Host "Created .env from .env.example -- fill in LITELLM_ANTHROPIC_BASE_URL / LITELLM_CLIENT_KEY / CCGW_CA_CERT." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Remaining steps are interactive (trusting the Mac's root CA, filling in the gateway key)"
Write-Host "and are documented in docs/ops.md#client-windows."
