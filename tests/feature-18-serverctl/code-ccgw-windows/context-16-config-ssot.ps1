#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, config, ssot, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# the annotation grammar itself. Context 4 asserts what a well-formed config
# produces; this asserts what the reader must do with the shapes a hand-edited
# YAML file actually takes. POSIX sibling: test-code-ccgw-config-tiers.sh.

Context '16. The ccgw_tiers annotation grammar (issue #89)' {
    # TL3 gap: whether LiteLLM itself accepts `ccgw_tiers` inside litellm_params
    # rather than rejecting it as an unknown parameter. Only a real server start
    # answers that; the docs/ops.md cutover smoke run at USER_VERIFIED covers it.

    It '16a. one route claiming several tiers maps all of them to the same name' {
        # The shape the repo actually ships: haiku, sonnet and the subagent route
        # share one backend. A reader that took only the first token would leave
        # the other two tiers unset and nobody would notice until a /model switch.
        $r = Invoke-Launcher -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        foreach ($tier in @('haiku', 'sonnet', 'subagent')) {
            Assert-LauncherEnv $r $script:TierRows[$tier] 'lite-shared' "config-ssot/shared: the $tier tier"
        }
    }

    It '16b. the comment form of the annotation is equivalent to the mapping form' {
        # Format F in the plan: a `# ccgw-tiers: ...` line for a LiteLLM version
        # that rejects unknown keys inside litellm_params. Placement is part of
        # the form, not decoration -- three conditions: inside the block, indent
        # >= 4, and on the block's SECOND line (the one right after
        # `- model_name:`). Tokens are space-separated. Both spellings have to
        # produce the same map or the fallback is a trap.
        $fixture = New-FixtureTree -Name 'fixture-ctx16-comment-form' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-shared'
            '    # ccgw-tiers: haiku sonnet subagent'
            '    litellm_params:'
            '      model: openai/Backend-A'
            ''
            '  - model_name: lite-fable'
            '    # ccgw-tiers: fable'
            '    litellm_params:'
            '      model: openai/Backend-B'
            ''
            '  - model_name: lite-opus'
            '    # ccgw-tiers: opus'
            '    litellm_params:'
            '      model: openai/Backend-C'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        foreach ($tier in $script:TierRows.Keys) {
            Assert-LauncherEnv $r $script:TierRows[$tier] $script:FixtureTierValues[$tier] "config-ssot/comment-form: the $tier tier"
        }
    }

    It '16b2. a comment-form annotation ABOVE its route is not adopted (C2)' {
        # The format-F trap the plan's risk list calls out by name: written above
        # `- model_name:` the line reads like a heading for what follows, but it
        # falls outside the block. A reader that took it anyway would drop the
        # first route's annotation and shift every later one by a route -- not a
        # crash, just a different tier pointing at a different backend, silently.
        #
        # `lite-shared` here therefore claims nothing, and the assertion is
        # two-sided: neither the route below the misplaced line nor the route
        # above it may end up owning haiku/sonnet/subagent.
        $fixture = New-FixtureTree -Name 'fixture-ctx16-comment-above' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-opus'
            '    # ccgw-tiers: opus'
            '    litellm_params:'
            '      model: openai/Backend-C'
            ''
            '    # ccgw-tiers: haiku sonnet subagent'
            '  - model_name: lite-shared'
            '    litellm_params:'
            '      model: openai/Backend-A'
            ''
            '  - model_name: lite-fable'
            '    # ccgw-tiers: fable'
            '    litellm_params:'
            '      model: openai/Backend-B'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "two routes are still annotated correctly; stderr: $($r.StdErr)"
        foreach ($tier in @('haiku', 'sonnet', 'subagent')) {
            Assert-LauncherEnvUnset $r $script:TierRows[$tier] "config-ssot/comment-above: a misplaced annotation must map nothing, but $tier was set"
        }
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'config-ssot/comment-above: the route ABOVE the misplaced line must keep its own tiers'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-fable' 'config-ssot/comment-above: a well-formed route elsewhere in the file is unaffected'
    }

    It '16c. an annotation between two routes belongs to neither (C2)' {
        # The block-boundary bug the review caught: a reader that scans forward
        # from `model_name` until "something that looks like a new block" can walk
        # past the banner comments the real file uses and absorb the NEXT route's
        # annotation. Here the stray line sits outside any route, so a correct
        # reader adopts it for nothing and leaves the opus tier as the second
        # route declared it.
        $fixture = New-FixtureTree -Name 'fixture-ctx16-stray' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-first'
            '    litellm_params:'
            '      model: openai/Backend-A'
            '      ccgw_tiers: [haiku, sonnet, fable, subagent]'
            ''
            '  # --- a banner, then an annotation attached to nothing ---'
            '  # ccgw-tiers: opus'
            ''
            '  - model_name: lite-second'
            '    litellm_params:'
            '      model: openai/Backend-B'
            '      ccgw_tiers: [opus]'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-second' 'config-ssot/stray: the stray annotation must not re-point the opus tier'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-first' 'config-ssot/stray: the first route must keep its own tiers'
    }

    It '16d. a token outside the tier vocabulary is reported, not silently dropped' {
        # `opuss` is a typo, and the tier it was meant for simply goes unset. That
        # is the right OUTCOME -- inventing a mapping would be worse -- but doing
        # it in silence is how a routing change appears to have had no effect.
        $fixture = New-FixtureTree -Name 'fixture-ctx16-unknown-token' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-typo'
            '    litellm_params:'
            '      model: openai/Backend-A'
            '      ccgw_tiers: [haiku, opuss]'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "a typo in one token must not stop the launch; stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-typo' 'config-ssot/unknown-token: the valid token still applies'
        Assert-LauncherEnvUnset $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'config-ssot/unknown-token: an unrecognized token maps nothing'
        Assert-LauncherWarning $r 'opuss' 'config-ssot/unknown-token: the warning must name the token it did not understand'
    }

    It '16e. a config with routes but no annotations at all is a hard failure' {
        # Distinct from 4e (no file): the file is there and parses, so a reader
        # that returned an empty map would look like it worked. Every tier unset
        # means Claude Code silently uses whatever the cloud default is -- exactly
        # the failure this whole change exists to make impossible.
        $fixture = New-FixtureTree -Name 'fixture-ctx16-no-annotations' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-unannotated'
            '    litellm_params:'
            '      model: openai/Backend-A'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Not -Be 0 -Because 'a routing table that maps no tier cannot configure a launch'
        Assert-Stderr $r 'ccgw_tiers' 'config-ssot/no-annotations: the error must name the annotation the operator has to add'
        foreach ($v in $script:ModelVars) {
            Assert-LauncherEnvUnset $r $v 'config-ssot/no-annotations: nothing may be invented'
        }
    }

    It '16f. two routes claiming the same tier warns and first wins' {
        # Asymmetric on purpose. The hard gate lives on the WRITER side --
        # set-model.sh refuses to publish a colliding file (exit 2) and the
        # static test refuses to ship one. Making the READER fatal too would let
        # one bad line pushed from the server leave every client unable to start
        # Claude Code at all, so the launcher warns, takes the first claimant,
        # and keeps the tiers nobody duplicated exactly as they were.
        $fixture = New-FixtureTree -Name 'fixture-ctx16-collision' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-alpha'
            '    litellm_params:'
            '      model: openai/Backend-A'
            '      ccgw_tiers: [haiku, opus]'
            ''
            '  - model_name: lite-beta'
            '    litellm_params:'
            '      model: openai/Backend-B'
            '      ccgw_tiers: [opus]'
            ''
            '  - model_name: lite-bystander'
            '    litellm_params:'
            '      model: anthropic/Backend-C'
            '      ccgw_tiers: [fable]'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "the other tiers are still usable; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'a duplicated tier must not cost the operator their client'
        Assert-LauncherWarning $r 'opus' 'config-ssot/collision: the warning must name the tier that was claimed twice'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-alpha' 'config-ssot/collision: the FIRST occurrence wins, so the resolution is at least reproducible'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-alpha' 'config-ssot/collision: a tier claimed once on a colliding route still maps'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-bystander' 'config-ssot/collision: a route in no collision at all is untouched'
    }

    It '16g. the repo''s own config.yaml maps all five tiers' {
        # The drift detector. Every case above runs against a fixture, so all of
        # them stay green while the real file loses an annotation in a rebase --
        # and the first person to notice would be whoever launched Claude Code
        # against a tier that had quietly stopped existing.
        $realConfig = Join-Path (Join-Path $script:RepoRoot 'litellm-server') 'config.yaml'
        Test-Path -LiteralPath $realConfig | Should -BeTrue -Because "litellm-server/config.yaml not found at $realConfig"

        $fixture = New-FixtureTree -Name 'fixture-ctx16-real' -ConfigYamlLines ([System.IO.File]::ReadAllLines($realConfig))
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "the repo's own routing table must launch; stderr: $($r.StdErr)"
        foreach ($tier in $script:TierRows.Keys) {
            $var = $script:TierRows[$tier]
            $got = if ($r.Env.ContainsKey($var)) { $r.Env[$var] } else { '' }
            $got | Should -Not -BeNullOrEmpty -Because "config-ssot/real-file: no route in litellm-server/config.yaml claims the $tier tier, so $var reaches Claude Code unset"
        }
    }
}
