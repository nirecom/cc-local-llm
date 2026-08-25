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

Context '4. Model selection (unconditional LiteLLM routing keys)' {
    # With the direct path gone there is no branch left: each LITELLM_*_MODEL is a
    # LiteLLM routing key and goes onto its own /model tier verbatim. The launcher
    # owns no backend names of its own -- inventing one would route to a model the
    # gateway has no entry for, and the error would surface as a 400 from LiteLLM
    # rather than as a launcher message.

    BeforeAll {
        $script:AllKeys = @{
            LITELLM_FABLE_MODEL  = 'lite-fable'
            LITELLM_OPUS_MODEL   = 'lite-opus'
            LITELLM_SONNET_MODEL = 'lite-sonnet'
            LITELLM_HAIKU_MODEL  = 'lite-haiku'
        }
    }

    It '4a. all four routing keys land verbatim on their own tiers' {
        $r = Invoke-Launcher -Environment (New-Env $script:AllKeys)
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-fable' 'models: fable routing key'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'models: opus routing key'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'lite-sonnet' 'models: sonnet routing key'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-haiku' 'models: haiku routing key'
        Assert-LauncherEnvUnset $r 'ANTHROPIC_MODEL' "models: the startup tier is settings.json's to choose, not the launcher's"
        Assert-LauncherEnv $r 'ANTHROPIC_CUSTOM_MODEL_OPTION' 'lite-fable' 'models: custom model option follows the fable tier'
        # Stated as an inequality too: a regression that collapses the tiers onto
        # one key would still satisfy each literal individually if all literals
        # moved.
        Assert-LauncherEnvDiffers $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'ANTHROPIC_DEFAULT_OPUS_MODEL' `
            'models: fable and opus must address different routing keys or /model cannot switch'
    }

    It '4b. no retired direct-path backend name may appear in any model var' {
        # The launcher is not allowed to know them any more.
        $r = Invoke-Launcher -Environment (New-Env $script:AllKeys)
        foreach ($v in $script:ModelVars) {
            $val = if ($r.Env.ContainsKey($v)) { $r.Env[$v] } else { '' }
            $val | Should -Not -Match '(?i)deepseek' -Because "models: $v='$val' is a backend name, not a LiteLLM routing key"
            $val | Should -Not -Match '(?i)laguna' -Because "models: $v='$val' is a backend name, not a LiteLLM routing key"
        }
    }

    It '4c. the retired startup-model variable must change nothing at all' {
        $r = Invoke-Launcher -Environment (New-Env ($script:AllKeys + @{ $script:RDefaultModel = 'laguna-s-2.1' }))
        Assert-LauncherEnvUnset $r 'ANTHROPIC_MODEL' 'models/retired-default: the retired startup-model variable must configure nothing'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'models/retired-default: the tier map must be unaffected'
    }

    # 4d. Subagent contract (three cases).
    #
    # Why it changed: the old launcher pinned CLAUDE_CODE_SUBAGENT_MODEL to the
    # fable tier so a subagent could not evict the resident backend. Routing now
    # goes through LiteLLM, which multiplexes, so the pin is no longer needed --
    # and it actively harms, because it silently overrides the model an agent
    # definition's frontmatter declares. Default is therefore "say nothing";
    # CCGW_SUBAGENT_MODEL exists only for the case where a user deliberately wants
    # every subagent confined to one route.

    It '4d-i. by default the subagent model is not exported at all' {
        $r = Invoke-Launcher -Environment (New-Env $script:AllKeys)
        Assert-LauncherEnvUnset $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'subagent/default: an unconditional value overrides agent frontmatter'
    }

    It '4d-ii. CCGW_SUBAGENT_MODEL is exported verbatim' {
        $r = Invoke-Launcher -Environment (New-Env ($script:AllKeys + @{ CCGW_SUBAGENT_MODEL = 'lite-haiku' }))
        Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'lite-haiku' 'subagent/opt-in'
    }

    It '4d-iii. an arbitrary routing key passes through untranslated' {
        # A key the launcher has never heard of must survive intact, and a tier
        # name must NOT be mapped to that tier's value.
        $r = Invoke-Launcher -Environment (New-Env ($script:AllKeys + @{ CCGW_SUBAGENT_MODEL = 'some-other-routing-key' }))
        Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'some-other-routing-key' 'subagent/domain'
    }

    It 'a defined-but-empty CCGW_SUBAGENT_MODEL counts as unset' {
        # Exporting an empty model name would make Claude Code request "" and fail
        # at the gateway.
        $r = Invoke-Launcher -Environment (New-Env @{ LITELLM_FABLE_MODEL = 'lite-fable'; CCGW_SUBAGENT_MODEL = '' })
        Assert-LauncherEnvUnset $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'subagent/empty'
    }

    It '4e. no routing keys at all: nothing may be invented' {
        $r = Invoke-Launcher -Environment (New-Env)
        foreach ($v in $script:ModelVars) {
            Assert-LauncherEnvUnset $r $v 'models/no-keys: the launcher must substitute no model name of its own'
        }
    }

    It '4f. partial keys: the fable tier drives the picker entry, so its absence leaves it unset' {
        $r = Invoke-Launcher -Environment (New-Env @{
                LITELLM_OPUS_MODEL   = 'lite-opus'
                LITELLM_SONNET_MODEL = 'lite-sonnet'
                LITELLM_HAIKU_MODEL  = 'lite-haiku'
            })
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'models/no-fable: opus routing key still applies'
        Assert-LauncherEnvUnset $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'models/no-fable: no fable key means no fable tier'
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
        $r = Invoke-Launcher -Environment (New-Env ($script:AllKeys + @{ ANTHROPIC_MODEL = 'stale-from-parent' }))
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnvUnset $r 'ANTHROPIC_MODEL' 'models/inherited-startup-model: an inherited value must be cleared'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'models/inherited-startup-model: the tier map must be unaffected'
        Assert-LauncherEnv $r 'ANTHROPIC_CUSTOM_MODEL_OPTION' 'lite-fable' 'models/inherited-startup-model: the picker entry must be unaffected'
    }
}
