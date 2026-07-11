# Ops

Day-to-day procedures. Parameter rationale is in [tuning.md](tuning.md); hosts/ports in
[infrastructure.md](infrastructure.md).

## Run the proxy (Mac)

The proxy is the sole LAN-visible endpoint (TLS termination + prompt normalization + token
auth); ds4-server itself listens on loopback. Rationale:
[architecture.md](architecture.md#reverse-proxy-layer).

One-time mkcert setup (issues a locally-trusted TLS cert for the proxy):
```sh
brew install mkcert
mkcert -install                              # install the local CA into the system trust store
mkdir -p ~/.config/ds4-proxy
mkcert -cert-file ~/.config/ds4-proxy/cert.pem -key-file ~/.config/ds4-proxy/key.pem localhost <mac-lan-ip>
```

Add the shared auth token to the server-side `.env` (repo root, gitignored):
```sh
# .env: DS4_PROXY_AUTH_TOKEN=<generated-secret>   (generate with /create-key)
```

Start the proxy (foreground; refuses to start if `DS4_PROXY_AUTH_TOKEN` is unset):
```sh
~/git/ds4-ops/scripts/ds4-proxy.sh
```

Client-side (Windows): set `DS4_CA_CERT` to `<mkcert -CAROOT>/rootCA.pem` in the repo-root
`.env` so Node trusts the proxy certificate, and set `DS4_API_KEY` to the same value as
`DS4_PROXY_AUTH_TOKEN`.

## Run the server (Mac)

```sh
mkdir -p ~/Library/Caches/ds4-server/kv     # first time only
~/git/ds4-ops/scripts/ds4-server.sh
```

Runs in the foreground. For background:
```sh
nohup ~/git/ds4-ops/scripts/ds4-server.sh > ~/ds4-server.log 2>&1 &
```

Stop:
```sh
kill "$(pgrep -f ds4-server)"
```

`caffeinate` is baked into the script and exits with the server; no separate step.

## Client (Windows)

First time only, create the repo-root `.env` from the template and put the Mac's LAN IP in it
(the IP is never committed — `.env` is gitignored):
```bat
copy .env.example .env
rem then edit .env: DS4_ANTHROPIC_BASE_URL=https://<mac-ip>:8443
rem and DS4_CA_CERT=<mkcert -CAROOT>\rootCA.pem (so Node trusts the proxy cert)
```
Then launch VS Code with the ds4 backend via the bundled wrapper:
```bat
scripts\code-ds4.cmd .
```
The wrapper loads `.env`, then sets the ds4 env (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
the `deepseek-v4-flash` model aliases (the haiku tier uses the non-thinking `deepseek-chat`),
`NODE_EXTRA_CA_CERTS` from `DS4_CA_CERT`,
and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=393216` /
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75`), then launches VS Code. The base URL now points at the
proxy (`https://<mac-ip>:8443`), not ds4 directly. If `DS4_ANTHROPIC_BASE_URL` is set
in neither `.env` nor the shell, the wrapper warns and falls back to `https://localhost:8443`
(a placeholder that will not reach the Mac). A value set in the shell takes precedence over
`.env`. `DS4_API_KEY` overrides the auth token; the proxy verifies it, so it must match
`DS4_PROXY_AUTH_TOKEN` on the Mac. `DS4_CA_CERT` must point at `<mkcert -CAROOT>/rootCA.pem`
so Node trusts the proxy certificate (if unset the wrapper warns and TLS will not be trusted).

**Isolation from native (subscription) VS Code:** the wrapper passes
`--user-data-dir "%LOCALAPPDATA%\vscode-ds4"`, starting a *separate* VS Code process. VS Code
shares one process — and thus one environment — across every window under the same
user-data-dir, so without this flag the ds4 env bleeds into native subscription windows. The
separate profile keeps the ds4 session and native `code` / `codes` sessions independent on the
same machine. Extensions are shared (`--user-data-dir` isolates settings/state, not
`~/.vscode/extensions`), so the Claude Code extension is already available in the ds4 profile.
Do not add ds4 env vars to native sessions: a bare `ANTHROPIC_BASE_URL` plus a credential
replaces the subscription (see
[architecture.md](architecture.md#two-strategies-chosen-by-whether-real-opus-is-wanted)).
Caveat: if the ds4 profile is already running, close *all* its windows before changing
`DS4_ANTHROPIC_BASE_URL` — closing one window is not enough; the process (and its captured
environment) persists until the last window of the profile closes, and new windows inherit the
old value. The same folder may be open in the native and ds4 profiles at the same time: the
"reuse the existing window for this folder" dedup is per-profile, so `codes .` followed by
`code-ds4.cmd .` on one repo yields two independent windows (native backend + ds4 backend),
not one activated window.

Terminal alternative (no VS Code): set the same env vars the wrapper does
(see [scripts/code-ds4.cmd](../scripts/code-ds4.cmd) for the full list) and run `claude`.

Optional per-tier thinking split: also set the `ANTHROPIC_DEFAULT_*_MODEL` vars from
[tuning.md](tuning.md#per-tier-thinking-split-without-a-router-optional).

**Verify connectivity:** after launch, run `/context` and confirm CC reports a window near
393216 (not 200K / 1M). Grow the conversation and confirm auto-compaction fires *before* ds4
returns `400 context_length_exceeded`.

## Monitoring (Mac)

| Check | Command |
|---|---|
| Sleep events (should be none while serving) | `pmset -g log \| grep -i "entering sleep"` |
| KV cache size | `du -sh ~/Library/Caches/ds4-server/kv` |
| Memory pressure / swap | `sysctl vm.swapusage` |
| Thinking on/off per request | grep the server log for `THINKING` in the `chat ...` lines |
| Process alive / one instance | `pgrep -fl ds4-server` |

## Recovery

| Symptom | Action |
|---|---|
| `400 context_length_exceeded` | Client conversation grew past ctx. `/compact`, or `/clear`, or raise `--ctx` and restart (the running conversation then fits). |
| `error during compaction` | The compaction request itself exceeds ctx. Ensure `CLAUDE_CODE_AUTO_COMPACT_WINDOW` + `PCT_OVERRIDE` are set so compaction fires *before* the ceiling; otherwise `/clear` or restart the server at higher ctx so the current conversation fits, then compact. |
| Server unresponsive / client API errors after idle | Check `pmset -g log` for a sleep window. caffeinate should prevent it; confirm the process is still wrapped. |
| `kv cache evicted reason=disk-cache-full` | Normal capacity management — not an error. Ignore. |

## Enable Think Max (accuracy option)

All three required (see [tuning.md](tuning.md#think-max-3-conditions-all-required)):
1. `--ctx >= 393216` ✅ (current config)
2. Thinking on (model resolves to `deepseek-reasoner` or default, not `deepseek-chat`)
3. **Client sends `effort=max`** — CC defaults to `xhigh`→HIGH, so this is the missing piece;
   verify CC can be set to max and forwards it before expecting Think Max.
