#!/usr/bin/env bash
set -eu
# A loop whose owner record names a dead PID (zsh with a trap set in 2.11.1 and
# older) is invisible to tunnel-stop. The next start must still make it leave,
# even while it is in its idle sleep, before a new owner takes the ports.
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'kill "$wpid" 2>/dev/null || :; rm -rf "$scratch"' EXIT
CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080 CLAUDE_WATCHDOG_INTERVAL=1 CLAUDE_WATCHDOG_IDLE_INTERVAL=600
_recovery_desktop_backend() { echo off; }
_listeners() { :; }
_port_bound() { return 1; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
ssh() { exec sleep 100; }
_wd_sleep() { sleep "$1"; }
_recovery_probe() { echo 'healthy|0|200|404|healthy'; }
dir="$scratch/main"; mkdir "$dir"
( _recovery_worker "$dir" ) >/dev/null 2>&1 & wpid=$!
i=0; while [ ! -e "$dir/lock/owner" ] && [ "$i" -lt 50 ]; do sleep .1; i=$((i+1)); done
sleep 1   # now in the 600 s idle sleep
# What 2.11.1 under zsh left behind: a record for a helper that already exited.
sh -c 'exit 0' & dead=$!; wait "$dead"
printf '%s\n%s\n' "$dead" 'gone' > "$dir/lock/owner"
assert kill -0 "$wpid"
! _recovery_owner_pid "$dir" >/dev/null || { echo 'FAIL: stale record still looks live' >&2; exit 1; }
_recovery_drain_stale "$dir" 2>/dev/null
i=0; while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep .1; i=$((i+1)); done
if kill -0 "$wpid" 2>/dev/null; then echo 'FAIL: the hidden loop is still running' >&2; exit 1; fi
assert test ! -e "$dir/sessions/$$"
echo 'PASS: a loop hidden behind a dead owner record leaves on the next start'
