#!/bin/sh
# Foreground launcher for the LiteLLM gateway. Used by launchd ProgramArguments
# and for direct foreground runs. For daily use, prefer: serverctl start litellm
# See scripts/serverctl.sh for the unified control command.
#
# LiteLLM is the single entry point every client talks to: it terminates TLS,
# converts the Anthropic wire format, and routes each model tier to its backend
# (see litellm-server/config.yaml).
set -eu

CCGW_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/root.sh
. "$CCGW_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$CCGW_SCRIPT_DIR/lib/load-dotenv.sh"

exec "$CCGW_SCRIPT_DIR/serverctl.sh" __run litellm
