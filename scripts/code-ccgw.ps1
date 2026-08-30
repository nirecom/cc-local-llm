#Requires -Version 5.1
# ccgw client launcher (Windows). Every client reaches the backends through the Mac
# LiteLLM gateway; the direct CCGW Proxy route is retired, so there is exactly one path
# and nothing to fall back to. An unconfigured base URL or credential is therefore an
# error rather than a dummy default -- a dummy default only defers the failure to a
# confusing 401 at request time. Because PowerShell has no exec, this script never writes
# any ccgw/LiteLLM value into its own process's $env:; every such value is collected and
# injected only into the launched VS Code child process's environment block, so the
# invoking shell's environment is left untouched and nothing bleeds into a later native
# subscription session started from that same shell (issue #66).
# Rationale: docs/architecture.md; procedure: docs/ops.md#client-windows.
#
# POSIX counterpart: scripts/code-ccgw.sh. The two resolve the base URL, the auth token,
# the CA and the model tiers identically. They differ where the platform forces it: the
# VS Code profile path and the launch itself -- the POSIX script execs VS Code, this one
# has no exec to hand off to, so it stays resident as the child's parent and passes the
# environment through the child's process environment block instead of its own.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error while
# ErrorActionPreference is Stop. Neither `mkcert -CAROOT` failing nor VS Code's own exit
# code should abort this launcher, so that conversion is switched off where it exists.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

# Strips #@if <token> / #@endif blocks. Must stay behaviorally identical to
# agents/hooks/lib/load-env.js's filterOsBlocks() state machine
# (docs/env-conditional-blocks.md is the SSOT spec both follow).
function ConvertFrom-OsConditionalLines {
    param([string[]]$Lines, [string]$ActiveToken)
    $depth = 0
    $suppressing = $false
    $suppressDepth = 0
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $Lines) {
        $stripped = $raw.TrimEnd("`r")
        $line = $stripped.Trim()
        if ($line -like '#@if *') {
            $depth++
            $token = $line.Substring(5).Trim()
            if (-not $suppressing -and $token -ne $ActiveToken) { $suppressing = $true; $suppressDepth = $depth }
            continue
        }
        if ($line -eq '#@endif') {
            if ($depth -gt 0) {
                if ($suppressing -and $depth -eq $suppressDepth) { $suppressing = $false }
                $depth--
            }
            continue
        }
        if ($line.StartsWith('#@')) { continue }
        if (-not $suppressing) { $out.Add($stripped) }
    }
    return $out
}

# All values destined for the launched VS Code process are collected here and applied
# only to that child process's environment block (ProcessStartInfo.Environment) -- never
# to this script's own $env:, which would leak into the invoking shell and into every
# later session started from it. PowerShell has no exec, so this is the only way to avoid
# that leak (issue #66). Ordered so the overlay is applied in the order it was resolved.
$ChildEnv = [ordered]@{}
function Set-ChildEnv([string]$Name, [string]$Value) {
    $ChildEnv[$Name] = $Value
}

# Reads the effective value of a variable, treating defined-but-empty as unset. A value
# already collected for the child wins over the ambient process env, so every consumer
# below reads back exactly what the child will receive.
function Get-EnvOrNull([string]$Name) {
    if ($ChildEnv.Contains($Name)) {
        $collected = $ChildEnv[$Name]
        if ([string]::IsNullOrEmpty($collected)) { return $null }
        return $collected
    }
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $null }
    return $v
}

