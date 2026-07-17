#!/bin/sh
# ds4ctl — unified control command for ds4-proxy and ds4-server.
# Usage: ds4ctl <start|stop|restart|status|logs|install|uninstall> [proxy|server|all]
set -eu

DS4CTL="$(cd "$(dirname "$0")" && pwd)/ds4ctl.sh"

DOTENV_FILE="$HOME/git/ds4-ops/.env"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$(dirname "$0")/lib/load-dotenv.sh"
# shellcheck source=scripts/lib/paths.sh
. "$(dirname "$0")/lib/paths.sh"
# shellcheck source=scripts/lib/colorize.sh
. "$(dirname "$0")/lib/colorize.sh"
# shellcheck source=scripts/lib/launchd.sh
. "$(dirname "$0")/lib/launchd.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$(dirname "$0")/lib/lifecycle.sh"

_usage() {
    cat >&2 <<'EOF'
Usage: ds4ctl <command> [proxy|server|all]

Commands:
  start     Start service(s) in the background (nohup + PID)
  stop      Stop service(s)
  restart   Stop then start service(s)
  status    Show running status
  logs      Tail log file(s) (requires DS4_LOG=on)
  install   Install launchd LaunchAgent for auto-start
  uninstall Remove launchd LaunchAgent

Targets: proxy, server, all (default)
EOF
}

if [ $# -lt 1 ]; then
    _usage
    exit 2
fi

cmd="$1"
target="${2:-all}"

# Validate target
case "$target" in
    proxy|server|all) ;;
    *)
        echo "[ds4ctl] unknown target: $target" >&2
        _usage
        exit 2
        ;;
esac

# Expand 'all' to list of services
if [ "$target" = "all" ]; then
    _services="proxy server"
else
    _services="$target"
fi

case "$cmd" in
    start)
        for _svc in $_services; do
            ds4_start "$_svc"
        done
        ;;
    stop)
        _err=0
        for _svc in $_services; do
            ds4_stop "$_svc" || _err=$?
        done
        exit $_err
        ;;
    restart)
        _err=0
        for _svc in $_services; do
            ds4_restart "$_svc" || _err=$?
        done
        exit $_err
        ;;
    status)
        for _svc in $_services; do
            ds4_status "$_svc"
        done
        ;;
    logs)
        if [ "$target" = "all" ]; then
            ds4_logs "all"
        else
            ds4_logs "$_services"
        fi
        ;;
    install)
        for _svc in $_services; do
            ds4_install "$_svc"
        done
        ;;
    uninstall)
        for _svc in $_services; do
            ds4_uninstall "$_svc"
        done
        ;;
    __run)
        # Internal: called by nohup/launchd to exec the real service process
        if [ $# -lt 2 ]; then
            echo "[ds4ctl] __run requires a service name" >&2
            exit 2
        fi
        ds4_exec "$2"
        ;;
    *)
        echo "[ds4ctl] unknown command: $cmd" >&2
        _usage
        exit 2
        ;;
esac
