#!/bin/sh
# set-model -- move a Claude Code tier to another backend by rewriting the one
# route in litellm-server/config.yaml that claims it, restarting the gateway,
# then publishing that file so every host follows. Rationale: docs/architecture.md.
set -eu

CCGW_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/root.sh
. "$CCGW_SCRIPT_DIR/lib/root.sh"
# shellcheck source=scripts/lib/load-dotenv.sh
. "$CCGW_SCRIPT_DIR/lib/load-dotenv.sh"
# shellcheck source=scripts/lib/paths.sh
. "$CCGW_SCRIPT_DIR/lib/paths.sh"
# shellcheck source=scripts/lib/atomic-write.sh
. "$CCGW_SCRIPT_DIR/lib/atomic-write.sh"
# shellcheck source=scripts/lib/launchd.sh
. "$CCGW_SCRIPT_DIR/lib/launchd.sh"
# shellcheck source=scripts/lib/lifecycle.sh
. "$CCGW_SCRIPT_DIR/lib/lifecycle.sh"
# shellcheck source=scripts/lib/git-remote.sh
. "$CCGW_SCRIPT_DIR/lib/git-remote.sh"
# shellcheck source=scripts/lib/litellm-config.sh
. "$CCGW_SCRIPT_DIR/lib/litellm-config.sh"

LLAMA_SWAP_CONFIG="$LLAMA_SWAP_ROOT/config.yaml"
LITELLM_CONFIG="$LITELLM_ROOT/config.yaml"
LITELLM_CONFIG_REL="litellm-server/config.yaml"
# What the gateway was last restarted with. A run that already restarted must
# not restart again when the operator reruns it to finish the commit, and a run
# whose restart failed must restart on the retry -- both states show the same
# rewritten-but-uncommitted file, so the difference is recorded here instead.
RESTART_MARKER="$CCGW_RUN_DIR/set-model-restart-state.yaml"
PUBLISH_DEADLINE_DEFAULT=60

NEWFILE=""
PUSHLOG=""
_sm_cleanup() {
    if [ -n "$NEWFILE" ]; then rm -f "$NEWFILE"; fi
    if [ -n "$PUSHLOG" ]; then rm -f "$PUSHLOG"; fi
    return 0
}
trap _sm_cleanup EXIT

_display_path() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

_say()  { echo "[set-model] $1"; }
_warn() { echo "[set-model] $1" >&2; }

