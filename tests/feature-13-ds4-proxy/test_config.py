# Tests: proxy/config.py
# Tags: scope:issue-specific
#
# Scenario: load_config() upstream routing target — Laguna S 2.1 / llama-swap
# migration changed the default DS4_PROXY_UPSTREAM from the old direct
# ds4-server address (http://127.0.0.1:8000) to the Mac llama-swap listener
# (http://127.0.0.1:18080). This is a real routing-target behavior change
# with zero prior test coverage (no test file referenced DS4_PROXY_UPSTREAM
# or load_config() before this file).
#
# L3 gap: none (pure function, no I/O beyond os.environ)

from proxy.config import load_config


def test_load_config_default_upstream_is_llama_swap(monkeypatch):
    # Regression guard for this session's routing change: with
    # DS4_PROXY_UPSTREAM unset, the proxy must default to the llama-swap
    # port (18080), NOT the old ds4-server-direct port (8000).
    monkeypatch.delenv("DS4_PROXY_UPSTREAM", raising=False)
    monkeypatch.setenv("DS4_PROXY_AUTH_TOKEN", "test-token")

    config = load_config()

    assert config.upstream == "http://127.0.0.1:18080"
    assert config.upstream != "http://127.0.0.1:8000"


def test_load_config_upstream_override_is_honored(monkeypatch):
    # An explicit DS4_PROXY_UPSTREAM must still be honored verbatim (e.g. for
    # a direct-to-ds4-server debug session bypassing llama-swap).
    monkeypatch.setenv("DS4_PROXY_UPSTREAM", "http://127.0.0.1:8000")
    monkeypatch.setenv("DS4_PROXY_AUTH_TOKEN", "test-token")

    config = load_config()

    assert config.upstream == "http://127.0.0.1:8000"
