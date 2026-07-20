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

rem Load repo-root .env (gitignored) for LITELLM_* vars
set "LITELLM_ENV_FILE=%~dp0..\.env"
if exist "%LITELLM_ENV_FILE%" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%LITELLM_ENV_FILE%") do (
        if not defined %%A set "%%A=%%B"
    )
)

rem Determine action from first argument
set "ACTION=%~1"
if not defined ACTION set "ACTION=up"

rem Compose file path (absolute Windows path)
set "COMPOSE_FILE=%~dp0..\litellm\docker-compose.yml"

rem Override LITELLM_LLAMA_SWAP_URL with host.docker.internal for container networking.
rem Inside the Docker container, localhost resolves to the container itself, not the
rem Windows host. Docker Desktop provides host.docker.internal to reach the Windows host.
rem The DS4 Proxy URL (LITELLM_DS4_URL) is NOT overridden -- it uses the .env value
rem which points at <mac-host>'s LAN IP (<mac-lan-ip>:8443). Only llama-swap needs the override.
set "LITELLM_LLAMA_SWAP_URL=http://host.docker.internal:18080/v1"

if /i "%ACTION%"=="up" (
    echo [litellm] Starting LiteLLM container...
    docker compose -f "%COMPOSE_FILE%" up -d
    if errorlevel 1 (
        echo [litellm] ERROR: docker compose up failed. Is Docker Desktop running?
        exit /b 1
    )
    echo [litellm] LiteLLM container started. Verify: docs/ops.md#litellm-verify.
    exit /b 0
)

if /i "%ACTION%"=="down" (
    echo [litellm] Stopping LiteLLM container...
    docker compose -f "%COMPOSE_FILE%" down
    if errorlevel 1 (
        echo [litellm] WARNING: docker compose down returned non-zero (container may not exist).
        exit /b 1
    )
    echo [litellm] LiteLLM container stopped.
    exit /b 0
)

if /i "%ACTION%"=="restart" (
    echo [litellm] Restarting LiteLLM container...
    docker compose -f "%COMPOSE_FILE%" down
    docker compose -f "%COMPOSE_FILE%" up -d
    if errorlevel 1 (
        echo [litellm] ERROR: restart failed.
        exit /b 1
    )
    echo [litellm] LiteLLM container restarted.
    exit /b 0
)

if /i "%ACTION%"=="status" (
    docker container inspect ds4-litellm --format "{{.State.Status}}" 2>nul
    if errorlevel 1 (
        echo [litellm] Container 'ds4-litellm' does not exist or is not running.
    )
    exit /b 0
)

echo [litellm] Unknown action: "%ACTION%"
echo Usage: litellm-start.cmd {up^|down^|restart^|status}
exit /b 1
