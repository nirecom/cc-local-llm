#!/usr/bin/env pwsh
# Tests: install.ps1, install/win/lib/roles.ps1, install/win/lib/nssm-args.ps1, install/win/lib/native.ps1, install/win/llama-swap-service.ps1, install/win/certs.ps1
# Tags: installer, windows, pwsh-required, nssm, pester, ast, layer:TL2, scope:common
# scope:common despite the feature-86- dir: the role matrix, the NSSM argument shapes and the "no bare native call" rule are permanent contracts.
# Only install/win/lib/*.ps1 are dot-sourced -- they hold function definitions and nothing else, so loading them is inert. install.ps1 / llama-swap-service.ps1 / certs.ps1 are read through the AST and NEVER executed, so this suite touches neither NSSM nor any service. Rationale: detail plan 4-1 / 4-3 / 6-5.
# Driver (skip gating, 120s timeout, exit 77 off-Windows): test-install-win-server.sh in this directory.
# TL3 gap (what this suite does NOT catch):
# - whether nssm accepts the settings hash and the two services actually reach Running
# - whether mkcert/winget/caddy exist and behave as the exit-code policy assumes
# - whether re-running the installer over an existing registration is idempotent (only the pure builders are checked here)
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh categories: installer, pwsh-required

$RepoRoot   = if ($env:CCLL_REPO) { $env:CCLL_REPO } else { (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path }
$LibDir     = Join-Path $RepoRoot 'install\win\lib'
$WinDir     = Join-Path $RepoRoot 'install\win'
$RolesPs1   = Join-Path $LibDir 'roles.ps1'
$NssmPs1    = Join-Path $LibDir 'nssm-args.ps1'
$NativePs1  = Join-Path $LibDir 'native.ps1'
$LibsPresent = (Test-Path $RolesPs1) -and (Test-Path $NssmPs1) -and (Test-Path $NativePs1)

# Pester 5 discovery and run are separate scopes: the assignments above are what
# the -Skip: conditions read (discovery), and this BeforeAll is what the It bodies
# read (run). $env:CCLL_REPO is the Windows-path counterpart of the bash suites'
# $REPO override, set by the driver so the two cannot disagree on the checkout.
BeforeAll {
    $RepoRoot  = if ($env:CCLL_REPO) { $env:CCLL_REPO } else { (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path }
    $LibDir    = Join-Path $RepoRoot 'install\win\lib'
    $WinDir    = Join-Path $RepoRoot 'install\win'
    $RolesPs1  = Join-Path $LibDir 'roles.ps1'
    $NssmPs1   = Join-Path $LibDir 'nssm-args.ps1'
    $NativePs1 = Join-Path $LibDir 'native.ps1'

    function Get-ScriptAst([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "parse errors in ${Path}: $($errors[0].Message)" }
        return $ast
    }

    function Test-ParamIsMandatory($Ast, [string]$Name) {
        $p = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
        if (-not $p) { return $false }
        foreach ($a in $p.Attributes) {
            if ($a -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
            if ($a.TypeName.GetReflectionType() -ne [Parameter] -and $a.TypeName.Name -ne 'Parameter') { continue }
            foreach ($na in $a.NamedArguments) {
                if ($na.ArgumentName -eq 'Mandatory') { return $true }
            }
        }
        return $false
    }
}

Describe 'Resolve-InstallRole (role matrix, detail plan 4-3)' -Skip:(-not $LibsPresent) {
    BeforeAll { . $RolesPs1 }

    # Every accepted combination, including the no-argument back-compat default.
    It 'resolves <name> to <expected>' -TestCases @(
        @{ name = 'no arguments';      splat = @{};                                   expected = 'client' }
        @{ name = '-Client';           splat = @{ Client = $true };                    expected = 'client' }
        @{ name = '-Server';           splat = @{ Server = $true };                    expected = 'server' }
        @{ name = '-All';              splat = @{ All = $true };                       expected = 'all' }
        @{ name = '-Server -Uninstall'; splat = @{ Server = $true; Uninstall = $true }; expected = 'server' }
    ) {
        $got = Resolve-InstallRole @splat
        $got | Should -Be $expected
    }

    # Every rejected combination. A role switch is exclusive, and -Uninstall has
    # exactly one meaningful target (server); anything else is refused rather
    # than guessed, because the guess would be a destructive one.
    It 'refuses <name>' -TestCases @(
        @{ name = '-Server -Client';        splat = @{ Server = $true; Client = $true } }
        @{ name = '-Server -All';           splat = @{ Server = $true; All = $true } }
        @{ name = '-Client -All';           splat = @{ Client = $true; All = $true } }
        @{ name = '-Server -Client -All';   splat = @{ Server = $true; Client = $true; All = $true } }
        @{ name = '-Uninstall alone';       splat = @{ Uninstall = $true } }
        @{ name = '-Client -Uninstall';     splat = @{ Client = $true; Uninstall = $true } }
        @{ name = '-All -Uninstall';        splat = @{ All = $true; Uninstall = $true } }
    ) {
        { Resolve-InstallRole @splat } | Should -Throw
    }
}

Describe 'Get-LlamaSwapNssmSettings' -Skip:(-not $LibsPresent) {
    BeforeAll {
        . $NssmPs1
        $script:RuntimeDir = 'C:\LLM\llama-swap'
        $script:ConfigPath = 'C:\LLM\cc-local-llm\llama-swap\rtx5070ti-128gb\config.yaml'
        $script:ListenAddr = '127.0.0.1:18080'
        $script:RotateBytes = 10485760
        $script:S = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -ListenAddr $ListenAddr -LogRotateBytes $RotateBytes
    }

    It 'returns the exact NSSM setting name set' {
        # Strict: a dropped setting is as much a regression as a wrong value.
        $expected = @(
            'Application', 'AppParameters', 'AppDirectory', 'Start', 'DisplayName', 'Description',
            'AppStdout', 'AppStderr', 'AppRotateFiles', 'AppRotateOnline', 'AppRotateBytes',
            'AppStdoutCreationDisposition', 'AppStderrCreationDisposition'
        ) | Sort-Object
        ((@($S.Keys) | Sort-Object) -join ',') | Should -Be ($expected -join ',')
    }

    It 'derives the executable and working directory from -RuntimeDir' {
        $S['Application']  | Should -Be (Join-Path $RuntimeDir 'llama-swap.exe')
        $S['AppDirectory'] | Should -Be $RuntimeDir
    }

    It 'builds AppParameters as --config <path> --listen <addr> --watch-config' {
        $S['AppParameters'] | Should -Be "--config $ConfigPath --listen $ListenAddr --watch-config"
    }

    It 'writes both log streams into the runtime directory' {
        $S['AppStdout'] | Should -Be (Join-Path $RuntimeDir 'service-stdout.log')
        $S['AppStderr'] | Should -Be (Join-Path $RuntimeDir 'service-stderr.log')
    }

    It 'sets log rotation (C6 regression guard: caddy-stderr.log once reached 125 MB)' {
        $S['AppRotateFiles']  | Should -Be 1
        $S['AppRotateOnline'] | Should -Be 1
        $S['AppRotateBytes']  | Should -Be $RotateBytes
        $S['AppStdoutCreationDisposition'] | Should -Be 4
        $S['AppStderrCreationDisposition'] | Should -Be 4
    }

    It 'starts automatically and names itself' {
        $S['Start'] | Should -Be 'SERVICE_AUTO_START'
        $S['DisplayName'] | Should -Not -BeNullOrEmpty
        $S['Description'] | Should -Not -BeNullOrEmpty
    }

    It 'threads a non-default -LogRotateBytes through instead of hardcoding it' {
        $alt = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -ListenAddr $ListenAddr -LogRotateBytes 4096
        $alt['AppRotateBytes'] | Should -Be 4096
    }

    It 'threads a non-default -ListenAddr through (single source for the port)' {
        $alt = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -ListenAddr '127.0.0.1:19999' -LogRotateBytes $RotateBytes
        $alt['AppParameters'] | Should -BeLike '*--listen 127.0.0.1:19999*'
        $alt['AppParameters'] | Should -Not -BeLike '*18080*'
    }

    It 'returns the identical hash on a second call (re-running the installer is safe)' {
        # The installer is re-run to upgrade; if this builder accumulated state or
        # appended to a shared collection, the second registration would silently
        # differ from the first.
        $again = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -ListenAddr $ListenAddr -LogRotateBytes $RotateBytes
        (($again.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n") |
            Should -Be (($S.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
    }
}

Describe 'Get-CaddyNssmSettings' -Skip:(-not $LibsPresent) {
    BeforeAll {
        . $NssmPs1
        $script:RuntimeDir = 'C:\LLM\llama-swap'
        $script:CaddyExe   = 'C:\Program Files\Caddy\caddy.exe'
        $script:Caddyfile  = 'C:\LLM\llama-swap\Caddyfile'
        $script:C = Get-CaddyNssmSettings -RuntimeDir $RuntimeDir -CaddyExe $CaddyExe -Caddyfile $Caddyfile -LogRotateBytes 10485760
    }

    It 'returns the same NSSM setting name set as the llama-swap side (CPR-ORTH)' {
        $expected = @(
            'Application', 'AppParameters', 'AppDirectory', 'Start', 'DisplayName', 'Description',
            'AppStdout', 'AppStderr', 'AppRotateFiles', 'AppRotateOnline', 'AppRotateBytes',
            'AppStdoutCreationDisposition', 'AppStderrCreationDisposition'
        ) | Sort-Object
        ((@($C.Keys) | Sort-Object) -join ',') | Should -Be ($expected -join ',')
    }

    It 'builds AppParameters as run --config <caddyfile> --adapter caddyfile' {
        $C['Application']   | Should -Be $CaddyExe
        $C['AppParameters'] | Should -Be "run --config $Caddyfile --adapter caddyfile"
        $C['AppDirectory']  | Should -Be $RuntimeDir
    }

    It 'writes its own log pair, distinct from the llama-swap pair' {
        $C['AppStdout'] | Should -Be (Join-Path $RuntimeDir 'caddy-stdout.log')
        $C['AppStderr'] | Should -Be (Join-Path $RuntimeDir 'caddy-stderr.log')
    }

    It 'sets log rotation on its pair too (the 125 MB file was this service)' {
        $C['AppRotateFiles']  | Should -Be 1
        $C['AppRotateOnline'] | Should -Be 1
        $C['AppRotateBytes']  | Should -Be 10485760
        $C['AppStdoutCreationDisposition'] | Should -Be 4
        $C['AppStderrCreationDisposition'] | Should -Be 4
    }

    It 'returns the identical hash on a second call (CPR-ORTH with the llama-swap side)' {
        $again = Get-CaddyNssmSettings -RuntimeDir $RuntimeDir -CaddyExe $CaddyExe -Caddyfile $Caddyfile -LogRotateBytes 10485760
        (($again.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n") |
            Should -Be (($C.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
    }
}

Describe 'Invoke-Native exit-code policy (C5)' -Skip:(-not ($LibsPresent -and $IsWindows)) {
    BeforeAll { . $NativePs1 }

    It 'accepts exit 0' {
        { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit', '0') -Context 'probe-zero' } | Should -Not -Throw
    }

    It 'throws on a non-zero exit when no code is allowed' {
        { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit', '3') -Context 'probe-three' } | Should -Throw
    }

    It 'accepts a non-zero exit that was explicitly allowed' {
        { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit', '3') -AllowExitCodes 3 -Context 'probe-allow' } | Should -Not -Throw
    }

    It 'allows only the enumerated codes, not "any non-zero"' {
        { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit', '1') -AllowExitCodes 3 -Context 'probe-narrow' } | Should -Throw
    }

    It 'reports the command line, the exit code and the -Context in the failure' {
        $msg = ''
        try { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit', '7') -Context 'probe-message' }
        catch { $msg = "$_" }
        $msg | Should -Not -BeNullOrEmpty
        $msg | Should -BeLike '*cmd.exe*'
        $msg | Should -BeLike '*7*'
        $msg | Should -BeLike '*probe-message*'
    }
}

Describe 'Source-structure contracts (AST only, nothing is executed)' {
    It 'install.ps1 exposes exactly Server/Client/All/Uninstall/LanIp' -Skip:(-not $LibsPresent) {
        $ast = Get-ScriptAst (Join-Path $RepoRoot 'install.ps1')
        $ast.ParamBlock | Should -Not -BeNullOrEmpty
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Sort-Object
        ($names -join ',') | Should -Be ((@('All', 'Client', 'LanIp', 'Server', 'Uninstall') | Sort-Object) -join ',')
    }

    It 'llama-swap-service.ps1 keeps RuntimeDir/ConfigPath/CertDir Mandatory' -Skip:(-not (Test-Path (Join-Path $WinDir 'llama-swap-service.ps1'))) {
        # The co-location assumption became explicit arguments; a re-introduced
        # default would silently restore it (detail plan 4-7).
        $ast = Get-ScriptAst (Join-Path $WinDir 'llama-swap-service.ps1')
        foreach ($p in 'RuntimeDir', 'ConfigPath', 'CertDir') {
            Test-ParamIsMandatory $ast $p | Should -BeTrue -Because "$p must stay Mandatory"
        }
    }

    It 'certs.ps1 keeps CertDir/SanNames Mandatory (SAN requirement, C1)' -Skip:(-not (Test-Path (Join-Path $WinDir 'certs.ps1'))) {
        $ast = Get-ScriptAst (Join-Path $WinDir 'certs.ps1')
        foreach ($p in 'CertDir', 'SanNames') {
            Test-ParamIsMandatory $ast $p | Should -BeTrue -Because "$p must stay Mandatory"
        }
    }

    It 'no bare native invocation lives outside install/win/lib/native.ps1' -Skip:(-not (Test-Path $WinDir)) {
        $banned = @('nssm', 'sc.exe', 'sc', 'taskkill', 'netstat', 'winget', 'mkcert', 'certutil')
        $files = @(Get-ChildItem -Path $WinDir -Filter '*.ps1' -Recurse -File | Where-Object { $_.FullName -ne (Join-Path $LibDir 'native.ps1') })
        $files.Count | Should -BeGreaterThan 0 -Because 'a zero-file scan would pass vacuously'
        $offenders = @()
        foreach ($f in $files) {
            $ast = Get-ScriptAst $f.FullName
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $c.GetCommandName()
                if (-not $name) { continue }
                $leaf = [System.IO.Path]::GetFileName($name).ToLowerInvariant()
                if ($banned -contains $leaf) { $offenders += "$($f.Name):$($c.Extent.StartLineNumber) -> $name" }
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }

    It 'install/win/lib/*.ps1 contain function definitions and nothing else' -Skip:(-not $LibsPresent) {
        # If a lib ever gains a top-level statement, dot-sourcing it from Pester
        # stops being inert and this suite becomes destructive (C2).
        $offenders = @()
        foreach ($f in Get-ChildItem -Path $LibDir -Filter '*.ps1' -File) {
            $ast = Get-ScriptAst $f.FullName
            foreach ($b in 'BeginBlock', 'ProcessBlock') {
                if ($ast.$b) { $offenders += "$($f.Name): unexpected $b" }
            }
            foreach ($st in $ast.EndBlock.Statements) {
                if ($st -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $offenders += "$($f.Name):$($st.Extent.StartLineNumber) -> top-level statement '$($st.Extent.Text.Split("`n")[0])'"
                }
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }
}
