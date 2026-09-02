# Tests: litellm-server/config.yaml, scripts/code-ccgw.sh, scripts/code-ccgw.ps1, .env.example, docs/history.md
# Tags: scope:issue-specific, layer:TL1
#
# TL1 gap (not covered here — needs live services or host-state checks; TL3):
# - Whether the renamed LiteLLM config actually serves the four model routes
# - Whether scripts/code-ccgw.sh still starts Claude Code against the gateway
# - Whether retired Windows Docker assets are gone from the developer's machine
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: pwsh-required

import re
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
    # Repo clone path (POSIX and Windows spellings) and the macOS run dir.
    "git/ds4-ops",
    "git\\ds4-ops",
    "ds4-ops/run",
    # --- issue #41: the Windows-side LiteLLM/Docker deployment is retired -----
    # The gateway moves to a native Mac service, so the client-side directory,
    # the Compose container name, and every PowerShell bootstrap script that
    # existed only to run Docker Desktop on Windows must disappear.
    "litellm-client",
    # Docker-context-qualified on purpose (issue #51): the bare string
    # `ccgw-litellm` is now the tail of the legitimate launchd label
    # `com.nire.ccgw-litellm`, so banning it unqualified would flag the very
    # name this rename introduces. Only the Compose `container_name:` spelling
    # is retired.
    "container_name: ccgw-litellm",
    "litellm-start.ps1",
    "setup-litellm.ps1",
    "generate-litellm-key.ps1",
    "docker-desktop.ps1",
    # --- issue #41: env vars retired with the Windows deployment --------------
    # The opus route now shares the single gateway proxy origin
    # (LITELLM_CCGW_PROXY_URL), and TLS/CA/DB/config-dir variables belonged to
    # the Docker stack only.
    "LITELLM_OPUS_URL",
    "LITELLM_OPUS_API_KEY",
    "LITELLM_TLS_DIR",
    "LITELLM_CA_CERT_FILE",
    "LITELLM_DB_URL",
    "LITELLM_CONFIG_DIR",
    # --- issue #41: client-side variables collapsed into one launcher path ----
    # code-ccgw no longer branches on a per-user gateway URL/key/model triple.
    "CCGW_ANTHROPIC_BASE_URL",
    "CCGW_API_KEY",
    "CCGW_DEFAULT_MODEL",
    # --- issue #41: direct-to-DS4-Proxy client variables retired --------------
    # Claude Code never talks to the proxy directly any more; it goes through
    # LiteLLM. These three previously bypassed the gateway entirely.
    "DS4_ANTHROPIC_BASE_URL",
    "DS4_API_KEY",
    "DS4_CA_CERT",
    # --- issue #51: the shared DS4_ operator prefix becomes CCGW_ -------------
    # Why: these configure the *gateway* (logging, run/ops/script roots, the
    # reverse proxy, LiteLLM's route to it), not the DeepSeek V4 Flash backend —
    # naming them after one backend model became misleading once llama-swap
    # started fronting several. Deliberately ABSENT: DS4_SERVER_HOST/ROOT/
    # COLOR_LOG, DS4_THINK_MAX_MIN_CONTEXT (still accurately name that server;
    # no bare `DS4_` prefix token appears here for the same reason). DS4_LOG
    # subsumes DS4_LOG_COLOR/DS4_LOG_TAIL_LINES but not DS4_SERVER_COLOR_LOG.
    "DS4_LOG",
    "DS4_RUN_DIR",
    "DS4_OPS_ROOT",
    "DS4_SCRIPT_DIR",
    "DS4_PROXY_AUTH_TOKEN",
    "DS4_PROXY_UPSTREAM",
    "DS4_PROXY_HOST",
    "DS4_PROXY_PORT",
    "DS4_PROXY_TLS",
    "DS4_PROXY_CERT",
    "DS4_PROXY_KEY",
    "DS4_PROXY_TEE",
    "DS4_PROXY_LOG_DIR",
    "LITELLM_DS4_PROXY_URL",
    "LITELLM_DS4_PROXY_OPENAI_URL",
    "LITELLM_DS4_PROXY_API_KEY",
    # --- issue #51: the ds4-proxy component becomes ccgw-proxy ---------------
    # The component name (launcher script, log directory, package name) and the
    # three launchd labels that ship with the gateway services.
    #
    # The labels are spelled in FULL on purpose. The bare prefix
    # `com.nire.ds4-` would also match `com.nire.ds4-server`, the label of the
    # DeepSeek V4 Flash backend, which must survive this rename untouched —
    # each label's near-miss control pins exactly that boundary.
    "ds4-proxy",
    "com.nire.ds4-proxy",
    "com.nire.ds4-llama-swap",
    "com.nire.ds4-litellm",
]

