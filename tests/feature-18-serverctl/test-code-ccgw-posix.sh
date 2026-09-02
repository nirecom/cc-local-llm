#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh, litellm-server/config.yaml
# Tags: lifecycle, client-launcher, scope:issue-specific
set -u

# This launcher (macOS/Linux counterpart of code-ccgw.ps1) has exactly ONE
# path -- through the Mac LiteLLM -- so an unconfigured base URL or key is a
# hard error, never a dummy default (docs/architecture.md).
# REPO is derived from $0's logical location (no symlink target resolution - see test-repo-derivation.sh); export REPO=<path> to point at another checkout.
REPO="${REPO:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
LAUNCHER="$REPO/scripts/code-ccgw.sh"

[ -f "$LAUNCHER" ] || { echo "SKIP: $LAUNCHER not found (implementation pending)"; exit 77; }

# Covered here: the single-source base URL and its exit-1 on absence, the
# LITELLM_CLIENT_KEY credential (LITELLM_VIRTUAL_KEY accepted for one
# deprecation cycle, with a warning) and the sweeps proving neither is echoed
# back, the CCGW_CA_CERT + mkcert derivation, per-OS VS Code --user-data-dir
# isolation and the missing-`code` error. Tier selection moved to
# test-code-ccgw-config-tiers.sh and the pre-launch pull to
# test-code-ccgw-auto-pull.sh when config.yaml took ownership (issue #89).
fail() { echo "FAIL: $*" >&2; exit 1; }

# TL3 gap: real VS Code startup and profile creation under the derived
#   --user-data-dir; a real mkcert CA actually being trusted by Node's TLS
#   stack; genuine end-to-end routing of the selected routing key through
#   LiteLLM to a loaded backend.
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

# --- the config.yaml the launcher derives its tiers from ---------------------
# Routing keys live here now (issue #89), so even the cases below that assert
# nothing about tiers need a readable one: without it the launcher has nothing
# to put on the /model tiers and would fail for a reason none of them is about.
OPS="$WORK/ops"
mkdir -p "$OPS/litellm-server"
cat > "$OPS/litellm-server/config.yaml" <<'EOF'
model_list:
  # --- Haiku, sonnet and the subagent route share one backend ---
  - model_name: lite-shared
    litellm_params:
      model: openai/Qwen3.8-27B
      ccgw_tiers: [haiku, sonnet, subagent]

  # --- Fable tier ---
  - model_name: lite-fable
    litellm_params:
      model: anthropic/deepseek-v4-flash
      ccgw_tiers: [fable]

  # --- Opus tier ---
  - model_name: lite-opus
    litellm_params:
      model: openai/qwen3.8-flash-next-3bit-mtp
      ccgw_tiers: [opus]
EOF

# --- stubs -------------------------------------------------------------------
# Method: `code` is stubbed on PATH with a script that dumps its inherited env
# and argv to files, so every assertion is made against the environment the
# launcher actually hands to Claude Code -- none of its branching is
# re-implemented here. `mkcert` and `uname` are stubbed the same way. The child
# runs under `env -i`, so an ambient LITELLM_*/CCGW_*/DS4_* value in the
# developer's shell can never satisfy an assertion by accident.
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
    # CCGW_AUTO_PULL defaults to on: left alone, every case here would reach
    # for a git remote before launching. Pinned off -- the pull is
    # test-code-ccgw-auto-pull.sh's subject, not a side effect of these cases.
    env -i \
        HOME="$HOME" PATH="$STUB_PATH" DOTENV_FILE="$DOTENV_FILE" \
        CCGW_OPS_ROOT="$OPS" CCGW_AUTO_PULL=off \
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

# The dump's own existence is checked first, the same way the sibling copies in
# test-code-ccgw-config-guards.sh and code-ccgw-config-tiers/fixture.sh do
# (CPR-ORTH). grep over a file that was never written reports "no match" too, so
# a launcher that died before ever reaching the stub 'code' would otherwise
# satisfy every "must not be set" row here for the wrong reason.
assert_unset() { # assert_unset <var> <context>
    [ -f "$DUMP" ] || fail "$2: stub 'code' was never reached (no env dump); stderr: $(cat "$WORK/err" 2>/dev/null)"
    ! grep -q "^$1=" "$DUMP" || fail "$2: $1 was exported as '$(dump_get "$1")' but must not be set at all"
}

