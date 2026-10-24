#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$repo/scripts/claude-proxy.sh")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
if ! declare -F _recovery_step >/dev/null; then echo 'FAIL: recovery state reducer is missing'; exit 1; fi
field() { printf '%s\n' "$1" | cut -d '|' -f "$2"; }
s=$(_recovery_step '' 'healthy|0|200|401|ok' 0 60)
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 5 60)
assert test "$(field "$s" 1)" = recovering
assert test "$(field "$s" 9)" = lost
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 64 60)
assert test "$(field "$s" 1)" = recovering
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 65 60)
assert test "$(field "$s" 9)" = prolonged
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 70 60)
assert test "$(field "$s" 9)" = none
s=$(_recovery_step "$s" 'healthy|0|200|429|ok' 75 60)
assert test "$(field "$s" 9)" = restored
s=$(_recovery_step "$s" 'healthy|0|200|500|ok' 1 60)
assert test "$(field "$s" 3)" = 75
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export XDG_STATE_HOME="$scratch/state"   # never the real recovery state
curl() {
 printf '%s\n' "$*" >> "$scratch/args"
 case "$*" in *--socks5-hostname*) printf '000 200'; return 0;; esac
 printf '%s' "$HTTP_RESULT"; return "$HTTP_RC"
}
HTTP_RESULT='200 403'; HTTP_RC=0
s=$(_recovery_probe claude 18080 11080)
assert test "$(field "$s" 1)" = healthy
assert grep -q -- '--noproxy' "$scratch/args"
assert grep -q -- '--proxy http://127.0.0.1:18080' "$scratch/args"
HTTP_RESULT='407 000'; HTTP_RC=56
s=$(_recovery_probe codex 18080 11080)
assert test "$(field "$s" 1)" = proxy
HTTP_RESULT='000 000'; HTTP_RC=52
s=$(_recovery_probe claude 18080 11080)
assert test "$(field "$s" 1)" = proxy
assert grep -q -- '--socks5-hostname 127.0.0.1:11080' "$scratch/args"
echo 'PASS: Bash recovery transitions, backwards time, and explicit proxy probes'
if ! declare -F _recovery_claim >/dev/null; then echo 'FAIL: shared recovery ownership is missing'; exit 1; fi
owner="$scratch/owner"; mkdir "$owner"
assert _recovery_claim "$owner" "$$"
if _recovery_claim "$owner" "$$"; then echo 'FAIL: second owner acquired an occupied lock'; exit 1; fi
assert test "$(_recovery_owner_pid "$owner")" = "$$"
printf '99999999\nbogus\n' > "$owner/lock/owner"
assert _recovery_claim "$owner" "$$"
printf 'recovering|5|10|5|2|12|1|proxy|lost\n' > "$owner/claude.state"
assert test "$(_recovery_status "$owner" claude | cut -d '|' -f1)" = recovering
# A stale PID identity must not authorize a signal to the live test process.
if _recovery_signal_owned "$$" bogus; then echo 'FAIL: stale process identity accepted'; exit 1; fi
printf 'recovering|5|10|5|0|0|1|tunnel|lost\n' > "$scratch/state"
assert test "$(_recovery_retry_record "$(cat "$scratch/state")" 2 30 | cut -d '|' -f5)" = 2
echo 'PASS: Bash shared ownership, stale identity, and recovery status'
# The actual worker runs with fake transport/process adapters in a private directory.
# A proxy-only outage must never restart SSH or clear inherited proxy variables.
_wd_sleep() { sleep .02; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(-L '8080:127.0.0.1:8888' -D 1080 example); }
ssh() {
 printf '%s\n' "$*" >> "$scratch/ssh.calls"
 trap 'sleep .4; : > "$scratch/ssh.terminated"; exit 0' TERM
 while :; do sleep .1; done
}
_recovery_probe() { echo 'proxy|0|407|000|proxy'; }
_listeners() { :; }
_port_bound() { return 1; }
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080
CLAUDE_DESKTOP_NOTIFICATIONS=off
CLAUDE_WATCHDOG_INTERVAL=.02 CLAUDE_WATCHDOG_FAILS=2
export HTTPS_PROXY=http://127.0.0.1:8080
mkdir "$scratch/worker"
(_recovery_worker "$scratch/worker") & worker=$!
for ((n=0;n<100;n++)); do [ -s "$scratch/worker/codex.state" ] && break; sleep .02; done
assert test -s "$scratch/worker/codex.state"
sleep .15
assert test "$(wc -l < "$scratch/ssh.calls" | tr -d ' ')" = 1
assert test "$HTTPS_PROXY" = http://127.0.0.1:8080
assert test "$(cut -d'|' -f8 "$scratch/worker/claude.state")" = proxy
assert grep -q 'BatchMode=yes.*8080:127.0.0.1:8888.*1080' "$scratch/ssh.calls"
_recovery_owner_stop "$scratch/worker"
wait "$worker" || :
assert test -f "$scratch/ssh.terminated"
sleep .05
assert test "$(wc -l < "$scratch/ssh.calls" | tr -d ' ')" = 1
assert test ! -e "$scratch/worker/lock"
echo 'PASS: real Bash worker preserves ports/settings during proxy failure and stops without respawn'
assert declare -F _recovery_subscribe
echo 'PASS: Bash subscriber interface'
# Load real launch integration without profile initialization.
eval "$(sed -n '/^proxy-up() {/,/^cc-stop() {/p' "$repo/scripts/claude-proxy.sh" | sed '$d')"
_killswitch_check() { :; }   # covered by tests/proxy-killswitch.sh
tunnel-start() { :; }
_tunnel_health() { echo 'ok 123 ssh 8080'; }
proxy-on() { export HTTPS_PROXY=http://127.0.0.1:8080; }
_verify_proxy_ip() { echo unexpected-ip-probe >> "$scratch/unexpected"; }
claude() { printf '%s\n' "$@" > "$scratch/app.args"; return 17; }
CLAUDE_TUNNEL_WATCHDOG=0
if _launch_via_proxy Claude claude hint skip --no-verify --safe 'hello world'; then echo 'FAIL: dead proxy allowed launch';exit 1;fi
assert test ! -e "$scratch/app.args"
_recovery_probe() { echo 'healthy|0|200|403|healthy'; }
if _launch_via_proxy Claude claude hint skip --no-verify --safe 'hello world'; then code=0; else code=$?; fi
assert test "$code" = 17
assert test "$(cat "$scratch/app.args")" = 'hello world'
assert test ! -e "$scratch/unexpected"
echo 'PASS: Bash mandatory preflight, native argument preservation, and application exit code'
# Real subscriber receives each generation once and never mutates shared status.
mkdir "$scratch/notifications"
printf 'healthy|-|0|0|0|0|0|healthy|none\n' > "$scratch/notifications/claude.state"
sub=$(_recovery_subscribe "$scratch/notifications" claude 2>"$scratch/notices")
substamp=$(_recovery_process_identity "$sub")
sleep 1.1
printf 'recovering|5|5|5|0|0|1|tunnel|lost\n' > "$scratch/notifications/claude.state"
sleep 1.1
printf 'prolonged|5|65|65|2|70|2|tunnel|prolonged\n' > "$scratch/notifications/claude.state"
sleep 2.1
_recovery_unsubscribe "$sub" "$substamp"
assert test "$(grep -c 'session has not been terminated' "$scratch/notices")" = 1
assert test "$(grep -c 'Proxy connection lost' "$scratch/notices")" = 1
assert test "$(cut -d'|' -f1 "$scratch/notifications/claude.state")" = prolonged
echo 'PASS: real Bash subscriber de-duplicates prolonged warning and leaves shared state intact'
assert declare -F proxy-test
_recovery_demo_sleep() { :; }
curl() { echo 'FAIL: demo called real transport' >&2;return 90; }
ssh() { echo 'FAIL: demo called SSH' >&2;return 90; }
for scenario in recover prolonged; do
 proxy-test "$scenario" --fast > "$scratch/demo.$scenario"
 assert grep -q 'Proxy connection lost' "$scratch/demo.$scenario"
 assert grep -q 'Proxy connection restored' "$scratch/demo.$scenario"
 assert grep -q 'simulated retry' "$scratch/demo.$scenario"
 assert test "$(grep -vc '^\[SIMULATION\]' "$scratch/demo.$scenario" || :)" = 0
done
assert test "$(grep -c 'session has not been terminated' "$scratch/demo.prolonged")" = 1
assert grep -q 't=75.*retry' "$scratch/demo.prolonged"
if proxy-test unknown > /dev/null;then echo 'FAIL: invalid demo accepted';exit 1;fi
echo 'PASS: Bash isolated simulations and retries beyond grace period'
