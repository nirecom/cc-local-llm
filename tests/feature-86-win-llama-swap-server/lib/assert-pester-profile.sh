#!/usr/bin/env bash
# Tests: install.ps1, install/win/lib/roles.ps1, install/win/lib/nssm-args.ps1, install/win/lib/native.ps1, install/win/llama-swap-service.ps1, install/win/certs.ps1
# Tags: installer, windows, pester, verdict, shared, layer:TL2, scope:common
# Not a test: the shared verdict rule for a Pester run whose files under test all
# exist. Kept out of the driver so test-install-driver-skip-profile.sh can
# exercise the rule directly, and so the two cannot drift apart.

# Rule: once the implementation is present, a SKIPPED case is a failure. Pester
# reports "0 failed" for a suite whose every case was skipped, so a bad -Skip:
# condition turns the whole suite green while testing nothing.

# Usage: assert-pester-profile.sh --total N --failed N --skipped N [--context TEXT]
# Exit 0 = acceptable profile; 1 = not, with the reason on stderr; 2 = bad usage.
set -u

TOTAL=""; FAILED=""; SKIPPED=""; CONTEXT="pester run"

while [ $# -gt 0 ]; do
    case "$1" in
        --total)   TOTAL="${2:-}";   shift 2 ;;
        --failed)  FAILED="${2:-}";  shift 2 ;;
        --skipped) SKIPPED="${2:-}"; shift 2 ;;
        --context) CONTEXT="${2:-}"; shift 2 ;;
        *) echo "assert-pester-profile: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

for pair in "total:$TOTAL" "failed:$FAILED" "skipped:$SKIPPED"; do
    name="${pair%%:*}"; value="${pair#*:}"
    case "$value" in
        '') echo "assert-pester-profile: --$name is required" >&2; exit 2 ;;
        *[!0-9]*) echo "assert-pester-profile: --$name must be a non-negative integer, got '$value'" >&2; exit 2 ;;
    esac
done

if [ "$TOTAL" -eq 0 ]; then
    echo "FAIL: $CONTEXT ran no cases at all - the suite files were not discovered, so 'no failures' means nothing" >&2
    exit 1
fi

if [ "$FAILED" -gt 0 ]; then
    echo "FAIL: $CONTEXT reported $FAILED failed case(s) of $TOTAL" >&2
    exit 1
fi

if [ "$SKIPPED" -gt 0 ]; then
    echo "FAIL: $CONTEXT skipped $SKIPPED case(s) of $TOTAL, but the driver only reaches this point once every file under test exists." >&2
    echo "      A skip here is a broken -Skip: condition, not a legitimate gap. Re-run with -Output Detailed to see which cases report Skipped." >&2
    exit 1
fi

exit 0
