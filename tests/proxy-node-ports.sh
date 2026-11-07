#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$repo/scripts/claude-proxy.sh")"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
CLAUDE_PROXY_LOCAL_NODES="$scratch/local"
printf 'lab 100\n' > "$CLAUDE_PROXY_LOCAL_NODES"
_nodes_tsv() { printf '%s\n' '0|jp|jpvpn|jp.example' '1|sg|sgvpn|sg.example' '2|us|usvpn|us.example'; }
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080
CLAUDE_NODE_HTTP_BASE=8180 CLAUDE_NODE_SOCKS_BASE=1180
CLAUDE_NODE_PORTS=''
[ "$(_node_ports_saved jp 0)" = '8180 1180' ]
CLAUDE_NODE_PORTS='# custom assignments
jp 9000 9001
manual 9100 9101'
[ "$(_node_ports_saved jp 0)" = '9000 9001' ]
rows=$(_node_ports_rows)
for row in 'jp 9000 9001' 'sg 8181 1181' 'us 8182 1182' 'lab 8280 1280' 'manual 9100 9101'; do
    printf '%s\n' "$rows" | grep -Fxq "$row"
done
[ "$(cat "$CLAUDE_PROXY_LOCAL_NODES")" = 'lab 100' ]
section=$(_node_ports_editor_section)
unset CLAUDE_NODE_PORTS
eval "$section"
_node_ports_validate
[ "$(_node_ports_saved manual 105)" = '9100 9101' ]
reject() { CLAUDE_NODE_PORTS="$1"; if _node_ports_validate >"$scratch/out" 2>"$scratch/err"; then echo "FAIL: accepted $1" >&2; exit 1; fi; [ -s "$scratch/err" ]; }
CLAUDE_NODE_PORTS='jp 8080 9001'
[ "$(_node_ports_saved us 2)" = '8182 1182' ]
_node_ports_rows | grep -Fxq 'jp 8080 9001'
_node_ports_editor_section > "$scratch/editable-conflict"
reject 'jp 8080 9001'
reject 'jp 9000 9000'
reject 'jp 9000 1181'
reject 'jp 9000 9001
us 9100 9000'
reject 'jp 9000 9001
jp 9100 9101'
reject 'bad/name 9000 9001'
reject 'jp 09000 9001'
reject 'jp 65536 9001'
reject 'jp 0 9001'
reject 'jp 9000 9001 trailing'
reject 'jp $(touch-NOT-RUN) 9001'
CLAUDE_NODE_PORTS=''
CLAUDE_NODE_HTTP_BASE=1080
if _node_ports_validate >/dev/null 2>&1; then echo 'FAIL: fallback conflicts with main were accepted'; exit 1; fi
echo 'PASS: node-port overrides, materialization, editable round trip, and planned conflict validation'