_usage() {
    cat <<EOF
Usage: set-model.sh [--no-publish] <tier> <model-key>
       set-model.sh --list [tier]
       set-model.sh -h|--help

Tiers: haiku, sonnet, fable, opus

Rewrites the route that serves <tier> in $(_display_path "$LITELLM_CONFIG") so
that its model_name and its litellm_params.model both name <model-key>, keeping
the existing provider prefix. It then restarts litellm-server and publishes the
file, so the other hosts pick the switch up on their next launch.
--no-publish stops after the restart, leaving the switch on this host only.

The route is found by the tier annotation each one carries, not by its position,
and one route may serve several tiers -- switching such a route moves all of
them, which the output names before it acts.

--list with no tier shows every tier, subagent included, against the routing key
it currently reaches; --list <tier> answers for that one tier only. subagent has
no route of its own to switch, so it is reportable but not settable here.

fable/opus keys are checked against $(_display_path "$LLAMA_SWAP_CONFIG"), and a
switch whose target needs a different provider shape (ds4-server's anthropic/ vs
mlx_lm.server's openai/) is refused: provider, api_base and context_window all
differ, so that move is a manual edit. haiku/sonnet run on the Windows llama-swap
instance, which this repo's Mac-side lineup cannot enumerate, so their keys are
trusted as given.
EOF
}

_usage_error() {
    _warn "$1"
    _usage >&2
    exit 2
}

# --- Mac-side lineup ------------------------------------------------------

# Model keys from llama-swap/m5-max-128gb/config.yaml's top-level `models:`
# block (2-space-indented `key:` lines, ending at the next 0-indent line).
_mac_model_keys() {
    [ -f "$LLAMA_SWAP_CONFIG" ] || return 0
    awk '
        /^models:/ { in_block = 1; next }
        in_block && /^[A-Za-z]/ { in_block = 0 }
        in_block && /^  [A-Za-z0-9_.-]+:/ {
            key = $0
            sub(/^  /, "", key)
            sub(/:.*/, "", key)
            print key
        }
    ' "$LLAMA_SWAP_CONFIG"
}

# Provider shape a Mac model key needs, inferred from which server binary its
# llama-swap `cmd` invokes. Empty output means "couldn't tell". mlx_vlm.server
# serves the same OpenAI shape as mlx_lm.server, so the two are swappable.
_mac_model_shape() {
    [ -f "$LLAMA_SWAP_CONFIG" ] || return 0
    awk -v target="$1" '
        /^models:/ { in_block = 1; next }
        in_block && /^[A-Za-z]/ { in_block = 0 }
        in_block && /^  [A-Za-z0-9_.-]+:/ {
            key = $0
            sub(/^  /, "", key)
            sub(/:.*/, "", key)
            cur = (key == target)
        }
        cur && /mlx_(lm|vlm)\.server/ { print "openai"; exit }
        cur && /ds4-server/           { print "anthropic"; exit }
    ' "$LLAMA_SWAP_CONFIG"
}

# --- Arguments ------------------------------------------------------------

NO_PUBLISH=0
MODE=set
LIST_TIER=""
TIER=""
MODEL_KEY=""

case "${1:-}" in
    -h|--help) _usage; exit 0 ;;
    --list)
        MODE=list
        shift
        [ "$#" -le 1 ] || _usage_error "--list takes at most one tier."
        LIST_TIER="${1:-}"
        ;;
    --no-publish)
        NO_PUBLISH=1
        shift
        ;;
esac

if [ "$MODE" = set ]; then
    [ "$#" -eq 2 ] || _usage_error "expected a tier and a model-key, got $# argument(s)."
    TIER="$1"
    MODEL_KEY="$2"
    case "$TIER" in
        haiku|sonnet|fable|opus) ;;
        subagent) _usage_error "the subagent tier rides on whichever route already serves another tier, so it is not switched on its own; switch that tier instead. Settable tiers: haiku, sonnet, fable, opus." ;;
        *) _usage_error "unknown tier '$TIER'. Settable tiers: haiku, sonnet, fable, opus." ;;
    esac
    case "$MODEL_KEY" in
        ''|*[!A-Za-z0-9._-]*)
            _usage_error "model-key '$MODEL_KEY' is outside the routing-name contract (A-Za-z0-9, dot, underscore, hyphen)."
            ;;
    esac
    if [ "${#MODEL_KEY}" -gt 100 ]; then
        _usage_error "model-key is ${#MODEL_KEY} characters long; a routing name that size is a mistake, not a model."
    fi
elif [ -n "$LIST_TIER" ]; then
    case "$LIST_TIER" in
        haiku|sonnet|fable|opus|subagent) ;;
        *) _usage_error "unknown tier '$LIST_TIER'. Tiers: haiku, sonnet, fable, opus, subagent." ;;
    esac
fi

# --- The routing table ----------------------------------------------------

if [ ! -e "$LITELLM_CONFIG" ]; then
    _warn "$LITELLM_CONFIG is not there, so there is no routing table to read."
    exit 2
fi
if [ ! -r "$LITELLM_CONFIG" ] || [ ! -f "$LITELLM_CONFIG" ]; then
    _warn "$LITELLM_CONFIG cannot be read."
    exit 2
fi
if [ ! -s "$LITELLM_CONFIG" ]; then
    _warn "$LITELLM_CONFIG is empty; a routing table with no routes is not something to guess at."
    exit 2
fi

CFG_ERRORS=""
CFG_NAMES=""
CFG_MODELS=""
MAP_HAIKU=""
MAP_SONNET=""
MAP_FABLE=""
MAP_OPUS=""
MAP_SUBAGENT=""

