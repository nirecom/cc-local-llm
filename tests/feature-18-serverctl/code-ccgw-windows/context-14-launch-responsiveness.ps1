#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '14. The launch is fire-and-forget: the launcher does not wait for VS Code' -Skip:(-not $IsWindows) {
    # Every other stub exits in milliseconds, hiding one class of defect: a
    # launcher that WAITS for the process it started (`Start-Process -Wait`,
    # or .WaitForExit() with no timeout on the #66 ProcessStartInfo path)
    # leaves the developer's prompt hanging until they close the editor --
    # only a child outliving the measurement can tell. Fire-and-forget is the
    # contract: the launcher's job ends once VS Code owns the environment
    # (`code` returns without propagating exit status), and staying attached
    # would tie the editor's lifetime to a console the user may close.
    # Windows-only: off Windows `code` is a .ps1 run INSIDE the launcher
    # process, so "did it wait" is unaskable there.

    BeforeAll {
        # One measured launch, read by both cases (CPR-SSOT): they are two halves
        # of one contract, and a blocking launcher costs this Context its whole
        # budget once instead of once per case. CCGW_AUTO_PULL is off (the suite
        # default in Set-ChildEnvBlock), so 14a/14b measure the launch alone.
        $script:Ctx14 = Measure-LauncherLaunch -Environment (New-Env) -Arguments @('C:\some\project') -BudgetMs 10000

        # 14c's fixture: the same long-lived `code` stub, plus a `git` that never
        # returns. ping is the sleep because PATH is the stub dir alone, so the
        # absolute System32 path is the only one that resolves.
        $script:Ctx14StubDir = New-StubDir -Name 'stub-ctx14-hanging-git' -NoMkcert -LongLivedCmdStub
        Set-Content -LiteralPath (Join-Path $script:Ctx14StubDir 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            '%SystemRoot%\System32\ping.exe -n 300 127.0.0.1 > nul'
            'exit /b 0'
        )
        # A tree that LOOKS like a checkout, so an implementation that skips the
        # pull when there is no .git still reaches the hanging git here.
        $script:Ctx14Launcher = New-FixtureTree -Name 'fixture-ctx14-autopull'
        $ctx14GitDir = Join-Path (Get-FixtureRoot $script:Ctx14Launcher) '.git'
        New-Item -ItemType Directory -Path $ctx14GitDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ctx14GitDir 'HEAD') -Value 'ref: refs/heads/main' -Encoding ascii
    }

    It '14a. the launcher returns promptly even when the process it started is still alive' {
        # The stub records that it ran, then blocks until the runner releases it,
        # so the two observations below are independent:
        #   StubStarted        -- a process really was launched (a launcher that
        #                         starts nothing also returns promptly, and that
        #                         is a different, worse bug)
        #   ExitedWithinBudget -- the launcher came back without waiting for it
        $r = $script:Ctx14

        $r.StubStarted | Should -BeTrue -Because "the long-lived stub never ran, so nothing was measured; launcher output: $($r.Output)"
        $r.ExitedWithinBudget | Should -BeTrue -Because @"
the launcher was still running $($r.ElapsedMs)ms after it started a code.cmd that is deliberately still alive:
it is waiting for VS Code to exit instead of handing over and returning. The invoking shell must get its
prompt back at once -- the launcher has no use for the editor's exit status and must not tie the editor's
lifetime to the console it was started from. Launcher output: $($r.Output)
"@
    }

    It '14b. the child it did not wait for still received its argv and environment' {
        # The other half (CPR-E2E): "returned promptly" is trivially satisfiable by
        # a launcher that hands over nothing at all, so the SAME launch is checked
        # for the payload as well.
        $r = $script:Ctx14

        $r.Reached | Should -BeTrue -Because "the stub wrote no environment dump; launcher output: $($r.Output)"
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'responsiveness/env'
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'responsiveness/env'
        $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'), 'C:\some\project')
        (@($r.Argv) -join "`u{1}") | Should -BeExactly ($expected -join "`u{1}") `
            -Because "a detached launch must still deliver the full argv; got [$(@($r.Argv) -join '][')]"
    }

    It '14c. auto-pull on: a git that never returns must not hold the launch hostage' {
        # Auto-pull is on by default (issue #89), which puts a network operation
        # on the critical path of every launch. An unreachable remote -- VPN down,
        # SSH agent asking for a passphrase nobody will type -- is the normal
        # failure, and it must cost the deadline, not the session. The budget is
        # the launcher's own 20s deadline plus room for process startup; anything
        # near this Context's cap means no deadline is being enforced at all.
        $r = Measure-LauncherLaunch -LauncherPath $script:Ctx14Launcher -StubDir $script:Ctx14StubDir `
            -Environment (New-Env @{ CCGW_AUTO_PULL = 'on' }) -BudgetMs 60000
        $r.ExitedWithinBudget | Should -BeTrue -Because @"
the launcher was still running $($r.ElapsedMs)ms after start with a deliberately hanging git on PATH:
auto-pull has no deadline, so an unreachable remote blocks the editor from ever opening. Launcher output: $($r.Output)
"@
        $r.StubStarted | Should -BeTrue -Because "a timed-out pull must still launch the editor; launcher output: $($r.Output)"
    }
}
