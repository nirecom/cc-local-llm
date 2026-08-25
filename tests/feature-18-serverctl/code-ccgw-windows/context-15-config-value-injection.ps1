#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '15. Adversarial CONFIG values stay data too (issue #66)' -Skip:(-not $IsWindows) {
    # Context 9 covers argv metacharacters; this covers .env/shell values --
    # a different road, since CreateProcess's env BLOCK is never re-parsed,
    # so only composing values into a command line (cmd /c "set K=%v% && ...",
    # -Command) would turn them into syntax. Adversarial, not hypothetical: a
    # generated key can hold `&`/`%`/`"`, a CA path can sit under "Program
    # Files (x86)". Newlines absent (unrepresentable, per 9d).

    BeforeAll {
        # One shape per launch, applied to ALL FOUR value-carrying inputs at once:
        # they are the same class (CPR-E2C), and a per-input sweep would multiply
        # the runtime by four to prove the same thing.
        $script:Ctx15Shapes = [ordered]@{
            'metachars'     = 'a&b|c^d<e>f'
            'expansion'     = '%PATH%-100%done'
            'quotes'        = 'x"y"z'
            'grouping-bang' = 'a(b)c;d,e!f!'
            'injection'     = '& type nul > "{0}" &'
        }
    }

    It '15a. metacharacters in the base URL, credential, CA path and model reach the child verbatim' {
        $bad = New-Object System.Collections.Generic.List[string]
        $i = 0
        foreach ($name in @($script:Ctx15Shapes.Keys)) {
            $i++
            # The injection shape names a marker file that must never exist; the
            # others format to themselves.
            $marker = Join-Path $script:Work "config-injection-marker-$i.txt"
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            $shape = [string]::Format([string]$script:Ctx15Shapes[$name], $marker)

            # Distinct per input, so a launcher that cross-wired two of them (e.g.
            # exported the key as the base URL) cannot pass by coincidence.
            $baseUrl = "https://ctx15-lite:1/$shape"
            $key = "ctx15-key-$shape"
            $ca = "C:\ctx15\$shape.pem"
            $model = "ctx15-model-$shape"

            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = $baseUrl
                LITELLM_CLIENT_KEY         = $key
                CCGW_CA_CERT               = $ca
                LITELLM_FABLE_MODEL        = $model
            } -Arguments @('C:\some\project')

            if (Test-Path -LiteralPath $marker) {
                $bad.Add("${name}: a command embedded in a CONFIG VALUE RAN (marker created)")
            }
            if ($r.ExitCode -ne 0) {
                $bad.Add("${name}: exit $($r.ExitCode); stderr: $($r.StdErr)")
                continue
            }
            if (-not $r.Reached) {
                $bad.Add("${name}: the stub was never reached; stderr: $($r.StdErr)")
                continue
            }
            foreach ($pair in @(
                    @{ Var = 'ANTHROPIC_BASE_URL'; Want = $baseUrl }
                    @{ Var = 'ANTHROPIC_AUTH_TOKEN'; Want = $key }
                    @{ Var = 'NODE_EXTRA_CA_CERTS'; Want = $ca }
                    @{ Var = 'ANTHROPIC_DEFAULT_FABLE_MODEL'; Want = $model }
                    @{ Var = 'ANTHROPIC_CUSTOM_MODEL_OPTION'; Want = $model }
                )) {
                $got = if ($r.Env.ContainsKey($pair.Var)) { $r.Env[$pair.Var] } else { '<absent>' }
                if ($got -cne $pair.Want) {
                    $bad.Add("${name}: $($pair.Var) reached the child as '$got', expected '$($pair.Want)'")
                }
            }
            # The argv half of the same launch: a value that leaked out of the
            # environment block and into the command line shows up as extra
            # arguments even when nothing executed.
            if (@($r.Argv).Count -ne 3) {
                $bad.Add("${name}: argv was [$(@($r.Argv) -join '][')] -- a config value reached the command line")
            }
        }
        $bad.Count | Should -Be 0 -Because "config values must be delivered as data, not as syntax: $($bad -join ' // ')"
    }

    It '15b. an adversarial credential is still never echoed back' {
        # A value carrying quotes and operators is the one an implementation is
        # most tempted to print while diagnosing it, and it is still the gateway
        # credential (OWASP ASVS V8).
        $key = 'ctx15-secret-& "quoted" %PATH%-key'
        $r = Invoke-Launcher -Environment @{
            LITELLM_ANTHROPIC_BASE_URL = 'https://ctx15-lite:1'
            LITELLM_CLIENT_KEY         = $key
            CCGW_CA_CERT               = 'C:\ctx15\ca.pem'
        } -Arguments @('C:\some\project')
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' $key 'config-injection/secret'
        Assert-NoSecretInOutput $r @($key) 'config-injection/secret'
    }
}
