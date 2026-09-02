#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced from its top-level
# BeforeAll: two of the three ways this suite runs the launcher (the third,
# Measure-LauncherLaunch, is in helpers-runners-latency.ps1), the shared
# environment-block builder, and the dump parsers. The child's environment block
# is cleared and rebuilt so an ambient LITELLM_*/CCGW_* value in the dev's shell
# cannot satisfy an assertion by accident, nor a real mkcert fake "no mkcert".
# Shared by every runner, so "cleared and rebuilt" is stated once (CPR-SSOT).
function Set-ChildEnvBlock {
    param(
        $Psi,
        [hashtable]$Environment = @{},
        [string]$StubDir = $script:StubDir,
        [string]$DumpPath,
        [string]$ArgvPath,
        [string]$ExeMarkerPath,
        [switch]$NoLocalAppData,
        [switch]$NoAutoPullDefault
    )
    $Psi.Environment.Clear()
    $Psi.Environment['PATH'] = $StubDir
    $Psi.Environment['CCGW_TEST_DUMP'] = $DumpPath
    $Psi.Environment['CCGW_TEST_ARGV'] = $ArgvPath
    if ($ExeMarkerPath) { $Psi.Environment['CCGW_TEST_EXE_MARKER'] = $ExeMarkerPath }
    if (-not $NoLocalAppData) { $Psi.Environment['LOCALAPPDATA'] = $script:LocalAppData }
    $Psi.Environment['TEMP'] = $script:Work
    $Psi.Environment['TMP'] = $script:Work
    $Psi.Environment['TMPDIR'] = $script:Work
    $Psi.Environment['HOME'] = $script:Work
    $Psi.Environment['USERPROFILE'] = $script:Work
    # .ps1 must stay a discoverable command extension for the stubs above, and
    # .CMD must precede it so a Windows run resolves `code` the way a real VS Code
    # install does.
    $Psi.Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD;.PS1'
    # Auto-pull is on by default in the launcher (issue #89), which would make
    # every case in this suite reach for a git remote. Off is the default HERE, so
    # only the cases that are about pulling opt back in via -Environment.
    # -NoAutoPullDefault omits the key entirely, which is the only way to ask
    # "where does the launcher READ the switch from" -- a process-env value, even
    # the matching one, would answer the question before the .env is opened.
    if (-not $NoAutoPullDefault) { $Psi.Environment['CCGW_AUTO_PULL'] = 'off' }
    foreach ($passthrough in @('SystemRoot', 'ComSpec', 'windir')) {
        $v = [Environment]::GetEnvironmentVariable($passthrough)
        if ($v) { $Psi.Environment[$passthrough] = $v }
    }
    foreach ($k in $Environment.Keys) {
        $Psi.Environment[[string]$k] = [string]$Environment[$k]
    }
}

# Reads a dump file as UTF-8 explicitly. Every writer in this suite emits UTF-8 --
# File.WriteAllLines from the .ps1 and .exe stubs, `set`/`echo` under the code
# page the .cmd stub pins to 65001 -- so decoding it as anything else would make
# a non-ASCII assertion a property of the developer's locale (CPR-UNV).
function Read-DumpLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
}

# Parses the `NAME=value` env dump every stub writes. A line whose '=' sits at
# index 0 is `set`'s rendering of a cmd-internal variable (=C:, =ExitCode) and is
# not an inheritable variable at all.
function ConvertFrom-SetDump {
    param([string]$Path)
    $map = @{}
    foreach ($line in (Read-DumpLines -Path $Path)) {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$line.Substring(0, $i)] = $line.Substring($i + 1)
    }
    return $map
}

function ConvertFrom-ArgvDump {
    param([string]$Path)
    $argv = @()
    $cwd = $null
    foreach ($line in (Read-DumpLines -Path $Path)) {
        if ($line -match '^ARG="(.*)"$') { $argv += $Matches[1] }
        elseif ($line -match '^CWD=(.*)$') { $cwd = $Matches[1] }
    }
    return [pscustomobject]@{ Argv = $argv; Cwd = $cwd }
}

