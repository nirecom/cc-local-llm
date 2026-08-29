#!/usr/bin/env bash
# Tests: llama-swap/rtx5070ti-128gb/config.yaml, llama-swap/rtx5070ti-128gb/model-annotations.yaml, llama-swap/m5-max-128gb/config.yaml, llama-swap/m5-max-128gb/model-annotations.yaml, CLAUDE.md
# Tags: llama-swap, model-annotations, parity, yaml, secret-scan, layer:TL2, scope:common
# scope:common despite the feature-86- dir: the config <-> annotations rule is a standing CLAUDE.md rule for every host dir, so this is permanent coverage.
# Enforces it across the whole class of llama-swap/<chip>-<memory>/ dirs (CPR-E2C) plus the PUBLIC-ification redaction. Rationale: detail plan 6-1.
# Skips (exit 77) until llama-swap/rtx5070ti-128gb/config.yaml exists (implementation pending).
# TL3 gap (what this test does NOT catch):
# - whether llama-swap actually loads this config and serves the models
# - whether the .gguf / llama-server.exe paths in cmd: exist on the real host (only TL3-installer-llama-cpp-build.sh under RUN_TL3 checks that)
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
SWAP_DIR="$REPO/llama-swap"
WIN_DIR="$SWAP_DIR/rtx5070ti-128gb"

