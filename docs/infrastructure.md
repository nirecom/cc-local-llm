# Infrastructure

SSOT for hosts, network, ports, and paths. Other docs reference this — do not duplicate.

## Hosts

| Host | Role | Spec |
|---|---|---|
| Mac (this machine) | ds4-server (backend) | MacBook Pro M5 Max, 128 GB unified memory |
| windows-client | Claude Code client | Windows |

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
| Server listen | `0.0.0.0:8000` (LAN, no auth — trusted network only) |
| Client base URL | `http://<mac-ip>:8000` (fill in the Mac's LAN IP) |
| Protocols served | `/v1/messages` (Anthropic), `/v1/chat/completions`, `/v1/completions`, `/v1/responses` (OpenAI), `/v1/models` |

## Paths (Mac)

| Item | Value |
|---|---|
| Start script | `~/git/ds4-ops/scripts/ds4-server.sh` |
| KV disk cache | `~/Library/Caches/ds4-server/kv` (persistent, Time Machine-excluded by macOS default) |
