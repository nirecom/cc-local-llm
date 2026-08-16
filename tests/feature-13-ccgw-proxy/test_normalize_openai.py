# Tests: proxy/normalize.py
# Tags: scope:issue-specific, layer:TL1, normalize, openai-shape
#
# Scenario (issue #41 / detail plan D2): LiteLLM now performs the
# Anthropic->OpenAI conversion upstream of ccgw-proxy, so the proxy receives
# OpenAI-shaped bodies on the opus route. Every normalization rule therefore
# takes an explicit `shape` argument ("anthropic" | "openai") with NO default —
# a forgotten argument must raise TypeError rather than silently normalizing
# the wrong field set.
#
# The rules themselves (regexes, text helpers) are unchanged: only *where* the
# rule scans differs per shape. These tests pin the OpenAI traversal and the
# shape isolation in both directions (openai body untouched under
# shape="anthropic" and vice versa) — a one-sided assertion would let an
# adapter that scans both shapes unconditionally pass.
#
# TL3 gap (what this test does NOT catch):
# - Whether LiteLLM actually emits this OpenAI body shape for the opus route
#   (tool_calls, SSE deltas, multimodal parts) — only a live LiteLLM shows that.
# - Whether the normalized body is accepted by mlx_lm.server behind llama-swap.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: installer.

import copy

import pytest

from proxy import normalize

ANTHROPIC = "anthropic"
OPENAI = "openai"

_DYNAMIC_LINE = "Working directory: /Users/dev/project"
_REMINDER = "<system-reminder>hidden context</system-reminder>"


def _openai_body(system_text="You are helpful.", user_text="run tests"):
    return {
        "model": "laguna-s-2.1",
        "messages": [
            {"role": "system", "content": system_text},
            {"role": "user", "content": user_text},
        ],
    }


# ===========================================================================
# Contract: `shape` is mandatory (no default value) — D2
# ===========================================================================

@pytest.mark.parametrize(
    "func_name",
    [
        "move_dynamic_sections",
        "normalize_date",
        "strip_system_reminders",
        "sort_tools",
        "apply_all",
    ],
)
def test_shape_argument_is_mandatory(func_name):
    """Calling a rule without `shape` must fail loudly.

    A default value would make "caller forgot to pass shape" behave as
    shape="anthropic" and silently skip normalization on the OpenAI route —
    a defect with no runtime symptom.
    """
    func = getattr(normalize, func_name)
    with pytest.raises(TypeError):
        func({"messages": []})


@pytest.mark.parametrize(
    "func_name",
    [
        "move_dynamic_sections",
        "normalize_date",
        "strip_system_reminders",
        "sort_tools",
        "apply_all",
    ],
)
@pytest.mark.parametrize("shape", [ANTHROPIC, OPENAI])
def test_shape_argument_accepts_both_shapes(func_name, shape):
    """Both verdicts of the shape switch must be reachable (classifier case)."""
    func = getattr(normalize, func_name)
    out = func({"messages": [{"role": "user", "content": "hi"}]}, shape=shape)
    assert isinstance(out, dict)


# ===========================================================================
# A. move_dynamic_sections — OpenAI shape
# ===========================================================================

def test_openai_move_dynamic_sections_lifts_into_first_user_message():
    body = _openai_body(system_text=f"You are helpful.\n{_DYNAMIC_LINE}\n")

    out = normalize.move_dynamic_sections(body, shape=OPENAI)

    assert "Working directory:" not in out["messages"][0]["content"]
    assert _DYNAMIC_LINE in out["messages"][1]["content"]
    assert out["messages"][1]["content"].startswith("run tests")


def test_openai_move_dynamic_sections_does_not_mutate_input():
    body = _openai_body(system_text=f"You are helpful.\n{_DYNAMIC_LINE}\n")
    before = copy.deepcopy(body)

    normalize.move_dynamic_sections(body, shape=OPENAI)

    assert body == before


def test_openai_move_dynamic_sections_no_system_message_is_noop():
    body = {"messages": [{"role": "user", "content": "hi"}]}

    out = normalize.move_dynamic_sections(body, shape=OPENAI)

    assert out == body


