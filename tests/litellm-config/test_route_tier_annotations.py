# Tests: litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL1, config, routing, ccgw-tiers, ssot
#
# Scenario (issue #89): the five Claude Code routing keys (haiku, sonnet,
# fable, opus, subagent) used to live in a per-machine .env each host edited by
# hand, so a backend swap on one machine left the other addressing a name the
# gateway no longer serves. They move into the file that already knows which
# backend each route is, as a `ccgw_tiers` annotation on the route record.
# The grammar itself lives in route_tier_annotations/ (CPR-SSOT); this file is
# cases only. Rationale: docs/tuning.md.

import pytest

from route_tier_annotations import (
    BLOCK_START_RE,
    CONFIG_PATH,
    ENV_REF_PREFIX,
    MODEL_NAME_RE,
    TIER_VOCAB,
    annotation_violations,
    config_text,
    formats_used,
    parse_routes,
    repo_root,
    schema_violations,
    tier_owners,
)
from route_tier_annotations.probes import probe_config

# TL3 gap: whether LiteLLM tolerates an unknown `ccgw_tiers` key on a route,
# and whether the annotated route really answers for that tier end to end.
# Mitigation: the cutover smoke run in docs/ops.md at WORKFLOW_USER_VERIFIED.


def test_config_is_present_and_parses_into_routes():
    """Anti-vacuous guard: every case below is a no-op on an unparsed file."""
    assert (repo_root() / CONFIG_PATH).is_file(), f"{CONFIG_PATH} not found"
    routes = parse_routes(config_text())
    assert routes, (
        f"no `  - model_name:` block parsed out of {CONFIG_PATH} -- the block "
        f"regex {BLOCK_START_RE.pattern!r} has drifted from the file's actual "
        "shape, so every case below would pass while checking nothing"
    )


def test_case1_model_name_is_a_literal_routing_key():
    """`model_name` is the value the client sends, so it must be in the file.

    While it was `os.environ/LITELLM_OPUS_MODEL`, the name a client had to send
    was knowable only by reading a machine's .env -- which is exactly how the
    two hosts drifted apart.
    """
    bad: list[str] = []
    for route in parse_routes(config_text()):
        if route.model_name.startswith(ENV_REF_PREFIX):
            bad.append(
                f"line {route.start + 1}: model_name is still {route.model_name!r} "
                "-- the routing key must be a literal now"
            )
        elif not MODEL_NAME_RE.match(route.model_name):
            bad.append(
                f"line {route.start + 1}: model_name {route.model_name!r} is not a "
                f"plain routing key (expected {MODEL_NAME_RE.pattern})"
            )
    assert not bad, "\n".join(bad)


def test_case2_model_name_is_unique_across_routes():
    """Two routes under one name is a silent 50/50 split, not an error.

    LiteLLM's router accepts the duplicate and load-balances between them, so
    `/model opus` would answer from a different backend on alternate requests.
    """
    seen: dict[str, int] = {}
    dupes: list[str] = []
    for route in parse_routes(config_text()):
        if route.model_name in seen:
            dupes.append(
                f"{route.model_name!r} at lines {seen[route.model_name] + 1} and "
                f"{route.start + 1}"
            )
        seen[route.model_name] = route.start
    assert not dupes, (
        "duplicate model_name -- LiteLLM would load-balance between the two "
        f"backends instead of failing: {'; '.join(dupes)}"
    )


def test_case2b_duplicate_model_name_is_actually_detectable():
    """The negative half of case 2: the detector must see a real collision."""
    fixture = (
        "model_list:\n"
        "  - model_name: shared-key\n"
        "    litellm_params:\n"
        "      model: openai/a\n"
        "  - model_name: shared-key\n"
        "    litellm_params:\n"
        "      model: openai/b\n"
    )
    names = [r.model_name for r in parse_routes(fixture)]
    assert len(names) == 2, f"the fixture must parse as two routes, got {names}"
    assert len(set(names)) < len(names), (
        "the collision detector cannot see two routes sharing a model_name, so "
        "the real-file case above is vacuous"
    )


def test_case3_annotation_grammar_and_placement_hold():
    violations = annotation_violations(config_text())
    assert not violations, "\n".join(violations)


def test_case3b_block_sequence_form_is_rejected():
    """A YAML block sequence is the natural thing to write and is NOT accepted.

    The launchers parse this file with awk/regex, not a YAML library -- they
    run before any Python is available -- so a multi-line sequence would read
    as an annotation with no items: an empty tier map that looks correct.
    """
    fixture = (
        "model_list:\n"
        "  - model_name: route-a\n"
        "    litellm_params:\n"
        "      model: openai/a\n"
        "      ccgw_tiers:\n"
        "        - haiku\n"
        "        - sonnet\n"
    )
    violations = annotation_violations(fixture)
    assert violations, (
        "a block-sequence `ccgw_tiers:` was accepted silently; it must be a "
        "hard error, because the shell-side parsers read no items from it"
    )


