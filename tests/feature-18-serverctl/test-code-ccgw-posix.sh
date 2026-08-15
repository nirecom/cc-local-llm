#!/usr/bin/env bash
# Tests: scripts/code-ccgw.sh
# Tags: lifecycle, client-launcher, scope:issue-specific
#
# Scenario (issue #41 / detail plan D5a): the direct-to-DS4-Proxy route is
# retired, so the POSIX client launcher (macOS/Linux counterpart of
# scripts/code-ccgw.ps1) has exactly ONE path — through the Mac LiteLLM.
#
# Why the precedence chains had to go, rather than merely being re-pointed:
# keeping a direct fallback would split the credential a client holds into two
# systems (a LiteLLM key and a proxy token), which defeats the TLS termination
# this change consolidates. With a single source there is nothing to fall back
# to, so an unconfigured base URL / key is an error, never a dummy default —
# a dummy default is what turns a misconfiguration into a confusing 401 much
# later, at request time.
#
# What this covers: the single-source base URL and its exit-1 on absence, the
# LITELLM_CLIENT_KEY credential with LITELLM_VIRTUAL_KEY accepted for one
# deprecation cycle (with a warning), the retained CCGW_CA_CERT + mkcert
# derivation, the unconditional LITELLM_*_MODEL tier assignment, the new
# subagent contract, per-OS VS Code --user-data-dir isolation, and the
# missing-`code` error.
#
# Method: `code` is stubbed on PATH with a script that dumps its inherited env
# and argv to files, so every assertion is made against the environment the
# launcher actually hands to Claude Code — none of the launcher's branching is
# re-implemented here. `mkcert` and `uname` are stubbed the same way. The child
# runs under `env -i`, so an ambient LITELLM_*/CCGW_*/DS4_* value in the
# developer's shell can never satisfy an assertion by accident.
#
# TL3 gap: real VS Code startup and profile creation under the derived
#   --user-data-dir; a real mkcert CA actually being trusted by Node's TLS
#   stack; genuine end-to-end routing of the selected routing key through
#   LiteLLM to a loaded backend.
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

assert_env_differs() { # assert_env_differs <var-a> <var-b> <context>
    local a b
    a="$(dump_get "$1")"; b="$(dump_get "$2")"
    [ "$a" != "$b" ] || fail "$3: $1 and $2 both resolved to '$a'; the two backends must stay on separate tiers"
}

assert_stderr() { # assert_stderr <pattern> <context>
    grep -q "$1" "$WORK/err" || fail "$2: expected stderr to match '$1', got: $(cat "$WORK/err")"
}

assert_no_ca_warning() { # assert_no_ca_warning <context>
    ! grep -q 'CCGW_CA_CERT not set' "$WORK/err" || fail "$1: unexpected CA warning: $(cat "$WORK/err")"
}

# The four /model tiers Claude Code switches between.
TIER_VARS="ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL"
# The vars that name the model in play at startup. CLAUDE_CODE_SUBAGENT_MODEL
# is deliberately NOT here any more: it is now opt-in (section 4d).
ACTIVE_VARS="ANTHROPIC_MODEL ANTHROPIC_CUSTOM_MODEL_OPTION"
MODEL_VARS="$TIER_VARS $ACTIVE_VARS CLAUDE_CODE_SUBAGENT_MODEL"

# --- Retired variable names --------------------------------------------------
# The cases that prove a retired variable no longer configures anything need
# its exact spelling, but those spellings are banned repo-wide by
# tests/ccgw-naming/test_no_legacy_names.py, whose scan is a raw substring
# match over every tracked file — this one included. The names are therefore
# assembled at runtime instead of appearing as literals. The cases themselves
# must stay: a stale .env still carrying them is precisely the situation where
# a surviving fallback would silently route around the new single path.
R_BASE_DS4="DS4_ANTHROPIC""_BASE_URL"
R_BASE_CCGW="CCGW_ANTHROPIC""_BASE_URL"
R_KEY_DS4="DS4_API""_KEY"
R_KEY_CCGW="CCGW_API""_KEY"
R_CA_DS4="DS4_CA""_CERT"
R_DEFAULT_MODEL="CCGW_DEFAULT""_MODEL"

# --- 1. Base URL: single source, hard failure when absent --------------------
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
[ "$RC" -eq 0 ] || fail "base-url/configured: exited $RC: $(cat "$WORK/err")"
assert_env ANTHROPIC_BASE_URL https://lite:1 "base-url: LITELLM_ANTHROPIC_BASE_URL is the only source"

# The retired sources must not be honored — a stale .env carrying them is
# exactly the situation where a silent fallback would send traffic down the
# route this change removed.
run_launcher "$R_BASE_CCGW=https://ccgw:2" "$R_BASE_DS4=https://ds4:3" LITELLM_CLIENT_KEY=ck
[ "$RC" -ne 0 ] || fail "base-url/retired-only: exited 0; CCGW_/DS4_ base URLs are retired and must not configure the launcher"

run_launcher LITELLM_CLIENT_KEY=ck
[ "$RC" -ne 0 ] || fail "base-url/unset: exited 0; an unset base URL must be a hard failure, not a dummy default"
assert_stderr 'LITELLM_ANTHROPIC_BASE_URL' "base-url/unset: the error must name the variable to set"
assert_stderr 'docs/ops.md' "base-url/unset: the error must point at the setup procedure"

# An empty (but defined) value must not count as configured — `-n` semantics,
# unlike the retired .cmd's `if defined`, which would accept an empty string.
# The .ps1 port matches this `-n` behaviour via its Get-EnvOrNull helper.
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

