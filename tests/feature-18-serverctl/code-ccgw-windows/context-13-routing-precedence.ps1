#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '13. Routing keys: .env outranks the inherited shell, and the shell keeps its own value' {
    # Two rules, five keys only: PR #63's inversion (.env always wins here,
    # unlike every other key -- per-key since $ModelRoutingKeys can lose an
    # entry in a rename, CPR-ORTH) and issue #66 (winning must not mean
    # OVERWRITING the shell's value -- one launch proves both, CPR-E2E).
    # One fixture per key: a partial fix would still pass a combined run.

    $ctx13Rows = @(
        @{ Key = 'LITELLM_HAIKU_MODEL'; Child = 'ANTHROPIC_DEFAULT_HAIKU_MODEL' }
        @{ Key = 'LITELLM_SONNET_MODEL'; Child = 'ANTHROPIC_DEFAULT_SONNET_MODEL' }
        @{ Key = 'LITELLM_FABLE_MODEL'; Child = 'ANTHROPIC_DEFAULT_FABLE_MODEL' }
        @{ Key = 'LITELLM_OPUS_MODEL'; Child = 'ANTHROPIC_DEFAULT_OPUS_MODEL' }
        @{ Key = 'CCGW_SUBAGENT_MODEL'; Child = 'CLAUDE_CODE_SUBAGENT_MODEL' }
    )

    It '13a. <Key>: .env drives <Child> in the child, and the invoking shell keeps its own value' -ForEach $ctx13Rows {
        $dotEnvValue = "ctx13-dotenv-$Key"
        $inherited = "INHERITED-$Key-MUST-NOT-WIN-AND-MUST-SURVIVE"

        $fixture = New-FixtureTree -Name "fixture-ctx13-$Key" -DotEnvLines @(
            'LITELLM_ANTHROPIC_BASE_URL=https://ctx13-lite:1'
            'LITELLM_CLIENT_KEY=ctx13-client-key'
            "$Key=$dotEnvValue"
        )

        # The invoking shell already holds a conflicting value for this key, the
        # way a shell that launched an older revision of the repo would.
        $r = Invoke-LauncherInParentShell -LauncherPath $fixture -Environment @{ $Key = $inherited }
        $r.LauncherExitCode | Should -Be '0' -Because "stderr: $($r.StdErr)"

        # Half one: .env won on the way to the child.
        Assert-LauncherEnv $r $Child $dotEnvValue "ctx13/$Key`: a routing key must always come from .env, never from an inherited shell value"

        # Half two: winning did not cost the shell its own value.
        $after = $r.AfterEnv
        $after.ContainsKey($Key) | Should -BeTrue -Because "issue #66: $Key was REMOVED from the shell that invoked the launcher"
        $after[$Key] | Should -BeExactly $inherited -Because "issue #66: the launcher overwrote $Key in the shell that invoked it"

        # And no other name was disturbed either -- the per-key check above cannot
        # see a value the launcher pushed onto some neighbouring variable.
        Assert-ParentEnvUnchanged $r "ctx13/$Key"
    }
}
