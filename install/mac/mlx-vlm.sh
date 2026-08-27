#!/bin/bash
# mlx-vlm.sh - Install mlx-vlm from git main (the mlx_vlm.server backends, and MLX model conversion)
#
# Why a second MLX server package alongside mlx-lm, and why git main rather than
# PyPI: docs/tuning.md ("MTP speculative decoding (Qwen3.8-27B)").

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

# --with jinja2: mlx-vlm's requirements.txt omits it, but every chat request goes
# through transformers' apply_chat_template, which hard-requires it. Without this
# the server starts and passes /health, then fails each completion with
# "apply_chat_template requires jinja2 to be installed".
echo "Installing mlx-vlm from git main..."
if ! uv tool install --force --with jinja2 --from git+https://github.com/Blaizzy/mlx-vlm mlx-vlm; then
    printf "${C_YELLOW}mlx-vlm installation failed.${C_RESET}\n" >&2
    exit 1
fi

# uv exposes every [project.scripts] entry point, but llama-swap only ever spawns
# mlx_vlm.server -- verify that one rather than trusting the install exit code.
if ! command -v mlx_vlm.server &>/dev/null; then
    printf "${C_YELLOW}mlx-vlm installed but mlx_vlm.server is not on PATH -- check 'uv tool dir' is in PATH.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_GREEN}mlx-vlm installed: mlx_vlm.server available${C_RESET}\n"
