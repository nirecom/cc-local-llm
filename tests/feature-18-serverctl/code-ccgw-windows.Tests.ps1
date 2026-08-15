#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Scenario (issue #41 / detail plan D5a): the direct-to-DS4-Proxy route is
# retired, so the Windows client launcher (pwsh counterpart of
# scripts/code-ccgw.sh) has exactly ONE path — through the Mac LiteLLM.
#
# Why the precedence chains had to go, rather than merely being re-pointed:
# keeping a direct fallback would split the credential a client holds into two
# systems (a LiteLLM key and a proxy token), which defeats the TLS termination
# this change consolidates. With a single source there is nothing to fall back
# to, so an unconfigured base URL / key is an error, never a dummy default —
# a dummy default is what turns a misconfiguration into a confusing 401 much
# later, at request time.
#
# This file is the 1:1 mirror of tests/feature-18-serverctl/test-code-ccgw-posix.sh
# (CPR-ORTH: the two launchers are symmetric members of one class, so the
# contract asserted on one must be asserted on the other). The only intentional
# divergences are the platform-specific ones: the VS Code profile dir lives
# under LOCALAPPDATA rather than being derived from `uname`, and PowerShell's
# native-command error conversion needs its own regression case.
#
# Method: `code` is stubbed on PATH with a code.ps1 that dumps the environment
# it inherited plus its argv to files, so every assertion is made against the
# environment the launcher actually hands to Claude Code — none of the
# launcher's branching is re-implemented here. `mkcert` is stubbed the same way.
# The launcher runs in a child pwsh whose environment block is cleared and
# rebuilt from scratch, so an ambient LITELLM_*/CCGW_*/DS4_* value in the
# developer's shell can never satisfy an assertion by accident. The script under
# test is copied into a fixture tree with its own (empty) repo-root .env, so the
# developer's real .env — which holds the actual base URL and API keys — is
# never read.
#
# TL3 gap: real VS Code startup and profile creation under the derived
#   --user-data-dir; a real mkcert CA actually being trusted by Node's TLS
#   stack; genuine end-to-end routing of the selected routing key through
#   LiteLLM to a loaded backend; a real Windows host. Also unreachable from
#   here: the $PSNativeCommandUseErrorActionPreference guard itself — that
#   conversion applies only to native executables, and the mkcert stub is a
#   .ps1, so the failing-mkcert case below exercises the resulting no-CAROOT
#   branch rather than the exit-code conversion that would have aborted the
#   launcher before the fix.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:SourceLauncher = Join-Path $script:RepoRoot 'scripts' 'code-ccgw.ps1'

    if (-not (Test-Path -LiteralPath $script:SourceLauncher)) {
        throw "$($script:SourceLauncher) not found (implementation pending)"
    }

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("ccgw-win-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

    $script:PwshPath = if ($IsWindows) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }

    # --- Retired variable names ---------------------------------------------
    # The cases that prove a retired variable no longer configures anything need
    # its exact spelling, but those spellings are banned repo-wide by
    # tests/ccgw-naming/test_no_legacy_names.py, whose scan is a raw substring
    # match over every tracked file — this one included. The names are therefore
    # assembled at runtime instead of appearing as literals. The cases
    # themselves must stay: a stale .env still carrying them is precisely the
    # situation where a surviving fallback would silently route around the new
    # single path.
    $script:RBaseDs4      = 'DS4_ANTHROPIC' + '_BASE_URL'
    $script:RBaseCcgw     = 'CCGW_ANTHROPIC' + '_BASE_URL'
    $script:RKeyDs4       = 'DS4_API' + '_KEY'
    $script:RKeyCcgw      = 'CCGW_API' + '_KEY'
    $script:RCaDs4        = 'DS4_CA' + '_CERT'
    $script:RDefaultModel = 'CCGW_DEFAULT' + '_MODEL'

    # --- fixture script tree -------------------------------------------------
    # The launcher reads <script>/../.env. Copying it into a fixture tree pins
    # that file to an empty one, so precedence is asserted from the child's
    # environment block alone.
    function New-FixtureTree {
        param([string]$Name, [string[]]$DotEnvLines = @('# intentionally empty: precedence is asserted from the env alone'))
        $root = Join-Path $script:Work $Name
        New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
        Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $root 'scripts' 'code-ccgw.ps1') -Force
        Set-Content -LiteralPath (Join-Path $root '.env') -Value $DotEnvLines -Encoding utf8
        return (Join-Path $root 'scripts' 'code-ccgw.ps1')
    }
    $script:Launcher = New-FixtureTree -Name 'fixture-default'

    # --- stubs ---------------------------------------------------------------
    # A .ps1 on PATH is a first-class command for PowerShell's discovery, so
    # `Get-Command code` / `& code` resolve these without any native binary.
    $script:CodeStubBody = @'
