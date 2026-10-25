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
# Kill switch (2.9): Claude's settings are pinned to the tunnel; a NO_PROXY
# that exempts the API refuses to launch; with the tunnel down the REAL Claude
# CLI tries only the pinned port and opens no direct connection; a program on
# the port makes tunnel-start refuse instead of moving the port.
# Parallel nodes (2.10): a second node 'sg' (same sshd, its own proxy) gets its
# own self-healing tunnel next to jp; killing or stopping it leaves jp alone;
# the real Claude CLI started with 'cc --node sg' goes through sg only, while
# Claude's pinned settings stay on jp; proxy-node refuses to move a session.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
SSHD=${SSHD:-/usr/sbin/sshd}
SSHD_PORT=22022 HTTP=28080 SOCKS=21080 REMOTE=28888 REMOTE_SG=28889 SG_HTTP=28181 SG_SOCKS=21181
for p in $SSHD_PORT $HTTP $SOCKS $REMOTE $REMOTE_SG $SG_HTTP $SG_SOCKS; do
    if ss -ltn | awk '{print $4}' | grep -qE "[:.]$p\$"; then echo "SKIP: port $p is busy" >&2; exit 2; fi
done
[ -x "$SSHD" ] || { echo "SKIP: no sshd at $SSHD" >&2; exit 2; }