# NOTE: LITELLM_VIRTUAL_KEY is deliberately absent. It survives one deprecation
# cycle as an alias for LITELLM_CLIENT_KEY, so banning it now would fail against
# the intended transitional state.

# docs/history.md is an append-only historical record.
HISTORY_PATH = "docs/history.md"

# This test file necessarily carries every legacy token as data.
SELF_PATH = "tests/ccgw-naming/test_no_legacy_names.py"

# Asserts the *absence* of retired env vars by naming them as literal fixture
# data (test_no_retired_env_var_is_still_referenced) — same rationale as SELF_PATH.
CONFIG_ENV_VARS_TEST_PATH = "tests/litellm-config/test_config_env_vars.py"

EXCLUDED_PATHS = {HISTORY_PATH, SELF_PATH, CONFIG_ENV_VARS_TEST_PATH}

# New env var names that must appear in the gateway source files after the move.
# Connection endpoints only -- the LITELLM_*_MODEL routing keys are excluded:
# they route via config.yaml's `ccgw_tiers` now, and warnings/docs must still be
# able to write their names. Their absence is pinned by
# tests/litellm-config/test_config_env_vars.py instead.
NEW_GATEWAY_ENV_VARS = [
    "LITELLM_CCGW_PROXY_URL",
    "LITELLM_CCGW_PROXY_OPENAI_URL",
    "LITELLM_CCGW_PROXY_API_KEY",
    "LITELLM_LLAMASWAP_URL",
]

# Files where the new env var names are expected to appear.
NEW_ENV_SOURCE_FILES = [
    "litellm-server/config.yaml",
]

