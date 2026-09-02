#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, auto-pull, git, scope:issue-specific
#
# Dot-sourced from code-ccgw-windows.Tests.ps1's top-level BeforeAll. What the
# two auto-pull context files need to build a repository and inspect it after a
# launch, stated once (CPR-SSOT): the seeded bare remote, the clone that tracks
# it, and the four-way snapshot. POSIX sibling: code-ccgw-auto-pull/fixture.sh.

# Array-wrapped and indexed: a Git for Windows install puts git.exe on PATH
# twice (cmd\ and mingw64\bin\), and `.Source` on the two-element result is a
# single joined string that resolves to nothing.
$script:Ctx17GitCmd = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
$script:Ctx17GitExe = if ($script:Ctx17GitCmd.Count -gt 0) { $script:Ctx17GitCmd[0].Source } else { '' }
$script:Ctx17GitBinDir = if ($script:Ctx17GitExe) { Split-Path -Parent $script:Ctx17GitExe } else { '' }

# PATH for a child that has to run git for real: the stub dir still comes first,
# so `code` and any stubbed command win, and git resolves behind it.
function New-Ctx17Path {
    param([string]$StubDir = $script:StubDir)
    return ($StubDir + ';' + $script:Ctx17GitBinDir + ';' + (Join-Path $env:WINDIR 'System32'))
}

function Invoke-Ctx17Git {
    param([string]$RepoPath, [string[]]$GitArgs)
    $out = & $script:Ctx17GitExe '-C' $RepoPath @GitArgs 2>&1
    return ($out -join "`n")
}

# Fixture isolation: the developer's own hooks and identity must not reach a
# throwaway repository (rules/test/fixture-isolation.md).
function Set-Ctx17RepoConfig {
    param([string]$RepoPath)
    Invoke-Ctx17Git -RepoPath $RepoPath -GitArgs @('config', 'core.hooksPath', '/dev/null') | Out-Null
    Invoke-Ctx17Git -RepoPath $RepoPath -GitArgs @('config', 'user.email', 'ctx17@example.com') | Out-Null
    Invoke-Ctx17Git -RepoPath $RepoPath -GitArgs @('config', 'user.name', 'ctx17') | Out-Null
    Invoke-Ctx17Git -RepoPath $RepoPath -GitArgs @('config', 'commit.gpgsign', 'false') | Out-Null
}

function New-Ctx17ConfigLines {
    param([string]$OpusName)
    return @(
        'model_list:'
        '  - model_name: ctx17-shared'
        '    litellm_params:'
        '      model: openai/Backend-A'
        '      ccgw_tiers: [haiku, sonnet, fable, subagent]'
        ''
        '  - model_name: ' + $OpusName
        '    litellm_params:'
        '      model: openai/Backend-B'
        '      ccgw_tiers: [opus]'
    )
}

