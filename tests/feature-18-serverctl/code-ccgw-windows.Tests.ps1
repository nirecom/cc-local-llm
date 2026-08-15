#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Scenario: the Windows client launcher (pwsh counterpart of
# scripts/code-ccgw.sh) — base-URL / auth-token / TLS-CA precedence chains, the
# mutually-exclusive model-selection branch (LiteLLM routing keys vs the direct
# DS4-Proxy path), the per-tier map that puts the two Mac backends on separate
# /model tiers while subagents follow whichever backend is resident rather than
# the Opus tier (a subagent on the other backend would evict the resident one),
# CCGW_DEFAULT_MODEL picking that resident backend without disturbing the tier
# map (the behaviour the retired .cmd never had), defined-but-empty variables
# being treated as unset, VS Code --user-data-dir isolation with its
# LOCALAPPDATA fallback, and the missing-`code` error.
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
# L3 gap: real VS Code startup and profile creation under the derived
#   --user-data-dir; a real mkcert CA actually being trusted by Node's TLS
#   stack; genuine end-to-end routing of the selected model through the Mac
#   swap layer to a loaded backend; a real Windows host. Also unreachable from
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
            throw "$Context`: $A and $B both resolved to '$($Result.Env[$A])'; the two backends must stay on separate tiers"
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
    # The vars that name the model in play at startup (main session + subagents).
    $script:ActiveVars = @(
        'ANTHROPIC_MODEL'
        'ANTHROPIC_CUSTOM_MODEL_OPTION'
        'CLAUDE_CODE_SUBAGENT_MODEL'
    )
    $script:ModelVars = $script:TierVars + $script:ActiveVars
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'code-ccgw.ps1' {

    Context '1. Base URL precedence' {
        It 'LITELLM must win over CCGW and DS4' {
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
                CCGW_ANTHROPIC_BASE_URL    = 'https://ccgw:2'
                DS4_ANTHROPIC_BASE_URL     = 'https://ds4:3'
            }
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://lite:1' 'base-url/all-three'
        }

        It 'CCGW must win over DS4' {
            $r = Invoke-Launcher -Environment @{
                CCGW_ANTHROPIC_BASE_URL = 'https://ccgw:2'
                DS4_ANTHROPIC_BASE_URL  = 'https://ds4:3'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://ccgw:2' 'base-url/ccgw-over-ds4'
        }

        It 'DS4 is the last named source' {
            $r = Invoke-Launcher -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://ds4:3' 'base-url/ds4-only'
        }

        It 'unset falls back to loopback 8445 and warns' {
            # 8445, not the .sh's 8443: the Windows client reaches the Mac through
            # the LiteLLM gateway running on this same PC.
            $r = Invoke-Launcher
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://localhost:8445' 'base-url/unset'
            Assert-Stderr $r 'Neither LITELLM_ANTHROPIC_BASE_URL nor CCGW_ANTHROPIC_BASE_URL set' 'base-url/unset'
        }

        It 'empty LITELLM value must fall through to CCGW' {
            # A defined-but-empty value must not count as configured — the .cmd's
            # `if defined` accepted an empty string, which this port must not.
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = ''
                CCGW_ANTHROPIC_BASE_URL    = 'https://ccgw:2'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://ccgw:2' 'base-url/empty-litellm'
        }

        It 'empty CCGW and DS4 values fall all the way through to the loopback default' {
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = ''
                CCGW_ANTHROPIC_BASE_URL    = ''
                DS4_ANTHROPIC_BASE_URL     = ''
            }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://localhost:8445' 'base-url/all-empty'
        }
    }

    Context '2. Auth token precedence' {
        It 'LITELLM_VIRTUAL_KEY must win' {
            $r = Invoke-Launcher -Environment @{
                LITELLM_VIRTUAL_KEY = 'vk'
                CCGW_API_KEY        = 'ck'
                DS4_API_KEY         = 'dk'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'vk' 'auth/all-three'
        }

        It 'CCGW_API_KEY must win over DS4_API_KEY' {
            $r = Invoke-Launcher -Environment @{ CCGW_API_KEY = 'ck'; DS4_API_KEY = 'dk' }
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'auth/ccgw-over-ds4'
        }

        It 'DS4_API_KEY is the last named source' {
            $r = Invoke-Launcher -Environment @{ DS4_API_KEY = 'dk' }
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'dk' 'auth/ds4-only'
        }

        It 'unset falls back to the shared local token and warns' {
            $r = Invoke-Launcher
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'dsv4-local' 'auth/unset'
            Assert-Stderr $r 'Neither LITELLM_VIRTUAL_KEY nor CCGW_API_KEY set' 'auth/unset'
        }

        It 'empty LITELLM_VIRTUAL_KEY must fall through to CCGW_API_KEY' {
            $r = Invoke-Launcher -Environment @{ LITELLM_VIRTUAL_KEY = ''; CCGW_API_KEY = 'ck' }
            Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' 'ck' 'auth/empty-virtual-key'
        }

        It 'a pre-existing ANTHROPIC_API_KEY must be cleared so the local backend is used' {
            $r = Invoke-Launcher -Environment @{
                ANTHROPIC_API_KEY = 'cloud-key-must-not-survive'
                DS4_API_KEY       = 'dk'
            }
            $r.Reached | Should -BeTrue -Because "stderr: $($r.StdErr)"
            # Assigning '' removes the variable outright on Windows; both shapes
            # satisfy the contract "no real cloud key reaches Claude Code".
            $got = if ($r.Env.ContainsKey('ANTHROPIC_API_KEY')) { $r.Env['ANTHROPIC_API_KEY'] } else { $null }
            [string]::IsNullOrEmpty($got) | Should -BeTrue -Because "ANTHROPIC_API_KEY survived as '$got'"
        }
    }

    Context '3. TLS CA precedence' {
        It 'CCGW_CA_CERT must win over DS4_CA_CERT' {
            $r = Invoke-Launcher -Environment @{
                CCGW_CA_CERT = 'C:\ca\ccgw.pem'
                DS4_CA_CERT  = 'C:\ca\ds4.pem'
            }
            Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' 'C:\ca\ccgw.pem' 'ca/ccgw-over-ds4'
            Assert-NoCaWarning $r 'ca/ccgw-over-ds4'
        }

        It 'DS4_CA_CERT is the second source' {
            $r = Invoke-Launcher -Environment @{ DS4_CA_CERT = 'C:\ca\ds4.pem' }
            Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' 'C:\ca\ds4.pem' 'ca/ds4-only'
        }

        It 'TLS verification must never be disabled' {
            # NODE_TLS_REJECT_UNAUTHORIZED=0 must never be the launcher's answer to TLS.
            $r = Invoke-Launcher -Environment @{ DS4_CA_CERT = 'C:\ca\ds4.pem' }
            Assert-LauncherEnvUnset $r 'NODE_TLS_REJECT_UNAUTHORIZED' 'ca/no-tls-bypass'
        }

        It 'an empty CCGW_CA_CERT falls through to DS4_CA_CERT' {
            $r = Invoke-Launcher -Environment @{ CCGW_CA_CERT = ''; DS4_CA_CERT = 'C:\ca\ds4.pem' }
            Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' 'C:\ca\ds4.pem' 'ca/empty-ccgw'
        }

        It 'mkcert -CAROOT must be derived when no CA var is set' {
            # 3a. The derivation the retired .cmd did not have.
            $r = Invoke-Launcher -StubDir $script:StubMkcertOk
            Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' (Join-Path $script:CarootOk 'rootCA.pem') 'ca/mkcert-ok'
            Assert-NoCaWarning $r 'ca/mkcert-ok'
        }

        It 'explicit CCGW_CA_CERT must outrank the mkcert derivation' {
            $r = Invoke-Launcher -StubDir $script:StubMkcertOk -Environment @{ CCGW_CA_CERT = 'C:\ca\explicit.pem' }
            Assert-LauncherEnv $r 'NODE_EXTRA_CA_CERTS' 'C:\ca\explicit.pem' 'ca/explicit-over-mkcert'
        }

        It 'a CAROOT without rootCA.pem must not yield a bogus NODE_EXTRA_CA_CERTS' {
            # 3b. mkcert present but its CAROOT holds no rootCA.pem -> warn, export nothing.
            $r = Invoke-Launcher -StubDir $script:StubMkcertBad
            Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/mkcert-empty'
            Assert-Stderr $r 'CCGW_CA_CERT not set' 'ca/mkcert-empty'
        }

        It 'mkcert absent entirely must warn and export nothing' {
            # 3c.
            $r = Invoke-Launcher
            Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/no-mkcert'
            Assert-Stderr $r 'CCGW_CA_CERT not set' 'ca/no-mkcert'
        }

        It 'a failing mkcert warns and still launches instead of aborting' {
            # 3d. mkcert present but exiting non-zero with no CAROOT on stdout.
            # Under PowerShell 7.4+ this used to become a terminating error while
            # ErrorActionPreference is Stop, killing the launcher outright; the
            # script now disables that conversion, so the run must reach `code`.
            # See the L3 note in the header: a .ps1 stub is not a native command,
            # so this reaches the warning through the no-CAROOT branch rather than
            # through the exit-code conversion itself.
            $r = Invoke-Launcher -StubDir $script:StubMkcertFails
            $r.Reached | Should -BeTrue -Because "a failing mkcert must not abort the launcher; stderr: $($r.StdErr)"
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            Assert-LauncherEnvUnset $r 'NODE_EXTRA_CA_CERTS' 'ca/mkcert-fails'
            Assert-Stderr $r 'CCGW_CA_CERT not set' 'ca/mkcert-fails'
        }
    }

    Context '4. Model selection (the two backends on separate /model tiers)' {
        # The two mutually-exclusive Mac backends are placed on different Claude
        # Code tiers so `/model` switches between them: fable -> ds4,
        # opus -> Laguna S 2.1. Subagents follow whichever backend is resident
        # (CCGW_DEFAULT_MODEL on the direct path, the fable routing key on the
        # LiteLLM one) rather than the Opus tier — a subagent landing on the
        # other backend would evict the resident one mid-session.

        It '4a. direct path puts each tier on its own backend' {
            $r = Invoke-Launcher -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'deepseek-v4-flash' 'direct: fable tier is ds4'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'laguna-s-2.1' 'direct: opus tier is the other backend'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'deepseek-v4-flash' 'direct: sonnet tier is ds4'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash' 'direct: haiku tier is ds4'
            foreach ($v in $script:ActiveVars) {
                Assert-LauncherEnv $r $v 'deepseek-v4-flash' 'direct: startup model defaults to ds4'
            }
            # Stated as an inequality too: a regression that collapses both tiers
            # onto one backend would still satisfy each literal individually if
            # both literals moved.
            Assert-LauncherEnvDiffers $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'ANTHROPIC_DEFAULT_OPUS_MODEL' `
                'direct: fable and opus must address different backends or /model cannot switch'
        }

        It '4b. CCGW_DEFAULT_MODEL moves only the active vars, never the tier map' {
            # The newly added behaviour: CCGW_DEFAULT_MODEL only picks which
            # backend is resident at startup. If it also rewrote the tier vars,
            # /model would lose one of the two backends entirely.
            $r = Invoke-Launcher -Environment @{
                DS4_ANTHROPIC_BASE_URL = 'https://ds4:3'
                CCGW_DEFAULT_MODEL     = 'laguna-s-2.1'
            }
            foreach ($v in $script:ActiveVars) {
                Assert-LauncherEnv $r $v 'laguna-s-2.1' 'direct: CCGW_DEFAULT_MODEL selects the startup-resident backend'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'deepseek-v4-flash' 'direct/ccgw-default: fable tier must stay on ds4'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'laguna-s-2.1' 'direct/ccgw-default: opus tier must stay on Laguna'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'deepseek-v4-flash' 'direct/ccgw-default: sonnet tier must stay on ds4'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash' 'direct/ccgw-default: haiku tier must stay on ds4'
            Assert-LauncherEnvDiffers $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'ANTHROPIC_DEFAULT_OPUS_MODEL' `
                'direct/ccgw-default: the tier map must survive a startup-model override'
        }

        It '4b-ii. an arbitrary CCGW_DEFAULT_MODEL still leaves all four tier vars untouched' {
            # Same invariant stated against a value that is neither tier literal,
            # so a "copy the override into every model var" regression cannot pass
            # by coinciding with the opus tier.
            $r = Invoke-Launcher -Environment @{
                DS4_ANTHROPIC_BASE_URL = 'https://ds4:3'
                CCGW_DEFAULT_MODEL     = 'some-other-backend'
            }
            foreach ($v in $script:ActiveVars) {
                Assert-LauncherEnv $r $v 'some-other-backend' 'direct/ccgw-default-arbitrary: active vars follow the override'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'deepseek-v4-flash' 'direct/ccgw-default-arbitrary: fable tier untouched'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'laguna-s-2.1' 'direct/ccgw-default-arbitrary: opus tier untouched'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'deepseek-v4-flash' 'direct/ccgw-default-arbitrary: sonnet tier untouched'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash' 'direct/ccgw-default-arbitrary: haiku tier untouched'
        }

        It 'an empty CCGW_DEFAULT_MODEL must fall back to the default model name' {
            # An empty model name is unroutable by the swap layer, so
            # defined-but-empty has to mean "unset" here too.
            $r = Invoke-Launcher -Environment @{
                DS4_ANTHROPIC_BASE_URL = 'https://ds4:3'
                CCGW_DEFAULT_MODEL     = ''
            }
            foreach ($v in $script:ActiveVars) {
                Assert-LauncherEnv $r $v 'deepseek-v4-flash' 'direct: empty CCGW_DEFAULT_MODEL must fall back to the default'
            }
        }

        It '4c. LiteLLM path uses the routing keys verbatim on their own tiers' {
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
                LITELLM_FABLE_MODEL        = 'lite-fable'
                LITELLM_OPUS_MODEL         = 'lite-opus'
                LITELLM_SONNET_MODEL       = 'lite-sonnet'
                LITELLM_HAIKU_MODEL        = 'lite-haiku'
                CCGW_DEFAULT_MODEL         = 'laguna-s-2.1'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-fable' 'litellm: fable routing key'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'litellm: opus routing key'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'lite-sonnet' 'litellm: sonnet routing key'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-haiku' 'litellm: haiku routing key'
            Assert-LauncherEnv $r 'ANTHROPIC_MODEL' 'lite-fable' 'litellm: startup model follows the fable tier'
            Assert-LauncherEnv $r 'ANTHROPIC_CUSTOM_MODEL_OPTION' 'lite-fable' 'litellm: custom model option follows the fable tier'
            # Load-bearing: on this path the resident backend is the fable routing
            # key, so subagents must track it rather than the opus tier — a
            # subagent on the opus backend would evict the resident one.
            Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'lite-fable' 'litellm: subagent must follow the resident backend, not opus'
            Assert-LauncherEnvDiffers $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'ANTHROPIC_DEFAULT_OPUS_MODEL' `
                'litellm: subagent must not be pinned to the opus tier'
            # CCGW_DEFAULT_MODEL was also set above: on the LiteLLM path it must be
            # ignored, and no deepseek-*/laguna-* name may appear in any model var.
            foreach ($v in $script:ModelVars) {
                $val = if ($r.Env.ContainsKey($v)) { $r.Env[$v] } else { '' }
                $val | Should -Not -Match '(?i)deepseek' -Because "litellm: $v='$val' leaked a direct-path backend name"
                $val | Should -Not -Match '(?i)laguna' -Because "litellm: $v='$val' leaked a direct-path backend name"
            }
        }

        It '4d. LiteLLM base URL with no routing keys must invent nothing' {
            $r = Invoke-Launcher -Environment @{ LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1' }
            foreach ($v in $script:ModelVars) {
                Assert-LauncherEnvUnset $r $v 'litellm/no-keys: launcher must not substitute a direct-path model'
            }
        }

        It '4e. LiteLLM path without the fable key leaves the startup vars unset' {
            # The fable tier drives the startup/subagent vars, so with
            # LITELLM_FABLE_MODEL absent they must stay unset rather than
            # borrowing the opus key or a direct-path name.
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
                LITELLM_OPUS_MODEL         = 'lite-opus'
                LITELLM_SONNET_MODEL       = 'lite-sonnet'
                LITELLM_HAIKU_MODEL        = 'lite-haiku'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'litellm/no-fable: opus routing key still applies'
            Assert-LauncherEnvUnset $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'litellm/no-fable: no fable key means no fable tier'
            foreach ($v in $script:ActiveVars) {
                Assert-LauncherEnvUnset $r $v 'litellm/no-fable: launcher must invent no backend name of its own'
            }
        }

        It '4f. stale LITELLM_* routing keys must never leak onto the direct path' {
            # DS4 Proxy / the swap layer do not recognise LiteLLM routing keys.
            $r = Invoke-Launcher -Environment @{
                DS4_ANTHROPIC_BASE_URL = 'https://ds4:3'
                LITELLM_FABLE_MODEL    = 'lite-fable'
                LITELLM_OPUS_MODEL     = 'lite-opus'
                LITELLM_SONNET_MODEL   = 'lite-sonnet'
                LITELLM_HAIKU_MODEL    = 'lite-haiku'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'deepseek-v4-flash' 'direct/stale-litellm-keys: fable tier stays on ds4'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'laguna-s-2.1' 'direct/stale-litellm-keys: opus tier stays on Laguna'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'deepseek-v4-flash' 'direct/stale-litellm-keys: sonnet tier stays on ds4'
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash' 'direct/stale-litellm-keys: haiku tier stays on ds4'
            foreach ($v in $script:ActiveVars) {
                Assert-LauncherEnv $r $v 'deepseek-v4-flash' 'direct/stale-litellm-keys: routing keys must not leak onto the direct path'
            }
            foreach ($v in $script:ModelVars) {
                $val = if ($r.Env.ContainsKey($v)) { $r.Env[$v] } else { '' }
                $val | Should -Not -Match '(?i)^lite-' -Because "direct: $v='$val' carries a LiteLLM routing key"
            }
        }

        It 'an empty LITELLM_ANTHROPIC_BASE_URL selects the direct path, not the LiteLLM one' {
            $r = Invoke-Launcher -Environment @{
                LITELLM_ANTHROPIC_BASE_URL = ''
                DS4_ANTHROPIC_BASE_URL     = 'https://ds4:3'
                LITELLM_FABLE_MODEL        = 'lite-fable'
            }
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'deepseek-v4-flash' 'empty-litellm-url: direct tier map applies'
            Assert-LauncherEnv $r 'ANTHROPIC_MODEL' 'deepseek-v4-flash' 'empty-litellm-url: direct startup model applies'
        }
    }

    Context '5. VS Code profile isolation and argv passthrough' {
        It 'passes an isolated --user-data-dir under LOCALAPPDATA plus the caller argv' {
            $r = Invoke-Launcher -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' } `
                -Arguments @('C:\some\project', '--new-window')
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            $expected = @('--user-data-dir', (Join-Path $script:LocalAppData 'vscode-ccgw'), 'C:\some\project', '--new-window')
            @($r.Argv) | Should -Be $expected
        }

        It 'passes only the --user-data-dir pair when the caller supplied no argv' {
            $r = Invoke-Launcher -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' }
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
            $r = Invoke-Launcher -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' } -NoLocalAppData
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
            $r = Invoke-Launcher -StubDir $script:StubNoCode -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' }
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
                'DS4_ANTHROPIC_BASE_URL=https://from-dotenv:9'
                'DS4_API_KEY=dotenv-token'
                '  CCGW_DEFAULT_MODEL = laguna-s-2.1  '
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
            Assert-LauncherEnv $r 'ANTHROPIC_MODEL' 'laguna-s-2.1' 'dotenv: whitespace-padded KEY = value is trimmed'
        }

        It 'a non-empty shell value outranks .env' {
            $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher `
                -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://from-shell:1' }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-shell:1' 'dotenv: shell wins over .env'
        }

        It 'a defined-but-empty shell value is treated as unset, so .env still applies' {
            # Every consumer below treats empty as unset, so honouring the empty
            # shell value would silently discard the .env entry.
            $r = Invoke-Launcher -LauncherPath $script:DotEnvLauncher `
                -Environment @{ DS4_ANTHROPIC_BASE_URL = '' }
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://from-dotenv:9' 'dotenv: empty shell value must not shadow .env'
        }

        It 'a missing .env is not an error' {
            $bare = Join-Path $script:Work 'fixture-no-dotenv'
            New-Item -ItemType Directory -Path (Join-Path $bare 'scripts') -Force | Out-Null
            Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $bare 'scripts' 'code-ccgw.ps1') -Force
            $r = Invoke-Launcher -LauncherPath (Join-Path $bare 'scripts' 'code-ccgw.ps1') `
                -Environment @{ DS4_ANTHROPIC_BASE_URL = 'https://ds4:3' }
            $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
            Assert-LauncherEnv $r 'ANTHROPIC_BASE_URL' 'https://ds4:3' 'dotenv/absent: launcher still runs'
        }
    }
}
