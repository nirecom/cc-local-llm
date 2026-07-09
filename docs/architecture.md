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
