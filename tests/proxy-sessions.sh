#!/usr/bin/env bash
# Every cc/cx registers a heartbeat with its owner. With no live session the
# owner probes rarely (Chrome may still use the tunnel) but wakes the moment a
# terminal needs it; the stop guards count these sessions too, so a Claude that
# runs under another process name (npm's node) still blocks cc-stop.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}"
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$src")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"
CLAUDE_SSH_HOST=jp
dir=$(_recovery_identity)

# 1) A subscriber registers its session at once and removes it when it ends.
sub=$(_recovery_subscribe "$dir" claude 2>/dev/null)
subid=$(_recovery_process_identity "$sub")
assert test -f "$dir/sessions/$sub"
assert test "$(cat "$dir/sessions/$sub")" = "$subid"
assert test "$(_recovery_sessions "$dir")" = 1
_recovery_unsubscribe "$sub" "$subid"
i=0; while [ -e "$dir/sessions/$sub" ] && [ "$i" -lt 30 ]; do sleep .1; i=$((i+1)); done
assert test ! -e "$dir/sessions/$sub"
assert test "$(_recovery_sessions "$dir")" = 0
echo 'PASS: a session registers with the owner and unregisters on exit'

# 2) Dead or reused PIDs do not count, and their entries are cleaned up.
printf 'whatever\n' > "$dir/sessions/99999999"
printf 'not-the-real-start\n' > "$dir/sessions/$$"
assert test "$(_recovery_sessions "$dir")" = 0
assert test ! -e "$dir/sessions/99999999"
assert test ! -e "$dir/sessions/$$"
_recovery_process_identity "$$" > "$dir/sessions/$$"
assert test "$(_recovery_sessions "$dir")" = 1
rm -f "$dir/sessions/$$"
echo 'PASS: only live sessions count; stale entries are removed'