def test_case4_no_tier_is_claimed_by_two_routes():
    conflicts = {
        tier: owners
        for tier, owners in tier_owners(config_text()).items()
        if len(owners) > 1
    }
    assert not conflicts, (
        "a tier maps to more than one route, so which backend answers for it "
        f"depends on parse order: {conflicts}"
    )


def test_case5_at_least_one_tier_is_mapped():
    """Anti-vacuous: cases 1-4 all pass on a file carrying no annotation."""
    owners = tier_owners(config_text())
    assert owners, (
        f"{CONFIG_PATH} maps no tier at all -- the launchers would derive an "
        "empty routing table and every request would land on whatever the "
        "gateway's default route happens to be"
    )


def test_case6_every_tier_in_the_vocabulary_is_mapped():
    """The current lineup pin -- edit this case, not case 4, when a tier retires."""
    owners = tier_owners(config_text())
    missing = [t for t in TIER_VOCAB if t not in owners]
    assert not missing, (
        f"{CONFIG_PATH} maps no route for {missing} -- that tier's child "
        "variable would be left unset and Claude Code would route it at the "
        "gateway default. If the tier was retired deliberately, edit this case."
    )


def test_case7_only_one_annotation_per_route():
    bad = [
        f"{r.model_name!r} (block at line {r.start + 1}) carries "
        f"{len(r.annotations)} annotations at lines "
        f"{[n + 1 for n, _f, _p in r.annotations]}"
        for r in parse_routes(config_text())
        if len(r.annotations) > 1
    ]
    assert not bad, (
        "a second annotation on one route makes the effective tier list depend "
        f"on which one the reader stops at: {'; '.join(bad)}"
    )


def test_case7b_the_two_formats_are_never_mixed():
    """One file, one convention: a reader supporting only P must not go quiet."""
    used = formats_used(config_text())
    assert len(used) <= 1, (
        f"{CONFIG_PATH} mixes annotation formats {sorted(used)} -- pick one, so "
        "a consumer that reads only the preferred form cannot silently drop "
        "half the routing table"
    )


def test_case8_an_annotation_above_the_block_start_is_rejected():
    """The C2 regression as a fixture: one line too early is not a syntax error.

    Written where a human naturally writes a heading -- above the item -- the
    comment form lands inside the PREVIOUS route's block and re-tiers that
    backend instead. The detector must reject it rather than adopt it.
    """
    fixture = (
        "model_list:\n"
        "  - model_name: route-a\n"
        "    # ccgw-tiers: haiku sonnet\n"
        "    litellm_params:\n"
        "      model: openai/a\n"
        "\n"
        "  # --- second route ---\n"
        "    # ccgw-tiers: opus\n"
        "  - model_name: route-b\n"
        "    litellm_params:\n"
        "      model: openai/b\n"
    )
    routes = parse_routes(fixture)
    by_name = {r.model_name: r for r in routes}
    assert set(by_name) == {"route-a", "route-b"}, f"fixture parsed as {list(by_name)}"

    violations = annotation_violations(fixture)
    assert any("line 8" in v for v in violations), (
        "the annotation written above `- model_name: route-b` was not rejected; "
        f"violations reported: {violations}"
    )
    assert "opus" not in by_name["route-b"].tiers, (
        "an out-of-block annotation must not be adopted by the route it was "
        "meant for -- it is not inside that route's record"
    )
    assert "opus" not in by_name["route-a"].tiers, (
        "worse: the out-of-block annotation was absorbed by the PREVIOUS route, "
        "which is the silent misrouting this case exists to catch"
    )


# name, form, annotation line, placement, tiers the probe ends up with, rejected
GRAMMAR_MATRIX = [
    ("p-single", "P", "      ccgw_tiers: [opus]", "body", ["opus"], False),
    ("p-pair", "P", "      ccgw_tiers: [opus, subagent]", "body", ["opus", "subagent"], False),
    ("p-tight-comma", "P", "      ccgw_tiers: [opus,subagent]", "body", ["opus", "subagent"], False),
    ("p-at-head", "P", "      ccgw_tiers: [opus]", "head", ["opus"], False),
    ("p-empty", "P", "      ccgw_tiers: []", "body", [], False),
    ("p-space-separated", "P", "      ccgw_tiers: [opus subagent]", "body", ["opus subagent"], True),
    ("p-duplicate-token", "P", "      ccgw_tiers: [opus, opus]", "body", ["opus", "opus"], True),
    ("p-garbage-token", "P", "      ccgw_tiers: [opus, banana]", "body", ["opus", "banana"], True),
    ("p-shallow-indent", "P", "  ccgw_tiers: [opus]", "body", [], True),
    ("p-above-block", "P", "      ccgw_tiers: [opus]", "above", [], True),
    ("f-single", "F", "    # ccgw-tiers: opus", "head", ["opus"], False),
    ("f-pair", "F", "    # ccgw-tiers: opus subagent", "head", ["opus", "subagent"], False),
    ("f-comma-separated", "F", "    # ccgw-tiers: opus, subagent", "head", ["opus,", "subagent"], True),
    ("f-in-body", "F", "    # ccgw-tiers: opus", "body", [], True),
    ("f-key-only", "F", "    # ccgw-tiers:", "head", [], True),
    ("f-shallow-indent", "F", "  # ccgw-tiers: opus", "head", [], True),
    ("f-deep-indent", "F", "      # ccgw-tiers: opus", "head", [], True),
]


