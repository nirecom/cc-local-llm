#!/bin/sh
# Shared git primitives for the two commands that talk to the ops repository's
# remote: scripts/set-model.sh publishes the routing table it rewrote, and
# scripts/code-ccgw.sh pulls it before launching. Resolved here once so the
# publisher and the puller can never disagree about where "publish" goes.
# Sourced, never executed. Tests: tests/feature-18-serverctl/test-git-remote-lib.sh

# Print `REMOTE=<name>` and `MERGE_REF=<refs/heads/...>` for the branch checked
# out in the current directory, or refuse with the reason on stderr.
_git_publish_target() {
    _gr_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ -z "$_gr_branch" ]; then
        echo "[git-remote] HEAD is detached, so there is no branch to publish." >&2
        return 1
    fi

    # Read from the config fields rather than splitting `rev-parse --abbrev-ref
    # @{u}`: a remote whose name contains a slash renders as `up/stream/main`,
    # which cannot be decoded back into its two halves.
    _gr_remote="$(git config --get "branch.$_gr_branch.remote" 2>/dev/null || true)"
    _gr_merge="$(git config --get "branch.$_gr_branch.merge" 2>/dev/null || true)"
    if [ -z "$_gr_remote" ] || [ -z "$_gr_merge" ]; then
        echo "[git-remote] branch '$_gr_branch' has no upstream; nothing is tracking a remote." >&2
        return 1
    fi

    # Both fields are plain text in .git/config, which people edit and merges
    # rewrite, so each is validated before it reaches `git push`.
    # `branch.<b>.remote = .` is legal git and means "track a local branch".
    if [ "$_gr_remote" = "." ]; then
        echo "[git-remote] branch '$_gr_branch' tracks a local branch, so there is no publish remote." >&2
        return 1
    fi
    case "$_gr_remote" in
        -*|*[!A-Za-z0-9._/-]*)
            echo "[git-remote] upstream remote name '$_gr_remote' is not a usable remote name." >&2
            return 1
            ;;
    esac
    _gr_known=0
    for _gr_candidate in $(git remote 2>/dev/null || true); do
        if [ "$_gr_candidate" = "$_gr_remote" ]; then
            _gr_known=1
        fi
    done
    if [ "$_gr_known" -ne 1 ]; then
        echo "[git-remote] no remote named '$_gr_remote' is configured, so there is no publish remote." >&2
        return 1
    fi

    # Only a branch is a publish target: `HEAD:refs/tags/v1` makes a tag out of a
    # commit and `HEAD:refs/remotes/...` writes a tracking ref nobody fetches --
    # both read to the operator as a successful publish.
    case "$_gr_merge" in
        refs/heads/?*) ;;
        *)
            echo "[git-remote] upstream ref '$_gr_merge' is not a branch under refs/heads/." >&2
            return 1
            ;;
    esac
    case "$_gr_merge" in
        *..*|*[!A-Za-z0-9._/-]*)
            echo "[git-remote] upstream ref '$_gr_merge' is not a well-formed branch ref." >&2
            return 1
            ;;
    esac
    if ! git check-ref-format "$_gr_merge" >/dev/null 2>&1; then
        echo "[git-remote] upstream ref '$_gr_merge' is not a well-formed branch ref." >&2
        return 1
    fi

    printf 'REMOTE=%s\n' "$_gr_remote"
    printf 'MERGE_REF=%s\n' "$_gr_merge"
    return 0
}

# Process ids sharing the given process-group id. `kill -TERM -<pgid>` is the
# one-call form, but a group whose leader has already been reaped is gone on
# some shells while its members are still running -- exactly the case a command
# that exits at once and leaves a helper behind produces.
_gr_group_members() {
    if ps -A -o pgid=,pid= >/dev/null 2>&1; then
        ps -A -o pgid=,pid= 2>/dev/null | awk -v g="$1" '$1 == g { print $2 }'
    else
        ps 2>/dev/null | awk -v g="$1" 'NR > 1 && $3 == g { print $1 }'
    fi
}

# Signal a whole process group, by the group and then member by member.
_gr_kill_tree() {
    kill "-$2" "-$1" 2>/dev/null || true
    for _gr_kt_member in $(_gr_group_members "$1"); do
        if [ "$_gr_kt_member" != "$$" ]; then
            kill "-$2" "$_gr_kt_member" 2>/dev/null || true
        fi
    done
}

# `_git_run_deadline <seconds> <cmd> [args...]` -- returns the command's own
# status when it finishes in time (the caller must be able to tell "the push was
# rejected" from "the push timed out"), non-zero once the deadline fires. The
# whole process TREE goes with it: a real `git fetch` spawns ssh or a credential
# helper, and killing only git leaves those holding the terminal. The command's
# stdout and stderr are inherited, never piped -- reading one to EOF would block
# for a descendant's full lifetime after the command itself had exited.
_git_run_deadline() {
    _gr_dl_secs="${1:-}"
    # timeout(1) reads `0` as "no limit at all", and `$(( ))` turns `abc` and the
    # empty string into 0 -- three spellings of the unbounded wait this primitive
    # exists to prevent. The caller passes a literal, so a bad value is a defect
    # in the caller: refuse before the command starts.
    case "$_gr_dl_secs" in
        ''|*[!0-9]*)
            echo "[git-remote] deadline '$_gr_dl_secs' is not a whole number of seconds; refusing to run the command unbounded." >&2
            return 2
            ;;
        *[!0]*) ;;
        *)
            echo "[git-remote] deadline '$_gr_dl_secs' is zero seconds, which is no limit at all; refusing to run the command unbounded." >&2
            return 2
            ;;
    esac
    shift
    if [ "$#" -eq 0 ]; then
        echo "[git-remote] no command was given to run under a deadline." >&2
        return 2
    fi

    # Job control puts the background job in a process group of its own, which is
    # what makes the tree -- not just the command -- reachable by one kill.
    set -m 2>/dev/null || true
    "$@" &
    _gr_dl_pid=$!
    set +m 2>/dev/null || true

    (
        _gr_dl_waited=0
        while [ "$_gr_dl_waited" -lt "$_gr_dl_secs" ]; do
            sleep 1
            _gr_dl_waited=$(( _gr_dl_waited + 1 ))
        done
        _gr_kill_tree "$_gr_dl_pid" TERM
        kill -TERM "$_gr_dl_pid" 2>/dev/null || true
        sleep 2
        _gr_kill_tree "$_gr_dl_pid" KILL
        kill -KILL "$_gr_dl_pid" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    _gr_dl_watchdog=$!

    _gr_dl_rc=0
    wait "$_gr_dl_pid" || _gr_dl_rc=$?

    kill -TERM "$_gr_dl_watchdog" 2>/dev/null || true
    wait "$_gr_dl_watchdog" 2>/dev/null || true
    # Even a command that exited cleanly may have left the helper it spawned
    # behind, still holding the pipes it inherited.
    _gr_kill_tree "$_gr_dl_pid" TERM

    return "$_gr_dl_rc"
}