def test_openai_move_dynamic_sections_no_user_message_still_cleans_system():
    body = {
        "messages": [
            {"role": "system", "content": f"stable\n{_DYNAMIC_LINE}\n"},
        ]
    }

    out = normalize.move_dynamic_sections(body, shape=OPENAI)

    assert "Working directory:" not in out["messages"][0]["content"]
    assert "stable" in out["messages"][0]["content"]


def test_openai_move_dynamic_sections_handles_list_shaped_system_content():
    body = {
        "messages": [
            {
                "role": "system",
                "content": [{"type": "text", "text": f"stable\n{_DYNAMIC_LINE}\n"}],
            },
            {"role": "user", "content": "go"},
        ]
    }

    out = normalize.move_dynamic_sections(body, shape=OPENAI)

    assert "Working directory:" not in out["messages"][0]["content"][0]["text"]
    assert _DYNAMIC_LINE in str(out["messages"][1]["content"])


def test_openai_move_dynamic_sections_multiple_system_messages():
    body = {
        "messages": [
            {"role": "system", "content": f"first\n{_DYNAMIC_LINE}\n"},
            {"role": "system", "content": "Platform: darwin\nsecond"},
            {"role": "user", "content": "go"},
        ]
    }

    out = normalize.move_dynamic_sections(body, shape=OPENAI)

    assert "Working directory:" not in out["messages"][0]["content"]
    assert "Platform:" not in out["messages"][1]["content"]
    moved = out["messages"][2]["content"]
    assert _DYNAMIC_LINE in moved
    assert "Platform: darwin" in moved


def test_openai_move_dynamic_sections_is_idempotent():
    body = _openai_body(system_text=f"You are helpful.\n{_DYNAMIC_LINE}\n")

    once = normalize.move_dynamic_sections(body, shape=OPENAI)
    twice = normalize.move_dynamic_sections(once, shape=OPENAI)

    assert once == twice


# ===========================================================================
# B. normalize_date — OpenAI shape
# ===========================================================================

def test_openai_normalize_date_collapses_timestamp():
    body = _openai_body(system_text="Today's date is 2026-08-15T09:36:00Z")

    out = normalize.normalize_date(body, shape=OPENAI)

    assert out["messages"][0]["content"] == "Today's date is 2026-08-15"


def test_openai_normalize_date_leaves_malformed_date_untouched():
    original = "Today's date is not-a-date"
    body = _openai_body(system_text=original)

    out = normalize.normalize_date(body, shape=OPENAI)

    assert out["messages"][0]["content"] == original


def test_openai_normalize_date_is_idempotent():
    body = _openai_body(system_text="Today's date is 2026-08-15T09:36:00Z")

    once = normalize.normalize_date(body, shape=OPENAI)
    twice = normalize.normalize_date(once, shape=OPENAI)

    assert once == twice


# ===========================================================================
# C. strip_system_reminders — OpenAI shape
# ===========================================================================

def test_openai_strip_reminders_from_system_and_user_messages():
    body = {
        "messages": [
            {"role": "system", "content": f"stable{_REMINDER}"},
            {"role": "user", "content": f"do it{_REMINDER}"},
        ]
    }

    out = normalize.strip_system_reminders(body, shape=OPENAI)

    assert out["messages"][0]["content"] == "stable"
    assert out["messages"][1]["content"] == "do it"


def test_openai_strip_reminders_from_assistant_and_tool_roles():
    body = {
        "messages": [
            {"role": "assistant", "content": f"answer{_REMINDER}"},
            {"role": "tool", "tool_call_id": "c1", "content": f"result{_REMINDER}"},
        ]
    }

    out = normalize.strip_system_reminders(body, shape=OPENAI)

    assert out["messages"][0]["content"] == "answer"
    assert out["messages"][1]["content"] == "result"
    # Non-content keys must survive untouched.
    assert out["messages"][1]["tool_call_id"] == "c1"


def test_openai_strip_reminders_from_list_shaped_content_parts():
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": f"part one{_REMINDER}"},
                    {"type": "text", "text": "part two"},
                ],
            }
        ]
    }

    out = normalize.strip_system_reminders(body, shape=OPENAI)

    assert out["messages"][0]["content"][0]["text"] == "part one"
    assert out["messages"][0]["content"][1]["text"] == "part two"