@pytest.mark.parametrize(
    ("name", "form", "annotation", "placement", "tiers", "rejected"),
    GRAMMAR_MATRIX,
    ids=[row[0] for row in GRAMMAR_MATRIX],
)
def test_case9_the_two_forms_keep_their_own_separators(
    name: str,
    form: str,
    annotation: str,
    placement: str,
    tiers: list[str],
    rejected: bool,
) -> None:
    """Row for row the shell and PowerShell grammar matrices (CPR-ORTH).

    P is comma-separated and may sit anywhere in the block; F is
    whitespace-separated and is read only on the line after the block start.
    Each written in the other's spelling has to be rejected, not quietly
    adopted -- a validator looser than the launchers is worse than none, since
    it green-lights a file they will read differently.
    """
    text = probe_config(form, annotation, placement)
    routes = {r.model_name: r for r in parse_routes(text)}
    assert set(routes) == {"grammar-neighbour", "grammar-probe"}, (
        f"{name}: the probe fixture parsed as {sorted(routes)}"
    )
    assert routes["grammar-probe"].tiers == tiers, (
        f"{name}: the probe route resolved to {routes['grammar-probe'].tiers}, "
        f"expected {tiers} -- annotation {annotation!r} at {placement}"
    )
    got = schema_violations(text)
    assert bool(got) == rejected, (
        f"{name}: expected {'a rejection' if rejected else 'no violation'} for "
        f"{annotation!r} at {placement}, got {got}"
    )


PURE_FORM_FILES = {
    "P": (
        "model_list:\n"
        "  # --- shared backend ---\n"
        "  - model_name: lite-shared\n"
        "    litellm_params:\n"
        "      model: openai/Qwen3.8-27B\n"
        "      ccgw_tiers: [haiku, sonnet, subagent]\n"
        "\n"
        "  # --- fable ---\n"
        "  - model_name: lite-fable\n"
        "    litellm_params:\n"
        "      model: anthropic/deepseek-v4-flash\n"
        "      ccgw_tiers: [fable]\n"
        "\n"
        "  # --- opus ---\n"
        "  - model_name: lite-opus\n"
        "    litellm_params:\n"
        "      model: openai/mtp\n"
        "      ccgw_tiers: [opus]\n"
    ),
    "F": (
        "model_list:\n"
        "  # --- shared backend ---\n"
        "  - model_name: lite-shared\n"
        "    # ccgw-tiers: haiku sonnet subagent\n"
        "    litellm_params:\n"
        "      model: openai/Qwen3.8-27B\n"
        "\n"
        "  # --- fable ---\n"
        "  - model_name: lite-fable\n"
        "    # ccgw-tiers: fable\n"
        "    litellm_params:\n"
        "      model: anthropic/deepseek-v4-flash\n"
        "\n"
        "  # --- opus ---\n"
        "  - model_name: lite-opus\n"
        "    # ccgw-tiers: opus\n"
        "    litellm_params:\n"
        "      model: openai/mtp\n"
    ),
}


@pytest.mark.parametrize("form", sorted(PURE_FORM_FILES), ids=sorted(PURE_FORM_FILES))
def test_case9b_either_form_alone_maps_the_whole_lineup(form: str) -> None:
    """Both forms are supported spellings, so both must carry a whole file.

    Format F exists for the operator whose YAML validator rejects an unknown
    key inside litellm_params; if only P ever validated cleanly, that fallback
    would be a form nothing accepts.
    """
    text = PURE_FORM_FILES[form]
    assert formats_used(text) == {form}, (
        f"the pure-{form} fixture parsed as {formats_used(text)}"
    )
    assert not schema_violations(text), (
        f"a file written entirely in format {form} was rejected: "
        f"{schema_violations(text)}"
    )
    owners = tier_owners(text)
    assert sorted(owners) == sorted(TIER_VOCAB), (
        f"format {form} mapped {sorted(owners)}, not the whole vocabulary"
    )
    assert owners["haiku"] == owners["sonnet"] == owners["subagent"], (
        f"format {form} split the shared route: {owners}"
    )


def test_case9c_a_mixed_file_is_actually_detectable() -> None:
    """The negative half of case 7b, which is vacuous on a single-form file."""
    mixed = (
        "model_list:\n"
        "  - model_name: route-a\n"
        "    litellm_params:\n"
        "      model: openai/a\n"
        "      ccgw_tiers: [haiku]\n"
        "\n"
        "  - model_name: route-b\n"
        "    # ccgw-tiers: opus\n"
        "    litellm_params:\n"
        "      model: openai/b\n"
    )
    assert formats_used(mixed) == {"P", "F"}, (
        "the mixing detector cannot see one file using both forms, so the "
        f"real-file case is vacuous: {formats_used(mixed)}"
    )
    assert any("mixes annotation formats" in v for v in schema_violations(mixed)), (
        f"a P/F mix was not reported as a schema breach: {schema_violations(mixed)}"
    )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
