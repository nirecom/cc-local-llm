# Tests: proxy/server.py
# Tags: scope:issue-specific, layer:TL1, routing, classifier
#
# Scenario (issue #41 / detail plan D2+D3): the proxy is no longer a
# single-endpoint hop. `_is_v1_messages_post` (bool) is replaced by
# `_normalize_shape(method, path) -> str | None`, which decides the body shape
# from the REQUEST PATH ALONE (never by sniffing the body):
#   POST /v1/messages          -> "anthropic"
#   POST /v1/chat/completions  -> "openai"
#   POST /chat/completions     -> "openai"   (llama-swap's bare alias route)
#   everything else            -> None (forward verbatim, no normalization)
#
# The current strictness is preserved: only the query string is stripped, so a
# trailing slash and a sub-path (/v1/messages/count_tokens) still do NOT match.
#
# TL3 gap: none for this pure function (no I/O). Whether llama-swap actually
# accepts the bare /chat/completions alias is a live-backend question covered by
# the manual cutover procedure in docs/ops.md.

import pytest

from proxy import server

ANTHROPIC = "anthropic"
OPENAI = "openai"


@pytest.mark.parametrize(
    "method,path,expected",
    [
        # --- anthropic verdict ---------------------------------------------
        ("POST", "/v1/messages", ANTHROPIC),
        ("POST", "/v1/messages?beta=true", ANTHROPIC),
        ("POST", "/v1/messages?beta=true&foo=bar", ANTHROPIC),
        ("POST", "/v1/messages?", ANTHROPIC),
        # --- openai verdict -------------------------------------------------
        ("POST", "/v1/chat/completions", OPENAI),
        ("POST", "/v1/chat/completions?stream=true", OPENAI),
        ("POST", "/chat/completions", OPENAI),
        ("POST", "/chat/completions?stream=true", OPENAI),
        # --- None verdict: wrong method ------------------------------------
        ("GET", "/v1/messages", None),
        ("GET", "/v1/messages?beta=true", None),
        ("GET", "/v1/chat/completions", None),
        ("GET", "/chat/completions", None),
        ("PUT", "/v1/messages", None),
        ("post", "/v1/messages", None),          # method match is exact-case
        # --- None verdict: trailing slash not tolerated ----------------------
        ("POST", "/v1/messages/", None),
        ("POST", "/v1/chat/completions/", None),
        ("POST", "/chat/completions/", None),
        # --- None verdict: sub-path / near-miss paths -----------------------
        ("POST", "/v1/messages/count_tokens", None),
        ("POST", "/v1/message", None),
        ("POST", "/v2/messages", None),
        ("POST", "/completions", None),
        ("POST", "/v1/completions", None),
        ("POST", "/chat/completions/extra", None),
        ("POST", "/v1/models", None),
        ("POST", "/health", None),
        # --- None verdict: degenerate paths ---------------------------------
        ("POST", "", None),
        ("POST", "/", None),
        ("POST", "?", None),
    ],
)
def test_normalize_shape(method, path, expected):
    # Fail-before-fix: server._normalize_shape does not exist yet, so this
    # raises AttributeError against the current source — the correct pre-fix
    # state. Referencing it through the module (rather than a top-level import)
    # keeps this a per-test failure instead of a collection error.
    assert server._normalize_shape(method, path) is expected


def test_normalize_shape_returns_none_or_a_known_shape_only():
    """No third shape may leak out of the classifier.

    apply_all() branches on this value; an unknown string would silently pick
    whichever branch is the adapter's fallback.
    """
    paths = [
        "/v1/messages", "/v1/chat/completions", "/chat/completions",
        "/v1/messages/count_tokens", "/v1/models", "/", "",
    ]
    for method in ("POST", "GET"):
        for path in paths:
            got = server._normalize_shape(method, path)
            assert got in (ANTHROPIC, OPENAI, None), (
                f"{method} {path} -> {got!r}: not a recognized shape"
            )


def test_legacy_predicate_is_gone():
    """`_is_v1_messages_post` must not survive alongside its replacement.

    Keeping both leaves two route tables that can drift apart (CPR-SSOT); the
    rename to `_normalize_shape` is the whole point of D3.
    """
    assert not hasattr(server, "_is_v1_messages_post"), (
        "_is_v1_messages_post still exists — it must be replaced by "
        "_normalize_shape, not shadowed by it"
    )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