def test_openai_strip_reminders_spanning_newlines():
    body = _openai_body(
        system_text="a<system-reminder>line1\nline2</system-reminder>b"
    )

    out = normalize.strip_system_reminders(body, shape=OPENAI)

    assert out["messages"][0]["content"] == "ab"


def test_openai_strip_reminders_is_idempotent():
    body = _openai_body(system_text=f"stable{_REMINDER}")

    once = normalize.strip_system_reminders(body, shape=OPENAI)
    twice = normalize.strip_system_reminders(once, shape=OPENAI)

    assert once == twice


# ===========================================================================
# D. sort_tools — OpenAI function shape
# ===========================================================================

def test_openai_sort_tools_sorts_by_function_name():
    body = {
        "messages": [],
        "tools": [
            {"type": "function", "function": {"name": "Write"}},
            {"type": "function", "function": {"name": "Bash"}},
            {"type": "function", "function": {"name": "Read"}},
        ],
    }

    out = normalize.sort_tools(body, shape=OPENAI)

    assert [t["function"]["name"] for t in out["tools"]] == ["Bash", "Read", "Write"]


def test_openai_sort_tools_missing_function_sorts_as_empty_name():
    body = {
        "messages": [],
        "tools": [
            {"type": "function", "function": {"name": "Bash"}},
            {"type": "function"},
        ],
    }

    out = normalize.sort_tools(body, shape=OPENAI)

    # Missing name -> "" sorts first; the point is that it does not raise.
    assert out["tools"][0] == {"type": "function"}
    assert out["tools"][1]["function"]["name"] == "Bash"


def test_openai_sort_tools_no_tools_key_is_noop():
    body = _openai_body()

    out = normalize.sort_tools(body, shape=OPENAI)

    assert "tools" not in out
    assert out == body


def test_openai_sort_tools_is_idempotent():
    body = {
        "messages": [],
        "tools": [
            {"type": "function", "function": {"name": "Write"}},
            {"type": "function", "function": {"name": "Bash"}},
        ],
    }

    once = normalize.sort_tools(body, shape=OPENAI)
    twice = normalize.sort_tools(once, shape=OPENAI)

    assert once == twice


# ===========================================================================
# E. apply_all — OpenAI shape, all four rules compose
# ===========================================================================

def test_openai_apply_all_composes_every_rule():
    body = {
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are helpful.\n"
                    f"{_DYNAMIC_LINE}\n"
                    "Today's date is 2026-08-15T09:36:00Z\n"
                    f"{_REMINDER}\n"
                ),
            },
            {"role": "user", "content": "run tests"},
        ],
        "tools": [
            {"type": "function", "function": {"name": "Write"}},
            {"type": "function", "function": {"name": "Bash"}},
        ],
    }

    out = normalize.apply_all(body, shape=OPENAI)

    system = out["messages"][0]["content"]
    assert "Working directory:" not in system          # A
    assert "Today's date is 2026-08-15" in system      # B
    assert "T09:36:00Z" not in system                  # B
    assert "system-reminder" not in system             # C
    assert "hidden context" not in system              # C
    assert [t["function"]["name"] for t in out["tools"]] == ["Bash", "Write"]  # D
    assert _DYNAMIC_LINE in out["messages"][1]["content"]


def test_openai_apply_all_is_idempotent():
    body = {
        "messages": [
            {"role": "system", "content": f"s\n{_DYNAMIC_LINE}\n{_REMINDER}"},
            {"role": "user", "content": "u"},
        ],
        "tools": [
            {"type": "function", "function": {"name": "Write"}},
            {"type": "function", "function": {"name": "Bash"}},
        ],
    }

    once = normalize.apply_all(body, shape=OPENAI)
    twice = normalize.apply_all(once, shape=OPENAI)

    assert once == twice


def test_openai_apply_all_on_empty_body_returns_empty():
    assert normalize.apply_all({}, shape=OPENAI) == {}


# ===========================================================================
# F. Malformed / edge shapes must not raise
# ===========================================================================

