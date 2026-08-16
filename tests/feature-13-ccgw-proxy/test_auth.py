# Tests: proxy/auth.py
# Tags: scope:issue-specific
#
# L3 gap (what this test suite does NOT catch — explicitly deferred):
# - Real asyncio TLS handshake behavior with mkcert certificates
# - End-to-end auth header validation through the full proxy handler pipeline
# - Security idempotency (repeated starts, duplicate CA/env entries: deferred
#     to post-/write-code environment-level tests)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required

import pytest

from proxy import auth


# ===========================================================================
# proxy/auth.py — verify_auth
# ===========================================================================

TOKEN = "s3cr3t-token-value"


def test_28_verify_auth_bearer_correct():
    headers = {"Authorization": f"Bearer {TOKEN}"}
    assert auth.verify_auth(headers, TOKEN) is True


def test_29_verify_auth_x_api_key_correct():
    headers = {"x-api-key": TOKEN}
    assert auth.verify_auth(headers, TOKEN) is True


def test_30_verify_auth_wrong_token():
    headers = {"Authorization": "Bearer wrong-token"}
    assert auth.verify_auth(headers, TOKEN) is False


def test_31_verify_auth_no_headers():
    assert auth.verify_auth({}, TOKEN) is False


def test_32_verify_auth_uses_compare_digest(monkeypatch):
    # Verify hmac.compare_digest is actually invoked at runtime (not merely
    # present in the source): patch the module-level reference auth.py uses and
    # record the calls.
    calls = []
    import hmac as hmac_mod
    original = hmac_mod.compare_digest

    def recording(a, b):
        calls.append((a, b))
        return original(a, b)

    monkeypatch.setattr(hmac_mod, "compare_digest", recording)
    result = auth.verify_auth({"authorization": "Bearer secret"}, "secret")
    assert result is True
    assert len(calls) >= 1, "hmac.compare_digest was not called"


def test_33_verify_auth_empty_token_fails():
    # Even when the expected token is empty, an empty presented token fails.
    headers = {"x-api-key": ""}
    assert auth.verify_auth(headers, "") is False


def test_34_verify_auth_missing_bearer_prefix():
    headers = {"Authorization": TOKEN}  # no "Bearer " prefix
    assert auth.verify_auth(headers, TOKEN) is False


# --- C10: auth edge cases --------------------------------------------------

def test_34a_authorization_header_lookup_case_insensitive():
    # Lower-cased header name must still be found (case-insensitive lookup).
    headers = {"authorization": f"Bearer {TOKEN}"}
    assert auth.verify_auth(headers, TOKEN) is True


def test_34b_token_with_surrounding_whitespace_rejected():
    # A trailing space makes the presented token differ from the expected one;
    # the comparison is strict, so this must NOT match.
    headers = {"Authorization": f"Bearer {TOKEN} "}
    assert auth.verify_auth(headers, TOKEN) is False


def test_34c_lowercase_bearer_prefix_rejected():
    # Only the exact "Bearer " prefix is accepted; "bearer " does not match.
    headers = {"Authorization": f"bearer {TOKEN}"}
    assert auth.verify_auth(headers, TOKEN) is False


def test_34d_wrong_bearer_but_correct_x_api_key_succeeds():
    # A wrong Bearer token must not veto a correct x-api-key: the request
    # presents a valid credential via x-api-key, so auth succeeds.
    headers = {"Authorization": "Bearer wrong-token", "x-api-key": TOKEN}
    assert auth.verify_auth(headers, TOKEN) is True


def test_34e_verify_auth_returns_bool_not_string():
    # The return type is always bool — never a string that could embed the token.
    result = auth.verify_auth({"Authorization": "Bearer wrong"}, TOKEN)
    assert result is False
    assert isinstance(result, bool)


def test_34f_empty_bearer_value_rejected():
    # "Bearer " with nothing after the prefix: presented token is empty string,
    # which is rejected even if the expected token is also empty (guard fires).
    headers = {"Authorization": "Bearer "}
    assert auth.verify_auth(headers, TOKEN) is False


def test_34g_empty_x_api_key_rejected():
    # x-api-key with empty value should fail regardless of expected token.
    headers = {"x-api-key": ""}
    assert auth.verify_auth(headers, TOKEN) is False


def test_34h_x_api_key_mixedcase_accepted():
    # verify_auth uses case-insensitive header lookup (_get_header).
    # Mixed-case variants of x-api-key must be found and accepted.
    assert auth.verify_auth({"X-API-Key": TOKEN}, TOKEN) is True
    assert auth.verify_auth({"X-Api-Key": TOKEN}, TOKEN) is True
    assert auth.verify_auth({"X-API-KEY": TOKEN}, TOKEN) is True
