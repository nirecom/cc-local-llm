#!/bin/sh
# Starts ds4-server (antirez/ds4) as a self-hosted Claude Code backend.
#
# caffeinate -ism: prevent idle / AC-system / disk sleep so macOS can never
#   freeze the process mid-generation. -d (display sleep) is intentionally
#   OMITTED so the display can still turn off (screen burn-in protection);
#   the assertion is tied to this script's child process, not the display.
#
# See ../docs/server-mac.md for the rationale behind every flag and value.
set -eu

cd "$HOME/git/ds4"          # antirez/ds4 build clone (ds4flash.gguf lives here)

exec caffeinate -ism ./ds4-server \
  --metal \
  --quality \
  --ctx 393216 \
  --kv-disk-dir "$HOME/Library/Caches/ds4-server/kv" \
  --kv-disk-space-mb 32768 \
  --kv-cache-cold-max-tokens 90000 \
  --kv-cache-continued-interval-tokens 25000 \
  --warm-weights \
  --host 0.0.0.0
