#!/bin/sh
# kvcache-report — aggregate the ds4-server KV cache log into a fixed report.
#
# Output is diff-friendly by contract: values come only from the log (never
# from the clock or file size) and every column is a fixed printf width.
#
# `kv cache stored` is a write and is counted in [3]; `kv cache evicted` is a
# deletion and is counted nowhere — matching it would double the write totals.
# Thresholds are the ones issue #34 used: 60s for [1], and 1000 / 10000 /
# 50000 common-prefix tokens for [2].
set -eu

# Pinned so [3]'s sort stays byte-ordered and "%.2f" keeps "." as the decimal
# separator regardless of the ambient locale (CPR-UNV).
export LC_ALL=C

CCGW_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/root.sh
. "$CCGW_SCRIPT_DIR/lib/root.sh"     # establishes CCGW_OPS_ROOT (paths.sh requires it)
# lib/load-dotenv.sh is deliberately not sourced: a read-only analyzer has no
# .env-derived input and must not read the developer's real .env.
# shellcheck source=scripts/lib/paths.sh
. "$CCGW_SCRIPT_DIR/lib/paths.sh"    # _ds4_log_file server is the SSOT for the log path

LOG_DEFAULT="$(_ds4_log_file server)"

# Display only: hides the account name in a pasted report (public repo). Every
# functional use still operates on the untouched path.
_display_path() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

_usage() {
    cat <<EOF
Usage: kvcache-report.sh [options]

Options:
  -f, --file PATH   Log file to analyze (default: $(_display_path "$LOG_DEFAULT"))
      --since SPEC  Include entries at or after SPEC (default: beginning of file)
      --until SPEC  Include entries at or before SPEC (default: end of file)
  -h, --help        Show this help

SPEC is a timestamp with 4, 8, or 10 digits after separators are removed:
  MMDD          e.g. 0801,  "08-01"
  MMDDHHMM      e.g. 08011200, "0801 12:00"
  MMDDHHMMSS    e.g. 0801120000, "0801 12:00:00"
--since pads the missing part with the earliest instant (00:00:00),
--until with the latest (23:59:59).
EOF
}

_usage_error() {
    echo "[kvcache-report] $1" >&2
    _usage >&2
    exit 2
}

# Log timestamps are "MMDD HH:MM:SS" with no year, so a numerically compared
# 10-digit key replaces date parsing; separators are stripped first so every
# accepted spelling normalizes the same way (CPR-UNV).
#
# Drops one leading '0' so POSIX arithmetic does not read "08"/"09" as octal.
_strip_lead0() {
    case "$1" in
        0?) STRIPPED0="${1#0}" ;;
        *)  STRIPPED0="$1" ;;
    esac
}

# Field-by-field range check, so "2025-08-01" (month "20" after stripping) is
# rejected instead of silently becoming a wrong range.
_validate_spec_fields() {
    _vf_side="$1"
    _vf_raw="$2"
    _vf_rest="$3"
    _vf_mm="${_vf_rest%????????}";  _vf_rest="${_vf_rest#??}"
    _vf_dd="${_vf_rest%??????}";    _vf_rest="${_vf_rest#??}"
    _vf_hh="${_vf_rest%????}";      _vf_rest="${_vf_rest#??}"
    _vf_mi="${_vf_rest%??}";        _vf_ss="${_vf_rest#??}"

    _strip_lead0 "$_vf_mm"
    [ "$STRIPPED0" -ge 1 ] && [ "$STRIPPED0" -le 12 ] || _usage_error "invalid --$_vf_side value: $_vf_raw (month $_vf_mm out of range 01-12)"
    _strip_lead0 "$_vf_dd"
    [ "$STRIPPED0" -ge 1 ] && [ "$STRIPPED0" -le 31 ] || _usage_error "invalid --$_vf_side value: $_vf_raw (day $_vf_dd out of range 01-31)"
    _strip_lead0 "$_vf_hh"
    [ "$STRIPPED0" -ge 0 ] && [ "$STRIPPED0" -le 23 ] || _usage_error "invalid --$_vf_side value: $_vf_raw (hour $_vf_hh out of range 00-23)"
    _strip_lead0 "$_vf_mi"
    [ "$STRIPPED0" -ge 0 ] && [ "$STRIPPED0" -le 59 ] || _usage_error "invalid --$_vf_side value: $_vf_raw (minute $_vf_mi out of range 00-59)"
    _strip_lead0 "$_vf_ss"
    [ "$STRIPPED0" -ge 0 ] && [ "$STRIPPED0" -le 59 ] || _usage_error "invalid --$_vf_side value: $_vf_raw (second $_vf_ss out of range 00-59)"
}

