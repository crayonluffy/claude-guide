#!/usr/bin/env bash
# The owner must never block on its own ssh: a stopped or wedged ssh ignores
# SIGTERM, and 'wait' on it used to hang the owner - and with it recovery for
# every terminal. TERM first, KILL if it is still there after the grace.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }

# 1) A normal process ends on TERM, without waiting out the grace.
sleep 100 & p=$!
stamp=$(_recovery_process_identity "$p")
t0=$(date +%s); _recovery_stop_ssh "$p" "$stamp"; t1=$(date +%s)
assert test $((t1-t0)) -lt 3
if kill -0 "$p" 2>/dev/null; then echo 'FAIL: process survived' >&2; exit 1; fi
echo 'PASS: a responsive ssh is stopped at once'

# 2) A stopped process (TERM stays pending) is killed after the grace.
sleep 100 & p=$!
stamp=$(_recovery_process_identity "$p")
kill -STOP "$p"
t0=$(date +%s); _recovery_stop_ssh "$p" "$stamp"; t1=$(date +%s)
assert test $((t1-t0)) -lt 9
if kill -0 "$p" 2>/dev/null; then echo 'FAIL: stopped process survived' >&2; exit 1; fi
echo 'PASS: a stopped ssh is killed after the grace instead of hanging the owner'

# 3) A PID that is no longer ours (identity differs) is never signalled.
sleep 100 & p=$!
_recovery_stop_ssh "$p" 'not-its-start-time'
assert kill -0 "$p"
kill "$p"; wait "$p" 2>/dev/null || :
echo 'PASS: a reused PID is left alone'
