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
2. Copy only the generated cert/key to the Mac as `~/.config/ds4-proxy/cert.pem` and `key.pem`.

Exact mkcert flags and cert locations are environment-specific — see mkcert's own docs.

Add the shared auth token to the server-side `.env` (repo root, gitignored):
```sh
# .env: DS4_PROXY_AUTH_TOKEN=<generated-secret>   (generate with /create-key)
```

Start the proxy in the background:
```sh
~/git/cc-local-llm/scripts/serverctl.sh start proxy
```

Or foreground (for debugging):
```sh
~/git/cc-local-llm/scripts/ds4-proxy.sh
```

Client-side (Windows): set `CCGW_CA_CERT` to `<mkcert -CAROOT>/rootCA.pem` in the repo-root
`.env` so Node trusts the proxy certificate, and set `CCGW_API_KEY` to the same value as
`DS4_PROXY_AUTH_TOKEN`.

## LiteLLM (Windows, Docker Desktop WSL2)

Run `install.ps1` first (once) to install Docker Desktop and mkcert and scaffold `.env` — see
[README.md](../README.md#quick-start). The steps below (TLS/CA/master key/container start) are
interactive and follow on from it.

### TLS setup (one-time)

The LiteLLM proxy needs an mkcert leaf cert/key. Use the same root CA as the DS4 Proxy
so the client trusts both endpoints with one `CCGW_CA_CERT`:

```powershell
mkcert localhost 127.0.0.1 ::1 <windows-host>
# Copy the generated cert.pem + key.pem to the directory specified by LITELLM_TLS_DIR
# (e.g., C:\Users\<user>\.config\litellm\)
```

### CA cert setup (one-time)

The LiteLLM container needs to trust the DS4 Proxy's TLS certificate for the Opus route.
Set `LITELLM_CA_CERT_FILE` in `.env` to the path of the mkcert root CA `.pem` file:

```powershell
# Get the path from mkcert -CAROOT, then append /rootCA.pem
# e.g. LITELLM_CA_CERT_FILE=C:\Users\<user>\AppData\Local\mkcert\rootCA.pem
```

This is the same root CA file used for `CCGW_CA_CERT`. The compose file mounts it into
the container and the entrypoint installs it into the system trust store.

### Initial setup (one-time)

1. Generate a master key and set it in `.env`:
   ```powershell
   .\scripts\generate-litellm-key.ps1
   # Set LITELLM_MASTER_KEY=sk-<output> in .env
   ```

2. Generate a TLS cert and set LITELLM_TLS_DIR in `.env` to point at the cert directory:
   ```powershell
   mkcert localhost 127.0.0.1 ::1 <windows-host>
   # Set LITELLM_TLS_DIR=<path-to-cert-dir> in .env
   ```

3. Set the CA cert path in `.env`:
   ```powershell
   # Set LITELLM_CA_CERT_FILE=<mkcert -CAROOT>\rootCA.pem in .env
   ```

4. Start the LiteLLM container:
   ```powershell
   .\scripts\litellm-start.ps1 up
   ```

5. Wait a few seconds for the SQLite database tables to be created, then generate a
   scoped virtual key for client auth:
   ```powershell
   .\scripts\setup-litellm.ps1
   # Copy the returned key into .env as LITELLM_VIRTUAL_KEY
   ```

6. Restart the container so it picks up the new env vars:
   ```powershell
   .\scripts\litellm-start.ps1 restart
   ```

### Start LiteLLM

```powershell
.\scripts\litellm-start.ps1 up
```

This starts the container via `docker compose up -d`. The container listens on
`LITELLM_PORT` (default 8445) with TLS.

### Stop LiteLLM

```powershell
.\scripts\litellm-start.ps1 down
```

### Verify LiteLLM is running

```powershell
.\scripts\litellm-start.ps1 status
```

Or check the health endpoint directly:
```powershell
curl.exe -k https://localhost:8445/health/
```

### Verify routing

Send a test request to confirm each tier routes correctly. Use the **Anthropic
/v1/messages** endpoint (the format Claude Code sends) to verify LiteLLM's
Anthropic-to-OpenAI conversion works end-to-end:

```powershell
# Haiku tier (Anthropic format -- LiteLLM converts to OpenAI for llama-swap on this PC)
curl.exe -k -X POST https://localhost:8445/v1/messages -H 'Content-Type: application/json' -H 'x-api-key: <LITELLM_VIRTUAL_KEY>' -H 'anthropic-version: 2023-06-01' -d '{"model":"devstral-small-2-24b","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'

# Sonnet tier (Anthropic format -- LiteLLM converts to OpenAI for llama-swap on this PC)
curl.exe -k -X POST https://localhost:8445/v1/messages -H 'Content-Type: application/json' -H 'x-api-key: <LITELLM_VIRTUAL_KEY>' -H 'anthropic-version: 2023-06-01' -d '{"model":"qwen3-coder-30b-a3b","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'

# Opus tier (Anthropic format -- passthrough to DS4 Proxy)
curl.exe -k -X POST https://localhost:8445/v1/messages -H 'Content-Type: application/json' -H 'x-api-key: <LITELLM_VIRTUAL_KEY>' -H 'anthropic-version: 2023-06-01' -d '{"model":"deepseek-v4-flash","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
```

Note: Use the virtual key, NOT the master key. The `/v1/messages` endpoint confirms
LiteLLM receives Anthropic-format requests and converts Haiku/Sonnet to OpenAI for
llama-swap running on this PC. No fallback exists for these two tiers — a request
fails outright if llama-swap is offline.

### Client (Windows) with LiteLLM

First time only, ensure the repo-root `.env` has the LiteLLM vars filled in. The
`code-ccgw.ps1` launcher now prefers `LITELLM_ANTHROPIC_BASE_URL` over `CCGW_ANTHROPIC_BASE_URL`.

Set in `.env`:
```ini
LITELLM_ANTHROPIC_BASE_URL=https://<windows-host>:8445
LITELLM_VIRTUAL_KEY=sk-<generated-token>
```

Then launch as before:
```powershell
.\scripts\code-ccgw.ps1 .
```

### Recovery

| Symptom | Action |
|---------|--------|
| LiteLLM container not running | `litellm-start.ps1 up`; check Docker Desktop is running |
| `Connection refused` on :8445 | Verify container status; check port mapping |
| Haiku/Sonnet tier returns `Cannot connect to host host.docker.internal:18080` | llama-swap service is down on this PC (`nssm status llama-swap`); no fallback exists — start it and retry |
| DS4 Proxy unreachable | Verify <mac-host> Mac is reachable (<mac-lan-ip>); check DS4 Proxy status |
| TLS errors | Verify cert/key files exist in `LITELLM_TLS_DIR` and are mkcert-signed |
| TLS errors on Opus route | Verify `LITELLM_CA_CERT_FILE` points to the mkcert root CA and the file is mounted correctly |
| `401 Unauthorized` from LiteLLM | Verify `LITELLM_VIRTUAL_KEY` is set in `.env` and matches the generated key |
| `/key/generate` fails | Verify `DATABASE_URL` is set (SQLite configured in compose); wait for database initialisation |
| Keys lost after restart | Verify `litellm-postgres` volume persists; check `docker volume ls` for the named volume |

## Install llama-swap and Laguna S 2.1 (Mac, one-time)

llama-swap owns the full start/stop lifecycle of both ds4-server and Laguna's
`mlx_lm.server` (see [architecture.md](architecture.md#mac-backend-layer-llama-swap)); it must
be installed before either backend can be reached through the proxy.

Run the bundled installer, which installs llama-swap (via Homebrew) and `mlx-lm` from git
`main` (Laguna architecture support is not yet in a PyPI release), then scaffolds `.env`:
```sh
~/git/cc-local-llm/install.sh
```
It cannot download the Laguna model itself — confirm
`~/.lmstudio/models/poolside/Laguna-S-2.1-NVFP4-mlx` exists (via LM Studio or `huggingface-cli`)
before starting llama-swap. The individual steps live under
[install/mac/](../install/mac/) (`llama-swap.sh`, `mlx-lm.sh`) if you need to re-run just one.

`LLAMA_SWAP_HOST` / `LLAMA_SWAP_PORT` in `.env` default to `127.0.0.1:18080`, which matches
`DS4_PROXY_UPSTREAM` — leave them as-is unless you have a reason to change the port.

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

llama-swap is the DS4 Proxy's sole upstream; starting it makes both ds4-server and Laguna
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
~/git/cc-local-llm/scripts/serverctl.sh start all         # start proxy + llama-swap
~/git/cc-local-llm/scripts/serverctl.sh stop all          # stop both
~/git/cc-local-llm/scripts/serverctl.sh restart all       # restart both
~/git/cc-local-llm/scripts/serverctl.sh status all        # show status
~/git/cc-local-llm/scripts/serverctl.sh logs llama-swap   # tail llama-swap log (color in TTY)
~/git/cc-local-llm/scripts/serverctl.sh logs proxy        # tail ds4-proxy log
~/git/cc-local-llm/scripts/serverctl.sh logs all          # tail both logs
```

Targets: `proxy`, `llama-swap`, `all` (default when omitted). `server` (bare ds4-server) is a
separate manual-debug-only target, excluded from `all` — see above.

## Automatic startup (launchd)

Install both services as LaunchAgents (start at login, restart on crash):
```sh
~/git/cc-local-llm/scripts/serverctl.sh install all
```

Uninstall (stops the service and removes auto-start):
```sh
~/git/cc-local-llm/scripts/serverctl.sh uninstall all
```

Plist locations and labels:
- `~/Library/LaunchAgents/com.nire.ds4-proxy.plist` (`com.nire.ds4-proxy`)
- `~/Library/LaunchAgents/com.nire.ds4-llama-swap.plist` (`com.nire.ds4-llama-swap`)

`server` (bare ds4-server) has no plist — it is not launchd-installable; llama-swap starts and
stops it on demand instead.

KeepAlive=true means launchd restarts the service automatically on crash.

**DS4_LOG change requires reinstall**: the log paths are baked into the plist at install time.
After changing `DS4_LOG` in `.env`, run `serverctl install all` to regenerate the plist.

**Stopping a launchd-managed service**: `serverctl stop` will refuse with an error when the
service is launchd-managed (KeepAlive would restart it immediately anyway). Use
`serverctl uninstall <svc>` to stop and disable auto-start.

**Restarting a launchd-managed service**: `serverctl install <svc>` on its own is the restart —
`ds4_install()` (`scripts/lib/launchd.sh`) runs `_ds4_write_plist` → `launchctl unload` →
`launchctl load -w` in sequence. Do **not** do `uninstall` then `install`: the two-step form
only opens a window in which no LaunchAgent exists, and buys nothing.

**Run `install` from the checkout the plist should point at.** `_ds4_write_plist` bakes the
absolute path `$DS4_OPS_ROOT/scripts/<wrapper>.sh` into `ProgramArguments` (`ds4-proxy.sh`,
`ds4-server.sh`, or `llama-swap.sh` — see `_ds4_wrapper_script` in `scripts/lib/paths.sh`), and
`DS4_OPS_ROOT` is derived by `scripts/lib/root.sh` from the parent directory of the script
that was actually executed. Installing from a throwaway checkout (a git worktree, say) leaves
the LaunchAgent pointing at a path that disappears when that checkout is removed, and the
service then fails to start. Always run it from the everyday checkout (`~/git/cc-local-llm`).

**start vs stop asymmetry**: when launchd manages a service, `serverctl start` is a silent
no-op (informational — launchd's KeepAlive is already running it), while `serverctl stop`
returns an error (stopping would be immediately undone by KeepAlive, so the command refuses
to create that confusion). This asymmetry is intentional.

## Log control

Three independent toggles control different log streams:

| Toggle | Controls | off effect |
|---|---|---|
| `DS4_LOG` | Service stdout/stderr → `proxy.log` / `kvcache.log` | No disk write for these logs |
| `DS4_PROXY_TEE` | Proxy body-dump debug logs (`DS4_PROXY_LOG_DIR`) | No body-dump disk write |
| `DS4_SERVER_COLOR_LOG` | ANSI color in terminal output for ds4-server | Plain text in terminal |

`DS4_LOG=off` stops only the stdout/stderr log files. If `DS4_PROXY_TEE=on`, the proxy
still writes body-dump logs to `DS4_PROXY_LOG_DIR` — they are independent.

Log file paths: `~/Library/Logs/ds4-proxy/proxy.log` and `~/Library/Logs/llama-swap/llama-swap.log`
(ds4-server's own stdout/stderr flow through llama-swap into the latter file — see
`kvcache.log` under [Monitoring](#monitoring-mac) for the separate KV-cache log ds4-server writes
directly).

For color-highlighted live log viewing:
```sh
~/git/cc-local-llm/scripts/serverctl.sh logs llama-swap   # TTY: color; pipe/file: plain
```

## Client (Windows)

First time only, create the repo-root `.env` from the template and put the Mac's LAN IP in it
(the IP is never committed — `.env` is gitignored):
```powershell
Copy-Item .env.example .env
# then edit .env: CCGW_ANTHROPIC_BASE_URL=https://<mac-ip>:8443
# and CCGW_CA_CERT=<mkcert -CAROOT>\rootCA.pem (so Node trusts the proxy cert)
```
Then launch VS Code with the ds4 backend via the bundled wrapper:
```powershell
.\scripts\code-ccgw.ps1 .
```
The wrapper loads `.env`, then sets the ds4 env (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
the per-tier model aliases (the tier table under "Client (macOS / Linux)" applies here too),
`NODE_EXTRA_CA_CERTS` from `CCGW_CA_CERT`,
and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=65536` /
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`), then launches VS Code. The base URL now points at the
proxy (`https://<mac-ip>:8443`), not ds4 directly. If `CCGW_ANTHROPIC_BASE_URL` is set
in neither `.env` nor the shell, the wrapper warns and falls back to `https://localhost:8443`
(a placeholder that will not reach the Mac). A value set in the shell takes precedence over
`.env`. `CCGW_API_KEY` overrides the auth token; the proxy verifies it, so it must match
`DS4_PROXY_AUTH_TOKEN` on the Mac. `CCGW_CA_CERT` must point at `<mkcert -CAROOT>/rootCA.pem`
so Node trusts the proxy certificate (if unset the wrapper warns and TLS will not be trusted).

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
`CCGW_ANTHROPIC_BASE_URL` — closing one window is not enough; the process (and its captured
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
counterpart of `code-ccgw.ps1`. On the backend Mac this is the cheapest path of all: the proxy
is already on loopback, so no LiteLLM container and no LAN IP are involved.

One-time setup:
```bash
./install.sh --client     # installs mkcert (Linux: apt/dnf/pacman; Mac: Homebrew)
cp .env.example .env      # if not already present
```
Then fill in `.env`:
- **On the backend Mac:** `CCGW_ANTHROPIC_BASE_URL=https://127.0.0.1:8443` and
  `CCGW_API_KEY=<same value as DS4_PROXY_AUTH_TOKEN>`. `CCGW_CA_CERT` may be omitted — the
  wrapper falls back to `$(mkcert -CAROOT)/rootCA.pem`, which is already correct on the host
  that issued the certificate.
- **On another Linux host:** `CCGW_ANTHROPIC_BASE_URL=https://<mac-ip>:8443`, `CCGW_API_KEY`,
  and `CCGW_CA_CERT` pointing at a copy of the Mac's `rootCA.pem`.

Launch:
```bash
./scripts/code-ccgw.sh .
```

**Choosing the backend model.** On the direct path the model name is what the Mac swap layer
routes on, so it must be a name that layer knows (see
[llama-swap/config.yaml](../llama-swap/config.yaml)). The two backends sit on separate Claude
Code tiers, so `/model` is what switches between them:

| Tier | Backend |
|---|---|
| Fable | ds4 (`deepseek-v4-flash`) |
| Opus | Laguna S 2.1 (`laguna-s-2.1`) |
| Sonnet / Haiku | ds4 — the Mac hosts nothing smaller |

`CCGW_DEFAULT_MODEL` in `.env` only picks which backend is resident at launch. The two are
mutually exclusive: selecting the other tier unloads the resident model and cold-starts the
new one, so expect a long first response after each switch. Subagents follow the resident model
(`CLAUDE_CODE_SUBAGENT_MODEL` tracks `CCGW_DEFAULT_MODEL`) rather than the Opus tier for that
reason — a subagent on the other backend would evict the model the main session is using.

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
  -H "x-api-key: $DS4_PROXY_AUTH_TOKEN" \
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
