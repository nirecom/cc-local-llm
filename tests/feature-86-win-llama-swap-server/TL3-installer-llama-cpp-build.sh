#!/usr/bin/env bash
# Tests: llama-swap/rtx5070ti-128gb/config.yaml
# Tags: llama-cpp, cuda, windows, host-state, run-tl3, layer:TL3, scope:common
# scope:common and deliberately WITHOUT an issue number in the filename: retirement policies key on feature-<N> names and would delete this permanent host-state coverage when #86 closes.
# Successor to the migration-source tests/main-llama-cpp-build.sh: only its two surviving phases are kept -- the CUDA build artifacts, plus a new check that every path the migrated config.yaml references really exists on this host. The other four phases asserted on a one-way migration that already completed (detail plan 6-6).
# Gated: exit 77 unless RUN_TL3=on, the host is Windows, and the config exists.
# What only this tier can see (the reason the TL2 siblings are not enough):
# - test-config-annotations-parity.sh proves the config is well-formed, never that the .gguf files it names are on disk
# - a repo-correct config with a stale model path fails at first load on the real host and nowhere else
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
CONFIG="$REPO/llama-swap/rtx5070ti-128gb/config.yaml"

[ "${RUN_TL3:-off}" = "on" ] || { echo "SKIP: RUN_TL3 is not 'on' - run with RUN_TL3=on bash $0"; exit 77; }

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
    *) echo "SKIP: not a Windows host - the llama.cpp CUDA build lives only there"; exit 77 ;;
esac

[ -f "$CONFIG" ] || { echo "SKIP: $CONFIG not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Windows literals in the config need a POSIX form before the shell can stat them.
to_posix() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u -- "$1"
    else
        printf '%s\n' "$1" | tr '\\' '/' | sed 's,^\([A-Za-z]\):,/\L\1,'
    fi
}

# Flatten the whole file into whitespace-separated tokens so a `>-` folded `cmd:`
# block cannot hide a flag from its value by wrapping between them.
tr -s '[:space:]' '\n' < "$CONFIG" > "$WORK/tokens"

collect_flag_values() {
    awk -v flag="$1" '$0 == flag { want = 1; next } want { print; want = 0 }' "$WORK/tokens"
}

# --- 0. the parser found something (guards every loop below) ---------------
MODEL_KEYS="$(awk '
    /^models:[[:space:]]*$/ { inm = 1; next }
    inm && /^[^[:space:]#]/ { inm = 0 }
    inm && /^  [A-Za-z0-9._-]+:/ { k = $0; sub(/^  /, "", k); sub(/:.*$/, "", k); print k }
' "$CONFIG")"
MODEL_N="$(printf '%s\n' "$MODEL_KEYS" | grep -c . || true)"
[ "$MODEL_N" -gt 0 ] || fail "parsed 0 model keys out of $CONFIG"

collect_flag_values --model > "$WORK/models"
GGUF_N="$(grep -c . < "$WORK/models" || true)"
[ "$GGUF_N" -eq "$MODEL_N" ] || fail "config declares $MODEL_N models but $GGUF_N '--model' values were parsed -- a model entry has no --model, or the parser missed one"

# --- 1. llama.cpp CUDA build artifacts exist and are runnable --------------
# The bin directory is taken from the config itself, not hardcoded: the config is
# the thing under test, so a moved build must fail here rather than be papered
# over by a constant that happens to still be right.
EXE_WIN="$(grep -oE '[A-Za-z]:\\[^"[:space:]]*llama-server\.exe' "$CONFIG" | head -n 1 || true)"
[ -n "$EXE_WIN" ] || fail "no llama-server.exe path found in $CONFIG"
EXE="$(to_posix "$EXE_WIN")"
BIN_DIR="$(dirname -- "$EXE")"

for artifact in llama-server.exe llama-bench.exe ggml-cuda.dll; do
    [ -f "$BIN_DIR/$artifact" ] || fail "$BIN_DIR/$artifact is missing -- the llama.cpp CUDA build is incomplete"
done

for tool in llama-server.exe llama-bench.exe; do
    if ! "$BIN_DIR/$tool" --help >"$WORK/help.out" 2>&1; then
        fail "$BIN_DIR/$tool --help exited non-zero (missing CUDA runtime DLL?): $(head -n 5 "$WORK/help.out")"
    fi
    [ -s "$WORK/help.out" ] || fail "$BIN_DIR/$tool --help produced no output"
done

# --- 2. every llama-server.exe the config names is the one we just checked --
MISSING=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    q="$(to_posix "$p")"
    if [ ! -f "$q" ]; then
        echo "  missing llama-server.exe referenced by config: $p" >&2
        MISSING=$((MISSING + 1))
    fi
done <<EOF
$(grep -oE '[A-Za-z]:\\[^"[:space:]]*llama-server\.exe' "$CONFIG" | sort -u)
EOF
[ "$MISSING" -eq 0 ] || fail "$MISSING llama-server.exe path(s) in the config do not exist on this host"

# --- 3. every --model .gguf the config names exists -------------------------
MISSING=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *.gguf) ;; *) fail "'--model $p' does not name a .gguf file" ;; esac
    q="$(to_posix "$p")"
    if [ ! -f "$q" ]; then
        echo "  missing model file: $p" >&2
        MISSING=$((MISSING + 1))
    fi
done < "$WORK/models"
[ "$MISSING" -eq 0 ] || fail "$MISSING of $GGUF_N '--model' path(s) do not exist on this host"

# --- 4. every --chat-template-file the config names exists ------------------
collect_flag_values --chat-template-file > "$WORK/templates"
TPL_N="$(grep -c . < "$WORK/templates" || true)"
MISSING=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    q="$(to_posix "$p")"
    if [ ! -f "$q" ]; then
        echo "  missing chat template: $p" >&2
        MISSING=$((MISSING + 1))
    fi
done < "$WORK/templates"
[ "$MISSING" -eq 0 ] || fail "$MISSING of $TPL_N '--chat-template-file' path(s) do not exist on this host"

echo "PASS: TL3-installer-llama-cpp-build ($MODEL_N models, $GGUF_N gguf, $TPL_N chat template(s))"
