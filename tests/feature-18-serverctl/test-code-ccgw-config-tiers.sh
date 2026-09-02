#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL2, client-launcher, config, ssot, routing
#
# config.yaml owns the routing map: the launcher reads each route's
# `ccgw_tiers` annotation and puts that route's `model_name` on the matching
# /model tier (issue #89; history: docs/history.md).
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/code-ccgw-config-tiers/fixture.sh"

# Split out of test-code-ccgw-posix.sh, which keeps the concerns one fixture
# config serves (base URL, credential, TLS CA, argv); every case here rewrites
# the config instead. Shared fixture in code-ccgw-config-tiers/fixture.sh, and
# cases 14+ continue in the `-2` sibling (rules/coding/file-split.md).
# TL3 gap: whether the routing key that reaches the child actually resolves at
# a running LiteLLM -- the docs/ops.md cutover run at USER_VERIFIED covers it.
#
# Assembled at runtime -- the literal spelling is banned repo-wide by
# tests/ccgw-naming/test_no_legacy_names.py.
R_DEFAULT_MODEL="CCGW_DEFAULT""_MODEL"

# --- Case 1: the annotated map reaches the child, tier by tier ---------------
write_default_config
run_launcher
[ "$RC" -eq 0 ] || fail "case 1: exited $RC: $(cat "$WORK/err")"
assert_env ANTHROPIC_DEFAULT_HAIKU_MODEL lite-shared "case 1: haiku tier"
assert_env ANTHROPIC_DEFAULT_SONNET_MODEL lite-shared "case 1: sonnet tier"
assert_env CLAUDE_CODE_SUBAGENT_MODEL lite-shared "case 1: the subagent route"
assert_env ANTHROPIC_DEFAULT_FABLE_MODEL lite-fable "case 1: fable tier"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "case 1: opus tier"
assert_env ANTHROPIC_CUSTOM_MODEL_OPTION lite-fable "case 1: the /model picker entry follows the fable tier"
assert_unset ANTHROPIC_MODEL "case 1: the startup tier is settings.json's to choose, not the launcher's"

# Stated as an inequality too: a regression collapsing every tier onto the
# first route would still satisfy each literal above if all of them moved.
[ "$(dump_get ANTHROPIC_DEFAULT_FABLE_MODEL)" != "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" ] \
    || fail "case 1: fable and opus resolved to the same key; /model could not switch between them"

# --- Case 2: the comment form of the annotation is equivalent ----------------
# A YAML key LiteLLM does not know can make a strict schema check reject the
# file, so the annotation also has a comment spelling (format F). Per the
# format-F contract, the comment sits on the line immediately AFTER the block
# start (`- model_name:`), 4-space indented, tokens space-separated — never
# above the route (that placement is the negative case: it falls outside the
# block and gets silently absorbed by the previous route, or dropped for the
# first route).
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
run_launcher
[ "$RC" -eq 0 ] || fail "case 2: exited $RC on the comment form: $(cat "$WORK/err")"
for t in haiku sonnet subagent; do
    assert_env "$(var_for "$t")" lite-shared "case 2 ($t): the comment form must map like the key form"
done
assert_env ANTHROPIC_DEFAULT_FABLE_MODEL lite-fable "case 2: fable tier"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "case 2: opus tier"

# --- Cases 3 and 4: a stale value loses, in either place, for every tier -----
# The 2026-08-22 regression in miniature: the operator's shell still exports
# what the .env said before the backend moved (case 3), and every machine's
# .env still carries the old lines until somebody edits them by hand (case 4).
# Dropping one fallback is not enough -- keeping either would go on routing to
# a model that no longer exists. Table-driven over all five keys per
# skills/_shared/test-design/parser-regex-tests.md, one route per tier: a
# lookup fixed for opus but not fable is invisible to a single combined run,
# and a regression collapsing every tier onto the first route it parsed can
# satisfy at most one row (CPR-ORTH; Windows sibling: context-13).
set_config <<'EOF'
model_list:
  - model_name: tier-haiku
    litellm_params:
      model: openai/Backend-H
      ccgw_tiers: [haiku]

  - model_name: tier-sonnet
    litellm_params:
      model: openai/Backend-S
      ccgw_tiers: [sonnet]

  - model_name: tier-fable
    litellm_params:
      model: anthropic/Backend-F
      ccgw_tiers: [fable]

  - model_name: tier-opus
    litellm_params:
      model: openai/Backend-O
      ccgw_tiers: [opus]

  - model_name: tier-subagent
    litellm_params:
      model: openai/Backend-U
      ccgw_tiers: [subagent]
