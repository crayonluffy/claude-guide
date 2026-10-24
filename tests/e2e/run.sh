#!/usr/bin/env bash
# End-to-end recovery test with a real ssh tunnel - and no system changes:
# a private sshd on 127.0.0.1:22022 (own host key, own authorized_keys), a
# local CONNECT proxy standing in for tinyproxy, and an isolated HOME/state.
# Probes go through the tunnel to the real api.anthropic.com / api.openai.com.
#
#   bash tests/e2e/run.sh
#
# Scenarios: start -> healthy; ssh killed -> recovered on the same ports;
# hung link (SIGSTOP) -> restarted; login refused -> classified 'auth';
# foreign program on the port during the outage -> 'takeover' alert;
# a terminal with stale settings runs tunnel-stop -> owner stops, stays stopped.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
SSHD=${SSHD:-/usr/sbin/sshd}
SSHD_PORT=22022 HTTP=28080 SOCKS=21080 REMOTE=28888
for p in $SSHD_PORT $HTTP $SOCKS $REMOTE; do
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]$p\$"; then echo "SKIP: port $p is busy" >&2; exit 2; fi
done
[ -x "$SSHD" ] || { echo "SKIP: no sshd at $SSHD" >&2; exit 2; }

E=$(mktemp -d); chmod 700 "$E"
dir="$E/state/claude-proxy/recovery/main"
pids=()
cleanup() {
    # The owner first (it would restart ssh), then our helpers. Only PIDs we started.
    [ -d "$E/state" ] && prof tunnel-stop >/dev/null 2>&1 || :
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || :; done
    [ -f "$E/sshd.pid" ] && kill "$(cat "$E/sshd.pid")" 2>/dev/null || :
    wait 2>/dev/null || :
    rm -rf "$E"
}
trap cleanup EXIT
fail() {
    echo "FAIL: $*" >&2
    echo '--- tunnel log ---' >&2; tail -n 30 "$E/tunnel.log" >&2 2>/dev/null || :
    echo '--- owner state ---' >&2; cat "$dir"/*.state "$dir/ssh.status" >&2 2>/dev/null || :
    [ -r "$dir/lock/owner" ] && ps -o pid=,stat=,etime=,args= --ppid "$(head -1 "$dir/lock/owner")" >&2 || :
    echo '--- tunnel ports ---' >&2; ss -ltnp 2>/dev/null | grep -E "[:.]($HTTP|$SOCKS) " >&2 || echo none >&2
    cat "$dir/takeover" >&2 2>/dev/null || :
    exit 1
}
pass() { echo "PASS: e2e - $*"; }
until_ok() {  # <seconds> <command...>: poll every 0.5s
    local n=$(( $1 * 2 )); shift
    while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep .5; n=$((n-1)); done
    return 1
}

# --- private sshd ------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "$E/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$E/client"
cp "$E/client.pub" "$E/authorized_keys"
cat > "$E/sshd_config" <<EOF
Port $SSHD_PORT
ListenAddress 127.0.0.1
HostKey $E/hostkey
AuthorizedKeysFile $E/authorized_keys
PidFile $E/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding yes
PermitTTY no
EOF
"$SSHD" -f "$E/sshd_config" -E "$E/sshd.log"
until_ok 5 test -s "$E/sshd.pid" || { cat "$E/sshd.log" >&2; fail 'sshd did not start'; }

# --- stand-in for tinyproxy on the "VM" -----------------------------------------
python3 -I "$repo/tests/e2e/connect_proxy.py" "$REMOTE" & pids+=($!)
until_ok 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$REMOTE" || fail 'CONNECT proxy did not start'

# --- isolated client: its own ssh config and known_hosts, never the user's -------
mkdir -p "$E/bin" "$E/home"
cat > "$E/ssh_config" <<EOF
Host e2e-jp
    HostName 127.0.0.1
    Port $SSHD_PORT
    User $(id -un)
    IdentityFile $E/client
    IdentitiesOnly yes
    UserKnownHostsFile $E/known_hosts
    GlobalKnownHostsFile /dev/null
EOF
printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v ssh)" "$E/ssh_config" > "$E/bin/ssh"
chmod +x "$E/bin/ssh"
cat > "$E/conf" <<EOF
CLAUDE_SSH_HOST=e2e-jp
CLAUDE_HTTP_PORT=$HTTP
CLAUDE_SOCKS_PORT=$SOCKS
CLAUDE_REMOTE_PROXY_PORT=$REMOTE
CLAUDE_SYNC_SETTINGS=0
CLAUDE_DESKTOP_NOTIFICATIONS=off
CLAUDE_PROXY_BANNER=0
CLAUDE_WATCHDOG_INTERVAL=1
CLAUDE_WATCHDOG_IDLE_INTERVAL=2
CLAUDE_WATCHDOG_FAILS=2
CLAUDE_WATCHDOG_STARTUP_GRACE=4
CLAUDE_WATCHDOG_MAX_BACKOFF=4
EOF
export HOME="$E/home" XDG_STATE_HOME="$E/state" CLAUDE_PROXY_CONF="$E/conf" CLAUDE_TUNNEL_LOG="$E/tunnel.log"
export PATH="$E/bin:$PATH"
unset SSH_AUTH_SOCK HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY NO_PROXY no_proxy
prof() { bash -c '. "$0" >/dev/null 2>&1; "$@"' "$repo/scripts/claude-proxy.sh" "$@"; }
dir="$E/state/claude-proxy/recovery/main"
through_tunnel() { curl -s -o /dev/null --max-time 8 -x "http://127.0.0.1:$HTTP" https://api.anthropic.com/; }
owner_ssh() { ps -o pid=,comm= --ppid "$(head -1 "$dir/lock/owner")" | awk '$2 == "ssh" {print $1}'; }
field() { cut -d'|' -f"$2" "$dir/$1.state" 2>/dev/null; }
state_is() { [ "$(field "$1" "$2")" = "$3" ]; }   # re-read on every poll
new_ssh() { local now; now=$(owner_ssh); [ -n "$now" ] && [ "$now" != "$1" ]; }

# 1) Start: one owner, healthy, traffic flows.
prof tunnel-start > "$E/start.out" 2>&1 || { cat "$E/start.out" >&2; fail 'tunnel-start failed'; }
until_ok 15 through_tunnel || fail 'no traffic through a fresh tunnel'
until_ok 10 state_is claude 1 healthy || fail "claude state: $(cat "$dir/claude.state" 2>/dev/null)"
grep -qx "http=$HTTP" "$dir/tunnel.rec" || fail 'tunnel record missing'
pass 'tunnel-start brings up a healthy owned tunnel'

# 2) ssh killed: recovered on the same ports.
old=$(owner_ssh); [ -n "$old" ] || fail 'owner has no ssh child'
kill "$old"
until_ok 15 new_ssh "$old" || fail 'ssh not relaunched'
until_ok 15 through_tunnel || fail 'traffic did not come back after ssh was killed'
pass 'a killed ssh is replaced and traffic resumes on the same ports'

# 3) Hung link: ssh alive but frozen -> killed and replaced after the grace + fails.
hung=$(owner_ssh); kill -STOP "$hung"
# A dead-link pass probes both providers over HTTP and SOCKS (4 x 3s timeouts),
# so FAILS=2 passes plus the 5s TERM grace take about 30s.
until_ok 60 bash -c '! kill -0 "$1" 2>/dev/null || [ "$(ps -o stat= -p "$1")" = Z ]' _ "$hung" || { kill -CONT "$hung" 2>/dev/null; fail 'hung ssh was never restarted'; }
until_ok 20 through_tunnel || fail 'traffic did not come back after a hung link'
pass 'a hung ssh is detected, replaced, and traffic resumes'

# 4) Login refused: classified as auth.
: > "$E/authorized_keys"
kill "$(owner_ssh)"
until_ok 20 bash -c 'cut -d"|" -f1 "$1" | grep -qx auth' _ "$dir/ssh.status" || fail "ssh.status: $(cat "$dir/ssh.status" 2>/dev/null)"
grep -q 'SSH login to e2e-jp was refused' "$E/tunnel.log" || fail 'auth hint not logged'
pass 'a refused login is classified as auth with its fix'

# 5) Foreign program takes the HTTP port during the outage: takeover alert, untouched.
python3 -I -m http.server "$HTTP" --bind 127.0.0.1 >/dev/null 2>&1 & squatter=$!; pids+=($squatter)
until_ok 15 state_is claude 9 takeover || fail "no takeover event: $(cat "$dir/claude.state")"
grep -q "$squatter" "$dir/takeover" || fail "takeover record: $(cat "$dir/takeover" 2>/dev/null)"
kill -0 "$squatter" || fail 'the foreign program was killed'
grep -q "PID $squatter) took proxy port $HTTP" "$E/tunnel.log" || fail 'takeover not logged'
kill "$squatter"; wait "$squatter" 2>/dev/null || :
cp "$E/client.pub" "$E/authorized_keys"
until_ok 30 through_tunnel || fail 'no recovery after the port freed and login was fixed'
until_ok 10 test ! -e "$dir/takeover" || fail 'takeover record not cleared'
pass 'a program taking the port is named once, left alone, and recovery resumes'

# 6) A terminal with stale settings stops the owner, and it stays stopped.
owner=$(head -1 "$dir/lock/owner")
CLAUDE_PROXY_CONF="$E/stale.conf" bash -c 'printf "CLAUDE_HTTP_PORT=8080\nCLAUDE_SOCKS_PORT=1080\nCLAUDE_SSH_HOST=e2e-jp\n" > "$CLAUDE_PROXY_CONF"; . "$0" >/dev/null 2>&1; tunnel-stop' "$repo/scripts/claude-proxy.sh" > "$E/stop.out" 2>&1 \
    || { cat "$E/stop.out" >&2; fail 'tunnel-stop from a stale terminal failed'; }
until_ok 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$owner" || fail 'owner still running after tunnel-stop'
sleep 4
if bash -c "exec 3<>/dev/tcp/127.0.0.1/$HTTP" 2>/dev/null; then fail 'tunnel came back after an explicit stop'; fi
pass 'tunnel-stop from a terminal with stale settings stops the owner for good'
