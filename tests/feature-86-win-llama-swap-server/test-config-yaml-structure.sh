#!/usr/bin/env bash
# Tests: llama-swap/rtx5070ti-128gb/config.yaml, llama-swap/rtx5070ti-128gb/model-annotations.yaml, llama-swap/m5-max-128gb/config.yaml, llama-swap/m5-max-128gb/model-annotations.yaml
# Tags: llama-swap, yaml, parser, config, model-annotations, layer:TL2, scope:issue-specific
# scope:issue-specific: the exact 11/3/14/3 counts and the three deleted-orphan names are the #86 migration's own arithmetic; the standing rule itself is covered by test-config-annotations-parity.sh.
# Answers the questions grep cannot: a real parse of both files (duplicate keys and ragged indentation rejected), exact model/group/annotation/retained counts, key-by-key correspondence both ways, group membership resolution, and a load smoke check that every model carries the cmd:/proxy: llama-swap needs. Rationale: detail plan 2-1 / 2-2 / 6-1.
# Parser is vendored at lib/yamlmin.py -- this host has neither PyYAML nor yq (probed); with no python3 at all the file skips with that reason rather than degrading to substring checks.
# Skips (exit 77) until llama-swap/rtx5070ti-128gb/config.yaml exists (implementation pending).
# TL3 gap (what this test does NOT catch):
# - whether llama-swap itself accepts the file (its own schema is stricter than "has cmd and proxy")
# - whether the .gguf / llama-server.exe paths the cmd: strings name exist on the host (TL3-installer-llama-cpp-build.sh under RUN_TL3)
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CHECK="$HERE/lib/check-config-pair.py"
SWAP_DIR="$REPO/llama-swap"
WIN_DIR="$SWAP_DIR/rtx5070ti-128gb"

[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }
[ -f "$WIN_DIR/config.yaml" ] || { echo "SKIP: $WIN_DIR/config.yaml not found (implementation pending)"; exit 77; }

