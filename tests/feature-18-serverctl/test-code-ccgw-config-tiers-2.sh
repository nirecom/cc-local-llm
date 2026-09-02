#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, client-launcher, config, ssot, routing
#
# Continuation of test-code-ccgw-config-tiers.sh past the 500-line limit of
# rules/coding/file-split.md; shared fixture in code-ccgw-config-tiers/fixture.sh,
# case numbering continues from 13. Subject: the two spellings the sibling suite
# leaves under-specified -- the comment form's grammar, and the byte shape of
# the file that grammar is matched against. TL3 gap as in the sibling suite:
# whether the key reaching the child resolves at a running LiteLLM (docs/ops.md).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/code-ccgw-config-tiers/fixture.sh"

# --- Case 14: the comment-form annotation grammar, spelling by spelling ------
# The mirror of case 13 for format F, and the reason the pair has to be stated
# twice: the two forms are matched by two different expressions, so a parser
# exact about one can be a substring match on the other. Row for row the
# Windows sibling's It '16i' (CPR-ORTH). Expectations re-derived from format F
# in detail plan S4: `^    # ccgw-tiers:[ ]+(.+)$` -- 4-space indent, a literal
# space after `#`, at least one space after the colon, then space-separated
# tokens from the closed lowercase vocabulary. Placement is part of the form:
# the fixture's probe builder puts the line on the block's second line, the
# only position format F is read at.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    grammar_probe_comment "${input//[[:space:]]/}"
    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 14/$name: exited $RC although the neighbour route is annotated: $(cat "$WORK/err")"
    # Reject rows (no `want`) assert the ABSENCE of the name, not an empty
    # value: see the note on assert_unset in the shared fixture. The comment
    # form needs it at least as much as case 13 does -- its rejects include
    # `key-only`, whose token list is genuinely empty, so "exported as nothing"
    # is exactly the wrong pass this row could otherwise collect.
    if [ -z "$want" ]; then
        assert_unset ANTHROPIC_DEFAULT_OPUS_MODEL \
            "case 14/$name: a rejected comment-form annotation must leave the opus tier unset"
    else
        assert_eq "case 14/$name: opus mapping" "$want" "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
    fi
    assert_eq "case 14/$name: the neighbour route must be untouched" \
        grammar-neighbour "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
done <<'TABLE'
plain            | @@@@#@ccgw-tiers:@opus       | grammar-probe
two-tokens       | @@@@#@ccgw-tiers:@fable@opus | grammar-probe
wide-colon-gap   | @@@@#@ccgw-tiers:@@@opus     | grammar-probe
trailing-space   | @@@@#@ccgw-tiers:@opus@@     | grammar-probe
repeated-token   | @@@@#@ccgw-tiers:@opus@opus  | grammar-probe
no-colon-space   | @@@@#@ccgw-tiers:opus        |
no-hash-space    | @@@@#ccgw-tiers:@opus        |
shallow-indent   | @@#@ccgw-tiers:@opus         |
deep-indent      | @@@@@@#@ccgw-tiers:@opus     |
key-only         | @@@@#@ccgw-tiers:            |
underscore-key   | @@@@#@ccgw_tiers:@opus       |
singular-key     | @@@@#@ccgw-tier:@opus        |
unseparated-key  | @@@@#@ccgwtiers:@opus        |
uppercase-key    | @@@@#@CCGW-TIERS:@opus       |
uppercase-token  | @@@@#@ccgw-tiers:@OPUS       |
suffixed-token   | @@@@#@ccgw-tiers:@opusx      |
comma-joined     | @@@@#@ccgw-tiers:@fable,opus |
bracketed        | @@@@#@ccgw-tiers:@[opus]     |
TABLE

# --- Case 15: the same config saved with either line ending reads the same ---
# config.yaml is edited from Windows as well as macOS now, and a Windows editor
# -- or the PowerShell writer, whose Set-Content default is CRLF -- leaves a CR
# at the end of every line. The CR lands exactly where both forms anchor their
# end: inside `[opus]\r` for format P, inside the captured token list for
# format F. A reader that does not strip it maps no tier at all, or maps one to
# a key with a trailing CR that no /model entry can match. Both endings against
# both forms, because the ending is the axis the sibling suite never varies;
# asserting the exact key rather than "something was exported" is what makes a
# surviving CR a failure instead of a curiosity.
write_comment_config() {
    set_config <<'EOF'
model_list:
  - model_name: lite-shared
    # ccgw-tiers: haiku sonnet subagent
    litellm_params:
      model: openai/Qwen3.8-27B

  - model_name: lite-fable
    # ccgw-tiers: fable
    litellm_params:
      model: anthropic/deepseek-v4-flash

  - model_name: lite-opus
    # ccgw-tiers: opus
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
EOF
}

to_crlf() { # to_crlf -- rewrite $CONFIG with CRLF terminators, in place
    awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$CONFIG" > "$CONFIG.tmp" \
        && mv "$CONFIG.tmp" "$CONFIG"
}

while IFS='|' read -r name form ending; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    form="${form//[[:space:]]/}"
    ending="${ending//[[:space:]]/}"

    case "$form" in
        key)     write_default_config ;;
        comment) write_comment_config ;;
        *)       fail "case 15/$name: unknown annotation form '$form'" ;;
    esac
    [ "$ending" = "crlf" ] && to_crlf

    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 15/$name: exited $RC on a $ending-terminated config: $(cat "$WORK/err")"
    assert_eq "case 15/$name: opus tier" lite-opus "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
    assert_eq "case 15/$name: fable tier" lite-fable "$(dump_get ANTHROPIC_DEFAULT_FABLE_MODEL)"
    assert_eq "case 15/$name: haiku tier" lite-shared "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
    assert_eq "case 15/$name: sonnet tier" lite-shared "$(dump_get ANTHROPIC_DEFAULT_SONNET_MODEL)"
    assert_eq "case 15/$name: the subagent route" lite-shared "$(dump_get CLAUDE_CODE_SUBAGENT_MODEL)"
    assert_eq "case 15/$name: the /model picker entry" lite-fable "$(dump_get ANTHROPIC_CUSTOM_MODEL_OPTION)"
done <<'TABLE'
key-lf        | key     | lf
key-crlf      | key     | crlf
comment-lf    | comment | lf
comment-crlf  | comment | crlf
TABLE

echo "PASS: test-code-ccgw-config-tiers-2"
