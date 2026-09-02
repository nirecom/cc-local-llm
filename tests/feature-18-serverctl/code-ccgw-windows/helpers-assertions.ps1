#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite. Dot-sourced from its top-level
# BeforeAll: the assertions the Contexts share. Definitions only.

function Assert-LauncherEnv {
    param($Result, [string]$Name, [string]$Expected, [string]$Context)
    if (-not $Result.Reached) {
        throw "$Context`: stub 'code' was never reached (no env dump); stderr: $($Result.StdErr)"
    }
    if (-not $Result.Env.ContainsKey($Name)) {
        throw "$Context`: $Name was not exported at all (expected '$Expected')"
    }
    if ($Result.Env[$Name] -cne $Expected) {
        throw "$Context`: $Name='$($Result.Env[$Name])', expected '$Expected'"
    }
}

function Assert-LauncherEnvUnset {
    param($Result, [string]$Name, [string]$Context)
    # The launcher's own contract treats defined-but-empty as unset, and .NET
    # drops an env var assigned '' on Windows -- so either shape counts.
    if ($Result.Env.ContainsKey($Name) -and -not [string]::IsNullOrEmpty($Result.Env[$Name])) {
        throw "$Context`: $Name was exported as '$($Result.Env[$Name])' but must not be set at all"
    }
}

function Assert-LauncherEnvDiffers {
    param($Result, [string]$A, [string]$B, [string]$Context)
    if ($Result.Env[$A] -ceq $Result.Env[$B]) {
        throw "$Context`: $A and $B both resolved to '$($Result.Env[$A])'; the two tiers must stay on separate routing keys"
    }
}

# For messages the launcher writes itself through Write-LauncherError, i.e.
# [Console]::Error -- genuinely stderr on every host, so this stays strict.
function Assert-Stderr {
    param($Result, [string]$Pattern, [string]$Context)
    if ($Result.StdErr -notmatch [regex]::Escape($Pattern)) {
        throw "$Context`: expected stderr to contain '$Pattern', got: $($Result.StdErr)"
    }
}

# For messages the launcher emits through Write-Warning. Which stream the warning
# stream lands on when redirected is the HOST's decision, not the launcher's --
# pwsh 7.6 writes it to stdout, other hosts have written it to stderr -- so
# pinning one stream here asserts a property of the PowerShell build rather than
# of the launcher (CPR-UNV: no implicit branch on the environment). The contract
# that matters is that the operator is told.
function Assert-LauncherWarning {
    param($Result, [string]$Pattern, [string]$Context)
    $combined = [string]$Result.StdErr + [string]$Result.StdOut
    if ($combined -notmatch [regex]::Escape($Pattern)) {
        throw "$Context`: expected a warning containing '$Pattern', got stderr: $($Result.StdErr) / stdout: $($Result.StdOut)"
    }
}

function Assert-NoCaWarning {
    param($Result, [string]$Context)
    $combined = [string]$Result.StdErr + [string]$Result.StdOut
    if ($combined -match 'CCGW_CA_CERT not set') {
        throw "$Context`: unexpected CA warning: $combined"
    }
}

# --- invoking-shell assertions (issue #66) ----------------------------------

# Every name whose value differs between two environment snapshots, rendered for
# a failure message. Stated as a whole-snapshot diff rather than as a list of
# forbidden names: a variable nobody thought to enumerate is exactly the one a
# future assignment would leak (CPR-UNV).
function Get-EnvSnapshotDiff {
    param([hashtable]$Before, [hashtable]$After)
    $diff = New-Object System.Collections.Generic.List[string]
    foreach ($k in (@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)) {
        $b = if ($Before.ContainsKey($k)) { $Before[$k] } else { '<absent>' }
        $a = if ($After.ContainsKey($k)) { $After[$k] } else { '<absent>' }
        if ($b -cne $a) { $diff.Add("$k : '$b' -> '$a'") }
    }
    return $diff
}

