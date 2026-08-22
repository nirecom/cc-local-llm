#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1
# Tags: lifecycle, client-launcher, windows, scope:issue-specific
#
# Entry point for the Windows client-launcher suite. The cases themselves live in
# the sibling folder code-ccgw-windows/ and are dot-sourced below, so
# `Invoke-Pester` against THIS path still discovers and runs every one of them.
#
#   code-ccgw-windows/
#     helpers-fixtures.ps1        fixture trees, the code/mkcert stubs, New-Env
#     helpers-runners.ps1         Invoke-Launcher, Invoke-LauncherInParentShell, dumps
#     helpers-runners-latency.ps1 Measure-LauncherLaunch (times the launcher itself)
#     helpers-assertions.ps1      Assert-LauncherEnv and friends
#     setup.ps1                   builds the fixtures (runs last, uses all of the above)
#     context-NN-*.ps1            one file per group of Contexts
#
# Scenario (issue #41 / detail plan D5a): the direct-to-DS4-Proxy route is
# retired, so the Windows client launcher (pwsh counterpart of
# scripts/code-ccgw.sh) has exactly ONE path — through the Mac LiteLLM.
#
# Why the precedence chains had to go, rather than merely being re-pointed:
# keeping a direct fallback would split the credential a client holds into two
# systems (a LiteLLM key and a proxy token), which defeats the TLS termination
# this change consolidates. With a single source there is nothing to fall back
# to, so an unconfigured base URL / key is an error, never a dummy default —
# a dummy default is what turns a misconfiguration into a confusing 401 much
# later, at request time.
#
# This suite is the 1:1 mirror of tests/feature-18-serverctl/test-code-ccgw-posix.sh
# (CPR-ORTH: the two launchers are symmetric members of one class, so the
# contract asserted on one must be asserted on the other). The only intentional
# divergences are the platform-specific ones: the VS Code profile dir lives
# under LOCALAPPDATA rather than being derived from `uname`, and PowerShell's
# native-command error conversion needs its own regression case.
#
# Scenario (issue #66): the launcher used to write every value it resolved into
# its OWN process environment before starting VS Code. PowerShell has no exec,
# so the launcher survives the call and those variables stay behind in the shell
# that invoked it — a later, unrelated cloud Claude Code session started from the
# same shell silently inherited local-LLM routing (ANTHROPIC_BASE_URL,
# CLAUDE_CODE_AUTO_COMPACT_WINDOW, …). The fix moves the destination, not the
# logic: every value is computed into script-local state and injected into the
# CHILD process's environment block only. Seven consequences are asserted here and
# nowhere else — Context 8 (the invoking shell is byte-for-byte untouched on the
# success paths AND on every error path, while the child still receives the
# computed values), Context 9 (an explicit process launch of a .cmd target must
# not let cmd.exe re-interpret argument metacharacters — the BatBadBut class —
# including the metacharacters in the resolved path of `code` itself, and with an
# observer faithful enough to compare an embedded quote literally), Context 11 (no
# statement in the source writes the environment at all, on any path, reachable by
# these tests or not), Context 12 (the argument shapes an explicit launch loses
# silently: empty, non-ASCII, over-long — and the safely-sized ones it must not
# refuse), Context 13 (the five model-routing keys, where ".env wins over the
# inherited value" and "the shell keeps its own value" have to hold at once, per
# key), Context 14 (the launcher hands over and returns instead of waiting for the
# editor — invisible to every fast-exiting stub) and Context 15 (the same
# metacharacter contract for the values the launcher READS, which reach the child
# through the environment block rather than through the command line).
#
# Method: `code` is stubbed on PATH with a stub that dumps the environment it
# inherited plus its argv to files, so every assertion is made against the
# environment the launcher actually hands to Claude Code — none of the
# launcher's branching is re-implemented here. `mkcert` is stubbed the same way.
# On Windows the `code` stub is a **code.cmd**, because the real `code` on a
# Windows VS Code install resolves to code.cmd: a .ps1 stub cannot be started by
# System.Diagnostics.Process at all, and — more importantly — it would never
# exercise the implicit cmd.exe re-parse that makes Context 9 necessary. On
# non-Windows hosts (where cmd.exe does not exist) the stub stays a code.ps1
# writing the identical dump format, so the platform-independent cases (the .env
# loader, precedence, the tier map) still run there. Context 10's `code` is
# instead a compiled .exe that reports what it received, because "the .exe branch
# was taken" cannot be shown by the absence of an error message.
#   Stub limitation: the .cmd stub recovers each argument through `%~1`, which
#   does NOT collapse a doubled embedded `""` back to `"` nor halve a doubled
#   trailing backslash. Arguments carrying an embedded quote or a trailing
#   backslash therefore cannot be round-trip-compared literally by THAT stub;
#   Context 9a-9c assert the weaker-but-still-decisive contract for those (no
#   argument splitting, no injection side effect), and Context 9f removes the
#   limitation with a second .cmd that forwards `%*` to a compiled argv observer
#   — the shape of a real code.cmd handing off to Code.exe — where the two shapes
#   are compared byte for byte.
#   Two further stubs exist for contracts a fast, well-named stub cannot express:
#   one whose DIRECTORY name carries a space, parentheses and `&` (Context 9e —
#   the path of `code` is part of the command line too), and one that stays alive
#   until released, so "the launcher returned" can be told apart from "the
#   launcher waited for VS Code" (Context 14).
# The launcher runs in a child pwsh whose environment block is cleared and
# rebuilt from scratch, so an ambient LITELLM_*/CCGW_*/DS4_* value in the
# developer's shell can never satisfy an assertion by accident. The script under
# test is copied into a fixture tree with its own (empty) repo-root .env, so the
# developer's real .env — which holds the actual base URL and API keys — is
# never read.
#
# Which PowerShell hosts the launcher: the launcher declares
# `#Requires -Version 5.1`, but only pwsh (7.x) ever ran it, so a 5.1-only
# incompatibility in ProcessStartInfo.Environment or the quoting helpers would
# ship unnoticed. CCGW_TEST_LAUNCHER_HOST selects the host binary for the child
# launcher process (default: this session's pwsh); test-code-ccgw-windows.sh
# runs the suite once with that variable explicitly unset and, under the RUN_TL3
# gate, again with CCGW_TEST_LAUNCHER_HOST=powershell.exe. Only the process under
# test moves — Pester keeps running on pwsh 7, because this harness itself needs
# ProcessStartInfo.ArgumentList, which the .NET Framework behind 5.1 does not
# have. The gate lives in the driver, not here: a host that was explicitly asked
# for and is missing is a configuration error worth failing on, not a case to
# quietly skip.
#
# TL3 gap: real VS Code startup and profile creation under the derived
#   --user-data-dir; a real mkcert CA actually being trusted by Node's TLS
#   stack; genuine end-to-end routing of the selected routing key through
#   LiteLLM to a loaded backend; a real `code.cmd` from a real VS Code install
#   (the stub is faithful about being a .cmd, not about what VS Code does with
#   its argv). Also unreachable from here: the
#   $PSNativeCommandUseErrorActionPreference guard itself — that conversion
#   applies only to native executables, and the mkcert stub is a .ps1, so the
#   failing-mkcert case exercises the resulting no-CAROOT branch rather than the
#   exit-code conversion that would have aborted the launcher before the fix.
#   And whether an .exe target is reached DIRECTLY or through a cmd.exe wrapper
#   is not observable from inside the child; Context 10 asserts what it received,
#   not how it was spawned.

