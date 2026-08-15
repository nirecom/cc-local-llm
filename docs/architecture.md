# Architecture

What/Why of running ds4 as a Claude Code backend, at the design level. Concrete parameter
values and their rationale live in [tuning.md](tuning.md); procedures in [ops.md](ops.md);
host facts in [infrastructure.md](infrastructure.md); chronology in [history.md](history.md).

## Goal

Use DeepSeek V4 Flash (via ds4-server) as a self-hosted stand-in for the Opus/Sonnet Claude
Code backend, primarily to run the agents-repo workflow without per-token API cost.

## Why a plain base-URL swap works

ds4-server implements the Anthropic `/v1/messages` endpoint natively and does not reject
unknown model names. Claude Code connects by pointing `ANTHROPIC_BASE_URL` at the ds4 host —
no protocol shim required.

## Thinking is controlled by model name, not effort

The design treats the requested **model name** as the thinking switch (a non-thinking alias
vs a thinking one), because ds4 flattens the `effort` scale and honours the model alias
instead. Everything downstream (per-tier splits, speed/quality trade) is built on that fact.
Mechanics and exact values: [tuning.md](tuning.md).

## Two strategies, chosen by whether real Opus is wanted

- **All-ds4 (no router)** — point every tier at ds4 and use Claude Code's alias-resolution
  env vars to give heavy-reasoning agents thinking and mechanical workers non-thinking. This
  gives a per-tier thinking split with zero extra infrastructure. Preferred default.
- **Hybrid (router)** — to send planning to *real* Anthropic Opus while implementation stays
  on ds4, a proxy (claude-code-router) is required. `ANTHROPIC_BASE_URL` is process-global,
  so env vars alone can rewrite the model name but cannot split the destination. The router
  is an extra always-on service and a critical-path dependency. It also **cannot preserve a
  fixed-price subscription**: Anthropic's 2026-02 legal-and-compliance terms bar OAuth tokens
  outside official clients, and server-side enforcement (2026-04) blocks OAuth-passthrough
  proxies (the known tools — LiteLLM header-forwarding, anthropic-max-router, meridian — were
  non-functional for this as of 2026-04). A
  router therefore bills the Anthropic leg as **metered API**, not subscription — take it only
  if metered planning is acceptable and ds4's thinking-on quality is judged insufficient.

Running native (subscription) Claude Code and ds4 side by side on one machine is a *process*
concern, not a routing one, and does not need a router: a bare `ANTHROPIC_BASE_URL` with a
credential already replaces the subscription, and VS Code shares one environment across all
windows of a user-data-dir. The two are kept apart by launching the ds4 window in an isolated
VS Code process (`--user-data-dir`). Procedure: [ops.md](ops.md#client-windows).

## Context window is a structural mismatch

Claude Code sizes auto-compaction from the model's nominal window (200K/1M for `claude-*`),
not ds4's real limit. ds4 does advertise its ceiling via `/v1/models`, but in a schema and
under model ids that an Anthropic client never consumes — so CC grows the conversation past
ds4's ceiling and ds4 rejects it. The fix is client-side alignment (told the real ceiling +
compact early), not a server change. Values: [tuning.md](tuning.md).

## Accuracy philosophy under the q2-q4 quant

The Mac's 128 GB caps the model at the 2-bit imatrix quant (the q4 build needs ≥256 GB), so
accuracy inside ds4 is bounded. The in-engine levers are exact-kernel mode and think depth;
both trade speed for accuracy. For maximum quality, route the hard work to real Opus rather
than push ds4 past its ceiling.

## Non-levers (evaluated and ruled out)

- **MTP / speculative decoding** — upstream calls it experimental with at most a slight speedup.
- **Distributed inference** — speeds prefill but slows decode and needs a second machine; wrong shape for interactive agent use.

## Reverse proxy layer

