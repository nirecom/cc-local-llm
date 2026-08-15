#Requires -Version 5.1
# ccgw client launcher (Windows). Every client reaches the backends through the Mac
# LiteLLM gateway; the direct DS4 Proxy route is retired, so there is exactly one path
# and nothing to fall back to. An unconfigured base URL or credential is therefore an
# error rather than a dummy default -- a dummy default only defers the failure to a
# confusing 401 at request time. Isolates the VS Code process so the env does not bleed
# into native subscription windows.
# Rationale: docs/architecture.md; procedure: docs/ops.md#client-windows.
#
# POSIX counterpart: scripts/code-ccgw.sh. The two resolve the base URL, the auth token,
# the CA and the model tiers identically. They differ where the platform forces it: the
# VS Code profile path and the launch itself -- the POSIX script execs VS Code, this one
# stays resident as its parent because PowerShell has no exec.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error while
# ErrorActionPreference is Stop. Neither `mkcert -CAROOT` failing nor VS Code's own exit
# code should abort this launcher, so that conversion is switched off where it exists.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# Format: KEY=value, one per line, # comment lines allowed. A value already set in
# the shell takes precedence over .env. See .env.example for the supported keys.
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

# Writes to stderr without the Write-Error machinery, so the message shape is the
# launcher's own and the exit code stays under this script's control.
function Write-LauncherError([string]$Message) {
    [Console]::Error.WriteLine("[code-ccgw] $Message")
}

# Clear any real Anthropic API key so the local backend is used instead. Assigning an
# empty string removes the variable on Windows rather than exporting an empty one; both
# read as "no key" to the client.
$env:ANTHROPIC_API_KEY = ''

# --- Base URL --------------------------------------------------------------
# The LiteLLM gateway is the only endpoint.
$BaseUrl = Get-EnvOrNull 'LITELLM_ANTHROPIC_BASE_URL'
if ($null -eq $BaseUrl) {
    Write-LauncherError 'ERROR: LITELLM_ANTHROPIC_BASE_URL is not set.'
    Write-LauncherError 'Set it to the LiteLLM gateway endpoint; see docs/ops.md.'
    exit 1
}
$env:ANTHROPIC_BASE_URL = $BaseUrl

# --- Authentication --------------------------------------------------------
# LiteLLM runs without a database, so no virtual keys exist: the client credential is
# the gateway key itself. LITELLM_VIRTUAL_KEY is accepted for one deprecation cycle so
# an unmigrated .env fails loudly rather than with a 401.
$ClientKey = Get-EnvOrNull 'LITELLM_CLIENT_KEY'
$LegacyKey = Get-EnvOrNull 'LITELLM_VIRTUAL_KEY'
if ($null -ne $ClientKey) {
    $env:ANTHROPIC_AUTH_TOKEN = $ClientKey
} elseif ($null -ne $LegacyKey) {
    Write-Warning '[code-ccgw] LITELLM_VIRTUAL_KEY is deprecated; rename it to LITELLM_CLIENT_KEY.'
    $env:ANTHROPIC_AUTH_TOKEN = $LegacyKey
} else {
    Write-LauncherError 'ERROR: LITELLM_CLIENT_KEY is not set.'
    Write-LauncherError 'Set it to the LiteLLM gateway key; see docs/ops.md.'
    exit 1
}

# --- TLS trust -------------------------------------------------------------
# Point Node at the mkcert local CA root so it trusts the gateway certificate.
# NODE_TLS_REJECT_UNAUTHORIZED=0 is deliberately NOT used.
$CaCert = Get-EnvOrNull 'CCGW_CA_CERT'
if ($null -ne $CaCert) {
    $env:NODE_EXTRA_CA_CERTS = $CaCert
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
# Each LITELLM_*_MODEL is a LiteLLM routing key and goes onto its own /model tier
# verbatim. The launcher owns no backend names: inventing one would address a model the
# gateway has no entry for, and the error would surface as a 400 from LiteLLM rather
# than as a message from here.
$FableModel = Get-EnvOrNull 'LITELLM_FABLE_MODEL'
if ($null -ne $FableModel) { $env:ANTHROPIC_DEFAULT_FABLE_MODEL = $FableModel }
$OpusModel = Get-EnvOrNull 'LITELLM_OPUS_MODEL'
if ($null -ne $OpusModel) { $env:ANTHROPIC_DEFAULT_OPUS_MODEL = $OpusModel }
$SonnetModel = Get-EnvOrNull 'LITELLM_SONNET_MODEL'
if ($null -ne $SonnetModel) { $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $SonnetModel }
$HaikuModel = Get-EnvOrNull 'LITELLM_HAIKU_MODEL'
if ($null -ne $HaikuModel) { $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $HaikuModel }
if ($null -ne $FableModel) {
    $env:ANTHROPIC_MODEL = $FableModel
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION = $FableModel
}

# Subagent routing is opt-in. LiteLLM multiplexes, so pinning every subagent to one tier
# is no longer needed -- and an unconditional value silently overrides the model an
# agent definition's frontmatter declares. The value is a routing key, passed through
# untranslated.
$SubagentModel = Get-EnvOrNull 'CCGW_SUBAGENT_MODEL'
if ($null -ne $SubagentModel) { $env:CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel }

$env:ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = 'Local model via ccgw'
$env:ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = 'Mac backend via the LiteLLM gateway, selected per request'

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
    Write-LauncherError "ERROR: 'code' command not found on PATH."
    Write-LauncherError "In VS Code run: Shell Command: Install 'code' command in PATH"
    exit 1
}
# LOCALAPPDATA is always set on Windows, but a stripped service environment (or pwsh on
# another OS) would otherwise make Join-Path throw here, after all the work is done.
$appData = if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { Join-Path (Join-Path $HOME '.local') 'share' } else { $env:LOCALAPPDATA }
& code --user-data-dir (Join-Path $appData 'vscode-ccgw') @args
