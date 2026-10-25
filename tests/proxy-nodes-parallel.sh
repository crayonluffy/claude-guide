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