E=$(mktemp -d); chmod 700 "$E"
dir="$E/state/claude-proxy/recovery/main"
pids=()
cleanup() {
    # The owner first (it would restart ssh), then our helpers. Only PIDs we started.
    [ -d "$E/state" ] && prof cc-stop --force >/dev/null 2>&1 || :
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
# Node sg: the same sshd, its own proxy, which logs what it serves.
python3 -I "$repo/tests/e2e/connect_proxy.py" "$REMOTE_SG" --log "$E/sg.log" & pids+=($!)
until_ok 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$REMOTE_SG" || fail 'sg CONNECT proxy did not start'

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
Host e2e-sg
    HostName 127.0.0.1
    Port $SSHD_PORT
    User $(id -un)
    IdentityFile $E/client
    IdentitiesOnly yes
    UserKnownHostsFile $E/known_hosts
    GlobalKnownHostsFile /dev/null
EOF
# The profile looks for node aliases in ~/.ssh/config; ssh itself reads the -F file.
mkdir -p "$E/home/.ssh"; cp "$E/ssh_config" "$E/home/.ssh/config"
cat > "$E/home/.claude-proxy.nodes.json" <<EOF
{ "nodes": [
{ "name": "jp", "alias": "e2e-jp", "host": "127.0.0.1", "ssh_port": $SSHD_PORT, "proxy_port": $REMOTE, "region": "Test", "slot": 0 },
{ "name": "sg", "alias": "e2e-sg", "host": "127.0.0.1", "ssh_port": $SSHD_PORT, "proxy_port": $REMOTE_SG, "region": "Test", "slot": 1 }
] }
EOF
printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v ssh)" "$E/ssh_config" > "$E/bin/ssh"
chmod +x "$E/bin/ssh"
cat > "$E/conf" <<EOF
CLAUDE_SSH_HOST=e2e-jp
CLAUDE_HTTP_PORT=$HTTP
CLAUDE_SOCKS_PORT=$SOCKS
CLAUDE_REMOTE_PROXY_PORT=$REMOTE
CLAUDE_SYNC_SETTINGS=1
CLAUDE_DESKTOP_NOTIFICATIONS=off
CLAUDE_PROXY_BANNER=0
CLAUDE_WATCHDOG_INTERVAL=1
CLAUDE_WATCHDOG_IDLE_INTERVAL=2
CLAUDE_WATCHDOG_FAILS=2
CLAUDE_WATCHDOG_STARTUP_GRACE=4
CLAUDE_WATCHDOG_MAX_BACKOFF=4
CLAUDE_NODE_HTTP_BASE=28180
CLAUDE_NODE_SOCKS_BASE=21180
EOF
export HOME="$E/home" XDG_STATE_HOME="$E/state" CLAUDE_PROXY_CONF="$E/conf" CLAUDE_TUNNEL_LOG="$E/tunnel.log"
export CLAUDE_SETTINGS="$E/home/.claude/settings.json"
export PATH="$E/bin:$PATH"
unset SSH_AUTH_SOCK HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY NO_PROXY no_proxy
prof() { bash -c '. "$0" >/dev/null 2>&1; "$@"' "$repo/scripts/claude-proxy.sh" "$@"; }
dir="$E/state/claude-proxy/recovery/main"
through_tunnel() { curl -s -o /dev/null --max-time 8 -x "http://127.0.0.1:$HTTP" https://api.anthropic.com/; }
owner_ssh() { ps -o pid=,comm= --ppid "$(head -1 "$dir/lock/owner")" | awk '$2 == "ssh" {print $1}'; }
field() { cut -d'|' -f"$2" "$dir/$1.state" 2>/dev/null; }
state_is() { [ "$(field "$1" "$2")" = "$3" ]; }   # re-read on every poll
new_ssh() { local now; now=$(owner_ssh); [ -n "$now" ] && [ "$now" != "$1" ]; }
pinned_port() { jq -r '.env.HTTPS_PROXY // empty' "$CLAUDE_SETTINGS" 2>/dev/null; }
tree_pids() {  # <pid>: it and all its descendants
    local p; echo "$1"
    for p in $(ps -o pid= --ppid "$1" 2>/dev/null); do tree_pids "$p"; done
}
# TCP peers of a process tree that are not loopback (one line each). Only this
# tree: Claude Code itself may be talking to Anthropic from the same machine.
direct_conns() {
    local p
    for p in $(tree_pids "$1"); do
        ss -tnpH 2>/dev/null | grep "pid=$p," | awk '{print $5}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' || :
    done
}

# 1) Start: one owner, healthy, traffic flows.
prof tunnel-start > "$E/start.out" 2>&1 || { cat "$E/start.out" >&2; fail 'tunnel-start failed'; }
until_ok 15 through_tunnel || fail 'no traffic through a fresh tunnel'
until_ok 10 state_is claude 1 healthy || fail "claude state: $(cat "$dir/claude.state" 2>/dev/null)"
grep -qx "http=$HTTP" "$dir/tunnel.rec" || fail 'tunnel record missing'
pass 'tunnel-start brings up a healthy owned tunnel'
[ "$(pinned_port)" = "http://127.0.0.1:$HTTP" ] || fail "Claude settings not pinned: $(cat "$CLAUDE_SETTINGS" 2>/dev/null)"
pass 'kill switch: Claude settings are pinned to the tunnel'

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

# Kill switch: a NO_PROXY that exempts the API stops the launch, even with a healthy tunnel.
{ cat "$E/conf"; echo 'CLAUDE_NO_PROXY="localhost,*.com"'; } > "$E/leak.conf"
if CLAUDE_PROXY_CONF="$E/leak.conf" prof proxy-up --no-verify > "$E/leak.out" 2>&1; then fail 'proxy-up launched with a leaky NO_PROXY'; fi
grep -q 'api.anthropic.com' "$E/leak.out" || fail "leak refusal does not name the host: $(cat "$E/leak.out")"
prof true   # the next shell re-pins NO_PROXY from the real settings
pass 'kill switch: a NO_PROXY that exempts the API refuses to launch'

# 6) A terminal with stale settings stops the owner, and it stays stopped.
owner=$(head -1 "$dir/lock/owner")
CLAUDE_PROXY_CONF="$E/stale.conf" bash -c 'printf "CLAUDE_HTTP_PORT=8080\nCLAUDE_SOCKS_PORT=1080\nCLAUDE_SSH_HOST=e2e-jp\n" > "$CLAUDE_PROXY_CONF"; . "$0" >/dev/null 2>&1; tunnel-stop' "$repo/scripts/claude-proxy.sh" > "$E/stop.out" 2>&1 \
    || { cat "$E/stop.out" >&2; fail 'tunnel-stop from a stale terminal failed'; }
until_ok 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$owner" || fail 'owner still running after tunnel-stop'
sleep 4
if bash -c "exec 3<>/dev/tcp/127.0.0.1/$HTTP" 2>/dev/null; then fail 'tunnel came back after an explicit stop'; fi
pass 'tunnel-stop from a terminal with stale settings stops the owner for good'

# Kill switch with the tunnel down: Claude stays pinned, even after proxy-off.
prof true; prof proxy-off >/dev/null
[ "$(pinned_port)" = "http://127.0.0.1:$HTTP" ] || fail "pin lost after tunnel-stop + proxy-off: $(cat "$CLAUDE_SETTINGS")"
pass 'kill switch: the pin survives tunnel-stop and proxy-off'

# The real Claude CLI (a fake API key; nothing can reach the API anyway).
if command -v claude >/dev/null 2>&1; then
    run_claude() {  # <seconds>: run 'claude -p' in the isolated HOME; fail on any direct connection
        local c direct=''
        ( cd "$E" && exec env -u HTTPS_PROXY -u HTTP_PROXY ANTHROPIC_API_KEY=sk-ant-e2e-not-a-key timeout "$1" claude -p hi </dev/null >"$E/claude.out" 2>&1 ) & c=$!
        while kill -0 "$c" 2>/dev/null; do direct="$direct$(direct_conns "$c")"; sleep .5; done
        wait "$c" 2>/dev/null || :
        [ -z "$direct" ] || fail "Claude opened DIRECT connections: $(printf '%s\n' "$direct" | sort -u | tr '\n' ' ')"
    }
    # Something on the pinned port that records and refuses: Claude goes there, nowhere else.
    python3 -I "$repo/tests/e2e/connect_proxy.py" "$HTTP" --record "$E/claude.rec" & rec=$!; pids+=($rec)
    until_ok 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$HTTP" || fail 'recording listener did not start'
    run_claude 15
    grep -q '^CONNECT api.anthropic.com:443' "$E/claude.rec" || fail "Claude did not use the pinned proxy: $(cat "$E/claude.rec" 2>/dev/null) / $(tail -3 "$E/claude.out")"
    kill "$rec"; wait "$rec" 2>/dev/null || :
    pass 'kill switch: the real Claude CLI uses only the pinned proxy port'
    # Nothing on the port at all: connection refused, and still no direct connection.
    run_claude 10
    pass 'kill switch: with the tunnel down the real Claude CLI fails closed (no direct connection)'
else
    echo 'SKIP: e2e - claude CLI not installed; real-CLI kill switch checks skipped'
fi

# A program on the proxy port: tunnel-start refuses instead of moving the port.
python3 -I -m http.server "$HTTP" --bind 127.0.0.1 >/dev/null 2>&1 & squatter=$!; pids+=($squatter)
until_ok 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$HTTP" || fail 'squatter did not start'
if prof tunnel-start > "$E/squat.out" 2>&1; then fail 'tunnel-start moved around a program on the port'; fi
grep -q "PID $squatter" "$E/squat.out" || fail "refusal does not name the program: $(cat "$E/squat.out")"
grep -q 'proxy-config set HTTP_PORT' "$E/squat.out" || fail 'refusal has no fix'
kill "$squatter"; wait "$squatter" 2>/dev/null || :
pass 'kill switch: tunnel-start refuses a program on the port instead of moving the tunnel'

# --- Parallel nodes ------------------------------------------------------------
prof tunnel-start > "$E/jp2.out" 2>&1 || { cat "$E/jp2.out" >&2; fail 'jp tunnel did not start again'; }
until_ok 20 through_tunnel || fail 'no traffic through jp'
jp_owner=$(head -1 "$dir/lock/owner"); jp_ssh=$(owner_ssh)
sgdir="$E/state/claude-proxy/recovery/node-sg"
prof tunnel-start sg > "$E/sg.out" 2>&1 || { cat "$E/sg.out" >&2; fail 'tunnel-start sg failed'; }
through_sg() { curl -s -o /dev/null --max-time 8 -x "http://127.0.0.1:$SG_HTTP" https://api.anthropic.com/; }
until_ok 20 through_sg || fail 'no traffic through the sg tunnel'
grep -qx "http=$SG_HTTP" "$sgdir/tunnel.rec" || fail "sg tunnel record: $(cat "$sgdir/tunnel.rec" 2>/dev/null)"
bash -c "exec 3<>/dev/tcp/127.0.0.1/$SG_SOCKS" || fail 'sg SOCKS port not listening'
n=$(wc -l < "$E/sg.log"); through_tunnel; [ "$(wc -l < "$E/sg.log")" = "$n" ] || fail 'jp traffic reached the sg proxy'
through_sg; [ "$(wc -l < "$E/sg.log")" -gt "$n" ] || fail 'sg traffic did not reach the sg proxy'
pass 'node sg runs its own tunnel next to jp; each node reaches its own proxy'

sg_ssh() { ps -o pid=,comm= --ppid "$(head -1 "$sgdir/lock/owner")" | awk '$2 == "ssh" {print $1}'; }
new_sg_ssh() { local now; now=$(sg_ssh); [ -n "$now" ] && [ "$now" != "$1" ]; }
old=$(sg_ssh); kill "$old"
until_ok 20 new_sg_ssh "$old" || fail 'sg ssh not relaunched'
until_ok 20 through_sg || fail 'sg traffic did not come back'
[ "$(owner_ssh)" = "$jp_ssh" ] || fail 'killing sg touched the jp tunnel'
pass 'a killed sg ssh is replaced; the jp tunnel is untouched'

if command -v claude >/dev/null 2>&1; then
    n=$(wc -l < "$E/sg.log")
    ( cd "$E" && ANTHROPIC_API_KEY=sk-ant-e2e-not-a-key timeout 40 bash -c '. "$0" >/dev/null 2>&1; cc --node sg --no-verify -p hi' "$repo/scripts/claude-proxy.sh" </dev/null > "$E/cc-sg.out" 2>&1 ) || :
    tail -n +"$((n+1))" "$E/sg.log" | grep -q '^CONNECT api.anthropic.com:443' || fail "cc --node sg did not go through sg: $(tail -5 "$E/cc-sg.out")"
    [ "$(pinned_port)" = "http://127.0.0.1:$HTTP" ] || fail "cc --node sg moved the pin: $(pinned_port)"
    pass 'kill switch + nodes: the real Claude CLI with cc --node sg goes through sg; the pin stays on jp'
fi

# A session on the default node: proxy-node refuses to move it.
sleep 300 & sess=$!; pids+=($sess)
mkdir -p "$dir/sessions"; (sed 's/.*) //' "/proc/$sess/stat" | awk '{print $20}') > "$dir/sessions/$sess"
if prof proxy-node sg > "$E/pn.out" 2>&1; then fail 'proxy-node moved a running session'; fi
grep -q '1 session(s)' "$E/pn.out" || fail "proxy-node refusal: $(cat "$E/pn.out")"
grep -qx 'CLAUDE_SSH_HOST=e2e-jp' "$E/conf" || fail 'the default node changed'
kill "$sess"; rm -f "$dir/sessions/$sess"
pass 'proxy-node refuses to move a running session to another node'

sg_owner=$(head -1 "$sgdir/lock/owner")   # before the stop removes the lock
prof tunnel-stop sg > /dev/null
until_ok 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$sg_owner" || fail 'sg owner still running'
if bash -c "exec 3<>/dev/tcp/127.0.0.1/$SG_HTTP" 2>/dev/null; then fail 'sg port still open after tunnel-stop sg'; fi
through_tunnel || fail 'tunnel-stop sg cut the jp tunnel'
[ "$(head -1 "$dir/lock/owner")" = "$jp_owner" ] || fail 'jp owner changed'
pass 'tunnel-stop sg stops only sg; jp keeps working'
