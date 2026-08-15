#!/bin/bash
# docker.sh - Install Docker Engine on Linux.
# Counterpart of install/win/docker-desktop.ps1 (Windows uses Docker Desktop + WSL2).
# Only needed when this host also runs the LiteLLM gateway container; a client that
# talks to the DS4 Proxy directly does not need Docker at all.

# Color fallback (standalone-safe: this script also runs directly, not only via install.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

export SYSTEM_OPS_APPROVED=1

if command -v docker &>/dev/null; then
    printf "${C_GRAY}Docker is already installed: $(docker --version 2>&1)${C_RESET}\n"
    exit 0
fi

echo "Installing Docker Engine..."
if command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin
elif command -v dnf &>/dev/null; then
    sudo dnf install -y docker docker-compose-plugin
elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm docker docker-compose
else
    printf "${C_YELLOW}No supported package manager found (apt-get/dnf/pacman).${C_RESET}\n" >&2
    printf "${C_YELLOW}Install Docker manually: https://docs.docker.com/engine/install/${C_RESET}\n" >&2
    exit 1
fi

if ! command -v docker &>/dev/null; then
    printf "${C_YELLOW}Docker installation failed.${C_RESET}\n" >&2
    exit 1
fi

printf "${C_GREEN}Docker installed: $(docker --version 2>&1)${C_RESET}\n"
printf "${C_GRAY}Add yourself to the 'docker' group to run it without sudo: sudo usermod -aG docker \"\$USER\"${C_RESET}\n"
