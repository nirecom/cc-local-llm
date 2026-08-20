#!/bin/sh
# Atomic file replacement that lands on the real file behind a symlinked
# target instead of replacing the symlink itself (issue #62).
#
# Usage:
#   tmp="$(_ccgw_begin_write "$FILE")"
#   ... > "$tmp"
#   _ccgw_commit_write "$tmp" "$FILE"

# Real path behind <path>: follows a chain of any depth, absolute or relative
# targets. Avoids `readlink -f`, which BSD/macOS readlink does not have.
_ccgw_resolve_symlink() {
    _crs_path="$1"
    _crs_hops=0
    while [ -L "$_crs_path" ]; do
        _crs_hops=$((_crs_hops + 1))
        if [ "$_crs_hops" -gt 40 ]; then
            echo "[atomic-write] symlink chain too deep (loop?): $1" >&2
            return 1
        fi
        _crs_target="$(readlink "$_crs_path")"
        case "$_crs_target" in
            "/"*) _crs_path="$_crs_target" ;;
            *)    _crs_path="$(dirname -- "$_crs_path")/$_crs_target" ;;
        esac
    done
    # A relative hop leaves a path only valid from the caller's cwd.
    _crs_dir="$(CDPATH= cd -- "$(dirname -- "$_crs_path")" && pwd)" || return 1
    printf '%s\n' "$_crs_dir/$(basename -- "$_crs_path")"
}

# Octal mode of <path>; empty if neither stat dialect (BSD, then GNU) answers.
_ccgw_file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null && return 0
    stat -c '%a' "$1" 2>/dev/null && return 0
    return 0
}

# Temp file beside <target>'s real file -- same directory, so the commit is a
# rename -- carrying that file's mode, since mktemp alone would force 600.
_ccgw_begin_write() {
    _cbw_real="$(_ccgw_resolve_symlink "$1")" || return 1
    _cbw_tmp="$(mktemp "${_cbw_real}.XXXXXX")" || return 1
    if [ -e "$_cbw_real" ]; then
        _cbw_mode="$(_ccgw_file_mode "$_cbw_real")"
        [ -n "$_cbw_mode" ] && chmod "$_cbw_mode" "$_cbw_tmp"
    fi
    printf '%s\n' "$_cbw_tmp"
}

# Moves <tmp> onto <target>'s real file, leaving any symlink at <target> intact.
_ccgw_commit_write() {
    _ccw_real="$(_ccgw_resolve_symlink "$2")" || return 1
    mv -- "$1" "$_ccw_real"
}
