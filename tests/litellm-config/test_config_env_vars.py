# Tests: litellm-server/config.yaml, .env.example
# Tags: scope:issue-specific, layer:TL1, config, env-vars
#
# Scenario (issue #41 / detail plan Phase 2): LiteLLM resolves every backend
# address and credential at startup through the `os.environ/<NAME>` pattern.
# Routing keys are NOT among them since issue #89 -- each `model_name` is a
# literal owned by config.yaml itself, pinned by test_route_tier_annotations.py.
# A name in config.yaml but not in .env.example is invisible until startup
# hands the *literal string* "os.environ/FOO" to the backend, surfacing as an
# opaque upstream error rather than a config error. TL1 closes that gap.

import re
import subprocess
from pathlib import Path

import pytest

# Direction is deliberately one-way: config.yaml -> .env.example. The reverse
# (a documented variable nothing consumes) is NOT checked -- .env.example also
# documents proxy/, llama-swap/ and serverctl variables LiteLLM never reads.
CONFIG_PATH = "litellm-server/config.yaml"

# TL3 gap: whether the values in .env.example resolve to a reachable backend
# (llama-swap on :18080, CCGW Proxy on :8443). Only a live stack can answer
# that; mitigation is the docs/ops.md cutover smoke run at USER_VERIFIED.
ENV_EXAMPLE_PATH = ".env.example"

_ENV_REF = re.compile(r"os\.environ/([A-Z0-9_]+)")

# The per-machine routing keys retired by issue #89. Named once and used on
# both sides of the migration (CPR-SSOT): they must be gone from the config's
# os.environ/ references AND from the documented .env keys.
ROUTING_KEYS = {
    "LITELLM_HAIKU_MODEL",
    "LITELLM_SONNET_MODEL",
    "LITELLM_FABLE_MODEL",
    "LITELLM_OPUS_MODEL",
    "CCGW_SUBAGENT_MODEL",
}


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
    } | ROUTING_KEYS
    still_there = retired.intersection(_referenced_env_vars())
    assert not still_there, (
        f"{CONFIG_PATH} still references retired env var(s): "
        f"{sorted(still_there)} — the opus and fable routes share the single "
        "LITELLM_CCGW_PROXY_URL / LITELLM_CCGW_PROXY_API_KEY pair now, and a "
        "route's own name is a literal (issue #89), not an os.environ/ lookup"
    )


def test_routing_keys_are_no_longer_declared_in_env_example():
    """The other half of the migration, and the one that actually bites.

    Removing the `os.environ/` reference alone leaves the old lines in every
    machine's .env, where load-dotenv still exports them; a launcher that keeps
    any fallback to the shell value would then go on serving the stale name
    from before the backend swap -- the 2026-08-22 failure, unchanged. Deleting
    the documented keys is what stops a fresh checkout from re-seeding them.
    """
    still_declared = ROUTING_KEYS.intersection(_declared_env_keys())
    assert not still_declared, (
        f"{ENV_EXAMPLE_PATH} still declares {sorted(still_declared)} — routing "
        f"keys are owned by {CONFIG_PATH}'s `ccgw_tiers` annotations now, and a "
        "documented key is how the per-machine drift got re-seeded on every "
        "new checkout"
    )


def test_routing_key_names_are_gone_from_env_example_entirely():
    """Catches a key surviving as a comment, which the `KEY=` scan above misses."""
    content = _read(ENV_EXAMPLE_PATH)
    surviving = sorted(name for name in ROUTING_KEYS if name in content)
    assert not surviving, (
        f"{ENV_EXAMPLE_PATH} still mentions {surviving} in raw text — routing "
        f"keys live in {CONFIG_PATH}'s `ccgw_tiers` annotations now; see "
        "docs/ops.md for the migration note"
    )


AUTO_PULL_KEY = "CCGW_AUTO_PULL"


def _declared_value(key: str) -> str | None:
    """The value on the `key=` line of .env.example, or None if there is none."""
    for line in _read(ENV_EXAMPLE_PATH).splitlines():
        match = re.match(rf"^{re.escape(key)}=(.*)$", line)
        if match:
            return match.group(1).split("#", 1)[0].strip()
    return None


def _comment_block_above(key: str) -> str:
    """The contiguous run of comment lines immediately above the `key=` line."""
    lines = _read(ENV_EXAMPLE_PATH).splitlines()
    for index, line in enumerate(lines):
        if not line.startswith(f"{key}="):
            continue
        block = []
        cursor = index - 1
        while cursor >= 0 and lines[cursor].lstrip().startswith("#"):
            block.append(lines[cursor])
            cursor -= 1
        return "\n".join(reversed(block))
    return ""


def test_auto_pull_is_declared_with_on_as_the_shipped_default():
    """A fresh checkout must self-update, and say so on the line itself.

    The pull is what carries a routing decision from the machine that made it to
    every other host (issue #89). Leaving the key undocumented would make the
    default invisible: an operator surprised by a launch that moved HEAD has
    nowhere to look, and one who wants it off has nothing to copy.
    """
    value = _declared_value(AUTO_PULL_KEY)
    assert value is not None, (
        f"{ENV_EXAMPLE_PATH} has no `{AUTO_PULL_KEY}=` line — the launcher pulls "
        "before every launch now, and an undocumented default is one an operator "
        "can neither expect nor turn off"
    )
    assert value == "on", (
        f"{ENV_EXAMPLE_PATH} ships `{AUTO_PULL_KEY}={value}` — the default is "
        "`on`, and a checkout seeded with anything else silently stops tracking "
        "the routing table it is supposed to follow"
    )


def test_auto_pull_documents_both_switch_positions():
    """`on` alone reads as a constant; the opt-out has to be written down.

    The values are the launcher's, not free text: anything that is not exactly
    `on` disables the pull, so `off` is the spelling an operator must be told to
    use rather than left to guess at (`false`, `0`, `no` all silently work by
    accident today and would not survive a stricter parser).
    """
    block = _comment_block_above(AUTO_PULL_KEY)
    assert block, (
        f"{ENV_EXAMPLE_PATH} declares {AUTO_PULL_KEY} with no comment above it — "
        "a bare on/off switch on a network operation needs its two positions and "
        "its consequence stated"
    )
    lowered = block.lower()
    for position in ("on", "off"):
        assert re.search(rf"\b{position}\b", lowered), (
            f"the {AUTO_PULL_KEY} comment in {ENV_EXAMPLE_PATH} never mentions "
            f"`{position}` — both positions of the switch must be documented "
            f"where the key is declared, got: {block!r}"
        )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
