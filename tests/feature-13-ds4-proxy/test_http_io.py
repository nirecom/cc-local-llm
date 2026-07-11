# Tests: proxy/http_io.py
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

import asyncio

import pytest

from proxy import http_io


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_read_body(data: bytes, headers: dict) -> bytes:
    """Build a real asyncio.StreamReader, feed it ``data``, and read the body.

    The StreamReader is created inside the running loop because, since Python
    3.14, StreamReader() requires an already-running event loop (the implicit
    get_event_loop() fallback in the main thread was removed).
    """
    async def _inner() -> bytes:
        reader = asyncio.StreamReader()
        reader.feed_data(data)
        reader.feed_eof()
        return await http_io.read_request_body(reader, headers)

    return asyncio.run(_inner())


# ===========================================================================
# proxy/http_io.py — read_request_body
# ===========================================================================

def test_18_read_request_body_content_length():
    body = _run_read_body(b"0123456789EXTRA", {"Content-Length": "10"})
    assert body == b"0123456789"


def test_19_read_request_body_chunked():
    # "Wiki" (4) + "pedia" (5), then terminating "0" chunk.
    payload = b"4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "chunked"})
    assert body == b"Wikipedia"


def test_20_read_request_body_no_te_no_cl():
    body = _run_read_body(b"", {})
    assert body == b""


def test_20b_non_chunked_transfer_encoding_returns_empty():
    # TE values other than "chunked" are not recognized by this proxy;
    # they fall through to the default empty-body return (b""). Correct
    # because Claude Code does not send non-chunked TE.
    body = _run_read_body(b"notchunked-data", {"Transfer-Encoding": "compress"})
    assert body == b""


def test_20c_multi_token_te_gzip_chunked_is_detected():
    # "gzip, chunked" contains "chunked" — the proxy must detect this as a
    # chunked body (substring match covers multi-coding header values).
    payload = b"5\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "gzip, chunked"})
    assert body == b"hello"


def test_20d_te_substring_notchunked_treated_as_chunked():
    # The current implementation uses `"chunked" in te.lower()` (substring).
    # "notchunked" contains "chunked" as a substring, so the code treats it as
    # a chunked body.  This test documents the known permissive behavior.
    # "notchunked" is not a valid RFC 7230 TE coding, so this edge case cannot
    # arise from well-formed HTTP clients.
    payload = b"5\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "notchunked"})
    assert body == b"hello"


def test_20e_te_identity_safe_boundary_returns_empty():
    # Safe-boundary assertion: "identity" does not contain "chunked", so the
    # proxy must NOT attempt to read a chunked body.  The request body is left
    # unread (returns b"") — this is the safe fallback that prevents a crafted
    # TE header from causing the proxy to hang waiting for chunk framing.
    body = _run_read_body(b"some-data", {"Transfer-Encoding": "identity"})
    assert body == b""


def test_20f_te_chunkedx_treated_as_chunked_permissive():
    # "chunkedx" contains "chunked" as a prefix substring → permissive match.
    # Documents the same substring behavior as test_20d (notchunked).
    payload = b"5\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "chunkedx"})
    assert body == b"hello"


def test_20g_te_xchunked_treated_as_chunked_permissive():
    # "xchunked" contains "chunked" as a suffix substring → permissive match.
    payload = b"5\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "xchunked"})
    assert body == b"hello"


async def test_21q_malformed_chunk_crlf_followed_by_valid_zero_chunk_permissive():
    # When the 2-byte CRLF terminator after chunk data is replaced by non-CRLF
    # bytes (here b"!!") but a valid zero-chunk terminator follows, _read_chunked
    # silently consumes the invalid framing bytes and returns the chunk payload.
    # This documents the permissive behavior: framing bytes are consumed but not
    # validated.  "5\r\nhello!!0\r\n\r\n" → reads "hello", consumes "!!", then
    # sees "0\r\n\r\n" as the terminator.
    stream = b"5\r\nhello!!0\r\n\r\n"
    reader = asyncio.StreamReader()
    reader.feed_data(stream)
    reader.feed_eof()
    result = await http_io.read_request_body(reader, {"Transfer-Encoding": "chunked"})
    assert result == b"hello"


def test_21_read_request_body_chunked_terminator():
    payload = b"5\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "chunked"})
    assert body == b"hello"
    assert b"0" not in body


# --- C6: read_request_body error cases -------------------------------------

def test_21a_content_length_larger_than_data():
    # Current behavior: readexactly() cannot satisfy the declared length and
    # raises IncompleteReadError; the bytes actually available are exposed on
    # the exception's .partial attribute.
    with pytest.raises(asyncio.IncompleteReadError) as exc_info:
        _run_read_body(b"hello", {"Content-Length": "10"})
    assert exc_info.value.partial == b"hello"


def test_21b_chunked_malformed_size_line():
    # Current behavior: a non-hex chunk-size token makes int(token, 16) raise
    # ValueError. The proxy does not catch it — the error propagates.
    with pytest.raises(ValueError):
        _run_read_body(b"zz\r\nhello\r\n0\r\n\r\n", {"Transfer-Encoding": "chunked"})


