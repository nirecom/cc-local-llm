# Tests: proxy/normalize.py
# Tags: scope:issue-specific
#
# L3 gap (what this test suite does NOT catch — explicitly deferred):
# - Real asyncio TLS handshake behavior with mkcert certificates
# - Actual SSE streaming under CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
# - End-to-end chunked transfer between real client and upstream ds4 server
# - Proxy handler integration (server.py not yet written; auth→normalize→
#     forward→sanitize pipeline tested post-/write-code as L2 integration tests)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required

import copy

import pytest

from proxy import normalize


# ===========================================================================
# proxy/normalize.py — sort_tools
# ===========================================================================

def test_13_sort_tools_mixed_order():
    body = {
        "tools": [
            {"name": "Write"},
            {"name": "Bash"},
            {"name": "Read"},
        ]
    }
    out = normalize.sort_tools(body)
    assert [t["name"] for t in out["tools"]] == ["Bash", "Read", "Write"]


def test_14_sort_tools_no_tools_key():
    body = {"system": "hi"}
    out = normalize.sort_tools(body)
    assert out == body


def test_15_sort_tools_idempotent():
    body = {
        "tools": [
            {"name": "Write"},
            {"name": "Bash"},
            {"name": "Read"},
        ]
    }
    once = normalize.sort_tools(body)
    twice = normalize.sort_tools(once)
    assert once == twice


# --- C8: sort_tools edge cases ---------------------------------------------

def test_15a_sort_tools_empty_list():
    body = {"tools": []}
    out = normalize.sort_tools(body)
    assert out["tools"] == []


def test_15b_sort_tools_duplicate_names_stable():
    # Duplicate names: both appear; Python's sorted() is stable, so the two
    # "A" entries keep their original relative order (id 1 before id 2).
    body = {
        "tools": [
            {"name": "A", "id": 1},
            {"name": "A", "id": 2},
            {"name": "B", "id": 3},
        ]
    }
    out = normalize.sort_tools(body)
    assert [(t["name"], t["id"]) for t in out["tools"]] == [
        ("A", 1),
        ("A", 2),
        ("B", 3),
    ]


def test_15c_sort_tools_missing_name_key():
    # Actual behavior: t.get('name', '') treats a missing name as the empty
    # string, which sorts BEFORE any real name. No crash; the tool is kept.
    body = {
        "tools": [
            {"name": "Write"},
            {"noname": "x"},
            {"name": "Bash"},
        ]
    }
    out = normalize.sort_tools(body)
    names = [t.get("name") for t in out["tools"]]
    assert names == [None, "Bash", "Write"]
    # The nameless tool is preserved intact, not dropped.
    assert {"noname": "x"} in out["tools"]


def test_15d_sort_tools_explicit_none_name():
    # When a tool has {"name": None}, t.get('name', '') returns None (the stored
    # value, not the default ''), because the key IS present. Python 3 cannot
    # compare None < str, so sorted() raises TypeError.
    # This test documents the actual behavior: sort_tools propagates the error.
    body = {
        "tools": [
            {"name": "Write"},
            {"name": None},
            {"name": "Bash"},
        ]
    }
    with pytest.raises(TypeError):
        normalize.sort_tools(body)


def test_15e_non_dict_tool_entry_raises():
    # Same: a non-dict tool entry causes AttributeError in the sort lambda.
    body = {"tools": ["not-a-dict", {"name": "Bash"}]}
    with pytest.raises(AttributeError):
        normalize.sort_tools(body)


# ===========================================================================
# proxy/normalize.py — immutability (C9)
# ===========================================================================

def _dynamic_body():
    return {
        "system": (
            "You are helpful.\n"
            "Working directory: C:\\git\\ds4-ops\n"
            "Today's date is 2026-07-11T09:36:00Z\n"
            "<system-reminder>hidden</system-reminder>\n"
        ),
        "messages": [{"role": "user", "content": "run"}],
        "tools": [{"name": "Write"}, {"name": "Bash"}],
    }


def test_immutable_move_dynamic_sections():
    body = _dynamic_body()
    snapshot = copy.deepcopy(body)
    normalize.move_dynamic_sections(body)
    assert body == snapshot


def test_immutable_normalize_date():
    body = _dynamic_body()
    snapshot = copy.deepcopy(body)
    normalize.normalize_date(body)
    assert body == snapshot


def test_immutable_strip_system_reminders():
    body = _dynamic_body()
    snapshot = copy.deepcopy(body)
    normalize.strip_system_reminders(body)
    assert body == snapshot


def test_immutable_sort_tools():
    body = _dynamic_body()
    snapshot = copy.deepcopy(body)
    normalize.sort_tools(body)
    assert body == snapshot


# === Idempotency ===


def _idempotency_body():
    """A body that exercises all four normalization rules at once."""
    return {
        "system": (
            "You are helpful.\n"
            "Working directory: C:\\git\\ds4-ops\n"
            "Today's date is 2026-07-11T09:36:00Z\n"
            "<system-reminder>hidden</system-reminder>\n"
        ),
        "messages": [{"role": "user", "content": "run"}],
        "tools": [{"name": "Write"}, {"name": "Bash"}],
    }


def test_idempotent_move_dynamic_sections():
    body = _idempotency_body()
    first = normalize.move_dynamic_sections(body)
    second = normalize.move_dynamic_sections(first)
    # Second call must not re-append dynamic sections into user content.
    assert second["system"] == first["system"]
    assert second["messages"][0]["content"] == first["messages"][0]["content"]


def test_idempotent_normalize_date():
    body = _idempotency_body()
    first = normalize.normalize_date(body)
    second = normalize.normalize_date(first)
    assert second == first


def test_idempotent_strip_system_reminders():
    body = _idempotency_body()
    first = normalize.strip_system_reminders(body)
    second = normalize.strip_system_reminders(first)
    assert second == first


def test_idempotent_apply_all():
    body = _idempotency_body()
    first = normalize.apply_all(body)
    second = normalize.apply_all(first)
    assert second == first


# ===========================================================================
# proxy/normalize.py — apply_all
# ===========================================================================

def test_16_apply_all_order_and_all_rules():
    body = {
        "system": (
            "You are helpful.\n"
            "Working directory: C:\\git\\ds4-ops\n"
            "Today's date is 2026-07-11T09:36:00Z\n"
            "<system-reminder>hidden</system-reminder>\n"
        ),
        "messages": [{"role": "user", "content": "run"}],
        "tools": [
            {"name": "Write"},
            {"name": "Bash"},
        ],
    }
    out = normalize.apply_all(body)
    # A: dynamic section lifted out of system, into user message.
    assert "Working directory:" not in out["system"]
    assert "Working directory: C:\\git\\ds4-ops" in out["messages"][0]["content"]
    # B: date normalized.
    assert "Today's date is 2026-07-11" in out["system"]
    assert "T09:36:00Z" not in out["system"]
    # C: system-reminder stripped.
    assert "system-reminder" not in out["system"]
    # D: tools sorted.
    assert [t["name"] for t in out["tools"]] == ["Bash", "Write"]


def test_17_apply_all_empty_body():
    out = normalize.apply_all({})
    assert out == {}
