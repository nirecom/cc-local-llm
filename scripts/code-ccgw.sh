#!/bin/bash
# ccgw client launcher (macOS / Linux). POSIX counterpart of scripts/code-ccgw.cmd.
#
# Prefers the LiteLLM gateway (ccgw) for Claude Code model routing; falls back to the
# DS4 Proxy direct connection when LiteLLM is unavailable. On the Mac that also hosts
# the backend, the direct path is the normal one -- the proxy is already on loopback,
# so no LiteLLM container is needed. Rationale: docs/architecture.md;
# procedure: docs/ops.md#client-macos--linux.
#
# Usage: ./scripts/code-ccgw.sh [args passed through to `code`]
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# lib/load-dotenv.sh keeps the "shell value wins over .env" semantics that
# code-ccgw.cmd implements with `if not defined`.
DS4_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=scripts/lib/root.sh
. "$SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$SCRIPT_DIR/lib/load-dotenv.sh"

# Clear any real Anthropic API key so the local backend is used instead.
export ANTHROPIC_API_KEY=""

# --- Base URL --------------------------------------------------------------
# LiteLLM's TLS endpoint when configured, else the DS4 Proxy path.
if [ -n "${LITELLM_ANTHROPIC_BASE_URL:-}" ]; then
    export ANTHROPIC_BASE_URL="$LITELLM_ANTHROPIC_BASE_URL"
elif [ -n "${CCGW_ANTHROPIC_BASE_URL:-}" ]; then
    export ANTHROPIC_BASE_URL="$CCGW_ANTHROPIC_BASE_URL"
elif [ -n "${DS4_ANTHROPIC_BASE_URL:-}" ]; then
    export ANTHROPIC_BASE_URL="$DS4_ANTHROPIC_BASE_URL"
else
    echo "[code-ccgw] WARNING: Neither LITELLM_ANTHROPIC_BASE_URL nor CCGW_ANTHROPIC_BASE_URL set." >&2
    # 8443, not the .cmd's 8445: a POSIX client is most often the backend Mac
    # itself, whose nearest endpoint is its own proxy, not a LiteLLM gateway.
    export ANTHROPIC_BASE_URL="https://localhost:8443"
fi

# --- Authentication --------------------------------------------------------
# Use a scoped LiteLLM virtual key, NOT the master key. Falls back to the DS4
# Proxy's own shared token for the direct path.
if [ -n "${LITELLM_VIRTUAL_KEY:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_VIRTUAL_KEY"
elif [ -n "${CCGW_API_KEY:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN="$CCGW_API_KEY"
elif [ -n "${DS4_API_KEY:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN="$DS4_API_KEY"
else
    echo "[code-ccgw] WARNING: Neither LITELLM_VIRTUAL_KEY nor CCGW_API_KEY set." >&2
    export ANTHROPIC_AUTH_TOKEN="dsv4-local"
fi

# --- TLS trust -------------------------------------------------------------
# mkcert local CA root so Node trusts the proxy certificate.
# NODE_TLS_REJECT_UNAUTHORIZED=0 is NOT used.
if [ -n "${CCGW_CA_CERT:-}" ]; then
    export NODE_EXTRA_CA_CERTS="$CCGW_CA_CERT"
elif [ -n "${DS4_CA_CERT:-}" ]; then
    export NODE_EXTRA_CA_CERTS="$DS4_CA_CERT"
elif command -v mkcert &>/dev/null; then
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
# LITELLM_*_MODEL are LiteLLM-specific routing keys that DS4 Proxy does not
# recognise -- never send them down the direct path. On the direct path the model
# name is what the Mac swap layer routes on, so it must be a name that layer knows
# (see llama-swap/config.yaml): deepseek-v4-flash or laguna-s-2.1.
if [ -n "${LITELLM_ANTHROPIC_BASE_URL:-}" ]; then
    if [ -n "${LITELLM_OPUS_MODEL:-}" ]; then
        export ANTHROPIC_MODEL="$LITELLM_OPUS_MODEL"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="$LITELLM_OPUS_MODEL"
        export ANTHROPIC_CUSTOM_MODEL_OPTION="$LITELLM_OPUS_MODEL"
        export CLAUDE_CODE_SUBAGENT_MODEL="$LITELLM_OPUS_MODEL"
    fi
    [ -n "${LITELLM_SONNET_MODEL:-}" ] && export ANTHROPIC_DEFAULT_SONNET_MODEL="$LITELLM_SONNET_MODEL"
    [ -n "${LITELLM_HAIKU_MODEL:-}" ] && export ANTHROPIC_DEFAULT_HAIKU_MODEL="$LITELLM_HAIKU_MODEL"
else
    # Direct path: CCGW_DEFAULT_MODEL selects which backend the swap layer loads.
    _model="${CCGW_DEFAULT_MODEL:-deepseek-v4-flash}"
    export ANTHROPIC_MODEL="$_model"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$_model"
    export ANTHROPIC_CUSTOM_MODEL_OPTION="$_model"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$_model"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$_model"
    export CLAUDE_CODE_SUBAGENT_MODEL="$_model"
fi
export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="Local model via ccgw"
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="Mac backend (ds4 / Laguna S 2.1), selected per request"

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
export CLAUDE_STREAM_IDLE_TIMEOUT_MS=600000

# Align auto-compaction with the tightest backend ceiling. A single env var cannot
# differentiate per-tier -- 64K is the safe floor (see code-ccgw.cmd for the same note).
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

if ! command -v code &>/dev/null; then
    echo "[code-ccgw] ERROR: 'code' command not found on PATH." >&2
    echo "[code-ccgw] In VS Code run: Shell Command: Install 'code' command in PATH" >&2
    exit 1
fi

exec code --user-data-dir "$_user_data_dir" "$@"
