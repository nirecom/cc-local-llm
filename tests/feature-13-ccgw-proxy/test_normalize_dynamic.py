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


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SYSTEM_WITH_CWD = (
    "You are a helpful assistant.\n"
    "Working directory: C:\\git\\ds4-ops\n"
    "Be concise.\n"
)


# ===========================================================================
# proxy/normalize.py — move_dynamic_sections (table-driven, C1 + C2)
# ===========================================================================

# Each case: (name, input_body, expected_removed_from_system, expected_in_user)
#   * expected_removed_from_system: substrings that must NOT survive in system
#   * expected_in_user: substrings that must appear in the first user message
# Every entry in normalize.DYNAMIC_PATTERNS is covered by at least one case.
_PREAMBLE = "You are a helpful assistant.\n"
_USER_MSG = [{"role": "user", "content": "hello"}]

MOVE_DYNAMIC_CASES = [
    (
        "working_directory",
        {
            "system": _PREAMBLE + "Working directory: C:\\git\\ds4-ops\n",
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["Working directory:"],
        ["Working directory: C:\\git\\ds4-ops"],
    ),
    (
        "is_directory_a_git_repo",
        {
            "system": _PREAMBLE + "Is directory a git repo: Yes\n",
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["Is directory a git repo:"],
        ["Is directory a git repo: Yes"],
    ),
    (
        "platform",
        {
            "system": _PREAMBLE + "Platform: win32\n",
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["Platform:"],
        ["Platform: win32"],
    ),
    (
        "os_version",
        {
            "system": _PREAMBLE + "OS Version: Windows 11 Home 10.0.26200\n",
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["OS Version:"],
        ["OS Version: Windows 11 Home 10.0.26200"],
    ),
    (
        "shell",
        {
            "system": _PREAMBLE + "Shell: PowerShell (primary)\n",
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["Shell:"],
        ["Shell: PowerShell (primary)"],
    ),
    (
        "auto_memory_path",
        {
            "system": _PREAMBLE + "You have a persistent, file-based memory system at `C:\\Users\\nire\\.claude\\projects\\ds4\\memory\\`.\n",
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["You have a persistent, file-based memory system at"],
        ["You have a persistent, file-based memory system at `C:\\Users\\nire\\.claude\\projects\\ds4\\memory\\`."],
    ),
    (
        "gitstatus_block_at_end",
        {
            "system": (
                _PREAMBLE
                + "gitStatus: This is the git status.\n"
                + " M proxy/normalize.py\n"
                + "?? tests/new.py\n"
            ),
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["gitStatus:", " M proxy/normalize.py", "?? tests/new.py"],
        ["gitStatus: This is the git status.", " M proxy/normalize.py"],
    ),
    (
        "gitstatus_block_preserves_trailing_text",
        # C4: a blank line terminates the gitStatus block; text after the
        # blank line is STABLE and must remain in the system prompt, not be
        # swallowed by the greedy DOTALL regex.
        {
            "system": (
                _PREAMBLE
                + "gitStatus: This is the git status.\n"
                + " M proxy/normalize.py\n"
                + "\n"
                + "IMPORTANT: this context may or may not be relevant.\n"
            ),
            "messages": copy.deepcopy(_USER_MSG),
        },
        ["gitStatus:", " M proxy/normalize.py"],
        ["gitStatus: This is the git status."],
    ),
    (
        "multiple_sections",
        {
            "system": (
                _PREAMBLE
                + "Working directory: C:\\git\\ds4-ops\n"
                + "Is directory a git repo: Yes\n"
                + "Platform: win32\n"
                + "OS Version: Windows 11\n"
                + "Shell: PowerShell\n"
                + "gitStatus: status.\n"
                + " M a.py\n"
            ),
            "messages": copy.deepcopy(_USER_MSG),
        },
        [
            "Working directory:",
            "Is directory a git repo:",
            "Platform:",
            "OS Version:",
            "Shell:",
            "gitStatus:",
        ],
        [
            "Working directory: C:\\git\\ds4-ops",
            "Is directory a git repo: Yes",
            "Platform: win32",
            "OS Version: Windows 11",
            "Shell: PowerShell",
            "gitStatus: status.",
        ],
    ),
]


@pytest.mark.parametrize(
    "name, body, removed_from_system, in_user",
    MOVE_DYNAMIC_CASES,
    ids=[c[0] for c in MOVE_DYNAMIC_CASES],
)
def test_01_move_dynamic_sections_table(name, body, removed_from_system, in_user):
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    system = out["system"]
    for needle in removed_from_system:
        assert needle not in system, f"[{name}] {needle!r} should be removed from system"
    # The static preamble always survives.
    assert "You are a helpful assistant." in system
    user_content = out["messages"][0]["content"]
    for needle in in_user:
        assert needle in user_content, f"[{name}] {needle!r} should be moved into user"


def test_01b_every_dynamic_pattern_has_a_case():
    """Guard: every compiled DYNAMIC_PATTERN is exercised by a table case.

    We match each pattern against the concatenated system prompts of all
    cases; an unexercised pattern signals a coverage gap in the table.
    """
    all_systems = "\n".join(c[1]["system"] for c in MOVE_DYNAMIC_CASES)
    for pat in normalize.DYNAMIC_PATTERNS:
        assert pat.search(all_systems), f"pattern {pat.pattern!r} has no test case"


def test_02_move_dynamic_sections_content_block_list():
    body = {
        "system": [
            {"type": "text", "text": SYSTEM_WITH_CWD},
        ],
        "messages": [{"role": "user", "content": "hi there"}],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    assert "Working directory:" not in out["system"][0]["text"]
    assert "Working directory: C:\\git\\ds4-ops" in out["messages"][0]["content"]


def test_03_move_dynamic_sections_no_dynamic():
    body = {
        "system": "You are a helpful assistant.\nBe concise.\n",
        "messages": [{"role": "user", "content": "hello"}],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    assert out["system"] == body["system"]
    assert out["messages"][0]["content"] == "hello"


def test_04_move_dynamic_sections_no_messages_key():
    # C3: with no messages to attach to, the dynamic content is discarded
    # (there is no user message target), but the system prompt is STILL
    # cleaned and the call must not crash. This documents that behavior:
    # the dynamic content is not silently *kept* in system — it is stripped.
    #
    # The dynamic section WAS extracted from system (verified below: "Working
    # directory:" is absent). With no user message to receive it, the content
    # is DISCARDED — not stored elsewhere, not accumulated. This is by design:
    # the proxy opts for cache stability over dynamic-content preservation when
    # there is no target message slot.
    body = {"system": SYSTEM_WITH_CWD}
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    # System is cleaned even though there was nowhere to move the content to.
    assert "Working directory:" not in out["system"]
    assert "You are a helpful assistant." in out["system"]
    # No messages key was invented, and nothing crashed.
    assert "messages" not in out
    # by design: dynamic content is discarded when there is no user message target
    assert "Working directory: C:\\git\\ds4-ops" not in out["system"]


def test_04b_gitstatus_does_not_eat_text_after_blank_line():
    # C4 (dedicated): the greedy DOTALL gitStatus regex must NOT consume
    # stable text that follows a blank line after the status listing.
    stable = "IMPORTANT: this context may or may not be relevant to your tasks."
    system = (
        "You are helpful.\n"
        "gitStatus: This is the git status.\n"
        " M proxy/normalize.py\n"
        "?? tests/new.py\n"
        "\n"
        f"{stable}\n"
    )
    body = {"system": system, "messages": [{"role": "user", "content": "go"}]}
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    # Stable trailing text is preserved in the system prompt.
    assert stable in out["system"]
    # But the gitStatus block itself was lifted out.
    assert "gitStatus:" not in out["system"]
    assert " M proxy/normalize.py" not in out["system"]
    # And the gitStatus block landed in the user message (not the stable text).
    user = out["messages"][0]["content"]
    assert "gitStatus: This is the git status." in user
    assert stable not in user


# --- move_dynamic_sections edge cases --------------------------------------

def test_04c_user_content_already_a_list():
    """When first user message content is already a list, dynamic section is
    appended as a new content block (not string-concatenated to the first block).
    """
    body = {
        "system": "You are helpful.\nWorking directory: C:\\git\\ds4-ops\n",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "existing block"},
                ],
            }
        ],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    # System should be cleaned.
    assert "Working directory:" not in out["system"]
    # First user message content remains a list.
    content = out["messages"][0]["content"]
    assert isinstance(content, list)
    # A new block containing the dynamic section must have been appended.
    combined = " ".join(block.get("text", "") for block in content)
    assert "Working directory: C:\\git\\ds4-ops" in combined


def test_04d_none_content_in_user_message_does_not_crash():
    """A user message with content=None must not raise; dynamic section goes
    to that message slot (None -> appendix string) per the else branch.
    """
    body = {
        "system": "You are helpful.\nWorking directory: C:\\git\\ds4-ops\n",
        "messages": [{"role": "user", "content": None}],
    }
    # Must not raise.
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    # System is cleaned.
    assert "Working directory:" not in out["system"]
    # The user message content received the appendix (None branch -> appendix).
    assert "Working directory: C:\\git\\ds4-ops" in out["messages"][0]["content"]


def test_04e_empty_string_content_in_user_message():
    """A user message with empty-string content gets the dynamic section appended."""
    body = {
        "system": "You are helpful.\nPlatform: win32\n",
        "messages": [{"role": "user", "content": ""}],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    assert "Platform:" not in out["system"]
    assert "Platform: win32" in out["messages"][0]["content"]


def test_04f_only_assistant_messages_does_not_crash():
    """When messages contains only assistant roles, no user target exists —
    the dynamic content is discarded but no exception is raised and the
    system prompt is still cleaned.
    """
    # The dynamic section WAS extracted from system (verified below: "OS Version:"
    # is absent). With no user message to receive it, the content is DISCARDED —
    # not stored elsewhere, not accumulated. This is by design: the proxy opts for
    # cache stability over dynamic-content preservation when there is no target.
    body = {
        "system": "You are helpful.\nOS Version: Windows 11\n",
        "messages": [{"role": "assistant", "content": "Sure."}],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    # System is cleaned.
    assert "OS Version:" not in out["system"]
    # by design: dynamic content is discarded when there is no user message target
    # Assistant message is unchanged.
    assert out["messages"][0]["content"] == "Sure."


def test_04f2_assistant_then_user_dynamic_goes_to_user():
    # When assistant messages precede the first user message, move_dynamic_sections
    # must skip the assistant entries and append the extracted section to the
    # first user message (the break-on-first-user-match path).
    body = {
        "system": "You are helpful.\nShell: bash\n",
        "messages": [
            {"role": "assistant", "content": "Welcome!"},
            {"role": "user", "content": "Hello."},
        ],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    assert "Shell:" not in out["system"]
    assert out["messages"][0]["content"] == "Welcome!"  # assistant unchanged
    assert "Shell: bash" in out["messages"][1]["content"]  # user received it


def test_04f3_empty_messages_list_system_still_cleaned():
    # `messages: []` (present but empty) is distinct from no 'messages' key.
    # Dynamic sections must still be extracted from system, but since there is
    # no user message to append to, the content is discarded — no crash.
    body = {
        "system": "You are helpful.\nPlatform: win32\n",
        "messages": [],
    }
    out = normalize.move_dynamic_sections(body, shape="anthropic")
    assert "Platform:" not in out["system"]
    assert out["messages"] == []


def test_04g_non_dict_message_entry_raises():
    # Non-dict entries in the messages list cause AttributeError because the
    # code calls .get() on each entry. Claude Code always sends well-formed
    # Anthropic API requests, so this case cannot arise in production.
    body = {
        "system": SYSTEM_WITH_CWD,
        "messages": ["not-a-dict"],
    }
    with pytest.raises(AttributeError):
        normalize.move_dynamic_sections(body, shape="anthropic")


# ===========================================================================
# proxy/normalize.py — normalize_date (table-driven)
# ===========================================================================

_NORMALIZE_DATE_CASES = [
    (
        "timestamp_z_suffix",
        {"system": "Today's date is 2026-07-11T09:36:00Z\nHello."},
        "Today's date is 2026-07-11",
        "T09:36:00Z",
    ),
    (
        "timestamp_tz_offset",
        {"system": "Today's date is 2026-07-11T09:36:00+09:00\nHello."},
        "Today's date is 2026-07-11",
        "T09:36:00+09:00",
    ),
    (
        "already_date_only",
        {"system": "Today's date is 2026-07-11\nHello."},
        "Today's date is 2026-07-11",
        None,  # no substring to assert absent
    ),
    (
        "malformed_kept_as_is",
        {"system": "Today's date is sometime-soon\nHello."},
        None,  # no assertion on present string
        None,
    ),
    (
        "space_separated_timestamp",
        {"system": "Today's date is 2026-07-11 09:36:00\nHello."},
        "Today's date is 2026-07-11",
        " 09:36:00",
    ),
    (
        "malformed_time_no_separator_date_preserved",
        # "2026-07-1109:00" — no T or space between date and time.
        # The regex (?:[T ][0-9:.\-+Z]*)? requires [T ] as separator;
        # "0" (first char of "09:00") is not a separator so the optional
        # group does not match.  Result: date retained, "09:00" not consumed.
        {"system": "Today's date is 2026-07-1109:00\nHello."},
        "Today's date is 2026-07-11",
        None,
    ),
    (
        "malformed_time_after_T_date_preserved",
        # "2026-07-11Tnot-a-time" — T matches [T ] but subsequent chars
        # "not-a-time" are not in [0-9:.\-+Z].  The optional group matches
        # only "T" (zero-length [0-9:.\-+Z]* match), consuming the T.
        # Remaining "not-a-time" stays in the string.
        # Date is correctly extracted; no corruption of the date value.
        {"system": "Today's date is 2026-07-11Tnot-a-time\nHello."},
        "Today's date is 2026-07-11",
        None,
    ),
]


@pytest.mark.parametrize(
    "name, body, present, absent",
    _NORMALIZE_DATE_CASES,
    ids=[c[0] for c in _NORMALIZE_DATE_CASES],
)
def test_06_normalize_date_table(name, body, present, absent):
    import copy as _copy
    original = _copy.deepcopy(body)
    out = normalize.normalize_date(body, shape="anthropic")
    if present is not None:
        assert present in out["system"], f"[{name}] expected {present!r} in system"
    if absent is not None:
        assert absent not in out["system"], f"[{name}] expected {absent!r} absent from system"
    if name == "malformed_kept_as_is":
        assert out["system"] == original["system"]
    if name == "already_date_only":
        assert out["system"] == original["system"]


def test_06b_normalize_date_list_shaped_system():
    """normalize_date strips timestamp from list-shaped system content blocks."""
    body = {
        "system": [
            {"type": "text", "text": "Today's date is 2026-07-11T09:36:00Z\nBe helpful."},
        ]
    }
    out = normalize.normalize_date(body, shape="anthropic")
    block_text = out["system"][0]["text"]
    assert "Today's date is 2026-07-11" in block_text
    assert "T09:36:00Z" not in block_text


def test_06c_normalize_date_skips_non_text_block():
    # Non-text content blocks (e.g. cache_control) carry no "text" field;
    # they must be preserved unchanged and not cause a crash.
    body = {
        "system": [
            {"type": "text", "text": "Today's date is 2026-07-11T09:36:00Z"},
            {"type": "cache_control", "ttl": 3600},
        ]
    }
    out = normalize.normalize_date(body, shape="anthropic")
    assert out["system"][0]["text"] == "Today's date is 2026-07-11"
    assert out["system"][1] == {"type": "cache_control", "ttl": 3600}
