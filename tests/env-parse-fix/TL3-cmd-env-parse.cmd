@echo off
setlocal EnableExtensions
rem =============================================================================
rem TL3-cmd-env-parse.cmd -- tests for scripts\lib\load-env-var.cmd, the shared
rem .env single-variable loader introduced to fix issue #31 (H1: command
rem injection via an unescaped double-quote in a .env value breaking out of a
rem `call` argument; H2: the previous version of this test file re-executed
rem whole caller scripts instead of a label, with dangerous side effects).
rem
rem SCOPE / SAFETY CONTRACT (read this before editing):
rem   - This file calls scripts\lib\load-env-var.cmd DIRECTLY, by its own file
rem     path, with synthetic fixture .env files created below. That is the
rem     only "seam" under test.
rem   - This file NEVER reads the real repo-root .env (gitignored, may contain
rem     live credentials) -- every fixture below lives under a fresh directory
rem     under %TEMP%, and no code path here references "%~dp0..\..\.env" or
rem     any other real config path.
rem   - This file NEVER invokes scripts\litellm-start.cmd, scripts\code-ccgw.cmd,
rem     or scripts\setup-litellm.cmd, end to end or otherwise. Those three are
rem     multi-purpose entry points (they start Docker containers, launch VS
rem     Code, and POST to a live LiteLLM /key/generate endpoint with the real
rem     master key) and are explicitly OUT OF SCOPE for this TL3 seam test.
rem     A prior version of this file called them via
rem     `call "%%SCRIPT%%" :load_env_var VAR`, wrongly assuming that jumps to a
rem     label inside the target file. cmd.exe has no such mechanism: that
rem     `call` form re-executes the ENTIRE target file from line 1 with
rem     %%1=":load_env_var" and %%2="VAR" -- on a real Windows run this read the
rem     developer's real .env, launched VS Code repeatedly, and minted a live
rem     LiteLLM API key. See the security report referenced in this issue's
rem     session history for the full writeup (findings H2, M1-M5). This
rem     rewrite tests scripts\lib\load-env-var.cmd directly instead, which is a
rem     standalone, side-effect-free file safe to call repeatedly.
rem
rem TIER / GATING (rules/test.md): TL3 -- real cmd.exe environment, single
rem component/seam (the shared loader). Not part of the default macOS/POSIX
rem test run. On a real Windows machine or Windows CI runner:
rem     set RUN_TL3=1
rem     tests\env-parse-fix\TL3-cmd-env-parse.cmd
rem The RUN_TL3 check below is this file's own self-gate (belt-and-suspenders
rem for anyone double-clicking it by accident); a Windows CI job is still
rem expected to set RUN_TL3=1 explicitly before invoking it.
rem
rem VERIFICATION: this file has NEVER been executed -- it was authored on
rem macOS, which has no cmd.exe/wine/dosbox/mono available (checked). Every
rem assertion below is preceded by a `rem DESK-CHECK:` block tracing
rem findstr, for /f, set, call, and quote-toggle behavior by hand against
rem scripts\lib\load-env-var.cmd's real source, in place of "run until green".
rem Do not treat a clean read-through as equivalent to a passing run --
rem treat this as reviewed-but-unrun until a Windows machine/CI runner
rem actually executes it and reports PASS/FAIL. Residual desk-check
rem uncertainty (called out again inline where it occurs, in case this
rem comment block is skimmed): the fixture lines that embed a caret-escaped
rem double-quote character (^") inside an otherwise-unquoted `echo` command
rem (used for scenarios S5, S11, Q1, Q2 below) rest on the documented cmd.exe
rem idiom that `^"` outside quotes yields a literal `"` without toggling
rem quote-parsing state, the same escaping family already used successfully
rem elsewhere in this file (and in the prior version of it) for ^&, ^|, ^^.
rem This specific character (^") was not exercised in the prior version of
rem this file, so it carries relatively more desk-check risk than the other
rem escapes here; verify those four scenarios' fixture files first (e.g. via
rem `type`) if a real run produces unexpected output.
rem
rem Fixtures: synthetic temp .env files generated below via `>`/`>>`
rem redirection under a per-run, collision-checked directory. NEVER copies or
rem reads the real (gitignored) repo-root .env. Cleaned up unconditionally
rem before this file exits, on every exit path.
rem
rem Scenario summary (S = "must load"/"must be rejected" against
rem scripts\lib\load-env-var.cmd directly; see each block for detail):
rem   S1  unquoted value with no special chars loads verbatim
rem   S2  value with ";" and "\" (a Windows cert-path style value) loads
rem       verbatim, unchanged -- confirms benign characters are not
rem       over-blocked by the new fail-closed check
rem   S3  quoted value (VAR="value") -- REJECTED. NOTE: this documents a real
rem       behavior change from the pre-fix loader (which stripped quotes) --
rem       see the S3 block below for why
rem   S4  quoted value containing an internal space -- REJECTED (this is the
rem       new, correct behavior superseding the old M3 truncation bug; see
rem       the S4 block for the desk-check reasoning)
rem   S5  bare double-quote in an otherwise plain value -- REJECTED (core H1
rem       regression test)
rem   S6  bare "&" -- REJECTED
rem   S7  bare "|" -- REJECTED
rem   S8  bare "^" -- REJECTED
rem   S9  bare "<" -- REJECTED
rem   S10 bare ">" -- REJECTED
rem   S11 realistic injection payload (quote + "&" combined, mirroring the
rem       security report's `abc" & whoami & "` example) -- REJECTED, AND a
rem       marker file the payload would have created if executed is confirmed
rem       absent
rem   S12 a value already `set` by the caller before the call takes
rem       precedence over .env and is never overwritten -- even when the
rem       .env file's same-named value is itself unsafe, proving the
rem       precedence check runs before the unsafe-character check; also
rem       asserts errorlevel 0 on this no-op path (N1 regression coverage)
rem   S13 missing .env file -- no-op, no error, errorlevel 0 asserted (N1
rem       regression coverage)
rem   S14 VARNAME absent from an existing .env file -- no-op, no error,
rem       errorlevel 0 asserted (N1 regression coverage)
rem =============================================================================

if not "%RUN_TL3%"=="1" (
    echo [TL3-cmd-env-parse] SKIP: RUN_TL3 not set to 1. This is a TL3 test intended
    echo [TL3-cmd-env-parse] for a real Windows machine or Windows CI runner only.
    exit /b 0
)

set "SCRIPT_DIR=%~dp0"
set "LOADER=%SCRIPT_DIR%..\..\scripts\lib\load-env-var.cmd"

if not exist "%LOADER%" (
    echo [TL3-cmd-env-parse] ERROR: loader not found at "%LOADER%" -- did scripts\lib\load-env-var.cmd move?
    exit /b 1
)

rem -----------------------------------------------------------------------
rem Fixture directory: collision-checked (aborts rather than silently
rem reusing a pre-existing/colliding directory -- fix for M4), cleaned up
rem unconditionally at :cleanup below.
rem -----------------------------------------------------------------------
set "FIXTURE_DIR=%TEMP%\tl3-env-parse-fix-%RANDOM%-%RANDOM%-%~n0"
if exist "%FIXTURE_DIR%" (
    echo [TL3-cmd-env-parse] ERROR: fixture directory already exists, aborting rather than reusing it: "%FIXTURE_DIR%"
    exit /b 1
)
mkdir "%FIXTURE_DIR%"
if errorlevel 1 (
    echo [TL3-cmd-env-parse] ERROR: failed to create fixture directory: "%FIXTURE_DIR%"
    exit /b 1
)

set "FIXTURE_NORMAL=%FIXTURE_DIR%\normal.env"
set "FIXTURE_UNSAFE=%FIXTURE_DIR%\unsafe.env"
set "FIXTURE_QUOTED=%FIXTURE_DIR%\quoted.env"
set "MARKER_FILE=%FIXTURE_DIR%\injection-should-never-create-this.marker"
set "MISSING_FIXTURE=%FIXTURE_DIR%\does-not-exist.env"

set /a FAIL_COUNT=0

rem =========================================================================
rem Fixture: normal.env -- benign values only, no forbidden characters.
rem =========================================================================
rem N7 fix: leading-redirect form avoids two compounding bugs at once -- a
rem trailing space before `>` would be captured as part of the echoed value
rem (unlike most other commands, `echo` treats a preceding space as literal
rem output text, not as separator-then-discarded), but the value here also
rem ends in a bare digit ("v1"), which cmd would otherwise misparse as an
rem explicit file-handle number immediately before `>` (the original N5 bug).
rem Putting the redirection before the command sidesteps both: the target
rem file is opened first, and none of the echoed text (including its
rem trailing digit) is ever seen by the redirect-operator scanner.
>"%FIXTURE_NORMAL%" echo PLAIN_URL_VAR=http://localhost:18080/v1
echo CERT_PATH_VAR=C:\certs;backup\rootCA.pem>> "%FIXTURE_NORMAL%"

rem =========================================================================
rem Fixture: unsafe.env -- one forbidden character per line, plus one
rem realistic combined injection payload line (S11). Each special character
rem is written via caret-escaping (^X) so that THIS script's own unquoted
rem `echo ... >> file` command line treats it as literal output data instead
rem of a cmd operator -- the same technique the prior version of this file
rem already used successfully for ^&, ^^, ^| (see its scenario 1 fixture).
rem `^"` for a literal double-quote is the one escape not previously
rem exercised in this file; see the top-of-file VERIFICATION note.
rem =========================================================================
echo SIMPLE_QUOTE_VAR=abc^"def> "%FIXTURE_UNSAFE%"
echo SIMPLE_AMP_VAR=abc^&def>> "%FIXTURE_UNSAFE%"
echo SIMPLE_PIPE_VAR=abc^|def>> "%FIXTURE_UNSAFE%"
echo SIMPLE_CARET_VAR=abc^^def>> "%FIXTURE_UNSAFE%"
echo SIMPLE_LT_VAR=abc^<def>> "%FIXTURE_UNSAFE%"
echo SIMPLE_GT_VAR=abc^>def>> "%FIXTURE_UNSAFE%"
rem The combined payload below mirrors the security report's H1 reproduction
rem string (`CCGW_API_KEY=abc" & whoami & "`), adapted to attempt writing
rem MARKER_FILE instead of running whoami, so a successful (i.e. NOT rejected)
rem injection would be independently observable via the filesystem rather
rem than only via stdout. `"%MARKER_FILE%"` below is a real, unescaped,
rem *balanced* quote pair (open before the path, close after) so cmd expands
rem %MARKER_FILE% normally inside it; every other quote/ampersand on the line
rem is caret-escaped literal data. Net quote-toggle effect of the whole line
rem is balanced (zero), so it does not disturb the trailing real `>>`
rem redirection that actually writes this file.
echo INJECT_PAYLOAD_VAR=abc^" ^& echo INJECTED^>"%MARKER_FILE%" ^& ^">> "%FIXTURE_UNSAFE%"

rem =========================================================================
rem Fixture: quoted.env -- well-formed VAR="value" style lines (the syntax
rem the OLD loader used to accept and strip quotes from). Under the new
rem fail-closed check these are expected to be REJECTED (see S3/S4): the
rem unsafe-character check runs before quote-stripping and its forbidden set
rem includes a bare `"` with no balance/context awareness (confirmed by
rem load-env-var.cmd's own error message text, line 31: "one of & | ^ < > or
rem a double quote" -- i.e. the literal quote character is itself always
rem unsafe, regardless of whether it is part of a well-formed pair).
rem =========================================================================
echo QUOTED_PLAIN_VAR=^"hello^"> "%FIXTURE_QUOTED%"
echo QUOTED_SPACE_VAR=^"hello world^">> "%FIXTURE_QUOTED%"

rem =========================================================================
rem S1: unquoted value with no special characters round-trips unchanged.
rem =========================================================================
rem DESK-CHECK (load-env-var.cmd lines 21-30): PLAIN_URL_VAR is undefined
rem going in, so line 21's `if defined %~2 goto :eof` does not fire. The file
rem exists, so line 22 does not fire either. Line 24's unsafe-character
rem regex `%~2=.*[&|^<>\"]` cannot match this line -- it contains none of
rem & | ^ < > " -- so the fail-closed branch (lines 25-28) is skipped. Line
rem 30's for/f with `tokens=1,* delims==` extracts token 1 = "PLAIN_URL_VAR"
rem and token 2 (%%B, everything after the FIRST "=") =
rem "http://localhost:18080/v1", then calls :strip_quotes_and_set, whose
rem `!_v:"=!` global-quote-strip is a no-op here (no quotes present), and
rem `endlocal & set "PLAIN_URL_VAR=..."` makes the value visible back in
rem THIS script's environment (no setlocal wraps load-env-var.cmd itself, so
rem the value genuinely escapes the call).
set "PLAIN_URL_VAR="
call "%LOADER%" "%FIXTURE_NORMAL%" PLAIN_URL_VAR
if "%PLAIN_URL_VAR%"=="http://localhost:18080/v1" (
    echo PASS S1-unquoted-value-loads
) else (
    echo FAIL S1-unquoted-value-loads: value did not match expected
    call :report_redacted PLAIN_URL_VAR
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S2: a value containing ";" and "\" (neither is in the forbidden set)
rem loads unchanged and is not truncated at the semicolon.
rem =========================================================================
rem DESK-CHECK: same code path as S1. Neither ";" nor "\" appears in the
rem unsafe-character class `[&|^<>\"]` (that class's own backslash is a
rem cmd-level artifact of embedding a literal `"` into the /c: argument, not
rem a member of the class itself -- confirmed by the printed error text on
rem line 31, which names exactly six forbidden characters: & | ^ < > and
rem "a double quote"). `delims==` in the for/f means only "=" splits tokens,
rem so ";" and "\" stay inside token 2 as ordinary data.
set "CERT_PATH_VAR="
call "%LOADER%" "%FIXTURE_NORMAL%" CERT_PATH_VAR
if "%CERT_PATH_VAR%"=="C:\certs;backup\rootCA.pem" (
    echo PASS S2-semicolon-backslash-not-truncated
) else (
    echo FAIL S2-semicolon-backslash-not-truncated: value did not match expected
    call :report_redacted CERT_PATH_VAR
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S3: quoted value (VAR="value") is REJECTED, not stripped-and-loaded.
rem =========================================================================
rem DESK-CHECK: this documents a real, intentional-looking behavior change
rem from the pre-fix loader. QUOTED_PLAIN_VAR="hello" contains two `"`
rem characters. Line 24's regex `QUOTED_PLAIN_VAR=.*[&|^<>\"]` matches this
rem line (the trailing `"` after "hello" satisfies the character class), so
rem the fail-closed branch at lines 25-28 fires: an ERROR line is printed and
rem `exit /b 1` runs -- via `call`, this only aborts the load-env-var.cmd
rem invocation, propagating errorlevel 1 back to this test script.
rem :strip_quotes_and_set (lines 33-38) is never reached for this fixture,
rem which matches the source's own line 6-7 comment describing quote
rem stripping there as now-defensive code operating on values that are
rem "(now guaranteed-absent, but the code still defensively strips)" quotes.
set "QUOTED_PLAIN_VAR="
call "%LOADER%" "%FIXTURE_QUOTED%" QUOTED_PLAIN_VAR
if errorlevel 1 (
    if defined QUOTED_PLAIN_VAR (
        echo FAIL S3-quoted-value-rejected: loader reported rejection but QUOTED_PLAIN_VAR became defined anyway
        call :report_redacted QUOTED_PLAIN_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S3-quoted-value-rejected
    )
) else (
    echo FAIL S3-quoted-value-rejected: loader returned success for a quoted value; expected rejection ^(errorlevel 1^)
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S4: quoted value containing an internal space is REJECTED. This is the
rem new, correct behavior that replaces the old M3 bug (silent truncation of
rem `VAR="value with space"` at the first space, which used to fail TLS
rem trust open for CCGW_CA_CERT-style values). Under the new loader, the
rem whole value is refused up front instead of being silently mangled.
rem =========================================================================
rem DESK-CHECK: identical reasoning to S3 -- the two `"` characters in
rem QUOTED_SPACE_VAR="hello world" trip the same unsafe-character regex
rem before the for/f (and therefore before any tokens=1,* delims== space
rem handling) ever runs, so the internal space is irrelevant to the outcome:
rem the value is rejected wholesale rather than truncated.
set "QUOTED_SPACE_VAR="
call "%LOADER%" "%FIXTURE_QUOTED%" QUOTED_SPACE_VAR
if errorlevel 1 (
    if defined QUOTED_SPACE_VAR (
        echo FAIL S4-quoted-value-with-space-rejected: loader reported rejection but QUOTED_SPACE_VAR became defined anyway
        call :report_redacted QUOTED_SPACE_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S4-quoted-value-with-space-rejected
    )
) else (
    echo FAIL S4-quoted-value-with-space-rejected: loader returned success for a quoted+spaced value; expected rejection ^(errorlevel 1^)
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S5-S10: one forbidden character each, in isolation. Core H1 regression
rem coverage -- every character load-env-var.cmd's own error message names
rem (& | ^ < > ") must independently trigger rejection.
rem =========================================================================
rem DESK-CHECK (shared across S5-S10): each fixture line is
rem "VARNAME=abcXdef" where X is the one forbidden character under test.
rem Line 24's regex `VARNAME=.*[&|^<>\"]` matches any line starting with
rem "VARNAME=" that contains at least one of the six class members anywhere
rem afterward -- exactly one occurrence is sufficient to trigger the
rem fail-closed branch, so each of these is expected to behave like S3/S4.

set "SIMPLE_QUOTE_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_QUOTE_VAR
if errorlevel 1 (
    if defined SIMPLE_QUOTE_VAR (
        echo FAIL S5-bare-quote-rejected: SIMPLE_QUOTE_VAR became defined despite rejection
        call :report_redacted SIMPLE_QUOTE_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S5-bare-quote-rejected
    )
) else (
    echo FAIL S5-bare-quote-rejected: loader returned success for a value containing a double quote; expected rejection
    set /a FAIL_COUNT+=1
)

set "SIMPLE_AMP_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_AMP_VAR
if errorlevel 1 (
    if defined SIMPLE_AMP_VAR (
        echo FAIL S6-bare-ampersand-rejected: SIMPLE_AMP_VAR became defined despite rejection
        call :report_redacted SIMPLE_AMP_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S6-bare-ampersand-rejected
    )
) else (
    echo FAIL S6-bare-ampersand-rejected: loader returned success for a value containing ^&; expected rejection
    set /a FAIL_COUNT+=1
)

set "SIMPLE_PIPE_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_PIPE_VAR
if errorlevel 1 (
    if defined SIMPLE_PIPE_VAR (
        echo FAIL S7-bare-pipe-rejected: SIMPLE_PIPE_VAR became defined despite rejection
        call :report_redacted SIMPLE_PIPE_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S7-bare-pipe-rejected
    )
) else (
    echo FAIL S7-bare-pipe-rejected: loader returned success for a value containing ^|; expected rejection
    set /a FAIL_COUNT+=1
)

set "SIMPLE_CARET_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_CARET_VAR
if errorlevel 1 (
    if defined SIMPLE_CARET_VAR (
        echo FAIL S8-bare-caret-rejected: SIMPLE_CARET_VAR became defined despite rejection
        call :report_redacted SIMPLE_CARET_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S8-bare-caret-rejected
    )
) else (
    echo FAIL S8-bare-caret-rejected: loader returned success for a value containing ^^; expected rejection
    set /a FAIL_COUNT+=1
)

set "SIMPLE_LT_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_LT_VAR
if errorlevel 1 (
    if defined SIMPLE_LT_VAR (
        echo FAIL S9-bare-lt-rejected: SIMPLE_LT_VAR became defined despite rejection
        call :report_redacted SIMPLE_LT_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S9-bare-lt-rejected
    )
) else (
    echo FAIL S9-bare-lt-rejected: loader returned success for a value containing ^<; expected rejection
    set /a FAIL_COUNT+=1
)

set "SIMPLE_GT_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_GT_VAR
if errorlevel 1 (
    if defined SIMPLE_GT_VAR (
        echo FAIL S10-bare-gt-rejected: SIMPLE_GT_VAR became defined despite rejection
        call :report_redacted SIMPLE_GT_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S10-bare-gt-rejected
    )
) else (
    echo FAIL S10-bare-gt-rejected: loader returned success for a value containing ^>; expected rejection
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S11: realistic combined injection payload is rejected AND produces no
rem observable side effect (MARKER_FILE is never created). This is the
rem direct regression test for H1 as originally reported.
rem =========================================================================
rem DESK-CHECK: INJECT_PAYLOAD_VAR's value contains multiple forbidden
rem characters (", &, >), so line 24's regex matches robustly -- the test
rem does not depend on getting the exact escaping of any single character
rem right, only on at least one forbidden character surviving into the
rem fixture file, which several redundant characters here provide. Per the
rem load-env-var.cmd header comment (lines 6-13), this check runs via
rem findstr against the RAW FILE, never against a cmd-substituted variable,
rem so the injected text is never handed to `call`/`set` as command syntax
rem regardless of how the check itself matches.
set "INJECT_PAYLOAD_VAR="
call "%LOADER%" "%FIXTURE_UNSAFE%" INJECT_PAYLOAD_VAR
if errorlevel 1 (
    if defined INJECT_PAYLOAD_VAR (
        echo FAIL S11-injection-payload-rejected: INJECT_PAYLOAD_VAR became defined despite rejection
        call :report_redacted INJECT_PAYLOAD_VAR
        set /a FAIL_COUNT+=1
    ) else (
        echo PASS S11-injection-payload-rejected
    )
) else (
    echo FAIL S11-injection-payload-rejected: loader returned success for the injection payload; expected rejection
    set /a FAIL_COUNT+=1
)
if exist "%MARKER_FILE%" (
    echo FAIL S11b-injection-payload-no-side-effect: MARKER_FILE was created -- the injected command executed
    set /a FAIL_COUNT+=1
) else (
    echo PASS S11b-injection-payload-no-side-effect
)

rem =========================================================================
rem S12: a value already `set` by the caller before calling the loader takes
rem precedence and is never overwritten -- even when the .env file's value
rem for the same name is itself unsafe. This proves the precedence check
rem (line 22) runs strictly before the unsafe-character check (line 25), so
rem a caller-provided value can never trigger a spurious rejection either.
rem Also asserts errorlevel 0 on this no-op path -- the direct regression
rem test for N1 (this is the "VARNAME already defined" no-op path; before
rem the N1 fix, `exit /b 0` on line 22 did not exist and the prior code's
rem `goto :eof` here left errorlevel latched at whatever a PRECEDING findstr
rem call in the caller's own script last set, which every real caller
rem observed as a false failure via `... || exit /b 1`).
rem =========================================================================
rem DESK-CHECK: line 22, `if defined %~2 exit /b 0`, is the very first
rem statement in load-env-var.cmd. When SIMPLE_QUOTE_VAR is already defined
rem going in, this line fires immediately and the whole rest of the file
rem (including the unsafe-character regex and the for/f extraction) never
rem runs at all -- fixture.unsafe.env's differing (and unsafe) value for the
rem same key cannot reach this variable under any circumstance. `exit /b 0`
rem sets errorlevel to 0 explicitly and returns control to this caller (via
rem `call`), so an errorlevel-0 assertion here is a direct, deterministic
rem check of the N1 fix rather than an incidental side effect.
set "SIMPLE_QUOTE_VAR=PRESET_FROM_CALLER"
call "%LOADER%" "%FIXTURE_UNSAFE%" SIMPLE_QUOTE_VAR
set "S12_ERRORLEVEL=%errorlevel%"
if "%SIMPLE_QUOTE_VAR%"=="PRESET_FROM_CALLER" (
    echo PASS S12-caller-value-takes-precedence
) else (
    echo FAIL S12-caller-value-takes-precedence: value changed from the caller-preset value
    call :report_redacted SIMPLE_QUOTE_VAR
    set /a FAIL_COUNT+=1
)
if "%S12_ERRORLEVEL%"=="0" (
    echo PASS S12b-caller-value-precedence-errorlevel-0
) else (
    echo FAIL S12b-caller-value-precedence-errorlevel-0: expected errorlevel 0 on the no-op path but got %S12_ERRORLEVEL% ^(N1 regression^)
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S13: missing .env file is a no-op -- no error, VARNAME stays unset, and
rem errorlevel is explicitly 0 (N1 regression coverage: this is the "env
rem file missing" no-op path fixed by N1).
rem =========================================================================
rem DESK-CHECK: line 23, `if not exist "%~1" exit /b 0`, fires because
rem MISSING_FIXTURE was never created by this script. `exit /b 0` explicitly
rem sets errorlevel to 0 and returns to this caller (via `call`) -- before
rem the N1 fix this was a bare `goto :eof` immediately after line 22's `if
rem defined` check, so errorlevel here reflected whatever the calling
rem script's environment last set it to, not a deterministic 0. Both the
rem "variable stays undefined" check and the new errorlevel-0 check below
rem are direct regression coverage for N1.
set "NEVER_SET_MISSING_FILE_VAR="
call "%LOADER%" "%MISSING_FIXTURE%" NEVER_SET_MISSING_FILE_VAR
set "S13_ERRORLEVEL=%errorlevel%"
if defined NEVER_SET_MISSING_FILE_VAR (
    echo FAIL S13-missing-env-file-is-noop: variable unexpectedly became defined
    call :report_redacted NEVER_SET_MISSING_FILE_VAR
    set /a FAIL_COUNT+=1
) else (
    echo PASS S13-missing-env-file-is-noop
)
if "%S13_ERRORLEVEL%"=="0" (
    echo PASS S13b-missing-env-file-errorlevel-0
) else (
    echo FAIL S13b-missing-env-file-errorlevel-0: expected errorlevel 0 on the no-op path but got %S13_ERRORLEVEL% ^(N1 regression^)
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem S14: VARNAME not present in an existing .env file is a no-op, and
rem errorlevel is explicitly 0 (N1 regression coverage: this is the
rem "VARNAME absent from the file" no-op path fixed by N1 -- the findstr
rem call on line 25 that precedes this path can itself exit 1 on no match,
rem and the prior code's `goto :eof` after the for/f loop left that 1
rem latched instead of normalizing it to a deterministic success code).
rem =========================================================================
rem DESK-CHECK: the file exists, so line 23 does not fire; line 25's
rem findstr /b /r /c:"NEVER_DEFINED_VAR=.*[&|^<>\"]" finds no matching line
rem in FIXTURE_NORMAL, so it exits nonzero (1, "no match"; not 2, which is
rem reserved for findstr's own error condition) -- the errorlevel-2 check on
rem line 26 does not fire, but the errorlevel-1 check on line 30 (`if not
rem errorlevel 1`) also does not fire (an errorlevel of exactly 1 fails an
rem "if not errorlevel 1" test, since that test is true only for errorlevel
rem 0), so the fail-closed reject branch on lines 31-33 is skipped. Line 35's
rem for/f (`findstr /b /c:"NEVER_DEFINED_VAR="`) likewise never matches, so
rem the `do` clause runs zero times and NEVER_DEFINED_VAR is left untouched.
rem Line 36's `exit /b 0` then runs unconditionally, explicitly overwriting
rem whatever errorlevel the preceding findstr calls left behind -- this is
rem exactly the N1 fix (this path used to fall through to a bare `goto
rem :eof` immediately after the for/f loop, leaving the findstr-1 errorlevel
rem latched instead of resetting it to 0).
set "NEVER_DEFINED_VAR="
call "%LOADER%" "%FIXTURE_NORMAL%" NEVER_DEFINED_VAR
set "S14_ERRORLEVEL=%errorlevel%"
if defined NEVER_DEFINED_VAR (
    echo FAIL S14-var-absent-from-file-is-noop: variable unexpectedly became defined
    call :report_redacted NEVER_DEFINED_VAR
    set /a FAIL_COUNT+=1
) else (
    echo PASS S14-var-absent-from-file-is-noop
)
if "%S14_ERRORLEVEL%"=="0" (
    echo PASS S14b-var-absent-from-file-errorlevel-0
) else (
    echo FAIL S14b-var-absent-from-file-errorlevel-0: expected errorlevel 0 on the no-op path but got %S14_ERRORLEVEL% ^(N1 regression^)
    set /a FAIL_COUNT+=1
)

rem =========================================================================
rem Summary / cleanup. Fixture directory removal is unconditional -- every
rem scenario above either falls through to here or was skipped by branching
rem within the same top-level flow, so this is the single exit point for the
rem whole run (fix for M4: no path in this file leaves FIXTURE_DIR behind).
rem =========================================================================
:cleanup
rd /s /q "%FIXTURE_DIR%" 2>nul

if %FAIL_COUNT% GTR 0 (
    echo [TL3-cmd-env-parse] %FAIL_COUNT% scenario(s) FAILED.
    exit /b 1
) else (
    echo [TL3-cmd-env-parse] All scenarios PASSED.
    exit /b 0
)

rem =============================================================================
rem Subroutines. Placed after the unconditional `exit /b` above so normal
rem script flow can never fall into them by accident.
rem =============================================================================

rem :report_redacted VARNAME
rem Prints a redacted summary (defined/undefined + length only, never the
rem actual value) for use in FAIL branches -- fix for M5. This test only
rem ever loads synthetic fixture data (never the real .env), but the
rem discipline of never echoing a value that looks credential-shaped is kept
rem regardless, per the security report's guidance.
:report_redacted
setlocal EnableDelayedExpansion
if not defined %~1 (
    echo   ^(value: undefined^)
    endlocal
    goto :eof
)
set "_s=!%~1!"
set "_n=0"
:report_redacted_strlen_loop
if defined _s (
    set "_s=!_s:~1!"
    set /a _n+=1
    goto :report_redacted_strlen_loop
)
echo   ^(value: defined, length=!_n!, contents redacted^)
endlocal
goto :eof