# Returns via NORMALIZED_SPEC, not stdout: _usage_error's exit inside a command
# substitution would only leave the subshell.
_normalize_spec() {
    _ns_side="$1"
    _ns_raw="$2"
    case "$_ns_raw" in
        *[!0-9\ :/-]*) _usage_error "invalid --$_ns_side value: $_ns_raw (only digits, space, ':', '/', '-' allowed)" ;;
    esac
    _ns_digits="$(printf '%s' "$_ns_raw" | tr -cd '0-9')"
    case "${#_ns_digits}" in
        4)
            if [ "$_ns_side" = since ]; then _ns_digits="${_ns_digits}000000"
            else _ns_digits="${_ns_digits}235959"; fi
            ;;
        8)
            if [ "$_ns_side" = since ]; then _ns_digits="${_ns_digits}00"
            else _ns_digits="${_ns_digits}59"; fi
            ;;
        10) ;;
        *)  _usage_error "invalid --$_ns_side value: $_ns_raw (need 4, 8, or 10 digits: MMDD, MMDDHHMM, or MMDDHHMMSS)" ;;
    esac
    _validate_spec_fields "$_ns_side" "$_ns_raw" "$_ns_digits"
    NORMALIZED_SPEC="$_ns_digits"
}

# 10-digit key -> "MMDD HH:MM:SS" for the "range requested" line.
_format_key() {
    _fk_k="$1"
    _fk_d="${_fk_k%??????}"
    _fk_t="${_fk_k#????}"
    _fk_h="${_fk_t%????}"
    _fk_rest="${_fk_t#??}"
    printf '%s %s:%s:%s' "$_fk_d" "$_fk_h" "${_fk_rest%??}" "${_fk_rest#??}"
}

LOG_FILE="$LOG_DEFAULT"
SINCE_KEY="0000000000"
UNTIL_KEY="9999999999"
REQ_SINCE="-"
REQ_UNTIL="-"

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file)
            [ $# -ge 2 ] || _usage_error "missing value for $1"
            LOG_FILE="$2"
            shift 2
            ;;
        --since)
            [ $# -ge 2 ] || _usage_error "missing value for $1"
            _normalize_spec since "$2"
            SINCE_KEY="$NORMALIZED_SPEC"
            REQ_SINCE="$(_format_key "$SINCE_KEY")"
            shift 2
            ;;
        --until)
            [ $# -ge 2 ] || _usage_error "missing value for $1"
            _normalize_spec until "$2"
            UNTIL_KEY="$NORMALIZED_SPEC"
            REQ_UNTIL="$(_format_key "$UNTIL_KEY")"
            shift 2
            ;;
        -h|--help)
            _usage
            exit 0
            ;;
        *)
            _usage_error "unknown option: $1"
            ;;
    esac
done

if [ ! -f "$LOG_FILE" ]; then
    echo "[kvcache-report] log file not found: $LOG_FILE" >&2
    exit 1
fi

# Single awk pass; the whole report is emitted from END so one process owns
# line order (no pipe, no child racing on the shared fd). Zero matching lines
# prints a zero-filled report, keeping the before/after diff line-aligned.
LOGDISPLAY="$(_display_path "$LOG_FILE")"
awk -v LOGPATH="$LOGDISPLAY" -v SINCE="$SINCE_KEY" -v UNTIL="$UNTIL_KEY" \
    -v REQ_SINCE="$REQ_SINCE" -v REQ_UNTIL="$REQ_UNTIL" '
