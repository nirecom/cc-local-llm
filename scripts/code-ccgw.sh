#!/bin/bash
# ccgw client launcher (macOS / Linux). POSIX counterpart of scripts/code-ccgw.ps1.
#
# Every client reaches the backends through the Mac LiteLLM gateway; the direct
# CCGW Proxy route is retired, so there is exactly one path and nothing to fall
# back to. An unconfigured base URL or credential is therefore an error rather
# than a dummy default -- a dummy default only defers the failure to a confusing
# 401 at request time. Rationale: docs/architecture.md;
# procedure: docs/ops.md#client-macos--linux.
#
# Usage: ./scripts/code-ccgw.sh [args passed through to `code`]
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# Load the repo-root .env (gitignored) so the real Mac LAN IP is never committed.
# lib/load-dotenv.sh keeps the "shell value wins over .env" semantics that
# code-ccgw.ps1 implements with its own "shell value wins" check.
CCGW_SCRIPT_DIR="$SCRIPT_DIR"
# shellcheck source=scripts/lib/root.sh
. "$SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$SCRIPT_DIR/lib/load-dotenv.sh"
# shellcheck source=scripts/lib/git-remote.sh
. "$SCRIPT_DIR/lib/git-remote.sh"

CCGW_CONFIG_FILE="$CCGW_OPS_ROOT/litellm-server/config.yaml"
_ccgw_warn() { printf '[code-ccgw] WARNING: %s\n' "$1" >&2; }

# --- Pre-launch update -----------------------------------------------------
# config.yaml is the routing map every host shares, so a backend swapped on one
# machine reaches this one only once the checkout does. This runs before every
# export below on purpose: git inherits this process's environment, and the
# gateway credential has not been copied into it yet.
#
# Absent from both the shell and .env means on -- a host that never opts in is
# the stale host this exists to prevent. Only `off` turns it off silently; any
# other spelling is named back, since the operator believes it took effect.
_ccgw_pull_enabled() {
    if [ -z "${CCGW_AUTO_PULL+x}" ]; then
        return 0
    fi
    case "$CCGW_AUTO_PULL" in
        on) return 0 ;;
        off|'') return 1 ;;
        *)
            _ccgw_warn "CCGW_AUTO_PULL='$CCGW_AUTO_PULL' is neither on nor off, so the pre-launch update stays off."
            return 1
            ;;
    esac
}

# Bounded because it sits on an interactive command's critical path: 12 seconds
# is long enough for a small fetch and short enough that an unreachable remote
# is a pause rather than a hang. Every failure returns 0 -- a pull problem must
# never cost the operator their client.
_ccgw_pull_now() {
    if ! _cp_target="$(cd "$CCGW_OPS_ROOT" && _git_publish_target)"; then
        _ccgw_warn "the pre-launch pull found nowhere to pull from; continuing with the checkout as it stands."
        return 0
    fi
    _cp_remote="$(printf '%s\n' "$_cp_target" | sed -n 's/^REMOTE=//p')"
    _cp_ref="$(printf '%s\n' "$_cp_target" | sed -n 's/^MERGE_REF=//p')"

    # Asked of the tree, not of the merge: `git merge --ff-only` succeeds over
    # staged, modified and untracked work that has nothing to do with the file
    # it rewrites, and walking over that is the worst outcome available here.
    _cp_status="$(git -C "$CCGW_OPS_ROOT" status --porcelain 2>/dev/null || true)"
    if [ -n "$_cp_status" ]; then
        _ccgw_warn "the checkout has uncommitted changes, so the pull was skipped and this host may be stale."
        return 0
    fi

    # git's own output is discarded: a remote URL can carry userinfo, and its
    # failure message is exactly where that would reach the terminal.
    if ! git -C "$CCGW_OPS_ROOT" fetch --quiet "$_cp_remote" "$_cp_ref" >/dev/null 2>&1; then
        _ccgw_warn "the pre-launch pull could not fetch from '$_cp_remote'; continuing with the checkout as it stands."
        return 0
    fi

    _cp_head="$(git -C "$CCGW_OPS_ROOT" rev-parse HEAD 2>/dev/null || true)"
    _cp_upstream="$(git -C "$CCGW_OPS_ROOT" rev-parse FETCH_HEAD 2>/dev/null || true)"
    if [ -z "$_cp_head" ] || [ -z "$_cp_upstream" ]; then
        _ccgw_warn "the pre-launch pull could not read what the remote is holding; continuing with the checkout as it stands."
        return 0
    fi
    # Already current, or merely holding commits nobody has published yet: both
    # are the ordinary shape of a working checkout, so both are silent.
    if [ "$_cp_head" = "$_cp_upstream" ]; then
        return 0
    fi
    if git -C "$CCGW_OPS_ROOT" merge-base --is-ancestor "$_cp_upstream" "$_cp_head" 2>/dev/null; then
        return 0
    fi
    if ! git -C "$CCGW_OPS_ROOT" merge-base --is-ancestor "$_cp_head" "$_cp_upstream" 2>/dev/null; then
        _ccgw_warn "the local and upstream histories have diverged, so nothing was merged; resolve it when convenient."
        return 0
    fi
    if ! git -C "$CCGW_OPS_ROOT" merge --ff-only --quiet FETCH_HEAD >/dev/null 2>&1; then
        _ccgw_warn "the pre-launch pull fetched but could not merge; continuing with the checkout as it stands."
        return 0
    fi
    printf '[code-ccgw] The checkout was brought up to date with %s.\n' "$_cp_remote" >&2
    return 0
}

