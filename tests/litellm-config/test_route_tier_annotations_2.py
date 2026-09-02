# Tests: litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL1, config, routing, ccgw-tiers, ssot
#
# Continuation of test_route_tier_annotations.py (issue #89), split off at the
# file-size limit. That file asks which spellings of a `ccgw_tiers` annotation
# the grammar accepts; this one asks what happens to the writing that ALMOST
# hits the grammar -- a near-miss annotation, and a route key the annotation
# cannot legally hang off. The grammar itself lives in route_tier_annotations/
# (CPR-SSOT). Rationale: docs/tuning.md.

import pytest

from route_tier_annotations import (
    LOOKALIKE_RE,
    MODEL_NAME_RE,
    annotation_violations,
    parse_routes,
    schema_violations,
    tier_owners,
)
from route_tier_annotations.probes import probe_config

# TL3 gap: whether LiteLLM itself rejects a config carrying one of these
# malformed rows, or serves it in some shape of its own. Mitigation: the cutover
# smoke run in docs/ops.md at WORKFLOW_USER_VERIFIED.


def test_the_name_contract_is_actually_expressible() -> None:
    """Anti-vacuous guard: case 10b is a no-op if MODEL_NAME_RE accepts anything."""
    assert MODEL_NAME_RE.fullmatch("lite-opus"), (
        "MODEL_NAME_RE rejects the routing names the config already serves, so "
        "every case below would pass for the wrong reason"
    )
    assert not MODEL_NAME_RE.fullmatch("two words"), (
        "MODEL_NAME_RE accepts a name with a space in it -- there is no name "
        "contract left for case 10b to test"
    )


def test_the_lookalike_detector_is_actually_loose() -> None:
    """Anti-vacuous guard, the mirror of the one above for case 10a.

    Case 10a asks whether a near miss is REPORTED; if the detector never
    recognises the line as an attempted annotation in the first place, every row
    there is decided by a regex that is itself untested. So state the looseness
    directly: case, number and separator each vary independently, and a
    detector narrow on any one axis lets that spelling through as a comment.
    """
    for spelling in ("CCGW_TIERS", "ccgw_tier", "CCGW_TIER", "ccgwtiers"):
        assert LOOKALIKE_RE.search(spelling), (
            f"LOOKALIKE_RE does not recognise {spelling!r} as an attempted "
            "annotation, so a route spelled that way is read as a comment and "
            "lands on no tier -- silently, which is what the detector exists to "
            "prevent"
        )
    # The other half: loose must not mean indiscriminate. A detector that fires
    # on ordinary prose would turn every comment in the file into a hard error.
    for innocent in (
        "      model: openai/Backend-A",
        "  # --- the fast tier lives here ---",
        "  # tiers are documented in docs/tuning.md",
        "        rpm: 100",
    ):
        assert not LOOKALIKE_RE.search(innocent), (
            f"LOOKALIKE_RE fires on {innocent!r}, so an ordinary line becomes a "
            "schema breach and the file is refused for saying nothing wrong"
        )


# A near miss is the failure the grammar matrix in the sibling file cannot
# reach. Every row there is spelled `ccgw_tiers` or `ccgw-tiers` and goes wrong
# somewhere else -- indent, placement, separator -- so the lookalike detector
# that decides whether a line is judged at all is never itself put under test.
#
# name, the line as the writer typed it, where it sits
NEAR_MISS_MATRIX = [
    ("upper-key", "      CCGW_TIERS: [opus]", "body"),
    ("upper-comment", "    # CCGW-TIERS: opus", "head"),
    ("title-case-comment", "    # Ccgw-Tiers: opus", "head"),
    ("singular-key", "      ccgw_tier: [opus]", "body"),
    ("singular-comment", "    # ccgw-tier: opus", "head"),
    ("no-separator", "      ccgwtiers: [opus]", "body"),
    ("no-separator-comment", "    # ccgwtiers: opus", "head"),
]


@pytest.mark.parametrize(
    ("name", "annotation", "placement"),
    NEAR_MISS_MATRIX,
    ids=[row[0] for row in NEAR_MISS_MATRIX],
)
def test_case10_a_near_miss_spelling_is_an_error_not_a_comment(
    name: str, annotation: str, placement: str
) -> None:
    """A line the writer meant as an annotation must never pass as a comment.

    That is the module's own stated design intent for LOOKALIKE_RE, and it is
    what makes the closed vocabulary safe to rely on: the operator who typed
    `CCGW_TIERS` sees their route land on no tier at all, and the tier they
    meant to move silently keeps whichever backend it had. Failing loudly costs
    them one edit; passing silently costs them a gateway serving the wrong
    model with a config file that reads as if it does not.
    """
    text = probe_config("P", annotation, placement)
    probe = {r.model_name: r for r in parse_routes(text)}["grammar-probe"]
    assert probe.tiers == [], (
        f"{name}: a misspelled annotation was read as a real one, so the row "
        "is not the near miss it claims to be"
    )
    got = annotation_violations(text)
    assert got, (
        f"{name}: {annotation!r} was treated as an ordinary comment -- the "
        "route it was meant to tier now maps nothing, and nothing says so"
    )


# The other half of what a route record is. The annotation grammar is checked
# line by line above; the key the annotation hangs off -- `model_name`, which is
# both the routing name LiteLLM serves and the string set-model.sh rewrites --
# is checked by nothing, and MODEL_NAME_RE sits in the module unused.
#
# name, the block-start line as the writer typed it
BAD_MODEL_NAME_MATRIX = [
    ("empty", "  - model_name:"),
    ("blank-value", "  - model_name:   "),
    ("embedded-space", "  - model_name: two words"),
    ("slash", "  - model_name: lite/opus"),
    ("quoted", '  - model_name: "lite-opus"'),
]