[ -f "$WIN_DIR/config.yaml" ] || { echo "SKIP: $WIN_DIR/config.yaml not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# grep_state <file> <flags> <pattern>: 0 = match, 1 = clean miss, never anything
# else. MSYS2 grep can abort (SIGABRT, rc 134), and an aborted grep is
# indistinguishable from "no match" at an `if` -- which would turn the security
# cases below into false greens. rc > 1 is a tool failure, not a clean miss.
grep_state() {
    grep "$2" -- "$3" "$1" > "$WORK/hits"
    _rc=$?
    [ "$_rc" -le 1 ] || fail "grep exited $_rc scanning $1 -- cannot conclude the pattern is absent"
    return "$_rc"
}

# --- parsers (no yq; top-level keys at indent 0, model keys at indent 2) ----
# A 4-space-indented line cannot match `^  [A-Za-z...]` -- its 3rd char is a space.
config_keys() {
    awk '
        /^models:[[:space:]]*$/ { inm = 1; next }
        inm && /^[^[:space:]#]/ { inm = 0 }
        inm && /^  [A-Za-z0-9._-]+:/ { k = $0; sub(/^  /, "", k); sub(/:.*$/, "", k); print k }
    ' "$1"
}

annotation_keys() {
    awk '/^[A-Za-z0-9._-]+:/ { k = $0; sub(/:.*$/, "", k); print k }' "$1"
}

# Does annotation entry <key> carry field <field> at indent 2? substr(), not a
# regex: model keys contain `.` and `-`, which would match the wrong entry.
entry_has_field() {
    awk -v k="$2" -v f="$3" '
        substr($0, 1, length(k) + 1) == k ":" { inb = 1; next }
        inb && /^[A-Za-z0-9._-]+:/ { inb = 0 }
        inb && substr($0, 1, length(f) + 3) == "  " f ":" { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

# --- the checker under test ------------------------------------------------
# Returns 0 when the pair satisfies the rule, 1 otherwise; never exits, so case
# 5 can call it on a broken fixture and assert the status.
check_pair() {
    _cfg="$1"; _ann="$2"; _label="$3"
    _bad=0

    _ckeys="$(config_keys "$_cfg")"
    _akeys="$(annotation_keys "$_ann")"

    # A parser that produced nothing would make every loop below vacuous.
    if [ -z "$_ckeys" ]; then
        echo "  [$_label] parsed 0 model keys out of $_cfg (parser broken or file empty)" >&2
        return 1
    fi
    if [ -z "$_akeys" ]; then
        echo "  [$_label] parsed 0 annotation keys out of $_ann (parser broken or file empty)" >&2
        return 1
    fi

    # Forward rule: every config model key is annotated.
    for _k in $_ckeys; do
        if ! printf '%s\n' "$_akeys" | grep -Fxq -- "$_k"; then
            echo "  [$_label] config model '$_k' has no entry in $(basename "$_ann")" >&2
            _bad=1
        fi
    done

    for _k in $_akeys; do
        # Every annotation entry states what the model is for.
        if ! entry_has_field "$_ann" "$_k" "role"; then
            echo "  [$_label] annotation '$_k' is missing 'role:'" >&2
            _bad=1
        fi
        # Reverse rule: an orphan annotation must justify itself with `retained:`.
        if ! printf '%s\n' "$_ckeys" | grep -Fxq -- "$_k"; then
            if ! entry_has_field "$_ann" "$_k" "retained"; then
                echo "  [$_label] annotation '$_k' has no config counterpart and no 'retained:' reason" >&2
                _bad=1
            fi
        fi
    done

    return "$_bad"
}

# --- 1. every populated host directory satisfies the rule ------------------
SCANNED=0
for d in "$SWAP_DIR"/*/; do
    [ -d "$d" ] || continue
    label="$(basename "$d")"
    cfg="$d/config.yaml"
    ann="$d/model-annotations.yaml"

    # Edge: a host directory without a config.yaml is skipped, not fatal.
    if [ ! -f "$cfg" ]; then
        echo "note: $label has no config.yaml -- not a populated host directory, skipped"
        continue
    fi
    [ -f "$ann" ] || fail "$label has config.yaml but no model-annotations.yaml (CLAUDE.md requires the pair)"

    check_pair "$cfg" "$ann" "$label" || fail "$label violates the config <-> annotations rule (see messages above)"
    SCANNED=$((SCANNED + 1))
done

# A glob that matched nothing would leave every assertion above unexecuted.
[ "$SCANNED" -ge 2 ] || fail "expected at least 2 populated host directories under $SWAP_DIR, scanned $SCANNED"

# --- 2. the Windows side really does exercise the reverse rule -------------
# Without it, deleting every retained orphan makes case 1's reverse branch vacuous.
WIN_CFG_N="$(config_keys "$WIN_DIR/config.yaml" | wc -l | tr -d ' ')"
WIN_ANN_N="$(annotation_keys "$WIN_DIR/model-annotations.yaml" | wc -l | tr -d ' ')"
[ "$WIN_ANN_N" -gt "$WIN_CFG_N" ] || fail "rtx5070ti-128gb: expected more annotations than config models (retained orphans), got $WIN_ANN_N annotations vs $WIN_CFG_N models"

RETAINED=0
for k in $(annotation_keys "$WIN_DIR/model-annotations.yaml"); do
    if entry_has_field "$WIN_DIR/model-annotations.yaml" "$k" "retained"; then
        RETAINED=$((RETAINED + 1))
    fi
done
[ "$RETAINED" -ge 1 ] || fail "rtx5070ti-128gb: no annotation carries 'retained:' -- the reverse rule is never exercised"

# --- 3. the Mac member of the class, by name and by the same field set -----
# CPR-ORTH: "some other directory exists" is not symmetry. The sibling is
# m5-max-128gb specifically -- same <chip>-<memory> naming, same two files and
# nothing else, same annotation schema as the Windows side.
MAC_DIR="$SWAP_DIR/m5-max-128gb"
[ -f "$MAC_DIR/config.yaml" ] || fail "$MAC_DIR/config.yaml not found -- the Mac member of the <chip>-<memory> class is the named counterpart, not 'whichever other directory happens to exist'"
[ -f "$MAC_DIR/model-annotations.yaml" ] || fail "$MAC_DIR/model-annotations.yaml not found"

# 3a. every host directory follows <chip>-<memory>; the memory half is digits+gb.
for d in "$SWAP_DIR"/*/; do
    name="$(basename "$d")"
    case "$name" in
        -*|*-) fail "host directory '$name' does not follow <chip>-<memory>" ;;
        *-*gb) ;;
        *) fail "host directory '$name' does not follow <chip>-<memory> (llama-swap/README.md)" ;;
    esac
    mem="${name##*-}"
    mem="${mem%gb}"
    case "$mem" in
        ''|*[!0-9]*) fail "host directory '$name': memory part '${name##*-}' is not <digits>gb" ;;
    esac
done

