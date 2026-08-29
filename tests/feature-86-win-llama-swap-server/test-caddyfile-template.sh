#!/usr/bin/env bash
# Tests: install/win/Caddyfile.template, install/win/llama-swap-service.ps1
# Tags: caddy, caddyfile, template, tls, placeholder, layer:TL2, scope:common
# scope:common despite the feature-86- dir: this template is permanent infrastructure and the placeholder/port contract outlives issue #86.
# Asserts the template carries no absolute cert path (paths belong to install.ps1 alone), exactly 10 {{CERT_DIR}} placeholders, and that each of the 5 ports is a self-contained site block: its own tls pair, its own reverse_proxy upstream. Then renders it and hands the result to caddy's own parser. Rationale: detail plan 4-6 / 6-3.
# Skips (exit 77) until install/win/Caddyfile.template exists (implementation pending) -- an explicit skip, never a silent pass. The caddy arm degrades to a note when caddy is off PATH; the structural cases still run.
# TL3 gap (what this test does NOT catch):
# - full `caddy validate` provisioning: the certificate files live outside the repo, so validate is only held to "no error other than loading them"
# - whether the 5 upstreams are actually listening, so a rendered-but-dead route looks identical here
# - closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see
# tests/feature-18-serverctl/test-repo-derivation.sh); export REPO=<path> to
# point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
TEMPLATE="$REPO/install/win/Caddyfile.template"

