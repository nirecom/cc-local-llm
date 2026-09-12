#!/usr/bin/env python3
# Runs mlx_vlm.convert with a per-module quantization recipe, for architectures
# where a single bit width degrades quality (see docs/history.md, 2026-09-03:
# a uniform 3bit/group-32 Qwen3.8-Flash-Next build degenerated into token
# repetition because its routers, QSA indexer and hashed n-gram PLE table ran
# on the same low-bit grid as the routed experts).
#
# mlx_vlm.convert's CLI only accepts a quant_predicate by name from its own
# fixed QUANT_RECIPES list (a layer-position heuristic, not a module-type one),
# so a recipe keyed on module role needs the Python API directly. Invoked by
# scripts/convert-mlx-model.sh when --recipe is given; not meant to run alone.
import argparse
import sys

from mlx_vlm.convert import convert


def classify_qwen4_exp(path: str) -> str:
    if ".ple_embedding.ngram_embedding.shards." in path:
        return "ple_table"
    if "switch_mlp." in path:
        return "experts"
    if path.endswith("mlp.gate") or path.endswith("shared_expert_gate"):
        return "router"
    if "indexer" in path:
        return "indexer"
    return "structural"


# Bucket bits/group_size fixed by the recipe. "structural" is absent here on
# purpose -- it takes whatever --q-bits/--q-group-size the caller passed, the
# same knobs the uniform (non-recipe) conversion path uses.
RECIPES = {
    "qwen4-exp-mixed": {
        "classify": classify_qwen4_exp,
        "buckets": {
            "ple_table": {"bits": 4, "group_size": 32, "fallback_group_size": 32},
            "experts": {"bits": 3, "group_size": 64, "fallback_group_size": 32},
            "router": False,
            "indexer": False,
        },
    },
}


def build_predicate(recipe_name: str, structural_bits: int, structural_group_size: int):
    recipe = RECIPES[recipe_name]
    classify = recipe["classify"]
    buckets = recipe["buckets"]

    def predicate(path, module):
        if not hasattr(module, "to_quantized"):
            return False
        bucket = classify(path)
        if bucket == "structural":
            return {
                "bits": structural_bits,
                "group_size": structural_group_size,
                "fallback_group_size": 32,
            }
        return buckets[bucket]

    return predicate


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe", required=True, choices=sorted(RECIPES))
    parser.add_argument("--hf-path", required=True)
    parser.add_argument("--mlx-path", required=True)
    parser.add_argument("--q-bits", type=int, required=True)
    parser.add_argument("--q-group-size", type=int, required=True)
    parser.add_argument("--mtp", action="store_true")
    parser.add_argument("--mtp-output")
    args = parser.parse_args()

    predicate = build_predicate(args.recipe, args.q_bits, args.q_group_size)

    convert(
        hf_path=args.hf_path,
        mlx_path=args.mlx_path,
        quantize=True,
        q_group_size=args.q_group_size,
        q_bits=args.q_bits,
        quant_predicate=predicate,
        mtp=args.mtp,
        mtp_output=args.mtp_output,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
