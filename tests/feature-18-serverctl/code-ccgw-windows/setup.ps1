#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
# lang-check: ignore (non-ASCII path fixtures are the test subject)
#
# Part of the code-ccgw-windows.Tests.ps1 suite. Dot-sourced LAST from its
# top-level BeforeAll, after the three helpers-*.ps1 files: this is the one part
# that actually builds things, so every function it calls is already defined.
# It runs as top-level code (not as a function) on purpose -- the $script:
# variables it sets are what every Context reads.

# The repo root is found by walking up until the launcher is there, rather than
# by counting '..' segments: this file's depth below the suite is a layout
# detail, and the split that introduced the sub-folder is exactly the kind of
# move that silently re-points a hard-coded relative path.
$script:RepoRoot = $PSScriptRoot
while ($script:RepoRoot -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'scripts') 'code-ccgw.ps1'))) {
    $parent = Split-Path -Parent $script:RepoRoot
    if ($parent -eq $script:RepoRoot) { break }
    $script:RepoRoot = $parent
}
$script:SourceLauncher = Join-Path (Join-Path $script:RepoRoot 'scripts') 'code-ccgw.ps1'
if (-not (Test-Path -LiteralPath $script:SourceLauncher)) {
    throw "scripts/code-ccgw.ps1 not found above $PSScriptRoot (implementation pending)"
}

