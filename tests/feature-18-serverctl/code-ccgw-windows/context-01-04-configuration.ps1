#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# what the launcher resolves before it launches anything -- the single-source base
# URL, the credential, the TLS CA, and the model tier map.

Context '1. Base URL: single source, hard failure when absent' {
    It 'LITELLM_ANTHROPIC_BASE_URL is the only source' {
        $r = Invoke-Launcher -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'base-url/configured'
    }

    It 'the retired CCGW_/DS4_ base URLs must not configure the launcher' {
        # A stale .env carrying them is exactly the situation where a silent
        # fallback would send traffic down the route this change removed.
        $env1 = @{ LITELLM_CLIENT_KEY = 'ck' }
        $env1[$script:RBaseCcgw] = 'https://ccgw:2'
        $env1[$script:RBaseDs4] = 'https://ds4:3'
        $r = Invoke-Launcher -Environment $env1
        $r.ExitCode | Should -Not -Be 0 -Because 'the retired base-URL variables are not a configuration source any more'
    }

    It 'an unset base URL is a hard failure, not a dummy default' {
        $r = Invoke-Launcher -Environment @{ LITELLM_CLIENT_KEY = 'ck' }
        $r.ExitCode | Should -Not -Be 0 -Because 'an unconfigured launcher must not silently pick a default endpoint'
        Assert-Stderr $r 'LITELLM_ANTHROPIC_BASE_URL' 'base-url/unset: the error must name the variable to set'
        Assert-Stderr $r 'docs/ops.md' 'base-url/unset: the error must point at the setup procedure'
    }

    It 'a defined-but-empty base URL is treated as unset' {
        # The retired .cmd's `if defined` accepted an empty string; the port must
        # not.
        $r = Invoke-Launcher -Environment @{ LITELLM_ANTHROPIC_BASE_URL = ''; LITELLM_CLIENT_KEY = 'ck' }
        $r.ExitCode | Should -Not -Be 0 -Because 'an empty value is not a configured endpoint'
    }
}