# 3b. a populated host directory holds exactly the two permitted files. A stray
# .bak or second config makes "which file is authoritative" ambiguous.
for d in "$SWAP_DIR"/*/; do
    [ -f "$d/config.yaml" ] || continue
    for entry in $(ls -A "$d"); do
        case "$entry" in
            config.yaml|model-annotations.yaml) ;;
            *) fail "$(basename "$d") contains '$entry'; a populated host directory holds exactly config.yaml and model-annotations.yaml" ;;
        esac
    done
done

# 3c. the shared annotation schema. Both hosts draw fields from one set; only
# Windows may add `optimizer:` -- the optimizer tunes llama.cpp, not MLX.
entry_fields() {
    awk -v k="$2" '
        substr($0, 1, length(k) + 1) == k ":" { inb = 1; next }
        inb && /^[A-Za-z0-9._-]+:/ { inb = 0 }
        inb && /^  [A-Za-z0-9._-]+:/ { f = $0; sub(/^  /, "", f); sub(/:.*$/, "", f); print f }
    ' "$1"
}

for d in "$SWAP_DIR"/*/; do
    [ -f "$d/config.yaml" ] || continue
    label="$(basename "$d")"
    ann="$d/model-annotations.yaml"
    fields_seen=0
    for k in $(annotation_keys "$ann"); do
        for f in $(entry_fields "$ann" "$k"); do
            fields_seen=$((fields_seen + 1))
            case "$f" in
                role|used_by|notes|decision|retained) ;;
                optimizer)
                    [ "$label" = "m5-max-128gb" ] && fail "[$label] annotation '$k' uses 'optimizer:', which the Mac format excludes"
                    ;;
                *) fail "[$label] annotation '$k' carries unknown field '$f:' -- the two hosts share one annotation schema (role/used_by/notes/decision/retained, plus optimizer on Windows only)" ;;
            esac
        done
    done
    [ "$fields_seen" -gt 0 ] || fail "[$label] parsed 0 annotation fields -- the schema check is vacuous"
done

# --- 4. security: the PUBLIC-ification redaction never regresses -----------
# Case-folded by lowering the haystack rather than with `grep -i`, which MSYS2
# grep aborts on here; see grep_state above for why that distinction matters.
# Tokens are base64 in the source so the private names they guard against are
# never themselves committed in plaintext to this public repo; decoded only in
# memory at test time for the comparison.
decode_token() { printf '%s' "$1" | base64 -d; }
PRIVATE_TOKENS_B64="bmVtb2NsYXc= YWktc3BlY3M= cHJpdmF0ZS1zcGVjcy1yZXBv"

for f in "$WIN_DIR/config.yaml" "$WIN_DIR/model-annotations.yaml"; do
    tr '[:upper:]' '[:lower:]' < "$f" > "$WORK/folded"
    for token_b64 in $PRIVATE_TOKENS_B64; do
        token="$(decode_token "$token_b64")"
        if grep_state "$WORK/folded" -F "$token"; then
            fail "a redacted private token reappeared in ${f#"$REPO/"} -- redaction from Commit 2 was undone"
        fi
    done
done

# 4b. the redaction scan itself must be able to fire: same fold + grep against a
# line that does carry the token in the OPPOSITE case, so case 4's silence means
# "absent", not "broken" (a same-case probe would pass even without folding).
probe_token="$(decode_token bmVtb2NsYXc=)"
probe_upper="$(printf '%s' "$probe_token" | tr '[:lower:]' '[:upper:]')"
printf 'notes: "used by %s"\n' "$probe_upper" > "$WORK/redaction-probe"
tr '[:upper:]' '[:lower:]' < "$WORK/redaction-probe" > "$WORK/folded"
grep_state "$WORK/folded" -F "$probe_token" || fail "redaction probe: the case-folded scan missed the upper-cased probe token -- case 4 cannot detect a regression"

# 4c. structural arm: the token list above only knows the three spellings that
# existed at migration time. These patterns catch the SHAPE of a private
# reference -- any repo/host reference, a cross-repo markdown link, an absolute
# host .md path -- so a fourth private name nobody listed still fails.
REDACTION_PATTERNS='github\.com[:/]|nirecom/|\]\([^)]*\.md|[A-Za-z]:\\[^"[:space:]]*\.md'
for f in "$WIN_DIR/config.yaml" "$WIN_DIR/model-annotations.yaml"; do
    if grep_state "$f" -nE "$REDACTION_PATTERNS"; then
        fail "${f#"$REPO/"} carries a private-reference shape (repo link, cross-repo .md link or host .md path): $(cat "$WORK/hits")"
    fi
done

