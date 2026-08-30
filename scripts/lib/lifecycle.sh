#!/bin/sh
# Lifecycle management for ds4 services (start/stop/restart/status/logs/exec).
# Sourced by serverctl.sh after launchd.sh (source order matters).
set -eu

# Everything _ds4_cmd prints is handed to `eval` by ds4_exec, so a value that
# carries a double quote or a shell metacharacter escapes its quoted argument
# and is executed as code. Every value sourced from .env is therefore screened
# against a charset allowlist before it is interpolated into the command
# string — refusing here, by name, beats debugging an injected command later.
_ds4_check_hostport() {
    case "$2" in
        *[!0-9a-zA-Z:.%-]*)
            echo "[serverctl] invalid $1 value (allowed chars: 0-9 a-z A-Z : . % -)" >&2
            exit 1
            ;;
    esac
}

_ds4_check_path() {
    case "$2" in
        *[!0-9a-zA-Z/._-]*)
            echo "[serverctl] invalid $1 value (allowed chars: 0-9 a-z A-Z / . _ -)" >&2
            exit 1
            ;;
    esac
}

# Fail-closed TLS toggle, mirroring proxy/config.py's CCGW_PROXY_TLS handling:
# only an explicit, case-insensitive "off" (surrounding whitespace ignored)
# disables TLS. A typo such as "ON" or "0" must never silently drop the gateway
# to plaintext on a LAN-visible bind.
_ds4_litellm_tls_enabled() {
    _tls="${LITELLM_TLS:-on}"
    # POSIX sh has no trim builtin; strip leading then trailing whitespace.
    _tls="${_tls#"${_tls%%[![:space:]]*}"}"
    _tls="${_tls%"${_tls##*[![:space:]]}"}"
    case "$_tls" in
        [Oo][Ff][Ff]) return 1 ;;
        *) return 0 ;;
    esac
}

_ds4_cmd() {
    case "$1" in
        proxy)
            echo "env PYTHONUNBUFFERED=1 uv run python -m proxy.server"
            ;;
        server)
            HOST="${DS4_SERVER_HOST:-127.0.0.1}"
            _ds4_check_hostport DS4_SERVER_HOST "$HOST"
            echo "caffeinate -ism ./ds4-server --metal --quality --ctx 393216 --kv-disk-dir \"$HOME/Library/Caches/ds4-server/kv\" --kv-disk-space-mb 32768 --kv-cache-cold-max-tokens 90000 --kv-cache-continued-interval-tokens 50000 --warm-weights --batched-session 2 --host \"$HOST\""
            ;;
        llama-swap)
            _host="${LLAMA_SWAP_HOST:-127.0.0.1}"
            _port="${LLAMA_SWAP_PORT:-18080}"
            _ds4_check_path LLAMA_SWAP_ROOT "$LLAMA_SWAP_ROOT"
            _ds4_check_hostport LLAMA_SWAP_HOST "$_host"
            _ds4_check_hostport LLAMA_SWAP_PORT "$_port"
            echo "llama-swap -config \"$LLAMA_SWAP_ROOT/config.yaml\" -listen \"$_host:$_port\""
            ;;
        litellm)
            _host="${LITELLM_HOST:-0.0.0.0}"
            _port="${LITELLM_PORT:-8445}"
            _ds4_check_path LITELLM_ROOT "$LITELLM_ROOT"
            _ds4_check_hostport LITELLM_HOST "$_host"
            _ds4_check_hostport LITELLM_PORT "$_port"
            _cmd="litellm --config \"$LITELLM_ROOT/config.yaml\" --host \"$_host\" --port \"$_port\""
            if _ds4_litellm_tls_enabled; then
                _cert="${LITELLM_TLS_CERT:-}"
                _key="${LITELLM_TLS_KEY:-}"
                _ds4_check_path LITELLM_TLS_CERT "$_cert"
                _ds4_check_path LITELLM_TLS_KEY "$_key"
                _cmd="$_cmd --ssl_certfile_path \"$_cert\" --ssl_keyfile_path \"$_key\""
            fi
            echo "$_cmd"
            ;;
    esac
}

_ds4_cwd() {
    case "$1" in
        proxy)      echo "$CCGW_OPS_ROOT" ;;
        server)     echo "$DS4_SERVER_ROOT" ;;
        llama-swap) echo "$LLAMA_SWAP_ROOT" ;;
        litellm)    echo "$LITELLM_ROOT" ;;
    esac
}