def test_21e_non_numeric_content_length_raises():
    # A non-numeric Content-Length value makes int() raise ValueError.
    with pytest.raises(ValueError):
        _run_read_body(b"hello", {"Content-Length": "abc"})


def test_21f_zero_content_length_returns_empty():
    body = _run_read_body(b"ignored", {"Content-Length": "0"})
    assert body == b""


def test_21g_truncated_chunk():
    # "5\r\nhel\r\n" declares 5 bytes but only 3 are provided before EOF.
    # _read_chunked calls readexactly(5) which raises IncompleteReadError.
    with pytest.raises(asyncio.IncompleteReadError):
        _run_read_body(b"5\r\nhel\r\n", {"Transfer-Encoding": "chunked"})


def test_21h_huge_content_length():
    # A very large Content-Length with only a few bytes fed — readexactly()
    # raises IncompleteReadError; the partial attribute holds the available bytes.
    with pytest.raises(asyncio.IncompleteReadError) as exc_info:
        _run_read_body(b"abc", {"Content-Length": "999999999999"})
    assert exc_info.value.partial == b"abc"


# --- C7: mixed-case TE and chunk extension ---------------------------------

def test_21c_chunked_mixed_case_transfer_encoding():
    # "Chunked" (mixed case) must still be detected as chunked.
    payload = b"5\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "Chunked"})
    assert body == b"hello"


def test_21d_chunked_size_line_with_extension():
    # "5;name=value" -> 5 bytes read, extension ignored.
    payload = b"5;name=value\r\nhello\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "chunked"})
    assert body == b"hello"


def test_21j_content_length_wins_over_chunked_te():
    # RFC 7230 §3.3.3: when both headers are present on a REQUEST, the proxy
    # uses Content-Length (first match in read_request_body). This is the
    # implemented priority. Feed exactly 5 bytes + trailing chunked data.
    # Content-Length=5 means the first 5 bytes are consumed, not the chunked body.
    #
    # RFC 7230 §3.3.3 recommends treating CL+TE:chunked as a request-smuggling
    # risk (reject the message or prefer TE:chunked over CL). The proxy
    # intentionally keeps CL-wins because the only client is Claude Code, which
    # never sends ambiguous framing. A rejection path is not implemented — this
    # is a documented known deviation for this internal-only proxy.
    # Policy guard: if CL-wins ever changes, update this test to match the new behavior.
    payload = b"hello5\r\nworld\r\n0\r\n\r\n"
    body = _run_read_body(payload, {"Content-Length": "5", "Transfer-Encoding": "chunked"})
    assert body == b"hello"


def test_21k_negative_content_length_raises():
    with pytest.raises((ValueError, asyncio.IncompleteReadError)):
        _run_read_body(b"hello", {"Content-Length": "-1"})


def test_21l_chunked_with_single_trailer():
    # The implementation drains ALL trailer lines after the zero-size chunk in a
    # loop until it encounters a blank line. Verify the payload arrives correctly
    # with a single trailer header + blank line terminator.
    payload = b"5\r\nhello\r\n0\r\nX-Trailer: value\r\n\r\n"
    body = _run_read_body(payload, {"Transfer-Encoding": "chunked"})
    assert body == b"hello"


async def test_21m_chunked_multiple_trailers_stream_exhausted():
    # The implementation drains ALL trailer lines until a blank line. Verify
    # that two trailer headers are consumed and the stream is fully exhausted.
    payload = b"5\r\nhello\r\n0\r\nX-Foo: bar\r\nX-Baz: qux\r\n\r\n"
    reader = asyncio.StreamReader()
    reader.feed_data(payload)
    reader.feed_eof()
    body = await http_io.read_request_body(reader, {"Transfer-Encoding": "chunked"})
    assert body == b"hello"
    assert reader.at_eof()
    # Buffer should be empty — stream fully consumed including trailers.
    assert len(reader._buffer) == 0


async def test_21n_chunked_eof_before_size_line_raises():
    # _read_chunked must raise IncompleteReadError when the stream closes
    # before any chunk-size line arrives (otherwise the readline loop spins
    # forever on b'' EOF returns).
    reader = asyncio.StreamReader()
    reader.feed_eof()
    with pytest.raises(asyncio.IncompleteReadError):
        await http_io.read_request_body(reader, {"Transfer-Encoding": "chunked"})


async def test_21o_cl_wins_over_te_stream_remainder_not_consumed():
    # RFC 7230 §3.3.2 / §3.3.3: when Content-Length and Transfer-Encoding are
    # both present, Content-Length wins.  The chunked-encoded suffix that
    # follows the CL body must remain in the stream so it cannot be silently
    # forwarded as a second request body (request-smuggling boundary check).
    cl_body = b"hello"
    chunk_suffix = b"5\r\nworld\r\n0\r\n\r\n"
    reader = asyncio.StreamReader()
    reader.feed_data(cl_body + chunk_suffix)
    reader.feed_eof()
    headers = {
        "Content-Length": str(len(cl_body)),
        "Transfer-Encoding": "chunked",
    }
    result = await http_io.read_request_body(reader, headers)
    assert result == cl_body
    # The chunked suffix must still be in the stream buffer — it was NOT consumed.
    remainder = await reader.read(len(chunk_suffix))
    assert remainder == chunk_suffix


