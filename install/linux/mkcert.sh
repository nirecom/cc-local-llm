#!/bin/bash
# mkcert.sh - Install mkcert (local TLS CA) on Linux.
# Counterpart of install/win/mkcert.ps1. The client trusts the CCGW Proxy / LiteLLM
# certificate through this CA -- NODE_TLS_REJECT_UNAUTHORIZED=0 is never used.

# Color fallback (standalone-safe: this script also runs directly, not only via install.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

export SYSTEM_OPS_APPROVED=1

if command -v mkcert &>/dev/null; then
    printf "${C_GRAY}mkcert is already installed: $(mkcert -version 2>&1)${C_RESET}\n"
    exit 0
fi

echo "Installing mkcert..."
if command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y mkcert libnss3-tools
elif command -v dnf &>/dev/null; then
    sudo dnf install -y mkcert nss-tools
elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm mkcert nss
else
    printf "${C_YELLOW}No supported package manager found (apt-get/dnf/pacman).${C_RESET}\n" >&2
    printf "${C_YELLOW}Install mkcert manually: https://github.com/FiloSottile/mkcert${C_RESET}\n" >&2
    exit 1
fi

if ! command -v mkcert &>/dev/null; then
    printf "${C_YELLOW}mkcert installation failed.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_GREEN}mkcert installed: $(mkcert -version 2>&1)${C_RESET}\n"
