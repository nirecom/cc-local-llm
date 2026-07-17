#!/bin/sh
# Foreground launcher for ds4-server. Used by launchd ProgramArguments and for
# direct foreground runs. For daily use, prefer: ds4ctl start server
# See scripts/ds4ctl.sh for the unified control command.
#
# caffeinate -ism: prevent idle/AC-system/disk sleep. -d (display sleep) is
# intentionally OMITTED so the display can turn off (screen burn-in protection).
# The kvcache.log tee is handled by ds4ctl (ds4_exec) via DS4_LOG toggle.
set -eu

DOTENV_FILE="$HOME/git/ds4-ops/.env"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$(dirname "$0")/lib/load-dotenv.sh"

exec "$(dirname "$0")/ds4ctl.sh" __run server
