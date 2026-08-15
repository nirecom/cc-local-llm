#Requires -Version 5.1
# ccgw client launcher (Windows). Prefers the LiteLLM gateway (ccgw) for Claude Code
# model routing; falls back to the DS4 Proxy direct connection when LiteLLM is
# unavailable. Isolates the VS Code process so the env does not bleed into native
# subscription windows. Rationale: docs/architecture.md; procedure: docs/ops.md#client-windows.
#
# POSIX counterpart: scripts/code-ccgw.sh. The two resolve the base URL, the auth token,
# the CA and the model tiers identically. They differ where the platform forces it: the
# VS Code profile path, the fallback base URL, and the launch itself -- the POSIX script
# execs VS Code, this one stays resident as its parent because PowerShell has no exec.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error while
# ErrorActionPreference is Stop. Neither `mkcert -CAROOT` failing nor VS Code's own exit
# code should abort this launcher, so that conversion is switched off where it exists.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# Format: KEY=value, one per line, # comment lines allowed. A value already set in
# the shell takes precedence over .env, matching what the retired .cmd did with
# `if not defined`. See .env.example for the supported keys.
$EnvFile = Join-Path (Join-Path $PSScriptRoot '..') '.env'
if (Test-Path -LiteralPath $EnvFile) {
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        $key = $trimmed.Substring(0, $split).Trim()
        $value = $trimmed.Substring($split + 1).Trim()
        # Shell value wins, but only when non-empty: a defined-but-empty variable is
        # indistinguishable from an unset one for every consumer below, so treating it
        # as "already set" would silently discard the .env value.
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) { continue }
        Set-Item -Path "env:$key" -Value $value
    }
}

# Reads an env var, treating defined-but-empty as unset.
function Get-EnvOrNull([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $null }
    return $v
}

# Clear any real Anthropic API key so the local backend is used instead. Assigning an
# empty string removes the variable on Windows rather than exporting an empty one; both
# read as "no key" to the client.
$env:ANTHROPIC_API_KEY = ''

# --- Base URL --------------------------------------------------------------
# LiteLLM's TLS endpoint when configured, else the DS4 Proxy path.
if ($null -ne (Get-EnvOrNull 'LITELLM_ANTHROPIC_BASE_URL')) {
    $env:ANTHROPIC_BASE_URL = $env:LITELLM_ANTHROPIC_BASE_URL
} elseif ($null -ne (Get-EnvOrNull 'CCGW_ANTHROPIC_BASE_URL')) {
    $env:ANTHROPIC_BASE_URL = $env:CCGW_ANTHROPIC_BASE_URL
} elseif ($null -ne (Get-EnvOrNull 'DS4_ANTHROPIC_BASE_URL')) {
    $env:ANTHROPIC_BASE_URL = $env:DS4_ANTHROPIC_BASE_URL
} else {
    Write-Warning '[code-ccgw] Neither LITELLM_ANTHROPIC_BASE_URL nor CCGW_ANTHROPIC_BASE_URL set.'
    # 8445, not the .sh's 8443: a Windows client normally reaches the Mac through the
    # LiteLLM gateway on this same PC, not through the Mac's proxy directly.
    $env:ANTHROPIC_BASE_URL = 'https://localhost:8445'
}

# --- Authentication --------------------------------------------------------
# Use a scoped LiteLLM virtual key, NOT the master key. Falls back to the DS4
# Proxy's own shared token for the direct path.
if ($null -ne (Get-EnvOrNull 'LITELLM_VIRTUAL_KEY')) {
    $env:ANTHROPIC_AUTH_TOKEN = $env:LITELLM_VIRTUAL_KEY
} elseif ($null -ne (Get-EnvOrNull 'CCGW_API_KEY')) {
    $env:ANTHROPIC_AUTH_TOKEN = $env:CCGW_API_KEY
} elseif ($null -ne (Get-EnvOrNull 'DS4_API_KEY')) {
    $env:ANTHROPIC_AUTH_TOKEN = $env:DS4_API_KEY
} else {
    Write-Warning '[code-ccgw] Neither LITELLM_VIRTUAL_KEY nor CCGW_API_KEY set.'
    $env:ANTHROPIC_AUTH_TOKEN = 'dsv4-local'
}