# --- 4. Model selection (unconditional LiteLLM routing keys) ----------------
# With the direct path gone there is no branch left: each LITELLM_*_MODEL is a
# LiteLLM routing key and goes onto its own /model tier verbatim. The launcher
# owns no backend names of its own — inventing one would route to a model the
# gateway has no entry for, and the error would surface as a 400 from LiteLLM
# rather than as a launcher message.

# 4a. All four keys present.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_FABLE_MODEL=lite-fable LITELLM_OPUS_MODEL=lite-opus \
    LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku
[ "$RC" -eq 0 ] || fail "models/all-keys: exited $RC: $(cat "$WORK/err")"
assert_env ANTHROPIC_DEFAULT_FABLE_MODEL lite-fable "models: fable routing key"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "models: opus routing key"
assert_env ANTHROPIC_DEFAULT_SONNET_MODEL lite-sonnet "models: sonnet routing key"
assert_env ANTHROPIC_DEFAULT_HAIKU_MODEL lite-haiku "models: haiku routing key"
assert_env ANTHROPIC_MODEL lite-fable "models: startup model follows the fable tier"
assert_env ANTHROPIC_CUSTOM_MODEL_OPTION lite-fable "models: custom model option follows the fable tier"
# Stated as an inequality too: a regression that collapses the tiers onto one
# key would still satisfy each literal individually if all literals moved.
assert_env_differs ANTHROPIC_DEFAULT_FABLE_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
    "models: fable and opus must address different routing keys or /model cannot switch"

# 4b. The retired direct-path backend names must never appear. The launcher is
# not allowed to know them any more.
for v in $MODEL_VARS; do
    val="$(dump_get "$v")"
    case "$(printf '%s' "$val" | tr 'A-Z' 'a-z')" in
        *deepseek*|*laguna*) fail "models: $v='$val' is a backend name, not a LiteLLM routing key; the launcher must carry no backend literals" ;;
    esac
done

# 4c. The retired startup-model variable goes with the direct path: setting it
# must change nothing at all.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_FABLE_MODEL=lite-fable LITELLM_OPUS_MODEL=lite-opus \
    LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku \
    "$R_DEFAULT_MODEL=laguna-s-2.1"
assert_env ANTHROPIC_MODEL lite-fable "models/ccgw-default: the retired startup-model variable must be ignored"
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "models/ccgw-default: the tier map must be unaffected"

# 4d. Subagent contract (three cases).
#
# Why it changed: the old launcher pinned CLAUDE_CODE_SUBAGENT_MODEL to the
# fable tier so a subagent could not evict the resident backend. Routing now
# goes through LiteLLM, which multiplexes, so the pin is no longer needed — and
# it actively harms, because it silently overrides the model an agent
# definition's frontmatter declares. Default is therefore "say nothing";
# CCGW_SUBAGENT_MODEL exists only for the case where a user deliberately wants
# every subagent confined to one route.

# (i) Default: not set at all, so agent frontmatter decides.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_FABLE_MODEL=lite-fable LITELLM_OPUS_MODEL=lite-opus \
    LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku
assert_unset CLAUDE_CODE_SUBAGENT_MODEL "subagent/default: must not be exported — an unconditional value overrides agent frontmatter"

# (ii) Opt-in: CCGW_SUBAGENT_MODEL is exported verbatim.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_FABLE_MODEL=lite-fable LITELLM_OPUS_MODEL=lite-opus \
    LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku \
    CCGW_SUBAGENT_MODEL=lite-haiku
assert_env CLAUDE_CODE_SUBAGENT_MODEL lite-haiku "subagent/opt-in: CCGW_SUBAGENT_MODEL must be exported as given"

# (iii) Value domain is a routing key, passed through untranslated: an
# arbitrary key the launcher has never heard of must survive intact, and a tier
# name must NOT be mapped to a tier's value.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_FABLE_MODEL=lite-fable LITELLM_OPUS_MODEL=lite-opus \
    LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku \
    CCGW_SUBAGENT_MODEL=some-other-routing-key
assert_env CLAUDE_CODE_SUBAGENT_MODEL some-other-routing-key "subagent/domain: the value is a LiteLLM routing key and must not be translated"

# A defined-but-empty value counts as unset — exporting an empty model name
# would make Claude Code request "" and fail at the gateway.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_FABLE_MODEL=lite-fable CCGW_SUBAGENT_MODEL=
assert_unset CLAUDE_CODE_SUBAGENT_MODEL "subagent/empty: an empty CCGW_SUBAGENT_MODEL must be treated as unset"

# 4e. No routing keys at all: nothing may be invented.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck
for v in $MODEL_VARS; do
    assert_unset "$v" "models/no-keys: the launcher must substitute no model name of its own"
done

# 4f. Partial keys: each tier is independent, and the fable tier drives the
# startup vars, so with LITELLM_FABLE_MODEL absent they stay unset rather than
# borrowing another tier's key.
run_launcher LITELLM_ANTHROPIC_BASE_URL=https://lite:1 LITELLM_CLIENT_KEY=ck \
    LITELLM_OPUS_MODEL=lite-opus LITELLM_SONNET_MODEL=lite-sonnet LITELLM_HAIKU_MODEL=lite-haiku
assert_env ANTHROPIC_DEFAULT_OPUS_MODEL lite-opus "models/no-fable: opus routing key still applies"
assert_unset ANTHROPIC_DEFAULT_FABLE_MODEL "models/no-fable: no fable key means no fable tier"
for v in $ACTIVE_VARS; do
    assert_unset "$v" "models/no-fable: the launcher must invent no model name of its own"
done

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