async def test_21p_malformed_chunk_crlf_terminator_raises():
    # _read_chunked calls readexactly(2) after each chunk's data to consume the
    # CRLF framing, but does NOT validate those bytes are \r\n.  When the
    # terminator is not \r\n (e.g. b"!!" replaces it), the 2 wrong bytes are
    # consumed silently and the next chunk-size line cannot be parsed as hex,
    # raising ValueError.  This test documents the current behavior.
    # Frame: "5\r\nhello!!" — "!!" is the malformed CRLF, then no valid size
    # line follows before EOF.
    malformed = b"5\r\nhello!!"
    reader = asyncio.StreamReader()
    reader.feed_data(malformed)
    reader.feed_eof()
    with pytest.raises((ValueError, asyncio.IncompleteReadError)):
        await http_io.read_request_body(reader, {"Transfer-Encoding": "chunked"})


# ===========================================================================
# proxy/http_io.py — sanitize_response_headers
# ===========================================================================

def test_22_sanitize_strips_te_and_connection():
    headers = [
        ("Content-Type", "application/json"),
        ("Transfer-Encoding", "chunked"),
        ("Connection", "keep-alive"),
    ]
    out = http_io.sanitize_response_headers(headers)
    names = [n.lower() for n, _ in out]
    assert "transfer-encoding" not in names
    # Only the appended Connection: close remains.
    assert names.count("connection") == 1
    assert ("Connection", "close") in out


def test_23_sanitize_strips_all_hop_by_hop():
    headers = [
        ("Connection", "x"),
        ("Keep-Alive", "x"),
        ("Proxy-Authenticate", "x"),
        ("Proxy-Authorization", "x"),
        ("TE", "x"),
        ("Trailers", "x"),
        ("Transfer-Encoding", "x"),
        ("Upgrade", "x"),
        ("Content-Type", "text/plain"),
    ]
    out = http_io.sanitize_response_headers(headers)
    names = [n.lower() for n, _ in out]
    for hop in http_io.HOP_BY_HOP:
        # The only surviving "connection" is the appended close.
        if hop == "connection":
            continue
        assert hop not in names
    assert ("Content-Type", "text/plain") in out


def test_24_sanitize_adds_connection_close():
    out = http_io.sanitize_response_headers([("Content-Type", "text/plain")])
    assert ("Connection", "close") in out


def test_25_sanitize_preserves_non_hop_by_hop():
    headers = [
        ("Content-Type", "application/json"),
        ("X-Request-Id", "abc-123"),
    ]
    out = http_io.sanitize_response_headers(headers)
    assert ("Content-Type", "application/json") in out
    assert ("X-Request-Id", "abc-123") in out


def test_26_sanitize_empty_input():
    out = http_io.sanitize_response_headers([])
    assert out == [("Connection", "close")]


def test_27_sanitize_case_insensitive_strip():
    headers = [
        ("TRANSFER-ENCODING", "chunked"),
        ("CoNnEcTiOn", "keep-alive"),
        ("UPGRADE", "h2c"),
        ("Content-Type", "text/plain"),
    ]
    out = http_io.sanitize_response_headers(headers)
    names = [n.lower() for n, _ in out]
    assert "transfer-encoding" not in names
    assert "upgrade" not in names
    assert names.count("connection") == 1
    assert ("Content-Type", "text/plain") in out


def test_27a_sanitize_strips_connection_nominated_header():
    # RFC 7230 6.1: a header named in the Connection value is hop-by-hop too.
    headers = [
        ("Connection", "X-Debug"),
        ("X-Debug", "secret"),
        ("Content-Type", "text/event-stream"),
    ]
    out = http_io.sanitize_response_headers(headers)
    names = [n.lower() for n, _ in out]
    assert "x-debug" not in names
    assert ("Content-Type", "text/event-stream") in out
    assert ("Connection", "close") in out


def test_27b_sanitize_strips_multiple_connection_headers_with_csv_nominations():
    # Two separate Connection tuples each nominating different headers via
    # comma-separated values — all nominated headers must be stripped.
    headers = [
        ("Connection", "X-Debug, X-Trace"),
        ("Connection", "X-Request-Id"),
        ("X-Debug", "1"),
        ("X-Trace", "2"),
        ("X-Request-Id", "3"),
        ("Content-Type", "text/plain"),
    ]
    out = http_io.sanitize_response_headers(headers)
    names = [n.lower() for n, _ in out]
    assert "x-debug" not in names
    assert "x-trace" not in names
    assert "x-request-id" not in names
    assert ("Content-Type", "text/plain") in out
    assert ("Connection", "close") in out
