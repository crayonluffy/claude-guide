#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$repo/scripts/claude-proxy.sh")"
scratch=$(mktemp -d)
sub='' stamp=''
cleanup() {
    [ -z "$sub" ] || _recovery_unsubscribe "$sub" "$stamp"
    rm -rf "$scratch"
}
trap cleanup EXIT
CLAUDE_SSH_HOST=test-node
unset CLAUDE_TERMINAL_NOTIFICATIONS
printf 'healthy|-|0|0|0|0|0|healthy|none\n' > "$scratch/claude.state"
sub=$(_recovery_subscribe "$scratch" claude 2>"$scratch/notices")
stamp=$(_recovery_process_identity "$sub")
sleep 1.1
printf 'recovering|5|5|5|0|0|1|tunnel|lost\n' > "$scratch/claude.state"
sleep 1.1
printf 'healthy|-|10|5|0|0|2|healthy|restored\n' > "$scratch/claude.state"
sleep 1.1
[ ! -s "$scratch/notices" ] || { cat "$scratch/notices"; echo 'FAIL: brief outage interrupted terminal' >&2; exit 1; }
# A subscriber can miss the original prolonged event, but still sees the phase.
printf 'prolonged|20|90|90|0|0|4|tunnel|progress\n' > "$scratch/claude.state"
sleep 1.1
printf 'prolonged|20|120|120|0|0|5|tunnel|progress\n' > "$scratch/claude.state"
sleep 1.1
printf 'healthy|-|125|120|0|0|6|healthy|restored\n' > "$scratch/claude.state"
sleep 1.1
[ "$(grep -c 'session has not been terminated' "$scratch/notices" || :)" = 1 ]
[ "$(grep -c 'Proxy connection restored' "$scratch/notices" || :)" = 1 ]
[ "$(grep -c 'Proxy recovery is still in progress' "$scratch/notices" || :)" = 0 ]
_recovery_unsubscribe "$sub" "$stamp"
sub=''
echo 'PASS: quiet real subscriber suppresses brief drops, warns once and restores once'

CLAUDE_TERMINAL_NOTIFICATIONS=off
sub=$(_recovery_subscribe "$scratch" claude 2>"$scratch/off.notices")
stamp=$(_recovery_process_identity "$sub")
sleep 1.1
printf 'prolonged|130|200|200|0|0|7|tunnel|prolonged\n' > "$scratch/claude.state"
sleep 1.1
[ ! -s "$scratch/off.notices" ]
printf 'auth|200|refused\n' > "$scratch/ssh.status"
printf '777|test-process|18080\n' > "$scratch/takeover"
printf 'prolonged|130|205|205|0|0|8|conflict|takeover\n' > "$scratch/claude.state"
sleep 1.1
grep -q 'SSH login to test-node was refused' "$scratch/off.notices"
grep -q 'Another program (test-process, PID 777) took proxy port 18080' "$scratch/off.notices"
echo 'PASS: off mode silences routine notices while retaining actionable warnings'

check() {
    actual=$(_recovery_terminal_step "$1" "$2" "$3" "$4")
    [ "$actual" = "$5" ] || { echo "FAIL: $* -> $actual" >&2; exit 1; }
}
check quiet recovering lost 0 '0|none'
check quiet healthy restored 0 '0|none'
check quiet prolonged prolonged 0 '1|prolonged'
check quiet prolonged progress 1 '1|none'
check quiet healthy restored 1 '0|restored'
check quiet healthy restored 0 '0|none'
check quiet prolonged progress 0 '1|prolonged'
check quiet prolonged takeover 0 '0|takeover'
check off prolonged prolonged 0 '0|none'
check off healthy restored 0 '0|none'
check off recovering takeover 0 '0|takeover'
check verbose recovering lost 0 '0|lost'
check verbose prolonged progress 0 '0|progress'
check verbose healthy restored 0 '0|restored'
check invalid recovering lost 0 '0|none'
echo 'PASS: terminal policies preserve critical alerts and support verbose/off modes'