# Insertion sort, ascending by name — never by quantity, whose ranking flips
# between runs and fills the diff with reordering noise. ("" x) forces string
# context, which awk would otherwise drop for numeric-looking values.
function isort(a, n,    i, j, key) {
    for (i = 2; i <= n; i++) {
        key = a[i]
        j = i - 1
        while (j >= 1 && ("" a[j]) > ("" key)) {
            a[j + 1] = a[j]
            j--
        }
        a[j + 1] = key
    }
}
function share(part, total) {
    return (total > 0 ? part * 100.0 / total : 0)
}
function avg(sum, n) {
    return (n > 0 ? sum / n : 0)
}
# Hygiene for log-derived tokens reaching printf: non-printable bytes never
# reach the terminal, and truncation keeps the fixed-width columns intact.
function sanitize(s) {
    gsub(/[^ -~]/, "?", s)
    if (length(s) > 14) s = substr(s, 1, 14)
    return s
}

{ scanned++ }

# Time gate. Startup banner lines carry no timestamp and are skipped silently.
$1 ~ /^[0-9][0-9][0-9][0-9]$/ && $2 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
    t = $2
    gsub(/:/, "", t)
    key = $1 t
    if (key + 0 < SINCE + 0 || key + 0 > UNTIL + 0) next
    inrange++
    stamp = $1 " " $2
    if (obs_n == 0) {
        obs_min_k = key; obs_min = stamp
        obs_max_k = key; obs_max = stamp
    } else {
        if (key + 0 < obs_min_k + 0) { obs_min_k = key; obs_min = stamp }
        if (key + 0 > obs_max_k + 0) { obs_max_k = key; obs_max = stamp }
    }
    obs_n++

    # [1] prompt processing. Field count varies (the TOOLS token), so the
    # duration is located by text, never by field index.
    p = index($0, "prompt done ")
    if (p > 0) {
        rest = substr($0, p + 12)
        if (split(rest, tk, " ") >= 1) {
            v = tk[1]
            sub(/s$/, "", v)
            if (v ~ /^[0-9]+(\.[0-9]+)?$/) {
                sec = v + 0
                p_all_c++; p_all_s += sec
                if (sec > 60) { p_over_c++; p_over_s += sec }
                else          { p_up_c++;   p_up_s   += sec }
            }
        }
    }

    # [2] live kv cache miss. Variable prefix, so values are found by key=.
    if (index($0, "live kv cache miss") > 0) {
        m_total++
        r = ""; c = ""
        for (i = 1; i <= NF; i++) {
            if (substr($i, 1, 7) == "reason=") r = substr($i, 8)
            else if (substr($i, 1, 7) == "common=") c = substr($i, 8)
        }
        if (r != "") {
            if (!(r in mcnt)) mkeys[++mnk] = r
            mcnt[r]++
        }
        if (c != "") {
            cv = c + 0
            if (cv < 1000)       b_lt++
            else if (cv < 10000) b_1k++
            else if (cv < 50000) b_10k++
            else                 b_50k++
        }
    }

    # [3] kv cache stored. The trailing space keeps a future "kv cache stored-"
    # message from matching. Evicted lines are deletions, so they have no row.
    if (index($0, "kv cache stored ") > 0) {
        r = ""; sz = ""; unit = ""
        for (i = 1; i <= NF; i++) {
            if (substr($i, 1, 7) == "reason=") r = substr($i, 8)
            else if (substr($i, 1, 5) == "size=") {
                sz = substr($i, 6)
                unit = (i < NF ? $(i + 1) : "(none)")
            }
        }
        if (r == "") r = "(unknown)"
        if (!(r in scnt)) skeys[++snk] = r
        scnt[r]++
        s_total_c++
        if (sz != "") {
            # Only MiB accumulates; other units go to the warnings line, so a
            # format change cannot silently under-report volume (CPR-UNV).
            if (unit == "MiB") {
                smib[r] += sz + 0
                s_total_m += sz + 0
            } else {
                if (!(unit in ucnt)) ukeys[++unk] = unit
                ucnt[unit]++
            }
        }
    }
}

