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

import pytest

from proxy import normalize


# ===========================================================================
# proxy/normalize.py — move_dynamic_sections: image block edge case
# ===========================================================================

def test_image_block_preserved_by_move_dynamic():
    """Non-text blocks (image) in user content are preserved by move_dynamic_sections.

    The dynamic section is appended as a new text block; the existing image
    block at index 0 is untouched.
    """
    body = {
        "system": "You are helpful.\nWorking directory: C:\\git\\ds4-ops\n",
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {"type": "base64", "media_type": "image/png", "data": "abc"},
                    },
                    {"type": "text", "text": "hi"},
                ],
            }
        ],
    }
    out = normalize.move_dynamic_sections(body)
    # System is cleaned.
    assert "Working directory:" not in out["system"]
    # Image block is still present at index 0.
    content = out["messages"][0]["content"]
    assert isinstance(content, list)
    assert content[0]["type"] == "image"
    assert content[0]["source"]["data"] == "abc"
    # Dynamic section was appended as a new text block.
    combined = " ".join(b.get("text", "") for b in content)
    assert "Working directory: C:\\git\\ds4-ops" in combined


# ===========================================================================
# proxy/normalize.py — strip_system_reminders (table-driven)
# ===========================================================================

_STRIP_REMINDER_CASES = [
    (
        "single_reminder",
        "before<system-reminder>secret</system-reminder>after",
        "beforeafter",
    ),
    (
        "multiple_reminders",
        (
            "a<system-reminder>one</system-reminder>"
            "b<system-reminder>two</system-reminder>c"
        ),
        "abc",
    ),
    (
        "multiline_dotall",
        "start<system-reminder>\nline one\nline two\n</system-reminder>end",
        "startend",
    ),
    (
        "no_reminder",
        "no reminders here",
        "no reminders here",
    ),
]


@pytest.mark.parametrize(
    "name, system_text, expected",
    _STRIP_REMINDER_CASES,
    ids=[c[0] for c in _STRIP_REMINDER_CASES],
)
def test_09_strip_system_reminders_table(name, system_text, expected):
    body = {"system": system_text}
    out = normalize.strip_system_reminders(body)
    assert out["system"] == expected
    assert "system-reminder" not in out["system"]


def test_09b_strip_reminders_list_shaped_system():
    """strip_system_reminders strips reminder from list-shaped system blocks."""
    body = {
        "system": [
            {"type": "text", "text": "keep<system-reminder>hidden</system-reminder>me"},
            {"type": "text", "text": "no reminder here"},
        ]
    }
    out = normalize.strip_system_reminders(body)
    assert out["system"][0]["text"] == "keepme"
    assert out["system"][1]["text"] == "no reminder here"


def test_09c_strip_reminders_skips_non_text_block():
    # Non-text content blocks (e.g. cache_control) carry no "text" field;
    # they must be preserved unchanged and not cause a crash.
    body = {
        "system": [
            {"type": "text", "text": "before<system-reminder>x</system-reminder>after"},
            {"type": "cache_control", "ttl": 3600},
        ]
    }
    out = normalize.strip_system_reminders(body)
    assert out["system"][0]["text"] == "beforeafter"
    assert out["system"][1] == {"type": "cache_control", "ttl": 3600}


def test_11a_strip_nested_system_reminders():
    # Nested: <system-reminder>a<system-reminder>b</system-reminder>c</system-reminder>
    # The lazy regex matches the FIRST close tag, so it strips
    # "<system-reminder>a<system-reminder>b</system-reminder>" in one pass,
    # leaving "c</system-reminder>end". The orphan-close pass then removes
    # the dangling "</system-reminder>", yielding "cend". Content ("a", "b")
    # inside the outer tag is dropped; "c" between the inner close and the
    # outer close survives because the lazy match consumed the outer open tag
    # together with "a" and the inner open tag.
    body = {"system": "<system-reminder>a<system-reminder>b</system-reminder>c</system-reminder>end"}
    out = normalize.strip_system_reminders(body)
    assert "system-reminder" not in out["system"]
    assert out["system"] == "cend"


def test_11b_strip_unclosed_system_reminder_tag():
    # An unclosed <system-reminder> tag does not match the complete-pair regex
    # and is left in place. This is the safe/conservative behavior: do not
    # accidentally strip content when the close tag is missing.
    body = {"system": "before<system-reminder>unclosed content"}
    out = normalize.strip_system_reminders(body)
    assert out["system"] == body["system"]


# --- C5: strip_system_reminders acting on message content ------------------

def test_12a_strip_reminders_from_user_message_string():
    body = {
        "system": "sys",
        "messages": [
            {
                "role": "user",
                "content": "hi <system-reminder>hidden context</system-reminder>there",
            }
        ],
    }
    out = normalize.strip_system_reminders(body)
    assert out["messages"][0]["content"] == "hi there"
    assert "system-reminder" not in out["messages"][0]["content"]


