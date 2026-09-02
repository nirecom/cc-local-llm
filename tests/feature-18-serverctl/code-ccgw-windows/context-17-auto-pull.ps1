#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, auto-pull, git, scope:issue-specific
#
# Part of the code-ccgw-windows.Tests.ps1 suite, dot-sourced into its Describe:
# the launch-time `git pull` that keeps the routing table current. POSIX
# sibling: test-code-ccgw-auto-pull.sh -- the two must stay in step (CPR-ORTH).

Context '17. Auto-pull: the routing table is refreshed before it is read' -Skip:(-not $IsWindows -or -not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    # TL3 gap: a real remote reached over SSH or HTTPS, with a credential helper
    # or an agent that may prompt. These cases stop at a local bare repository,
    # which is the mechanism but not the network; docs/ops.md's cutover smoke run
    # is what exercises the real origin.

    # The fixture builders (New-Ctx17Clone, Publish-Ctx17Update, the snapshot)
    # live in helpers-autopull.ps1, dot-sourced by the suite's top-level
    # BeforeAll, because context-18 needs the same ones (CPR-SSOT).
    # Every case here states CCGW_AUTO_PULL explicitly: Set-ChildEnvBlock turns
    # the pull OFF for the whole suite, so a case about pulling that inherited
    # that default would assert "nothing was pulled" and pass for free.

    It '17a. on by default: the launch pulls, and the tier map comes from what was pulled' {
        # The whole point of the change, in one assertion: a routing decision
        # committed on another machine reaches this one at the next launch,
        # without anyone editing a per-machine file. It also pins the ORDER --
        # a launcher that read config.yaml before pulling would export v1.
        $launcher = New-Ctx17Clone -Name 'ctx17-default'
        Publish-Ctx17Update -Name 'ctx17-default' -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v2' 'auto-pull/default-on: the config must be read AFTER the pull'
    }

    It '17a2. the default is on with the switch set nowhere at all' {
        # 17a hands the child CCGW_AUTO_PULL=on, so it proves the ON branch and
        # says nothing about which branch is taken when nobody chose. That is the
        # branch every host actually runs: a fresh machine has no such line in its
        # .env and no such value in its shell. Off-by-default is silent -- every
        # host quietly keeps whatever routing table it cloned with -- so the
        # default has to be asserted with the switch absent from BOTH sources.
        $launcher = New-Ctx17Clone -Name 'ctx17-bare-default'
        Publish-Ctx17Update -Name 'ctx17-bare-default' -OpusName 'ctx17-opus-v2'
        $before = Get-Ctx17Head -LauncherPath $launcher

        $r = Invoke-Launcher -LauncherPath $launcher -NoAutoPullDefault `
            -Environment (New-Env @{ PATH = (New-Ctx17Path) })
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        (Get-Ctx17Head -LauncherPath $launcher) | Should -Not -BeExactly $before `
            -Because 'auto-pull/bare-default: the checkout never advanced, so the unset default is off'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v2' `
            'auto-pull/bare-default: the config must be read AFTER the default pull'
    }

    It '17b. CCGW_AUTO_PULL=off leaves the working copy exactly where it was' {
        # The opt-out has to be real: on a metered link, or mid-bisect, a launch
        # that silently moves HEAD is worse than a stale routing table.
        $launcher = New-Ctx17Clone -Name 'ctx17-off'
        $before = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name 'ctx17-off' -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'off' })
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before -Because 'auto-pull/off: HEAD moved even though the pull was disabled'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' 'auto-pull/off: the local table is what applies'
    }

    It '17c. a dirty working copy is preserved: warn, do not discard, still launch' {
        # Somebody is mid-edit in the ops repo. Their uncommitted change is worth
        # more than the pull, so the pull is what gives way -- and the launch must
        # not be held hostage to either.
        $launcher = New-Ctx17Clone -Name 'ctx17-dirty'
        $root = Get-FixtureRoot $launcher
        $configPath = Join-Path (Join-Path $root 'litellm-server') 'config.yaml'
        Set-Content -LiteralPath $configPath -Encoding utf8 -Value (New-Ctx17ConfigLines -OpusName 'ctx17-opus-local-edit')
        Publish-Ctx17Update -Name 'ctx17-dirty' -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "a dirty repo must still open the editor; stderr: $($r.StdErr)"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-local-edit' 'auto-pull/dirty: the uncommitted edit must survive'
        Assert-LauncherWarning $r 'pull' 'auto-pull/dirty: skipping the pull silently is how a stale table looks fresh'
        [System.IO.File]::ReadAllText($configPath) | Should -Match 'ctx17-opus-local-edit' `
            -Because 'auto-pull/dirty: the working copy was overwritten -- a launcher may never discard uncommitted work'
    }

    It '17d. no upstream configured: warn and launch, never guess a remote' {
        # A worktree or a locally-created branch has no branch.<name>.remote. The
        # launcher has no basis for choosing one, and picking `origin` anyway is
        # how a pull lands from a branch nobody asked for.
        $launcher = New-Ctx17Clone -Name 'ctx17-no-upstream'
        $root = Get-FixtureRoot $launcher
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('config', '--unset', 'branch.main.remote') | Out-Null
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('config', '--unset', 'branch.main.merge') | Out-Null
        $before = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name 'ctx17-no-upstream' -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "a repo with no upstream must still launch; stderr: $($r.StdErr)"
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before -Because 'auto-pull/no-upstream: something was pulled from a remote nobody configured'
        Assert-LauncherWarning $r 'upstream' 'auto-pull/no-upstream: the operator must be told why the table was not refreshed'
    }

    It '17e. diverged history is reported, never resolved by force (POSIX case 4)' {
        # Reachability alone is too weak a contract: `git reset --hard @{u}` and
        # `git rebase` both leave the old commit reachable through the reflog, and
        # a merge that succeeds leaves it reachable as a parent -- yet all three
        # have rewritten the operator's checkout. So the assertion is that NOTHING
        # moved: not HEAD, not the index, not the working tree, not the file.
        $launcher = New-Ctx17Clone -Name 'ctx17-diverged'
        $root = Get-FixtureRoot $launcher
        Set-Content -LiteralPath (Join-Path (Join-Path $root 'litellm-server') 'config.yaml') `
            -Encoding utf8 -Value (New-Ctx17ConfigLines -OpusName 'ctx17-opus-local')
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('commit', '--quiet', '-am', 'local work not yet pushed') | Out-Null
        $localSha = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name 'ctx17-diverged' -OpusName 'ctx17-opus-v2'
        $before = Get-Ctx17Snapshot -LauncherPath $launcher

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "a diverged repo must still launch; stderr: $($r.StdErr)"
        Assert-Ctx17RepoUnchanged $before (Get-Ctx17Snapshot -LauncherPath $launcher) `
            'auto-pull/diverged: a diverged history must be reported, not resolved'
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('merge-base', '--is-ancestor', $localSha, 'HEAD') | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "auto-pull/diverged: the local commit $localSha is no longer reachable from HEAD -- the pull discarded it"
        # Assert-LauncherWarning escapes its pattern, and the wording is not
        # pinned here -- any of the three words a git-literate message would use.
        ([string]$r.StdErr + [string]$r.StdOut) | Should -Match 'diverg|behind|ahead' `
            -Because 'auto-pull/diverged: the operator must be told the histories parted'
        # The launch still runs on the LOCAL file: refusing to merge must not also
        # mean refusing to read what is already on disk.
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-local' `
            'auto-pull/diverged: the un-merged local config.yaml is still the one in effect'
    }

    It '17e2. ahead of an upstream that never moved: silence, and nothing published (POSIX case 4b)' {
        # The other half of 17e's classifier, and the shape the operator is in
        # after every commit they have not pushed yet. Nothing to fetch and
        # nothing to fast-forward to, so by S5 step 7 -- print only when HEAD
        # actually moved -- the correct behaviour is silence. A classifier that
        # reads "not equal to upstream" as "diverged" warns on every launch
        # until 17e's real warning goes unread; one that reads "ahead" as an
        # invitation to publish ships work the operator had not chosen to share.
        $launcher = New-Ctx17Clone -Name 'ctx17-ahead'
        $root = Get-FixtureRoot $launcher
        $bare = Join-Path $script:Work 'ctx17-ahead-remote.git'
        Set-Content -LiteralPath (Join-Path (Join-Path $root 'litellm-server') 'config.yaml') `
            -Encoding utf8 -Value (New-Ctx17ConfigLines -OpusName 'ctx17-opus-ahead')
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('commit', '--quiet', '-am', 'local commit not yet pushed') | Out-Null
        $localSha = Get-Ctx17Head -LauncherPath $launcher
        $remoteBefore = (Invoke-Ctx17Git -RepoPath $bare -GitArgs @('rev-parse', 'refs/heads/main')).Trim()
        $before = Get-Ctx17Snapshot -LauncherPath $launcher

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/ahead: being ahead is not a failure; stderr: $($r.StdErr)"
        Assert-Ctx17RepoUnchanged $before (Get-Ctx17Snapshot -LauncherPath $launcher) `
            'auto-pull/ahead: upstream moved nowhere, so there was nothing to fast-forward to'
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $localSha `
            -Because 'auto-pull/ahead: HEAD left the operator''s own commit'
        (Invoke-Ctx17Git -RepoPath $bare -GitArgs @('rev-parse', 'refs/heads/main')).Trim() |
            Should -BeExactly $remoteBefore `
            -Because 'auto-pull/ahead: the launcher published the operator''s unpushed commit; auto-PULL may never push'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-ahead' `
            'auto-pull/ahead: the local commit''s tier map is the one in effect'
        ([string]$r.StdErr + [string]$r.StdOut) | Should -Not -Match 'diverg|behind|dirty|uncommitted' `
            -Because "auto-pull/ahead: an unpushed commit was reported as a problem on the launch shape that happens most; 17e's warning becomes noise. Output: $($r.StdErr)"
        ([string]$r.StdErr + [string]$r.StdOut) | Should -Not -Match 'pulled|fast.?forward|updated' `
            -Because "auto-pull/ahead: an update was announced although HEAD never moved. Output: $($r.StdErr)"
    }

    It '17f. a git that never returns is killed with its descendants (C5)' {
        # Bounding the wait is not enough on its own: a deadline that abandons the
        # process leaves a git -- and whatever credential helper or ssh it spawned
        # -- alive after every launch, holding locks in .git and accumulating one
        # process per session. The descendant, not the direct child, is what proves
        # the kill reached the whole tree.
        $stub = New-StubDir -Name 'stub-ctx17-hanging-git' -NoMkcert -LongLivedCmdStub
        $pidFile = Join-Path $script:Work 'ctx17-descendant-pid.txt'
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue

        $helper = Join-Path $script:Work 'ctx17-hanging-git.ps1'
        Set-Content -LiteralPath $helper -Encoding utf8 -Value @(
            'param([string]$PidFile)'
            "`$child = Start-Process -FilePath '$($script:PwshPath)' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -PassThru"
            'Set-Content -LiteralPath $PidFile -Value $child.Id'
            'Start-Sleep -Seconds 300'
        )
        Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            """$($script:PwshPath)"" -NoProfile -File ""$helper"" ""$pidFile"""
        )

        $launcher = New-Ctx17Clone -Name 'ctx17-hanging'
        $r = Measure-LauncherLaunch -LauncherPath $launcher -StubDir $stub -BudgetMs 60000 `
            -Environment (New-Env @{ PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32')); CCGW_AUTO_PULL = 'on' })
        $r.ExitedWithinBudget | Should -BeTrue -Because "auto-pull/deadline: still running after $($r.ElapsedMs)ms; output: $($r.Output)"

        Test-Path -LiteralPath $pidFile | Should -BeTrue -Because 'auto-pull/deadline: the stub git never ran, so nothing about the kill was proven'
        $descendant = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        while ($deadline.ElapsedMilliseconds -lt 15000 -and (Get-Process -Id $descendant -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 250
        }
        (Get-Process -Id $descendant -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty `
            -Because "auto-pull/deadline: pid $descendant outlived the timed-out pull -- the deadline killed the direct child only"
    }

    It '17g. a local-tracking upstream is a distinct warning, never resolved as a remote to fetch (POSIX case 6)' {
        # `branch.<b>.remote = .` is legal git and means "track a local branch".
        # There is nothing to fetch, and a resolver that hands back "." pulls from
        # the repository it is already standing in -- a different failure mode
        # from 17d's "no upstream configured at all", so it needs its own case
        # and its own wording (CPR-SC).
        $launcher = New-Ctx17Clone -Name 'ctx17-local-upstream'
        $root = Get-FixtureRoot $launcher
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('branch', 'other') | Out-Null
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('config', 'branch.main.remote', '.') | Out-Null
        Invoke-Ctx17Git -RepoPath $root -GitArgs @('config', 'branch.main.merge', 'refs/heads/other') | Out-Null
        $before = Get-Ctx17Head -LauncherPath $launcher

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "a local-only upstream must still launch; stderr: $($r.StdErr)"
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before -Because 'auto-pull/local-upstream: HEAD moved although there was nothing to fetch'
        Assert-LauncherWarning $r 'remote' 'auto-pull/local-upstream: the warning must say there is no remote to pull from'
    }

    It '17h. a git that exits at once is not waited on: the pipe it leaves open must not block the launch (POSIX case 9, C5)' {
        # The descendant still holds the inherited pipe open. A launcher that
        # reads to EOF blocks for its full lifetime even though the command it
        # ran is already finished -- distinct from 17f, where it is git ITSELF
        # that never returns.
        $stub = New-StubDir -Name 'stub-ctx17-exiting-git' -NoMkcert -LongLivedCmdStub
        $pidFile = Join-Path $script:Work 'ctx17-pipe-descendant-pid.txt'
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue

        $helper = Join-Path $script:Work 'ctx17-exiting-git.ps1'
        Set-Content -LiteralPath $helper -Encoding utf8 -Value @(
            'param([string]$PidFile)'
            "`$child = Start-Process -FilePath '$($script:PwshPath)' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -PassThru"
            'Set-Content -LiteralPath $PidFile -Value $child.Id'
            'exit 0'
        )
        Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            """$($script:PwshPath)"" -NoProfile -File ""$helper"" ""$pidFile"""
        )

        $launcher = New-Ctx17Clone -Name 'ctx17-exiting'
        $r = Measure-LauncherLaunch -LauncherPath $launcher -StubDir $stub -BudgetMs 20000 `
            -Environment (New-Env @{ PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32')); CCGW_AUTO_PULL = 'on' })
        $r.ExitedWithinBudget | Should -BeTrue -Because "auto-pull/no-wait: still running after $($r.ElapsedMs)ms although the stub git exited at once -- it waited on the descendant's inherited pipe; output: $($r.Output)"

        Test-Path -LiteralPath $pidFile | Should -BeTrue -Because 'auto-pull/no-wait: the stub git never ran, so nothing about the pipe was proven'
        $descendant = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        while ($deadline.ElapsedMilliseconds -lt 15000 -and (Get-Process -Id $descendant -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 250
        }
        (Get-Process -Id $descendant -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty `
            -Because "auto-pull/no-wait: pid $descendant survived a git that had already exited -- the whole process tree must go with it"
    }

    It '17i. git is not on PATH at all: warn, launch anyway (POSIX case 10)' {
        # The pull is a convenience the launcher grew. A Windows host with VS Code
        # but no Git for Windows -- or a PATH that lost it -- still has a working
        # client, so a missing binary is a warning, never a launch failure. Silence
        # would be the other failure: that host then goes stale forever.
        $stub = New-StubDir -Name 'stub-ctx17-no-git' -NoMkcert
        $launcher = New-Ctx17Clone -Name 'ctx17-no-git'
        $before = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name 'ctx17-no-git' -OpusName 'ctx17-opus-v2'

        # System32 carries no git, and the stub dir has none either, so the child
        # cannot resolve one however it looks.
        $r = Invoke-Launcher -LauncherPath $launcher -StubDir $stub -Environment (New-Env @{
                PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32')); CCGW_AUTO_PULL = 'on'
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/no-git: the client does not need git; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/no-git: a missing git cost the operator their client'
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before `
            -Because 'auto-pull/no-git: HEAD moved although no git was reachable'
        Assert-LauncherWarning $r 'git' 'auto-pull/no-git: the warning must name the binary it could not find'
    }

    It '17j. the first git call fails outright: warn, launch anyway (POSIX case 11)' {
        # An expired credential, a proxy refusing CONNECT, a remote that has gone
        # away: git returns at once with a message. 17f and 17h cover the two hang
        # shapes; nothing there would notice a launcher that treated a plain
        # non-zero exit as fatal.
        $stub = New-StubDir -Name 'stub-ctx17-failing-git' -NoMkcert
        Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            'echo fatal: could not read from remote repository 1>&2'
            'exit /b 128'
        )

        $launcher = New-Ctx17Clone -Name 'ctx17-failing-git'
        $before = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name 'ctx17-failing-git' -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -StubDir $stub -Environment (New-Env @{
                PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32')); CCGW_AUTO_PULL = 'on'
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/failed-fetch: a failed pull must not cost the launch; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/failed-fetch: the client was never started'
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before `
            -Because 'auto-pull/failed-fetch: HEAD moved although every git call failed'
        Assert-LauncherWarning $r 'pull' 'auto-pull/failed-fetch: a failed pull must be reported, not swallowed'
    }

    It '17k. CCGW_AUTO_PULL=<Label> is not "on", so nothing is pulled (POSIX case 12)' -ForEach @(
        @{ Label = 'onn'; Value = 'onn'; Warn = $true }
        @{ Label = 'ON'; Value = 'ON'; Warn = $true }
        @{ Label = 'true'; Value = 'true'; Warn = $true }
        @{ Label = '1'; Value = '1'; Warn = $true }
        @{ Label = 'yes'; Value = 'yes'; Warn = $true }
        @{ Label = 'space'; Value = ' '; Warn = $true }
        @{ Label = 'empty'; Value = ''; Warn = $false }
    ) {
        # `on` is the only value that turns the pull on. Off silently is the trap:
        # whoever wrote CCGW_AUTO_PULL=true believes this host self-updates, and it
        # never will. Per-spelling because one prose case pins one spelling and
        # leaves the rest to chance (CPR-UNV; POSIX sibling: auto-pull case 12).
        $name = "ctx17-badvalue-$($Label -replace '[^A-Za-z0-9]', 'x')"
        $launcher = New-Ctx17Clone -Name $name
        $before = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name $name -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{
                PATH = (New-Ctx17Path); CCGW_AUTO_PULL = $Value
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/bad-value: stderr: $($r.StdErr)"
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before `
            -Because "auto-pull/bad-value: '$Label' pulled; only 'on' turns the pull on"
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' `
            "auto-pull/bad-value: the child got the upstream value, so the pull ran after all"
        if ($Warn) {
            Assert-LauncherWarning $r 'CCGW_AUTO_PULL' `
                "auto-pull/bad-value: a value that is neither on nor off must be named back to the operator"
        }
    }

    It '17l. the opt-out stops the fetch itself, not just the merge, read from <Label> (POSIX case 16)' -ForEach @(
        @{ Label = 'process-env'; FromDotEnv = $false }
        @{ Label = 'dotenv-file'; FromDotEnv = $true }
    ) {
        # 17b asserts HEAD did not move, which a bare `git fetch` satisfies: it
        # writes remote-tracking refs and nothing else. But the delay is what the
        # opt-out exists for -- on a metered or slow link the operator wants the
        # editor back, not a still SHA -- so a launcher that fetches and then
        # declines to merge passes 17b while costing exactly what 17b was meant
        # to prevent. This stub logs every call and blocks on the network verbs,
        # so a still-fetching launcher is caught twice: by the log, and by the
        # runner's own 60s ceiling. Both sources of the switch, because where it
        # is read from is a separate question from whether it is obeyed.
        $stub = New-StubDir -Name "stub-ctx17-logging-git-$Label" -NoMkcert
        $log = Join-Path $script:Work "ctx17-git-calls-$Label.log"
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue

        # Non-network calls are forwarded to the real git so the launcher still
        # takes its ordinary path; only the verbs that reach a remote are trapped.
        Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            ">>""$log"" echo %*"
            'echo %*|findstr /I "fetch pull ls-remote" >nul'
            'if not errorlevel 1 ('
            '    ping -n 300 127.0.0.1 >nul'
            '    exit /b 1'
            ')'
            """$($script:Ctx17GitExe)"" %*"
            'exit /b %ERRORLEVEL%'
        )

        $name = "ctx17-fetchless-off-$Label"
        $launcher = if ($FromDotEnv) {
            New-Ctx17Clone -Name $name -DotEnvLines @('CCGW_AUTO_PULL=off')
        } else {
            New-Ctx17Clone -Name $name
        }
        Publish-Ctx17Update -Name $name -OpusName 'ctx17-opus-v2'

        $envBlock = New-Env @{ PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32')) }
        if (-not $FromDotEnv) { $envBlock['CCGW_AUTO_PULL'] = 'off' }
        $r = Invoke-Launcher -LauncherPath $launcher -StubDir $stub -NoAutoPullDefault -Environment $envBlock

        $r.ExitCode | Should -Be 0 -Because "auto-pull/fetchless-off: stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/fetchless-off: the client was never started'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' `
            'auto-pull/fetchless-off: opting out of the pull must still route from the checkout as it stands'
        $calls = if (Test-Path -LiteralPath $log) { [System.IO.File]::ReadAllText($log) } else { '' }
        $calls | Should -Not -Match '(^|\s)(fetch|pull|ls-remote)(\s|$)' `
            -Because "auto-pull/fetchless-off: the opt-out still reached the network; git was called as: $calls"
    }

    It '17m. a failing fetch must not print the remote''s credential (POSIX case 17)' {
        # The entrypoint's half of the leak that test-git-remote-lib.sh case 13
        # covers one layer down. An https remote may carry userinfo, and the
        # launcher's whole contract on a failed pull is to say so and carry on --
        # so the failure message is exactly where a URL gets echoed, into the
        # terminal the operator is about to screenshot for help. Nothing here
        # needs a real credential: the string is a fixed fake, and any appearance
        # of it is the failure.
        $secret = 'n0t-a-real-token-c5b-4f21'
        $launcher = New-Ctx17Clone -Name 'ctx17-secret'
        $root = Get-FixtureRoot $launcher
        Invoke-Ctx17Git -RepoPath $root -GitArgs @(
            'remote', 'set-url', 'origin', "https://ctx17-user:$secret@127.0.0.1:9/ops.git") | Out-Null
        $before = Get-Ctx17Head -LauncherPath $launcher

        # A temp directory of this case's own, created empty. Set-ChildEnvBlock
        # points all three spellings at the shared $script:Work, which every
        # other case has already written to; overriding them here is what makes
        # "everything in this tree came from this run" true. The sweep is a
        # negative assertion over a usually-empty directory, so it is proven
        # against a planted copy before it is trusted on the real one.
        $secretTemp = Join-Path $script:Work 'ctx17-secret-temp'
        Remove-Item -LiteralPath $secretTemp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $secretTemp -Force | Out-Null
        $probeDir = Join-Path $script:Work 'ctx17-secret-probe'
        New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $probeDir 'probe.log') -Encoding utf8 `
            -Value "https://ctx17-user:$secret@127.0.0.1:9/ops.git"
        { Assert-NoSecretInTree -Path $probeDir -Secrets @($secret) -Context 'probe' } |
            Should -Throw -Because 'auto-pull/secret: the tree sweep passed a file that plainly contains the secret, so the sweep below asserts nothing'
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{
                PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on'; GIT_TERMINAL_PROMPT = '0'
                TEMP = $secretTemp; TMP = $secretTemp; TMPDIR = $secretTemp
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/secret: an unreachable remote must not cost the launch; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/secret: the client was never started'
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before `
            -Because 'auto-pull/secret: the checkout advanced although the remote is unreachable'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' `
            'auto-pull/secret: an unreachable remote must still leave the checkout''s own tier map delivered'
        Assert-LauncherWarning $r 'pull' `
            'auto-pull/secret: the failed pull must be reported -- and that report is the line the credential would ride out on'
        Assert-NoSecretInOutput -Result $r -Secrets @($secret) -Context 'auto-pull/secret'
        Assert-NoSecretInTree -Path $secretTemp -Secrets @($secret) `
            -Context 'auto-pull/secret: the failed pull spilled the credential into a temp file, which outlives the terminal it was kept out of'

        # .git/ is the copy the two sweeps above cannot reach and nobody empties:
        # it is handed on with the checkout. Same treatment as the POSIX sibling
        # -- prove the single exclusion is load-bearing, then prove the sweep
        # reaches past it.
        $gitConfig = Join-Path (Join-Path $root '.git') 'config'
        [System.IO.File]::ReadAllText($gitConfig) | Should -Match ([regex]::Escape($secret)) `
            -Because 'auto-pull/secret: .git/config no longer carries the credential, so the sweep''s single exclusion is not being exercised'
        $gitProbe = Join-Path (Join-Path $root '.git') 'ccgw-leak-probe'
        Set-Content -LiteralPath $gitProbe -Encoding utf8 -Value "https://ctx17-user:$secret@127.0.0.1:9/ops.git"
        { Assert-NoSecretInGitState -RepoPath $root -Secrets @($secret) -Context 'probe' } |
            Should -Throw -Because 'auto-pull/secret: the .git sweep passed a file under .git/ that plainly contains the secret, so the sweep below asserts nothing'
        Remove-Item -LiteralPath $gitProbe -Force -ErrorAction SilentlyContinue
        Assert-NoSecretInGitState -RepoPath $root -Secrets @($secret) `
            -Context 'auto-pull/secret: the failed pull wrote the credential into .git/, which outlives %TEMP% and travels with the checkout'
    }

}