# Writes to stderr without the Write-Error machinery, so the message shape is the
# launcher's own and the exit code stays under this script's control.
function Write-LauncherError([string]$Message) {
    [Console]::Error.WriteLine("[code-ccgw] $Message")
}

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# Format: KEY=value, one per line, # comment lines allowed. A value already set in
# the shell takes precedence over .env -- EXCEPT for $ModelRoutingKeys, which must
# always come from .env so a stale inherited shell value (e.g. an old
# LITELLM_OPUS_MODEL from a previous launch) can never override the repo's intent.
# See .env.example for the supported keys.
# .env may also carry #@if windows / #@if posix / #@endif blocks (docs/env-conditional-blocks.md).
$EnvFile = Join-Path (Join-Path $PSScriptRoot '..') '.env'
$ModelRoutingKeys = @('LITELLM_HAIKU_MODEL', 'LITELLM_SONNET_MODEL', 'LITELLM_FABLE_MODEL', 'LITELLM_OPUS_MODEL', 'CCGW_SUBAGENT_MODEL')
if (Test-Path -LiteralPath $EnvFile) {
    $IsWindowsPlatform = if (Test-Path variable:IsWindows) { $IsWindows } else { $true }
    $ActiveToken = if ($IsWindowsPlatform) { 'windows' } else { 'posix' }
    $filteredLines = ConvertFrom-OsConditionalLines -Lines (Get-Content -LiteralPath $EnvFile) -ActiveToken $ActiveToken
    # Keys already claimed by an earlier line of this same .env, so a later duplicate
    # cannot overwrite them (matches scripts/lib/load-dotenv.sh: first occurrence wins).
    # The POSIX sibling gets this for free by exporting as it goes; here the collected
    # values never touch the process env, so the rule needs its own record.
    $claimedKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in $filteredLines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        $key = $trimmed.Substring(0, $split).Trim()
        $value = $trimmed.Substring($split + 1).Trim()
        # Shell value wins, but only when non-empty: a defined-but-empty variable is
        # indistinguishable from an unset one for every consumer below, so treating it
        # as "already set" would silently discard the .env value. Model-routing keys
        # are the exception: they always take the .env value (see $ModelRoutingKeys).
        # This check deliberately reads the raw process env: the rule it enforces is
        # about the value the invoking shell really carries. Reading is safe -- only
        # writing to this process is what issue #66 forbids.
        if ($claimedKeys.Contains($key)) { continue }
        if (-not ($ModelRoutingKeys -contains $key) -and -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) { continue }
        [void]$claimedKeys.Add($key)
        Set-ChildEnv $key $value
    }
}

# Credentials and routing switches that must never reach the child. The child talks to
# exactly one endpoint -- the local LiteLLM gateway -- so any cloud/subscription
# credential presented to it would either be forwarded onto the gateway's egress path or
# redirect the child away from the gateway entirely. Whatever the invoking shell happens
# to carry is therefore removed from the child's environment block rather than merely
# left unset (an inherited value would otherwise pass straight through the overlay).
# An empty collected value is what performs the removal; the invoking shell's own
# variables are never read, cleared, or copied. Adding to the class is a one-line change.
$StrippedCredentialVars = @(
    # Cloud API / subscription credentials for the Anthropic-compatible client.
    'ANTHROPIC_API_KEY',
    'CLAUDE_CODE_OAUTH_TOKEN',
    # Provider switches: either would send the child's traffic somewhere other than the
    # gateway, past every setting resolved below.
    'CLAUDE_CODE_USE_BEDROCK',
    'CLAUDE_CODE_USE_VERTEX',
    # Credentials those providers would pick up.
    'AWS_ACCESS_KEY_ID',
    'AWS_SECRET_ACCESS_KEY',
    'AWS_SESSION_TOKEN',
    'AWS_PROFILE',
    'AWS_REGION',
    'GOOGLE_APPLICATION_CREDENTIALS',
    # TLS verification is pinned on: the gateway's certificate is trusted through
    # NODE_EXTRA_CA_CERTS below, so an inherited NODE_TLS_REJECT_UNAUTHORIZED=0 (common
    # while debugging other tools) would silently disable verification for no gain.
    'NODE_TLS_REJECT_UNAUTHORIZED'
)
foreach ($stripped in $StrippedCredentialVars) { Set-ChildEnv $stripped '' }

