#!/bin/bash
# mkcert.sh - Install mkcert (local TLS CA) via Homebrew.
# The Mac needs this in both roles: as the backend host it signs the DS4 Proxy
# certificate, and as a client it trusts that certificate through the same CA.

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
if ! brew install mkcert nss; then
    if command -v mkcert &>/dev/null; then
        printf "${C_GRAY}mkcert already present (installer returned non-zero).${C_RESET}\n"
    else
        printf "${C_YELLOW}mkcert installation failed.${C_RESET}\n" >&2
        exit 1
    fi
fi

printf "${C_GREEN}mkcert installed: $(mkcert -version 2>&1)${C_RESET}\n"
