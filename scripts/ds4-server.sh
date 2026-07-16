#!/bin/sh
# Starts ds4-server (antirez/ds4) as a self-hosted Claude Code backend.
#
# caffeinate -ism: prevent idle / AC-system / disk sleep so macOS can never
#   freeze the process mid-generation. -d (display sleep) is intentionally
#   OMITTED so the display can still turn off (screen burn-in protection);
#   the assertion is tied to this script's child process, not the display.
#
# stdout/stderr (including ds4's own kv-cache hit/evict log lines) are teed to
# LOG_DIR/kvcache.log so they are both visible live and persisted.
#
# See ../docs/server-mac.md for the rationale behind every flag and value.
set -eu

# Load .env from the repo root (gitignored).
DOTENV_FILE="$HOME/git/ds4-ops/.env"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$(dirname "$0")/lib/load-dotenv.sh"

cd "$HOME/git/ds4"          # antirez/ds4 build clone (ds4flash.gguf lives here)

LOG_DIR="$HOME/Library/Logs/ds4-server"
mkdir -p "$LOG_DIR"

# DS4_SERVER_HOST overrides the bind address (default: 127.0.0.1).
# Set to 0.0.0.0 (or a specific LAN IP) for temporary A/B testing vs proxy.
# Revert to 127.0.0.1 after testing — the raw server has no auth.
HOST="${DS4_SERVER_HOST:-127.0.0.1}"

caffeinate -ism ./ds4-server \
  --metal \
  --quality \
  --ctx 393216 \
  --kv-disk-dir "$HOME/Library/Caches/ds4-server/kv" \
  --kv-disk-space-mb 32768 \
  --kv-cache-cold-max-tokens 90000 \
  --kv-cache-continued-interval-tokens 25000 \
  --warm-weights \
  --host "$HOST" \
  2>&1 | tee -a "$LOG_DIR/kvcache.log"
