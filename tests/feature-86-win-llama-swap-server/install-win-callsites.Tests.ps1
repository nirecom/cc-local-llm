#!/usr/bin/env pwsh
# Tests: install/win/lib/native.ps1, install/win/llama-swap-service.ps1, install/win/certs.ps1, install/win/nssm.ps1, install/win/caddy.ps1, install/win/mkcert.ps1
# Tags: installer, windows, pwsh-required, ast, exit-codes, native, pester, layer:TL2, scope:common
# scope:common despite the feature-86- dir: the per-call-site exit-code table is a permanent operational contract, not #86 arithmetic.
# Sibling install-win-server.Tests.ps1 proves the WRAPPER honours -AllowExitCodes; this file proves each CALL SITE passes the set the plan's 4-2 table assigns it. Neither question implies the other: a correct wrapper handed 1072 still reports a pending delete as success.
# AST only. Nothing here is dot-sourced or executed, so no service, NSSM, winget or certificate is touched -- the whole file reads text through Parser::ParseFile (detail plan 4-1 boundary).
# Driver (skip gating, exit 77 off-Windows): test-install-win-server.sh in this directory.
# TL3 gap (what this suite does NOT catch):
# - whether sc.exe/taskkill/winget really return 1060/128/-1978335189 on the operator's host (measured once, recorded in the plan; a Windows build change would not fail this suite)
# - whether Get-NetTCPConnection actually finds the zombie the replaced netstat pipeline used to find
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh categories: installer, pwsh-required

