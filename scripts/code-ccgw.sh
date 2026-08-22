#!/bin/bash
# ccgw client launcher (macOS / Linux). POSIX counterpart of scripts/code-ccgw.ps1.
#
# Every client reaches the backends through the Mac LiteLLM gateway; the direct
# CCGW Proxy route is retired, so there is exactly one path and nothing to fall
# back to. An unconfigured base URL or credential is therefore an error rather
# than a dummy default -- a dummy default only defers the failure to a confusing
# 401 at request time. Rationale: docs/architecture.md;
# procedure: docs/ops.md#client-macos--linux.
#
# Usage: ./scripts/code-ccgw.sh [args passed through to `code`]
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# lib/load-dotenv.sh keeps the "shell value wins over .env" semantics that
# code-ccgw.ps1 implements with its own "shell value wins" check.
CCGW_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=scripts/lib/root.sh
. "$SCRIPT_DIR/lib/root.sh"
# The model-routing keys must ALWAYS come from .env: a stale inherited shell
# value (e.g. an old LITELLM_OPUS_MODEL left over from a previous launch) must
# never override the repo's .env intent. DOTENV_FORCE_KEYS is deliberately
# NON-exported -- it is consumed only by lib/load-dotenv.sh, and leaking it into
# the child (VS Code) environment would be noise.
DOTENV_FORCE_KEYS="LITELLM_HAIKU_MODEL LITELLM_SONNET_MODEL LITELLM_FABLE_MODEL LITELLM_OPUS_MODEL CCGW_SUBAGENT_MODEL"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$SCRIPT_DIR/lib/load-dotenv.sh"

# Clear any real Anthropic API key so the local backend is used instead.
export ANTHROPIC_API_KEY=""

# --- Base URL --------------------------------------------------------------
# The LiteLLM gateway is the only endpoint. Defined-but-empty counts as unset:
# every consumer below reads it that way, so honouring an empty value would
# only produce a request to "".
if [ -z "${LITELLM_ANTHROPIC_BASE_URL:-}" ]; then
    echo "[code-ccgw] ERROR: LITELLM_ANTHROPIC_BASE_URL is not set." >&2
    echo "[code-ccgw] Set it to the LiteLLM gateway endpoint; see docs/ops.md." >&2
    exit 1
fi
export ANTHROPIC_BASE_URL="$LITELLM_ANTHROPIC_BASE_URL"

# --- Authentication --------------------------------------------------------
# LiteLLM runs without a database, so no virtual keys exist: the client
# credential is the gateway key itself. LITELLM_VIRTUAL_KEY is accepted for one
# deprecation cycle so an unmigrated .env fails loudly rather than with a 401.
if [ -n "${LITELLM_CLIENT_KEY:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_CLIENT_KEY"
elif [ -n "${LITELLM_VIRTUAL_KEY:-}" ]; then
    echo "[code-ccgw] WARNING: LITELLM_VIRTUAL_KEY is deprecated; rename it to LITELLM_CLIENT_KEY." >&2
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_VIRTUAL_KEY"
else
    echo "[code-ccgw] ERROR: LITELLM_CLIENT_KEY is not set." >&2
    echo "[code-ccgw] Set it to the LiteLLM gateway key; see docs/ops.md." >&2
    exit 1
fi

# --- TLS trust -------------------------------------------------------------
# mkcert local CA root so Node trusts the gateway certificate.
# NODE_TLS_REJECT_UNAUTHORIZED=0 is NOT used.
if [ -n "${CCGW_CA_CERT:-}" ]; then
    export NODE_EXTRA_CA_CERTS="$CCGW_CA_CERT"
elif command -v mkcert >/dev/null 2>&1; then
    # On the backend Mac the CA is already local -- derive it rather than making
    # the user restate a path the tool can answer for itself.
    _caroot="$(mkcert -CAROOT 2>/dev/null || true)"
    if [ -n "$_caroot" ] && [ -f "$_caroot/rootCA.pem" ]; then
        export NODE_EXTRA_CA_CERTS="$_caroot/rootCA.pem"
    else
        echo "[code-ccgw] WARNING: CCGW_CA_CERT not set; TLS certificate will not be trusted." >&2
    fi
else
    echo "[code-ccgw] WARNING: CCGW_CA_CERT not set; TLS certificate will not be trusted." >&2
fi

# --- Model aliases ---------------------------------------------------------
# Each LITELLM_*_MODEL is a LiteLLM routing key and goes onto its own /model
# tier verbatim. The launcher owns no backend names: inventing one would address
# a model the gateway has no entry for, and the error would surface as a 400
# from LiteLLM rather than as a message from here.
if [ -n "${LITELLM_FABLE_MODEL:-}" ]; then
    export ANTHROPIC_DEFAULT_FABLE_MODEL="$LITELLM_FABLE_MODEL"
fi
if [ -n "${LITELLM_OPUS_MODEL:-}" ]; then
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$LITELLM_OPUS_MODEL"
fi
if [ -n "${LITELLM_SONNET_MODEL:-}" ]; then
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$LITELLM_SONNET_MODEL"
fi
if [ -n "${LITELLM_HAIKU_MODEL:-}" ]; then
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$LITELLM_HAIKU_MODEL"
fi
if [ -n "${LITELLM_FABLE_MODEL:-}" ]; then
    export ANTHROPIC_MODEL="$LITELLM_FABLE_MODEL"
    export ANTHROPIC_CUSTOM_MODEL_OPTION="$LITELLM_FABLE_MODEL"
fi

# Subagent routing is opt-in. LiteLLM multiplexes, so pinning every subagent to
# one tier is no longer needed -- and an unconditional value silently overrides
# the model an agent definition's frontmatter declares. The value is a routing
# key, passed through untranslated.
if [ -n "${CCGW_SUBAGENT_MODEL:-}" ]; then
    export CLAUDE_CODE_SUBAGENT_MODEL="$CCGW_SUBAGENT_MODEL"
fi

export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="Local model via ccgw"
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="Mac backend via the LiteLLM gateway, selected per request"

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
export CLAUDE_STREAM_IDLE_TIMEOUT_MS=600000

# Align auto-compaction with the tightest backend ceiling. A single env var cannot
# differentiate per-tier -- 64K is the safe floor (see code-ccgw.ps1 for the same note).
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=65536
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75

# Launch VS Code in an isolated process. A distinct --user-data-dir starts a separate
# VS Code instance; VS Code otherwise shares one process (and one environment) across
# all windows of a user-data-dir, which would leak this env into native windows.
if [ "$(uname -s)" = "Darwin" ]; then
    _user_data_dir="$HOME/Library/Application Support/vscode-ccgw"
else
    _user_data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/vscode-ccgw"
fi

if ! command -v code >/dev/null 2>&1; then
    echo "[code-ccgw] ERROR: 'code' command not found on PATH." >&2
    echo "[code-ccgw] In VS Code run: Shell Command: Install 'code' command in PATH" >&2
    exit 1
fi

exec code --user-data-dir "$_user_data_dir" "$@"
