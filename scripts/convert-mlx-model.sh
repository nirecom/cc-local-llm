#!/bin/bash
# convert-mlx-model.sh - Convert an HF checkpoint to MLX, into ~/.lmstudio/models/<publisher>/<name>
# so llama-swap can point at it with the same path form every other entry uses.
# Why convert locally instead of pulling a ready-made MLX repo: docs/history.md.
# Usage: scripts/convert-mlx-model.sh --help

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/convert-mlx-model.sh [options]

  --hf-path <repo|dir>   Source checkpoint      (default: Qwen/Qwen3.8-Flash-Next)
  --publisher <name>     ~/.lmstudio/models/<publisher>   (default: nirecom)
  --name <name>          Output dir name       (default: <model>-<bits>bit)
  --q-bits <n>           Bits per weight       (default: 3, or 8 with --recipe)
  --q-group-size <n>     Quantization group    (default: 32, or 64 with --recipe)
  --recipe <name>        Per-module mixed-precision recipe; one of: qwen4-exp-mixed
                         (rationale and per-bucket bits: scripts/lib/convert-mixed-quant.py)
  --no-mtp               Skip MTP drafter extraction
  --dry-run              Print the plan and the convert command, then exit

The source resolves through the ordinary Hugging Face cache, so a checkpoint
already fetched with `hf download` is reused rather than downloaded again.
EOF
}

# Color fallback (standalone-safe pattern, matching install/mac/mlx-vlm.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
        C_GRAY='\033[0;90m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
    else
        C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_BOLD=''; C_RESET=''
    fi
fi

HF_PATH="Qwen/Qwen3.8-Flash-Next"
PUBLISHER="nirecom"
NAME=""
Q_BITS=3
Q_GROUP_SIZE=32
Q_BITS_EXPLICIT=0
Q_GROUP_SIZE_EXPLICIT=0
RECIPE=""
WITH_MTP=1
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --hf-path)       HF_PATH="${2:?--hf-path needs a value}"; shift 2 ;;
        --publisher)     PUBLISHER="${2:?--publisher needs a value}"; shift 2 ;;
        --name)          NAME="${2:?--name needs a value}"; shift 2 ;;
        --q-bits)        Q_BITS="${2:?--q-bits needs a value}"; Q_BITS_EXPLICIT=1; shift 2 ;;
        --q-group-size)  Q_GROUP_SIZE="${2:?--q-group-size needs a value}"; Q_GROUP_SIZE_EXPLICIT=1; shift 2 ;;
        --recipe)        RECIPE="${2:?--recipe needs a value}"; shift 2 ;;
        --no-mtp)        WITH_MTP=0; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            printf "${C_YELLOW}Unknown option: $1${C_RESET}\n" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# A recipe's "everything else" bucket follows docs/history.md's validated
# build (8bit/group-64), not the uniform path's low-bit default -- only when
# the caller did not pass their own --q-bits/--q-group-size.
if [ -n "$RECIPE" ]; then
    [ "$Q_BITS_EXPLICIT" -eq 1 ] || Q_BITS=8
    [ "$Q_GROUP_SIZE_EXPLICIT" -eq 1 ] || Q_GROUP_SIZE=64

    case "$RECIPE" in
        qwen4-exp-mixed) ;;
        *)
            printf "${C_YELLOW}Unknown --recipe '$RECIPE'. Run --help for the available recipes.${C_RESET}\n" >&2
            exit 2
            ;;
    esac
fi

if [ "$(uname -s)" != "Darwin" ]; then
    printf "${C_YELLOW}MLX conversion requires macOS with Metal.${C_RESET}\n" >&2
    exit 1
fi

if ! command -v mlx_vlm.convert &>/dev/null; then
    printf "${C_YELLOW}mlx_vlm.convert not found -- run install/mac/mlx-vlm.sh first.${C_RESET}\n" >&2
    exit 1
fi

# mlx_vlm / huggingface_hub live in mlx-vlm's own venv, not in system python3.
# The entry point's shebang finds it without hardcoding a uv/pipx/venv layout.
PY="$(sed -n '1s|^#!\([^ ]*\)$|\1|p' "$(command -v mlx_vlm.convert)")"
[ -x "${PY:-}" ] || PY="python3"

# --- Preflight: does the installed mlx-vlm know this architecture? -----------
# A checkpoint whose model_type has no module under mlx_vlm/models/ fails deep
# inside convert, after the weights are already loaded. Reading config.json costs
# a few KB and turns that into an actionable message.
MODEL_TYPE="$("$PY" - "$HF_PATH" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path

src = sys.argv[1]
local = Path(src) / "config.json"
if local.is_file():
    text = local.read_text()
else:
    from huggingface_hub import hf_hub_download
    text = Path(hf_hub_download(src, "config.json")).read_text()
print(json.loads(text).get("model_type") or "")
PY
)"

