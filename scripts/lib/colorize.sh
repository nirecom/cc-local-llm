#!/bin/sh
# ds4_colorize: stdin→stdout ANSI color filter for ds4-server output.
# Only applied to TTY output; files receive raw bytes (tee is upstream).
set -eu

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