[ -f "$TEMPLATE" ] || { echo "SKIP: $TEMPLATE not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Sanity: an empty file would satisfy several "absence" assertions below.
[ -s "$TEMPLATE" ] || fail "$TEMPLATE is empty"

# --- 1. no absolute certificate path literals -----------------------------
# The single owner of path literals is install.ps1 ($CertDir); a drive-letter or
# /c/-style path here means the template went back to hardcoding host paths.
if grep -nE '[A-Za-z]:\\' "$TEMPLATE"; then
    fail "$TEMPLATE contains a drive-letter absolute path (must use {{CERT_DIR}})"
fi
if grep -nE '(^|[^A-Za-z0-9_.-])/[a-zA-Z]/(LLM|Users|git)/' "$TEMPLATE"; then
    fail "$TEMPLATE contains a /c/-style absolute path (must use {{CERT_DIR}})"
fi

# Every .pem reference must be rooted at the placeholder, not at anything else.
BAD_PEM="$(grep -oE '[^[:space:]]*\.pem' "$TEMPLATE" | grep -v '^{{CERT_DIR}}[\\/]' || true)"
[ -z "$BAD_PEM" ] || fail "$TEMPLATE references .pem files not rooted at {{CERT_DIR}}: $BAD_PEM"

# --- 2. exactly 10 placeholders (5 blocks x cert + key) --------------------
PH_COUNT="$(grep -o '{{CERT_DIR}}' "$TEMPLATE" | wc -l | tr -d ' ')"
[ "$PH_COUNT" -eq 10 ] || fail "expected exactly 10 '{{CERT_DIR}}' occurrences (5 tls blocks x cert+key), found $PH_COUNT"

# No other placeholder shape may creep in unnoticed: llama-swap-service.ps1
# substitutes {{CERT_DIR}} only, so any other {{...}} would ship verbatim.
OTHER_PH="$(grep -oE '\{\{[A-Za-z0-9_]+\}\}' "$TEMPLATE" | grep -v '^{{CERT_DIR}}$' | sort -u || true)"
[ -z "$OTHER_PH" ] || fail "unsubstituted placeholder(s) other than {{CERT_DIR}} present: $OTHER_PH"

# --- 3. all 5 site blocks present, each with its own reverse_proxy ---------
# Block map from detail plan 4-6: front TLS port -> plaintext upstream port.
awk '
    /^[[:space:]]*:[0-9]+[[:space:]]*\{/ {
        line = $0
        sub(/^[[:space:]]*:/, "", line)
        sub(/[^0-9].*$/, "", line)
        port = line
        blocks[port] = 1
        cur = port
        next
    }
    /^[[:space:]]*\}/ { cur = ""; next }
    cur != "" && /reverse_proxy/ {
        rp[cur] = rp[cur] + 1
        up = $0
        sub(/^.*reverse_proxy[[:space:]]+/, "", up)
        sub(/[[:space:]].*$/, "", up)
        upstream[cur] = up
    }
    cur != "" && $1 == "tls" {
        tls[cur] = tls[cur] + 1
        c = $2; k = $3
        gsub(/^"|"$/, "", c); gsub(/^"|"$/, "", k)   # quoting the paths is allowed
        cert[cur] = c
        key[cur]  = k
    }
    END {
        for (p in blocks)
            printf "BLOCK %s %d %s %d %s %s\n", p, rp[p] + 0, upstream[p], tls[p] + 0, \
                (cert[p] == "" ? "-" : cert[p]), (key[p] == "" ? "-" : key[p])
    }
' "$TEMPLATE" > "$WORK/blocks"

[ -s "$WORK/blocks" ] || fail "parsed 0 site blocks out of $TEMPLATE (parser broken or template restructured)"

BLOCK_N="$(wc -l < "$WORK/blocks" | tr -d ' ')"
[ "$BLOCK_N" -eq 5 ] || fail "expected exactly 5 site blocks, parsed $BLOCK_N (see $TEMPLATE)"

# Each port is checked as a whole block: its own upstream AND its own tls pair.
# A file-wide "5 tls directives" count is satisfied by five tls lines in one
# block and none in the other four, which is exactly the shape that silently
# serves four ports as plaintext.
check_block() {
    _port="$1"; _upstream="$2"
    _line="$(grep "^BLOCK $_port " "$WORK/blocks" || true)"
    [ -n "$_line" ] || fail "no ':$_port' site block in $TEMPLATE"
    set -- $_line
    _rp="$3"; _up="$4"; _tls="$5"; _cert="$6"; _key="$7"

    [ "$_rp" -eq 1 ] || fail "block ':$_port' has $_rp reverse_proxy directives, expected exactly 1"
    case "$_up" in
        *:"$_upstream") ;;
        *) fail "block ':$_port' proxies to '$_up', expected an upstream on port $_upstream" ;;
    esac

    [ "$_tls" -eq 1 ] || fail "block ':$_port' has $_tls 'tls' directives, expected exactly 1 -- a port without its own tls line is served as plaintext on an HTTPS port"
    case "$_cert" in
        '{{CERT_DIR}}'[\\/]*.pem) ;;
        *) fail "block ':$_port' takes its certificate from '$_cert', expected a {{CERT_DIR}}-rooted .pem" ;;
    esac
    case "$_key" in
        '{{CERT_DIR}}'[\\/]*.pem) ;;
        *) fail "block ':$_port' takes its key from '$_key', expected a {{CERT_DIR}}-rooted .pem" ;;
    esac
    [ "$_cert" != "$_key" ] || fail "block ':$_port' names the same file as both certificate and key ($_cert)"
}

check_block 8443  18080   # llama-swap
check_block 3443  3000    # Open WebUI
check_block 18790 18789   # JudgeClaw
check_block 8444  8100    # LangChain
check_block 13443 13000   # Langfuse

# --- 4. no tls directive outside a site block ------------------------------
# The per-block count above cannot see a stray global tls line; a global one
# would look like "TLS is configured" while overriding nothing per port.
TLS_N="$(grep -cE '^[[:space:]]*tls[[:space:]]' "$TEMPLATE" | tr -d ' ')"
[ "$TLS_N" -eq 5 ] || fail "expected exactly 5 'tls' directives file-wide (one per block), found $TLS_N"