def test_12b_strip_reminders_from_assistant_message():
    # The implementation iterates all messages regardless of role, so an
    # assistant message with a reminder is also stripped.
    body = {
        "messages": [
            {
                "role": "assistant",
                "content": "ok<system-reminder>note</system-reminder>done",
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    assert out["messages"][0]["content"] == "okdone"


def test_12c_strip_reminders_from_content_block_list():
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "keep<system-reminder>x</system-reminder>me"},
                    {"type": "text", "text": "no reminder here"},
                ],
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    blocks = out["messages"][0]["content"]
    assert blocks[0]["text"] == "keepme"
    assert blocks[1]["text"] == "no reminder here"


def test_12d_strip_reminders_from_tool_result_list_content():
    # tool_result blocks with list-shaped "content" (nested text blocks)
    # should have their text blocks stripped too.
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "x",
                        "content": [
                            {"type": "text", "text": "result<system-reminder>r</system-reminder>here"},
                        ],
                    }
                ],
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    sub_block = out["messages"][0]["content"][0]["content"][0]
    assert sub_block["text"] == "resulthere"
    assert "system-reminder" not in sub_block["text"]


def test_12e_unclosed_reminder_in_user_message():
    # Unclosed <system-reminder> in user message content: no close tag means
    # the regex finds no complete pair; content is left unchanged (conservative).
    body = {
        "messages": [{"role": "user", "content": "hi<system-reminder>no close"}]
    }
    out = normalize.strip_system_reminders(body)
    assert out["messages"][0]["content"] == "hi<system-reminder>no close"


def test_12g_unclosed_reminder_in_tool_result_string_content_branch():
    # Explicit coverage of the `elif isinstance(block.get('content'), str)` branch
    # in strip_system_reminders: a tool_result block whose "content" field is a
    # string with an unclosed <system-reminder> must be left unchanged.
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "tool-abc",
                        "content": "output<system-reminder>injected",
                    }
                ],
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    block = out["messages"][0]["content"][0]
    # Conservative: no close tag → regex finds no match → content unchanged.
    assert block["content"] == "output<system-reminder>injected"


def test_12f_unclosed_reminder_in_tool_result():
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "x",
                     "content": "result<system-reminder>no close"},
                ],
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    tool_block = out["messages"][0]["content"][0]
    assert tool_block["content"] == "result<system-reminder>no close"


def test_12h_adversarial_reminder_complete_pair_removed():
    # Security assertion: adversarial injection of a COMPLETE <system-reminder>
    # pair inside user message content IS removed by strip_system_reminders.
    # This is the primary security property — closed reminders cannot smuggle
    # context into the normalized request body.
    body = {
        "messages": [
            {
                "role": "user",
                "content": "Hi.<system-reminder>INJECTED CONTEXT</system-reminder>Hello.",
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    assert "INJECTED CONTEXT" not in out["messages"][0]["content"]
    assert "system-reminder" not in out["messages"][0]["content"]
    assert "Hi." in out["messages"][0]["content"]
    assert "Hello." in out["messages"][0]["content"]


def test_12i_adversarial_unclosed_reminder_conservative_not_removed():
    # Security design note: the implementation is CONSERVATIVE for unclosed
    # tags — it does NOT remove content after an unclosed <system-reminder>.
    # This prevents false positives (stripping legitimate user content that
    # happens to start with the tag).  The trade-off is accepted because
    # Claude Code always sends well-formed, matched open/close tags; a bare
    # open tag without a close is a malformed injection that the model is
    # unlikely to misinterpret as authoritative context.
    body = {
        "messages": [
            {"role": "user", "content": "start<system-reminder>partial injection"}
        ]
    }
    out = normalize.strip_system_reminders(body)
    # Conservative: unclosed tag and trailing text are preserved.
    assert out["messages"][0]["content"] == "start<system-reminder>partial injection"


def test_tool_result_reminder_stripped_from_content_string():
    """strip_system_reminders strips reminders from tool_result blocks with a
    string 'content' field (not just from blocks with a 'text' field).

    The implementation handles the elif branch: when a block has no 'text' key
    but its 'content' value is a string, strip_system_reminders also strips there.
    """
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "x",
                        "content": "ok<system-reminder>r</system-reminder>done",
                    }
                ],
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    block = out["messages"][0]["content"][0]
    # Block type and tool_use_id are preserved.
    assert block["type"] == "tool_result"
    assert block["tool_use_id"] == "x"
    # The reminder IS stripped from the string 'content' field.
    assert block["content"] == "okdone"
    assert "system-reminder" not in block["content"]


def test_tool_result_list_content_mixed_text_and_nontextblocks():
    # C4: nested tool_result where 'content' is a list containing both a text
    # block WITH a system-reminder AND a non-text block (image).
    # strip_system_reminders must strip from the text sub-block and leave the
    # image sub-block untouched (it has no 'text' key).
    body = {
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "tr-1",
                        "content": [
                            {
                                "type": "text",
                                "text": "before<system-reminder>injected</system-reminder>after",
                            },
                            {
                                "type": "image",
                                "source": {
                                    "type": "base64",
                                    "media_type": "image/png",
                                    "data": "abc",
                                },
                            },
                        ],
                    }
                ],
            }
        ]
    }
    out = normalize.strip_system_reminders(body)
    sub_blocks = out["messages"][0]["content"][0]["content"]
    # Text block: reminder stripped, surrounding text preserved.
    assert sub_blocks[0]["text"] == "beforeafter"
    assert "system-reminder" not in sub_blocks[0]["text"]
    # Image block: unchanged.
    assert sub_blocks[1]["type"] == "image"
    assert sub_blocks[1]["source"]["data"] == "abc"