# Required configuration for a service, checked before anything is launched.
# A LaunchAgent has KeepAlive set, so a service that starts and then dies on a
# missing credential respawns forever and buries the cause in its log; refusing
# here names the variable once, on stderr, when the user asked for the start.
_ds4_check_config() {
    case "$1" in
        proxy)
            if [ -z "${CCGW_PROXY_AUTH_TOKEN:-}" ]; then
                echo "[ccgw-proxy] CCGW_PROXY_AUTH_TOKEN is not set in .env — refusing to start" >&2
                return 1
            fi
            ;;
        litellm)
            _bad=0
            if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
                echo "[litellm] LITELLM_MASTER_KEY is not set in .env — refusing to start" >&2
                _bad=1
            fi
            if [ -z "${LITELLM_CCGW_PROXY_URL:-}" ]; then
                echo "[litellm] LITELLM_CCGW_PROXY_URL is not set in .env — refusing to start" >&2
                _bad=1
            fi
            if _ds4_litellm_tls_enabled &&
               { [ -z "${LITELLM_TLS_CERT:-}" ] || [ -z "${LITELLM_TLS_KEY:-}" ]; }; then
                echo "[litellm] LITELLM_TLS is on but LITELLM_TLS_CERT / LITELLM_TLS_KEY is not set in .env — refusing to start" >&2
                _bad=1
            fi
            [ "$_bad" = "0" ] || return 1
            ;;
    esac
    return 0
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
    _ds4_check_config "$_svc" || exit 1
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
        if [ "${CCGW_LOG:-on}" = "on" ]; then
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
        echo "[serverctl] $_svc is managed by launchd (KeepAlive). Use 'serverctl install $_svc' instead of 'start'." >&2
        return 0
    fi
    if _pid=$(_ds4_running "$_svc"); then
        echo "[serverctl] $_svc already running (pid $_pid)"
        return 0
    fi
    if pgrep -f "$(_ds4_pgrep_pattern "$_svc")" >/dev/null 2>&1; then
        echo "[serverctl] $_svc already running (untracked)"
        return 0
    fi
    _ds4_check_config "$_svc" || exit 1
    mkdir -p "$CCGW_RUN_DIR"
    mkdir -p "$(_ds4_log_dir "$_svc")"
    _logfile="$(_ds4_log_file "$_svc")"
    _pid_file="$(_ds4_pid_file "$_svc")"
    if [ "${CCGW_LOG:-on}" = "on" ]; then
        nohup "$SERVERCTL" __run "$_svc" >>"$_logfile" 2>&1 &
    else
        nohup "$SERVERCTL" __run "$_svc" >/dev/null 2>&1 &
    fi
    echo $! > "$_pid_file"
    _started_pid=$(cat "$_pid_file")
    # The `&` fork returns before the child has exec'd the service, so anything
    # that inspects the log or the process table right after `start` (including
    # the next service in an `all` loop) would otherwise race the launch.
    sleep 0.5
    echo "[serverctl] started $_svc (pid $_started_pid)"
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
        echo "[serverctl] $_svc is managed by launchd (KeepAlive — it will restart immediately if killed). To stop: 'serverctl uninstall $_svc'" >&2
        return 1
    fi
    if _pid=$(_ds4_running "$_svc"); then
        _ds4_stop_pid "$_pid" "$_svc"
        rm -f "$(_ds4_pid_file "$_svc")"
        echo "[serverctl] stopped $_svc"
    else
        echo "[serverctl] $_svc not running"
    fi
}

ds4_restart() {
    _svc="$1"
    # Under launchd the stop/start pair cannot work: KeepAlive revives the job
    # the moment stop kills it, and start refuses outright. Re-exec the job in
    # place instead -- the service re-reads its config at startup, which is the
    # whole point of a restart.
    if _ds4_launchd_active "$_svc"; then
        _label="$(_ds4_plist_label "$_svc")"
        for _domain in "gui/$(id -u)" "user/$(id -u)"; do
            if launchctl kickstart -k "$_domain/$_label" >/dev/null 2>&1; then
                echo "[serverctl] restarted $_label (launchd $_domain)"
                return 0
            fi
        done
        echo "[serverctl] kickstart unavailable for $_label; reloading instead" >&2
        ds4_install "$_svc"
        return $?
    fi
    ds4_stop "$_svc"
    ds4_start "$_svc"
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
    if [ "${CCGW_LOG:-on}" != "on" ]; then
        echo "[serverctl] log recording is disabled (CCGW_LOG=off)" >&2
        return 1
    fi
    if [ "$_svc" = "all" ]; then
        # A single `tail -f file1 file2 ...` interleaves lines as they arrive,
        # with no indication of which file a line came from beyond an
        # occasional "==> file <==" header on switch — so a high-volume
        # service (litellm) reads as if it were the only thing logging.
        # Tail each service separately and tag every line with a colored
        # "[svc]" prefix so the source stays legible regardless of volume.
        # `tail -f` with no `-n` dumps 10 lines of backlog per file before
        # following; three services at the default would flood 30 lines on
        # startup alone, well past one terminal screen. Keep the per-service
        # backlog small so `all` fits in a normal window.
        _n="${CCGW_LOG_TAIL_LINES:-6}"
        _found=0
        _pids=""
        for _s in proxy llama-swap litellm; do
            _f="$(_ds4_log_file "$_s")"
            [ -f "$_f" ] || continue
            _found=1
            if [ -t 1 ] && [ "${CCGW_LOG_COLOR:-on}" = "on" ]; then
                tail -n "$_n" -f "$_f" | ds4_prefix_colorize "$_s" &
            else
                tail -n "$_n" -f "$_f" | ds4_prefix_plain "$_s" &
            fi
            _pids="$_pids $!"
        done
        if [ "$_found" = "0" ]; then
            echo "[serverctl] no log files found" >&2
            return 1
        fi
        # shellcheck disable=SC2086
        trap 'kill $_pids 2>/dev/null' INT TERM
        wait
    else
        _logfile="$(_ds4_log_file "$_svc")"
        if [ ! -f "$_logfile" ]; then
            echo "[serverctl] log file not found: $_logfile" >&2
            return 1
        fi
        if [ -t 1 ] && [ "$_svc" = "server" ] && [ "${DS4_SERVER_COLOR_LOG:-on}" = "on" ]; then
            tail -f "$_logfile" | ds4_colorize
        else
            tail -f "$_logfile"
        fi
    fi
}
