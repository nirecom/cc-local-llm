#!/bin/sh
# Lifecycle management for ds4 services (start/stop/restart/status/logs/exec).
# Sourced by ds4ctl.sh after launchd.sh (source order matters).
set -eu

_ds4_cmd() {
    case "$1" in
        proxy)
            echo "uv run python -m proxy.server"
            ;;
        server)
            HOST="${DS4_SERVER_HOST:-127.0.0.1}"
            case "$HOST" in
                *[!0-9a-zA-Z:.%-]*)
                    echo "[ds4-ops] invalid DS4_SERVER_HOST value (allowed chars: 0-9 a-z A-Z : . %)" >&2
                    exit 1
                    ;;
            esac
            echo "caffeinate -ism ./ds4-server --metal --quality --ctx 393216 --kv-disk-dir \"$HOME/Library/Caches/ds4-server/kv\" --kv-disk-space-mb 32768 --kv-cache-cold-max-tokens 90000 --kv-cache-continued-interval-tokens 25000 --warm-weights --host \"$HOST\""
            ;;
    esac
}

_ds4_cwd() {
    case "$1" in
        proxy)  echo "$DS4_OPS_ROOT" ;;
        server) echo "$DS4_SERVER_ROOT" ;;
    esac
}

_ds4_running() {
    _pid_file="$(_ds4_pid_file "$1")"
    if [ -f "$_pid_file" ]; then
        _pid=$(cat "$_pid_file")
        if kill -0 "$_pid" 2>/dev/null; then
            echo "$_pid"
            return 0
        else
            rm -f "$_pid_file"
        fi
    fi
    return 1
}

ds4_exec() {
    _svc="$1"
    if [ "$_svc" = "proxy" ] && [ -z "${DS4_PROXY_AUTH_TOKEN:-}" ]; then
        echo "[ds4-proxy] DS4_PROXY_AUTH_TOKEN is not set in .env — refusing to start" >&2
        exit 1
    fi
    mkdir -p "$(_ds4_log_dir "$_svc")"
    _logfile="$(_ds4_log_file "$_svc")"
    _cmd="$(_ds4_cmd "$_svc")"
    _cwd="$(_ds4_cwd "$_svc")"

    if [ -t 1 ]; then
        # TTY (foreground interactive)
        _color_filter="cat"
        if [ "$_svc" = "server" ] && [ "${DS4_SERVER_COLOR_LOG:-on}" = "on" ]; then
            _color_filter="ds4_colorize"
        fi
        if [ "${DS4_LOG:-on}" = "on" ]; then
            cd "$_cwd"
            eval "$_cmd" 2>&1 | tee -a "$_logfile" | "$_color_filter"
        else
            cd "$_cwd"
            eval "$_cmd" 2>&1 | "$_color_filter"
        fi
    else
        # Non-TTY (launchd / nohup) — exec to let caller track the process
        cd "$_cwd"
        eval "exec $_cmd"
    fi
}

ds4_start() {
    _svc="$1"
    if _ds4_launchd_active "$_svc"; then
        echo "[ds4-ops] $_svc is managed by launchd (KeepAlive). Use 'ds4ctl install $_svc' instead of 'start'." >&2
        return 0
    fi
    if _pid=$(_ds4_running "$_svc"); then
        echo "[ds4-ops] $_svc already running (pid $_pid)"
        return 0
    fi
    if pgrep -f "$(_ds4_pgrep_pattern "$_svc")" >/dev/null 2>&1; then
        echo "[ds4-ops] $_svc already running (untracked)"
        return 0
    fi
    if [ "$_svc" = "proxy" ] && [ -z "${DS4_PROXY_AUTH_TOKEN:-}" ]; then
        echo "[ds4-proxy] DS4_PROXY_AUTH_TOKEN is not set in .env — refusing to start" >&2
        exit 1
    fi
    mkdir -p "$DS4_RUN_DIR"
    mkdir -p "$(_ds4_log_dir "$_svc")"
    _logfile="$(_ds4_log_file "$_svc")"
    _pid_file="$(_ds4_pid_file "$_svc")"
    if [ "${DS4_LOG:-on}" = "on" ]; then
        nohup "$DS4CTL" __run "$_svc" >>"$_logfile" 2>&1 &
    else
        nohup "$DS4CTL" __run "$_svc" >/dev/null 2>&1 &
    fi
    echo $! > "$_pid_file"
    _started_pid=$(cat "$_pid_file")
    echo "[ds4-ops] started $_svc (pid $_started_pid)"
}

_ds4_stop_pid() {
    _pid="$1"
    _svc="$2"
    # Kill children first to prevent reparenting to launchd/init
    pkill -TERM -P "$_pid" 2>/dev/null || true
    kill -TERM "$_pid" 2>/dev/null || true
    _i=0
    while [ $_i -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do
        sleep 1
        _i=$((_i + 1))
    done
    if kill -0 "$_pid" 2>/dev/null; then
        pkill -KILL -P "$_pid" 2>/dev/null || true
        kill -KILL "$_pid" 2>/dev/null || true
    fi
    # Insurance: catch any stragglers (pattern is narrow enough to avoid false kills)
    pkill -f "$(_ds4_pgrep_pattern "$_svc")" 2>/dev/null || true
}

ds4_stop() {
    _svc="$1"
    if _ds4_launchd_active "$_svc"; then
        echo "[ds4-ops] $_svc is managed by launchd (KeepAlive — it will restart immediately if killed). To stop: 'ds4ctl uninstall $_svc'" >&2
        return 1
    fi
    if _pid=$(_ds4_running "$_svc"); then
        _ds4_stop_pid "$_pid" "$_svc"
        rm -f "$(_ds4_pid_file "$_svc")"
        echo "[ds4-ops] stopped $_svc"
    else
        echo "[ds4-ops] $_svc not running"
    fi
}

ds4_restart() {
    ds4_stop "$1"
    ds4_start "$1"
}

ds4_status() {
    _svc="$1"
    if _pid=$(_ds4_running "$_svc"); then
        echo "$_svc: running (pid $_pid)"
    elif _ds4_launchd_active "$_svc"; then
        echo "$_svc: running (launchd)"
    else
        echo "$_svc: stopped"
    fi
}

ds4_logs() {
    _svc="$1"
    if [ "${DS4_LOG:-on}" != "on" ]; then
        echo "[ds4-ops] log recording is disabled (DS4_LOG=off)" >&2
        return 1
    fi
    if [ "$_svc" = "all" ]; then
        _pf="$(_ds4_log_file proxy)"
        _sf="$(_ds4_log_file server)"
        if [ ! -f "$_pf" ] && [ ! -f "$_sf" ]; then
            echo "[ds4-ops] no log files found" >&2
            return 1
        fi
        # Use only existing files
        _files=""
        [ -f "$_pf" ] && _files="$_pf"
        [ -f "$_sf" ] && _files="$_files $_sf"
        # shellcheck disable=SC2086
        tail -f $_files
    else
        _logfile="$(_ds4_log_file "$_svc")"
        if [ ! -f "$_logfile" ]; then
            echo "[ds4-ops] log file not found: $_logfile" >&2
            return 1
        fi
        if [ -t 1 ] && [ "$_svc" = "server" ] && [ "${DS4_SERVER_COLOR_LOG:-on}" = "on" ]; then
            tail -f "$_logfile" | ds4_colorize
        else
            tail -f "$_logfile"
        fi
    fi
}
