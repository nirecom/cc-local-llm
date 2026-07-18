#!/bin/sh
# Foreground launcher for ds4-proxy. Used by launchd ProgramArguments and for
# direct foreground runs. For daily use, prefer: ds4ctl start proxy
# See scripts/ds4ctl.sh for the unified control command.
set -eu

DOTENV_FILE="$HOME/git/ds4-ops/.env"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$(dirname "$0")/lib/load-dotenv.sh"

exec "$(dirname "$0")/ds4ctl.sh" __run proxy
