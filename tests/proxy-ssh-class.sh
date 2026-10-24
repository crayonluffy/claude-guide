#!/usr/bin/env bash
# An ssh that exits is classified from its own stderr, so the owner can say WHY
# the tunnel is down (and how to fix it) and stop hammering the server with a
# login that cannot succeed. Retries for network trouble keep their normal pace.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"   # never the real recovery state

# 1) Classifier table.
check() {  # <expected class> <stderr text>
    printf '%s\n' "$2" > "$scratch/err"
    got=$(_recovery_ssh_class "$scratch/err")
    if [ "$got" != "$1" ]; then echo "FAIL: expected $1, got $got for: $2" >&2; exit 1; fi
}
check auth     'user@jp: Permission denied (publickey).'
check auth     'Too many authentication failures'
check auth     'Load key "/home/u/.ssh/id": bad permissions'
check hostkey  'Host key verification failed.'
check hostkey  '@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@'
check forward  'bind [127.0.0.1]:8080: Address already in use'
check forward  'channel_setup_fwd_listener_tcpip: cannot listen to port: 1080'
check forward  'Could not request local forwarding.'
check network  'ssh: connect to host jp port 22: Connection timed out'
check network  'ssh: Could not resolve hostname jp: Name or service not known'
check network  'ssh: connect to host jp port 22: Connection refused'
check network  'Connection closed by 1.2.3.4 port 22'
check unknown  'something nobody has seen before'
check unknown  ''
[ "$(_recovery_ssh_class "$scratch/does-not-exist")" = unknown ]
echo 'PASS: ssh stderr classified as auth, hostkey, forward, network or unknown'

# 2) Each class says how to fix it, and names the server.
hint=$(_recovery_ssh_hint auth jp);     case "$hint" in *'ssh-add'*jp*|*jp*'ssh-add'*) ;; *) echo "FAIL: auth hint: $hint" >&2; exit 1;; esac
hint=$(_recovery_ssh_hint hostkey jp);  case "$hint" in *'ssh-keygen -R jp'*) ;; *) echo "FAIL: hostkey hint: $hint" >&2; exit 1;; esac
hint=$(_recovery_ssh_hint network jp);  case "$hint" in *'Retrying'*) ;; *) echo "FAIL: network hint: $hint" >&2; exit 1;; esac
echo 'PASS: each failure class has a one-line fix'