assert_stderr() { # assert_stderr <pattern> <context>
    grep -q "$1" "$WORK/err" || fail "$2: expected stderr to match '$1', got: $(cat "$WORK/err")"
}

assert_no_ca_warning() { # assert_no_ca_warning <context>
    ! grep -q 'CCGW_CA_CERT not set' "$WORK/err" || fail "$1: unexpected CA warning: $(cat "$WORK/err")"
}

# --- Retired variable names --------------------------------------------------
# Assembled at runtime -- the literal spellings are banned repo-wide by
# tests/ccgw-naming/test_no_legacy_names.py.
R_BASE_DS4="DS4_ANTHROPIC""_BASE_URL"
R_BASE_CCGW="CCGW_ANTHROPIC""_BASE_URL"
R_KEY_DS4="DS4_API""_KEY"
R_KEY_CCGW="CCGW_API""_KEY"
R_CA_DS4="DS4_CA""_CERT"

# --- 1. Base URL: single source, hard failure when absent --------------------
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
[ "$RC" -eq 0 ] || fail "base-url/configured: exited $RC: $(cat "$WORK/err")"
assert_env ANTHROPIC_BASE_URL https://lite:1 "base-url: LITELLM_ANTHROPIC_BASE_URL is the only source"

# A stale .env carrying only the retired sources must not be honored.
run_launcher "$R_BASE_CCGW=https://ccgw:2" "$R_BASE_DS4=https://ds4:3" LITELLM_CLIENT_KEY=ck
[ "$RC" -ne 0 ] || fail "base-url/retired-only: exited 0; CCGW_/DS4_ base URLs are retired and must not configure the launcher"

run_launcher LITELLM_CLIENT_KEY=ck
[ "$RC" -ne 0 ] || fail "base-url/unset: exited 0; an unset base URL must be a hard failure, not a dummy default"
assert_stderr 'LITELLM_ANTHROPIC_BASE_URL' "base-url/unset: the error must name the variable to set"
assert_stderr 'docs/ops.md' "base-url/unset: the error must point at the setup procedure"

# An empty (but defined) value must not count as configured (`-n` semantics).
run_launcher LITELLM_ANTHROPIC_BASE_URL= LITELLM_CLIENT_KEY=ck
[ "$RC" -ne 0 ] || fail "base-url/empty: an empty LITELLM_ANTHROPIC_BASE_URL must be treated as unset"

# --- 2. Auth token: LITELLM_CLIENT_KEY, with a one-cycle deprecated alias ----
# No virtual keys exist without a LiteLLM database, so the client credential is
# the master key itself; LITELLM_VIRTUAL_KEY survives one cycle because an
# existing .env carrying only the old name would otherwise 401 with no clue.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
assert_env ANTHROPIC_AUTH_TOKEN ck "auth: LITELLM_CLIENT_KEY is the credential"
! grep -qi 'deprecat' "$WORK/err" || fail "auth/current-name: warned about deprecation even though the current name was used: $(cat "$WORK/err")"

run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_VIRTUAL_KEY=vk
assert_env ANTHROPIC_AUTH_TOKEN vk "auth: the deprecated alias is still accepted for one cycle"
assert_stderr 'LITELLM_VIRTUAL_KEY' "auth/alias: using the deprecated name must warn"
assert_stderr 'LITELLM_CLIENT_KEY' "auth/alias: the warning must name the replacement"

# Both set: the current name wins, so a half-migrated .env behaves predictably.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck LITELLM_VIRTUAL_KEY=vk
assert_env ANTHROPIC_AUTH_TOKEN ck "auth: LITELLM_CLIENT_KEY must win over the deprecated alias"

# The retired client credentials must not configure anything.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 "$R_KEY_CCGW=ck" "$R_KEY_DS4=dk"
[ "$RC" -ne 0 ] || fail "auth/retired-only: exited 0; the retired client key variables must not configure the launcher (the proxy token is now internal to LiteLLM)"

