#Requires -Version 5.1
# ccgw client launcher (Windows). Every client reaches the backends through the Mac
# LiteLLM gateway; an unconfigured base URL or credential is an error rather than a
# dummy default, which would only defer the failure to a confusing 401.
# PowerShell has no exec, so no ccgw/LiteLLM value is ever written into this
# process's own $env: -- each is collected and injected only into the launched VS
# Code child's environment block, leaving the invoking shell untouched (issue #66).
# POSIX counterpart: scripts/code-ccgw.sh. The two resolve the base URL, the auth
# token, the CA, the pre-launch pull and the tier map identically.
# Rationale: docs/architecture.md; procedure: docs/ops.md#client-windows.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ turns a non-zero native exit code into a terminating error while
# ErrorActionPreference is Stop. Neither `mkcert -CAROOT` failing nor VS Code's own
# exit code should abort this launcher, so that conversion is switched off.
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

# The same resolution WITHOUT the empty-is-unset rule, for a switch whose empty
# spelling is a deliberate "off" while "set nowhere at all" is a different answer.
function Get-RawEnvOrNull([string]$Name) {
    if ($ChildEnv.Contains($Name)) { return [string]$ChildEnv[$Name] }
    return [Environment]::GetEnvironmentVariable($Name)
}

# Written straight to stderr rather than through Write-Error, so the message shape is
# the launcher's own and the exit code stays under this script's control.
function Write-LauncherError([string]$Message) {
    [Console]::Error.WriteLine("[code-ccgw] $Message")
}
function Write-LauncherWarning([string]$Message) {
    [Console]::Error.WriteLine("[code-ccgw] WARNING: $Message")
}

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# Format: KEY=value, one per line, # comment lines allowed. A value already set in the
# shell takes precedence over .env. See .env.example for the supported keys.
# .env may also carry #@if windows / #@if posix / #@endif blocks (docs/env-conditional-blocks.md).
$OpsRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $OpsRoot '.env'
$ConfigFile = Join-Path (Join-Path $OpsRoot 'litellm-server') 'config.yaml'
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
        # as "already set" would silently discard the .env value. This check reads the
        # raw process env deliberately -- the rule it enforces is about the value the
        # invoking shell really carries. Reading is safe; only writing to this process
        # is what issue #66 forbids.
        if ($claimedKeys.Contains($key)) { continue }
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) { continue }
        [void]$claimedKeys.Add($key)
        Set-ChildEnv $key $value
    }
}

# --- Pre-launch update -----------------------------------------------------
# config.yaml is the routing map every host shares, so a backend swapped on one
# machine reaches this one only once the checkout does. This runs before every
# credential below on purpose: git inherits this process's environment, and the
# gateway credential has not been resolved into it yet.
#
# Absent from both the shell and .env means on -- a host that never opts in is the
# stale host this exists to prevent. Only `off` (or an explicitly empty value) turns
# it off silently; any other spelling is named back, since the operator believes it
# took effect.
function Test-CcgwPullEnabled {
    $switch = Get-RawEnvOrNull 'CCGW_AUTO_PULL'
    if ($null -eq $switch) { return $true }
    if ($switch -ceq 'on') { return $true }
    if ($switch -ceq 'off' -or $switch -eq '') { return $false }
    Write-LauncherWarning "CCGW_AUTO_PULL='$switch' is neither on nor off, so the pre-launch update stays off."
    return $false
}

