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
[llama-swap/config.yaml](../llama-swap/config.yaml):

| Flag / key | Value | Why |
|---|---|---|
| `--draft-kind` | `mtp` | Auto-detection from the adapter's `model_type` exists, but `--help` documents `mtp` as the Gemma 4 family; pinning it explicitly keeps the pairing from silently falling back to `dflash`. |
| `useModelName` (llama-swap) | the `--model` path | The **opposite** of the `laguna-s-2.1` quirk. mlx_vlm.server registers the loaded model under its `--model` path and resolves any other body `model` as an HF repo id (401). `${env.HOME}` does expand here. |
| `--max-num-seqs` | `3` | Matches `concurrencyLimit`, bounding peak memory at the server as well as the swapper. |
| *(no `--prompt-cache-*`)* | — | mlx-vlm does prefix caching automatically (APC); it has no equivalent flags. |

`jinja2` is a missing dependency in mlx-vlm's `requirements.txt`, so the installer adds it with
`--with jinja2`. Without it the server starts and passes `/health`, then fails **every**
completion with `apply_chat_template requires jinja2 to be installed`.

`qwen3.8-27b-uncensored-4bit` (orcarouter abliterated fine-tune) is deliberately unpaired: the
drafter was split from the stock checkpoint, and that weight drift would depress its acceptance
rate.

## Memory budget (Laguna S 2.1)

Weights ~67 GB resident. `sliding_window: 512` on 36/48 layers + `num_key_value_heads: 8` (GQA)
keeps a single request's KV cost to ~48 KB/token — even a maxed-out 262144-token request costs
only ~12.9 GB of active KV memory. Full derivation and incident history: [history.md](history.md).

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
Designed in `litellm-server/config.yaml`. The `model_name` fields use the `os.environ/` pattern;
the `litellm_params.model` values are hardcoded backend model names (env vars cannot be embedded
after a provider prefix). Defaults are documented here but are NOT embedded in config.yaml; they
are set in `.env.example` and resolved at process startup.

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
| `LITELLM_HAIKU_MODEL` | `devstral-small-2-24b` | Model routing key for the Haiku tier. Claude Code sends this value as the model name; LiteLLM matches it to the model_name entry in config.yaml, which routes to Devstral-Small-2-24B via llama-swap. |
| `LITELLM_SONNET_MODEL` | `qwen3-coder-30b-a3b` | Model routing key for the Sonnet tier. LiteLLM routes it to Qwen3-Coder-30B-A3B via llama-swap. |
| `LITELLM_FABLE_MODEL` | `deepseek-v4-flash` | Model routing key for the Fable tier — ds4 on the Mac. |
| `LITELLM_OPUS_MODEL` | `qwen3-next-80b-a3b-thinking` | Model routing key for the Opus tier — an `mlx_lm.server` backend on the Mac. `scripts/set-model.sh opus <key>` switches it among the Mac llama-swap entries and rewrites `litellm-server/config.yaml` to match, so no backend name is fixed here. The Mac backends are mutually exclusive, so they occupy separate tiers and `/model` is what switches tier. |
| `LITELLM_ANTHROPIC_BASE_URL` | (required for client) | The gateway endpoint the launcher points `ANTHROPIC_BASE_URL` at. The direct CCGW Proxy route is retired, so the launcher exits when this is unset. |
| `LITELLM_CLIENT_KEY` | (required for client) | Credential the launcher presents to the gateway. Same value as `LITELLM_MASTER_KEY`. `LITELLM_VIRTUAL_KEY` is accepted for one release as a deprecated alias, with a warning. |
| `CCGW_SUBAGENT_MODEL` | (empty) | Pins every subagent to one routing key. Empty — the default — lets each agent's frontmatter decide. |

### Client env vars

`ANTHROPIC_BASE_URL` points at the gateway (`https://<mac-lan-ip>:8445`); there is no second
path. The per-tier alias vars take the `LITELLM_*_MODEL` routing keys verbatim — the launchers
own no backend names, so an unknown key surfaces as a 400 from the gateway rather than as a
guess made client-side.

| Tier | Backend |
|---|---|
| Fable | ds4 (`deepseek-v4-flash`), Mac |
| Opus | the `.env`-selected Mac backend (`qwen3-next-80b-a3b-thinking`) |
| Sonnet | Qwen3-Coder-30B-A3B, Windows llama-swap |
| Haiku | Devstral-Small-2-24B, Windows llama-swap |

`CLAUDE_CODE_SUBAGENT_MODEL` is no longer set unconditionally. The gateway multiplexes across
four backends, so pinning subagents to the resident Mac model bought nothing and silently
overrode the model an agent definition asks for. Set `CCGW_SUBAGENT_MODEL` to opt back in.
