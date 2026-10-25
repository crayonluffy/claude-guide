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

# 7) Per-terminal node: cc / cx / proxy-up --node <other node> touch only this
#    terminal (and only the app's environment for cc / cx).
mkdir -p "$scratch/bin"
for b in claude codex; do
    cat > "$scratch/bin/$b" <<BIN
#!/bin/sh
printf '%s\n' "\$@" > "$scratch/$b.argv"
echo "\${HTTPS_PROXY:-unset}" > "$scratch/$b.proxy"
ls "$scratch/st7/claude-proxy/recovery/node-sg/sessions" 2>/dev/null | wc -l | tr -d ' ' > "$scratch/$b.sessions"
BIN
    chmod +x "$scratch/bin/$b"
done
run() {  # <conf lines> <commands>: fresh isolated shell with the profile and mocked tunnels
    local conf="$1"; shift
    (
        export HOME="$scratch/h7" XDG_STATE_HOME="$scratch/st7" CLAUDE_PROXY_CONF="$scratch/c7"
        export CLAUDE_SETTINGS="$scratch/s7.json" CLAUDE_PROXY_NODES="$scratch/nodes.json" PATH="$scratch/bin:$PATH"
        unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy
        mkdir -p "$HOME"; printf 'CLAUDE_SSH_HOST=jpvpn\nCLAUDE_PROXY_BANNER=0\n%s\n' "$conf" > "$CLAUDE_PROXY_CONF"
        set +eu; . "$src" >/dev/null 2>&1
        tunnel-start() { echo "tunnel-start $*" >> "$scratch/ts7"; }
        _tunnel_health() { echo "ok 1 ssh $CLAUDE_HTTP_PORT"; }
        _recovery_probe() { echo "$2" >> "$scratch/probed7"; echo 'healthy|0|200|404|healthy'; }
        _recovery_owner_start() { _recovery_identity "$(_node_slot "${2:-$CLAUDE_SSH_HOST}")"; }
        _listeners() { :; }; _port_bound() { return 1; }
        eval "$*"
    )
}
rm -f "$scratch"/claude.* "$scratch"/codex.* "$scratch/ts7"
out=$(run '' 'cc --node sg --no-verify -p hi; echo "shell:${HTTPS_PROXY:-unset}"' 2>&1)
assert grep -qx 'tunnel-start sg' "$scratch/ts7"
assert test "$(sed -n 1p "$scratch/claude.argv")" = --settings
json=$(sed -n 2p "$scratch/claude.argv")
assert test "$(printf '%s' "$json" | jq -r .env.HTTPS_PROXY)" = http://127.0.0.1:8181
assert test "$(printf '%s' "$json" | jq -r .env.HTTP_PROXY)" = http://127.0.0.1:8181
assert test "$(sed -n '3,5p' "$scratch/claude.argv" | tr '\n' ' ')" = '--dangerously-skip-permissions -p hi '
assert test "$(cat "$scratch/claude.proxy")" = http://127.0.0.1:8181
assert test "$(cat "$scratch/claude.sessions")" = 1
case "$out" in *'shell:unset'*) ;; *) echo "FAIL: cc --node changed the shell: $out" >&2; exit 1;; esac
assert grep -qx 8181 "$scratch/probed7"
echo 'PASS: cc --node sg runs Claude through sg (--settings + env) and leaves the shell alone'

out=$(run '' 'cx --node sg --no-verify exec ls; echo "shell:${HTTPS_PROXY:-unset}"' 2>&1)
assert test "$(cat "$scratch/codex.proxy")" = http://127.0.0.1:8181
assert test "$(head -1 "$scratch/codex.argv")" = --dangerously-bypass-approvals-and-sandbox
if grep -q -- --settings "$scratch/codex.argv"; then echo 'FAIL: codex got --settings' >&2; exit 1; fi
case "$out" in *'shell:unset'*) ;; *) echo "FAIL: cx --node changed the shell: $out" >&2; exit 1;; esac
echo 'PASS: cx --node sg runs Codex through sg (env for the app only)'

