#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '13. Routing: config.yaml is the only source, and the invoking shell keeps its own value' {
    # Three rules, five tiers, one launch each. Issue #89 replaced PR #63's
    # ".env outranks the shell" inversion with something stronger: neither is a
    # source at all, so a stale value in EITHER place has to lose to the
    # annotation. Issue #66's rule still rides along -- winning must not mean
    # OVERWRITING the shell's value. Per-tier rather than combined because a
    # partial fix would still pass a single run that set every tier at once.

    $ctx13Rows = @(
        @{ Tier = 'haiku'; Key = 'LITELLM_HAIKU_MODEL'; Child = 'ANTHROPIC_DEFAULT_HAIKU_MODEL' }
        @{ Tier = 'sonnet'; Key = 'LITELLM_SONNET_MODEL'; Child = 'ANTHROPIC_DEFAULT_SONNET_MODEL' }
        @{ Tier = 'fable'; Key = 'LITELLM_FABLE_MODEL'; Child = 'ANTHROPIC_DEFAULT_FABLE_MODEL' }
        @{ Tier = 'opus'; Key = 'LITELLM_OPUS_MODEL'; Child = 'ANTHROPIC_DEFAULT_OPUS_MODEL' }
        @{ Tier = 'subagent'; Key = 'CCGW_SUBAGENT_MODEL'; Child = 'CLAUDE_CODE_SUBAGENT_MODEL' }
    )

    It '13a. <Tier>: config.yaml drives <Child>, beating a stale <Key> in both .env and the shell' -ForEach $ctx13Rows {
        $configValue = "ctx13-config-$Tier"
        $dotEnvValue = "ctx13-dotenv-$Key-MUST-NOT-WIN"
        $inherited = "INHERITED-$Key-MUST-NOT-WIN-AND-MUST-SURVIVE"

        # The route claims ONLY this tier, so a launcher that mapped the whole
        # vocabulary onto one route could not pass every row.
        $fixture = New-FixtureTree -Name "fixture-ctx13-$Tier" -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://ctx13-lite:1'
            'LITELLM_CLIENT_KEY=ctx13-client-key'
            "$Key=$dotEnvValue"
        ) -ConfigYamlLines @(
            'model_list:'
            "  - model_name: $configValue"
            '    litellm_params:'
            '      model: openai/Backend-A'
            "      ccgw_tiers: [$Tier]"
        )

        # The invoking shell already holds a conflicting value for this key, the
        # way a shell that launched an older revision of the repo would.
        $r = Invoke-LauncherInParentShell -LauncherPath $fixture -Environment @{ $Key = $inherited }
        $r.LauncherExitCode | Should -Be '0' -Because "stderr: $($r.StdErr)"

        # Half one: the annotation won on the way to the child, over both stale
        # copies at once. This is the 2026-08-22 failure stated per tier.
        Assert-LauncherEnv $r $Child $configValue "ctx13/$Tier`: the tier must come from config.yaml, never from .env or an inherited shell value"

        # Half two: winning did not cost the shell its own value.
        $after = $r.AfterEnv
        $after.ContainsKey($Key) | Should -BeTrue -Because "issue #66: $Key was REMOVED from the shell that invoked the launcher"
        $after[$Key] | Should -BeExactly $inherited -Because "issue #66: the launcher overwrote $Key in the shell that invoked it"

        # And no other name was disturbed either -- the per-key check above cannot
        # see a value the launcher pushed onto some neighbouring variable.
        Assert-ParentEnvUnchanged $r "ctx13/$Tier"
    }

    It '13b. <Tier>: no route claiming it leaves <Child> unset even when <Key> is set everywhere' -ForEach $ctx13Rows {
        # The complement of 13a, and the case a "fall back to the env when the
        # config says nothing" implementation passes 13a but fails: silence in the
        # config has to mean silence in the child, not a return to the old source.
        # One tier IS claimed -- some other one -- so this is "the config is
        # silent about THIS tier", not "the config annotates nothing", which is a
        # different contract (context-16, a hard failure).
        $other = if ($Tier -eq 'opus') { 'haiku' } else { 'opus' }
        $fixture = New-FixtureTree -Name "fixture-ctx13-silent-$Tier" -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://ctx13-lite:1'
            'LITELLM_CLIENT_KEY=ctx13-client-key'
            "$Key=ctx13-dotenv-fallback-must-not-happen"
        ) -ConfigYamlLines @(
            'model_list:'
            '  - model_name: ctx13-unrelated'
            '    litellm_params:'
            '      model: openai/Backend-A'
            "      ccgw_tiers: [$other]"
        )

        $r = Invoke-Launcher -LauncherPath $fixture -Environment @{ $Key = 'ctx13-shell-fallback-must-not-happen' }

        # "Absent from the child" is also what a launcher that died before ever
        # starting the child produces, so the run itself is pinned first -- the
        # same full assertion set 13a carries (CPR-ORTH). Without these three the
        # row below is green on a launcher that never ran.
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "ctx13/$Tier`: the stub 'code' was never reached, so an unset $Child proves nothing"

        Assert-LauncherEnvUnset $r $Child "ctx13/$Tier`: an unclaimed tier must stay unset, not fall back to the retired key"

        # And the tier the config DOES claim still resolved: silence about this
        # tier must not be silence about the whole file.
        # Derived here rather than read off $ctx13Rows: that table is a discovery
        # -phase variable and is not in scope while the It body runs.
        $otherChild = "ANTHROPIC_DEFAULT_$($other.ToUpperInvariant())_MODEL"
        Assert-LauncherEnv $r $otherChild 'ctx13-unrelated' "ctx13/$Tier`: the neighbouring $other route must still resolve while $Tier is unclaimed"
    }
}