function Invoke-Launcher {
    param(
        [hashtable]$Environment = @{},
        [string[]]$Arguments = @(),
        [string]$StubDir = $script:StubDir,
        [string]$LauncherPath = $script:Launcher,
        [string]$WorkingDirectory = $script:Work,
        [switch]$NoLocalAppData,
        [switch]$NoAutoPullDefault
    )

    $dump = Join-Path $script:Work 'env.dump'
    $argvFile = Join-Path $script:Work 'argv.dump'
    $marker = Join-Path $script:Work 'exe-launch-marker.txt'
    Remove-Item -LiteralPath $dump, $argvFile, $marker -Force -ErrorAction SilentlyContinue

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshPath
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $LauncherPath) + $Arguments) {
        $psi.ArgumentList.Add([string]$a)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $WorkingDirectory
    Set-ChildEnvBlock -Psi $psi -Environment $Environment -StubDir $StubDir `
        -DumpPath $dump -ArgvPath $argvFile -ExeMarkerPath $marker -NoLocalAppData:$NoLocalAppData `
        -NoAutoPullDefault:$NoAutoPullDefault

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(60000)) {
        try { $proc.Kill($true) } catch { }
        throw "launcher did not exit within 60s"
    }

    $parsed = ConvertFrom-ArgvDump -Path $argvFile
    return [pscustomobject]@{
        ExitCode  = $proc.ExitCode
        StdOut    = $stdout
        StdErr    = $stderr
        Env       = ConvertFrom-SetDump -Path $dump
        Argv      = $parsed.Argv
        Cwd       = $parsed.Cwd
        Reached   = (Test-Path -LiteralPath $dump)
        ExeMarker = (Test-Path -LiteralPath $marker)
    }
}

# --- invoking-shell runner (issue #66) --------------------------------------
# Invoke-Launcher above can never see this suite's target bug: it inspects
# the CHILD's environment, and the leak is in the PARENT's. This runner
# inserts a wrapper script playing the interactive shell -- it snapshots its
# own process environment, calls the launcher with `&` (a child SCOPE not a
# PROCESS, so every `$env:` assignment stays exactly as in the invoking
# pwsh), and snapshots again; the child dump still shows values reached VS
# Code too. `exit` inside a `&`-called script ends that script, not the
# wrapper, so the after-snapshot is written on failure paths too, letting
# 8g-8j be asserted here ($LASTEXITCODE records the launcher's own exit code separately).
$script:ParentShellWrapperBody = @'
param(
    [string]$LauncherPath,
    [string]$BeforeFile,
    [string]$AfterFile,
    [string]$ExitFile,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LauncherArgs = @()
)
function Save-CcgwEnvSnapshot([string]$Path) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($e in Get-ChildItem env:) { $lines.Add($e.Name + '=' + $e.Value) }
    [System.IO.File]::WriteAllLines($Path, $lines)
}
Save-CcgwEnvSnapshot $BeforeFile
$launcherExit = 'NONE'
try {
    if ($LauncherArgs.Count -gt 0) { & $LauncherPath @LauncherArgs } else { & $LauncherPath }
    $launcherExit = [string]$LASTEXITCODE
} catch {
    [Console]::Error.WriteLine('[wrapper] ' + $_.Exception.Message)
    $launcherExit = 'THREW'
}
Save-CcgwEnvSnapshot $AfterFile
[System.IO.File]::WriteAllText($ExitFile, $launcherExit)
'@

function Invoke-LauncherInParentShell {
    param(
        [hashtable]$Environment = @{},
        [string[]]$Arguments = @(),
        [string]$StubDir = $script:StubDir,
        [string]$LauncherPath = $script:Launcher
    )

    $dump = Join-Path $script:Work 'parent.env.dump'
    $argvFile = Join-Path $script:Work 'parent.argv.dump'
    $beforeFile = Join-Path $script:Work 'parent.before.dump'
    $afterFile = Join-Path $script:Work 'parent.after.dump'
    $exitFile = Join-Path $script:Work 'parent.exit.dump'
    $marker = Join-Path $script:Work 'parent.exe-launch-marker.txt'
    Remove-Item -LiteralPath $dump, $argvFile, $beforeFile, $afterFile, $exitFile, $marker `
        -Force -ErrorAction SilentlyContinue

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshPath
    $wrapperArgs = @('-NoProfile', '-NonInteractive', '-File', $script:ParentShellWrapper,
        $LauncherPath, $beforeFile, $afterFile, $exitFile) + $Arguments
    foreach ($a in $wrapperArgs) { $psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $script:Work
    Set-ChildEnvBlock -Psi $psi -Environment $Environment -StubDir $StubDir `
        -DumpPath $dump -ArgvPath $argvFile -ExeMarkerPath $marker

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(60000)) {
        try { $proc.Kill($true) } catch { }
        throw "parent-shell wrapper did not exit within 60s"
    }

    $launcherExit = if (Test-Path -LiteralPath $exitFile) {
        [System.IO.File]::ReadAllText($exitFile).Trim()
    } else { 'NONE' }

    return [pscustomobject]@{
        ExitCode         = $proc.ExitCode
        LauncherExitCode = $launcherExit
        StdOut           = $stdout
        StdErr           = $stderr
        Env              = ConvertFrom-SetDump -Path $dump
        Argv             = (ConvertFrom-ArgvDump -Path $argvFile).Argv
        BeforeEnv        = ConvertFrom-SetDump -Path $beforeFile
        AfterEnv         = ConvertFrom-SetDump -Path $afterFile
        Reached          = (Test-Path -LiteralPath $dump)
    }
}
