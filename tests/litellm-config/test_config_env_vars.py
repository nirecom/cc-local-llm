# Tests: litellm-server/config.yaml, .env.example
# Tags: scope:issue-specific, layer:TL1, config, env-vars
#
# Scenario (issue #41 / detail plan Phase 2): LiteLLM resolves every backend
# address, key and model name at startup through the `os.environ/<NAME>`
# pattern. A name that appears in config.yaml but not in .env.example is
# invisible until the service starts and hands the *literal string*
# "os.environ/FOO" to the backend — which surfaces downstream as an opaque
# upstream error, not as a config error. This suite closes that gap at TL1.
#
# Direction is deliberately one-way: config.yaml -> .env.example.
# The reverse (a documented variable nothing consumes) is NOT checked, because
# .env.example also documents proxy/, llama-swap/ and serverctl variables that
# LiteLLM legitimately never reads.
#
# TL3 gap: whether the values in .env.example actually resolve to a reachable
# backend (llama-swap on :18080, DS4 Proxy on :8443). Only a live stack can
# answer that. Closest-to-action mitigation: the manual cutover smoke run in
# docs/ops.md, executed at WORKFLOW_USER_VERIFIED.

import re
import subprocess
from pathlib import Path

import pytest

CONFIG_PATH = "litellm-server/config.yaml"
ENV_EXAMPLE_PATH = ".env.example"

_ENV_REF = re.compile(r"os\.environ/([A-Z0-9_]+)")


def _repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
        cwd=Path(__file__).resolve().parent,
    )
    return Path(result.stdout.strip())


def _read(rel: str) -> str:
    path = _repo_root() / rel
    assert path.is_file(), (
        f"{rel} not found — litellm-client/ must be git-mv'd to "
        "litellm-server/ (the config is server-side material now)"
    )
    return path.read_text(encoding="utf-8", errors="replace")


def _referenced_env_vars() -> list[str]:
    """Collection-safe: a missing config yields [], never an import-time error.

    Raising here would turn the whole module into a collection error and hide
    test_config_declares_at_least_one_env_reference, which is the case that
    reports the real problem.
    """
    path = _repo_root() / CONFIG_PATH
    if not path.is_file():
        return []
    return sorted(
        set(_ENV_REF.findall(path.read_text(encoding="utf-8", errors="replace")))
    )


def _declared_env_keys() -> set[str]:
    keys = set()
    for line in _read(ENV_EXAMPLE_PATH).splitlines():
        match = re.match(r"^([A-Z0-9_]+)=", line)
        if match:
            keys.add(match.group(1))
    return keys


def test_config_declares_at_least_one_env_reference():
    """Guard against a vacuously-green cross-check (one-sided classifier).

    If the `os.environ/` spelling ever changes (e.g. LiteLLM switches to
    `${VAR}`), the extraction silently returns [] and every parametrized case
    below disappears — the suite would report success while checking nothing.
    """
    assert (_repo_root() / CONFIG_PATH).is_file(), f"{CONFIG_PATH} not found"
    refs = _referenced_env_vars()
    assert refs, (
        f"no os.environ/<NAME> reference found in {CONFIG_PATH} — the "
        f"extraction regex {_ENV_REF.pattern!r} has drifted from the file's "
        "actual syntax, so the cross-check below is vacuous"
    )


def test_env_example_declares_keys():
    """Symmetric guard for the other side of the cross-check."""
    assert _declared_env_keys(), (
        f"no ^NAME= line parsed out of {ENV_EXAMPLE_PATH} — the key extraction "
        "has drifted and every lookup below would fail for the wrong reason"
    )


@pytest.mark.parametrize("name", _referenced_env_vars())
def test_referenced_env_var_is_documented_in_env_example(name):
    declared = _declared_env_keys()
    assert name in declared, (
        f"{CONFIG_PATH} resolves os.environ/{name}, but {ENV_EXAMPLE_PATH} has "
        f"no `{name}=` line. LiteLLM does not fail on an unset name — it passes "
        f"the literal string 'os.environ/{name}' to the backend, so the mistake "
        "only surfaces as an opaque upstream error at request time."
    )


def test_no_retired_env_var_is_still_referenced():
    """The Windows/Docker-era names must not survive in the server config.

    Cross-checked against tests/ccgw-naming/test_no_legacy_names.py, which bans
    the same names repo-wide; this case pins the specific failure mode that
    matters here — a stale reference that still *resolves*, silently routing
    the opus/fable models at the wrong origin.
    """
    retired = {
        "LITELLM_OPUS_URL",
        "LITELLM_OPUS_API_KEY",
        "LITELLM_DS4_URL",
        "LITELLM_DS4_API_KEY",
    }
    still_there = retired.intersection(_referenced_env_vars())
    assert not still_there, (
        f"{CONFIG_PATH} still references retired env var(s): "
        f"{sorted(still_there)} — the opus and fable routes share the single "
        "LITELLM_DS4_PROXY_URL / LITELLM_DS4_PROXY_API_KEY pair now"
    )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
