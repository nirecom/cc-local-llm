#!/bin/sh
# Foreground launcher for ds4-server. Used by launchd ProgramArguments and for
# direct foreground runs. For daily use, prefer: serverctl start server
# See scripts/serverctl.sh for the unified control command.
#
# caffeinate -ism: prevent idle/AC-system/disk sleep. -d (display sleep) is
# intentionally OMITTED so the display can turn off (screen burn-in protection).
# The kvcache.log tee is handled by serverctl (ds4_exec) via DS4_LOG toggle.
set -eu

DS4_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/root.sh
. "$DS4_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$DS4_SCRIPT_DIR/lib/load-dotenv.sh"

exec "$DS4_SCRIPT_DIR/serverctl.sh" __run server