# `.git` is asked for by name rather than through `rev-parse`, which walks UP:
# a copied litellm-server/ sitting inside some unrelated repository would
# otherwise fast-forward a checkout that is not the gateway's.
if _ccgw_pull_enabled; then
    if [ ! -e "$CCGW_OPS_ROOT/.git" ]; then
        _ccgw_warn "$CCGW_OPS_ROOT is not a git checkout of its own, so the pre-launch update was skipped."
    elif ! command -v git >/dev/null 2>&1; then
        _ccgw_warn "git was not found on PATH, so the pre-launch update was skipped."
    elif ! _git_run_deadline 12 _ccgw_pull_now; then
        _ccgw_warn "the pre-launch pull ran out of time; continuing with the checkout as it stands."
    fi
fi

# Clear any real Anthropic API key so the local backend is used instead. Exported
# defined-but-empty rather than unset: every consumer reads an empty value as "no key",
# and the exported empty makes the clearing visible to anything inspecting the child env.
export ANTHROPIC_API_KEY=""

# The rest of the credential/provider-switch class that must never reach the child
# `exec` replaces this shell with -- see docs/architecture.md "Child-process-only
# environment injection" for why the class is this wide and how to extend it.
for _stripped in \
    CLAUDE_CODE_OAUTH_TOKEN \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION \
    GOOGLE_APPLICATION_CREDENTIALS \
    NODE_TLS_REJECT_UNAUTHORIZED; do
    unset "$_stripped"
done
unset _stripped

# --- Base URL --------------------------------------------------------------
# The LiteLLM gateway is the only endpoint. Defined-but-empty counts as unset:
# every consumer below reads it that way, so honouring an empty value would
# only produce a request to "".
if [ -z "${LITELLM_ANTHROPIC_BASE_URL:-}" ]; then
    echo "[code-ccgw] ERROR: LITELLM_ANTHROPIC_BASE_URL is not set." >&2
    echo "[code-ccgw] Set it to the LiteLLM gateway endpoint; see docs/ops.md." >&2
    exit 1
fi
export ANTHROPIC_BASE_URL="$LITELLM_ANTHROPIC_BASE_URL"

# --- Authentication --------------------------------------------------------
# LiteLLM runs without a database, so no virtual keys exist: the client
# credential is the gateway key itself. LITELLM_VIRTUAL_KEY is accepted for one
# deprecation cycle so an unmigrated .env fails loudly rather than with a 401.
if [ -n "${LITELLM_CLIENT_KEY:-}" ]; then
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_CLIENT_KEY"
elif [ -n "${LITELLM_VIRTUAL_KEY:-}" ]; then
    echo "[code-ccgw] WARNING: LITELLM_VIRTUAL_KEY is deprecated; rename it to LITELLM_CLIENT_KEY." >&2
    export ANTHROPIC_AUTH_TOKEN="$LITELLM_VIRTUAL_KEY"
else
    echo "[code-ccgw] ERROR: LITELLM_CLIENT_KEY is not set." >&2
    echo "[code-ccgw] Set it to the LiteLLM gateway key; see docs/ops.md." >&2
    exit 1
fi

# --- TLS trust -------------------------------------------------------------
# mkcert local CA root so Node trusts the gateway certificate.
# NODE_TLS_REJECT_UNAUTHORIZED=0 is NOT used.
if [ -n "${CCGW_CA_CERT:-}" ]; then
    export NODE_EXTRA_CA_CERTS="$CCGW_CA_CERT"
