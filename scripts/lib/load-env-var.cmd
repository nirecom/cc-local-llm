@echo off
rem Shared .env single-variable loader for cmd scripts (issue #31).
rem
rem Extracts one KEY=value line via findstr -- never a full-file parse -- so a
rem special cmd character elsewhere in .env cannot break the caller's parsing.
rem Fails closed when the matched value contains a character that could break
rem out of the quoted argument for/f hands to `call` below: an unbalanced
rem double quote in the value lets a following &, |, or > be parsed as new
rem command syntax instead of literal text (command injection via the .env
rem file). A pure `set` inside the for/f body has the identical breakout, so
rem this check must run before the value is ever substituted into a command
rem line -- it is done here via findstr against the raw file, never against a
rem cmd-substituted variable.
rem
rem Usage: call "<path-to-this-file>" "<env-file-path>" VARNAME
rem No-op (leaves VARNAME unset, errorlevel 0) when the env file does not
rem exist, VARNAME is already defined in the caller's environment (caller
rem values win), or no matching line is found. Exits with errorlevel 1 (via
rem `call`, so only this invocation is aborted -- the caller decides whether
rem to propagate) when the matched value contains an unsafe character, or
rem when the validation check itself could not run (fail closed, not open).
if defined %~2 exit /b 0
if not exist "%~1" exit /b 0

findstr /b /r /c:"%~2=.*[&|^<>\"]" "%~1" >nul 2>nul
if errorlevel 2 (
    echo [load-env-var] ERROR: validation of %~2 could not run -- refusing to load.
    exit /b 1
)
if not errorlevel 1 (
    echo [load-env-var] ERROR: %~2 in .env contains an unsafe character ^(one of ^& ^| ^^ ^< ^> or a double quote^) -- refusing to load.
    exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"%~2=" "%~1" 2^>nul`) do call :strip_quotes_and_set %~2 "%%B"
exit /b 0

:strip_quotes_and_set
setlocal EnableDelayedExpansion
set "_v=%~2"
set "_v=!_v:"=!"
endlocal & set "%~1=%_v%"
goto :eof
