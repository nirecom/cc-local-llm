#!/bin/sh
# SSOT for ds4 service paths and patterns. Repository root is owned by
# lib/root.sh — this file requires it to be sourced first.
set -eu

: "${CCGW_OPS_ROOT:?paths.sh requires lib/root.sh to be sourced first}"
DS4_SERVER_ROOT="$HOME/git/ds4"
LLAMA_SWAP_ROOT="$CCGW_OPS_ROOT/llama-swap/m5-max-128gb"
LITELLM_ROOT="$CCGW_OPS_ROOT/litellm-server"
CCGW_RUN_DIR="$HOME/Library/Application Support/cc-local-llm/run"

_ds4_pid_file() { echo "$CCGW_RUN_DIR/${1}.pid"; }

_ds4_log_dir() {
    case "$1" in
        proxy)      echo "$HOME/Library/Logs/ccgw-proxy" ;;
        server)     echo "$HOME/Library/Logs/ds4-server" ;;
        llama-swap) echo "$HOME/Library/Logs/llama-swap" ;;
        litellm)    echo "$HOME/Library/Logs/litellm" ;;
    esac
}

_ds4_log_file() {
    case "$1" in
        proxy)      echo "$(_ds4_log_dir proxy)/proxy.log" ;;
        server)     echo "$(_ds4_log_dir server)/kvcache.log" ;;
        llama-swap) echo "$(_ds4_log_dir llama-swap)/llama-swap.log" ;;
        litellm)    echo "$(_ds4_log_dir litellm)/litellm.log" ;;
    esac
}

# 'server' (bare ds4-server) is a valid target for manual foreground debugging
# only -- it is deliberately excluded from the "all" group in serverctl.sh, since
# llama-swap now owns ds4-server's start/stop lifecycle exclusively. Running
# both would double-manage the same process and break ds4/Laguna exclusivity.
_ds4_valid_svc() {
    case "$1" in
        proxy|server|llama-swap|litellm) return 0 ;;
        *) return 1 ;;
    esac
}

_ds4_pgrep_pattern() {
    case "$1" in
        proxy)      echo "proxy.server" ;;
        server)     echo "caffeinate.*ds4-server" ;;
        llama-swap) echo "llama-swap.*config.yaml" ;;
        # Directory-qualified: a bare `litellm.*config` would also match a
        # litellm the user runs by hand against their own config, and
        # `serverctl stop litellm` would kill it.
        litellm)    echo "litellm.*/litellm-server/config.yaml" ;;
    esac
}

# Foreground-launcher wrapper filename under scripts/, used by launchd
# ProgramArguments. Each name is the component it launches: ccgw-proxy is the
# gateway's own reverse proxy, ds4-server is the DeepSeek V4 Flash backend, and
# llama-swap/litellm are third-party tools that keep their own names.
_ds4_wrapper_script() {
    case "$1" in
        proxy)      echo "ccgw-proxy.sh" ;;
        server)     echo "ds4-server.sh" ;;
        llama-swap) echo "llama-swap.sh" ;;
        litellm)    echo "litellm.sh" ;;
    esac
}
