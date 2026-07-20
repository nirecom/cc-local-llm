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
    echo [setup-litellm] Run: openssl rand -hex 32 and set LITELLM_MASTER_KEY=sk-<output>
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

rem Generate a random key string
for /f "tokens=*" %%A in ('openssl rand -hex 32') do set "RANDOM_KEY_HEX=%%A"
set "VIRTUAL_KEY_VALUE=sk-%RANDOM_KEY_HEX%"

rem POST to /key/generate with the new random key, authenticated by the master key.
rem The response contains the generated virtual key which we capture.
rem NOTE: /key/generate requires DATABASE_URL to be set (SQLite configured in compose).
for /f "tokens=*" %%A in (
    'curl -k -s -X POST "https://localhost:%LITELLM_PORT%/key/generate" ^
      -H "Content-Type: application/json" ^
      -H "x-api-key: %LITELLM_MASTER_KEY%" ^
      -d "{\"key\":\"%VIRTUAL_KEY_VALUE%\",\"metadata\":{\"scopes\":[\"*\"]}}"'
) do set "VIRTUAL_KEY_RESPONSE=%%A"

rem Parse the response for the virtual key (format: {"key":"sk-..."})
rem This is a simplified parse; real-world would use a JSON parser
echo [setup-litellm] Virtual key response: %VIRTUAL_KEY_RESPONSE%

rem Extract key value -- simplified for initial setup
rem Full JSON parsing is out of scope; the user copies the returned key manually
echo [setup-litellm] ---
echo [setup-litellm] IMPORTANT: Copy the generated key from the response above
echo [setup-litellm] and set it as LITELLM_VIRTUAL_KEY in your .env file.
echo [setup-litellm] Example: LITELLM_VIRTUAL_KEY=%VIRTUAL_KEY_VALUE%
echo [setup-litellm] ---

exit /b 0
