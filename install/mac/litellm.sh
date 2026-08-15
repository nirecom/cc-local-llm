#!/bin/bash
# litellm.sh - Install the LiteLLM gateway as a native uv-managed tool.
# The gateway used to run as a Docker container on the Windows PC; it is now a
# single native process on the Mac (see docs/architecture.md), so it is installed
# in user scope with no daemon and no sudo.
#
# This script has no macOS-specific dependency (plain `uv tool install`) -- it
# lives under install/mac/ because the gateway is deliberately colocated with
# the Metal/MLX-only backend (llama-swap.sh, mlx-lm.sh) on the same host, not
# because litellm itself requires macOS.

# Color fallback (no dotfiles dependency -- standalone-safe pattern from claude-code.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

if ! command -v uv &>/dev/null; then
    printf "${C_YELLOW}uv not found -- install uv first (https://docs.astral.sh/uv/).${C_RESET}\n" >&2
    exit 1
fi

if command -v litellm &>/dev/null; then
    printf "${C_GRAY}litellm is already installed: $(litellm --version 2>&1 | head -1)${C_RESET}\n"
    exit 0
fi

echo "Installing litellm (proxy extra)..."
# The proxy extra is what provides the `litellm --config ...` server entrypoint.
# litellm's own fastapi constraint (>=0.136.3,<1.0) is too loose: fastapi 0.140.7
# removed the internal get_flat_dependant() that litellm's proxy code still
# imports, breaking `litellm --version` / server startup. Pin below that until
# litellm ships a release compatible with newer fastapi.
if ! uv tool install --with "fastapi<0.140.7" "litellm[proxy]"; then
    printf "${C_YELLOW}litellm installation failed.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_GREEN}litellm installed: $(litellm --version 2>&1 | head -1)${C_RESET}\n"
