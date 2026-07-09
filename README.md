# ds4-ops (nirecom/ds4-ops)

Running **DeepSeek V4 Flash** via [`antirez/ds4`](https://github.com/antirez/ds4) as a
self-hosted **Claude Code backend**.

- **Server**: Mac (M5 Max, 128 GB) runs `ds4-server` on `:8000`. Speaks both the
  OpenAI and the Anthropic (`/v1/messages`) protocols.
- **Client**: Claude Code on Windows points `ANTHROPIC_BASE_URL` at the Mac.

> This repo holds only the **ops / config / decisions** for using ds4 as a Claude Code
> backend. The engine is the public upstream `antirez/ds4`, cloned separately at `~/git/ds4`
> on the Mac; the local directory here is `ds4-ops` to stay distinct from that clone.

## Docs

Standard layout (mirrors the agents-repo convention):

| File | Role |
|---|---|
| [docs/architecture.md](docs/architecture.md) | What/Why of the design — thinking control, hybrid routing, context-window model |
| [docs/tuning.md](docs/tuning.md) | Parameters — each flag/env var, its value, and why |
| [docs/ops.md](docs/ops.md) | How — run the server/client, monitoring, recovery |
| [docs/history.md](docs/history.md) | Completed work with why — incidents (write storm, sleep freeze) and decisions |
| [docs/infrastructure.md](docs/infrastructure.md) | SSOT for hosts, network, ports, paths |
| [scripts/ds4-start.sh](scripts/ds4-start.sh) | Canonical Mac start script |
| [scripts/claude-ds4.cmd](scripts/claude-ds4.cmd) | Windows client launcher — loads `.env`, sets ds4 env, isolates the VS Code process, launches VS Code |
| [.env.example](.env.example) | Template for the gitignored `.env` — Windows client `DS4_ANTHROPIC_BASE_URL` (Mac IP) and `DS4_API_KEY` |

## Quick start

**Mac (server):**
```sh
git -C ~/git/ds4 pull                 # update the antirez/ds4 build clone if needed
~/git/ds4-ops/scripts/ds4-start.sh
```

**Windows (client):** put the Mac's IP in a gitignored `.env` (first time only), then run the
bundled launcher (loads `.env`, sets the ds4 env, isolates the VS Code process, opens VS Code):
```bat
copy .env.example .env
rem edit .env: DS4_ANTHROPIC_BASE_URL=http://<mac-ip>:8000
scripts\claude-ds4.cmd .
```
See [docs/ops.md](docs/ops.md#client-windows) for details and the terminal alternative.

## Configuration at a glance

| Side | Setting | Value |
|---|---|---|
| Server | `--ctx` | `393216` |
| Server | `--quality` | on |
| Server | `--kv-disk-dir` | `~/Library/Caches/ds4-server/kv` |
| Client | `ANTHROPIC_BASE_URL` | `http://<mac-ip>:8000` |
| Client | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `393216` |
| Client | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` |

See [docs/tuning.md](docs/tuning.md) for the full reference and [docs/history.md](docs/history.md)
for why each value is what it is.
