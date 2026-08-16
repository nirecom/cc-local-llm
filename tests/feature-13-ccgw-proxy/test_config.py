# Tests: proxy/config.py
# Tags: scope:issue-specific
#
# Scenario: load_config() upstream routing target — Laguna S 2.1 / llama-swap
# migration changed the default CCGW_PROXY_UPSTREAM from the old direct
# ds4-server address (http://127.0.0.1:8000) to the Mac llama-swap listener
# (http://127.0.0.1:18080). This is a real routing-target behavior change
# with zero prior test coverage (no test file referenced CCGW_PROXY_UPSTREAM
# or load_config() before this file).
#
# L3 gap: none (pure function, no I/O beyond os.environ)

import pytest

from proxy.config import load_config


def test_load_config_default_upstream_is_llama_swap(monkeypatch):
    # Regression guard for this session's routing change: with
    # CCGW_PROXY_UPSTREAM unset, the proxy must default to the llama-swap
    # port (18080), NOT the old ds4-server-direct port (8000).
    monkeypatch.delenv("CCGW_PROXY_UPSTREAM", raising=False)
    monkeypatch.setenv("CCGW_PROXY_AUTH_TOKEN", "test-token")

    config = load_config()

    assert config.upstream == "http://127.0.0.1:18080"
    assert config.upstream != "http://127.0.0.1:8000"


def test_load_config_upstream_override_is_honored(monkeypatch):
    # An explicit CCGW_PROXY_UPSTREAM must still be honored verbatim (e.g. for
    # a direct-to-ds4-server debug session bypassing llama-swap).
    monkeypatch.setenv("CCGW_PROXY_UPSTREAM", "http://127.0.0.1:8000")
    monkeypatch.setenv("CCGW_PROXY_AUTH_TOKEN", "test-token")

    config = load_config()

    assert config.upstream == "http://127.0.0.1:8000"


# ===========================================================================
# CCGW_PROXY_TLS / CCGW_PROXY_HOST (issue #41 / detail plan D4, D4a)
#
# The proxy becomes a loopback plaintext hop in the final topology, but the
# demotion must be a reversible .env toggle, not a code change: during the
# cutover the old Windows LiteLLM still connects over HTTPS. The shipped code
# default therefore stays TLS ON / bind 0.0.0.0 — asserted here so a
# well-meaning "we're plaintext now" change cannot silently break the cutover.
#
# Every case pins the variable explicitly (config-dependent branch): the
# developer's ambient .env must never decide the verdict.
# ===========================================================================

_TLS_HOST_VARS = ("CCGW_PROXY_TLS", "CCGW_PROXY_HOST")


def _clear(monkeypatch):
    for name in _TLS_HOST_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("CCGW_PROXY_AUTH_TOKEN", "test-token")


def test_tls_defaults_to_on_when_unset(monkeypatch):
    _clear(monkeypatch)

    assert load_config().tls is True


@pytest.mark.parametrize("value", ["on", "ON", "On"])
def test_tls_explicit_on_is_honored(monkeypatch, value):
    _clear(monkeypatch)
    monkeypatch.setenv("CCGW_PROXY_TLS", value)

    assert load_config().tls is True


def test_tls_off_is_honored(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("CCGW_PROXY_TLS", "off")

    assert load_config().tls is False


@pytest.mark.parametrize(
    "value", ["", "0", "false", "no", "yes", "true", "1", "onn"]
)
def test_tls_non_off_values_fail_safe_to_on(monkeypatch, value):
    """Anything that is not the literal "off" must keep TLS enabled.

    Fail-safe direction: a typo'd CCGW_PROXY_TLS must never silently expose a
    plaintext listener on 0.0.0.0.
    """
    _clear(monkeypatch)
    monkeypatch.setenv("CCGW_PROXY_TLS", value)

    assert load_config().tls is True


def test_host_defaults_to_all_interfaces(monkeypatch):
    _clear(monkeypatch)

    assert load_config().host == "0.0.0.0"


def test_host_override_is_honored(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("CCGW_PROXY_HOST", "127.0.0.1")

    assert load_config().host == "127.0.0.1"


def test_tls_and_host_are_independent_toggles(monkeypatch):
    """The final topology sets both at once; neither may imply the other.

    D4a's four-variable simultaneous switch is an operational procedure, not a
    code coupling — a config that derived host from tls would make the
    documented partial-switch failure impossible to reproduce.
    """
    _clear(monkeypatch)
    monkeypatch.setenv("CCGW_PROXY_TLS", "off")
    config = load_config()
    assert config.tls is False
    assert config.host == "0.0.0.0"

    _clear(monkeypatch)
    monkeypatch.setenv("CCGW_PROXY_HOST", "127.0.0.1")
    config = load_config()
    assert config.tls is True
    assert config.host == "127.0.0.1"
