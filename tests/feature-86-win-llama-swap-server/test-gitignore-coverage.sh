#!/usr/bin/env bash
# Tests: .gitignore
# Tags: gitignore, git-check-ignore, migration-safety, layer:TL1, scope:common
# scope:common despite the feature-86- dir: these ignore rules protect every future commit, not just the #86 migration, so this is permanent coverage.
# Pins the three holes Commit 1 closes (*.exe / config.yaml.bak* / certs/), the symmetric guard that repo-tracked config is still NOT ignored, and -- because .gitignore is only advice -- what the index actually tracks. Rationale: detail plan 1-1 and 6-2.
# Skips (exit 77) until llama-swap/rtx5070ti-128gb/config.yaml exists: the ignore rules and the config transfer ship in the same PR (commits 1-2), so the transferred config is the marker that the receiving-side work landed.
# TL3 gap (what this test does NOT catch):
# - a secret already pushed to a remote, or one living in a commit that is no longer at HEAD (the index is a snapshot, not the history)
# - whether the real migration copy step ever put certs/ or a .bak inside the worktree at all
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"

[ -f "$REPO/llama-swap/rtx5070ti-128gb/config.yaml" ] || { echo "SKIP: $REPO/llama-swap/rtx5070ti-128gb/config.yaml not found (implementation pending)"; exit 77; }
[ -f "$REPO/.gitignore" ] || { echo "FAIL: $REPO/.gitignore not found" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# --no-index on every call: without it `git check-ignore` reports a TRACKED path
# as not-ignored regardless of the patterns, which would make case 4 (the
# symmetric guard) pass vacuously and stop testing anything.
ignored() { git -C "$REPO" check-ignore -q --no-index -- "$1"; }

# --- 1. the llama-swap runtime binary never enters the repo ----------------
# 23,930,368 bytes on the real host; the repo holds ops/config/decisions only.
ignored "llama-swap.exe" || fail "'llama-swap.exe' is NOT ignored -- .gitignore lacks an *.exe rule"
ignored "install/win/some-tool.exe" || fail "'install/win/some-tool.exe' is NOT ignored -- the *.exe rule is anchored to the repo root instead of matching at any depth"

# --- 2. the suffix-match trap (the bug this case exists for) ---------------
# The pre-existing `*.bak` is a SUFFIX match, so it does not match a name whose
# timestamp comes after `.bak`. The migration source carries 8 such files.
ignored "config.yaml.bak.20260715_022745" || fail "'config.yaml.bak.20260715_022745' is NOT ignored -- a bare '*.bak' rule does not match a timestamped backup; a 'config.yaml.bak*' prefix glob is required"
ignored "config.yaml.bak" || fail "'config.yaml.bak' is NOT ignored -- the plain suffix form regressed"

# --- 3. private keys and certs never enter the repo (security) -------------
ignored "certs/cert.pem" || fail "'certs/cert.pem' is NOT ignored -- .gitignore lacks a certs/ rule"
ignored "certs/key.pem" || fail "'certs/key.pem' is NOT ignored -- the private key half of the pair is unprotected"

# --- 4. CPR-ORTH symmetric guard: the tracked config is NOT ignored --------
# Cases 1-3 all pass under a catch-all like '*'. This is the counterpart verdict
# that makes them meaningful: an over-broad rule must fail here.
for keep in \
    "llama-swap/rtx5070ti-128gb/config.yaml" \
    "llama-swap/rtx5070ti-128gb/model-annotations.yaml" \
    "llama-swap/m5-max-128gb/config.yaml" \
    "install.ps1" \
    "docs/infrastructure.md"
do
    if ignored "$keep"; then
        fail "'$keep' IS ignored -- an over-broad .gitignore rule now hides a tracked source file"
    fi
done

# --- 5. and nothing sensitive is actually tracked --------------------------
# .gitignore is advice; `git add -f` overrides it, and a file added before the
# rule existed stays tracked forever afterwards. Cases 1-3 cannot see either.
# This asks the index itself, which is the only authority on what ships.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -C "$REPO" ls-files > "$WORK/tracked" 2>"$WORK/err" || { cat "$WORK/err" >&2; fail "git ls-files failed in $REPO"; }
[ -s "$WORK/tracked" ] || fail "git ls-files listed nothing in $REPO -- not a checkout, so case 5 would pass vacuously"

grep -Fq -- 'install.ps1' "$WORK/tracked"
rc=$?
[ "$rc" -le 1 ] || fail "grep exited $rc reading the tracked-file list"
[ "$rc" -eq 0 ] || fail "install.ps1 is not tracked -- the file list is not the one this test means to scan"

# One pattern per class of thing that must never reach a remote: build output,
# any key or certificate material, the timestamped config backups, and model
# weights. Matched against paths, so a nested certs/ directory is caught too.
FORBIDDEN='\.exe$|\.gguf$|(^|/)certs/|\.bak|\.pem$|\.key$|\.pfx$|\.p12$'

scan_tracked() {
    grep -nE -- "$FORBIDDEN" "$1" > "$WORK/hits"
    _rc=$?
    [ "$_rc" -le 1 ] || fail "grep exited $_rc scanning $1 -- cannot conclude nothing sensitive is tracked"
    return "$_rc"
}

if scan_tracked "$WORK/tracked"; then
    fail "sensitive path(s) are tracked despite .gitignore (force-added, or added before the rule): $(tr '\n' ' ' < "$WORK/hits")"
fi

# 5b. the scan must be able to fire, or its silence means nothing.
printf 'install.ps1\ncerts/key.pem\nllama-swap/rtx5070ti-128gb/config.yaml.bak.20260715_022745\nC:/tools/llama-swap.exe\n' > "$WORK/probe"
scan_tracked "$WORK/probe" || fail "the tracked-file scan missed an obvious key/backup/binary path -- case 5 cannot detect a regression"
PROBE_HITS="$(wc -l < "$WORK/hits" | tr -d ' ')"
[ "$PROBE_HITS" -eq 3 ] || fail "the tracked-file scan matched $PROBE_HITS of 3 planted offenders (and must not match install.ps1)"

echo "PASS: test-gitignore-coverage ($(wc -l < "$WORK/tracked" | tr -d ' ') tracked paths scanned)"