A Python asyncio reverse proxy (`proxy/`) sits between Claude Code (HTTPS client) and Mac
llama-swap (plain HTTP, 127.0.0.1:18080 — see
[Mac backend layer](#mac-backend-layer-llama-swap) below). It serves three goals that cannot
be achieved by env-var wiring alone.

### Why TLS termination

`ANTHROPIC_BASE_URL` is the only wiring point between Claude Code and ds4. Without TLS the full conversation — including prompts, tool calls, and model outputs — travels over plain HTTP on the local network. A self-signed mkcert certificate and `NODE_EXTRA_CA_CERTS` give full TLS without `NODE_TLS_REJECT_UNAUTHORIZED=0`. Procedures: [ops.md](ops.md).

### Why prompt normalization

Claude Code injects volatile content into every system prompt: working directory, git status, platform, OS version, shell, auto-memory path, and `<system-reminder>` blocks. This volatile prefix changes on every request and breaks KV cache prefix continuity — the model must re-prefill from scratch each turn. The proxy normalizes four properties before forwarding to ds4:

| Rule | What it does | Why |
|---|---|---|
| `move_dynamic_sections` | Removes volatile system-prompt lines and appends them to the first user message | System prompt prefix stays stable; KV cache hits on every subsequent turn |
| `normalize_date` | Collapses `Today's date is YYYY-MM-DDTHH:MM:SSZ` to `YYYY-MM-DD` | Time component changes every second; bare date is stable for one calendar day |
| `strip_system_reminders` | Removes `<system-reminder>…</system-reminder>` blocks | Session-scoped injections differ across turns; stripping them stabilises the prefix |
| `sort_tools` | Sorts the `tools` array by name | Tool order can vary; deterministic order gives the same prompt bytes across requests |

Each rule is a pure function; all four are applied in order via `apply_all()`. The pipeline is transparent for non-`/v1/messages` paths and non-JSON bodies.

### Why token auth

ds4 has no authentication. The proxy adds an HMAC-based token gate (constant-time comparison via `hmac.compare_digest`) so that only Claude Code with the correct `CCGW_API_KEY` can reach ds4. This matters because the proxy is exposed to the LAN via HTTPS rather than `0.0.0.0` plain HTTP; auth prevents use by other devices on the network.

### Design choices

- **Pure asyncio, no framework** — SSE must flow through without buffering (`CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1`). Standard `asyncio` gives direct control over chunk relay.
- **httpx for upstream forwarding** — async, streaming, fits the asyncio model.
- **`--host 127.0.0.1` for ds4** — once the proxy handles LAN termination, ds4 no longer needs to listen on `0.0.0.0`. The proxy is the sole LAN-visible endpoint.
- **Tee logging** — optional request/response body logging for debugging; off by default, controlled by env var. Logs are pre- and post-normalization bodies; auth tokens are never written.

### Repository placement — may split out later

`proxy/` currently lives inside cc-local-llm rather than in its own repository. The coupling justifies co-location today: it shares the repo-root `.env` (its auth token must match the client's `CCGW_API_KEY`, its listen port must match the client's base URL), the ops/tuning/infrastructure docs describe proxy, server, and client as one system, and it has no second consumer. The normalization rules are ds4-specific — they stabilise *this* model's KV-cache prefix — so the package is not yet a general-purpose library.

`proxy/` is nonetheless a self-contained Python package (its own `pyproject.toml` / `uv.lock`), so extraction stays cheap and can preserve history via `git filter-repo`. Split it into its own repository when any of these triggers fires:

1. A second consumer wants the proxy (another backend, or a client other than this ds4 setup).
2. The proxy needs an independent release / deploy / version lifecycle.
3. The normalization rules generalise beyond ds4.

Until then it stays here as a deliberate hold, not drift.

## Mac backend layer (llama-swap)

The Mac hosts two mutually-exclusive local models — ds4-server (DeepSeek V4 Flash) and
Laguna S 2.1 (`mlx_lm.server`, 4-bit NVFP4 MLX). Together their resident weights (~90.9 GB +
~72-90 GB) exceed the Mac's 128 GB unified memory, so at most one may be loaded at a time.

**Mac llama-swap** (`llama-swap/config.yaml`, listen `127.0.0.1:18080`) is the DS4 Proxy's
sole upstream and the only service needed to manage this — it spawns and kills ds4-server /
`mlx_lm.server` on demand, keyed by the requested model name. Its **default** behavior (no
`groups:` block) already keeps exactly one model process loaded at a time, which is
sufficient here since neither backend needs to stay resident while the other runs — unlike a
judge+reasoner setup with an always-on small model, there is no asymmetry to encode with an
explicit group.

An earlier draft of this design added a `litellm-server` hop between the DS4 Proxy and Mac
llama-swap, to do model-name routing and Anthropic↔OpenAI protocol conversion. That hop
turned out to be redundant: `mostlygeek/llama-swap` already speaks Anthropic `/v1/messages`
natively (translating to whatever the spawned backend needs) and already routes by the
model name in the request, so it needed no proxy in front of it. The DS4 Proxy forwards the
client's `x-api-key` header unchanged (see [Why token auth](#why-token-auth)), and Mac
llama-swap is loopback-only, so no extra auth hop was needed either — the DS4 Proxy is
already the sole gate. `litellm-server` was removed before ever being deployed.

### Why ds4-server is no longer a launchd-managed always-on service

Before Laguna, ds4-server ran as an always-on `launchd` `KeepAlive` service
(`com.nire.ds4-server.plist`) — the Mac only ever hosted one model, so permanent residency
was harmless. With Laguna added, permanent ds4-server residency would fight llama-swap for
control of the same process and defeat the exclusivity goal (launchd would keep ds4-server
resident even while a Laguna request is in flight). ds4-server's lifecycle is now owned
exclusively by Mac llama-swap; the KeepAlive LaunchAgent is retired, and llama-swap itself
becomes the always-on `launchd` service instead. `scripts/ds4-server.sh` (direct binary
invocation) remains available for manual foreground debugging only, deliberately excluded
from `serverctl`'s `all` target — see [ops.md](ops.md) for the exact retirement/install steps.

### Why no explicit llama-swap `groups:` block

`mostlygeek/llama-swap`'s `groups:` feature exists to model asymmetric cases (e.g. an
always-on small "judge" model plus an on-demand "reasoner" — the pattern used by the
`portable-llm-server` reference repo). ds4/Laguna is symmetric: both are large, both are
requested on demand, neither needs to stay warm while idle. The tool's default behavior
(exactly one model process alive, previous one killed before the next starts) already
implements that symmetric exclusivity, so an explicit `groups:` block would only add
config surface without changing behavior.

## LiteLLM routing layer (Windows)

A LiteLLM proxy on <windows-host> (Windows, Docker Desktop WSL2) routes Claude Code requests
by model name to three backends:

| Tier | Model name (routing key) | Backend | Protocol conversion |
|------|--------------------------|---------|---------------------|
| Haiku | `devstral-small-2-24b` | Devstral-Small-2-24B-Instruct-2512-IQ4_XS via llama-swap (<windows-host>, `host.docker.internal:18080/v1`) | Anthropic to OpenAI |
| Sonnet | `qwen3-coder-30b-a3b` | Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL via llama-swap (<windows-host>, `host.docker.internal:18080/v1`) | Anthropic to OpenAI |
| Opus | `deepseek-v4-flash` | DS4 Proxy (<mac-host>, :8443) | None (Anthropic passthrough) |

Haiku and Sonnet have no fallback: llama-swap on <windows-host> is the sole backend for
both tiers. A Mac (M4 Pro) fallback existed briefly during the 2026-08 migration but was
removed — its own failure modes (upstream model process crashing) made it an unreliable
safety net not worth the diagnostic overhead. A request fails outright if this PC's
llama-swap is offline.

### Why LiteLLM and not a custom router

LiteLLM is an established open-source proxy that supports Anthropic-to-OpenAI conversion
natively. Building a custom router would duplicate its model routing, virtual key auth,
and protocol translation -- a net cost with no benefit given LiteLLM's maturity.

### TLS termination

LiteLLM listens on HTTPS with an mkcert-signed certificate, sharing the same root CA
already used by the DS4 Proxy. The Windows client trusts it via `NODE_EXTRA_CA_CERTS`
pointing at `<mkcert -CAROOT>/rootCA.pem` (same `CCGW_CA_CERT` value). No new CA setup
is needed.

### CA cert trust for Opus route (container to <mac-host>)

The LiteLLM container connects to the DS4 Proxy (<mac-host>:8443) over HTTPS for Opus requests.
Inside the container, the mkcert root CA is mounted and appended to the system CA bundle
at startup (via the compose file's entrypoint). This ensures LiteLLM can verify the DS4
Proxy's TLS certificate. The same root CA file used for the Windows client (`CCGW_CA_CERT`)
is reused -- no separate CA setup.

### Virtual key authentication

LiteLLM uses virtual_key authentication. The `LITELLM_MASTER_KEY` is used for the admin
API and virtual key generation -- it is NEVER exposed to the client. A one-time setup
step (`scripts/setup-litellm.cmd`) creates a scoped virtual key from a randomly-generated
key (NOT the master key). Claude Code presents the virtual key as `ANTHROPIC_AUTH_TOKEN`
to authenticate with LiteLLM. The DS4 Proxy's own token auth is preserved for the Opus
route: LiteLLM forwards `LITELLM_OPUS_API_KEY` as the `x-api-key` header to the DS4 Proxy.

### Database for virtual key persistence

LiteLLM requires a database backend for key generation and verification. The compose file
configures PostgreSQL (`DATABASE_URL=postgresql://litellm:litellm@postgres:5432/litellm`) with a named
volume for persistence across restarts. 
### Host.docker.internal (Haiku/Sonnet route to this PC)

The Haiku and Sonnet backends run on llama-swap on <windows-host> itself -- the same
machine running the LiteLLM container. The container reaches it via
`host.docker.internal:18080`, resolved through the `extra_hosts: host-gateway` entry in
docker-compose.yml. The DS4 Proxy endpoint (Opus tier) is a separate machine (<mac-host>)
reached by LAN IP directly.

### Two strategies update

The LiteLLM router is the implementation for the "Hybrid (router)" strategy, but with
the caveat that it does not preserve an Anthropic subscription (the Opus leg goes to
self-hosted DS4, not real Opus).