elif command -v mkcert >/dev/null 2>&1; then
    # On the backend Mac the CA is already local -- derive it rather than making
    # the user restate a path the tool can answer for itself.
    _caroot="$(mkcert -CAROOT 2>/dev/null || true)"
    if [ -n "$_caroot" ] && [ -f "$_caroot/rootCA.pem" ]; then
        export NODE_EXTRA_CA_CERTS="$_caroot/rootCA.pem"
    else
        echo "[code-ccgw] WARNING: CCGW_CA_CERT not set; TLS certificate will not be trusted." >&2
    fi
else
    echo "[code-ccgw] WARNING: CCGW_CA_CERT not set; TLS certificate will not be trusted." >&2
fi

# --- Model aliases ---------------------------------------------------------
# The five keys below used to name the routing keys per host, which is how each
# machine ended up addressing whatever it was told about last. They configure
# nothing now, so a stale one is named back rather than ignored: an .env that
# reads as if it sets routing, and does not, is the same silence again.
for _ccgw_retired in \
    LITELLM_HAIKU_MODEL LITELLM_SONNET_MODEL LITELLM_FABLE_MODEL \
    LITELLM_OPUS_MODEL CCGW_SUBAGENT_MODEL; do
    if [ -n "${!_ccgw_retired:-}" ]; then
        printf '[code-ccgw] WARNING: %s no longer configures anything; the tier map moved into litellm-server/config.yaml.\n' \
            "$_ccgw_retired" >&2
    fi
done
unset _ccgw_retired

# config.yaml is the single source of truth for which tier reaches which route:
# each route's annotation names the tiers it serves, and that route's model_name
# is the key those tiers address. The launcher owns no backend names of its own,
# and there is nothing to fall back to -- a client started with no tier map at
# all hands Claude Code an empty /model list, which reads as a puzzle much later.
if [ ! -f "$CCGW_CONFIG_FILE" ] || [ ! -r "$CCGW_CONFIG_FILE" ]; then
    echo "[code-ccgw] ERROR: cannot read $CCGW_CONFIG_FILE." >&2
    echo "[code-ccgw] It is the only source of the /model tier map; see docs/ops.md." >&2
    exit 1
fi

# Line-oriented rather than YAML-aware, so that this reader, the PowerShell one
# and the Python schema check can be held to the same two spellings byte for
# byte. Any `- model_name:` line closes the block above it, well-formed or not:
# a name outside the contract must take its own annotation out of play, never
# hand it to the route before it.
_ccgw_map="$(awk '
function emit(payload, sep,   n, parts, i, tok) {
    if (sep == "P") n = split(payload, parts, ",")
    else n = split(payload, parts, /[ \t]+/)
    for (i = 1; i <= n; i++) {
        tok = parts[i]
        gsub(/^[ \t]+/, "", tok); gsub(/[ \t]+$/, "", tok)
        if (tok == "") continue
        if (tok != "haiku" && tok != "sonnet" && tok != "fable" && tok != "opus" && tok != "subagent") {
            print "warn config.yaml: \"" tok "\" is not a Claude Code tier (haiku, sonnet, fable, opus, subagent); ignored."
            continue
        }
        if (tok in owner) {
            if (owner[tok] != current)
                print "warn config.yaml: the " tok " tier is claimed by both \"" owner[tok] "\" and \"" current "\"; the first one wins."
            continue
        }
        owner[tok] = current
        print "map " tok " " current
        mapped++
    }
}
BEGIN { open = 0; startline = -1; mapped = 0 }
{
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^  - model_name:/) {
        open = 0
        rest = substr(line, 16)
        name = rest
        gsub(/^[ \t]+/, "", name); gsub(/[ \t]+$/, "", name)
        if (rest ~ /^[ ]+[^ \t]+[ ]*$/ && name ~ /^[A-Za-z0-9._-]+$/) {
            open = 1; current = name; startline = NR
        } else {
            print "warn config.yaml: model_name \"" name "\" is outside the routing-name contract, so that route claims no tier."
        }
        next
    }
    if (line != "" && line !~ /^[ \t]/) { open = 0; next }
    if (open == 0) next
    if (line ~ /^      ccgw_tiers:[ ]*\[[^]]*\][ ]*$/) {
        payload = line
        sub(/^      ccgw_tiers:[ ]*\[/, "", payload)
        sub(/\][ ]*$/, "", payload)
        emit(payload, "P")
        next
    }
    if (NR == startline + 1 && line ~ /^    # ccgw-tiers:[ ]+.+$/) {
        payload = line
        sub(/^    # ccgw-tiers:[ ]+/, "", payload)
        emit(payload, "F")
    }
}
END { if (mapped == 0) print "empty" }
' "$CCGW_CONFIG_FILE")"

