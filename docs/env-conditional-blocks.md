# .env OS-conditional blocks

Spec for the `#@if windows` / `#@if posix` / `#@endif` marker syntax that lets a
single repo-root `.env` carry platform-specific lines. Three independent
implementations follow this state machine: `scripts/lib/load-dotenv.sh`
(`_dotenv_filter_os_blocks`, sourced by `scripts/ccgw-proxy.sh`),
`scripts/code-ccgw.ps1` (`ConvertFrom-OsConditionalLines`), and the `agents`
repo's Node loader (informational reference only — see the note at the
bottom of this file).

## State machine

Process the `.env` file line by line, in order. State: `depth` (integer,
starts at 0), `suppressing` (boolean, starts false), `suppressDepth`
(integer, meaningless until `suppressing` is first set).

1. **Strip `\r`.** Each line has a trailing `\r` (CRLF line ending) stripped
   first, regardless of platform. This is the only transformation applied to
   the line that gets emitted.
2. **Trim for marker detection only.** A separately-trimmed copy of the line
   (`trimmed`: leading and trailing whitespace stripped) is used only to
   detect and classify marker lines. Non-marker lines are emitted using the
   original `\r`-stripped line — internal whitespace and indentation are
   never altered.
3. **`#@if` marker.** `trimmed` starting with exactly `"#@if "` (the 5
   characters `#`, `@`, `i`, `f`, one literal space) is recognized as an
   `#@if` marker. Any other spelling — no space (`#@ifwindows`), a tab
   instead of a space, extra `@`, etc. — is NOT recognized as `#@if`.
   - `depth` increments by 1, whether or not the block turns out active, and
     whether or not a suppression is already in effect.
   - The token is everything after the 5-character prefix, trimmed again.
   - If not currently suppressing, and the token does not match the active
     platform token, suppression begins: `suppressing = true`,
     `suppressDepth = depth`.
   - If already suppressing when a nested `#@if` is seen (of either token),
     `suppressDepth` is left untouched — it stays pinned at the depth where
     suppression first began.
   - The marker line itself is never emitted.
4. **`#@endif` marker.** `trimmed` exactly equal to `"#@endif"` (no leading
   or trailing extra text) is recognized as `#@endif`. It is only processed
   when `depth > 0`:
   - If suppressing and `depth == suppressDepth`, suppression is lifted
     (`suppressing = false`).
   - `depth` is then decremented, regardless of whether suppression was
     lifted.
   - At `depth == 0`, `#@endif` is a no-op (no state change) — this covers
     an orphan `#@endif` with no matching `#@if`.
   - The marker line itself is never emitted.
5. **Unknown `#@` line.** Any line whose `trimmed` form starts with `"#@"`
   but matches neither of the two patterns above — including a non-strict
   `#@if` spelling and an `#@endif` line carrying trailing text — is
   silently discarded: not emitted, and no state change. This is
   deliberately lenient for forward-compatibility with markers this filter
   does not yet know about, and deliberately non-lenient about closing a
   block: `#@endif foo` does not close anything, on purpose (case 10 below).
6. **All other lines.** Emitted as-is (after the `\r` strip) only when not
   currently suppressing.
7. **EOF.** An unclosed `#@if` (`depth > 0` at end of file) is not an error.
   Any lines after the last unclosed marker simply keep whatever
   suppression state was in effect.

## Platform token resolution

- **POSIX sh:** run `uname -s`. `MINGW*`, `MSYS*`, or `CYGWIN*` (Git
  Bash/MSYS2/Cygwin on Windows) resolve to token `windows`; anything else
  resolves to `posix`.
- **PowerShell:** when `Test-Path variable:IsWindows` is true, use
  `$IsWindows` (`windows` when true, `posix` when false). When that
  variable does not exist at all — Windows PowerShell 5.1, which only ever
  runs on Windows — fall back to `windows` directly, without referencing
  `$IsWindows` (referencing an undefined variable under
  `Set-StrictMode -Version Latest` throws).

## Conformance cases

The following 13 cases are the shared conformance fixture, exercised
identically (mirrored per platform) by
`tests/feature-18-serverctl/test-load-dotenv-os-blocks.sh` (sh) and
`tests/feature-18-serverctl/code-ccgw-windows.Tests.ps1` (PowerShell). Those
test files are the authoritative source; this list is a concise summary.

1. **Basic branching.** `#@if windows` / `#@if posix` blocks each set the
   same key to a different value — only the active platform's value
   survives.
2. **No marker leakage.** Marker lines (`#@if ...`, `#@endif`) never appear
   in the filtered output or in any exported value.
3. **Unconditional plain lines.** A plain comment and a `KEY=VALUE` line
   outside any block always survive, on both platforms.
4. **Blank lines preserved.** A blank line between two `KEY=VALUE` lines
   does not fuse them or drop either one.
5. **Inactive-outer nesting doesn't leak.** An outer `#@if <inactive>`
   block containing a nested `#@if <active>` block: neither the outer nor
   the inner content is emitted — `suppressDepth` pins at the outer depth,
   so the inner marker cannot reactivate output.
6. **Active-outer nesting removes only the inner inactive part.** An outer
   `#@if <active>` block containing a nested `#@if <inactive>` block: lines
   before and after the nested block (but still inside the outer block) are
   emitted; only the nested block's content is suppressed.
7. **Unknown token.** `#@if darwin` (a token that is neither `windows` nor
   `posix`) suppresses its block on both platforms — an unrecognized token
   is never treated as active.
8. **Non-strict spelling opens no block.** `#@ifwindows` (no space) is not
   recognized as `#@if` at all; it is discarded as an unknown `#@` line and
   the line that follows it is treated as a normal, unconditional line.
9. **Orphan `#@endif`.** An `#@endif` with no preceding unclosed `#@if`
   (`depth == 0`) is a no-op: it does not affect surrounding plain lines.
10. **`#@endif` with trailing text never closes a block.** `#@endif foo` is
    an unknown `#@` line, not `#@endif` — deliberately, so the block it
    "looks like" it should close stays open (and suppression, if active,
    never lifts) for the rest of the file. This is intentionally not
    "fixed" to be lenient; the case exists to keep all implementations
    drift-matched on the strict behavior.
11. **CRLF resilience.** A file saved with CRLF line endings resolves
    identically to the same content saved with LF.
12. **Whitespace-padded markers.** Leading/trailing whitespace around a
    marker line (` #@if windows `, ` #@endif `) does not prevent
    recognition.
13. **Duplicate keys.** When the same key is set once outside any block and
    again inside an active block, both `.env` loaders in this repo
    (`_dotenv_filter_os_blocks` + `scripts/lib/load-dotenv.sh`'s
    already-set check, and `code-ccgw.ps1`) keep the *first* physical
    occurrence, because each loader skips re-setting a variable that has
    already been set to a non-empty value. This is the opposite of the
    `agents` repo's Node `parseEnv`, which builds a plain object and keeps
    the *last* occurrence. This asymmetry is intentional and documented,
    not something to unify — the two loaders serve different consumption
    models (shell env export vs. a parsed config map).

## Reference implementation

`agents/hooks/lib/load-env.js`'s `filterOsBlocks()` function is the
reference implementation this spec was extracted from. It is informational
only: this repo (`cc-local-llm`) does not have a runtime dependency on the
`agents` repo — `scripts/lib/load-dotenv.sh` and `scripts/code-ccgw.ps1`
each implement the state machine natively in their own language.
