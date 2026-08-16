"""asyncio TLS reverse proxy for ccgw.

Terminates TLS from LiteLLM, authenticates the request against a shared token,
normalizes the request body for a stable prompt-cache prefix, then forwards to
the plain-HTTP Mac llama-swap and relays the (possibly streamed) response back.
One handler runs per client connection.

The proxy is a path-preserving generic hop: it appends the incoming path to
CCGW_PROXY_UPSTREAM verbatim and never rewrites the model name. llama-swap
routes by model name to ds4-server or Laguna's mlx_lm.server, both of which
speak the OpenAI /v1/chat/completions shape — Anthropic-to-OpenAI conversion
is LiteLLM's job, upstream of here. Normalization therefore has to understand
both shapes, which is what the `shape` argument threaded through
proxy.normalize selects.
"""

import asyncio
import json
import ssl
import sys
from datetime import datetime, timezone

import httpx

from proxy import auth, http_io, normalize
from proxy.config import load_config
from proxy.tee import TeeLogger

MAX_BODY_BYTES = 10 * 1024 * 1024  # 10 MB; return 413 if exceeded
WRITE_TIMEOUT = 60.0  # seconds; bounds writer.drain() so a stalled client
# connection (dead network, sleep, etc.) can't hang a handler task forever.
# The upstream httpx client is deliberately timeout=None (LLM generations can
# legitimately run for many minutes) — this bounds only the client-facing side.


def _get_header(headers: dict, name: str) -> str | None:
    """Case-insensitive header lookup."""
    lname = name.lower()
    for key, value in headers.items():
        if key.lower() == lname:
            return value
    return None


_SHAPE_BY_PATH = {
    "/v1/messages": "anthropic",
    "/v1/chat/completions": "openai",
    # llama-swap also exposes the bare alias, and LiteLLM may address it.
    "/chat/completions": "openai",
}


def _normalize_shape(method: str, path: str) -> str | None:
    """Body shape to normalize this request as, or None to forward verbatim.

    Decided from the request path alone — never by sniffing the body, which
    would make routing depend on client-controlled content.

    Only the query string is stripped (path.partition("?")[0]); no urlsplit
    normalization and no trailing-slash tolerance, so "/v1/messages/" and
    "/v1/messages/count_tokens" deliberately do NOT match.
    """
    if method != "POST":
        return None
    return _SHAPE_BY_PATH.get(path.partition("?")[0])


async def _read_request_head(
    reader: asyncio.StreamReader,
) -> tuple[str, str, str, dict]:
    """Read the request line and headers.

    Returns (method, path, version, headers). Raises EOFError on a closed
    connection and ValueError on a malformed request line.
    """
    request_line = await reader.readline()
    if not request_line:
        raise EOFError("connection closed before request line")

    parts = request_line.decode("latin-1").rstrip("\r\n").split(" ")
    if len(parts) != 3:
        raise ValueError(f"malformed request line: {request_line!r}")
    method, path, version = parts

    headers: dict = {}
    while True:
        line = await reader.readline()
        if line in (b"\r\n", b"\n", b""):
            break
        name, sep, value = line.decode("latin-1").rstrip("\r\n").partition(":")
        if not sep:
            continue
        headers[name.strip()] = value.strip()

    return method, path, version, headers


def _build_upstream_headers(req_headers: dict, body: bytes) -> dict:
    """Strip hop-by-hop + Content-Length, then set a fresh Content-Length."""
    result: dict = {}
    for name, value in req_headers.items():
        lname = name.lower()
        if lname in http_io.HOP_BY_HOP or lname == "content-length":
            continue
        result[name] = value
    if body:
        result["Content-Length"] = str(len(body))
    return result


async def _drain(writer: asyncio.StreamWriter) -> None:
    """Flush ``writer`` with a bound, so a stalled peer can't hang forever."""
    await asyncio.wait_for(writer.drain(), timeout=WRITE_TIMEOUT)


