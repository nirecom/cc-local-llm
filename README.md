# cc-local-llm (nirecom/cc-local-llm)

Running **DeepSeek V4 Flash** (via [`antirez/ds4`](https://github.com/antirez/ds4)) and
**Laguna S 2.1** (via `mlx_lm.server`, 4-bit NVFP4 MLX) as self-hosted **Claude Code
backends**, plus smaller local models (Devstral, Qwen3-Coder) for lighter tiers.

- **Mac (M5 Max, 128 GB)**: runs ds4-server and Laguna S 2.1, managed by **llama-swap**
  (`127.0.0.1:18080`) — mutually exclusive, since both together exceed 128 GB unified
  memory. A TLS reverse proxy (**DS4 Proxy**, `:8443`) sits in front for auth and
  prompt normalization; see [docs/architecture.md](docs/architecture.md).
- **Windows client**: Claude Code routes through **LiteLLM** (`litellm-client/`), which
  selects the tier by model name — Haiku/Sonnet to a local llama-swap on the same PC,
  Fable/Opus to the Mac's DS4 Proxy (Fable is ds4, Opus is Laguna S 2.1).

> This repo holds only the **ops / config / decisions** for using these engines as Claude
> Code backends. Both the GitHub repo and the local clone are named `cc-local-llm`
> (`~/git/cc-local-llm` on the Mac, `C:\git\cc-local-llm` on Windows).
> The ds4 engine itself is the public upstream `antirez/ds4`, a separate and unrelated
> repo, cloned on its own at `~/git/ds4`.

## Docs

Standard layout (mirrors the agents-repo convention):

| File | Role |
|---|---|
| [docs/architecture.md](docs/architecture.md) | What/Why of the design — reverse proxy, Mac backend layer (llama-swap), thinking control, hybrid routing |
| [docs/tuning.md](docs/tuning.md) | Parameters — each flag/env var, its value, and why |
| [docs/ops.md](docs/ops.md) | How — install/run the proxy, llama-swap, LiteLLM, monitoring, recovery |
| [docs/history.md](docs/history.md) | Completed work with why — incidents and decisions |
| [docs/infrastructure.md](docs/infrastructure.md) | SSOT for hosts, network, ports, paths |
| [scripts/serverctl.sh](scripts/serverctl.sh) | Unified Mac control command — `start\|stop\|restart\|status\|logs\|install\|uninstall [proxy\|llama-swap\|server\|all]` |
| [scripts/llama-swap.sh](scripts/llama-swap.sh) | Foreground launcher for llama-swap (thin wrapper; used by launchd) — owns ds4-server's and Laguna's lifecycle |
| [scripts/ds4-server.sh](scripts/ds4-server.sh) | Foreground launcher for ds4-server, manual debug only (llama-swap owns normal start/stop) |
| [scripts/code-ccgw.cmd](scripts/code-ccgw.cmd) | Windows client launcher — loads `.env`, sets ccgw env, isolates the VS Code process, launches VS Code |
| [scripts/code-ccgw.sh](scripts/code-ccgw.sh) | macOS/Linux client launcher — POSIX counterpart of `code-ccgw.cmd`; lets the backend Mac drive its own backend |
| [litellm-client/](litellm-client/) | Windows-side LiteLLM proxy config — model-tier routing |
| [install.sh](install.sh) / [install.ps1](install.ps1) | One-time prereq installers — `install.sh [--server\|--client\|--all]` (macOS/Linux), `install.ps1` (Windows) |
| [.env.example](.env.example) | Template for the gitignored `.env` |

## Quick start

**Mac (llama-swap + proxy):** one-time install of llama-swap and `mlx-lm`:
```sh
~/git/cc-local-llm/install.sh
```
See [docs/ops.md](docs/ops.md#install-llama-swap-and-laguna-s-21-mac-one-time) for what it does
and for the Laguna model download step it can't automate. Then:
```sh
git -C ~/git/ds4 pull                            # update the antirez/ds4 build clone if needed
~/git/cc-local-llm/scripts/serverctl.sh start all    # background; or 'install all' for auto-start at login
```

**Windows (client):** one-time install of Docker Desktop and mkcert, and `.env` scaffolding:
```powershell
.\install.ps1
```
Then edit `.env` (Mac's IP and auth token: `CCGW_ANTHROPIC_BASE_URL`, `CCGW_CA_CERT`,
`CCGW_API_KEY`) and run the bundled launcher (loads `.env`, sets the ds4 env, isolates the
VS Code process, opens VS Code):
```bat
scripts\code-ccgw.cmd .
```
See [docs/ops.md](docs/ops.md#client-windows) for details and the terminal alternative, or
[docs/ops.md](docs/ops.md#litellm-windows-docker-desktop-wsl2) to route through LiteLLM instead
for multi-tier (Haiku/Sonnet/Fable/Opus) model selection.

**macOS / Linux (client):** the backend Mac can drive its own backend, and so can any Linux
host on the LAN:
```sh
./install.sh --client      # mkcert only; no Docker unless you also host LiteLLM
./scripts/code-ccgw.sh .
```
On the Mac itself, point `CCGW_ANTHROPIC_BASE_URL` at `https://127.0.0.1:8443` and leave
`CCGW_CA_CERT` empty — the launcher derives the CA from `mkcert -CAROOT`. The two backends sit
on separate tiers, so `/model` switches between them: **Fable** is ds4, **Opus** is Laguna S 2.1.
`CCGW_DEFAULT_MODEL` only picks which one is resident at startup.
See [docs/ops.md](docs/ops.md#client-macos--linux).

## Configuration at a glance

| Side | Setting | Value |
|---|---|---|
| Server | `--ctx` | `393216` |
| Server | `--quality` | on |
| Server | `--kv-disk-dir` | `~/Library/Caches/ds4-server/kv` |
| Mac llama-swap | listen | `127.0.0.1:18080` |
| Proxy | listen | `0.0.0.0:8443` (TLS) |
| Client | `CCGW_ANTHROPIC_BASE_URL` | `https://<mac-ip>:8443` |
| Client | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `393216` |
| Client | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` |

See [docs/tuning.md](docs/tuning.md) for the full reference, [docs/infrastructure.md](docs/infrastructure.md)
for hosts/ports/paths, and [docs/history.md](docs/history.md) for why each value is what it is.
