#!/usr/bin/env bash
# Real process boundaries and recovery leases; all state is temporary.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
source_file="$repo/scripts/claude-proxy.sh"
helper="$repo/scripts/lib/operations.sh"
[ -r "$helper" ] || { echo 'FAIL: operation coordinator is missing' >&2; exit 1; }
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$source_file")"
. "$helper"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
await_file() { local n=0; while [ ! -e "$1" ] && [ "$n" -lt 800 ]; do sleep .025; n=$((n+1)); done; assert test -e "$1"; }
worker_shell=${PROXY_OPERATION_SHELL:-bash}
test_file="$repo/tests/proxy-operations.sh"
if [ "${1:-}" = child ]; then
    scratch=$2; mode=$3; export XDG_STATE_HOME="$scratch/state"
    critical() { echo "enter-$mode" >> "$scratch/order"; touch "$scratch/$mode.entered"; [ "$mode" != first ] || await_file "$scratch/release"; echo "leave-$mode" >> "$scratch/order"; }
    hold() { touch "$scratch/holder.entered"; await_file "$scratch/holder.release"; }
    early() { _proxy_operation_release; "$worker_shell" -f "$test_file" child "$scratch" holder >"$scratch/holder.out" 2>&1 & echo $! > "$scratch/holder.pid"; await_file "$scratch/holder.entered"; }
    case "$mode" in
        first|second|third) touch "$scratch/$mode.attempted"; _proxy_operation_run critical ;;
        holder) _proxy_operation_run hold ;;
        early) _proxy_operation_run early; touch "$scratch/early.done" ;;
        crash) _proxy_operation_run sh -c 'kill -KILL "$PPID"' ;;
        timeout) sleep() { :; }; if _proxy_operation_run true; then echo 'FAIL: entered an occupied operation'; exit 1; fi ;;
    esac
    exit
fi
scratch=$(mktemp -d); export XDG_STATE_HOME="$scratch/state"
cleanup() { local f; for f in "$scratch/first.pid" "$scratch/second.pid" "$scratch/third.pid" "$scratch/holder.pid"; do if [ -r "$f" ]; then kill "$(cat "$f")" 2>/dev/null || :; fi; done; rm -rf "$scratch"; }
trap cleanup EXIT
"$worker_shell" -f "$test_file" child "$scratch" first >"$scratch/first.out" 2>&1 & first=$!; echo "$first" > "$scratch/first.pid"
await_file "$scratch/first.entered"
"$worker_shell" -f "$test_file" child "$scratch" second >"$scratch/second.out" 2>&1 & second=$!; echo "$second" > "$scratch/second.pid"
await_file "$scratch/second.attempted"
sleep .2; assert test ! -e "$scratch/second.entered"
touch "$scratch/release"; wait "$first"; wait "$second"
assert test "$(cat "$scratch/order" | tr '\n' ' ')" = 'enter-first leave-first enter-second leave-second '
echo 'PASS: unrelated processes serialize operations'
inner() { assert _proxy_operation_owned; }
nested() { _proxy_operation_run inner; result=$(_proxy_operation_run inner; echo nested); assert test "$result" = nested; }
_proxy_operation_run nested
assert test ! -e "$(_proxy_operation_dir)/lock/owner"
echo 'PASS: nested functions and command substitutions reuse the live lease'
fail_operation() { return 17; }
if _proxy_operation_run fail_operation; then echo 'FAIL: failure status was lost'; exit 1; else rc=$?; fi
assert test "$rc" = 17
_proxy_operation_run inner
assert test ! -e "$(_proxy_operation_dir)/lock/owner"
echo 'PASS: failure releases the lease and preserves status'
"$worker_shell" -f "$test_file" child "$scratch" early >"$scratch/early.out" 2>&1 & early_pid=$!
await_file "$scratch/early.done"; wait "$early_pid"
"$worker_shell" -f "$test_file" child "$scratch" third >"$scratch/third.out" 2>&1 & third=$!; echo "$third" > "$scratch/third.pid"
await_file "$scratch/third.attempted"
sleep .2; assert test ! -e "$scratch/third.entered"
"$worker_shell" -f "$test_file" child "$scratch" timeout >"$scratch/timeout.out" 2>&1
assert grep -qi 'operation' "$scratch/timeout.out"
touch "$scratch/holder.release"; wait "$third"
echo 'PASS: early release admits another process; old cleanup cannot release its lease'
# The current process also releases and reacquires while the outer runner exists.
reenter() { local old="$_CLAUDE_OPERATION_TOKEN"; _proxy_operation_release; _proxy_operation_run inner; _proxy_operation_release "$old"; }
_proxy_operation_run reenter
_proxy_operation_release; _proxy_operation_release
"$worker_shell" -f "$test_file" child "$scratch" crash >"$scratch/crash.out" 2>&1 & crash_pid=$!
wait "$crash_pid" 2>/dev/null || :
_proxy_operation_run inner
assert test ! -e "$(_proxy_operation_dir)/lock/owner"
echo 'PASS: idempotent release and crashed-owner recovery'
# A delayed inherited releaser must not affect a new lease in this same shell.
eval "$(sed -n '/^_recovery_owner_pid() {/,/^}/p' "$source_file" | sed '1s/_recovery_owner_pid/_operation_real_owner_pid/')"
_recovery_owner_pid() {
    if [ "${delay_release:-0}" = 1 ] && [ ! -e "$scratch/release.delayed" ]; then
        touch "$scratch/release.delayed"; await_file "$scratch/release.resume"
    fi
    _operation_real_owner_pid "$@"
}
replacement() { touch "$scratch/release.resume"; wait "$delayed_pid"; assert _proxy_operation_owned; }
simultaneous_release() {
    (delay_release=1; _proxy_operation_release; touch "$scratch/release.finished") & delayed_pid=$!
    await_file "$scratch/release.delayed"
    _proxy_operation_release
    _proxy_operation_run replacement
}
_proxy_operation_run simultaneous_release
eval "$(sed -n '/^_recovery_owner_pid() {/,/^}/p' "$source_file")"
echo 'PASS: delayed inherited release cannot revoke a replacement in the same shell'
# No coordinator traps may replace a caller's signal/exit handlers.
trap 'echo caller-int >/dev/null' INT
trap 'echo caller-term >/dev/null' TERM
before=$(trap)
_proxy_operation_run inner
after=$(trap)
assert test "$before" = "$after"
assert test "$(dirname "$(_proxy_operation_dir)")" = "$(dirname "$(_recovery_root)")"
assert test ! -e "$(_recovery_root)/operations"
echo 'PASS: caller traps and tunnel enumeration remain untouched'