# --- Base URL --------------------------------------------------------------
# The LiteLLM gateway is the only endpoint.
$BaseUrl = Get-EnvOrNull 'LITELLM_ANTHROPIC_BASE_URL'
if ($null -eq $BaseUrl) {
    Write-LauncherError 'ERROR: LITELLM_ANTHROPIC_BASE_URL is not set.'
    Write-LauncherError 'Set it to the LiteLLM gateway endpoint; see docs/ops.md.'
    exit 1
}
Set-ChildEnv 'ANTHROPIC_BASE_URL' $BaseUrl

# --- Authentication --------------------------------------------------------
# LiteLLM runs without a database, so no virtual keys exist: the client credential is
# the gateway key itself. LITELLM_VIRTUAL_KEY is accepted for one deprecation cycle so
# an unmigrated .env fails loudly rather than with a 401.
$ClientKey = Get-EnvOrNull 'LITELLM_CLIENT_KEY'
$LegacyKey = Get-EnvOrNull 'LITELLM_VIRTUAL_KEY'
if ($null -ne $ClientKey) {
    Set-ChildEnv 'ANTHROPIC_AUTH_TOKEN' $ClientKey
} elseif ($null -ne $LegacyKey) {
    Write-Warning '[code-ccgw] LITELLM_VIRTUAL_KEY is deprecated; rename it to LITELLM_CLIENT_KEY.'
    Set-ChildEnv 'ANTHROPIC_AUTH_TOKEN' $LegacyKey
} else {
    Write-LauncherError 'ERROR: LITELLM_CLIENT_KEY is not set.'
    Write-LauncherError 'Set it to the LiteLLM gateway key; see docs/ops.md.'
    exit 1
}

# --- TLS trust -------------------------------------------------------------
# Point Node at the mkcert local CA root so it trusts the gateway certificate.
# NODE_TLS_REJECT_UNAUTHORIZED=0 is deliberately NOT used -- and an inherited one is
# stripped from the child above ($StrippedCredentialVars), so it cannot arrive by accident.
$CaCert = Get-EnvOrNull 'CCGW_CA_CERT'
if ($null -ne $CaCert) {
    Set-ChildEnv 'NODE_EXTRA_CA_CERTS' $CaCert
} else {
    $caroot = $null
    if (Get-Command mkcert -ErrorAction SilentlyContinue) {
        # When this host issued the cert the CA is already local -- derive it rather
        # than making the user restate a path the tool can answer for itself.
        $caroot = (& mkcert -CAROOT 2>$null | Select-Object -First 1)
    }
    if ($caroot -and (Test-Path -LiteralPath (Join-Path $caroot 'rootCA.pem'))) {
        Set-ChildEnv 'NODE_EXTRA_CA_CERTS' (Join-Path $caroot 'rootCA.pem')
    } else {
        Write-Warning '[code-ccgw] CCGW_CA_CERT not set; TLS certificate will not be trusted.'
    }
}

