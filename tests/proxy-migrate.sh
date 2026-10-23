#!/usr/bin/env bash
# A tunnel started by an older profile has ssh on our ports but no owner that can
# heal it. It is replaced automatically by one with an owner, on the same ports.
# A foreign program on those ports is never touched, and a live owner is left alone.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state" CLAUDE_TUNNEL_LOG="$scratch/tunnel.log"
export CLAUDE_TUNNEL_WATCHDOG=1 CLAUDE_WATCHDOG_STARTUP_GRACE=20
CLAUDE_SSH_HOST=jp CLAUDE_SSH_USER= CLAUDE_SSH_PORT=22 CLAUDE_SSH_KEY= CLAUDE_REMOTE_PROXY_PORT=8888
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080

# Fake world: the old tunnel answers as $scratch/health says; stopping it frees the
# ports; a new owner exists once the worker has been started.
_legacy_watchdog_pid() { [ -e "$scratch/legacy" ] && echo 77 || return 1; }
_tunnel_health() { cat "$scratch/health"; }
_port_in_use() { [ ! -e "$scratch/freed" ]; }
tunnel-stop() { echo stop >> "$scratch/stops"; touch "$scratch/freed"; }
_recovery_worker() { touch "$scratch/spawned"; }
_recovery_owner_pid() { [ -e "$scratch/spawned" ] || return 1; echo 4242; }
reset() { rm -f "$scratch/freed" "$scratch/spawned" "$scratch/stops" "$scratch/legacy" "$scratch/err"; }

# 1) Healthy old tunnel: replaced on the same ports, and an owner now runs.
reset; echo 'ok 4242 ssh 8080' > "$scratch/health"
dir=$(_recovery_owner_start 2>"$scratch/err")
assert test "$(wc -l < "$scratch/stops" | tr -d ' ')" = 1
assert test -e "$scratch/spawned"
assert grep -q '\[Upgrade\]' "$scratch/err"
assert test "$dir" = "$(_recovery_identity)"
assert test "$CLAUDE_HTTP_PORT" = 8080
echo 'PASS: an old healthy tunnel is replaced automatically on the same ports'

# 2) Stale old tunnel (ssh alive, not answering): replaced too.
reset; echo 'stale 4242 ssh' > "$scratch/health"
_recovery_owner_start >/dev/null 2>"$scratch/err"
assert test -e "$scratch/spawned"
assert test "$(wc -l < "$scratch/stops" | tr -d ' ')" = 1
echo 'PASS: a stale old tunnel is replaced automatically'

# 3) Old watchdog whose ssh is currently down: also migrated, not refused.
reset; touch "$scratch/legacy"; echo 'down' > "$scratch/health"
_recovery_owner_start >/dev/null 2>"$scratch/err"
assert test -e "$scratch/spawned"
assert test "$(wc -l < "$scratch/stops" | tr -d ' ')" = 1
echo 'PASS: an old watchdog with ssh down is migrated'

# 4) A foreign program holds the port: refused, nothing stopped, nothing spawned.
reset; echo 'foreign 99 nginx 8080' > "$scratch/health"
rc=0; _recovery_owner_start >/dev/null 2>"$scratch/err" || rc=$?
assert test "$rc" -ne 0
assert test ! -e "$scratch/stops"
assert test ! -e "$scratch/spawned"
assert grep -q 'used by another program' "$scratch/err"
echo 'PASS: a foreign program on the ports is never touched'

# 5) A live owner is adopted as it is: no migration, no stop.
reset; touch "$scratch/spawned"; echo 'ok 4242 ssh 8080' > "$scratch/health"
_recovery_owner_start >/dev/null 2>"$scratch/err"
assert test ! -e "$scratch/stops"
assert test ! -s "$scratch/err"
echo 'PASS: a live owner is left alone'
