#!/bin/sh
# launchd LaunchAgent helpers for ds4 services.
# Sourced by ds4ctl.sh before lifecycle.sh.
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
    _wrapper="$DS4_OPS_ROOT/scripts/ds4-${_svc}.sh"
    _cwd="$(_ds4_cwd "$_svc")"
    _logfile="$(_ds4_log_file "$_svc")"

    if [ "${DS4_LOG:-on}" = "on" ]; then
        _out_path="$_logfile"
        _err_path="$_logfile"
    else
        _out_path="/dev/null"
        _err_path="/dev/null"
    fi

    # Resolve uv path for launchd's minimal PATH
    _uv_bin=""
    if command -v uv >/dev/null 2>&1; then
        _uv_bin="$(dirname "$(command -v uv)")"
    fi
    _path_val="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if [ -n "$_uv_bin" ]; then
        _path_val="${_uv_bin}:${_path_val}"
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
    echo "[ds4-ops] installed $_label"
}

ds4_uninstall() {
    _svc="$1"
    _plist="$(_ds4_plist_path "$_svc")"
    _label="$(_ds4_plist_label "$_svc")"
    launchctl unload -w "$_plist" 2>/dev/null || true
    rm -f "$_plist"
    echo "[ds4-ops] uninstalled $_label"
}