if [ -z "$MODEL_TYPE" ]; then
    printf "${C_YELLOW}Could not read config.json for '$HF_PATH' -- check the path, and that the checkpoint is downloaded.${C_RESET}\n" >&2
    exit 1
fi

MLX_VLM_MODELS="$("$PY" -c 'import mlx_vlm.models, pathlib; print(pathlib.Path(mlx_vlm.models.__file__).parent)' 2>/dev/null || true)"
if [ -n "$MLX_VLM_MODELS" ] && [ ! -d "$MLX_VLM_MODELS/$MODEL_TYPE" ]; then
    printf "${C_YELLOW}The installed mlx-vlm has no backend for model_type '$MODEL_TYPE'.${C_RESET}\n" >&2
    printf "${C_YELLOW}Re-run install/mac/mlx-vlm.sh to pull git main, then try again.${C_RESET}\n" >&2
    exit 1
fi

# The group size must divide every quantized tensor's input dimension, or the
# tensor is silently left in BF16 and the output balloons past its planned size.
# qwen4_exp's hashed n-gram PLE tables are 160 wide: 160 % 32 == 0, 160 % 64 != 0.
# Only applies to the uniform path -- a recipe pins the PLE table's own group
# size (see scripts/lib/convert-mixed-quant.py) regardless of --q-group-size.
if [ -z "$RECIPE" ] && [ "$MODEL_TYPE" = "qwen4_exp" ] && [ "$Q_GROUP_SIZE" -gt 32 ]; then
    printf "${C_YELLOW}qwen4_exp needs --q-group-size 32 or smaller (its n-gram PLE tables are 160 wide), or --recipe qwen4-exp-mixed.${C_RESET}\n" >&2
    exit 1
fi

# --- Output paths -----------------------------------------------------------
MODEL_BASENAME="$(basename "$HF_PATH")"
if [ -n "$RECIPE" ]; then
    # Naming convention validated against pipenetwork/mlx-community's own mixed
    # builds (docs/history.md, 2026-09-03): hyphen between name components,
    # underscore joining the two bit widths. "3" is qwen4-exp-mixed's fixed
    # routed-expert bit width -- the only recipe today, so not parameterized.
    [ -n "$NAME" ] || NAME="${MODEL_BASENAME}-mixed-3_${Q_BITS}bit"
else
    [ -n "$NAME" ] || NAME="${MODEL_BASENAME}-${Q_BITS}bit"
fi
MODELS_ROOT="$HOME/.lmstudio/models/$PUBLISHER"
OUT_DIR="$MODELS_ROOT/$NAME"
# Mirrors mlx-community's own naming (Qwen3.8-27B-MTP-8bit) so the drafter sorts
# next to its base model. convert's default, "<mlx-path>-mtp", does not.
if [ -n "$RECIPE" ]; then
    MTP_NAME="${MODEL_BASENAME}-MTP-mixed-3_${Q_BITS}bit"
else
    MTP_NAME="${MODEL_BASENAME}-MTP-${Q_BITS}bit"
fi
MTP_DIR="$MODELS_ROOT/$MTP_NAME"
# Staged in siblings and moved on success -- a conversion this long must not
# leave a half-written directory that looks like a finished model.
STAGING_DIR="$MODELS_ROOT/.$NAME.partial"
MTP_STAGING_DIR="$MODELS_ROOT/.$MTP_NAME.partial"

if [ -d "$OUT_DIR" ]; then
    printf "${C_YELLOW}Output already exists: $OUT_DIR -- remove it or pass a different --name.${C_RESET}\n" >&2
    exit 1
fi

# --- Preflight: disk ---------------------------------------------------------
# An affine group quantization stores `bits` per weight plus an fp16 scale and an
# fp16 bias per group: (bits + 32/group_size) bits, against the source's 16.
# Applied to the source's on-disk size this lands within a few percent.
SOURCE_DIR="$("$PY" - "$HF_PATH" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path

src = sys.argv[1]
if (Path(src) / "config.json").is_file():
    print(Path(src).resolve())
else:
    from huggingface_hub import snapshot_download
    print(snapshot_download(src, local_files_only=True))
PY
)"

SOURCE_GB=""
if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
    SOURCE_GB="$(du -sk -L "$SOURCE_DIR" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')"
fi

# A recipe mixes bit widths per module, so the uniform formula above is only
# approximate for it -- routed experts dominate a MoE's parameter count, so
# estimate from their bucket (3bit/group-64) rather than the structural one.
if [ -n "$RECIPE" ]; then
    EST_BITS=3
    EST_GROUP_SIZE=64
else
    EST_BITS="$Q_BITS"
    EST_GROUP_SIZE="$Q_GROUP_SIZE"
fi

