#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# the --extensions-dir bootstrap-install branch added alongside --extensions-dir
# itself, so a freshly pointed-at extensions dir gets anthropic.claude-code
# before the real launch (best-effort: a failed install warns but never blocks).

# ConvertTo-CallLogInvocations lives in helpers-assertions.ps1 (dot-sourced
# from the suite's BeforeAll) -- see the comment there for why.

Context '20. Bootstrap-installing anthropic.claude-code into the isolated extensions dir' {
    It '20a. no marker present: code is invoked to install, then to launch' {
        $freshLocalAppData = Join-Path $script:Work 'ctx20-fresh-nolog'
        New-Item -ItemType Directory -Path $freshLocalAppData -Force | Out-Null
        $stub = New-StubDir -Name 'stub-ctx20-nolog' -NoMkcert -CallLogCmdStub

        $r = Invoke-Launcher -StubDir $stub -Environment (New-Env @{ LOCALAPPDATA = $freshLocalAppData }) -Arguments @('C:\some\project')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "the real launch must still happen; stderr: $($r.StdErr)"

        $extensionsDir = Join-Path $freshLocalAppData 'vscode-ccgw-extensions'
        $invocations = ConvertTo-CallLogInvocations -Lines $r.CallLog
        $invocations.Count | Should -Be 2 -Because "install + real launch must be two separate invocations; call log: $($r.CallLog -join ' / ')"
        @($invocations[0]) | Should -Be @('--install-extension', 'anthropic.claude-code', '--extensions-dir', $extensionsDir) `
            -Because "the install call's own argv; got [$(@($invocations[0]) -join '][')]"
        @($r.Argv) | Should -Be @('--user-data-dir', (Join-Path $freshLocalAppData 'vscode-ccgw'), '--extensions-dir', $extensionsDir, 'C:\some\project') `
            -Because "the real launch's argv must still be correct after the install call"
    }

    It '20b. a marker already present: code is invoked only once, for the real launch' {
        # Reuses $script:LocalAppData, pre-seeded by setup.ps1 with a fake
        # anthropic.claude-code-* folder so this is the no-install path.
        $stub = New-StubDir -Name 'stub-ctx20-seeded' -NoMkcert -CallLogCmdStub
        $r = Invoke-Launcher -StubDir $stub -Environment (New-Env) -Arguments @('C:\some\project')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $invocations = ConvertTo-CallLogInvocations -Lines $r.CallLog
        $invocations.Count | Should -Be 1 -Because "a marker already present must skip the install call entirely; call log: $($r.CallLog -join ' / ')"
    }

    It '20c. a failing install is non-fatal: the real launch still happens and a WARNING is printed' {
        $freshLocalAppData = Join-Path $script:Work 'ctx20-fresh-failinstall'
        New-Item -ItemType Directory -Path $freshLocalAppData -Force | Out-Null
        $stub = New-StubDir -Name 'stub-ctx20-failinstall' -NoMkcert -CallLogFailInstallCmdStub

        $r = Invoke-Launcher -StubDir $stub -Environment (New-Env @{ LOCALAPPDATA = $freshLocalAppData }) -Arguments @('C:\some\project')
        $r.ExitCode | Should -Be 0 -Because "a failed install must not block the launch; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "the real launch must still happen even though the install failed; stderr: $($r.StdErr)"
        Assert-LauncherWarning $r 'could not install' 'ctx20c/failing-install'

        $invocations = ConvertTo-CallLogInvocations -Lines $r.CallLog
        $invocations.Count | Should -Be 2 -Because "the install attempt and the real launch are both invocations of code; call log: $($r.CallLog -join ' / ')"
    }
}
