#!/usr/bin/env bash
# Tests: install.ps1, docs/infrastructure.md
# Tags: infrastructure, docs-sync, ssot, paths, windows, layer:TL2, scope:common
# scope:common despite the feature-86- dir: the code-is-authority / docs-mirror contract is permanent, so this file must outlive issue #86.
# install.ps1 owns the Windows path literals; docs/infrastructure.md mirrors them on lines carrying the '<!-- synced-from: install.ps1 -->' marker. Contract: detail plan 5-1 (C11), test spec 6-4.
# Skips (exit 77) until install.ps1 defines $CertDir (implementation pending). Once it does, a missing marker line or an unextractable assignment is a FAILURE, never a pass-by-finding-nothing.
# TL3 gap (what this test does NOT catch):
# - whether the directories these literals name exist on the real Windows host
# - whether NSSM actually burned the same $ConfigPath into AppParameters (only `nssm get` on the host shows that)
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
INSTALLER="$REPO/install.ps1"
DOC="$REPO/docs/infrastructure.md"
MARKER='<!-- synced-from: install.ps1 -->'

[ -f "$INSTALLER" ] || { echo "SKIP: $INSTALLER not found (implementation pending)"; exit 77; }
grep -q '\$CertDir' "$INSTALLER" || { echo "SKIP: $INSTALLER does not define \$CertDir yet (server role pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$DOC" ] || fail "$DOC not found, but install.ps1 already owns the server-role path literals"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Marker lines are the only place the docs may restate a code-owned value.
grep -F "$MARKER" "$DOC" > "$WORK/marker-lines" || true
MARKER_N="$(wc -l < "$WORK/marker-lines" | tr -d ' ')"
[ "$MARKER_N" -ge 3 ] || fail "expected at least 3 lines carrying '$MARKER' in ${DOC#"$REPO/"}, found $MARKER_N -- the docs side of the C11 contract is missing"

# Extract `$Name = '<literal>'` / "<literal>" from the installer. Anything else
# (an unquoted expression, a renamed variable) yields the empty string and fails
# below rather than silently skipping the assertion.
extract_assign() {
    sed -n "s/^[[:space:]]*\\\$$1[[:space:]]*=[[:space:]]*['\"]\\(.*\\)['\"][[:space:]]*\$/\\1/p" "$INSTALLER" | head -n 1
}

assert_mirrored() {
    _name="$1"; _value="$2"
    [ -n "$_value" ] || fail "could not extract \$$_name from ${INSTALLER#"$REPO/"} -- the assignment is missing or no longer a quoted literal"
    if ! grep -Fq -- "$_value" "$WORK/marker-lines"; then
        fail "\$$_name = '$_value' does not appear on any '$MARKER' line in ${DOC#"$REPO/"} -- code and docs drifted"
    fi
    echo "  ok: \$$_name -> $_value"
}

# --- 1. $CertDir and $RuntimeDir are plain literals ------------------------
CERT_DIR="$(extract_assign CertDir)"
RUNTIME_DIR="$(extract_assign RuntimeDir)"
assert_mirrored CertDir "$CERT_DIR"
assert_mirrored RuntimeDir "$RUNTIME_DIR"

# --- 2. $ConfigPath is an expression rooted at $RepoRoot -------------------
# Compare on the $RepoRoot-stripped relative part only; the absolute prefix is a
# property of the checkout, not of the contract.
CONFIG_RAW="$(extract_assign ConfigPath)"
[ -n "$CONFIG_RAW" ] || fail "could not extract \$ConfigPath from ${INSTALLER#"$REPO/"}"
case "$CONFIG_RAW" in
    *'$RepoRoot'*) ;;
    *) fail "\$ConfigPath = '$CONFIG_RAW' is not rooted at \$RepoRoot -- it must be derived from the checkout, not hardcoded" ;;
esac
CONFIG_REL="${CONFIG_RAW#*\$RepoRoot}"
CONFIG_REL="${CONFIG_REL#\\}"
CONFIG_REL="${CONFIG_REL#/}"
[ -n "$CONFIG_REL" ] || fail "\$ConfigPath has no path part after \$RepoRoot: '$CONFIG_RAW'"
assert_mirrored ConfigPath "$CONFIG_REL"

# --- 3. the relative part really is the migrated config --------------------
# Guards against a mirror that matches because both sides were changed to
# something meaningless (e.g. an empty-ish fragment that greps everywhere).
case "$CONFIG_REL" in
    *rtx5070ti-128gb*config.yaml) ;;
    *) fail "\$ConfigPath relative part '$CONFIG_REL' does not point at the rtx5070ti-128gb config.yaml" ;;
esac

# --- 4. mutation probe: the mirror check must reject a drifted doc ---------
# Runs assert_mirrored's comparison against a marker set that deliberately lacks
# the value, so a grep that always succeeds cannot hide behind cases 1-3.
printf '| some row | no value here | %s\n' "$MARKER" > "$WORK/probe-lines"
if grep -Fq -- "$CERT_DIR" "$WORK/probe-lines"; then
    fail "mutation probe: a marker line without the value still matched \$CertDir -- the comparison is vacuous"
