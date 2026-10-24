#!/usr/bin/env bash
# Another program that binds a proxy port while the tunnel is down could
# receive Claude/Codex traffic. The owner never kills it (it may be anything),
# but says so loudly - once per program - naming it and telling the user to
# exit the session. When the port frees up, normal recovery resumes.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT

# 1) The conflict names the first foreign listener; our own ssh is not one.
CLAUDE_HTTP_PORT=18080 CLAUDE_SOCKS_PORT=11080
_listeners() { case "$1" in 18080) echo 777;; esac; }
_proc_name() { echo clash; }
assert test "$(_recovery_port_conflict 555)" = '777|clash|18080'
_listeners() { case "$1" in 18080|11080) echo 555;; esac; }
if _recovery_port_conflict 555 >/dev/null; then echo 'FAIL: own ssh reported as a conflict' >&2; exit 1; fi
# A socket we cannot attribute (another user's) still counts while our ssh is down.
_listeners() { :; }
_port_bound() { [ "$1" = 11080 ]; }
assert test "$(_recovery_port_conflict '')" = "-|another user's program|11080"
_port_bound() { return 1; }
echo 'PASS: the conflict names the program, PID and port'

# 2) The messages name it and say what to do.
msg=$(_recovery_message takeover '777|clash|18080')
case "$msg" in *clash*'PID 777'*18080*'exit this session'*) ;; *) echo "FAIL: terminal message: $msg" >&2; exit 1;; esac
msg=$(_recovery_desktop_message takeover '777|clash|18080')
case "$msg" in 'Proxy port taken|clash (PID 777) took port 18080'*) ;; *) echo "FAIL: desktop message: $msg" >&2; exit 1;; esac
echo 'PASS: terminal and desktop messages name the program and say to exit'

# 3) Worker: foreign program on the HTTP port during an outage, then it leaves.
export CLAUDE_TUNNEL_LOG="$scratch/tunnel.log"
CLAUDE_SSH_HOST=jp CLAUDE_SSH_USER= CLAUDE_SSH_PORT=22 CLAUDE_SSH_KEY= CLAUDE_REMOTE_PROXY_PORT=8888
CLAUDE_WATCHDOG_INTERVAL=0 CLAUDE_WATCHDOG_FAILS=2 CLAUDE_WATCHDOG_NOTICE_AFTER=60 CLAUDE_WATCHDOG_STARTUP_GRACE=0
_tunnel_ssh_args() { _CP_SSH_ARGS=(); }
_wd_sleep() { :; }
_recovery_idle_sleep() { :; }
_recovery_desktop_backend() { echo linux; }
_recovery_desktop_send() { printf '%s\n' "$2" >> "$scratch/desktop"; }
kill() { case " $* " in *' 777 '*) echo "$*" >> "$scratch/kills";; esac; builtin kill "$@"; }
ssh() { exec sleep 100; }
dir="$scratch/owner"; mkdir "$dir"; echo 0 > "$scratch/pass"
# Passes 1-3: clash holds 18080 (no ssh can start). Pass 4+: port free, tunnel healthy.
_recovery_now() { local n; read -r n < "$scratch/pass"; echo $((n+1)) > "$scratch/pass"; echo $((n*5)); }
_listeners() { local n; read -r n < "$scratch/pass"; [ "$n" -gt 3 ] || { [ "$1" = 18080 ] && echo 777; }; }
_recovery_probe() {
    local n; read -r n < "$scratch/pass"
    [ "$n" -ne 1 ] || cp "$dir/claude.state" "$scratch/state.1" 2>/dev/null || :
    [ "$n" -lt 6 ] || touch "$dir/stopped"
    if [ "$n" -le 3 ]; then echo 'tunnel|7|000|000|tunnel'; else echo 'healthy|0|200|404|healthy'; fi
}
_recovery_worker "$dir" > "$scratch/worker.log"
assert grep -q 'clash, PID 777.*exit this session' "$scratch/worker.log"
assert test "$(grep -c 'clash, PID 777' "$scratch/worker.log")" = 1
assert test "$(grep -c '^takeover$' "$scratch/desktop")" = 1
assert test ! -e "$scratch/kills"
assert test ! -e "$dir/takeover"
assert test "$(cut -d'|' -f1 "$dir/claude.state")" = healthy
assert test "$(cut -d'|' -f9 "$dir/claude.state")" = restored
assert grep -qx restored "$scratch/desktop"
echo 'PASS: the owner alerts once, never kills the program, and recovers when the port frees'

# 4) A live terminal shows the takeover with the program's name.
printf '777|clash|18080\n' > "$dir/takeover"
printf 'recovering|0|0|0|0|0|9|conflict|takeover\n' > "$dir/claude.state"
parent_state=$(_recovery_subscribe "$dir" claude 2>"$scratch/sub.err")
subid=$(_recovery_process_identity "$parent_state")
sleep 1.5
_recovery_unsubscribe "$parent_state" "$subid"
assert grep -q 'claude proxy\] Another program (clash, PID 777) took proxy port 18080' "$scratch/sub.err"
echo 'PASS: a live terminal is told which program took the port'