$RepoRoot   = if ($env:CCLL_REPO) { $env:CCLL_REPO } else { (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path }
$WinDir     = Join-Path $RepoRoot 'install\win'
$NativePs1  = Join-Path $WinDir 'lib\native.ps1'
$WinPresent = (Test-Path $WinDir) -and (Test-Path $NativePs1)

# Pester 5 keeps discovery and run in separate scopes: the assignments above are
# what the -Skip: conditions read, and this BeforeAll is what the It bodies read.
BeforeAll {
    $RepoRoot  = if ($env:CCLL_REPO) { $env:CCLL_REPO } else { (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path }
    $WinDir    = Join-Path $RepoRoot 'install\win'
    $NativePs1 = Join-Path $WinDir 'lib\native.ps1'

    function Get-ScriptAst([string]$Path) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "parse errors in ${Path}: $($errors[0].Message)" }
        return $ast
    }

    # One integer out of an argument expression. Written to survive every spelling
    # the implementation may legitimately choose: 1060, @(0, 1060), 0,1060 and the
    # negative winget code, which PowerShell may hand back either as a literal or
    # as a UnaryExpressionAst around a positive one.
    function Get-IntFromAst($Node) {
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
            $inner = Get-IntFromAst $Node.Child
            if ($null -eq $inner) { return $null }
            if ($Node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus) { return - $inner }
            return $inner
        }
        if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            $v = $Node.Value
            if ($v -is [int] -or $v -is [long]) { return [int]$v }
        }
        return $null
    }

    function Get-IntSetFromAst($Node) {
        $out = @()
        if ($null -eq $Node) { return $out }
        if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
            foreach ($e in $Node.Elements) { $out += (Get-IntSetFromAst $e) }
            return $out
        }
        if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst] -or
            $Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
            foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpressionAst] }, $true)) {
                $i = Get-IntFromAst $c
                if ($null -ne $i) { $out += $i }
            }
            return ($out | Select-Object -Unique)
        }
        $i = Get-IntFromAst $Node
        if ($null -ne $i) { $out += $i }
        return $out
    }

    # The value handed to a named parameter, whichever of the two forms the source
    # uses: `-X value` (argument is the next element) or `-X:value` (attached).
    function Get-NamedArgumentAst($Command, [string]$Name) {
        $els = @($Command.CommandElements)
        for ($i = 1; $i -lt $els.Count; $i++) {
            $e = $els[$i]
            if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($e.ParameterName -ne $Name) { continue }
            if ($null -ne $e.Argument) { return @{ Ast = $e.Argument; Raw = $e.Argument.Extent.Text } }
            if ($i + 1 -lt $els.Count) { return @{ Ast = $els[$i + 1]; Raw = $els[$i + 1].Extent.Text } }
            return @{ Ast = $null; Raw = '' }
        }
        return $null
    }

    # `-AllowExitCodes -1978335189` is tokenised as a PARAMETER named 1978335189,
    # not as a negative literal. Reading only the AST node would silently see an
    # empty allow set and pass -- the exact false green this file exists to stop.
    function Get-AllowedCodes($Command) {
        $found = Get-NamedArgumentAst $Command 'AllowExitCodes'
        if ($null -eq $found) { return @() }
        if ($found.Ast -is [System.Management.Automation.Language.CommandParameterAst]) {
            $n = $found.Ast.ParameterName
            if ($n -match '^\d+$') { return @([int]"-$n") }
            throw "unreadable -AllowExitCodes argument: $($found.Raw)"
        }
        $codes = @(Get-IntSetFromAst $found.Ast)
        if ($codes.Count -eq 0 -and $found.Raw -ne '') {
            throw "unreadable -AllowExitCodes argument: $($found.Raw)"
        }
        # 0 always succeeds inside the wrapper; spelling it here is redundant, not wrong.
        return @($codes | Where-Object { $_ -ne 0 } | Sort-Object -Unique)
    }

    function Get-ConstStrings($Node) {
        $out = @()
        if ($null -eq $Node) { return $out }
        foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            $out += $c.Value
        }
        return $out
    }

    # Every Invoke-Native / Invoke-Nssm call site under install/win, reduced to
    # (tool, first argument, allowed codes, where).
    function Get-NativeCallSites([string]$Root) {
        $sites = @()
        foreach ($f in Get-ChildItem -Path $Root -Filter '*.ps1' -Recurse -File) {
            $ast = Get-ScriptAst $f.FullName
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $c.GetCommandName()
                if ($name -notin 'Invoke-Native', 'Invoke-Nssm') { continue }
                # Inside native.ps1 the wrapper delegates to itself; that is plumbing.
                if ($f.FullName -eq (Resolve-Path $NativePs1).Path -and $name -eq 'Invoke-Native') { continue }

                $tool = 'nssm'
                if ($name -eq 'Invoke-Native') {
                    $fp = Get-NamedArgumentAst $c 'FilePath'
                    $tool = if ($null -ne $fp) { @(Get-ConstStrings $fp.Ast)[0] } else { $null }
                }
                $argNode = Get-NamedArgumentAst $c 'Arguments'
                $argv = if ($null -ne $argNode) { @(Get-ConstStrings $argNode.Ast) } else { @() }

                $sites += [pscustomobject]@{
                    Tool  = if ($tool) { [System.IO.Path]::GetFileName($tool).ToLowerInvariant() } else { '<dynamic>' }
                    Verb  = if ($argv.Count -gt 0) { $argv[0].ToLowerInvariant() } else { '' }
                    Codes = @(Get-AllowedCodes $c)
                    Where = "$($f.Name):$($c.Extent.StartLineNumber)"
                }
            }
        }
        return $sites
    }

    $script:Sites = @(Get-NativeCallSites $WinDir)
}

