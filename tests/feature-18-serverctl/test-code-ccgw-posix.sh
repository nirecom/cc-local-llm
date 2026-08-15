#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh
# Tags: lifecycle, client-launcher, scope:issue-specific
#
# Scenario: the POSIX client launcher (macOS/Linux counterpart of
# scripts/code-ccgw.cmd) — base-URL / auth-token / TLS-CA precedence chains, the
# mutually-exclusive model-selection branch (LiteLLM routing keys vs the direct
# DS4-Proxy path where CCGW_DEFAULT_MODEL picks which Mac backend the swap layer
# loads), per-OS VS Code --user-data-dir isolation, and the missing-`code` error.
#
# Method: `code` is stubbed on PATH with a script that dumps its inherited env
# and argv to files, so every assertion is made against the environment the
# launcher actually hands to Claude Code — none of the launcher's branching is
# re-implemented here. `mkcert` and `uname` are stubbed the same way. The child
# runs under `env -i`, so an ambient LITELLM_*/CCGW_*/DS4_* value in the
# developer's shell can never satisfy an assertion by accident.
#
# L3 gap: real VS Code startup and profile creation under the derived
#   --user-data-dir; a real mkcert CA actually being trusted by Node's TLS
#   stack; genuine end-to-end routing of the selected model through the Mac
#   swap layer (llama-swap) to a loaded backend.
set -u

# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LAUNCHER="$REPO/scripts/code-ccgw.sh"

[ -f "$LAUNCHER" ] || { echo "SKIP: $LAUNCHER not found (implementation pending)"; exit 77; }

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
# Pin DOTENV_FILE into this test's tmpdir so the real repo dotenv is never
# read; scripts/lib/root.sh would otherwise default it to <repo>/.env, which
# holds the developer's actual base URL and API keys.
export DOTENV_FILE="$WORK/dotenv"
printf '# intentionally empty: precedence is asserted from the shell env only\n' > "$DOTENV_FILE"
export HOME="$WORK/home"
mkdir -p "$HOME"
trap 'rm -rf "$WORK"' EXIT

DUMP="$WORK/env.dump"
ARGV="$WORK/argv.dump"

# --- stubs -------------------------------------------------------------------
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/code" <<'EOF'
#!/bin/bash
env > "$CCGW_TEST_DUMP"
printf '%s\n' "$@" > "$CCGW_TEST_ARGV"
EOF
chmod +x "$STUB/code"

# uname is stubbed so the OS branch is exercised on either host, not just the
# one this suite happens to run on.
make_uname() { # make_uname <dir> <sysname>
    mkdir -p "$1"
    printf '#!/bin/bash\nprintf %%s\\\\n %s\n' "$2" > "$1/uname"
    chmod +x "$1/uname"
}
make_uname "$STUB" Darwin

# mkcert stub prints the CAROOT it was given at creation time.
make_mkcert() { # make_mkcert <dir> <caroot>
    mkdir -p "$1"
    printf '#!/bin/bash\nprintf %%s\\\\n %s\n' "$2" > "$1/mkcert"
    chmod +x "$1/mkcert"
}

# Deliberately excludes the host's real PATH: a real mkcert (typically in
# /opt/homebrew/bin) would otherwise turn the "no mkcert" case into a false pass.
STUB_PATH="$STUB:/usr/bin:/bin"

