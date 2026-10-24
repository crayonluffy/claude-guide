#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$repo/scripts/claude-proxy.sh")"
assert() { "$@" || { echo "FAIL: $*" >&2;exit 1; }; }
if ! declare -F _recovery_desktop_step >/dev/null;then echo 'FAIL: desktop outage aggregation is missing';exit 1;fi
healthy='healthy|-|0|0|0|0|0|healthy|none'
failed='recovering|5|5|5|0|0|1|tunnel|lost'
s=$(_recovery_desktop_step '' "$healthy" "$healthy" 0 60)
s=$(_recovery_desktop_step "$s" "$failed" "$failed" 5 60)
assert test "${s##*|}" = lost
s=$(_recovery_desktop_step "$s" "$failed" "$healthy" 65 60)
assert test "${s##*|}" = prolonged
s=$(_recovery_desktop_step "$s" "$healthy" "$failed" 66 60)
assert test "${s##*|}" = none
s=$(_recovery_desktop_step "$s" "$healthy" "$healthy" 80 60)
assert test "${s##*|}" = restored
echo 'PASS: one desktop outage spans both providers; partial recovery cannot duplicate warnings'
scratch=$(mktemp -d);trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat > "$scratch/bin/notify-send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$DESKTOP_ARGS"
if [ "${DESKTOP_HANG:-0}" = 1 ];then
 printf '%s\n' "$$" > "$DESKTOP_PID"
 trap '' TERM
 exec sleep 30
fi
exit "${DESKTOP_EXIT:-0}"
STUB
cp "$scratch/bin/notify-send" "$scratch/bin/osascript";chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH" DESKTOP_ARGS="$scratch/args" DBUS_SESSION_BUS_ADDRESS=unix:path=/fake/test
uname() { echo Linux; }
assert test "$(_recovery_desktop_backend)" = linux
assert _recovery_desktop_send linux lost 'Claude and Codex'
assert grep -q -- '--urgency=normal' "$scratch/args"
assert grep -q 'Sessions stay open' "$scratch/args"
uname() { echo Darwin; }
assert test "$(_recovery_desktop_backend)" = macos
assert _recovery_desktop_send macos restored Codex
assert grep -q 'on run argv' "$scratch/args"
assert grep -q 'Retry any failed request' "$scratch/args"
(
 unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
 uname() { echo Linux; }
 assert test "$(_recovery_desktop_backend)" = unavailable
)
CLAUDE_DESKTOP_NOTIFICATIONS=off
assert test "$(_recovery_desktop_backend)" = off
before=$(wc -l < "$scratch/args")
_recovery_desktop_send off lost Codex || :
assert test "$(wc -l < "$scratch/args")" = "$before"
CLAUDE_DESKTOP_NOTIFICATIONS=auto
export DESKTOP_EXIT=9
if _recovery_desktop_send macos lost Codex;then echo 'FAIL: rejected native notification was called submitted';exit 1;fi
echo 'PASS: native Linux/macOS adapters, off switch, and delivery failure handling'
export DESKTOP_HANG=1 DESKTOP_PID="$scratch/native.pid"
started=$SECONDS
if _recovery_desktop_send linux lost Codex;then echo 'FAIL: hanging adapter reported success';exit 1;fi
assert test "$((SECONDS-started))" -lt 8
read -r native_pid < "$DESKTOP_PID"
if kill -0 "$native_pid" 2>/dev/null;then
 kill -KILL "$native_pid" 2>/dev/null || :
 wait "$native_pid" 2>/dev/null || :
 echo 'FAIL: timed-out native adapter survived';exit 1
fi
# Cancel just the notifier while an unrelated fake foreground application lives.
export DESKTOP_HANG=1 DESKTOP_PID="$scratch/cancel.pid"
sleep 10 & application=$!
application_stamp=$(_recovery_process_identity "$application")
_recovery_desktop_exec "$scratch/bin/notify-send" test & runner=$!
runner_stamp=$(_recovery_process_identity "$runner")
for ((n=0;n<50;n++));do [ -f "$DESKTOP_PID" ] && break;sleep .02;done
read -r native_pid < "$DESKTOP_PID"
_recovery_signal_owned "$runner" "$runner_stamp"
wait "$runner" 2>/dev/null || :
# A parent wrapper may exit first; the isolated adapter supervisor still has
# its two-second timeout and bounded cleanup grace.
for ((n=0;n<80;n++));do kill -0 "$native_pid" 2>/dev/null || break;sleep .05;done
assert kill -0 "$application"
if kill -0 "$native_pid" 2>/dev/null;then
 kill -KILL "$native_pid" 2>/dev/null || :
 echo 'FAIL: cancelled notifier left its native child alive';exit 1