@pytest.mark.parametrize(
    "body",
    [
        {"messages": "not-a-list"},
        {"messages": None},
        {"messages": [None, 42, "text"]},
        {"messages": [{"role": "system"}]},              # no content key
        {"messages": [{"role": "system", "content": 7}]},  # non-str content
        {"messages": [{"content": "roleless"}]},
        {"tools": "not-a-list"},
        {},
    ],
    ids=[
        "messages-str", "messages-none", "messages-nondict-entries",
        "system-without-content", "system-content-int", "message-without-role",
        "tools-str", "empty-body",
    ],
)
def test_openai_apply_all_tolerates_malformed_bodies(body):
    out = normalize.apply_all(copy.deepcopy(body), shape=OPENAI)
    assert isinstance(out, dict)


def test_openai_sort_tools_non_dict_tool_entry_does_not_raise():
    body = {"tools": [{"type": "function", "function": {"name": "Bash"}}, "bogus"]}

    out = normalize.sort_tools(body, shape=OPENAI)

    assert len(out["tools"]) == 2


# ===========================================================================
# G. Shape isolation — both directions (classifier: cover both verdicts)
# ===========================================================================

def test_openai_body_is_untouched_under_anthropic_shape():
    """An OpenAI body normalized as "anthropic" must come back unchanged.

    Anthropic traversal reads body["system"] and Anthropic-shaped message
    content. Applying it to an OpenAI body must be a no-op — if the adapter
    scans both layouts unconditionally, this fails and the shape switch is
    proven decorative.
    """
    body = {
        "messages": [
            {"role": "system", "content": f"s\n{_DYNAMIC_LINE}\n{_REMINDER}"},
            {"role": "user", "content": "u"},
        ],
        "tools": [
            {"type": "function", "function": {"name": "Write"}},
            {"type": "function", "function": {"name": "Bash"}},
        ],
    }
    expected = copy.deepcopy(body)

    out = normalize.move_dynamic_sections(body, shape=ANTHROPIC)
    assert out["messages"][0]["content"] == expected["messages"][0]["content"]

    out = normalize.normalize_date(body, shape=ANTHROPIC)
    assert out["messages"][0]["content"] == expected["messages"][0]["content"]

    out = normalize.sort_tools(body, shape=ANTHROPIC)
    # Anthropic sort key is t["name"], absent here -> "" for every entry, so the
    # original order is preserved (sorted() is stable).
    assert [t["function"]["name"] for t in out["tools"]] == ["Write", "Bash"]


def test_anthropic_body_is_untouched_under_openai_shape():
    """The symmetric direction: an Anthropic body normalized as "openai"."""
    body = {
        "system": f"s\n{_DYNAMIC_LINE}\nToday's date is 2026-08-15T09:36:00Z",
        "messages": [{"role": "user", "content": "u"}],
        "tools": [{"name": "Write"}, {"name": "Bash"}],
    }
    expected = copy.deepcopy(body)

    out = normalize.move_dynamic_sections(body, shape=OPENAI)
    assert out["system"] == expected["system"]

    out = normalize.normalize_date(body, shape=OPENAI)
    assert out["system"] == expected["system"]

    out = normalize.sort_tools(body, shape=OPENAI)
    # OpenAI sort key is t["function"]["name"], absent here -> "" for every
    # entry, so the Anthropic tool order is left as-is.
    assert [t["name"] for t in out["tools"]] == ["Write", "Bash"]


def test_anthropic_shape_still_normalizes_anthropic_body():
    """Positive control for the isolation pair above.

    Without this, the two "untouched" tests would also pass against a rule set
    that does nothing at all for any shape.
    """
    body = {
        "system": f"s\n{_DYNAMIC_LINE}\n{_REMINDER}",
        "messages": [{"role": "user", "content": "u"}],
        "tools": [{"name": "Write"}, {"name": "Bash"}],
    }

    out = normalize.apply_all(body, shape=ANTHROPIC)

    assert "Working directory:" not in out["system"]
    assert "system-reminder" not in out["system"]
    assert _DYNAMIC_LINE in out["messages"][0]["content"]
    assert [t["name"] for t in out["tools"]] == ["Bash", "Write"]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