RC=0
run_launcher() { # run_launcher [KEY=VAL ...] [-- <argv for code>]
    local envs=() args=() seen=0 a
    for a in "$@"; do
        if [ "$seen" -eq 0 ] && [ "$a" = "--" ]; then seen=1; continue; fi
        if [ "$seen" -eq 0 ]; then envs+=("$a"); else args+=("$a"); fi
    done
    rm -f "$DUMP" "$ARGV"
    env -i \
        HOME="$HOME" PATH="$STUB_PATH" DOTENV_FILE="$DOTENV_FILE" \
        CCGW_TEST_DUMP="$DUMP" CCGW_TEST_ARGV="$ARGV" \
        ${envs[@]+"${envs[@]}"} \
        bash "$LAUNCHER" ${args[@]+"${args[@]}"} >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

dump_get() { grep -m1 "^$1=" "$DUMP" | cut -d= -f2-; }

assert_env() { # assert_env <var> <expected> <context>
    [ -f "$DUMP" ] || fail "$3: stub 'code' was never reached (no env dump); stderr: $(cat "$WORK/err")"
    grep -q "^$1=" "$DUMP" || fail "$3: $1 was not exported at all (expected '$2')"
    local got; got="$(dump_get "$1")"
    [ "$got" = "$2" ] || fail "$3: $1='$got', expected '$2'"
}

assert_unset() { # assert_unset <var> <context>
    ! grep -q "^$1=" "$DUMP" || fail "$2: $1 was exported as '$(dump_get "$1")' but must not be set at all"
}

assert_stderr() { # assert_stderr <pattern> <context>
    grep -q "$1" "$WORK/err" || fail "$2: expected stderr to match '$1', got: $(cat "$WORK/err")"
}

assert_no_ca_warning() { # assert_no_ca_warning <context>
    ! grep -q 'CCGW_CA_CERT not set' "$WORK/err" || fail "$1: unexpected CA warning: $(cat "$WORK/err")"
}

MODEL_VARS="ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_CUSTOM_MODEL_OPTION ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL"

# --- 1. Base URL precedence --------------------------------------------------
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 CCGW_ANTHROPIC_BASE_URL=https://ccgw:2 DS4_ANTHROPIC_BASE_URL=https://ds4:3
[ "$RC" -eq 0 ] || fail "base-url/all-three: exited $RC: $(cat "$WORK/err")"
assert_env ANTHROPIC_BASE_URL https://lite:1 "base-url: LITELLM must win over CCGW and DS4"

run_launcher CCGW_ANTHROPIC_BASE_URL=https://ccgw:2 DS4_ANTHROPIC_BASE_URL=https://ds4:3
assert_env ANTHROPIC_BASE_URL https://ccgw:2 "base-url: CCGW must win over DS4"

run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3
assert_env ANTHROPIC_BASE_URL https://ds4:3 "base-url: DS4 is the last named source"

run_launcher
assert_env ANTHROPIC_BASE_URL https://localhost:8443 "base-url: unset falls back to loopback"
assert_stderr 'WARNING: Neither LITELLM_ANTHROPIC_BASE_URL nor CCGW_ANTHROPIC_BASE_URL set' "base-url: unset must warn"

# An empty (but defined) value must not be treated as configured — `-n` semantics,
# unlike the .cmd's `if defined`, which would accept an empty string.
run_launcher LITELLM_ANTHROPIC_BASE_URL= CCGW_ANTHROPIC_BASE_URL=https://ccgw:2
assert_env ANTHROPIC_BASE_URL https://ccgw:2 "base-url: empty LITELLM value must fall through to CCGW"

# --- 2. Auth token precedence ------------------------------------------------
run_launcher LITELLM_VIRTUAL_KEY=vk CCGW_API_KEY=ck DS4_API_KEY=dk
assert_env ANTHROPIC_AUTH_TOKEN vk "auth: LITELLM_VIRTUAL_KEY must win"

run_launcher CCGW_API_KEY=ck DS4_API_KEY=dk
assert_env ANTHROPIC_AUTH_TOKEN ck "auth: CCGW_API_KEY must win over DS4_API_KEY"

run_launcher DS4_API_KEY=dk
assert_env ANTHROPIC_AUTH_TOKEN dk "auth: DS4_API_KEY is the last named source"

run_launcher
assert_env ANTHROPIC_AUTH_TOKEN dsv4-local "auth: unset falls back to the shared local token"
assert_stderr 'WARNING: Neither LITELLM_VIRTUAL_KEY nor CCGW_API_KEY set' "auth: unset must warn"

# A real cloud key in the ambient env must be neutralised, not forwarded.
run_launcher ANTHROPIC_API_KEY=cloud-key-must-not-survive DS4_API_KEY=dk
assert_env ANTHROPIC_API_KEY "" "auth: a pre-existing ANTHROPIC_API_KEY must be cleared so the local backend is used"

# --- 3. TLS CA precedence ----------------------------------------------------
run_launcher CCGW_CA_CERT=/ca/ccgw.pem DS4_CA_CERT=/ca/ds4.pem
assert_env NODE_EXTRA_CA_CERTS /ca/ccgw.pem "ca: CCGW_CA_CERT must win over DS4_CA_CERT"
assert_no_ca_warning "ca: explicit CCGW_CA_CERT"

run_launcher DS4_CA_CERT=/ca/ds4.pem
assert_env NODE_EXTRA_CA_CERTS /ca/ds4.pem "ca: DS4_CA_CERT is the second source"

# NODE_TLS_REJECT_UNAUTHORIZED=0 must never be the launcher's answer to TLS.
assert_unset NODE_TLS_REJECT_UNAUTHORIZED "ca: TLS verification must never be disabled"

# 3a. mkcert derivation — the behavior the Windows .cmd does not have.
CAROOT_OK="$WORK/caroot-ok"
mkdir -p "$CAROOT_OK"
: > "$CAROOT_OK/rootCA.pem"
MKCERT_OK="$WORK/stub-mkcert-ok"
make_mkcert "$MKCERT_OK" "$CAROOT_OK"
make_uname "$MKCERT_OK" Darwin
cp "$STUB/code" "$MKCERT_OK/code"

SAVED_PATH="$STUB_PATH"
STUB_PATH="$MKCERT_OK:/usr/bin:/bin"
run_launcher
assert_env NODE_EXTRA_CA_CERTS "$CAROOT_OK/rootCA.pem" "ca: mkcert -CAROOT must be derived when no CA var is set"
grep -q 'CCGW_CA_CERT not set' "$WORK/err" && fail "ca/mkcert-ok: warned even though the CA was successfully derived: $(cat "$WORK/err")"

# An explicit CA still outranks the mkcert derivation.
run_launcher CCGW_CA_CERT=/ca/explicit.pem
assert_env NODE_EXTRA_CA_CERTS /ca/explicit.pem "ca: explicit CCGW_CA_CERT must outrank the mkcert derivation"

# 3b. mkcert present but its CAROOT holds no rootCA.pem -> warn, export nothing.
CAROOT_EMPTY="$WORK/caroot-empty"
mkdir -p "$CAROOT_EMPTY"
MKCERT_BAD="$WORK/stub-mkcert-bad"
make_mkcert "$MKCERT_BAD" "$CAROOT_EMPTY"
make_uname "$MKCERT_BAD" Darwin
cp "$STUB/code" "$MKCERT_BAD/code"
STUB_PATH="$MKCERT_BAD:/usr/bin:/bin"
run_launcher
assert_unset NODE_EXTRA_CA_CERTS "ca/mkcert-empty: a CAROOT without rootCA.pem must not yield a bogus NODE_EXTRA_CA_CERTS"
assert_stderr 'CCGW_CA_CERT not set' "ca/mkcert-empty: must warn"

# 3c. mkcert absent entirely -> warn, export nothing.
STUB_PATH="$SAVED_PATH"
run_launcher
assert_unset NODE_EXTRA_CA_CERTS "ca/no-mkcert: nothing to derive from"
assert_stderr 'CCGW_CA_CERT not set' "ca/no-mkcert: must warn"

# --- 4. Model selection (the mutually-exclusive backend choice) --------------
# 4a. LiteLLM path: routing keys are used verbatim, and no backend name of the
# launcher's own invention is emitted.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 \
    LITELLM_OPUS_MODEL=lite-opus LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku \
    CCGW_DEFAULT_MODEL=laguna-s-2.1
assert_env ANTHROPIC_MODEL lite-opus "litellm: opus routing key"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "litellm: opus routing key"
assert_env ANTHROPIC_CUSTOM_MODEL_OPTION lite-opus "litellm: opus routing key"
assert_env CLAUDE_CODE_SUBAGENT_MODEL lite-opus "litellm: subagent follows opus"
assert_env ANTHROPIC_DEFAULT_SONNET_MODEL lite-sonnet "litellm: sonnet routing key"
assert_env ANTHROPIC_DEFAULT_HAIKU_MODEL lite-haiku "litellm: haiku routing key"
# CCGW_DEFAULT_MODEL was also set above: on the LiteLLM path it must be ignored,
# and no deepseek-*/laguna-* name may appear in any model var.
for v in $MODEL_VARS; do
    val="$(dump_get "$v")"
    case "$(printf '%s' "$val" | tr 'A-Z' 'a-z')" in
        *deepseek*|*laguna*) fail "litellm: $v='$val' leaked a direct-path backend name; LiteLLM routing keys are exclusive" ;;
    esac
