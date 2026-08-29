#!/usr/bin/env bash
# Tests: tests/feature-86-win-llama-swap-server/test-install-win-server.sh, tests/feature-86-win-llama-swap-server/lib/assert-pester-profile.sh
# Tags: installer, windows, pester, driver, skip-profile, meta-test, layer:TL2, scope:common
# scope:common despite the feature-86- dir: "a skip is only acceptable while the subject is absent" is a permanent property of the driver, not #86 arithmetic.
# The driver decides between two states, and this file proves both. Subject absent -> the whole run is a clean skip (77). Subject present -> a skipped Pester case is a failure, because Invoke-Pester reports "0 failed" for a suite that ran nothing.
# Runs the driver only against throwaway fixtures, never against the real checkout, and never reaches pwsh: every case here stops at the driver's own file gate.
# TL3 gap (what this test does NOT catch):
# - whether Pester's SkippedCount means what this rule assumes on the operator's Pester build
# - whether the driver's pwsh invocation actually emits the CCLL_PROFILE line (only a real pwsh run shows that; the sibling driver run under RUN_TL3 does)
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh categories: installer, pwsh-required
set -u

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DRIVER="$HERE/test-install-win-server.sh"
PROFILE="$HERE/lib/assert-pester-profile.sh"

[ -f "$DRIVER" ]  || { echo "FAIL: $DRIVER not found" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "FAIL: $PROFILE not found" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. the rule, both directions -----------------------------------------
# expect_profile <want-rc> <label> <args...>
expect_profile() {
    _want="$1"; _label="$2"; shift 2
    bash "$PROFILE" "$@" > "$WORK/p.out" 2>&1
    _rc=$?
    if [ "$_rc" -ne "$_want" ]; then
        cat "$WORK/p.out" >&2
        fail "$_label: assert-pester-profile exited $_rc, expected $_want"
    fi
}

# 1a. the healthy profile passes (classifier guard: a rule wired to always fail
#     would satisfy 1b-1d and be worthless).
expect_profile 0 "healthy run" --total 40 --failed 0 --skipped 0

# 1b. the whole point of C9: green-with-skips is not green.
expect_profile 1 "one skipped case" --total 40 --failed 0 --skipped 1
expect_profile 1 "every case skipped" --total 40 --failed 0 --skipped 40

# 1c. an actual failure still fails (the skip rule did not replace it).
expect_profile 1 "failed case" --total 40 --failed 1 --skipped 0

# 1d. a run that discovered nothing is the other silent green.
expect_profile 1 "no cases discovered" --total 0 --failed 0 --skipped 0

# 1e. malformed input is a usage error (2), never a silent pass. Without this a
#     driver that lost its counts would call the helper with empty strings and
#     an integer comparison would abort mid-script with a nonzero-but-untyped rc.
expect_profile 2 "missing --total" --failed 0 --skipped 0
expect_profile 2 "non-numeric --skipped" --total 4 --failed 0 --skipped "many"
expect_profile 2 "unknown flag" --total 4 --failed 0 --skipped 0 --bogus

# 1f. the skip message must name the reason, or the operator cannot act on it.
bash "$PROFILE" --total 9 --failed 0 --skipped 9 --context "probe suite" > "$WORK/msg" 2>&1
grep -Fq -- 'probe suite' "$WORK/msg"
rc=$?
[ "$rc" -le 1 ] || fail "grep exited $rc reading the skip message"
[ "$rc" -eq 0 ] || fail "the skip failure never names its --context, so the operator cannot tell which suite skipped"

# --- 2. the driver uses the rule (it is not dead code) ---------------------
grep -Fq -- 'assert-pester-profile.sh' "$DRIVER"
rc=$?
[ "$rc" -le 1 ] || fail "grep exited $rc reading $DRIVER"
[ "$rc" -eq 0 ] || fail "test-install-win-server.sh no longer references lib/assert-pester-profile.sh - the skip profile is enforced nowhere"

grep -Fq -- 'SkippedCount' "$DRIVER"
rc=$?
[ "$rc" -le 1 ] || fail "grep exited $rc reading $DRIVER"
[ "$rc" -eq 0 ] || fail "test-install-win-server.sh no longer reads SkippedCount out of Invoke-Pester, so the rule is fed nothing"

# --- 3. subject absent -> a clean skip, not a pass -------------------------
EMPTY="$WORK/empty-repo"
mkdir -p "$EMPTY"
REPO="$EMPTY" bash "$DRIVER" > "$WORK/d.out" 2>&1
rc=$?
[ "$rc" -eq 77 ] || { cat "$WORK/d.out" >&2; fail "against a checkout with no installer the driver exited $rc, expected 77 (skip)"; }
grep -Fq -- 'implementation pending' "$WORK/d.out"
g=$?
[ "$g" -le 1 ] || fail "grep exited $g reading the driver output"
[ "$g" -eq 0 ] || fail "the driver skipped without saying the implementation is pending - a silent 77 is indistinguishable from a broken gate"

# --- 4. the gate covers every file the suites read (CPR-ORTH) --------------
# One file missing at a time. Without this, dropping a path from the gate would
# let the suites run against a half-present checkout and report Skipped cases,
# which case 1b then blames on a broken -Skip: condition instead.
GATED="install/win/lib/roles.ps1 install/win/lib/nssm-args.ps1 install/win/lib/native.ps1 install/win/llama-swap-service.ps1 install/win/certs.ps1 install/win/mkcert.ps1 install.ps1"

CHECKED=0
for missing in $GATED; do
    STUB="$WORK/stub"
    rm -rf "$STUB"
    mkdir -p "$STUB/install/win/lib"
    for f in $GATED; do
        [ "$f" = "$missing" ] && continue
        mkdir -p "$STUB/$(dirname -- "$f")"
        printf '# stub\n' > "$STUB/$f"
    done
    REPO="$STUB" bash "$DRIVER" > "$WORK/d.out" 2>&1
    rc=$?
    [ "$rc" -eq 77 ] || { cat "$WORK/d.out" >&2; fail "with only $missing missing the driver exited $rc, expected 77 - that path is not in the driver's gate"; }
    grep -Fq -- "$missing" "$WORK/d.out"
    g=$?
    [ "$g" -le 1 ] || fail "grep exited $g reading the driver output"
    [ "$g" -eq 0 ] || fail "the driver skipped for a missing $missing without naming it"
    CHECKED=$((CHECKED + 1))
done
[ "$CHECKED" -eq 7 ] || fail "expected to probe 7 gated paths, probed $CHECKED"

# --- 5. the driver refuses to run with no suite beside it ------------------
# A rename that orphans the *.Tests.ps1 files must fail loudly; "found nothing to
# run" is the third silent-green shape, next to "ran nothing" and "skipped all".
SOLO="$WORK/solo"
mkdir -p "$SOLO/lib"
cp "$DRIVER" "$SOLO/"
cp "$PROFILE" "$SOLO/lib/"
mkdir -p "$WORK/full/install/win/lib"
for f in $GATED; do
    mkdir -p "$WORK/full/$(dirname -- "$f")"
    printf '# stub\n' > "$WORK/full/$f"
done
REPO="$WORK/full" bash "$SOLO/$(basename -- "$DRIVER")" > "$WORK/d.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$WORK/d.out" >&2; fail "with no *.Tests.ps1 beside it the driver exited $rc, expected 1 (hard failure, not a skip and not a pass)"; }

echo "PASS: test-install-driver-skip-profile (8 rule probes, 7 gated paths, 2 driver states)"
