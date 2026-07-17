# Tests: proxy/normalize.py, proxy/http_io.py, proxy/auth.py
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
import json
import types

import httpx
import pytest

from proxy import auth, normalize, server
from proxy.tee import TeeLogger


# ===========================================================================
# Proxy-level integration: verify_auth + apply_all per-request flow
# ===========================================================================

_INTEGRATION_TOKEN = "integration-test-token"


def test_proxy_integration_auth_and_normalize():
    """Chain verify_auth + apply_all to simulate the per-request server flow.

    Checks:
      1. verify_auth returns True for the correct token.
      2. apply_all removes the dynamic section from system.
      3. The dynamic section appears in the first user message.
      4. The date is normalized (timestamp -> date only).
      5. The system-reminder is stripped.
    """
    # Step 1: authentication
    headers = {"Authorization": f"Bearer {_INTEGRATION_TOKEN}"}
    assert auth.verify_auth(headers, _INTEGRATION_TOKEN) is True

    # Step 2: normalization
    body = {
        "system": (
            "You are helpful.\n"
            "Working directory: C:\\git\\ds4-ops\n"
            "Today's date is 2026-07-11T09:36:00Z\n"
            "<system-reminder>hidden context</system-reminder>\n"
        ),
        "messages": [{"role": "user", "content": "run tests"}],
        "tools": [{"name": "Write"}, {"name": "Bash"}],
    }
    out = normalize.apply_all(body)

    # Dynamic section removed from system, placed in first user message.
    assert "Working directory:" not in out["system"]
    assert "Working directory: C:\\git\\ds4-ops" in out["messages"][0]["content"]

    # Date normalized.
    assert "Today's date is 2026-07-11" in out["system"]
    assert "T09:36:00Z" not in out["system"]

    # System-reminder stripped.
    assert "system-reminder" not in out["system"]
    assert "hidden context" not in out["system"]


# ===========================================================================
# proxy/server.py — _handle end-to-end (StreamReader in, stubbed upstream out)
#
# These drive the real _handle so the /v1/messages route-match bug is exercised
# through the actual normalize->tee->forward call path, not just the pure route
# predicate. The upstream httpx call is replaced by _FakeClient so no network is
# touched; the client-facing socket is replaced by _FakeWriter.
# ===========================================================================

_HANDLE_TOKEN = "integration-handle-token"

# Body shape mirrors test_proxy_integration_auth_and_normalize above: the
# <system-reminder> marker lives in the `system` field, which is exactly where
# normalize.strip_system_reminders operates. If normalization fires, the marker
# is stripped from what is forwarded upstream; if it is skipped, the marker
# survives verbatim.
_MARKER = "<system-reminder>hidden context</system-reminder>"
_MARKER_BODY = {
    "system": "You are helpful.\n" + _MARKER + "\n",
    "messages": [{"role": "user", "content": "run tests"}],
}


class _FakeWriter:
    """Captures bytes written to the client-facing socket."""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.closed = False

    def write(self, data: bytes) -> None:
        self.buffer.extend(data)

    async def drain(self) -> None:
        return None

    def close(self) -> None:
        self.closed = True


class _FakeUpstream:
    """Mimics the async-context-manager response from httpx client.stream()."""

    def __init__(
        self,
        status_code: int = 200,
        reason_phrase: str = "OK",
        headers: dict | None = None,
        chunks: list[bytes] | None = None,
        raise_on_enter: Exception | None = None,
    ) -> None:
        self.status_code = status_code
        self.reason_phrase = reason_phrase
        self.headers = headers if headers is not None else {"Content-Type": "application/json"}
        self._chunks = chunks if chunks is not None else [b'{"ok":true}']
        self._raise_on_enter = raise_on_enter

    async def __aenter__(self) -> "_FakeUpstream":
        if self._raise_on_enter is not None:
            raise self._raise_on_enter
        return self

    async def __aexit__(self, *exc) -> bool:
        return False

    async def aiter_raw(self):
        for chunk in self._chunks:
            yield chunk


class _FakeClient:
    """Stub for httpx.AsyncClient: records what _handle forwards upstream."""

    def __init__(self, response: _FakeUpstream | None = None) -> None:
        self._response = response if response is not None else _FakeUpstream()
        self.captured: dict | None = None

    def stream(self, method, url, content, headers):
        self.captured = {
            "method": method,
            "url": url,
            "content": content,
            "headers": headers,
        }
        return self._response


def _make_config(token: str = _HANDLE_TOKEN, upstream: str = "http://127.0.0.1:8000"):
    # _handle only touches config.auth_token and config.upstream.
    return types.SimpleNamespace(auth_token=token, upstream=upstream)


def _build_request(method, path, body_dict=None, raw_body=None, token=_HANDLE_TOKEN):
    if raw_body is not None:
        body = raw_body
    elif body_dict is not None:
        body = json.dumps(body_dict).encode("utf-8")
    else:
        body = b""
    head = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Authorization: Bearer {token}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "\r\n"
    ).encode("latin-1")
    return head + body


async def _run_handle(request_bytes, config, client, tee) -> _FakeWriter:
    # StreamReader must be built inside the running loop (Python 3.14 removed the
    # implicit get_event_loop() fallback); mirrors _run_read_body in test_http_io.
    reader = asyncio.StreamReader()
    reader.feed_data(request_bytes)
    reader.feed_eof()
    writer = _FakeWriter()
    await server._handle(reader, writer, config, client, tee)
    return writer