# --- Model aliases ---------------------------------------------------------
# Each LITELLM_*_MODEL is a LiteLLM routing key and goes onto its own /model tier
# verbatim. The launcher owns no backend names: inventing one would address a model the
# gateway has no entry for, and the error would surface as a 400 from LiteLLM rather
# than as a message from here.
# Absence of a source key means "the child must not have the derived variable at all",
# never "keep whatever the invoking shell happened to carry": a leftover
# ANTHROPIC_DEFAULT_OPUS_MODEL would otherwise pin a tier the repo's .env no longer
# names. Hence every conditional set has an explicit clearing else branch.
$FableModel = Get-EnvOrNull 'LITELLM_FABLE_MODEL'
if ($null -ne $FableModel) { Set-ChildEnv 'ANTHROPIC_DEFAULT_FABLE_MODEL' $FableModel }
else { Set-ChildEnv 'ANTHROPIC_DEFAULT_FABLE_MODEL' '' }
$OpusModel = Get-EnvOrNull 'LITELLM_OPUS_MODEL'
if ($null -ne $OpusModel) { Set-ChildEnv 'ANTHROPIC_DEFAULT_OPUS_MODEL' $OpusModel }
else { Set-ChildEnv 'ANTHROPIC_DEFAULT_OPUS_MODEL' '' }
$SonnetModel = Get-EnvOrNull 'LITELLM_SONNET_MODEL'
if ($null -ne $SonnetModel) { Set-ChildEnv 'ANTHROPIC_DEFAULT_SONNET_MODEL' $SonnetModel }
else { Set-ChildEnv 'ANTHROPIC_DEFAULT_SONNET_MODEL' '' }
$HaikuModel = Get-EnvOrNull 'LITELLM_HAIKU_MODEL'
if ($null -ne $HaikuModel) { Set-ChildEnv 'ANTHROPIC_DEFAULT_HAIKU_MODEL' $HaikuModel }
else { Set-ChildEnv 'ANTHROPIC_DEFAULT_HAIKU_MODEL' '' }
# ANTHROPIC_MODEL never reaches the child: it outranks the `model` setting in the user's
# settings.json, so any value here silently discards the tier chosen there -- an opus
# session would still start on fable, with nothing in the client to say why. Cleared
# unconditionally, since an inherited value reintroduces the same override.
Set-ChildEnv 'ANTHROPIC_MODEL' ''

# The picker entry is additive: it offers the fable tier, it does not choose the startup one.
if ($null -ne $FableModel) { Set-ChildEnv 'ANTHROPIC_CUSTOM_MODEL_OPTION' $FableModel }
else { Set-ChildEnv 'ANTHROPIC_CUSTOM_MODEL_OPTION' '' }

# Subagent routing is opt-in. LiteLLM multiplexes, so pinning every subagent to one tier
# is no longer needed -- and an unconditional value silently overrides the model an
# agent definition's frontmatter declares. The value is a routing key, passed through
# untranslated.
$SubagentModel = Get-EnvOrNull 'CCGW_SUBAGENT_MODEL'
if ($null -ne $SubagentModel) { Set-ChildEnv 'CLAUDE_CODE_SUBAGENT_MODEL' $SubagentModel }
else { Set-ChildEnv 'CLAUDE_CODE_SUBAGENT_MODEL' '' }

Set-ChildEnv 'ANTHROPIC_CUSTOM_MODEL_OPTION_NAME' 'Local model via ccgw'
Set-ChildEnv 'ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION' 'Mac backend via the LiteLLM gateway, selected per request'

Set-ChildEnv 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' '1'
Set-ChildEnv 'CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK' '1'
Set-ChildEnv 'CLAUDE_STREAM_IDLE_TIMEOUT_MS' '600000'

# Align auto-compaction with the tightest backend ceiling. A single env var cannot
# differentiate per-tier, so this is the floor over every routed tier -- measured, not
# assumed: 100k runs on the Windows sonnet/haiku backend at 1335 tok/s prefill and
# 22.7 decode, and the Mac opus tier reaches ~115k with APC on. The 75% below is what
# actually reaches a backend, so 76,800.
Set-ChildEnv 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' '102400'
Set-ChildEnv 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' '75'

# Launch VS Code in an isolated process. A distinct --user-data-dir starts a separate
# VS Code instance; VS Code otherwise shares one process (and one environment) across
# all windows of a user-data-dir, which would leak this env into native windows.
# Application-only resolution: a function/alias/script named "code" would not be a real
# executable Process.Start can launch.
# The indexing must be guarded rather than done inline: under Set-StrictMode -Version
# Latest, [0] on the empty array Get-Command returns when "code" is absent throws a
# terminating index-out-of-bounds error before the intended message below can run.
$codeCmdMatches = @(Get-Command code -CommandType Application -ErrorAction SilentlyContinue)
$codeCmd = if ($codeCmdMatches.Count -gt 0) { $codeCmdMatches[0] } else { $null }
if (-not $codeCmd) {
    Write-LauncherError "ERROR: 'code' command not found on PATH."
    Write-LauncherError "In VS Code run: Shell Command: Install 'code' command in PATH"
    exit 1
}

