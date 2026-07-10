@echo off
setlocal

rem ds4 client launcher (Windows). Sets the ds4 backend env, isolates the VS Code
rem process so the env does not bleed into native subscription windows, then launches
rem VS Code. Rationale: docs/architecture.md; procedure: docs/ops.md#client-windows.

rem Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
rem Format: KEY=value, one per line, # comment lines allowed. A value already set in
rem the shell takes precedence over .env. See .env.example for the supported keys.
set "DS4_ENV_FILE=%~dp0..\.env"
if exist "%DS4_ENV_FILE%" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%DS4_ENV_FILE%") do (
        if not defined %%A set "%%A=%%B"
    )
)

rem Clear any real Anthropic API key so the ds4 server is used instead
set ANTHROPIC_API_KEY=

rem ds4 server base URL. The real Mac LAN IP is NOT committed (public repo): put
rem DS4_ANTHROPIC_BASE_URL=http://<mac-ip>:8000 in the repo-root .env (or set it in the
rem shell). The default below is a placeholder (localhost) and will not reach the Mac.
if defined DS4_ANTHROPIC_BASE_URL (
    set ANTHROPIC_BASE_URL=%DS4_ANTHROPIC_BASE_URL%
) else (
    echo [code-ds4] WARNING: DS4_ANTHROPIC_BASE_URL not set; using placeholder default http://localhost:8000 ^(will not reach the Mac ds4 server^).
    set ANTHROPIC_BASE_URL=http://localhost:8000
)

rem ds4 server auth token. ds4 does not authenticate, so any non-empty value works
rem (override with DS4_API_KEY env var).
if defined DS4_API_KEY (
    set ANTHROPIC_AUTH_TOKEN=%DS4_API_KEY%
) else (
    set ANTHROPIC_AUTH_TOKEN=dsv4-local
)

set ANTHROPIC_MODEL=deepseek-v4-flash
set ANTHROPIC_CUSTOM_MODEL_OPTION=deepseek-v4-flash
set ANTHROPIC_CUSTOM_MODEL_OPTION_NAME=DeepSeek V4 Flash local ds4
set ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION=ds4.c local GGUF
set ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash
rem Haiku is the lightweight/mechanical tier (titles, quick background tasks); map it to the
rem non-thinking alias so it stays fast and cheap. Thinking-control model names: docs/tuning.md.
set ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-chat
set ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash
set CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash

set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
set CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
set CLAUDE_STREAM_IDLE_TIMEOUT_MS=600000

rem Align auto-compaction with ds4's real ceiling so it fires before ds4 rejects the
rem conversation with 400 context_length_exceeded. Values: docs/tuning.md.
set CLAUDE_CODE_AUTO_COMPACT_WINDOW=393216
set CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75

rem Launch VS Code in an isolated process. A distinct --user-data-dir starts a separate
rem VS Code instance; VS Code otherwise shares one process (and one environment) across
rem all windows of a user-data-dir, which would leak the ds4 env into native windows.
code --user-data-dir "%LOCALAPPDATA%\vscode-ds4" %*
