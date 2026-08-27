# llama-swap configs

One subdirectory per host, named `<chip>-<memory>`. Each holds `config.yaml`
and `model-annotations.yaml` — see [../CLAUDE.md](../CLAUDE.md) for the rule that keeps
the two in step.

| Directory | Host | What the memory in the name is |
|---|---|---|
| `m5-max-128gb/` | Mac (this machine) | 128 GB unified memory — the VRAM equivalent |
| `rtx5070ti-128gb/` | Windows host | 128 GB system RAM. The 5070 Ti's 16 GB VRAM holds only part of a model; the rest spills to host RAM (`--n-cpu-moe`), so system RAM is the governing budget |

The memory belongs in the name because every value in these configs is derived from it —
weights, context length, KV budget, `concurrencyLimit`. Replacing the hardware forces a
rename, which is the intent: a changed ceiling should not pass silently.

The Mac serves `m5-max-128gb/` only (`LLAMA_SWAP_ROOT` in
[../scripts/lib/paths.sh](../scripts/lib/paths.sh)). The Windows directory is kept here
for side-by-side review; that host runs its own llama-swap.