NEED_GB=""
if [ -n "$SOURCE_GB" ] && [ "$SOURCE_GB" -gt 0 ]; then
    NEED_GB="$(awk -v s="$SOURCE_GB" -v b="$EST_BITS" -v g="$EST_GROUP_SIZE" 'BEGIN{printf "%.0f", s*(b+32/g)/16*1.15}')"
fi
AVAIL_GB="$(df -g "$HOME" | awk 'NR==2{print $4}')"

# --- Plan -------------------------------------------------------------------
printf "${C_CYAN}=== MLX conversion plan ===${C_RESET}\n"
printf "  source        %s (model_type: %s)\n" "$HF_PATH" "$MODEL_TYPE"
[ -n "$SOURCE_GB" ] && printf "  source size   ~%s GiB\n" "$SOURCE_GB"
if [ -n "$RECIPE" ]; then
    printf "  quantization  recipe %s: experts 3bit/g64, PLE table 4bit/g32, router/indexer unquantized, everything else %s-bit/g%s\n" "$RECIPE" "$Q_BITS" "$Q_GROUP_SIZE"
else
    printf "  quantization  %s-bit affine, group size %s\n" "$Q_BITS" "$Q_GROUP_SIZE"
fi
printf "  output        %s\n" "$OUT_DIR"
if [ "$WITH_MTP" -eq 1 ]; then
    printf "  MTP drafter   %s\n" "$MTP_DIR"
else
    printf "  MTP drafter   ${C_GRAY}(skipped)${C_RESET}\n"
fi
if [ -n "$NEED_GB" ]; then
    if [ -n "$RECIPE" ]; then
        printf "  disk needed   ~%s GiB (available: %s GiB, approximate -- estimated from the experts bucket)\n" "$NEED_GB" "$AVAIL_GB"
    else
        printf "  disk needed   ~%s GiB (available: %s GiB)\n" "$NEED_GB" "$AVAIL_GB"
    fi
fi
echo ""

if [ -n "$NEED_GB" ] && [ "$AVAIL_GB" -lt "$NEED_GB" ]; then
    printf "${C_YELLOW}Not enough free disk: need ~${NEED_GB} GiB, have ${AVAIL_GB} GiB.${C_RESET}\n" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$RECIPE" ]; then
    CONVERT_CMD=("$PY" "$SCRIPT_DIR/lib/convert-mixed-quant.py" --recipe "$RECIPE" --hf-path "$HF_PATH" --mlx-path "$STAGING_DIR" --q-bits "$Q_BITS" --q-group-size "$Q_GROUP_SIZE")
    if [ "$WITH_MTP" -eq 1 ]; then
        CONVERT_CMD+=(--mtp --mtp-output "$MTP_STAGING_DIR")
    fi
else
    CONVERT_CMD=(mlx_vlm.convert --hf-path "$HF_PATH" --mlx-path "$STAGING_DIR" -q --q-bits "$Q_BITS" --q-group-size "$Q_GROUP_SIZE")
    if [ "$WITH_MTP" -eq 1 ]; then
        CONVERT_CMD+=(--mtp --mtp-output "$MTP_STAGING_DIR")
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf "${C_GRAY}caffeinate -ism ${CONVERT_CMD[*]}${C_RESET}\n"
    exit 0
fi

# --- Convert ----------------------------------------------------------------
# caffeinate: the conversion runs for hours and must survive an idle display.
# -i no idle sleep, -s no system sleep, -m no disk sleep.
mkdir -p "$MODELS_ROOT"
rm -rf "$STAGING_DIR" "$MTP_STAGING_DIR"

printf -- "${C_BOLD}--- Converting (this takes a while; do not interrupt) ---${C_RESET}\n"
if ! caffeinate -ism "${CONVERT_CMD[@]}"; then
    printf "${C_YELLOW}Conversion failed -- leaving $STAGING_DIR in place for inspection.${C_RESET}\n" >&2
    exit 1
fi

mv "$STAGING_DIR" "$OUT_DIR"
printf "${C_GREEN}Model written: $OUT_DIR${C_RESET}\n"

# convert() treats a drafter failure as non-fatal and only warns, so the staging
# directory's absence -- not the exit code -- is what says MTP did not happen.
if [ "$WITH_MTP" -eq 1 ]; then
    if [ -d "$MTP_STAGING_DIR" ]; then
        mv "$MTP_STAGING_DIR" "$MTP_DIR"
        printf "${C_GREEN}MTP drafter written: $MTP_DIR${C_RESET}\n"
    else
        printf "${C_YELLOW}No MTP drafter produced -- see the [WARNING] above. The base model is unaffected.${C_RESET}\n"
    fi
fi

echo ""
printf "${C_GREEN}=== Done ===${C_RESET}\n"
echo "Next: add a llama-swap entry pointing at the paths above, then"
echo "  ~/git/cc-local-llm/scripts/serverctl.sh restart llama-swap"
