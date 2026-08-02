#!/bin/sh
# Foreground launcher for ds4-proxy. Used by launchd ProgramArguments and for
# direct foreground runs. For daily use, prefer: ds4ctl start proxy
# See scripts/ds4ctl.sh for the unified control command.
set -eu

DS4_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/root.sh
. "$DS4_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$DS4_SCRIPT_DIR/lib/load-dotenv.sh"

exec "$DS4_SCRIPT_DIR/ds4ctl.sh" __run proxy