# 4d. the structural arm must be able to fire too.
printf 'decision: "see https://github.com/example/private-thing/blob/main/history.md"\n' > "$WORK/shape-probe"
grep_state "$WORK/shape-probe" -nE "$REDACTION_PATTERNS" || fail "structural redaction probe: the pattern arm missed an obvious repo link -- case 4c cannot detect a regression"

# --- 6. CLAUDE.md states the rule this file enforces (C11) -----------------
# The reverse rule lives in CLAUDE.md; this test is only its enforcement arm.
# Without this case, deleting the rule would leave the tests passing.
CLAUDE_MD="$REPO/CLAUDE.md"
[ -f "$CLAUDE_MD" ] || fail "$CLAUDE_MD not found -- the retained-orphan rule has no home"

docs_rules_section() {
    awk '
        /^## Docs Update Rules[[:space:]]*$/ { ins = 1; next }
        ins && /^## / { ins = 0 }
        ins { print }
    ' "$1"
}

docs_rules_section "$CLAUDE_MD" > "$WORK/docs-rules"
[ -s "$WORK/docs-rules" ] || fail "CLAUDE.md has no '## Docs Update Rules' section (or it is empty) -- the annotation rules lost their SSOT"

grep_state "$WORK/docs-rules" -F 'retained:' || fail "CLAUDE.md's '## Docs Update Rules' never mentions 'retained:' -- the reverse rule (an orphan annotation may stay only with a written reason) is unstated, so this test enforces a rule the repo no longer declares"
grep_state "$WORK/docs-rules" -F 'config.yaml' || fail "CLAUDE.md's '## Docs Update Rules' does not mention config.yaml -- the forward rule is unstated"

# 6b. the section extractor must be able to come back empty, or case 6 would
# pass on any file that merely contains the word 'retained:' somewhere.
printf '# Rules\n\n## Docs Update Rules\n\nUpdate the annotations beside config.yaml.\n\n## Other\n\nretained: not here\n' > "$WORK/claude-probe"
docs_rules_section "$WORK/claude-probe" > "$WORK/probe-section"
if grep_state "$WORK/probe-section" -F 'retained:'; then
    fail "CLAUDE.md probe: the section extractor leaked text from a later '## ' section -- case 6 would pass on a rule stated nowhere near the docs rules"
fi

# --- 5. mutation probe: the checker must reject a deliberately broken pair --
MUT="$WORK/mutant"
mkdir -p "$MUT"
printf 'healthCheckTimeout: 600\nmodels:\n  alpha-model:\n    cmd: true\n  beta-model:\n    cmd: true\n' > "$MUT/config.yaml"

# 5a. missing annotation for beta-model
printf 'alpha-model:\n  role: probe\n' > "$MUT/model-annotations.yaml"
if check_pair "$MUT/config.yaml" "$MUT/model-annotations.yaml" mutant-missing 2>/dev/null; then
    fail "mutation probe 5a: checker accepted a config model with no annotation (false-green parser)"
fi

# 5b. annotation without role:
printf 'alpha-model:\n  role: probe\nbeta-model:\n  notes: "no role here"\n' > "$MUT/model-annotations.yaml"
if check_pair "$MUT/config.yaml" "$MUT/model-annotations.yaml" mutant-norole 2>/dev/null; then
    fail "mutation probe 5b: checker accepted an annotation with no 'role:'"
fi

# 5c. orphan annotation without retained:
printf 'alpha-model:\n  role: probe\nbeta-model:\n  role: probe\ngamma-model:\n  role: probe\n' > "$MUT/model-annotations.yaml"
if check_pair "$MUT/config.yaml" "$MUT/model-annotations.yaml" mutant-orphan 2>/dev/null; then
    fail "mutation probe 5c: checker accepted an orphan annotation with no 'retained:'"
fi

# 5d. classifier guard: the same fixture, made compliant, must pass -- a checker
# hardwired to fail would satisfy 5a-5c and still be wrong.
printf 'alpha-model:\n  role: probe\nbeta-model:\n  role: probe\ngamma-model:\n  role: probe\n  retained: "kept on purpose for the probe"\n' > "$MUT/model-annotations.yaml"
check_pair "$MUT/config.yaml" "$MUT/model-annotations.yaml" mutant-ok || fail "mutation probe 5d: checker rejected a compliant fixture (over-blocking)"

echo "PASS: test-config-annotations-parity ($SCANNED host directories, $RETAINED retained annotation(s))"
