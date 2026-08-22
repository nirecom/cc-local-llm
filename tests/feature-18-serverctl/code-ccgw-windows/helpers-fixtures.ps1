#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite. Dot-sourced from the
# suite's top-level BeforeAll: fixture trees and the `code` / `mkcert`
# stubs. Definitions only -- setup.ps1 builds anything. Both dumping stubs
# write the SAME two files, so assertion helpers are blind to which ran:
# argv dump -- `CWD=<dir>` then `ARG="<value>"` per argument in order; env
# dump -- `NAME=value` per variable (the `set` shape, no formatting needed).

# --- code.cmd stub (Windows) ------------------------------------------------
# Windows uses code.cmd since that's what a real VS Code install puts on
# PATH, and Process can't start a .ps1 at all -- a .ps1 stub would exempt
# the launcher from the cmd.exe re-parse Context 9 polices. `ARG="%~1"`
# quoting is load-bearing: cmd expands %~1 as text into the line it's
# scanning, so unquoted `echo ARG=%~1` would let `&`/`|` in the VALUE split
# the stub's own echo, misreporting argv or running what followed the
# operator. chcp 65001 first, by absolute path (PATH is the stub dir alone):
# `echo`/`set` render via the CONSOLE code page, so without this a non-ASCII
# round-trip only holds where the code page happens to match; pinning UTF-8 makes it the same bytes everywhere (CPR-UNV).
$script:CodeStubCmdBody = @'
@echo off
%SystemRoot%\System32\chcp.com 65001 > nul
> "%CCGW_TEST_ARGV%" echo CWD=%CD%
:ccgwloop
if "%~1"=="" goto ccgwdone
>>"%CCGW_TEST_ARGV%" echo ARG="%~1"
shift
goto ccgwloop
:ccgwdone
set > "%CCGW_TEST_DUMP%"
'@

# Positional variant of the same stub. The loop above cannot report an EMPTY
# argument at all: `if "%~1"==""` is equally true for "this argument is the empty
# string" and for "there are no more arguments", so an empty argument reads as
# end-of-argv and everything after it disappears. Unrolling the loop removes the
# ambiguity for a known argument count -- position N is dumped whether or not it
# is empty -- which is what Context 12's empty-argument case needs. Eight slots
# is well past any argv this suite passes; trailing unused slots dump as empty.
$script:CodeStubCmdPositionalBody = @'
@echo off
%SystemRoot%\System32\chcp.com 65001 > nul
> "%CCGW_TEST_ARGV%" echo CWD=%CD%
>>"%CCGW_TEST_ARGV%" echo ARG="%~1"
>>"%CCGW_TEST_ARGV%" echo ARG="%~2"
>>"%CCGW_TEST_ARGV%" echo ARG="%~3"
>>"%CCGW_TEST_ARGV%" echo ARG="%~4"
>>"%CCGW_TEST_ARGV%" echo ARG="%~5"
>>"%CCGW_TEST_ARGV%" echo ARG="%~6"
>>"%CCGW_TEST_ARGV%" echo ARG="%~7"
>>"%CCGW_TEST_ARGV%" echo ARG="%~8"
set > "%CCGW_TEST_DUMP%"
'@

# Long-lived variant: dumps argv/environment as above, announces itself via
# %CCGW_TEST_STARTED%, then stays alive until released via %CCGW_TEST_STOP%.
# Needed because every other stub exits in milliseconds, so a launcher that
# WAITS (`Start-Process -Wait`, or .WaitForExit() with no timeout) passes
# them all while blocking the developer's terminal -- only an outliving
# child can tell. ping.exe not timeout.exe: timeout.exe refuses stdin
# redirection, which is how the child starts here (`ping -n 2` = 1s). The
# iteration cap is a safety net, not the mechanism: the test releases the
# stub once measured; the cap only stops a dying test leaking a process.
$script:CodeStubCmdLongLivedBody = @'
@echo off
%SystemRoot%\System32\chcp.com 65001 > nul
> "%CCGW_TEST_ARGV%" echo CWD=%CD%
:ccgwloop
if "%~1"=="" goto ccgwdone
>>"%CCGW_TEST_ARGV%" echo ARG="%~1"
shift
goto ccgwloop
:ccgwdone
set > "%CCGW_TEST_DUMP%"
> "%CCGW_TEST_STARTED%" echo started
set CCGWWAIT=0
:ccgwwait
if exist "%CCGW_TEST_STOP%" goto ccgwend
set /a CCGWWAIT=%CCGWWAIT%+1
if %CCGWWAIT% GTR 60 goto ccgwend
%SystemRoot%\System32\ping.exe -n 2 127.0.0.1 > nul
goto ccgwwait
:ccgwend
'@