CFG_READ="$(_llc_read "$LITELLM_CONFIG")"
while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _kind="${_line%%|*}"
    _rest="${_line#*|}"
    case "$_kind" in
        err)  CFG_ERRORS="$CFG_ERRORS$_rest
" ;;
        name) CFG_NAMES="$CFG_NAMES $_rest" ;;
        model) CFG_MODELS="$CFG_MODELS$_rest
" ;;
        map)
            _tier="${_rest%%|*}"
            _route="${_rest#*|}"
            case "$_tier" in
                haiku)    MAP_HAIKU="$_route" ;;
                sonnet)   MAP_SONNET="$_route" ;;
                fable)    MAP_FABLE="$_route" ;;
                opus)     MAP_OPUS="$_route" ;;
                subagent) MAP_SUBAGENT="$_route" ;;
            esac
            ;;
    esac
done <<EOF
$CFG_READ
EOF

if [ -n "$CFG_ERRORS" ]; then
    _warn "$LITELLM_CONFIG does not hold a routing table this can act on:"
    printf '%s' "$CFG_ERRORS" | while IFS= read -r _e; do
        [ -n "$_e" ] || continue
        echo "  $_e" >&2
    done
    exit 2
fi

_route_for_tier() {
    case "$1" in
        haiku)    printf '%s' "$MAP_HAIKU" ;;
        sonnet)   printf '%s' "$MAP_SONNET" ;;
        fable)    printf '%s' "$MAP_FABLE" ;;
        opus)     printf '%s' "$MAP_OPUS" ;;
        subagent) printf '%s' "$MAP_SUBAGENT" ;;
    esac
}

# Every tier the given route serves, so an operator switching one is told which
# others move with it before the file is written.
_tiers_on_route() {
    _tor=""
    if [ -n "$1" ] && [ "$MAP_HAIKU" = "$1" ];    then _tor="${_tor}haiku, "; fi
    if [ -n "$1" ] && [ "$MAP_SONNET" = "$1" ];   then _tor="${_tor}sonnet, "; fi
    if [ -n "$1" ] && [ "$MAP_FABLE" = "$1" ];    then _tor="${_tor}fable, "; fi
    if [ -n "$1" ] && [ "$MAP_OPUS" = "$1" ];     then _tor="${_tor}opus, "; fi
    if [ -n "$1" ] && [ "$MAP_SUBAGENT" = "$1" ]; then _tor="${_tor}subagent, "; fi
    printf '%s' "${_tor%, }"
}

_model_of_route() {
    _mor=""
    while IFS= read -r _m; do
        [ -n "$_m" ] || continue
        if [ "${_m%%|*}" = "$1" ]; then _mor="${_m#*|}"; fi
    done <<EOF
$CFG_MODELS
EOF
    printf '%s' "$_mor"
}

if [ "$MODE" = list ]; then
    for _t in haiku sonnet fable opus subagent; do
        if [ -n "$LIST_TIER" ] && [ "$_t" != "$LIST_TIER" ]; then continue; fi
        _r="$(_route_for_tier "$_t")"
        if [ -n "$_r" ]; then
            printf '%-9s %s\n' "$_t" "$_r"
        else
            printf '%-9s (unclaimed -- no route is annotated for it)\n' "$_t"
        fi
    done
    exit 0
fi

# --- The route this switch moves ------------------------------------------

ROUTE="$(_route_for_tier "$TIER")"
if [ -z "$ROUTE" ]; then
    _warn "no route in $LITELLM_CONFIG claims the $TIER tier, so there is nothing to switch."
    exit 2
fi

CURRENT_MODEL="$(_model_of_route "$ROUTE")"
if [ -z "$CURRENT_MODEL" ]; then
    _warn "the $TIER route '$ROUTE' in $LITELLM_CONFIG has no litellm_params.model line to move."
    exit 2
