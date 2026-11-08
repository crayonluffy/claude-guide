#!/usr/bin/env bash
# 2.13.2: only loopback / any-address listeners clash with the tunnel's 127.0.0.1
# forward (a service on a LAN address doesn't), and a program this account can't
# see is never treated as an old tunnel to replace.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in _port_bound _port_in_use _listeners _recovery_migrate _is_ssh_name; do
    eval "$(sed -n "/^$f() {/,/^}\$/p" "$repo/scripts/claude-proxy.sh")"
done
eval "$(sed -n '/^_SS_LOOPBACK_AWK=/p' "$repo/scripts/claude-proxy.sh")"
eval "$(sed -n '/^_macos_port_bound() {/,/^}$/p' "$repo/scripts/claude-proxy-macos.sh")"
lsof() { return 1; }; command() { [ "$2" != lsof ] && builtin command "$@"; }
ss() {
    printf '%s\n' 'State Recv-Q Send-Q Local Peer' \
        'LISTEN 0 1 10.148.0.2:1080 0.0.0.0:*' 'LISTEN 0 1 127.0.0.1:8080 0.0.0.0:*' \
        'LISTEN 0 1 [::]:22 [::]:*' 'LISTEN 0 1 *:7070 *:*' 'LISTEN 0 1 127.0.0.53%lo:53 0.0.0.0:*'
}
for p in 8080 22 7070; do _port_bound "$p" || fail "$p should clash"; done
for p in 1080 53 80 108; do ! _port_bound "$p" || fail "$p should be free"; done
netstat() { printf '%s\n' 'tcp4 0 0 10.0.0.5.1080 *.* LISTEN' 'tcp46 0 0 *.7070 *.* LISTEN' 'tcp6 0 0 ::1.9090 *.* LISTEN'; }
! _macos_port_bound 1080 || fail 'macOS LAN listener'
_macos_port_bound 7070 && _macos_port_bound 9090 || fail 'macOS loopback listeners'
echo 'PASS: port checks count only loopback/any-address listeners'

# Another user's program on the tunnel port (bound, no visible PID) is refused.
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1081
_listeners() { :; }
tunnel-stop() { fail 'tunnel-stop must not run for a foreign port'; }
out=$(_recovery_migrate 2>&1) && fail 'migrate accepted a foreign port'
case "$out" in *"Another user's program is on port 8080"*) ;; *) fail "message: $out" ;; esac
echo 'PASS: an invisible port owner is never treated as an old tunnel'
