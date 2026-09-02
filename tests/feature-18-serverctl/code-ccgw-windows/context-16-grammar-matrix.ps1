#!/usr/bin/env pwsh
# Tests: scripts/code-ccgw.ps1, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, windows, config, ssot, parser, scope:issue-specific
#
# Split out of context-16-config-ssot.ps1: the same annotation grammar written
# as a table, per skills/_shared/test-design/parser-regex-tests.md. Only
# near-misses separate the grammar from a reader that merely substring-matches
# `ccgw`, and near-misses are affordable only in bulk. The grammar itself is
# owned by detail plan S4; the row-for-row POSIX sibling is
# test-code-ccgw-config-tiers.sh case 13 (CPR-ORTH). `@` stands for one space.

Context '16h-16j. The ccgw_tiers grammar, spelling by spelling (issue #89)' {
    # TL3 gap: shared with context-16-config-ssot.ps1 -- whether a real LiteLLM
    # accepts `ccgw_tiers` inside litellm_params at all, rather than refusing to
    # start. Only a live server answers that; the docs/ops.md cutover smoke run
    # at USER_VERIFIED covers it.

    BeforeAll {
        # Every probe is one route claiming opus next to a fixed neighbour
        # claiming haiku, so a single run says both "this spelling was (not)
        # adopted" and "a rejected line took nothing else down with it".
        function ConvertTo-Ctx16Line {
            param([string]$Encoded)
            return ($Encoded -replace '@', ' ')
        }

        # Format P (`^      ccgw_tiers:[ ]*\[([^]]*)\][ ]*$`) may sit anywhere in
        # the block, so the probe line goes last -- where a hand-edit lands.
        function New-Ctx16KeyProbeLines {
            param([string]$Line)
            return @(
                'model_list:'
                '  - model_name: grammar-neighbour'
                '    litellm_params:'
                '      model: openai/Backend-N'
                '      ccgw_tiers: [haiku]'
                ''
                '  - model_name: grammar-probe'
                '    litellm_params:'
                '      model: openai/Backend-P'
                (ConvertTo-Ctx16Line $Line)
            )
        }

        # Format F (`^    # ccgw-tiers:[ ]+(.+)$`) is placement-sensitive: the
        # probe line goes on the block's second line, the only place it is read.
        function New-Ctx16CommentProbeLines {
            param([string]$Line)
            return @(
                'model_list:'
                '  - model_name: grammar-neighbour'
                '    litellm_params:'
                '      model: openai/Backend-N'
                '      ccgw_tiers: [haiku]'
                ''
                '  - model_name: grammar-probe'
                (ConvertTo-Ctx16Line $Line)
                '    litellm_params:'
                '      model: openai/Backend-P'
            )
        }

        # The other half of a route record: the name the annotation hangs off.
        # Same block shape as the key-form probe, with the NAME as the variable.
        function New-Ctx16NameProbeLines {
            param([string]$Name)
            return @(
                'model_list:'
                '  - model_name: grammar-neighbour'
                '    litellm_params:'
                '      model: openai/Backend-N'
                '      ccgw_tiers: [haiku]'
                ''
                "  - model_name: $Name"
                '    litellm_params:'
                '      model: openai/Backend-P'
                '      ccgw_tiers: [opus]'
            )
        }

        function Assert-Ctx16Probe {
            param($Result, [string]$Want, [string]$Context)
            $Result.ExitCode | Should -Be 0 -Because "$Context`: the neighbour route is annotated, so the launch must survive a bad probe line; stderr: $($Result.StdErr)"
            if ($Want) {
                Assert-LauncherEnv $Result 'ANTHROPIC_DEFAULT_OPUS_MODEL' $Want "$Context`: this spelling is inside the grammar and must be adopted"
            }
            else {
                Assert-LauncherEnvUnset $Result 'ANTHROPIC_DEFAULT_OPUS_MODEL' "$Context`: this spelling is outside the grammar and must be adopted for nothing"
            }
            Assert-LauncherEnv $Result 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'grammar-neighbour' "$Context`: the neighbour route must be untouched either way"
        }
    }

    It '16h. key form <Name>' -ForEach @(
        @{ Name = 'plain';           Line = '@@@@@@ccgw_tiers:@[opus]';        Want = 'grammar-probe' }
        @{ Name = 'inner-padding';   Line = '@@@@@@ccgw_tiers:@[@opus@]';      Want = 'grammar-probe' }
        @{ Name = 'wide-colon-gap';  Line = '@@@@@@ccgw_tiers:@@@[opus]';      Want = 'grammar-probe' }
        @{ Name = 'no-colon-space';  Line = '@@@@@@ccgw_tiers:[opus]';         Want = 'grammar-probe' }
        @{ Name = 'trailing-space';  Line = '@@@@@@ccgw_tiers:@[opus]@@';      Want = 'grammar-probe' }
        @{ Name = 'two-tokens';      Line = '@@@@@@ccgw_tiers:@[fable,@opus]'; Want = 'grammar-probe' }
        @{ Name = 'repeated-token';  Line = '@@@@@@ccgw_tiers:@[opus,@opus]';  Want = 'grammar-probe' }
        @{ Name = 'shallow-indent';  Line = '@@@@ccgw_tiers:@[opus]';          Want = '' }
        @{ Name = 'deep-indent';     Line = '@@@@@@@@ccgw_tiers:@[opus]';      Want = '' }
        @{ Name = 'no-brackets';     Line = '@@@@@@ccgw_tiers:@opus';          Want = '' }
        @{ Name = 'empty-list';      Line = '@@@@@@ccgw_tiers:@[]';            Want = '' }
        @{ Name = 'key-only';        Line = '@@@@@@ccgw_tiers:';               Want = '' }
        @{ Name = 'hyphen-key';      Line = '@@@@@@ccgw-tiers:@[opus]';        Want = '' }
        @{ Name = 'singular-key';    Line = '@@@@@@ccgw_tier:@[opus]';         Want = '' }
        @{ Name = 'unseparated-key'; Line = '@@@@@@ccgwtiers:@[opus]';         Want = '' }
        @{ Name = 'uppercase-key';   Line = '@@@@@@CCGW_TIERS:@[opus]';        Want = '' }
        @{ Name = 'suffixed-key';    Line = '@@@@@@ccgw_tiers_extra:@[opus]';  Want = '' }
        @{ Name = 'uppercase-token'; Line = '@@@@@@ccgw_tiers:@[OPUS]';        Want = '' }
        @{ Name = 'suffixed-token';  Line = '@@@@@@ccgw_tiers:@[opusx]';       Want = '' }
        @{ Name = 'truncated-token'; Line = '@@@@@@ccgw_tiers:@[opu]';         Want = '' }
    ) {
        $fixture = New-FixtureTree -Name "fixture-ctx16h-$Name" -ConfigYamlLines (New-Ctx16KeyProbeLines $Line)
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        Assert-Ctx16Probe $r $Want "config-ssot/key-grammar/$Name"
    }

    It '16i. comment form <Name>' -ForEach @(
        @{ Name = 'plain';           Line = '@@@@#@ccgw-tiers:@opus';       Want = 'grammar-probe' }
        @{ Name = 'two-tokens';      Line = '@@@@#@ccgw-tiers:@fable@opus'; Want = 'grammar-probe' }
        @{ Name = 'wide-colon-gap';  Line = '@@@@#@ccgw-tiers:@@@opus';     Want = 'grammar-probe' }
        @{ Name = 'trailing-space';  Line = '@@@@#@ccgw-tiers:@opus@@';     Want = 'grammar-probe' }
        @{ Name = 'repeated-token';  Line = '@@@@#@ccgw-tiers:@opus@opus';  Want = 'grammar-probe' }
        @{ Name = 'no-colon-space';  Line = '@@@@#@ccgw-tiers:opus';        Want = '' }
        @{ Name = 'no-hash-space';   Line = '@@@@#ccgw-tiers:@opus';        Want = '' }
        @{ Name = 'shallow-indent';  Line = '@@#@ccgw-tiers:@opus';         Want = '' }
        @{ Name = 'deep-indent';     Line = '@@@@@@#@ccgw-tiers:@opus';     Want = '' }
        @{ Name = 'key-only';        Line = '@@@@#@ccgw-tiers:';            Want = '' }
        @{ Name = 'underscore-key';  Line = '@@@@#@ccgw_tiers:@opus';       Want = '' }
        @{ Name = 'singular-key';    Line = '@@@@#@ccgw-tier:@opus';        Want = '' }
        @{ Name = 'unseparated-key'; Line = '@@@@#@ccgwtiers:@opus';        Want = '' }
        @{ Name = 'uppercase-key';   Line = '@@@@#@CCGW-TIERS:@opus';       Want = '' }
        @{ Name = 'uppercase-token'; Line = '@@@@#@ccgw-tiers:@OPUS';       Want = '' }
        @{ Name = 'suffixed-token';  Line = '@@@@#@ccgw-tiers:@opusx';      Want = '' }
        @{ Name = 'comma-joined';    Line = '@@@@#@ccgw-tiers:@opus,fable'; Want = '' }
        @{ Name = 'bracketed';       Line = '@@@@#@ccgw-tiers:@[opus]';     Want = '' }
    ) {
        $fixture = New-FixtureTree -Name "fixture-ctx16i-$Name" -ConfigYamlLines (New-Ctx16CommentProbeLines $Line)
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        Assert-Ctx16Probe $r $Want "config-ssot/comment-grammar/$Name"
    }

    It '16j. the comment form is read from the block''s second line and nowhere else' {
        # The other half of 16b2. Above the block start the line falls outside
        # the block; below the second line it is inside the block but no longer
        # where the format-F reader looks -- and "inside the block" is exactly
        # the reasoning that would tempt an implementation to accept it, which
        # is why the two are separate cases rather than one.
        $fixture = New-FixtureTree -Name 'fixture-ctx16j-third-line' -ConfigYamlLines @(
            'model_list:'
            '  - model_name: grammar-neighbour'
            '    litellm_params:'
            '      model: openai/Backend-N'
            '      ccgw_tiers: [haiku]'
            ''
            '  - model_name: grammar-probe'
            '    litellm_params:'
            '    # ccgw-tiers: opus'
            '      model: openai/Backend-P'
        )
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        Assert-Ctx16Probe $r '' 'config-ssot/comment-grammar/third-line'
    }

    It '16k. a model_name that reads as a YAML scalar is the literal token: <Name>' -ForEach @(
        @{ Name = 'null-literal';  Token = 'null';  Want = 'null' }
        @{ Name = 'tilde-null';    Token = '~';     Want = '' }
        @{ Name = 'true-literal';  Token = 'true';  Want = 'true' }
        @{ Name = 'false-literal'; Token = 'false'; Want = 'false' }
        @{ Name = 'yes-literal';   Token = 'yes';   Want = 'yes' }
        @{ Name = 'no-literal';    Token = 'no';    Want = 'no' }
        @{ Name = 'integer';       Token = '123';   Want = '123' }
        @{ Name = 'float';         Token = '1.5';   Want = '1.5' }
    ) {
        # Seven of these are ordinary names to `[A-Za-z0-9._-]+` and reserved
        # literals to a YAML reader; `~` is the one row outside the class, and
        # is refused exactly as any other illegal character is. This launcher
        # matches lines rather than loading YAML, so the only answer it may give
        # is the token as typed -- the same answer the POSIX sibling (case 7 of
        # test-code-ccgw-config-guards.sh) and the Python mirror (case 10c of
        # test_route_tier_annotations_2.py) give. PowerShell is the reader most
        # likely to disagree: an unquoted `no` or `1.5` reaching a comparison
        # can be coerced on the way, and what the operator would then see is a
        # /model entry pointing at a key their config.yaml does not contain.
        $fixture = New-FixtureTree -Name "fixture-ctx16k-$Name" -ConfigYamlLines (New-Ctx16NameProbeLines $Token)
        $r = Invoke-Launcher -LauncherPath $fixture -Environment (New-Env)
        Assert-Ctx16Probe $r $Want "config-ssot/name-scalar/$Name"
    }
}