fi
PROVIDER="${CURRENT_MODEL%%/*}"
if [ "$PROVIDER" = "$CURRENT_MODEL" ] || [ -z "$PROVIDER" ]; then
    _warn "the $TIER route's backend '$CURRENT_MODEL' in $LITELLM_CONFIG carries no provider prefix, so a switch cannot keep one."
    exit 2
fi

for _n in $CFG_NAMES; do
    if [ "$_n" = "$MODEL_KEY" ] && [ "$_n" != "$ROUTE" ]; then
        _warn "'$MODEL_KEY' is already the routing name of the route serving $(_tiers_on_route "$_n"), and two routes answering to one name make the choice of backend arbitrary."
        exit 2
    fi
done

# The lineup this repo can enumerate is the Mac one. haiku and sonnet are served
# by the Windows llama-swap instance, so their keys are named exceptions to the
# check rather than an unverified default for every tier.
case "$TIER" in
    fable|opus)
        if [ ! -f "$LLAMA_SWAP_CONFIG" ]; then
            _warn "the llama-swap lineup $LLAMA_SWAP_CONFIG is not there, so '$MODEL_KEY' cannot be checked against the models this Mac can actually start."
            exit 2
        fi
        if ! _mac_model_keys | grep -qxF -- "$MODEL_KEY"; then
            _warn "unknown model-key for $TIER: $MODEL_KEY"
            _warn "choices:"
            _mac_model_keys | sed 's/^/  /' >&2
            exit 2
        fi
        TARGET_SHAPE="$(_mac_model_shape "$MODEL_KEY")"
        if [ -n "$TARGET_SHAPE" ] && [ "$TARGET_SHAPE" != "$PROVIDER" ]; then
            _warn "$MODEL_KEY needs provider '$TARGET_SHAPE/' but the $TIER route is wired as '$PROVIDER/' -- provider, api_base and context_window all differ between those two shapes."
            _warn "not supported by this script; edit $(_display_path "$LITELLM_CONFIG") by hand."
            exit 2
        fi
        ;;
    haiku|sonnet)
        _warn "note: $TIER runs on the Windows llama-swap instance, whose lineup this repo's Mac-side config cannot enumerate -- trusting '$MODEL_KEY' as given."
        ;;
esac

# --- Rewrite --------------------------------------------------------------

NEWFILE="$(mktemp "${TMPDIR:-/tmp}/ccgw-set-model.XXXXXX")"
_llc_rewrite "$LITELLM_CONFIG" "$ROUTE" "$MODEL_KEY" "$PROVIDER" > "$NEWFILE"

_sm_in_repo() { git -C "$CCGW_OPS_ROOT" rev-parse --git-dir >/dev/null 2>&1; }
_sm_config_dirty() {
    if ! _sm_in_repo; then return 1; fi
    [ -n "$(git -C "$CCGW_OPS_ROOT" status --porcelain -- "$LITELLM_CONFIG_REL" 2>/dev/null)" ]
}

# A file already differing from HEAD is either this command's own unfinished
# work -- byte-for-byte what it would write -- or somebody's edit that a commit
# here would sweep up unannounced. Only the first may be resumed.
if _sm_config_dirty && ! cmp -s "$LITELLM_CONFIG" "$NEWFILE"; then
    _warn "$LITELLM_CONFIG carries uncommitted changes that are not this switch, and publishing would commit them too; commit or stash them first."
    exit 2
fi

if ! cmp -s "$LITELLM_CONFIG" "$NEWFILE"; then
    if ! _sm_tmp="$(_ccgw_begin_write "$LITELLM_CONFIG")"; then
        _warn "$LITELLM_CONFIG could not be opened for replacement, so nothing was changed."
        exit 1
    fi
    cat "$NEWFILE" > "$_sm_tmp"
    _ccgw_commit_write "$_sm_tmp" "$LITELLM_CONFIG"
fi
MOVED="$(_tiers_on_route "$ROUTE")"
_say "$TIER route '$ROUTE' -> '$MODEL_KEY' ($CURRENT_MODEL -> $PROVIDER/$MODEL_KEY)"
_say "tiers moving with it: $MOVED"

# --- Restart --------------------------------------------------------------