out=$(run '' 'proxy-up --node sg --no-verify >/dev/null; echo "shell:$HTTPS_PROXY"; grep CLAUDE_SSH_HOST "$CLAUDE_PROXY_CONF"; jq -r .env.HTTPS_PROXY "$CLAUDE_SETTINGS"' 2>&1)
case "$out" in *'shell:http://127.0.0.1:8181'*'CLAUDE_SSH_HOST=jpvpn'*'http://127.0.0.1:8080'*) ;; *) echo "FAIL: proxy-up --node: $out" >&2; exit 1;; esac
echo 'PASS: proxy-up --node sg sets this shell only; the default node and the pin stay'

rm -f "$scratch/claude.argv"
run '' 'cc --node jp --no-verify -p hi' >/dev/null 2>&1
if grep -q -- --settings "$scratch/claude.argv"; then echo 'FAIL: default node got --settings' >&2; exit 1; fi
assert test "$(head -1 "$scratch/claude.argv")" = --dangerously-skip-permissions
echo 'PASS: cc --node <default node> is plain cc'

rm -f "$scratch/claude.argv"
run 'CLAUDE_PLAIN_COMMANDS=auto' 'claude --node sg -p hi' >/dev/null 2>&1
assert test "$(sed -n 1p "$scratch/claude.argv")" = --settings
assert test "$(sed -n 3p "$scratch/claude.argv")" = -p
echo 'PASS: plain claude --node sg (PLAIN_COMMANDS=auto) goes through sg'

# The --settings JSON is valid for any NO_PROXY, with or without jq.
eval "$(sed -n '/^_node_settings_json() {/,/^}/p' "$src")"
CLAUDE_NO_PROXY='localhost,a"b\c'
assert test "$(_node_settings_json 8181 | jq -r .env.NO_PROXY)" = 'localhost,a"b\c'
mkdir -p "$scratch/nojq"; for t in sed printf; do ln -sf "$(command -v $t)" "$scratch/nojq/$t"; done
nojq=$(PATH="$scratch/nojq"; _node_settings_json 8181)
assert test "$(printf '%s' "$nojq" | jq -r .env.NO_PROXY)" = 'localhost,a"b\c'
assert test "$(printf '%s' "$nojq" | jq -r .env.HTTPS_PROXY)" = http://127.0.0.1:8181
echo 'PASS: the --settings JSON is valid with and without jq'

# 8) proxy-node changes the default only when no session would silently move.
out=$(run '' '_recovery_sessions() { case "$1" in */main) echo 2;; *) echo 0;; esac; }; proxy-node sg; echo "rc=$?"; grep CLAUDE_SSH_HOST "$CLAUDE_PROXY_CONF"' 2>&1)
case "$out" in *'2 session(s)'*'cc --node sg'*'--force'*'rc=1'*'CLAUDE_SSH_HOST=jpvpn'*) ;; *) echo "FAIL: proxy-node moved running sessions: $out" >&2; exit 1;; esac
out=$(run '' '_tunnel_health() { echo down; }; _recovery_sessions() { case "$1" in */main) echo 2;; *) echo 0;; esac; }; _node_ensure_alias() { :; }; proxy-node --force sg >/dev/null; echo "rc=$?"; grep CLAUDE_SSH_HOST "$CLAUDE_PROXY_CONF"' 2>&1)
case "$out" in *'rc=0'*'CLAUDE_SSH_HOST="sgvpn"'*) ;; *) echo "FAIL: proxy-node --force: $out" >&2; exit 1;; esac
out=$(run '' '_tunnel_health() { echo down; }; _recovery_sessions() { echo 0; }; _node_ensure_alias() { :; }; proxy-node sg >/dev/null; echo "rc=$?"' 2>&1)
case "$out" in *'rc=0'*) ;; *) echo "FAIL: proxy-node with no sessions: $out" >&2; exit 1;; esac
echo 'PASS: proxy-node refuses to move running sessions unless --force'

