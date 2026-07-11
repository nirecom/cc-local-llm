#!/bin/sh
# Starts the ds4 reverse proxy (TLS termination + prompt normalization + token auth).
# The proxy sits in front of ds4-server and is the sole LAN-visible endpoint.
# ds4-server itself listens on 127.0.0.1:8000 after this change.
# See docs/architecture.md#reverse-proxy-layer for the full rationale.
set -eu

# Load .env from the repo root (gitignored). DS4_PROXY_AUTH_TOKEN is required.
DOTENV_FILE="$HOME/git/ds4-ops/.env"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$(dirname "$0")/lib/load-dotenv.sh"

# Fail early if auth token is missing (config.py also checks, but fail here too).
if [ -z "${DS4_PROXY_AUTH_TOKEN:-}" ]; then
    echo "[ds4-proxy] DS4_PROXY_AUTH_TOKEN is not set in .env — refusing to start" >&2
    exit 1
fi

cd "$HOME/git/ds4-ops"
exec uv run python -m proxy.server