def _tee_file_count(log_dir) -> int:
    # One normalize-then-tee pass writes a numbered pre/post pair -> 2 files.
    return len(list(log_dir.glob("*.json")))


# --- Case 1: control — POST /v1/messages (no query) normalizes + tees --------

async def test_handle_post_v1_messages_normalizes_and_tees(tmp_path):
    config = _make_config()
    client = _FakeClient()
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    request = _build_request("POST", "/v1/messages", body_dict=_MARKER_BODY)

    writer = await _run_handle(request, config, client, tee)

    sent = client.captured["content"].decode("utf-8")
    assert "system-reminder" not in sent
    assert "hidden context" not in sent
    assert _tee_file_count(tmp_path) == 2
    assert "200 OK" in writer.buffer.decode("latin-1")
    assert writer.closed is True


# --- Case 2: regression — POST /v1/messages?beta=true (fail-before-fix) -------

async def test_handle_post_v1_messages_query_string_still_normalizes(tmp_path):
    # Fail-before-fix: against the CURRENT unfixed server.py the path
    # "/v1/messages?beta=true" fails the exact-string route match, so the body is
    # forwarded un-normalized and zero tee files are written. The assertions
    # below encode the CORRECT post-fix behavior (query stripped before matching,
    # normalize+tee fire), so this test is EXPECTED to fail until the fix lands.
    config = _make_config()
    client = _FakeClient()
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    request = _build_request("POST", "/v1/messages?beta=true", body_dict=_MARKER_BODY)

    writer = await _run_handle(request, config, client, tee)

    sent = client.captured["content"].decode("utf-8")
    assert "system-reminder" not in sent
    assert "hidden context" not in sent
    assert _tee_file_count(tmp_path) == 2
    # The query string must remain on the forwarded upstream URL: server.py:139
    # builds the URL from the untouched path, so the fix must not drop the query.
    assert client.captured["url"].endswith("/v1/messages?beta=true")
    assert "200 OK" in writer.buffer.decode("latin-1")


# --- Case 3: method guard — GET /v1/messages?beta=true is never normalized ----

async def test_handle_get_v1_messages_query_not_normalized(tmp_path):
    config = _make_config()
    client = _FakeClient()
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    request = _build_request("GET", "/v1/messages?beta=true", body_dict=_MARKER_BODY)

    writer = await _run_handle(request, config, client, tee)

    sent = client.captured["content"].decode("utf-8")
    # GET never matches the POST-only special case, query string or not.
    assert _MARKER in sent
    assert _tee_file_count(tmp_path) == 0
    assert client.captured["method"] == "GET"


# --- Case 4: path boundary — POST /v1/messages/count_tokens must not match ----

async def test_handle_post_count_tokens_not_normalized(tmp_path):
    config = _make_config()
    client = _FakeClient()
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    request = _build_request("POST", "/v1/messages/count_tokens", body_dict=_MARKER_BODY)

    writer = await _run_handle(request, config, client, tee)

    sent = client.captured["content"].decode("utf-8")
    # A sub-path must NOT be treated as the /v1/messages special case (declared
    # non-goal: minimal fix strips only the query string, not trailing segments).
    assert _MARKER in sent
    assert _tee_file_count(tmp_path) == 0


# --- Case 5: edge/error bodies on the matched route must not crash ------------

async def test_handle_post_empty_body_passthrough_no_tee(tmp_path):
    # Empty body is not valid JSON: _normalize_body catches the decode error and
    # forwards the original bytes unchanged, and tee is not written (the tee.log
    # call is downstream of the successful-decode branch).
    config = _make_config()
    client = _FakeClient()
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    request = _build_request("POST", "/v1/messages", raw_body=b"")

    writer = await _run_handle(request, config, client, tee)

    assert client.captured["content"] == b""
    assert _tee_file_count(tmp_path) == 0
    assert "200 OK" in writer.buffer.decode("latin-1")
    assert writer.closed is True


async def test_handle_post_missing_system_field_no_crash(tmp_path):
    # A JSON body with no `system` key must normalize without error (every
    # normalize rule tolerates a missing system) and still tee its pre/post pair.
    config = _make_config()
    client = _FakeClient()
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    body = {"messages": [{"role": "user", "content": "hi"}]}
    request = _build_request("POST", "/v1/messages", body_dict=body)

    writer = await _run_handle(request, config, client, tee)

    assert json.loads(client.captured["content"])["messages"][0]["content"] == "hi"
    assert _tee_file_count(tmp_path) == 2
    assert "200 OK" in writer.buffer.decode("latin-1")


# --- Case 6: upstream boundary — httpx.RequestError yields 502 Bad Gateway ----

async def test_handle_upstream_request_error_returns_502(tmp_path):
    # When the upstream connection fails, _handle's `except httpx.RequestError`
    # branch must relay a 502 to the client rather than propagate. Normalization
    # still fires first (matched route), independent of the forward failure.
    config = _make_config()
    client = _FakeClient(
        response=_FakeUpstream(raise_on_enter=httpx.RequestError("upstream down"))
    )
    tee = TeeLogger(enabled=True, log_dir=tmp_path)
    request = _build_request("POST", "/v1/messages", body_dict=_MARKER_BODY)

    writer = await _run_handle(request, config, client, tee)

    assert "502 Bad Gateway" in writer.buffer.decode("latin-1")
    assert _tee_file_count(tmp_path) == 2
    assert writer.closed is True


# (L3 gaps documented in file header)

if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
