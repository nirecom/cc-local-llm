#!/bin/bash
# llama-swap.sh - Install llama-swap (mostlygeek/llama-swap) via Homebrew
# Manages ds4-server's and Laguna's start/stop lifecycle -- see docs/architecture.md
export SYSTEM_OPS_APPROVED=1

# Color fallback (no dotfiles dependency -- standalone-safe pattern from claude-code.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

if command -v llama-swap &>/dev/null; then
    printf "${C_GRAY}llama-swap is already installed: $(llama-swap --version 2>&1 | head -1)${C_RESET}\n"
    exit 0
fi

echo "Installing llama-swap..."
if ! brew tap mostlygeek/llama-swap; then
    printf "${C_YELLOW}brew tap mostlygeek/llama-swap failed.${C_RESET}\n" >&2
    exit 1
fi

# Recent Homebrew refuses to load formulae from a third-party tap until it is
# explicitly trusted (separate from tapping it). This repo pins the exact tap
# (mostlygeek/llama-swap) as a documented dependency, so trusting it here is
# part of installing this specific, already-vetted tool -- not a blanket
# trust grant for arbitrary taps.
if command -v brew &>/dev/null && brew commands 2>/dev/null | grep -qx trust; then
    brew trust --tap mostlygeek/llama-swap
fi

if ! brew install llama-swap; then
    if command -v llama-swap &>/dev/null; then
        printf "${C_GRAY}llama-swap already present (installer returned non-zero).${C_RESET}\n"
    else
        printf "${C_YELLOW}llama-swap installation failed.${C_RESET}\n" >&2
        exit 1
    fi
fi

printf "${C_GREEN}llama-swap installed: $(llama-swap --version 2>&1 | head -1)${C_RESET}\n"
