#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '14. The launch is fire-and-forget: the launcher does not wait for VS Code' -Skip:(-not $IsWindows) {
    # Every other stub in this suite exits in milliseconds, which makes one whole
    # class of defect invisible: a launcher that WAITS for the process it started
    # -- `Start-Process -Wait`, or a bare .WaitForExit() with no timeout on the
    # ProcessStartInfo path issue #66 introduces -- passes all of them and still
    # leaves the developer's prompt hanging until they close the editor. Nothing
    # in an exit code, an env dump or an argv dump distinguishes the two; only a
    # child that outlives the measurement can.
    #
    # Why fire-and-forget is the contract and not merely the current behaviour:
    # the launcher's job ends once VS Code owns the environment it computed. It
    # has nothing left to do with the editor's exit status (it does not propagate
    # it -- `code` on Windows returns as soon as it has handed the folder to the
    # running instance), and staying attached would additionally tie the editor's
    # lifetime to a console the user is entitled to close. The POSIX counterpart
    # gets this for free by exec'ing; on Windows it has to be a decision.
    #
    # Windows-only: off Windows `code` is a .ps1 stub, which PowerShell runs
    # INSIDE the launcher process rather than starting as one, so "the launcher
    # did not wait for it" is not a question that can be asked there.

    BeforeAll {
        # One measured launch, read by both cases (CPR-SSOT): they are two halves
        # of one contract, and a blocking launcher costs this Context its whole
        # budget once instead of once per case.
        $script:Ctx14 = Measure-LauncherLaunch -Environment (New-Env) -Arguments @('C:\some\project') -BudgetMs 10000
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
}