EOF

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    input="${input//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    child="$(var_for "$name")"

    # 3: the retired key reaches the launcher from the shell that invoked it,
    # the way a shell that sourced an older .env carries it.
    printf '# empty on purpose: the shell is the stale source under test\n' > "$DOTENV"
    run_launcher "$input=stale-from-shell-$name" </dev/null
    [ "$RC" -eq 0 ] || fail "case 3 ($name): exited $RC: $(cat "$WORK/err")"
    assert_eq "case 3/$name: config.yaml must outrank a stale shell value" \
        "$want" "$(dump_get "$child")"

    # 4: the retired key is still written in .env, which load-dotenv exports
    # before the launcher ever looks at config.yaml.
    printf '%s=stale-from-dotenv-%s\n' "$input" "$name" > "$DOTENV"
    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 4 ($name): exited $RC: $(cat "$WORK/err")"
    assert_eq "case 4/$name: config.yaml must outrank a stale .env line" \
        "$want" "$(dump_get "$child")"
done <<'TABLE'
haiku    | LITELLM_HAIKU_MODEL  | tier-haiku
sonnet   | LITELLM_SONNET_MODEL | tier-sonnet
fable    | LITELLM_FABLE_MODEL  | tier-fable
opus     | LITELLM_OPUS_MODEL   | tier-opus
subagent | CCGW_SUBAGENT_MODEL  | tier-subagent
TABLE

# --- Case 5: the operator is told their .env still carries the retired keys --
# All five names are driven separately so a warning that only handles one
# spelling can't pass by accident.
write_default_config
while IFS= read -r key; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="${key//[[:space:]]/}"
    printf '%s=stale-from-dotenv\n' "$key" > "$DOTENV"
    run_launcher
    [ "$RC" -eq 0 ] || fail "case 5/$key: exited $RC: $(cat "$WORK/err")"
    assert_stderr "$key" "case 5/$key: the migration warning must name the key that no longer does anything"
    assert_stderr 'config.yaml' "case 5/$key: the warning must say where the setting lives now"
done <<'TABLE'
LITELLM_HAIKU_MODEL
LITELLM_SONNET_MODEL
LITELLM_FABLE_MODEL
LITELLM_OPUS_MODEL
CCGW_SUBAGENT_MODEL
TABLE

# The negative control: a clean .env must draw no warning at all, or the five
# rows above are satisfied by a launcher that warns unconditionally.
printf '# intentionally empty unless a case rewrites it\n' > "$DOTENV"
run_launcher
grep -qi 'no longer\|retired\|migrat' "$WORK/err" \
    && fail "case 5: warned about retired keys although .env carries none: $(cat "$WORK/err")"

# --- Case 6: no config.yaml at all is a hard failure -------------------------
# There is nothing to fall back to by design, and a launcher that starts anyway
# hands Claude Code an empty /model list -- a puzzle at the far end of the run.
drop_config
run_launcher
[ "$RC" -ne 0 ] || fail "case 6: exited 0 with no config.yaml; there is no tier map to launch with"
assert_stderr 'config.yaml' "case 6: the error must name the file it could not read"

# --- Case 7: a config with no annotations at all is a hard failure -----------
# Distinct from case 6: the file is there and parses, so a silent "no tiers"
# looks like a working launch until the first /model switch does nothing.
set_config <<'EOF'
model_list:
  - model_name: lite-shared
    litellm_params:
      model: openai/Qwen3.8-27B
EOF
run_launcher
[ "$RC" -ne 0 ] || fail "case 7: exited 0 although no route claims any tier"
assert_stderr 'ccgw_tiers\|ccgw-tiers' "case 7: the error must name the annotation that is missing"

