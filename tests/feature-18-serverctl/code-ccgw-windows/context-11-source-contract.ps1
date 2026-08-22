#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe.

Context '11. The zero-pollution contract, asserted against the source itself' {
    # Context 8 observes the parent environment before/after a launch, which
    # catches pollution only on paths the tests walk. This closes the gap the
    # other way: it reads scripts/code-ccgw.ps1 and requires NO statement
    # anywhere write to the process environment, reachable or not (CPR-UNV --
    # whole input domain, not the sampled one). Load-bearing for #66: no
    # exec() in PowerShell means every `$env:X = ...` lands in the developer's
    # own shell and outlives the launch, so the fix is "never write to this
    # process" (values go to the child via ProcessStartInfo.Environment
    # instead) -- structural, tested via AST (a regex can't tell a write from
    # a read inside a string). Reads (LOCALAPPDATA etc.) stay legal.

    BeforeAll {
        $script:EnvWriteScan = {
            param([string]$Path)

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
            $offenders = New-Object System.Collections.Generic.List[string]
            $add = {
                param($Node, $Why)
                $text = $Node.Extent.Text
                if ($text.Length -gt 90) { $text = $text.Substring(0, 90) + '...' }
                $text = $text -replace '\r?\n', ' '
                $offenders.Add("line $($Node.Extent.StartLineNumber): $Why -- $text")
            }

            # 1. `$env:X = ...`, `${env:X} = ...`, `$env:X += ...`
            foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                $target = $node.Left
                while ($target -is [System.Management.Automation.Language.AttributedExpressionAst]) { $target = $target.Child }
                if ($target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $target.VariablePath.IsDriveQualified -and
                    $target.VariablePath.DriveName -eq 'env') {
                    & $add $node 'assigns to the parent process environment'
                }
            }

            # 2. The provider cmdlets and their aliases, aimed at the env: drive.
            $itemCmdlets = @('set-item', 'new-item', 'remove-item', 'clear-item', 'rename-item', 'copy-item',
                'set-content', 'add-content', 'clear-content', 'si', 'ni', 'ri', 'rni', 'cpi', 'sc', 'ac', 'rd', 'del', 'erase')
            foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $node.GetCommandName()
                if ($null -eq $name -or $itemCmdlets -notcontains $name.ToLowerInvariant()) { continue }
                $touchesEnv = $false
                foreach ($el in $node.CommandElements) {
                    if ($el.Extent.Text -match '(?i)(^|[^a-z0-9_])env:') { $touchesEnv = $true }
                }
                if ($touchesEnv) { & $add $node "calls $name against the env: drive" }
            }

            # 3. [Environment]::SetEnvironmentVariable(...) -- with no scope argument
            #    this writes the current process too, so it is the same defect.
            foreach ($node in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
                if ("$($node.Member)" -match '(?i)^SetEnvironmentVariable$') {
                    & $add $node 'writes the environment through the .NET API'
                }
            }

            return $offenders
        }
    }

    It '11a. no statement in the launcher writes to the environment of the shell that invoked it' {
        $offenders = & $script:EnvWriteScan $script:SourceLauncher
        $offenders.Count | Should -Be 0 -Because @"
scripts/code-ccgw.ps1 must hand its configuration to the child process (ProcessStartInfo.Environment),
never to its own -- PowerShell has no exec(), so every write below survives in the caller's shell after
the launcher exits (issue #66). Offending statements:
  $($offenders -join "`n  ")
"@
    }

    It '11b. the scan itself detects each shape of environment write' {
        # A static assertion that cannot fail is worse than no assertion: it reads
        # as green forever. This pins the detector against one sample per shape,
        # plus a read that must NOT be flagged.
        $probe = Join-Path $script:Work 'env-write-probe.ps1'
        $lines = @(
            '$env:A = ''1'''
            '${env:B} = ''2'''
            '$env:C += ''3'''
            'Set-Item -Path "env:D" -Value ''4'''
            'Remove-Item -Path env:E'
            '[Environment]::SetEnvironmentVariable(''F'', ''6'')'
        )
        Set-Content -LiteralPath $probe -Value $lines -Encoding utf8
        $found = & $script:EnvWriteScan $probe
        $found.Count | Should -Be $lines.Count -Because "the scan missed a write shape; it found: $($found -join ' // ')"

        $clean = Join-Path $script:Work 'env-read-probe.ps1'
        Set-Content -LiteralPath $clean -Encoding utf8 -Value @(
            '$local = $env:LOCALAPPDATA'
            '$p = Join-Path $env:USERPROFILE ''x'''
            'if ($env:PATH -match ''x'') { Write-Host "env:PATH mentioned in a string" }'
            '$copy = Get-Item -Path env:PATH'
        )
        $readOnly = & $script:EnvWriteScan $clean
        $readOnly.Count | Should -Be 0 -Because "reading the environment is legal and must not be flagged; got: $($readOnly -join ' // ')"
    }
}