# Every LEGACY_TOKEN is scanned with the same raw substring rule
# (`if token in line`), so each needs a positive control (proves it *can*
# match) and a near-miss (proves it does not over-match) — without these a
# typo'd token would silently pass test_legacy_token_absent_from_tracked_files
# forever. The near-miss is, wherever possible, the *replacement* spelling
# this rename introduces, so the control also proves the ban cannot flag it.
# (token, line that must match, line that must NOT match)
PATH_TOKEN_CONTROLS = [
    (
        "ds4-litellm",
        "  container_name: ds4-litellm",
        "  brew services restart litellm",
    ),
    (
        "ds4-litellm-postgres",
        "    depends_on: [ds4-litellm-postgres]",
        "    depends_on: [ds4-litellm-db]",
    ),
    (
        "LITELLM_DS4_URL",
        "LITELLM_DS4_URL=https://127.0.0.1:8443",
        "LITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443",
    ),
    (
        "LITELLM_DS4_API_KEY",
        "LITELLM_DS4_API_KEY=sk-example-value",
        "LITELLM_CCGW_PROXY_API_KEY=sk-example-value",
    ),
    (
        "LITELLM_LLAMA_SWAP_URL",
        "LITELLM_LLAMA_SWAP_URL=http://127.0.0.1:18080/v1",
        "LITELLM_LLAMASWAP_URL=http://127.0.0.1:18080/v1",
    ),
    (
        "code-ds4.cmd",
        "doskey cc=code-ds4.cmd $*",
        "doskey cc=code-ccgw.cmd $*",
    ),
    (
        "vscode-ds4",
        "alias vscode-ds4='code --profile ds4'",
        "alias vscode-ccgw='code --profile ccgw'",
    ),
    (
        "nirecom/ds4-ops",
        "git clone https://github.com/nirecom/ds4-ops.git",
        "git clone https://github.com/nirecom/cc-local-llm.git",
    ),
    (
        "[ds4-ops]",
        "echo \"[ds4-ops] starting proxy\"",
        "echo \"[cc-local-llm] starting proxy\"",
    ),
    (
        "git/ds4-ops",
        "DOTENV_FILE=\"$HOME/git/ds4-ops/.env\"",
        "DOTENV_FILE=\"$HOME/git/cc-local-llm/.env\"",
    ),
    (
        # Single backslash — the Windows spelling as it appears in raw file
        # bytes (e.g. `C:\git\ds4-ops\litellm` in .env.example).
        "git\\ds4-ops",
        "LITELLM_CONFIG_DIR=C:\\git\\ds4-ops\\litellm",
        # Double backslash — a Windows path *escaped inside a source string
        # literal*. Deliberately NOT matched: see
        # test_feature_13_fixtures_scanned_and_clean.
        "\"Working directory: C:\\\\git\\\\ds4-ops\\n\"",
    ),
    (
        "ds4-ops/run",
        'CCGW_RUN_DIR="$HOME/Library/Application Support/ds4-ops/run"',
        'CCGW_RUN_DIR="$HOME/Library/Application Support/ds4-ops-run"',
    ),
    # --- issue #41 additions -------------------------------------------------
    (
        "litellm-client",
        "LITELLM_CONFIG_DIR=C:\\git\\cc-local-llm\\litellm-client",
        "  - litellm-server/config.yaml",
    ),
    (
        # Qualified with the Compose key so the ban cannot reach the launchd
        # label `com.nire.ccgw-litellm` that issue #51 introduces — the
        # near-miss below is that exact label.
        "container_name: ccgw-litellm",
        "  container_name: ccgw-litellm",
        "  <key>Label</key><string>com.nire.ccgw-litellm</string>",
    ),
    (
        "litellm-start.ps1",
        "powershell -NoProfile -File scripts\\litellm-start.ps1",
        "scripts/litellm.sh",
    ),
    (
        "setup-litellm.ps1",
        ".\\scripts\\setup-litellm.ps1 -Force",
        "./scripts/serverctl.sh start litellm",
    ),
    (
        "generate-litellm-key.ps1",
        ".\\scripts\\generate-litellm-key.ps1 -Alias laptop",
        "openssl rand -hex 32  # LITELLM_CLIENT_KEY",
    ),
    (
        "docker-desktop.ps1",
        ".\\scripts\\docker-desktop.ps1 -Start",
        "Docker Desktop is no longer required on Windows.",
    ),
    (
        "LITELLM_OPUS_URL",
        "LITELLM_OPUS_URL=https://127.0.0.1:8443",
        "LITELLM_OPUS_MODEL=laguna-s-2.1",
    ),
    (
        "LITELLM_OPUS_API_KEY",
        "LITELLM_OPUS_API_KEY=sk-example-value",
        "LITELLM_CCGW_PROXY_API_KEY=sk-example-value",
    ),
    (
        "LITELLM_TLS_DIR",
        "LITELLM_TLS_DIR=C:\\git\\cc-local-llm\\tls",
        "CCGW_PROXY_TLS=on",
    ),
    (
        "LITELLM_CA_CERT_FILE",
        "LITELLM_CA_CERT_FILE=C:\\certs\\rootCA.pem",
        "SSL_CERT_FILE=/opt/homebrew/etc/rootCA.pem",
    ),
    (
        "LITELLM_DB_URL",
        "LITELLM_DB_URL=postgresql://litellm@127.0.0.1:5432/litellm",
        "LITELLM_CCGW_PROXY_URL=http://127.0.0.1:8443",
    ),
    (
        "LITELLM_CONFIG_DIR",
        "LITELLM_CONFIG_DIR=C:\\git\\cc-local-llm",
        "config_path=litellm-server/config.yaml",
    ),
    (
        "CCGW_ANTHROPIC_BASE_URL",
        "set CCGW_ANTHROPIC_BASE_URL=https://127.0.0.1:4000",
        "export ANTHROPIC_BASE_URL=http://127.0.0.1:4000",
    ),
    (
        "CCGW_API_KEY",
        "set CCGW_API_KEY=sk-example-value",
        "export LITELLM_CLIENT_KEY=sk-example-value",
    ),
    (
        "CCGW_DEFAULT_MODEL",
        "CCGW_DEFAULT_MODEL=sonnet",
        "ANTHROPIC_MODEL=sonnet",
    ),
    (
        "DS4_ANTHROPIC_BASE_URL",
        "set DS4_ANTHROPIC_BASE_URL=https://127.0.0.1:8443",
        "export ANTHROPIC_BASE_URL=http://127.0.0.1:4000",
    ),
    (
        "DS4_API_KEY",
        "set DS4_API_KEY=sk-example-value",
        "export CCGW_PROXY_AUTH_TOKEN=sk-example-value",
    ),
    (
        "DS4_CA_CERT",
        "DS4_CA_CERT=C:\\certs\\rootCA.pem",
        "CCGW_PROXY_CERT=/opt/homebrew/etc/ccgw-proxy.pem",
    ),
    # --- issue #51 additions: shared DS4_ env prefix -> CCGW_ -----------------
    # Each near-miss is the post-rename spelling, so the row doubles as the
    # rename map for that variable.
    (
        "DS4_LOG",
        "DS4_LOG=on ./scripts/serverctl.sh start proxy",
        "CCGW_LOG=on ./scripts/serverctl.sh start proxy",
    ),
    (
        "DS4_RUN_DIR",
        'DS4_RUN_DIR="$HOME/Library/Application Support/cc-local-llm/run"',
        'CCGW_RUN_DIR="$HOME/Library/Application Support/cc-local-llm/run"',
    ),
    (
        "DS4_OPS_ROOT",
        'EXPECT="$DS4_OPS_ROOT/litellm-server"',
        'EXPECT="$CCGW_OPS_ROOT/litellm-server"',
    ),
    (
        # Near-miss doubles as the DS4_SERVER_* boundary: the token must not
        # reach the backend's own root variable.
        "DS4_SCRIPT_DIR",
        '. "$DS4_SCRIPT_DIR/lib/launchd.sh"',
        '. "$DS4_SERVER_ROOT/lib/launchd.sh"',
    ),
    (
        "DS4_PROXY_AUTH_TOKEN",
        "DS4_PROXY_AUTH_TOKEN=sk-example-value",
        "CCGW_PROXY_AUTH_TOKEN=sk-example-value",
    ),
    (
        "DS4_PROXY_UPSTREAM",
        "DS4_PROXY_UPSTREAM=http://127.0.0.1:18080",
        "CCGW_PROXY_UPSTREAM=http://127.0.0.1:18080",
    ),
    (
        # Near-miss is DS4_SERVER_HOST, which keeps the DS4_ prefix.
        "DS4_PROXY_HOST",
        "DS4_PROXY_HOST=0.0.0.0",
        "DS4_SERVER_HOST=127.0.0.1",
    ),
    (
        "DS4_PROXY_PORT",
        "DS4_PROXY_PORT=8443",
        "CCGW_PROXY_PORT=8443",
    ),
    (
        "DS4_PROXY_TLS",
        "DS4_PROXY_TLS=on",
        "CCGW_PROXY_TLS=on",
    ),
    (
        "DS4_PROXY_CERT",
        "DS4_PROXY_CERT=/opt/homebrew/etc/ds4-proxy.pem",
        "CCGW_PROXY_CERT=/opt/homebrew/etc/ccgw-proxy.pem",
    ),
    (
        "DS4_PROXY_KEY",
        "DS4_PROXY_KEY=/opt/homebrew/etc/ds4-proxy-key.pem",
        "CCGW_PROXY_KEY=/opt/homebrew/etc/ccgw-proxy-key.pem",
    ),
    (
        "DS4_PROXY_TEE",
        "DS4_PROXY_TEE=on",
        "CCGW_PROXY_TEE=on",
    ),
    (
        "DS4_PROXY_LOG_DIR",
        'DS4_PROXY_LOG_DIR="$HOME/Library/Logs/ds4-proxy"',
        'CCGW_PROXY_LOG_DIR="$HOME/Library/Logs/ccgw-proxy"',
    ),
    (
        "LITELLM_DS4_PROXY_URL",
        "      api_base: os.environ/LITELLM_DS4_PROXY_URL",
        "      api_base: os.environ/LITELLM_CCGW_PROXY_URL",
    ),
    (
        "LITELLM_DS4_PROXY_OPENAI_URL",
        "      api_base: os.environ/LITELLM_DS4_PROXY_OPENAI_URL",
        "      api_base: os.environ/LITELLM_CCGW_PROXY_OPENAI_URL",
    ),
    (
        "LITELLM_DS4_PROXY_API_KEY",
        "      api_key: os.environ/LITELLM_DS4_PROXY_API_KEY",
        "      api_key: os.environ/LITELLM_CCGW_PROXY_API_KEY",
    ),
    # --- issue #51 additions: ds4-proxy component + launchd labels ------------
    # Every near-miss here is a ds4-server spelling: the DeepSeek V4 Flash
    # backend keeps its name, and these rows are what proves the bans cannot
    # reach it.
    (
        "ds4-proxy",
        'exec "$CCGW_SCRIPT_DIR/ds4-proxy.sh" "$@"',
        'exec "$CCGW_SCRIPT_DIR/ds4-server.sh" "$@"',
    ),
    (
        "com.nire.ds4-proxy",
        "  <key>Label</key><string>com.nire.ds4-proxy</string>",
        "  <key>Label</key><string>com.nire.ds4-server</string>",
    ),
    (
        "com.nire.ds4-llama-swap",
        "launchctl print gui/$UID/com.nire.ds4-llama-swap",
        "launchctl print gui/$UID/com.nire.ds4-server",
    ),
    (
        "com.nire.ds4-litellm",
        'PLIST="$LAUNCH_AGENTS/com.nire.ds4-litellm.plist"',
        'PLIST="$LAUNCH_AGENTS/com.nire.ds4-server.plist"',
    ),
]

