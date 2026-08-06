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

rem Repo-root .env (gitignored) — passed directly to docker compose via --env-file
rem so that ${VAR} in docker-compose.yml is resolved without shell parsing.
set "LITELLM_ENV_FILE=%~dp0..\.env"

rem Determine action from first argument
set "ACTION=%~1"
if not defined ACTION set "ACTION=up"

rem Compose file path (absolute Windows path)
set "COMPOSE_FILE=%~dp0..\litellm\docker-compose.yml"

if /i "%ACTION%"=="up" (
    echo [litellm] Starting LiteLLM container...
    docker compose -f "%COMPOSE_FILE%" --env-file "%LITELLM_ENV_FILE%" up -d --force-recreate
    if errorlevel 1 (
        echo [litellm] ERROR: docker compose up failed. Is Docker Desktop running?
        exit /b 1
    )
    echo [litellm] LiteLLM container started. Verify: docs/ops.md#litellm-verify.
    exit /b 0
)

if /i "%ACTION%"=="down" (
    echo [litellm] Stopping LiteLLM container...
    docker compose -f "%COMPOSE_FILE%" --env-file "%LITELLM_ENV_FILE%" down
    if errorlevel 1 (
        echo [litellm] WARNING: docker compose down returned non-zero (container may not exist).
        exit /b 1
    )
    echo [litellm] LiteLLM container stopped.
    exit /b 0
)

if /i "%ACTION%"=="restart" (
    echo [litellm] Restarting LiteLLM container...
    docker compose -f "%COMPOSE_FILE%" --env-file "%LITELLM_ENV_FILE%" down
    docker compose -f "%COMPOSE_FILE%" --env-file "%LITELLM_ENV_FILE%" up -d --force-recreate
    if errorlevel 1 (
        echo [litellm] ERROR: restart failed.
        exit /b 1
    )
    echo [litellm] LiteLLM container restarted.
    exit /b 0
)

if /i "%ACTION%"=="status" (
    docker compose -f "%COMPOSE_FILE%" --env-file "%LITELLM_ENV_FILE%" ps 2>nul
    if errorlevel 1 (
        echo [litellm] Container 'ccgw-litellm' does not exist or is not running.
    )
    exit /b 0
)

echo [litellm] Unknown action: "%ACTION%"
echo Usage: litellm-start.cmd {up^|down^|restart^|status}
exit /b 1
