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

### FEATURE: PR #19 — feature/serverctl-launchd-logging (2026-07-18, e957a6d)
Background: Production-readiness for ds4 service management: unified control, launchd auto-start, log control, Ctrl-C fix (#18)
Changes: Unified serverctl.sh control command (start/stop/restart/status/logs/install/uninstall [proxy|server|all]); launchd LaunchAgent auto-start with KeepAlive=true for both services; DS4_LOG on/off toggle for stdout/stderr file logging (prevents disk write storms); DS4_SERVER_COLOR_LOG for ANSI terminal color on ds4-server output (files stay raw); proxy/server.py Ctrl-C traceback suppression; modular lib/ split (paths/colorize/lifecycle/launchd); existing ds4-proxy.sh/ds4-server.sh shrunk to thin backward-compatible wrappers. <!-- compose-doc-append-sentinel: branch=feature/serverctl-launchd-logging pr=#19 -->

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
Changes: #34: ds4-server was measured over 0713 00:50:27 .. 0811 07:21:29 and showed two problems with one shared cause. Prompt processing ran 3054 times for 34.10 h, but the 349 runs over 60 s accounted for 30.67 h — 90% of all prefill time sat in a tenth of the requests. KV disk writes totalled 879.31 GiB, of which reason=evict was 475.00 GiB (54%) and reason=continued 325.94 GiB (37%). The link is the single live KV slot: all 548 live-cache misses were token-mismatch and 55.1% shared under 1000 tokens of common prefix, i.e. the slot had been handed to an unrelated request, which both forces the next cold prefill and writes the evicted checkpoint to disk. For scale, the 2026-07-06 entry records a 137 GB write storm as an incident; this configuration was writing several times that as a matter of routine. Applied to scripts/lib/lifecycle.sh: added --batched-session 2 and raised --kv-cache-continued-interval-tokens from 25000 to 50000. Added scripts/kvcache-report.sh (POSIX sh + BSD awk) to aggregate kvcache.log, and tests/feature-18-serverctl/test-server-flags.sh, which locks the full _ds4_cmd server flag string by exact equality. Corrected the launchd restart procedure in docs/ops.md: `serverctl install <svc>` alone is the restart (ds4_install already does write-plist -> unload -> load -w), and install must be run from the checkout the plist should point at, because _ds4_write_plist bakes $DS4_OPS_ROOT into ProgramArguments. Started at N=2 rather than N=3 because the premise for sizing N — roughly 1.3 GB per KV session — is a derived figure that has never been measured; --prefill-chunk, --quality on/off and --mixed-prefill-quantum were deliberately deferred to #37 so they do not confound the measurement of these two flags. Pre-cutover baseline (frozen copy of kvcache.log, range observed 0713 00:50:27 .. 0811 07:21:29): [1] prompt processing 3054 runs / 34.10 h, over-60s 349 runs / 30.67 h, avg 316.37 s; [2] live kv cache miss 548, 100% token-mismatch, common prefix under 1000 = 302 (55.1%); [3] kv cache stored TOTAL 1087 writes / 879.31 GiB — cold 238 / 73.36 GiB, continued 317 / 325.94 GiB, evict 527 / 475.00 GiB, shutdown 5 / 5.00 GiB. Cutover, before side (fixed): the old-flag window is `scripts/kvcache-report.sh --until "0811 07:21:29"`, that upper bound being the last timestamp written under the old flags. Cutover, after side (location, not value): the new flags only take effect once ds4-server is restarted from the main checkout after this PR merges — the restart cannot happen before commit, because _ds4_write_plist would bake the linked worktree path into the plist — so the after-side boundary is recorded as a comment on #37 immediately after the restart, and the after window is `scripts/kvcache-report.sh --since <that post-restart timestamp>`. kvcache.log is appended across restarts and never rotated, so --since / --until are the only way to separate the two regimes. <!-- compose-doc-append-sentinel: branch=feature/ds4-flags-34 pr=#40 -->

### FEATURE: Laguna S 2.1 added as a second Mac backend, managed by llama-swap (2026-08-12)
Background: The Mac's 128 GB unified memory can hold ds4-server (~90.9 GB resident) or Laguna S 2.1 (poolside 4-bit NVFP4 MLX export, ~72-90 GB resident) but not both, so a second Claude Code backend needed a component to keep them mutually exclusive rather than a second always-on service.
Changes: Added llama-swap/config.yaml: llama-swap (mostlygeek/llama-swap) manages both ds4-server and Laguna's mlx_lm.server as two model entries with no groups: block -- its default single-active-model behavior (kill the previous process before starting the next) is sufficient exclusivity on its own, since neither backend needs to stay warm while the other serves. ttl: 0 on both entries disables idle auto-unload, since swap-on-request is the only unload trigger either backend should see. An earlier draft added a litellm-server hop between the DS4 Proxy and Mac llama-swap for model-name routing and Anthropic<->OpenAI translation; this was caught as redundant before being deployed, since llama-swap already does both natively, and was deleted -- DS4_PROXY_UPSTREAM points directly at Mac llama-swap (127.0.0.1:18080). Retired ds4-server's always-on launchd KeepAlive service (com.nire.ds4-server.plist): llama-swap now owns its full start/stop lifecycle exclusively, so serverctl's server target is manual-debug-only and excluded from all/install; Mac llama-swap itself became the new always-on LaunchAgent instead, via a renamed scripts/llama-swap.sh wrapper (previously ds4-llama-swap.sh -- renamed to drop the ds4- prefix from a tool that isn't ds4-specific) and a new _ds4_wrapper_script indirection in scripts/lib/paths.sh so launchd.sh no longer hardcodes the ds4-<svc>.sh naming pattern. Added install.sh (Mac) and install.ps1 (Windows), matching the nirecom/agents installer format (top-level dispatcher + install/<platform>/ per-tool scripts): install.sh installs llama-swap (brew) and mlx-lm from git main (Laguna's architecture support predates any PyPI release) via install/mac/{llama-swap,mlx-lm}.sh; install.ps1 installs Docker Desktop and mkcert via install/win/{docker-desktop,mkcert}.ps1. Both scaffold .env from .env.example. Added the laguna-s-2.1 tier to litellm-client/config.yaml (renamed from litellm/ earlier) alongside the existing deepseek-v4-flash tier, both routed through the same DS4 Proxy URL and distinguished by model name.

### FEATURE: LiteLLM gateway consolidated onto the Mac; Laguna S 2.1 fronted by the model-swap layer (2026-08-15)
Background: The LiteLLM gateway ran as a Docker Compose stack (LiteLLM + PostgreSQL) on the Windows PC, and issue #41 collected the consequences. The Opus tier reached Laguna S 2.1 through a route that assumed the backend spoke Anthropic natively -- it does not, since mlx_lm.server serves only the OpenAI shape -- so that tier returned protocol errors. scripts/code-ccgw.sh and .ps1 pinned every subagent to one model unconditionally, silently overriding the model each agent definition's frontmatter asks for. A second, direct DS4 Proxy client route existed alongside the gateway route, so the same request could take two paths under two different auth models. The false premise was recorded in this file's 2026-08-12 entry and in proxy/server.py's header comment: llama-swap does not convert between the Anthropic and OpenAI wire formats, and both statements are corrected by this change.
Changes: Protocol conversion is now owned solely by LiteLLM (CPR-SSOT). The Opus tier uses the same openai/ provider pattern as the haiku and sonnet tiers, and the body model rewrite mlx_lm.server needs is llama-swap's useModelName: default_model rather than a proxy-side rewrite table -- any other value is treated as a HuggingFace repo path and 401s. litellm-client/ was renamed to litellm-server/, and the gateway now runs as a native uv-installed process on the Mac: the Compose file, the PostgreSQL service, scripts/litellm-start.ps1, scripts/setup-litellm.ps1, scripts/generate-litellm-key.ps1, install/win/docker-desktop.ps1 and install/linux/docker.sh are deleted, install/mac/litellm.sh is added, and install.ps1 is client-only. Auth is master-key only: deleting the database is what removes virtual keys, not a policy layered on top, so LITELLM_CLIENT_KEY is the client credential and LITELLM_VIRTUAL_KEY is accepted for one release with a warning. serverctl gained litellm as a fourth native service (all = proxy + llama-swap + litellm) with a directory-qualified pgrep pattern, a credential guard that refuses to launch a misconfigured gateway rather than starting one that will 401, and a launchd minimal-PATH generalized from uv-only to uv/llama-swap/litellm via command -v. The DS4 Proxy is demoted to a path-preserving generic hop: _normalize_shape(method, path) classifies requests by path only, never by sniffing the body, and proxy/normalize.py takes a mandatory shape keyword on every rule -- the Anthropic path keeps its original strict raise-on-malformed behavior while the OpenAI path is tolerant. DS4_PROXY_TLS and DS4_PROXY_HOST make the proxy hop reversible; only the literal off disables TLS, so a typo fails towards an encrypted listener rather than plaintext on a LAN-visible bind. Subagent pinning became opt-in via CCGW_SUBAGENT_MODEL, and the direct non-gateway client route was retired outright -- an unset base URL or credential now exits with a docs pointer instead of falling back to a placeholder that would resurface later as a confusing 401.

### INCIDENT: #1: llama-swap: fix Laguna S 2.1 429s and mlx_lm.server 116GB memory growth (2026-08-16)
Cause: laguna-s-2.1 had no concurrencyLimit set in llama-swap/config.yaml, so llama-swap fell back to its internal default of 10 parallel requests; Claude Code's multi-agent fan-out exceeded that and got 429s. Separately, mlx_lm.server wires up to Metal's max_recommended_working_set_size (~116GB on this M5 Max/128GB Mac) via mx.set_wired_limit(), and mlx_lm's LRUPromptCache defaults to an unbounded byte cap (max_bytes=1<<63) unless --prompt-cache-bytes is passed. With Laguna's ~67GB weights resident and no cache byte cap, concurrent long-context conversations grew the KV prompt cache all the way to the 116GB wired ceiling, nearly exhausting the Mac's RAM (observed: python3.14 process at 116GB RSS).
Fix: Added concurrencyLimit: 4 and --prompt-cache-bytes 24GB --prompt-cache-size 6 to the laguna-s-2.1 entry in llama-swap/config.yaml. 24GB was derived from this machine's memory budget (67GB weights + 24GB cache = 91GB, leaving ~25GB headroom below the 116GB wired ceiling) and cross-checked against mlx-lm upstream issue #1390, where an unbounded prompt cache in the 23-26GB range caused a Metal OOM on a smaller 48GB Mac. concurrencyLimit: 4 bounds worst-case simultaneous active-generation memory below the previous implicit default of 10. Restarted llama-swap via scripts/serverctl.sh; verified new process args carry both flags and that concurrencyLimit is enforced (4/6 concurrent requests returned 200, 2 returned 429). See nirecom/cc-local-llm#49.

### CONFIG: llama-swap: raise Laguna S 2.1 prompt-cache headroom and concurrencyLimit (2026-08-16)
Background: After the 429/116GB memory incident fix (concurrencyLimit: 4, --prompt-cache-bytes 24GB, see INCIDENT #1 above and nirecom/cc-local-llm#49), reviewed mlx_lm.server's actual source to size these more precisely instead of leaving conservative first-pass values in place. Two things changed the analysis: (1) mlx_lm/server.py's trim_to(n_bytes=prompt_cache_bytes - active_bytes) clamps at 0, so --prompt-cache-bytes only ever shrinks the *idle* LRU cache to make room for active generation -- it never blocks active memory, so raising it cannot worsen the worst case, only improve idle-cache retention under light load. (2) Laguna's own config.json shows only 12 of 48 layers are full_attention (the other 36 use sliding_window: 512, capped regardless of context length) with num_key_value_heads: 8 (GQA), working out to ~48KB/token of full-attention KV -- so even a maxed-out 262144-token request costs only ~12.9GB of active KV memory, well below what was assumed when the emergency fix was sized.
Changes: llama-swap/config.yaml laguna-s-2.1: --prompt-cache-bytes 24GB -> 40GB (weights ~67GB + 40GB idle cache = ~107GB, ~9GB headroom below the ~116GB wired ceiling even fully packed and idle), --prompt-cache-size 6 -> 10 (mlx-lm's own default, so typical shorter conversations aren't evicted by entry count before the byte cap), concurrencyLimit: 4 -> 5 (one conservative step; a residual worst-case risk remains if all concurrent slots hit near-max context simultaneously, accepted as low-probability given typical multi-agent fan-out context sizes -- this existed at concurrencyLimit: 4 too and is not something any mlx-lm flag fully closes). Restarted llama-swap via scripts/serverctl.sh; verified new process args, verified concurrencyLimit: 5 concurrent-request test (5x200, 2x429 on 7 concurrent requests), and confirmed live prompt-cache visibility via llama-swap's /logs/stream/laguna-s-2.1 endpoint (mlx_lm.server logs 'Prompt Cache: N sequences, X.XX GB' on each batched request; not persisted to llama-swap.log itself, only readable live via that endpoint).

### REFACTOR: Rename ds4-proxy to ccgw-proxy and the shared DS4_* env vars to CCGW_* (2026-08-16)
Background: The reverse proxy in proxy/ was named ds4-proxy when DeepSeek V4 Flash (ds4) was its only backend. Since the Laguna S 2.1 tier was added, the same proxy also fronts mlx_lm.server through Mac llama-swap, and it has been demoted to a path-preserving generic hop that never inspects the model. The ds4- name therefore describes only one of its two backends and misleads anyone reading the config: DS4_PROXY_UPSTREAM does not point at ds4, and LITELLM_DS4_PROXY_OPENAI_URL is the Laguna route. The shared lifecycle/logging variables (DS4_LOG, DS4_RUN_DIR, DS4_OPS_ROOT, DS4_SCRIPT_DIR) had the same problem one level up: they govern every service serverctl manages, not the ds4 backend. Renamed to the gateway's own name, ccgw (Claude Code GateWay), which is already the repo-wide prefix for the cross-service settings (CCGW_CA_CERT, CCGW_SUBAGENT_MODEL, code-ccgw.sh). See nirecom/cc-local-llm#51.
Changes: Hard cutover with no compatibility shims and no alias fallbacks -- a stale .env now fails loudly at startup instead of silently falling back, which is the intended behaviour for a single-operator deployment where a half-renamed config is worse than a clear error. Renamed: scripts/ds4-proxy.sh -> scripts/ccgw-proxy.sh (git mv); DS4_PROXY_{AUTH_TOKEN,UPSTREAM,HOST,PORT,TLS,CERT,KEY,TEE,LOG_DIR} -> CCGW_PROXY_*; LITELLM_DS4_PROXY_{URL,OPENAI_URL,and the LiteLLM key var} -> LITELLM_CCGW_PROXY_*; DS4_{LOG,LOG_COLOR,LOG_TAIL_LINES,RUN_DIR,OPS_ROOT,SCRIPT_DIR} -> CCGW_*.
Launchd labels com.nire.ds4-{proxy,litellm,llama-swap} -> com.nire.ccgw-{proxy,litellm,llama-swap}; on-disk paths ~/.config/ds4-proxy/, ~/Library/Logs/ds4-proxy/ and ~/Library/Caches/ds4-proxy/ -> ccgw-proxy; pyproject name ds4-proxy -> ccgw-proxy (uv.lock regenerated). _ds4_plist_label changed from a flat com.nire.ds4-<svc> concatenation to a per-service case, because server is the one label that must keep its ds4- prefix. Deliberately unchanged: DS4_SERVER_HOST, DS4_SERVER_ROOT, DS4_SERVER_COLOR_LOG, DS4_THINK_MAX_MIN_CONTEXT, scripts/ds4-server.sh, com.nire.ds4-server, and every _ds4_* / ds4_* shell function name -- the first group genuinely describes the DeepSeek V4 Flash backend, and the internal function names are a separate rename tracked on their own issue. Guarded by tests/ccgw-naming/test_no_legacy_names.py, which scans every tracked file for the legacy tokens and asserts the new gateway env vars are present in litellm-server/config.yaml. Requires a manual reinstall of the LaunchAgents after merge (serverctl install all): the old com.nire.ds4-{proxy,litellm,llama-swap} plists are not removed by the rename and must be unloaded by hand.

### FEATURE: PR #52 — feature/51-ds4-proxy-ds4-ccgw (2026-08-16, 96132f7099f01074a3264eae7a3648106082dbd3, #52)
Background: PR #52 merged on 2026-08-16.
Changes: Renamed `ds4-proxy` to `ccgw-proxy` and the shared `DS4_*` env vars to `CCGW_*` across scripts, launchd labels, config, and docs, since the proxy component now also fronts Laguna and the old DS4-specific name was misleading; `DS4_SERVER_*`/`ds4-server` was excluded (it accurately names the DeepSeek V4 backend) and `_ds4_*` internal shell function prefixes were deferred to a follow-up issue (#51) <!-- compose-doc-append-sentinel: branch=feature/51-ds4-proxy-ds4-ccgw pr=#52 -->

### FEATURE: PR #57 — feature/56-cc-local-llm (2026-08-18, ffdd8e882338b151f3a22e8f71d8a637f0359997, #57)
Background: feature/56 cc local llm
Changes: #56: Added native `#@if windows` / `#@if posix` / `#@endif` OS-conditional-block marker support to cc-local-llm's `.env` loading — the POSIX (`scripts/lib/load-dotenv.sh`) and PowerShell (`scripts/code-ccgw.ps1`) loaders now filter blocks by platform token, so a single `.env` (shared across machines via a symlink to a centrally-managed private dotfiles store) can carry both Windows and macOS/Linux values. Added SSOT spec `docs/env-conditional-blocks.md`; `.env.example`'s `CCGW_CA_CERT` entry converted to marker form as the reference example. <!-- compose-doc-append-sentinel: branch=feature/56-cc-local-llm pr=#57 -->

### BUGFIX: ccgw model-routing keys always come from .env (stale shell value was overriding the opus tier on Windows) (2026-08-22)

Background: The Windows launcher (scripts/code-ccgw.ps1) loaded .env with 'shell value wins over .env', so a stale inherited LITELLM_OPUS_MODEL left in the launching shell could override .env's correct value. On this machine .env carried qwen3-next-80b-a3b-thinking but the /model opus tier showed qwen3-coder-next-80b-a3b, diverging from the Mac/gateway side which used the .env value.

Changes: Added an opt-in DOTENV_FORCE_KEYS (space-separated, NON-exported) to scripts/lib/load-dotenv.sh so .env always wins for listed keys; scripts/code-ccgw.sh sets it for the 5 model-routing keys (LITELLM_HAIKU_MODEL, LITELLM_SONNET_MODEL, LITELLM_FABLE_MODEL, LITELLM_OPUS_MODEL, CCGW_SUBAGENT_MODEL) and scripts/code-ccgw.ps1 mirrors it with $ModelRoutingKeys. Loaders that never set the list keep the default shell-value-wins behavior. Also fixed a pre-existing harness bug in tests/feature-18-serverctl/test-load-dotenv-os-blocks.sh: run_dotenv expanded $@ without shifting away $1/$2, leaking the dotenv-file/stub-dir into env's positional args so every case produced an empty env dump; added cases 14/15 locking the DOTENV_FORCE_KEYS opt-in behavior.

Test gap: no test asserted the model-routing keys take .env over a stale shell value; the loader test's run_dotenv also had an unshifted $@ that made all its cases fail with an empty dump

### FEATURE: [win-server] nirecom/llama-swap merged into this repo, absorbing its optimization history (2026-08-29)
Background: the Windows llama-swap host had its own private repo (`nirecom/llama-swap`), holding the
config, the launch tooling and an `optimization-history.md` that nothing else could see. That
split meant the two halves of one system — the Mac gateway and the Windows backend it routes
Haiku/Sonnet to — were documented in two places, and the tuning rationale for the backend was
invisible from the repo an operator actually reads. Merging it here makes one repository the
whole picture. Because this repo is PUBLIC, everything carried over was redacted first: private
tokens, keys and machine identifiers were stripped or replaced with placeholders before the
first commit, and the outbound scan gates each one. The source repo was deliberately kept —
made private and archived as `nirecom/llama-swap-archived` rather than deleted — because the
verbatim pre-redaction history is the only record of what the redaction removed, and a deleted
repo cannot answer a later "was this ever public?" question.
Changes: merged in six commits, each independently reviewable: (1) `.gitignore` + `LICENSE`,
(2) `llama-swap/rtx5070ti-128gb/{config.yaml,model-annotations.yaml}`, (3) `CLAUDE.md` +
`llama-swap/README.md`, (4) the Windows server installer, (5) documentation (this entry), (6)
close-out.

Decisions taken along the way:

- **Annotation split, 3 removed / 3 retained.** Three model keys were dropped from
  `config.yaml` (`gemma-3-4b-it-Q4_K_M`, `Mistral-22B-v0.2-Q4_K_S`, `Qwen3-8B-Q4_K_M`) and
  three annotations were kept for models no longer configured, because the judgement behind
  them is still live. The result is an 11-model / 14-annotation asymmetry on the Windows side,
  against the Mac side's 1:1. That asymmetry is intentional, so a new rule was written into
  `CLAUDE.md` to keep it from reading as rot: an annotation may outlive its key only with a
  `retained:` line naming the decision it will be consulted for, and an annotation nobody can
  write that line for is deleted with the key.
- **`install.ps1` grew a role matrix** (`-Server` / `-Client` / `-All` / `-Uninstall`, plus
  `-LanIp`), with no switch still meaning `-Client` so the one-word invocation in existing
  notes keeps working. The server role installs its own dependencies via winget (mkcert, NSSM,
  Caddy), idempotently.
- **Certificates moved outside the repo.** They are host state, not source, and the leaf now
  MUST carry the host's LAN IPv4 in its SAN list — a loopback-only cert terminates TLS happily
  while every LAN client refuses the connection, which is a failure with no error message on
  the server side.
- **Log rotation was added to both NSSM services.** Motivation was concrete: a 125 MB service
  log found on the host. The threshold is an installer default, not a tuning decision, which is
  why it is recorded here and not in `tuning.md`.
- **Native-command exit-code policy was centralised into `Invoke-Native`** (`install/win/lib/native.ps1`).
  Each call site had been deciding for itself which non-zero codes were survivable (`sc query`'s
  1060, `taskkill`'s 128); one helper now owns that, so a forgotten check cannot silently pass.
- **The llama-swap runtime directory was deliberately left outside the checkout** (path in
  `infrastructure.md`). `llama-swap.exe` is an upstream-distributed binary and the NSSM logs are
  host state; neither belongs in git. The config, by contrast, is a checked-out file read in
  place — the old design that kept `config.yaml` beside the exe is dead, and
  `llama-swap-service.ps1` now takes all three paths as mandatory parameters so no default can
  quietly resurrect the co-location assumption.
- **LICENSE**: MIT, attributed to the repository owner, matching the pre-existing public posture
  of this repo rather than the private source repo's absence of one.
- **A rehearsal backup copy of the source repo was deleted** once the real cutover completed and
  the archived remote was confirmed reachable; keeping a third unredacted copy on disk was the
  larger risk.

Absorbed from the source repo's `optimization-history.md` (all five dated sections), plus
`legacy-launch-cmd.md` and `legacy-manual-tuning.md`, both now obsolete. That file was the only
record of these measurements and does not survive the merge, so it is transcribed here in full.

**2026/02/21 — initial optimizer run.**

| model | tok/s | threads | batch | ubatch | ngl | FA |
|---|---|---|---|---|---|---|
| (8 model rows) | (not individually recorded — see the 2026/04/05 consolidated table for the superseding measurement) | | | | | |

The per-model figures of this first run were not preserved in the extraction; the run's shape
(8 models, the seven columns above) is recorded so the later tables can be read as supersessions
rather than as the first data point.

**2026/02/22 — re-run after adding nemotron.**

| model | tok/s | threads | batch | ubatch | ngl | FA |
|---|---|---|---|---|---|---|
| (9 model rows — the 02/21 set plus the newly added nemotron) | (not individually recorded — see the 2026/04/05 consolidated table for the superseding measurement) | | | | | |

`Qwen3-32B-Q4_K_M` is already `(pending)` here.

**2026/04/05 — consolidated table (11 models).** The numbers below are the surviving ones; ✓/✗
in the FA column mean flash-attention on/off, `—` means not recorded. One further row of the
original eleven was not preserved in the extraction.

| model | tok/s | FA | notes |
|---|---|---|---|
| `Qwen3.5-27B-IQ3_M` | 47.4 | ✓ | the chosen quant |
| `Qwen3.5-27B-Q4_K_M` | 14.6 | ✗ | rejected — this row is the basis of the 16 GB-VRAM Q4-avoidance decision |
| `Llama-3-ELYZA-JP-8B` | 146.4 | — | later re-measured at 144.3 |
| `Lumimaid-v0.2-12B` | 97.6 | — | later re-measured at 96.5 |
| `Nemotron` | 77.2 | — | later re-measured at 74.4 |
| `Qwen2.5-7B-Instruct-Q4_K_M` | 149.2 | — | at the optimizer's suggested `-ngl 136` — **deliberately not adopted**, see below |
| `gemma-3-4b-it-Q4_K_M` | 201.2 | — | key removed from config.yaml in commit 2 of this migration |
| `Mistral-22B-v0.2-Q4_K_S` | 57.9 | — | key removed in commit 2 |
| `Qwen3-8B-Q4_K_M` | (pending) | — | never benchmarked; key removed in commit 2 |
| `Qwen3-32B-Q4_K_M` | (pending) | — | never benchmarked, pending in both this table and the 02/22 one, never resolved; no annotation survives for it either |

The single most important fact in this table is the one the numbers do not show:
**`Qwen2.5-7B-Instruct-Q4_K_M`'s optimizer suggestion was rejected on purpose.** The optimizer
proposed `-ngl 136` for 149.2 tok/s; the deployed config runs it `-ngl 0 --device none` instead.
It is the always-resident judge in the `forever` group, so occupying zero GPU memory outranks its
own throughput — a faster judge that evicts a working model is a net loss. Anyone reading the
optimizer output later would otherwise "fix" this config back to a slower system.

`Qwen3-8B-Q4_K_M` was confirmed genuinely unused before removal, by cross-checking the host's
other stacks: the langchain-stack "judge" role actually runs `Qwen2.5-7B-Instruct-Q4_K_M`, not
this model; Qwen3-8B had been rejected as unsuitable for RAGAS; and in another internal stack it was
only a temporary onboarding scaffold.

**2026/08/27 — `Qwen3.8-27B-UD-IQ4_XS`, context scaling.**

| context | tok/s | VRAM spill |
|---|---|---|
| 32K | 79–82 | ~211 MiB |
| 64K | 55.4 | ~873 MiB |

MTP draft acceptance rate 0.845 (125/148 drafts accepted, mean accepted length 2.69). Context
growth slope ≈ 30.7 KiB/token. Built on llama.cpp b1881-3653e6d6d, running the external
`froggeric v22.4` chat template. Coding-task accuracy was **not** verified at this point — the
figures are throughput only.

**2026/08/28 — IQ4_XS replaced by UD-Q3_K_XL.**

| quant / context | tok/s | VRAM spill | VRAM used |
|---|---|---|---|
| UD-IQ4_XS @ 32K | 79–82 | ~211 MiB | — |
| UD-IQ4_XS @ 64K | 55.4 | ~873 MiB | — |
| UD-Q3_K_XL @ 64K | 90.6 | ~305 MiB | 12,537 MiB |

The same 64K context, a few hundred MiB less spill, and throughput rises from 55.4 to 90.6 tok/s.
This is the concrete example behind the claim in `tuning.md` that at this VRAM budget a
hundreds-of-MiB spill difference produces a tens-of-percent throughput difference.

**Absorbed from `legacy-launch-cmd.md`:** before NSSM-based service management, models were
launched from hand-written command lines. When NSSM was adopted, `--watch-config` was added to
the launch arguments so a config edit takes effect without a manual restart; that argument is now
produced by `Get-LlamaSwapNssmSettings` in `install/win/lib/nssm-args.ps1`, and the file
describing the manual launch has no readers left.

**Absorbed from `legacy-manual-tuning.md`:** before the optimizer tool existed, tuning was done
by hand through a dedicated cmd/ini file. Some of those hand-tuned settings reportedly beat what
the automated optimizer later produced. Recorded as a historical observation only — no
measurement survives to act on, so it is not a claim that hand-tuning is better.

### SECURITY: Windows installer security review: Caddy bind scope and NSSM LocalSystem accepted as known risk (2026-08-29)
Background: Review-code-security round 1 (session da9ea40f-3775-4662-abc9-7b33bb4df317) surfaced two deployment-scope risks in the Windows server installer: (1) every Caddy site block in install/win/Caddyfile.template binds unauthenticated on all interfaces, some reachable via Cloudflare Tunnel; (2) the llama-swap and llama-swap-caddy NSSM services run as LocalSystem and reference config files inside the git checkout with --watch-config, so write access to the checkout is effectively SYSTEM-level code execution.
Changes: Both accepted as known risk for the current deployment scope: a private, single-operator home LAN with no untrusted or external clients. Hardening (authentication / bind-scope restriction for Caddy; dedicated service account and checkout/config separation with ACLs for NSSM) is deferred until the threat model changes (e.g. additional users, external exposure).

### FEATURE: PR #87 — feature/86-nirecom-llama-swap-cc-local (2026-08-29, 082e659811368a860c6e688089fdf8fbf175a205, #87)
Background: feat(win-server): add Windows host support, merge in the internal-only companion repo
Changes: FEATURE: [win-server] nirecom/llama-swap (private repo) merged into cc-local-llm, closes #86. Background: the Windows RTX 5070 Ti / 128 GB host previously ran its own separate, private llama-swap repo with no shared history or docs conventions with this repo; consolidating removes that split and lets the Windows host's Haiku/Sonnet tier follow the same config/tuning/history/ops documentation pattern as the Mac server. Changes: added a Windows installer path (`install.ps1 -Server`, `install/win/*.ps1`, NSSM services, Caddy TLS front via mkcert) that provisions and runs llama-swap as a Windows service; added `llama-swap/rtx5070ti-128gb/` config + annotations as a second host directory alongside the Mac's; added a root `LICENSE` (MIT); extended `docs/architecture.md`, `docs/ops.md`, `docs/tuning.md`, `docs/infrastructure.md`, `README.md`, and `llama-swap/README.md` to cover the Windows side; absorbed the standalone repo's optimization history into `docs/history.md`. Two review-code-security findings (Caddy binds unauthenticated on all interfaces; NSSM services run as LocalSystem against checkout-resident config) were accepted as known risk for the current single-operator home-LAN deployment scope, recorded as a SECURITY entry in `docs/history.md`, with hardening deferred until the threat model changes. <!-- compose-doc-append-sentinel: branch=feature/86-nirecom-llama-swap-cc-local pr=#87 -->

### CONFIG: Flash-Next: prefill step halved after the memory curve showed the QSA indexer, not KV, sets the ceiling (2026-08-30, 841d108)
Background: The opus-tier Flash-Next entries could not reach the checkpoint's native 262,144 context. A 4-point peak-memory curve (10k/35k/70k/103k, ascending on one model load, since mlx-vlm never resets its process-lifetime peak_memory high-water mark) measured 134 KB per token of context on a 91.8 GB intercept -- a hard ceiling of ~176k against Metal's 115.45 GB recommendedMaxWorkingSetSize, and ~151k on a practical 112 GB budget. Architecture accounts for only 27.7 KB/token of that (12 full-attention layers of 48 at 2 KV heads x 256 head_dim, plus QSA index_keys), so the KV cache was never the binding constraint and --kv-bits would have been the wrong lever: QSAKVCache.to_quantized passes index_keys through unquantized, so it reaches only the 24.6 KB part. Reading mlx_vlm/models/qwen4_exp/language.py located the other ~106 KB/token in QSAIndexer.from_projected, which materialises float32 block scores across the whole key length once per prefill chunk and therefore scales with --prefill-step-size, not with the model.
Changes: Added --prefill-step-size 1024 to qwen3.8-flash-next-3bit and -3bit-mtp, halving mlx-vlm's default. Measured on isolated bench twins first (one variable each), then verified on the routed entries: 85.5 KB per token of context on a 91.1 GB intercept, matching the ~85 predicted from the code. Hard ceiling ~298k, so native 262,144 fits; with the MTP drafter's 1.6 GB against the 6.1 GB freed, ~278k, still covering native. A 112 GB budget reaches ~236k with MTP -- the one case that misses native, and the reason to try step 512 next. Prefill costs -8.8% at 10k but only -1.1% at 103k, so the penalty is smallest where the memory mattered; decode and output are unchanged. The bench twins were deleted once the flag moved into the routed entries, since they would then have been byte-identical duplicates. Separately, docs/tuning.md carried a false claim that mlx-vlm does prefix caching automatically: APC is off by default (RuntimeConfig.apc_enabled=False, APC_ENABLED=0, no CLI flag), measures 0% hit on all four request shapes at 93k including byte-identical resends, and PATCH /v1/settings accepts apc_enabled without taking effect. Corrected, and docs/architecture.md's normalization table updated to five rules with the note that its four cache rules currently pay off only on the ds4 tier.

### CONFIG: Flash-Next: APC turns a continuation turn from 145s into 1.3s and halves the reachable context (2026-08-30)
Background: With --prefill-step-size 1024 the memory ceiling was extrapolated from four points below 103k. A fifth at 155,049 tokens closes it: 105.6 GB, 85.3 KB per token against the 85.5 fitted below, intercept 92.4 GB, hard ceiling ~270k and ~230k on a 112 GB budget -- so native 262,144 clears the hard ceiling by only 0.8 GB and should not be planned against. That point had to be measured twice: the first reading of 109.6 GB made the line look like it bent upward, but it ran on the process that had just timed out on a 200k prompt, and peak_memory is a process-lifetime high-water mark that no API resets -- a failed request contaminates it exactly as a successful one does. Above ~155k the binding limit stopped being memory anyway: a 200k prompt exceeds MLX_VLM_TOKEN_QUEUE_TIMEOUT (600s) in prefill, at 489 tok/s and falling. Nothing but not re-prefilling the prefix moves that, which is what made APC worth settling.
Changes: APC_ENABLED=1 and APC_EXACT_CACHE_ENTRIES=1 added via env: on the qwen3.8-flash-next-3bit-mtp candidate entry -- llama-swap does pass env: to the model process, and there is no other way in: mlx_vlm exposes no CLI flag and PATCH /v1/settings reports apc_enabled applied while /health still reports it false, because the model-load path never re-runs. A continuation turn over a 96,140-token prompt drops from 145.1s to 1.3s (cache_n 96,140, 39 tokens prefilled). Three corrections to what docs/tuning.md previously claimed. First, the mode is exact on both mlx-vlm tiers, not block: apc_block_eligible matches on exact type, so Flash-Next's QSAKVCache fails it as a subclass and the 27B fails it via ArraysCache, and --kv-bits cannot open the block path because generate/common.py skips any cache setting preserve_auxiliary_kv_state. Second, one entry rather than two, for a reason the earlier reading had backwards: each request stores both an n-1 checkpoint and the full n, and lookup caps candidates at len(prompt)-1, so the full-length entry is the only one a continuation can match and the n-1 entry the only one an identical resend can. The full-length store lands last and so survives a one-entry cache -- the first attempt at entries=1 measured 0 hits only because the bench put an unrelated request between the turn and its continuation. Third, the cost is a full second copy of the KV, 84 KB per token measured against the cache's own 85.3, so the memory line doubles its slope to 170.6 KB per token: ~135k hard, ~115k on a 112 GB budget, confirmed by a 134,425-token continuation dying of kIOGPUCommandBufferCallbackErrorOutOfMemory mid-request. Left on the used_by: [] candidate and off every routed tier, because the failure mode changed: an over-long prompt used to be slow, and now returns HTTP 500 with no tokens. Routing a tier here needs that bound enforced upstream first.

### BUGFIX: serverctl restart could never succeed on a launchd-managed service (2026-08-30)
Background: ds4_restart was stop-then-start, and under launchd neither half works: ds4_stop refuses because KeepAlive would revive the job immediately, and ds4_start refuses because the job is already installed. Every restart therefore printed two refusals and left the service untouched, which is worse than failing -- the caller believes the config was reloaded. Every APC measurement in this session needed a config reload, so this surfaced repeatedly.
Changes: ds4_restart now re-execs the job in place with launchctl kickstart -k, trying gui/<uid> then user/<uid>, and falls back to ds4_install when kickstart is unavailable. The non-launchd path is unchanged. serverctl.sh's usage line no longer says 'Stop then start'.
Test gap: scripts/ has no test covering the launchd branch of the lifecycle helpers, so no test asserted that restart leaves the service running; the refusal was only ever visible by reading the command's output.

### CONFIG: Context window 65536 -> 102400, and the haiku tier folded onto the sonnet backend (2026-08-30)
Background: CLAUDE_CODE_AUTO_COMPACT_WINDOW is a single global value, so the narrowest routed tier sets it, and it had been floored at 65536 by the RTX 5070 Ti's 16GB VRAM. The Mac side was measured first and had headroom either way: the opus tier reaches ~115k with APC on, and 206,819 tokens complete at peak 109.7GB with APC off. The question was whether the Windows host could meet it anywhere near 100k. Issue #88 was filed to measure it there rather than infer it, because llama.cpp preallocates the KV for --ctx-size at load but the Windows driver falls back to host RAM instead of failing, so a backend can start at a context it cannot serve -- only a real prompt of the target length separates the two cases.
Changes: Window raised to 102400 in both launchers (75% of it, 76,800, is what reaches a backend), Qwen3-Coder-30B-A3B raised to --ctx-size 102400, and its LiteLLM route to context_window 102400 with timeout 60 -> 600: a cold 76,800-token prefill is 58s at the measured 1335 tok/s, so the old timeout would have expired on the first turn after every compaction. Three Windows entries were measured at 100k (median of three n_predict-512 runs). Qwen3-Coder-30B-A3B: 1334.63 tok/s prefill, 22.71 decode, peak 14,545 of 16,303 MiB, and it also clears 128k at 1080.70 / 15,289 MiB. Qwen3.8-27B: 908.10 and 51.78, peak 15,916 -- fastest decode by 2.3x but 387 MiB of margin, and at 128k it starts at 435 tok/s and decays geometrically to 33 as the KV crosses the ceiling. Devstral-Small-2-24B: 6.50 tok/s and aborted at 17% after 39 minutes; -ngl 95 -> 70 with --parallel 1 bought 12% against the two orders of magnitude needed, and -ctk/-ctv q4_0 was already spent, so the offload direction was abandoned rather than tuned. Devstral therefore left the haiku tier, which now points at the same Qwen3-Coder-30B-A3B route as sonnet: the heavy group is exclusive, so a separate haiku model would be swapped in and out on every haiku call, making two backends strictly worse than one. The duplicate LiteLLM haiku entry was deleted rather than repointed, so one entry serves both tiers. Qwen3-Coder-30B-A3B was kept over the faster-decoding Qwen3.8-27B because neither Windows tier is a human's conversation partner -- sonnet is the subagent pin, and subagent work is prefill-bound, where A3B is 1.5x ahead -- and because 387 MiB of VRAM margin is not safe for an unattended tier on a desktop GPU.

### CONFIG: Haiku, sonnet and the subagent route moved to Qwen3.8-27B to settle its unverified coding accuracy (2026-08-31)
Background: The Windows coding tier was on Qwen3-Coder-30B-A3B, chosen a day earlier on risk grounds: it clears 128k as well as 100k and leaves 1,758 MiB of VRAM margin, where Qwen3.8-27B leaves 387 and fails 128k outright. That decision compared throughput, which was measured on both, and not coding accuracy, which was measured on neither -- the 27B annotation had said 'Coding-task accuracy itself is still unverified' since it was added. No bench settles that question as well as running the tier on real work, so the routing is the experiment.
Changes: LITELLM_HAIKU_MODEL, LITELLM_SONNET_MODEL and CCGW_SUBAGENT_MODEL all now hold qwen3.8-27b, and the single LiteLLM entry keyed on the sonnet variable points at Qwen3.8-27B-UD-Q3_K_XL. All three move together because the routing key IS the LiteLLM model_name: leaving the subagent on qwen3-coder-30b-a3b would have named an entry that no longer exists, and even if it did, the heavy group is exclusive, so a second Windows model would be swapped in and out on every subagent call. The 27B entry rose from --ctx-size 65536 to 102400, without which the 76,800-token effective prompt would 400 on context length. The LiteLLM timeout note moved from 58s at 1335 tok/s to 85s at 908, this backend's measured prefill. Qwen3-Coder-30B-A3B stays configured at ctx 102400, unrouted, as the fallback the evaluation returns to; it is the only entry that clears 128k, so raising the window again means moving back to it first. What is being traded: 2.3x the decode (51.78 vs 22.71 tok/s) for 1.5x less prefill (908.10 vs 1334.63) and a quarter of the VRAM headroom.
