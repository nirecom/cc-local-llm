#!/bin/bash
# cc-local-llm installer for macOS and Linux.
#
# Two roles, independently installable:
#   server  Mac backend stack (LiteLLM gateway + ds4-server + Laguna S 2.1 +
#           the model-swap layer). macOS only -- the backends need Metal / MLX.
#   client  Claude Code client prerequisites (mkcert, for TLS trust in the
#           gateway certificate).
#
# Usage: ./install.sh [--server | --client | --all]
#   macOS default: --all      (the Mac is both backend host and a usable client)
#   Linux default: --client   (client only; the backend cannot run here)
# Windows-side setup uses install.ps1 instead.

set -euo pipefail

# Colors (only when stdout is a terminal)
if [ -t 1 ]; then
    C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_GRAY='\033[0;90m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_BOLD=''; C_RESET=''
fi
export C_CYAN C_GREEN C_YELLOW C_GRAY C_BOLD C_RESET

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Platform ---------------------------------------------------------------
case "$(uname -s)" in
    Darwin) PLATFORM="mac" ;;
    Linux)  PLATFORM="linux" ;;
    *)
        printf "${C_YELLOW}Unsupported platform: $(uname -s). Use install.ps1 on Windows.${C_RESET}\n" >&2
        exit 1
        ;;
esac

# --- Role selection ---------------------------------------------------------
# Default differs by platform: only macOS can host the backend.
if [ "$PLATFORM" = "mac" ]; then
    ROLE="all"
else
    ROLE="client"
fi

case "${1:-}" in
    "")                 ;;
    --server) ROLE="server" ;;
    --client) ROLE="client" ;;
    --all)    ROLE="all"    ;;
    *)
        printf "${C_YELLOW}Unknown option: $1${C_RESET}\n" >&2
        echo "Usage: ./install.sh [--server | --client | --all]" >&2
        exit 2
        ;;
esac

if [ "$ROLE" != "client" ] && [ "$PLATFORM" != "mac" ]; then
    printf "${C_YELLOW}The backend (ds4-server / Laguna S 2.1) requires macOS with Metal -- '--server' is unavailable here.${C_RESET}\n" >&2
    printf "${C_YELLOW}Run './install.sh --client' to set up this host as a client instead.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_CYAN}=== cc-local-llm installer (${PLATFORM}, role: ${ROLE}) ===${C_RESET}\n"

# --- Client role ------------------------------------------------------------
if [ "$ROLE" = "client" ] || [ "$ROLE" = "all" ]; then
    echo ""
    printf -- "${C_BOLD}--- Installing mkcert (TLS trust for the gateway certificate) ---${C_RESET}\n"
    "$REPO_ROOT/install/$PLATFORM/mkcert.sh"
fi

# --- Server role ------------------------------------------------------------
if [ "$ROLE" = "server" ] || [ "$ROLE" = "all" ]; then
    echo ""
    printf -- "${C_BOLD}--- Checking Homebrew ---${C_RESET}\n"
    if ! command -v brew &>/dev/null; then
        printf "${C_YELLOW}Homebrew not found. Install it first: https://brew.sh${C_RESET}\n" >&2
        exit 1
    fi

    echo ""
    printf -- "${C_BOLD}--- Checking uv ---${C_RESET}\n"
    if ! command -v uv &>/dev/null; then
        printf "${C_YELLOW}uv not found. Install it first: https://docs.astral.sh/uv/${C_RESET}\n" >&2
        exit 1
    fi

    echo ""
    printf -- "${C_BOLD}--- Installing the model-swap layer ---${C_RESET}\n"
    "$REPO_ROOT/install/mac/llama-swap.sh"

    echo ""
    printf -- "${C_BOLD}--- Installing the LiteLLM gateway ---${C_RESET}\n"
    "$REPO_ROOT/install/mac/litellm.sh"

    echo ""
    printf -- "${C_BOLD}--- Installing mlx-lm (git main, for Laguna S 2.1) ---${C_RESET}\n"
    "$REPO_ROOT/install/mac/mlx-lm.sh"

    echo ""
    printf -- "${C_BOLD}--- Checking Laguna S 2.1 model files ---${C_RESET}\n"
    LAGUNA_MODEL_DIR="$HOME/.lmstudio/models/poolside/Laguna-S-2.1-NVFP4-mlx"
    if [ -d "$LAGUNA_MODEL_DIR" ]; then
        printf "${C_GRAY}Laguna model found: $LAGUNA_MODEL_DIR${C_RESET}\n"
    else
        printf "${C_YELLOW}Laguna model not found at $LAGUNA_MODEL_DIR${C_RESET}\n"
        printf "${C_YELLOW}Download it via LM Studio or huggingface-cli before starting the swap layer.${C_RESET}\n"
    fi
fi

# --- Shared: .env -----------------------------------------------------------
echo ""
printf -- "${C_BOLD}--- Setting up .env ---${C_RESET}\n"
if [ -f "$REPO_ROOT/.env" ]; then
    printf "${C_GRAY}.env already exists -- leaving it as-is.${C_RESET}\n"
else
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
    if [ "$ROLE" = "client" ]; then
        printf "${C_GREEN}Created .env from .env.example -- fill in LITELLM_ANTHROPIC_BASE_URL / LITELLM_CLIENT_KEY / CCGW_CA_CERT.${C_RESET}\n"
    else
        printf "${C_GREEN}Created .env from .env.example -- fill in LITELLM_MASTER_KEY, DS4_PROXY_AUTH_TOKEN and the TLS cert paths.${C_RESET}\n"
    fi
fi

echo ""
printf "${C_GREEN}=== Done ===${C_RESET}\n"
if [ "$ROLE" = "client" ]; then
    echo "Next: docs/ops.md#client-macos--linux, then:"
    echo "  ./scripts/code-ccgw.sh"
else
    echo "Next: docs/ops.md#install-the-model-swap-layer-and-laguna-s-21-mac-one-time, then:"
    echo "  ~/git/cc-local-llm/scripts/serverctl.sh start all"
    echo "To use this Mac as a client too:  ./scripts/code-ccgw.sh"
fi
