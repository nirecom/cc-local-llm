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

Both directories are served from here, by different mechanisms. The Mac resolves
`m5-max-128gb/` through `LLAMA_SWAP_ROOT` in
[../scripts/lib/paths.sh](../scripts/lib/paths.sh). The Windows host's llama-swap service
reads `rtx5070ti-128gb/config.yaml` directly, because NSSM burns the path into the
service's `--config` argument at registration time; `install.ps1 -Server` is what registers
it. Neither path is spelled out here — see [../docs/infrastructure.md](../docs/infrastructure.md).

Windows carries 14 annotations against 11 models. Three keys that left `config.yaml` are kept
with a `retained:` reason because the judgement behind them is still consulted. The Mac side
is 1:1 not because a different rule applies to it, but because it happens to have no expired
annotation worth keeping — the rule itself is in [../CLAUDE.md](../CLAUDE.md).
