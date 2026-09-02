#!/bin/sh
# Sourced by ccgw-proxy.sh. Loads KEY=VALUE pairs from DOTENV_FILE (must be set
# by caller). Shell-existing values take precedence (matches code-ccgw.ps1 semantics).
# Lines starting with # and blank lines are skipped.

# OS token detection. sh normally only runs on POSIX, but Git Bash/MSYS/Cygwin
# needs to resolve to windows too, so check uname -s rather than assuming.
# Spec: docs/env-conditional-blocks.md
_dotenv_os_token() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        *) echo posix ;;
    esac
}

# Strips #@if <token> / #@endif blocks. Must stay byte-for-byte behaviorally
# identical to agents/hooks/lib/load-env.js's filterOsBlocks() state machine
# (docs/env-conditional-blocks.md is the SSOT spec both follow).
_dotenv_filter_os_blocks() {
    awk -v active="$(_dotenv_os_token)" '
        {
            orig = $0
            sub(/\r$/, "", orig)
            line = orig
            gsub(/^[ \t]+/, "", line)
            gsub(/[ \t]+$/, "", line)
            if (line ~ /^#@if /) {
                depth++
                token = substr(line, 6)
                gsub(/^[ \t]+/, "", token)
                gsub(/[ \t]+$/, "", token)
                if (!suppressing && token != active) { suppressing = 1; suppress_depth = depth }
                next
            }
            if (line == "#@endif") {
                if (depth > 0) {
                    if (suppressing && depth == suppress_depth) suppressing = 0
                    depth--
                }
                next
            }
            if (line ~ /^#@/) { next }
            if (!suppressing) print orig
        }
    ' "$1"
}

# Return 0 if the environment variable named by $1 is already set (matches the
# "shell value wins" semantics: an exported value is what the child would see).
_dotenv_is_set() {
    printenv "$1" >/dev/null 2>&1
}

if [ -f "$DOTENV_FILE" ]; then
    while IFS= read -r _dotenv_line || [ -n "$_dotenv_line" ]; do
        case "$_dotenv_line" in
            '#'*) continue ;;
            '') continue ;;
        esac
        # Split on the first '=' only.
        _dotenv_key=${_dotenv_line%%=*}
        _dotenv_val=${_dotenv_line#*=}
        # A blank key, or a line with no '=' at all, is not a KEY=VALUE pair.
        if [ -z "$_dotenv_key" ] || [ "$_dotenv_key" = "$_dotenv_line" ]; then
            continue
        fi
        # Export only when the variable is not already set in the environment:
        # one rule for every key, so what the shell hands over always wins.
        if ! _dotenv_is_set "$_dotenv_key"; then
            export "$_dotenv_key=$_dotenv_val"
        fi
    done <<EOF
$(_dotenv_filter_os_blocks "$DOTENV_FILE")
EOF
    unset _dotenv_line _dotenv_key _dotenv_val
fi