_ccgw_haiku=""; _ccgw_sonnet=""; _ccgw_fable=""; _ccgw_opus=""; _ccgw_subagent=""
_ccgw_empty=0
# Read through a process substitution, never a here-document: a here-document
# re-expands what it is given, and a model_name carrying `$(...)` would run.
while IFS= read -r _ccgw_line; do
    case "$_ccgw_line" in
        'map '*)
            _ccgw_rest="${_ccgw_line#map }"
            _ccgw_name="${_ccgw_rest#* }"
            case "${_ccgw_rest%% *}" in
                haiku)    _ccgw_haiku="$_ccgw_name" ;;
                sonnet)   _ccgw_sonnet="$_ccgw_name" ;;
                fable)    _ccgw_fable="$_ccgw_name" ;;
                opus)     _ccgw_opus="$_ccgw_name" ;;
                subagent) _ccgw_subagent="$_ccgw_name" ;;
            esac
            ;;
        'warn '*) _ccgw_warn "${_ccgw_line#warn }" ;;
        empty)    _ccgw_empty=1 ;;
    esac
done < <(printf '%s\n' "$_ccgw_map")

if [ "$_ccgw_empty" -eq 1 ]; then
    echo "[code-ccgw] ERROR: no route in $CCGW_CONFIG_FILE carries a ccgw_tiers annotation." >&2
    echo "[code-ccgw] There is no /model tier map to launch with; see docs/ops.md." >&2
    exit 1
fi

# An unmapped tier means "the child must not have the variable at all", never
# "keep whatever the invoking shell carried": a leftover value would pin a tier
# config.yaml no longer names, and an empty one hands Claude Code a /model entry
# that resolves nowhere.
_ccgw_route() { # _ccgw_route <child-variable> <routing-key-or-empty>
    if [ -n "$2" ]; then
        export "$1=$2"
    else
        unset "$1"
    fi
}
_ccgw_route ANTHROPIC_DEFAULT_HAIKU_MODEL  "$_ccgw_haiku"
_ccgw_route ANTHROPIC_DEFAULT_SONNET_MODEL "$_ccgw_sonnet"
_ccgw_route ANTHROPIC_DEFAULT_FABLE_MODEL  "$_ccgw_fable"
_ccgw_route ANTHROPIC_DEFAULT_OPUS_MODEL   "$_ccgw_opus"
_ccgw_route CLAUDE_CODE_SUBAGENT_MODEL     "$_ccgw_subagent"
# The picker entry is additive: it offers the fable tier, it does not choose the startup one.
_ccgw_route ANTHROPIC_CUSTOM_MODEL_OPTION  "$_ccgw_fable"

# ANTHROPIC_MODEL is never exported: it outranks the `model` setting in the user's
# settings.json, so any value here silently discards the tier chosen there -- an opus
# session would still start on fable, with nothing in the client to say why. Cleared
# unconditionally, since an inherited value reintroduces the same override.
unset ANTHROPIC_MODEL

export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="Local model via ccgw"
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="Mac backend via the LiteLLM gateway, selected per request"

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
export CLAUDE_STREAM_IDLE_TIMEOUT_MS=600000

# Align auto-compaction with the tightest backend ceiling. A single env var cannot
# differentiate per-tier, so this is the floor over every routed tier -- measured, not
# assumed: 100k runs on the Windows sonnet/haiku backend at 1335 tok/s prefill and
# 22.7 decode, and the Mac opus tier reaches ~115k with APC on. The 75% below is what
# actually reaches a backend, so 76,800 (see code-ccgw.ps1 for the same note).
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=102400
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75

# Launch VS Code in an isolated process. A distinct --user-data-dir starts a separate
# VS Code instance; VS Code otherwise shares one process (and one environment) across
# all windows of a user-data-dir, which would leak this env into native windows.
if [ "$(uname -s)" = "Darwin" ]; then
    _user_data_dir="$HOME/Library/Application Support/vscode-ccgw"
else
    _user_data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/vscode-ccgw"
fi

if ! command -v code >/dev/null 2>&1; then
    echo "[code-ccgw] ERROR: 'code' command not found on PATH." >&2
    echo "[code-ccgw] In VS Code run: Shell Command: Install 'code' command in PATH" >&2
    exit 1
fi

exec code --user-data-dir "$_user_data_dir" "$@"
