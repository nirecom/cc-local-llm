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

### FEATURE: PR #19 — feature/ds4ctl-launchd-logging (2026-07-18, e957a6d)
Background: Production-readiness for ds4 service management: unified control, launchd auto-start, log control, Ctrl-C fix (#18)
Changes: Unified ds4ctl.sh control command (start/stop/restart/status/logs/install/uninstall [proxy|server|all]); launchd LaunchAgent auto-start with KeepAlive=true for both services; DS4_LOG on/off toggle for stdout/stderr file logging (prevents disk write storms); DS4_SERVER_COLOR_LOG for ANSI terminal color on ds4-server output (files stay raw); proxy/server.py Ctrl-C traceback suppression; modular lib/ split (paths/colorize/lifecycle/launchd); existing ds4-proxy.sh/ds4-server.sh shrunk to thin backward-compatible wrappers. <!-- compose-doc-append-sentinel: branch=feature/ds4ctl-launchd-logging pr=#19 -->

### FEATURE: PR #22 — worktree-litellm-proxy (2026-07-21, 55f365e, #22)
Background: feat(litellm): add LiteLLM proxy configuration for Claude Code model routing
Changes: Added LiteLLM proxy configuration so Claude Code can route each model tier to a different backend (#20). Previously `code-ds4.cmd` sent every tier to DS4 Flash, whose coding quality is fine but whose prefill is slow — a bad fit for the many small Haiku/Sonnet-tier calls Claude Code makes. LiteLLM now fronts both backends on HTTPS :8445: Haiku and Sonnet tiers go to local models via llama-swap, and only the Opus tier reaches DS4 Flash. Client auth uses a scoped virtual key generated by `setup-litellm.cmd` rather than the master key. The database backend was changed from SQLite to a bundled loopback-only PostgreSQL container after SQLite proved unusable — LiteLLM's schema depends on PostgreSQL-only column types even though `DATABASE_URL` accepts any connection string. <!-- compose-doc-append-sentinel: branch=worktree-litellm-proxy pr=#22 -->

### FEATURE: PR #25 — fix/ccgw-rename (2026-07-31, 798e768e9ebaca0e2f81dd841f2967dcc45b950c, #25)
Background: fix(ccgw): rename client-side ds4- prefix to ccgw-, pin Compose project name (#24)
Changes: #24: client-side ds4- → ccgw- rename, Compose project name pinned to fix 401 volume mismatch <!-- compose-doc-append-sentinel: branch=fix/ccgw-rename pr=#25 -->

### FEATURE: PR #30 — chore/ds4ops-path-audit (2026-08-02, cf1b2a88b12c73419ca4a8e8ec2352a851f933a2, #30)
Background: Rename local clone directory and migrate remaining ds4-ops path references to cc-local-llm
Changes: #27: Renamed the local clone directory reference from `nirecom/ds4-ops` to `nirecom/cc-local-llm` following the GitHub repository rename, establishing `scripts/lib/root.sh` and `scripts/lib/paths.sh` as the single source of truth for repo-root derivation.;#28: Audited and migrated all remaining `ds4-ops` path string references across entrypoint scripts, tests, docs, `.env.example`, and `docker-compose.yml` to `cc-local-llm`; added a `DOTENV_FILE` hermetic-pin uniformity assertion to the test suite per a review-code-security finding. <!-- compose-doc-append-sentinel: branch=chore/ds4ops-path-audit pr=#30 -->

### FEATURE: PR #40 — feature/ds4-flags-34 (2026-08-11, e5aac7063bf813cd5d4027cbd9455087348ef634, #40)
Background: perf(ds4-server): multiplex live KV slot, halve continued KV writes
Changes: #34: ds4-server was measured over 0713 00:50:27 .. 0811 07:21:29 and showed two problems with one shared cause. Prompt processing ran 3054 times for 34.10 h, but the 349 runs over 60 s accounted for 30.67 h — 90% of all prefill time sat in a tenth of the requests. KV disk writes totalled 879.31 GiB, of which reason=evict was 475.00 GiB (54%) and reason=continued 325.94 GiB (37%). The link is the single live KV slot: all 548 live-cache misses were token-mismatch and 55.1% shared under 1000 tokens of common prefix, i.e. the slot had been handed to an unrelated request, which both forces the next cold prefill and writes the evicted checkpoint to disk. For scale, the 2026-07-06 entry records a 137 GB write storm as an incident; this configuration was writing several times that as a matter of routine. Applied to scripts/lib/lifecycle.sh: added --batched-session 2 and raised --kv-cache-continued-interval-tokens from 25000 to 50000. Added scripts/kvcache-report.sh (POSIX sh + BSD awk) to aggregate kvcache.log, and tests/feature-18-ds4ctl/test-server-flags.sh, which locks the full _ds4_cmd server flag string by exact equality. Corrected the launchd restart procedure in docs/ops.md: `ds4ctl install <svc>` alone is the restart (ds4_install already does write-plist -> unload -> load -w), and install must be run from the checkout the plist should point at, because _ds4_write_plist bakes $DS4_OPS_ROOT into ProgramArguments. Started at N=2 rather than N=3 because the premise for sizing N — roughly 1.3 GB per KV session — is a derived figure that has never been measured; --prefill-chunk, --quality on/off and --mixed-prefill-quantum were deliberately deferred to #37 so they do not confound the measurement of these two flags. Pre-cutover baseline (frozen copy of kvcache.log, range observed 0713 00:50:27 .. 0811 07:21:29): [1] prompt processing 3054 runs / 34.10 h, over-60s 349 runs / 30.67 h, avg 316.37 s; [2] live kv cache miss 548, 100% token-mismatch, common prefix under 1000 = 302 (55.1%); [3] kv cache stored TOTAL 1087 writes / 879.31 GiB — cold 238 / 73.36 GiB, continued 317 / 325.94 GiB, evict 527 / 475.00 GiB, shutdown 5 / 5.00 GiB. Cutover, before side (fixed): the old-flag window is `scripts/kvcache-report.sh --until "0811 07:21:29"`, that upper bound being the last timestamp written under the old flags. Cutover, after side (location, not value): the new flags only take effect once ds4-server is restarted from the main checkout after this PR merges — the restart cannot happen before commit, because _ds4_write_plist would bake the linked worktree path into the plist — so the after-side boundary is recorded as a comment on #37 immediately after the restart, and the after window is `scripts/kvcache-report.sh --since <that post-restart timestamp>`. kvcache.log is appended across restarts and never rotated, so --since / --until are the only way to separate the two regimes. <!-- compose-doc-append-sentinel: branch=feature/ds4-flags-34 pr=#40 -->