# A .cmd that forwards its whole argument tail to a real executable, which is the
# shape of a genuine VS Code install (code.cmd hands %* to Code.exe). It is the
# only observer in this suite that can report an embedded quote or a trailing
# backslash faithfully: the `%~1` loop above recovers each argument through cmd's
# own de-quoting, which neither collapses a doubled "" nor halves a doubled
# trailing backslash, whereas %* passes the tail on untouched for
# CommandLineToArgvW in the target .exe to parse by the documented rules.
# {0} is the absolute path of that executable.
$script:CodeStubCmdForwardBodyFormat = @'
@echo off
"{0}" %*
'@

# A shebang script on PATH, found via `Get-Command code -CommandType
# Application`, like a real VS Code CLI shim on macOS/Linux: an
# extensionless file with the execute bit set, first line handing it to
# pwsh. Used only off Windows, where cmd.exe (and the .cmd stub) don't
# exist. A bare `code.ps1` does NOT satisfy this: PowerShell resolves a
# .ps1 as ExternalScript, which the launcher's `-CommandType Application`
# filter excludes, so a .ps1 stub would make the launcher report "code not
# found" on every non-Windows host, silently exempting these contexts.
$script:CodeStubPs1Body = @'
#!/usr/bin/env pwsh
$argvOut = New-Object System.Collections.Generic.List[string]
$argvOut.Add('CWD=' + (Get-Location).ProviderPath)
foreach ($a in $args) { $argvOut.Add('ARG="' + [string]$a + '"') }
[System.IO.File]::WriteAllLines($env:CCGW_TEST_ARGV, $argvOut)
$envOut = New-Object System.Collections.Generic.List[string]
foreach ($e in Get-ChildItem env:) { $envOut.Add($e.Name + '=' + $e.Value) }
[System.IO.File]::WriteAllLines($env:CCGW_TEST_DUMP, $envOut)
'@

# The .exe stub, compiled at fixture time. It exists because "the .exe branch was
# taken" cannot be shown by absence of an error message: a launcher that launches
# NOTHING produces no error either. This one reports what it actually received --
# argv, its inherited environment, and a marker file whose existence is the
# unambiguous "a process really started" evidence -- in the same dump format as
# the .cmd stub, and through File.WriteAllLines, which is code-page-independent
# and therefore also the honest way to assert a non-ASCII argument.
$script:CodeStubCsSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
class CcgwCodeStub {
  static int Main(string[] argv) {
    UTF8Encoding enc = new UTF8Encoding(false);
    List<string> args = new List<string>();
    args.Add("CWD=" + Directory.GetCurrentDirectory());
    foreach (string a in argv) args.Add("ARG=\"" + a + "\"");
    File.WriteAllLines(Environment.GetEnvironmentVariable("CCGW_TEST_ARGV"), args.ToArray(), enc);
    List<string> env = new List<string>();
    foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
      env.Add(e.Key + "=" + e.Value);
    File.WriteAllLines(Environment.GetEnvironmentVariable("CCGW_TEST_DUMP"), env.ToArray(), enc);
    string marker = Environment.GetEnvironmentVariable("CCGW_TEST_EXE_MARKER");
    if (!string.IsNullOrEmpty(marker)) File.WriteAllText(marker, "launched", enc);
    return 0;
  }
}
'@

# The launcher reads <script>/../.env. Copying it into a fixture tree pins that
# file to an empty one, so precedence is asserted from the child's environment
# block alone.
function New-FixtureTree {
    param([string]$Name, [string[]]$DotEnvLines = @('# intentionally empty: precedence is asserted from the env alone'))
    $root = Join-Path $script:Work $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $root 'scripts' 'code-ccgw.ps1') -Force
    Set-Content -LiteralPath (Join-Path $root '.env') -Value $DotEnvLines -Encoding utf8
    return (Join-Path $root 'scripts' 'code-ccgw.ps1')
}