# 9) cc-stop and proxy-status cover every node tunnel.
out=$(run '' '
    d=$(_recovery_identity node-sg)
    mkdir -p "$d/sessions"; _recovery_process_identity $$ > "$d/sessions/$$"
    _other_agents() { :; }
    cc-stop; echo "rc=$?"' 2>&1)
case "$out" in *'1 Claude/Codex session(s)'*'rc=1'*) ;; *) echo "FAIL: cc-stop ignored a node session: $out" >&2; exit 1;; esac
out=$(run '' '
    _other_agents() { :; }; proxy-off() { :; }; _node_tunnels_stop() { echo legacy-sweep >> "'"$scratch"'/order9"; }
    _recovery_owned_dirs() { [ "${1:-}" = all ] && printf "%s\n" "$XDG_STATE_HOME/claude-proxy/recovery/main" "$XDG_STATE_HOME/claude-proxy/recovery/node-sg"; :; }
    _recovery_owner_stop() { echo "stop ${1##*/}" >> "'"$scratch"'/order9"; }
    rm -rf "$XDG_STATE_HOME/claude-proxy/recovery/node-sg/sessions"
    cc-stop >/dev/null; echo "rc=$?"' 2>&1)
case "$out" in *'rc=0'*) ;; *) echo "FAIL: cc-stop: $out" >&2; exit 1;; esac
assert grep -qx 'stop node-sg' "$scratch/order9"
assert test "$(tail -1 "$scratch/order9")" = legacy-sweep
echo 'PASS: cc-stop counts sessions on every node and stops node owners before the old-tunnel sweep'

out=$(run '' '
    d=$(_recovery_identity node-sg)
    printf "host=sgvpn\nhttp=8181\nsocks=1181\n" > "$d/tunnel.rec"
    printf "auth|5|Permission denied\n" > "$d/ssh.status"
    _recovery_owner_pid() { case "$1" in */node-sg) echo 4242;; *) return 1;; esac; }
    _tunnel_health() { echo down; }; proxy-notify() { :; }; curl() { :; }
    proxy-status' 2>&1)
case "$out" in *'Node tunnels'*'sg'*'8181'*'1181'*'SSH login to sgvpn was refused'*) ;; *) echo "FAIL: proxy-status node line: $out" >&2; exit 1;; esac
echo 'PASS: proxy-status shows each node tunnel with its ports and last error'

# No owner may outlive the test.
for d in "$root"/*; do
    if _recovery_owner_pid "$d" >/dev/null; then echo "FAIL: owner left running in ${d##*/}" >&2; exit 1; fi
done
echo 'PASS: no owner left running'

# 10) proxy-doctor probes each node tunnel through its own port.
out=$(run '' '
    d=$(_recovery_identity node-sg); printf "host=sgvpn\nhttp=8181\nsocks=1181\n" > "$d/tunnel.rec"
    _recovery_owner_pid() { case "$1" in */node-sg) echo 4242;; *) return 1;; esac; }
    _proxy_probe() { [ "$1" = 8181 ] && echo "dead 7 000 000" || echo "ok 0 200 404"; }
    _doctor_vm_check() { :; }; curl() { :; }
    proxy-doctor' 2>&1)
case "$out" in *'Node tunnel sg (sgvpn, :8181) does not answer'*'proxy-restart sg'*) ;; *) echo "FAIL: doctor node line: $(printf '%s' "$out" | grep -i node)" >&2; exit 1;; esac
echo 'PASS: proxy-doctor probes each node tunnel'

# 11) Plain ssh aliases (not in the node list) work as nodes too: each gets a
#     fixed local slot from 100 up, saved so the ports stay the same.
fn _ssh_config_has_alias _node_local_slot
export HOME="$scratch/h11"; mkdir -p "$HOME/.ssh"
printf 'Host devbox\n    HostName 192.0.2.20\nHost lab2\n    HostName 192.0.2.21\n' > "$HOME/.ssh/config"
CLAUDE_PROXY_LOCAL_NODES="$HOME/.claude-proxy.local-nodes"
assert test "$(_node_slot devbox)" = node-devbox
got=$( _node_ctx devbox; echo "$CLAUDE_SSH_HOST|$CLAUDE_HTTP_PORT|$CLAUDE_SOCKS_PORT|$CLAUDE_REMOTE_PROXY_PORT" )
assert test "$got" = 'devbox|8280|1280|8888'
got=$( _node_ctx lab2; echo "$CLAUDE_HTTP_PORT|$CLAUDE_SOCKS_PORT" )
assert test "$got" = '8281|1281'
got=$( _node_ctx devbox; echo "$CLAUDE_HTTP_PORT" )
assert test "$got" = 8280                                   # stable across calls
assert grep -qx 'devbox 100' "$CLAUDE_PROXY_LOCAL_NODES"
assert grep -qx 'lab2 101' "$CLAUDE_PROXY_LOCAL_NODES"
# A catalogue node still wins; an unknown name is still refused.
assert test "$(_node_slot sg)" = node-sg
if _node_slot nowhere >/dev/null 2>&1; then echo 'FAIL: unknown name accepted' >&2; exit 1; fi
# The local file is data, never code.
printf '$(touch %s/pwned) 7\n' "$scratch" >> "$CLAUDE_PROXY_LOCAL_NODES"
( _node_ctx devbox >/dev/null )
assert test ! -e "$scratch/pwned"
echo 'PASS: plain ssh aliases are nodes with fixed local slots (from 100); the node list wins'

