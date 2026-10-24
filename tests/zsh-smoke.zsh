#!/usr/bin/env zsh
# The profile is sourced by zsh on macOS (the default shell) as well as bash.
# Source it for real in an isolated HOME and drive the recovery owner's pieces,
# so a bash-only construct (word splitting, read <<<, arrays, $BASHPID ...)
# fails here instead of on a user's Mac.
repo=${0:A:h:h}
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" CLAUDE_PROXY_CONF="$scratch/none.conf"
export CLAUDE_TUNNEL_LOG="$scratch/tunnel.log" CLAUDE_DESKTOP_NOTIFICATIONS=off CLAUDE_PROXY_BANNER=0
mkdir -p "$HOME"
fail() { print -u2 "FAIL: $*"; exit 1; }
# Sourced the way a login shell does it (no errexit), then checked strictly.
source "$repo/scripts/claude-proxy.sh" >/dev/null
set -eu

# State reducer: lost -> prolonged -> restored.
s=$(_recovery_step '' 'tunnel|7|000|000|tunnel' 5 60)
[[ ${s%%|*} == recovering && ${s##*|} == lost ]] || fail "step lost: $s"
s=$(_recovery_step "$s" 'tunnel|7|000|000|tunnel' 70 60)
[[ ${s%%|*} == prolonged ]] || fail "step prolonged: $s"
s=$(_recovery_step "$s" 'healthy|0|200|404|healthy' 75 60)
[[ ${s%%|*} == healthy && ${s##*|} == restored ]] || fail "step restored: $s"
print 'PASS: zsh - recovery state reducer'

# Slot identity, record and adoption.
CLAUDE_SSH_HOST=jpvpn CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080
dir=$(_recovery_identity)
[[ $dir == "$XDG_STATE_HOME/claude-proxy/recovery/main" ]] || fail "identity: $dir"
_recovery_record_write "$dir"
_recovery_owner_pid() { echo $$; }
CLAUDE_SSH_HOST=stale CLAUDE_HTTP_PORT=9999
_recovery_adopt "$dir"
[[ $CLAUDE_SSH_HOST == jpvpn && $CLAUDE_HTTP_PORT == 8080 ]] || fail "adopt: $CLAUDE_SSH_HOST $CLAUDE_HTTP_PORT"
unfunction _recovery_owner_pid; set +eu; source "$repo/scripts/claude-proxy.sh" >/dev/null; set -eu
print 'PASS: zsh - slot identity, tunnel record and adoption'

# ssh failure classifier.
print 'user@jp: Permission denied (publickey).' > "$scratch/err"
[[ $(_recovery_ssh_class "$scratch/err") == auth ]] || fail 'classifier'
print 'PASS: zsh - ssh failure classifier'

# Sessions: register, count, unregister.
sub=$(_recovery_subscribe "$dir" claude 2>/dev/null)
subid=$(_recovery_process_identity "$sub")
[[ $(_recovery_sessions "$dir") == 1 ]] || fail "sessions after subscribe: $(_recovery_sessions "$dir")"
_recovery_unsubscribe "$sub" "$subid"
for i in {1..30}; do [[ -e $dir/sessions/$sub ]] || break; sleep .1; done
[[ $(_recovery_sessions "$dir") == 0 ]] || fail 'session not removed'
print 'PASS: zsh - sessions register and unregister'

# One worker run with a fake ssh that is refused (the Task 3 auth case).
CLAUDE_SSH_HOST=jp CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080
CLAUDE_WATCHDOG_INTERVAL=0 CLAUDE_WATCHDOG_STARTUP_GRACE=0 CLAUDE_WATCHDOG_MAX_BACKOFF=30
_listeners() { :; }
_port_bound() { return 1; }
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
_wd_sleep() { :; }
_recovery_idle_sleep() { :; }
print 0 > "$scratch/clock"; : > "$scratch/launches"
_recovery_now() { local t; read -r t < "$scratch/clock"; print $t; print $((t+5)) > "$scratch/clock"; }
_recovery_probe() {
    local t; read -r t < "$scratch/clock"
    if (( t >= 25 )); then cp "$wdir/ssh.status" "$scratch/status" 2>/dev/null || :; touch "$wdir/stopped"; fi
    print 'tunnel|7|000|000|tunnel'
}
ssh() { print x >> "$scratch/launches"; print 'user@jp: Permission denied (publickey).' >&2; exit 255; }
wdir="$scratch/worker"; mkdir -p "$wdir"
_recovery_worker "$wdir" > "$scratch/worker.log"
[[ $(wc -l < "$scratch/launches" | tr -d ' ') == 1 ]] || fail "launches: $(wc -l < "$scratch/launches")"
[[ $(cut -d'|' -f1 "$scratch/status") == auth ]] || fail "status: $(cat "$scratch/status" 2>/dev/null)"
grep -q 'SSH login to jp was refused' "$scratch/worker.log" || fail "worker log: $(cat "$scratch/worker.log")"
print 'PASS: zsh - worker classifies a refused login and backs off'

# Kill switch: NO_PROXY matcher (word splitting of the host list differs in zsh).
[[ $(_noproxy_exempts '*.com,localhost' | wc -l | tr -d ' ') == 5 ]] || fail "noproxy *.com: $(_noproxy_exempts '*.com,localhost')"
[[ -z $(_noproxy_exempts 'localhost,*.local') ]] || fail 'noproxy safe list flagged'
print 'PASS: zsh - NO_PROXY exemption matcher'