done

# 4b. LiteLLM base URL set but no routing keys: nothing may be invented.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1
for v in $MODEL_VARS; do
    assert_unset "$v" "litellm/no-keys: launcher must not substitute a direct-path model"
done

# 4c. Direct path default.
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3
for v in $MODEL_VARS; do
    assert_env "$v" deepseek-v4-flash "direct: default model"
done

# 4d. Direct path with the swap layer's other backend selected — the core of the
# feature: the client picks which of the two mutually-exclusive Mac backends loads.
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3 CCGW_DEFAULT_MODEL=laguna-s-2.1
for v in $MODEL_VARS; do
    assert_env "$v" laguna-s-2.1 "direct: CCGW_DEFAULT_MODEL must propagate to every model var"
done

# A defined-but-empty CCGW_DEFAULT_MODEL must fall back to the default, not send
# an empty model name the swap layer cannot route (`:-`, not `-`).
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3 CCGW_DEFAULT_MODEL=
for v in $MODEL_VARS; do
    assert_env "$v" deepseek-v4-flash "direct: empty CCGW_DEFAULT_MODEL must fall back to the default"
done

# 4e. Stale LITELLM_*_MODEL keys in .env/shell must never reach the direct path —
# DS4 Proxy / the swap layer do not recognise them.
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3 \
    LITELLM_OPUS_MODEL=lite-opus LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku
for v in $MODEL_VARS; do
    assert_env "$v" deepseek-v4-flash "direct/stale-litellm-keys: LiteLLM routing keys must not leak onto the direct path"
done

# --- 5. VS Code profile isolation and argv passthrough ----------------------
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3 -- /some/project --new-window
[ "$RC" -eq 0 ] || fail "argv: exited $RC: $(cat "$WORK/err")"
EXPECT_ARGV="--user-data-dir
$HOME/Library/Application Support/vscode-ccgw
/some/project
--new-window"
GOT_ARGV="$(cat "$ARGV")"
[ "$GOT_ARGV" = "$EXPECT_ARGV" ] || fail "argv on Darwin:
  expected: $EXPECT_ARGV
  actual:   $GOT_ARGV"

# Linux: XDG_DATA_HOME default.
LINUX_STUB="$WORK/stub-linux"
make_uname "$LINUX_STUB" Linux
cp "$STUB/code" "$LINUX_STUB/code"
STUB_PATH="$LINUX_STUB:/usr/bin:/bin"
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3
GOT_ARGV="$(cat "$ARGV")"
EXPECT_ARGV="--user-data-dir
$HOME/.local/share/vscode-ccgw"
[ "$GOT_ARGV" = "$EXPECT_ARGV" ] || fail "argv on Linux (XDG unset):
  expected: $EXPECT_ARGV
  actual:   $GOT_ARGV"

# Linux: explicit XDG_DATA_HOME is honored.
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3 XDG_DATA_HOME="$WORK/xdg"
GOT_ARGV="$(cat "$ARGV")"
EXPECT_ARGV="--user-data-dir
$WORK/xdg/vscode-ccgw"
[ "$GOT_ARGV" = "$EXPECT_ARGV" ] || fail "argv on Linux (XDG_DATA_HOME set):
  expected: $EXPECT_ARGV
  actual:   $GOT_ARGV"

STUB_PATH="$SAVED_PATH"

# --- 6. Missing `code` on PATH ----------------------------------------------
NO_CODE="$WORK/stub-nocode"
make_uname "$NO_CODE" Darwin
STUB_PATH="$NO_CODE:/usr/bin:/bin"
run_launcher DS4_ANTHROPIC_BASE_URL=https://ds4:3
[ "$RC" -ne 0 ] || fail "missing-code: exited 0; a missing 'code' must be a hard failure"
assert_stderr "ERROR: 'code' command not found on PATH" "missing-code: must name the problem"
assert_stderr "Install 'code' command in PATH" "missing-code: must state the remedy"

echo "PASS: test-code-ccgw-posix"
