#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '10. The non-batch (.exe) launch path' {
    # `code` resolves to code.cmd on every real Windows VS Code install, so the
    # .exe branch has to be driven through a purpose-built stand-in. It is covered
    # at the two points where it can fail: the quoting rule it applies (10a,
    # against the real function, extracted from the source rather than
    # re-implemented here) and what an .exe target actually receives (10b).
    #
    # 10b used to assert only that two error strings were ABSENT, which a launcher
    # that started no process at all would also satisfy -- absence of an error is
    # not evidence of a launch. It now runs a compiled stub that reports what it
    # got: a marker file (a process really started), its argv, and its inherited
    # environment. The stub writes through File.WriteAllLines, so unlike the .cmd
    # stub it is code-page-independent and can carry the non-ASCII case too.
    #
    # TL3 gap: whether the .exe was reached DIRECTLY or through a cmd.exe wrapper
    #   is not observable from inside the child -- both deliver the same argv when
    #   the wrapper quotes correctly. What is observable, and asserted, is that a
    #   .cmd target IS re-parsed by cmd.exe (Context 9) and that an .exe target
    #   receives its argv and environment intact.

    It '10a. ConvertTo-ArgvQuotedArgument follows the CommandLineToArgvW rules' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SourceLauncher, [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({
                    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $args[0].Name -eq 'ConvertTo-ArgvQuotedArgument'
                }, $true))
        # AST rather than a regex: the body nests braces, which a regex cannot
        # balance.
        $fn.Count | Should -Be 1 -Because 'the .exe branch must quote through one named helper the tests can reach'
        . ([scriptblock]::Create($fn[0].Extent.Text))

        $cases = @(
            @{ In = 'plain'; Out = 'plain' }
            @{ In = ''; Out = '""' }
            @{ In = 'has space'; Out = '"has space"' }
            @{ In = 'a"b'; Out = '"a\"b"' }
            @{ In = 'a\"b'; Out = '"a\\\"b"' }
            @{ In = 'C:\dir\'; Out = 'C:\dir\' }
            @{ In = 'C:\my dir\'; Out = '"C:\my dir\\"' }
        )
        foreach ($c in $cases) {
            (ConvertTo-ArgvQuotedArgument $c.In) | Should -BeExactly $c.Out -Because "input '$($c.In)'"
        }
    }

    It '10b. a `code` that resolves to a real .exe is launched, and receives its argv and environment intact' {
        if (-not ($IsWindows -and $script:HaveExeStub)) {
            Set-ItResult -Skipped -Because 'no C# compiler was available to build the dumping code.exe stub on this host'
            return
        }
        # A metacharacter and a non-ASCII value ride along: they are the two
        # classes of value a quoting helper corrupts, and the .exe branch quotes by
        # different rules than the .cmd branch does (CommandLineToArgvW, not
        # cmd.exe's re-parse), so each branch has to be shown to carry them.
        $meta = 'a&b|c^d'
        $unicode = "$([char]0x30D7)$([char]0x30ED)$([char]0x30B8)-caf$([char]0x00E9)"
        $r = Invoke-Launcher -StubDir $script:StubExe -Environment (New-Env) `
            -Arguments @('C:\some\project', $meta, $unicode)

        $r.StdErr | Should -Not -Match ([regex]::Escape("'code' command not found on PATH")) -Because 'an .exe on PATH is a valid code'
        $r.ExitCode | Should -Be 0 -Because "the .exe branch must start the process; stderr: $($r.StdErr)"
        $r.ExeMarker | Should -BeTrue -Because "the stub must actually have run; a launcher that starts nothing passes every absence-of-error check. stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"

        $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'), 'C:\some\project', $meta, $unicode)
        (@($r.Argv) -join "`u{1}") | Should -BeExactly ($expected -join "`u{1}") `
            -Because "the .exe branch must deliver argv verbatim; got [$(@($r.Argv) -join '][')]"

        # The environment half of the same launch: a branch that launches but
        # hands over nothing routes Claude Code straight back to the cloud.
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'exe-branch/env'
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'exe-branch/env'
    }
}