Describe 'code-ccgw.ps1' {

    BeforeAll {
        # Definitions first, then setup.ps1 — which is top-level code, not a
        # function, so the $script: fixtures it builds land in this block's scope
        # where every It below can see them.
        $suite = Join-Path $PSScriptRoot 'code-ccgw-windows'
        . (Join-Path $suite 'helpers-fixtures.ps1')
        . (Join-Path $suite 'helpers-runners.ps1')
        . (Join-Path $suite 'helpers-runners-latency.ps1')
        . (Join-Path $suite 'helpers-assertions.ps1')
        . (Join-Path $suite 'setup.ps1')
    }

    AfterAll {
        if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
            Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Dot-sourced during Pester's DISCOVERY phase, which is when a Describe body
    # runs — each file's Context/It blocks are registered as if written here.
    # Enumerated rather than globbed so the order is the reading order and a new
    # file has to be added deliberately.
    foreach ($contextFile in @(
            'context-01-04-configuration.ps1'
            'context-05-06-launch.ps1'
            'context-07-dotenv.ps1'
            'context-08-parent-env.ps1'
            'context-09-metacharacters.ps1'
            'context-10-exe-branch.ps1'
            'context-11-source-contract.ps1'
            'context-12-argument-boundaries.ps1'
            'context-13-routing-precedence.ps1'
            'context-14-launch-responsiveness.ps1'
            'context-15-config-value-injection.ps1'
        )) {
        . (Join-Path (Join-Path $PSScriptRoot 'code-ccgw-windows') $contextFile)
    }
}
