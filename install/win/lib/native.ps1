# native.ps1 - the one place a native (non-PowerShell) command is allowed to run.
#
# $ErrorActionPreference = 'Stop' does not catch a native command's non-zero exit, so every
# native call in this installer goes through Invoke-Native, which closes that gap once for the
# class (CPR-E2C) instead of once per call site. Exit-code policy, the Win32-vs-bash truncation
# caution, and why this file holds only function definitions: docs/ops.md "Server (Windows)" ->
# Native command exit-code policy.

function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FilePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Arguments,
        [int[]]$AllowExitCodes = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Context,
        [switch]$PassThru
    )

    $commandLine = "$FilePath $($Arguments -join ' ')"

    # 2>&1 folds the tool's stderr into the captured stream so it can be reported with
    # the failure. 'Continue' is required for that: under 'Stop' a single stderr line
    # would be re-raised as a terminating error before the exit code is ever examined,
    # turning a successful-but-chatty command into a failure.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    $allowed = @(0) + @($AllowExitCodes)
    if ($allowed -notcontains $exitCode) {
        $captured = (@($output) | ForEach-Object { "$_" }) -join [Environment]::NewLine
        $message = "$Context failed: '$commandLine' exited with $exitCode (accepted: $($allowed -join ', '))."
        if ($captured) { $message = $message + [Environment]::NewLine + $captured }
        throw $message
    }

    if ($PassThru) { return $output }
}

function Invoke-Nssm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Arguments,
        [int[]]$AllowExitCodes = @(),
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Context,
        [switch]$PassThru
    )

    # nssm's non-zero codes differ between builds, so no caller should be blessing them.
    # The service scripts avoid needing to: they ask Get-Service (a cmdlet, hence no exit
    # code at all) whether the service exists, and only then call nssm.
    return Invoke-Native -FilePath 'nssm' -Arguments $Arguments -AllowExitCodes $AllowExitCodes -Context $Context -PassThru:$PassThru
}