@pytest.mark.parametrize(
    ("name", "block_start"),
    BAD_MODEL_NAME_MATRIX,
    ids=[row[0] for row in BAD_MODEL_NAME_MATRIX],
)
def test_case10b_a_malformed_model_name_is_a_schema_breach(
    name: str, block_start: str
) -> None:
    """A route whose name is unusable must be reported, not skipped.

    Skipping it is the dangerous reading: the block's annotation is then
    attributed to the PREVIOUS route -- the same absorption case 9's `above`
    row exists to prevent -- so one unnamed route re-tiers a backend nobody
    edited. `set-model.sh` validates the candidate file against this same
    contract before committing, so a name it cannot rewrite has to be a
    refusal, not a route that quietly disappears from the lineup.
    """
    text = (
        "model_list:\n"
        "  - model_name: grammar-neighbour\n"
        "    litellm_params:\n"
        "      model: openai/Backend-N\n"
        "      ccgw_tiers: [haiku]\n"
        "\n"
        f"{block_start}\n"
        "    litellm_params:\n"
        "      model: openai/Backend-P\n"
        "      ccgw_tiers: [opus]\n"
    )
    assert tier_owners(text).get("haiku") == ["grammar-neighbour"], (
        f"{name}: the fixture's own valid route did not parse, so this case "
        "would pass on a broken file for the wrong reason"
    )
    got = schema_violations(text)
    assert got, (
        f"{name}: block start {block_start!r} was accepted or silently "
        "dropped; either way the file is not the lineup it reads as"
    )


# The third thing a `model_name` can be, after "well-formed" and "malformed": a
# token that is well-formed by this contract and ALSO a reserved literal in the
# surrounding file format. `null`, `~`, `true`, `no` and `123` are what a YAML
# reader turns into None, a boolean and an int; `[A-Za-z0-9._-]+` sees seven of
# the eight as ordinary names.
#
# name, the token as the writer typed it, whether the name contract admits it
YAML_SCALAR_NAME_MATRIX = [
    ("null-literal", "null", True),
    ("tilde-null", "~", False),
    ("true-literal", "true", True),
    ("false-literal", "false", True),
    ("yes-literal", "yes", True),
    ("no-literal", "no", True),
    ("integer", "123", True),
    ("float", "1.5", True),
]

# Nothing forces an operator to write one of these -- but `no` is a plausible
# short backend alias and `123` a plausible build number, and the point of the
# row is that all three readers (this module, the POSIX launcher, the
# PowerShell launcher) must land on the SAME answer for it. Where they diverge,
# the launcher exports a key the file does not name.


@pytest.mark.parametrize(
    ("name", "token", "admitted"),
    YAML_SCALAR_NAME_MATRIX,
    ids=[row[0] for row in YAML_SCALAR_NAME_MATRIX],
)
def test_case10c_a_yaml_looking_model_name_is_read_as_the_literal_token(
    name: str, token: str, admitted: bool
) -> None:
    """A name that reads as a YAML scalar is still just the characters typed.

    `~` is the one row outside `[A-Za-z0-9._-]+`, and it has to fail the same
    way `lite/opus` does in case 10b -- as a name the contract does not admit,
    reported rather than dropped. The other seven are admitted, and admitted
    means carried through byte for byte: a reader that normalises `no` to
    `False` or `1.5` to a float writes a routing key that no /model entry
    matches, and set-model.sh would rewrite a name that is not in the file.

    Deliberately NOT asserted: what a real YAML loader, or a running LiteLLM,
    makes of these rows. All three parsers are line matchers over the raw text
    (detail plan S4), so the contract they owe each other is that the token is
    carried through verbatim; whether LiteLLM agrees is the TL3 gap the
    cutover smoke run in docs/ops.md covers.
    """
    text = (
        "model_list:\n"
        "  - model_name: grammar-neighbour\n"
        "    litellm_params:\n"
        "      model: openai/Backend-N\n"
        "      ccgw_tiers: [haiku]\n"
        "\n"
        f"  - model_name: {token}\n"
        "    litellm_params:\n"
        "      model: openai/Backend-P\n"
        "      ccgw_tiers: [opus]\n"
    )
    assert tier_owners(text).get("haiku") == ["grammar-neighbour"], (
        f"{name}: the fixture's own valid route did not parse, so this case "
        "would pass on a broken file for the wrong reason"
    )
    assert bool(MODEL_NAME_RE.fullmatch(token)) is admitted, (
        f"{name}: MODEL_NAME_RE disagrees with this row about {token!r}; the "
        "row states the contract, so one of the two is wrong"
    )

    if not admitted:
        assert schema_violations(text), (
            f"{name}: {token!r} is outside the name contract but was accepted "
            "or silently dropped, exactly as case 10b forbids"
        )
        return

    assert not schema_violations(text), (
        f"{name}: {token!r} satisfies the name contract, so refusing the file "
        "would strand a lineup the operator is allowed to write"
    )
    names = [r.model_name for r in parse_routes(text)]
    assert token in names, (
        f"{name}: the parsed lineup is {names}, so {token!r} was rewritten on "
        "the way in -- the routing key exported would not be the one written"
    )
    assert tier_owners(text).get("opus") == [token], (
        f"{name}: opus resolved to {tier_owners(text).get('opus')!r} rather "
        f"than the literal token {token!r}"
    )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
