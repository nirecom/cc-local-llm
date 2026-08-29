#!/usr/bin/env pwsh
# Tests: install.ps1, install/win/certs.ps1, install/win/llama-swap-service.ps1, install/win/lib/nssm-args.ps1
# Tags: installer, windows, pwsh-required, validation, boundary, ast, pester, layer:TL2, scope:common
# scope:common despite the feature-86- dir: rejecting bad input is a permanent property of the installer, not #86 arithmetic.
# The sibling suites ask "does the happy path build the right thing". This one asks the other half: what happens at the edges of each input -- an empty path, a path with a space, a rotation size of 0 or int max, an unvalidated LanIp or SanNames. Every case here is a value an operator can actually type.
# The builders under lib/ are pure and are called for real; install.ps1 and certs.ps1 are read through the AST only, so nothing is executed (detail plan 4-1 boundary).
# Driver (skip gating, exit 77 off-Windows): test-install-win-server.sh in this directory.
# TL3 gap (what this suite does NOT catch):
# - whether NSSM itself survives a quoted path with a space in AppParameters (only `nssm get` on the host shows that)
# - whether a rejected LanIp produces a message the operator can act on (the AST sees the attribute, not the text)
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh categories: installer, pwsh-required

$RepoRoot    = if ($env:CCLL_REPO) { $env:CCLL_REPO } else { (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path }
$WinDir      = Join-Path $RepoRoot 'install\win'
$NssmPs1     = Join-Path $WinDir 'lib\nssm-args.ps1'
$InstallPs1  = Join-Path $RepoRoot 'install.ps1'
$CertsPs1    = Join-Path $WinDir 'certs.ps1'
$ServicePs1  = Join-Path $WinDir 'llama-swap-service.ps1'
$BuildersPresent = Test-Path $NssmPs1
$SourcesPresent  = (Test-Path $InstallPs1) -and (Test-Path $CertsPs1) -and (Test-Path $ServicePs1)

# Pester 5 keeps discovery and run in separate scopes: the assignments above are
# what the -Skip: conditions read, and this BeforeAll is what the It bodies read.
BeforeAll {
    $RepoRoot   = if ($env:CCLL_REPO) { $env:CCLL_REPO } else { (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path }
    $WinDir     = Join-Path $RepoRoot 'install\win'
    $NssmPs1    = Join-Path $WinDir 'lib\nssm-args.ps1'
    $InstallPs1 = Join-Path $RepoRoot 'install.ps1'
    $CertsPs1   = Join-Path $WinDir 'certs.ps1'
    $ServicePs1 = Join-Path $WinDir 'llama-swap-service.ps1'

    function Get-ScriptAst([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "parse errors in ${Path}: $($errors[0].Message)" }
        return $ast
    }

    function Get-ParamAst($Ast, [string]$Name) {
        return $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
    }

    # The names of every attribute on a parameter, e.g. Parameter, ValidatePattern.
    function Get-ParamAttributeNames($Ast, [string]$Name) {
        $p = Get-ParamAst $Ast $Name
        if (-not $p) { return @() }
        return @($p.Attributes | ForEach-Object { $_.TypeName.Name })
    }

    # A Validate* attribute, or an explicit guard in the body that names the
    # variable and throws. Either is real validation; neither present is not.
    function Test-ParamIsValidated($Ast, [string]$Name) {
        foreach ($a in @(Get-ParamAttributeNames $Ast $Name)) {
            if ($a -like 'Validate*') { return $true }
        }
        foreach ($t in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)) {
            $vars = @($t.Parent.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                ForEach-Object { $_.VariablePath.UserPath })
            if ($vars -contains $Name) { return $true }
        }
        return $false
    }
}

Describe 'Log rotation size boundaries (the 125 MB incident is why rotation exists)' -Skip:(-not $BuildersPresent) {
    BeforeAll {
        . $NssmPs1
        $script:RuntimeDir = 'C:\LLM\llama-swap'
        $script:ConfigPath = 'C:\LLM\cc-local-llm\llama-swap\rtx5070ti-128gb\config.yaml'
        $script:CaddyExe   = 'C:\Program Files\Caddy\caddy.exe'
        $script:Caddyfile  = 'C:\LLM\llama-swap\Caddyfile'
    }

    # Both builders, same table (CPR-ORTH): a size that one accepts and the other
    # rejects would leave the two services rotating on different rules.
    It '<builder> refuses a rotation size of <size>' -TestCases @(
        @{ builder = 'llama-swap'; size = 0 }
        @{ builder = 'llama-swap'; size = -1 }
        @{ builder = 'llama-swap'; size = -10485760 }
        @{ builder = 'caddy';      size = 0 }
        @{ builder = 'caddy';      size = -1 }
        @{ builder = 'caddy';      size = -10485760 }
    ) {
        # 0 means "never rotate" to NSSM, which is exactly the state that grew a
        # 125 MB caddy-stderr.log. It must not be reachable by passing a number.
        if ($builder -eq 'llama-swap') {
            { Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -LogRotateBytes $size } |
                Should -Throw -Because 'a non-positive rotation size silently disables rotation'
        } else {
            { Get-CaddyNssmSettings -RuntimeDir $RuntimeDir -CaddyExe $CaddyExe -Caddyfile $Caddyfile -LogRotateBytes $size } |
                Should -Throw -Because 'a non-positive rotation size silently disables rotation'
        }
    }

    It 'accepts the largest int without overflowing into a negative AppRotateBytes' {
        $s = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -LogRotateBytes ([int]::MaxValue)
        $s['AppRotateBytes'] | Should -Be ([int]::MaxValue)
        [int]$s['AppRotateBytes'] | Should -BeGreaterThan 0
    }

    It 'accepts the smallest positive size (the boundary next to the rejected 0)' {
        # Paired with the size=0 case above so the rule is a boundary, not a ban.
        $s = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -LogRotateBytes 1
        $s['AppRotateBytes'] | Should -Be 1
    }

    It 'defaults to a rotation size that is positive and at least 1 MB' {
        $s = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath
        $c = Get-CaddyNssmSettings -RuntimeDir $RuntimeDir -CaddyExe $CaddyExe -Caddyfile $Caddyfile
        [int]$s['AppRotateBytes'] | Should -BeGreaterThan 1048575
        [int]$c['AppRotateBytes'] | Should -Be ([int]$s['AppRotateBytes']) -Because 'both services must default to the same size'
    }
}

Describe 'Path parameter boundaries' -Skip:(-not $BuildersPresent) {
    BeforeAll {
        . $NssmPs1
        $script:RuntimeDir = 'C:\LLM\llama-swap'
        $script:ConfigPath = 'C:\LLM\cc-local-llm\llama-swap\rtx5070ti-128gb\config.yaml'
        $script:CaddyExe   = 'C:\Program Files\Caddy\caddy.exe'
        $script:Caddyfile  = 'C:\LLM\llama-swap\Caddyfile'
    }

    It 'refuses an empty <param>' -TestCases @(
        @{ param = 'RuntimeDir' }
        @{ param = 'ConfigPath' }
    ) {
        $splat = @{ RuntimeDir = $RuntimeDir; ConfigPath = $ConfigPath }
        $splat[$param] = ''
        { Get-LlamaSwapNssmSettings @splat } | Should -Throw -Because "an empty $param would build a service pointing at the filesystem root"
    }

    It 'refuses a whitespace-only RuntimeDir' {
        { Get-LlamaSwapNssmSettings -RuntimeDir '   ' -ConfigPath $ConfigPath } |
            Should -Throw -Because 'Mandatory alone accepts a blank string'
    }

    It 'quotes a ConfigPath containing a space, so NSSM does not split it into two arguments' {
        # AppParameters is one flat string handed to NSSM; an unquoted
        # "C:\Program Files\..." becomes --config C:\Program plus a stray token,
        # and llama-swap starts with the wrong config or not at all.
        $spaced = 'C:\Program Files\cc-local-llm\llama-swap\rtx5070ti-128gb\config.yaml'
        $s = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $spaced
        $s['AppParameters'] | Should -BeLike "*`"$spaced`"*"
    }

    It 'quotes a Caddyfile path containing a space too (CPR-ORTH)' {
        $spaced = 'C:\Program Files\llama-swap\Caddyfile'
        $c = Get-CaddyNssmSettings -RuntimeDir $RuntimeDir -CaddyExe $CaddyExe -Caddyfile $spaced
        $c['AppParameters'] | Should -BeLike "*`"$spaced`"*"
    }

    It 'leaves a space-free path unquoted (the quoting is conditional, not blanket)' {
        # Classifier guard: quoting everything would satisfy the two cases above
        # while changing every existing registration's AppParameters.
        $s = Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath
        $s['AppParameters'] | Should -Not -BeLike '*"*'
    }

    It 'keeps a RuntimeDir with a space intact in every derived path' {
        $spaced = 'C:\Program Files\llama-swap'
        $s = Get-LlamaSwapNssmSettings -RuntimeDir $spaced -ConfigPath $ConfigPath
        $s['Application']  | Should -Be (Join-Path $spaced 'llama-swap.exe')
        $s['AppDirectory'] | Should -Be $spaced
        $s['AppStdout']    | Should -Be (Join-Path $spaced 'service-stdout.log')
    }

    It 'refuses a ListenAddr that is not host:port' -TestCases @(
        @{ addr = '' }
        @{ addr = '127.0.0.1' }
        @{ addr = '127.0.0.1:' }
        @{ addr = '127.0.0.1:notaport' }
        @{ addr = '127.0.0.1:70000' }
    ) {
        # The port here is the single source for the front-end mapping; a bad one
        # reaches NSSM as a literal and the service fails long after the install
        # reported success.
        { Get-LlamaSwapNssmSettings -RuntimeDir $RuntimeDir -ConfigPath $ConfigPath -ListenAddr $addr } | Should -Throw
    }
}

Describe 'Operator-supplied identity is validated before it reaches a certificate (AST only)' -Skip:(-not $SourcesPresent) {

    It 'install.ps1 validates -LanIp' {
        # An unvalidated LanIp is baked into the certificate SAN list. A typo
        # produces a cert that every client silently rejects, days later.
        $ast = Get-ScriptAst $InstallPs1
        Get-ParamAst $ast 'LanIp' | Should -Not -BeNullOrEmpty
        Test-ParamIsValidated $ast 'LanIp' | Should -BeTrue -Because '-LanIp needs a Validate* attribute or an explicit guard that throws'
    }

    It 'certs.ps1 validates -SanNames rather than accepting an empty list' {
        # [string[]] with Mandatory still accepts @(), and mkcert called with no
        # names produces a certificate good for nothing.
        $ast = Get-ScriptAst $CertsPs1
        $p = Get-ParamAst $ast 'SanNames'
        $p | Should -Not -BeNullOrEmpty
        Test-ParamIsValidated $ast 'SanNames' | Should -BeTrue -Because '-SanNames needs a Validate* attribute or an explicit guard that throws'
    }

    It 'certs.ps1 declares -SanNames as a string array, not a single string' {
        $ast = Get-ScriptAst $CertsPs1
        $p = Get-ParamAst $ast 'SanNames'
        $p.StaticType.IsArray | Should -BeTrue -Because 'a single string would silently generate a one-name certificate'
    }

    It 'llama-swap-service.ps1 validates its -LogRotateBytes' {
        $ast = Get-ScriptAst $ServicePs1
        Get-ParamAst $ast 'LogRotateBytes' | Should -Not -BeNullOrEmpty
        Test-ParamIsValidated $ast 'LogRotateBytes' | Should -BeTrue -Because 'the entry point must reject 0 before the builder is ever called'
    }

    It 'the validation helper can return false (classifier guard)' {
        # Without this, a helper that answered $true unconditionally would make
        # every case in this Describe pass while checking nothing.
        $ast = Get-ScriptAst $CertsPs1
        Test-ParamIsValidated $ast 'ThisParameterDoesNotExist' | Should -BeFalse
    }
}
