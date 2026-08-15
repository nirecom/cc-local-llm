#Requires -Version 5.1
# litellm launcher (Windows). Starts/stops the LiteLLM Docker container
# for Claude Code model routing. Procedure: docs/ops.md#litellm.
#
# Usage:
#   litellm-start.ps1 up       -- start LiteLLM container
#   litellm-start.ps1 down     -- stop and remove LiteLLM container
#   litellm-start.ps1 restart  -- down then up
#   litellm-start.ps1 status   -- show container status
#   (no args)                  -- same as "up"

[CmdletBinding()]
param(
    [ValidateSet('up', 'down', 'restart', 'status')]
    [string]$Action = 'up'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error while
# ErrorActionPreference is Stop. This script inspects $LASTEXITCODE itself so it can
# explain what failed, so that conversion is switched off where the variable exists.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

# Repo-root .env (gitignored) — passed directly to docker compose via --env-file
# so that ${VAR} in docker-compose.yml is resolved without shell parsing.
$repoRoot = Join-Path $PSScriptRoot '..'
$EnvFile = Join-Path $repoRoot '.env'
$ComposeFile = Join-Path (Join-Path $repoRoot 'litellm-client') 'docker-compose.yml'

# docker compose reports failures through the exit code, so every call returns it for the
# caller to check. Compose's own output goes straight to the host rather than down the
# pipeline, which would otherwise be returned alongside the exit code.
function Invoke-Compose {
    & docker compose -f $ComposeFile --env-file $EnvFile @args | Out-Host
    return $LASTEXITCODE
}

switch ($Action) {
    'up' {
        Write-Host '[litellm] Starting LiteLLM container...'
        if ((Invoke-Compose up -d --force-recreate) -ne 0) {
            Write-Error '[litellm] docker compose up failed. Is Docker Desktop running?'
            exit 1
        }
        Write-Host '[litellm] LiteLLM container started. Verify: docs/ops.md#litellm-verify.'
        exit 0
    }
    'down' {
        Write-Host '[litellm] Stopping LiteLLM container...'
        if ((Invoke-Compose down) -ne 0) {
            Write-Warning '[litellm] docker compose down returned non-zero (container may not exist).'
            exit 1
        }
        Write-Host '[litellm] LiteLLM container stopped.'
        exit 0
    }
    'restart' {
        Write-Host '[litellm] Restarting LiteLLM container...'
        # down may legitimately fail when nothing is running -- only up decides the
        # outcome of a restart.
        [void](Invoke-Compose down)
        if ((Invoke-Compose up -d --force-recreate) -ne 0) {
            Write-Error '[litellm] restart failed.'
            exit 1
        }
        Write-Host '[litellm] LiteLLM container restarted.'
        exit 0
    }
    'status' {
        if ((Invoke-Compose ps) -ne 0) {
            Write-Host "[litellm] Container 'ccgw-litellm' does not exist or is not running."
        }
        exit 0
    }
}