Context '2. Auth token: LITELLM_CLIENT_KEY, with a one-cycle deprecated alias' {
    # No virtual keys exist without a LiteLLM database, so the client credential
    # is the master key itself; LITELLM_VIRTUAL_KEY survives one cycle because an
    # existing .env carrying only the old name would otherwise 401 with no clue.

    It 'LITELLM_CLIENT_KEY is the credential, and using it warns about nothing' {
        $r = Invoke-Launcher -Environment (New-Env)
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'auth/current-name'
        # Both streams: the warning stream's destination is host-dependent (see
        # Assert-LauncherWarning), so checking stderr alone would pass by accident
        # on a host that routes warnings to stdout.
        ([string]$r.StdErr + [string]$r.StdOut) | Should -Not -Match '(?i)deprecat' -Because 'the current name must not produce a deprecation warning'
    }

    It 'the deprecated LITELLM_VIRTUAL_KEY is still accepted, with a warning naming both names' {
        # The credential is a distinctive string rather than 'vk' because this
        # path is the one that PRINTS something about it. A deprecation warning is
        # written to help, and "here is the value I found" is the most natural
        # unhelpful thing to add to one -- which would put the gateway credential
        # into terminal scrollback and CI logs (OWASP ASVS V8). The name belongs
        # in the message; the value never does.
        $secret = 'vk-alias-secret-must-not-be-echoed'
        $r = Invoke-Launcher -Environment @{
            LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
            LITELLM_VIRTUAL_KEY        = $secret
        }
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' $secret 'auth/alias'
        Assert-LauncherWarning $r 'LITELLM_VIRTUAL_KEY' 'auth/alias: using the deprecated name must warn'
        Assert-LauncherWarning $r 'LITELLM_CLIENT_KEY' 'auth/alias: the warning must name the replacement'
        Assert-NoSecretInOutput $r @($secret) 'auth/alias: the deprecation warning must name the variable, not its value'
    }

    It 'LITELLM_CLIENT_KEY wins when both names are set' {
        # A half-migrated .env has to behave predictably.
        $r = Invoke-Launcher -Environment (New-Env @{ LITELLM_VIRTUAL_KEY = 'vk' })
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'auth/both-names'
    }

    It 'the retired client key variables must not configure the launcher' {
        $env1 = @{ LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1' }
        $env1[$script:RKeyCcgw] = 'ck'
        $env1[$script:RKeyDs4] = 'dk'
        $r = Invoke-Launcher -Environment $env1
        $r.ExitCode | Should -Not -Be 0 -Because 'the proxy token is now internal to LiteLLM and no longer a client credential'
    }

    It 'an unset credential is a hard failure, not a shared dummy token' {
        # A credential IS present here, under names the launcher no longer accepts
        # -- the shape a half-migrated .env actually has. That makes this the
        # error path with a secret in scope: an error message that helpfully
        # reported "I found <the old CCGW-prefixed API key>=... but I want LITELLM_CLIENT_KEY" would
        # leak it, and the refusal is exactly where such a message gets written.
        $attempted = 'retired-name-secret-must-not-be-echoed'
        $env1 = @{ LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1' }
        $env1[$script:RKeyCcgw] = $attempted
        $env1[$script:RKeyDs4] = $attempted
        $r = Invoke-Launcher -Environment $env1
        $r.ExitCode | Should -Not -Be 0 -Because 'a missing credential must surface at launch, not as a 401 much later'
        Assert-Stderr $r 'LITELLM_CLIENT_KEY' 'auth/unset: the error must name the variable to set'
        $r.StdErr | Should -Not -Match 'dsv4-local' -Because 'the retired dummy token must be gone'
        Assert-NoSecretInOutput $r @($attempted) 'auth/unset: a refusal must not echo the credential it rejected'
    }

    It 'a pre-existing ANTHROPIC_API_KEY must be cleared so the local backend is used' {
        $r = Invoke-Launcher -Environment (New-Env @{ ANTHROPIC_API_KEY = 'cloud-key-must-not-survive' })
        $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"
        # Assigning '' removes the variable outright on Windows; both shapes
        # satisfy the contract "no real cloud key reaches Claude Code".
        $got = if ($r.Env.ContainsKey('ANTHROPIC_API_KEY')) { $r.Env['ANTHROPIC_API_KEY'] } else { $null }
        [string]::IsNullOrEmpty($got) | Should -BeTrue -Because "ANTHROPIC_API_KEY survived as '$got'"
    }
}

Context '3. TLS CA (retained: LiteLLM terminates TLS with the mkcert leaf)' {
    It 'CCGW_CA_CERT is honored' {
        $r = Invoke-Launcher -Environment (New-Env @{ CCGW_CA_CERT = 'C:\ca\ccgw.pem' })
        Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' 'C:\ca\ccgw.pem' 'ca/explicit'
        Assert-NoCaWarning $r 'ca/explicit'
    }

    It 'the retired direct-path CA variable must not be picked up' {
        $r = Invoke-Launcher -Environment (New-Env @{ $script:RCaDs4 = 'C:\ca\ds4.pem' })
        Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/retired-var'
    }

    It 'TLS verification must never be disabled' {
        # NODE_TLS_REJECT_UNAUTHORIZED=0 must never be the launcher's answer to TLS.
        $r = Invoke-Launcher -Environment (New-Env @{ CCGW_CA_CERT = 'C:\ca\ccgw.pem' })
        Assert-LauncherEnvUnset $r 'NODE_TLS_REJECT_UNAUTHORIZED' 'ca/no-tls-bypass'
    }

    It '3a. mkcert -CAROOT must be derived when no CA var is set' {
        $r = Invoke-Launcher -StubDir $script:StubMkcertOk -Environment (New-Env)
        Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' (Join-Path $script:CarootOk 'rootCA.pem') 'ca/mkcert-ok'
        Assert-NoCaWarning $r 'ca/mkcert-ok'
    }

    It 'explicit CCGW_CA_CERT must outrank the mkcert derivation' {
        $r = Invoke-Launcher -StubDir $script:StubMkcertOk -Environment (New-Env @{ CCGW_CA_CERT = 'C:\ca\explicit.pem' })
        Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' 'C:\ca\explicit.pem' 'ca/explicit-over-mkcert'
    }

    It '3b. a CAROOT without rootCA.pem must not yield a bogus NODE_EXTRA_CA_CERTS' {
        $r = Invoke-Launcher -StubDir $script:StubMkcertBad -Environment (New-Env)
        Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/mkcert-empty'
        Assert-LauncherWarning $r 'CCGW_CA_CERT not set' 'ca/mkcert-empty'
    }

    It '3c. mkcert absent entirely must warn and export nothing' {
        $r = Invoke-Launcher -Environment (New-Env)
        Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/no-mkcert'
        Assert-LauncherWarning $r 'CCGW_CA_CERT not set' 'ca/no-mkcert'
    }

    It '3d. a failing mkcert warns and still launches instead of aborting' {
        # Under PowerShell 7.4+ a non-zero native exit used to become a
        # terminating error while ErrorActionPreference is Stop, killing the
        # launcher outright; the script disables that conversion, so the run must
        # reach `code`. See the TL3 note in the suite header: a .ps1 stub is not a
        # native command, so this reaches the warning through the no-CAROOT branch
        # rather than through the conversion itself.
        $r = Invoke-Launcher -StubDir $script:StubMkcertFails -Environment (New-Env)
        $r.Reached | Should -BeTrue -Because "a failing mkcert must not abort the launcher; stderr: $($r.StdErr)"
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/mkcert-fails'
        Assert-LauncherWarning $r 'CCGW_CA_CERT not set' 'ca/mkcert-fails'
    }
}

Context '4. Model selection (tier map derived from litellm-server/config.yaml)' {
    # Since issue #89 the launcher takes no routing key from its environment at
    # all: it reads its own tree's litellm-server/config.yaml and derives each
    # /model tier from the `ccgw_tiers` annotation on the route that serves it.
    # The launcher owns no backend names of its own -- inventing one would route
    # to a model the gateway has no entry for, and the error would surface as a
    # 400 from LiteLLM rather than as a launcher message.

    BeforeAll {
        # One route claiming every tier but fable: the shape that proves the
        # picker entry is driven by an ANNOTATION and not by a variable.
        $script:Ctx4NoFable = New-FixtureTree -Name 'fixture-ctx4-no-fable' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-only'
            '    litellm_params:'
            '      model: openai/Qwen3.8-27B'
            '      ccgw_tiers: [haiku, sonnet, opus, subagent]'
        )
        # No route claims `subagent`, which is how an operator says "let each
        # agent definition's frontmatter choose".
        $script:Ctx4NoSubagent = New-FixtureTree -Name 'fixture-ctx4-no-subagent' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: lite-only'
            '    litellm_params:'
            '      model: openai/Qwen3.8-27B'
            '      ccgw_tiers: [haiku, sonnet, fable, opus]'
        )
        $script:Ctx4NoConfig = New-FixtureTree -Name 'fixture-ctx4-no-config' -NoConfigYaml
    }

    It '4a. every tier the config claims lands verbatim on its own /model tier' {
        $r = Invoke-Launcher -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        foreach ($tier in $script:TierRows.Keys) {
            Assert-LauncherEnv $r $script:TierRows[$tier] $script:FixtureTierValues[$tier] "models: the $tier tier comes from config.yaml"
        }
        Assert-LauncherEnvUnset $r 'ANTHROPIC_MODEL' "models: the startup tier is settings.json's to choose, not the launcher's"
        Assert-LauncherEnv $r 'ANTHROPIC_CUSTOM_MODEL_OPTION' $script:FixtureTierValues['fable'] 'models: custom model option follows the fable tier'
        # Stated as an inequality too: a regression that collapses the tiers onto
        # one route would still satisfy each literal individually if all literals
        # moved.
        Assert-LauncherEnvDiffers $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'ANTHROPIC_DEFAULT_OPUS_MODEL' `
            'models: fable and opus must address different routes or /model cannot switch'
    }

    It '4b. no retired direct-path backend name may appear in any model var' {
        # The launcher is not allowed to know them any more. The fixture's
        # `model:` lines deliberately carry such names so this case can only pass
        # by the launcher reading `model_name`, never the backend behind it.
        $r = Invoke-Launcher -Environment (New-Env)
        foreach ($v in $script:ModelVars) {
            $val = if ($r.Env.ContainsKey($v)) { $r.Env[$v] } else { '' }
            $val | Should -Not -Match '(?i)deepseek' -Because "models: $v='$val' is a backend name, not a LiteLLM route"
            $val | Should -Not -Match '(?i)laguna' -Because "models: $v='$val' is a backend name, not a LiteLLM route"
            $val | Should -Not -Match '(?i)qwen' -Because "models: $v='$val' is a backend name, not a LiteLLM route"
        }
    }

    It '4c. the retired startup-model variable must change nothing at all' {
        $r = Invoke-Launcher -Environment (New-Env @{ $script:RDefaultModel = 'laguna-s-2.1' })
        Assert-LauncherEnvUnset $r 'ANTHROPIC_MODEL' 'models/retired-default: the retired startup-model variable must configure nothing'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' $script:FixtureTierValues['opus'] 'models/retired-default: the tier map must be unaffected'
    }

    # 4d. Subagent contract (three cases).
    #
    # Why it changed twice: the launcher once pinned CLAUDE_CODE_SUBAGENT_MODEL
    # to the fable tier, which silently overrode the model an agent definition's
    # frontmatter declares; the opt-in CCGW_SUBAGENT_MODEL that replaced it then
    # became one more per-machine value to keep in sync. Both roles now live in
    # the annotation: a route claiming `subagent` sets it, no route claiming it
    # leaves it unset, and the environment cannot say otherwise.

    It '4d-i. a route claiming the subagent tier exports it' {
        $r = Invoke-Launcher -Environment (New-Env)
        Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' $script:FixtureTierValues['subagent'] 'subagent/claimed'
    }

    It '4d-ii. no route claiming it leaves the subagent model unexported' {
        $r = Invoke-Launcher -LauncherPath $script:Ctx4NoSubagent -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnvUnset $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'subagent/unclaimed: an unconditional value overrides agent frontmatter'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-only' 'subagent/unclaimed: the other tiers must still be mapped'
    }

    It '4d-iii. the retired CCGW_SUBAGENT_MODEL variable no longer configures it' {
        # A stale .env still carrying it is exactly the situation where a
        # surviving fallback would keep serving a name the config has moved on
        # from.
        $r = Invoke-Launcher -LauncherPath $script:Ctx4NoSubagent -Environment (New-Env @{ CCGW_SUBAGENT_MODEL = 'some-other-routing-key' })
        # A launcher that failed before starting the child leaves the same
        # "unset" evidence, so the run is pinned first -- the assertion set 4d-ii
        # already carries (CPR-ORTH).
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'subagent/retired-var: the stub `code` was never reached, so an unset subagent model proves nothing'
        Assert-LauncherEnvUnset $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'subagent/retired-var: config.yaml is the only source'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-only' 'subagent/retired-var: the other tiers must still be mapped'
    }

    It 'a stale routing key in the environment cannot override the config' {
        # The 2026-08-22 failure in one line: the per-machine value is wrong, the
        # config is right, and the config has to win.
        $r = Invoke-Launcher -Environment (New-Env @{
                LITELLM_FABLE_MODEL = 'stale-fable-from-env'
                LITELLM_OPUS_MODEL  = 'stale-opus-from-env'
            })
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' $script:FixtureTierValues['fable'] 'models/stale-env: the config value wins'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' $script:FixtureTierValues['opus'] 'models/stale-env: the config value wins'
    }

    It '4e. an absent config.yaml is a hard failure naming the file' {
        $r = Invoke-Launcher -LauncherPath $script:Ctx4NoConfig -Environment (New-Env)
        $r.ExitCode | Should -Not -Be 0 -Because 'with no routing table there is no tier map to derive, and inventing one routes nowhere'
        Assert-Stderr $r 'config.yaml' 'models/no-config: the error must name the file the launcher could not read'
        foreach ($v in $script:ModelVars) {
            Assert-LauncherEnvUnset $r $v 'models/no-config: the launcher must substitute no model name of its own'
        }
    }

    It '4f. a tier no route claims: the fable tier drives the picker entry, so its absence leaves it unset' {
        $r = Invoke-Launcher -LauncherPath $script:Ctx4NoFable -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-only' 'models/no-fable: the claimed tiers still apply'
        Assert-LauncherEnvUnset $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'models/no-fable: no route claims fable, so no fable tier'
        foreach ($v in $script:ActiveVars) {
            Assert-LauncherEnvUnset $r $v 'models/no-fable: the launcher must invent no model name of its own'
        }
    }

    # 4g. ANTHROPIC_MODEL must never reach the child, whatever the parent carried.
    # It outranks settings.json's `model`, so any value silently discards the tier the
    # user chose there. Asserted against a parent that already carries one: an inherited
    # value takes a different route than a set one, so the launcher has to clear it
    # rather than merely decline to set it.
    It '4g. an inherited ANTHROPIC_MODEL is cleared, not passed through' {
        $r = Invoke-Launcher -Environment (New-Env @{ ANTHROPIC_MODEL = 'stale-from-parent' })
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnvUnset $r 'ANTHROPIC_MODEL' 'models/inherited-startup-model: an inherited value must be cleared'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' $script:FixtureTierValues['opus'] 'models/inherited-startup-model: the tier map must be unaffected'
        Assert-LauncherEnv $r 'ANTHROPIC_CUSTOM_MODEL_OPTION' $script:FixtureTierValues['fable'] 'models/inherited-startup-model: the picker entry must be unaffected'
    }

    # 4h. The migration warning, the CPR-ORTH sibling of POSIX case 5. Being
    # ignored (4c/4d) and being TOLD you are ignored are different guarantees, and
    # only the second one gets the operator to their .env: a key that silently
    # stops working reads as the launcher being broken. All five retired keys are
    # covered because an implementation that warns about the one key a test names
    # is the likeliest way for this to pass while four operators stay stranded
    # (detail.md:239).
    It '4h. a retired routing key still in .env draws a migration warning: <Key>' -ForEach @(
        @{ Key = 'LITELLM_HAIKU_MODEL' }
        @{ Key = 'LITELLM_SONNET_MODEL' }
        @{ Key = 'LITELLM_FABLE_MODEL' }
        @{ Key = 'LITELLM_OPUS_MODEL' }
        @{ Key = 'CCGW_SUBAGENT_MODEL' }
    ) {
        $launcher = New-FixtureTree -Name "ctx4-retired-$Key" -DotEnvLines @("$Key=stale-from-dotenv")
        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "models/retired-$Key`: a retired key is a thing to say something about, never a reason to withhold the editor; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "models/retired-$Key`: the client was never started"
        Assert-LauncherWarning $r $Key "models/retired-$Key`: the warning must name the key that no longer does anything, or the operator cannot find it"
        Assert-LauncherWarning $r 'config.yaml' "models/retired-$Key`: the warning must say where the setting lives now"
    }

    It '4h-control. a .env with no retired key draws no migration warning' {
        # Without this, the five rows above are all satisfied by a launcher that
        # prints the same warning on every single start -- which trains the
        # operator to ignore it.
        $launcher = New-FixtureTree -Name 'ctx4-retired-none'
        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        ($r.StdErr + $r.StdOut) | Should -Not -Match '(?i)(no longer|retired|migrat)' `
            -Because 'models/retired-none: warned about retired keys although .env carries none'
    }
}