# Compiles $script:CodeStubCsSource into <Dir>\code.exe. csc.exe from the .NET
# Framework is used rather than Add-Type -OutputAssembly, which PowerShell 7 does
# not support; it ships with every Windows install that has .NET Framework 4.
# Returns $true only when the executable really exists afterwards -- a host
# without a compiler must produce a SKIP, never a stub that silently proves
# nothing.
function New-DumpingCodeExe {
    param([string]$Dir)
    if (-not $IsWindows) { return $false }
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if (-not $csc) {
        $cmd = @(Get-Command 'csc.exe' -CommandType Application -ErrorAction SilentlyContinue)
        if ($cmd) { $csc = @($cmd[0].Source) }
    }
    if (-not $csc) { return $false }
    $src = Join-Path $script:Work 'ccgw-code-stub.cs'
    [System.IO.File]::WriteAllText($src, $script:CodeStubCsSource, (New-Object System.Text.UTF8Encoding($false)))
    $exe = Join-Path $Dir 'code.exe'
    & $csc[0] '/nologo' '/target:exe' "/out:$exe" $src 2>&1 | Out-Null
    return (Test-Path -LiteralPath $exe)
}

function New-StubDir {
    param(
        [string]$Name,
        [string]$MkcertCaroot,
        [int]$MkcertExitCode = 0,
        [switch]$NoCode,
        [switch]$NoMkcert,
        [switch]$ExeStub,
        [switch]$BrokenExeStub,
        [switch]$PositionalCmdStub,
        [switch]$LongLivedCmdStub,
        [string]$ForwardCmdStubTo
    )
    $dir = Join-Path $script:Work $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if ($ForwardCmdStubTo) {
        Set-Content -LiteralPath (Join-Path $dir 'code.cmd') -Encoding ascii `
            -Value ([string]::Format($script:CodeStubCmdForwardBodyFormat, $ForwardCmdStubTo))
    } elseif ($ExeStub) {
        New-DumpingCodeExe -Dir $dir | Out-Null
    } elseif ($BrokenExeStub) {
        # Resolvable as `code` (PATHEXT lists .EXE) but not a startable image, so
        # CreateProcess fails AFTER every value has been resolved -- the last
        # place a launcher could still leave the invoking shell dirty.
        Set-Content -LiteralPath (Join-Path $dir 'code.exe') -Value 'not a portable executable' -Encoding ascii
    } elseif (-not $NoCode) {
        if ($IsWindows) {
            # -Encoding ascii: a UTF-8 BOM ahead of `@echo off` is echoed by cmd
            # as garbage before the stub ever runs.
            $body =
                if ($PositionalCmdStub) { $script:CodeStubCmdPositionalBody }
                elseif ($LongLivedCmdStub) { $script:CodeStubCmdLongLivedBody }
                else { $script:CodeStubCmdBody }
            Set-Content -LiteralPath (Join-Path $dir 'code.cmd') -Value $body -Encoding ascii
        } else {
            # Extensionless, matching a real `code` shim's name on PATH: an
            # extension would let PowerShell's own script discovery resolve it
            # as ExternalScript, which `Get-Command code -CommandType
            # Application` does not match (see the shebang-body comment above).
            $codePath = Join-Path $dir 'code'
            Set-Content -LiteralPath $codePath -Value $script:CodeStubPs1Body -Encoding utf8
            & chmod +x $codePath
        }
    }
    if (-not $NoMkcert) {
        # Prints the CAROOT it was created with; the launcher pipes it through
        # Select-Object -First 1. A failing stub prints nothing and exits non-zero
        # -- it deliberately writes no stderr, which would otherwise contaminate
        # the launcher's own stderr that the warning assertions read.
        $body = if ($MkcertExitCode -ne 0) {
            "exit $MkcertExitCode"
        } else {
            "Write-Output '" + ($MkcertCaroot -replace "'", "''") + "'"
        }
        Set-Content -LiteralPath (Join-Path $dir 'mkcert.ps1') -Value $body -Encoding utf8
    }
    return $dir
}

# The minimum configuration every non-configuration case needs, so that a case
# about (say) argv is never accidentally satisfied by the base-URL guard refusing
# to run at all.
function New-Env {
    param([hashtable]$Extra = @{})
    $h = @{}
    foreach ($k in $script:Configured.Keys) { $h[$k] = $script:Configured[$k] }
    foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    return $h
}