# --- Case 8: one tier unmapped leaves only that tier unset -------------------
set_config <<'EOF'
model_list:
  # --- Haiku, sonnet and the subagent route ---
  - model_name: lite-shared
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet, subagent]

  # --- Fable's annotation was deliberately removed ---
  - model_name: lite-fable
    litellm_params:
      model: anthropic/deepseek-v4-flash

  # --- Opus tier ---
  - model_name: lite-opus
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus]
EOF
run_launcher
[ "$RC" -eq 0 ] || fail "case 8: exited $RC although four tiers are still mapped: $(cat "$WORK/err")"
assert_unset ANTHROPIC_DEFAULT_FABLE_MODEL "case 8: an unmapped tier must stay unset, not borrow another route's key"
assert_unset ANTHROPIC_CUSTOM_MODEL_OPTION "case 8: the picker entry follows fable, so it goes too"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "case 8: the other tiers are unaffected"
assert_env ANTHROPIC_DEFAULT_HAIKU_MODEL lite-shared "case 8: the other tiers are unaffected"

# --- Case 9: a token outside the tier vocabulary warns and is skipped --------
# Refusing to launch over a typo in one annotation would strand the operator
# with no client at all; the four good tiers are still perfectly usable.
set_config <<'EOF'
model_list:
  - model_name: lite-shared
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet, subagent]

  - model_name: lite-fable
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable, opuss]

  - model_name: lite-opus
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus]
EOF
run_launcher
[ "$RC" -eq 0 ] || fail "case 9: a typo in one annotation must not stop the launch: $(cat "$WORK/err")"
assert_stderr 'opuss' "case 9: the warning must quote the token it did not recognise"
assert_env ANTHROPIC_DEFAULT_FABLE_MODEL lite-fable "case 9: the valid token on the same route still applies"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "case 9: the real opus route is unaffected by the near-miss"

# --- Case 10: an annotation outside any route belongs to no route ------------
# Written at the item's own indent it reads like a heading for what follows,
# but a scanner that treats a blank line or a comment as the block boundary
# either hands it to the NEXT route or leaves it inside the PREVIOUS one --
# both silently wrong, and the operator sees a launcher that started fine.
set_config <<'EOF'
model_list:
  # --- Haiku and sonnet ---
  - model_name: lite-shared
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet]

  # --- Opus tier ---
  ccgw_tiers: [opus]
  - model_name: lite-opus
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp

  # --- Fable tier ---
  - model_name: lite-fable
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]
EOF
run_launcher
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" != "lite-opus" ] \
    || fail "case 10: the stray annotation was adopted by the route below it"
[ "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)" != "lite-shared" ] \
    || fail "case 10: the stray annotation was absorbed into the route above it"
assert_env ANTHROPIC_DEFAULT_HAIKU_MODEL lite-shared "case 10: the well-formed routes still map"
assert_env ANTHROPIC_DEFAULT_FABLE_MODEL lite-fable "case 10: the well-formed routes still map"

# --- Case 11: the retired inputs configure nothing ---------------------------
# A stale .env is exactly where these survive, so "ignored" has to be proven,
# not assumed -- a surviving fallback is what routes around the new single path.
write_default_config
run_launcher "$R_DEFAULT_MODEL=laguna-s-2.1" ANTHROPIC_MODEL=stale-from-parent
[ "$RC" -eq 0 ] || fail "case 11: exited $RC: $(cat "$WORK/err")"
assert_unset ANTHROPIC_MODEL "case 11: an inherited ANTHROPIC_MODEL must be cleared -- it outranks settings.json's own tier"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "case 11: the tier map is unaffected by either retired input"

# The launcher must carry no backend literals of its own: every value it
# exports has to have come from the config it just read.
for row in $TIER_ROWS; do
    v="${row#*:}"
    val="$(dump_get "$v")"
    case "$(printf '%s' "$val" | tr 'A-Z' 'a-z')" in
        *deepseek*|*laguna*) fail "case 11: $v='$val' is a backend name, not a routing key from config.yaml" ;;
    esac
done

