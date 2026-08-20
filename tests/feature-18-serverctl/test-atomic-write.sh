#!/usr/bin/env bash
# Tests: scripts/lib/atomic-write.sh, scripts/set-model
# Tags: scope:issue-specific, layer:TL1
# Scenario (issue #62): set-model's old atomic write did
# mktemp "$TARGET.XXXXXX" + mv tmp "$TARGET", replacing a symlinked TARGET's
# path and destroying the symlink. atomic-write.sh now resolves the symlink
# chain, lands the temp beside the real file with its mode, and commits onto
# the real file so the symlink survives.
set -u

REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LIB="$REPO/scripts/lib/atomic-write.sh"

[ -f "$LIB" ] || { echo "SKIP: $LIB not found (implementation pending)"; exit 77; }
. "$LIB"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

no_leftover_tmp() { # no_leftover_tmp <dir> <context>
    local extra
    extra="$(find "$1" -maxdepth 1 -name '*.??????' 2>/dev/null)"
    [ -z "$extra" ] || fail "$2: leftover temp file(s) after commit: $extra"
}

# --- Case 1: resolve a plain regular file to its own absolute path ---------
mkdir -p "$WORK/c1"
echo hi > "$WORK/c1/plain.txt"
GOT="$(_ccgw_resolve_symlink "$WORK/c1/plain.txt")"
EXP="$(CDPATH= cd -- "$WORK/c1" && pwd)/plain.txt"
[ "$GOT" = "$EXP" ] || fail "case 1: plain file resolved to '$GOT', expected '$EXP'"

# --- Case 2: single-hop symlink, absolute target ----------------------------
mkdir -p "$WORK/c2"
echo real > "$WORK/c2/real.txt"
ln -s "$WORK/c2/real.txt" "$WORK/c2/link.txt"
GOT="$(_ccgw_resolve_symlink "$WORK/c2/link.txt")"
EXP="$(CDPATH= cd -- "$WORK/c2" && pwd)/real.txt"
[ "$GOT" = "$EXP" ] || fail "case 2: single-hop absolute symlink resolved to '$GOT', expected '$EXP'"

# --- Case 3: multi-hop symlink chain (>=2 hops) -----------------------------
mkdir -p "$WORK/c3"
echo real > "$WORK/c3/real.txt"
ln -s "$WORK/c3/real.txt" "$WORK/c3/hop1.txt"
ln -s "$WORK/c3/hop1.txt" "$WORK/c3/hop2.txt"
ln -s "$WORK/c3/hop2.txt" "$WORK/c3/hop3.txt"
GOT="$(_ccgw_resolve_symlink "$WORK/c3/hop3.txt")"
EXP="$(CDPATH= cd -- "$WORK/c3" && pwd)/real.txt"
[ "$GOT" = "$EXP" ] || fail "case 3: multi-hop chain resolved to '$GOT', expected '$EXP'"

# --- Case 4: relative symlink target, resolved from elsewhere ---------------
mkdir -p "$WORK/c4/sub"
echo real > "$WORK/c4/real.txt"
(cd "$WORK/c4/sub" && ln -s ../real.txt rel.txt)
mkdir -p "$WORK/elsewhere"
GOT="$(cd "$WORK/elsewhere" && _ccgw_resolve_symlink "$WORK/c4/sub/rel.txt")"
EXP="$(CDPATH= cd -- "$WORK/c4" && pwd)/real.txt"
[ "$GOT" = "$EXP" ] || fail "case 4: relative-target symlink resolved to '$GOT' from a foreign cwd, expected '$EXP'"

# --- Case 5: symlink loop -> non-zero exit, message on stderr, no hang ------
mkdir -p "$WORK/c5"
ln -s "$WORK/c5/b.txt" "$WORK/c5/a.txt"
ln -s "$WORK/c5/a.txt" "$WORK/c5/b.txt"
_ccgw_resolve_symlink "$WORK/c5/a.txt" >"$WORK/c5.out" 2>"$WORK/c5.err"
RC=$?
[ "$RC" -ne 0 ] || fail "case 5: symlink loop returned success (rc=$RC), expected non-zero"
[ -s "$WORK/c5.err" ] || fail "case 5: symlink loop produced no stderr message"

# --- Case 6: begin/commit on a non-symlink target ---------------------------
mkdir -p "$WORK/c6"
echo old > "$WORK/c6/target.txt"
tmp="$(_ccgw_begin_write "$WORK/c6/target.txt")" || fail "case 6: _ccgw_begin_write failed"
echo new > "$tmp"
_ccgw_commit_write "$tmp" "$WORK/c6/target.txt" || fail "case 6: _ccgw_commit_write failed"
[ -f "$WORK/c6/target.txt" ] || fail "case 6: target is no longer a regular file"
[ ! -L "$WORK/c6/target.txt" ] || fail "case 6: target unexpectedly became a symlink"
[ "$(cat "$WORK/c6/target.txt")" = new ] || fail "case 6: target content was not replaced"
no_leftover_tmp "$WORK/c6" "case 6"