# Fixture files that intentionally carry the escaped Windows spelling
# `C:\\git\\ds4-ops` (two raw backslashes) as proxy-normalization test data.
# They are NOT in EXCLUDED_PATHS — they are scanned like everything else and
# must pass, because no LEGACY_TOKEN matches the escaped byte form.
FEATURE_13_FIXTURE_DIR = "tests/feature-13-ccgw-proxy"
ESCAPED_WINDOWS_PATH = "git\\\\ds4-ops"


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


@pytest.mark.parametrize(
    "token,matching_line,near_miss_line",
    PATH_TOKEN_CONTROLS,
    ids=[c[0] for c in PATH_TOKEN_CONTROLS],
)
def test_path_token_matches_positive_control(token, matching_line, near_miss_line):
    assert token in LEGACY_TOKENS, (
        f"{token!r} is no longer in LEGACY_TOKENS — the positive control is "
        "guarding a token that is not actually scanned"
    )
    # Same matching rule as test_legacy_token_absent_from_tracked_files.
    assert token in matching_line, (
        f"legacy token {token!r} does not match {matching_line!r} — the token "
        "is misspelled/over-escaped and would never flag anything, making the "
        "absence assertion vacuously true"
    )
    assert token not in near_miss_line, (
        f"legacy token {token!r} falsely matches the near-miss line "
        f"{near_miss_line!r} — it is too loose and will produce false positives"
    )


