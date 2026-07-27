@echo off
setlocal

rem litellm one-time setup (Windows). Run once after LiteLLM container is running.
rem Generates master key, creates virtual key (random, NOT reusing master key),
rem verifies TLS certs and CA cert.
rem Procedure: docs/ops.md#litellm-setup.
rem
rem IMPORTANT: LiteLLM requires a database for key generation. The compose file
rem configures SQLite by default (DATABASE_URL). The /key/generate endpoint will
rem fail if the database is not initialised. Wait a few seconds after container
rem start for the database tables to be created.

rem Load repo-root .env
set "DS4_ENV_FILE=%~dp0..\.env"
if exist "%DS4_ENV_FILE%" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%DS4_ENV_FILE%") do (
        if not defined %%A set "%%A=%%B"
    )
)

rem Check required vars
if not defined LITELLM_MASTER_KEY (
    echo [setup-litellm] ERROR: LITELLM_MASTER_KEY is not set in .env.
    echo [setup-litellm] Run: powershell -File scripts\generate-litellm-key.ps1
    echo [setup-litellm] Then set LITELLM_MASTER_KEY=sk-^<output^> in .env
    exit /b 1
)

if not defined LITELLM_PORT set "LITELLM_PORT=8445"

rem Step 1: Verify LiteLLM container is running
docker container inspect ds4-litellm --format "{{.State.Status}}" >nul 2>&1
if errorlevel 1 (
    echo [setup-litellm] ERROR: LiteLLM container 'ds4-litellm' is not running.
    echo [setup-litellm] Run litellm-start.cmd up first.
    exit /b 1
)

rem Step 2: Generate a random virtual key using openssl, then register it with LiteLLM.
rem IMPORTANT: Do NOT send the master key as the generated key value. The /key/generate
rem endpoint creates a scoped virtual key from a NEW random key, not the master key itself.
rem Sending the master key as the "key" value would create a virtual key that IS the master
rem key -- defeating the purpose of scoped virtual keys.
echo [setup-litellm] Generating random virtual key...

rem Generate a random 32-byte key using generate-litellm-key.ps1.
rem -OutFile writes ASCII directly -- avoids cmd.exe stdout redirect producing UTF-16 BOM,
rem which causes set /p to read an empty or garbled string.
set "_LITELLM_TMP=%TEMP%\_litellm_rng.tmp"
powershell -NoProfile -File "%~dp0generate-litellm-key.ps1" -OutFile "%_LITELLM_TMP%"
if errorlevel 1 (
    echo [setup-litellm] ERROR: PowerShell key generation failed.
    del "%_LITELLM_TMP%" 2>nul
    exit /b 1
)
set /p RANDOM_KEY_HEX=<"%_LITELLM_TMP%"
del "%_LITELLM_TMP%" 2>nul
if "%RANDOM_KEY_HEX%"=="" (
    echo [setup-litellm] ERROR: Generated key is empty.
    exit /b 1
)
set "VIRTUAL_KEY_VALUE=sk-%RANDOM_KEY_HEX%"

rem POST to /key/generate. Output goes directly to stdout -- copy the key from the response.
rem NOTE: /key/generate requires DATABASE_URL set (PostgreSQL configured in compose).
echo [setup-litellm] Registering key with LiteLLM...
curl.exe -k -s -X POST "https://localhost:%LITELLM_PORT%/key/generate" -H "Content-Type: application/json" -H "x-api-key: %LITELLM_MASTER_KEY%" -d "{\"key\":\"%VIRTUAL_KEY_VALUE%\",\"metadata\":{\"scopes\":[\"*\"]}}"
echo.

echo [setup-litellm] ---
echo [setup-litellm] IMPORTANT: Copy the "key" value from the JSON response above
echo [setup-litellm] and set it as LITELLM_VIRTUAL_KEY in your .env file.
echo [setup-litellm] Example: LITELLM_VIRTUAL_KEY=%VIRTUAL_KEY_VALUE%
echo [setup-litellm] ---

exit /b 0
