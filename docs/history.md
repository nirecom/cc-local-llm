# History

Completed work with why (background, incidents, decisions). Ascending order, oldest first.
Parameter values live in [tuning.md](tuning.md); this file records how they were arrived at.

Each entry is tagged with the side it concerns:
- **[server]** — Mac `ds4-server` (start script / flags / host)
- **[client]** — the Windows client's Claude Code startup env

### [server] KV cache disk write storm — 137 GB (2026-07-06)
Background: ds4-server ran with `--kv-disk-space-mb 131072` (128 GB) and default continued
interval. Over a long remote session it wrote ~137 GB to disk; the single-threaded worker
blocked on `fwrite`, and the Mac froze (required a reboot).
Cause: each continued KV checkpoint rewrites the **whole live prefix** (not a delta), doubled
f16→f32, every ~10k tokens. Unbounded disk budget removed the per-file skip, so nothing
throttled it.
Fix: `--kv-cache-continued-interval-tokens 25000` (halve the rewrite frequency),
`--kv-cache-cold-max-tokens 90000`, `--kv-disk-space-mb 32768`. `--kv-disk-space-mb` bounds
single-file size + eviction but not total churn — the interval is the real lever.

### [server] KV cache relocated /tmp → ~/Library/Caches (2026-07-07)
Background: cache was on `/tmp` (lost on the reboot; and `/tmp` is Time Machine-*included*).
Changes: moved to `~/Library/Caches/ds4-server/kv` — persistent and TM-excluded by macOS
default, same SSD volume so no speed loss. Cache files are content-addressed (`<sha1>.kv`)
with no path index, so `mv` between same-volume paths is safe (stop the server first).

### [server] Sleep freeze — mistaken for a ds4 hang (2026-07-07)
Background: after hours of remote use the server went unresponsive; the client saw API
errors; ds4 logged multi-minute `finish=error error="client stream write failed"`.
Cause: **macOS idle sleep**, not ds4 — `pmset -g log` showed `Entering Sleep state` during
each hang. ds4's SSE keepalive detects a dead client, not the OS suspending the process.
Fix: wrap the server in `caffeinate -ism` in the start script (assertion tied to the process,
freed on exit). `-d` omitted so the display can still sleep (burn-in). The System Settings
"prevent sleeping when display is off" toggle was tried first but proved unreliable in
practice — an idle-sleep window still fired.

### [server] Context size raised for tokenizer mismatch: 204800 → 393216 (2026-07-07..08)
Background: CC repeatedly hit `400 ... context size is N tokens`, over by only tens of tokens
each time. Cause: CC counts tokens with Claude's tokenizer, ds4 with DeepSeek's — the same
text tokenizes differently, and a zero-margin `--ctx` cannot absorb the gap. (The client-side
half of this fix is the next entry.)
Changes: server `--ctx` 204800 → 225280 → 327680 → 393216, each adding margin. 393216 also
happens to be the Think Max gate. Memory verified: ~101 GB peak of 128 GB, ~27 GB headroom.
`1M` ruled out (~117 GB peak).

### [client] Context-window alignment env vars (2026-07-08)
Background: CC kept growing conversations past ds4's ceiling because it sizes auto-compaction
from the model's nominal window (200K/1M for `claude-*`), not ds4's `--ctx`. ds4 advertises
its limit via `/v1/models` but as OpenAI-schema `context_length` under `deepseek-*` ids,
which an Anthropic client never reads. (Server-side half is the previous entry.)
Changes: in the Windows client's startup env, set `CLAUDE_CODE_AUTO_COMPACT_WINDOW=393216` (real
ceiling) + `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75` (compact early, to leave room for ds4's higher
token count). `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` — proposed but does **not** exist
in the docs; not used.

### [server] --quality enabled (2026-07-08)
Background: seeking any accuracy gain under the q2-q4 quant without a router.
Changes: added `--quality` (exact kernels vs approximate) — the most direct in-engine accuracy
lever, accepting the tok/s cost. Effort tuning confirmed inert (collapses to HIGH); MTP and
distributed inference ruled out.
Note: this ops/decisions repo (`nirecom/ds4-ops`) was created the same day to share state between
the [server] and [client] sides.

### FEATURE: PR #5 — feature/ds4-client-env (2026-07-10, 4f0dedc0f09824b483179b196035f086bda16b89, #5)
Background: client: bundle Windows launcher, .env config, and compaction/isolation fixes
Changes: Brought the Windows client launcher under repo management as `scripts/claude-ds4.cmd` (migrated from an out-of-repo `claude-ds4.cmd`). Added the compaction-alignment env vars (`CLAUDE_CODE_AUTO_COMPACT_WINDOW=393216`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`) that were missing from the old wrapper, and `--user-data-dir "%LOCALAPPDATA%\vscode-ds4"` so the ds4 VS Code runs as a separate process and its env no longer bleeds into native (subscription) VS Code windows sharing the single-instance process. Real Mac LAN IP is not committed — the launcher loads a gitignored repo-root `.env` (added `.env.example` template + `.env` to `.gitignore`) for `DS4_ANTHROPIC_BASE_URL` / `DS4_API_KEY`; a shell-set value takes precedence over `.env`, and an unset base URL falls back to a `localhost` placeholder with a warning. Corrected the `docs/architecture.md` "Hybrid (router)" note: a subscription-preserving 1-session hybrid is not achievable — Anthropic's 2026-02 legal-and-compliance terms bar OAuth tokens outside official clients and 2026-04 server-side enforcement blocks OAuth-passthrough proxies, so a router bills the Anthropic leg as metered API; machine-level native/ds4 coexistence is handled by the wrapper's `--user-data-dir` process isolation instead. Updated `docs/ops.md` client section and README to match. <!-- compose-doc-append-sentinel: branch=feature/ds4-client-env pr=#5 -->

### FEATURE: PR #14 — feature/ds4-proxy (2026-07-11, 7d05d0536434ddd1c584c5b50fbfcc937d350e24, #14)
Background: feat(proxy): add ds4 reverse proxy with TLS termination, prompt normalization, and token auth
Changes: Implement ds4 reverse proxy (proxy/) using Python asyncio + httpx: TLS termination, token auth (hmac.compare_digest), and a four-rule prompt normalization pipeline (move dynamic sections, normalize date, strip system-reminders, sort tools) implemented as pure functions. Bind ds4 server to 127.0.0.1 and switch client URL to https, eliminating plaintext LAN traffic. 118 tests. (#13) <!-- compose-doc-append-sentinel: branch=feature/ds4-proxy pr=#14 -->
