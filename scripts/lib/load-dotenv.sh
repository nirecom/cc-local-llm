#!/bin/sh
# Sourced by ds4-proxy.sh. Loads KEY=VALUE pairs from DOTENV_FILE (must be set
# by caller). Shell-existing values take precedence (matches code-ds4.cmd semantics).
# Lines starting with # and blank lines are skipped.

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
        # Export only when the variable is not already set in the environment.
        if ! _dotenv_is_set "$_dotenv_key"; then
            export "$_dotenv_key=$_dotenv_val"
        fi
    done < "$DOTENV_FILE"
    unset _dotenv_line _dotenv_key _dotenv_val
fi
