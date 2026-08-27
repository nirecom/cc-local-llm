# Tests: proxy/normalize.py
# Tags: scope:issue-specific
#
# Scenario: LiteLLM forwards /effort as reasoning_effort; Qwen3.8's template
# rejects values outside xhigh/medium/low, so clamp_reasoning_effort (rule E)
# maps high/max->xhigh, minimal->low, for the Qwen3.8 family only.
# TL3 gap: wire-level LiteLLM emission, server.py's openai-shape routing, and
# Qwen3.8's actual "xhigh" acceptance are not asserted here (checked at WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: installer).

import copy

import pytest

from proxy import normalize

ANTHROPIC = "anthropic"
OPENAI = "openai"


# ===========================================================================
# proxy/normalize.py — clamp_reasoning_effort mapping (table-driven)
# ===========================================================================
# Each case: (case_id, model, reasoning_effort, expected_reasoning_effort).
# All run under shape="openai" — the only shape this rule acts on.

_MAPPING_CASES = [
    # --- Normal: Qwen3.8-family models, effort gets clamped -----------------
    ("qwen38_flash_next_high_to_xhigh", "qwen3.8-flash-next-3bit-mtp", "high", "xhigh"),
    ("qwen38_flash_next_max_to_xhigh", "qwen3.8-flash-next-3bit-mtp", "max", "xhigh"),
    ("qwen38_flash_next_minimal_to_low", "qwen3.8-flash-next-3bit-mtp", "minimal", "low"),
    ("qwen38_27b_8bit_high_to_xhigh", "qwen3.8-27b-8bit", "high", "xhigh"),
    ("qwen38_27b_uncensored_max_to_xhigh", "qwen3.8-27b-uncensored-4bit", "max", "xhigh"),
    ("qwen38_27b_mtp_minimal_to_low", "qwen3.8-27b-4bit-mtp", "minimal", "low"),
    # --- Pass-through: already-accepted values on a matching model ----------
    # (classifier counter-verdict: matching the model prefix is not enough by
    # itself, the effort string must also be a key of the mapping)
    ("matching_model_xhigh_passthrough", "qwen3.8-flash-next-3bit-mtp", "xhigh", "xhigh"),
    ("matching_model_medium_passthrough", "qwen3.8-flash-next-3bit-mtp", "medium", "medium"),
    ("matching_model_low_passthrough", "qwen3.8-flash-next-3bit-mtp", "low", "low"),
    ("matching_model_none_passthrough", "qwen3.8-flash-next-3bit-mtp", "none", "none"),
    # --- Pass-through: non-Qwen3.8 models (CPR-ORTH counter-verdict) --------
    # Guards against clobbering backends with their own effort semantics.
    ("laguna_high_untouched", "laguna-s-2.1", "high", "high"),
    ("ds4_high_untouched", "deepseek-v4-flash", "high", "high"),
    ("ds4_max_untouched", "deepseek-v4-flash", "max", "max"),
    # These two start with "qwen3" but are NOT the qwen3.8 family. A
    # startswith("qwen3") bug or a substring `in` bug must fail here.
    ("qwen3_coder_high_untouched", "qwen3-coder-next-80b-a3b", "high", "high"),
    ("qwen3_next_thinking_max_untouched", "qwen3-next-80b-a3b-thinking", "max", "max"),
    # --- Prefix boundary ------------------------------------------------------
    ("substring_not_prefix_untouched", "my-qwen3.8-clone", "high", "high"),
    ("exact_prefix_match_converts", "qwen3.8", "high", "xhigh"),
]


@pytest.mark.parametrize(
    "case_id, model, effort, expected",
    _MAPPING_CASES,
    ids=[c[0] for c in _MAPPING_CASES],
)
def test_40_clamp_reasoning_effort_mapping(case_id, model, effort, expected):
    body = {"model": model, "reasoning_effort": effort}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == expected, (
        f"{case_id}: model={model!r} effort={effort!r} "
        f"expected={expected!r} got={out['reasoning_effort']!r}"
    )


def test_40a_clamp_reasoning_effort_preserves_other_body_keys():
    body = {
        "model": "qwen3.8-flash-next-3bit-mtp",
        "reasoning_effort": "high",
        "messages": [{"role": "user", "content": "hi"}],
        "tools": [{"type": "function", "function": {"name": "Bash"}}],
    }

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == "xhigh"
    assert out["messages"] == body["messages"]
    assert out["tools"] == body["tools"]


# ===========================================================================
# proxy/normalize.py — clamp_reasoning_effort shape branch
# ===========================================================================
# Acts only when shape == "openai"; any other shape (e.g. "anthropic") must
# leave reasoning_effort untouched, even on a matching model+effort pair.