# cc --node <alias> runs through the alias's own tunnel.
rm -f "$scratch/claude.argv" "$scratch/ts7"
mkdir -p "$scratch/h7/.ssh"; cp "$HOME/.ssh/config" "$scratch/h7/.ssh/config"
run '' 'cc --node devbox --no-verify -p hi' >/dev/null 2>&1
assert grep -qx 'tunnel-start devbox' "$scratch/ts7"
assert test "$(sed -n 2p "$scratch/claude.argv" | jq -r .env.HTTPS_PROXY)" = http://127.0.0.1:8280
echo 'PASS: cc --node <plain ssh alias> goes through that alias'

# 12) cc-stop <node> / cx-stop <node>: stop one node's tunnel only.
out=$(run '' '
    tunnel-stop() { echo "tunnel-stop ${1:-default}"; }; _recovery_stop_owners() { echo "stop-all"; }
    proxy-off() { echo proxy-off; }; _node_tunnels_stop() { :; }; _other_agents() { :; }
    d=$(_recovery_identity node-sg); mkdir -p "$d/sessions"; _recovery_process_identity $$ > "$d/sessions/$$"
    echo "== guarded"; cc-stop sg; echo "rc=$?"
    echo "== forced"; cc-stop sg --force
    rm -f "$d/sessions/$$"
    echo "== cx"; cx-stop sg
    echo "== env"; export HTTPS_PROXY=http://127.0.0.1:8181; cc-stop sg >/dev/null; echo "env:${HTTPS_PROXY:-cleared}"
    echo "== other env"; export HTTPS_PROXY=http://127.0.0.1:8080; cc-stop sg >/dev/null; echo "env:${HTTPS_PROXY:-cleared}"
    echo "== default"; cc-stop jp
    echo "== unknown"; cc-stop nowhere; echo "rc=$?"' 2>&1)
sect() { printf '%s\n' "$out" | sed -n "/^== $1\$/,/^== /p"; }
case "$(sect guarded)" in *'1 Claude/Codex session(s) use node sg'*'cc-stop sg --force'*'rc=1'*) ;; *) echo "FAIL: guard: $(sect guarded)" >&2; exit 1;; esac
if sect guarded | grep -q 'tunnel-stop'; then echo 'FAIL: stopped under a session' >&2; exit 1; fi
sect forced | grep -qx 'tunnel-stop sg' || { echo "FAIL: --force: $(sect forced)" >&2; exit 1; }
sect cx | grep -qx 'tunnel-stop sg' || { echo "FAIL: cx-stop: $(sect cx)" >&2; exit 1; }
if printf '%s\n' "$out" | sed -n '/^== forced$/,/^== default$/p' | grep -q 'stop-all\|proxy-off'; then echo 'FAIL: cc-stop sg stopped other nodes or cleared the shell' >&2; exit 1; fi
sect env | grep -qx 'env:cleared' || { echo "FAIL: env of sg not cleared: $(sect env)" >&2; exit 1; }
sect 'other env' | grep -qx 'env:http://127.0.0.1:8080' || { echo "FAIL: other env cleared: $(sect 'other env')" >&2; exit 1; }
case "$(sect default)" in *'tunnel-stop default'*'proxy-off'*) ;; *) echo "FAIL: cc-stop <default node>: $(sect default)" >&2; exit 1;; esac
if sect default | grep -q 'stop-all'; then echo 'FAIL: cc-stop <default> stopped other nodes' >&2; exit 1; fi
case "$(sect unknown)" in *"Unknown node 'nowhere'"*'rc=1'*) ;; *) echo "FAIL: unknown: $(sect unknown)" >&2; exit 1;; esac
echo 'PASS: cc-stop / cx-stop <node> stop one node only, guarded by its sessions'
