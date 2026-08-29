# Architecture

What/Why of running ds4 as a Claude Code backend, at the design level. Concrete parameter
values and their rationale live in [tuning.md](tuning.md); procedures in [ops.md](ops.md);
host facts in [infrastructure.md](infrastructure.md); chronology in [history.md](history.md);
`.env` OS-conditional blocks in [env-conditional-blocks.md](env-conditional-blocks.md).

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

Claude Code injects volatile content into every system prompt: working directory, git status, platform, OS version, shell, auto-memory path, and `<system-reminder>` blocks. This volatile prefix changes on every request and breaks KV cache prefix continuity — the model must re-prefill from scratch each turn. The proxy normalizes four properties before forwarding to ds4, and clamps a fifth field that is unrelated to caching:

| Rule | What it does | Why |
|---|---|---|
| `move_dynamic_sections` | Removes volatile system-prompt lines and appends them to the first user message | System prompt prefix stays stable; KV cache hits on every subsequent turn |
| `normalize_date` | Collapses `Today's date is YYYY-MM-DDTHH:MM:SSZ` to `YYYY-MM-DD` | Time component changes every second; bare date is stable for one calendar day |
| `strip_system_reminders` | Removes `<system-reminder>…</system-reminder>` blocks | Session-scoped injections differ across turns; stripping them stabilises the prefix |
| `sort_tools` | Sorts the `tools` array by name | Tool order can vary; deterministic order gives the same prompt bytes across requests |
| `clamp_reasoning_effort` | Rewrites `reasoning_effort` to a value the target model's chat template accepts (`qwen3.8`: `high`/`max`→`xhigh`, `minimal`→`low`) | Qwen3.8's template raises on any other value, turning the request into an HTTP 500 with zero tokens returned. Keyed on the body's model name, not the tier, since which model backs which tier lives in `.env` |

Each rule is a pure function; all five are applied in order via `apply_all()`. The pipeline is transparent for unrecognized paths and non-JSON bodies.

