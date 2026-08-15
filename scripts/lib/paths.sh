#!/bin/sh
# SSOT for ds4 service paths and patterns. Repository root is owned by
# lib/root.sh — this file requires it to be sourced first.
set -eu

: "${DS4_OPS_ROOT:?paths.sh requires lib/root.sh to be sourced first}"
DS4_SERVER_ROOT="$HOME/git/ds4"
LLAMA_SWAP_ROOT="$DS4_OPS_ROOT/llama-swap"
DS4_RUN_DIR="$HOME/Library/Application Support/cc-local-llm/run"

_ds4_pid_file() { echo "$DS4_RUN_DIR/${1}.pid"; }

_ds4_log_dir() {
    case "$1" in
        proxy)      echo "$HOME/Library/Logs/ds4-proxy" ;;
        server)     echo "$HOME/Library/Logs/ds4-server" ;;
        llama-swap) echo "$HOME/Library/Logs/llama-swap" ;;
    esac
}

_ds4_log_file() {
    case "$1" in
        proxy)      echo "$(_ds4_log_dir proxy)/proxy.log" ;;
        server)     echo "$(_ds4_log_dir server)/kvcache.log" ;;
        llama-swap) echo "$(_ds4_log_dir llama-swap)/llama-swap.log" ;;
    esac
}

# 'server' (bare ds4-server) is a valid target for manual foreground debugging
# only -- it is deliberately excluded from the "all" group in serverctl.sh, since
# llama-swap now owns ds4-server's start/stop lifecycle exclusively. Running
# both would double-manage the same process and break ds4/Laguna exclusivity.
_ds4_valid_svc() {
    case "$1" in
        proxy|server|llama-swap) return 0 ;;
        *) return 1 ;;
    esac
}

_ds4_pgrep_pattern() {
    case "$1" in
        proxy)      echo "proxy.server" ;;
        server)     echo "caffeinate.*ds4-server" ;;
        llama-swap) echo "llama-swap.*config.yaml" ;;
    esac
}

# Foreground-launcher wrapper filename under scripts/, used by launchd
# ProgramArguments. ds4-proxy/ds4-server are named after the literal process
# they launch; llama-swap is a neutral (non-ds4-branded) tool, so it keeps its
# own name rather than a "ds4-" prefix.
_ds4_wrapper_script() {
    case "$1" in
        proxy)      echo "ds4-proxy.sh" ;;
        server)     echo "ds4-server.sh" ;;
        llama-swap) echo "llama-swap.sh" ;;
    esac
}
