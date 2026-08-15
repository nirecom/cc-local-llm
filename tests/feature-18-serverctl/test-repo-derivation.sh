#!/usr/bin/env bash
# Tests: scripts/lib/root.sh
# Tags: lifecycle, serverctl, scope:issue-specific
#
# Scenario: the REPO derivation shared by every tests/feature-18-serverctl/*.sh —
# auto-discovery when REPO is unset (from an unrelated CWD), env override
# precedence, and the documented symlink limitation.
#
# Why this exists: the other 13 files never pin REPO explicitly, so an ambient
# REPO in the environment could silently redirect (or skip) all of them without
# any test noticing. This file pins both branches of `${REPO:-<derivation>}`.
# The derivation mirrors the design of scripts/lib/root.sh (CDPATH= cd + pwd),
# so a change to that SSOT should be reflected here.
#
# TDD note: scripts/lib/root.sh does not exist yet at write-tests time (it is
# created by the write-code step of this session). This file therefore checks
# the derivation snippet embedded in each tests/feature-18-serverctl/*.sh file,
# not root.sh directly — intentional, TDD-red-before-green ordering, not a gap.
#
# L3 gap: real launchctl load/unload persistence across reboots; actual
#   caffeinate process supervision on macOS; real DS4_API_KEY auth check.
set -u

# REPO is derived from $0's logical location (no symlink target resolution — see the symlink case below); export REPO=<path> to point the suite at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SAMPLE="$SELF_DIR/test-dispatch.sh"
[ -f "$SAMPLE" ] || fail "sample test $SAMPLE not found"

# The derivation is read out of a real test file rather than re-typed here, so
# this test cannot drift away from what the suite actually runs.
DERIV="$(grep -m1 '^REPO=' "$SAMPLE")"
[ -n "$DERIV" ] || fail "no REPO= line found in $SAMPLE"

# --- 0. Every file in the suite uses the identical derivation (CPR-5) --------
for f in "$SELF_DIR"/test-*.sh; do
    line="$(grep -m1 '^REPO=' "$f")"
    [ -n "$line" ] || fail "$(basename "$f"): no REPO= assignment"
    [ "$line" = "$DERIV" ] || fail "$(basename "$f"): REPO derivation differs from $(basename "$SAMPLE")
  expected: $DERIV
  actual:   $line"
done

# --- 0b. Every file that runs repo code pins DOTENV_FILE (hermetic isolation) -
# scripts/lib/root.sh defaults DOTENV_FILE to <repo-root>/.env — a REAL file that
# may hold the developer's actual secrets. Any test that executes repo code
# ($REPO/scripts/... or $REPO/proxy/...) therefore has to pin DOTENV_FILE into
# its own tmpdir, or the run silently reads the developer's real dotenv.
# Excluded: files with no $REPO/{scripts,proxy} reference never reach root.sh's
# DOTENV_FILE resolution at runtime (this file is the only such case today — it
# reads the other tests as text and never executes any of them).
PIN="$(grep -m1 '^export DOTENV_FILE=' "$SAMPLE")"
[ -n "$PIN" ] || fail "no 'export DOTENV_FILE=' line found in $(basename "$SAMPLE")"

pinned=0
for f in "$SELF_DIR"/test-*.sh; do
    # Comments are stripped first: prose mentioning $REPO/scripts (as in the
    # block above) must not count as running repo code.
    grep -v '^[[:space:]]*#' "$f" | grep -q '\$REPO/\(scripts\|proxy\)' || continue
    line="$(grep -m1 '^export DOTENV_FILE=' "$f")"
    [ -n "$line" ] || fail "$(basename "$f"): runs repo code but has no 'export DOTENV_FILE=' pin — it would read the developer's real dotenv (see scripts/lib/root.sh)"
    [ "$line" = "$PIN" ] || fail "$(basename "$f"): DOTENV_FILE pin differs from $(basename "$SAMPLE")
  expected: $PIN
  actual:   $line"
    pinned=$((pinned + 1))
