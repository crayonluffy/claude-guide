#!/usr/bin/env bash
# Deterministic public-command races. All transports/apps and state are private.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
profile="$repo/scripts/claude-proxy.sh"
test_file="$repo/tests/proxy-switch-race.sh"
worker_shell=${PROXY_OPERATION_SHELL:-bash}
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
await_file() { local n=0; while [ ! -e "$1" ] && [ "$n" -lt 800 ]; do sleep .025; n=$((n+1)); done; assert test -e "$1"; }
use_scratch() {
    scratch=$1
    export AUDIT_SCRATCH="$scratch" HOME="$scratch/home" XDG_STATE_HOME="$scratch/state"
    export CLAUDE_PROXY_CONF="$scratch/conf" CLAUDE_PROXY_NODES="$scratch/nodes.json" CLAUDE_SETTINGS="$scratch/settings.json"
    export CLAUDE_PROXY_LOCAL_NODES="$scratch/local-nodes" CLAUDE_TUNNEL_LOG="$scratch/transport.log"
    export PATH="$scratch/bin:$PATH"
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
}
audit_load() {
    . "$profile" >/dev/null 2>&1
    _node_ensure_alias() { :; }
    _listeners() { :; }; _port_bound() { return 1; }; _legacy_watchdog_pid() { return 1; }
    _recovery_probe() { echo 'healthy|0|200|404|healthy'; }
    _proxy_probe() { echo 'ok 0 200 404'; }
    _recovery_desktop_backend() { echo off; }
    ssh() { echo 'FAIL: remote SSH attempted' >&2; return 99; }
    _port_in_use() {
        local slot d
        for slot in main node-jp node-sg node-us; do
            d="$XDG_STATE_HOME/claude-proxy/recovery/$slot"
            if _recovery_owner_pid "$d" >/dev/null; then
                if [ "$1" = "$(_recovery_record_get "$d" http)" ] || [ "$1" = "$(_recovery_record_get "$d" socks)" ]; then return 0; fi
            fi
        done
        return 1
    }
    _tunnel_health() {
        local d="$XDG_STATE_HOME/claude-proxy/recovery/main" p
        if p=$(_recovery_owner_pid "$d"); then echo "ok $p ssh $CLAUDE_HTTP_PORT"; else echo down; fi
    }
    _recovery_worker() {
        local dir="$1" me
        me=$(exec sh -c 'echo $PPID')
        _recovery_claim "$dir" "$me" || return 0
        echo "$me" >> "$scratch/worker.pids"
        _recovery_record_write "$dir"
        trap '_recovery_release "$dir" "$me"; exit 0' TERM INT
        while [ ! -e "$dir/stopped" ]; do sleep .025; done
        _recovery_release "$dir" "$me"
    }
    _conf_reload() { audit_load; }
    _platform_chrome_launch() { printf '%s|%s\n' "$1" "$2" >> "$scratch/chrome.flags"; }
}
# Instrument only failed real claims, so a barrier proves actual contention.
claim_barrier() {
    eval "$(sed -n '/^_recovery_claim() {/,/^}/p' "$profile" | sed '1s/_recovery_claim/_audit_real_claim/')"
    _recovery_claim() {
        if _audit_real_claim "$@"; then return 0; fi
        if [ "$1" = "$(_proxy_operation_dir)" ]; then touch "$scratch/$AUDIT_ROLE.blocked"; fi
        return 1
    }
}
initialize() {
    mkdir -p "$scratch/home" "$scratch/bin"
    cat > "$CLAUDE_PROXY_CONF" <<'CONF'
CLAUDE_SSH_HOST=jpvpn
CLAUDE_PROXY_BANNER=0
CLAUDE_PROXY_MODE=managed
CLAUDE_KILLSWITCH=off
CLAUDE_SYNC_SETTINGS=0
CLAUDE_REMOTE_PROXY_PORT=8888
CONF
    cat > "$CLAUDE_PROXY_NODES" <<'NODES'
{"nodes":[{"name":"jp","alias":"jpvpn","host":"jp.example","slot":0,"proxy_port":8888},{"name":"sg","alias":"sgvpn","host":"sg.example","slot":1,"proxy_port":8899},{"name":"us","alias":"usvpn","host":"us.example","slot":2,"proxy_port":8888}]}
NODES
    cat > "$scratch/bin/claude" <<'APP'
#!/bin/sh
if [ "${1:-}" = --help ]; then echo usage; exit 0; fi
root="$AUDIT_SCRATCH/state/claude-proxy/recovery/main"
printf '%s|%s|%s\n' "$HTTPS_PROXY" "$(sed -n 's/^host=//p' "$root/tunnel.rec")" "$(ls "$root/sessions" 2>/dev/null | wc -l | tr -d ' ')" > "$AUDIT_SCRATCH/app.record"
if [ "${AUDIT_CASE:-}" = register ]; then
    touch "$AUDIT_SCRATCH/app.entered"
    n=0; while [ ! -e "$AUDIT_SCRATCH/app.release" ] && [ "$n" -lt 800 ]; do sleep .025; n=$((n+1)); done
    test -e "$AUDIT_SCRATCH/app.release"
fi
APP
    chmod +x "$scratch/bin/claude"
    cp "$scratch/bin/claude" "$scratch/bin/codex"
    audit_load
    tunnel-start >/dev/null
}
if [ "${1:-}" = child ]; then
    use_scratch "$2"; mode=$3; export AUDIT_ROLE="$mode"
    case "$mode" in
        switch)
            audit_load
            eval "$(sed -n '/^_conf_set() {/,/^}/p' "$profile" | sed '1s/_conf_set/_audit_conf_set/')"
            _conf_set() { _audit_conf_set "$@"; if [ "$1" = CLAUDE_REMOTE_PROXY_PORT ]; then touch "$scratch/conf.ready"; await_file "$scratch/tab.loaded"; fi; }
            eval "$(declare -f tunnel-stop | sed '1s/tunnel-stop/_audit_tunnel_stop/')"
            tunnel-stop() { _audit_tunnel_stop "$@"; touch "$scratch/main.stopped"; await_file "$scratch/newtab.blocked"; }
            proxy-node sg --force
            printf '%s|%s\n' "$CLAUDE_SSH_HOST" "$CLAUDE_HTTP_PORT" > "$scratch/switch.record"
            ;;
        newtab)
            await_file "$scratch/conf.ready"
            audit_load
            echo "$CLAUDE_SSH_HOST" > "$scratch/tab.adopted"
            touch "$scratch/tab.loaded"
            await_file "$scratch/main.stopped"
            claim_barrier
            cc --no-verify >/dev/null
            ;;
        register)
            audit_load; export AUDIT_CASE=register
            eval "$(sed -n '/^_recovery_subscribe() {/,/^}/p' "$profile" | sed '1s/_recovery_subscribe/_audit_subscribe/')"
            _recovery_subscribe() { touch "$scratch/register.entered"; await_file "$scratch/refuse.blocked"; _audit_subscribe "$@"; }
            cx --no-verify >/dev/null
            ;;
        refuse)
            await_file "$scratch/register.entered"
            audit_load; claim_barrier
            if proxy-node sg > "$scratch/refuse.message"; then echo accepted > "$scratch/refuse.result"; else echo refused > "$scratch/refuse.result"; fi
            ;;
    esac
    exit