fi

# --- 5. no doc restates a code-owned value OFF a marker line ---------------
# CPR-SSOT: an unmarked copy is a second definition point that no test guards,
# and it is the copy that goes stale. Scanned across every doc, not just
# infrastructure.md -- a value pasted into tuning.md drifts exactly as easily.
# `grep -v` on a non-match returns 1, so the rc of each stage is checked rather
# than swallowed by `|| true`; an rc above 1 is a broken scan, not a clean one.
DOCS=""
DOC_N=0
for d in "$DOC" "$REPO"/docs/*.md "$REPO"/README.md; do
    [ -f "$d" ] || continue
    case " $DOCS " in *" $d "*) continue ;; esac
    DOCS="$DOCS $d"
    DOC_N=$((DOC_N + 1))
done
[ "$DOC_N" -ge 1 ] || fail "found no markdown to scan under $REPO/docs -- case 5 would pass vacuously"

unmarked_hits() {
    _file="$1"; _value="$2"
    grep -Fn -- "$_value" "$_file" > "$WORK/raw"
    _rc=$?
    [ "$_rc" -le 1 ] || fail "grep exited $_rc scanning ${_file#"$REPO/"} for '$_value'"
    [ "$_rc" -eq 0 ] || return 1
    grep -Fv -- "$MARKER" "$WORK/raw" > "$WORK/unmarked"
    _rc=$?
    [ "$_rc" -le 1 ] || fail "grep exited $_rc filtering marker lines for '$_value'"
    return "$_rc"
}

for d in $DOCS; do
    for v in "$CERT_DIR" "$RUNTIME_DIR"; do
        if unmarked_hits "$d" "$v"; then
            fail "value '$v' appears in ${d#"$REPO/"} on line(s) without the sync marker: $(tr '\n' ' ' < "$WORK/unmarked")"
        fi
    done
done

# $ConfigPath's relative part is checked in infrastructure.md alone: unlike the
# two absolute directories, naming llama-swap/<host>/config.yaml in prose is
# ordinary writing, not a restatement of a code-owned literal.
if unmarked_hits "$DOC" "$CONFIG_REL"; then
    fail "\$ConfigPath's path part '$CONFIG_REL' appears in ${DOC#"$REPO/"} without the sync marker: $(tr '\n' ' ' < "$WORK/unmarked")"
fi

# 5b. the unmarked-copy scan must be able to fire.
printf '| runtime | %s | (no marker on this row)\n' "$RUNTIME_DIR" > "$WORK/dup-probe"
unmarked_hits "$WORK/dup-probe" "$RUNTIME_DIR" || fail "the unmarked-copy scan missed a planted duplicate of '$RUNTIME_DIR' -- case 5 cannot detect a regression"

# 5c. and it must NOT fire on a properly marked line (classifier guard).
printf '| runtime | %s | %s\n' "$RUNTIME_DIR" "$MARKER" > "$WORK/ok-probe"
if unmarked_hits "$WORK/ok-probe" "$RUNTIME_DIR"; then
    fail "the unmarked-copy scan flagged a correctly marked line -- it would make every compliant doc fail"
fi

# --- 6. the co-location assumption stays dead (detail plan 4-7) ------------
# The old design kept config.yaml inside the runtime directory, which is what
# made llama-swap-service.ps1 able to default its paths. A doc that still spells
# it that way would send an operator to a file the installer never writes.
colocated() {
    grep -F -- "$RUNTIME_DIR" "$1" > "$WORK/rt"
    _rc=$?
    [ "$_rc" -le 1 ] || fail "grep exited $_rc scanning ${1#"$REPO/"} for the runtime directory"
    [ "$_rc" -eq 0 ] || return 1
    grep -E 'config\.yaml|model-annotations\.yaml' "$WORK/rt" > "$WORK/colo"
    _rc=$?
    [ "$_rc" -le 1 ] || fail "grep exited $_rc checking for the co-location spelling"
    return "$_rc"
}

for d in $DOCS; do
    if colocated "$d"; then
        fail "${d#"$REPO/"} places a config file under the runtime directory '$RUNTIME_DIR': $(tr '\n' ' ' < "$WORK/colo") -- the config lives in the checkout, not beside the exe"
    fi
done

# 6b. the co-location scan must be able to fire.
printf '%s\\config.yaml\n' "$RUNTIME_DIR" > "$WORK/colo-probe"
colocated "$WORK/colo-probe" || fail "the co-location scan missed a planted '$RUNTIME_DIR\\config.yaml' -- case 6 cannot detect a regression"

echo "PASS: test-infrastructure-paths-sync ($MARKER_N marker line(s), $DOC_N doc(s) scanned)"