# Builds a bare remote seeded with one commit, clones it into a fixture tree, and
# returns the launcher path. scripts/ and .env are gitignored in the seed so the
# clone's worktree is CLEAN once the fixture is dropped in -- otherwise every
# case would take the dirty-worktree branch. NOTES.md is a tracked file the pull
# never rewrites, so a dirty-tree case can dirty something OTHER than the file
# under contention; $DotEnvLines is what lets a case put the switch in the .env
# rather than in the environment block.
function New-Ctx17Clone {
    param(
        [string]$Name,
        [string]$OpusName = 'ctx17-opus-v1',
        [string[]]$DotEnvLines = @('# ctx17: configuration comes from the environment block')
    )
    $seed = Join-Path $script:Work "$Name-seed"
    $bare = Join-Path $script:Work "$Name-remote.git"
    $root = Join-Path $script:Work $Name

    New-Item -ItemType Directory -Path (Join-Path $seed 'litellm-server') -Force | Out-Null
    Invoke-Ctx17Git -RepoPath $seed -GitArgs @('init', '--quiet', '--initial-branch=main') | Out-Null
    Set-Ctx17RepoConfig -RepoPath $seed
    Set-Content -LiteralPath (Join-Path $seed '.gitignore') -Encoding utf8 -Value @('scripts/', '.env')
    Set-Content -LiteralPath (Join-Path $seed 'NOTES.md') -Encoding utf8 -Value @('fixture checkout')
    Set-Content -LiteralPath (Join-Path (Join-Path $seed 'litellm-server') 'config.yaml') `
        -Encoding utf8 -Value (New-Ctx17ConfigLines -OpusName $OpusName)
    Invoke-Ctx17Git -RepoPath $seed -GitArgs @('add', '-A') | Out-Null
    Invoke-Ctx17Git -RepoPath $seed -GitArgs @('commit', '--quiet', '-m', 'seed') | Out-Null

    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    Invoke-Ctx17Git -RepoPath $bare -GitArgs @('init', '--quiet', '--bare', '--initial-branch=main') | Out-Null
    Invoke-Ctx17Git -RepoPath $seed -GitArgs @('remote', 'add', 'origin', $bare) | Out-Null
    Invoke-Ctx17Git -RepoPath $seed -GitArgs @('push', '--quiet', '-u', 'origin', 'main') | Out-Null

    & $script:Ctx17GitExe 'clone' '--quiet' $bare $root 2>&1 | Out-Null
    Set-Ctx17RepoConfig -RepoPath $root

    New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $root 'scripts' 'code-ccgw.ps1') -Force
    Set-Content -LiteralPath (Join-Path $root '.env') -Encoding utf8 -Value $DotEnvLines
    return (Join-Path $root 'scripts' 'code-ccgw.ps1')
}

# A change that exists only on the remote: the launcher has to fetch to see it,
# so a child carrying $OpusName proves the pull ran AND that the config was read
# afterwards rather than before.
function Publish-Ctx17Update {
    param([string]$Name, [string]$OpusName)
    $bare = Join-Path $script:Work "$Name-remote.git"
    $pub = Join-Path $script:Work "$Name-publisher"
    & $script:Ctx17GitExe 'clone' '--quiet' $bare $pub 2>&1 | Out-Null
    Set-Ctx17RepoConfig -RepoPath $pub
    Set-Content -LiteralPath (Join-Path (Join-Path $pub 'litellm-server') 'config.yaml') `
        -Encoding utf8 -Value (New-Ctx17ConfigLines -OpusName $OpusName)
    Invoke-Ctx17Git -RepoPath $pub -GitArgs @('commit', '--quiet', '-am', 'publish') | Out-Null
    Invoke-Ctx17Git -RepoPath $pub -GitArgs @('push', '--quiet', 'origin', 'main') | Out-Null
}

function Get-Ctx17Head {
    param([string]$LauncherPath)
    return (Invoke-Ctx17Git -RepoPath (Get-FixtureRoot $LauncherPath) -GitArgs @('rev-parse', 'HEAD')).Trim()
}

# "Nothing moved" needs all four of the things a fetch/merge can move, named
# separately: HEAD alone stays put while `git merge --ff-only` still rewrites the
# index, and the index stays put while a checkout rewrites the file.
function Get-Ctx17Snapshot {
    param([string]$LauncherPath)
    $root = Get-FixtureRoot $LauncherPath
    return [pscustomobject]@{
        Head   = (Invoke-Ctx17Git -RepoPath $root -GitArgs @('rev-parse', 'HEAD')).Trim()
        Index  = (Invoke-Ctx17Git -RepoPath $root -GitArgs @('ls-files', '--stage'))
        Status = (Invoke-Ctx17Git -RepoPath $root -GitArgs @('status', '--porcelain'))
        Config = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'litellm-server') 'config.yaml'))
    }
}

function Assert-Ctx17RepoUnchanged {
    param($Before, $After, [string]$Because)
    foreach ($facet in @('Head', 'Index', 'Status', 'Config')) {
        $After.$facet | Should -BeExactly $Before.$facet -Because "${Because} (the repository's $facet moved)"
    }
}
