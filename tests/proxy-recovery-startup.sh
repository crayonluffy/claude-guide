#!/usr/bin/env bash
set -eu
# A freshly started ssh that is still connecting is not an outage: no "lost"
# notice and no kill until CLAUDE_WATCHDOG_STARTUP_GRACE has passed - but an ssh
# that never comes up is still restarted after it.
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080
CLAUDE_WATCHDOG_INTERVAL=0 CLAUDE_WATCHDOG_FAILS=2 CLAUDE_WATCHDOG_NOTICE_AFTER=60 CLAUDE_WATCHDOG_STARTUP_GRACE=20
_recovery_desktop_backend() { echo linux; }
_recovery_desktop_send() { printf '%s\n' "$2" >> "$scratch/desktop"; }
_listeners() { :; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
ssh() { echo x >> "$scratch/starts"; exec sleep 100; }
_wd_sleep() { :; }
# Fake clock: 0, 5, 10 ... one step per pass.
_recovery_now() { local t; read -r t < "$scratch/t"; echo $((t+5)) > "$scratch/t"; echo "$t"; }
_now() { local t; read -r t < "$scratch/t"; echo $((t-5)); }
# Kills while running count; the shutdown kill after 'stopped' is expected.
eval "$(declare -f _recovery_signal_owned | sed '1s/_recovery_signal_owned/_real_signal_owned/')"
_recovery_signal_owned() { [ -e "$dir/stopped" ] || echo "$(_now)" >> "$scratch/kills"; _real_signal_owned "$@"; }

# 1) Slow link: the tunnel answers only from t=15.
dir="$scratch/slow"; mkdir "$dir"; echo 0 > "$scratch/t"; rm -f "$scratch/kills" "$scratch/starts" "$scratch/desktop"
_recovery_probe() {
    [ "$(_now)" -lt 40 ] || touch "$dir/stopped"
    if [ "$(_now)" -lt 15 ]; then echo 'tunnel|7|000|000|tunnel'; else echo 'healthy|0|200|404|healthy'; fi
}
_recovery_worker "$dir" > "$scratch/slow.log"
assert test ! -e "$scratch/kills"
assert test "$(wc -l < "$scratch/starts" | tr -d ' ')" = 1
if grep -q 'connection lost' "$scratch/slow.log"; then echo 'FAIL: startup reported as an outage' >&2; exit 1; fi
assert test "$(cut -d'|' -f1 "$dir/claude.state")" = healthy
assert test ! -e "$scratch/desktop"
echo 'PASS: Bash slow start - no false outage and no kill while ssh is connecting'

# 2) Hung ssh: never answers, so it is restarted once the grace is over.
dir="$scratch/hung"; mkdir "$dir"; echo 0 > "$scratch/t"; rm -f "$scratch/kills" "$scratch/starts" "$scratch/desktop"
_recovery_probe() { [ "$(_now)" -lt 60 ] || touch "$dir/stopped"; echo 'tunnel|7|000|000|tunnel'; }
_recovery_worker "$dir" > "$scratch/hung.log"
assert test -s "$scratch/kills"
assert test "$(head -1 "$scratch/kills")" -ge 20
assert grep -q 'connection lost' "$scratch/hung.log"
assert test "$(head -1 "$scratch/desktop")" = lost
echo 'PASS: Bash hung ssh is still restarted after the startup grace'
