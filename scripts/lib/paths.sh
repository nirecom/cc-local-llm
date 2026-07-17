#!/bin/sh
# SSOT for ds4-ops service paths and patterns.
set -eu

DS4_OPS_ROOT="$HOME/git/ds4-ops"
DS4_SERVER_ROOT="$HOME/git/ds4"
DS4_RUN_DIR="$HOME/Library/Application Support/ds4-ops/run"

_ds4_pid_file() { echo "$DS4_RUN_DIR/${1}.pid"; }

_ds4_log_dir() {
    case "$1" in
        proxy)  echo "$HOME/Library/Logs/ds4-proxy" ;;
        server) echo "$HOME/Library/Logs/ds4-server" ;;
    esac
}

_ds4_log_file() {
    case "$1" in
        proxy)  echo "$(_ds4_log_dir proxy)/proxy.log" ;;
        server) echo "$(_ds4_log_dir server)/kvcache.log" ;;
    esac
}

_ds4_valid_svc() {
    case "$1" in
        proxy|server) return 0 ;;
        *) return 1 ;;
    esac
}

_ds4_pgrep_pattern() {
    case "$1" in
        proxy)  echo "proxy.server" ;;
        server) echo "caffeinate.*ds4-server" ;;
    esac
}