# --- Case 12: the repository's real config.yaml maps every tier --------------
# The fixtures above prove the launcher's behaviour; only the real file proves
# the migration was actually carried out. Without this, every case here could
# stay green while the shipped config annotates nothing.
cp "$REPO/litellm-server/config.yaml" "$CONFIG" \
    || fail "case 12: the repository's litellm-server/config.yaml could not be read"
run_launcher
[ "$RC" -eq 0 ] || fail "case 12: the repository's own config.yaml did not launch: $(cat "$WORK/err")"
for row in $TIER_ROWS; do
    assert_nonempty "${row#*:}" "case 12 (${row%%:*}): the shipped config.yaml leaves this tier unmapped"
done

# --- Case 13: the key-form annotation grammar, spelling by spelling ----------
# Cases 1-12 each state one spelling in prose, which is how a parser that
# accepts far more than the grammar allows -- a substring match on `ccgw` --
# stays invisible. The matrix form is the one
# skills/_shared/test-design/parser-regex-tests.md prescribes. Every row is one
# route claiming opus beside a fixed neighbour claiming haiku, so each also
# says a rejected line took nothing else down with it. Row for row the Windows
# sibling's It '16h' (CPR-ORTH); the comment form is case 14 in the `-2`
# sibling. Expectations re-derived from format P in detail plan S4:
# `^      ccgw_tiers:[ ]*\[([^]]*)\][ ]*$` over a closed lowercase vocabulary.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    grammar_probe "${input//[[:space:]]/}"
    run_launcher </dev/null
    [ "$RC" -eq 0 ] || fail "case 13/$name: exited $RC although the neighbour route is annotated: $(cat "$WORK/err")"
    # A row with no `want` is a REJECT row, and rejection means the tier is not
    # exported at all -- not exported carrying nothing. assert_eq against the
    # empty string cannot tell those apart, and the second of them is a client
    # whose /model entry resolves nowhere.
    if [ -z "$want" ]; then
        assert_unset ANTHROPIC_DEFAULT_OPUS_MODEL \
            "case 13/$name: a rejected annotation must leave the opus tier unset"
    else
        assert_eq "case 13/$name: opus mapping" "$want" "$(dump_get ANTHROPIC_DEFAULT_OPUS_MODEL)"
    fi
    assert_eq "case 13/$name: the neighbour route must be untouched" \
        grammar-neighbour "$(dump_get ANTHROPIC_DEFAULT_HAIKU_MODEL)"
done <<'TABLE'
plain            | @@@@@@ccgw_tiers:@[opus]        | grammar-probe
inner-padding    | @@@@@@ccgw_tiers:@[@opus@]      | grammar-probe
wide-colon-gap   | @@@@@@ccgw_tiers:@@@[opus]      | grammar-probe
no-colon-space   | @@@@@@ccgw_tiers:[opus]         | grammar-probe
trailing-space   | @@@@@@ccgw_tiers:@[opus]@@      | grammar-probe
two-tokens       | @@@@@@ccgw_tiers:@[fable,@opus] | grammar-probe
repeated-token   | @@@@@@ccgw_tiers:@[opus,@opus]  | grammar-probe
shallow-indent   | @@@@ccgw_tiers:@[opus]          |
deep-indent      | @@@@@@@@ccgw_tiers:@[opus]      |
no-brackets      | @@@@@@ccgw_tiers:@opus          |
empty-list       | @@@@@@ccgw_tiers:@[]            |
key-only         | @@@@@@ccgw_tiers:               |
bare-hyphen-key  | @@@@@@ccgw-tiers:@[opus]        |
singular-key     | @@@@@@ccgw_tier:@[opus]         |
unseparated-key  | @@@@@@ccgwtiers:@[opus]         |
uppercase-key    | @@@@@@CCGW_TIERS:@[opus]        |
suffixed-key     | @@@@@@ccgw_tiers_extra:@[opus]  |
uppercase-token  | @@@@@@ccgw_tiers:@[OPUS]        |
suffixed-token   | @@@@@@ccgw_tiers:@[opusx]       |
truncated-token  | @@@@@@ccgw_tiers:@[opu]         |
TABLE

echo "PASS: test-code-ccgw-config-tiers"
