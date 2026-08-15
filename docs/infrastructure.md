# Infrastructure

SSOT for hosts, network, ports, and paths. Other docs reference this — do not duplicate.

## Hosts

| Host | Role | Spec |
|---|---|---|
| Mac (this machine) | ds4-server / Laguna S 2.1 (backend, mutually exclusive) + llama-swap | MacBook Pro M5 Max, 128 GB unified memory |
| <windows-host> (Windows) | LiteLLM proxy + llama-swap | Windows 11, Docker Desktop WSL2 |
| windows-client | Claude Code client | Windows (same machine as <windows-host>) |

## Engine & model (on the Mac)

| Item | Value |
|---|---|
| Engine source | `antirez/ds4` cloned at `~/git/ds4` (public upstream; not owned) |
| Server binary | `~/git/ds4/ds4-server` |
| Model | `~/git/ds4/ds4flash.gguf` → DeepSeek V4 Flash, 2-bit imatrix quant (routed experts q2-q4), ~90.9 GB on disk |
| Weights resident (`--warm-weights`) | ~90.9 GB RSS |
| Laguna engine source | `mlx_lm.server` (Apple `mlx-lm`, must be installed from git `main` — Laguna architecture support is not yet in a PyPI release) |
| Laguna model | `~/.lmstudio/models/poolside/Laguna-S-2.1-NVFP4-mlx` → Laguna S 2.1, 4-bit NVFP4 MLX quant (poolside official export) |
| Laguna weights resident | ~72–90 GB RSS (depends on context length) |
| ds4 / Laguna exclusivity | Both together exceed 128 GB unified memory — Mac llama-swap keeps only one loaded at a time (default single-active-model behavior, no `groups:` block needed) |

## Network & ports

| Item | Value |
|---|---|
| Server listen (ds4-server) | dynamic port assigned by Mac llama-swap (`${PORT}` macro), loopback only |
| Laguna listen (mlx_lm.server) | dynamic port assigned by Mac llama-swap (`${PORT}` macro), loopback only |
| Mac llama-swap listen | `127.0.0.1:18080` (OpenAI+Anthropic-compatible, this Mac — model-process manager for ds4-server / Laguna) |
| Proxy listen | `0.0.0.0:8443` (HTTPS, TLS terminated, mkcert cert) |
| Proxy upstream | `http://127.0.0.1:18080` (Mac llama-swap directly) |
| Client base URL | `https://<mac-ip>:8443` (fill in the Mac's LAN IP) |
| Windows llama-swap listen | `127.0.0.1:18080` (OpenAI-compatible, <windows-host> — separate instance, Haiku/Sonnet tiers) |
| LiteLLM listen | `0.0.0.0:8445` (HTTPS, TLS terminated, mkcert cert, <windows-host>) |
| Client base URL (LiteLLM path) | `https://<windows-host>:8445` |
| DS4 Proxy listen | `0.0.0.0:8443` (HTTPS, <mac-host> Mac, reachable from WSL2 via LAN) |
| <mac-host> LAN IP | `<mac-lan-ip>` (for WSL2 container direct access) |
| Protocols served | `/v1/messages` (Anthropic), `/v1/chat/completions`, `/v1/completions`, `/v1/responses` (OpenAI), `/v1/models` |

## Paths (Mac)

| Item | Value |
|---|---|
| Unified control command | `~/git/cc-local-llm/scripts/serverctl.sh` (start/stop/restart/status/logs/install/uninstall) |
| Start script (manual debug only) | `~/git/cc-local-llm/scripts/ds4-server.sh` — not launchd-installed; llama-swap owns ds4-server's lifecycle |
| Proxy start script | `~/git/cc-local-llm/scripts/ds4-proxy.sh` |
| llama-swap start script | `~/git/cc-local-llm/scripts/llama-swap.sh` |
| Mac llama-swap config | `~/git/cc-local-llm/llama-swap/config.yaml` |
| Proxy TLS cert/key | `~/.config/ds4-proxy/cert.pem` / `key.pem` (mkcert-generated) |
| Client launcher (POSIX) | `~/git/cc-local-llm/scripts/code-ccgw.sh` (macOS/Linux counterpart of `code-ccgw.ps1`) |
| Client VS Code profile | `~/Library/Application Support/vscode-ccgw` (macOS), `${XDG_DATA_HOME:-~/.local/share}/vscode-ccgw` (Linux) |
| KV disk cache | `~/Library/Caches/ds4-server/kv` (persistent, Time Machine-excluded by macOS default) |
| Laguna model directory | `~/.lmstudio/models/poolside/Laguna-S-2.1-NVFP4-mlx` |

## Paths (Windows)

| Item | Value |
|---|---|
| LiteLLM config | `C:\git\cc-local-llm\litellm-client\config.yaml` |
| LiteLLM compose | `C:\git\cc-local-llm\litellm-client\docker-compose.yml` |
| LiteLLM start script | `C:\git\cc-local-llm\scripts\litellm-start.ps1` |
| LiteLLM setup script | `C:\git\cc-local-llm\scripts\setup-litellm.ps1` |
| LiteLLM TLS cert/key | `C:\Users\<user>\.config\litellm\cert.pem` / `key.pem` (mkcert-generated) |
| LiteLLM CA cert (Opus trust) | `<mkcert -CAROOT>\rootCA.pem` (same as CCGW_CA_CERT) |
| LiteLLM database volume | `litellm-postgres` (Docker named volume, PostgreSQL data at /var/lib/postgresql/data) |
| llama-swap config | `C:\LLM\llama-swap\config.yaml` (not in this repo) |
