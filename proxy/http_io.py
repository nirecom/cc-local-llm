"""HTTP framing helpers for the ds4 reverse proxy.

Two concerns:
  * read_request_body        - drain a request body from an asyncio stream,
                               honoring Content-Length and chunked transfer
                               encoding.
  * sanitize_response_headers - strip hop-by-hop headers before relaying an
                               upstream response to the client, and force
                               "Connection: close".
"""

import asyncio

# RFC 7230 section 6.1 hop-by-hop headers. These are meaningful only for a
# single transport-level connection and must never be forwarded by a proxy.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def _get_header(headers: dict, name: str) -> str | None:
    """Case-insensitive header lookup."""
    for key, value in headers.items():
        if key.lower() == name:
            return value
    return None


async def read_request_body(reader: asyncio.StreamReader, headers: dict) -> bytes:
    """Read a request body from ``reader``.

    Resolution order:
      1. Content-Length  -> read exactly that many bytes.
      2. Transfer-Encoding contains "chunked" -> decode the chunked body.
      3. Otherwise -> return b"".
    """
    content_length = _get_header(headers, "content-length")
    if content_length is not None:
        return await reader.readexactly(int(content_length))

    transfer_encoding = _get_header(headers, "transfer-encoding")
    if transfer_encoding is not None and "chunked" in transfer_encoding.lower():
        return await _read_chunked(reader)

    return b""


async def _read_chunked(reader: asyncio.StreamReader) -> bytes:
    """Decode a chunked transfer-encoded body into its concatenated payload."""
    chunks: list[bytes] = []
    while True:
        size_line = await reader.readline()
        if not size_line:
            # EOF before any chunk data — stream closed mid-message.
            raise asyncio.IncompleteReadError(b'', None)
        # A chunk-size line may carry extensions after a ';'; ignore them.
        size_token = size_line.split(b";", 1)[0].strip()
        if not size_token:
            # Blank line before the first size (defensive) -> keep reading.
            continue
        chunk_size = int(size_token, 16)
        if chunk_size == 0:
            # Last chunk. Drain all trailer header lines up to and including
            # the terminating blank line (CRLF-only line), per RFC 7230 §4.1.2.
            while True:
                line = await reader.readline()
                if line in (b'\r\n', b'\n', b''):
                    break
            break
        data = await reader.readexactly(chunk_size)
        chunks.append(data)
        # Each chunk's data is followed by a CRLF that is not part of the body.
        await reader.readexactly(2)
    return b"".join(chunks)


def sanitize_response_headers(upstream_headers: list[tuple]) -> list[tuple]:
    """Strip hop-by-hop headers (case-insensitive) and force Connection: close.

    In addition to the standard HOP_BY_HOP set, RFC 7230 section 6.1 requires
    that any header name listed in the Connection header's value is itself
    treated as hop-by-hop and stripped (e.g. ``Connection: X-Debug`` marks
    ``X-Debug`` as connection-specific).

    Returns the surviving end-to-end headers followed by a single
    ("Connection", "close") entry. An empty input yields exactly
    [("Connection", "close")].
    """
    # Collect names nominated as hop-by-hop by any Connection header value.
    nominated: set[str] = set()
    for name, value in upstream_headers:
        if name.lower() == "connection":
            for token in value.split(","):
                token = token.strip().lower()
                if token:
                    nominated.add(token)

    result: list[tuple] = []
    for name, value in upstream_headers:
        lname = name.lower()
        if lname in HOP_BY_HOP or lname in nominated:
            continue
        result.append((name, value))
    result.append(("Connection", "close"))
    return result
