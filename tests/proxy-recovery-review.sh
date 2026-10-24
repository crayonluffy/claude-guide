#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"   # never the real recovery state
mkdir -p "$scratch/empty/lock"
_recovery_claim "$scratch/empty" "$$" || { echo 'FAIL: abandoned empty lock blocks startup';exit 1; }
# Simulate a concurrent replacement after an observer saw the stale owner.
mkdir -p "$scratch/race/lock";printf '99999999\nbogus\n' > "$scratch/race/lock/owner"
real_pid=$$; real_stamp=$(_recovery_process_identity "$$")
eval "$(declare -f _recovery_owner_pid | sed '1s/_recovery_owner_pid/_real_owner_pid/')"
_recovery_owner_pid() {
 if [ ! -e "$scratch/injected" ];then
  touch "$scratch/injected";printf '%s\n%s\n' "$real_pid" "$real_stamp" > "$1/lock/owner";return 1
 fi
 _real_owner_pid "$@"
}
if _recovery_claim "$scratch/race" "$$";then echo 'FAIL: concurrent replacement owner was stolen';exit 1;fi
[ "$(_real_owner_pid "$scratch/race")" = "$$" ]
echo 'PASS: abandoned lock and concurrent stale-owner replacement safety'
# Load the real compatibility functions and test the legacy PID migration guard.
eval "$(sed -n '/^# Compatibility entry points/,/^# PIDs of Claude/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}" | sed '$d')"
eval "$(declare -f _real_owner_pid | sed '1s/_real_owner_pid/_recovery_owner_pid/')"
_proc_name() { ps -p "$1" -o comm= | tr -d ' '; }
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080
CLAUDE_TUNNEL_PIDFILE="$scratch/old-watchdog.pid";printf '%s\n' "$$" > "$CLAUDE_TUNNEL_PIDFILE"
if ! declare -F _legacy_watchdog_pid >/dev/null;then echo 'FAIL: legacy watchdog is ignored';exit 1;fi
[ "$(_legacy_watchdog_pid)" = "$$" ]
_ssh_listeners() { :; }
_recovery_signal_owned() { echo "$1" >> "$scratch/signals"; }
if _legacy_watchdog_stop;then echo 'FAIL: unverified old shell was accepted';exit 1;fi
[ ! -e "$scratch/signals" ]
echo 'PASS: legacy watchdog detected; reused shell PID cannot authorize termination'
# Test interruption cleanup on the native foreground function path.
eval "$(sed -n '/^proxy-up() {/,/^cc-stop() {/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}" | sed '$d')"
proxy-up() { :; }
claude() { trap -p INT > "$scratch/foreground.trap";return 130; }
CLAUDE_TUNNEL_WATCHDOG=0
trap ':' INT
saved=$(trap -p INT)
if _launch_via_proxy Claude claude hint skip --safe;then code=0;else code=$?;fi
[ "$code" = 130 ]
[ "$(trap -p INT)" = "$saved" ]
grep -q _recovery_unsubscribe "$scratch/foreground.trap" || { echo 'FAIL: Ctrl+C has no subscriber cleanup';exit 1;}
trap - INT
echo 'PASS: Ctrl+C cleanup installed; caller interrupt trap and application status preserved'
if ! declare -F _recovery_port_conflict >/dev/null;then echo 'FAIL: live port conflicts are not classified';exit 1;fi
_listeners() { echo 99999999; }
_recovery_port_conflict 123 || { echo 'FAIL: foreign port owner was ignored';exit 1; }
if _recovery_port_conflict 99999999;then echo 'FAIL: owned port classified as foreign';exit 1;fi
echo 'PASS: owned and foreign port classification'
# Actual concurrent shells contend for the same empty lease; exactly one wins.
mkdir -p "$scratch/contest"
for ((n=0;n<12;n++));do
 (
  self=$BASHPID
  if _recovery_claim "$scratch/contest" "$self";then
   printf '%s\n' "$self" > "$scratch/contest/winner.$self"
   sleep 2
  fi
 ) &
done
wait
count=$(find "$scratch/contest" -name 'winner.*' -type f | wc -l | tr -d ' ')
[ "$count" = 1 ] || { echo "FAIL: $count concurrent owners won";exit 1; }
echo 'PASS: twelve simultaneous shells elect exactly one owner'