run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1
[ "$RC" -ne 0 ] || fail "auth/unset: exited 0; a missing credential must be a hard failure, not a shared dummy token"
assert_stderr 'LITELLM_CLIENT_KEY' "auth/unset: the error must name the variable to set"
! grep -q 'dsv4-local' "$WORK/err" || fail "auth/unset: the retired dummy token still appears: $(cat "$WORK/err")"

# A real cloud key in the ambient env must be neutralised, not forwarded.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck ANTHROPIC_API_KEY=cloud-key-must-not-survive
assert_env ANTHROPIC_API_KEY "" "auth: a pre-existing ANTHROPIC_API_KEY must be cleared so the local backend is used"

# --- 2a. The credential must not come back out -------------------------------
# Section 2 proves the key reaches the child; nothing yet proves it reaches
# nowhere else. It is the LiteLLM master key itself -- there are no virtual keys
# without a database -- and every failure path above prints variable names into
# the terminal the operator screenshots. The Windows half of this contract is
# context-15's `15b` (CPR-ORTH). The deprecated alias is swept the same way
# because its whole purpose is to WARN, and a warning that quotes the value it
# is deprecating is how this leak actually happens.
assert_no_secret_in_tree() { # assert_no_secret_in_tree <dir> <secret> <context>
    local hits
    hits="$(grep -rlaF -- "$2" "$1" 2>/dev/null)"
    [ -z "$hits" ] || fail "$3: the credential was written into: $hits"
    hits="$(find "$1" -name "*$2*" 2>/dev/null)"
    [ -z "$hits" ] || fail "$3: the credential appears in the NAME of: $hits"
}

# A negative sweep over a directory that is usually empty passes while testing
# nothing, so it is made to fail on a tree that plainly holds a secret first.
mkdir -p "$WORK/leak-selftest"
printf 'ANTHROPIC_AUTH_TOKEN=%s\n' 'leak-probe-value' > "$WORK/leak-selftest/probe.log"
( assert_no_secret_in_tree "$WORK/leak-selftest" 'leak-probe-value' "harness self-test" ) >/dev/null 2>&1 \
    && fail "harness self-test: assert_no_secret_in_tree passed a tree that plainly contains the secret; both sweeps below assert nothing"
rm -rf "$WORK/leak-selftest"

# TMPDIR is each pass's own and created empty, so anything found in it after the
# run was written during it -- by the launcher or by what it invoked. All three
# spellings are handed over: macOS and Git-for-Windows bash read different ones.
while IFS='|' read -r name var warn; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; var="${var//[[:space:]]/}"; warn="${warn//[[:space:]]/}"
    SECRET="n0t-a-real-client-key-$name-7f2b"
    LEAK_TMP="$WORK/leak-tmp-$name"
    rm -rf "$LEAK_TMP"
    mkdir -p "$LEAK_TMP"
    run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 "$var=$SECRET" \
        TMPDIR="$LEAK_TMP" TEMP="$LEAK_TMP" TMP="$LEAK_TMP"
    [ "$RC" -eq 0 ] || fail "leak/$name: exited $RC: $(cat "$WORK/err")"
    assert_env ANTHROPIC_AUTH_TOKEN "$SECRET" \
        "leak/$name: the credential must still reach the child verbatim; dropping it to stay quiet is not the fix"
    case "$(cat "$WORK/out" "$WORK/err")" in
        *"$SECRET"*) fail "leak/$name: the gateway credential was echoed back into the terminal: $(cat "$WORK/out" "$WORK/err")" ;;
    esac
    assert_no_secret_in_tree "$LEAK_TMP" "$SECRET" \
        "leak/$name: the credential landed in a file, which outlives the terminal it was kept out of"
    if [ "$warn" = warns ]; then
        assert_stderr 'LITELLM_CLIENT_KEY' \
            "leak/$name: redacting the value must not silence the deprecation warning, which still has to name the replacement"
    fi
done <<'TABLE'
current | LITELLM_CLIENT_KEY  | quiet
alias   | LITELLM_VIRTUAL_KEY | warns
TABLE

# --- 3. TLS CA (retained: LiteLLM terminates TLS with the mkcert leaf) -------
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck CCGW_CA_CERT=/ca/ccgw.pem
assert_env NODE_EXTRA_CA_CERTS /ca/ccgw.pem "ca: CCGW_CA_CERT is honored"
assert_no_ca_warning "ca: explicit CCGW_CA_CERT"