# 3) The owner idles while nobody uses it, and keeps the fast pace otherwise.
export CLAUDE_TUNNEL_LOG="$scratch/tunnel.log"
CLAUDE_SSH_USER= CLAUDE_SSH_PORT=22 CLAUDE_SSH_KEY= CLAUDE_REMOTE_PROXY_PORT=8888
CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080
CLAUDE_WATCHDOG_INTERVAL=5 CLAUDE_WATCHDOG_IDLE_INTERVAL=60 CLAUDE_WATCHDOG_FAILS=2
CLAUDE_WATCHDOG_NOTICE_AFTER=60 CLAUDE_WATCHDOG_STARTUP_GRACE=0
_listeners() { :; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
_recovery_desktop_backend() { echo off; }
ssh() { exec sleep 100; }
eval "$(grep '^_wd_sleep()' "$src" | sed 's/^_wd_sleep/_real_wd_sleep/')"
eval "$(declare -f _recovery_idle_sleep | sed '1s/_recovery_idle_sleep/_real_idle_sleep/')"
_wd_sleep() { echo "busy $1" >> "$scratch/sleeps"; }
_recovery_idle_sleep() { echo "idle $1" >> "$scratch/sleeps"; }
_recovery_probe() {
    n=$(( $(cat "$scratch/passes" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$scratch/passes"
    [ "$n" -lt 2 ] || touch "$wdir/stopped"
    echo 'healthy|0|200|404|healthy'
}
wdir="$scratch/idle"; mkdir -p "$wdir"; rm -f "$scratch/sleeps" "$scratch/passes"
_recovery_worker "$wdir" > /dev/null
assert test "$(head -1 "$scratch/sleeps")" = 'idle 60'
wdir="$scratch/busy"; mkdir -p "$wdir/sessions"; rm -f "$scratch/sleeps" "$scratch/passes"
_recovery_process_identity "$$" > "$wdir/sessions/$$"
_recovery_worker "$wdir" > /dev/null
assert test "$(head -1 "$scratch/sleeps")" = 'busy 5'
echo 'PASS: an owner with no sessions probes at the idle interval, with sessions at the normal one'

# 3b) Never idle while the tunnel is unhealthy - recovery keeps its pace.
_recovery_probe() {
    n=$(( $(cat "$scratch/passes" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$scratch/passes"
    [ "$n" -lt 2 ] || touch "$wdir/stopped"
    echo 'tunnel|7|000|000|tunnel'
}
wdir="$scratch/down"; mkdir -p "$wdir"; rm -f "$scratch/sleeps" "$scratch/passes"
_recovery_worker "$wdir" > /dev/null
assert test "$(head -1 "$scratch/sleeps")" = 'busy 5'
echo 'PASS: an unhealthy tunnel is never probed at the idle pace'

# 4) The idle sleep ends early on a wake request or a new session.
_wd_sleep() { _real_wd_sleep "$@"; }
_recovery_idle_sleep() { _real_idle_sleep "$@"; }
wdir="$scratch/wake"; mkdir -p "$wdir"
( sleep .3; touch "$wdir/wake" ) &
t0=$(date +%s); _recovery_idle_sleep 10 "$wdir"; t1=$(date +%s)
assert test $((t1-t0)) -lt 3
assert test ! -e "$wdir/wake"
( sleep .3; mkdir -p "$wdir/sessions"; _recovery_process_identity "$$" > "$wdir/sessions/$$" ) &
t0=$(date +%s); _recovery_idle_sleep 10 "$wdir"; t1=$(date +%s)
assert test $((t1-t0)) -lt 3
wait
echo 'PASS: an idle owner wakes on demand and when a session starts'

# 5) proxy-up wakes an idle owner and waits for it instead of refusing at once.
eval "$(sed -n '/^proxy-up() {/,/^}/p' "$src")"
_recovery_owner_pid() { echo 4242; }
_recovery_adopt() { :; }
tunnel-start() { :; }
_tunnel_health() { echo "ok 4242 ssh $CLAUDE_HTTP_PORT"; }
proxy-on() { :; }
rm -rf "$dir/wake"; echo 0 > "$scratch/probes"
_recovery_probe() {
    n=$(( $(cat "$scratch/probes") + 1 )); echo "$n" > "$scratch/probes"
    if [ "$n" -lt 3 ]; then echo 'tunnel|7|000|000|tunnel'; else echo 'healthy|0|200|404|healthy'; fi
}
CLAUDE_WATCHDOG_STARTUP_GRACE=5
proxy-up --no-verify > "$scratch/up.out"
assert test -e "$dir/wake"
assert test "$(cat "$scratch/probes")" = 3
assert grep -q 'Proxy ready' "$scratch/up.out"
_recovery_probe() { echo 'tunnel|7|000|000|tunnel'; }
CLAUDE_WATCHDOG_STARTUP_GRACE=1
if proxy-up --no-verify > "$scratch/up2.out"; then echo 'FAIL: proxy-up launched over a dead tunnel' >&2; exit 1; fi
assert grep -q 'transport unavailable' "$scratch/up2.out"
echo 'PASS: proxy-up wakes the owner, waits for health, and still refuses a dead tunnel'

# 6) cc-stop refuses while a registered session runs, even if ps cannot name it.
eval "$(sed -n '/^_count() {/,/^}/p' "$src")"
eval "$(sed -n '/^cc-stop() {/,/^}/p' "$src")"
_other_agents() { :; }
tunnel-stop() { echo stopped >> "$scratch/stops"; }
_node_tunnels_stop() { :; }
proxy-off() { :; }
_recovery_process_identity "$$" > "$dir/sessions/$$"
if cc-stop > "$scratch/stop.out"; then echo 'FAIL: cc-stop ignored a registered session' >&2; exit 1; fi
assert test ! -e "$scratch/stops"
assert grep -q '1 Claude/Codex session' "$scratch/stop.out"
rm -f "$dir/sessions/$$"
cc-stop > /dev/null
assert test -e "$scratch/stops"
echo 'PASS: cc-stop counts registered sessions'
