# Requires PowerShell 7+: Invoke-RestMethod -SkipCertificateCheck does not exist in 5.1.
#Requires -Version 7.0
# litellm one-time setup (Windows). Run once after the LiteLLM container is running.
# Generates a virtual key (random, NOT reusing the master key) and registers it.
# Procedure: docs/ops.md#litellm-setup.
#
# IMPORTANT: LiteLLM requires PostgreSQL for key generation. The compose file starts a
# bundled postgres service and passes DATABASE_URL; /key/generate fails until postgres
# passes its healthcheck and LiteLLM has created its tables. Wait a few seconds after
# container start.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error while
# ErrorActionPreference is Stop; the container check below reads $LASTEXITCODE itself.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

# Load repo-root .env. A value already set in the shell takes precedence.
$EnvFile = Join-Path (Join-Path $PSScriptRoot '..') '.env'
if (Test-Path -LiteralPath $EnvFile) {
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        $key = $trimmed.Substring(0, $split).Trim()
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) { continue }
        Set-Item -Path "env:$key" -Value $trimmed.Substring($split + 1).Trim()
    }
}

if ([string]::IsNullOrEmpty($env:LITELLM_MASTER_KEY)) {
    Write-Error @'
[setup-litellm] LITELLM_MASTER_KEY is not set in .env.
[setup-litellm] Run: pwsh -NoProfile -File scripts\generate-litellm-key.ps1
[setup-litellm] Then set LITELLM_MASTER_KEY=sk-<output> in .env
'@
    exit 1
}

$port = if ([string]::IsNullOrEmpty($env:LITELLM_PORT)) { '8445' } else { $env:LITELLM_PORT }

# Step 1: Verify the LiteLLM container is running.
& docker container inspect ccgw-litellm --format '{{.State.Status}}' *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error @'
[setup-litellm] LiteLLM container 'ccgw-litellm' is not running.
[setup-litellm] Run scripts\litellm-start.ps1 up first.
'@
    exit 1
}

# Step 2: Generate a random virtual key, then register it with LiteLLM.
# IMPORTANT: Do NOT send the master key as the generated key value. The /key/generate
# endpoint creates a scoped virtual key from a NEW random key, not the master key itself.
# Sending the master key as the "key" value would create a virtual key that IS the master
# key -- defeating the purpose of scoped virtual keys.
Write-Host '[setup-litellm] Generating random virtual key...'
$randomHex = & (Join-Path $PSScriptRoot 'generate-litellm-key.ps1')
if ([string]::IsNullOrWhiteSpace($randomHex)) {
    Write-Error '[setup-litellm] Generated key is empty.'
    exit 1
}
$virtualKey = "sk-$($randomHex.Trim())"

# POST to /key/generate. The response JSON carries the registered key.
# The proxy answers on loopback with its own mkcert leaf, whose SAN may be the LAN IP
# rather than localhost, so the check is skipped for this one local admin call.
Write-Host '[setup-litellm] Registering key with LiteLLM...'
$body = @{ key = $virtualKey; metadata = @{ scopes = @('*') } } | ConvertTo-Json -Depth 4
$headers = @{ 'x-api-key' = $env:LITELLM_MASTER_KEY }
$response = Invoke-RestMethod -Method Post -Uri "https://localhost:$port/key/generate" -Headers $headers -ContentType 'application/json' -Body $body -SkipCertificateCheck
$response | ConvertTo-Json -Depth 6

Write-Host '[setup-litellm] ---'
Write-Host '[setup-litellm] IMPORTANT: Copy the "key" value from the JSON response above'
Write-Host '[setup-litellm] and set it as LITELLM_VIRTUAL_KEY in your .env file.'
Write-Host "[setup-litellm] Example: LITELLM_VIRTUAL_KEY=$virtualKey"
Write-Host '[setup-litellm] ---'
