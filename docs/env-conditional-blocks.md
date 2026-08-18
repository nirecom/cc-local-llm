# .env OS-conditional blocks

A shared `.env` covers both Windows and POSIX clients. `#@if windows` / `#@if posix` / `#@endif` mark a block; only the block matching the running platform is kept, and marker lines themselves are never emitted.

Nesting is depth-tracked: if an outer block is inactive, everything inside stays suppressed even if an inner `#@if` would otherwise match. Unknown `#@` lines are dropped and treated as inert.

Platform detection: POSIX uses `uname -s` (`MINGW*/MSYS*/CYGWIN*` → windows). PowerShell uses `$IsWindows` (falls back to `windows` when that variable doesn't exist).

Implemented in `scripts/lib/load-dotenv.sh` (`_dotenv_filter_os_blocks`) and `scripts/code-ccgw.ps1` (`ConvertFrom-OsConditionalLines`).