# 3) The owner drives the real loop with a fake ssh that exits at once.
export CLAUDE_TUNNEL_LOG="$scratch/tunnel.log"
export CLAUDE_DESKTOP_NOTIFICATIONS=off
CLAUDE_SSH_HOST=jp CLAUDE_SSH_USER= CLAUDE_SSH_PORT=22 CLAUDE_SSH_KEY= CLAUDE_REMOTE_PROXY_PORT=8888
CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080
CLAUDE_WATCHDOG_INTERVAL=0 CLAUDE_WATCHDOG_FAILS=2 CLAUDE_WATCHDOG_NOTICE_AFTER=60
CLAUDE_WATCHDOG_MAX_BACKOFF=30 CLAUDE_WATCHDOG_STARTUP_GRACE=0
_listeners() { :; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
_wd_sleep() { :; }
# Clock advances 5 s per pass; the file survives subshells.
_recovery_now() { local t; read -r t < "$scratch/clock"; echo "$t"; echo $((t+5)) > "$scratch/clock"; }
_recovery_probe() {
    local t; read -r t < "$scratch/clock"
    if [ "$t" -ge 25 ]; then cp "$dir/ssh.status" "$scratch/status.$(basename "$dir")" 2>/dev/null || :; touch "$dir/stopped"; fi
    echo 'tunnel|7|000|000|tunnel'
}
_recovery_desktop_backend() { echo off; }

# 3a) Login refused: reported at once, and no retry storm while it stays refused.
dir="$scratch/auth"; mkdir "$dir"; echo 0 > "$scratch/clock"; : > "$scratch/launches"
ssh() { echo x >> "$scratch/launches"; echo 'user@jp: Permission denied (publickey).' >&2; exit 255; }
_recovery_worker "$dir" > "$scratch/auth.log"
assert test "$(wc -l < "$scratch/launches" | tr -d ' ')" = 1
assert test "$(cut -d'|' -f1 "$scratch/status.auth")" = auth
assert test "$(cut -d'|' -f6 "$dir/claude.state")" -ge 30   # next retry waits the maximum backoff
assert grep -q 'SSH login to jp was refused' "$scratch/auth.log"
assert grep -q 'Permission denied' "$scratch/auth.log"
echo 'PASS: refused login is reported at once and retried only after the maximum backoff'

# 3b) Network trouble: keeps the normal, shorter retry pace.
dir="$scratch/net"; mkdir "$dir"; echo 0 > "$scratch/clock"; : > "$scratch/launches"
ssh() { echo x >> "$scratch/launches"; echo 'ssh: connect to host jp port 22: Connection timed out' >&2; exit 255; }
_recovery_worker "$dir" > "$scratch/net.log"
assert test "$(cut -d'|' -f1 "$scratch/status.net")" = network
assert test "$(wc -l < "$scratch/launches" | tr -d ' ')" -ge 3
echo 'PASS: network failures keep retrying at the normal pace'

# 3c) A healthy tunnel clears the stale reason.
dir="$scratch/healthy"; mkdir "$dir"; echo 0 > "$scratch/clock"
printf 'auth|5|old\n' > "$dir/ssh.status"
ssh() { exec sleep 100; }
_recovery_probe() {
    local t; read -r t < "$scratch/clock"
    if [ "$t" -ge 10 ]; then cp "$dir/ssh.status" "$scratch/status.$(basename "$dir")" 2>/dev/null || :; touch "$dir/stopped"; fi
    echo 'healthy|0|200|404|healthy'
}
_recovery_worker "$dir" > "$scratch/healthy.log"
assert test ! -e "$scratch/status.healthy"
echo 'PASS: a healthy tunnel clears the last ssh failure'

# 4) What the user sees: the failure report, a live terminal notice, proxy-status.
src="${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}"
eval "$(sed -n '/^_recovery_failure_report() {/,/^}/p' "$src")"
eval "$(sed -n '/^proxy-status() {/,/^}/p' "$src")"
dir=$(_recovery_identity)
printf 'auth|5|Permission denied (publickey).\n' > "$dir/ssh.status"
printf 'user@jp: Permission denied (publickey).\n' > "$dir/ssh.err"
report=$(_recovery_failure_report)
case "$report" in *'SSH login to jp was refused'*) ;; *) echo "FAIL: report lacks the fix: $report" >&2; exit 1;; esac
case "$report" in *'Permission denied (publickey)'*) ;; *) echo "FAIL: report lacks ssh output" >&2; exit 1;; esac
echo 'PASS: a failed start explains the reason, the fix, and the real ssh output'

# A live terminal is told once, without waiting for the next probe.
sub=$(_recovery_subscribe "$dir" claude 2>"$scratch/sub.err")
subid=$(_recovery_process_identity "$sub")
sleep 2
_recovery_unsubscribe "$sub" "$subid"
assert grep -q 'claude proxy\] SSH login to jp was refused' "$scratch/sub.err"
assert test "$(grep -c 'was refused' "$scratch/sub.err")" = 1
echo 'PASS: a live terminal is told once that its login was refused'

# proxy-status shows the reason; network calls and the desktop check are mocked.
CLAUDE_PROXY_VERSION=test CLAUDE_PROXY_CONF="$scratch/none.conf"   # set by the profile in real use
_tunnel_health() { echo down; }
_node_active_name() { :; }
proxy-notify() { :; }
curl() { :; }
out=$(proxy-status 2>&1)
case "$out" in *'Last ssh error'*'SSH login to jp was refused'*) ;; *) echo "FAIL: proxy-status hides the reason" >&2; exit 1;; esac
echo 'PASS: proxy-status shows the last ssh error with its fix'