# --- Case 7: begin/commit on a symlink target -------------------------------
mkdir -p "$WORK/c7"
echo old > "$WORK/c7/original.txt"
ln -s "$WORK/c7/original.txt" "$WORK/c7/link.txt"
MTIME_BEFORE="$(_ccgw_file_mode "$WORK/c7/original.txt" >/dev/null; stat -f '%m' "$WORK/c7/original.txt" 2>/dev/null || stat -c '%Y' "$WORK/c7/original.txt")"
sleep 1
tmp="$(_ccgw_begin_write "$WORK/c7/link.txt")" || fail "case 7: _ccgw_begin_write failed"
echo new > "$tmp"
_ccgw_commit_write "$tmp" "$WORK/c7/link.txt" || fail "case 7: _ccgw_commit_write failed"
[ -L "$WORK/c7/link.txt" ] || fail "case 7: link.txt is no longer a symlink (issue #62 regression)"
[ "$(readlink "$WORK/c7/link.txt")" = "$WORK/c7/original.txt" ] || fail "case 7: symlink no longer points at the original"
[ "$(cat "$WORK/c7/original.txt")" = new ] || fail "case 7: original file content was not updated through the symlink"
MTIME_AFTER="$(stat -f '%m' "$WORK/c7/original.txt" 2>/dev/null || stat -c '%Y' "$WORK/c7/original.txt")"
[ "$MTIME_AFTER" -gt "$MTIME_BEFORE" ] || fail "case 7: original.txt mtime did not advance (before=$MTIME_BEFORE after=$MTIME_AFTER) -- suggests the commit did not actually write the real file"
no_leftover_tmp "$WORK/c7" "case 7"

# --- Case 8: mode preservation (600 and 644; symlink asserts real mode) -----
mkdir -p "$WORK/c8"
echo old > "$WORK/c8/mode600.txt"
chmod 600 "$WORK/c8/mode600.txt"
tmp="$(_ccgw_begin_write "$WORK/c8/mode600.txt")" || fail "case 8: begin_write (600) failed"
echo new > "$tmp"
_ccgw_commit_write "$tmp" "$WORK/c8/mode600.txt" || fail "case 8: commit_write (600) failed"
MODE="$(_ccgw_file_mode "$WORK/c8/mode600.txt")"
[ "$MODE" = 600 ] || fail "case 8: mode600.txt ended as '$MODE', expected 600"

echo old > "$WORK/c8/mode644.txt"
chmod 644 "$WORK/c8/mode644.txt"
tmp="$(_ccgw_begin_write "$WORK/c8/mode644.txt")" || fail "case 8: begin_write (644) failed"
echo new > "$tmp"
_ccgw_commit_write "$tmp" "$WORK/c8/mode644.txt" || fail "case 8: commit_write (644) failed"
MODE="$(_ccgw_file_mode "$WORK/c8/mode644.txt")"
[ "$MODE" = 644 ] || fail "case 8: mode644.txt ended as '$MODE', expected 644 (mktemp alone would force 600)"

echo old > "$WORK/c8/real.txt"
chmod 640 "$WORK/c8/real.txt"
ln -s "$WORK/c8/real.txt" "$WORK/c8/linkmode.txt"
tmp="$(_ccgw_begin_write "$WORK/c8/linkmode.txt")" || fail "case 8: begin_write (symlink mode) failed"
echo new > "$tmp"
_ccgw_commit_write "$tmp" "$WORK/c8/linkmode.txt" || fail "case 8: commit_write (symlink mode) failed"
MODE="$(_ccgw_file_mode "$WORK/c8/real.txt")"
[ "$MODE" = 640 ] || fail "case 8: symlink-resolved real.txt ended as '$MODE', expected 640"

# --- Case 9: no leftover temp files after commit (aggregate over cases) -----
no_leftover_tmp "$WORK/c8" "case 9"

# --- Case 10: nonexistent target -> begin_write still yields a usable tmp --
mkdir -p "$WORK/c10"
tmp="$(_ccgw_begin_write "$WORK/c10/does-not-exist.txt")" || fail "case 10: begin_write failed for a nonexistent target"
[ -n "$tmp" ] || fail "case 10: begin_write returned an empty path"
echo fresh > "$tmp"
_ccgw_commit_write "$tmp" "$WORK/c10/does-not-exist.txt" || fail "case 10: commit_write failed"
[ "$(cat "$WORK/c10/does-not-exist.txt")" = fresh ] || fail "case 10: new file content missing after commit"
no_leftover_tmp "$WORK/c10" "case 10"

# --- Case 11: static regression guard on scripts/set-model ------------------
SET_MODEL="$REPO/scripts/set-model"
[ -f "$SET_MODEL" ] || fail "case 11: $SET_MODEL not found"
grep -q 'lib/atomic-write\.sh' "$SET_MODEL" || fail "case 11: set-model no longer sources lib/atomic-write.sh"
if grep -E 'mktemp[[:space:]]+"\$(DOTENV_FILE|LITELLM_CONFIG)\.XXXXXX"' "$SET_MODEL" >/dev/null; then
    fail "case 11: set-model still contains the pre-#62 raw mktemp+mv pattern for DOTENV_FILE/LITELLM_CONFIG"
fi

echo "PASS: test-atomic-write"
