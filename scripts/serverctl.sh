#!/bin/sh
# serverctl — unified control command for the Mac backend stack
# (LiteLLM gateway, CCGW Proxy, llama-swap).
# Usage: serverctl <start|stop|restart|status|logs|install|uninstall> [proxy|llama-swap|litellm|server|all]
set -eu

CCGW_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SERVERCTL="$CCGW_SCRIPT_DIR/serverctl.sh"

# shellcheck source=scripts/lib/root.sh
. "$CCGW_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$CCGW_SCRIPT_DIR/lib/load-dotenv.sh"
# shellcheck source=scripts/lib/paths.sh
. "$CCGW_SCRIPT_DIR/lib/paths.sh"
# shellcheck source=scripts/lib/colorize.sh
. "$CCGW_SCRIPT_DIR/lib/colorize.sh"
# shellcheck source=scripts/lib/launchd.sh
. "$CCGW_SCRIPT_DIR/lib/launchd.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$CCGW_SCRIPT_DIR/lib/lifecycle.sh"

_usage() {
    cat >&2 <<'EOF'
Usage: serverctl <command> [proxy|llama-swap|litellm|server|all]

Commands:
  start     Start service(s) in the background (nohup + PID)
  stop      Stop service(s)
  restart   Restart service(s) -- launchd-managed ones are re-exec'd in place
  status    Show running status
  logs      Tail log file(s) (requires CCGW_LOG=on)
  install   Install launchd LaunchAgent for auto-start
  uninstall Remove launchd LaunchAgent

Targets: proxy, llama-swap, litellm, all (default). 'server' (bare ds4-server) is a
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
    proxy|llama-swap|litellm|server|all) ;;
    *)
        echo "[serverctl] unknown target: $target" >&2
        _usage
        exit 2
        ;;
esac

# Expand 'all' to list of services. 'server' is intentionally excluded --
# see _usage.
if [ "$target" = "all" ]; then
    _services="proxy llama-swap litellm"
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