# The direct-path CA variable is retired along with the route it served.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck "$R_CA_DS4=/ca/ds4.pem"
assert_unset NODE_EXTRA_CA_CERTS "ca: the retired direct-path CA variable must not be picked up"

# NODE_TLS_REJECT_UNAUTHORIZED=0 must never be the launcher's answer to TLS.
assert_unset NODE_TLS_REJECT_UNAUTHORIZED "ca: TLS verification must never be disabled"

# 3a. mkcert derivation — mirrored by the Windows .ps1 (see
# code-ccgw-windows.Tests.ps1); the retired .cmd had no equivalent.
CAROOT_OK="$WORK/caroot-ok"
mkdir -p "$CAROOT_OK"
: > "$CAROOT_OK/rootCA.pem"
MKCERT_OK="$WORK/stub-mkcert-ok"
make_mkcert "$MKCERT_OK" "$CAROOT_OK"
make_uname "$MKCERT_OK" Darwin
cp "$STUB/code" "$MKCERT_OK/code"

SAVED_PATH="$STUB_PATH"
STUB_PATH="$MKCERT_OK:/usr/bin:/bin"
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
assert_env NODE_EXTRA_CA_CERTS "$CAROOT_OK/rootCA.pem" "ca: mkcert -CAROOT must be derived when no CA var is set"
grep -q 'CCGW_CA_CERT not set' "$WORK/err" && fail "ca/mkcert-ok: warned even though the CA was successfully derived: $(cat "$WORK/err")"

# An explicit CA still outranks the mkcert derivation.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck CCGW_CA_CERT=/ca/explicit.pem
assert_env NODE_EXTRA_CA_CERTS /ca/explicit.pem "ca: explicit CCGW_CA_CERT must outrank the mkcert derivation"

# 3b. mkcert present but its CAROOT holds no rootCA.pem -> warn, export nothing.
CAROOT_EMPTY="$WORK/caroot-empty"
mkdir -p "$CAROOT_EMPTY"
MKCERT_BAD="$WORK/stub-mkcert-bad"
make_mkcert "$MKCERT_BAD" "$CAROOT_EMPTY"
make_uname "$MKCERT_BAD" Darwin
cp "$STUB/code" "$MKCERT_BAD/code"
STUB_PATH="$MKCERT_BAD:/usr/bin:/bin"
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
assert_unset NODE_EXTRA_CA_CERTS "ca/mkcert-empty: a CAROOT without rootCA.pem must not yield a bogus NODE_EXTRA_CA_CERTS"
assert_stderr 'CCGW_CA_CERT not set' "ca/mkcert-empty: must warn"

# 3c. mkcert absent entirely -> warn, export nothing.
STUB_PATH="$SAVED_PATH"
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
assert_unset NODE_EXTRA_CA_CERTS "ca/no-mkcert: nothing to derive from"
assert_stderr 'CCGW_CA_CERT not set' "ca/no-mkcert: must warn"

# --- 4. Model selection ------------------------------------------------------
# Moved to test-code-ccgw-config-tiers.sh (issue #89): the tier map is derived
# from config.yaml's ccgw_tiers annotations now, so it needs a fixture matrix of
# its own -- one config per case -- rather than the flat env sweep that lived
# here. This file keeps the concerns that a single fixture config serves.

# --- 5. VS Code profile isolation and argv passthrough ----------------------
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck -- /some/project --new-window
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
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
GOT_ARGV="$(cat "$ARGV")"
EXPECT_ARGV="--user-data-dir
$HOME/.local/share/vscode-ccgw"
[ "$GOT_ARGV" = "$EXPECT_ARGV" ] || fail "argv on Linux (XDG unset):
  expected: $EXPECT_ARGV
  actual:   $GOT_ARGV"

# Linux: explicit XDG_DATA_HOME is honored.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck XDG_DATA_HOME="$WORK/xdg"
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
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
[ "$RC" -ne 0 ] || fail "missing-code: exited 0; a missing 'code' must be a hard failure"
assert_stderr "ERROR: 'code' command not found on PATH" "missing-code: must name the problem"
assert_stderr "Install 'code' command in PATH" "missing-code: must state the remedy"

echo "PASS: test-code-ccgw-posix"