# LOCALAPPDATA is always set on Windows, but a stripped service environment (or pwsh on
# another OS) would otherwise make Join-Path throw here, after all the work is done.
$appData = if ([string]::IsNullOrEmpty($env:LOCALAPPDATA)) { Join-Path (Join-Path $HOME '.local') 'share' } else { $env:LOCALAPPDATA }
$codeArgs = @('--user-data-dir', (Join-Path $appData 'vscode-ccgw')) + $args

# The resolved "code" command is a .cmd on every real install (VS Code ships code.cmd),
# and Win32 CreateProcess() implicitly re-invokes cmd.exe to interpret .cmd/.bat targets
# (the "BatBadBut" vulnerability class). CommandLineToArgvW-style quoting, which is
# correct for .exe targets, does NOT protect against cmd.exe metacharacters like
# &,|,^,<,>,% -- those need a separate, cmd.exe-specific escaping scheme. Both branches
# are kept (rather than assuming .cmd) so an .exe-resolved "code" in some other
# environment is still handled correctly (CPR-UNV).
$ext = [System.IO.Path]::GetExtension($codeCmd.Source)
$isBatchTarget = ($ext -ieq '.cmd') -or ($ext -ieq '.bat')

# Formats a single argument per CommandLineToArgvW quoting rules, for direct (non-cmd.exe)
# process launches.
function ConvertTo-ArgvQuotedArgument([string]$Arg) {
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $backslashes = 0
        while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $backslashes++; $i++ }
        if ($i -eq $Arg.Length) {
            [void]$sb.Append('\' * ($backslashes * 2))
            break
        } elseif ($Arg[$i] -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $backslashes)
            [void]$sb.Append($Arg[$i])
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()

if ($isBatchTarget) {
    # cmd.exe will re-parse the command line regardless of what we pass, so every
    # argument must be escaped for cmd.exe's own grammar (the BatBadBut-recommended
    # recipe), not just for CommandLineToArgvW: double embedded quotes, double a
    # run of backslashes immediately before a quote, replace % (percent expansion)
    # with a self-referential substring expansion that always yields a literal %, and
    # wrap the whole argument in quotes. An embedded newline cannot be escaped at all
    # -- cmd.exe truncates its command line at the first newline and would silently run
    # only part of it, so that case is rejected before the launch instead of being
    # passed through partially.
    foreach ($a in $codeArgs) {
        if ($a -match "`r|`n") {
            Write-LauncherError "ERROR: an argument to 'code' contains a newline, which cmd.exe cannot pass through safely."
            exit 1
        }
    }

    # Backslash doubling and quote doubling must happen in one left-to-right pass:
    # CommandLineToArgvW doubles a backslash run only where it immediately precedes a
    # quote (or the closing quote), so doubling quotes first and then patching only a
    # trailing backslash run misses every run before an interior quote and lets the
    # parser run past the argument boundary. The % pass stays separate -- it does not
    # interact with backslash/quote escaping.
    function ConvertTo-BatchSafeArgument([string]$Arg) {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $Arg.Length; $i++) {
            $backslashes = 0
            while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $backslashes++; $i++ }
            if ($i -eq $Arg.Length) {
                [void]$sb.Append('\' * ($backslashes * 2))
                break
            } elseif ($Arg[$i] -eq '"') {
                [void]$sb.Append('\' * ($backslashes * 2))
                [void]$sb.Append('""')
            } else {
                [void]$sb.Append('\' * $backslashes)
                [void]$sb.Append($Arg[$i])
            }
        }
        $s = $sb.ToString()
        # %%cd:~,% expands to a literal % followed by the empty substring of %CD%, so a
        # % in the value can never start an expansion of its own -- a caret cannot
        # escape %, and percent expansion runs before caret processing anyway.
        $s = $s.Replace('%', '%%cd:~,%')
        return '"' + $s + '"'
    }
    function ConvertTo-BatchSafeCommandLine([string]$TargetPath, [string[]]$Arguments) {
        $parts = @((ConvertTo-BatchSafeArgument $TargetPath))
        foreach ($a in $Arguments) { $parts += (ConvertTo-BatchSafeArgument $a) }
        return ($parts -join ' ')
    }

    $comSpec = [Environment]::GetEnvironmentVariable('ComSpec')
    if ([string]::IsNullOrEmpty($comSpec)) { $comSpec = Join-Path $env:SystemRoot 'System32\cmd.exe' }
    $psi.FileName = $comSpec
    $inner = ConvertTo-BatchSafeCommandLine -TargetPath $codeCmd.Source -Arguments $codeArgs
    # /d disables AutoRun registry-key code injection; /v:off disables delayed
    # expansion so embedded !...! sequences in an argument cannot be misinterpreted;
    # /s enables the documented cmd.exe /C behavior where, when the text following
    # /C starts and ends with a quote, only that single outer quote pair is stripped
    # and the remainder is not reinterpreted -- which is what makes wrapping $inner
    # in one quote pair here mean what ConvertTo-BatchSafeCommandLine intended.
    $psi.Arguments = '/d /s /v:off /c "' + $inner + '"'
} else {
    $psi.FileName = $codeCmd.Source
    $psi.Arguments = ($codeArgs | ForEach-Object { ConvertTo-ArgvQuotedArgument $_ }) -join ' '
}

# cmd.exe stops reading its command line at roughly 8191 characters and truncates the
# rest silently rather than failing, so a too-long argument list would open a path that
# ends mid-word. The launch is fire-and-forget and never sees cmd.exe's exit code, so
# the only place that can still catch this is here, before the launch. The ceiling
# belongs to the cmd.exe route alone -- a direct .exe launch is bounded by
# CreateProcess's far larger 32767 instead.
if ($isBatchTarget) {
    $CmdExeCommandLineLimit = 8191
    # The command line CreateProcess assembles is the quoted FileName, a space, then
    # Arguments -- hence the three characters added to the two lengths.
    $commandLineLength = $psi.FileName.Length + 3 + $psi.Arguments.Length
    if ($commandLineLength -gt $CmdExeCommandLineLimit) {
        Write-LauncherError "ERROR: the command line is too long for cmd.exe ($commandLineLength characters; the limit is $CmdExeCommandLineLimit)."
        Write-LauncherError "Pass fewer or shorter arguments to 'code'."
        exit 1
    }
}

# UseShellExecute must be false for both Arguments and Environment to be honored at all,
# and a shell-execute launch would additionally re-introduce a shell to re-parse what was
# just escaped.
$psi.UseShellExecute = $false
$psi.WorkingDirectory = if ($PWD.Provider.Name -eq 'FileSystem') { $PWD.ProviderPath } else { [Environment]::CurrentDirectory }

# $psi.Environment starts pre-populated with this process's own (inherited) environment;
# only the collected ccgw/LiteLLM values are overlaid on top of it, so the child still
# inherits everything else -- PATH, LOCALAPPDATA, ... -- as it would with a plain
# `& code` call. An empty collected value means "the child must not have this variable
# at all", which is how ANTHROPIC_API_KEY is kept away from Claude Code without the
# invoking shell's own key ever being touched.
foreach ($name in @($ChildEnv.Keys)) {
    if ([string]::IsNullOrEmpty($ChildEnv[$name])) { [void]$psi.Environment.Remove($name) }
    else { $psi.Environment[$name] = $ChildEnv[$name] }
}

# Fire-and-forget: `code` without --wait hands the folder to the running VS Code instance
# and returns at once, and this launcher must behave the same -- waiting would tie the
# editor's lifetime to the console it was started from and hold the developer's prompt.
# Only the failure to start is this script's to report.
try {
    [void][System.Diagnostics.Process]::Start($psi)
} catch {
    Write-LauncherError "ERROR: failed to launch '$($codeCmd.Source)': $($_.Exception.Message)"
    exit 1
}
exit 0
