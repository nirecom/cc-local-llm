# Tests: litellm/docker-compose.yml, litellm/config.yaml, scripts/*.cmd, .env.example, docs/*.md
# Tags: scope:issue-specific, layer:TL1
#
# TL1 gap (what this test suite does NOT catch — explicitly deferred):
# - Whether the renamed Compose project name actually resolves the 401 auth bug
#     (requires a live LiteLLM + Postgres stack; TL3)
# - Whether the renamed .cmd launchers still start Claude Code successfully
#     (requires a real Windows shell; TL3, category pwsh-required)
# - context_window additions in config.yaml (Haiku=32768, Sonnet=32768, Opus=393216)
#     are in the main worktree's uncommitted diff and are NOT part of this rename PR;
#     they are separate tuning work. Coverage deferred to that PR.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required

import subprocess
from pathlib import Path

import pytest

LEGACY_TOKENS = [
    "ds4-litellm",
    "ds4-litellm-postgres",
    "LITELLM_DS4_URL",
    "LITELLM_DS4_API_KEY",
    "LITELLM_LLAMA_SWAP_URL",
    "code-ds4.cmd",
    "vscode-ds4",
    "nirecom/ds4-ops",
    "[ds4-ops]",
]

# docs/history.md is an append-only historical record.
HISTORY_PATH = "docs/history.md"

# This test file necessarily carries every legacy token as data.
SELF_PATH = "tests/ccgw-naming/test_no_legacy_names.py"

EXCLUDED_PATHS = {HISTORY_PATH, SELF_PATH}

# These name the DS4 Proxy backend directly, not the ccgw gateway — the rename
# must not touch them.
RETAINED_ENV_VARS = [
    "DS4_ANTHROPIC_BASE_URL",
    "DS4_API_KEY",
    "DS4_CA_CERT",
]

LAUNCHER_PATH = "scripts/code-ccgw.cmd"

# New env var names that must appear in the gateway source files after rename.
NEW_GATEWAY_ENV_VARS = [
    "LITELLM_OPUS_URL",
    "LITELLM_OPUS_API_KEY",
    "LITELLM_HAIKU_URL",
    "LITELLM_SONNET_URL",
]

# Files where the new env var names are expected to appear.
NEW_ENV_SOURCE_FILES = [
    "litellm/docker-compose.yml",
    "litellm/config.yaml",
]

COMPOSE_FILE = "litellm/docker-compose.yml"


def _repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
        cwd=Path(__file__).resolve().parent,
    )
    return Path(result.stdout.strip())


def _tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files"],
        capture_output=True,
        text=True,
        check=True,
        cwd=root,
    )
    return [line for line in result.stdout.splitlines() if line]


def _scannable_files() -> list[tuple[str, Path]]:
    root = _repo_root()
    return [
        (rel, root / rel)
        for rel in _tracked_files(root)
        if rel not in EXCLUDED_PATHS
    ]


@pytest.mark.parametrize("token", LEGACY_TOKENS)
def test_legacy_token_absent_from_tracked_files(token):
    hits = []
    for rel, path in _scannable_files():
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for lineno, line in enumerate(lines, start=1):
            if token in line:
                hits.append(f"  {rel}:{lineno}: {line.strip()}")

    assert not hits, (
        f"legacy token {token!r} still present in {len(hits)} location(s) — "
        f"rename to the ccgw- scheme:\n" + "\n".join(hits)
    )


def test_exclusion_paths_resolve():
    root = _repo_root()
    assert (root / HISTORY_PATH).is_file(), (
        f"{HISTORY_PATH} does not exist — the exclusion is silently doing "
        "nothing (moved or renamed?)"
    )
    assert Path(__file__).resolve() == (root / SELF_PATH).resolve(), (
        f"SELF_PATH ({SELF_PATH}) no longer points at this test file — the "
        "self-exclusion would break and this test would report itself"
    )


@pytest.mark.parametrize("env_var", RETAINED_ENV_VARS)
def test_retained_ds4_backend_env_var_still_referenced(env_var):
    launcher = _repo_root() / LAUNCHER_PATH
    assert launcher.is_file(), (
        f"{LAUNCHER_PATH} not found — the launcher must be git-mv'd from "
        f"scripts/code-ds4.cmd as part of the ccgw rename"
    )
    content = launcher.read_text(encoding="utf-8", errors="replace")
    assert env_var in content, (
        f"{env_var} no longer appears in {LAUNCHER_PATH} — this variable names "
        f"the DS4 Proxy backend, not the ccgw gateway, and must survive the "
        f"rename (over-replacement bug)"
    )


def test_compose_project_name_pinned():
    compose = _repo_root() / COMPOSE_FILE
    lines = compose.read_text(encoding="utf-8", errors="replace").splitlines()
    assert any("name: ccgw" in line for line in lines), (
        f"{COMPOSE_FILE} must have a top-level `name: ccgw` line to pin the "
        "Compose project name (fixes the 401 volume-mismatch root cause)"
    )


@pytest.mark.parametrize("env_var", NEW_GATEWAY_ENV_VARS)
def test_new_gateway_env_var_wired_in_source_files(env_var):
    root = _repo_root()
    for rel in NEW_ENV_SOURCE_FILES:
        path = root / rel
        content = path.read_text(encoding="utf-8", errors="replace")
        assert env_var in content, (
            f"{env_var} must appear in {rel} after the rename — the env var "
            "passthrough in docker-compose.yml and the os.environ/ reference in "
            f"config.yaml must both use the new name"
        )
