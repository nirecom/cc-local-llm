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

A Python asyncio reverse proxy (`proxy/`) sits between Claude Code (HTTPS client) and ds4 (plain HTTP on 127.0.0.1:8000). It serves three goals that cannot be achieved by env-var wiring alone.

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

ds4 has no authentication. The proxy adds an HMAC-based token gate (constant-time comparison via `hmac.compare_digest`) so that only Claude Code with the correct `DS4_API_KEY` can reach ds4. This matters because the proxy is exposed to the LAN via HTTPS rather than `0.0.0.0` plain HTTP; auth prevents use by other devices on the network.

### Design choices

- **Pure asyncio, no framework** — SSE must flow through without buffering (`CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1`). Standard `asyncio` gives direct control over chunk relay.
- **httpx for upstream forwarding** — async, streaming, fits the asyncio model.
- **`--host 127.0.0.1` for ds4** — once the proxy handles LAN termination, ds4 no longer needs to listen on `0.0.0.0`. The proxy is the sole LAN-visible endpoint.
- **Tee logging** — optional request/response body logging for debugging; off by default, controlled by env var. Logs are pre- and post-normalization bodies; auth tokens are never written.

### Repository placement — may split out later

`proxy/` currently lives inside ds4-ops rather than in its own repository. The coupling justifies co-location today: it shares the repo-root `.env` (its auth token must match the client's `DS4_API_KEY`, its listen port must match the client's base URL), the ops/tuning/infrastructure docs describe proxy, server, and client as one system, and it has no second consumer. The normalization rules are ds4-specific — they stabilise *this* model's KV-cache prefix — so the package is not yet a general-purpose library.

`proxy/` is nonetheless a self-contained Python package (its own `pyproject.toml` / `uv.lock`), so extraction stays cheap and can preserve history via `git filter-repo`. Split it into its own repository when any of these triggers fires:

1. A second consumer wants the proxy (another backend, or a client other than this ds4 setup).
2. The proxy needs an independent release / deploy / version lifecycle.
3. The normalization rules generalise beyond ds4.

Until then it stays here as a deliberate hold, not drift.
