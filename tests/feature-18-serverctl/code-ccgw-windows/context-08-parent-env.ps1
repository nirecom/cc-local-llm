#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '8. The invoking shell keeps its own environment (issue #66)' {
    # Contexts 1-7 all read the CHILD's environment, and the defect reported in
    # #66 lives in the PARENT's: PowerShell has no exec, so a launcher that
    # assigns to `$env:` outlives the VS Code launch and leaves those values in
    # the shell the developer typed the command into. The next, unrelated cloud
    # Claude Code session started from that same shell then inherits local-LLM
    # routing. Only Invoke-LauncherInParentShell can see it: it interposes a
    # wrapper that runs the launcher in its own process and snapshots its
    # environment on either side.
    #
    # Why every variable the launcher sets carries a sentinel rather than just
    # ANTHROPIC_API_KEY (which is all the suite used to pre-seed): the two failure
    # shapes are different and each hides on a different variable. "Assigned, then
    # never cleaned up" leaves the launcher's value behind; "assigned, then
    # removed" deletes a value the shell already had. 8b names the offending
    # variable in its own message so either shape points straight at the
    # assignment that caused it.
    #
    # 8b and 8e are deliberately a pair, and read the SAME run: "the parent is
    # untouched" is satisfied just as well by a launcher that computes nothing at
    # all, so the child must be shown to have received the correctly-computed
    # values in the very same launch (CPR-E2E).
    #
    # 8g-8j carry the same contract onto the paths that do NOT reach a launch.
    # Every one of them fails partway through the resolution sequence, which is
    # precisely where a half-applied environment would be abandoned in the shell:
    # a launcher that unwound its own writes only on the happy path would satisfy
    # 8a and still poison the shell of every developer who mistyped a variable
    # name. They also assert the negative that a snapshot comparison cannot see --
    # no VS Code was started -- and that the refusal message did not echo the
    # credential back.

    BeforeAll {
        # One map, two roles (CPR-SSOT): its keys are the variables that must
        # survive untouched in the parent, its values are what the child must
        # receive for each of them given the fixture .env below.
        $script:Ctx8ExpectedChild = [ordered]@{
            ANTHROPIC_BASE_URL                        = 'https://ctx8-lite:1'
            ANTHROPIC_AUTH_TOKEN                      = 'ctx8-client-key'
            NODE_EXTRA_CA_CERTS                       = 'C:\ctx8\ca.pem'
            ANTHROPIC_DEFAULT_FABLE_MODEL             = 'ctx8-fable'
            ANTHROPIC_DEFAULT_OPUS_MODEL              = 'ctx8-opus'
            ANTHROPIC_DEFAULT_SONNET_MODEL            = 'ctx8-sonnet'
            ANTHROPIC_DEFAULT_HAIKU_MODEL             = 'ctx8-haiku'
            ANTHROPIC_MODEL                           = 'ctx8-fable'
            ANTHROPIC_CUSTOM_MODEL_OPTION             = 'ctx8-fable'
            ANTHROPIC_CUSTOM_MODEL_OPTION_NAME        = 'Local model via ccgw'
            ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = 'Mac backend via the LiteLLM gateway, selected per request'
            CLAUDE_CODE_SUBAGENT_MODEL                = 'ctx8-subagent'
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC  = '1'
            CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = '1'
            CLAUDE_STREAM_IDLE_TIMEOUT_MS             = '600000'
            CLAUDE_CODE_AUTO_COMPACT_WINDOW           = '65536'
            CLAUDE_AUTOCOMPACT_PCT_OVERRIDE           = '75'
        }
        # ANTHROPIC_API_KEY is deliberately NOT in that map: its contract is the
        # opposite shape ("the child must see no key at all"), so it gets its own
        # case, 8d.
        $script:MustVars = @($script:Ctx8ExpectedChild.Keys)

        # Every routing key set, so each variable above is genuinely computed to
        # something OTHER than its sentinel -- a launcher that quietly stopped
        # exporting anything must not be able to pass 8b.
        $script:Ctx8Launcher = New-FixtureTree -Name 'fixture-ctx8' -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://ctx8-lite:1'
            'LITELLM_CLIENT_KEY=ctx8-client-key'
            'CCGW_CA_CERT=C:\ctx8\ca.pem'
            'LITELLM_FABLE_MODEL=ctx8-fable'
            'LITELLM_OPUS_MODEL=ctx8-opus'
            'LITELLM_SONNET_MODEL=ctx8-sonnet'
            'LITELLM_HAIKU_MODEL=ctx8-haiku'
            'CCGW_SUBAGENT_MODEL=ctx8-subagent'
            'BASIC_KEY=ctx8-basic'
        )
        # Keys the .env introduces that the shell never had. They exist to prove
        # the loader's own writes do not land in the shell either (8c).
        $script:Ctx8DotEnvOnlyKeys = @(
            'BASIC_KEY', 'LITELLM_ANTHROPIC_BASE_URL', 'LITELLM_CLIENT_KEY',
            'CCGW_CA_CERT', 'LITELLM_FABLE_MODEL', 'LITELLM_OPUS_MODEL',
            'LITELLM_SONNET_MODEL', 'LITELLM_HAIKU_MODEL', 'CCGW_SUBAGENT_MODEL'
        )

        $script:Ctx8ApiKey = 'cloud-key-must-survive-in-parent'

        # The shell the developer typed the command into: every variable the
        # launcher touches already holds a value of the user's own. Reused by the
        # failure cases so they police the same names as 8b.
        function New-Ctx8ParentEnv {
            param([hashtable]$Config = @{})
            $h = @{ ANTHROPIC_API_KEY = $script:Ctx8ApiKey }
            foreach ($n in $script:MustVars) { $h[$n] = "PARENT-SENTINEL-$n-KEEP" }
            foreach ($k in $Config.Keys) { $h[$k] = $Config[$k] }
            return $h
        }

        # The credential the failure cases hand in. Distinct from the happy path's
        # so a leak assertion cannot be satisfied by the wrong run's value.
        $script:Ctx8ErrKey = 'ctx8-error-path-secret-key'

        # One launch, read by every case below, so the cases cannot disagree about
        # what happened (CPR-SSOT) and the suite pays for it once.
        $script:Ctx8 = Invoke-LauncherInParentShell `
            -Environment (New-Ctx8ParentEnv) -LauncherPath $script:Ctx8Launcher
    }

    It '8a. the invoking shell''s environment is byte-for-byte identical before and after' {
        # Stated as a zero-difference contract rather than as a list of forbidden
        # names: a variable nobody thought to enumerate is exactly the one a future
        # assignment would leak (CPR-UNV).
        Assert-ParentEnvUnchanged $script:Ctx8 'ctx8/happy-path'
    }

    It '8b. every variable the launcher sets keeps its pre-existing value in the invoking shell' {
        $after = $script:Ctx8.AfterEnv
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($name in $script:MustVars) {
            $expected = "PARENT-SENTINEL-$name-KEEP"
            if (-not $after.ContainsKey($name)) {
                $bad.Add("$name was REMOVED from the invoking shell")
            } elseif ($after[$name] -cne $expected) {
                $bad.Add("$name = '$($after[$name])' (expected the untouched '$expected')")
            }
        }
        $bad.Count | Should -Be 0 -Because "issue #66: $($bad -join '; ')"
    }

    It '8c. keys the launcher loaded from .env do not land in the invoking shell either' {
        $after = $script:Ctx8.AfterEnv
        $leaked = @($script:Ctx8DotEnvOnlyKeys | Where-Object { $after.ContainsKey($_) })
        $leaked.Count | Should -Be 0 -Because "the .env loader must populate the child's block, not the shell's; leaked: $($leaked -join ', ')"
    }

    It '8d. a real cloud ANTHROPIC_API_KEY survives in the shell but never reaches the child' {
        # Two halves of one contract, and the launcher used to get both wrong in
        # the same statement: `$env:ANTHROPIC_API_KEY = ''` destroyed the
        # developer's real key in their own shell while it was blanking it for VS
        # Code.
        $script:Ctx8.AfterEnv['ANTHROPIC_API_KEY'] | Should -BeExactly $script:Ctx8ApiKey `
            -Because 'blanking the key for VS Code must not blank it for the shell'
        $got = if ($script:Ctx8.Env.ContainsKey('ANTHROPIC_API_KEY')) { $script:Ctx8.Env['ANTHROPIC_API_KEY'] } else { $null }
        [string]::IsNullOrEmpty($got) | Should -BeTrue -Because "ANTHROPIC_API_KEY reached the child as '$got'"
    }

    It '8e. the same launch still hands the computed values to the child' {
        $script:Ctx8.Reached | Should -BeTrue -Because "stderr: $($script:Ctx8.StdErr)"
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($name in $script:MustVars) {
            $expected = [string]$script:Ctx8ExpectedChild[$name]
            if (-not $script:Ctx8.Env.ContainsKey($name)) {
                $bad.Add("$name never reached the child (expected '$expected')")
            } elseif ($script:Ctx8.Env[$name] -cne $expected) {
                $bad.Add("$name = '$($script:Ctx8.Env[$name])' (expected '$expected')")
            }
        }
        $bad.Count | Should -Be 0 -Because "protecting the parent must not mean starving the child: $($bad -join '; ')"
    }

    It '8f. the gateway credential never appears in the launcher''s own output' {
        # The credential is the one secret the launcher handles; a diagnostic that
        # echoes it would put it into terminal scrollback and CI logs (OWASP ASVS
        # V8).
        Assert-NoSecretInOutput $script:Ctx8 @('ctx8-client-key', $script:Ctx8ApiKey) 'ctx8/happy-path'
    }

    It '8g. an unset base URL refuses without touching the invoking shell' {
        # The earliest exit there is: it happens after ANTHROPIC_API_KEY has
        # already been dealt with, which is exactly the write that used to destroy
        # the developer's own key on the way out.
        $r = Invoke-LauncherInParentShell -LauncherPath $script:Launcher `
            -Environment (New-Ctx8ParentEnv @{ LITELLM_CLIENT_KEY = $script:Ctx8ErrKey })
        $r.LauncherExitCode | Should -Not -Be '0' -Because "an unconfigured base URL must not exit 0; stderr: $($r.StdErr)"
        Assert-ParentEnvUnchanged $r 'ctx8/base-url-unset'
        Assert-NoChildLaunched $r 'ctx8/base-url-unset'
        Assert-NoSecretInOutput $r @($script:Ctx8ErrKey, $script:Ctx8ApiKey) 'ctx8/base-url-unset'
    }

    It '8h. an unset credential refuses without touching the invoking shell' {
        # One statement further in: the base URL has been resolved, so a launcher
        # that writes as it goes has already made its first assignment when this
        # guard fires.
        #
        # Two credentials are in scope on this path even though neither is
        # accepted: the shell's own ANTHROPIC_API_KEY, which the launcher has
        # already handled by the time the guard fires, and a value under a retired
        # name -- the half-migrated .env that produces this error in real life.
        # The refusal is written precisely when the launcher is trying to be
        # helpful about credentials, so both must be shown to stay out of it.
        $ctx8hEnv = New-Ctx8ParentEnv @{ LITELLM_ANTHROPIC_BASE_URL = 'https://ctx8-err:1' }
        $ctx8hEnv[$script:RKeyCcgw] = $script:Ctx8ErrKey
        $r = Invoke-LauncherInParentShell -LauncherPath $script:Launcher -Environment $ctx8hEnv
        $r.LauncherExitCode | Should -Not -Be '0' -Because "a missing credential must not exit 0; stderr: $($r.StdErr)"
        Assert-ParentEnvUnchanged $r 'ctx8/credential-unset'
        Assert-NoChildLaunched $r 'ctx8/credential-unset'
        Assert-NoSecretInOutput $r @($script:Ctx8ErrKey, $script:Ctx8ApiKey) 'ctx8/credential-unset'
    }

    It '8i. a missing `code` refuses without touching the invoking shell' {
        # The far end of the resolution sequence: every value has been computed by
        # the time this guard fires, so this is the case that leaks the MOST if
        # the values went into the launcher's own process.
        $r = Invoke-LauncherInParentShell -LauncherPath $script:Ctx8Launcher -StubDir $script:StubNoCode `
            -Environment (New-Ctx8ParentEnv)
        $r.LauncherExitCode | Should -Not -Be '0' -Because "a missing code command must not exit 0; stderr: $($r.StdErr)"
        Assert-ParentEnvUnchanged $r 'ctx8/missing-code'
        Assert-NoChildLaunched $r 'ctx8/missing-code'
        Assert-NoSecretInOutput $r @('ctx8-client-key', $script:Ctx8ApiKey) 'ctx8/missing-code'
    }

    It '8j. a `code` that cannot be started refuses without touching the invoking shell' -Skip:(-not $IsWindows) {
        # Past the last guard: `code` resolves, so the launcher commits to the
        # launch and CreateProcess is what fails. Nothing after this point can be
        # rolled back, which is why the environment must never have been written
        # in the first place.
        $r = Invoke-LauncherInParentShell -LauncherPath $script:Ctx8Launcher -StubDir $script:StubBrokenExe `
            -Environment (New-Ctx8ParentEnv)
        $r.LauncherExitCode | Should -Not -Be '0' -Because "a failed process start must be reported, not swallowed; stderr: $($r.StdErr)"
        Assert-ParentEnvUnchanged $r 'ctx8/process-start-failure'
        Assert-NoChildLaunched $r 'ctx8/process-start-failure'
        Assert-NoSecretInOutput $r @('ctx8-client-key', $script:Ctx8ApiKey) 'ctx8/process-start-failure'
    }
}