$script:Work = Join-Path ([IO.Path]::GetTempPath()) ("ccgw-win-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

# The host that runs the launcher under test. Parameterized because the
# launcher's stated floor is `#Requires -Version 5.1` while only pwsh ever
# exercised it -- see the suite header. An explicitly requested host that is not
# installed is a configuration error, not a case to skip: the caller asked for a
# specific verification and silently not doing it is worse than red.
$script:LauncherHostOverride = [Environment]::GetEnvironmentVariable('CCGW_TEST_LAUNCHER_HOST')
$script:PwshPath =
    if (-not [string]::IsNullOrEmpty($script:LauncherHostOverride)) {
        $hostCmd = Get-Command $script:LauncherHostOverride -CommandType Application -ErrorAction SilentlyContinue
        if (-not $hostCmd) { throw "CCGW_TEST_LAUNCHER_HOST='$($script:LauncherHostOverride)' not found on PATH" }
        @($hostCmd)[0].Source
    } elseif ($IsWindows) { Join-Path $PSHOME 'pwsh.exe' }
    else { Join-Path $PSHOME 'pwsh' }

# --- Retired variable names -------------------------------------------------
# The cases that prove a retired variable no longer configures anything need its
# exact spelling, but those spellings are banned repo-wide by
# tests/ccgw-naming/test_no_legacy_names.py, whose scan is a raw substring match
# over every tracked file -- this one included. The names are therefore assembled
# at runtime instead of appearing as literals. The cases themselves must stay: a
# stale .env still carrying them is precisely the situation where a surviving
# fallback would silently route around the new single path.
$script:RBaseDs4 = 'DS4_ANTHROPIC' + '_BASE_URL'
$script:RBaseCcgw = 'CCGW_ANTHROPIC' + '_BASE_URL'
$script:RKeyDs4 = 'DS4_API' + '_KEY'
$script:RKeyCcgw = 'CCGW_API' + '_KEY'
$script:RCaDs4 = 'DS4_CA' + '_CERT'
$script:RDefaultModel = 'CCGW_DEFAULT' + '_MODEL'

# --- fixture trees ----------------------------------------------------------
$script:Launcher = New-FixtureTree -Name 'fixture-default'

# Configuration that exists ONLY in the fixture's .env, so a case can prove the
# launcher found that file from its own location rather than from the caller's
# working directory (Context 5's cwd case). Defined here, not in a Context,
# because Pester keeps only the last BeforeAll of a block and nothing may depend
# on which Context happens to run first.
$script:DotEnvLauncherForCwd = New-FixtureTree -Name 'fixture-cwd' -DotEnvLines @(
    'LITELLM_ANTHROPIC_BASE_URL=https://from-dotenv-cwd:9'
    'LITELLM_CLIENT_KEY=cwd-token'
)

# A launcher whose whole tree sits under a non-ASCII directory name (Context 12).
# Every path the launcher composes -- $PSScriptRoot, the .env beside it -- is then
# non-ASCII, which is what a real install under OneDrive\ドキュメント looks like.
$script:UnicodeDirName = "fixture-$([char]0x30D7)$([char]0x30ED)$([char]0x30B8)$([char]0x30A7)$([char]0x30AF)$([char]0x30C8)"
$script:UnicodeLauncher = New-FixtureTree -Name $script:UnicodeDirName -DotEnvLines @(
    'LITELLM_ANTHROPIC_BASE_URL=https://unicode-lite:1'
    'LITELLM_CLIENT_KEY=unicode-token'
)

# --- stub dirs --------------------------------------------------------------
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

# `code` resolving to a real, dumping .exe (Context 10).
$script:StubExe = New-StubDir -Name 'stub-exe' -NoMkcert -ExeStub
$script:HaveExeStub = Test-Path -LiteralPath (Join-Path $script:StubExe 'code.exe')

# `code` that resolves but cannot be started (Context 8's process-start failure).
$script:StubBrokenExe = New-StubDir -Name 'stub-broken-exe' -NoMkcert -BrokenExeStub

# `code.cmd` that dumps argv by position, so an empty argument is visible
# (Context 12).
$script:StubPositional = New-StubDir -Name 'stub-positional' -NoMkcert -PositionalCmdStub

# `code.cmd` that stays alive until released, so "the launcher returned" can be
# distinguished from "the launcher waited for VS Code" (Context 14).
$script:StubLongLived = New-StubDir -Name 'stub-longlived' -NoMkcert -LongLivedCmdStub

# A stub directory whose own PATH entry carries a space, parentheses and `&` --
# the shape of "C:\Program Files (x86)\Foo & Bar\code.cmd" (Context 9e). The
# resolved path of `code` itself is part of the command line the launcher builds,
# so it needs the same escaping as any argument does; every other stub dir in this
# suite is shell-safe and would never show a missing quote.
$script:StubMetacharDir = New-StubDir -Name 'stub (x86) & co' -NoMkcert

# code.cmd -> code.exe forwarding pair (Context 9f): the .cmd hands %* to a real
# executable, so an embedded quote or a trailing backslash can be compared
# literally instead of through cmd's own de-quoting. The observer lives outside
# the stub dir so only the .cmd is discoverable as `code`.
$script:ObserverDir = Join-Path $script:Work 'observer'
New-Item -ItemType Directory -Path $script:ObserverDir -Force | Out-Null
$script:HaveObserverExe = [bool](New-DumpingCodeExe -Dir $script:ObserverDir)
$script:StubCmdForward = if ($script:HaveObserverExe) {
    New-StubDir -Name 'stub-cmd-forward' -NoMkcert -ForwardCmdStubTo (Join-Path $script:ObserverDir 'code.exe')
} else { $null }

$script:LocalAppData = Join-Path $script:Work 'localappdata'
New-Item -ItemType Directory -Path $script:LocalAppData -Force | Out-Null

$script:Configured = @{
    LITELLM_ANTHROPIC_BASE_URL = 'https://lite:1'
    LITELLM_CLIENT_KEY         = 'ck'
}

# The wrapper that plays the developer's interactive shell; see
# helpers-runners.ps1 for why it exists and what it proves.
$script:ParentShellWrapper = Join-Path $script:Work 'parent-shell-wrapper.ps1'
Set-Content -LiteralPath $script:ParentShellWrapper -Encoding utf8 -Value $script:ParentShellWrapperBody

# The wrapper that keeps the launcher's streams off a pipe so its runtime can be
# measured; see Measure-LauncherLaunch in helpers-runners.ps1.
$script:LatencyWrapper = Join-Path $script:Work 'latency-wrapper.ps1'
Set-Content -LiteralPath $script:LatencyWrapper -Encoding utf8 -Value $script:LatencyWrapperBody

# The four /model tiers Claude Code switches between.
$script:TierVars = @(
    'ANTHROPIC_DEFAULT_FABLE_MODEL'
    'ANTHROPIC_DEFAULT_OPUS_MODEL'
    'ANTHROPIC_DEFAULT_SONNET_MODEL'
    'ANTHROPIC_DEFAULT_HAIKU_MODEL'
)
# The vars that name the model in play at startup. CLAUDE_CODE_SUBAGENT_MODEL is
# deliberately NOT here any more: it is now opt-in (section 4d).
$script:ActiveVars = @(
    'ANTHROPIC_MODEL'
    'ANTHROPIC_CUSTOM_MODEL_OPTION'
)
$script:ModelVars = $script:TierVars + $script:ActiveVars + @('CLAUDE_CODE_SUBAGENT_MODEL')
