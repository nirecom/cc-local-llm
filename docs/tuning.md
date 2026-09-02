# Tuning — parameters and their rationale

Every ds4-server flag and Claude Code env var, with the value and **why**. Design context is
in [architecture.md](architecture.md); procedures in [ops.md](ops.md); the chronological
incidents that produced these values in [history.md](history.md).

## Server flags (ds4-server)

| Flag | Value | Why |
|---|---|---|
| `--metal` | — | Apple GPU backend. |
| `--quality` | on | Prefer exact kernels over faster approximate paths. Direct accuracy lever under the q2-q4 quant; costs some tok/s (accepted). |
| `--ctx` | `393216` | 384K context, and the gate for Think Max (`DS4_THINK_MAX_MIN_CONTEXT = 393216`). See "Think Max" below. |
| `--kv-disk-dir` | `~/Library/Caches/ds4-server/kv` | Persistent + Time Machine-excluded by macOS default. `/tmp` was rejected (non-persistent, and TM-*included* → would back up 100s of GB). Same SSD volume, so no speed loss. |
| `--kv-disk-space-mb` | `32768` | 32 GB cap: skips pathologically large single checkpoints and bounds eviction. Not a total-write cap (eviction deletes, so churn can still exceed it). Lowered back from 64 GB (2026-07-13) — header analysis of the live cache showed only 34 total hits across 52 files, 68% of bytes never reused; the 2026-07-11 raise to 64 GB likely masked a gap in the eviction score (`(effective_hits+1) × tokens/file_size`, half-life-decayed) rather than fixing a real capacity shortfall — a brand-new unhit checkpoint scores identically to an ancient unhit one, so the larger budget mainly let dead sessions linger. Rolled back pending real `kv cache evicted`/`kv cache hit` log evidence (now persisted to `~/Library/Logs/ds4-server/kvcache.log`, see `scripts/ds4-server.sh`) on whether a live session's checkpoint is ever evicted prematurely at this budget. |
| `--kv-cache-cold-max-tokens` | `90000` | Largest single cold-save snapshot; big enough to cache a typical CC initial context in one write, below `--ctx`. |
| `--kv-cache-continued-interval-tokens` | `50000` | **The write-amplification lever.** Each continued checkpoint rewrites the whole live prefix (not a delta), doubled f16→f32. The default 10000 caused a 137 GB write storm; 25000 more than halved the churn. Doubled again to 50000 on 2026-08-10 (#34): over the 0713–0811 window `reason=continued` was still 317 writes / 325.94 GiB, 37% of all KV disk writes. Note the reduction is **not** linear — a longer interval means each individual checkpoint is larger, so halving the checkpoint count does not halve the bytes. |
| `--warm-weights` | on | Page in the whole model at startup. RSS ~90.9 GB is expected, not a leak. |
| `--batched-session` | `2` | **Number of resident KV sessions.** With a single live KV slot, the main conversation, sub-agents and one-off small prompts evict each other's prefix every time they interleave. Over the 0713–0811 window every one of the 548 live-cache misses was `token-mismatch`, and 55% of them shared under 1000 tokens of common prefix — i.e. the slot had been handed to an unrelated request. That eviction is also what produced `reason=evict` 475.00 GiB, 54% of all KV disk writes. So the single slot is the **common cause** of both the 30.7 hours of cold prefill and the bulk of the disk churn, which is why it is attacked first. Started at N=2 rather than N=3 because the premise for sizing N — "~1.3 GB per KV session" — is a derived figure that has never been measured (#34); confirm real RSS before deciding on N=3. |
| `--host 127.0.0.1` | — | Loopback only; the proxy (scripts/ccgw-proxy.sh) is the LAN endpoint. |

## Memory budget (128 GB)

Weights ~90.9 GB resident; KV grows lazily as a session fills (startup RSS ≈ weights only).

| ctx | full-context KV | peak RSS | macOS headroom |
|---|---|---|---|
| 327680 | ~8.5 GB | ~99.4 GB | ~28.6 GB |
| **393216** | ~10.2 GB | **~101.1 GB** | **~26.9 GB** |

393216 fits comfortably as a dedicated server. `1M` ctx (~26 GB KV → ~117 GB peak) is too
much — do not.

The peak RSS figures above assume **one** resident KV session. With `--batched-session 2` a
second resident session's KV can add on top, so the real headroom is smaller than the table
says. The numbers are left unchanged until the actual RSS under N=2 is measured — update this
section once that measurement exists rather than substituting an estimate.

## Server flags (Laguna S 2.1 / mlx_lm.server)

| Flag / key | Value | Why |
|---|---|---|
| `--prompt-cache-bytes` | `40GB` | Caps the *idle* LRU prompt cache only — `mlx_lm/server.py`'s trim only shrinks idle entries toward 0 to make room for active generation, never blocks active memory. Raising it can't worsen the worst case. weights(~67GB)+40GB ≈ 107GB, ~9GB under the ~116GB Metal wired ceiling. |
| `--prompt-cache-size` | `10` | mlx-lm's own default entry-count cap, so shorter conversations aren't evicted by count before the byte cap binds. |
| `concurrencyLimit` (llama-swap) | `5` | The only real cap on *active* generation memory (not covered by the flag above). Raised from the emergency value of 4 — full KV-cost derivation and accepted worst-case risk in [history.md](history.md) (CONFIG, 2026-08-16). |

## MTP speculative decoding (Qwen3.8-27B)

The whole Qwen3.8-27B family runs on **`mlx_vlm.server`**, not `mlx_lm.server`. mlx-lm ships
no `qwen3_5_mtp` module at all — pointing `--draft-model` at an MTP adapter there fails with
`Model type qwen3_5_mtp not supported` — and its native-MTP PR ([ml-explore/mlx-lm#990]
(https://github.com/ml-explore/mlx-lm/pull/990)) is still unmerged. mlx-vlm has the drafter
(`mlx_vlm/speculative/drafters/qwen3_5_mtp/`), and Qwen3.8-27B is itself multimodal
(`Qwen3_5ForConditionalGeneration`), so mlx-vlm is its proper home. Installed by
[install/mac/mlx-vlm.sh](../install/mac/mlx-vlm.sh); the two packages coexist as separate
uv tools, so Laguna and Qwen3-Next keep using mlx-lm untouched.

The **non**-MTP entries stay on the same server on purpose: with only the drafter differing,
the A/B below is controlled rather than a comparison of two different runtimes.

Measured on this Mac, 8bit, 27-token prompt / 59-token completion, identical output text:

| Entry | decode | prefill | peak mem | drafter |
|---|---|---|---|---|
| `qwen3.8-27b-8bit` | 17.9 tok/s | 183 tok/s | 29.8 GB | — |
| `qwen3.8-27b-8bit-mtp` | **36.6 tok/s** | 211 tok/s | 30.8 GB | 36/44 accepted (82%) |

**2.0x on generation for ~1 GB.** MTP does not help prefill — the target still does one full
forward pass — so the prefill column differs only by run-to-run noise.

Two behavioural differences from `mlx_lm.server` shape the flags in
[llama-swap/m5-max-128gb/config.yaml](../llama-swap/m5-max-128gb/config.yaml):

| Flag / key | Value | Why |
|---|---|---|
| `--draft-kind` | `mtp` | Auto-detection from the adapter's `model_type` exists, but `--help` documents `mtp` as the Gemma 4 family; pinning it explicitly keeps the pairing from silently falling back to `dflash`. |
| `useModelName` (llama-swap) | the `--model` path | The **opposite** of the `laguna-s-2.1` quirk. mlx_vlm.server registers the loaded model under its `--model` path and resolves any other body `model` as an HF repo id (401). `${env.HOME}` does expand here. |
| `--max-num-seqs` | `3` | Matches `concurrencyLimit`, bounding peak memory at the server as well as the swapper. |
| *(no `--prompt-cache-*`)* | — | mlx-vlm has no equivalent flags — its prefix cache is a different mechanism (APC), enabled per entry through `env:` rather than a flag. See "Prefix caching (APC)" below: it turns a continuation turn from minutes into ~1 s, and halves the reachable context. |

`jinja2` is a missing dependency in mlx-vlm's `requirements.txt`, so the installer adds it with
`--with jinja2`. Without it the server starts and passes `/health`, then fails **every**
completion with `apply_chat_template requires jinja2 to be installed`.

`qwen3.8-27b-uncensored-4bit` (orcarouter abliterated fine-tune) is deliberately unpaired: the
drafter was split from the stock checkpoint, and that weight drift would depress its acceptance
rate.

## Qwen3.8-Flash-Next (3bit)

All numbers below come from `mlx_vlm.server`'s llama.cpp-shaped `timings` block, which is
attached **only to non-streaming responses** — a streaming client sees none of it, so every
measurement here has to be taken with `stream: false`.

### Baseline, and where MTP stops paying

Same server, same 3bit checkpoint, identical output text; the only difference is the drafter:

| Entry | prompt | prefill | decode | peak mem | drafter |
|---|---|---|---|---|---|
| `qwen3.8-flash-next-3bit` | 27 tok | 298 tok/s | 36.6 tok/s | 89.7 GB | — |
| `qwen3.8-flash-next-3bit-mtp` | 27 tok | 299 tok/s | **52.9 tok/s** | 91.2 GB | 21/21 (100%) |
| `qwen3.8-flash-next-3bit` | 35,797 tok | 1098 tok/s | 30.2 tok/s | 96.5 GB | — |
| `qwen3.8-flash-next-3bit-mtp` | 35,797 tok | 1069 tok/s | **35.0 tok/s** | 98.1 GB | 186/214 (87%) |

**1.44x at a short prompt, 1.16x at 36k.** The variable is context length, and nobody sets it:
a Claude Code session accumulates history on its own, so it drifts from the first row to the
second without anyone touching a flag. What decays along the way is acceptance (100% → 87%) —
the drafter guesses less well the more history conditions it. The ~1.5 GB still pays at both
ends, but the number to size expectations from is the 36k row, since that is where a working
session spends its time.

### Peak memory vs context

`peak_memory` is a **process-lifetime high-water mark** — no `reset_peak_memory` call exists
anywhere in mlx-vlm — so a curve is only valid if the cases run in ascending context order on a
single model load. Measured that way, non-MTP entry:

| prompt_n | peak mem | prefill | decode |
|---|---|---|---|
| 10,434 | 93.3 GB | 1406 tok/s | 32.9 tok/s |
| 36,319 | 96.5 GB | 1083 tok/s | 29.7 tok/s |
| 72,434 | 101.5 GB | 788 tok/s | 25.7 tok/s |
| 103,434 | 105.7 GB | 605 tok/s | 23.0 tok/s |

The four points are a straight line, so the whole tier reduces to two numbers:
`peak = intercept + per-token cost × context`. Least squares gives **134 KB per token of
context, on an intercept of 91.8 GB** — the intercept being what is resident regardless of
context length (weights, mostly), the per-token cost being what each further token adds.

Those two numbers are the entire ceiling story, because the reachable context is
`(limit − intercept) ÷ per-token cost` and nothing else. Metal reports
`recommendedMaxWorkingSetSize` = 115.45 GB, so the hard ceiling is ~176k tokens and a practical
112 GB budget stops at ~151k — **well short of the checkpoint's native 262,144**. Raising it
means lowering one of the two, and only the per-token cost is movable by a flag.

Same actor, same non-action: a session on this tier arrives at ~151k by running long enough, and
nothing on the client side knows it should stop there. The checkpoint advertises 262,144, and
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` ([below](#client-env-vars-claude-code)) is a single global
value — so the ceiling that has to be honoured is the smallest one across the tiers actually in
use, not ds4's.

Only about a fifth of that per-token cost is cache. `config.json` gives `full_attention_interval: 4`
over `num_hidden_layers: 48` → 12 full-attention layers; at `num_key_value_heads: 2` ×
`head_dim: 256` × (K,V) × 2 bytes that is 24.6 KB/token, plus ~3.1 KB/token of QSA `index_keys`,
which `QSAKVCache` carries alongside K and V. The remaining ~106 KB/token is **prefill scratch**:
`QSAIndexer.from_projected` builds its block scores in float32 across the whole key length for
every chunk, so that term scales with `--prefill-step-size` (2048 by default, unset here) rather
than with the model.

That split is what decides which lever moves the ceiling. Halving the prefill step attacks the
dominant term; `--kv-bits 4` reaches only the 24.6 KB portion, because `QSAKVCache.to_quantized`
passes `index_keys` through unquantized. Same 4-point curve, same ascending order, one flag
changed:

| Setting | per token | intercept | hard ceiling | at 112 GB | peak at 103k |
|---|---|---|---|---|---|
| `--prefill-step-size 2048` *(mlx-vlm default)* | 134 KB/tok | 91.8 GB | ~176k | ~151k | 105.7 GB |
| `--prefill-step-size 1024` | **85.5 KB/tok** | 91.1 GB | **~298k** | ~256k | 99.6 GB |
| `--kv-bits 4` *(estimate, unmeasured)* | ~116 KB/tok | — | ~204k | ~174k | — |

The prediction from the code reading was ~85 KB/token and the measurement is 85.5, which is the
confirmation that the fp32 indexer scratch — not the cache — is what fills the machine. **The
native 262,144 clears outright at the hard ceiling**, and a 112 GB budget lands within ~6k of it.

What it costs is prefill throughput, and less than the halved step suggests:

| prompt_n | 2048 | 1024 | delta |
|---|---|---|---|
| 10,434 | 1406 tok/s | 1282 tok/s | −8.8% |
| 36,319 | 1083 tok/s | 1006 tok/s | −7.1% |
| 72,434 | 788 tok/s | 761 tok/s | −3.4% |
| 103,434 | 605 tok/s | 599 tok/s | −1.1% |

The penalty **shrinks as the context grows** — it is largest where memory was never the problem
and nearly free at the lengths that motivated the change. Decode is unchanged within run-to-run
noise at all four points. `--kv-bits` stays unmeasured and unattractive by comparison: it buys
less ceiling, and it would stack quantization error on already-3bit weights.

The remaining question was whether the drafter gives that headroom back. Three conditions at the
same 103,434-token prompt — byte-identical, so the only variables are the two flags:

| Condition | peak | prefill | decode | drafter |
|---|---|---|---|---|
| step 2048, no drafter | 105.7 GB | 605 tok/s | 23.0 tok/s | — |
| step 1024, no drafter | 99.6 GB | 599 tok/s | 23.6 tok/s | — |
| step 1024, MTP | 101.2 GB | 653 tok/s | **28.2 tok/s** | 31/32 |

**The drafter costs 1.6 GB against the 6.1 GB the flag freed**, so the two compose. A fifth
point closes the extrapolation instead of leaving it as one:

| prompt_n | peak mem | prefill | decode | drafter |
|---|---|---|---|---|
| 103,434 | 101.2 GB | 627 tok/s | 27.8 tok/s | 31/32 |
| 155,049 | 105.6 GB | 489 tok/s | 22.6 tok/s | 31/32 |

85.3 KB per token between those two against the 85.5 fitted below 103k — the line does not bend.
Intercept 92.4 GB, so the ceilings are measured rather than guessed: **~270k hard, ~230k on a
112 GB budget**. Native 262,144 clears the hard ceiling by about 0.8 GB, which is not margin
worth relying on; plan against ~230k, and halving the step again is the obvious next candidate.

That fifth point had to be measured twice. The first attempt read 109.6 GB and made the line look
like it bent upward — but it ran on the process that had just timed out on a 200k prompt, and
`peak_memory` is a **process-lifetime** high-water mark, so it had inherited that partial
prefill's peak. This is the ascending-order rule above, restated: any earlier allocation in the
process contaminates the reading, and whether the request that caused it succeeded makes no
difference. Evicting the model first — any request to another llama-swap entry does it — and
re-measuring gave 105.6 GB.

The ceiling that binds first is no longer memory, though. A 200,000-token prompt came back with
`Timed out waiting for 600s for the next generated token` — `MLX_VLM_TOKEN_QUEUE_TIMEOUT`, not an
allocation failure. Prefill falls from 1,406 tok/s at 10k to 489 at 155k, where a single turn
already costs 317 s. So the clock stops somewhere between 155k and 200k while memory still has
room to ~230k, and no flag in this file moves that — only not re-prefilling the prefix does,
which is the next section.

That 600s is a fixed default rather than a real limit, so the entry now sets
`MLX_VLM_TOKEN_QUEUE_TIMEOUT=3600` and the prompt completes: 206,819 tokens at 288.6 tok/s of
prefill, 717 s, peak 109.7 GB against the 115.45 GB ceiling — 0.3 GB off the 109.4 the memory
line predicts. Native 262,144 would take past 1,100 s at that rate. Note this measurement needs
APC off, since its second copy of the KV puts 200k at 126.5 GB. The two are mutually exclusive:
~230k at roughly twelve minutes a turn, or ~115k at 1.3 s. Only the latter is a usable tier, and
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` keeps prompts to 76,800 in either case.

Two cautions on that last row. The prefill figure is *higher* than the no-drafter run, which MTP
cannot cause — the target still does one full forward pass — so read it as run-to-run noise, not
an effect. And 31/32 acceptance does not generalise: the task was listing consecutive shard
names, which is about the friendliest thing a drafter can be asked to predict, over only 32 draft
tokens. The 87% at 36k is the more honest number to plan against.

### Prefix caching (APC)

Off by default and not reachable by flag: `RuntimeConfig.apc_enabled` defaults to `False`, its env
override `APC_ENABLED` defaults to `"0"`, and `mlx_vlm/server/cli.py` exposes nothing. `PATCH
/v1/settings` looks like a way in and is not — it answers `applied: {apc_enabled: true}`,
`rejected: []`, `reload_kinds: ["text_generation"]`, and `/health` still reports
`apc_enabled=false` once the reload finishes. `apc.from_env` does honour `overrides["enabled"]`,
so the model-load path simply never re-runs. Treat it as **startup-only** and set it through the
entry's `env:` block in [llama-swap/m5-max-128gb/config.yaml](../llama-swap/m5-max-128gb/config.yaml),
which llama-swap does pass to the model process.

Turned on, against a 96,140-token corpus on `qwen3.8-flash-next-3bit-mtp`:

| Case | cache_n / uncached | peak | wall |
|---|---|---|---|
| cold | 0 / 96,140 | 102.6 GB | 145.1 s |
| continuation (prior turn + new question) | 96,140 / 39 | 110.7 GB | **1.3 s** |
| cold, 134,425 tokens | 0 / 134,425 | 115.2 GB | 338.9 s |
| continuation of that | — | — | **Metal OOM, HTTP 500** |

Three things decide whether this helps or hurts.

**The mode is `exact`, not `block` — on both mlx-vlm tiers.** `apc_adapters.apc_block_eligible`
matches on exact type (`type(cache) in {KVCache}`), so Flash-Next's `QSAKVCache` fails it by being
a *subclass*, and the 27B fails it too because its `make_cache` mixes `ArraysCache` into the
linear layers. `PrefixCachePlan.strategy` returns `"block"` only when **every** layer is
block-eligible, so both models fall to `"checkpoint"`, which `legacy_mode` maps to `"exact"`: a
whole-prefix snapshot, restored only on a full prefix match. That makes `APC_NUM_BLOCKS` the wrong
knob; the ones that apply are `APC_EXACT_CACHE_ENTRIES` and `APC_EXACT_MIN_TOKENS` (default 16).
`--kv-bits` does not open the block path either — `generate/common.py` skips any cache setting
`preserve_auxiliary_kv_state`, which `QSAKVCache` sets precisely so the quantizers cannot drop its
`index_keys`.

**One entry is enough, and it is not the obvious one.** Each request stores *two* snapshots: a
checkpoint at `n-1` tokens during prefill, then the full `n` at the end. Lookup caps candidates at
`len(prompt) - 1`, so the two are not interchangeable — the `n-1` entry can only ever serve a
byte-identical resend, and the full-length one can only ever serve a *longer* prompt, i.e. a
continuation. The full-length store lands last, so at `APC_EXACT_CACHE_ENTRIES=1` it is the one
that survives eviction, which is exactly the entry an append-only conversation needs. A second
entry buys only the identical-resend case and tolerance for one interleaved unrelated request
(a parallel session or a subagent) — at the price below, per entry.

**The price is a second copy of the KV cache.** An exact snapshot is a clone of the live cache, so
it costs what the cache costs: 8.1 GB measured over 96,140 tokens, 84 KB/token against the KV's
own 85.3. That doubles the slope of the memory line — `peak ≈ 92.4 GB + 170.6 KB/token` instead of
85.3 — and so **halves the reachable context: ~135k hard, ~115k on a 112 GB budget**, against the
~270k/~230k of the same entry with APC off. The 134,425-token continuation above is that ceiling
being hit: `kIOGPUCommandBufferCallbackErrorOutOfMemory`, mid-request, after the prompt was
accepted. `APC_DISK_PATH` adds an SSD tier holding exact snapshots too
(`_DiskExactCacheSnapshot`), but it is a second tier rather than a replacement, so it does not by
itself lower the resident cost.

The trade is worth taking on this model — the context it gives up costs twelve minutes a turn to
use, which no interactive tier can spend — but it
changes the failure mode, which is why it is on the `used_by: []` candidate entry and not yet on a
routed tier. Without APC an over-long prompt is slow; with it, a prompt past ~115k returns HTTP
500 with no tokens at all. A routed tier needs that bound enforced upstream first.

APC is also what makes the proxy's prompt normalization
([architecture.md](architecture.md#why-prompt-normalization)) pay off here: an exact-mode hit needs
the prefix to match token-for-token, so a timestamp or a git line that moves between turns costs
the whole 145 s. Before APC there was no prefix cache for a stable prefix to hit, and the
normalization only earned its keep on the ds4 tier, which keeps its own KV cache via
`--kv-disk-dir`.

## Memory budget (Laguna S 2.1)

Weights ~67 GB resident. `sliding_window: 512` on 36/48 layers + `num_key_value_heads: 8` (GQA)
keeps a single request's KV cost to ~48 KB/token — even a maxed-out 262144-token request costs
only ~12.9 GB of active KV memory. Full derivation and incident history: [history.md](history.md).

## Windows host (RTX 5070 Ti 16 GB / 128 GB RAM)

The Mac's problem is one huge model against 128 GB of unified memory. The Windows host's is the
opposite: eleven models against **16 GB of VRAM**, with 128 GB of ordinary system RAM behind it.
Every decision in [llama-swap/rtx5070ti-128gb/config.yaml](../llama-swap/rtx5070ti-128gb/config.yaml)
falls out of that. Values live in that file; only the reasoning is here.

**VRAM placement is four distinct patterns, not one.** Classify by what the entry actually does,
not by parameter count:

- **Full GPU residency** — no offload flag at all, `-ngl` set past the layer count:
  `NVIDIA-Nemotron-Nano-9B-v2-Japanese-Q8_0`, `Qwen3.5-27B-IQ3_M`, `Qwen3-Coder-Next-Q4_K_M`,
  `Qwen3.8-27B-UD-Q3_K_XL`. The two 27B-class members only reach this pattern because the quant
  is pushed down to IQ3_M / UD-Q3_K_XL — at Q4 they would not fit at all.
- **MoE expert layers pushed to host RAM** — `gpt-oss-120b-MXFP4` and
  `Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL` via `--n-cpu-moe`, `gpt-oss-20b-MXFP4` via an
  `--override-tensor` regex that sends the upper block range's `ffn_*_exps` to CPU (the 30B-A3B
  entry carries both). These three are the reason 128 GB of system RAM matters, and the `128gb`
  in the host directory's name refers to this class, not to the GPU.
- **Partial offload** — `Devstral-Small-2-24B-Instruct-2512-IQ4_XS` keeps most layers on the GPU
  and pays for its 64K context with quantized KV.
- **Deliberately GPU-free** — `Qwen2.5-7B-Instruct-Q4_K_M` runs `-ngl 0 --device none`. It is the
  always-resident judge in the `forever` group, so occupying **zero** GPU bytes outranks its own
  throughput. The optimizer's 2026/04/05 run proposed a full-offload `-ngl` for it and measured a
  large speedup; that suggestion was rejected outright and never deployed (figures and date in
  [history.md](history.md)). The gap between what the optimizer suggested and what was deployed is
  exactly the kind of reasoning this file exists to hold.

`Llama-3-ELYZA-JP-8B-q4_k_m` and `Lumimaid-v0.2-12B.q4_k_m` (and the `Qwen2.5-7B` entry above)
carry an `--override-tensor` `ffn_*_exps` regex despite being dense models with no `exps` tensors
for it to match. This is **likely a no-op** left over from the optimizer applying the flag
uniformly — unconfirmed: verifying it means reading `llama-server`'s startup tensor-allocation
log and checking whether any tensor is redirected. Do not remove it on the strength of this
paragraph alone.

**KV quantization splits into three groups, and the split does not follow the group config.**
Within the seven `heavy` members alone there are two different policies:

- `-ctk q4_0 -ctv q4_0` — `Qwen3.5-27B-IQ3_M`, `Devstral`, `Qwen3-Coder-Next`,
  `Qwen3-Coder-30B-A3B` and `Qwen3.8-27B` (five models), running 32K to 100K context — the last
  two both at 100K. At this
  VRAM budget it is effectively the only lever that makes that much context fit, and `q4_0` is
  as far as llama.cpp goes — there is no deeper setting to fall back on.
- `--cache-type-k q8_0 --cache-type-v q8_0` — `gpt-oss-120b-MXFP4` alone. It can afford the
  larger KV type because its context is the smallest in the file.
- **No KV quantization** (f16 default) — `gpt-oss-20b`, `Qwen2.5-7B`, `Nemotron`, `ELYZA` and
  `Lumimaid` (five models), whose context is small or unset, so there is nothing to shrink.
  `gpt-oss-20b` sits in `heavy` yet quantizes no KV: group membership and KV policy are
  independent axes.

How much this matters is visible in the IQ4_XS → UD-Q3_K_XL swap on `Qwen3.8-27B`: a few hundred
MiB less spill out of VRAM bought a tens-of-percent throughput gain at the same 64K context.
Exact spill figures, tok/s and dates are in [history.md](history.md).

### Why the context window is 102400, and why the floor is here

`CLAUDE_CODE_AUTO_COMPACT_WINDOW` is one global value, so it is the *smallest* routed tier that
sets it. That floor lives on this host, not the Mac: the opus tier reaches ~115k with APC on, and
the fable tier runs `--ctx 393216`. The number is measured on both ends rather than inferred —
llama.cpp preallocates the KV for `--ctx-size` at load, but on Windows the driver falls back to
host RAM instead of failing, so a backend can start at a context it cannot actually serve. Only a
real prompt of the target length tells the two apart.

| entry | 100k prefill | 100k decode | peak VRAM (of 16,303 MiB) | verdict |
|---|---|---|---|---|
| `Qwen3-Coder-30B-A3B` | 1334.63 tok/s | 22.71 tok/s | 14,545 | clears 128k too; unrouted fallback |
| `Qwen3.8-27B` | 908.10 tok/s | 51.78 tok/s | 15,916 | routed (haiku + sonnet + subagent); fails 128k |
| `Devstral-Small-2-24B` | 6.50 tok/s, aborted | — | — | fails |

Both failures are the same mechanism at different severities. `Devstral` is dense 24B and leaves
no VRAM for a 96k KV; `Qwen3.8-27B` clears 100k flat at 908 tok/s but at 128k starts at 435 and
decays geometrically to 33 over the prompt, with peak VRAM pinned at 15,946 MiB — the KV crosses
the ceiling as it fills and every further block pages over PCIe. A dense model at this VRAM has
one place to take the memory from, and `-ctk/-ctv q4_0` is already spent; dropping `-ngl 95` to
70 on `Devstral` bought 12% against the two orders of magnitude needed.

Between the two that clear 100k the table cannot decide, because it measures throughput and the
tier is chosen on coding accuracy, which is unmeasured on both. `Qwen3.8-27B` is routed so that
gap closes on real work: it is the newer generation and 2.3× the decode, against 1.5× less
prefill and — the real cost — 387 MiB of headroom instead of 1,758. That margin is why it is the
routed model and not the safe one. `Qwen3-Coder-30B-A3B` stays configured and unrouted as what
the evaluation falls back to; it is also the only entry that clears 128k (1080.70 tok/s, 15,289
MiB), so raising the window again means moving back to it first.

One entry serves haiku, sonnet and the subagent route alike. The `heavy` group is `exclusive`, so
a second model there would be swapped in and out on every call that named it — with an exclusive
group, two backends are strictly worse than one, and that holds for the subagent route as much as
for haiku.

75% of 102400 is 76,800, which is what a backend actually receives. That is also why the LiteLLM
`timeout` on this route is no longer 60s: a cold 76,800-token prefill is 85s at 908 tok/s, so the
old value expired on the first turn after every compaction.

**Concurrency is explicit for only four entries.** `gpt-oss-120b`, `Nemotron` and `Qwen3.8-27B`
pin `--parallel` to a single slot; `Qwen2.5-7B` is the one entry that raises it, which it can
afford precisely because it is CPU-resident and never contends for the GPU. The remaining seven
leave the flag unset and inherit llama.cpp's default of one.

**Group roles** carry the exclusivity policy that the Mac side gets for free:

| Group | Policy | Purpose |
|---|---|---|
| `heavy` | `swap: true`, `exclusive: true` (7 models) | Large models, one loaded at a time |
| `light` | `swap: false`, `exclusive: true` (2 models) | Small models that need not evict each other on swap |
| `forever` | `persistent: true`, `exclusive: false` (1 model) | Keeps the judge model loaded permanently |

The Mac config has no `groups:` block at all and relies on llama-swap's default
single-active-model behavior — with two mutually exclusive backends there is nothing to arbitrate.
Eleven models contending for one 16 GB GPU is what forces the Windows side to state the policy.

Everything above is a placement decision under a hard VRAM ceiling; the Mac side's equivalents
are memory-budget decisions under a soft unified-memory ceiling. Benchmark numbers and the dates
they were taken belong to [history.md](history.md) and are deliberately not repeated here.

## Thinking control

- ds4 defaults **every** chat request to HIGH thinking.
- `effort` is nearly inert: `low`/`medium`/`high`/`xhigh` all collapse to HIGH; only `max`
  maps to Think Max. Claude Code's default `xhigh` therefore yields HIGH, unchanged from the
  server default.
- The **model name** is the real switch: `deepseek-chat` = no thinking, `deepseek-reasoner`
  = thinking on, anything else = default HIGH. In thinking mode, client sampling knobs
  (temperature/top_p/top_k) are ignored, like the official API — so accuracy cannot be tuned
  via sampling.

### Think Max (3 conditions, all required)

1. Client sends `reasoning_effort=max` or `output_config.effort=max`
2. Server `--ctx >= 393216` ✅ (this config)
3. Thinking mode on (not `deepseek-chat` / `think:false`)

Claude Code defaults to `xhigh` → HIGH, so **ctx alone does not give max** — the client must
emit `effort=max`, and whether CC forwards that to a custom endpoint is unverified. Think Max
= more reasoning = slower; a modest accuracy lever for hard planning only. For most work,
HIGH + `--quality` is the better trade.

## Client env vars (Claude Code)

| Var | Value | Why |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `https://<mac-ip>:8443` | Route CC to the ccgw proxy (TLS). |
| `ANTHROPIC_AUTH_TOKEN` | must match `CCGW_PROXY_AUTH_TOKEN` | The proxy now enforces auth; the token must match the proxy's secret. |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `393216` | Tell CC ds4's real ceiling (CC otherwise assumes the model's nominal 200K/1M window and never compacts in time). Keep in sync with `--ctx`. |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` | Compact at ~75% (~245K by CC's count). Absorbs the tokenizer mismatch — ds4/DeepSeek counts more tokens than CC/Claude for the same text, so CC must compact well before its own ceiling to keep ds4's count under 393216. |

### Per-tier thinking split without a router (optional)

To give heavy-reasoning agents thinking and mechanical workers non-thinking on ds4, use
Claude Code's alias-resolution vars (they also propagate to sub-agent `model:` frontmatter):

| Var | Value |
|---|---|
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `deepseek-reasoner` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `deepseek-chat` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `deepseek-chat` |

Caveat: whether CC accepts a non-Anthropic alias target on a custom endpoint is the one thing
to verify empirically (grep the ds4 log for `THINKING` per request). If CC rejects it, fall
back to a router.

## Proxy env vars (Mac)

Read by `scripts/ccgw-proxy.sh` (from the repo-root `.env`). Design: [architecture.md](architecture.md#reverse-proxy-layer).

| Var | Value | Why |
|---|---|---|
| `CCGW_PROXY_PORT` | `8443` (default) | HTTPS listen port. Must match the port in the client's `ANTHROPIC_BASE_URL`. |
| `CCGW_PROXY_UPSTREAM` | `http://127.0.0.1:18080` (default) | Mac llama-swap, which routes by model name to ds4-server or Laguna. An origin with no path — the incoming path is appended verbatim. |
| `CCGW_PROXY_AUTH_TOKEN` | required | Token every request reaching the proxy must present; must match the gateway's `LITELLM_CCGW_PROXY_API_KEY`. The proxy refuses to start if unset. |
| `CCGW_PROXY_TLS` | `on` (default) / `off` | Whether the proxy terminates TLS. Only the literal `off` disables it, so a typo fails towards an encrypted listener. Must be switched together with `CCGW_PROXY_HOST`, `LITELLM_CCGW_PROXY_URL`, `LITELLM_CCGW_PROXY_OPENAI_URL` and `SSL_CERT_FILE`. |
| `CCGW_PROXY_HOST` | `0.0.0.0` (default) | Bind address. `127.0.0.1` restricts the proxy to gateways on this Mac. Authentication is required either way. |
| `CCGW_PROXY_CERT` / `CCGW_PROXY_KEY` | `~/.config/ccgw-proxy/cert.pem` / `key.pem` (defaults) | mkcert-generated TLS cert/key for the HTTPS listener. Unused while `CCGW_PROXY_TLS=off`. |
| `CCGW_PROXY_TEE` | `off` (default) / `on` | When `on`, logs pre- and post-normalization request bodies for debugging. The filename carries the body shape (`anthropic` / `openai`). |
| `CCGW_PROXY_LOG_DIR` | `~/Library/Caches/ccgw-proxy/log` (default) | Where tee logs are written when `CCGW_PROXY_TEE=on`. |

### LiteLLM env vars

Read by the native LiteLLM process on the Mac, started by `serverctl.sh start litellm`.
Designed in `litellm-server/config.yaml`. Each route's `model_name` is written literally and
carries a `ccgw_tiers:` annotation naming the Claude Code tiers it serves, so that one git-tracked
file is the whole tier map and every host reads the same one. Endpoints and credentials still
arrive through `os.environ/`; their defaults are documented here rather than embedded in the
config, and are resolved at process startup.

| Var | Default | Why |
|-----|---------|-----|
| `LITELLM_MASTER_KEY` | (required) | The gateway's credential. With no database there are no virtual keys, so clients present this same value as `LITELLM_CLIENT_KEY`. Generate with `/create-key`. |
| `LITELLM_HOST` | `0.0.0.0` | Bind address. `127.0.0.1` restricts the gateway to this Mac. |
| `LITELLM_PORT` | `8445` | HTTPS listen port. Must match the port in `LITELLM_ANTHROPIC_BASE_URL`. |
| `LITELLM_TLS` | `on` | Whether the gateway terminates TLS. Clients verify against `CCGW_CA_CERT`, so `off` is only usable from this Mac. |
| `LITELLM_TLS_CERT` / `LITELLM_TLS_KEY` | (required while `LITELLM_TLS=on`) | mkcert-issued leaf cert/key the gateway serves. The start guard refuses to launch when either is missing. |
| `SSL_CERT_FILE` | (required while the proxy or llama-swap hop is HTTPS) | Root CA the gateway trusts when connecting to the CCGW Proxy and to the Windows PC's Caddy TLS front — both are signed by the same mkcert root CA. Absolute path — tilde is not expanded. |
| `LITELLM_CCGW_PROXY_URL` | `https://<mac-lan-ip>:8443` | CCGW Proxy origin for the Fable tier. No path component: the proxy appends the incoming path verbatim, and the `anthropic/` provider appends `/v1/messages` itself. |
| `LITELLM_CCGW_PROXY_OPENAI_URL` | `https://<mac-lan-ip>:8443/v1` | The same proxy endpoint with a `/v1` suffix, for the Opus tier. The `openai/` provider appends only `/chat/completions`, so without the suffix the request lands on llama-swap's unrouted `/chat/completions` and comes back as a bare `404 page not found`. Same host and port as `LITELLM_CCGW_PROXY_URL` — only the suffix differs. |
| `LITELLM_CCGW_PROXY_API_KEY` | (required) | Credential the gateway presents to the CCGW Proxy. Must match `CCGW_PROXY_AUTH_TOKEN`. |
| `LITELLM_LLAMASWAP_URL` | `https://<windows-lan-ip>:8443/v1` | Windows PC endpoint shared by the Haiku and Sonnet tiers: the host's Caddy TLS front, which reverse-proxies to llama-swap's loopback-only `:18080`. Sole backend for these tiers — no fallback. Its certificate is verified against `SSL_CERT_FILE`; the hop carries no auth key. Carries a `/v1` suffix for the same reason `LITELLM_CCGW_PROXY_OPENAI_URL` does — an `openai/`-provider route — and is the only endpoint here addressing a host directly rather than through the CCGW Proxy. |
| `LITELLM_ANTHROPIC_BASE_URL` | (required for client) | The gateway endpoint the launcher points `ANTHROPIC_BASE_URL` at. The direct CCGW Proxy route is retired, so the launcher exits when this is unset. |
| `LITELLM_CLIENT_KEY` | (required for client) | Credential the launcher presents to the gateway. Same value as `LITELLM_MASTER_KEY`. `LITELLM_VIRTUAL_KEY` is accepted for one release as a deprecated alias, with a warning. |
| `CCGW_AUTO_PULL` | `on` | Whether the launcher refreshes this checkout from its upstream before starting the editor. On by default including when set nowhere at all: a host that never opts in is the stale host the switch exists to prevent. An uncommitted or diverged checkout is reported and left alone, never fast-forwarded over. |

`LITELLM_HAIKU_MODEL`, `LITELLM_SONNET_MODEL`, `LITELLM_FABLE_MODEL`, `LITELLM_OPUS_MODEL` and
`CCGW_SUBAGENT_MODEL` are retired. Each named a routing key per machine, which is how the hosts
came to address different backends from the same repo; the tier map now lives in the
`ccgw_tiers:` annotations of `litellm-server/config.yaml`. A launcher that still finds one of
them set says so and ignores it.

### Client env vars

`ANTHROPIC_BASE_URL` points at the gateway (`https://<mac-lan-ip>:8445`); there is no second
path. The per-tier alias vars take each route's `model_name` from `litellm-server/config.yaml`
verbatim — the launchers own no backend names, so an unknown key surfaces as a 400 from the
gateway rather than as a guess made client-side. A tier no route claims leaves its alias var out
of the child's environment entirely, rather than set to something that resolves nowhere.

| Tier | Route | Backend |
|---|---|---|
| Fable | `deepseek-v4-flash` | ds4, Mac |
| Opus | `qwen3.8-flash-next-3bit-mtp` | `mlx_lm.server`, Mac |
| Sonnet | `qwen3.8-27b` | Qwen3.8-27B, Windows llama-swap |
| Haiku | `qwen3.8-27b` | the same route as Sonnet |
| Subagent | `qwen3.8-27b` | the same route again |

Haiku, Sonnet and the subagent route share one entry because the Windows `heavy` group is
exclusive: a second Windows route would be swapped in and out against the tier running beside it.
`CLAUDE_CODE_SUBAGENT_MODEL` is therefore set from that route rather than left unset — the
annotation is what decides, so opting subagents back out is a config.yaml edit, not a per-host one.