if [ -f "$RESTART_MARKER" ] && cmp -s "$LITELLM_CONFIG" "$RESTART_MARKER"; then
    _say "the gateway is already serving this file; not restarting it again."
else
    if _ds4_launchd_active litellm; then
        ds4_uninstall litellm
        ds4_install litellm
    elif ! "$CCGW_SCRIPT_DIR/serverctl.sh" restart litellm; then
        _warn "litellm-server did not restart, so the file says '$MODEL_KEY' and the gateway still serves the old key; nothing was committed or published."
        exit 1
    fi
    if mkdir -p "$CCGW_RUN_DIR" 2>/dev/null; then
        cp "$LITELLM_CONFIG" "$RESTART_MARKER" 2>/dev/null || true
    fi
    _say "$TIER now routes to $MODEL_KEY"
fi

if [ "$NO_PUBLISH" -eq 1 ]; then
    _say "--no-publish: the switch stays on this host, uncommitted and unpublished."
    exit 0
fi

# --- Commit ---------------------------------------------------------------

if ! _sm_in_repo; then
    _warn "$CCGW_OPS_ROOT is not a git checkout, so the switch cannot be published; it is live on this host only."
    exit 3
fi

if _sm_config_dirty; then
    if ! git -C "$CCGW_OPS_ROOT" commit --quiet \
            -m "chore(litellm): route $TIER to $MODEL_KEY" \
            -- "$LITELLM_CONFIG_REL"; then
        _warn "the switch could not be committed, so it is live on this host only and nothing was published."
        exit 3
    fi
    _say "committed $LITELLM_CONFIG_REL"
fi

# --- Publish --------------------------------------------------------------

if ! PUBLISH_TARGET="$(cd "$CCGW_OPS_ROOT" && _git_publish_target)"; then
    _warn "the switch is committed here but there is nowhere to publish it to, so the other hosts will not see it."
    exit 3
fi
REMOTE="$(printf '%s\n' "$PUBLISH_TARGET" | sed -n 's/^REMOTE=//p')"
MERGE_REF="$(printf '%s\n' "$PUBLISH_TARGET" | sed -n 's/^MERGE_REF=//p')"

DEADLINE="$PUBLISH_DEADLINE_DEFAULT"
if [ -n "${CCGW_PUBLISH_DEADLINE+x}" ]; then
    _sm_deadline_ok=1
    case "$CCGW_PUBLISH_DEADLINE" in
        ''|*[!0-9]*) _sm_deadline_ok=0 ;;
        *[!0]*) ;;
        *) _sm_deadline_ok=0 ;;
    esac
    if [ "$_sm_deadline_ok" -eq 1 ]; then
        DEADLINE="$CCGW_PUBLISH_DEADLINE"
    else
        _warn "CCGW_PUBLISH_DEADLINE='$CCGW_PUBLISH_DEADLINE' is not a positive whole number of seconds; using the default of ${PUBLISH_DEADLINE_DEFAULT}s."
    fi
fi

# git's own explanation of a refusal is what tells the operator whether to pull
# or to look at the server, so it is passed through -- with any userinfo in a
# remote URL removed, since a push that fails prints the URL it tried.
_sm_show_push_log() {
    sed -e 's|://[^/@[:space:]]*@|://<redacted>@|g' "$PUSHLOG" >&2
}

_say "publishing: git push $REMOTE HEAD:$MERGE_REF"
PUSHLOG="$(mktemp "${TMPDIR:-/tmp}/ccgw-set-model-push.XXXXXX")"
if _git_run_deadline "$DEADLINE" git -C "$CCGW_OPS_ROOT" push "$REMOTE" "HEAD:$MERGE_REF" \
        >"$PUSHLOG" 2>&1; then
    _sm_show_push_log
    _say "published to $REMOTE $MERGE_REF"
else
    _sm_show_push_log
    _warn "the push to $REMOTE did not complete within ${DEADLINE}s or was refused, so the switch is live and committed here but not published; the commit is waiting locally."
    exit 3
fi
