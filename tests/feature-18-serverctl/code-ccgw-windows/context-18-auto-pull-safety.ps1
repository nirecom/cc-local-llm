#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, auto-pull, git, scope:issue-specific
#
# Continuation of context-17-auto-pull.ps1: where the switch is READ from, what
# a tree too dirty to touch looks like, and what a repeat launch may change.
# Fixture builders come from helpers-autopull.ps1. POSIX sibling:
# test-code-ccgw-auto-pull-2.sh -- the two must stay in step (CPR-ORTH).

Context '18. Auto-pull safety: the operator''s checkout is not collateral' -Skip:(-not $IsWindows -or -not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    # TL3 gap: the same one context-17 declares -- a real remote over SSH/HTTPS
    # with a credential helper that may prompt, and a merge that leaves the
    # checkout in a state only a real conflict produces. docs/ops.md's cutover
    # smoke run is what exercises the real origin.

    It '18a. the opt-out is honoured from .env, not only from the environment' {
        # 17b sets CCGW_AUTO_PULL in the process environment, which proves the
        # branch reads the variable but says nothing about WHEN. .env is where an
        # operator actually writes it, and the launcher loads that file itself --
        # so a pull placed before the loader would ignore the file entirely and
        # still pass 17b. Here the environment block carries no CCGW_AUTO_PULL at
        # all, so the file is the only place the answer can come from.
        $launcher = New-Ctx17Clone -Name 'ctx18-dotenv-off' -DotEnvLines @('CCGW_AUTO_PULL=off')
        Publish-Ctx17Update -Name 'ctx18-dotenv-off' -OpusName 'ctx17-opus-v2'
        $before = Get-Ctx17Snapshot -LauncherPath $launcher

        $r = Invoke-Launcher -LauncherPath $launcher -NoAutoPullDefault `
            -Environment (New-Env @{ PATH = (New-Ctx17Path) })
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/dotenv-off: the client was never started'
        Assert-Ctx17RepoUnchanged $before (Get-Ctx17Snapshot -LauncherPath $launcher) `
            'auto-pull/dotenv-off: .env said off, so the loader has to run before the pull'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' `
            'auto-pull/dotenv-off: the child got the upstream value, so the pull ran despite .env'
    }

    It '18b. a dirty tree defers the pull whatever the dirt is: <Label>' -ForEach @(
        @{ Label = 'staged'; Staged = $true; Modified = $false; Untracked = $false }
        @{ Label = 'modified'; Staged = $false; Modified = $true; Untracked = $false }
        @{ Label = 'untracked'; Staged = $false; Modified = $false; Untracked = $true }
        @{ Label = 'combined'; Staged = $true; Modified = $true; Untracked = $true }
    ) {
        # 17c dirties config.yaml itself, which any implementation notices because
        # it is the file the merge would rewrite. These four dirty something else,
        # and `git merge --ff-only` succeeds against all of them -- so an
        # implementation that asks git whether the merge is possible, rather than
        # whether the tree is clean, walks over the operator's work in progress.
        $name = "ctx18-dirty-$Label"
        $launcher = New-Ctx17Clone -Name $name
        $root = Get-FixtureRoot $launcher
        Publish-Ctx17Update -Name $name -OpusName 'ctx17-opus-v2'

        if ($Staged) {
            Set-Content -LiteralPath (Join-Path $root 'staged.txt') -Encoding utf8 -Value @('staged but not committed')
            Invoke-Ctx17Git -RepoPath $root -GitArgs @('add', 'staged.txt') | Out-Null
        }
        if ($Modified) {
            Add-Content -LiteralPath (Join-Path $root 'NOTES.md') -Encoding utf8 -Value 'edited in place'
        }
        if ($Untracked) {
            Set-Content -LiteralPath (Join-Path $root 'scratch.txt') -Encoding utf8 -Value @('scratch')
        }
        $before = Get-Ctx17Snapshot -LauncherPath $launcher

        $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $r.ExitCode | Should -Be 0 -Because "a dirty repo must still open the editor; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "auto-pull/dirty-${Label}: the client was never started"
        Assert-Ctx17RepoUnchanged $before (Get-Ctx17Snapshot -LauncherPath $launcher) `
            "auto-pull/dirty-${Label}: work the operator has not committed outranks a background convenience"
        Assert-LauncherWarning $r 'pull' `
            "auto-pull/dirty-${Label}: skipping the pull silently is how a stale table looks fresh"
    }

    It '18c. a second launch against an already-current checkout changes nothing' {
        # The launcher runs on every VS Code start, so the already-current path is
        # the one it takes almost every time. An implementation that merges
        # unconditionally, or writes the index to find out whether it needs to,
        # leaves a different tree behind on each launch -- which 18b then reads as
        # dirty, and the host stops updating for good.
        $launcher = New-Ctx17Clone -Name 'ctx18-idempotent'
        Publish-Ctx17Update -Name 'ctx18-idempotent' -OpusName 'ctx17-opus-v2'

        $first = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $first.ExitCode | Should -Be 0 -Because "the first run failed, so the second proves nothing; stderr: $($first.StdErr)"
        Assert-LauncherEnv $first 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v2' `
            'auto-pull/idempotent: the first run did not pull, so there is no already-current state to re-test'
        $afterFirst = Get-Ctx17Snapshot -LauncherPath $launcher

        $second = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{ PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on' })
        $second.ExitCode | Should -Be 0 -Because "stderr: $($second.StdErr)"
        Assert-Ctx17RepoUnchanged $afterFirst (Get-Ctx17Snapshot -LauncherPath $launcher) `
            'auto-pull/idempotent: pulling an already-current checkout must be a no-op'
        Assert-LauncherEnv $second 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v2' `
            'auto-pull/idempotent: the tier map changed between two identical launches'
    }

    It '18d. a failing pull must not print the CLIENT credential either (POSIX case 18)' {
        # 17m covers the credential the launcher read OUT of git. This is the
        # other one in the same process: LITELLM_CLIENT_KEY is the LiteLLM master
        # key itself (no virtual keys without a database), and it sits in the
        # environment the whole time the pull is failing. A launcher that reports
        # that failure by showing its own state -- a stray echo of the
        # environment block, a transcript, a git error report that inherits it --
        # spills the key that opens the gateway, on a path nothing else about
        # credentials runs through.
        $secret = 'n0t-a-real-client-key-8ae-1d07'
        $stub = New-StubDir -Name 'stub-ctx18-clientkey-git' -NoMkcert

        # The network verbs fail at once so the failure is reported rather than
        # waited out; everything else is forwarded, so the launcher still takes
        # its ordinary path up to the point where the pull breaks.
        Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            'echo %*|findstr /I "fetch pull ls-remote" >nul'
            'if not errorlevel 1 ('
            '    echo fatal: ccgw-fixture: the remote refused the connection 1>&2'
            '    exit /b 128'
            ')'
            """$($script:Ctx17GitExe)"" %*"
            'exit /b %ERRORLEVEL%'
        )

        $launcher = New-Ctx17Clone -Name 'ctx18-clientkey'
        $root = Get-FixtureRoot $launcher
        $before = Get-Ctx17Head -LauncherPath $launcher
        Publish-Ctx17Update -Name 'ctx18-clientkey' -OpusName 'ctx17-opus-v2'

        # A temp tree of this case's own, created empty, so everything found in
        # it was written by this run. The sweeps are proven against a planted
        # copy in 17m; what is proven here is that they run over this run.
        $keyTemp = Join-Path $script:Work 'ctx18-clientkey-temp'
        Remove-Item -LiteralPath $keyTemp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $keyTemp -Force | Out-Null

        $r = Invoke-Launcher -LauncherPath $launcher -StubDir $stub -Environment (New-Env @{
                PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32')); CCGW_AUTO_PULL = 'on'
                LITELLM_CLIENT_KEY = $secret
                TEMP = $keyTemp; TMP = $keyTemp; TMPDIR = $keyTemp
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/client-key: a refused fetch must not cost the launch; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/client-key: the client was never started'
        (Get-Ctx17Head -LauncherPath $launcher) | Should -BeExactly $before `
            -Because 'auto-pull/client-key: HEAD moved although every network call failed'
        Assert-LauncherEnv $r 'ANTHROPIC_AUTH_TOKEN' $secret `
            'auto-pull/client-key: the credential must still reach the child verbatim; dropping it to stay quiet is not the fix'
        Assert-LauncherWarning $r 'pull' `
            'auto-pull/client-key: the failed pull must be reported -- and that report is the line the environment would ride out on'
        Assert-NoSecretInOutput -Result $r -Secrets @($secret) -Context 'auto-pull/client-key'
        Assert-NoSecretInTree -Path $keyTemp -Secrets @($secret) `
            -Context 'auto-pull/client-key: the failed pull spilled the gateway credential into a temp file'
        Assert-NoSecretInGitState -RepoPath $root -Secrets @($secret) `
            -Context 'auto-pull/client-key: the gateway credential was written into the repository''s own git state by a failed pull'
    }

    It '18e. the fetch lands and the merge is the step that fails (POSIX case 19)' {
        # 17e is the only partial success covered so far, and it fails at the
        # merge for the one reason the launcher was written against: the branches
        # diverged. This is the other half -- the branches are still
        # fast-forwardable and the merge still cannot happen. A stale
        # .git/index.lock is the everyday way in on Windows especially, where an
        # editor's git integration, an antivirus scanner or a killed command
        # leaves one behind and nothing ever clears it.
        $name = 'ctx18-merge-fails'
        $launcher = New-Ctx17Clone -Name $name
        $root = Get-FixtureRoot $launcher
        Publish-Ctx17Update -Name $name -OpusName 'ctx17-opus-v2'
        $before = Get-Ctx17Snapshot -LauncherPath $launcher
        $gitConfigBefore = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root '.git') 'config'))

        # `git status` reads clean through the lock, so 18b's dirty-tree guard
        # waves the run past and the merge is the first step that touches the
        # index -- which is what makes this a merge-step case rather than a
        # second copy of 18b.
        $lock = Join-Path (Join-Path $root '.git') 'index.lock'
        Set-Content -LiteralPath $lock -Encoding ascii -Value ''
        try {
            (Invoke-Ctx17Git -RepoPath $root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty `
                -Because 'auto-pull/merge-fails: the fixture''s own lock made the tree read as dirty, so this case would exercise the dirty-tree guard instead of the merge step'

            $r = Invoke-Launcher -LauncherPath $launcher -Environment (New-Env @{
                    PATH = (New-Ctx17Path); CCGW_AUTO_PULL = 'on'
                })
        } finally {
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        }

        $r.ExitCode | Should -Be 0 -Because "auto-pull/merge-fails: a merge that cannot run must not cost the launch; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/merge-fails: the client was never started'
        Assert-Ctx17RepoUnchanged $before (Get-Ctx17Snapshot -LauncherPath $launcher) `
            'auto-pull/merge-fails: the merge could not run, so nothing about the checkout may have moved'
        [System.IO.File]::ReadAllText((Join-Path (Join-Path $root '.git') 'config')) |
            Should -BeExactly $gitConfigBefore -Because 'auto-pull/merge-fails: a failed merge rewrote .git/config'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' `
            'auto-pull/merge-fails: the tier map must come from the checkout as it stands; taking it from a merge that did not complete is how a host ends up addressing a name only the remote knows'
        Assert-LauncherWarning $r 'pull' `
            'auto-pull/merge-fails: a pull that silently did nothing leaves the operator believing they are on the published config'
    }

    It '18f. a failing pull passes no secret to git as an argument or a new variable (POSIX case 20)' {
        # 17m proves the terminal, %TEMP% and .git/ come out clean, and all three
        # are post-hoc: they see a leak only once something wrote it down. A
        # command line is never written down and is readable by every other
        # session on the host while the call runs -- Get-CimInstance
        # Win32_Process, an EDR agent's process log, a transcript -- so `git
        # fetch https://user:key@host/ops.git` leaks in full while leaving all
        # three of 17m's sweeps perfectly clean. 17l already runs a stub that
        # records argv; this is the case that reads what it recorded.
        $urlSecret = 'n0t-a-real-url-token-31d-6fa4'
        $masterSecret = 'n0t-a-real-master-key-77c-2b90'
        $clientSecret = 'n0t-a-real-client-key-40b-9c15'

        $stub = New-StubDir -Name 'stub-ctx18-spy-git' -NoMkcert
        $argvLog = Join-Path $script:Work 'ctx18-git-argv.log'
        $envLog = Join-Path $script:Work 'ctx18-git-env.log'
        Remove-Item -LiteralPath $argvLog, $envLog -Force -ErrorAction SilentlyContinue

        # Records its own argv and its own environment, then refuses the network
        # verbs so the failure is reported at once rather than waited out; every
        # other call is forwarded to the real git, exactly as 17l's stub does.
        Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
            '@echo off'
            ">>""$argvLog"" echo %*"
            ">>""$envLog"" set"
            'echo %*|findstr /I "fetch pull ls-remote" >nul'
            'if not errorlevel 1 ('
            '    echo fatal: ccgw-fixture: the remote refused the connection 1>&2'
            '    exit /b 128'
            ')'
            """$($script:Ctx17GitExe)"" %*"
            'exit /b %ERRORLEVEL%'
        )

        $launcher = New-Ctx17Clone -Name 'ctx18-spy-git'
        $root = Get-FixtureRoot $launcher
        Invoke-Ctx17Git -RepoPath $root -GitArgs @(
            'remote', 'set-url', 'origin', "https://ctx18-user:$urlSecret@127.0.0.1:9/ops.git") | Out-Null

        $r = Invoke-Launcher -LauncherPath $launcher -StubDir $stub -Environment (New-Env @{
                PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32'))
                CCGW_AUTO_PULL = 'on'; GIT_TERMINAL_PROMPT = '0'
                LITELLM_MASTER_KEY = $masterSecret; LITELLM_CLIENT_KEY = $clientSecret
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/spy-git: a refused fetch must not cost the launch; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/spy-git: the client was never started'

        # Both logs are negative assertions over files the launcher may simply
        # never have written, which is the shape that passes while testing
        # nothing. Prove the spy ran before believing its silence.
        $argv = if (Test-Path -LiteralPath $argvLog) { [System.IO.File]::ReadAllText($argvLog) } else { '' }
        $envDump = if (Test-Path -LiteralPath $envLog) { [System.IO.File]::ReadAllText($envLog) } else { '' }
        $argv | Should -Not -BeNullOrEmpty -Because 'auto-pull/spy-git: git was never invoked, so the argv sweep asserts nothing'
        $envDump | Should -Not -BeNullOrEmpty -Because 'auto-pull/spy-git: the spy recorded no environment, so the env sweep asserts nothing'

        foreach ($s in @($urlSecret, $masterSecret, $clientSecret)) {
            $argv | Should -Not -Match ([regex]::Escape($s)) `
                -Because "auto-pull/spy-git: a secret reached git's command line, where any other session on the host can read it: $argv"
        }

        # The convention 17m and POSIX case 18 set: a variable the parent holds
        # is INHERITED by every child, and that is not a leak. A leak is the same
        # value under a name nobody set -- so each secret is swept everywhere
        # except the one variable it belongs in, and the URL's credential (which
        # belongs in .git/config alone) everywhere at all.
        $lines = $envDump -split "`r?`n"
        foreach ($row in @(
                @{ Secret = $masterSecret; Carrier = 'LITELLM_MASTER_KEY' }
                @{ Secret = $clientSecret; Carrier = 'LITELLM_CLIENT_KEY' }
                @{ Secret = $urlSecret; Carrier = '' }
            )) {
            $unexpected = $lines | Where-Object {
                $_ -like "*$($row.Secret)*" -and -not ($row.Carrier -and $_ -like "$($row.Carrier)=*")
            }
            $carrierName = if ($row.Carrier) { $row.Carrier } else { '(none -- it belongs in .git/config only)' }
            $unexpected | Should -BeNullOrEmpty -Because `
                "auto-pull/spy-git: git's environment carries the secret under a name other than $carrierName, so something copied it there: $unexpected"
        }
    }

    # A git that records every call and then forwards it to the real one. 18d and
    # 18f both block the network verbs, which can only ever prove a negative;
    # forwarding is what lets the same stub serve a row whose expected answer is
    # "the fetch happened". POSIX sibling: the passthrough spy in
    # test-code-ccgw-auto-pull-3.sh. In BeforeAll rather than the Context body so
    # that both are in scope while the It bodies run, not only at discovery.
    BeforeAll {
        function New-Ctx18PassthroughGit {
            param([string]$Name, [string]$ArgvLog)
            $stub = New-StubDir -Name $Name -NoMkcert
            Set-Content -LiteralPath (Join-Path $stub 'git.cmd') -Encoding ascii -Value @(
                '@echo off'
                ">>""$ArgvLog"" echo %*"
                """$($script:Ctx17GitExe)"" %*"
                'exit /b %ERRORLEVEL%'
            )
            return $stub
        }

        $ctx18NetworkVerbs = '(^|\s)(fetch|pull|ls-remote)(\s|$)'
    }

    It '18g. shell and .env disagree about the switch, and the shell decides: <Label>' -ForEach @(
        @{ Label = 'shell-off-beats-dotenv-on'; Shell = 'off'; DotEnv = 'on'; Fetches = $false }
        @{ Label = 'shell-on-beats-dotenv-off'; Shell = 'on'; DotEnv = 'off'; Fetches = $true }
    ) {
        # 17b sets only the environment and 18a only the .env, so between them they
        # cannot tell "the shell wins" apart from "whichever one is set wins". The
        # conflict is the operator's own escape hatch: CCGW_AUTO_PULL=off in front
        # of one launch is how someone on a slow link gets their editor back, and
        # it works only if the branch consults the RESOLVED value rather than
        # re-reading .env for itself (detail.md:258 -- the ordinary non-routing
        # rule, where the shell's value outranks the file's).
        $name = "ctx18-conflict-$Label"
        $argvLog = Join-Path $script:Work "$name-argv.log"
        Remove-Item -LiteralPath $argvLog -Force -ErrorAction SilentlyContinue
        $stub = New-Ctx18PassthroughGit -Name "stub-$name" -ArgvLog $argvLog

        $launcher = New-Ctx17Clone -Name $name -DotEnvLines @("CCGW_AUTO_PULL=$DotEnv")
        Publish-Ctx17Update -Name $name -OpusName 'ctx17-opus-v2'

        $r = Invoke-Launcher -LauncherPath $launcher -StubDir $stub -Environment (New-Env @{
                PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32'))
                CCGW_AUTO_PULL = $Shell
            })
        $r.ExitCode | Should -Be 0 -Because "stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because "auto-pull/$Label`: the client was never started"

        $argv = if (Test-Path -LiteralPath $argvLog) { [System.IO.File]::ReadAllText($argvLog) } else { '' }
        if ($Fetches) {
            $argv | Should -Match $ctx18NetworkVerbs -Because `
                "auto-pull/$Label`: the shell said on, so the shell's on has to reach the network; git was called with: $argv"
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v2' `
                "auto-pull/$Label`: the shell turned the pull on, so the published lineup is the one that must be delivered"
        } else {
            $argv | Should -Not -Match $ctx18NetworkVerbs -Because `
                "auto-pull/$Label`: the shell said off; re-reading .env here spends exactly the wait the operator opted out of: $argv"
            Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'ctx17-opus-v1' `
                "auto-pull/$Label`: opting out must still route from the checkout as it stands"
        }
    }

    It '18h. a config tree that was never a checkout (POSIX case 22)' {
        # Distinct from 17f/17g -- "no upstream" and "detached HEAD" both
        # presuppose a .git. Here there is none: an operator copied the tree out of
        # the repo, or unpacked a release tarball. The hazard is that `git
        # rev-parse --is-inside-work-tree` (detail.md:265) WALKS UP, so a tree
        # sitting inside some unrelated repository reads as satisfying the
        # precondition -- and a naive launcher then fast-forwards a checkout that
        # has nothing to do with the gateway. The ancestor below is therefore a
        # real repository with a real upstream holding a different lineup: every
        # ingredient a wrong fetch would need to succeed.
        $ancestor = Join-Path $script:Work 'ctx18-ancestor'
        $ancestorBare = Join-Path $script:Work 'ctx18-ancestor-remote.git'
        $nested = Join-Path $ancestor 'vendor\ccgw-ops'

        New-Item -ItemType Directory -Path $ancestor -Force | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('init', '--quiet', '--initial-branch=main') | Out-Null
        Set-Ctx17RepoConfig -RepoPath $ancestor
        Set-Content -LiteralPath (Join-Path $ancestor 'README.md') -Encoding utf8 `
            -Value @('an unrelated repository that merely contains the directory')
        Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('add', '-A') | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('commit', '--quiet', '-m', 'ancestor seed') | Out-Null
        New-Item -ItemType Directory -Path $ancestorBare -Force | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestorBare -GitArgs @('init', '--quiet', '--bare', '--initial-branch=main') | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('remote', 'add', 'origin', $ancestorBare) | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('push', '--quiet', '-u', 'origin', 'main') | Out-Null

        # A commit the ancestor's upstream has and the ancestor does not. If the
        # launcher fast-forwards it, the tier assertions below name the key that
        # would arrive.
        $ancestorPub = Join-Path $script:Work 'ctx18-ancestor-publisher'
        & $script:Ctx17GitExe 'clone' '--quiet' $ancestorBare $ancestorPub 2>&1 | Out-Null
        Set-Ctx17RepoConfig -RepoPath $ancestorPub
        New-Item -ItemType Directory -Path (Join-Path $ancestorPub 'vendor\ccgw-ops\litellm-server') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ancestorPub 'vendor\ccgw-ops\litellm-server\config.yaml') `
            -Encoding utf8 -Value (New-Ctx17ConfigLines -OpusName 'wrong-repo-opus')
        Invoke-Ctx17Git -RepoPath $ancestorPub -GitArgs @('add', '-A') | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestorPub -GitArgs @('commit', '--quiet', '-m', 'a different lineup') | Out-Null
        Invoke-Ctx17Git -RepoPath $ancestorPub -GitArgs @('push', '--quiet', 'origin', 'main') | Out-Null

        # The tree under test: a launcher, a .env and a config.yaml, and no .git.
        New-Item -ItemType Directory -Path (Join-Path $nested 'scripts') -Force | Out-Null
        Copy-Item -LiteralPath $script:SourceLauncher -Destination (Join-Path $nested 'scripts\code-ccgw.ps1') -Force
        Set-Content -LiteralPath (Join-Path $nested '.env') -Encoding utf8 `
            -Value @('# ctx18h: the switch is on, and there is still nothing of ours to pull')
        New-FixtureConfigYaml -Root $nested | Out-Null
        $configPath = Join-Path $nested 'litellm-server\config.yaml'
        $configBefore = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configPath))
        (Test-Path -LiteralPath (Join-Path $nested '.git')) | Should -BeFalse `
            -Because 'auto-pull/no-git: the fixture tree has a .git of its own, so it is not the case this asserts'

        # The walk-up really does happen here; without it the branch under test is
        # never entered and the case would pass for the wrong reason.
        (Invoke-Ctx17Git -RepoPath $nested -GitArgs @('rev-parse', '--is-inside-work-tree')).Trim() |
            Should -BeExactly 'true' -Because 'auto-pull/no-git: git does not see the tree as inside a work tree, so the hazard this case exists for is absent'

        $argvLog = Join-Path $script:Work 'ctx18-no-git-argv.log'
        Remove-Item -LiteralPath $argvLog -Force -ErrorAction SilentlyContinue
        $stub = New-Ctx18PassthroughGit -Name 'stub-ctx18-no-git' -ArgvLog $argvLog
        $ancestorHeadBefore = (Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('rev-parse', 'HEAD')).Trim()

        $r = Invoke-Launcher -LauncherPath (Join-Path $nested 'scripts\code-ccgw.ps1') -StubDir $stub `
            -Environment (New-Env @{
                PATH = ($stub + ';' + (Join-Path $env:WINDIR 'System32'))
                CCGW_AUTO_PULL = 'on'
            })
        $r.ExitCode | Should -Be 0 -Because "auto-pull/no-git: a missing .git is a reason to skip the pull, never to withhold the editor; stderr: $($r.StdErr)"
        $r.Reached | Should -BeTrue -Because 'auto-pull/no-git: the client was never started'
        Assert-LauncherWarning $r 'git' `
            'auto-pull/no-git: skipping the update silently leaves the operator believing they are current'

        $argv = if (Test-Path -LiteralPath $argvLog) { [System.IO.File]::ReadAllText($argvLog) } else { '' }
        $argv | Should -Not -Match $ctx18NetworkVerbs -Because `
            "auto-pull/no-git: the tree is not a checkout, so it has no upstream of ITS OWN -- anything fetched here belongs to a repository that merely contains it: $argv"
        (Invoke-Ctx17Git -RepoPath $ancestor -GitArgs @('rev-parse', 'HEAD')).Trim() |
            Should -BeExactly $ancestorHeadBefore -Because 'auto-pull/no-git: the surrounding repository was fast-forwarded; the launcher moved a checkout that is not the gateway''s'
        [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($configPath)) |
            Should -BeExactly $configBefore -Because 'auto-pull/no-git: config.yaml is no longer byte-for-byte the file that was written'

        # And the whole point of continuing: the local file still drives all five
        # tiers, none of them from the lineup the ancestor's upstream holds.
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'lite-shared' 'auto-pull/no-git: haiku from the local file'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_SONNET_MODEL' 'lite-shared' 'auto-pull/no-git: sonnet from the local file'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_FABLE_MODEL' 'lite-fable' 'auto-pull/no-git: fable from the local file'
        Assert-LauncherEnv $r 'ANTHROPIC_DEFAULT_OPUS_MODEL' 'lite-opus' 'auto-pull/no-git: opus from the local file'
        Assert-LauncherEnv $r 'CLAUDE_CODE_SUBAGENT_MODEL' 'lite-shared' 'auto-pull/no-git: subagent from the local file'
    }
}