# --- TLS trust -------------------------------------------------------------
# Point Node at the mkcert local CA root so it trusts the proxy certificate.
# NODE_TLS_REJECT_UNAUTHORIZED=0 is deliberately NOT used.
if ($null -ne (Get-EnvOrNull 'CCGW_CA_CERT')) {
    $env:NODE_EXTRA_CA_CERTS = $env:CCGW_CA_CERT
} elseif ($null -ne (Get-EnvOrNull 'DS4_CA_CERT')) {
    $env:NODE_EXTRA_CA_CERTS = $env:DS4_CA_CERT
} else {
    $caroot = $null
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        # When this host issued the cert the CA is already local -- derive it rather
        # than making the user restate a path the tool can answer for itself.
        $caroot = (& mkcert -CAROOT 2>$null | Select-Object -First 1)
    }
    if ($caroot -and (Test-Path -LiteralPath (Join-Path $caroot 'rootCA.pem'))) {
        $env:NODE_EXTRA_CA_CERTS = Join-Path $caroot 'rootCA.pem'
    } else {
        Write-Warning '[code-ccgw] CCGW_CA_CERT not set; TLS certificate will not be trusted.'
    }
}

# --- Model aliases ---------------------------------------------------------
# LITELLM_*_MODEL are LiteLLM-specific routing keys that DS4 Proxy does not
# recognise -- never send them down the direct path. On the direct path the model
# name is what the Mac swap layer routes on, so it must be a name that layer knows
# (see llama-swap/config.yaml): deepseek-v4-flash or laguna-s-2.1.
#
# The two Mac backends sit on separate tiers so /model can switch between them:
# fable -> ds4, opus -> Laguna S 2.1. Subagents follow whichever backend is resident
# rather than the Opus tier -- a subagent on the other backend would evict it.
if ($null -ne (Get-EnvOrNull 'LITELLM_ANTHROPIC_BASE_URL')) {
    if ($null -ne (Get-EnvOrNull 'LITELLM_FABLE_MODEL')) { $env:ANTHROPIC_DEFAULT_FABLE_MODEL = $env:LITELLM_FABLE_MODEL }
    if ($null -ne (Get-EnvOrNull 'LITELLM_OPUS_MODEL')) { $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $env:LITELLM_OPUS_MODEL }
    if ($null -ne (Get-EnvOrNull 'LITELLM_SONNET_MODEL')) { $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $env:LITELLM_SONNET_MODEL }
    if ($null -ne (Get-EnvOrNull 'LITELLM_HAIKU_MODEL')) { $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $env:LITELLM_HAIKU_MODEL }
    if ($null -ne (Get-EnvOrNull 'LITELLM_FABLE_MODEL')) {
        $env:ANTHROPIC_MODEL = $env:LITELLM_FABLE_MODEL
        $env:ANTHROPIC_CUSTOM_MODEL_OPTION = $env:LITELLM_FABLE_MODEL
        $env:CLAUDE_CODE_SUBAGENT_MODEL = $env:LITELLM_FABLE_MODEL
    }
} else {
    # Direct path: the swap layer routes on the model name itself, so the tiers can
    # name the two backends outright. CCGW_DEFAULT_MODEL only picks which one is
    # resident at startup.
    $env:ANTHROPIC_DEFAULT_FABLE_MODEL = 'deepseek-v4-flash'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'laguna-s-2.1'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'deepseek-v4-flash'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'deepseek-v4-flash'

    $model = Get-EnvOrNull 'CCGW_DEFAULT_MODEL'
    if ($null -eq $model) { $model = 'deepseek-v4-flash' }
    $env:ANTHROPIC_MODEL = $model
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION = $model
    $env:CLAUDE_CODE_SUBAGENT_MODEL = $model
}
$env:ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = 'Local model via ccgw'
$env:ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = 'Mac backend (ds4 / Laguna S 2.1), selected per request'

$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
$env:CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = '1'
$env:CLAUDE_STREAM_IDLE_TIMEOUT_MS = '600000'

# Align auto-compaction with the tightest backend ceiling (64K for Qwen on this PC).
# The Mac backends compact earlier than necessary but do not error. A single env var
# cannot differentiate per-tier -- 64K is the safe floor.
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = '65536'
$env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = '75'

# Launch VS Code in an isolated process. A distinct --user-data-dir starts a separate
# VS Code instance; VS Code otherwise shares one process (and one environment) across
# all windows of a user-data-dir, which would leak this env into native windows.
if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
    Write-Error "[code-ccgw] 'code' command not found on PATH. In VS Code run: Shell Command: Install 'code' command in PATH"
    exit 1
}
# LOCALAPPDATA is always set on Windows, but a stripped service environment (or pwsh on
# another OS) would otherwise make Join-Path throw here, after all the work is done.
$appData = if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { Join-Path $HOME '.local\share' } else { $env:LOCALAPPDATA }
& code --user-data-dir (Join-Path $appData 'vscode-ccgw') @args
