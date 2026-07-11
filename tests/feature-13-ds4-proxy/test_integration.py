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

import pytest

from proxy import auth, normalize


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


# (L3 gaps documented in file header)

if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