fi
scratch_base=$(mktemp -d)
cleanup() {
    local d p
    for d in startup registration named; do
        if [ -r "$scratch_base/$d/worker.pids" ]; then while read -r p; do kill "$p" 2>/dev/null || :; done < "$scratch_base/$d/worker.pids"; fi
    done
    for p in $(echo "${test_children:-}"); do kill "$p" 2>/dev/null || :; done
    rm -rf "$scratch_base"
}
trap cleanup EXIT
test_children=''
use_scratch "$scratch_base/startup"; initialize
"$worker_shell" -f "$test_file" child "$scratch" newtab > "$scratch/newtab.out" 2>&1 & tab=$!; test_children="$test_children $tab"
"$worker_shell" -f "$test_file" child "$scratch" switch > "$scratch/switch.out" 2>&1 & switcher=$!; test_children="$test_children $switcher"
if ! wait "$switcher"; then cat "$scratch/switch.out" >&2; exit 1; fi
if ! wait "$tab"; then cat "$scratch/newtab.out" >&2; exit 1; fi
assert test "$(cat "$scratch/tab.adopted")" = jpvpn
assert test "$(cat "$scratch/switch.record")" = 'sgvpn|8080'
assert test "$(cat "$scratch/app.record")" = 'http://127.0.0.1:8080|sgvpn|1'
assert grep -q 'CLAUDE_SSH_HOST="sgvpn"' "$CLAUDE_PROXY_CONF"
assert grep -qx host=sgvpn "$XDG_STATE_HOME/claude-proxy/recovery/main/tunnel.rec"
echo 'PASS: new-tab startup waits for the switch and launches on the saved target at HTTP 8080'
use_scratch "$scratch_base/registration"; initialize
"$worker_shell" -f "$test_file" child "$scratch" register > "$scratch/register.out" 2>&1 & launcher=$!; test_children="$test_children $launcher"
"$worker_shell" -f "$test_file" child "$scratch" refuse > "$scratch/refuse.out" 2>&1 & refuser=$!; test_children="$test_children $refuser"
if ! wait "$refuser"; then cat "$scratch/refuse.out" >&2; exit 1; fi
await_file "$scratch/app.entered"
assert test "$(cat "$scratch/refuse.result")" = refused
assert grep -q '1 session' "$scratch/refuse.message"
assert grep -qx host=jpvpn "$XDG_STATE_HOME/claude-proxy/recovery/main/tunnel.rec"
assert grep -qx CLAUDE_SSH_HOST=jpvpn "$CLAUDE_PROXY_CONF"
assert test "$(cat "$scratch/app.record")" = 'http://127.0.0.1:8080|jpvpn|1'
touch "$scratch/app.release"
if ! wait "$launcher"; then cat "$scratch/register.out" >&2; exit 1; fi
echo 'PASS: switch waits for session registration, then refuses an unforced move while the app runs'
use_scratch "$scratch_base/named"; initialize
chrome-proxy jp >/dev/null; chrome-proxy sg >/dev/null; chrome-proxy us >/dev/null
cc --node jp --no-verify >/dev/null 2>&1
assert test "$(cut -d '|' -f 1 "$scratch/app.record")" = http://127.0.0.1:8180
proxy-node sg --force > "$scratch/named-switch.message" 2>&1
chrome-proxy jp >/dev/null; chrome-proxy sg >/dev/null; chrome-proxy us >/dev/null
cc --node sg --no-verify >/dev/null 2>&1
assert test "$(cut -d '|' -f 1 "$scratch/app.record")" = http://127.0.0.1:8181
assert test "$(cat "$scratch/chrome.flags" | tr '\n' ' ')" = 'jp|socks5://127.0.0.1:1180 sg|socks5://127.0.0.1:1181 us|socks5://127.0.0.1:1182 jp|socks5://127.0.0.1:1180 sg|socks5://127.0.0.1:1181 us|socks5://127.0.0.1:1182 '
assert grep -qx http=8080 "$XDG_STATE_HOME/claude-proxy/recovery/main/tunnel.rec"
assert grep -qx host=sgvpn "$XDG_STATE_HOME/claude-proxy/recovery/main/tunnel.rec"
echo 'PASS: named Chrome and CLI endpoints remain fixed across a default switch'
# With no tracked CLI session, unknown consumers can still use main (plain CLI,
# extensions, other accounts). Moving that endpoint requires a warning or refusal.
if proxy-node jp > "$scratch/untracked.message" 2>&1; then
    assert grep -Eiq '^\[(warn|warning)\].*(client|chrome|browser|extension|plain|account|endpoint)' "$scratch/untracked.message"
else
    assert grep -qx host=sgvpn "$XDG_STATE_HOME/claude-proxy/recovery/main/tunnel.rec"
fi
echo 'PASS: an unforced main-endpoint move warns about untracked clients or refuses'