@pytest.mark.parametrize("effort", ["high", "max"], ids=["high", "max"])
def test_41_clamp_reasoning_effort_noop_under_anthropic_shape(effort):
    body = {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": effort}

    out = normalize.clamp_reasoning_effort(body, shape=ANTHROPIC)

    assert out["reasoning_effort"] == effort


def test_41a_clamp_reasoning_effort_shape_is_mandatory():
    """No default on `shape` — same contract as the other four rules.

    A default would let a forgotten argument silently skip clamping (or
    silently apply it) with no runtime symptom.
    """
    with pytest.raises(TypeError):
        normalize.clamp_reasoning_effort({"model": "qwen3.8", "reasoning_effort": "high"})


# ===========================================================================
# proxy/normalize.py — clamp_reasoning_effort error / edge cases
# ===========================================================================
# None of these may raise; each must pass the body through unchanged.

def test_42_clamp_reasoning_effort_missing_key_is_noop():
    body = {"model": "qwen3.8-flash-next-3bit-mtp"}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out == body


def test_43_clamp_missing_model_key_is_noop():
    body = {"reasoning_effort": "high"}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out == body


def test_44_clamp_empty_body_is_noop():
    out = normalize.clamp_reasoning_effort({}, shape=OPENAI)

    assert out == {}


def test_45_clamp_reasoning_effort_none_is_noop():
    body = {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": None}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] is None


def test_46_clamp_reasoning_effort_int_is_noop():
    body = {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": 3}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == 3


def test_47_clamp_model_none_is_noop_no_typeerror():
    body = {"model": None, "reasoning_effort": "high"}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == "high"


@pytest.mark.parametrize(
    "model_value", [123, {"nested": "dict"}, ["a", "list"]],
    ids=["int", "dict", "list"],
)
def test_48_clamp_model_non_str_is_noop_no_typeerror(model_value):
    body = {"model": model_value, "reasoning_effort": "high"}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == "high"
    assert out["model"] == model_value


def test_49_clamp_unknown_effort_string_is_noop():
    # The rule is a mapping (only its keys are rewritten), not a
    # whitelist-reject of everything outside a known-good set.
    body = {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": "banana"}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == "banana"


def test_50_clamp_uppercase_effort_not_converted():
    # Documents actual behavior per spec: the mapping lookup is an exact-key
    # lookup ({'high': ..., 'max': ..., 'minimal': ...}), so "HIGH" is not a
    # key and passes through unchanged. Case-insensitivity is deliberately
    # out of scope: LiteLLM always emits lowercase reasoning_effort values.
    body = {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": "HIGH"}

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert out["reasoning_effort"] == "HIGH"


# ===========================================================================
# proxy/normalize.py — non-mutation (same contract as the other four rules)
# ===========================================================================

@pytest.mark.parametrize(
    "body",
    [
        {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": "high"},
        {"model": "laguna-s-2.1", "reasoning_effort": "high"},
    ],
    ids=["converting_case", "passthrough_case"],
)
def test_51_clamp_reasoning_effort_does_not_mutate_input(body):
    snapshot = copy.deepcopy(body)

    out = normalize.clamp_reasoning_effort(body, shape=OPENAI)

    assert body == snapshot
    # deepcopy-first contract: the returned dict is a distinct object even
    # when its contents end up unchanged (matches sort_tools' no-op path).
    assert out is not body


# ===========================================================================
# proxy/normalize.py — idempotency
# ===========================================================================

def test_52_clamp_reasoning_effort_is_idempotent():
    body = {"model": "qwen3.8-flash-next-3bit-mtp", "reasoning_effort": "high"}

    once = normalize.clamp_reasoning_effort(body, shape=OPENAI)
    twice = normalize.clamp_reasoning_effort(once, shape=OPENAI)

    assert once == twice
    assert twice["reasoning_effort"] == "xhigh"


# ===========================================================================
# proxy/normalize.py — apply_all wiring (E appended after D)
# ===========================================================================

def _wiring_body():
    return {
        "model": "qwen3.8-flash-next-3bit-mtp",
        "reasoning_effort": "high",
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are helpful.\n"
                    "<system-reminder>hidden</system-reminder>\n"
                ),
            },
            {"role": "user", "content": "run tests"},
        ],
        "tools": [
            {"type": "function", "function": {"name": "Write"}},
            {"type": "function", "function": {"name": "Bash"}},
        ],
    }


def test_53_apply_all_openai_clamps_and_keeps_earlier_rules():
    body = _wiring_body()

    out = normalize.apply_all(body, shape=OPENAI)

    # E: reasoning_effort clamped for the Qwen3.8 family.
    assert out["reasoning_effort"] == "xhigh"
    # A regression that drops an earlier rule while adding E must still be
    # caught here: C (system-reminder stripped) and D (tools sorted).
    assert "system-reminder" not in out["messages"][0]["content"]
    assert [t["function"]["name"] for t in out["tools"]] == ["Bash", "Write"]


def test_54_apply_all_anthropic_leaves_reasoning_effort_unchanged():
    body = {
        "system": "You are helpful.",
        "reasoning_effort": "high",
        "model": "qwen3.8-flash-next-3bit-mtp",
        "messages": [{"role": "user", "content": "run"}],
    }

    out = normalize.apply_all(body, shape=ANTHROPIC)

    assert out["reasoning_effort"] == "high"


def test_55_apply_all_is_idempotent_with_clamp_openai():
    body = _wiring_body()

    once = normalize.apply_all(body, shape=OPENAI)
    twice = normalize.apply_all(once, shape=OPENAI)

    assert once == twice
    assert twice["reasoning_effort"] == "xhigh"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
