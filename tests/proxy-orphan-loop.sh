#!/usr/bin/env bash
# 2.13.6: a leftover tunnel loop from an older profile (a shell with no terminal,
# adopted by launchd/init) is recognised and stopped - even when it ignores TERM -
# while live terminals are never touched; another account's tunnel is named.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in _orphan_loop_parent _stop_orphan_loop _port_other_account _other_account_hint; do
    eval "$(sed -n "/^$f() {/,/^}\$/p" "$src")"
done
me=$(id -u)
# Fake ps: "-o ppid= -p X", "-o ppid=,tty=,uid=,comm= -p X", "-o comm= -p X", "-axo ...".
ps() {
    case "$*" in
        '-o ppid= -p 500') echo 400;;            # ssh 500 <- orphan loop 400
        "-o ppid=,tty=,uid=,comm= -p 400") echo "1 ?? $me -zsh";;
        '-o ppid= -p 501') echo 401;;            # ssh 501 <- interactive shell 401 (has a tty)
        "-o ppid=,tty=,uid=,comm= -p 401") echo "1 ttys004 $me -zsh";;
        '-o ppid= -p 502') echo 402;;            # ssh 502 <- shell whose parent (300) is alive Terminal
        "-o ppid=,tty=,uid=,comm= -p 402") echo "300 ?? $me zsh";;
        '-o comm= -p 300') echo /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal;;
        '-o ppid= -p 503') echo 403;;            # ssh 503 <- another user's orphan shell
        "-o ppid=,tty=,uid=,comm= -p 403") echo "1 ?? 99999 -zsh";;
        '-o ppid= -p 504') echo 404;;            # Linux: adopted by systemd --user
        "-o ppid=,tty=,uid=,comm= -p 404") echo "1200 ? $me bash";;
        '-o comm= -p 1200') echo systemd;;
        '-o ppid= -p 505') echo 405;;            # parent is not a shell
        "-o ppid=,tty=,uid=,comm= -p 405") echo "1 ?? $me python3";;
        -axo\ uid=,user=,command=) printf '%s\n' \
            "99999 ming ssh -o BatchMode=yes -N -C -L 8080:127.0.0.1:8888 -D 1080 jpvpn" \
            "99999 ming ssh -N -L 8181:127.0.0.1:8888 -D 1181 sgvpn" \
            "$me me ssh -N -L 8080:127.0.0.1:8888 -D 1080 jpvpn" \
            "99999 ming /usr/bin/vim notes-8080.txt";;
        *) command ps "$@";;
    esac
}
[ "$(_orphan_loop_parent 500)" = 400 ] || fail 'orphan -zsh loop not recognised'
[ "$(_orphan_loop_parent 504)" = 404 ] || fail 'systemd-adopted loop not recognised'
for pid in 501 502 503 505; do
    ! _orphan_loop_parent "$pid" >/dev/null || fail "ssh $pid: its parent must not be treated as a leftover loop"
done
echo 'PASS: only a terminal-less shell adopted by launchd/init (ours) counts as a leftover loop'

[ "$(_port_other_account 8080)" = ming ] || fail "other account on 8080: $(_port_other_account 8080)"
[ "$(_port_other_account 1080)" = ming ] || fail 'other account on 1080'
[ -z "$(_port_other_account 8081)" ] || fail 'nobody is on 8081'
[ -z "$(_port_other_account 808)" ] || fail ':808 must not match :8080'
case "$(_other_account_hint 8080)" in *"'ming'"*'PROXY_MODE shared'*) ;; *) fail "hint: $(_other_account_hint 8080)";; esac
! _other_account_hint 9999 >/dev/null || fail 'hint for a free port'
echo "PASS: another account's tunnel on our port is named, with the shared-mode fix"

# A real loop that ignores TERM (as old watchdogs did) is still stopped.
unset -f ps
# Detached like a real leftover (its reaper is not this shell, so no zombie lingers).
pidfile=$(mktemp)
( bash -c 'trap "" TERM; echo $$ > "$1"; while :; do sleep 1; done' _ "$pidfile" & )
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$pidfile" ] && break; sleep .1; done
loop=$(cat "$pidfile"); rm -f "$pidfile"
kill -0 "$loop" || fail 'test loop did not start'
_stop_orphan_loop "$loop" || { kill -9 "$loop" 2>/dev/null; fail 'TERM-ignoring loop survived'; }
echo 'PASS: a loop that ignores TERM is stopped with KILL'

# tunnel-stop stops the leftover loop BEFORE its ssh, so ssh does not come back.
eval "$(sed -n '/^tunnel-stop() {/,/^}$/p' "$src")"
log=$(mktemp)
_proxy_operation_owned() { return 0; }; _proxy_shared() { return 1; }; _recovery_adopt() { :; }
_recovery_owned_dirs() { :; }; _legacy_watchdog_pid() { return 1; }; _watchdog_stop() { :; }
_listeners() { [ "$1" = 8080 ] && echo 500; }; _proc_name() { echo ssh; }; _is_ssh_name() { [ "$1" = ssh ]; }
_ssh_listeners() { :; }; sleep() { :; }
_orphan_loop_parent() { [ "$1" = 500 ] && echo 400; }
_stop_orphan_loop() { echo "loop $1" >> "$log"; }
kill() { echo "kill $*" >> "$log"; }
CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080
out=$(tunnel-stop)
[ "$(head -1 "$log")" = 'loop 400' ] || fail "order: $(cat "$log")"
grep -qx 'kill 500' "$log" || fail "ssh not stopped: $(cat "$log")"
case "$out" in *'PID 400 (leftover tunnel loop'*'PID 500 (ssh)'*'Tunnel stopped'*) ;; *) fail "output: $out";; esac
rm -f "$log"; unset -f kill sleep
echo 'PASS: tunnel-stop stops the leftover loop first, then its ssh'
