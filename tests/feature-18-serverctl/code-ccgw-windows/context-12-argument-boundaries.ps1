#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
# lang-check: ignore (non-ASCII path fixtures are the test subject)
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '12. Argument boundaries: empty, non-ASCII, and over-long' {
    # Context 9 covers the values a shell would treat as SYNTAX. This one covers
    # the values a quoting layer loses without ever looking like an attack: an
    # argument that is empty, one that is not ASCII, and one that is longer than
    # the transport can carry. All three are silent corruptions -- the launcher
    # exits 0 and VS Code simply opens the wrong thing (or nothing) -- which is why
    # each case asserts on what the child RECEIVED, never on the exit code alone.

    It '12a. an empty argument is preserved in place, not dropped' {
        # `code -g file:1:1 "" --wait` is a real shape: an empty string means
        # "this optional positional is blank", and dropping it shifts every
        # later argument one slot left -- VS Code then reads the next
        # argument as the value of the previous flag, invisibly in the exit
        # code. The default .cmd stub can't observe this: `if "%~1"==""` is
        # its end-of-argv test, so an empty argument ends the dump early and
        # later arguments look dropped even when delivered. This case uses
        # the positional stub instead, which dumps a fixed number of slots
        # whether or not they are empty.
        $r = Invoke-Launcher -StubDir $script:StubPositional -Environment (New-Env) `
            -Arguments @('SENTINEL-A', '', 'SENTINEL-B')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"

        $argv = @($r.Argv)
        $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'), 'SENTINEL-A', '', 'SENTINEL-B')
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $got = if ($i -lt $argv.Count) { $argv[$i] } else { '<missing>' }
            $got | Should -BeExactly $expected[$i] -Because "argument $($i + 1) of [$($argv -join '][')] -- an empty argument must occupy its own slot, not vanish"
        }
        # The other half of "not dropped": nothing may have shifted up into the
        # slot after the last real argument either.
        if ($argv.Count -gt $expected.Count) {
            $argv[$expected.Count] | Should -BeExactly '' -Because "argv must end after SENTINEL-B; got [$($argv -join '][')]"
        }
    }

    It '12b. a non-ASCII path, argument and profile directory survive byte for byte' {
        # A Japanese or accented directory name is the normal case for a large part
        # of the user base (OneDrive\\ドキュメント, C:\\Users\\Müller), and every
        # transport in play here can mangle it: cmd.exe renders through the console
        # code page, a .NET command line is UTF-16, and a naive quoting helper that
        # counts bytes instead of chars splits a surrogate pair.
        #
        # Three non-ASCII things are exercised in ONE run, because they fail
        # independently: the launcher's own location (so $PSScriptRoot and the .env
        # beside it are non-ASCII), the profile directory it composes, and an
        # argument it forwards.
        $uniLocalAppData = Join-Path $script:Work ("localappdata-$([char]0x30C6)$([char]0x30B9)$([char]0x30C8)")
        New-Item -ItemType Directory -Path $uniLocalAppData -Force | Out-Null
        $uniArg = "C:\$([char]0x30D7)$([char]0x30ED)$([char]0x30B8)\caf$([char]0x00E9)-$([char]0x00DF)$([char]0x4E2D)$([char]0x6587).txt"

        $r = Invoke-Launcher -LauncherPath $script:UnicodeLauncher `
            -Environment @{ LOCALAPPDATA = $uniLocalAppData } `
            -Arguments @($uniArg, '--new-window')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"

        # The launcher found its own .env through a non-ASCII $PSScriptRoot.
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://unicode-lite:1' 'unicode: .env beside a non-ASCII script dir'

        $expected = @('--user-data-dir', (Join-Path $uniLocalAppData 'vscode-ccgw'), $uniArg, '--new-window')
        (@($r.Argv) -join "`u{1}") | Should -BeExactly ($expected -join "`u{1}") `
            -Because "a non-ASCII argument or profile path must reach VS Code unchanged; got [$(@($r.Argv) -join '][')]"
    }

    It '12c-i. a command line comfortably under the limit must simply launch' -Skip:(-not $IsWindows) {
        # The allow half of the length guard, and the only half that pins the
        # guard's other edge. 12c-ii below accepts a refusal as one correct
        # outcome, which on its own sanctions a launcher that refuses EVERYTHING
        # long-ish -- a 2,000-character workspace path list is ordinary (a handful
        # of deep OneDrive paths gets there), and refusing it would be a
        # regression dressed up as caution. Nothing may be refused here: cmd.exe's
        # ceiling is around 8,191 characters, so these are not close to it.
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($len in @(200, 2000)) {
            $value = 'L' + ('x' * ($len - 2)) + 'Z'
            $r = Invoke-Launcher -Environment (New-Env) -Arguments @($value)
            $tag = "length $len"
            if ($r.ExitCode -ne 0) {
                $bad.Add("${tag}: refused a command line the transport can carry; stderr: $($r.StdErr)")
                continue
            }
            if (-not $r.Reached) {
                $bad.Add("${tag}: exit 0 but nothing was launched; stderr: $($r.StdErr)")
                continue
            }
            $delivered = @($r.Argv)[-1]
            if ($delivered -cne $value) {
                $bad.Add("${tag}: the child received $($delivered.Length) chars instead of $($value.Length)")
            }
        }
        $bad.Count | Should -Be 0 -Because "a safely-sized command line must be delivered, not refused: $($bad -join ' // ')"
    }

    It '12c-ii. an over-long command line is delivered whole or refused outright, never truncated' -Skip:(-not $IsWindows) {
        # cmd.exe stops reading at ~8191 chars. A .cmd target is reached
        # THROUGH cmd.exe (Context 9), so a long argument list crosses that
        # well before the 32767-char CreateProcess limit, truncating rather
        # than failing -- exit 0, path ending mid-word. Acceptable:
        # delivering the whole thing, or refusing before launch with an
        # explanatory error. Not acceptable: exit 0 with nothing launched, or
        # a truncated delivery. Ceiling depends on the stub's own path
        # length, so lengths below bracket it; comfortably-under lengths live
        # in 12c-i, where refusal is NOT acceptable.
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($len in @(7000, 9000)) {
            # Sentinels at both ends: truncation of any amount changes the tail,
            # and comparing the whole string keeps a partial delivery from passing.
            $value = 'L' + ('x' * ($len - 2)) + 'Z'
            $r = Invoke-Launcher -Environment (New-Env) -Arguments @($value)
            $tag = "length $len"

            if ($r.ExitCode -eq 0) {
                if (-not $r.Reached) {
                    $bad.Add("${tag}: exit 0 but nothing was launched -- a command line that cannot be delivered must fail loudly; stderr: $($r.StdErr)")
                    continue
                }
                $delivered = @($r.Argv)[-1]
                if ($delivered -cne $value) {
                    $bad.Add("${tag}: the child received $($delivered.Length) chars instead of $($value.Length) -- silently truncated")
                }
            } else {
                if ($r.Reached) {
                    $bad.Add("${tag}: VS Code was launched and the launcher still failed; the refusal must precede the launch")
                }
                if ($r.StdErr -notmatch '(?i)(too long|length|limit|8191)') {
                    $bad.Add("${tag}: refused with no explanation of the length limit; stderr: $($r.StdErr)")
                }
            }
        }
        $bad.Count | Should -Be 0 -Because "command-line length: $($bad -join ' // ')"
    }
}
