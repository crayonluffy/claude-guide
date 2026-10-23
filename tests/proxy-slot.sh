#!/usr/bin/env bash
# Slot-keyed recovery owner: one state directory per user and slot ('main'),
# whatever host or ports this terminal's settings happen to name, and a tunnel
# record that a live owner publishes and every terminal adopts.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"

# 1) The directory depends on the user and slot only - not on host or ports.
CLAUDE_SSH_HOST=jpvpn CLAUDE_SSH_USER= CLAUDE_SSH_PORT=22 CLAUDE_SSH_KEY=''
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080 CLAUDE_REMOTE_PROXY_PORT=8888
a=$(_recovery_identity)
CLAUDE_SSH_HOST=other CLAUDE_HTTP_PORT=8081 CLAUDE_SOCKS_PORT=1081 CLAUDE_REMOTE_PROXY_PORT=9999
b=$(_recovery_identity)
assert test "$a" = "$b"
assert test "$a" = "$scratch/state/claude-proxy/recovery/main"
mode=$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$a")
assert test "$mode" = 0o700
echo 'PASS: owner directory is per user and slot, independent of host and ports'

# 2) A live owner publishes its tunnel; a terminal with stale settings adopts it.
dir=$a
CLAUDE_SSH_HOST=jpvpn CLAUDE_SSH_USER=alice CLAUDE_SSH_PORT=22 CLAUDE_SSH_KEY=/keys/id
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080 CLAUDE_REMOTE_PROXY_PORT=8888
_recovery_record_write "$dir"
_recovery_owner_pid() { echo "$$"; }
CLAUDE_SSH_HOST=stale CLAUDE_SSH_USER=bob CLAUDE_SSH_PORT=2222 CLAUDE_SSH_KEY=''
CLAUDE_HTTP_PORT=8081 CLAUDE_SOCKS_PORT=1081 CLAUDE_REMOTE_PROXY_PORT=9999
_recovery_adopt "$dir"
assert test "$CLAUDE_SSH_HOST" = jpvpn
assert test "$CLAUDE_SSH_USER" = alice
assert test "$CLAUDE_SSH_PORT" = 22
assert test "$CLAUDE_SSH_KEY" = /keys/id
assert test "$CLAUDE_HTTP_PORT" = 8080
assert test "$CLAUDE_SOCKS_PORT" = 1080
assert test "$CLAUDE_REMOTE_PROXY_PORT" = 8888
echo 'PASS: a terminal with stale settings adopts the live owner tunnel'

# 3) No live owner: nothing is adopted, so a stale record cannot override settings.
_recovery_owner_pid() { return 1; }
CLAUDE_HTTP_PORT=8090
_recovery_adopt "$dir" || :
assert test "$CLAUDE_HTTP_PORT" = 8090
echo 'PASS: without a live owner the terminal keeps its own settings'

# 4) The record is data, never code: shell syntax in a value is inert.
payload='$(touch '"$scratch"'/pwned)'
CLAUDE_SSH_HOST=$payload
_recovery_record_write "$dir"
_recovery_owner_pid() { echo "$$"; }
CLAUDE_SSH_HOST=placeholder
_recovery_adopt "$dir"
assert test ! -e "$scratch/pwned"
assert test "$CLAUDE_SSH_HOST" = "$payload"
echo 'PASS: tunnel record values are read as literal text'
