# Infrastructure

SSOT for hosts, network, ports, and paths. Other docs reference this — do not duplicate.

## Hosts

| Host | Role | Spec |
|---|---|---|
| Mac (this machine) | ds4-server (backend) | MacBook Pro M5 Max, 128 GB unified memory |
| <windows-host> (Windows) | LiteLLM proxy + llama-swap | Windows 11, Docker Desktop WSL2 |
| windows-client | Claude Code client | Windows (same machine as <windows-host>) |

## Engine & model (on the Mac)

| Item | Value |
|---|---|
| Engine source | `antirez/ds4` cloned at `~/git/ds4` (public upstream; not owned) |
| Server binary | `~/git/ds4/ds4-server` |
| Model | `~/git/ds4/ds4flash.gguf` → DeepSeek V4 Flash, 2-bit imatrix quant (routed experts q2-q4), ~90.9 GB on disk |
| Weights resident (`--warm-weights`) | ~90.9 GB RSS |

## Network & ports

| Item | Value |
|---|---|
| Server listen | `127.0.0.1:8000` (loopback only — proxy is the LAN endpoint) |
| Proxy listen | `0.0.0.0:8443` (HTTPS, TLS terminated, mkcert cert) |
| Client base URL | `https://<mac-ip>:8443` (fill in the Mac's LAN IP) |
| llama-swap listen | `127.0.0.1:18080` (OpenAI-compatible, <windows-host>) |
| LiteLLM listen | `0.0.0.0:8445` (HTTPS, TLS terminated, mkcert cert, <windows-host>) |
| Client base URL (LiteLLM path) | `https://<windows-host>:8445` |
| DS4 Proxy listen | `0.0.0.0:8443` (HTTPS, <mac-host> Mac, reachable from WSL2 via LAN) |
| <mac-host> LAN IP | `<mac-lan-ip>` (for WSL2 container direct access) |
| Protocols served | `/v1/messages` (Anthropic), `/v1/chat/completions`, `/v1/completions`, `/v1/responses` (OpenAI), `/v1/models` |

## Paths (Mac)

| Item | Value |
|---|---|
| Start script | `~/git/ds4-ops/scripts/ds4-server.sh` |
| Proxy start script | `~/git/ds4-ops/scripts/ds4-proxy.sh` |
| Proxy TLS cert/key | `~/.config/ds4-proxy/cert.pem` / `key.pem` (mkcert-generated) |
| KV disk cache | `~/Library/Caches/ds4-server/kv` (persistent, Time Machine-excluded by macOS default) |

## Paths (Windows)

| Item | Value |
|---|---|
| LiteLLM config | `C:\git\ds4-ops\litellm\config.yaml` |
| LiteLLM compose | `C:\git\ds4-ops\litellm\docker-compose.yml` |
| LiteLLM start script | `C:\git\ds4-ops\scripts\litellm-start.cmd` |
| LiteLLM setup script | `C:\git\ds4-ops\scripts\setup-litellm.cmd` |
| LiteLLM TLS cert/key | `C:\Users\<user>\.config\litellm\cert.pem` / `key.pem` (mkcert-generated) |
| LiteLLM CA cert (Opus trust) | `<mkcert -CAROOT>\rootCA.pem` (same as DS4_CA_CERT) |
| LiteLLM database volume | `litellm-data` (Docker named volume, persists at /app/litellm/data) |
| llama-swap config | `C:\LLM\llama-swap\config.yaml` (not in this repo) |
