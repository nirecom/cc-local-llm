#!/bin/bash
# mlx-lm.sh - Install mlx-lm from git main (the mlx_lm.server backends in llama-swap/config.yaml)
# Laguna's architecture support is not yet in a PyPI release, so this installs from
# the ml-explore/mlx-lm main branch as a uv-managed tool (user scope, no sudo).

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

echo "Installing mlx-lm from git main..."
if ! uv tool install --force --from git+https://github.com/ml-explore/mlx-lm mlx-lm; then
    printf "${C_YELLOW}mlx-lm installation failed.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_GREEN}mlx-lm installed: $(mlx_lm.server --help 2>&1 | head -1)${C_RESET}\n"