done
# Guard the guard: if the detection pattern ever stops matching, the loop above
# would pass vacuously instead of catching an unpinned fixture.
[ "$pinned" -ge 2 ] || fail "DOTENV_FILE pin check matched only $pinned file(s) — the '\$REPO/{scripts,proxy}' detection pattern has drifted and this assertion is now vacuous"

# Evaluate the extracted derivation with $0 set to <path>, then print REPO.
derive() { # derive <argv0-path>
    bash -c "$DERIV"$'\n''printf %s "$REPO"' "$1"
}

EXPECT="$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)"

# --- 1. Auto-discovery: REPO unset, invoked from an unrelated CWD ------------
mkdir -p "$WORK/elsewhere"
GOT="$(cd "$WORK/elsewhere" && unset REPO && derive "$SAMPLE")"
[ "$GOT" = "$EXPECT" ] || fail "auto-discovery from an unrelated CWD resolved REPO to '$GOT', expected '$EXPECT' (derivation is CWD-dependent — tests would run against the wrong tree)"

# Relative argv[0] must resolve the same way (invocation as ./test-foo.sh).
GOT="$(cd "$SELF_DIR" && unset REPO && derive "./$(basename "$SAMPLE")")"
[ "$GOT" = "$EXPECT" ] || fail "relative argv[0] resolved REPO to '$GOT', expected '$EXPECT'"

# --- 2. Explicit env override wins over auto-discovery -----------------------
mkdir -p "$WORK/override"
OVERRIDE="$(CDPATH= cd -- "$WORK/override" && pwd)"
GOT="$(cd "$WORK/elsewhere" && REPO="$OVERRIDE" derive "$SAMPLE")"
[ "$GOT" = "$OVERRIDE" ] || fail "explicit REPO='$OVERRIDE' was not honored (got '$GOT') — the \${REPO:-...} override path is broken"

# An empty REPO must fall back to auto-discovery, not to an empty path.
GOT="$(cd "$WORK/elsewhere" && REPO="" derive "$SAMPLE")"
[ "$GOT" = "$EXPECT" ] || fail "empty REPO did not fall back to auto-discovery (got '$GOT')"

# --- 3. Symlink invocation: documented limitation, not a guarantee -----------
# `CDPATH= cd -- <dir> && pwd` returns the LOGICAL path of $0's directory; it
# does not resolve a symlinked $0 back to its target. Invoking a test through a
# symlink therefore derives REPO from the symlink's own location. This is the
# same limitation scripts/lib/root.sh carries, and it is acceptable because the
# override in section 2 is the supported escape hatch. Pinned here so a future
# change to the derivation (e.g. adding readlink -f) is a conscious decision.
mkdir -p "$WORK/sym/a/b"
LINK="$WORK/sym/a/b/link.sh"
if ln -s "$SAMPLE" "$LINK" 2>/dev/null && [ -e "$LINK" ]; then
    SYM_EXPECT="$(CDPATH= cd -- "$WORK/sym" && pwd)"
    GOT="$(cd "$WORK/elsewhere" && unset REPO && derive "$LINK")"
    [ -L "$LINK" ] || echo "NOTE: ln -s produced a copy, not a real symlink (Git Bash without winsymlinks) — the assertion below still holds because the derivation is purely path-based"
    [ "$GOT" = "$SYM_EXPECT" ] || fail "symlink invocation resolved REPO to '$GOT', expected the symlink-relative '$SYM_EXPECT' — the derivation's documented behavior changed"
    [ "$GOT" != "$EXPECT" ] || fail "symlink invocation unexpectedly resolved to the real repo root — the derivation now follows symlink targets; update this documented limitation"
else
    echo "NOTE: symlink creation unsupported here — symlink-invocation case not exercised"
fi

echo "PASS: test-repo-derivation"