END {
    HDR5 = "  %-14s%8s%13s%12s%13s\n"
    ROW5 = "  %-14s%8d%13.2f%12.2f%13.2f\n"
    HDR3 = "  %-14s%8s%11s\n"
    ROW3 = "  %-14s%8d%10.1f%%\n"

    printf("kvcache-report %s\n", LOGPATH)
    printf("range requested : %s .. %s\n", REQ_SINCE, REQ_UNTIL)
    if (obs_n > 0) printf("range observed  : %s .. %s\n", obs_min, obs_max)
    else           printf("range observed  : %s .. %s\n", "-", "-")
    printf("lines scanned   : %-7d in range: %d\n", scanned, inrange)
    printf("\n")

    printf("[1] prompt processing  (match: \"prompt done \")\n")
    printf(HDR5, "bucket", "count", "total_s", "total_h", "avg_s")
    printf(ROW5, "all",      p_all_c,  p_all_s,  p_all_s / 3600.0,  avg(p_all_s, p_all_c))
    printf(ROW5, "over_60s", p_over_c, p_over_s, p_over_s / 3600.0, avg(p_over_s, p_over_c))
    printf(ROW5, "upto_60s", p_up_c,   p_up_s,   p_up_s / 3600.0,   avg(p_up_s, p_up_c))
    printf("\n")

    printf("[2] live kv cache miss  (match: \"live kv cache miss\")\n")
    printf("  %-14s%8d\n", "total", m_total)
    printf(HDR3, "by_reason", "count", "share")
    isort(mkeys, mnk)
    for (i = 1; i <= mnk; i++) {
        r = mkeys[i]
        printf(ROW3, sanitize(r), mcnt[r], share(mcnt[r], m_total))
    }
    printf(HDR3, "by_common", "count", "share")
    printf(ROW3, "lt_1000",     b_lt  + 0, share(b_lt  + 0, m_total))
    printf(ROW3, "1000_9999",   b_1k  + 0, share(b_1k  + 0, m_total))
    printf(ROW3, "10000_49999", b_10k + 0, share(b_10k + 0, m_total))
    printf(ROW3, "ge_50000",    b_50k + 0, share(b_50k + 0, m_total))
    printf("\n")

    printf("[3] kv cache stored  (match: \"kv cache stored \", excludes \"kv cache evicted\")\n")
    printf(HDR5, "reason", "count", "MiB", "GiB", "avg_MiB")
    isort(skeys, snk)
    for (i = 1; i <= snk; i++) {
        r = skeys[i]
        printf(ROW5, sanitize(r), scnt[r], smib[r] + 0, (smib[r] + 0) / 1024.0, avg(smib[r] + 0, scnt[r]))
    }
    # Always printed, even with no rows above it, so it never shifts the diff.
    printf(ROW5, "TOTAL", s_total_c + 0, s_total_m + 0, (s_total_m + 0) / 1024.0, avg(s_total_m + 0, s_total_c + 0))
    printf("\n")

    # Same reason: "none" when clean, so a warning never shifts the line count.
    if (unk > 0) {
        isort(ukeys, unk)
        w = ""
        for (i = 1; i <= unk; i++) {
            w = w (i > 1 ? "; " : "") sprintf("%d line(s) with unexpected size unit: %s", ucnt[ukeys[i]], sanitize(ukeys[i]))
        }
        printf("warnings: %s\n", w)
    } else {
        printf("warnings: none\n")
    }
}
' < "$LOG_FILE"
# Redirection, not a trailing operand: POSIX awk reads an operand containing
# "=" as a variable assignment, so such a filename would be silently swallowed.