PY=""
for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || { echo "SKIP: no python3/python on PATH - lib/yamlmin.py needs one (PyYAML and yq are both absent on this host, so there is no fallback parser)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_check <expect-rc> <label> <args...>
run_check() {
    _want="$1"; _label="$2"; shift 2
    "$PY" "$CHECK" "$@" > "$WORK/out" 2>&1
    _rc=$?
    if [ "$_rc" -ne "$_want" ]; then
        echo "--- checker output ---" >&2
        cat "$WORK/out" >&2
        fail "$_label: checker exited $_rc, expected $_want"
    fi
}

# --- 1. the Windows pair, by exact count and by name -----------------------
# 11 models / 3 groups / 14 annotations / 3 retained orphans is the arithmetic
# the migration decided (detail plan 2-2 and its accepted tradeoff). A silent
# drift in any of the four is the regression this case exists for.
run_check 0 "rtx5070ti-128gb structure" \
    --config "$WIN_DIR/config.yaml" \
    --annotations "$WIN_DIR/model-annotations.yaml" \
    --expect-models 11 --expect-groups 3 \
    --expect-annotations 14 --expect-retained 3 \
    --absent gemma-3-4b-it-Q4_K_M \
    --absent Mistral-22B-v0.2-Q4_K_S \
    --absent Qwen3-8B-Q4_K_M \
    --require-text '<private-agent-project>'
echo "  ok: $(cat "$WORK/out")"

# --- 2. every populated host directory parses and correspends (CPR-E2C) ----
SCANNED=0
for d in "$SWAP_DIR"/*/; do
    [ -f "$d/config.yaml" ] || continue
    [ -f "$d/model-annotations.yaml" ] || fail "$(basename "$d") has config.yaml but no model-annotations.yaml"
    run_check 0 "$(basename "$d") structure" \
        --config "$d/config.yaml" --annotations "$d/model-annotations.yaml"
    SCANNED=$((SCANNED + 1))
done
[ "$SCANNED" -ge 2 ] || fail "expected at least 2 populated host directories under $SWAP_DIR, scanned $SCANNED"

# --- 3. mutation probes: each arm of the checker must be able to fail ------
# Without these, a checker that returned 0 unconditionally would satisfy 1-2.
MUT="$WORK/mut"
mkdir -p "$MUT"

good_config() {
    printf 'healthCheckTimeout: 600\nmodels:\n  alpha:\n    cmd: >-\n      a.exe --model a.gguf\n    proxy: http://127.0.0.1:1\n  beta:\n    cmd: b.exe\n    proxy: http://127.0.0.1:2\ngroups:\n  heavy:\n    swap: true\n    members:\n      - beta\n' > "$1"
}
good_ann() {
    printf 'alpha:\n  role: probe\nbeta:\n  role: probe\ngamma:\n  role: probe\n  retained: "still consulted"\n' > "$1"
}

good_config "$MUT/config.yaml"
good_ann "$MUT/ann.yaml"
BASE="--config $MUT/config.yaml --annotations $MUT/ann.yaml"

# 3a. baseline passes with its true counts (classifier guard: a checker wired
#     to always fail would satisfy 3b-3i and still be worthless).
# shellcheck disable=SC2086
run_check 0 "probe baseline" $BASE --expect-models 2 --expect-groups 1 --expect-annotations 3 --expect-retained 1

# 3b. wrong expected model count
# shellcheck disable=SC2086
run_check 1 "probe model count" $BASE --expect-models 3

# 3c. wrong expected group count
# shellcheck disable=SC2086
run_check 1 "probe group count" $BASE --expect-groups 2

# 3d. wrong expected annotation count
# shellcheck disable=SC2086
run_check 1 "probe annotation count" $BASE --expect-annotations 4

# 3e. wrong expected retained count
# shellcheck disable=SC2086
run_check 1 "probe retained count" $BASE --expect-retained 2

# 3f. a model with no annotation
good_ann "$MUT/ann.yaml"
"$PY" - "$MUT/ann.yaml" <<'PYEOF' || fail "probe setup 3f failed"
import sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read().replace('beta:\n  role: probe\n', '')
open(p, 'w', encoding='utf-8').write(t)
PYEOF
# shellcheck disable=SC2086
run_check 1 "probe missing annotation" $BASE

# 3g. an orphan annotation with no retained: reason
printf 'alpha:\n  role: probe\nbeta:\n  role: probe\ngamma:\n  role: probe\n' > "$MUT/ann.yaml"
# shellcheck disable=SC2086
run_check 1 "probe orphan without retained" $BASE

# 3h. an annotation entry with no role:
printf 'alpha:\n  role: probe\nbeta:\n  notes: "no role"\n' > "$MUT/ann.yaml"
# shellcheck disable=SC2086
run_check 1 "probe annotation without role" $BASE

# 3i. a group member that names no model (load smoke)
good_ann "$MUT/ann.yaml"
good_config "$MUT/config.yaml"
printf 'healthCheckTimeout: 600\nmodels:\n  alpha:\n    cmd: a.exe\n    proxy: http://127.0.0.1:1\n  beta:\n    cmd: b.exe\n    proxy: http://127.0.0.1:2\ngroups:\n  heavy:\n    members:\n      - delta\n' > "$MUT/config.yaml"
# shellcheck disable=SC2086
run_check 1 "probe dangling group member" $BASE

# 3j. a model with no proxy: (load smoke)
printf 'models:\n  alpha:\n    cmd: a.exe\n  beta:\n    cmd: b.exe\n    proxy: http://127.0.0.1:2\n' > "$MUT/config.yaml"
# shellcheck disable=SC2086
run_check 1 "probe model without proxy" $BASE

# 3k. duplicate key -> parse error (rc 2), never a silent last-wins read
printf 'models:\n  alpha:\n    cmd: a.exe\n    proxy: p\n  alpha:\n    cmd: b.exe\n    proxy: p\n' > "$MUT/config.yaml"
# shellcheck disable=SC2086
run_check 2 "probe duplicate key" $BASE

# 3l. ragged indentation -> parse error, not a partial read
printf 'models:\n  alpha:\n    cmd: a.exe\n    proxy: p\n   beta:\n    cmd: b.exe\n' > "$MUT/config.yaml"
# shellcheck disable=SC2086
run_check 2 "probe ragged indent" $BASE

# 3m. --absent must fire when the key is still there
good_config "$MUT/config.yaml"
# shellcheck disable=SC2086
run_check 1 "probe absent key still present" $BASE --absent gamma

# 3n. --require-text must fire when the text is missing
# shellcheck disable=SC2086
run_check 1 "probe required text missing" $BASE --require-text '<private-agent-project>'

echo "PASS: test-config-yaml-structure ($SCANNED host directories parsed, 14 checker probes)"
