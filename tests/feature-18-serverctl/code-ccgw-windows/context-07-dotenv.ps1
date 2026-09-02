#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# the repo-root .env loader, including the #@if windows / #@if posix conditional
# blocks (issue #56).

Context '7. Repo-root .env loading' {
    # The launcher composes the path as Join-Path (Join-Path $PSScriptRoot '..') '.env',
    # so the separator is the platform's own and these cases run everywhere pwsh
    # does -- they are not Windows-gated.

    # One BeforeAll for the whole Context, deliberately: Pester 5 keeps only the
    # LAST BeforeAll of a block, so a second one silently discards the first --
    # which is how the .env fixtures below came to be $null and the four
    # plain-.env cases to fail on an empty -File path. The OS-conditional fixtures
    # therefore live here rather than in a block of their own.
    BeforeAll {
        $script:DotEnvLauncher = New-FixtureTree -Name 'fixture-dotenv' -DotEnvLines @(
            '# comment line must be ignored'
            ''
            'LITELLM_ANTHROPIC_BASE_URL=https://from-dotenv:9'
            'LITELLM_CLIENT_KEY=dotenv-token'
            # Deliberately NOT a routing key: those are config.yaml's since issue
            # #89, so probing the trim through one would assert the loader's
            # behaviour on a value nothing consumes any more.
            '  TRIM_PROBE_KEY = trimmed_value  '
            'MALFORMED_NO_EQUALS'
        )

        # --- OS-conditional blocks (issue #56): `#@if windows` / `#@if posix` /
        # `#@endif` in the repo-root .env.
        #
        # This suite runs wherever pwsh happens to execute, not necessarily on
        # Windows, and the launcher's own platform-token resolution ($IsWindows,
        # falling back to 'windows' only when that variable does not exist at all)
        # is a property of whatever REAL host runs the child launcher process
        # below -- it cannot be mocked without touching the source. So every
        # assertion here is phrased in terms of $script:OsBlockToken, resolved the
        # same way, rather than hardcoding an assumption that the host is Windows.
        $script:OsBlockToken = if (Test-Path variable:IsWindows) { if ($IsWindows) { 'windows' } else { 'posix' } } else { 'windows' }
        $script:OsBlockOtherToken = if ($script:OsBlockToken -eq 'windows') { 'posix' } else { 'windows' }

        function Get-OsBlockExpected {
            param([string]$WindowsValue, [string]$PosixValue)
            if ($script:OsBlockToken -eq 'windows') { return $WindowsValue }
            return $PosixValue
        }

        $script:OsBlockCase1 = New-FixtureTree -Name 'fixture-osblock-case1' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            '#@if windows'
            'BASIC_KEY=win_value'
            '#@endif'
            '#@if posix'
            'BASIC_KEY=posix_value'
            '#@endif'
        )
        $script:OsBlockCase3 = New-FixtureTree -Name 'fixture-osblock-case3' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            '# a plain comment'
            'PLAIN_KEY=plain_value'
        )
        $script:OsBlockCase4 = New-FixtureTree -Name 'fixture-osblock-case4' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            'BEFORE_KEY=before_value'
            ''
            'AFTER_KEY=after_value'
        )
        $script:OsBlockCase5 = New-FixtureTree -Name 'fixture-osblock-case5' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            "#@if $($script:OsBlockOtherToken)"
            'OUTER_KEY=outer_should_not_appear'
            "#@if $($script:OsBlockToken)"
            'INNER_KEY=inner_should_not_appear'
            '#@endif'
            '#@endif'
        )
        $script:OsBlockCase6 = New-FixtureTree -Name 'fixture-osblock-case6' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            "#@if $($script:OsBlockToken)"
            'BEFORE_KEY=before_value'
            "#@if $($script:OsBlockOtherToken)"
            'NESTED_KEY=nested_should_not_appear'
            '#@endif'
            'AFTER_KEY=after_value'
            '#@endif'
        )
        $script:OsBlockCase7 = New-FixtureTree -Name 'fixture-osblock-case7' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            '#@if darwin'
            'UNKNOWN_TOKEN_KEY=should_never_appear'
            '#@endif'
        )
        $script:OsBlockCase8 = New-FixtureTree -Name 'fixture-osblock-case8' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            '#@ifwindows'
            'FOLLOW_KEY=should_always_appear'
            '#@endif'
        )
        $script:OsBlockCase9 = New-FixtureTree -Name 'fixture-osblock-case9' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            'BEFORE_KEY=before_value'
            '#@endif'
            'AFTER_KEY=after_value'
        )
        $script:OsBlockCase10 = New-FixtureTree -Name 'fixture-osblock-case10' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            "#@if $($script:OsBlockOtherToken)"
            'INSIDE_KEY=inside_value'
            '#@endif foo'
            'AFTER_KEY=after_value'
        )

        $script:OsBlockCase11 = New-FixtureTree -Name 'fixture-osblock-case11'
        $osBlockCase11Root = Split-Path (Split-Path $script:OsBlockCase11 -Parent) -Parent
        $osBlockCase11Lines = @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            '#@if windows'
            'BASIC_KEY=win_value'
            '#@endif'
            '#@if posix'
            'BASIC_KEY=posix_value'
            '#@endif'
        )
        # Explicit CRLF write: New-FixtureTree's Set-Content uses this host's
        # default newline, which is already LF on macOS/Linux -- this case exists
        # specifically to prove a CRLF-authored .env (e.g. edited on a real
        # Windows box) resolves identically regardless of host.
        [System.IO.File]::WriteAllText((Join-Path $osBlockCase11Root '.env'), (($osBlockCase11Lines -join "`r`n") + "`r`n"))

        $script:OsBlockCase12 = New-FixtureTree -Name 'fixture-osblock-case12' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            '  #@if windows  '
            'PAD_KEY=win_value'
            '  #@endif  '
            '  #@if posix  '
            'PAD_KEY=posix_value'
            '  #@endif  '
        )
        $script:OsBlockCase13 = New-FixtureTree -Name 'fixture-osblock-case13' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://lite:1'
            'LITELLM_CLIENT_KEY=ck'
            'DUP_KEY=first_value'
            "#@if $($script:OsBlockToken)"
            'DUP_KEY=second_value_inside_active_block'
            '#@endif'
        )
    }

    It 'loads KEY=value lines and ignores comments and blanks' {
        $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-dotenv:9' 'dotenv: base URL comes from .env'
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'dotenv-token' 'dotenv: auth token comes from .env'
    }

    It 'trims surrounding whitespace around key and value' {
        $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher
        Assert-LauncherEnv $r 'TRIM_PROBE_KEY' 'trimmed_value' 'dotenv: whitespace-padded KEY = value is trimmed'
    }

    It 'a non-empty shell value outranks .env' {
        $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher `
            -Environment @{ LITELLM_ANTHROPIC_BASE_URL = 'https://from-shell:1' }
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-shell:1' 'dotenv: shell wins over .env'
    }

    It 'a defined-but-empty shell value is treated as unset, so .env still applies' {
        # Every consumer below treats empty as unset, so honouring the empty shell
        # value would silently discard the .env entry.
        $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher `
            -Environment @{ LITELLM_ANTHROPIC_BASE_URL = '' }
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-dotenv:9' 'dotenv: empty shell value must not shadow .env'
    }

    It 'a missing .env is not an error when the shell supplies the configuration' {
        $bare = Join-Path $script:Work 'fixture-no-dotenv'
        New-Item -ItemType Directory -Path (Join-Path $bare 'scripts') -Force | Out-Null
        Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $bare 'scripts' 'code-ccgw.ps1') -Force
        # The tree is hand-built rather than New-FixtureTree'd precisely so that
        # .env is absent; config.yaml is a separate concern and must still be
        # there, or this case would pass through the missing-config guard instead.
        New-FixtureConfigYaml -Root $bare | Out-Null
        $r = Invoke-Launcher -LauncherPath (Join-Path $bare 'scripts' 'code-ccgw.ps1') -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'dotenv/absent: launcher still runs'
    }

    It '[env-conditional-blocks: case 1] only the active platform block''s value survives' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase1
        $expected = Get-OsBlockExpected -WindowsValue 'win_value' -PosixValue 'posix_value'
        Assert-LauncherEnv $r 'BASIC_KEY' $expected "os-block/case1 (host token: $($script:OsBlockToken))"
    }

    It '[env-conditional-blocks: case 2] marker lines never leak into the loaded env' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase1
        $leaked = @($r.Env.Keys | Where-Object { $r.Env[$_] -match '#@if|#@endif' })
        $leaked.Count | Should -Be 0 -Because "marker syntax must never appear in an exported value; found in: $($leaked -join ', ')"
    }

    It '[env-conditional-blocks: case 3] plain lines outside any block are unconditional' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase3
        Assert-LauncherEnv $r 'PLAIN_KEY' 'plain_value' 'os-block/case3'
    }

    It '[env-conditional-blocks: case 4] blank lines outside marker blocks are preserved' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase4
        Assert-LauncherEnv $r 'BEFORE_KEY' 'before_value' 'os-block/case4'
        Assert-LauncherEnv $r 'AFTER_KEY' 'after_value' 'os-block/case4'
    }

    It '[env-conditional-blocks: case 5] nesting does not leak -- an inactive outer block suppresses a would-be-active nested block' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase5
        Assert-LauncherEnvUnset $r 'OUTER_KEY' "os-block/case5 (host token: $($script:OsBlockToken))"
        Assert-LauncherEnvUnset $r 'INNER_KEY' 'os-block/case5: suppressDepth must pin at the outer depth'
    }

    It '[env-conditional-blocks: case 6] nesting does not leak the other way -- an active outer block only removes the nested inactive block' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase6
        Assert-LauncherEnv $r 'BEFORE_KEY' 'before_value' "os-block/case6 (host token: $($script:OsBlockToken))"
        Assert-LauncherEnvUnset $r 'NESTED_KEY' 'os-block/case6: the nested inactive block must be removed'
        Assert-LauncherEnv $r 'AFTER_KEY' 'after_value' 'os-block/case6: content after the nested block, still inside the active outer block, must load'
    }

    It '[env-conditional-blocks: case 7] an unrecognized token suppresses its block on any host' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase7
        Assert-LauncherEnvUnset $r 'UNKNOWN_TOKEN_KEY' "os-block/case7 (host token: $($script:OsBlockToken))"
    }

    It '[env-conditional-blocks: case 8] non-strict spelling ("#@ifwindows", no space) opens no block' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase8
        Assert-LauncherEnv $r 'FOLLOW_KEY' 'should_always_appear' "os-block/case8 (host token: $($script:OsBlockToken))"
    }

    It '[env-conditional-blocks: case 9] an orphan #@endif is a no-op' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase9
        Assert-LauncherEnv $r 'BEFORE_KEY' 'before_value' 'os-block/case9'
        Assert-LauncherEnv $r 'AFTER_KEY' 'after_value' 'os-block/case9'
    }

    It '[env-conditional-blocks: case 10] "#@endif foo" (trailing text) never closes the block -- deliberately non-lenient' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase10
        Assert-LauncherEnvUnset $r 'INSIDE_KEY' "os-block/case10: #@if $($script:OsBlockOtherToken) is inactive on this host (token: $($script:OsBlockToken))"
        Assert-LauncherEnvUnset $r 'AFTER_KEY' 'os-block/case10: "#@endif foo" does not close the block, so suppression never lifts'
    }

    It '[env-conditional-blocks: case 11] CRLF-saved markers resolve identically to LF' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase11
        $expected = Get-OsBlockExpected -WindowsValue 'win_value' -PosixValue 'posix_value'
        Assert-LauncherEnv $r 'BASIC_KEY' $expected "os-block/case11 (host token: $($script:OsBlockToken))"
    }

    It '[env-conditional-blocks: case 12] whitespace-padded marker lines are still recognized' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase12
        $expected = Get-OsBlockExpected -WindowsValue 'win_value' -PosixValue 'posix_value'
        Assert-LauncherEnv $r 'PAD_KEY' $expected "os-block/case12 (host token: $($script:OsBlockToken))"
    }

    It '[env-conditional-blocks: case 13] duplicate keys -- first occurrence wins' {
        $r = Invoke-Launcher -LauncherPath $script:OsBlockCase13
        Assert-LauncherEnv $r 'DUP_KEY' 'first_value' "os-block/case13: the loader skips re-setting an already-set var (host token: $($script:OsBlockToken))"
    }
}
