#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '9. Argument metacharacters stay data, never cmd.exe operators (issue #66)' -Skip:(-not $IsWindows) {
    # Windows-only by nature: the hazard is cmd.exe, observed via a .cmd stub.
    # `code` resolves to code.cmd on a real VS Code install, and Win32
    # CreateProcess given a .cmd/.bat silently re-launches cmd.exe to
    # interpret it, so an argument carrying &, |, ^, <, > or % is re-read as
    # shell syntax even with no whitespace at all (the BatBadBut class);
    # CommandLineToArgvW-style quoting, what an .exe target needs, does not
    # defend against this. Cases depend on the stub echoing `ARG="%~1"` with
    # the expansion already inside quotes -- see the suite header's Method
    # note for why an unquoted stub would misreport these inputs.

    BeforeAll {
        # One class, one table (CPR-E2C): each of these is "a value the shell would
        # treat as syntax", not a separate feature.
        $script:MetacharValues = @(
            'plain-arg'
            'has space'
            'a&b'
            'a|b'
            'a^b'
            'a<b'
            'a>b'
            '100%done'
            '%PATH%'
            'a(b)c'
            'a;b'
            'a,b'
            '!bang!'
            'a&&b||c'
        )
        $script:ProfileArg = Join-Path $script:LocalAppData 'vscode-ccgw'
    }

    It '9a. a metacharacter in an argument reaches the child as the literal string' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($value in $script:MetacharValues) {
            $r = Invoke-Launcher -Environment (New-Env) -Arguments @('C:\some\project', $value)
            $expected = @('--user-data-dir', $script:ProfileArg, 'C:\some\project', $value)
            if ($r.ExitCode -ne 0) {
                $bad.Add("'$value': exit $($r.ExitCode); stderr: $($r.StdErr)")
            } elseif (-not $r.Reached) {
                $bad.Add("'$value': the stub was never reached; stderr: $($r.StdErr)")
            } elseif ((@($r.Argv) -join "`u{1}") -cne ($expected -join "`u{1}")) {
                $bad.Add("'$value': argv was [$(@($r.Argv) -join '][')], expected [$($expected -join '][')]")
            }
        }
        $bad.Count | Should -Be 0 -Because "argument splitting or corruption by cmd.exe: $($bad -join ' // ')"
    }

    It '9b. a value shaped like a command injection creates nothing and runs nothing' {
        # The decisive assertion is the marker file, not the argv: if a
        # metacharacter were still an operator, the text after it would run as a
        # second command with the launcher's own privileges (CWE-78).
        $bad = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($template in @(
                '& type nul > "{0}"'
                '| type nul > "{0}"'
                'x&type nul>{0}'
                '"" & type nul > "{0}" & echo ""'
            )) {
            $i++
            $marker = Join-Path $script:Work "injection-marker-$i.txt"
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            $value = [string]::Format($template, $marker)
            $r = Invoke-Launcher -Environment (New-Env) -Arguments @('C:\some\project', $value)
            if (Test-Path -LiteralPath $marker) {
                $bad.Add("'$value': the injected command RAN (marker created)")
            }
            # "Nothing ran" is only half the contract: an argument mangled badly
            # enough to abort the launch also creates no marker, and that is a
            # broken launcher, not a safe one. The child must be reached, exit
            # cleanly, and see exactly four arguments.
            if ($r.ExitCode -ne 0) {
                $bad.Add("'$value': exit $($r.ExitCode); stderr: $($r.StdErr)")
            } elseif (-not $r.Reached) {
                $bad.Add("'$value': the stub was never reached; stderr: $($r.StdErr)")
            } elseif (@($r.Argv).Count -ne 4) {
                $bad.Add("'$value': argv was [$(@($r.Argv) -join '][')]")
            } elseif ($value -notmatch '"' -and (@($r.Argv)[-1] -cne $value)) {
                # Argv equality is only checked for the values the stub can
                # round-trip: %~1 does not collapse the doubled "" an embedded
                # quote becomes, so a quoted template stops at the count check.
                $bad.Add("'$value': reached the child as '$(@($r.Argv)[-1])'")
            }
        }
        $bad.Count | Should -Be 0 -Because "cmd.exe re-interpreted an argument: $($bad -join ' // ')"
    }

    It '9c. an argument ending in a backslash is neither split nor truncated' {
        # A trailing backslash is the other half of the BatBadBut recipe: it would
        # otherwise escape the closing quote and swallow the next argument. The
        # stub cannot show the doubling being undone (%~1 does not halve it), so
        # the contract asserted here is "same argument count, same value up to
        # backslash doubling".
        $r = Invoke-Launcher -Environment (New-Env) -Arguments @('C:\trailing\dir\', 'C:\some\project')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"
        @($r.Argv).Count | Should -Be 4 -Because "the trailing backslash must not swallow the next argument; argv: [$(@($r.Argv) -join '][')]"
        ($r.Argv[2] -replace '\\+$', '\') | Should -BeExactly 'C:\trailing\dir\'
        $r.Argv[3] | Should -BeExactly 'C:\some\project'
    }

    It '9d. an argument containing a newline is refused before anything is launched, and its payload never runs' {
        # cmd.exe truncates its command line at a newline, so the tail of such
        # an argument would run as a separate command; no escaping makes that
        # safe, so refusing BEFORE the launch is the only honest option, with
        # no half-executed state. Refusing is asserted three ways since each
        # alone is satisfiable by a wrong implementation: non-zero exit alone
        # also fits a launcher that ran the payload and then failed; "stub
        # never reached" alone also fits the payload running INSTEAD of VS
        # Code. The marker file closes it -- each payload's second line is a
        # complete cmd command creating a file, so if the newline reached
        # cmd.exe the file exists regardless of anything else (CWE-78).
        $bad = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($template in @(
                "C:\some\project`ntype nul > `"{0}`""
                "C:\some\project`r`ntype nul > `"{0}`""
                "`ntype nul>{0}"
            )) {
            $i++
            $marker = Join-Path $script:Work "newline-marker-$i.txt"
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            $value = [string]::Format($template, $marker)
            $rendered = $value -replace "`r", '<CR>' -replace "`n", '<LF>'
            $r = Invoke-Launcher -Environment (New-Env) -Arguments @($value)
            if (Test-Path -LiteralPath $marker) {
                $bad.Add("'$rendered': the payload after the newline RAN (marker created)")
            }
            if ($r.ExitCode -eq 0) {
                $bad.Add("'$rendered': exit 0 -- an unrepresentable argument must not be silently truncated")
            }
            if ($r.Reached) {
                $bad.Add("'$rendered': VS Code was launched anyway; the refusal must precede the launch")
            }
            if ($r.StdErr -notmatch 'newline') {
                $bad.Add("'$rendered': the error must say what is wrong with the argument; stderr: $($r.StdErr)")
            }
        }
        $bad.Count | Should -Be 0 -Because "metachars/newline: $($bad -join ' // ')"
    }

    It '9e. a `code.cmd` whose own directory contains a space and metacharacters is still launched correctly' {
        # Everything above escapes the ARGUMENTS. The resolved path of `code`
        # goes onto the same command line and needs the same treatment -- the
        # half no stub directory in this suite would catch, since they're all
        # shell-safe names under TEMP. Real world: "C:\Program Files (x86)\...
        # \code.cmd" already has a space and parentheses, and `&` is legal in a
        # directory name; unquoted, cmd.exe splits at the space and runs what
        # follows `&` as a second command, while quoted-but-unescaped leaves an
        # unquoted `(` unsafe. Arguments here stay shell-safe on purpose: 9a
        # owns the argument axis, and reusing a metachar argument would fail
        # for 9a's reason and say nothing about the path (CPR-SC).
        $r = Invoke-Launcher -StubDir $script:StubMetacharDir -Environment (New-Env) `
            -Arguments @('C:\some\project', '--new-window')

        $r.ExitCode | Should -Be 0 -Because "the launcher must find and start a code.cmd under an unfriendly path; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"
        # A path split at a metacharacter produces cmd's own complaint rather than
        # a launcher error, so it is asserted by name: it is the signature of the
        # tail of the path having been run as a command.
        $r.StdErr | Should -Not -Match '(?i)is not recognized as an internal or external command' `
            -Because "part of the stub's own path was executed as a command: $($r.StdErr)"

        $expected = @('--user-data-dir', $script:ProfileArg, 'C:\some\project', '--new-window')
        (@($r.Argv) -join "`u{1}") | Should -BeExactly ($expected -join "`u{1}") `
            -Because "argv must survive an unfriendly path to code.cmd; got [$(@($r.Argv) -join '][')]"
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'metachars/unfriendly-code-path'
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'metachars/unfriendly-code-path'
    }

    It '9f. an embedded quote and a trailing backslash round-trip byte for byte' {
        # 9b/9c settle for "not split, not injected" here for an OBSERVER
        # reason: `%~1` undoes neither a doubled "" nor a doubled trailing
        # backslash, so literal comparison fails there even on a correct
        # launcher. This case removes that limit: `code` is a code.cmd
        # forwarding %* to a real executable (as a genuine install does),
        # which reports the argv CommandLineToArgvW handed it, so both hops
        # run for real and output compares to input with no allowance made.
        # Opposite-direction failure shapes: a doubled quote arrives as two
        # quotes; an undoubled trailing backslash escapes the closing quote
        # and swallows the next argument.
        if (-not $script:HaveObserverExe) {
            Set-ItResult -Skipped -Because 'no C# compiler was available to build the argv observer that code.cmd forwards to'
            return
        }
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($value in @(
                'a"b'
                'say "hi" now'
                '"leading-quote'
                'trailing-quote"'
                'C:\trailing\dir\'
                'C:\my dir\'
                'two-backslashes\\'
                '"quoted path\"'
            )) {
            $r = Invoke-Launcher -StubDir $script:StubCmdForward -Environment (New-Env) `
                -Arguments @($value, 'TAIL-SENTINEL')
            $expected = @('--user-data-dir', $script:ProfileArg, $value, 'TAIL-SENTINEL')
            if ($r.ExitCode -ne 0) {
                $bad.Add("'$value': exit $($r.ExitCode); stderr: $($r.StdErr)")
            } elseif (-not $r.Reached) {
                $bad.Add("'$value': the observer was never reached; stderr: $($r.StdErr)")
            } elseif ((@($r.Argv) -join "`u{1}") -cne ($expected -join "`u{1}")) {
                $bad.Add("'$value': argv was [$(@($r.Argv) -join '][')], expected [$($expected -join '][')]")
            }
        }
        $bad.Count | Should -Be 0 -Because "quoting corrupted an argument on the .cmd path: $($bad -join ' // ')"
    }
}
