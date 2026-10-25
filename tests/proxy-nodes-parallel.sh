#!/usr/bin/env bash
# Parallel node tunnels (2.10): every node has its own slot, fixed ports and
# owner; the default node keeps slot 'main' on the main ports.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}"
fn() { local f; for f in "$@"; do eval "$(sed -n "/^$f() {/,/^}/p" "$src")"; done; }
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fn _nodes_tsv _node_lookup _node_provisioned _node_slot _node_ctx
cat > "$scratch/nodes.json" <<'EOF'
{ "nodes": [
{ "name": "jp", "alias": "jpvpn", "host": "jp.example.com", "user": "", "ssh_port": 22, "proxy_port": 8888, "region": "Japan", "note": "", "hostkey": "", "slot": 0 },
{ "name": "sg", "alias": "sgvpn", "host": "sg.example.com", "user": "", "ssh_port": 2222, "proxy_port": 8899, "region": "Singapore", "note": "", "hostkey": "", "slot": 1 },
{ "name": "us", "alias": "usvpn", "host": "<not provisioned>", "user": "", "ssh_port": 22, "proxy_port": 8888, "region": "US", "note": "", "hostkey": "", "slot": 2 }
] }
EOF
CLAUDE_PROXY_NODES="$scratch/nodes.json"
CLAUDE_SSH_HOST=jpvpn CLAUDE_SSH_USER=alice CLAUDE_SSH_KEY=/k CLAUDE_SSH_PORT=22
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080 CLAUDE_REMOTE_PROXY_PORT=8888
CLAUDE_NODE_HTTP_BASE=8180 CLAUDE_NODE_SOCKS_BASE=1180

# 1) Slots: the default node (by name or alias) is 'main'; others are node-<name>.
assert test "$(_node_slot jp)" = main
assert test "$(_node_slot jpvpn)" = main
assert test "$(_node_slot sg)" = node-sg
assert test "$(_node_slot sgvpn)" = node-sg
if out=$(_node_slot nowhere 2>&1); then echo 'FAIL: unknown node accepted' >&2; exit 1; fi
case "$out" in *"Unknown node 'nowhere'"*) ;; *) echo "FAIL: unknown node message: $out" >&2; exit 1;; esac
if out=$(_node_slot us 2>&1); then echo 'FAIL: unprovisioned node accepted' >&2; exit 1; fi
case "$out" in *'no address'*) ;; *) echo "FAIL: unprovisioned message: $out" >&2; exit 1;; esac
echo 'PASS: the default node is slot main; every other node has its own slot'

# 2) Node context: the node's alias and fixed ports, only inside the subshell.
got=$( _node_ctx sg; echo "$CLAUDE_SSH_HOST|$CLAUDE_SSH_USER|$CLAUDE_SSH_KEY|$CLAUDE_HTTP_PORT|$CLAUDE_SOCKS_PORT|$CLAUDE_REMOTE_PROXY_PORT" )
assert test "$got" = 'sgvpn|||8181|1181|8899'
assert test "$CLAUDE_SSH_HOST|$CLAUDE_HTTP_PORT|$CLAUDE_SSH_USER" = 'jpvpn|8080|alice'
got=$( _node_ctx jp; echo "$CLAUDE_SSH_HOST|$CLAUDE_SSH_USER|$CLAUDE_HTTP_PORT|$CLAUDE_SOCKS_PORT" )
assert test "$got" = 'jpvpn|alice|8080|1080'
echo "PASS: a node's context has its alias and fixed ports; the caller is unchanged"

# 3) Node ports must never collide with the main ports.
CLAUDE_NODE_HTTP_BASE=8079
if out=$( _node_ctx sg 2>&1 ); then echo 'FAIL: colliding node port accepted' >&2; exit 1; fi
case "$out" in *'proxy-config set NODE_HTTP_BASE'*) ;; *) echo "FAIL: collision message: $out" >&2; exit 1;; esac
CLAUDE_NODE_HTTP_BASE=8180 CLAUDE_NODE_SOCKS_BASE=1079
if out=$( _node_ctx sg 2>&1 ); then echo 'FAIL: colliding SOCKS port accepted' >&2; exit 1; fi
case "$out" in *'proxy-config set NODE_SOCKS_BASE'*) ;; *) echo "FAIL: SOCKS collision message: $out" >&2; exit 1;; esac
CLAUDE_NODE_SOCKS_BASE=1180
echo 'PASS: node ports that collide with the main ports are refused with the fix'

