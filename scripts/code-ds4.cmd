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

rem LiteLLM proxy base URL. If LITELLM_ANTHROPIC_BASE_URL is set, the launcher uses
rem LiteLLM's TLS endpoint. Otherwise falls back to the DS4 Proxy path.
rem When neither is set, uses a placeholder default (localhost:8445).
if defined LITELLM_ANTHROPIC_BASE_URL (
    set "ANTHROPIC_BASE_URL=%LITELLM_ANTHROPIC_BASE_URL%"
) else if defined DS4_ANTHROPIC_BASE_URL (
    set "ANTHROPIC_BASE_URL=%DS4_ANTHROPIC_BASE_URL%"
) else (
    echo [code-ds4] WARNING: Neither LITELLM_ANTHROPIC_BASE_URL nor DS4_ANTHROPIC_BASE_URL set.
    set "ANTHROPIC_BASE_URL=https://localhost:8445"
)

rem LiteLLM authentication. Use a scoped virtual key generated from the master key,
rem NOT the master key itself. The virtual key is set up via scripts/setup-litellm.cmd.
rem If no virtual key is available, fall back to DS4_API_KEY for direct proxy auth.
if defined LITELLM_VIRTUAL_KEY (
    set "ANTHROPIC_AUTH_TOKEN=%LITELLM_VIRTUAL_KEY%"
) else if defined DS4_API_KEY (
    set "ANTHROPIC_AUTH_TOKEN=%DS4_API_KEY%"
) else (
    echo [code-ds4] WARNING: Neither LITELLM_VIRTUAL_KEY nor DS4_API_KEY set.
    set "ANTHROPIC_AUTH_TOKEN=dsv4-local"
)

rem mkcert local CA root so Node trusts the proxy TLS certificate. Set DS4_CA_CERT to
rem the path printed by "mkcert -CAROOT"/rootCA.pem. NODE_TLS_REJECT_UNAUTHORIZED=0 is
rem NOT used.
if defined DS4_CA_CERT (
    set NODE_EXTRA_CA_CERTS=%DS4_CA_CERT%
) else (
    echo [code-ds4] WARNING: DS4_CA_CERT not set; TLS certificate will not be trusted.
)

rem Model aliases for Claude Code.
rem When LITELLM_ANTHROPIC_BASE_URL is set, use LITELLM_*_MODEL routing keys.
rem When falling back to DS4 Proxy, always use deepseek-* originals so that
rem DS4 Proxy receives model names it understands (deepseek-v4-flash, deepseek-chat).
rem The LITELLM_*_MODEL vars are LiteLLM-specific routing keys that DS4 Proxy
rem does not recognise -- never send them to DS4 Proxy.
if defined LITELLM_ANTHROPIC_BASE_URL (
    if defined LITELLM_OPUS_MODEL (
        set "ANTHROPIC_MODEL=%LITELLM_OPUS_MODEL%"
        set "ANTHROPIC_DEFAULT_OPUS_MODEL=%LITELLM_OPUS_MODEL%"
        set "ANTHROPIC_CUSTOM_MODEL_OPTION=%LITELLM_OPUS_MODEL%"
    )
    if defined LITELLM_SONNET_MODEL (
        set "ANTHROPIC_DEFAULT_SONNET_MODEL=%LITELLM_SONNET_MODEL%"
    )
    if defined LITELLM_HAIKU_MODEL (
        set "ANTHROPIC_DEFAULT_HAIKU_MODEL=%LITELLM_HAIKU_MODEL%"
    )
    if defined LITELLM_OPUS_MODEL (
        set "CLAUDE_CODE_SUBAGENT_MODEL=%LITELLM_OPUS_MODEL%"
    )
) else (
    rem Fall back to deepseek-* originals (backward compatible with old .env files)
    set "ANTHROPIC_MODEL=deepseek-v4-flash"
    set "ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash"
    set "ANTHROPIC_CUSTOM_MODEL_OPTION=deepseek-v4-flash"
    set "ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash"
    set "ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-chat"
    set "CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash"
)
set "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME=DeepSeek V4 Flash local ds4"
set "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION=ds4.c local GGUF"

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
