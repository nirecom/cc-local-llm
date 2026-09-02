#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, config, ssot, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# the SHAPE of the file every other context assumes it can read -- how its lines
# end, and what happens when it cannot be read at all. POSIX sibling: case 15 of
# test-code-ccgw-config-tiers-2.sh for the line endings (CPR-ORTH).

Context '19. config.yaml file shape: line endings, and a file that will not open' -Skip:(-not $IsWindows) {
    # Every other context builds its config.yaml with Set-Content, whose Windows
    # default is CRLF, so the whole suite has been asserting one ending only.
    # config.yaml is shared between hosts through git, and a macOS commit reaches
    # this launcher LF-terminated -- the ending no case here has ever read.
    BeforeAll {
        $script:Ctx19CommentFormLines = @(
            'model_list:'
            '  - model_name: lite-shared'
            '    # ccgw-tiers: haiku sonnet subagent'
            '    litellm_params:'
            '      model: openai/Qwen3.8-27B'
            ''
            '  - model_name: lite-fable'
            '    # ccgw-tiers: fable'
            '    litellm_params:'
            '      model: openai/DeepSeek-V4-Flash'
            ''
            '  - model_name: lite-opus'
            '    # ccgw-tiers: opus'
            '    litellm_params:'
            '      model: openai/Qwen3.8-Flash-Next'
        )
    }

    It '19a. the <Form> annotation is read from a <Ending>-terminated file' -ForEach @(
        @{ Form = 'key'; Ending = 'CRLF'; Newline = "`r`n" }
        @{ Form = 'key'; Ending = 'LF'; Newline = "`n" }
        @{ Form = 'comment'; Ending = 'CRLF'; Newline = "`r`n" }
        @{ Form = 'comment'; Ending = 'LF'; Newline = "`n" }
    ) {
        # The CR lands exactly where both forms anchor their end -- inside
        # `[opus]<CR>` for the key form, inside the captured token list for the
        # comment form. A reader written against one ending either maps no tier
        # at all or maps one to a key with a trailing CR that no /model entry can
        # match, and the operator sees a client that starts fine and routes to
        # nothing. Asserting the exact key, not merely that something was
        # exported, is what makes a surviving CR a failure here.
        $launcher = New-FixtureTree -Name "ctx19-$Form-$Ending"
        $root = Get-FixtureRoot $launcher
        $lines = if ($Form -eq 'comment') { $script:Ctx19CommentFormLines } else { $script:DefaultConfigYamlLines }
        $path = Join-Path (Join-Path $root 'litellm-server') 'config.yaml'
        [System.IO.File]::WriteAllText($path, (($lines -join $Newline) + $Newline),
            (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "config-shape/$Form-$Ending`: stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' "config-shape/$Form-$Ending`: opus tier"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-fable' "config-shape/$Form-$Ending`: fable tier"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-shared' "config-shape/$Form-$Ending`: haiku tier"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'lite-shared' "config-shape/$Form-$Ending`: sonnet tier"
        Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'lite-shared' "config-shape/$Form-$Ending`: the subagent route"
    }

    It '19b. a config.yaml that cannot be opened is a hard failure, not a silent launch' {
        # The file exists, so the launcher's "is it there" guard says yes and the
        # read is what fails -- an ACL an org policy applied, a file another
        # process holds, a profile restored without its permissions. Windows-only
        # by construction: the read-only ATTRIBUTE does not stop a read, so an
        # explicit deny ACE is the only way to make this file unreadable, and it
        # has no POSIX sibling. Launching anyway would hand Claude Code an empty
        # /model list and turn an unreadable file into a routing mystery hours
        # later, so the contract is the same as for an absent file: exit 1, say
        # which file, start nothing.
        $launcher = New-FixtureTree -Name 'ctx19-denied'
        $root = Get-FixtureRoot $launcher
        $path = Join-Path (Join-Path $root 'litellm-server') 'config.yaml'
        $dotEnv = Join-Path $root '.env'
        $dotEnvBefore = [System.IO.File]::ReadAllText($dotEnv)
        $account = "$($env:USERDOMAIN)\$($env:USERNAME)"

        try {
            & icacls $path '/deny' "$($account):(R)" 2>&1 | Out-Null
            $readable = $true
            try { [System.IO.File]::ReadAllText($path) | Out-Null } catch { $readable = $false }
            if ($readable) {
                Set-ItResult -Skipped -Because 'the deny ACE did not take effect for this account (elevated, or a backup privilege overrides it), so nothing about an unreadable file could be proven'
                return
            }

            $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env)
            $r.ExitCode | Should -Be 1 -Because "config-shape/denied: an unreadable routing table must be fatal; stderr: $($r.StdErr)"
            Assert-NoChildLaunched $r 'config-shape/denied'
            Assert-Stderr $r 'config.yaml' 'config-shape/denied: the error must name the file it could not read'
        } finally {
            & icacls $path '/remove:d' $account 2>&1 | Out-Null
        }

        Test-Path -LiteralPath $path | Should -BeTrue -Because 'config-shape/denied: the launcher deleted or replaced a file it could not even read'
        [System.IO.File]::ReadAllText($dotEnv) | Should -BeExactly $dotEnvBefore `
            -Because 'config-shape/denied: a refusal rewrote the .env beside the file it refused over'
    }

    It '19c. a config.yaml that maps no tier at all is a hard failure: <Shape>' -ForEach @(
        @{ Shape = 'zero-byte'; Body = '' }
        @{ Shape = 'model_list-with-no-routes'; Body = "model_list:`n" }
    ) {
        # The POSIX siblings are cases 4 and 5 of test-code-ccgw-config-guards.sh
        # (CPR-ORTH). Both files are perfectly readable, so 19b's guard has
        # nothing to say about them: the read succeeds and returns a routing
        # table with nothing in it. Launching on that is the worst of the three
        # outcomes -- Claude Code comes up, every /model entry is missing or
        # inherited from whatever the parent environment happened to carry, and
        # the operator debugs a routing problem instead of a config one. An
        # empty file is also what a truncated write and an interrupted git
        # checkout both leave behind, so this is a state reachable without
        # anybody hand-editing anything.
        $launcher = New-FixtureTree -Name "ctx19-empty-$Shape"
        $root = Get-FixtureRoot $launcher
        $path = Join-Path (Join-Path $root 'litellm-server') 'config.yaml'
        [System.IO.File]::WriteAllText($path, $Body, (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env)
        $r.ExitCode | Should -Not -Be 0 -Because "config-shape/$Shape`: a config.yaml that names no tier must not launch a client that routes nowhere; stderr: $($r.StdErr)"
        Assert-NoChildLaunched $r "config-shape/$Shape"
        ([string]$r.StdErr + [string]$r.StdOut) | Should -Match 'config\.yaml|ccgw[_-]tiers' `
            -Because "config-shape/$Shape`: the error has to name the file or the annotation it found none of, or the operator has nothing to go and look at"
    }
}
