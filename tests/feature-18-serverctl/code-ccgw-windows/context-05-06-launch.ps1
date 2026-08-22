#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# the launch itself -- the isolated VS Code profile, argv passthrough, the working
# directory, and the missing-`code` refusal.

Context '5. VS Code profile isolation and argv passthrough' {
    It 'passes an isolated --user-data-dir under LOCALAPPDATA plus the caller argv' {
        $r = Invoke-Launcher -Environment (New-Env) -Arguments @('C:\some\project', '--new-window')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'), 'C:\some\project', '--new-window')
        @($r.Argv) | Should -Be $expected
    }

    It 'passes only the --user-data-dir pair when the caller supplied no argv' {
        $r = Invoke-Launcher -Environment (New-Env)
        $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'))
        @($r.Argv) | Should -Be $expected
    }

    It 'falls back to a home-relative profile dir when LOCALAPPDATA is unset' {
        # LOCALAPPDATA is always set on a normal Windows session, but a stripped
        # service environment would otherwise make the final Join-Path throw after
        # every env var had already been resolved. The exact fallback spelling is
        # the script's business; what must hold is that it still launches, still
        # isolates, and still roots the profile under the user's home.
        $r = Invoke-Launcher -Environment (New-Env) -NoLocalAppData
        $r.Reached | Should -BeTrue -Because "an unset LOCALAPPDATA must not abort the launcher; stderr: $($r.StdErr)"
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        @($r.Argv).Count | Should -Be 2
        $r.Argv[0] | Should -Be '--user-data-dir'
        $r.Argv[1] | Should -BeLike "$($script:Work)*"
        $r.Argv[1] | Should -BeLike '*vscode-ccgw'
        # Still isolated: the fallback must not be the LOCALAPPDATA path, and must
        # not be the bare home dir either.
        $r.Argv[1] | Should -Not -Be (Join-Path $script:Work 'vscode-ccgw')
    }

    It 'resolves .env and the profile dir from the script''s own location, not the caller''s cwd' {
        # The launcher composes its .env path from $PSScriptRoot. Switching to an
        # explicit Process.Start makes the child's working directory a thing the
        # launcher now sets deliberately, so the invariant is worth pinning: a
        # developer running the launcher from anywhere must get the same
        # configuration, and the child must actually start in the caller's
        # directory (VS Code resolves relative file arguments there).
        $elsewhere = Join-Path $script:Work 'cwd-elsewhere'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncherForCwd -WorkingDirectory $elsewhere
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-dotenv-cwd:9' 'cwd: .env is resolved from $PSScriptRoot, not the cwd'
        $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'))
        @($r.Argv) | Should -Be $expected -Because 'the profile dir must not depend on the cwd either'
        (Resolve-Path -LiteralPath $r.Cwd).Path | Should -Be (Resolve-Path -LiteralPath $elsewhere).Path `
            -Because 'the child must inherit the caller''s directory so relative file arguments still resolve'
    }
}

Context '6. Missing code on PATH' {
    It 'is a hard failure that names both the problem and the remedy' {
        $r = Invoke-Launcher -StubDir $script:StubNoCode -Environment (New-Env)
        $r.ExitCode | Should -Not -Be 0 -Because 'a missing code command must not exit 0'
        Assert-Stderr $r "'code' command not found on PATH" 'missing-code: must name the problem'
        Assert-Stderr $r "Install 'code' command in PATH" 'missing-code: must state the remedy'
    }
}