fi
_recovery_signal_owned "$application" "$application_stamp" || :
wait "$application" 2>/dev/null || :
unset DESKTOP_HANG
# An EXIT trap entered with failure must still be able to identify its owned child.
if (trap 'if _recovery_process_identity "$$" >/dev/null;then echo ok > "$scratch/exit-identity";fi' EXIT; exit 1);then :;fi
assert test -s "$scratch/exit-identity"

# Exercise the real shared owner with isolated clocks/transports and fake OS submission.
mkdir "$scratch/worker";echo 0 > "$scratch/tick"
CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080
CLAUDE_WATCHDOG_INTERVAL=0 CLAUDE_WATCHDOG_FAILS=2 CLAUDE_WATCHDOG_NOTICE_AFTER=60
_listeners() { :; }
_port_bound() { return 1; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
ssh() { exec sleep 100; }
_wd_sleep() { :; }
_recovery_now() {
 local tick;read -r tick < "$scratch/tick";echo $((tick+1)) > "$scratch/tick"
 case "$tick" in 0) echo 0;;1) echo 5;;2) echo 65;;*) echo 80;;esac
}
_recovery_probe() {
 local tick;read -r tick < "$scratch/tick"
 if [ "$tick" -ge 4 ] && [ "$1" = codex ];then touch "$scratch/worker/stopped";fi
 if [ "$tick" = 1 ] || [ "$tick" -ge 4 ];then echo 'healthy|0|200|403|healthy';else echo 'proxy|0|407|000|proxy';fi
}
_recovery_desktop_backend() { echo linux; }
_recovery_desktop_send() { printf '%s\n' "$2" >> "$scratch/desktop.calls"; }
_recovery_worker "$scratch/worker" > "$scratch/worker.log"
assert test -s "$scratch/desktop.calls"
assert test "$(cat "$scratch/desktop.calls")" = "$(printf 'lost\nprolonged\nrestored')"
assert grep -q 'submitted.*restored' "$scratch/worker/desktop.status"
echo 'PASS: real owner emits three desktop alerts across two providers and records submission status'
# Default demo stays silent on the desktop; opt-in demo labels every real OS alert.

_recovery_demo_sleep() { :; }
_recovery_desktop_backend() { echo linux; }
_recovery_desktop_send() { printf '%s|%s\n' "$2" "${4:-0}" >> "$scratch/demo-alerts"; }
proxy-test prolonged --fast > "$scratch/demo-default"
assert test ! -e "$scratch/demo-alerts"
proxy-test prolonged --fast --desktop > "$scratch/demo-native"
assert test "$(cat "$scratch/demo-alerts")" = "$(printf 'lost|1\nprolonged|1\nrestored|1')"
assert grep -q 'Real desktop' "$scratch/demo-native"
echo 'PASS: opt-in desktop demo is labelled and does not change default simulation isolation'
# A rejected desktop service must not break network recovery or change the terminal state.
_recovery_desktop_send() { return 1; }
_recovery_now() {
 local tick;read -r tick < "$scratch/tick";echo $((tick+1)) > "$scratch/tick"
 case "$tick" in 0) echo 0;;1) echo 5;;2) echo 65;;*) echo 80;;esac
}
rm -f "$scratch/worker/stopped";echo 0 > "$scratch/tick"
_recovery_worker "$scratch/worker" > "$scratch/failed-ui-worker.log"
assert grep -q 'failed.*restored' "$scratch/worker/desktop.status"
assert test "$(cut -d'|' -f1 "$scratch/worker/codex.state")" = healthy
echo 'PASS: notification failures and headless desktop cannot stop proxy recovery'