$dump = @{}
foreach ($e in Get-ChildItem env:) { $dump[$e.Name] = $e.Value }
$dump | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $env:CCGW_TEST_DUMP -Encoding utf8
$argvOut = @($args) | ForEach-Object { [string]$_ }
Set-Content -LiteralPath $env:CCGW_TEST_ARGV -Value $argvOut -Encoding utf8
'@

    function New-StubDir {
        param(
            [string]$Name,
            [string]$MkcertCaroot,
            [int]$MkcertExitCode = 0,
            [switch]$NoCode,
            [switch]$NoMkcert
        )
        $dir = Join-Path $script:Work $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        if (-not $NoCode) {
            Set-Content -LiteralPath (Join-Path $dir 'code.ps1') -Value $script:CodeStubBody -Encoding utf8
        }
        if (-not $NoMkcert) {
            # Prints the CAROOT it was created with; the launcher pipes it through
            # Select-Object -First 1. A failing stub prints nothing and exits
            # non-zero — it deliberately writes no stderr, which would otherwise
            # contaminate the launcher's own stderr that the warning assertions read.
            $body = if ($MkcertExitCode -ne 0) {
                "exit $MkcertExitCode"
            } else {
                "Write-Output '" + ($MkcertCaroot -replace "'", "''") + "'"
            }
            Set-Content -LiteralPath (Join-Path $dir 'mkcert.ps1') -Value $body -Encoding utf8
        }
        return $dir
    }

    # Default stub dir: `code` present, no mkcert at all.
    $script:StubDir = New-StubDir -Name 'stub' -NoMkcert

    # mkcert whose CAROOT really holds a rootCA.pem.
    $script:CarootOk = Join-Path $script:Work 'caroot-ok'
    New-Item -ItemType Directory -Path $script:CarootOk -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:CarootOk 'rootCA.pem') -Value '' -Encoding utf8
    $script:StubMkcertOk = New-StubDir -Name 'stub-mkcert-ok' -MkcertCaroot $script:CarootOk

    # mkcert whose CAROOT is empty (no rootCA.pem).
    $script:CarootEmpty = Join-Path $script:Work 'caroot-empty'
    New-Item -ItemType Directory -Path $script:CarootEmpty -Force | Out-Null
    $script:StubMkcertBad = New-StubDir -Name 'stub-mkcert-bad' -MkcertCaroot $script:CarootEmpty

    # mkcert that exits non-zero without printing a CAROOT.
    $script:StubMkcertFails = New-StubDir -Name 'stub-mkcert-fails' -MkcertExitCode 3

    # No `code` on PATH at all.
    $script:StubNoCode = New-StubDir -Name 'stub-nocode' -NoCode -NoMkcert

    $script:LocalAppData = Join-Path $script:Work 'localappdata'
    New-Item -ItemType Directory -Path $script:LocalAppData -Force | Out-Null

    # The minimum configuration every non-configuration case needs, so that a
    # case about (say) argv is never accidentally satisfied by the base-URL
    # guard refusing to run at all.
    $script:Configured = @{
        LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
        LITELLM_CLIENT_KEY         = 'ck'
    }
    function New-Env {
        param([hashtable]$Extra = @{})
        $h = @{}
        foreach ($k in $script:Configured.Keys) { $h[$k] = $script:Configured[$k] }
        foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
        return $h
    }

    # --- launcher runner -----------------------------------------------------
    # The child's environment block is cleared and rebuilt: only the variables
    # named here exist inside the launcher. PATH deliberately excludes the host's
    # real directories, so a genuinely installed mkcert cannot turn the
    # "no mkcert" case into a false pass.
    function Invoke-Launcher {
        param(
            [hashtable]$Environment = @{},
            [string[]]$Arguments = @(),
            [string]$StubDir = $script:StubDir,
            [string]$LauncherPath = $script:Launcher,
            [switch]$NoLocalAppData
        )

        $dump = Join-Path $script:Work 'env.dump.json'
        $argvFile = Join-Path $script:Work 'argv.dump'
        Remove-Item -LiteralPath $dump, $argvFile -ErrorAction SilentlyContinue

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:PwshPath
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $LauncherPath) + $Arguments) {
            $psi.ArgumentList.Add([string]$a)
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.Environment.Clear()

        $psi.Environment['PATH'] = $StubDir
        $psi.Environment['CCGW_TEST_DUMP'] = $dump
        $psi.Environment['CCGW_TEST_ARGV'] = $argvFile
        if (-not $NoLocalAppData) { $psi.Environment['LOCALAPPDATA'] = $script:LocalAppData }
        $psi.Environment['TEMP'] = $script:Work
        $psi.Environment['TMP'] = $script:Work
        $psi.Environment['TMPDIR'] = $script:Work
        $psi.Environment['HOME'] = $script:Work
        $psi.Environment['USERPROFILE'] = $script:Work
        # .ps1 must stay a discoverable command extension for the stubs above.
        $psi.Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD;.PS1'
        foreach ($passthrough in @('SystemRoot', 'ComSpec', 'windir')) {
            $v = [Environment]::GetEnvironmentVariable($passthrough)
            if ($v) { $psi.Environment[$passthrough] = $v }
        }
        foreach ($k in $Environment.Keys) {
            $psi.Environment[[string]$k] = [string]$Environment[$k]
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit(60000)) {
            try { $proc.Kill($true) } catch { }
            throw "launcher did not exit within 60s"
        }

        $envMap = @{}
        if (Test-Path -LiteralPath $dump) {
            $raw = Get-Content -LiteralPath $dump -Raw
            if ($raw.Trim()) { $envMap = $raw | ConvertFrom-Json -AsHashtable }
        }
        $argv = @()
        if (Test-Path -LiteralPath $argvFile) {
            $argv = @(Get-Content -LiteralPath $argvFile)
        }

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Env      = $envMap
            Argv     = $argv
            Reached  = (Test-Path -LiteralPath $dump)
        }
    }

    # --- assertion helpers ---------------------------------------------------
    function Assert-LauncherEnv {
        param($Result, [string]$Name, [string]$Expected, [string]$Context)
        if (-not $Result.Reached) {
            throw "$Context`: stub 'code' was never reached (no env dump); stderr: $($Result.StdErr)"
        }
        if (-not $Result.Env.ContainsKey($Name)) {
            throw "$Context`: $Name was not exported at all (expected '$Expected')"
        }
        if ($Result.Env[$Name] -cne $Expected) {
            throw "$Context`: $Name='$($Result.Env[$Name])', expected '$Expected'"
        }
    }

    function Assert-LauncherEnvUnset {
        param($Result, [string]$Name, [string]$Context)
        # The launcher's own contract treats defined-but-empty as unset, and
        # .NET drops an env var assigned '' on Windows — so either shape counts.
        if ($Result.Env.ContainsKey($Name) -and -not [string]::IsNullOrEmpty($Result.Env[$Name])) {
            throw "$Context`: $Name was exported as '$($Result.Env[$Name])' but must not be set at all"
        }
    }

    function Assert-LauncherEnvDiffers {
        param($Result, [string]$A, [string]$B, [string]$Context)
        if ($Result.Env[$A] -ceq $Result.Env[$B]) {
            throw "$Context`: $A and $B both resolved to '$($Result.Env[$A])'; the two tiers must stay on separate routing keys"
        }
    }

    function Assert-Stderr {
        param($Result, [string]$Pattern, [string]$Context)
        if ($Result.StdErr -notmatch [regex]::Escape($Pattern)) {
            throw "$Context`: expected stderr to contain '$Pattern', got: $($Result.StdErr)"
        }
    }

    function Assert-NoCaWarning {
        param($Result, [string]$Context)
        if ($Result.StdErr -match 'CCGW_CA_CERT not set') {
            throw "$Context`: unexpected CA warning: $($Result.StdErr)"
        }
    }

    # The four /model tiers Claude Code switches between.
    $script:TierVars = @(
        'ANTHROPIC_DEFAULT_FABLE_MODEL'
        'ANTHROPIC_DEFAULT_OPUS_MODEL'
        'ANTHROPIC_DEFAULT_SONNET_MODEL'
        'ANTHROPIC_DEFAULT_HAIKU_MODEL'
    )
    # The vars that name the model in play at startup. CLAUDE_CODE_SUBAGENT_MODEL
    # is deliberately NOT here any more: it is now opt-in (section 4d).
    $script:ActiveVars = @(
        'ANTHROPIC_MODEL'
        'ANTHROPIC_CUSTOM_MODEL_OPTION'
    )
    $script:ModelVars = $script:TierVars + $script:ActiveVars + @('CLAUDE_CODE_SUBAGENT_MODEL')
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'code-ccgw.ps1' {

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
            # The retired .cmd's `if defined` accepted an empty string; the port
            # must not.
            $r = Invoke-Launcher -Environment @{ LITELLM_ANTHROPIC_BASE_URL = ''; LITELLM_CLIENT_KEY = 'ck' }
            $r.ExitCode | Should -Not -Be 0 -Because 'an empty value is not a configured endpoint'
        }
    }

    Context '2. Auth token: LITELLM_CLIENT_KEY, with a one-cycle deprecated alias' {
        # No virtual keys exist without a LiteLLM database, so the client
        # credential is the master key itself; LITELLM_VIRTUAL_KEY survives one
        # cycle because an existing .env carrying only the old name would
        # otherwise 401 with no clue.

        It 'LITELLM_CLIENT_KEY is the credential, and using it warns about nothing' {
            $r = Invoke-Launcher -Environment (New-Env)
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'auth/current-name'
            $r.StdErr | Should -Not -Match '(?i)deprecat' -Because 'the current name must not produce a deprecation warning'
        }

        It 'the deprecated LITELLM_VIRTUAL_KEY is still accepted, with a warning naming both names' {
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
                LITELLM_VIRTUAL_KEY        = 'vk'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'vk' 'auth/alias'
            Assert-Stderr $r 'LITELLM_VIRTUAL_KEY' 'auth/alias: using the deprecated name must warn'
            Assert-Stderr $r 'LITELLM_CLIENT_KEY' 'auth/alias: the warning must name the replacement'
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
            $r = Invoke-Launcher -Environment @{ LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1' }
            $r.ExitCode | Should -Not -Be 0 -Because 'a missing credential must surface at launch, not as a 401 much later'
            Assert-Stderr $r 'LITELLM_CLIENT_KEY' 'auth/unset: the error must name the variable to set'
            $r.StdErr | Should -Not -Match 'dsv4-local' -Because 'the retired dummy token must be gone'
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
            Assert-Stderr $r 'CCGW_CA_CERT not set' 'ca/mkcert-empty'
        }

        It '3c. mkcert absent entirely must warn and export nothing' {
            $r = Invoke-Launcher -Environment (New-Env)
            Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/no-mkcert'
            Assert-Stderr $r 'CCGW_CA_CERT not set' 'ca/no-mkcert'
        }

        It '3d. a failing mkcert warns and still launches instead of aborting' {
            # Under PowerShell 7.4+ a non-zero native exit used to become a
            # terminating error while ErrorActionPreference is Stop, killing the
            # launcher outright; the script disables that conversion, so the run
            # must reach `code`. See the TL3 note in the header: a .ps1 stub is
            # not a native command, so this reaches the warning through the
            # no-CAROOT branch rather than through the conversion itself.
            $r = Invoke-Launcher -StubDir $script:StubMkcertFails -Environment (New-Env)
            $r.Reached | Should -BeTrue -Because "a failing mkcert must not abort the launcher; stderr: $($r.StdErr)"
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/mkcert-fails'
            Assert-Stderr $r 'CCGW_CA_CERT not set' 'ca/mkcert-fails'
        }
    }

    Context '4. Model selection (unconditional LiteLLM routing keys)' {
        # With the direct path gone there is no branch left: each
        # LITELLM_*_MODEL is a LiteLLM routing key and goes onto its own /model
        # tier verbatim. The launcher owns no backend names of its own —
        # inventing one would route to a model the gateway has no entry for, and
        # the error would surface as a 400 from LiteLLM rather than as a
        # launcher message.

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
            Assert-LauncherEnv $r 'ANTHROPIC_MODEL' 'lite-fable' 'models: startup model follows the fable tier'
            Assert-LauncherEnv $r 'ANTHROPIC_CUSTOM_MODEL_OPTION' 'lite-fable' 'models: custom model option follows the fable tier'
            # Stated as an inequality too: a regression that collapses the tiers
            # onto one key would still satisfy each literal individually if all
            # literals moved.
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
            Assert-LauncherEnv $r 'ANTHROPIC_MODEL' 'lite-fable' 'models/retired-default: the retired startup-model variable must be ignored'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'models/retired-default: the tier map must be unaffected'
        }

        # 4d. Subagent contract (three cases).
        #
        # Why it changed: the old launcher pinned CLAUDE_CODE_SUBAGENT_MODEL to
        # the fable tier so a subagent could not evict the resident backend.
        # Routing now goes through LiteLLM, which multiplexes, so the pin is no
        # longer needed — and it actively harms, because it silently overrides
        # the model an agent definition's frontmatter declares. Default is
        # therefore "say nothing"; CCGW_SUBAGENT_MODEL exists only for the case
        # where a user deliberately wants every subagent confined to one route.

        It '4d-i. by default the subagent model is not exported at all' {
            $r = Invoke-Launcher -Environment (New-Env $script:AllKeys)
            Assert-LauncherEnvUnset $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'subagent/default: an unconditional value overrides agent frontmatter'
        }

        It '4d-ii. CCGW_SUBAGENT_MODEL is exported verbatim' {
            $r = Invoke-Launcher -Environment (New-Env ($script:AllKeys + @{ CCGW_SUBAGENT_MODEL = 'lite-haiku' }))
            Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'lite-haiku' 'subagent/opt-in'
        }

        It '4d-iii. an arbitrary routing key passes through untranslated' {
            # A key the launcher has never heard of must survive intact, and a
            # tier name must NOT be mapped to that tier's value.
            $r = Invoke-Launcher -Environment (New-Env ($script:AllKeys + @{ CCGW_SUBAGENT_MODEL = 'some-other-routing-key' }))
            Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'some-other-routing-key' 'subagent/domain'
        }

        It 'a defined-but-empty CCGW_SUBAGENT_MODEL counts as unset' {
            # Exporting an empty model name would make Claude Code request ""
            # and fail at the gateway.
            $r = Invoke-Launcher -Environment (New-Env @{ LITELLM_FABLE_MODEL = 'lite-fable'; CCGW_SUBAGENT_MODEL = '' })
            Assert-LauncherEnvUnset $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'subagent/empty'
        }

        It '4e. no routing keys at all: nothing may be invented' {
            $r = Invoke-Launcher -Environment (New-Env)
            foreach ($v in $script:ModelVars) {
                Assert-LauncherEnvUnset $r $v 'models/no-keys: the launcher must substitute no model name of its own'
            }
        }

        It '4f. partial keys: the fable tier drives the startup vars, so its absence leaves them unset' {
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
    }

    Context '5. VS Code profile isolation and argv passthrough' {
        It 'passes an isolated --user-data-dir under LOCALAPPDATA plus the caller argv' {
            $r = Invoke-Launcher -Environment (New-Env) -Arguments @('C:\some\project', '--new-window')
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'), 'C:\some\project', '--new-window')
            @($r.Argv) | Should -Be $expected
        }

        It 'passes only the --user-data-dir pair when the caller supplied no argv' {
            $r = Invoke-Launcher -Environment (New-Env)
            $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'))
            @($r.Argv) | Should -Be $expected
        }

        It 'falls back to a home-relative profile dir when LOCALAPPDATA is unset' {
            # LOCALAPPDATA is always set on a normal Windows session, but a
            # stripped service environment would otherwise make the final
            # Join-Path throw after every env var had already been resolved.
            # The exact fallback spelling is the script's business; what must
            # hold is that it still launches, still isolates, and still roots the
            # profile under the user's home.
            $r = Invoke-Launcher -Environment (New-Env) -NoLocalAppData
            $r.Reached | Should -BeTrue -Because "an unset LOCALAPPDATA must not abort the launcher; stderr: $($r.StdErr)"
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            @($r.Argv).Count | Should -Be 2
            $r.Argv[0] | Should -Be '--user-data-dir'
            $r.Argv[1] | Should -BeLike "$($script:Work)*"
            $r.Argv[1] | Should -BeLike '*vscode-ccgw'
            # Still isolated: the fallback must not be the LOCALAPPDATA path, and
            # must not be the bare home dir either.
            $r.Argv[1] | Should -Not -Be (Join-Path $script:Work 'vscode-ccgw')
        }
    }

    Context '6. Missing code on PATH' {
        It 'is a hard failure that names both the problem and the remedy' {
            $r = Invoke-Launcher -StubDir $script:StubNoCode -Environment (New-Env)
            $r.ExitCode | Should -Not -Be 0 -Because 'a missing code command must not exit 0'
            Assert-Stderr $r "'code' command not found on PATH" 'missing-code: must name the problem'
            Assert-Stderr $r "Install 'code' command in PATH" 'missing-code: must state the remedy'
        }
    }

    Context '7. Repo-root .env loading' {
        # The launcher composes the path as Join-Path (Join-Path $PSScriptRoot '..') '.env',
        # so the separator is the platform's own and these cases run everywhere
        # pwsh does — they are not Windows-gated.

        BeforeAll {
            $script:DotEnvLauncher = New-FixtureTree -Name 'fixture-dotenv' -DotEnvLines @(
                '# comment line must be ignored'
                ''
                'LITELLM_ANTHROPIC_BASE_URL=https://from-dotenv:9'
                'LITELLM_CLIENT_KEY=dotenv-token'
                '  LITELLM_FABLE_MODEL = lite-fable  '
                'MALFORMED_NO_EQUALS'
            )
        }

        It 'loads KEY=value lines and ignores comments and blanks' {
            $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-dotenv:9' 'dotenv: base URL comes from .env'
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'dotenv-token' 'dotenv: auth token comes from .env'
        }

        It 'trims surrounding whitespace around key and value' {
            $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-fable' 'dotenv: whitespace-padded KEY = value is trimmed'
        }

        It 'a non-empty shell value outranks .env' {
            $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher `
                -Environment @{ LITELLM_ANTHROPIC_BASE_URL = 'https://from-shell:1' }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-shell:1' 'dotenv: shell wins over .env'
        }

        It 'a defined-but-empty shell value is treated as unset, so .env still applies' {
            # Every consumer below treats empty as unset, so honouring the empty
            # shell value would silently discard the .env entry.
            $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher `
                -Environment @{ LITELLM_ANTHROPIC_BASE_URL = '' }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-dotenv:9' 'dotenv: empty shell value must not shadow .env'
        }

        It 'a missing .env is not an error when the shell supplies the configuration' {
            $bare = Join-Path $script:Work 'fixture-no-dotenv'
            New-Item -ItemType Directory -Path (Join-Path $bare 'scripts') -Force | Out-Null
            Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $bare 'scripts' 'code-ccgw.ps1') -Force
            $r = Invoke-Launcher -LauncherPath (Join-Path $bare 'scripts' 'code-ccgw.ps1') -Environment (New-Env)
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'dotenv/absent: launcher still runs'
        }
    }
}