The four cache rules only pay off where the backend actually keeps a prefix cache. That is true of ds4 (`--kv-disk-dir`) and **not** of the mlx-vlm-hosted tiers, whose prefix cache is off by default — see [tuning.md](tuning.md#prefix-caching-apc-is-off).

Two body shapes reach the proxy, because the gateway in front of it converts the Opus tier to the OpenAI shape while the Fable tier stays Anthropic. The shape is decided from the request path alone (`/v1/messages` → Anthropic, `/v1/chat/completions` and `/chat/completions` → OpenAI) and passed to every rule as a mandatory argument — never sniffed from the body, which the client controls, and never defaulted, since a forgotten argument would then normalize the wrong field set silently.

### Why token auth

ds4 has no authentication. The proxy adds an HMAC-based token gate (constant-time comparison via `hmac.compare_digest`) so that only a caller with the correct `CCGW_PROXY_AUTH_TOKEN` (sent by the gateway as `LITELLM_CCGW_PROXY_API_KEY`) can reach ds4. This matters whenever the proxy is reachable beyond loopback; auth prevents use by other devices on the network.

### Design choices

- **Pure asyncio, no framework** — SSE must flow through without buffering (`CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1`). Standard `asyncio` gives direct control over chunk relay.
- **httpx for upstream forwarding** — async, streaming, fits the asyncio model.
- **`--host 127.0.0.1` for ds4** — once the proxy handles LAN termination, ds4 no longer needs to listen on `0.0.0.0`. The proxy is the sole LAN-visible endpoint.
- **Tee logging** — optional request/response body logging for debugging; off by default, controlled by env var. Logs are pre- and post-normalization bodies; auth tokens are never written.

### Repository placement — may split out later

`proxy/` currently lives inside cc-local-llm rather than in its own repository. The coupling justifies co-location today: it shares the repo-root `.env` (its auth token must match the gateway's `LITELLM_CCGW_PROXY_API_KEY`, its listen port must match `LITELLM_CCGW_PROXY_URL`), the ops/tuning/infrastructure docs describe proxy, server, and client as one system, and it has no second consumer. The normalization rules are ds4-specific — they stabilise *this* model's KV-cache prefix — so the package is not yet a general-purpose library.

`proxy/` is nonetheless a self-contained Python package (its own `pyproject.toml` / `uv.lock`), so extraction stays cheap and can preserve history via `git filter-repo`. Split it into its own repository when any of these triggers fires:

1. A second consumer wants the proxy (another backend, or a client other than this ds4 setup).
2. The proxy needs an independent release / deploy / version lifecycle.
3. The normalization rules generalise beyond ds4.

Until then it stays here as a deliberate hold, not drift.

## Mac backend layer (llama-swap)

The Mac hosts two mutually-exclusive local models — ds4-server (DeepSeek V4 Flash) and
Laguna S 2.1 (`mlx_lm.server`, 4-bit NVFP4 MLX). Together their resident weights (~90.9 GB +
~72-90 GB) exceed the Mac's 128 GB unified memory, so at most one may be loaded at a time.

**Mac llama-swap** (`llama-swap/m5-max-128gb/config.yaml`, listen `127.0.0.1:18080`) is the CCGW Proxy's
sole upstream and the only service needed to manage this — it spawns and kills ds4-server /
`mlx_lm.server` on demand, keyed by the requested model name. Its **default** behavior (no
`groups:` block) already keeps exactly one model process loaded at a time, which is
sufficient here since neither backend needs to stay resident while the other runs — unlike a
judge+reasoner setup with an always-on small model, there is no asymmetry to encode with an
explicit group.

llama-swap routes by the model name in the request, but it does **not** convert protocols:
it forwards the body to whichever backend it spawned. ds4-server implements the Anthropic
`/v1/messages` shape itself, while Laguna's `mlx_lm.server` speaks only the OpenAI
`/v1/chat/completions` shape. Anthropic↔OpenAI conversion therefore has to happen upstream
of llama-swap, and the LiteLLM gateway is the single place that does it — one converter for
every tier rather than a second, ds4-specific one inside the proxy.

One llama-swap directive is needed for Laguna: `useModelName: default_model`.
`mlx_lm.server` resolves any body `model` other than `default_model` as a Hugging Face repo
path and answers 401, so llama-swap rewrites the forwarded body while still matching on the
`laguna-s-2.1` routing key. ds4-server accepts any model name, so its entry does not set it.

The Qwen3.8-27B family runs on a second MLX server, `mlx_vlm.server` — the only one that can
load its MTP speculative-decoding drafters. It speaks the same OpenAI shape, so nothing above
changes, but it inverts the directive: it registers the loaded model under its `--model` path,
so `useModelName` must carry that path rather than `default_model`. Rationale and the measured
MTP speedup: [tuning.md](tuning.md#mtp-speculative-decoding-qwen3827b).

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

## LiteLLM gateway layer (Mac, native)

A single LiteLLM process on <mac-host> (native, `uv`-installed, managed by
`serverctl`) is the one endpoint every client talks to. It terminates client TLS, converts
the Anthropic wire format where the backend needs it, and routes by model name to four
backends:

| Tier | Model name (routing key) | Backend | Protocol conversion |
|------|--------------------------|---------|---------------------|
| Haiku | `devstral-small-2-24b` | Devstral-Small-2-24B-Instruct-2512-IQ4_XS via llama-swap (<windows-host>, Caddy TLS front `:8443/v1`) | Anthropic to OpenAI |
| Sonnet | `qwen3-coder-30b-a3b` | Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL via llama-swap (<windows-host>, Caddy TLS front `:8443/v1`) | Anthropic to OpenAI |
| Fable | `deepseek-v4-flash` | CCGW Proxy (<mac-host>, :8443) | None (Anthropic passthrough) |
| Opus | `qwen3-next-80b-a3b-thinking` (`.env`-selected) | CCGW Proxy (<mac-host>, :8443) | Anthropic to OpenAI |

### Why the gateway moved off Windows/Docker

The gateway used to run as a Docker Compose stack (LiteLLM + PostgreSQL) on the Windows PC.
Two of its three backends are on the Mac, so every Fable/Opus request crossed the LAN twice;
the container also needed `host.docker.internal` plumbing, a CA bundle mounted at startup,
and a database whose only purpose was virtual-key persistence. Running it natively next to
the backends removes all four moving parts. The Windows PC keeps only its llama-swap, which
the gateway now reaches by LAN IP over HTTPS — through that host's existing Caddy front, which
terminates TLS on `:8443` and reverse-proxies to llama-swap's loopback-only `:18080`, so the
LAN hop is encrypted rather than plaintext. Caddy's certificate comes from the same mkcert root
CA as the CCGW Proxy's, so the gateway verifies it with the `SSL_CERT_FILE` trust it already
carries — no second CA to distribute. This is transport encryption only: like the CCGW Proxy hop
it is not mutual TLS, and unlike that hop it still presents no auth key, matching the
Haiku/Sonnet tiers' existing no-credential design.

### Why the Opus tier is converted, not passed through

Both Mac tiers reach the same CCGW Proxy, but the Opus backend is served by `mlx_lm.server`, which
speaks only the OpenAI shape. LiteLLM converts that tier with the same `openai/` provider
pattern already used for Haiku/Sonnet, so protocol conversion stays in exactly one component
(see [Mac backend layer](#mac-backend-layer-llama-swap)). The CCGW Proxy is a path-preserving
generic hop underneath: it appends the incoming path to its upstream verbatim and never
rewrites the model name.

Which OpenAI endpoint that conversion targets is a deliberate choice. Given an `openai/`
route, LiteLLM converts an incoming `/v1/messages` request to the Responses API by default,
and that endpoint is new enough that OpenAI-compatible servers do not all implement it:
llama.cpp answers it, `mlx_lm.server` returns a bare 404 that surfaces to the client as
"the model may not exist". `chat/completions` is the one endpoint every backend here
implements, so `use_chat_completions_url_for_anthropic_messages` pins all three `openai/`
tiers to it rather than leaving Haiku/Sonnet on a second, differently-shaped path. The
Fable tier is untouched by the setting — it stays on LiteLLM's native Anthropic
passthrough. This is also why the Opus tier needs its own `/v1`-suffixed base URL: the
`openai/` provider appends only `/chat/completions`, whereas the `anthropic/` Fable tier
appends `/v1/messages` to a bare origin.

Pinning those tiers to `chat/completions` also means they inherit its stricter parameter
set: Claude Code sends `reasoning_effort`, which the Responses API accepts but
`chat/completions` rejects for a non-reasoning model. Local weights ignore the field, so
the three `openai/` tiers set `drop_params` per route to discard it. The global default
stays strict, so an unsupported parameter anywhere else still surfaces as an error rather
than being silently discarded.

Fable and Opus deliberately land on the same CCGW Proxy but on different tiers. The Mac's two
backends cannot be resident together, so putting them on separate tiers makes `/model` the
switch — no extra routing key, no second base URL. The cost is a cold start on every switch,
which is inherent to the memory constraint rather than to this arrangement.

Which tier a session *starts* on is not the launcher's to decide. `code-ccgw.sh` / `.ps1` set
only the four `ANTHROPIC_DEFAULT_*_MODEL` aliases and never `ANTHROPIC_MODEL`, which outranks
`settings.json`'s `model` and would silently discard the tier chosen there. The startup tier
comes from `settings.json` or `--model`; `/model` switches it afterwards.

Haiku and Sonnet have no fallback: llama-swap on <windows-host> is the sole backend for
both tiers. A Mac (M4 Pro) fallback existed briefly during the 2026-08 migration but was
removed — its own failure modes (upstream model process crashing) made it an unreliable
safety net not worth the diagnostic overhead. A request fails outright if this PC's
llama-swap is offline.

### Why LiteLLM and not a custom router

LiteLLM is an established open-source proxy that supports Anthropic-to-OpenAI conversion
natively. Building a custom router would duplicate its model routing, auth, and protocol
translation -- a net cost with no benefit given LiteLLM's maturity.

### TLS termination

LiteLLM listens on HTTPS with an mkcert-signed certificate, sharing the same root CA
already used by the CCGW Proxy. Clients trust it via `NODE_EXTRA_CA_CERTS` pointing at
`<mkcert -CAROOT>/rootCA.pem` (the `CCGW_CA_CERT` value). No new CA setup is needed. On the
Mac itself the issuing CA is already trusted, so `CCGW_CA_CERT` may be left empty there.

The hop from the gateway to the CCGW Proxy is configurable in the same way: while the proxy
still terminates TLS (`CCGW_PROXY_TLS=on`), the gateway trusts its certificate through
`SSL_CERT_FILE`. Once both processes sit on the same Mac, the pair can be switched to plain
loopback HTTP — but only as a set, together with `CCGW_PROXY_HOST`,
`LITELLM_CCGW_PROXY_URL` and `LITELLM_CCGW_PROXY_OPENAI_URL`; changing some and not the
others leaves the gateway unable to connect.

### Master-key authentication

Auth is master-key only: `LITELLM_MASTER_KEY` is the gateway's credential, and clients
present the same value as `LITELLM_CLIENT_KEY`. The previous deployment issued scoped
virtual keys through `/key/generate`, which required a PostgreSQL database purely to
persist them. With a single trusted user on a LAN, that database bought nothing but
operational surface, so it is gone along with the container. Deleting the database is what
makes virtual keys impossible — not a policy choice layered on top of it.

The CCGW Proxy's own token auth is unchanged and independent: the gateway sends
`LITELLM_CCGW_PROXY_API_KEY`, which must equal the proxy's `CCGW_PROXY_AUTH_TOKEN`.

### One client route, no fallback

Clients used to have two ways in: the gateway, and a direct CCGW Proxy connection with its own
base URL and its own credential. Two paths for one request means two auth models to keep in
sync and two explanations for any failure, and the direct path could not reach the Haiku or
Sonnet tiers at all. It is retired: `LITELLM_ANTHROPIC_BASE_URL` and `LITELLM_CLIENT_KEY` are
required, and the launchers exit when either is missing. A placeholder default would only defer
the same failure to a 401 at request time, where it is much harder to read.

### Subagent pinning is opt-in

The launchers used to export `CLAUDE_CODE_SUBAGENT_MODEL` unconditionally, because the two Mac
backends are mutually exclusive: a subagent on the other backend would evict the model the main
session is using. With the gateway multiplexing across four backends on two machines, that
premise no longer holds for the Haiku and Sonnet tiers, while the unconditional export silently
overrode the model each agent definition's frontmatter asks for. `CCGW_SUBAGENT_MODEL` now makes
the pin opt-in, and it takes a routing key that is passed through untranslated.

### Two strategies update

The LiteLLM router is the implementation for the "Hybrid (router)" strategy, but with
the caveat that it does not preserve an Anthropic subscription (the Opus leg goes to
self-hosted DS4, not real Opus).

### Child-process-only environment injection

`code-ccgw.ps1` used to set routing values with `$env:`, mutating the invoking
PowerShell process itself; Windows has no `exec`, so those values outlived the launch
and leaked into whatever ran next in that shell, including unrelated cloud sessions
(issue #66). It now overlays a `$ChildEnv` block onto the spawned VS Code process's
`ProcessStartInfo.Environment` only — the parent's `$env:` is never written.

The child still inherits the rest of the parent's environment, so stripping only
`ANTHROPIC_API_KEY` was not enough: `CLAUDE_CODE_OAUTH_TOKEN`, the Bedrock/Vertex
switches and their AWS/GCP credentials, and `NODE_TLS_REJECT_UNAUTHORIZED` are cleared
too, so a real credential can't reach the local gateway's egress path. `code-ccgw.sh`
execs rather than spawning, but the same ambient class would otherwise reach the
replaced process unchanged, so it clears the same set.
