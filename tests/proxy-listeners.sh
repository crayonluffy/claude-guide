#!/usr/bin/env bash
# Without lsof (minimal Linux images) the profile still names the programs on a
# port, and the ports a PID listens on, from ss -ltnp.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}"
eval "$(sed -n '/^_listeners() {/,/^}/p;/^_pid_listen_ports() {/,/^}/p' "$src")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
# Only the tools the helpers and this test use - and deliberately no lsof.
for tool in awk grep cut sort cat tr rm; do ln -s "$(command -v "$tool")" "$scratch/bin/$tool"; done
cat > "$scratch/bin/ss" <<'SS'
#!/bin/sh
cat <<'OUT'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      128        127.0.0.1:8080       0.0.0.0:*    users:(("ssh",pid=123,fd=5))
LISTEN 0      128        127.0.0.1:1080       0.0.0.0:*    users:(("ssh",pid=123,fd=4))
LISTEN 0      128            [::1]:8080          [::]:*    users:(("ssh",pid=123,fd=6))
LISTEN 0      128          0.0.0.0:18080      0.0.0.0:*    users:(("python3",pid=12,fd=3))
LISTEN 0      128          0.0.0.0:80         0.0.0.0:*
OUT
SS
chmod +x "$scratch/bin/ss"
PATH="$scratch/bin"   # no lsof here
assert test "$(_listeners 8080)" = 123
assert test "$(_listeners 18080)" = 12
assert test -z "$(_listeners 80)"       # another user's socket: seen by _port_bound, not named
assert test -z "$(_listeners 808)"
assert test "$(_pid_listen_ports 123 | tr '\n' ' ')" = '1080 8080 '
assert test "$(_pid_listen_ports 12)" = 18080
echo 'PASS: without lsof, ss names the listeners and their ports'