def test_every_legacy_token_has_a_control():
    """No token may be added to the ban list without both controls.

    The absence assertion is one-sided: a token that can never match passes it
    silently forever. PATH_TOKEN_CONTROLS is what makes it two-sided, so the
    two lists must stay in lockstep.
    """
    controlled = {c[0] for c in PATH_TOKEN_CONTROLS}
    missing = [t for t in LEGACY_TOKENS if t not in controlled]
    assert not missing, (
        "legacy token(s) with no positive/negative control: "
        f"{missing} — add a (token, matching_line, near_miss_line) row to "
        "PATH_TOKEN_CONTROLS"
    )


def test_legacy_and_new_token_sets_are_disjoint():
    """A banned token must never be a substring of a required one (or vice versa).

    Match granularity matters: the file scan uses `if token in line`
    (substring), so a set-intersection check would miss containment pairs like
    legacy `DS4_API_KEY` vs new `LITELLM_DS4_API_KEY` — the scan would flag
    every line that writes the new variable while the disjointness test stayed
    green. All-pairs mutual-substring subsumes exact equality.
    """
    conflicts = []
    for legacy in LEGACY_TOKENS:
        for new in NEW_GATEWAY_ENV_VARS:
            if legacy in new:
                conflicts.append(f"legacy {legacy!r} is a substring of new {new!r}")
            if new in legacy:
                conflicts.append(f"new {new!r} is a substring of legacy {legacy!r}")

    assert not conflicts, (
        "LEGACY_TOKENS and NEW_GATEWAY_ENV_VARS overlap under the same "
        "substring rule the file scan uses — every file that correctly writes "
        "the new name would be reported as a legacy leak:\n  "
        + "\n  ".join(conflicts)
    )


