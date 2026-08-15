#!/bin/sh
# serverctl — unified control command for the Mac backend stack (DS4 Proxy, llama-swap).
# Usage: serverctl <start|stop|restart|status|logs|install|uninstall> [proxy|llama-swap|server|all]
set -eu

DS4_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SERVERCTL="$DS4_SCRIPT_DIR/serverctl.sh"

# shellcheck source=scripts/lib/root.sh
. "$DS4_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$DS4_SCRIPT_DIR/lib/load-dotenv.sh"
# shellcheck source=scripts/lib/paths.sh
. "$DS4_SCRIPT_DIR/lib/paths.sh"
# shellcheck source=scripts/lib/colorize.sh
. "$DS4_SCRIPT_DIR/lib/colorize.sh"
# shellcheck source=scripts/lib/launchd.sh
. "$DS4_SCRIPT_DIR/lib/launchd.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$DS4_SCRIPT_DIR/lib/lifecycle.sh"

_usage() {
    cat >&2 <<'EOF'
Usage: serverctl <command> [proxy|llama-swap|server|all]

Commands:
  start     Start service(s) in the background (nohup + PID)
  stop      Stop service(s)
  restart   Stop then start service(s)
  status    Show running status
  logs      Tail log file(s) (requires DS4_LOG=on)
  install   Install launchd LaunchAgent for auto-start
  uninstall Remove launchd LaunchAgent

Targets: proxy, llama-swap, all (default). 'server' (bare ds4-server) is a
separate manual-debug-only target, excluded from 'all' -- llama-swap owns
ds4-server's start/stop lifecycle, so running it outside llama-swap would
double-manage the same process.
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
    proxy|llama-swap|server|all) ;;
    *)
        echo "[serverctl] unknown target: $target" >&2
        _usage
        exit 2
        ;;
esac

# Expand 'all' to list of services. 'server' is intentionally excluded --
# see _usage.
if [ "$target" = "all" ]; then
    _services="proxy llama-swap"
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
            echo "[serverctl] __run requires a service name" >&2
            exit 2
        fi
        ds4_exec "$2"
        ;;
    *)
        echo "[serverctl] unknown command: $cmd" >&2
        _usage
        exit 2
        ;;
esac
