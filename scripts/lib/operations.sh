# Shared mutation lease. Included after the recovery helpers by the profile builder.
# Keep it outside recovery/: a coordinator is not a tunnel owner.
_proxy_operation_dir() {
    local root
    root=$(_recovery_root) || return 1
    printf '%s/operations\n' "${root%/*}"
}
_proxy_operation_owned() {
    local dir token owner expected stamp nonce
    [ -n "${_CLAUDE_OPERATION_TOKEN:-}" ] || return 1
    dir=$(_proxy_operation_dir) || return 1
    owner=$(_recovery_owner_pid "$dir") || return 1
    token=$(cat "$dir/token" 2>/dev/null) || return 1
    [ "$token" = "$_CLAUDE_OPERATION_TOKEN" ] || return 1
    IFS='|' read -r expected stamp nonce <<< "$token"
    [ "$owner" = "$expected" ] && [ "$(_recovery_process_identity "$owner")" = "$stamp" ]
}
_proxy_operation_claim_wait() {
    local dir="$1" me="$2" i=0
    while ! _recovery_claim "$dir" "$me"; do
        if [ "$i" -ge 300 ]; then
            echo '[Err] Another terminal is still changing proxy settings or tunnels. Operation timed out after 30 seconds; retry when it finishes.' >&2
            return 1
        fi
        sleep .1; i=$((i+1))
    done
}
_proxy_operation_release() {
    local token="${1-${_CLAUDE_OPERATION_TOKEN:-}}" dir owner current expected stamp nonce gate me rc=0
    [ -n "$token" ] || return 0
    dir=$(_proxy_operation_dir) || return 1
    current=$(cat "$dir/token" 2>/dev/null) || return 0
    [ "$current" = "$token" ] || return 0
    owner=$(_recovery_owner_pid "$dir") || return 0
    # Two inherited callbacks may release together. Serialize their validation
    # and removal with the same crash-recoverable lease primitive as the owner.
    # Recheck after acquiring: the earlier read may name a previous generation.
    gate="$dir/release"
    me=$(exec sh -c 'echo $PPID')
    _proxy_operation_claim_wait "$gate" "$me" || return 1
    current=$(cat "$dir/token" 2>/dev/null) || current=''
    owner=$(_recovery_owner_pid "$dir") || owner=''
    IFS='|' read -r expected stamp nonce <<< "$token"
    if [ "$current" = "$token" ] && [ "$owner" = "$expected" ] && [ "$(_recovery_process_identity "$owner")" = "$stamp" ]; then
        # Remove the generation before dropping the lease, never after: a new
        # operation may publish its own token as soon as the owner is released.
        rm -f "$dir/token"
        _recovery_release "$dir" "$owner" || rc=1
    fi
    _recovery_release "$gate" "$me" || rc=1
    if [ "${_CLAUDE_OPERATION_TOKEN:-}" = "$token" ]; then _CLAUDE_OPERATION_TOKEN=''; fi
    return "$rc"
}
_proxy_operation_run() {
    if _proxy_operation_owned; then "$@"; return $?; fi
    local dir me candidate acquired rc stamp
    local _CLAUDE_OPERATION_TOKEN="${_CLAUDE_OPERATION_TOKEN:-}"
    dir=$(_proxy_operation_dir) || return 1
    (umask 077; mkdir -p "$dir") || return 1
    chmod 700 "$dir" || return 1
    # Unlike $$, this is the executing shell even inside $(...) or a subshell.
    me=$(exec sh -c 'echo $PPID')
    _proxy_operation_claim_wait "$dir" "$me" || return 1
    candidate=$(umask 077; mktemp "$dir/token.XXXXXX") || { _recovery_release "$dir" "$me"; return 1; }
    stamp=$(_recovery_process_identity "$me") || { rm -f "$candidate"; _recovery_release "$dir" "$me"; return 1; }
    acquired="$me|$stamp|${candidate##*/}"
    rm -f "$candidate"
    if ! _recovery_write "$dir/token" "$acquired" "$me"; then
        _recovery_release "$dir" "$me"; return 1
    fi
    _CLAUDE_OPERATION_TOKEN=$acquired
    # Do not install traps: callers retain their INT/TERM/EXIT handlers. A dead
    # shell's lease is recovered by the existing identity-checked claim helper.
    if "$@"; then rc=0; else rc=$?; fi
    # The command can release early (before running an interactive CLI). Its
    # original generation must never release a newer operation at final cleanup.
    _proxy_operation_release "$acquired" || :
    return "$rc"
}