Describe 'Native call sites pass exactly their documented allow-code set (detail plan 4-2)' -Skip:(-not $WinPresent) {

    It 'finds call sites at all (a zero-site scan would pass every case below vacuously)' {
        $Sites.Count | Should -BeGreaterThan 0 -Because 'install/win must route native commands through Invoke-Native / Invoke-Nssm'
    }

    # Row-by-row against the plan's table. Each row states the tool, the first
    # argument that identifies the sub-command, and the ONLY non-zero exit code
    # that may be reported as success there.
    It '<tool> <verb> allows exactly <expected> and nothing else' -TestCases @(
        @{ tool = 'sc.exe';   verb = 'query';   expected = @(1060);         why = '1060 = service does not exist, which is what the ghost check wants to find' }
        @{ tool = 'sc.exe';   verb = 'delete';  expected = @(1060);         why = '1060 = already gone. 1072 (MARKED_FOR_DELETE) must NOT be allowed: the handle is still open, so reporting success makes the very next registration fail' }
        @{ tool = 'taskkill'; verb = '/f';      expected = @(128);          why = '128 = no such process; enumeration-to-kill always races a natural exit' }
        @{ tool = 'winget';   verb = 'install'; expected = @(-1978335189);  why = '-1978335189 (0x8A15002B) = already installed, which is the idempotent outcome' }
    ) {
        $matching = @($Sites | Where-Object { $_.Tool -eq $tool -and $_.Verb -eq $verb })
        $matching.Count | Should -BeGreaterThan 0 -Because "the plan documents a '$tool $verb' call site; if it moved, this table moves with it"
        foreach ($s in $matching) {
            (@($s.Codes) -join ',') | Should -Be (@($expected) -join ',') -Because "$($s.Where): $why"
        }
    }

    It 'never allows 1072 anywhere (a pending delete is not a completed one)' {
        # Stated separately from the sc.exe delete row: 1072 must not creep into
        # ANY site, including a future retry helper that never says "delete".
        $bad = @($Sites | Where-Object { $_.Codes -contains 1072 } | ForEach-Object { $_.Where })
        ($bad -join '; ') | Should -BeNullOrEmpty -Because 'ERROR_SERVICE_MARKED_FOR_DELETE means the service is still there'
    }

    It 'nssm itself is allowed nothing but 0' {
        # The design avoids "service missing" by pre-checking with Get-Service,
        # precisely so nssm's build-dependent codes never need an exception.
        foreach ($s in @($Sites | Where-Object { $_.Tool -eq 'nssm' })) {
            (@($s.Codes) -join ',') | Should -Be '' -Because "$($s.Where): nssm exit codes vary by build, so none may be pre-blessed"
        }
    }

    It 'certificate tools are allowed nothing but 0' {
        foreach ($s in @($Sites | Where-Object { $_.Tool -in 'mkcert', 'certutil' })) {
            (@($s.Codes) -join ',') | Should -Be '' -Because "$($s.Where): a failed cert or trust step has no benign non-zero outcome"
        }
    }

    It 'every call site names its tool as a literal (an allow set cannot be checked against a computed one)' {
        $dyn = @($Sites | Where-Object { $_.Tool -eq '<dynamic>' } | ForEach-Object { $_.Where })
        ($dyn -join '; ') | Should -BeNullOrEmpty -Because 'a -FilePath built at runtime would slip past this whole table'
    }

    It 'every call site carries a -Context (the failure text is the operator guidance)' {
        $missing = @()
        foreach ($f in Get-ChildItem -Path $WinDir -Filter '*.ps1' -Recurse -File) {
            $ast = Get-ScriptAst $f.FullName
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ($c.GetCommandName() -notin 'Invoke-Native', 'Invoke-Nssm') { continue }
                if ($f.FullName -eq (Resolve-Path $NativePs1).Path) { continue }
                if ($null -eq (Get-NamedArgumentAst $c 'Context')) { $missing += "$($f.Name):$($c.Extent.StartLineNumber)" }
            }
        }
        ($missing -join '; ') | Should -BeNullOrEmpty
    }
}

Describe 'netstat is gone, not merely wrapped (detail plan 4-2 row 5)' -Skip:(-not $WinPresent) {

    It 'no netstat invocation survives anywhere under install/win' {
        # netstat returns 0 with zero matching lines, so its exit code cannot tell
        # "no zombie" from "did not look". Wrapping it would not fix that; only
        # replacing it does. Checked as text as well as AST because the old form
        # was a pipeline into Select-String, where the AST name is easy to miss.
        $hits = @()
        foreach ($f in Get-ChildItem -Path $WinDir -Filter '*.ps1' -Recurse -File) {
            $ast = Get-ScriptAst $f.FullName
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $n = $c.GetCommandName()
                if (-not $n) { continue }
                if ([System.IO.Path]::GetFileNameWithoutExtension($n).ToLowerInvariant() -eq 'netstat') {
                    $hits += "$($f.Name):$($c.Extent.StartLineNumber) (command)"
                }
            }
            foreach ($s in @(Get-ConstStrings $ast)) {
                if ($s -match '(?i)(^|[\\/\s])netstat(\.exe)?($|[\s])') { $hits += "$($f.Name) (string literal '$s')" }
            }
        }
        ($hits -join '; ') | Should -BeNullOrEmpty
    }

    It 'the zombie hunt uses Get-NetTCPConnection instead' -Skip:(-not (Test-Path (Join-Path $WinDir 'llama-swap-service.ps1'))) {
        # Asserted positively as well: deleting the netstat line and replacing it
        # with nothing would satisfy the case above while losing the cleanup.
        $ast = Get-ScriptAst (Join-Path $WinDir 'llama-swap-service.ps1')
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $names | Should -Contain 'Get-NetTCPConnection'
    }
}
