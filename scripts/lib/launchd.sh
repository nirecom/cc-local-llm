#!/bin/sh
# launchd LaunchAgent helpers for ds4 services.
# Sourced by serverctl.sh before lifecycle.sh.
set -eu

_ds4_plist_path() { echo "$HOME/Library/LaunchAgents/com.nire.ds4-${1}.plist"; }
_ds4_plist_label() { echo "com.nire.ds4-${1}"; }

_ds4_launchd_active() {
    _label="$(_ds4_plist_label "$1")"
    _plist="$(_ds4_plist_path "$1")"
    [ -f "$_plist" ] && launchctl list "$_label" >/dev/null 2>&1
}

_ds4_write_plist() {
    _svc="$1"
    _plist="$(_ds4_plist_path "$_svc")"
    _label="$(_ds4_plist_label "$_svc")"
    _wrapper="$DS4_OPS_ROOT/scripts/$(_ds4_wrapper_script "$_svc")"
    _cwd="$(_ds4_cwd "$_svc")"
    _logfile="$(_ds4_log_file "$_svc")"

    if [ "${DS4_LOG:-on}" = "on" ]; then
        _out_path="$_logfile"
        _err_path="$_logfile"
    else
        _out_path="/dev/null"
        _err_path="/dev/null"
    fi

    # launchd hands the agent a minimal PATH, so every service binary's
    # directory has to be named here — uv, llama-swap and litellm alike, since
    # an unresolvable binary shows up only as a KeepAlive respawn loop after
    # `serverctl install`. Missing binaries are skipped and repeated
    # directories (the usual single-prefix install) are emitted once.
    _path_val="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    _resolved=""
    for _bin in uv llama-swap litellm; do
        command -v "$_bin" >/dev/null 2>&1 || continue
        _dir="$(dirname "$(command -v "$_bin")")"
        [ -n "$_dir" ] || continue
        case ":${_resolved}:${_path_val}:" in
            *":${_dir}:"*) continue ;;
        esac
        if [ -z "$_resolved" ]; then
            _resolved="$_dir"
        else
            _resolved="${_resolved}:${_dir}"
        fi
    done
    if [ -n "$_resolved" ]; then
        _path_val="${_resolved}:${_path_val}"
    fi

    mkdir -p "$(_ds4_log_dir "$_svc")"

    cat > "$_plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>${_wrapper}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${_cwd}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${_out_path}</string>
    <key>StandardErrorPath</key>
    <string>${_err_path}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${_path_val}</string>
    </dict>
</dict>
</plist>
PLIST_EOF
}

ds4_install() {
    _svc="$1"
    _plist="$(_ds4_plist_path "$_svc")"
    _label="$(_ds4_plist_label "$_svc")"
    mkdir -p "$HOME/Library/LaunchAgents"
    _ds4_write_plist "$_svc"
    launchctl unload "$_plist" 2>/dev/null || true
    launchctl load -w "$_plist"
    echo "[serverctl] installed $_label"
}

ds4_uninstall() {
    _svc="$1"
    _plist="$(_ds4_plist_path "$_svc")"
    _label="$(_ds4_plist_label "$_svc")"
    launchctl unload -w "$_plist" 2>/dev/null || true
    rm -f "$_plist"
    echo "[serverctl] uninstalled $_label"
}
