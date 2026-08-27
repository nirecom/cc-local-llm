#!/bin/sh
# Foreground launcher for llama-swap. Used by launchd ProgramArguments and for
# direct foreground runs. For daily use, prefer: serverctl start llama-swap
# See scripts/serverctl.sh for the unified control command.
#
# llama-swap owns ds4-server's and Laguna's start/stop lifecycle exclusively
# (see llama-swap/m5-max-128gb/config.yaml) -- it is the sole spawner of both model
# processes, keeping them mutually exclusive on the Mac's 128 GB memory.
set -eu

CCGW_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/root.sh
. "$CCGW_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$CCGW_SCRIPT_DIR/lib/load-dotenv.sh"

exec "$CCGW_SCRIPT_DIR/serverctl.sh" __run llama-swap