# The zero-pollution contract, applied to one parent-shell run. Used by the happy
# path (8a) and by every failure path (8g-8j): a launcher that gives up halfway
# through is exactly where a half-applied environment would be left behind.
function Assert-ParentEnvUnchanged {
    param($Result, [string]$Context)
    if ($Result.BeforeEnv.Count -eq 0) {
        throw "$Context`: the wrapper wrote no before-snapshot; stderr: $($Result.StdErr)"
    }
    if ($Result.AfterEnv.Count -eq 0) {
        throw "$Context`: the wrapper did not survive the launch; stderr: $($Result.StdErr)"
    }
    $diff = Get-EnvSnapshotDiff -Before $Result.BeforeEnv -After $Result.AfterEnv
    if ($diff.Count -ne 0) {
        throw "$Context`: the launcher must not write to the shell that invoked it; changed: $($diff -join '; ')"
    }
}

# No secret in anything the operator (or CI log) sees. The credential is the one
# secret the launcher handles; a diagnostic that echoes it would put it into
# terminal scrollback and CI logs (OWASP ASVS V8). Asserted on the failure paths
# too, because an error message is precisely where a value gets echoed back "to
# help".
function Assert-NoSecretInOutput {
    param($Result, [string[]]$Secrets, [string]$Context)
    $combined = [string]$Result.StdOut + [string]$Result.StdErr
    foreach ($s in $Secrets) {
        if ([string]::IsNullOrEmpty($s)) { continue }
        if ($combined -match [regex]::Escape($s)) {
            throw "$Context`: the credential '$s' appeared in the launcher's output: $combined"
        }
    }
}

# The terminal is only the copy the operator watches go past. git and the
# launcher both write scratch under TEMP -- lock files, error reports, spooled
# output -- and a credential kept out of stderr but left in one of those has
# leaked into a file that OUTLIVES the run: onto a shared box, into a backup,
# into the next search someone runs over %TEMP%. The caller hands over a
# directory it created empty, so every file found here was written by that run.
# The file NAMES are swept too: git derives temp names from what it was handed.
function Assert-NoSecretInTree {
    param([string]$Path, [string[]]$Secrets, [string]$Context)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $text = try { [System.IO.File]::ReadAllText($file.FullName) } catch { '' }
        foreach ($s in $Secrets) {
            if ([string]::IsNullOrEmpty($s)) { continue }
            if ($file.FullName -match [regex]::Escape($s)) {
                throw "$Context`: the credential '$s' appears in the NAME of $($file.FullName)"
            }
            if ($text -match [regex]::Escape($s)) {
                throw "$Context`: the credential '$s' was written into $($file.FullName)"
            }
        }
    }
}

# The third copy is the one nobody clears. A failing fetch writes FETCH_HEAD,
# reflogs and its own error reports INSIDE .git/, and that directory is handed on
# with the checkout: into every archive, backup and copy taken of it, long after
# %TEMP% has been emptied. POSIX sibling: git_state_hits in
# code-ccgw-auto-pull/fixture.sh (CPR-ORTH). `config` and `config.worktree` are
# the only exclusions -- the remote URL is in them because the operator put it
# there with `git remote set-url`, so that copy is their own record rather than a
# spill, which is why the caller is expected to prove the secret is still IN one
# of them and to plant a probe elsewhere under .git/ before trusting a silence.
function Assert-NoSecretInGitState {
    param([string]$RepoPath, [string[]]$Secrets, [string]$Context)
    $gitDir = Join-Path $RepoPath '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        throw "$Context`: $gitDir does not exist, so this sweep would pass over nothing at all"
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $gitDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        foreach ($s in $Secrets) {
            if ([string]::IsNullOrEmpty($s)) { continue }
            if ($file.Name -match [regex]::Escape($s)) {
                throw "$Context`: the credential '$s' appears in the NAME of $($file.FullName), which travels with the checkout"
            }
            if ($file.Name -in @('config', 'config.worktree')) { continue }
            $text = try { [System.IO.File]::ReadAllText($file.FullName) } catch { '' }
            if ($text -match [regex]::Escape($s)) {
                throw "$Context`: the credential '$s' was written into $($file.FullName), which travels with the checkout"
            }
        }
    }
}

# "No child was launched" -- the other half of a refusal. A refusal that has
# already started VS Code is not a refusal.
function Assert-NoChildLaunched {
    param($Result, [string]$Context)
    if ($Result.Reached) {
        throw "$Context`: a child process was launched even though the launcher had to refuse"
    }
}
