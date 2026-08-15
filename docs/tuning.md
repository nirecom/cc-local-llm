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
| `--host 127.0.0.1` | — | Loopback only; the proxy (scripts/ds4-proxy.sh) is the LAN endpoint. |

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
| `ANTHROPIC_BASE_URL` | `https://<mac-ip>:8443` | Route CC to the ds4 proxy (TLS). |
| `ANTHROPIC_AUTH_TOKEN` | must match `DS4_PROXY_AUTH_TOKEN` | The proxy now enforces auth; the token must match the proxy's secret. |
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

Read by `scripts/ds4-proxy.sh` (from the repo-root `.env`). Design: [architecture.md](architecture.md#reverse-proxy-layer).

| Var | Value | Why |
|---|---|---|
| `DS4_PROXY_PORT` | `8443` (default) | HTTPS listen port. Must match the port in the client's `ANTHROPIC_BASE_URL`. |
| `DS4_PROXY_UPSTREAM` | `http://127.0.0.1:8000` (default) | The ds4 backend the proxy forwards to. |
| `DS4_PROXY_AUTH_TOKEN` | required | Token every client request must present; must match the client's `CCGW_API_KEY`. The proxy refuses to start if unset. |
| `DS4_PROXY_CERT` / `DS4_PROXY_KEY` | `~/.config/ds4-proxy/cert.pem` / `key.pem` (defaults) | mkcert-generated TLS cert/key for the HTTPS listener. |
| `DS4_PROXY_TEE` | `off` (default) / `on` | When `on`, logs pre- and post-normalization request bodies for debugging. |
| `DS4_PROXY_LOG_DIR` | `~/Library/Caches/ds4-proxy/log` (default) | Where tee logs are written when `DS4_PROXY_TEE=on`. |

### LiteLLM env vars

Read by the LiteLLM container (passed through from `.env` via the compose file).
Designed in `litellm-client/config.yaml`. The `model_name` fields use `os.environ/` pattern;
the `litellm_params.model` values are hardcoded backend model names (env vars cannot
be embedded after a provider prefix). Defaults are documented here but are NOT
embedded in config.yaml; they are set in `.env.example` and resolved at container
startup.

| Var | Default | Why |
|-----|---------|-----|
| `LITELLM_MASTER_KEY` | (required) | Master key for LiteLLM admin API and virtual key generation. Generate with `openssl rand -hex 32`. Never expose to clients. |
| `LITELLM_PORT` | `8445` | HTTPS listen port. Must match the port in `ANTHROPIC_BASE_URL` when routing through LiteLLM. |
| `LITELLM_TLS_DIR` | (required) | Directory containing `cert.pem` and `key.pem` (mkcert-issued). Mounted into the container at `/app/certs`. No default -- user must set this in `.env`. |
| `LITELLM_CA_CERT_FILE` | (required for Opus) | Path to mkcert root CA `.pem` file. Mounted into the container so LiteLLM trusts the DS4 Proxy TLS cert. Same root CA as `CCGW_CA_CERT`. |
| `LITELLM_DB_URL` | `postgresql://litellm:litellm@postgres:5432/litellm` | Database URL for virtual key persistence. PostgreSQL via bundled postgres service. Leave unset to use the compose default. |
| `LITELLM_CONFIG_DIR` | `C:\git\cc-local-llm\litellm-client` | Config directory containing `config.yaml`. Renamed from `litellm\` -- an existing `.env` still pointing at the old path breaks the container's config mount. |
| `LITELLM_LLAMASWAP_URL` | `http://host.docker.internal:18080/v1` | llama-swap endpoint on this PC, shared by both Haiku and Sonnet tiers. Sole backend for these tiers -- no fallback. |
| `LITELLM_OPUS_URL` | `https://<mac-lan-ip>:8443` | DS4 Proxy endpoint for Opus tier. Uses <mac-host>'s LAN IP directly -- NOT host.docker.internal. |
| `LITELLM_OPUS_API_KEY` | `dsv4-local` | API key sent to DS4 Proxy for Opus route. Must match `CCGW_API_KEY`. |
| `LITELLM_HAIKU_MODEL` | `devstral-small-2-24b` | Model routing key for Haiku tier. Claude Code sends this value as the model name; LiteLLM matches it to the model_name entry in config.yaml, which routes to Devstral-Small-2-24B via llama-swap. |
| `LITELLM_SONNET_MODEL` | `qwen3-coder-30b-a3b` | Model routing key for Sonnet tier. Claude Code sends this value as the model name; LiteLLM routes it to Qwen3-Coder-30B-A3B via llama-swap. |
| `LITELLM_OPUS_MODEL` | `deepseek-v4-flash` | Model routing key for Opus tier. |
| `LITELLM_ANTHROPIC_BASE_URL` | (optional) | Override for `ANTHROPIC_BASE_URL` in code-ccgw.cmd. When unset, falls back to `CCGW_ANTHROPIC_BASE_URL` and ignores LITELLM_*_MODEL vars. |
| `LITELLM_VIRTUAL_KEY` | (required for client) | Scoped virtual key for client authentication with LiteLLM. Generated from a random key (not the master key). |

### Client env vars update

The `ANTHROPIC_BASE_URL` now points at LiteLLM (`https://<windows-host>:8445`) rather than directly at DS4 Proxy when `LITELLM_ANTHROPIC_BASE_URL` is set. The model
alias vars now use conditional logic: when `LITELLM_ANTHROPIC_BASE_URL` is set, they
use `LITELLM_HAIKU_MODEL` / `LITELLM_SONNET_MODEL` / `LITELLM_OPUS_MODEL`; otherwise
they fall back to `deepseek-chat` / `deepseek-v4-flash` / `deepseek-v4-flash`.
