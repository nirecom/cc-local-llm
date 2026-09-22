#!/bin/bash
# lm-eval.sh - Install lm-evaluation-harness (EleutherAI) for benchmark runs.
# Used by IFEval / MMLU-Pro / GPQA via the local OpenAI-compatible endpoint.

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_RESET=''
    fi
fi

if ! command -v uv &>/dev/null; then
    printf "${C_YELLOW}uv not found -- install uv first (https://docs.astral.sh/uv/).${C_RESET}\n" >&2
    exit 1
fi

echo "Installing lm-evaluation-harness..."
if ! uv tool install --force "lm_eval[api]"; then
    printf "${C_YELLOW}lm-evaluation-harness installation failed.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_GREEN}lm-evaluation-harness installed: $(lm_eval --version 2>&1 | head -1)${C_RESET}\n"