# 4) One owner per node: started in the node's context, found again, stopped alone.
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$src")"
eval "$(sed -n '/^# Compatibility entry points/,/^# PIDs of Claude/p' "$src" | sed '$d')"
fn tunnel-stop _node_tunnel_up tunnel-start _recovery_failure_report _node_ensure_alias _ssh_config_has_alias
export XDG_STATE_HOME="$scratch/state" CLAUDE_TUNNEL_LOG="$scratch/tunnel.log"
root=$(_recovery_root)
_node_ensure_alias() { :; }
_is_wsl() { return 1; }
# A stand-in worker: records the context it runs in, owns its slot until stopped.
_recovery_worker() {
    local me; me=$(sh -c 'echo $PPID')
    echo "$CLAUDE_SSH_HOST|$CLAUDE_HTTP_PORT|$CLAUDE_SOCKS_PORT|$CLAUDE_REMOTE_PROXY_PORT" > "$1/ctx"
    echo x >> "$scratch/spawns.${1##*/}"
    _recovery_claim "$1" "$me" || return 0
    _recovery_record_write "$1"
    while [ -d "$1" ] && [ ! -e "$1/stopped" ]; do sleep .1; done   # never outlive the test
    _recovery_release "$1" "$me"
}
_listeners() { :; }; _port_bound() { return 1; }; _port_in_use() { return 1; }
_legacy_watchdog_pid() { return 1; }
dsg=$(_recovery_owner_start claude sg)
assert test "$dsg" = "$root/node-sg"
assert test "$(cat "$dsg/ctx")" = 'sgvpn|8181|1181|8899'
assert grep -qx 'http=8181' "$dsg/tunnel.rec"
assert test "$(_recovery_owner_start claude sg)" = "$dsg"
assert test "$(wc -l < "$scratch/spawns.node-sg" | tr -d ' ')" = 1
dmain=$(_recovery_owner_start claude)
assert test "$dmain" = "$root/main"
assert test "$(cat "$dmain/ctx")" = 'jpvpn|8080|1080|8888'
assert test "$CLAUDE_SSH_HOST|$CLAUDE_HTTP_PORT" = 'jpvpn|8080'
echo 'PASS: each node gets its own owner, in its own context; a second start finds it'

tunnel-stop sg > "$scratch/stop-sg.out"
i=0; while _recovery_owner_pid "$dsg" >/dev/null && [ "$i" -lt 50 ]; do sleep .1; i=$((i+1)); done
assert test -z "$(_recovery_owner_pid "$dsg" || :)"
assert test -n "$(_recovery_owner_pid "$dmain")"
dsg=$(_recovery_owner_start claude sg)
mkdir -p "$root/hash123"   # an older version's owner directory
tunnel-stop > /dev/null
i=0; while _recovery_owner_pid "$dmain" >/dev/null && [ "$i" -lt 50 ]; do sleep .1; i=$((i+1)); done
assert test -z "$(_recovery_owner_pid "$dmain" || :)"
assert test -n "$(_recovery_owner_pid "$dsg")"
tunnel-stop sg > /dev/null
echo 'PASS: tunnel-stop <node> stops only that node; plain tunnel-stop leaves node tunnels running'

# 5) Migration: a 2.9 Chrome tunnel (unsupervised ssh on the node's SOCKS port) is
#    replaced; a foreign program on a node port is refused, never killed.
rm -f "$dsg/stopped" "$scratch/kills"
echo 4444 > "$scratch/legacy"
_listeners() { [ "$1" = 1181 ] && [ -s "$scratch/legacy" ] && cat "$scratch/legacy"; :; }
_port_in_use() { [ -n "$(_listeners "$1")" ]; }
_proc_name() { echo "$NAME"; }
kill() { case "$*" in *4444*) echo "$*" >> "$scratch/kills"; : > "$scratch/legacy";; *) builtin kill "$@";; esac; }
NAME=ssh
dsg=$(_recovery_owner_start claude sg 2>"$scratch/mig.err")
assert grep -q 4444 "$scratch/kills"
assert grep -q 'Upgrade' "$scratch/mig.err"
assert test -n "$(_recovery_owner_pid "$dsg")"
tunnel-stop sg > /dev/null; i=0; while _recovery_owner_pid "$dsg" >/dev/null && [ "$i" -lt 50 ]; do sleep .1; i=$((i+1)); done
rm -f "$scratch/kills"; echo 4444 > "$scratch/legacy"; NAME=python3
if _recovery_owner_start claude sg > /dev/null 2>"$scratch/foreign.err"; then echo 'FAIL: started over a foreign program' >&2; exit 1; fi
assert test ! -e "$scratch/kills"
assert grep -q 'python3 (PID 4444)' "$scratch/foreign.err"
assert grep -q 'NODE_SOCKS_BASE' "$scratch/foreign.err"
: > "$scratch/legacy"
echo 'PASS: an old Chrome tunnel on a node port is replaced; a foreign program is refused'

# 6) tunnel-start <node>: brings the node up and reports its ports.
_listeners() { :; }; _port_in_use() { [ "$1" = 8181 ] && [ -e "$scratch/sg-up" ]; }
command() { [ "$1 $2" = '-v ssh' ] && return 0; builtin command "$@"; }
touch "$scratch/sg-up"
tunnel-start sg > "$scratch/start-sg.out"
assert grep -q '8181' "$scratch/start-sg.out"
assert grep -q '1181' "$scratch/start-sg.out"
assert test -n "$(_recovery_owner_pid "$root/node-sg")"
tunnel-stop sg > /dev/null
unset -f command
echo 'PASS: tunnel-start <node> brings up that node on its own ports'

# No owner may outlive the test.
for d in "$root"/*; do
    if _recovery_owner_pid "$d" >/dev/null; then echo "FAIL: owner left running in ${d##*/}" >&2; exit 1; fi
done
echo 'PASS: no owner left running'
