@echo off
setlocal

rem litellm launcher (Windows). Starts/stops the LiteLLM Docker container
rem for Claude Code model routing. Procedure: docs/ops.md#litellm.
rem
rem Usage:
rem   litellm-start.cmd up       -- start LiteLLM container
rem   litellm-start.cmd down     -- stop and remove LiteLLM container
rem   litellm-start.cmd restart  -- down then up
rem   litellm-start.cmd status   -- show container status
rem   (no args)                  -- same as "up"

rem Load repo-root .env (gitignored) for LITELLM_* vars. Compose parses the
rem full file itself via --env-file below (see ENV_FILE_ARG), so cmd never
rem full-file-parses .env anymore. Only the two vars that need the
rem localhost -> host.docker.internal rewrite (LITELLM_HAIKU_URL,
rem LITELLM_SONNET_URL) are individually extracted into the cmd shell here,
rem via the shared scripts\lib\load-env-var.cmd loader, which fails closed on
rem values containing a cmd metacharacter instead of silently mis-parsing them.
set "LITELLM_ENV_FILE=%~dp0..\.env"
set ENV_FILE_ARG=
if exist "%LITELLM_ENV_FILE%" set ENV_FILE_ARG=--env-file "%LITELLM_ENV_FILE%"

if exist "%LITELLM_ENV_FILE%" (
    call "%~dp0lib\load-env-var.cmd" "%LITELLM_ENV_FILE%" LITELLM_HAIKU_URL || exit /b 1
    call "%~dp0lib\load-env-var.cmd" "%LITELLM_ENV_FILE%" LITELLM_SONNET_URL || exit /b 1
)

rem Determine action from first argument
set "ACTION=%~1"
if not defined ACTION set "ACTION=up"

rem Compose file path (absolute Windows path)
set "COMPOSE_FILE=%~dp0..\litellm\docker-compose.yml"

rem Each tier URL is independently configurable in .env. Inside the container,
rem loopback resolves to the container itself, so rewrite loopback hosts (and only
rem those) to host.docker.internal. Non-loopback hosts are passed through unchanged,
rem so a tier pointed at another machine keeps working.
rem The Opus URL (LITELLM_OPUS_URL) is NOT overridden -- it uses the .env value
rem which points at <mac-host>'s LAN IP (<mac-lan-ip>:8443). Only llama-swap tiers
rem need the override.
if not defined LITELLM_HAIKU_URL set "LITELLM_HAIKU_URL=http://localhost:18080/v1"
if not defined LITELLM_SONNET_URL set "LITELLM_SONNET_URL=http://localhost:18080/v1"
set "LITELLM_HAIKU_URL=%LITELLM_HAIKU_URL:localhost=host.docker.internal%"
set "LITELLM_HAIKU_URL=%LITELLM_HAIKU_URL:127.0.0.1=host.docker.internal%"
set "LITELLM_SONNET_URL=%LITELLM_SONNET_URL:localhost=host.docker.internal%"
set "LITELLM_SONNET_URL=%LITELLM_SONNET_URL:127.0.0.1=host.docker.internal%"

if /i "%ACTION%"=="up" (
    echo [litellm] Starting LiteLLM container...
    docker compose %ENV_FILE_ARG% -f "%COMPOSE_FILE%" up -d
    if errorlevel 1 (
        echo [litellm] ERROR: docker compose up failed. Is Docker Desktop running?
        exit /b 1
    )
    echo [litellm] LiteLLM container started. Verify: docs/ops.md#litellm-verify.
    exit /b 0
)

if /i "%ACTION%"=="down" (
    echo [litellm] Stopping LiteLLM container...
    docker compose %ENV_FILE_ARG% -f "%COMPOSE_FILE%" down
    if errorlevel 1 (
        echo [litellm] WARNING: docker compose down returned non-zero (container may not exist).
        exit /b 1
    )
    echo [litellm] LiteLLM container stopped.
    exit /b 0
)

if /i "%ACTION%"=="restart" (
    echo [litellm] Restarting LiteLLM container...
    docker compose %ENV_FILE_ARG% -f "%COMPOSE_FILE%" down
    docker compose %ENV_FILE_ARG% -f "%COMPOSE_FILE%" up -d
    if errorlevel 1 (
        echo [litellm] ERROR: restart failed.
        exit /b 1
    )
    echo [litellm] LiteLLM container restarted.
    exit /b 0
)

if /i "%ACTION%"=="status" (
    docker container inspect ccgw-litellm --format "{{.State.Status}}" 2>nul
    if errorlevel 1 (
        echo [litellm] Container 'ccgw-litellm' does not exist or is not running.
    )
    exit /b 0
)

echo [litellm] Unknown action: "%ACTION%"
echo Usage: litellm-start.cmd {up^|down^|restart^|status}
exit /b 1
