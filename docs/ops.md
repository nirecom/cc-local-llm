# Ops

Day-to-day procedures. Parameter rationale is in [tuning.md](tuning.md); hosts/ports in
[infrastructure.md](infrastructure.md).

## Run the proxy (Mac)

The proxy is the sole LAN-visible endpoint (TLS termination + prompt normalization + token
auth); ds4-server itself listens on loopback. Rationale:
[architecture.md](architecture.md#reverse-proxy-layer).

One-time TLS setup. The proxy's cert must be trusted by the Windows client, so sign it with the
**same mkcert root CA the client already uses** — do not create a separate root CA on the Mac.
Sharing one root means the client trusts the proxy by pointing `CCGW_CA_CERT` at that existing
root; nothing new has to be distributed and trusted.

1. On the Windows client, issue a leaf cert/key for the proxy from the existing root CA. The
   root CA private key never leaves the client.
2. Copy only the generated cert/key to the Mac as `~/.config/ccgw-proxy/cert.pem` and `key.pem`.

Exact mkcert flags and cert locations are environment-specific — see mkcert's own docs.

Add the shared auth token to the server-side `.env` (repo root, gitignored):
```sh
# .env: CCGW_PROXY_AUTH_TOKEN=<generated-secret>   (generate with /create-key)
```

Start the proxy in the background:
```sh
~/git/cc-local-llm/scripts/serverctl.sh start proxy
```

Or foreground (for debugging):
```sh
~/git/cc-local-llm/scripts/ccgw-proxy.sh
```

The gateway sends `LITELLM_CCGW_PROXY_API_KEY`, which must equal `CCGW_PROXY_AUTH_TOKEN`. Clients
never talk to the proxy directly — see [Client (Windows)](#client-windows).

## LiteLLM gateway (Mac)

The gateway is the single endpoint every client uses, and the only place the Anthropic wire
format is converted. It runs as a native process on this Mac, installed by `install.sh --server`
(`install/mac/litellm.sh`, `uv tool install "litellm[proxy]"`) and managed by `serverctl`.

### Initial setup (one-time)

1. Generate a master key and set it in `.env`:
   ```sh
   # .env: LITELLM_MASTER_KEY=sk-<generated>   (generate with /create-key)
   ```
   There is no database and no `/key/generate` step: clients present this same value as
   `LITELLM_CLIENT_KEY`.

2. Issue an mkcert leaf cert/key for the gateway from the same root CA the CCGW Proxy uses, so
   one `CCGW_CA_CERT` covers every endpoint, and point `.env` at the files:
   ```sh
   mkcert localhost 127.0.0.1 ::1 <mac-lan-ip>
   # .env: LITELLM_TLS_CERT=/Users/<you>/.config/litellm/cert.pem
   #       LITELLM_TLS_KEY=/Users/<you>/.config/litellm/key.pem
   ```

3. Point the gateway at the CCGW Proxy and at the root CA that signed the proxy's certificate.
   The same CA also signs the Windows PC's TLS front, so one value covers both hops:
   ```sh
   # .env: LITELLM_CCGW_PROXY_URL=https://<mac-lan-ip>:8443
   #       LITELLM_CCGW_PROXY_OPENAI_URL=https://<mac-lan-ip>:8443/v1
   #       LITELLM_CCGW_PROXY_API_KEY=<same value as CCGW_PROXY_AUTH_TOKEN>
   #       SSL_CERT_FILE=<mkcert -CAROOT>/rootCA.pem      (absolute path, no ~)
   ```

   The first two are the same host and port; only the `/v1` suffix differs. The Fable
   tier uses the bare origin and the Opus tier the suffixed form, so setting only one
   leaves the other tier returning `404 page not found`.

4. Point the Haiku/Sonnet tiers at the Caddy TLS front on the Windows PC, which
   reverse-proxies to that host's loopback-only llama-swap (`127.0.0.1:18080`):
   ```sh
   # .env: LITELLM_LLAMASWAP_URL=https://<windows-lan-ip>:8443/v1
   ```

The gateway refuses to start when `LITELLM_MASTER_KEY` or `LITELLM_CCGW_PROXY_URL` is unset, or
when `LITELLM_TLS=on` without both cert and key — no process is launched in that case.

### Start / stop / verify

```sh
~/git/cc-local-llm/scripts/serverctl.sh start litellm
~/git/cc-local-llm/scripts/serverctl.sh stop litellm
~/git/cc-local-llm/scripts/serverctl.sh status litellm
~/git/cc-local-llm/scripts/serverctl.sh logs litellm
```

Foreground (debugging):
```sh
~/git/cc-local-llm/scripts/litellm.sh
```

Health endpoint:
```sh
curl -sk https://127.0.0.1:8445/health/
```

### Verify routing

Send a test request per tier through the **Anthropic /v1/messages** endpoint (the format Claude
Code sends), which also exercises the Anthropic-to-OpenAI conversion:

```sh
curl -sk -X POST https://127.0.0.1:8445/v1/messages -H 'Content-Type: application/json' -H "x-api-key: $LITELLM_MASTER_KEY" -H 'anthropic-version: 2023-06-01' -d '{"model":"devstral-small-2-24b","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
curl -sk -X POST https://127.0.0.1:8445/v1/messages -H 'Content-Type: application/json' -H "x-api-key: $LITELLM_MASTER_KEY" -H 'anthropic-version: 2023-06-01' -d '{"model":"qwen3-coder-30b-a3b","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
curl -sk -X POST https://127.0.0.1:8445/v1/messages -H 'Content-Type: application/json' -H "x-api-key: $LITELLM_MASTER_KEY" -H 'anthropic-version: 2023-06-01' -d '{"model":"deepseek-v4-flash","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
curl -sk -X POST https://127.0.0.1:8445/v1/messages -H 'Content-Type: application/json' -H "x-api-key: $LITELLM_MASTER_KEY" -H 'anthropic-version: 2023-06-01' -d '{"model":"laguna-s-2.1","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
```

The Haiku and Sonnet tiers have no fallback — a request fails outright if the Windows PC's
llama-swap or the Caddy front in front of it is offline. The Fable and Opus tiers are mutually exclusive on the Mac, so the last
two commands force a model swap between them; expect a cold start on each switch.

### Recovery

| Symptom | Action |
|---------|--------|
| Gateway not running | `serverctl.sh start litellm`; `serverctl.sh logs litellm` for the reason |
| Gateway refuses to start, naming a variable | Fill that variable in `.env` — the guard runs before launch |
| `Connection refused` on :8445 | Verify `LITELLM_HOST` / `LITELLM_PORT` and that the process is up |
| Haiku/Sonnet tier cannot connect to :8443 | The Windows PC's Caddy front or the llama-swap behind it is down; no fallback exists — start both and retry |
| TLS errors on the Haiku/Sonnet hop | Verify `SSL_CERT_FILE` points at the mkcert root CA and that Caddy's cert on the Windows PC is signed by it |
| CCGW Proxy unreachable | Verify `LITELLM_CCGW_PROXY_URL` and that `serverctl.sh status proxy` reports running |
| Client reports "the selected model may not exist" for one tier only | A 404 or 400 the client renders opaquely. Check `LITELLM_CCGW_PROXY_OPENAI_URL` is set with its `/v1` suffix; that `use_chat_completions_url_for_anthropic_messages: true` is still in `litellm-server/config.yaml` (without it the `openai/` tiers go to the Responses API, which `mlx_lm.server` does not implement); and that the tier still carries `drop_params: true` (without it the client's `reasoning_effort` is a 400). The gateway log holds the real status and message |
| TLS errors from clients | Verify `LITELLM_TLS_CERT` / `LITELLM_TLS_KEY` exist and are mkcert-signed |
| TLS errors on the Fable/Opus hop | Verify `SSL_CERT_FILE` is an absolute path (no `~`) to the mkcert root CA |
| `401 Unauthorized` from the gateway | `LITELLM_CLIENT_KEY` on the client must equal `LITELLM_MASTER_KEY` on the Mac |
| `401` from the CCGW Proxy | `LITELLM_CCGW_PROXY_API_KEY` must equal `CCGW_PROXY_AUTH_TOKEN` |

Two properties of the Windows Caddy certificate that a "TLS error" never spells out:

- Its SAN list must include the host's **LAN IPv4 address**, not just `localhost` / `127.0.0.1`.
  A cert that covers only loopback still terminates TLS, so the service looks healthy from the
  host — LAN clients simply refuse the connection, with no matching entry in Caddy's log.
- That assumes the LAN IP is **static or DHCP-reserved**. A roaming address invalidates the
  certificate the moment the lease changes; re-issue it (`install.ps1 -Server`) after any move.

## Install llama-swap and Laguna S 2.1 (Mac, one-time)

llama-swap owns the full start/stop lifecycle of both ds4-server and Laguna's
`mlx_lm.server` (see [architecture.md](architecture.md#mac-backend-layer-llama-swap)); it must
be installed before either backend can be reached through the proxy.

Run the bundled installer, which installs llama-swap (via Homebrew), then `mlx-lm` and
`mlx-vlm` from git `main` (neither model family's support is in a PyPI release yet), then
scaffolds `.env`:
```sh
~/git/cc-local-llm/install.sh
```
Both MLX packages are needed and coexist as separate uv tools: mlx-lm serves Laguna and the
Qwen3-Next family, mlx-vlm serves the Qwen3.8-27B family including its MTP speculative-decoding
variants — see [tuning.md](tuning.md#mtp-speculative-decoding-qwen3827b) for why.

It cannot download model weights itself — confirm
`~/.lmstudio/models/poolside/Laguna-S-2.1-NVFP4-mlx` exists (via LM Studio or `huggingface-cli`)
before starting llama-swap. The individual steps live under
[install/mac/](../install/mac/) (`llama-swap.sh`, `mlx-lm.sh`, `mlx-vlm.sh`) if you need to
re-run just one.

A model directory that still holds a `downloading_*.safetensors.part` file is an **incomplete**
download; mlx-vlm reports it as `Missing N parameters: ...` at startup and llama-swap surfaces
only `upstream command exited prematurely`. Finish the download rather than debugging the config.

`LLAMA_SWAP_HOST` / `LLAMA_SWAP_PORT` in `.env` default to `127.0.0.1:18080`, which matches
`CCGW_PROXY_UPSTREAM` — leave them as-is unless you have a reason to change the port.

## Retire the always-on ds4-server LaunchAgent (one-time, existing installs only)

Skip this if `com.nire.ds4-server.plist` was never installed. Otherwise, llama-swap now owns
ds4-server's lifecycle exclusively — leaving the old LaunchAgent running would fight llama-swap
for the same process and break ds4/Laguna exclusivity. Run this once, yourself, before starting
llama-swap for the first time:

```sh
~/git/cc-local-llm/scripts/serverctl.sh uninstall server
```

This stops the resident ds4-server process and removes
`~/Library/LaunchAgents/com.nire.ds4-server.plist`. After this, `server` is a manual-debug-only
`serverctl` target — it is not part of `all`.

## Run llama-swap (Mac)

llama-swap is the CCGW Proxy's sole upstream; starting it makes both ds4-server and Laguna
reachable (llama-swap spawns whichever one is requested, on demand):

```sh
~/git/cc-local-llm/scripts/serverctl.sh start llama-swap
```

For foreground (debugging):
```sh
~/git/cc-local-llm/scripts/llama-swap.sh
```

Stop:
```sh
~/git/cc-local-llm/scripts/serverctl.sh stop llama-swap
```

Note: if the service is launchd-managed (auto-start installed), `stop` exits with an error
and guides you to use `serverctl uninstall llama-swap` instead.

### Manual foreground ds4-server (debugging only)

For debugging ds4-server in isolation, outside llama-swap's management:
```sh
mkdir -p ~/Library/Caches/ds4-server/kv     # first time only
~/git/cc-local-llm/scripts/ds4-server.sh
```
`caffeinate` is baked into the script and exits with the server; no separate step. Do not run
this alongside llama-swap — both would try to manage the same process.

## Unified control (Mac)

```sh
~/git/cc-local-llm/scripts/serverctl.sh start all         # start proxy + llama-swap + litellm
~/git/cc-local-llm/scripts/serverctl.sh stop all          # stop all three
~/git/cc-local-llm/scripts/serverctl.sh restart all       # restart all three
~/git/cc-local-llm/scripts/serverctl.sh status all        # show status
~/git/cc-local-llm/scripts/serverctl.sh logs llama-swap   # tail llama-swap log (color in TTY)
~/git/cc-local-llm/scripts/serverctl.sh logs proxy        # tail ccgw-proxy log
~/git/cc-local-llm/scripts/serverctl.sh logs litellm      # tail LiteLLM gateway log
~/git/cc-local-llm/scripts/serverctl.sh logs all          # tail all three logs
```

Targets: `proxy`, `llama-swap`, `litellm`, `all` (default when omitted). `server` (bare
ds4-server) is a separate manual-debug-only target, excluded from `all` — see above.

## Automatic startup (launchd)

Install the services as LaunchAgents (start at login, restart on crash):
```sh
~/git/cc-local-llm/scripts/serverctl.sh install all
```

Uninstall (stops the service and removes auto-start):
```sh
~/git/cc-local-llm/scripts/serverctl.sh uninstall all
```

Plist locations and labels:
- `~/Library/LaunchAgents/com.nire.ccgw-proxy.plist` (`com.nire.ccgw-proxy`)
- `~/Library/LaunchAgents/com.nire.ccgw-llama-swap.plist` (`com.nire.ccgw-llama-swap`)

The gateway follows the same `com.nire.ccgw-<service>` naming as the other two; the label and
path come from a per-service lookup keyed on the `serverctl` target name (`_ds4_plist_label` in
`scripts/lib/launchd.sh`).

`server` (bare ds4-server) has no plist — it is not launchd-installable; llama-swap starts and
stops it on demand instead.

KeepAlive=true means launchd restarts the service automatically on crash.

**CCGW_LOG change requires reinstall**: the log paths are baked into the plist at install time.
After changing `CCGW_LOG` in `.env`, run `serverctl install all` to regenerate the plist.

**Stopping a launchd-managed service**: `serverctl stop` will refuse with an error when the
service is launchd-managed (KeepAlive would restart it immediately anyway). Use
`serverctl uninstall <svc>` to stop and disable auto-start.

**Restarting a launchd-managed service**: `serverctl install <svc>` on its own is the restart —
`ds4_install()` (`scripts/lib/launchd.sh`) runs `_ds4_write_plist` → `launchctl unload` →
`launchctl load -w` in sequence. Do **not** do `uninstall` then `install`: the two-step form
only opens a window in which no LaunchAgent exists, and buys nothing.

**Run `install` from the checkout the plist should point at.** `_ds4_write_plist` bakes the
absolute path `$CCGW_OPS_ROOT/scripts/<wrapper>.sh` into `ProgramArguments` (`ccgw-proxy.sh`,
`ds4-server.sh`, `llama-swap.sh`, or `litellm.sh` — see `_ds4_wrapper_script` in
`scripts/lib/paths.sh`), and
`CCGW_OPS_ROOT` is derived by `scripts/lib/root.sh` from the parent directory of the script
that was actually executed. Installing from a throwaway checkout (a git worktree, say) leaves
the LaunchAgent pointing at a path that disappears when that checkout is removed, and the
service then fails to start. Always run it from the everyday checkout (`~/git/cc-local-llm`).

**start vs stop asymmetry**: when launchd manages a service, `serverctl start` is a silent
no-op (informational — launchd's KeepAlive is already running it), while `serverctl stop`
returns an error (stopping would be immediately undone by KeepAlive, so the command refuses
to create that confusion). This asymmetry is intentional.

## Log control

Five independent toggles control different log streams:

| Toggle | Controls | off effect |
|---|---|---|
| `CCGW_LOG` | Service stdout/stderr → `proxy.log` / `kvcache.log` | No disk write for these logs |
| `CCGW_PROXY_TEE` | Proxy body-dump debug logs (`CCGW_PROXY_LOG_DIR`) | No body-dump disk write |
| `DS4_SERVER_COLOR_LOG` | ANSI color in terminal output for ds4-server | Plain text in terminal |
| `CCGW_LOG_COLOR` | ANSI "[service]" prefix per line in `serverctl logs all` | Plain "[service]" prefix, no color |
| `CCGW_LOG_TAIL_LINES` | Backlog lines shown per service when `serverctl logs all` starts (default 6) | N/A — sets the count, no on/off |

`CCGW_LOG=off` stops only the stdout/stderr log files. If `CCGW_PROXY_TEE=on`, the proxy
still writes body-dump logs to `CCGW_PROXY_LOG_DIR` — they are independent.

Log file paths: `~/Library/Logs/ccgw-proxy/proxy.log` and `~/Library/Logs/llama-swap/llama-swap.log`
(ds4-server's own stdout/stderr flow through llama-swap into the latter file — see
`kvcache.log` under [Monitoring](#monitoring-mac) for the separate KV-cache log ds4-server writes
directly).

For color-highlighted live log viewing:
```sh
~/git/cc-local-llm/scripts/serverctl.sh logs llama-swap   # TTY: color; pipe/file: plain
```

`serverctl logs all` tails proxy, llama-swap, and litellm concurrently instead of
handing multiple files to a single `tail -f` — litellm's line volume otherwise drowns
out the other two in a plain interleaved stream. Each service's lines get a fixed,
colored `[service]` prefix (magenta proxy, blue llama-swap, green litellm) so the
source stays legible regardless of which service is currently the noisiest; piped or
redirected output gets the same prefix without ANSI.

## Server (Windows)

This host serves the Haiku and Sonnet tiers: llama-swap holds the models, Caddy terminates TLS
in front of it, and both run as NSSM services. One-time install, from an **elevated** pwsh in
the checkout:

```powershell
.\install.ps1 -Server
```

The installer is the source of truth for the exact commands, so they are not restated here: it
installs mkcert, NSSM and Caddy, issues the certificate, renders the Caddyfile from
[install/win/Caddyfile.template](../install/win/Caddyfile.template), and registers and starts
both services. The three prerequisites it assumes rather than installs — the `llama-swap.exe`
binary in the runtime directory, a CUDA-built llama.cpp plus the `.gguf` weights the config
names, and the Mac's *full* mkcert CA directory (`rootCA.pem` **and** `rootCA-key.pem`) copied
here with `$env:CAROOT` pointed at it — are listed under **Windows (server)** in
[README.md](../README.md#quick-start). A trust-store import of `rootCA.pem` alone does not cover
that last one: mkcert signs the leaf with the CA private key, so without `rootCA-key.pem` it
issues from a *different*, locally generated CA and the gateway rejects the result. Every path is
in [infrastructure.md](infrastructure.md#paths-windows).

**Reissuing the certificate after this host's LAN IP changes:** the SAN list is fixed when the
certificate is issued, and [install/win/certs.ps1](../install/win/certs.ps1) leaves an existing
pair untouched so a re-run never invalidates a certificate LAN clients already trust. Re-running
the installer alone therefore keeps serving the old address. Delete both PEMs first, then re-run
from an **elevated** pwsh — `<cert-dir>` is the llama-swap TLS cert/key directory in
[infrastructure.md](infrastructure.md#paths-windows), the only place that path is written down:

```powershell
Remove-Item <cert-dir>\cert.pem, <cert-dir>\key.pem
.\install.ps1 -Server
```

Deleting only one of the two is refused rather than completed, so remove both. LAN clients keep
trusting the new certificate without any client-side change: it is issued by the same root CA.

Verification — the installer asserts all of this itself, so a clean run has already proved it;
re-check it by hand after any manual service surgery:

- `Get-Service llama-swap, llama-swap-caddy` reports **Running** for both.
- Every port is actually accepting connections within 30 s of the start: llama-swap's internal
  listen port plus one port per front-end block in the generated Caddyfile. Check with
  `Get-NetTCPConnection -State Listen`. A service that reports Running while nothing is bound is
  the failure NSSM hides — the process is crash-looping.
- A request survives the TLS hop end to end:
  `curl.exe -sk https://<windows-lan-ip>:8443/v1/models`.

**Blast radius of `llama-swap-caddy`:** it is a single Caddy process serving *every* front-end
block in the generated Caddyfile, not only llama-swap's `:8443`. Four unrelated local services
share it — Open WebUI (`:3443`), JudgeClaw (`:18790`), the LangChain API (`:8444`) and Langfuse
(`:13443`). Stopping or removing this one service therefore drops external reachability for all
five at once, so "just restart Caddy" is never a llama-swap-local action.

**Native command exit-code policy (`install/win/lib/native.ps1`):** `$ErrorActionPreference =
'Stop'` does not turn a native executable's non-zero exit into a PowerShell exception, so every
native call the installer makes (nssm, sc.exe, taskkill, winget, mkcert, certutil) goes through
`Invoke-Native`, which closes that gap once for the class instead of once per call site. Exit 0
is the only automatic success; a caller must enumerate any other code it wants treated as benign
(e.g. "already absent"), since the same code is benign at one call site and a real failure at
another. When extending an allow list: PowerShell reports the full Win32 exit code, but bash
observing the same run truncates it to 8 bits — `sc.exe` on a missing service is Win32 `1060`,
which shows as `36` (`1060 & 0xFF`) from bash. Always write the Win32 value. The file holds only
function definitions: the Pester suites dot-source it, so a stray top-level statement would make
the test run itself destructive.

## Client (Windows)

Run `install.ps1` first (once) to install mkcert and scaffold `.env` — see
[README.md](../README.md#quick-start). This host is a client, and also serves as the llama-swap
backend for the Haiku/Sonnet tier (see "Server (Windows)" above); the gateway itself still runs
on the Mac.

Then edit the repo-root `.env` (gitignored, so the LAN IP and the key are never committed):
```powershell
Copy-Item .env.example .env
# then edit .env: LITELLM_ANTHROPIC_BASE_URL=https://<mac-lan-ip>:8445
#                 LITELLM_CLIENT_KEY=<same value as LITELLM_MASTER_KEY on the Mac>
#                 CCGW_CA_CERT=<mkcert -CAROOT>\rootCA.pem  (the Mac's root CA, imported here)
```
Then launch VS Code with the ccgw backend via the bundled wrapper:
```powershell
.\scripts\code-ccgw.ps1 .
```
The wrapper loads `.env`, then sets the ccgw env (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
the per-tier model aliases (the tier table under "Client (macOS / Linux)" applies here too),
`NODE_EXTRA_CA_CERTS` from `CCGW_CA_CERT`, and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=65536` /
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`), then launches VS Code. There is exactly one route: the
direct CCGW Proxy path is retired, so an unset `LITELLM_ANTHROPIC_BASE_URL` or
`LITELLM_CLIENT_KEY` is an error and the wrapper exits rather than falling back to a placeholder
that would surface later as a confusing 401. A value set in the shell takes precedence over
`.env` — except for the model-routing keys (`LITELLM_HAIKU_MODEL`, `LITELLM_SONNET_MODEL`,
`LITELLM_FABLE_MODEL`, `LITELLM_OPUS_MODEL`, `CCGW_SUBAGENT_MODEL`), which always come from `.env`
so a stale inherited shell value (e.g. an old `LITELLM_OPUS_MODEL` from a previous launch) cannot
override the repo's intent. `LITELLM_VIRTUAL_KEY` is still accepted in place of `LITELLM_CLIENT_KEY` for one release,
with a warning. `CCGW_CA_CERT` must point at `<mkcert -CAROOT>\rootCA.pem` so Node trusts the
gateway certificate (if unset the wrapper warns and TLS will not be trusted). `.env` may carry
`#@if windows` / `#@if posix` / `#@endif` blocks so one file holds both platforms' values — see
[env-conditional-blocks.md](env-conditional-blocks.md).

Subagent routing is opt-in: set `CCGW_SUBAGENT_MODEL` to a LiteLLM routing key to pin every
subagent to one tier. Left empty — the default — each agent's own frontmatter decides.

When the Mac switches a tier's backend with `scripts/set-model.sh`, this `.env` must be updated
by hand to match — see "Mirroring a `set-model.sh` change to the Windows client" under
"Client (macOS / Linux)".

**Isolation from native (subscription) VS Code:** the wrapper passes
`--user-data-dir "$env:LOCALAPPDATA\vscode-ccgw"`, starting a *separate* VS Code process. VS Code
shares one process — and thus one environment — across every window under the same
user-data-dir, so without this flag the ds4 env bleeds into native subscription windows. The
separate profile keeps the ds4 session and native `code` / `codes` sessions independent on the
same machine. Extensions are shared (`--user-data-dir` isolates settings/state, not
`~/.vscode/extensions`), so the Claude Code extension is already available in the ds4 profile.
Do not add ds4 env vars to native sessions: a bare `ANTHROPIC_BASE_URL` plus a credential
replaces the subscription (see
[architecture.md](architecture.md#two-strategies-chosen-by-whether-real-opus-is-wanted)).
Caveat: if the ds4 profile is already running, close *all* its windows before changing
`LITELLM_ANTHROPIC_BASE_URL` — closing one window is not enough; the process (and its captured
environment) persists until the last window of the profile closes, and new windows inherit the
old value. The same folder may be open in the native and ds4 profiles at the same time: the
"reuse the existing window for this folder" dedup is per-profile, so `codes .` followed by
`code-ccgw.ps1 .` on one repo yields two independent windows (native backend + ds4 backend),
not one activated window.

Terminal alternative (no VS Code): set the same env vars the wrapper does
(see [scripts/code-ccgw.ps1](../scripts/code-ccgw.ps1) for the full list) and run `claude`.

Optional per-tier thinking split: also set the `ANTHROPIC_DEFAULT_*_MODEL` vars from
[tuning.md](tuning.md#per-tier-thinking-split-without-a-router-optional).

**Verify connectivity:** after launch, run `/context` and confirm CC reports the local window
(65536, the floor the launcher sets) rather than a cloud 200K / 1M. Grow the conversation and
confirm auto-compaction fires *before* the backend returns `400 context_length_exceeded`.

## Client (macOS / Linux)

The Windows box is the primary client, but the backend Mac — and any Linux host on the LAN —
can drive the same backend through [scripts/code-ccgw.sh](../scripts/code-ccgw.sh), the POSIX
counterpart of `code-ccgw.ps1`. On the backend Mac this is the cheapest path of all: the gateway
is already on loopback, so no LAN IP is involved.

One-time setup:
```bash
./install.sh --client     # installs mkcert (Linux: apt/dnf/pacman; Mac: Homebrew)
cp .env.example .env      # if not already present
```
Then fill in `.env`:
- **On the backend Mac:** `LITELLM_ANTHROPIC_BASE_URL=https://127.0.0.1:8445` and
  `LITELLM_CLIENT_KEY=<same value as LITELLM_MASTER_KEY>`. `CCGW_CA_CERT` may be omitted — the
  wrapper falls back to `$(mkcert -CAROOT)/rootCA.pem`, which is already correct on the host
  that issued the certificate.
- **On another Linux host:** `LITELLM_ANTHROPIC_BASE_URL=https://<mac-lan-ip>:8445`,
  `LITELLM_CLIENT_KEY`, and `CCGW_CA_CERT` pointing at a copy of the Mac's `rootCA.pem`.

The same repo-root `.env` is shared with the Windows client above, so a value that differs by
platform (like `CCGW_CA_CERT`'s path syntax) can live in one `#@if windows` / `#@if posix` /
`#@endif` block instead of two files — see [env-conditional-blocks.md](env-conditional-blocks.md).

Launch:
```bash
./scripts/code-ccgw.sh .
```

**Choosing the backend model.** Model names are LiteLLM routing keys — the `LITELLM_*_MODEL`
values in `.env`, matched against `model_name` entries in
[litellm-server/config.yaml](../litellm-server/config.yaml). Each tier is a separate route, so
`/model` is what switches between them:

| Tier | Where its backend runs |
|---|---|
| Fable | Mac llama-swap |
| Opus | Mac llama-swap |
| Sonnet | Windows llama-swap |
| Haiku | Windows llama-swap |

Which model a tier currently points at is not fixed — it is `.env`'s `LITELLM_<TIER>_MODEL`,
and `scripts/set-model.sh` rewrites it. Read the live value with `scripts/set-model.sh --list`
(which also enumerates the choices for the two Mac tiers) rather than a name written here.

**Mirroring a `set-model.sh` change to the Windows client.** `set-model.sh` edits two files on
the Mac — `litellm-server/config.yaml` and the Mac's `.env` — and restarts litellm-server. It
does not reach the Windows client, and nothing else does either: `.env` is gitignored, and the
Windows box is a separate clone. So a tier switch on the Mac needs a manual mirror.

It matters because `model_name` in the LiteLLM config is `os.environ/LITELLM_<TIER>_MODEL`. The
name LiteLLM answers to is literally the Mac `.env` value, while the Windows wrapper builds
`ANTHROPIC_DEFAULT_*_MODEL` from *its own* `.env`. Leave the two out of sync and the client asks
for a model group the gateway no longer publishes — a 400, not a silent fallback.

1. On the Mac, read the new value: `scripts/set-model.sh --list <tier>`.
2. On Windows, set the same bare key in the repo-root `.env` as `LITELLM_<TIER>_MODEL=<key>`.
3. Close *all* windows of the ccgw VS Code profile, then relaunch `.\scripts\code-ccgw.ps1 .` —
   the wrapper captures its environment at process start, so closing one window is not enough
   (same caveat as `LITELLM_ANTHROPIC_BASE_URL` under "Client (Windows)").

Only the tier that changed needs mirroring; the other three keys keep working untouched.

The two Mac backends are mutually exclusive: switching between Fable and Opus unloads the
resident model and cold-starts the other, so expect a long first response after each switch.
Haiku and Sonnet live on a different machine and are unaffected. Subagents are no longer pinned
to one tier — the gateway multiplexes, so each agent's frontmatter decides unless
`CCGW_SUBAGENT_MODEL` is set.

**Isolation from native (subscription) VS Code** works the same way as on Windows: the wrapper
passes its own `--user-data-dir` (`~/Library/Application Support/vscode-ccgw` on macOS,
`${XDG_DATA_HOME:-~/.local/share}/vscode-ccgw` on Linux), so this env never bleeds into native
subscription windows. The Windows section above covers the reasoning and the caveats — they
apply verbatim here.

Terminal alternative (no VS Code): set the same env vars the wrapper does (see
[scripts/code-ccgw.sh](../scripts/code-ccgw.sh) for the full list) and run `claude`.

## Verify Laguna S 2.1 (Mac)

With llama-swap running, send a direct request naming the Laguna model. This forces llama-swap
to kill any resident ds4-server and cold-start `mlx_lm.server` — expect the first response to
take as long as a full model load (see [infrastructure.md](infrastructure.md#engine--model-on-the-mac)
for expected weight size):
```sh
curl -s http://127.0.0.1:18080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $CCGW_PROXY_AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"laguna-s-2.1","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
```
Then confirm exclusivity: sending a `deepseek-v4-flash` request next should make llama-swap kill
the Laguna process and cold-start ds4-server in its place — `pgrep -fl mlx_lm.server` should
show nothing once ds4-server is back up.

## Monitoring (Mac)

| Check | Command |
|---|---|
| Sleep events (should be none while serving) | `pmset -g log \| grep -i "entering sleep"` |
| KV cache size | `du -sh ~/Library/Caches/ds4-server/kv` |
| Memory pressure / swap | `sysctl vm.swapusage` |
| Thinking on/off per request | grep the server log for `THINKING` in the `chat ...` lines |
| Process alive / one instance | `pgrep -fl ds4-server` |
| KV cache report (long-prefill counts, cache-miss prefix distribution, per-reason write volume) | `~/git/cc-local-llm/scripts/kvcache-report.sh` |

The report reads `~/Library/Logs/ds4-server/kvcache.log` and takes `--since` / `--until` to
restrict the window. A SPEC is a timestamp with 4, 8 or 10 digits once separators are removed
(`0801`, `"08-01"`, `"0801 12:00"`, `0801120000`); `--since` pads the missing part with
`00:00:00` and `--until` with `23:59:59`. The log carries no year, so these are the only way
to split a window — the file is appended across restarts and is never rotated on restart.

The output is deterministic for a given input range, so a before/after comparison is just a
`diff` of two runs:
```sh
~/git/cc-local-llm/scripts/kvcache-report.sh --until "0811 07:21:29" > /tmp/before.txt
~/git/cc-local-llm/scripts/kvcache-report.sh --since "0811 07:21:29" > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

## Recovery

| Symptom | Action |
|---|---|
| `400 context_length_exceeded` | Client conversation grew past ctx. `/compact`, or `/clear`, or raise `--ctx` and restart (the running conversation then fits). |
| `error during compaction` | The compaction request itself exceeds ctx. Ensure `CLAUDE_CODE_AUTO_COMPACT_WINDOW` + `PCT_OVERRIDE` are set so compaction fires *before* the ceiling; otherwise `/clear` or restart the server at higher ctx so the current conversation fits, then compact. |
| Server unresponsive / client API errors after idle | Check `pmset -g log` for a sleep window. caffeinate should prevent it; confirm the process is still wrapped. |
| `kv cache evicted reason=disk-cache-full` | Normal capacity management — not an error. Ignore. |
| Switching between ds4/Laguna is slow every time | Expected — llama-swap fully unloads the previous model before loading the next (`ttl: 0`, no idle auto-unload; see [architecture.md](architecture.md#mac-backend-layer-llama-swap)). Both together exceed 128 GB, so there is no way to keep both warm. |
| `502 Bad Gateway` from the proxy right after a model switch | llama-swap is still loading the newly-requested model. Retry after the load completes (`serverctl logs llama-swap` shows progress). |

## Enable Think Max (accuracy option)

All three required (see [tuning.md](tuning.md#think-max-3-conditions-all-required)):
1. `--ctx >= 393216` ✅ (current config)
2. Thinking on (model resolves to `deepseek-reasoner` or default, not `deepseek-chat`)
3. **Client sends `effort=max`** — CC defaults to `xhigh`→HIGH, so this is the missing piece;
   verify CC can be set to max and forwards it before expecting Think Max.
