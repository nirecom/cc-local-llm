#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '9. Argument metacharacters stay data, never cmd.exe operators (issue #66)' -Skip:(-not $IsWindows) {
    # Windows-only by nature: the hazard is cmd.exe, and the stub that observes it
    # is a .cmd. `code` resolves to code.cmd on a real VS Code install, and Win32
    # CreateProcess given a .cmd/.bat silently re-launches cmd.exe to interpret it
    # -- so an argument carrying &, |, ^, <, > or % is re-read as shell syntax even
    # when it contains no whitespace at all (the BatBadBut class).
    # CommandLineToArgvW-style quoting, which is what an .exe target needs, does
    # not defend against this.
    #
    # These cases depend on the stub echoing `ARG="%~1"` with the expansion
    # already inside quotes; see the Method note in the suite header for why an
    # unquoted stub would misreport exactly the inputs under test.

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
        # cmd.exe truncates its command line at a newline, so the tail of such an
        # argument would run as a separate command. No escaping makes that safe,
        # which leaves refusing it as the only honest option -- and refusing BEFORE
        # the launch, so there is no half-executed state.
        #
        # Refusing is asserted three ways, because each alone is satisfiable by
        # the wrong implementation: a non-zero exit alone would also be produced by
        # a launcher that ran the payload and then failed; "the stub was never
        # reached" alone would also hold if the payload had run INSTEAD of VS Code.
        # The marker file is the one that closes it -- the second line of every
        # payload below is a complete cmd command that creates a file, so if the
        # newline ever reached cmd.exe the file exists, whatever else happened
        # (CWE-78).
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
        # itself goes onto the very same command line and needs the very same
        # treatment -- and it is the half that no stub directory in this suite
        # would have caught, because they are all shell-safe names under TEMP.
        #
        # The real world is not: "C:\Program Files (x86)\Microsoft VS Code\bin\code.cmd"
        # already carries a space and parentheses, and `&` is legal in a directory
        # name. Unquoted, cmd.exe splits the path at the space and treats what
        # follows `&` as a second command; quoted but not escaped, the `&` inside
        # the quotes is safe while an unquoted `(` is not.
        # Every argument here is deliberately shell-safe: 9a already owns the
        # argument axis, and reusing a metacharacter argument would make this case
        # fail for 9a's reason and say nothing about the path (CPR-SC -- one
        # variable at a time).
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
        # 9b and 9c settle for "not split, not injected" on these two shapes for a
        # reason that is about the OBSERVER, not about the contract: the default
        # stub recovers each argument with `%~1`, which undoes neither the doubled
        # "" nor the doubled trailing backslash that correct quoting produces, so
        # a literal comparison there would fail on a correct launcher.
        #
        # This case removes that limitation instead of living with it: `code` is a
        # code.cmd that forwards %* to a real executable -- which is exactly what a
        # genuine VS Code install does -- and the executable reports the argv
        # CommandLineToArgvW handed it. Both hops therefore run for real, and what
        # comes out can be compared against what went in with no allowance made.
        #
        # These are the two shapes quoting gets wrong in opposite directions: a
        # doubled quote arrives as two quotes, and a trailing backslash that is not
        # doubled escapes the closing quote and swallows the argument after it.
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
