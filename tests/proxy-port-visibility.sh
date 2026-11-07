#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PLATFORM ADAPTERS$/,/^# END PLATFORM ADAPTERS$/p' "$repo/scripts/claude-proxy.sh")"
eval "$(sed -n '/^_port_bound() {/,/^}/p' "$repo/scripts/claude-proxy.sh")"
uname() { echo Darwin; }
command() { if [ "${1:-}" = -v ] && [ "${2:-}" = ss ]; then return 1; fi; builtin command "$@"; }
_listeners() { :; } # other account's process is not visible to lsof
netstat() {
    cat <<'SOCKETS'
Active Internet connections (including servers)
Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
tcp4  0      0       127.0.0.1.8080         *.*                    LISTEN
tcp6  0      0       ::1.1080               *.*                    LISTEN
tcp4  0      0       127.0.0.1.8180         127.0.0.1.53211         ESTABLISHED
SOCKETS
}
_port_bound 8080
_port_bound 1080
if _port_bound 80 || _port_bound 8180; then echo 'FAIL: wrong port or non-listening socket counted'; exit 1; fi
echo 'PASS: macOS detects another account\047s listening ports without seeing its process'
