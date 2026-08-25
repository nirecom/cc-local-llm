# cc-local-llm (nirecom/cc-local-llm)

Running **DeepSeek V4 Flash** (via [`antirez/ds4`](https://github.com/antirez/ds4)) and
**Laguna S 2.1** (via `mlx_lm.server`, 4-bit NVFP4 MLX) as self-hosted **Claude Code
backends**, plus smaller local models (Devstral, Qwen3-Coder) for lighter tiers.

- **Mac (M5 Max, 128 GB)**: runs ds4-server and Laguna S 2.1, managed by **llama-swap**
  (`127.0.0.1:18080`) — mutually exclusive, since both together exceed 128 GB unified
  memory. A TLS reverse proxy (**CCGW Proxy**, `:8443`) sits in front for auth and
  prompt normalization; see [docs/architecture.md](docs/architecture.md).
- **LiteLLM gateway (Mac, `:8445`)**: the single endpoint every client talks to, configured in
  `litellm-server/`. It selects the tier by model name — Haiku/Sonnet to the Windows PC's
  llama-swap, Fable/Opus to the Mac's CCGW Proxy (Fable is ds4, Opus is the `.env`-selected
  `mlx_lm.server` backend) — and is
  the only place the Anthropic wire format is converted.
- **Clients (Windows, macOS, Linux)**: Claude Code points at the gateway and nothing else.

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
| [docs/ops.md](docs/ops.md) | How — install/run the proxy, llama-swap, the LiteLLM gateway, monitoring, recovery |
| [docs/history.md](docs/history.md) | Completed work with why — incidents and decisions |
| [docs/infrastructure.md](docs/infrastructure.md) | SSOT for hosts, network, ports, paths |
| [scripts/serverctl.sh](scripts/serverctl.sh) | Unified Mac control command — `start\|stop\|restart\|status\|logs\|install\|uninstall [proxy\|llama-swap\|litellm\|server\|all]` |
| [scripts/llama-swap.sh](scripts/llama-swap.sh) | Foreground launcher for llama-swap (thin wrapper; used by launchd) — owns ds4-server's and Laguna's lifecycle |
| [scripts/litellm.sh](scripts/litellm.sh) | Foreground launcher for the LiteLLM gateway (thin wrapper; used by launchd) |
| [scripts/ds4-server.sh](scripts/ds4-server.sh) | Foreground launcher for ds4-server, manual debug only (llama-swap owns normal start/stop) |
| [scripts/code-ccgw.ps1](scripts/code-ccgw.ps1) | Windows client launcher (pwsh) — loads `.env`, sets ccgw env, isolates the VS Code process, launches VS Code |
| [scripts/code-ccgw.sh](scripts/code-ccgw.sh) | macOS/Linux client launcher — POSIX counterpart of `code-ccgw.ps1`; lets the backend Mac drive its own backend |
| [litellm-server/](litellm-server/) | LiteLLM gateway config — model-tier routing and protocol conversion |
| [install.sh](install.sh) / [install.ps1](install.ps1) | One-time prereq installers — `install.sh [--server\|--client\|--all]` (macOS/Linux), `install.ps1` (Windows) |
| [.env.example](.env.example) | Template for the gitignored `.env` |

## Quick start

**Mac (server):** one-time install of llama-swap, the LiteLLM gateway and `mlx-lm`:
```sh
~/git/cc-local-llm/install.sh
```
See [docs/ops.md](docs/ops.md#install-llama-swap-and-laguna-s-21-mac-one-time) for what it does
and for the Laguna model download step it can't automate, and
[docs/ops.md](docs/ops.md#litellm-gateway-mac) for the gateway's one-time key/TLS setup. Then:
```sh
git -C ~/git/ds4 pull                            # update the antirez/ds4 build clone if needed
~/git/cc-local-llm/scripts/serverctl.sh start all    # proxy + llama-swap + litellm; or 'install all' for auto-start at login
```

**Windows (client):** one-time install of mkcert and `.env` scaffolding:
```powershell
.\install.ps1
```
Then edit `.env` (`LITELLM_ANTHROPIC_BASE_URL`, `LITELLM_CLIENT_KEY`, `CCGW_CA_CERT`) and run the
bundled launcher (loads `.env`, sets the ccgw env, isolates the VS Code process, opens VS Code):
```powershell
.\scripts\code-ccgw.ps1 .
```
See [docs/ops.md](docs/ops.md#client-windows) for details and the terminal alternative.

**macOS / Linux (client):** the backend Mac can drive its own backend, and so can any Linux
host on the LAN:
```sh
./install.sh --client      # mkcert only
./scripts/code-ccgw.sh .
```
On the Mac itself, point `LITELLM_ANTHROPIC_BASE_URL` at `https://127.0.0.1:8445` and leave
`CCGW_CA_CERT` empty — the launcher derives the CA from `mkcert -CAROOT`. Each tier is its own
route, so `/model` switches backends: **Fable** is ds4 and **Opus** is the `.env`-selected Mac
backend (mutually exclusive with ds4), **Sonnet**/**Haiku** are the Windows PC's smaller models.
See [docs/ops.md](docs/ops.md#client-macos--linux).

## Configuration at a glance

| Side | Setting | Value |
|---|---|---|
| Server | `--ctx` | `393216` |
| Server | `--quality` | on |
| Server | `--kv-disk-dir` | `~/Library/Caches/ds4-server/kv` |
| Mac llama-swap | listen | `127.0.0.1:18080` |
| Proxy | listen | `0.0.0.0:8443` (TLS) |
| LiteLLM gateway | listen | `0.0.0.0:8445` (TLS) |
| Client | `LITELLM_ANTHROPIC_BASE_URL` | `https://<mac-lan-ip>:8445` |
| Client | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `393216` |
| Client | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` |

See [docs/tuning.md](docs/tuning.md) for the full reference, [docs/infrastructure.md](docs/infrastructure.md)
for hosts/ports/paths, and [docs/history.md](docs/history.md) for why each value is what it is.