def _send_error(writer: asyncio.StreamWriter, status: int, phrase: str) -> None:
    """Write a bodyless HTTP/1.1 error response with Connection: close."""
    response = (
        f"HTTP/1.1 {status} {phrase}\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    )
    writer.write(response.encode("latin-1"))


async def _handle(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    config,
    client: httpx.AsyncClient,
    tee: TeeLogger,
) -> None:
    """Per-connection request handler."""
    try:
        try:
            method, path, _version, req_headers = await _read_request_head(reader)
        except (EOFError, ValueError):
            return

        # Authenticate before reading the body, so unauthorized requests do no
        # upstream work.
        if not auth.verify_auth(req_headers, config.auth_token):
            _send_error(writer, 401, "Unauthorized")
            await _drain(writer)
            return

        # Reject oversize bodies up front when the client advertises the size.
        content_length = _get_header(req_headers, "content-length")
        if content_length is not None:
            try:
                if int(content_length) > MAX_BODY_BYTES:
                    _send_error(writer, 413, "Content Too Large")
                    await _drain(writer)
                    return
            except ValueError:
                pass

        body = await http_io.read_request_body(reader, req_headers)

        # Guard against a lying/absent Content-Length (e.g. chunked bodies).
        if len(body) > MAX_BODY_BYTES:
            _send_error(writer, 413, "Content Too Large")
            await _drain(writer)
            return

        shape = _normalize_shape(method, path)
        if shape is not None:
            body = _normalize_body(body, tee, shape)

        upstream_url = config.upstream.rstrip("/") + path
        headers = _build_upstream_headers(req_headers, body)

        try:
            async with client.stream(
                method, upstream_url, content=body, headers=headers
            ) as resp:
                writer.write(
                    f"HTTP/1.1 {resp.status_code} {resp.reason_phrase}\r\n".encode(
                        "latin-1"
                    )
                )
                for name, value in http_io.sanitize_response_headers(
                    list(resp.headers.items())
                ):
                    writer.write(f"{name}: {value}\r\n".encode("latin-1"))
                writer.write(b"\r\n")
                await _drain(writer)
                async for chunk in resp.aiter_raw():
                    writer.write(chunk)
                    await _drain(writer)
        except httpx.RequestError:
            _send_error(writer, 502, "Bad Gateway")
            await _drain(writer)
    except (OSError, ssl.SSLError, asyncio.IncompleteReadError, TimeoutError):
        # Peer reset/closed the connection, or stopped reading and a write
        # timed out (WRITE_TIMEOUT); nothing more to respond to.
        pass
    finally:
        writer.close()


def _normalize_body(body: bytes, tee: TeeLogger, shape: str) -> bytes:
    """Normalize a JSON body in the given shape; pass through on non-JSON.

    On any JSON decode failure the original bytes are forwarded unchanged, so a
    non-JSON POST is never dropped.
    """
    try:
        body_dict = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body

    normalized = normalize.apply_all(body_dict, shape=shape)
    if tee.enabled:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        tee.log(timestamp, body_dict, normalized, shape=shape)
    return json.dumps(
        normalized, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")


async def main() -> None:
    config = load_config()
    tee = TeeLogger(enabled=config.tee, log_dir=config.log_dir)

    ctx = None
    if config.tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        try:
            ctx.load_cert_chain(config.cert, config.key)
        except (FileNotFoundError, ssl.SSLError) as exc:
            sys.exit(
                f"[ccgw-proxy] failed to load TLS cert/key "
                f"({config.cert} / {config.key}): {exc}"
            )

    scheme = "https" if config.tls else "http"
    async with httpx.AsyncClient(timeout=None) as client:
        server = await asyncio.start_server(
            lambda r, w: _handle(r, w, config, client, tee),
            host=config.host,
            port=config.port,
            ssl=ctx,
        )
        print(
            f"[ccgw-proxy] listening on {scheme}://{config.host}:{config.port}"
            f" → {config.upstream}"
        )
        async with server:
            await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("[ccgw-proxy] shutting down", file=sys.stderr)