# --- 5. rendering is total and repeatable ----------------------------------
# Two directories on purpose. The spaced one answers "is the substitution total
# and value-independent" -- a CertDir carrying a space must still land in every
# one of the 10 slots. The plain one is what goes to caddy below, because
# whether an unquoted spaced path is a valid Caddyfile token is a question about
# the template's quoting style, not about this substitution.
render() {
    _dir="$1"; _out="$2"
    sed "s|{{CERT_DIR}}|$(printf '%s' "$_dir" | sed 's/[&|\\]/\\&/g')|g" "$TEMPLATE" > "$_out"
}
render 'C:\LLM\cert store\llama-swap' "$WORK/rendered-spaced"
render 'C:\LLM\cert store\llama-swap' "$WORK/rendered-spaced2"
render 'C:\LLM\certs\llama-swap'      "$WORK/rendered"

cmp -s "$WORK/rendered-spaced" "$WORK/rendered-spaced2" || fail "rendering the template twice produced different output"
cmp -s "$WORK/rendered-spaced" "$TEMPLATE" && fail "rendering changed nothing -- the substitution did not run"

for r in "$WORK/rendered-spaced" "$WORK/rendered"; do
    if grep -nE '\{\{[A-Za-z0-9_]+\}\}' "$r"; then
        fail "a placeholder survived rendering -- llama-swap-service.ps1 would ship it verbatim to caddy"
    fi
done

RENDERED_PEM="$(grep -o 'cert store' "$WORK/rendered-spaced" | wc -l | tr -d ' ')"
[ "$RENDERED_PEM" -eq 10 ] || fail "expected the spaced CertDir in all 10 slots, found $RENDERED_PEM"

# --- 6. caddy's own parser accepts it --------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
    echo "  note: caddy not on PATH - skipping the adapt/validate arm (the structural cases above still ran)"
else
    # `caddy adapt` is the full Caddyfile parser without provisioning, so it can
    # run against paths that do not exist on this machine. Its JSON is then the
    # authority for the per-port structure, independent of the awk above.
    if ! caddy adapt --adapter caddyfile --config "$(cygpath -m -- "$WORK/rendered" 2>/dev/null || printf '%s' "$WORK/rendered")" > "$WORK/adapted.json" 2> "$WORK/adapt.err"; then
        cat "$WORK/adapt.err" >&2
        fail "caddy rejected the rendered template"
    fi

    for p in 8443 3443 18790 8444 13443; do
        grep -Fq -- "\":$p\"" "$WORK/adapted.json"
        rc=$?
        [ "$rc" -le 1 ] || fail "grep exited $rc reading the adapted JSON"
        [ "$rc" -eq 0 ] || fail "caddy's adapted config has no listener on :$p"
    done

    # Caddy de-duplicates identical cert/key pairs into one load_files entry, so
    # the countable per-port fact is the TLS connection policy: five servers,
    # five policies. Four ports left plaintext would show four policies.
    POLICIES="$(grep -o '"tls_connection_policies"' "$WORK/adapted.json" | wc -l | tr -d ' ')"
    [ "$POLICIES" -eq 5 ] || fail "caddy produced $POLICIES TLS connection policies, expected 5 (one per site block) -- a port without one is served as plaintext"

    grep -Fq -- '"load_files"' "$WORK/adapted.json"
    rc=$?
    [ "$rc" -le 1 ] || fail "grep exited $rc reading the adapted JSON"
    [ "$rc" -eq 0 ] || fail "caddy's adapted config loads no certificate file at all"

    # `caddy validate` additionally provisions, which reads the certificate files
    # themselves. Those live outside the repo and are absent in CI, so the only
    # acceptable failure here is that one -- any other error is a real defect.
    if ! caddy validate --adapter caddyfile --config "$(cygpath -m -- "$WORK/rendered" 2>/dev/null || printf '%s' "$WORK/rendered")" > "$WORK/validate.out" 2>&1; then
        grep -Fq -- 'loading certificates' "$WORK/validate.out"
        rc=$?
        [ "$rc" -le 1 ] || fail "grep exited $rc reading the caddy validate output"
        if [ "$rc" -ne 0 ]; then
            cat "$WORK/validate.out" >&2
            fail "caddy validate failed for a reason other than the absent certificate files"
        fi
    fi
fi

echo "PASS: test-caddyfile-template (5 blocks, $PH_COUNT placeholders, each with its own tls pair)"
