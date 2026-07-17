# Tests: proxy/server.py
# Tags: scope:issue-specific
# L3 gap: none (pure function, no I/O)

import pytest

from proxy import server


@pytest.mark.parametrize(
    "method,path,expected",
    [
        ("POST", "/v1/messages", True),
        ("POST", "/v1/messages?beta=true", True),
        ("POST", "/v1/messages?beta=true&foo=bar", True),
        ("POST", "/v1/messages?", True),
        ("GET", "/v1/messages", False),
        ("GET", "/v1/messages?beta=true", False),
        ("POST", "/v1/messages/", False),
        ("POST", "/v1/messages/count_tokens", False),
        ("POST", "/v1/message", False),
        ("POST", "", False),
    ],
)
def test_is_v1_messages_post(method, path, expected):
    # Fail-before-fix: server._is_v1_messages_post does not exist yet, so this
    # raises AttributeError against the current (unfixed) source — the correct
    # pre-fix state. Referencing it via the module (rather than a top-level
    # import) keeps this a per-test failure instead of a collection error that
    # would abort the whole session. Once the fix extracts the route match into
    # this pure function, every case runs and passes.
    assert server._is_v1_messages_post(method, path) is expected
