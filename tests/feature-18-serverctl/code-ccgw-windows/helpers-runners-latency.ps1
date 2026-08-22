#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite. Dot-sourced from its top-level
# BeforeAll, after helpers-runners.ps1 (whose Set-ChildEnvBlock and dump parsers
# it uses): the runner that measures how long the launcher takes to come back.
# Definitions only.
#
# It lives in its own file rather than in helpers-runners.ps1 because that file
# had reached the 300-line split threshold, and this runner is a self-contained
# third way of running the launcher -- neither of the other two can time it.

# --- responsiveness runner (issue #66) --------------------------------------
# Invoke-Launcher cannot measure how long the launcher takes to return, for a
# reason that has nothing to do with the launcher: it reads the launcher's stdout
# to the end, and a GRANDCHILD that inherited that pipe holds it open for as long
# as it lives. Against a deliberately long-lived `code` stub the read alone would
# block, whatever the launcher did. This runner therefore redirects the launcher's
# streams to a FILE from inside a one-line wrapper -- a file handle an inherited
# grandchild cannot stall on -- and times the launcher process itself.
$script:LatencyWrapperBody = @'
param(
    [string]$LauncherPath,
    [string]$OutFile,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$LauncherArgs = @()
)
if ($LauncherArgs.Count -gt 0) { & $LauncherPath @LauncherArgs *> $OutFile } else { & $LauncherPath *> $OutFile }
if ($null -eq $LASTEXITCODE) { exit 0 }
exit $LASTEXITCODE
'@

# Starts the launcher against the long-lived stub and reports how long the
# launcher took to come back. The stub is released as soon as the measurement is
# taken, so a launcher that DOES block still ends the case in seconds instead of
# waiting out the stub's own safety cap.
function Measure-LauncherLaunch {
    param(
        [hashtable]$Environment = @{},
        [string[]]$Arguments = @(),
        [string]$StubDir = $script:StubLongLived,
        [string]$LauncherPath = $script:Launcher,
        [int]$BudgetMs = 10000
    )

    $dump = Join-Path $script:Work 'latency.env.dump'
    $argvFile = Join-Path $script:Work 'latency.argv.dump'
    $outFile = Join-Path $script:Work 'latency.out.txt'
    $started = Join-Path $script:Work 'latency.started.txt'
    $stop = Join-Path $script:Work 'latency.stop.txt'
    Remove-Item -LiteralPath $dump, $argvFile, $outFile, $started, $stop -Force -ErrorAction SilentlyContinue

    $childEnv = @{}
    foreach ($k in $Environment.Keys) { $childEnv[$k] = $Environment[$k] }
    $childEnv['CCGW_TEST_STARTED'] = $started
    $childEnv['CCGW_TEST_STOP'] = $stop

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshPath
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $script:LatencyWrapper, $LauncherPath, $outFile) + $Arguments) {
        $psi.ArgumentList.Add([string]$a)
    }
    # Deliberately NOT redirected here; the wrapper above owns the redirection.
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $script:Work
    Set-ChildEnvBlock -Psi $psi -Environment $childEnv -StubDir $StubDir -DumpPath $dump -ArgvPath $argvFile

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $exitedInBudget = $proc.WaitForExit($BudgetMs)
    $sw.Stop()

    # Release the stub whatever the verdict, then let the launcher finish so the
    # next case starts from a quiet machine.
    [System.IO.File]::WriteAllText($stop, 'stop')
    if (-not $exitedInBudget) {
        if (-not $proc.WaitForExit(90000)) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit(10000) | Out-Null
        }
    } else {
        # The launcher is fire-and-forget: it starts the stub child and returns
        # well before that long-lived child has necessarily finished writing its
        # own $started/$dump/$argvFile files. Waiting for the LAUNCHER process to
        # exit (above) says nothing about whether the CHILD has reached that
        # point yet, so reading the marker files immediately here races the
        # child's own writes -- intermittently reporting Reached=$false / an
        # empty Argv even though the child would have written them a few
        # milliseconds later. Poll briefly for $started (and, once that shows the
        # child is alive, for $dump/$argvFile) before trusting their presence.
        # This only firms up the artifact-existence observation; ElapsedMs and
        # ExitedWithinBudget above already captured the launcher's own
        # responsiveness and are untouched by this wait.
        $pollBudget = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $started) -and $pollBudget.ElapsedMilliseconds -lt 3000) {
            Start-Sleep -Milliseconds 50
        }
        if (Test-Path -LiteralPath $started) {
            while ((-not (Test-Path -LiteralPath $dump) -or -not (Test-Path -LiteralPath $argvFile)) -and $pollBudget.ElapsedMilliseconds -lt 3000) {
                Start-Sleep -Milliseconds 50
            }
        }
    }

    return [pscustomobject]@{
        ExitedWithinBudget = $exitedInBudget
        ElapsedMs          = [int]$sw.ElapsedMilliseconds
        BudgetMs           = $BudgetMs
        StubStarted        = (Test-Path -LiteralPath $started)
        Reached            = (Test-Path -LiteralPath $dump)
        Argv               = (ConvertFrom-ArgvDump -Path $argvFile).Argv
        Env                = ConvertFrom-SetDump -Path $dump
        Output             = if (Test-Path -LiteralPath $outFile) { [System.IO.File]::ReadAllText($outFile) } else { '' }
    }
}
