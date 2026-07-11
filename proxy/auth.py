"""Bearer / API-key authentication for the ds4 reverse proxy."""

import hmac


def _get_header(headers: dict, name: str) -> str | None:
    """Case-insensitive header lookup."""
    for key, value in headers.items():
        if key.lower() == name:
            return value
    return None


def _constant_time_eq(a: str, b: str) -> bool:
    """Constant-time string comparison using hmac.compare_digest.

    compare_digest guards against timing side channels that a plain ``==``
    would leak. Both operands are encoded to bytes first.
    """
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def verify_auth(headers: dict, expected_token: str) -> bool:
    """Return True iff the request presents the expected token.

    Accepts the token from either:
      * Authorization: Bearer <token>
      * x-api-key: <token>

    An empty expected token or an empty presented token always fails, so a
    misconfigured/blank secret can never authenticate.
    """
    if not expected_token:
        return False

    # Collect every credential the request presents, then accept if ANY of
    # them matches. A wrong Bearer token must not veto a correct x-api-key.
    candidates: list[str] = []

    authorization = _get_header(headers, "authorization")
    if authorization is not None and authorization.startswith("Bearer "):
        candidates.append(authorization[len("Bearer "):])

    api_key = _get_header(headers, "x-api-key")
    if api_key is not None:
        candidates.append(api_key)

    for presented in candidates:
        if presented and _constant_time_eq(presented, expected_token):
            return True

    return False