# A whole process tree is terminated through a Win32 job object: `git fetch` spawns
# ssh or a credential helper, and a descendant whose parent has already exited is
# unreachable by every parent-walking tool. Compiled only on the path that actually
# runs git, so an opted-out launch pays nothing for it.
$CcgwJobApiSource = @'
using System;
using System.Runtime.InteropServices;
public static class CcgwJob {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@

$script:PullTimedOut = $false
$script:JobApiReady = $false
$script:GitExe = ''
$script:PullClock = $null
$CcgwPullBudgetMs = 20000
$CcgwGitCallMs = 12000
# Every argument is validated against this before it reaches git: CreateProcess
# re-invokes cmd.exe for a .cmd target, so a metacharacter in a branch name, a
# remote name or a ref would be re-parsed by a shell nobody asked for.
$CcgwGitTokenRe = '^[A-Za-z0-9][A-Za-z0-9._/-]*$'

# One git call, bounded, with its output captured rather than inherited. Captured
# because a remote URL may carry userinfo and git's own text must never reach the
# terminal; asynchronously because a descendant holding an inherited pipe would
# otherwise keep this launcher alive long after git itself had exited.
function Invoke-CcgwGit {
    param([string[]]$GitArgs)
    if ($script:PullClock.ElapsedMilliseconds -ge $CcgwPullBudgetMs) { $script:PullTimedOut = $true }
    if ($script:PullTimedOut) { return [pscustomobject]@{ Ok = $false; Out = '' } }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:GitExe
    $psi.Arguments = ($GitArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $OpsRoot
    # No credential prompt may open on an interactive launch path.
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $ok = $false
    $out = ''
    $job = [IntPtr]::Zero
    try {
        if ($script:JobApiReady) { $job = [CcgwJob]::CreateJobObjectW([IntPtr]::Zero, $null) }
        $proc = [System.Diagnostics.Process]::Start($psi)
        if ($job -ne [IntPtr]::Zero) { [void][CcgwJob]::AssignProcessToJobObject($job, $proc.Handle) }
        $proc.StandardInput.Close()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        [void]$proc.StandardError.ReadToEndAsync()
        if ($proc.WaitForExit($CcgwGitCallMs)) { $ok = ($proc.ExitCode -eq 0) }
        else { $script:PullTimedOut = $true }
        if ($job -ne [IntPtr]::Zero) { [void][CcgwJob]::TerminateJobObject($job, 1) }
        elseif (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        [void]$proc.WaitForExit(2000)
        if ($outTask.Wait(2000)) { $out = [string]$outTask.Result }
    } catch {
        $ok = $false
    } finally {
        if ($job -ne [IntPtr]::Zero) { [void][CcgwJob]::CloseHandle($job) }
    }
    return [pscustomobject]@{ Ok = $ok; Out = $out.Trim() }
}

# Resolves the upstream from the config fields rather than from `rev-parse
# --abbrev-ref @{u}`: a remote whose name contains a slash renders as `up/stream/main`
# there, which cannot be decoded back into its two halves. Both fields are plain text
# in .git/config, so each is validated before it reaches `git fetch`.
function Get-CcgwPullTarget {
    $branch = (Invoke-CcgwGit @('symbolic-ref', '--quiet', '--short', 'HEAD')).Out
    if ($script:PullTimedOut) { return $null }
    if ($branch -eq '' -or $branch -notmatch $CcgwGitTokenRe) {
        Write-LauncherWarning 'HEAD is detached, so the pre-launch pull had nowhere to pull from.'
        return $null
    }
    $remote = (Invoke-CcgwGit @('config', '--get', "branch.$branch.remote")).Out
    $ref = (Invoke-CcgwGit @('config', '--get', "branch.$branch.merge")).Out
    if ($script:PullTimedOut) { return $null }
    if ($remote -eq '' -or $ref -eq '') {
        Write-LauncherWarning "branch '$branch' has no upstream, so the pre-launch pull had nowhere to pull from."
        return $null
    }
    if ($remote -eq '.') {
        Write-LauncherWarning "branch '$branch' tracks a local branch, so there is no remote to pull from."
        return $null
    }
    if ($remote -notmatch $CcgwGitTokenRe -or $ref -cnotmatch '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref -match '\.\.') {
        Write-LauncherWarning "branch '$branch' has an upstream that is not a usable remote branch, so the pre-launch pull was skipped."
        return $null
    }
    return [pscustomobject]@{ Remote = $remote; Ref = $ref }
}

# Every failure path returns without raising: a pull problem must never cost the
# operator their client. Nothing here prints git's own output, and the only piece of
# the remote that is ever named back is its NAME.
function Invoke-CcgwPull {
    $target = Get-CcgwPullTarget
    if ($null -eq $target) { return }

    # Asked of the tree, not of the merge: `git merge --ff-only` succeeds over staged,
    # modified and untracked work that has nothing to do with the file it rewrites, and
    # walking over that is the worst outcome available here.
    $status = Invoke-CcgwGit @('status', '--porcelain')
    if ($script:PullTimedOut) { return }
    if (-not $status.Ok -or $status.Out -ne '') {
        Write-LauncherWarning 'the checkout has uncommitted changes, so the pull was skipped and this host may be stale.'
        return
    }

    if (-not (Invoke-CcgwGit @('fetch', '--quiet', $target.Remote, $target.Ref)).Ok) {
        if ($script:PullTimedOut) { return }
        Write-LauncherWarning "the pre-launch pull could not fetch from '$($target.Remote)'; continuing with the checkout as it stands."
        return
    }

    $head = (Invoke-CcgwGit @('rev-parse', 'HEAD')).Out
    $upstream = (Invoke-CcgwGit @('rev-parse', 'FETCH_HEAD')).Out
    if ($script:PullTimedOut) { return }
    if ($head -cnotmatch '^[0-9a-f]{7,64}$' -or $upstream -cnotmatch '^[0-9a-f]{7,64}$') {
        Write-LauncherWarning 'the pre-launch pull could not read what the remote is holding; continuing with the checkout as it stands.'
        return
    }
    # Already current, or merely holding commits nobody has published yet: both are the
    # ordinary shape of a working checkout, so both are silent.
    if ($head -eq $upstream) { return }
    if ((Invoke-CcgwGit @('merge-base', '--is-ancestor', $upstream, $head)).Ok) { return }
    if ($script:PullTimedOut) { return }
    if (-not (Invoke-CcgwGit @('merge-base', '--is-ancestor', $head, $upstream)).Ok) {
        if ($script:PullTimedOut) { return }
        Write-LauncherWarning 'the local and upstream histories have diverged, so nothing was merged; resolve it when convenient.'
        return
    }
    if (-not (Invoke-CcgwGit @('merge', '--ff-only', '--quiet', 'FETCH_HEAD')).Ok) {
        if ($script:PullTimedOut) { return }
        Write-LauncherWarning 'the pre-launch pull fetched but could not merge; continuing with the checkout as it stands.'
        return
    }
    Write-LauncherError "The checkout was brought up to date with $($target.Remote)."
}

# `.git` is asked for by name rather than through `rev-parse`, which walks UP: a copied
# tree sitting inside some unrelated repository would otherwise fast-forward a checkout
# that is not the gateway's. Array-indexed because a Git for Windows install puts git on
# PATH twice, and `.Source` on the two-element result is a single joined string.
if (Test-CcgwPullEnabled) {
    $gitMatches = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
    if (-not (Test-Path -LiteralPath (Join-Path $OpsRoot '.git'))) {
        Write-LauncherWarning "$OpsRoot is not a git checkout of its own, so the pre-launch update was skipped."
    } elseif ($gitMatches.Count -eq 0) {
        Write-LauncherWarning 'git was not found on PATH, so the pre-launch update was skipped.'
    } else {
        $script:GitExe = $gitMatches[0].Source
        $script:PullClock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if (-not ('CcgwJob' -as [type])) { Add-Type -TypeDefinition $CcgwJobApiSource }
            $script:JobApiReady = $true
        } catch { $script:JobApiReady = $false }
        Invoke-CcgwPull
        if ($script:PullTimedOut) {
            Write-LauncherWarning 'the pre-launch pull ran out of time; continuing with the checkout as it stands.'
        }
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
# The five keys below used to name the routing keys per host, which is how each machine
# ended up addressing whatever it was told about last. They configure nothing now, so a
# stale one is named back rather than ignored: an .env that reads as if it sets routing,
# and does not, is the same silence again.
foreach ($retired in @('LITELLM_HAIKU_MODEL', 'LITELLM_SONNET_MODEL', 'LITELLM_FABLE_MODEL',
        'LITELLM_OPUS_MODEL', 'CCGW_SUBAGENT_MODEL')) {
    if ($null -ne (Get-EnvOrNull $retired)) {
        Write-LauncherWarning "$retired no longer configures anything; the tier map moved into litellm-server/config.yaml."
    }
}

$CcgwTierNames = @('haiku', 'sonnet', 'fable', 'opus', 'subagent')
$script:TierOwner = @{}
$script:TierWarnings = New-Object System.Collections.Generic.List[string]

# One route's annotation payload. First claim of a tier wins, so a duplicate is a
# warning about the loser rather than a silent overwrite, and a token outside the
# closed vocabulary is named back instead of being routed nowhere.
function Add-CcgwTierTokens([string[]]$Tokens, [string]$RouteName) {
    foreach ($raw in $Tokens) {
        $tok = $raw.Trim()
        if ($tok -eq '') { continue }
        if ($CcgwTierNames -cnotcontains $tok) {
            $script:TierWarnings.Add("config.yaml: `"$tok`" is not a Claude Code tier (haiku, sonnet, fable, opus, subagent); ignored.")
            continue
        }
        if ($script:TierOwner.ContainsKey($tok)) {
            if ($script:TierOwner[$tok] -cne $RouteName) {
                $script:TierWarnings.Add("config.yaml: the $tok tier is claimed by both `"$($script:TierOwner[$tok])`" and `"$RouteName`"; the first one wins.")
            }
            continue
        }
        $script:TierOwner[$tok] = $RouteName
    }
}

# Line-oriented rather than YAML-aware, so that this reader, the POSIX awk one and the
# Python schema check can be held to the same two spellings byte for byte. Any
# `- model_name:` line closes the block above it, well-formed or not: a name outside the
# contract must take its own annotation out of play, never hand it to the route before
# it. An unindented non-empty line closes a block too; a blank line and an indented
# banner comment do not.
function Read-CcgwTierMap([string[]]$Lines) {
    $open = $false
    $current = ''
    $startIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i].TrimEnd("`r")
        if ($line.StartsWith('  - model_name:')) {
            $open = $false
            $rest = $line.Substring(15)
            $name = $rest.Trim()
            if ($rest -match '^[ ]+[^ \t]+[ ]*$' -and $name -match '^[A-Za-z0-9._-]+$') {
                $open = $true
                $current = $name
                $startIndex = $i
            } else {
                $script:TierWarnings.Add("config.yaml: model_name `"$name`" is outside the routing-name contract, so that route claims no tier.")
            }
            continue
        }
        if ($line -ne '' -and $line -notmatch '^[ \t]') { $open = $false; continue }
        if (-not $open) { continue }
        if ($line -cmatch '^      ccgw_tiers:[ ]*\[([^\]]*)\][ ]*$') {
            Add-CcgwTierTokens ($Matches[1] -split ',') $current
            continue
        }
        if ($i -eq $startIndex + 1 -and $line -cmatch '^    # ccgw-tiers:[ ]+(.+)$') {
            Add-CcgwTierTokens ($Matches[1] -split '[ \t]+') $current
        }
    }
}

# config.yaml is the single source of truth for which tier reaches which route: each
# route's annotation names the tiers it serves, and that route's model_name is the key
# those tiers address. The launcher owns no backend names of its own, and there is
# nothing to fall back to -- a client started with no tier map at all hands Claude Code
# an empty /model list, which reads as a puzzle much later.
$configLines = $null
if (Test-Path -LiteralPath $ConfigFile -PathType Leaf) {
    try { $configLines = [System.IO.File]::ReadAllLines($ConfigFile) } catch { $configLines = $null }
}
if ($null -eq $configLines) {
    Write-LauncherError "ERROR: cannot read $ConfigFile."
    Write-LauncherError 'It is the only source of the /model tier map; see docs/ops.md.'
    exit 1
}
Read-CcgwTierMap $configLines
foreach ($warning in $script:TierWarnings) { Write-LauncherWarning $warning }
if ($script:TierOwner.Count -eq 0) {
    Write-LauncherError "ERROR: no route in $ConfigFile carries a ccgw_tiers annotation."
    Write-LauncherError 'There is no /model tier map to launch with; see docs/ops.md.'
    exit 1
}

# An unmapped tier means "the child must not have the variable at all", never "keep
# whatever the invoking shell carried": a leftover value would pin a tier config.yaml no
# longer names, and an empty one hands Claude Code a /model entry that resolves nowhere.
# An empty collected value is what removes it from the child's block.
$TierRows = [ordered]@{
    haiku    = 'ANTHROPIC_DEFAULT_HAIKU_MODEL'
    sonnet   = 'ANTHROPIC_DEFAULT_SONNET_MODEL'
    fable    = 'ANTHROPIC_DEFAULT_FABLE_MODEL'
    opus     = 'ANTHROPIC_DEFAULT_OPUS_MODEL'
    subagent = 'CLAUDE_CODE_SUBAGENT_MODEL'
}
foreach ($tier in @($TierRows.Keys)) {
    if ($script:TierOwner.ContainsKey($tier)) { Set-ChildEnv $TierRows[$tier] $script:TierOwner[$tier] }
    else { Set-ChildEnv $TierRows[$tier] '' }
}
# The picker entry is additive: it offers the fable tier, it does not choose the startup one.
if ($script:TierOwner.ContainsKey('fable')) { Set-ChildEnv 'ANTHROPIC_CUSTOM_MODEL_OPTION' $script:TierOwner['fable'] }
else { Set-ChildEnv 'ANTHROPIC_CUSTOM_MODEL_OPTION' '' }

# ANTHROPIC_MODEL never reaches the child: it outranks the `model` setting in the user's
# settings.json, so any value here silently discards the tier chosen there -- an opus
# session would still start on fable, with nothing in the client to say why. Cleared
# unconditionally, since an inherited value reintroduces the same override.
Set-ChildEnv 'ANTHROPIC_MODEL' ''

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
# executable Process.Start can launch. The indexing must be guarded rather than done
# inline: under Set-StrictMode -Version Latest, [0] on the empty array Get-Command
# returns when "code" is absent throws before the intended message below can run.
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