def test_feature_13_fixtures_scanned_and_clean():
    """The escaped Windows spelling is a deliberate non-token boundary.

    `tests/feature-13-ccgw-proxy/` fixtures carry `C:\\\\git\\\\ds4-ops` (two raw
    backslashes) as proxy-normalization input data. That byte form is NOT a
    LEGACY_TOKEN and must not become one: it is payload, not a repo path.
    This test pins both halves of the boundary so neither can drift silently.
    """
    root = _repo_root()
    fixtures = [
        (rel, path)
        for rel, path in _scannable_files()
        if rel.startswith(f"{FEATURE_13_FIXTURE_DIR}/")
    ]
    assert fixtures, (
        f"{FEATURE_13_FIXTURE_DIR}/ produced no scannable files — moved, "
        "renamed, or accidentally added to EXCLUDED_PATHS"
    )

    carriers = []
    for rel, path in fixtures:
        content = path.read_text(encoding="utf-8", errors="replace")
        if ESCAPED_WINDOWS_PATH in content:
            carriers.append(rel)
        for token in LEGACY_TOKENS:
            assert token not in content, (
                f"legacy token {token!r} matches fixture {rel} — the token is "
                "over-broad and is now flagging intentional test payload; "
                "tighten the token rather than excluding the file (exclusion "
                "is per-file and would hide real path leaks too)"
            )

    assert carriers, (
        f"no file under {FEATURE_13_FIXTURE_DIR}/ still contains the escaped "
        f"spelling {ESCAPED_WINDOWS_PATH!r} — the fixtures were rewritten by "
        "an over-eager rename; this test's boundary is no longer meaningful"
    )
    assert (root / FEATURE_13_FIXTURE_DIR).is_dir()


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


@pytest.mark.parametrize("rel", NEW_ENV_SOURCE_FILES)
def test_new_env_source_file_exists(rel):
    path = _repo_root() / rel
    assert path.is_file(), (
        f"{rel} not found — litellm-client/ must be git-mv'd to litellm-server/ "
        "(the assets are server-side now, so the old name is simply wrong)"
    )


@pytest.mark.parametrize("env_var", NEW_GATEWAY_ENV_VARS)
def test_new_gateway_env_var_wired_in_source_files(env_var):
    root = _repo_root()
    for rel in NEW_ENV_SOURCE_FILES:
        path = root / rel
        assert path.is_file(), f"{rel} not found"
        content = path.read_text(encoding="utf-8", errors="replace")
        assert env_var in content, (
            f"{env_var} must appear in {rel} — every model route resolves its "
            "backend through os.environ/ so the deployment stays config-only"
        )


def test_new_gateway_env_vars_are_actually_used_as_env_refs():
    """Guard against the required-name list drifting into decoration.

    `in content` would be satisfied by a mention inside a comment. The contract
    is that each name is an actual `os.environ/<NAME>` reference.
    """
    root = _repo_root()
    refs: set[str] = set()
    for rel in NEW_ENV_SOURCE_FILES:
        path = root / rel
        assert path.is_file(), f"{rel} not found"
        content = path.read_text(encoding="utf-8", errors="replace")
        refs.update(re.findall(r"os\.environ/([A-Z0-9_]+)", content))

    missing = [name for name in NEW_GATEWAY_ENV_VARS if name not in refs]
    assert not missing, (
        f"declared new gateway env vars are not os.environ/ references: "
        f"{missing} (found: {sorted(refs)})"
    )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
