#!/bin/sh
# ds4_colorize: stdin→stdout ANSI color filter for ds4-server output.
# Only applied to TTY output; files receive raw bytes (tee is upstream).
set -eu

# Fixed per-service color, used to tag interleaved `logs all` output so a
# high-volume service (litellm) doesn't visually drown out the others.
_ds4_service_color() {
    case "$1" in
        proxy)      echo "35" ;; # magenta
        llama-swap) echo "34" ;; # blue
        litellm)    echo "32" ;; # green
        server)     echo "36" ;; # cyan
        *)          echo "37" ;; # white
    esac
}

# ds4_prefix_colorize <svc>: stdin→stdout filter that tags every line with a
# "[svc]" prefix in that service's fixed color. Used by `serverctl logs all`
# so lines stay attributable to their source even when one service dominates
# the interleaved stream.
ds4_prefix_colorize() {
    _svc="$1"
    _code="$(_ds4_service_color "$_svc")"
    awk -v svc="$_svc" -v code="$_code" '
    {
        printf "\033[%sm[%s]\033[0m %s\n", code, svc, $0
        fflush()
    }'
}

# ds4_prefix_plain <svc>: stdin→stdout filter that tags every line with a
# "[svc]" prefix, no ANSI. Used by `serverctl logs all` when output is not a
# TTY (piped/redirected), where color codes would pollute the stream.
ds4_prefix_plain() {
    _svc="$1"
    awk -v svc="$_svc" '{ printf "[%s] %s\n", svc, $0; fflush() }'
}

ds4_colorize() {
    awk '
    {
        line = $0
        color = ""
        if (line ~ /kv cache evicted|disk-cache-full/) {
            color = "\033[33m"
        } else if (line ~ /THINKING/ && line ~ /chat/) {
            color = "\033[36m"
        } else if (tolower(line) ~ /error|warn/) {
            color = "\033[31m"
        }
        if (color != "") {
            printf "%s%s\033[0m\n", color, line
        } else {
            print line
        }
        fflush()
    }'
}
