# ============================================================
# claude-proxy.sh - Claude/Codex SSH tunnel + HTTP proxy + SOCKS5 (Chrome)
# (source from ~/.zshrc or ~/.bashrc - works in zsh AND bash)
# ============================================================
# One SSH connection carries two forwards:
#   -L 8080:127.0.0.1:8888  ->  VM's HTTP proxy (tinyproxy)  ->  used by Claude & Codex (HTTPS_PROXY)
#   -D 1080                 ->  SOCKS5 on the VM              ->  used by Chrome / other apps
#
# Claude Code only speaks HTTP proxies, so it uses the -L forward to the VM's
# HTTP proxy (see webproxy-manager: https://github.com/crayonluffy/forge/tree/main/webproxy-manager).
# Codex reads the same HTTP(S)_PROXY env vars, so it shares that forward too.
# Chrome is happier on SOCKS5 (full traffic, remote DNS), so it uses the -D forward.
#
# YOUR SETTINGS LIVE IN ~/.claude-proxy.conf, NOT IN THIS FILE.
#   proxy-config        show / edit them
#   proxy-update        replace this file with the latest version (settings are kept)
#
# NODES (v2.1): the admin publishes a catalogue of VMs (jp / sg / us ...) as
# scripts/nodes.json. 'proxy-nodes --refresh' downloads it and creates the
# matching ~/.ssh/config aliases; 'proxy-node sg' makes sg the node that cc / cx
# use; 'chrome-proxy sg' opens a Chrome window through sg on its OWN tunnel and
# profile, so several regions can be open side by side.
#
# v2.2: nodes can come from YOUR DOMAIN instead of GitHub (DNS TXT records at
# _claude-proxy.<domain>, see CLAUDE_PROXY_DOMAIN), a region can have several
# VMs (jp, jp2, jp3 ...), and 'chrome-proxy jp --profile work' opens another
# Chrome profile that goes out through the same node.
#
# v2.3: the node list can come PRIVATELY from one of your VMs over SSH
# ('proxy-nodes --from jpvpn', see CLAUDE_NODES_FROM) - only people who can log
# in can read it, and you choose (and can change) which VM serves it.
# ============================================================

CLAUDE_PROXY_VERSION="2.9.0"
# Where proxy-update fetches from (override in the conf file to use a mirror/fork).
CLAUDE_PROXY_REPO_RAW="${CLAUDE_PROXY_REPO_RAW:-https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts}"

# Where THIS file lives (so proxy-update can replace it). bash and zsh expose it differently.
if [ -n "${BASH_SOURCE:-}" ]; then
    CLAUDE_PROXY_SELF="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    eval 'CLAUDE_PROXY_SELF="${(%):-%x}"'
fi
[ -n "${CLAUDE_PROXY_SELF:-}" ] || CLAUDE_PROXY_SELF="$HOME/.claude-proxy.sh"
case "$CLAUDE_PROXY_SELF" in ~*) CLAUDE_PROXY_SELF="$HOME${CLAUDE_PROXY_SELF#\~}" ;; esac

# ============================================================
# Settings - built-in defaults. DO NOT EDIT HERE: put overrides in
# ~/.claude-proxy.conf (created by the setup wizard / 'proxy-config edit').
# That file survives 'proxy-update', so you never re-enter anything.
# ============================================================
CLAUDE_PROXY_CONF="${CLAUDE_PROXY_CONF:-$HOME/.claude-proxy.conf}"

CLAUDE_SSH_HOST="jpvpn"          # an ~/.ssh/config alias, OR a raw host/IP
CLAUDE_SSH_USER=""               # leave blank when CLAUDE_SSH_HOST is a config alias
CLAUDE_SSH_KEY=""                # leave blank when CLAUDE_SSH_HOST is a config alias
CLAUDE_SSH_PORT=22
CLAUDE_HTTP_PORT=8080            # local HTTP port -> forwarded to the VM's HTTP proxy (Claude/Codex)
CLAUDE_REMOTE_PROXY_PORT=8888    # tinyproxy port on the VM (webproxy-manager)
CLAUDE_SOCKS_PORT=1080           # local SOCKS5 port (Chrome / other apps)

# Node catalogue (jp / sg / us ...): downloaded by 'proxy-nodes --refresh' from
# $CLAUDE_PROXY_REPO_RAW/nodes.json. 'chrome-proxy <node>' opens a SEPARATE
# SOCKS-only tunnel per node so several regions can be open at once; node i
# (0-based, catalogue order) listens on NODE_SOCKS_BASE + i.
CLAUDE_PROXY_NODES="${CLAUDE_PROXY_NODES:-$HOME/.claude-proxy.nodes.json}"
CLAUDE_NODE_SOCKS_BASE=1180
# 2.10: every node can have its own tunnel at the same time ('cc --node sg' in
# one terminal, the default node in another). Node i (its catalogue slot) uses
# HTTP NODE_HTTP_BASE + i and SOCKS NODE_SOCKS_BASE + i; the default node keeps
# HTTP_PORT / SOCKS_PORT.
CLAUDE_NODE_HTTP_BASE=8180
CLAUDE_CHROME_BIN=""             # Chrome binary/app, only if it isn't in the usual place (macOS: app name or path)

# Where 'proxy-nodes --refresh' gets the node list from (set with 'proxy-nodes --from / --domain'):
#   CLAUDE_NODES_FROM="jpvpn"        -> PRIVATE: asks that VM over SSH ('ssh jpvpn claude-proxy-nodes',
#                                       forge proxynodes-manager). If it doesn't answer, the other
#                                       VMs already in your list are tried.
#   CLAUDE_PROXY_DOMAIN="example.com" -> PUBLIC DNS TXT records at _claude-proxy.example.com
#   both empty                       -> $CLAUDE_PROXY_REPO_RAW/nodes.json (this guide's list - empty)
CLAUDE_NODES_FROM=""
CLAUDE_PROXY_DOMAIN=""

# Also write the proxy into Claude's settings.json while the tunnel is up, so
# `claude` launched from ANY shell (not just this one) uses it. Removed again on
# proxy-off / cc-stop, so a down tunnel never leaves Claude pointed at a dead proxy.
# Needs `jq`; set to 0 to disable and rely on shell env vars only.
CLAUDE_SYNC_SETTINGS=1
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# Kill switch (2.9): Claude and Codex fail closed. While 'on', Claude's
# settings.json keeps the proxy permanently - proxy-off / cc-stop clear only the
# shell - so plain 'claude' and the IDE extensions go through the tunnel or get
# "connection refused", never out from your own IP. cc / cx also refuse to start
# when something would leak (a NO_PROXY that exempts the API, another program on
# the proxy port). 'off' = the pre-2.9 behaviour. See 'proxy-killswitch'.
CLAUDE_KILLSWITCH=on
# auto = plain 'claude' and 'codex' also start through the tunnel (like cc-safe /
# cx-safe, but quiet: only the app writes to stdout). off = they run untouched:
# Claude is still protected by its pinned settings; plain 'codex' is not.
CLAUDE_PLAIN_COMMANDS=off

# WSL only: ALSO keep the WINDOWS-side Claude (%USERPROFILE%\.claude\settings.json)
# pointed at this tunnel while it is up. Windows reaches WSL's 127.0.0.1 ports
# through WSL2 localhost forwarding (on by default). 1 to enable.
CLAUDE_SYNC_WINDOWS_SETTINGS=0

# Hosts that must NOT go through the proxy. Append company intranet ranges/domains
# in the conf file, e.g.  CLAUDE_NO_PROXY="$CLAUDE_NO_PROXY,172.20.0.0/24,*.mycorp.example"
CLAUDE_NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,*.local,*.internal,*.corp"

# One-line notice when a new shell loads this file (0 = silent).
CLAUDE_PROXY_BANNER=1

# Where the background ssh writes its errors (auth failure vs. network timeout).
# Per-UID: a single shared /tmp/claude-tunnel.log is created by whoever runs
# first (often root, mode 644), and then every `ssh 2>$CLAUDE_TUNNEL_LOG` by any
# other user fails on the REDIRECT - before ssh even starts - so the tunnel dies
# with no usable error. The pidfile below derives from this, so it splits too.
CLAUDE_TUNNEL_LOG="${CLAUDE_TUNNEL_LOG:-${TMPDIR:-/tmp}/claude-tunnel-$(id -u).log}"

# v2.5: every terminal tab shares ONE tunnel, so one hung tunnel used to freeze
# them all. A small background watchdog now owns the ssh process: it restarts
# ssh the moment it exits, and also when the proxy stops answering for
# WATCHDOG_FAILS checks in a row (ssh still alive but the link is dead - typical
# after sleep or a Wi-Fi change). Every tab heals on its own; nobody needs
# cc-stop. 0 = old behaviour (plain 'ssh -f', no auto-restart).
CLAUDE_TUNNEL_WATCHDOG=1
CLAUDE_WATCHDOG_INTERVAL=5      # seconds between health checks
CLAUDE_WATCHDOG_FAILS=2          # failed checks in a row before the tunnel is restarted
CLAUDE_WATCHDOG_IDLE_INTERVAL=60 # seconds between checks while no cc/cx session uses the tunnel

CLAUDE_WATCHDOG_NOTICE_AFTER=60
CLAUDE_WATCHDOG_PROBE_TIMEOUT=3
CLAUDE_WATCHDOG_PROGRESS_INTERVAL=30
CLAUDE_WATCHDOG_MAX_BACKOFF=30
# A freshly started ssh gets this long (its ConnectTimeout 15s + margin) to bring
# the forwards up before failed checks count as an outage or get it killed.
CLAUDE_WATCHDOG_STARTUP_GRACE=20
CLAUDE_DESKTOP_NOTIFICATIONS=auto  # auto or off; never changes CLI input

# --- personal overrides ------------------------------------------------------
if [ -f "$CLAUDE_PROXY_CONF" ]; then
    . "$CLAUDE_PROXY_CONF"
fi
export CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_KEY CLAUDE_SSH_PORT \
       CLAUDE_HTTP_PORT CLAUDE_REMOTE_PROXY_PORT CLAUDE_SOCKS_PORT \
       CLAUDE_SYNC_SETTINGS CLAUDE_SETTINGS CLAUDE_NO_PROXY CLAUDE_PROXY_CONF \
       CLAUDE_PROXY_NODES CLAUDE_NODE_SOCKS_BASE CLAUDE_CHROME_BIN CLAUDE_PROXY_DOMAIN CLAUDE_NODES_FROM \
       CLAUDE_TUNNEL_WATCHDOG CLAUDE_WATCHDOG_INTERVAL CLAUDE_WATCHDOG_FAILS
CLAUDE_TUNNEL_PIDFILE="${CLAUDE_TUNNEL_LOG%.log}.watchdog.pid"

# The keys a conf file may carry (used by proxy-config / migration).
_CLAUDE_CONF_KEYS="CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_KEY CLAUDE_SSH_PORT CLAUDE_HTTP_PORT CLAUDE_REMOTE_PROXY_PORT CLAUDE_SOCKS_PORT CLAUDE_NODE_SOCKS_BASE CLAUDE_NODE_HTTP_BASE CLAUDE_CHROME_BIN CLAUDE_NODES_FROM CLAUDE_PROXY_DOMAIN CLAUDE_SYNC_SETTINGS CLAUDE_SYNC_WINDOWS_SETTINGS CLAUDE_KILLSWITCH CLAUDE_PLAIN_COMMANDS CLAUDE_PROXY_BANNER CLAUDE_TUNNEL_WATCHDOG CLAUDE_WATCHDOG_INTERVAL CLAUDE_WATCHDOG_IDLE_INTERVAL CLAUDE_WATCHDOG_FAILS CLAUDE_WATCHDOG_NOTICE_AFTER CLAUDE_WATCHDOG_PROBE_TIMEOUT CLAUDE_WATCHDOG_PROGRESS_INTERVAL CLAUDE_WATCHDOG_MAX_BACKOFF CLAUDE_WATCHDOG_STARTUP_GRACE CLAUDE_TUNNEL_LOG CLAUDE_DESKTOP_NOTIFICATIONS"

# ============================================================
# Helpers
# ============================================================

# PIDs listening on a TCP port, one per line (empty if none).
# Minimal Linux images ship without lsof; ss -p names the same processes (our own).
_listeners() {
    if command -v lsof >/dev/null 2>&1; then lsof -ti:"$1" -sTCP:LISTEN 2>/dev/null; return 0; fi
    ss -ltnp 2>/dev/null | awk -v port="$1" 'NR > 1 && $4 ~ ("[:.]" port "$")' \
        | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# TCP ports a PID listens on, one per line.
_pid_listen_ports() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -aPn -p "$1" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p' | sort -u
        return 0
    fi
    # "pid=12," never matches pid=123.
    ss -ltnp 2>/dev/null | awk -v pid="pid=$1," 'NR > 1 && index($0, pid) { n = split($4, a, ":"); print a[n] }' | sort -u
}

# Is ANYONE listening on this TCP port - including another user?
# lsof and ss only NAME processes you own, but both still SEE the socket, so
# "can I bind here?" must not be answered from a PID list. A root-owned :8080
# looked FREE to a normal user, so the fallback below never fired and ssh died
# with "bind: Address already in use" seconds AFTER reporting [OK].
_port_bound() {
    local p=$1
    if command -v ss >/dev/null 2>&1; then
        # $4 is "Local Address:Port" ([::1]:8080, 0.0.0.0:8080, *:8080).
        # The [:.] guard stops :80 matching :8080.
        ss -ltn 2>/dev/null | awk -v port="$p" '$4 ~ ("[:.]" port "$") { f = 1 } END { exit !f }'
        return $?
    fi
    # No ss: lsof still sees only our own sockets, but it beats nothing.
    [ -n "$(_listeners "$p")" ]
}

_port_in_use() {
    _port_bound "$1"
}

# Short command name of a PID ("" if gone).
_proc_name() {
    ps -p "$1" -o comm= 2>/dev/null | tr -d ' '
}

_is_ssh_name() {
    case "$1" in ssh|*/ssh) return 0 ;; *) return 1 ;; esac
}

# Number of non-empty lines in $1 (portable: mac's wc pads with spaces).
_count() {
    printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '
}

# Only the ssh PIDs listening on a port.
_ssh_listeners() {
    local p
    for p in $(_listeners "$1"); do
        _is_ssh_name "$(_proc_name "$p")" && echo "$p"
    done
}

# First free port at or after $1 (fails if none within 20).
_find_free_port() {
    local p=$1 end=$(( $1 + 20 ))
    while [ "$p" -lt "$end" ]; do
        if ! _port_in_use "$p"; then
            echo "$p"
            return 0
        fi
        p=$((p+1))
    done
    return 1
}

# Classify what holds the tunnel ports, so callers can HEAL instead of guessing.
# Prints: "ok|down|stale|foreign [pid] [command] [http_port]"
#   ok      - our ssh tunnel is up; the 4th field is where the HTTP forward
#             actually listens (may be a fallback port like 8081)
#   down    - no tunnel, configured HTTP port is free
#   stale   - a broken leftover ssh holds a tunnel port - safe to kill/restart
#   foreign - a NON-ssh app holds the HTTP port - never killed; callers fall
#             back to another port instead
# Anchored on the SOCKS port: its ssh owner identifies OUR tunnel even when the
# HTTP forward went to a fallback port in an earlier shell.
_tunnel_health() {
    local socks_pids http_pids pid name other
    socks_pids=$(_listeners "$CLAUDE_SOCKS_PORT")
    if [ "$(_count "$socks_pids")" -eq 1 ]; then
        pid=$socks_pids
        name=$(_proc_name "$pid")
        if _is_ssh_name "$name"; then
            other=$(_pid_listen_ports "$pid" | grep -vx "$CLAUDE_SOCKS_PORT")
            if [ "$(_count "$other")" -eq 1 ]; then
                echo "ok $pid $name $other"
            elif printf '%s\n' "$other" | grep -qx "$CLAUDE_HTTP_PORT"; then
                echo "ok $pid $name $CLAUDE_HTTP_PORT"
            else
                echo "stale $pid $name"
            fi
            return
        fi
    fi

    # No healthy ssh anchor - classify whatever sits on the configured HTTP port.
    http_pids=$(_listeners "$CLAUDE_HTTP_PORT")
    if [ -z "$http_pids" ]; then
        echo "down"
        return
    fi
    pid=$(printf '%s\n' "$http_pids" | head -1)
    name=$(_proc_name "$pid")
    if _is_ssh_name "$name"; then
        echo "stale $pid $name"
    else
        echo "foreign $pid ${name:-unknown}"
    fi
}

# Does the proxy on a local port actually answer? A listening port is not enough:
# after sleep / a Wi-Fi change ssh can keep the port open while the link is dead.
# Prints: "ok|proxy|dead <curl exit> <CONNECT code> <HTTP code>"
#   ok    - api.anthropic.com answered through the proxy
#   proxy - the VM's proxy answered but the request still failed (refused CONNECT,
#           slow upstream ...) - the TUNNEL is fine, restarting it won't help
#   dead  - nothing came back at all - tunnel hung, or nothing on the VM's proxy port
_proxy_probe() {  # <local port> [timeout seconds]
    local out rc cc hc
    out=$(curl -s -o /dev/null --max-time "${2:-8}" -w '%{http_connect} %{http_code}' \
          -x "http://127.0.0.1:$1" https://api.anthropic.com/ 2>/dev/null)
    rc=$?
    read -r cc hc <<< "$out"
    cc=${cc:-000}; hc=${hc:-000}
    if [ $rc -eq 0 ]; then
        echo "ok $rc $cc $hc"
    elif [ "$cc" != "000" ] || [ "$hc" != "000" ]; then
        echo "proxy $rc $cc $hc"
    else
        echo "dead $rc 000 000"
    fi
}

# ssh arguments that reach the main server: key/port only when set explicitly,
# then the destination. Result in the array _CP_SSH_DEST.
_ssh_dest_args() {
    _CP_SSH_DEST=()
    [ -n "$CLAUDE_SSH_KEY" ] && _CP_SSH_DEST+=(-i "$CLAUDE_SSH_KEY" -p "$CLAUDE_SSH_PORT")
    if [ -n "$CLAUDE_SSH_USER" ]; then _CP_SSH_DEST+=("$CLAUDE_SSH_USER@$CLAUDE_SSH_HOST"); else _CP_SSH_DEST+=("$CLAUDE_SSH_HOST"); fi
}

# The full ssh command line of the main tunnel (without -f). Result in _CP_SSH_ARGS.
# ServerAlive 15s x 3: a dead link makes ssh exit within ~45s (was 3 minutes).
_tunnel_ssh_args() {
    _ssh_dest_args
    _CP_SSH_ARGS=(-N -C
        -L "${CLAUDE_HTTP_PORT}:127.0.0.1:${CLAUDE_REMOTE_PROXY_PORT}"
        -D "${CLAUDE_SOCKS_PORT}"
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=3
        -o ConnectTimeout=15
        -o ExitOnForwardFailure=yes
        -o StrictHostKeyChecking=accept-new
        "${_CP_SSH_DEST[@]}")
}

# BEGIN PROXY RECOVERY
# State is data, never sourced/evaluated. Fields: phase/start/observed/notice/
# retries/next-retry/generation/failure/event. No application PID is signalled.
_recovery_now() {
    local up
    if [ -r /proc/uptime ]; then read -r up _ < /proc/uptime; echo "${up%%.*}"
    else osascript -l JavaScript -e 'ObjC.import("Foundation"); Math.floor($.NSProcessInfo.processInfo.systemUptime);' 2>/dev/null; fi
}
_recovery_step() {
    local phase=healthy start=- observed=0 notice=0 retries=0 next=0 gen=0 failure=healthy old_event kind event=none now="$3" grace="$4"
    [ -z "$1" ] || IFS='|' read -r phase start observed notice retries next gen failure old_event <<< "$1"
    IFS='|' read -r kind _ <<< "$2"
    [ "$now" -ge "$observed" ] || now=$observed
    if [ "$kind" = healthy ]; then
        if [ "$phase" != healthy ]; then event=restored; gen=$((gen+1)); fi
        phase=healthy; start=-; failure=healthy; retries=0; next=0
    else
        failure=$kind
        if [ "$phase" = healthy ]; then phase=recovering; start=$now; event=lost
        elif [ "$phase" = recovering ] && [ $((now-start)) -ge "$grace" ]; then phase=prolonged; event=prolonged
        elif [ $((now-notice)) -ge "${CLAUDE_WATCHDOG_PROGRESS_INTERVAL:-30}" ]; then event=progress; fi
        if [ "$event" != none ]; then notice=$now; gen=$((gen+1)); fi
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$phase" "$start" "$now" "$notice" "$retries" "$next" "$gen" "$failure" "$event"
}
_recovery_message() {  # <event> [pid|name|port, for takeover]
    local pid name port
    case "$1" in
        takeover)
            IFS='|' read -r pid name port <<< "${2:-}"
            echo "Another program (${name:-unknown}, PID $pid) took proxy port $port while the tunnel was down. Claude/Codex traffic may go to it - exit this session now; nothing was stopped." ;;
        lost) echo 'Proxy connection lost. Retrying; proxy settings remain enabled.' ;;
        prolonged) echo 'Proxy is still unavailable. Your session has not been terminated. Keep retrying, or exit normally and resume later.' ;;
        restored) echo 'Proxy connection restored. Your session is still running. Retry any failed request if the application did not retry it automatically.' ;;
        progress) echo 'Proxy recovery is still in progress; retrying without closing your session.' ;;
    esac
}
_recovery_probe() {
    local endpoint out rc cc hc kind=tunnel timeout="${CLAUDE_WATCHDOG_PROBE_TIMEOUT:-3}"
    case "$1" in claude) endpoint=https://api.anthropic.com/ ;; codex) endpoint=https://api.openai.com/ ;; *) return 2;; esac
    if out=$(curl -q -sS -o /dev/null --connect-timeout 2 --max-time "$timeout" --noproxy '' --proxy "http://127.0.0.1:$2" -w '%{http_connect} %{http_code}' "$endpoint" 2>/dev/null); then rc=0; else rc=$?; fi
    read -r cc hc <<< "$out"; cc=${cc:-000}; hc=${hc:-000}
    if [ "$rc" -eq 0 ] && [ "$cc" = 200 ] && [ "$hc" != 000 ]; then kind=healthy
    elif [ "$cc" != 000 ] && [ "$cc" != 200 ]; then kind=proxy
    elif [ "$cc" = 200 ]; then kind=proxy
    else
        # A second, explicitly proxied transport proves whether SSH still works.
        if out=$(curl -q -sS -o /dev/null --connect-timeout 2 --max-time "$timeout" --noproxy '' --proxy '' --socks5-hostname "127.0.0.1:$3" -w '%{http_code}' "$endpoint" 2>/dev/null); then kind=proxy; fi
    fi
    printf '%s|%s|%s|%s|%s\n' "$kind" "$rc" "$cc" "$hc" "$kind"
}
_recovery_process_identity() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$1" 2>/dev/null || return 1
    if [ -r "/proc/$1/stat" ]; then
        # Strip comm (which may contain spaces), then use start ticks since boot.
        sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
        return 0
    fi
    # ps start time is portable to macOS and includes the date (PID reuse guard).
    LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//'
}
_recovery_owner_pid() {
    local pid stamp actual
    [ -r "$1/lock/owner" ] || return 1
    { read -r pid; read -r stamp; } < "$1/lock/owner"
    actual=$(_recovery_process_identity "$pid") || return 1
    [ -n "$stamp" ] && [ "$stamp" = "$actual" ] || return 1
    echo "$pid"
}
_recovery_claim() {
    local dir="$1" pid="$2" stamp candidate snapshot current token gate
    stamp=$(_recovery_process_identity "$pid") || return 1
    mkdir -p "$dir/lock" || return 1
    candidate=$(umask 077; mktemp "$dir/claim.XXXXXX") || return 1
    printf '%s\n%s\n' "$pid" "$stamp" > "$candidate"
    if ln "$candidate" "$dir/lock/owner" 2>/dev/null; then rm -f "$candidate"; return 0; fi
    snapshot=$(cat "$dir/lock/owner" 2>/dev/null) || { rm -f "$candidate"; return 1; }
    if _recovery_owner_pid "$dir" >/dev/null; then rm -f "$candidate"; return 1; fi
    # One reaper for this exact stale generation. Keep its tombstone so a late
    # observer cannot remove a replacement owner's lease. No empty lease window
    # exists during publication: link(2) atomically publishes PID and identity.
    token=$(printf '%s' "$snapshot" | cksum | awk '{print $1}')
    gate="$dir/reaped.$token"
    if ! mkdir "$gate" 2>/dev/null; then rm -f "$candidate"; return 1; fi
    current=$(cat "$dir/lock/owner" 2>/dev/null) || current=''
    if [ "$current" != "$snapshot" ]; then rm -f "$candidate"; return 1; fi
    rm -f "$dir/lock/owner"
    if ln "$candidate" "$dir/lock/owner" 2>/dev/null; then rm -f "$candidate"; return 0; fi
    rm -f "$candidate"; return 1
}
_recovery_release() {
    local pid
    pid=$(_recovery_owner_pid "$1") || return 0
    [ "$pid" = "$2" ] || return 1
    rm -f "$1/lock/owner"; rmdir "$1/lock" 2>/dev/null || :
}
_recovery_signal_owned() {
    local actual
    actual=$(_recovery_process_identity "$1") || return 1
    [ -n "$2" ] && [ "$actual" = "$2" ] || return 1
    kill -TERM "$1" 2>/dev/null
}
# Stop the owner's own ssh without ever blocking on it: a stopped or wedged ssh
# leaves SIGTERM pending, and 'wait' on it would hang the owner - and recovery for
# every terminal. TERM, then KILL after 5s. A zombie (exited, not yet reaped) is gone.
_recovery_stop_ssh() {  # <pid> <start identity>
    local i=0
    _recovery_signal_owned "$1" "$2" || return 0
    while [ "$(_recovery_process_identity "$1" 2>/dev/null)" = "$2" ] && [ "$i" -lt 50 ]; do
        case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) break;; esac
        sleep .1; i=$((i+1))
    done
    if [ "$i" -ge 50 ]; then kill -KILL "$1" 2>/dev/null || :; fi
    wait "$1" 2>/dev/null || :
}
_recovery_retry_record() { printf '%s\n' "$1" | awk -F'|' -v OFS='|' -v n="$2" -v t="$3" '{$5=n;$6=t;print}'; }
_recovery_root() { echo "${XDG_STATE_HOME:-$HOME/.local/state}/claude-proxy/recovery"; }
# One owner per user and slot. The slot is 'main' (the default node on the main
# ports). It must NOT depend on host or ports: a terminal with stale settings
# would otherwise get its own owner and fight the live one for the same ports.
_recovery_identity() {
    local root slot="${1:-main}"
    root=$(_recovery_root)
    (umask 077; mkdir -p "$root/$slot") || return 1
    chmod 700 "$root" "$root/$slot" || return 1
    printf '%s/%s\n' "$root" "$slot"
}
# The live owner publishes the tunnel it runs as key=value lines. Read back as
# literal text (never eval'd), so a value cannot execute anything.
_recovery_record_write() {
    _recovery_write "$1/tunnel.rec" "$(printf 'host=%s\nuser=%s\nport=%s\nkey=%s\nhttp=%s\nsocks=%s\nremote=%s' \
        "$CLAUDE_SSH_HOST" "$CLAUDE_SSH_USER" "$CLAUDE_SSH_PORT" "$CLAUDE_SSH_KEY" \
        "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT" "$CLAUDE_REMOTE_PROXY_PORT")" rec
}
_recovery_record_get() { sed -n "s/^$2=//p" "$1/tunnel.rec" 2>/dev/null | head -1; }
# A terminal whose settings are stale (old conf, fallback port, another node)
# must use the tunnel that is actually running, not recompute its own.
# Adopts only while the owner is live; otherwise changes nothing.
_recovery_adopt() {
    local dir="${1:-}" v
    [ -n "$dir" ] || dir=$(_recovery_identity) || return 1
    _recovery_owner_pid "$dir" >/dev/null || return 1
    [ -r "$dir/tunnel.rec" ] || return 1
    v=$(_recovery_record_get "$dir" host);   [ -z "$v" ] || CLAUDE_SSH_HOST=$v
    CLAUDE_SSH_USER=$(_recovery_record_get "$dir" user)
    v=$(_recovery_record_get "$dir" port);   [ -z "$v" ] || CLAUDE_SSH_PORT=$v
    CLAUDE_SSH_KEY=$(_recovery_record_get "$dir" key)
    v=$(_recovery_record_get "$dir" http);   [ -z "$v" ] || CLAUDE_HTTP_PORT=$v
    v=$(_recovery_record_get "$dir" socks);  [ -z "$v" ] || CLAUDE_SOCKS_PORT=$v
    v=$(_recovery_record_get "$dir" remote); [ -z "$v" ] || CLAUDE_REMOTE_PROXY_PORT=$v
    export CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_PORT CLAUDE_SSH_KEY \
           CLAUDE_HTTP_PORT CLAUDE_SOCKS_PORT CLAUDE_REMOTE_PROXY_PORT
}
# Why an ssh exited, from its own stderr: auth|hostkey|forward|network|unknown.
# Auth and hostkey failures will not heal by retrying, so the owner waits longer
# for them; network trouble retries at the normal pace.
_recovery_ssh_class() {
    local f="$1"
    [ -s "$f" ] || { echo unknown; return; }
    if grep -qiE 'host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' "$f"; then echo hostkey
    elif grep -qiE 'permission denied|too many authentication failures|load key|no such identity|bad permissions' "$f"; then echo auth
    elif grep -qiE 'address already in use|cannot listen to port|could not request local forwarding|forwarding failed' "$f"; then echo forward
    elif grep -qiE 'timed out|could not resolve|connection refused|no route to host|network is unreachable|connection closed|connection reset|broken pipe' "$f"; then echo network
    else echo unknown
    fi
}
_recovery_ssh_hint() {  # <class> <server>
    case "$1" in
        auth)    echo "SSH login to $2 was refused - load your key (ssh-add <key>) or check the user name, then 'proxy-restart'." ;;
        hostkey) echo "The host key of $2 changed. If your admin expected that: ssh-keygen -R $2, then run 'ssh $2' once." ;;
        forward) echo "A tunnel port is held by another program - see 'proxy-status'." ;;
        network) echo "Cannot reach $2 - network down, Wi-Fi changed, or the server is offline. Retrying." ;;
        *)       echo "ssh to $2 exited without a known reason - see $CLAUDE_TUNNEL_LOG" ;;
    esac
}
# Last exit reason, as 'class|time|last stderr line' (read by proxy-status and terminals).
_recovery_ssh_note() {  # <dir> <class> <now>
    local last
    last=$(tail -n 1 "$1/ssh.err" 2>/dev/null | tr -d '\r|')
    _recovery_write "$1/ssh.status" "$2|$3|$last" ssh
}
_recovery_status() { case "$2" in claude|codex) cat "$1/$2.state" 2>/dev/null;; *) return 1;; esac; }
_recovery_write() {
    local target="$1" value="$2" tmp="$1.tmp.$3"
    (umask 077; printf '%s\n' "$value" > "$tmp") && mv -f "$tmp" "$target"
}
_recovery_owner_stop() {
    local pid stamp dir="$1" i=0
    # Revoke first: even if the monitor is between retries it cannot respawn.
    : > "$dir/stopped"
    if pid=$(_recovery_owner_pid "$dir"); then
        stamp=$(sed -n '2p' "$dir/lock/owner")
        _recovery_signal_owned "$pid" "$stamp" || :
        while _recovery_owner_pid "$dir" >/dev/null && [ "$i" -lt 100 ]; do sleep .1; i=$((i+1)); done
        _recovery_owner_pid "$dir" >/dev/null && return 1
    fi
    return 0
}
# A tunnel started by an older profile (ssh on our ports, nothing that can heal it)
# is replaced by one with an owner, on the same ports. Only that ssh and the old
# watchdog are stopped; a foreign program on the ports is never touched.
_recovery_migrate() {
    local i=0 state
    state=$(_tunnel_health | awk '{print $1}')
    case "$state" in
        ok|stale|down) ;;
        *) echo "[Err] Port $CLAUDE_HTTP_PORT or $CLAUDE_SOCKS_PORT is used by another program - see proxy-status." >&2; return 1 ;;
    esac
    echo '[Upgrade] Replacing the tunnel from an older profile with a self-healing one on the same ports (open sessions reconnect within seconds).' >&2
    tunnel-stop >/dev/null 2>&1 || { echo '[Err] The old tunnel could not be stopped - run proxy-doctor.' >&2; return 1; }
    while { _port_in_use "$CLAUDE_HTTP_PORT" || _port_in_use "$CLAUDE_SOCKS_PORT"; } && [ "$i" -lt 50 ]; do sleep .1; i=$((i+1)); done
    if _port_in_use "$CLAUDE_HTTP_PORT" || _port_in_use "$CLAUDE_SOCKS_PORT"; then
        echo "[Err] Ports $CLAUDE_HTTP_PORT / $CLAUDE_SOCKS_PORT did not free up after the old tunnel stopped - run proxy-doctor." >&2
        return 1
    fi
}
_recovery_owner_start() {
    local dir pid i=0
    dir=$(_recovery_identity) || return 1
    if ! _recovery_owner_pid "$dir" >/dev/null; then
        if _legacy_watchdog_pid >/dev/null 2>&1 || _port_in_use "$CLAUDE_HTTP_PORT" || _port_in_use "$CLAUDE_SOCKS_PORT"; then
            _recovery_migrate || return 1
        fi
        rm -f "$dir/stopped"
        ( _recovery_worker "$dir" ) </dev/null >>"$CLAUDE_TUNNEL_LOG" 2>&1 &
        disown 2>/dev/null || :
        while ! _recovery_owner_pid "$dir" >/dev/null && [ "$i" -lt 30 ]; do sleep .1; i=$((i+1)); done
        _recovery_owner_pid "$dir" >/dev/null || return 1
    fi
    echo "$dir"
}
# First listener on a tunnel port that is not our ssh, as 'pid|name|port'.
# A socket with no visible PID (another user's) counts only while our ssh is
# down - otherwise it is our own forward, seen without lsof.
_recovery_port_conflict() {  # <owned ssh pid>
    local pid port alive=0
    _recovery_process_identity "$1" >/dev/null 2>&1 && alive=1
    for port in "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT"; do
        for pid in $(_listeners "$port"); do
            [ "$pid" = "$1" ] || { printf '%s|%s|%s\n' "$pid" "$(_proc_name "$pid" | tr -d '|')" "$port"; return 0; }
        done
        if [ "$alive" -eq 0 ] && [ -z "$(_listeners "$port")" ] && _port_bound "$port"; then
            printf "%s|another user's program|%s\n" - "$port"; return 0
        fi
    done
    return 1
}
_recovery_worker() {
    local dir="$1" me spid='' stamp='' sshat=0 connecting now next=0 delay=2 retries=0 fails=0 provider sample state old event gen prior all_tunnel all_healthy conflict
    local takeover cinfo conflict_seen=''
    local classified=1 sshclass='' lastclass=''
    local desktop_backend desktop_state='' desktop_event=none desktop_result=not-tested cs xs scope
    me=$(sh -c 'echo $PPID')
    _recovery_claim "$dir" "$me" || return 0
    _recovery_record_write "$dir"
    trap '' HUP
    trap '_recovery_stop_ssh "$spid" "$stamp"; rm -f "$dir/ssh.status" "$dir/takeover" "$dir/ssh.pid"; _recovery_release "$dir" "$me"; exit 0' TERM INT
    _tunnel_ssh_args
    desktop_backend=$(_recovery_desktop_backend)
    [ "$desktop_backend" != off ] || desktop_result=off
    while [ ! -e "$dir/stopped" ]; do
        now=$(_recovery_now)
        conflict=0 takeover=0
        if cinfo=$(_recovery_port_conflict "$spid"); then
            conflict=1
            # A new program on our port is announced once, loudly; it is never killed.
            if [ "$cinfo" != "$conflict_seen" ]; then takeover=1; conflict_seen=$cinfo; _recovery_write "$dir/takeover" "$cinfo" "$me"; fi
        else
            conflict_seen=''; rm -f "$dir/takeover"
        fi
        if [ "$classified" -eq 0 ] && ! _recovery_process_identity "$spid" >/dev/null; then
            # The ssh we started has exited: record why before deciding on a retry.
            sshclass=$(_recovery_ssh_class "$dir/ssh.err")
            _recovery_ssh_note "$dir" "$sshclass" "$now"
            if [ "$sshclass" != "$lastclass" ]; then
                echo "[ssh] $sshclass: $(_recovery_ssh_hint "$sshclass" "$CLAUDE_SSH_HOST")"
                if [ -s "$dir/ssh.err" ]; then tail -n 5 "$dir/ssh.err" | sed 's/^/[ssh]   /'; fi
                lastclass=$sshclass
            fi
            classified=1
            case "$sshclass" in auth|hostkey) next=$((now+${CLAUDE_WATCHDOG_MAX_BACKOFF:-30}));; esac
        fi
        if ! _recovery_process_identity "$spid" >/dev/null; then
            if [ "$now" -ge "$next" ] && [ "$conflict" -eq 0 ]; then
                ssh -o BatchMode=yes "${_CP_SSH_ARGS[@]}" 2>"$dir/ssh.err" & spid=$!
                classified=0
                stamp=$(_recovery_process_identity "$spid") || stamp=''; sshat=$now
                # Published so launch checks can tell our ssh from anything else on the port.
                _recovery_write "$dir/ssh.pid" "$spid|$stamp" "$me"
                retries=$((retries+1)); next=$((now+delay))
                delay=$((delay*2)); [ "$delay" -le "${CLAUDE_WATCHDOG_MAX_BACKOFF:-30}" ] || delay=${CLAUDE_WATCHDOG_MAX_BACKOFF:-30}
            fi
        fi
        # A live ssh younger than the grace may still be connecting: its dead
        # checks are neither an outage notice nor a reason to kill it.
        connecting=0
        if [ $((now-sshat)) -lt "${CLAUDE_WATCHDOG_STARTUP_GRACE:-20}" ] && _recovery_process_identity "$spid" >/dev/null; then connecting=1; fi
        all_tunnel=1 all_healthy=1
        for provider in claude codex; do
            if [ "$conflict" -eq 1 ]; then sample='conflict|0|000|000|local-port-conflict'
            else sample=$(_recovery_probe "$provider" "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT"); fi
            case "$sample" in healthy\|*) :;; *) all_healthy=0;; esac
            case "$connecting:$sample" in 1:tunnel\|*) all_tunnel=0; continue;; esac
            case "$sample" in tunnel\|*) :;; *) all_tunnel=0;; esac
            case "$sample" in healthy\|*) delay=2; retries=0; rm -f "$dir/ssh.status"; lastclass='';; esac
            old=$(_recovery_status "$dir" "$provider") || old=''
            state=$(_recovery_step "$old" "$sample" "$now" "${CLAUDE_WATCHDOG_NOTICE_AFTER:-60}")
            event=$(printf '%s' "$state" | cut -d'|' -f9)
            if [ "$takeover" -eq 1 ]; then
                # Overrides lost/progress: this is the notice terminals must show.
                [ "$event" != none ] || state=$(printf '%s\n' "$state" | awk -F'|' -v OFS='|' '{$7=$7+1;print}')
                state="${state%|*}|takeover"
                [ "$provider" != claude ] || printf '[Recovery] %s\n' "$(_recovery_message takeover "$cinfo")"
            elif [ "$event" = none ] && [ -n "$old" ]; then
                prior=$(printf '%s' "$old" | cut -d'|' -f9)
                state="${state%|*}|$prior"
            elif [ "$event" != none ]; then
                [ "$conflict" -eq 0 ] || echo '[Recovery] Local port conflict: keeping the fixed ports and leaving the other process untouched.'
                printf '[%s] %s\n' "$provider" "$(_recovery_message "$event")"
            fi
            state=$(_recovery_retry_record "$state" "$retries" "$next")
            _recovery_write "$dir/$provider.state" "$state" "$me"
        done
        cs=$(_recovery_status "$dir" claude) || cs=''; xs=$(_recovery_status "$dir" codex) || xs=''
        # Nothing observed yet (ssh still connecting) is not "unavailable".
        [ -z "$cs$xs" ] || desktop_state=$(_recovery_desktop_step "$desktop_state" "$cs" "$xs" "$now" "${CLAUDE_WATCHDOG_NOTICE_AFTER:-60}")
        case "$takeover:$cs$xs:${desktop_state##*|}" in
            1:*)
                desktop_event=takeover
                if [ "$desktop_backend" != off ]; then
                    if _recovery_desktop_send "$desktop_backend" takeover "$cinfo"; then desktop_result=submitted; else desktop_result=failed; fi
                fi;;
            0::*) :;;
            *:lost|*:prolonged|*:restored)
                desktop_event=${desktop_state##*|}; scope=$(_recovery_desktop_scope "$cs" "$xs")
                if [ "$desktop_backend" != off ]; then
                    if _recovery_desktop_send "$desktop_backend" "$desktop_event" "$scope"; then desktop_result=submitted
                    else desktop_result=failed; echo '[Notify] Desktop submission unavailable or failed; terminal/status/log fallbacks remain enabled. Try proxy-notify test.'; fi
                fi;;
        esac
        _recovery_write "$dir/desktop.status" "$desktop_backend|$desktop_result|$desktop_event|$now" "$me"
        if [ "$all_tunnel" -eq 1 ]; then fails=$((fails+1)); else fails=0; fi
        if [ "$fails" -ge "${CLAUDE_WATCHDOG_FAILS:-2}" ]; then
            _recovery_stop_ssh "$spid" "$stamp"; spid=''; stamp=''; fails=0
        fi
        # Nobody to protect and nothing to heal: probe rarely (Chrome may still use it).
        if [ "$all_healthy" -eq 1 ] && [ "$(_recovery_sessions "$dir")" -eq 0 ]; then
            _recovery_idle_sleep "${CLAUDE_WATCHDOG_IDLE_INTERVAL:-60}" "$dir" "$spid"
        else
            _wd_sleep "${CLAUDE_WATCHDOG_INTERVAL:-5}"
        fi
    done
    _recovery_stop_ssh "$spid" "$stamp"
    rm -f "$dir/ssh.status" "$dir/takeover" "$dir/ssh.pid"
    _recovery_release "$dir" "$me"
}
# Live cc/cx sessions on a slot. Each subscriber is one session; its entry holds
# the subscriber's start identity, so a dead or reused PID never counts.
_recovery_sessions() {  # <dir>
    local f pid stamp n=0
    # ls, not a glob: an empty directory is a fatal "no matches found" in zsh.
    # Entries are PIDs, so word splitting is safe.
    for pid in $(ls "$1/sessions" 2>/dev/null); do
        f="$1/sessions/$pid"
        [ -f "$f" ] || continue
        stamp=''
        read -r stamp < "$f" 2>/dev/null || :
        if [ -n "$stamp" ] && [ "$(_recovery_process_identity "$pid" 2>/dev/null)" = "$stamp" ]; then n=$((n+1)); else rm -f "$f"; fi
    done
    echo "$n"
}
# Sleep between probes while nobody uses the tunnel; end early when a terminal
# asks (<dir>/wake), a session starts, or the owned ssh exits.
_recovery_idle_sleep() {  # <seconds> <dir> [ssh pid]
    local i=0 dir="$2"
    while [ "$i" -lt "$1" ]; do
        if [ -e "$dir/wake" ]; then rm -f "$dir/wake"; return 0; fi
        [ "$(_recovery_sessions "$dir")" -eq 0 ] || return 0
        [ -z "${3:-}" ] || kill -0 "$3" 2>/dev/null || return 0
        _wd_sleep 1; i=$((i+1))
    done
}
_recovery_subscribe() {
    local dir="$1" provider="$2" parent stamp sub
    parent=$$; stamp=$(_recovery_process_identity "$parent")
    (
        local me
        me=$(sh -c 'echo $PPID')
        trap 'rm -f "$dir/sessions/$me"; exit 0' TERM
        trap '' HUP
        local state gen event phase seen=-1 sshwhy seenssh=''
        while [ "$(_recovery_process_identity "$parent")" = "$stamp" ]; do
            sshwhy=$(cut -d'|' -f1 "$dir/ssh.status" 2>/dev/null) || sshwhy=''
            if [ "$sshwhy" != "$seenssh" ]; then
                case "$sshwhy" in auth|hostkey) printf '\n[%s proxy] %s\n' "$provider" "$(_recovery_ssh_hint "$sshwhy" "$CLAUDE_SSH_HOST")" >&2;; esac
                seenssh=$sshwhy
            fi
            state=$(_recovery_status "$dir" "$provider") || state=''
            if [ -n "$state" ]; then
                IFS='|' read -r phase _ _ _ _ _ gen _ event <<< "$state"
                if [ "$gen" != "$seen" ]; then
                    if [ "$seen" != -1 ] || [ "$phase" != healthy ]; then
                        printf '\n[%s proxy] %s\n' "$provider" "$(_recovery_message "$event" "$(cat "$dir/takeover" 2>/dev/null)")" >&2
                    fi
                    seen=$gen
                fi
            fi
            sleep 1 & wait $! || :
        done
        rm -f "$dir/sessions/$me"
    ) </dev/null >/dev/null &
    sub=$!
    # Registered here, before cc launches, so an idle owner sees the session at once.
    (umask 077; mkdir -p "$dir/sessions" && _recovery_process_identity "$sub" > "$dir/sessions/$sub") 2>/dev/null || :
    echo "$sub"
}
_recovery_unsubscribe() {
    # Caller supplies the start identity captured immediately after subscribing.
    _recovery_signal_owned "$1" "$2" || :
}
_recovery_demo_sleep() { sleep "$1"; }
proxy-test() {
    local scenario="${1:-}" fast=0 desktop=0 backend='' t end=20 state='' kind event retries=0 tick=5
    local usage='usage: proxy-test <recover|prolonged> [--fast] [--desktop]'
    case "$scenario" in recover) end=20;; prolonged) end=80;; *) echo "$usage"; return 2;; esac
    shift
    while [ $# -gt 0 ]; do
        case "$1" in --fast|-Fast) fast=1; tick=.5;; --desktop|-Desktop) desktop=1;; *) echo "$usage"; return 2;; esac
        shift
    done
    echo '[SIMULATION] Isolated in-memory demo; no real SSH, CLI, network, or settings changes.'
    [ "$fast" -eq 0 ] || echo '[SIMULATION] Fast mode: 60 simulated seconds = 6 wall-clock seconds.'
    if [ "$desktop" -eq 1 ]; then
        backend=$(_recovery_desktop_backend)
        echo "[SIMULATION] Real desktop alerts enabled ($backend); proxy/network/session actions remain simulated."
    fi
    for ((t=0; t<=end; t+=5)); do
        kind=healthy
        if [ "$t" -ge 5 ] && [ "$t" -lt "$end" ]; then kind=tunnel; retries=$((retries+1)); fi
        state=$(_recovery_step "$state" "$kind|0|000|000|simulation" "$t" 60)
        event=$(printf '%s' "$state" | cut -d'|' -f9)
        [ "$event" = none ] || printf '[SIMULATION] t=%s %s\n' "$t" "$(_recovery_message "$event")"
        if [ "$desktop" -eq 1 ]; then
            case "$event" in lost|prolonged|restored)
                if ! _recovery_desktop_send "$backend" "$event" 'Claude and Codex' 1; then echo '[SIMULATION] Desktop submission unavailable/failed; use proxy-notify status and check OS notification settings.'; fi;;
            esac
        fi
        [ "$kind" = healthy ] || printf '[SIMULATION] t=%s simulated retry %s; session stays open.\n' "$t" "$retries"
        [ "$t" -eq "$end" ] || _recovery_demo_sleep "$tick" || return
    done
    echo '[SIMULATION] Complete; no user session was launched or closed.'
}

# Desktop alerts belong to the shared owner, never to individual CLI windows.
_recovery_desktop_step() {
    local kind=unavailable
    case "$2:$3" in healthy\|*:healthy\|*) kind=healthy;; esac
    _recovery_step "$1" "$kind" "$4" "$5"
}
_recovery_desktop_scope() {
    case "$1:$2" in
        healthy\|*:healthy\|*) echo 'Claude and Codex';;
        healthy\|*:*) echo Codex;;
        *:healthy\|*) echo Claude;;
        *) echo 'Claude and Codex';;
    esac
}
_recovery_desktop_backend() {
    case "${CLAUDE_DESKTOP_NOTIFICATIONS:-auto}" in off|0) echo off; return;; auto|1) :;; *) echo invalid-setting; return;; esac
    case "$(uname)" in
        Darwin) if command -v osascript >/dev/null 2>&1; then echo macos; else echo unavailable; fi;;
        Linux)
            if command -v notify-send >/dev/null 2>&1 && { [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; }; then echo linux
            else echo unavailable; fi;;
        *) echo unavailable;;
    esac
}
_recovery_desktop_message() {
    local pid name port
    case "$1" in
        takeover)
            IFS='|' read -r pid name port <<< "$2"
            printf 'Proxy port taken|%s (PID %s) took port %s. Exit Claude/Codex sessions now.\n' "${name:-unknown}" "$pid" "$port";;
        lost) printf 'Proxy connection lost|%s: reconnecting. Sessions stay open.\n' "$2";;
        prolonged) printf 'Proxy still unavailable|%s: retrying for a prolonged outage. Keep waiting or exit normally; sessions stay open.\n' "$2";;
        restored) printf 'Proxy connection restored|%s: connected again. Retry any failed request your CLI did not retry.\n' "$2";;
        test) echo '[TEST] Proxy desktop notifications|This is a test. No proxy, network, or session was changed.';;
        *) return 1;;
    esac
}
_recovery_desktop_cancel() {
    local pid="$1" stamp="$2" actual n=0
    [ -n "$pid" ] && [ -n "$stamp" ] || return 0
    if _recovery_signal_owned "$pid" "$stamp"; then
        while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep .05; n=$((n+1)); done
    fi
    actual=$(_recovery_process_identity "$pid") || actual=''
    if [ -n "$actual" ] && [ "$actual" = "$stamp" ]; then
        kill -KILL "$pid" 2>/dev/null || :
    fi
    wait "$pid" 2>/dev/null || :
}
_recovery_desktop_exec() (
    # Isolate cancellation traps from the shell/CLI and own only this OS adapter.
    local pid='' stamp='' n=0 rc
    trap '_recovery_desktop_cancel "$pid" "$stamp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    "$@" </dev/null >/dev/null 2>&1 & pid=$!
    stamp=$(_recovery_process_identity "$pid") || stamp=''
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do sleep .1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then return 1; fi
    if wait "$pid"; then return 0; else rc=$?; return "$rc"; fi
)
_recovery_desktop_send() {
    local backend="$1" event="$2" scope="$3" title body icon=network-error
    IFS='|' read -r title body <<< "$(_recovery_desktop_message "$event" "$scope")"
    [ -n "$title" ] || return 1
    [ "${4:-0}" != 1 ] || title="[SIMULATION] $title"
    case "$backend" in
        linux)
            case "$event" in restored|test) icon=network-transmit-receive;; esac
            _recovery_desktop_exec notify-send --app-name='Claude Proxy' --urgency=normal --expire-time=10000 --icon="$icon" -- "$title" "$body";;
        macos)
            # Pass all text as argv; never interpolate notification text into code.
            _recovery_desktop_exec osascript -e 'on run argv
                display notification (item 2 of argv) with title (item 1 of argv)
            end run' -- "$title" "$body";;
        *) return 1;;
    esac
}
proxy-notify() {
    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    local action="${1:-status}" backend identity result
    [ $# -le 1 ] || { echo 'usage: proxy-notify [status|test]'; return 2; }
    case "$action" in status|test) :;; *) echo 'usage: proxy-notify [status|test]'; return 2;; esac
    backend=$(_recovery_desktop_backend)
    echo "[Notify] Desktop backend: $backend (setting: ${CLAUDE_DESKTOP_NOTIFICATIONS:-auto})."
    if [ "$backend" = unavailable ] || [ "$backend" = invalid-setting ]; then
        echo '[Notify] Requires macOS osascript, or Linux notify-send and a desktop D-Bus session. Headless/SSH/WSL shells may have no desktop service.'
    fi
    if [ "$action" = test ]; then
        if _recovery_desktop_send "$backend" test 'Claude and Codex'; then
            echo '[Notify] Test submitted to the desktop. Confirm you saw it; OS notification settings can hide it.'
        else
            echo '[Notify] Test could not be submitted. Terminal warnings, proxy-status, and logs remain available.'
            return 1
        fi
    else
        identity=$(_recovery_identity) || return 1
        if [ -r "$identity/desktop.status" ]; then
            printf '[Notify] Last owner result (backend | submission | event | observed): '
            cat "$identity/desktop.status"
        fi
        echo '[Notify] Try proxy-notify test in another terminal while cc/cx is open. Desktop alerts never take over CLI input.'
    fi
}
# END PROXY RECOVERY

# Compatibility entry points all delegate to the single recovery owner.
_legacy_watchdog_pid() {
    local pid
    [ -n "${CLAUDE_TUNNEL_PIDFILE:-}" ] && [ -f "$CLAUDE_TUNNEL_PIDFILE" ] && [ ! -L "$CLAUDE_TUNNEL_PIDFILE" ] && [ -O "$CLAUDE_TUNNEL_PIDFILE" ] || return 1
    read -r pid < "$CLAUDE_TUNNEL_PIDFILE"
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    _recovery_process_identity "$pid" >/dev/null || return 1
    case "$(_proc_name "$pid")" in *sh) echo "$pid";; *) return 1;; esac
}
_legacy_watchdog_stop() {
    local pid stamp child parent found=0 i=0
    pid=$(_legacy_watchdog_pid) || return 0
    # The old PID file has no start identity. Prove parentage to a tunnel SSH
    # before authorising its removal, so a reused shell PID is never enough.
    for child in $(_ssh_listeners "$CLAUDE_HTTP_PORT"); do
        parent=$(ps -p "$child" -o ppid= 2>/dev/null | tr -d ' ')
        [ "$parent" != "$pid" ] || found=1
    done
    [ "$found" -eq 1 ] || { echo '[Err] Legacy watchdog identity cannot be verified. Stop it from its old shell before retrying.' >&2; return 1; }
    stamp=$(_recovery_process_identity "$pid") || return 1
    _recovery_signal_owned "$pid" "$stamp" || return 1
    while _recovery_process_identity "$pid" >/dev/null && [ "$i" -lt 100 ]; do sleep .1; i=$((i+1)); done
    _recovery_process_identity "$pid" >/dev/null && return 1
    rm -f "$CLAUDE_TUNNEL_PIDFILE"
    return 0
}
_watchdog_pid() { local dir; dir=$(_recovery_identity) && _recovery_owner_pid "$dir"; }
# Live owners in every state directory (this slot and any left by older versions).
_recovery_owned_dirs() {
    local d
    find "$(_recovery_root)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
        _recovery_owner_pid "$d" >/dev/null && printf '%s\n' "$d"
    done
}
_recovery_stop_owners() {
    local d rc=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        _recovery_owner_stop "$d" || rc=1
    done <<< "$(_recovery_owned_dirs)"
    return $rc
}
_wd_sleep() { sleep "$1" & wait $!; }
_wd_log() { echo "[watchdog] $*" >> "$CLAUDE_TUNNEL_LOG"; }
_tunnel_watchdog() { local dir; dir=$(_recovery_identity) && _recovery_worker "$dir"; }
_watchdog_spawn() { _recovery_owner_start claude >/dev/null; }
_watchdog_stop() { local dir; dir=$(_recovery_identity) && _recovery_owner_stop "$dir"; }

# PIDs of Claude / Codex sessions running anywhere (other tabs, IDEs ...).
# The [e]/[x] keep this awk from matching its own command line.
_other_agents() {
    ps -Ao pid=,args= 2>/dev/null | awk '{ b = $2; sub(/.*\//, "", b) }
        b == "claude" || b == "codex" || $0 ~ /anthropic-ai.claude-cod[e]|openai.code[x]/ { print $1 }'
}

_is_wsl() {
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

# WSL: the Windows user's ~/.claude/settings.json as a Linux path ("" if unknown).
_win_claude_settings() {
    _is_wsl || return 1
    local cmd up
    cmd=$(command -v cmd.exe || echo /mnt/c/Windows/System32/cmd.exe)
    [ -x "$cmd" ] || return 1
    up=$("$cmd" /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')
    [ -n "$up" ] || return 1
    up=$(wslpath -u "$up" 2>/dev/null) || return 1
    echo "$up/.claude/settings.json"
}

# All settings.json files the proxy should be written into.
_settings_targets() {
    echo "$CLAUDE_SETTINGS"
    if [ "${CLAUDE_SYNC_WINDOWS_SETTINGS:-0}" = "1" ]; then
        _win_claude_settings || echo "[Warn] CLAUDE_SYNC_WINDOWS_SETTINGS=1 but the Windows home folder could not be found (not WSL, or cmd.exe unavailable)" >&2
    fi
}

_ensure_ssh_agent() {
    # A backgrounded 'ssh -f' cannot answer a passphrase prompt, and WSL keeps no
    # ssh-agent across shells by default (no systemd unless you enabled it). Make
    # sure an agent is up with the key loaded so the tunnel won't silently hang.
    ssh-add -l >/dev/null 2>&1
    local rc=$?          # 0 = agent + keys, 1 = agent but no keys, 2 = no agent reachable
    if [ $rc -eq 2 ]; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1
    fi
    if [ $rc -ne 0 ] && [ -n "$CLAUDE_SSH_KEY" ]; then
        ssh-add "$CLAUDE_SSH_KEY" 2>/dev/null
    fi
}

# Hosts Claude and Codex talk to. A NO_PROXY entry matching any of them would
# send that traffic DIRECT, from the user's real IP (telemetry included).
_CLAUDE_API_HOSTS="api.anthropic.com claude.ai statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com"

# API hosts a NO_PROXY list exempts, one per line (nothing when it is safe).
# Same rules as curl and Node's proxy-from-env: '*' is everything; an entry
# matches the host itself and its subdomains; a leading '*' or '.' and a ':port'
# are ignored; IP ranges never match a host name.
_noproxy_exempts() {  # <NO_PROXY list>
    local list h e
    list=$(printf '%s' "$1" | tr 'A-Z,' 'a-z\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/:[0-9]*$//')
    for h in $(echo "$_CLAUDE_API_HOSTS"); do   # zsh does not split a bare $var
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            if [ "$e" = '*' ]; then echo "$h"; break; fi
            e=${e#\*}; e=${e#.}
            [ -n "$e" ] || continue
            case "$h" in "$e"|*".$e") echo "$h"; break;; esac
        done <<< "$list"
    done
}

# --- Claude settings.json sync (toggle-synced with the proxy) ---------------
# Does this settings.json already carry exactly our proxy? (Then never rewrite it.)
_settings_file_pinned() {  # <settings.json>
    jq -e --arg url "http://127.0.0.1:$CLAUDE_HTTP_PORT" --arg np "$CLAUDE_NO_PROXY" \
        '.env.HTTPS_PROXY == $url and .env.HTTP_PROXY == $url and .env.NO_PROXY == $np' "$1" >/dev/null 2>&1
}

_settings_file_proxy_on() {  # <settings.json>
    local f="$1" url="http://127.0.0.1:$CLAUDE_HTTP_PORT" tmp
    _settings_file_pinned "$f" && return 0
    mkdir -p "$(dirname "$f")"
    [ -f "$f" ] || echo '{}' > "$f"
    cp "$f" "${f}.bak" 2>/dev/null
    tmp=$(mktemp)
    if jq --arg url "$url" --arg np "$CLAUDE_NO_PROXY" \
        '.env = (.env // {}) | .env.HTTPS_PROXY=$url | .env.HTTP_PROXY=$url | .env.NO_PROXY=$np' \
        "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
        echo "[OK] Proxy written into $f (env block)"
    else
        rm -f "$tmp"
        echo "[Warn] Could not update $f (invalid JSON?) - left it untouched"
        return 1
    fi
}

_settings_file_proxy_off() {  # <settings.json>
    local f="$1" tmp
    [ -f "$f" ] || return 0
    cp "$f" "${f}.bak" 2>/dev/null
    tmp=$(mktemp)
    if jq 'if .env then .env |= del(.HTTPS_PROXY, .HTTP_PROXY, .NO_PROXY) else . end' \
        "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f"
        echo "[OK] Proxy removed from $f"
    else
        rm -f "$tmp"
    fi
}

_claude_settings_proxy_on() {
    [ "${CLAUDE_SYNC_SETTINGS:-0}" = "1" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        echo "[Info] jq not found - skipping ~/.claude/settings.json sync (shell env vars still set)"
        return 0
    fi
    local f
    for f in $(_settings_targets); do _settings_file_proxy_on "$f"; done
}

_claude_settings_proxy_off() {
    [ "${CLAUDE_SYNC_SETTINGS:-0}" = "1" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local f
    for f in $(_settings_targets); do _settings_file_proxy_off "$f"; done
}

# Anything but an explicit "off" counts as on: a typo must not open a leak.
_killswitch_on() { [ "${CLAUDE_KILLSWITCH:-on}" != off ]; }

# What Claude's own settings say: 'pinned <port>' (exactly our proxy),
# 'mismatch <port>' (a proxy, but not ours), or 'unpinned sync-off|no-jq|missing'.
_killswitch_pin_state() {
    local url port
    [ "${CLAUDE_SYNC_SETTINGS:-0}" = 1 ] || { echo 'unpinned sync-off'; return; }
    command -v jq >/dev/null 2>&1 || { echo 'unpinned no-jq'; return; }
    url=$(jq -r '.env.HTTPS_PROXY // empty' "$CLAUDE_SETTINGS" 2>/dev/null)
    [ -n "$url" ] || { echo 'unpinned missing'; return; }
    port=${url%/}; port=${port##*:}
    if _settings_file_pinned "$CLAUDE_SETTINGS"; then echo "pinned $port"; else echo "mismatch $port"; fi
}

# Pin every Claude settings file that is missing or wrong; silent when all are right.
_killswitch_ensure_pin() {
    _killswitch_on && [ "${CLAUDE_SYNC_SETTINGS:-0}" = 1 ] && command -v jq >/dev/null 2>&1 || return 0
    local f changed=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        _settings_file_pinned "$f" && continue
        _settings_file_proxy_on "$f" >/dev/null 2>&1 && changed=1
    done <<< "$(_settings_targets 2>/dev/null)"
    [ "$changed" -eq 0 ] || echo "[Kill switch] Claude's settings now point at the tunnel (127.0.0.1:$CLAUDE_HTTP_PORT): while it is down Claude cannot connect, so it never goes out directly. Details: proxy-killswitch"
}

# ============================================================
# Nodes: catalogue (nodes.json) + ~/.ssh/config aliases + per-node Chrome tunnels
# ============================================================

# The catalogue as one line per node, '|'-separated:
#   idx|name|alias|host|user|ssh_port|proxy_port|region|note|hostkey
# idx is the node's 'slot' (its Chrome-tunnel port offset), or its position when
# the catalogue has no slots. jq when available; otherwise a small awk parser
# that relies on the file keeping ONE node object per line (which nodes.json promises).
_nodes_tsv() {
    [ -f "$CLAUDE_PROXY_NODES" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '.nodes // [] | to_entries[] | [
            (.value.slot // .key), .value.name, .value.alias, (.value.host // ""), (.value.user // ""),
            (.value.ssh_port // 22), (.value.proxy_port // 8888),
            (.value.region // ""), (.value.note // ""), (.value.hostkey // "")
        ] | map(tostring) | join("|")' "$CLAUDE_PROXY_NODES" 2>/dev/null
    else
        awk '
        function f(k,   r, s) {
            r = "\"" k "\"[ \t]*:[ \t]*"
            if (match($0, r "\"[^\"]*\"")) { s = substr($0, RSTART, RLENGTH); sub(r "\"", "", s); sub(/"$/, "", s); return s }
            if (match($0, r "[0-9]+"))    { s = substr($0, RSTART, RLENGTH); sub(r, "", s); return s }
            return ""
        }
        /"name"[ \t]*:/ && /"alias"[ \t]*:/ {
            sp = f("ssh_port"); if (sp == "") sp = 22
            pp = f("proxy_port"); if (pp == "") pp = 8888
            sl = f("slot"); if (sl == "") sl = i + 0
            i++
            print sl "|" f("name") "|" f("alias") "|" f("host") "|" f("user") "|" sp "|" pp "|" f("region") "|" f("note") "|" f("hostkey")
        }' "$CLAUDE_PROXY_NODES"
    fi
}

# --- catalogue from DNS (CLAUDE_PROXY_DOMAIN) -----------------------------------
# One TXT value per node at _claude-proxy.<domain>, space-separated key=value:
#   v=cp1 name=jp2 slot=3 region=Japan [alias=jpvpn2] [host=jpvpn2.example.com]
#         [user=] [ssh=22] [proxy=8888] [note=Second_JP_VM] [hostkey=ssh-ed25519:AAAA...]
# Required: v=cp1, name, slot. alias defaults to <letters>vpn<digits> of the name
# (jp -> jpvpn, jp2 -> jpvpn2), host to <alias>.<domain>. '_' in region/note is a
# space; the ':' in hostkey stands for the space between key type and key.

# TXT records of a DNS name, one per line (multi-string records joined, quotes
# stripped). dig / host when present, else DNS-over-HTTPS through curl.
_dns_txt() {  # <fqdn>
    local q="$1" out="" url
    if command -v dig >/dev/null 2>&1; then
        out=$(dig +short +time=3 +tries=1 TXT "$q" 2>/dev/null | grep '^"' | sed 's/" "//g; s/^"//; s/"$//')
    fi
    if [ -z "$out" ] && command -v host >/dev/null 2>&1; then
        out=$(host -W 3 -t TXT "$q" 2>/dev/null | sed -n 's/.*descriptive text "\(.*\)"$/\1/p' | sed 's/" "//g')
    fi
    if [ -z "$out" ]; then
        for url in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do
            out=$(curl -fsS --max-time 6 -H 'accept: application/dns-json' "$url?name=$q&type=TXT" 2>/dev/null \
                | grep -oE '"data": ?"(\\.|[^"\\])*"' \
                | sed 's/^"data": \{0,1\}"//; s/"$//; s/\\" *\\"//g; s/^\\"//; s/\\"$//; s/\\\\/\\/g')
            [ -n "$out" ] && break
        done
    fi
    [ -n "$out" ] && printf '%s\n' "$out"
}

# A nodes.json (same shape as the published one, one node per line, sorted by
# slot) built from the TXT records of _claude-proxy.<domain>. Fails when there are none.
_nodes_json_from_dns() {  # <domain>
    local domain="$1" txt body
    txt=$(_dns_txt "_claude-proxy.$domain") || return 1
    body=$(printf '%s\n' "$txt" | awk -v dom="$domain" '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        $1 != "v=cp1" { next }
        {
            split("", kv)
            for (i = 2; i <= NF; i++) { p = index($i, "="); if (p > 1) kv[substr($i, 1, p - 1)] = substr($i, p + 1) }
            name = kv["name"]; slot = kv["slot"]
            if (name !~ /^[A-Za-z][A-Za-z0-9]*$/ || slot !~ /^[0-9]+$/) {
                print "[Warn] Ignoring a TXT record without a valid name/slot: " $0 > "/dev/stderr"; next
            }
            letters = name; sub(/[0-9]+$/, "", letters); digits = substr(name, length(letters) + 1)
            alias = ("alias" in kv) ? kv["alias"] : letters "vpn" digits
            host  = ("host"  in kv) ? kv["host"]  : alias "." dom
            ssh   = (kv["ssh"]   ~ /^[0-9]+$/) ? kv["ssh"]   : 22
            proxy = (kv["proxy"] ~ /^[0-9]+$/) ? kv["proxy"] : 8888
            region = kv["region"]; gsub(/_/, " ", region)
            note   = kv["note"];   gsub(/_/, " ", note)
            hk     = kv["hostkey"]; sub(/:/, " ", hk)
            printf "%d\t    { \"name\": \"%s\", \"alias\": \"%s\", \"host\": \"%s\", \"user\": \"%s\", \"ssh_port\": %d, \"proxy_port\": %d, \"region\": \"%s\", \"note\": \"%s\", \"hostkey\": \"%s\", \"slot\": %d }\n", \
                slot, esc(name), esc(alias), esc(host), esc(kv["user"]), ssh, proxy, esc(region), esc(note), esc(hk), slot
        }' | sort -n | cut -f2- | sed '$!s/$/,/')
    [ -n "$body" ] || return 1
    printf '{\n  "_comment": "Generated by proxy-nodes from the DNS TXT records at _claude-proxy.%s - edit DNS, not this file.",\n' "$domain"
    printf '  "version": 1,\n  "source": "dns:%s",\n  "updated": "%s",\n  "nodes": [\n%s\n  ]\n}\n' "$domain" "$(date +%Y-%m-%d)" "$body"
}

# The node list from a VM over SSH (forge proxynodes-manager serves it to anyone
# who can log in, tunnel-only accounts included). Fails with a clear reason.
_nodes_fetch_ssh() {  # <ssh alias or host> <file>
    local target="$1" out="$2" err
    err=$(mktemp) || return 1
    echo "[Nodes] Fetching the node list from $target over SSH..."
    _is_wsl && _ensure_ssh_agent
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
           "$target" claude-proxy-nodes > "$out" 2> "$err" && grep -q '"nodes"' "$out"; then
        sed -i.bak "s|\"source\": *\"ssh\"|\"source\": \"ssh:$target\"|" "$out" && rm -f "$out.bak"
        rm -f "$err"
        return 0
    fi
    if grep -qs "tunnel-only account" "$out" "$err"; then
        echo "[Err] $target answered, but doesn't serve the node list yet - admin: install forge proxynodes-manager there (and its sshd ForceCommand)"
    elif grep -qisE "claude-proxy-nodes.*not found|not found.*claude-proxy-nodes" "$out" "$err"; then
        echo "[Err] $target has no 'claude-proxy-nodes' command - admin: install forge proxynodes-manager there"
    else
        echo "[Err] Could not get the node list from $target: $(sed '/^[[:space:]]*$/d' "$err" | tail -1)"
        echo "      Try 'ssh $target' by hand (a key with a passphrase has to be loaded in ssh-agent)."
    fi
    rm -f "$err"
    return 1
}

# How the node list is currently sourced, in words.
_nodes_source_desc() {
    if [ -n "$CLAUDE_NODES_FROM" ]; then echo "VM $CLAUDE_NODES_FROM (over SSH)"
    elif [ -n "$CLAUDE_PROXY_DOMAIN" ]; then echo "the DNS of $CLAUDE_PROXY_DOMAIN"
    else echo "the guide's list"
    fi
}

# Download / discover the catalogue into <file>. With a 2nd argument only the
# configured source is tried (used when a new source is being set).
_nodes_fetch() {  # <file> [no-fallback]
    local idx name alias rest
    if [ -n "$CLAUDE_NODES_FROM" ]; then
        _nodes_fetch_ssh "$CLAUDE_NODES_FROM" "$1" && return 0
        [ -z "${2:-}" ] || return 1
        # The chosen VM is down / moved: ask the other VMs we already know.
        while IFS='|' read -r idx name alias rest; do
            [ -n "$alias" ] && [ "$alias" != "$CLAUDE_NODES_FROM" ] && _ssh_config_has_alias "$alias" || continue
            if _nodes_fetch_ssh "$alias" "$1"; then
                echo "[Info] $CLAUDE_NODES_FROM didn't answer - took the list from $alias instead (your setting is unchanged; 'proxy-nodes --from $alias' switches for good)"
                return 0
            fi
        done <<< "$(_nodes_tsv)"
        return 1
    fi
    if [ -n "$CLAUDE_PROXY_DOMAIN" ]; then
        echo "[Nodes] Looking up the nodes of $CLAUDE_PROXY_DOMAIN (DNS TXT _claude-proxy.$CLAUDE_PROXY_DOMAIN)..."
        if ! _nodes_json_from_dns "$CLAUDE_PROXY_DOMAIN" > "$1"; then
            echo "[Err] No valid 'v=cp1' TXT records at _claude-proxy.$CLAUDE_PROXY_DOMAIN - check the domain (proxy-config set PROXY_DOMAIN <domain>) or ask your admin."
            return 1
        fi
        return 0
    fi
    echo "[Nodes] Fetching the node catalogue..."
    if ! curl -fsSL "$CLAUDE_PROXY_REPO_RAW/nodes.json" -o "$1"; then
        echo "[Err] Download failed. GitHub not reachable from here? Try 'proxy-up' first, then again."
        return 1
    fi
}

# The catalogue line for a node NAME or ALIAS ("" if unknown).
_node_lookup() {
    local want="$1" line idx name alias rest
    [ -n "$want" ] || return 1
    while IFS='|' read -r idx name alias rest; do
        [ -n "$idx" ] || continue
        if [ "$name" = "$want" ] || [ "$alias" = "$want" ]; then
            echo "$idx|$name|$alias|$rest"
            return 0
        fi
    done <<< "$(_nodes_tsv)"
    return 1
}

# Name of the node cc/cx currently use ("" when CLAUDE_SSH_HOST isn't in the catalogue).
_node_active_name() {
    local line
    line=$(_node_lookup "$CLAUDE_SSH_HOST") || return 1
    echo "$line" | cut -d'|' -f2
}

# A node's host is "provisioned" once the admin replaced the <placeholder>.
_node_provisioned() {  # <host>
    [ -n "$1" ] && case "$1" in "<"*) return 1 ;; esac
}

_node_socks_port() {  # <idx>
    echo $((CLAUDE_NODE_SOCKS_BASE + $1))
}

# The recovery slot of a node: 'main' for the default node (main ports), else
# node-<name>. Fails, with the reason on stderr, for an unknown or unprovisioned node.
_node_slot() {  # <node name or alias>
    local line idx name alias host
    if ! line=$(_node_lookup "$1"); then
        [ "$1" != "$CLAUDE_SSH_HOST" ] || { echo main; return 0; }
        echo "[Err] Unknown node '$1'. 'proxy-nodes' lists them ('proxy-nodes --refresh' fetches the latest)." >&2
        return 1
    fi
    IFS='|' read -r idx name alias host _ <<< "$line"
    if [ "$alias" = "$CLAUDE_SSH_HOST" ]; then echo main; return 0; fi
    if ! _node_provisioned "$host"; then
        echo "[Err] Node '$name' has no address in the catalogue yet - ask your admin, then 'proxy-nodes --refresh'." >&2
        return 1
    fi
    echo "node-$name"
}

# Point this shell's tunnel settings at a node: its ssh alias (which carries
# user, key and port) and its fixed ports. Call it in a subshell - the worker
# that runs there then supervises that node. The default node changes nothing.
_node_ctx() {  # <node name or alias>
    local line idx name alias host user sport pport http socks
    [ "$(_node_slot "$1")" != main ] || return 0
    line=$(_node_lookup "$1") || return 1
    IFS='|' read -r idx name alias host user sport pport _ <<< "$line"
    http=$((CLAUDE_NODE_HTTP_BASE + idx)) socks=$((CLAUDE_NODE_SOCKS_BASE + idx))
    if [ "$http" = "$CLAUDE_HTTP_PORT" ] || [ "$http" = "$CLAUDE_SOCKS_PORT" ]; then
        echo "[Err] Node '$name' would use port $http, which the default tunnel uses. Fix: proxy-config set NODE_HTTP_BASE $((CLAUDE_HTTP_PORT + 100))" >&2
        return 1
    fi
    if [ "$socks" = "$CLAUDE_HTTP_PORT" ] || [ "$socks" = "$CLAUDE_SOCKS_PORT" ]; then
        echo "[Err] Node '$name' would use port $socks, which the default tunnel uses. Fix: proxy-config set NODE_SOCKS_BASE $((CLAUDE_SOCKS_PORT + 100))" >&2
        return 1
    fi
    CLAUDE_SSH_HOST=$alias CLAUDE_SSH_USER='' CLAUDE_SSH_KEY='' CLAUDE_SSH_PORT=${sport:-22}
    CLAUDE_HTTP_PORT=$http CLAUDE_SOCKS_PORT=$socks CLAUDE_REMOTE_PROXY_PORT=${pport:-8888}
    export CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_KEY CLAUDE_SSH_PORT CLAUDE_HTTP_PORT CLAUDE_SOCKS_PORT CLAUDE_REMOTE_PROXY_PORT
}

_ssh_config_has_alias() {  # <alias>
    grep -qiE "^Host[[:space:]]+$1([[:space:]]|$)" "$HOME/.ssh/config" 2>/dev/null
}

# A field (IdentityFile, User, ...) of an ~/.ssh/config alias ("" if none) - new
# nodes reuse the key AND the username the wizard set up for the first one, since
# sshu-manager gives every person their own account with one key for all nodes.
_ssh_config_field() {  # <alias> <Field>
    [ -f "$HOME/.ssh/config" ] || return 1
    awk -v a="$1" -v f="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" '
        tolower($1) == "host" { inblk = 0; for (i = 2; i <= NF; i++) if ($i == a) inblk = 1; next }
        inblk && tolower($1) == f { $1 = ""; sub(/^[ \t]+/, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$HOME/.ssh/config"
}
_ssh_config_identity() { _ssh_config_field "$1" IdentityFile; }

# Append a Host block (same shape as the setup wizard writes).
_ssh_config_add_alias() {  # <alias> <host> <user> <port> <identityfile>
    local alias="$1" host="$2" user="$3" port="$4" key="$5"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    {
        printf '\nHost %s\n' "$alias"
        printf '    HostName %s\n' "$host"
        [ -n "$user" ] && printf '    User %s\n' "$user"
        [ -n "$port" ] && [ "$port" != "22" ] && printf '    Port %s\n' "$port"
        [ -n "$key" ]  && printf '    IdentityFile %s\n' "$key"
        printf '    AddKeysToAgent yes\n'
        [ "$(uname)" = "Darwin" ] && printf '    UseKeychain yes\n'
    } >> "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
}

# Pin a node's host key so the first connection never stops at "Are you sure...?".
_known_hosts_add() {  # <host> <port> <hostkey>
    local host="$1" port="$2" key="$3" entry
    [ -n "$key" ] || return 0
    [ "$port" = "22" ] && entry="$host" || entry="[$host]:$port"
    mkdir -p "$HOME/.ssh"
    grep -qsF "$key" "$HOME/.ssh/known_hosts" && return 0
    printf '%s %s\n' "$entry" "$key" >> "$HOME/.ssh/known_hosts"
    chmod 600 "$HOME/.ssh/known_hosts"
    echo "[OK] Host key for $host pinned in ~/.ssh/known_hosts"
}

# Make sure a catalogue node has an ssh alias (creates it from the catalogue if
# missing, reusing the active alias's key). Fails when the node has no host yet.
_node_ensure_alias() {  # <catalogue line>
    local idx name alias host user sport pport region note hostkey key
    IFS='|' read -r idx name alias host user sport pport region note hostkey <<< "$1"
    if _ssh_config_has_alias "$alias"; then
        _known_hosts_add "$host" "$sport" "$hostkey"
        return 0
    fi
    if ! _node_provisioned "$host"; then
        echo "[Err] Node '$name' has no host in the catalogue yet (not provisioned) - ask your admin, then 'proxy-nodes --refresh'."
        return 1
    fi
    key=$(_ssh_config_identity "$CLAUDE_SSH_HOST")
    [ -n "$key" ] || key="$CLAUDE_SSH_KEY"
    # Catalogue 'user' empty = everyone has their own account: reuse the User of the active alias.
    if [ -z "$user" ]; then
        user=$(_ssh_config_field "$CLAUDE_SSH_HOST" User)
        [ -n "$user" ] || user="$CLAUDE_SSH_USER"
    fi
    _ssh_config_add_alias "$alias" "$host" "$user" "$sport" "$key"
    if [ -n "$key" ]; then
        echo "[OK] ssh alias '$alias' -> ${user:+$user@}$host written to ~/.ssh/config (key: $key)"
    else
        echo "[OK] ssh alias '$alias' -> ${user:+$user@}$host written to ~/.ssh/config (no IdentityFile found on '$CLAUDE_SSH_HOST' - ssh will use your default key)"
    fi
    _known_hosts_add "$host" "$sport" "$hostkey"
}

# --- per-node Chrome tunnels (SOCKS only; the main tunnel is untouched) ------
_node_tunnel_start() {  # <name> <alias> <port>
    local name="$1" alias="$2" port="$3" pid pname attempts=0
    if _port_in_use "$port"; then
        pid=$(_ssh_listeners "$port" | head -1)
        if [ -n "$pid" ]; then
            echo "[OK]  $name tunnel already running (PID $pid, SOCKS 127.0.0.1:$port)"
            return 0
        fi
        pid=$(_listeners "$port" | head -1); pname=$(_proc_name "$pid")
        echo "[Err] Port $port (reserved for the $name tunnel) is used by '${pname:-unknown}' (PID $pid). Move the node ports: proxy-config set NODE_SOCKS_BASE 1280"
        return 1
    fi
    _is_wsl && _ensure_ssh_agent
    echo "[SSH] Starting $name tunnel to $alias (SOCKS 127.0.0.1:$port)..."
    ssh -N -f -C -D "$port" \
        -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
        "$alias" 2>"$CLAUDE_TUNNEL_LOG.$name"
    while ! _port_in_use "$port" && [ $attempts -lt 10 ]; do
        sleep 0.5; attempts=$((attempts+1))
    done
    if _port_in_use "$port"; then
        echo "[OK]  $name tunnel up: SOCKS 127.0.0.1:$port -> $alias"
    else
        echo "[Err] $name tunnel failed to start within 5s. ssh said:"
        sed 's/^/       /' "$CLAUDE_TUNNEL_LOG.$name" 2>/dev/null | head -5
        echo "       (first time? run 'ssh $alias' once to accept the host key)"
        return 1
    fi
}

# Running per-node tunnels: "name|port|pid" per line.
_node_tunnels_running() {
    local idx name rest port pid
    while IFS='|' read -r idx name rest; do
        [ -n "$idx" ] || continue
        port=$(_node_socks_port "$idx")
        for pid in $(_ssh_listeners "$port"); do echo "$name|$port|$pid"; done
    done <<< "$(_nodes_tsv)"
}

_node_tunnels_stop() {
    local name port pid
    while IFS='|' read -r name port pid; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null
        echo "[Kill] PID $pid (ssh, $name Chrome tunnel :$port)"
    done <<< "$(_node_tunnels_running)"
}

# --- commands ----------------------------------------------------------------
proxy-nodes() {
    # (zsh prints a variable when 'local' re-declares it - declare everything once)
    local refresh=0 tmp updated source line idx name alias host user sport pport region note hostkey
    local tstate hpid hname hport running mark target where found_active=0 cur dups
    local set_src="" new_val="" force=0 prev_domain prev_from prev_desc ok current
    local usage="usage: proxy-nodes [--refresh] [--from <vm alias>] [--domain <domain>] [--force]   ('' as the value = back to the guide's list)"
    # (the PowerShell spellings -Refresh / -From / -Domain / -Force work too)
    while [ $# -gt 0 ]; do
        case "$1" in
            --refresh|-r|-Refresh|refresh) refresh=1 ;;
            --force|-f|-Force) force=1 ;;
            --domain|-Domain|--from|-From)
                [ $# -ge 2 ] || { echo "$usage"; return 1; }
                case "$1" in *omain) set_src=domain ;; *) set_src=from ;; esac
                shift; new_val="$1" ;;
            --domain=*) new_val="${1#--domain=}"; set_src=domain ;;
            --from=*)   new_val="${1#--from=}"; set_src=from ;;
            list) ;;
            *) echo "[Err] Unknown argument '$1'. $usage"; return 1 ;;
        esac
        shift
    done
    if [ "$set_src" = domain ]; then
        new_val=$(printf '%s' "$new_val" | tr 'A-Z' 'a-z' | sed 's/[[:space:]]//g; s/\.$//')
        if [ -n "$new_val" ] && ! printf '%s' "$new_val" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'; then
            echo "[Err] '$new_val' is not a domain name (example: proxy-nodes --domain example.com) - nothing changed."
            return 1
        fi
    elif [ "$set_src" = from ]; then
        if [ -n "$new_val" ] && ! printf '%s' "$new_val" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._@-]*$'; then
            echo "[Err] '$new_val' is not an ssh alias or host (example: proxy-nodes --from jpvpn) - nothing changed."
            return 1
        fi
    fi
    [ -n "$set_src" ] && refresh=1

    if [ $refresh -eq 1 ]; then
        tmp=$(mktemp) || return 1
        prev_domain="$CLAUDE_PROXY_DOMAIN"; prev_from="$CLAUDE_NODES_FROM"; prev_desc=$(_nodes_source_desc)
        # One source at a time: setting one clears the other.
        case "$set_src" in
            domain) CLAUDE_PROXY_DOMAIN="$new_val"; CLAUDE_NODES_FROM="" ;;
            from)   CLAUDE_NODES_FROM="$new_val"; CLAUDE_PROXY_DOMAIN="" ;;
        esac
        ok=1
        _nodes_fetch "$tmp" "$set_src" || ok=0
        if [ $ok -eq 1 ] && { ! grep -q '"nodes"' "$tmp" || { command -v jq >/dev/null 2>&1 && ! jq -e '.nodes | type == "array"' "$tmp" >/dev/null 2>&1; }; }; then
            echo "[Err] Downloaded file doesn't look like a node catalogue - nothing changed."
            ok=0
        fi
        if [ $ok -eq 0 ]; then
            rm -f "$tmp"
            if [ -n "$set_src" ] && [ $force -eq 1 ]; then
                _conf_set CLAUDE_NODES_FROM "$CLAUDE_NODES_FROM"; _conf_set CLAUDE_PROXY_DOMAIN "$CLAUDE_PROXY_DOMAIN"; _conf_reload
                echo "[OK] Node list source saved anyway (--force): $(_nodes_source_desc) - run 'proxy-nodes --refresh' once it answers."
            elif [ -n "$set_src" ]; then
                CLAUDE_PROXY_DOMAIN="$prev_domain"; CLAUDE_NODES_FROM="$prev_from"
                echo "[Info] Node list source not changed (still: $prev_desc). Fix the problem above, or add --force to save it anyway."
            fi
            return 1
        fi
        if [ -n "$set_src" ]; then
            _conf_set CLAUDE_NODES_FROM "$CLAUDE_NODES_FROM"; _conf_set CLAUDE_PROXY_DOMAIN "$CLAUDE_PROXY_DOMAIN"; _conf_reload
            echo "[OK] Node list now comes from $(_nodes_source_desc) (saved to $CLAUDE_PROXY_CONF)"
        fi
        mv "$tmp" "$CLAUDE_PROXY_NODES"
        echo "[OK] Catalogue saved: $CLAUDE_PROXY_NODES"
        # Create the ssh aliases the catalogue promises (never touches existing ones).
        while IFS='|' read -r line; do
            [ -n "$line" ] || continue
            IFS='|' read -r idx name alias host user sport pport region note hostkey <<< "$line"
            if _ssh_config_has_alias "$alias"; then
                _node_ensure_alias "$line" >/dev/null   # pins the host key if given
                # Existing aliases are never rewritten - but say so when they point elsewhere.
                cur=$(_ssh_config_field "$alias" HostName)
                if _node_provisioned "$host" && [ -n "$cur" ] && [ "$cur" != "$host" ]; then
                    echo "[Warn] ssh alias '$alias' points to $cur, the catalogue says $host - edit ~/.ssh/config (or delete that Host block and refresh again)"
                fi
            elif _node_provisioned "$host"; then
                _node_ensure_alias "$line"
            else
                echo "[Info] Node '$name' is listed but has no host yet - skipped"
            fi
        done <<< "$(_nodes_tsv)"
    fi

    cur=$(_ssh_config_field "$CLAUDE_SSH_HOST" HostName)
    current="$CLAUDE_SSH_HOST${cur:+ -> $cur}"
    if [ ! -f "$CLAUDE_PROXY_NODES" ]; then
        echo ""
        echo "[Info] No node list yet - get it from one of your VMs: proxy-nodes --from $CLAUDE_SSH_HOST"
        echo "       Current server: $current"
        echo ""
        return 0
    fi
    if [ -z "$(_nodes_tsv)" ]; then
        echo ""
        if [ -n "$CLAUDE_NODES_FROM" ]; then
            echo "[Info] $CLAUDE_NODES_FROM doesn't list any nodes yet - admin: 'sudo proxynodes-add ...' there, then 'proxy-nodes --refresh'."
        elif [ -n "$CLAUDE_PROXY_DOMAIN" ]; then
            echo "[Info] $CLAUDE_PROXY_DOMAIN lists no nodes (yet) - 'proxy-nodes --refresh' after your admin registers the VMs."
        else
            echo "[Info] No nodes listed. This guide doesn't publish any VMs - get your list privately from one of your VMs:"
            echo "       proxy-nodes --from $CLAUDE_SSH_HOST          (or from public DNS: proxy-nodes --domain <domain>)"
        fi
        echo "       Current server: $current (cc / cx / chrome-proxy keep using it)"
        echo ""
        return 0
    fi

    updated=$(sed -n 's/.*"updated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CLAUDE_PROXY_NODES" | head -1)
    source=$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CLAUDE_PROXY_NODES" | head -1)
    where="the guide's nodes.json"
    [ -n "$source" ] && where="$source"
    [ -n "$updated" ] && where="$where, updated $updated"
    echo ""
    echo "=== Proxy nodes (catalogue: $CLAUDE_PROXY_NODES, from $where) ==="
    if [ -n "$CLAUDE_NODES_FROM" ] && [ "$source" != "ssh:$CLAUDE_NODES_FROM" ]; then
        echo "[Info] Your list source is $CLAUDE_NODES_FROM, but this copy came from ${source:-elsewhere} - 'proxy-nodes --refresh' reloads it"
    elif [ -n "$CLAUDE_PROXY_DOMAIN" ] && [ "$source" != "dns:$CLAUDE_PROXY_DOMAIN" ]; then
        echo "[Info] PROXY_DOMAIN is '$CLAUDE_PROXY_DOMAIN' but this list came from elsewhere - 'proxy-nodes --refresh' reloads it"
    fi
    dups=$(_nodes_tsv | cut -d'|' -f1 | sort | uniq -d | tr '\n' ' ')
    [ -n "$dups" ] && echo "[Warn] Several nodes share slot(s) $dups- their Chrome tunnels would collide. Tell your admin."
    echo ""
    read -r tstate hpid hname hport <<< "$(_tunnel_health)"
    running=$(_node_tunnels_running)
    while IFS='|' read -r idx name alias host user sport pport region note hostkey; do
        [ -n "$idx" ] || continue
        mark=" "; where=""
        if [ "$alias" = "$CLAUDE_SSH_HOST" ]; then
            mark="*"; found_active=1
            case "$tstate" in
                ok) where="ACTIVE - cc/cx tunnel UP (127.0.0.1:${hport:-$CLAUDE_HTTP_PORT} / :$CLAUDE_SOCKS_PORT)" ;;
                *)  where="ACTIVE - tunnel down ('cc' starts it)" ;;
            esac
        fi
        if printf '%s\n' "$running" | grep -q "^$name|"; then
            where="${where:+$where; }Chrome tunnel UP (:$(_node_socks_port "$idx"))"
        fi
        if _node_provisioned "$host"; then
            target="${user:+$user@}$host"
            _ssh_config_has_alias "$alias" || where="${where:+$where; }no ssh alias yet ('proxy-nodes --refresh' creates it)"
        else
            # no address in the list, but your ~/.ssh/config may have one
            target=$(_ssh_config_field "$alias" HostName)
            if [ -n "$target" ]; then target="$target (your alias)"; else target="<not provisioned>"; fi
        fi
        printf '  %s %-5s %-8s %-11s %-30s %s\n' "$mark" "$name" "$alias" "$region" "$target" "$where"
    done <<< "$(_nodes_tsv | sort -t'|' -k8,8 -k1,1n)"
    if [ $found_active -eq 0 ]; then
        echo "  * ($current)  - current server, not in this list"
    fi
    echo ""
    echo "  proxy-node <name>                  make it the node cc / cx use (restarts the tunnel if it's up)"
    echo "  chrome-proxy <name>                open a Chrome window through that node (own tunnel; several nodes can be open)"
    echo "  chrome-proxy <name> --profile <p>  another Chrome profile through the same node ('chrome-profiles' lists them)"
    echo "  proxy-nodes --refresh              reload the list and create any missing ssh aliases"
    echo "  proxy-nodes --from <vm>            take the list (privately, over SSH) from another VM from now on"
    echo ""
}

proxy-node() {
    local want="${1:-}" line idx name alias host user sport pport rest
    if [ -z "$want" ]; then
        name=$(_node_active_name)
        if [ -n "$name" ]; then
            echo "[..] Active node: $name ($CLAUDE_SSH_HOST) - 'proxy-node <name>' switches, 'proxy-nodes' lists them"
        else
            echo "[..] Active server: $CLAUDE_SSH_HOST (not in the node catalogue) - 'proxy-nodes' lists the known nodes"
        fi
        return 0
    fi

    if line=$(_node_lookup "$want"); then
        IFS='|' read -r idx name alias host user sport pport rest <<< "$line"
        _node_ensure_alias "$line" || return 1
    elif _ssh_config_has_alias "$want"; then
        name="$want"; alias="$want"; pport=""
        echo "[Info] '$want' is not in the node catalogue but exists in ~/.ssh/config - using it as-is."
    else
        echo "[Err] Unknown node '$want'. 'proxy-nodes' lists them ('proxy-nodes --refresh' fetches the latest)."
        return 1
    fi

    if [ "$alias" = "$CLAUDE_SSH_HOST" ]; then
        echo "[OK] '$name' is already the active node ($alias)"
        return 0
    fi

    local was_up=0 env_on=0
    [ "$(_tunnel_health | awk '{print $1}')" = "ok" ] && was_up=1
    [ -n "${HTTPS_PROXY:-}" ] && env_on=1

    _conf_set CLAUDE_SSH_HOST "$alias"
    [ -n "$pport" ] && _conf_set CLAUDE_REMOTE_PROXY_PORT "$pport"
    if [ $was_up -eq 1 ]; then
        echo "[Node] Switching the cc/cx tunnel to $name ($alias)..."
        tunnel-stop
    fi
    _conf_reload
    echo "[OK] Active node: $name ($alias) - saved to $CLAUDE_PROXY_CONF"
    if [ $was_up -eq 1 ]; then
        tunnel-start || return 1
        [ $env_on -eq 1 ] && proxy-on
    fi
    echo "[Info] Open shells keep the old node until they run: source $CLAUDE_PROXY_SELF"
}

# ============================================================
# 1. SSH tunnel: -L (HTTP proxy for Claude) + -D (SOCKS5 for Chrome)
# ============================================================

# What to tell the user when the tunnel does not come up: the classified reason
# and its fix first, then the actual ssh output (owner's stderr, else the log).
_recovery_failure_report() {
    local dir why=''
    dir=$(_recovery_identity 2>/dev/null) || dir=''
    if [ -n "$dir" ]; then why=$(cut -d'|' -f1 "$dir/ssh.status" 2>/dev/null); fi
    echo "[Err] SSH tunnel failed to start within 10s."
    if [ -n "$why" ]; then echo "       $(_recovery_ssh_hint "$why" "$CLAUDE_SSH_HOST")"; fi
    echo "       ssh said:"
    if [ -n "$dir" ] && [ -s "$dir/ssh.err" ]; then tail -n 5 "$dir/ssh.err" | sed 's/^/       /'
    else tail -n 5 "$CLAUDE_TUNNEL_LOG" 2>/dev/null | sed 's/^/       /'; fi
    echo "       (full log: $CLAUDE_TUNNEL_LOG - 'proxy-doctor' for more)"
}

tunnel-start() {
    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    # Everything below needs an ssh client, and without this guard the failure
    # is opaque: the backgrounded start swallows "command not found" and you get
    # a bare "tunnel failed to start" instead.
    if ! command -v ssh >/dev/null 2>&1; then
        echo "[Err] 'ssh' not found - no tunnel is possible. Install an OpenSSH client:"
        echo "       Debian/Ubuntu: sudo apt install openssh-client"
        echo "       Fedora/RHEL:   sudo dnf install openssh-clients"
        echo "       Alpine:        sudo apk add openssh-client"
        echo "       macOS:         included with the system (check your PATH)"
        return 1
    fi

    # Auto-heal: a HEALTHY tunnel is reused (adopting its port if it's on a
    # fallback), a STALE ssh is killed and replaced, and a FOREIGN app keeps its
    # port - the tunnel simply falls back to the next free port instead.
    if _watchdog_pid >/dev/null; then
        echo "[Info] Shared recovery owner is running; keeping HTTP :$CLAUDE_HTTP_PORT / SOCKS :$CLAUDE_SOCKS_PORT."
        return 0
    fi
    local tstate hpid hname hport newp healing=""
    read -r tstate hpid hname hport <<< "$(_tunnel_health)"
    if [ "$tstate" = "ok" ]; then
        # Listening is not enough: a tunnel that no longer answers is shared by
        # every tab, so replace it now instead of reusing it.
        [ -n "$hport" ] || hport=$CLAUDE_HTTP_PORT
        case "$(_proxy_probe "$hport" 6)" in
            dead*)
                echo "[Heal] SSH tunnel (PID $hpid) is up but not answering - restarting it for every window..."
                export CLAUDE_HTTP_PORT=$hport
                tstate=stale healing=1
                ;;
        esac
    fi
    case "$tstate" in
        ok)
            if [ "${CLAUDE_TUNNEL_WATCHDOG:-1}" = "1" ] && ! _watchdog_pid >/dev/null; then
                # Started by an older profile: give it an owner on the same ports (replaces it).
                [ "$hport" = "$CLAUDE_HTTP_PORT" ] || export CLAUDE_HTTP_PORT=$hport
                _watchdog_spawn >/dev/null || return 1
                echo "[OK]  Self-healing tunnel up on HTTP :$CLAUDE_HTTP_PORT / SOCKS :$CLAUDE_SOCKS_PORT"
                return 0
            fi
            if [ "$hport" != "$CLAUDE_HTTP_PORT" ]; then
                export CLAUDE_HTTP_PORT=$hport
                echo "[OK]  SSH tunnel already running (PID $hpid) on fallback port $hport - using it"
            else
                echo "[OK]  SSH tunnel already running (PID $hpid)"
            fi
            return 0
            ;;
        stale)
            [ -n "$healing" ] || echo "[Heal] Stale ssh tunnel (PID $hpid) - killing it and starting fresh..."
            tunnel-stop
            ;;
        foreign)
            if _killswitch_on; then
                # A moved port would no longer match Claude's pinned settings: refuse instead.
                echo "[Err] $hname (PID $hpid) is on proxy port $CLAUDE_HTTP_PORT. With the kill switch on the tunnel does not move silently."
                echo "      Fix: close that program, or move the tunnel for good: proxy-config set HTTP_PORT $((CLAUDE_HTTP_PORT+10))"
                return 1
            fi
            echo "[Info] Port $CLAUDE_HTTP_PORT is used by '$hname' (PID $hpid) - that's another app, leaving it alone."
            if ! newp=$(_find_free_port $((CLAUDE_HTTP_PORT+1))); then
                echo "[Err] No free port found in $((CLAUDE_HTTP_PORT+1))-$((CLAUDE_HTTP_PORT+20)) - free one up or change CLAUDE_HTTP_PORT (proxy-config edit)."
                return 1
            fi
            export CLAUDE_HTTP_PORT=$newp
            echo "[Info] Falling back to free port $newp for the HTTP proxy (this session)."
            ;;
    esac

    # The SOCKS port can be squatted by another app too (ssh owners were handled
    # above) - fall back the same way so ExitOnForwardFailure doesn't kill ssh.
    if _port_in_use "$CLAUDE_SOCKS_PORT"; then
        local spid sname snew
        spid=$(_listeners "$CLAUDE_SOCKS_PORT" | head -1)
        sname=$(_proc_name "$spid")
        if _killswitch_on; then
            echo "[Err] ${sname:-another program} (PID ${spid:-?}) is on SOCKS port $CLAUDE_SOCKS_PORT. With the kill switch on the tunnel does not move silently."
            echo "      Fix: close that program, or move the tunnel for good: proxy-config set SOCKS_PORT $((CLAUDE_SOCKS_PORT+10))"
            return 1
        fi
        if ! snew=$(_find_free_port $((CLAUDE_SOCKS_PORT+1))); then
            echo "[Err] SOCKS port $CLAUDE_SOCKS_PORT is used by '$sname' and no free port found nearby."
            return 1
        fi
        echo "[Info] SOCKS port $CLAUDE_SOCKS_PORT is used by '$sname' (PID $spid) - falling back to $snew."
        export CLAUDE_SOCKS_PORT=$snew
    fi

    # WSL: load the key first so 'ssh -f' won't block on a passphrase it can't answer.
    _is_wsl && _ensure_ssh_agent

    echo "[SSH] Starting tunnel to $CLAUDE_SSH_HOST..."
    # stderr -> log so a failed tunnel is debuggable (auth error vs. network timeout).
    if [ "${CLAUDE_TUNNEL_WATCHDOG:-1}" = "1" ]; then
        _watchdog_spawn
    else
        _tunnel_ssh_args
        ssh -f "${_CP_SSH_ARGS[@]}" 2>"$CLAUDE_TUNNEL_LOG"
    fi

    local attempts=0
    while ! _port_in_use "$CLAUDE_HTTP_PORT" && [ $attempts -lt 20 ]; do
        sleep 0.5
        attempts=$((attempts+1))
    done

    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[OK]  SSH tunnel up:"
        echo "       HTTP  127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT   (Claude / Codex)"
        echo "       SOCKS 127.0.0.1:$CLAUDE_SOCKS_PORT                                   (Chrome / apps)"
        if _watchdog_pid >/dev/null; then
            echo "       Watchdog on: reconnects by itself if the link drops (log: $CLAUDE_TUNNEL_LOG)"
        fi
    else
        # Report first (the owner's ssh.status is what explains it), then stop the
        # watchdog so it does not keep retrying a tunnel that can't start.
        _recovery_failure_report
        _watchdog_stop >/dev/null
        return 1
    fi
}

tunnel-stop() {
    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    # Kill every SSH process listening on either forwarded port (ours, including
    # stale leftovers), then verify. Non-ssh apps that happen to sit on a tunnel
    # port are NOT ours - they are reported and left alone.
    local pid name port still p wd_msg
    local ssh_pids=() survivors=()

    # The owner goes first, or it would just start ssh again (it takes its ssh with it).
    # Every live owner under this profile's state root counts: after an upgrade the
    # previous version's owner can sit in a differently named directory.
    if [ -n "$(_recovery_owned_dirs)" ]; then
        _recovery_stop_owners || return 1
        echo "[OK] Recovery stopped; proxy settings remain enabled until proxy-off."
        return 0
    fi
    if _legacy_watchdog_pid >/dev/null; then
        _legacy_watchdog_stop || return 1
        echo '[OK] Previous watchdog stopped; new recovery can start on the same ports.'
        return 0
    fi
    wd_msg=$(_watchdog_stop)
    [ -n "$wd_msg" ] && echo "$wd_msg"

    for pid in $( { _listeners "$CLAUDE_HTTP_PORT"; _listeners "$CLAUDE_SOCKS_PORT"; } | sort -u ); do
        name=$(_proc_name "$pid")
        if [ -z "$name" ] || _is_ssh_name "$name"; then
            ssh_pids+=("$pid")
        else
            echo "[Skip] PID $pid ($name) on a tunnel port - another app, left alone"
        fi
    done

    if [ ${#ssh_pids[@]} -eq 0 ]; then
        if [ -n "$wd_msg" ]; then echo "[OK] Tunnel stopped"; else echo "[Info] No tunnel running on ports $CLAUDE_HTTP_PORT / $CLAUDE_SOCKS_PORT"; fi
        return 0
    fi

    for pid in "${ssh_pids[@]}"; do
        kill "$pid" 2>/dev/null
        echo "[Kill] PID $pid (ssh)"
    done

    # Verify the ssh listeners are actually gone; escalate to SIGKILL if one lingers.
    # Only SSH survivors count as failure - foreign apps are none of our business.
    sleep 0.5
    for port in "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT"; do
        still=$(_ssh_listeners "$port")
        if [ -n "$still" ]; then
            for p in $(_ssh_listeners "$port"); do kill -9 "$p" 2>/dev/null; done
            sleep 0.3
            still=$(_ssh_listeners "$port")
        fi
        [ -n "$still" ] && survivors+=("$port held by ssh PID(s): $(printf '%s\n' "$still" | tr '\n' ' ')")
    done

    if [ ${#survivors[@]} -eq 0 ]; then
        echo "[OK] Tunnel stopped"
    else
        echo "[Err] Could not stop everything (even with SIGKILL):"
        for p in "${survivors[@]}"; do echo "       $p"; done
        echo "       Inspect: lsof -i:$CLAUDE_HTTP_PORT -i:$CLAUDE_SOCKS_PORT"
        echo "       A process you don't own needs sudo; a wedged one may need a re-login."
        return 1
    fi
}

# Back-compat stubs: the separate HTTP bridge is gone - the VM runs the proxy now,
# and 'tunnel-start' forwards straight to it.
bridge-start() { echo "[Info] No bridge needed anymore - the VM runs the HTTP proxy; 'tunnel-start' forwards straight to it."; }
bridge-stop()  { echo "[Info] No bridge to stop - the VM runs the HTTP proxy now. Use 'tunnel-stop'."; }

# ============================================================
# 2. Proxy env vars (+ Claude settings.json sync)
# ============================================================

proxy-on() {
    local url="http://127.0.0.1:$CLAUDE_HTTP_PORT"
    export http_proxy="$url"
    export HTTP_PROXY="$url"
    export https_proxy="$url"
    export HTTPS_PROXY="$url"
    export no_proxy="$CLAUDE_NO_PROXY"
    export NO_PROXY="$CLAUDE_NO_PROXY"
    echo "[OK] Env vars set: HTTPS_PROXY=$url"
    _claude_settings_proxy_on
    if _is_wsl && [ "${CLAUDE_SYNC_WINDOWS_SETTINGS:-0}" != "1" ]; then
        echo "[Info] WSL: Windows apps can use this tunnel too at $url (Windows-side Claude: proxy-config set SYNC_WINDOWS_SETTINGS 1)"
    fi
}

proxy-off() {
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY
    echo "[OK] Env vars cleared"
    if ! _killswitch_on; then
        _claude_settings_proxy_off
    elif [ "${CLAUDE_SYNC_SETTINGS:-0}" = 1 ]; then
        echo "[Kill switch] Claude's settings keep the proxy, so plain 'claude' cannot go out directly ('proxy-killswitch off' allows that)."
    fi
}

# Kill switch: everything that would let Claude/Codex traffic leak, checked right
# before launch. Prints one reason and one fix and fails; silent when all is well.
_killswitch_check() {  # <http port> <socks port>
    _killswitch_on || return 0
    local http="$1" socks="$2" hosts dir own='' spid sstamp port pid fix state
    hosts=$(_noproxy_exempts "$CLAUDE_NO_PROXY" | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$hosts" ]; then
        echo "[Kill switch] NO_PROXY would send $hosts DIRECT (from your own IP) - not launched."
        echo "              Fix: remove the matching entries from CLAUDE_NO_PROXY (proxy-config edit)."
        return 1
    fi
    # Our ssh is the one the owner published - checked by start identity, so a reused PID is not it.
    if dir=$(_recovery_identity 2>/dev/null) && IFS='|' read -r spid sstamp < "$dir/ssh.pid" 2>/dev/null \
       && [ -n "$sstamp" ] && [ "$(_recovery_process_identity "$spid" 2>/dev/null)" = "$sstamp" ]; then own=$spid; fi
    for port in "$http" "$socks"; do
        if [ "$port" = "$http" ]; then fix="proxy-config set HTTP_PORT $((http+10))"; else fix="proxy-config set SOCKS_PORT $((socks+10))"; fi
        for pid in $(_listeners "$port"); do
            [ "$pid" = "$own" ] && continue
            echo "[Kill switch] $(_proc_name "$pid" || :) (PID $pid) is on proxy port $port, not the tunnel - Claude/Codex traffic could go to it. Not launched."
            echo "              Fix: close that program, or move the tunnel: $fix"
            return 1
        done
        if [ -z "$(_listeners "$port")" ] && _port_bound "$port"; then
            echo "[Kill switch] another user's program is on proxy port $port, not the tunnel - Claude/Codex traffic could go to it. Not launched."
            echo "              Fix: move the tunnel: $fix"
            return 1
        fi
    done
    # Claude reads its settings.json over the shell, so it must name this same port.
    if [ "$http" = "$CLAUDE_HTTP_PORT" ] && [ "${CLAUDE_SYNC_SETTINGS:-0}" = 1 ] && command -v jq >/dev/null 2>&1; then
        _killswitch_ensure_pin >/dev/null
        state=$(_killswitch_pin_state)
        if [ "$state" != "pinned $http" ]; then
            echo "[Kill switch] Claude's settings ($CLAUDE_SETTINGS) could not be pointed at the tunnel on port $http ($state) - not launched."
            echo "              Fix: repair that file (valid JSON), or 'proxy-killswitch off'."
            return 1
        fi
    fi
}

# proxy-doctor's kill-switch lines, with its own ok / warn / fail markers.
_killswitch_report() {  # <ok> <warn> <bad>
    local ok="$1" warn="$2" bad="$3" state hosts
    if ! _killswitch_on; then
        echo "$warn Kill switch OFF - with the tunnel down, plain 'claude' / 'codex' go out from your own IP. Fix: proxy-killswitch on"
        return 0
    fi
    state=$(_killswitch_pin_state)
    case "$state" in
        "pinned $CLAUDE_HTTP_PORT") echo "$ok  Kill switch on - Claude's settings pinned to 127.0.0.1:$CLAUDE_HTTP_PORT" ;;
        mismatch*) echo "$bad Kill switch on, but Claude's settings point at port ${state#mismatch } (tunnel: $CLAUDE_HTTP_PORT). Fix: proxy-killswitch on" ;;
        'unpinned sync-off') echo "$warn Kill switch on, but settings.json is not managed (SYNC_SETTINGS=0): only cc-launched Claude is protected" ;;
        'unpinned no-jq') echo "$warn Kill switch on, but jq is missing: Claude's settings cannot be pinned. Fix: install jq" ;;
        *) echo "$bad Kill switch on, but Claude's settings are not pinned ($state). Fix: proxy-killswitch on" ;;
    esac
    hosts=$(_noproxy_exempts "$CLAUDE_NO_PROXY" | tr '\n' ' ' | sed 's/ $//')
    [ -z "$hosts" ] || echo "$bad NO_PROXY would send $hosts DIRECT - cc/cx refuse to start. Fix: remove those entries (proxy-config edit)"
    [ "${CLAUDE_PLAIN_COMMANDS:-off}" = auto ] || \
        echo "$warn plain 'codex' is not protected (Codex reads only the shell). Fix: proxy-config set PLAIN_COMMANDS auto - or always use cx"
}

# Kill switch: show it, or switch it (saved to the conf file).
proxy-killswitch() {
    local action="${1:-status}" running=0 f state hosts
    case "$action" in
        status) ;;
        on|off)
            # Decide before the reload, which re-reads every function and setting.
            _watchdog_pid >/dev/null 2>&1 && running=1
            _conf_set CLAUDE_KILLSWITCH "$action"
            _conf_reload
            if [ "$action" = on ]; then
                _killswitch_ensure_pin >/dev/null
                echo "[OK] Kill switch ON - Claude and Codex cannot go out directly. Saved to $CLAUDE_PROXY_CONF"
            elif [ "$running" -eq 1 ]; then
                echo "[OK] Kill switch OFF. A tunnel is running, so Claude keeps the proxy until 'proxy-off' / 'cc-stop'."
            else
                _claude_settings_proxy_off >/dev/null
                echo "[OK] Kill switch OFF - with no tunnel, plain 'claude' now goes out directly (from your own IP)."
            fi
            return 0 ;;
        *) echo 'usage: proxy-killswitch [status|on|off]'; return 2 ;;
    esac

    if _killswitch_on; then echo "=== Kill switch: ON ==="; else echo "=== Kill switch: OFF (pre-2.9 behaviour) - 'proxy-killswitch on' ==="; fi
    if [ "${CLAUDE_SYNC_SETTINGS:-0}" != 1 ]; then
        echo "[!!]  Claude : settings.json is not managed (SYNC_SETTINGS=0) - only cc-launched Claude is protected. Fix: proxy-config set SYNC_SETTINGS 1"
    elif ! command -v jq >/dev/null 2>&1; then
        echo "[!!]  Claude : jq is missing, so settings.json cannot be pinned - only cc-launched Claude is protected. Fix: install jq"
    else
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if _settings_file_pinned "$f"; then
                echo "[ON]  Claude : pinned to 127.0.0.1:$CLAUDE_HTTP_PORT ($f) - plain 'claude' and IDEs use the tunnel or fail"
            elif _killswitch_on; then
                echo "[!!]  Claude : $f does not point at the tunnel - run 'proxy-killswitch on' to fix it"
            else
                echo "[OFF] Claude : not pinned ($f) - plain 'claude' goes direct while no tunnel is up"
            fi
        done <<< "$(_settings_targets 2>/dev/null)"
    fi
    if [ "${CLAUDE_PLAIN_COMMANDS:-off}" = auto ]; then
        echo "[ON]  Codex  : protected when started with cx and as plain 'codex'"
    else
        echo "[..]  Codex  : protected when started with cx; plain 'codex' reads only your shell and may go direct (proxy-config set PLAIN_COMMANDS auto)"
    fi
    hosts=$(_noproxy_exempts "$CLAUDE_NO_PROXY" | tr '\n' ' ')
    if [ -z "$hosts" ]; then echo "[OK]  NO_PROXY : no API host is exempted"
    else echo "[!!]  NO_PROXY : would send $hosts DIRECT - remove those entries (proxy-config edit)"; fi
    echo "      Not covered: the Claude Desktop app, browsers and other apps (chrome-proxy has its own fail-closed rules)."
}

# --- Confirm the external IP really is the proxy's (VM's), not the client's ---
_verify_proxy_ip() {
    echo "[Check] Verifying the external IP is the proxy's..."
    local proxied direct
    # THROUGH the proxy (explicit -x, doesn't depend on env vars)...
    proxied=$(curl -s --max-time 10 -x "http://127.0.0.1:$CLAUDE_HTTP_PORT" https://ipinfo.io/ip 2>/dev/null)
    # ...vs. straight out (bypassing any proxy).
    direct=$(curl -s --max-time 10 --noproxy '*' https://ipinfo.io/ip 2>/dev/null)

    if [ -z "$proxied" ]; then
        echo "[FAIL] Could not fetch your IP THROUGH the proxy - the proxy isn't working."
        echo "       Run 'proxy-doctor'; check the VM with 'webproxy-status'."
        return 1
    fi
    if [ -n "$direct" ] && [ "$proxied" = "$direct" ]; then
        echo "[WARN] IP via proxy ($proxied) == your direct IP - traffic is NOT going through the VM!"
        echo "       (Only OK if the client and VM genuinely share this IP.)"
        return 1
    fi
    echo "[OK]  External IP via proxy: $proxied  (your direct IP: ${direct:-unknown})"
}

# ============================================================
# Bring the proxy stack up: tunnel + env vars + verify
# (everything 'cc' does EXCEPT launching Claude)
# ============================================================

proxy-up() {
    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    local no_verify=0 node="" provider="${_CLAUDE_LAUNCH_PROVIDER:-claude}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-verify) no_verify=1 ;;
            --node)      shift; node="${1:-}" ;;
            --node=*)    node="${1#--node=}" ;;
        esac
        shift
    done

    # Step 0: --node sg  ==  proxy-node sg first (persists, like running it yourself).
    if [ -n "$node" ]; then
        proxy-node "$node" || return 1
    fi

    # Step 1: SSH tunnel (HTTP + SOCKS forwards).
    # tunnel-start no-ops when the tunnel is healthy, auto-heals a stale one,
    # and falls back to a free port when a foreign app holds the configured one -
    # so require actual health afterwards, not just "something is on the port".
    tunnel-start || return 1
    [ "$(_tunnel_health | awk '{print $1}')" = "ok" ] || return 1

    # Mandatory authenticated-TLS transport check, even with --no-verify.
    # An idle owner may not have noticed a dropped link yet: wake it and give
    # it the startup grace to heal before refusing.
    local dir='' waited=0
    until _recovery_probe "$provider" "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT" | grep -q '^healthy|'; do
        if [ -z "$dir" ]; then
            dir=$(_recovery_identity 2>/dev/null) && _recovery_owner_pid "$dir" >/dev/null || dir=-
            [ "$dir" = - ] || { : > "$dir/wake"; echo "[Wait] Proxy not answering yet - waiting for the recovery owner to reconnect..."; }
        fi
        if [ "$dir" = - ] || [ "$waited" -ge "${CLAUDE_WATCHDOG_STARTUP_GRACE:-20}" ]; then
            echo "[Err] $provider proxy transport unavailable; application was not launched. Run proxy-status / proxy-doctor."; return 1
        fi
        sleep 1; waited=$((waited+1))
    done
    _killswitch_check "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT" || return 1
    # Step 2: Env vars (+ settings.json sync)
    proxy-on

    # Step 3: Verify the external IP really is the proxy's (VM's), not yours
    if [ $no_verify -eq 0 ]; then
        _verify_proxy_ip
    fi

    echo "[OK]  Proxy ready in this shell - run 'claude' or 'codex' yourself, or 'cc-stop' to tear it down."
}

# ============================================================
# All-in-one: proxy stack + launch Claude / Codex
# ============================================================

# Path of the real program, never a shell function of the same name
# (PLAIN_COMMANDS=auto defines 'claude' / 'codex' functions).
_bin_path() {
    if [ -n "${ZSH_VERSION:-}" ]; then whence -p "$1"; else type -P "$1"; fi
}

# _launch_via_proxy <label> <binary> <install hint> <skip-prompts flag> [args...]
# Flags the wrapper understands: --safe (keep the app's prompts), --no-verify.
# EVERYTHING ELSE is passed straight to the app, so 'cc -c', 'cc -r',
# 'cc --resume <id>', 'cx resume' ... all work.
_launch_via_proxy() {
    local label="$1" bin="$2" hint="$3" skip_flag="$4"
    shift 4
    local safe=0 quiet=0
    local up_args=() app_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --safe)      safe=1 ;;
            --quiet)     quiet=1 ;;
            --no-verify) up_args+=(--no-verify) ;;
            --node)      up_args+=(--node "${2:-}"); shift ;;
            --node=*)    up_args+=("$1") ;;
            *)           app_args+=("$1") ;;
        esac
        shift
    done

    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    # Locate the app first, so we don't bring the tunnel up only to find it missing.
    if ! _bin_path "$bin" >/dev/null 2>&1; then
        echo "[Err] '$bin' not found - install it first: $hint" >&2
        return 1
    fi

    # Steps 1-3: bring up tunnel + env vars + verify
    local _CLAUDE_LAUNCH_PROVIDER=claude subscriber='' subscriber_stamp='' rc=0 identity saved_int
    [ "$bin" != codex ] || _CLAUDE_LAUNCH_PROVIDER=codex
    # Quiet (plain claude/codex): the profile's own lines go to stderr, so stdout
    # carries only the app's output ('claude -p ... | jq' keeps working).
    if [ "$quiet" -eq 1 ]; then proxy-up "${up_args[@]}" >&2 || return 1
    else proxy-up "${up_args[@]}" || return 1; fi
    if [ "${CLAUDE_TUNNEL_WATCHDOG:-1}" = 1 ]; then
        identity=$(_recovery_owner_start "$_CLAUDE_LAUNCH_PROVIDER") || return 1
        subscriber=$(_recovery_subscribe "$identity" "$_CLAUDE_LAUNCH_PROVIDER")
        subscriber_stamp=$(_recovery_process_identity "$subscriber") || subscriber_stamp=''
        [ "$quiet" -eq 1 ] || echo "[Notify] Desktop alerts: $(_recovery_desktop_backend). Test visibility with proxy-notify test in another terminal."
    else
        echo '[Warn] Automatic recovery and live notifications are disabled.' >&2
    fi

    saved_int=$(trap -p INT)
    trap '_recovery_unsubscribe "$subscriber" "$subscriber_stamp"' INT
    # Step 4: launch (it picks up HTTP(S)_PROXY from this shell's env)
    [ "$quiet" -eq 1 ] || echo "[Launch] Starting $label${app_args:+ (${app_args[*]})}..."
    # 'command': the real program, not a plain-command wrapper of the same name.
    if [ $safe -eq 1 ]; then
        if command "$bin" "${app_args[@]}"; then rc=0; else rc=$?; fi
    else
        if command "$bin" "$skip_flag" "${app_args[@]}"; then rc=0; else rc=$?; fi
    fi
    [ -z "$subscriber" ] || _recovery_unsubscribe "$subscriber" "$subscriber_stamp"
    trap - INT
    [ -z "$saved_int" ] || eval "$saved_int"  # restore the caller's own trap
    return "$rc"
}

cc() { _launch_via_proxy Claude claude "npm install -g @anthropic-ai/claude-code" --dangerously-skip-permissions "$@"; }
cx() { _launch_via_proxy Codex  codex  "npm install -g @openai/codex"            --dangerously-bypass-approvals-and-sandbox "$@"; }
cc-safe() { cc --safe "$@"; }
cx-safe() { cx --safe "$@"; }

# PLAIN_COMMANDS=auto: plain 'claude' / 'codex' start through the tunnel too, in
# safe mode (the app's own prompts) and quietly. Version/help need no network.
_plain_launch() {  # <label> <bin> <install hint> <skip flag> [app args]
    local bin="$2"
    case "${5:-}" in --version|-v|--help|-h) shift 4; command "$bin" "$@"; return;; esac
    _launch_via_proxy "$@" --safe --no-verify --quiet
}
if [ "${CLAUDE_PLAIN_COMMANDS:-off}" = auto ]; then
    claude() { _plain_launch Claude claude "npm install -g @anthropic-ai/claude-code" --dangerously-skip-permissions "$@"; }
    codex()  { _plain_launch Codex  codex  "npm install -g @openai/codex" --dangerously-bypass-approvals-and-sandbox "$@"; }
else
    # Also undoes 'auto' when the setting changes in a running shell.
    case "$(type -t claude 2>/dev/null; whence -w claude 2>/dev/null)" in *function*) unset -f claude;; esac
    case "$(type -t codex 2>/dev/null; whence -w codex 2>/dev/null)" in *function*) unset -f codex;; esac
fi

cc-stop() {
    # tunnel-stop does the hardened kill-all-on-both-ports + verify; honour its
    # result so cc-stop never falsely claims success when a port is still held.
    local rc=0 force=0 others n sessions dir
    case "${1:-}" in --force|-f) force=1 ;; esac

    # The tunnel and settings.json are shared by every window. Stopping them
    # while Claude/Codex runs elsewhere is what used to kill the other tabs.
    # Registered cc/cx sessions count too: ps may not name an npm-installed app.
    others=$(_other_agents)
    n=$(_count "$others") sessions=0
    if dir=$(_recovery_identity 2>/dev/null); then sessions=$(_recovery_sessions "$dir"); fi
    [ "$sessions" -le "$n" ] || n=$sessions
    if [ "$n" -gt 0 ] && [ $force -eq 0 ]; then
        echo "[Stop] $n Claude/Codex session(s) still running in other windows${others:+ (PID $(printf '%s\n' "$others" | tr '\n' ' '| sed 's/ $//'))}."
        echo "       They use this same tunnel - stopping it would cut them off."
        echo "       Proxy stuck?  proxy-restart     (fresh tunnel for every window, sessions keep running)"
        echo "       Stop anyway?  cc-stop --force"
        return 1
    fi

    tunnel-stop || rc=1
    _node_tunnels_stop      # per-node Chrome tunnels (chrome-proxy <node>) go too
    proxy-off
    if [ $rc -eq 0 ]; then
        echo "[OK] All proxy services stopped"
    else
        echo "[Err] Env cleared, but the tunnel did NOT fully stop (see above). Run 'proxy-doctor' to see what's stuck."
        return 1
    fi
}

# Replace a hung tunnel for EVERY window without touching env vars or
# settings.json, so Claude/Codex running in other tabs just carry on.
proxy-restart() {
    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    echo "[Restart] Replacing the SSH tunnel (other windows keep their proxy settings)..."
    tunnel-stop >/dev/null || { tunnel-stop; return 1; }
    tunnel-start || return 1
    local state rc cc hc
    read -r state rc cc hc <<< "$(_proxy_probe "$CLAUDE_HTTP_PORT" 10)"
    if [ "$state" = "ok" ]; then
        echo "[OK]  api.anthropic.com answers through the new tunnel - other windows recover on their next request."
    else
        echo "[FAIL] New tunnel is up, but api.anthropic.com still doesn't answer (curl exit $rc, CONNECT $cc) - the problem is on the VM side. Run 'proxy-doctor'."
        return 1
    fi
}

# ============================================================
# Status check
# ============================================================

proxy-status() {
    _recovery_adopt >/dev/null 2>&1 || :   # use the live owner's tunnel, not stale settings
    proxy-notify status
    local identity provider
    identity=$(_recovery_identity)
    echo "[Recovery] State: $identity (phase | outage start | observed | notice | retries | next | generation | failure | event)"
    for provider in claude codex; do printf '%s: ' "$provider"; _recovery_status "$identity" "$provider" || echo unknown; done

    echo ""
    echo "=== Proxy Status (claude-proxy v$CLAUDE_PROXY_VERSION) ==="
    echo ""
    local tstate hpid hname hport note=""
    read -r tstate hpid hname hport <<< "$(_tunnel_health)"
    case "$tstate" in
        ok)
            if [ -n "$hport" ] && [ "$hport" != "$CLAUDE_HTTP_PORT" ]; then
                export CLAUDE_HTTP_PORT=$hport
                note=" [fallback port]"
            fi
            echo "[ON]  HTTP tunnel   : 127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT (Claude / Codex)$note"
            echo "[ON]  SOCKS tunnel  : 127.0.0.1:$CLAUDE_SOCKS_PORT (Chrome / apps)"
            if _watchdog_pid >/dev/null; then
                echo "[ON]  Watchdog      : PID $(_watchdog_pid) - reconnects by itself"
            else
                echo "[OFF] Watchdog      : none - a dropped link won't heal by itself ('proxy-restart' adds it)"
            fi
            case "$(_proxy_probe "$CLAUDE_HTTP_PORT" 6)" in
                ok*)    echo "[OK]  Proxy answers : yes" ;;
                proxy*) echo "[!!]  Proxy answers : VM proxy answers but the request fails - run 'proxy-doctor'" ;;
                *)      echo "[!!]  Proxy answers : NO - tunnel hung. Run 'proxy-restart' (safe with Claude open in other windows)" ;;
            esac
            ;;
        down)
            echo "[OFF] HTTP tunnel   : not running"
            echo "[OFF] SOCKS tunnel  : not running"
            ;;
        stale)
            echo "[!!]  Tunnel BROKEN : stale ssh (PID $hpid) - run 'cc' to auto-heal (or 'cc-stop')"
            ;;
        foreign)
            echo "[!!]  No tunnel     : port $CLAUDE_HTTP_PORT is used by '$hname' (PID $hpid)"
            echo "      Run 'cc' - it leaves that app alone and uses the next free port automatically."
            ;;
    esac

    local sdir swhy=''
    sdir=$(_recovery_identity 2>/dev/null) || sdir=''
    if [ -n "$sdir" ]; then swhy=$(cut -d'|' -f1 "$sdir/ssh.status" 2>/dev/null); fi
    if [ -n "$swhy" ]; then echo "[!!]  Last ssh error : $(_recovery_ssh_hint "$swhy" "$CLAUDE_SSH_HOST")"; fi
    if [ -n "${HTTPS_PROXY:-}" ]; then
        echo "[ON]  Env HTTPS_PROXY: $HTTPS_PROXY"
    else
        echo "[OFF] Env HTTPS_PROXY: not set"
    fi
    if ! _killswitch_on; then
        echo "[OFF] Kill switch   : off - plain claude/codex go direct while the tunnel is down ('proxy-killswitch on')"
    else
        case "$(_killswitch_pin_state)" in
            "pinned $CLAUDE_HTTP_PORT") echo "[ON]  Kill switch   : Claude pinned to 127.0.0.1:$CLAUDE_HTTP_PORT - no direct connections ('proxy-killswitch' for details)" ;;
            *) echo "[!!]  Kill switch   : on, but Claude's settings are not pinned - run 'proxy-killswitch'" ;;
        esac
    fi
    local nname
    nname=$(_node_active_name)
    if [ -n "$nname" ]; then
        echo "[..]  Node          : $nname ($CLAUDE_SSH_HOST)  - 'proxy-node <name>' switches, 'proxy-nodes' lists  (settings: $CLAUDE_PROXY_CONF)"
    else
        echo "[..]  Server        : $CLAUDE_SSH_HOST  (settings: $CLAUDE_PROXY_CONF)"
    fi
    local nport npid
    while IFS='|' read -r nname nport npid; do
        [ -n "$npid" ] || continue
        echo "[ON]  Chrome tunnel : $nname -> 127.0.0.1:$nport (PID $npid)"
    done <<< "$(_node_tunnels_running)"

    echo ""
    echo "Current external IP:"
    curl -s --max-time 5 ipinfo.io
    echo ""
}

# ============================================================
# Doctor - check every part and say exactly what's wrong + how to fix it
# ============================================================

proxy-doctor() {
    local ok="[ OK ]" warn="[WARN]" bad="[FAIL]"
    echo ""
    echo "=== Proxy Doctor (claude-proxy v$CLAUDE_PROXY_VERSION) ==="

    # --- profile + settings ---
    echo "$ok  Profile: $CLAUDE_PROXY_SELF (v$CLAUDE_PROXY_VERSION) - 'proxy-update --check' to see if a newer one exists"
    if [ -f "$CLAUDE_PROXY_CONF" ]; then
        echo "$ok  Settings: $CLAUDE_PROXY_CONF (server '$CLAUDE_SSH_HOST', VM proxy port $CLAUDE_REMOTE_PROXY_PORT)"
    else
        echo "$warn No $CLAUDE_PROXY_CONF - using built-in defaults (server '$CLAUDE_SSH_HOST'). Fix: proxy-config edit (or re-run the setup wizard)"
    fi
    if grep -qiE "^Host[[:space:]]+$CLAUDE_SSH_HOST([[:space:]]|$)" "$HOME/.ssh/config" 2>/dev/null; then
        echo "$ok  ~/.ssh/config has an alias '$CLAUDE_SSH_HOST'"
    elif [ -z "$CLAUDE_SSH_USER" ]; then
        echo "$warn No 'Host $CLAUDE_SSH_HOST' in ~/.ssh/config and CLAUDE_SSH_USER is blank - ssh may not know how to reach it. Fix: re-run the setup wizard, or set CLAUDE_SSH_USER/KEY (proxy-config edit)"
    fi
    if [ -n "$CLAUDE_NODES_FROM" ]; then
        echo "$ok  Node list comes from VM $CLAUDE_NODES_FROM over SSH ('proxy-nodes --from <vm>' changes it)"
    fi
    if [ -n "$CLAUDE_PROXY_DOMAIN" ]; then
        echo "$ok  Nodes come from DNS: TXT _claude-proxy.$CLAUDE_PROXY_DOMAIN ($(_count "$(_dns_txt "_claude-proxy.$CLAUDE_PROXY_DOMAIN" | grep '^v=cp1 ')") node records visible right now)"
    fi
    if [ -f "$CLAUDE_PROXY_NODES" ]; then
        local nn an
        nn=$(_count "$(_nodes_tsv)"); an=$(_node_active_name)
        echo "$ok  Node catalogue: $CLAUDE_PROXY_NODES ($nn nodes, active: ${an:-none - '$CLAUDE_SSH_HOST' is not a catalogue node}) - 'proxy-nodes --refresh' updates it"
    else
        echo "$warn No node catalogue ($CLAUDE_PROXY_NODES) - only needed for 'proxy-node' / 'chrome-proxy <node>'. Fix: proxy-nodes --refresh"
    fi

    if _is_wsl; then
        local wf
        if [ "${CLAUDE_SYNC_WINDOWS_SETTINGS:-0}" = "1" ]; then
            if wf=$(_win_claude_settings); then
                echo "$ok  WSL: Windows-side Claude kept in sync too ($wf)"
            else
                echo "$warn WSL: SYNC_WINDOWS_SETTINGS=1 but the Windows home folder could not be found (cmd.exe / wslpath unavailable?)"
            fi
        else
            echo "$ok  WSL detected - Windows apps can use the tunnel at http://127.0.0.1:$CLAUDE_HTTP_PORT (Windows-side Claude: proxy-config set SYNC_WINDOWS_SETTINGS 1)"
        fi
    fi

    # --- tools ---
    if command -v ssh >/dev/null 2>&1; then
        echo "$ok  ssh installed ($(ssh -V 2>&1 | head -1))"
    else
        echo "$bad ssh NOT installed - the tunnel cannot be built at all. Fix: sudo apt install openssh-client"
    fi
    if command -v ss >/dev/null 2>&1; then
        echo "$ok  ss installed - ports held by OTHER users are detected (fallback works)"
    else
        echo "$warn ss NOT installed - port checks fall back to lsof, which cannot see other users' sockets, so a port held by root may look free and collide at bind time. Fix: sudo apt install iproute2"
    fi
    if command -v lsof >/dev/null 2>&1; then
        echo "$ok  lsof installed"
    elif command -v ss >/dev/null 2>&1; then
        echo "$ok  lsof not installed - using ss to see which program holds a port"
    else
        echo "$bad lsof and ss NOT installed - status/teardown can't see ports. Fix: sudo apt install lsof"
    fi
    if command -v jq >/dev/null 2>&1; then
        echo "$ok  jq installed ($(jq --version)) - settings.json sync available"
    else
        echo "$warn jq NOT installed - settings.json sync is skipped (shell env vars still work). Fix: sudo apt install jq"
    fi
    if command -v claude >/dev/null 2>&1; then
        echo "$ok  claude installed - 'cc' available"
    else
        echo "$warn claude NOT installed - 'cc' won't work. Fix: npm install -g @anthropic-ai/claude-code"
    fi
    if command -v codex >/dev/null 2>&1; then
        echo "$ok  codex installed - 'cx' available"
    else
        echo "$warn codex NOT installed (optional) - 'cx' won't work. Fix: npm install -g @openai/codex"
    fi

    # --- tunnel / ports ---
    # If the tunnel runs on a fallback port (configured one was busy), adopt it
    # so every check below looks at the right port.
    local dstatus dpid dname dport
    read -r dstatus dpid dname dport <<< "$(_tunnel_health)"
    if [ "$dstatus" = "ok" ] && [ -n "$dport" ] && [ "$dport" != "$CLAUDE_HTTP_PORT" ]; then
        export CLAUDE_HTTP_PORT=$dport
        echo "$ok  Tunnel runs on fallback port $dport (configured port was busy) - checks use it"
    fi

    local http_pids socks_pids http_pid socks_pid
    http_pids=$(_listeners "$CLAUDE_HTTP_PORT")
    socks_pids=$(_listeners "$CLAUDE_SOCKS_PORT")
    http_pid=$(printf '%s\n' "$http_pids" | head -1)
    socks_pid=$(printf '%s\n' "$socks_pids" | head -1)

    if [ -n "$http_pid" ]; then
        echo "$ok  HTTP forward  :$CLAUDE_HTTP_PORT listening (PID $http_pid $(_proc_name "$http_pid"))"
    else
        echo "$bad HTTP forward  :$CLAUDE_HTTP_PORT NOT listening - Claude has no proxy. Fix: tunnel-start (or cc)"
        if [ -s "$CLAUDE_TUNNEL_LOG" ]; then
            echo "       Last ssh error ($CLAUDE_TUNNEL_LOG): $(tail -1 "$CLAUDE_TUNNEL_LOG")"
        fi
    fi
    if [ -n "$socks_pid" ]; then
        echo "$ok  SOCKS forward :$CLAUDE_SOCKS_PORT listening (PID $socks_pid) - Chrome OK"
    else
        echo "$warn SOCKS forward :$CLAUDE_SOCKS_PORT NOT listening - chrome-proxy won't work. Fix: tunnel-start"
    fi
    # Both ports should belong to the SAME ssh process. Different PIDs => a stale
    # leftover (e.g. an old SOCKS+bridge session) is squatting on one of them.
    if [ -n "$http_pid" ] && [ -n "$socks_pid" ] && [ "$http_pid" != "$socks_pid" ]; then
        echo "$warn Ports held by DIFFERENT PIDs ($http_pid vs $socks_pid) - likely a stale process. Fix: run 'cc' (auto-heals stale ssh) or cc-stop"
    fi
    if [ -n "$http_pid" ]; then
        local http_owner
        http_owner=$(_proc_name "$http_pid")
        if [ -n "$http_owner" ] && ! _is_ssh_name "$http_owner"; then
            echo "$bad Port $CLAUDE_HTTP_PORT is held by '$http_owner' (PID $http_pid) - NOT an ssh tunnel. Fix: run 'cc' - it uses the next free port automatically."
        fi
    fi
    # More than one PID on a single port is also a leftover.
    if [ "$(_count "$http_pids")" -gt 1 ]; then
        echo "$warn Port $CLAUDE_HTTP_PORT has MULTIPLE listeners ($(printf '%s\n' "$http_pids" | tr '\n' ' ')) - stale process. Fix: cc-stop"
    fi

    # --- shell env ---
    if [ -n "${HTTPS_PROXY:-}" ]; then
        echo "$ok  Shell env HTTPS_PROXY=$HTTPS_PROXY"
    else
        echo "$warn Shell env HTTPS_PROXY not set in THIS shell. Fix: proxy-on (or cc)"
    fi

    # --- Claude settings.json ---
    if [ "${CLAUDE_SYNC_SETTINGS:-0}" != "1" ]; then
        echo "$ok  settings.json sync disabled (CLAUDE_SYNC_SETTINGS=0)"
    elif [ ! -f "$CLAUDE_SETTINGS" ]; then
        echo "$warn $CLAUDE_SETTINGS does not exist yet (created on first proxy-on)"
    elif ! command -v jq >/dev/null 2>&1; then
        echo "$warn Can't inspect $CLAUDE_SETTINGS without jq"
    elif ! jq empty "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
        echo "$bad $CLAUDE_SETTINGS is INVALID JSON - sync is skipped. Fix by hand, or restore ${CLAUDE_SETTINGS}.bak"
    else
        if [ "$(jq 'has("env")' "$CLAUDE_SETTINGS")" != "true" ]; then
            echo "$warn $CLAUDE_SETTINGS has no \"env\" block yet - proxy-on will add it"
        else
            local sp
            sp=$(jq -r '.env.HTTPS_PROXY // empty' "$CLAUDE_SETTINGS")
            if [ -n "$sp" ]; then
                echo "$ok  settings.json env.HTTPS_PROXY=$sp"
            else
                echo "$warn settings.json has an \"env\" block but no HTTPS_PROXY (proxy currently OFF in config)"
            fi
        fi
    fi

    # --- kill switch ---
    _killswitch_report "$ok" "$warn" "$bad"

    # --- recovery owner ---
    if [ "${CLAUDE_TUNNEL_WATCHDOG:-1}" != "1" ]; then
        echo "$warn Tunnel watchdog disabled (CLAUDE_TUNNEL_WATCHDOG=0) - a dropped link freezes every window until 'proxy-restart'"
    elif _watchdog_pid >/dev/null; then
        echo "$ok  Tunnel watchdog running (PID $(_watchdog_pid)) - reconnects by itself"
    elif [ -n "$http_pid" ]; then
        echo "$warn Tunnel has no watchdog (started by an older profile) - a dropped link won't heal by itself. Fix: proxy-restart"
    fi
    if grep -q "administratively prohibited" "$CLAUDE_TUNNEL_LOG" 2>/dev/null; then
        echo "$bad The VM refuses port forwarding for this login ('administratively prohibited' in $CLAUDE_TUNNEL_LOG)."
        echo "       Fix on the VM: AllowTcpForwarding yes in /etc/ssh/sshd_config (or its Match block for this user), then restart sshd"
    fi

    # --- end-to-end: can we actually reach the API through the proxy? ---
    if [ -n "$http_pid" ]; then
        local pstate prc pcc phc
        read -r pstate prc pcc phc <<< "$(_proxy_probe "$CLAUDE_HTTP_PORT" 10)"
        case "$pstate" in
            ok)
                echo "$ok  api.anthropic.com reachable through the proxy (HTTP $phc)"
                ;;
            proxy)
                echo "$bad The VM's proxy answered but api.anthropic.com could not be reached (curl exit $prc, proxy CONNECT reply $pcc)."
                _doctor_vm_check
                ;;
            *)
                echo "$bad Proxy port is open but NOTHING comes back (curl exit $prc) - checking the VM directly..."
                _doctor_vm_check
                ;;
        esac
    fi
    echo ""
}

# Ask the VM itself (over a separate ssh) whether ITS proxy reaches the API, to
# tell a hung local tunnel apart from a problem on the VM.
_doctor_vm_check() {
    local out rc cc hc direct
    _ssh_dest_args
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${_CP_SSH_DEST[@]}" \
          "curl -s -o /dev/null -m 10 -w '%{http_connect} %{http_code}' -x http://127.0.0.1:$CLAUDE_REMOTE_PROXY_PORT https://api.anthropic.com/; echo \" \$?\"" 2>/dev/null)
    if [ -z "$out" ]; then
        echo "       Can't open a new ssh session to $CLAUDE_SSH_HOST right now (network down, VM down, or the key needs a passphrase: try 'ssh $CLAUDE_SSH_HOST')."
        echo "       Once ssh works again: proxy-restart"
        return
    fi
    read -r cc hc rc <<< "$out"
    if [ "$rc" = "0" ]; then
        echo "       On the VM, its proxy reaches api.anthropic.com fine (HTTP $hc) -> YOUR TUNNEL is the problem (hung after sleep / Wi-Fi change)."
        echo "       Fix: proxy-restart   (safe while Claude runs in other windows; they recover on their next request)"
    elif [ "$cc" = "403" ]; then
        echo "       On the VM, tinyproxy REFUSES the request (CONNECT 403)."
        echo "       Fix on the VM: /etc/tinyproxy/tinyproxy.conf needs 'Allow 127.0.0.1', and 'ConnectPort 443' if any ConnectPort lines exist; then 'webproxy-status'"
    elif [ "$cc" = "000" ] && [ "$hc" = "000" ] && { [ "$rc" = "7" ] || [ "$rc" = "52" ] || [ "$rc" = "56" ]; }; then
        echo "       On the VM, nothing answers on port $CLAUDE_REMOTE_PROXY_PORT (curl exit $rc) -> tinyproxy is down or on another port."
        echo "       Fix on the VM: run 'webproxy-status' and start it; or match the port here: proxy-config set REMOTE_PROXY_PORT <port>"
    else
        direct=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${_CP_SSH_DEST[@]}" \
                 "curl -s -o /dev/null -m 10 -w '%{http_code}' https://api.anthropic.com/" 2>/dev/null)
        if [ -n "$direct" ] && [ "$direct" != "000" ]; then
            echo "       On the VM, the API is reachable directly (HTTP $direct) but not through tinyproxy (curl exit $rc, CONNECT $cc)."
            echo "       Fix on the VM: check tinyproxy's log and config ('webproxy-status')"
        else
            echo "       The VM itself can't reach api.anthropic.com (curl exit $rc) - VM network / firewall / DNS problem, not your Mac."
            echo "       Try another node meanwhile: proxy-nodes, then proxy-node <name>"
        fi
    fi
}

# ============================================================
# Settings file: show / edit / set  (~/.claude-proxy.conf)
# ============================================================

# Write KEY=VALUE into the conf file (replace the line if the key exists,
# append otherwise). Creates the file with a header on first use.
_conf_set() {
    local key="$1" val="$2" tmp
    case "$key" in CLAUDE_*) ;; *) key="CLAUDE_$key" ;; esac
    if [ ! -f "$CLAUDE_PROXY_CONF" ]; then
        {
            echo "# ~/.claude-proxy.conf - YOUR settings for claude-proxy.sh"
            echo "# 'proxy-update' replaces the script but never touches this file."
            echo "# Lines you leave out keep the script's built-in default."
        } > "$CLAUDE_PROXY_CONF"
    fi
    tmp=$(mktemp)
    if grep -q "^${key}=" "$CLAUDE_PROXY_CONF"; then
        # Escape the few characters that matter on the sed replacement side.
        local esc
        esc=$(printf '%s' "$val" | sed 's/[\/&|]/\\&/g')
        sed "s|^${key}=.*|${key}=\"${esc}\"|" "$CLAUDE_PROXY_CONF" > "$tmp" && mv "$tmp" "$CLAUDE_PROXY_CONF"
    else
        rm -f "$tmp"
        printf '%s="%s"\n' "$key" "$val" >> "$CLAUDE_PROXY_CONF"
    fi
}

# Snapshot every current setting into the conf file (used the first time an
# older install - settings embedded in the script - is updated, and by
# 'proxy-config edit' when no file exists yet, so the editor opens on a full template).
_conf_write_all() {
    local k v
    for k in $(echo "$_CLAUDE_CONF_KEYS"); do
        eval "v=\${$k}"
        _conf_set "$k" "$v"
    done
}

_conf_reload() {
    # Re-source the whole profile so defaults + conf apply in the right order.
    _CLAUDE_PROXY_QUIET=1
    . "$CLAUDE_PROXY_SELF"
    _CLAUDE_PROXY_QUIET=0
}

proxy-config() {
    local k v
    case "${1:-show}" in
        show|"")
            echo ""
            echo "=== claude-proxy settings (v$CLAUDE_PROXY_VERSION) ==="
            if [ -f "$CLAUDE_PROXY_CONF" ]; then
                echo "  file: $CLAUDE_PROXY_CONF"
            else
                echo "  file: $CLAUDE_PROXY_CONF  (not created yet - built-in defaults in use)"
            fi
            echo ""
            for k in $(echo "$_CLAUDE_CONF_KEYS"); do
                eval "v=\${$k}"
                printf '  %-26s = %s\n' "$k" "$v"
            done
            printf '  %-26s = %s\n' "CLAUDE_NO_PROXY" "$CLAUDE_NO_PROXY"
            echo ""
            echo "  proxy-config edit               open the file in \$EDITOR"
            echo "  proxy-config set KEY VALUE      e.g. proxy-config set SSH_HOST myvm"
            echo "  proxy-config path               print the file path"
            echo ""
            ;;
        path)
            echo "$CLAUDE_PROXY_CONF"
            ;;
        edit)
            [ -f "$CLAUDE_PROXY_CONF" ] || _conf_write_all
            "${EDITOR:-${VISUAL:-nano}}" "$CLAUDE_PROXY_CONF"
            _conf_reload
            echo "[OK] Settings reloaded from $CLAUDE_PROXY_CONF (server '$CLAUDE_SSH_HOST'). Open shells need: source $CLAUDE_PROXY_SELF"
            ;;
        set)
            if [ $# -lt 3 ]; then
                echo "usage: proxy-config set KEY VALUE   (KEY = one of: $_CLAUDE_CONF_KEYS NO_PROXY)"
                return 1
            fi
            k="$2"; case "$k" in CLAUDE_*) ;; *) k="CLAUDE_$k" ;; esac
            case " $_CLAUDE_CONF_KEYS CLAUDE_NO_PROXY " in
                *" $k "*) ;;
                *) echo "[Err] Unknown key '$2'. Valid: $_CLAUDE_CONF_KEYS CLAUDE_NO_PROXY"; return 1 ;;
            esac
            _conf_set "$k" "$3"
            _conf_reload
            echo "[OK] Saved to $CLAUDE_PROXY_CONF and applied in this shell. Open shells need: source $CLAUDE_PROXY_SELF"
            ;;
        *)
            echo "usage: proxy-config [show|edit|set KEY VALUE|path]"
            return 1
            ;;
    esac
}

# ============================================================
# Self-update: fetch the latest claude-proxy.sh, keep ~/.claude-proxy.conf
# ============================================================

proxy-update() {
    local check=0 force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --check|-n) check=1 ;;
            --force|-f) force=1 ;;
            *) echo "usage: proxy-update [--check] [--force]"; return 1 ;;
        esac
        shift
    done

    local self="$CLAUDE_PROXY_SELF" tmp newver
    tmp=$(mktemp) || return 1
    echo "[Update] Fetching latest profile from GitHub..."
    if ! curl -fsSL "$CLAUDE_PROXY_REPO_RAW/claude-proxy.sh" -o "$tmp"; then
        rm -f "$tmp"
        echo "[Err] Download failed. GitHub not reachable from here? Try 'proxy-up' first, then 'proxy-update' again."
        return 1
    fi
    # Sanity: must be this profile and must parse, or we'd brick every new shell.
    if ! grep -q '^CLAUDE_PROXY_VERSION=' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "[Err] Downloaded file doesn't look like a valid claude-proxy.sh - nothing changed."
        return 1
    fi
    newver=$(sed -n 's/^CLAUDE_PROXY_VERSION="\(.*\)"/\1/p' "$tmp")

    if [ $force -eq 0 ] && cmp -s "$tmp" "$self"; then
        rm -f "$tmp"
        # The file was already updated (e.g. from another shell), but THIS shell
        # still runs an older copy - load the installed one.
        local running="$CLAUDE_PROXY_VERSION"
        if [ -n "$newver" ] && [ "$newver" != "$running" ]; then
            if [ $check -eq 1 ]; then
                echo "[Info] $self is already v$newver, but this shell runs v$running - 'proxy-update' loads it"
            else
                _conf_reload
                echo "[OK] $self was already v$newver - loaded it into this shell (it was running v$running)"
            fi
            return 0
        fi
        echo "[OK] Already up to date (v$running)"
        return 0
    fi
    if [ $check -eq 1 ]; then
        rm -f "$tmp"
        echo "[Info] Update available: v$CLAUDE_PROXY_VERSION -> v$newver. Run 'proxy-update' to install it."
        return 0
    fi

    # First update from an install that still had settings inside the script:
    # snapshot them to the conf file so nothing has to be typed again.
    if [ ! -f "$CLAUDE_PROXY_CONF" ]; then
        _conf_write_all
        echo "[OK] Saved your current settings to $CLAUDE_PROXY_CONF (they survive every future update)"
    fi

    cp "$self" "$self.bak" 2>/dev/null
    if ! cp "$tmp" "$self"; then
        rm -f "$tmp"
        echo "[Err] Could not write $self"
        return 1
    fi
    rm -f "$tmp"
    echo "[OK] Updated $self: v$CLAUDE_PROXY_VERSION -> v$newver  (previous copy: $self.bak)"
    _conf_reload
    echo "[OK] New version loaded in this shell; other open shells pick it up when reopened."
}

# ============================================================
# Launch Chrome through the SOCKS5 proxy (separate, isolated profile)
# ============================================================

# Chrome keys a RUNNING instance on its --user-data-dir, not on its flags: a
# second launch into the same dir just opens a window in the existing instance
# and silently ignores a different --proxy-server. So every node gets its own
# profile dir (<base>-<node>), which is also what keeps logins/cookies per region.
# The pre-2.1 dir (<base>) is renamed to the active node's dir once, so nobody
# loses their existing logins.
_chrome_profile_dir() {  # <base linux path> <node name>   (prints the dir to use)
    local base="$1" name="$2" target
    [ -n "$name" ] || { echo "$base"; return; }
    target="$base-$name"
    if [ ! -d "$target" ] && [ -d "$base" ] && [ "$name" = "$(_node_active_name)" ]; then
        if mv "$base" "$target" 2>/dev/null; then
            echo "[Info] Chrome profile moved to $target (per-node profiles since v2.1) - your logins are kept" >&2
        else
            echo "$base"; return
        fi
    fi
    echo "$target"
}

# Base of the per-node Chrome data dirs (a Linux path; under WSL it is on C:).
_chrome_base_dir() {
    if _is_wsl; then
        echo "/mnt/c/wsl-proxy-profile"
    elif [ "$(uname)" = "Darwin" ]; then
        echo "$HOME/.chrome-proxy-profile"
    else
        echo "$HOME/.config/google-chrome-vpn"
    fi
}

# chrome-proxy [node] [--profile NAME] [url ...]
#   chrome-proxy            Chrome through the node cc/cx use (main tunnel; starts it if needed)
#   chrome-proxy sg         Chrome through node 'sg' on its OWN SOCKS tunnel + profile -
#                           the main tunnel and other nodes' windows are untouched
#   chrome-proxy sg -p work ...as Chrome profile 'work' (created on first use). Every profile
#                           of a node lives in that node's data dir, so all of them share its
#                           tunnel and IP but keep their own logins/cookies/extensions.
#   chrome-proxy sg URL     ...and open URL there (any other argument is passed to Chrome)
chrome-proxy() {
    local a line node="" name idx alias host rest socks port label profile="" want_profile=0
    local extra=() pargs=()
    for a in "$@"; do
        if [ $want_profile -eq 1 ]; then
            profile="$a"; want_profile=0
            continue
        fi
        case "$a" in
            -p|--profile) want_profile=1; continue ;;
            --profile=*)  profile="${a#--profile=}"; continue ;;
        esac
        if [ -z "$node" ] && line=$(_node_lookup "$a"); then
            node="$a"
        else
            if [ -z "$node" ] && printf '%s\n' "$a" | LC_ALL=C grep -Eq '^[A-Za-z][A-Za-z0-9]*$'; then
                echo "[Err] Unknown proxy node '$a' - Chrome not launched. Run 'proxy-nodes --refresh' in this window and check the list. For a website, use an explicit URL such as https://$a/ ."
                return 1
            fi
            extra+=("$a")
        fi
    done
    if [ $want_profile -eq 1 ]; then
        echo "usage: chrome-proxy [node] --profile <name> [url]   ('chrome-profiles' lists the existing ones)"
        return 1
    fi
    case "$profile" in
        "") ;;
        default|Default) profile="Default" ;;
        *[!A-Za-z0-9._\ -]*|.*)
            echo "[Err] Profile names may only use letters, digits, space, '.', '_' and '-' (got '$profile')"
            return 1 ;;
    esac
    [ -n "$profile" ] && pargs=(--profile-directory="$profile")

    if [ -n "$node" ]; then
        IFS='|' read -r idx name alias host rest <<< "$line"
        if [ "$alias" = "$CLAUDE_SSH_HOST" ] && [ "$(_tunnel_health | awk '{print $1}')" = "ok" ]; then
            port="$CLAUDE_SOCKS_PORT"; label="$name (main tunnel)"
            echo "[OK]  $name is the active node and its tunnel is up - reusing it"
        else
            _node_ensure_alias "$line" || return 1
            port=$(_node_socks_port "$idx")
            _node_tunnel_start "$name" "$alias" "$port" || {
                echo "[Err] $name tunnel could not be started - Chrome not launched. Try 'ssh $alias' by hand to see why."
                return 1
            }
            label="$name (own tunnel)"
        fi
    else
        # Main tunnel (the node cc/cx use). Ensure it's up; bail if it won't start.
        if ! _port_in_use "$CLAUDE_SOCKS_PORT"; then
            echo "[Info] SSH tunnel (SOCKS port $CLAUDE_SOCKS_PORT) not running - starting it..."
            tunnel-start
            _port_in_use "$CLAUDE_SOCKS_PORT" || {
                echo "[Err] SSH tunnel could not be started - Chrome not launched. Run 'proxy-doctor' to diagnose."
                return 1
            }
        else
            echo "[OK]  SSH tunnel already running"
        fi
        port="$CLAUDE_SOCKS_PORT"
        name=$(_node_active_name)
        label="${name:-$CLAUDE_SSH_HOST} (main tunnel)"
    fi
    socks="socks5://127.0.0.1:$port"

    local c pdir dock_tip=""
    if _is_wsl; then
        # WSL has no Linux Chrome; drive Windows Chrome instead. It reaches the
        # WSL-side SOCKS port via WSL2 localhost forwarding (on by default).
        local win_chrome=""
        for c in "$CLAUDE_CHROME_BIN" \
            "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
            "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"; do
            [ -n "$c" ] && [ -x "$c" ] && { win_chrome="$c"; break; }
        done
        [ -n "$win_chrome" ] || {
            echo "[Err] Windows Chrome not found under /mnt/c - set its path: proxy-config set CHROME_BIN '/mnt/c/.../chrome.exe' (or launch it manually with --proxy-server=$socks)"
            return 1
        }
        # Profile dir is a Windows path; do the one-time rename via /mnt/c.
        pdir=$(_chrome_profile_dir "$(_chrome_base_dir)" "$name")
        pdir="C:\\${pdir#/mnt/c/}"
        "$win_chrome" \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="$pdir" "${pargs[@]}" \
            --no-first-run "${extra[@]}" >/dev/null 2>&1 &
        [ -n "$profile" ] && label="$label, profile '$profile'"
        echo "[OK] Windows Chrome launched through $label - $socks, data dir $pdir"
        return
    fi

    # Native Linux / macOS
    if [ "$(uname)" = "Darwin" ]; then
        local app="${CLAUDE_CHROME_BIN:-Google Chrome}"
        [ -n "$CLAUDE_CHROME_BIN" ] || [ -d "/Applications/Google Chrome.app" ] || {
            echo "[Err] Google Chrome not found in /Applications - set it: proxy-config set CHROME_BIN 'Chromium' (app name or path)"
            return 1
        }
        # A dedicated user-data-dir OUTSIDE the real Chrome folder: the proxied
        # Chrome is fully isolated and can never touch your normal profiles.
        pdir=$(_chrome_profile_dir "$(_chrome_base_dir)" "$name")
        # macOS gives an app ONE Dock icon: if the normal Chrome is not running,
        # the proxied one takes that icon over and a click on it only re-focuses
        # the proxied window - the normal Chrome then needs 'open -n' to start.
        local procs bundle="${app##*/}"
        bundle="${bundle%.app}.app/Contents/MacOS/"
        procs=$(ps -axo command= 2>/dev/null)
        printf '%s\n' "$procs" | grep -F -- "$bundle" | grep -qv -- '--user-data-dir=' \
            || dock_tip="open -n -a \"$app\""
        open -n -a "$app" --args \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="$pdir" "${pargs[@]}" \
            --no-first-run "${extra[@]}"
    else
        local bin
        bin="$CLAUDE_CHROME_BIN"
        [ -n "$bin" ] || bin=$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)
        [ -n "$bin" ] || { echo "[Err] Chrome/Chromium not found on PATH - set it: proxy-config set CHROME_BIN /path/to/chrome"; return 1; }
        pdir=$(_chrome_profile_dir "$(_chrome_base_dir)" "$name")
        nohup "$bin" \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="$pdir" "${pargs[@]}" \
            --no-first-run "${extra[@]}" >/dev/null 2>&1 &
    fi
    [ -n "$profile" ] && label="$label, profile '$profile'"
    echo "[OK] Chrome launched through $label - $socks, data dir $pdir"
    [ -z "$dock_tip" ] || echo "[Tip] The Dock's Chrome icon now points at this proxied Chrome. To open your normal Chrome next to it:  $dock_tip"
}

# chrome-profiles [node]  - the Chrome profiles that exist in each node's data dir
chrome-profiles() {
    local want="${1:-}" base idx name alias rest dir prefs p disp state found=0
    base=$(_chrome_base_dir)
    echo ""
    echo "=== Chrome profiles per node (data dirs: $base-<node>) ==="
    while IFS='|' read -r idx name alias rest; do
        [ -n "$idx" ] || continue
        [ -z "$want" ] || [ "$want" = "$name" ] || [ "$want" = "$alias" ] || continue
        dir="$base-$name"
        [ -d "$dir" ] || continue
        found=1
        state=""
        if [ -L "$dir/SingletonLock" ] || [ -e "$dir/lockfile" ]; then state="  (Chrome open)"; fi
        echo ""
        echo "  $name ($alias)$state"
        prefs=$(find "$dir" -mindepth 2 -maxdepth 2 -name Preferences 2>/dev/null | sort)
        if [ -z "$prefs" ]; then
            echo "      (no profile yet - opens as 'Default')"
            continue
        fi
        while IFS= read -r p; do
            p=$(basename "$(dirname "$p")")
            case "$p" in "System Profile"|"Guest Profile") continue ;; esac
            disp=""
            if command -v jq >/dev/null 2>&1 && [ -f "$dir/Local State" ]; then
                disp=$(jq -r --arg k "$p" '.profile.info_cache[$k].name // empty' "$dir/Local State" 2>/dev/null)
            fi
            [ -n "$disp" ] && disp="\"$disp\""
            printf '      %-20s %s\n' "$p" "$disp"
        done <<< "$prefs"
    done <<< "$(_nodes_tsv)"
    if [ $found -eq 0 ]; then
        echo ""
        if [ -n "$want" ]; then echo "  (none yet for '$want')"; else echo "  (none yet)"; fi
    fi
    echo ""
    echo "  chrome-proxy <node> --profile <name>   open one (a new name creates it; 'Default' is the first)"
    echo "  Profiles added from Chrome's own profile menu show up here too (e.g. 'Profile 1')."
    echo ""
}

# ============================================================
# cc-install - check / install / update Node.js, Claude Code and Codex
# ============================================================
# Downloads go through the proxy (it's started first), so this works on a
# blocked network too. Nothing is changed without asking (unless -y).

CLAUDE_TOOLS_MIN_NODE_FALLBACK=22   # used when the npm registry can't be asked

_tools_ask() {  # <question> [Y|N] - honours $_TOOLS_YES / $_TOOLS_CHECK
    [ "${_TOOLS_CHECK:-0}" = 1 ] && return 1
    [ "${_TOOLS_YES:-0}" = 1 ] && return 0
    local def="${2:-Y}" hint r
    [ "$def" = Y ] && hint="[Y/n]" || hint="[y/N]"
    { printf '%s %s: ' "$1" "$hint" > /dev/tty; } 2>/dev/null || return 1
    IFS= read -r r < /dev/tty || r=""
    [ -n "$r" ] || r="$def"
    case "$r" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

_tools_skip() { [ "${_TOOLS_CHECK:-0}" = 1 ] || echo "      Skipped${1:+ - $1}"; }

_tools_major() { printf '%s' "$1" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\).*/\1/p'; }
_tools_semver() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
_tools_older() {  # <a> <b> : true when version a < b
    [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] &&
        [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}

# The Node.js major version Claude Code (and Codex) need, from their npm metadata.
_tools_min_node() {
    local m best=0 pkg
    for pkg in @anthropic-ai/claude-code @openai/codex; do
        m=$(curl -fsS --max-time 8 "https://registry.npmjs.org/$pkg/latest" 2>/dev/null |
            sed -n 's/.*"engines":{[^}]*"node":"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -1)
        [ -n "$m" ] && [ "$m" -gt "$best" ] && best=$m
    done
    [ "$best" -gt 0 ] || best=$CLAUDE_TOOLS_MIN_NODE_FALLBACK
    echo "$best"
}

# Newest Node.js LTS, e.g. v24.8.0 ("" if nodejs.org can't be reached).
_tools_node_lts() {
    curl -fsS --max-time 10 https://nodejs.org/dist/index.json 2>/dev/null |
        tr '{' '\n' | grep -m1 '"lts":"' | sed -n 's/.*"version":"\(v[0-9.]*\)".*/\1/p'
}

_tools_node_version() { command -v node >/dev/null 2>&1 && node --version 2>/dev/null; }

# Install / upgrade Node.js to the current LTS with whatever this machine uses.
_tools_install_node() {
    local ver tmp
    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
        echo "[Tools] Using nvm: nvm install --lts"
        # shellcheck disable=SC1090,SC1091
        . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && nvm install --lts && nvm alias default 'lts/*'
        return
    fi
    if [ "$(uname)" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            if brew list --formula node >/dev/null 2>&1; then
                echo "[Tools] brew upgrade node"; brew upgrade node
            else
                echo "[Tools] brew install node"; brew install node
            fi
            return
        fi
        ver=$(_tools_node_lts)
        [ -n "$ver" ] || { echo "[Err] Can't reach nodejs.org to find the LTS version."; return 1; }
        tmp=$(mktemp -d)
        echo "[Tools] Downloading the official Node.js $ver installer (you'll be asked for your Mac password)..."
        curl -fL --progress-bar -o "$tmp/node.pkg" "https://nodejs.org/dist/$ver/node-$ver.pkg" &&
            sudo installer -pkg "$tmp/node.pkg" -target /
        local rc=$?; rm -rf "$tmp"; return $rc
    fi
    if command -v apt-get >/dev/null 2>&1; then
        tmp=$(mktemp)
        echo "[Tools] Installing Node.js LTS from NodeSource (apt; you may be asked for your password)..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$tmp" &&
            sudo -E bash "$tmp" && sudo -E apt-get install -y nodejs
        local rc=$?; rm -f "$tmp"; return $rc
    fi
    if command -v dnf >/dev/null 2>&1; then
        tmp=$(mktemp)
        echo "[Tools] Installing Node.js LTS from NodeSource (dnf; you may be asked for your password)..."
        curl -fsSL https://rpm.nodesource.com/setup_lts.x -o "$tmp" &&
            sudo -E bash "$tmp" && sudo -E dnf install -y nodejs
        local rc=$?; rm -f "$tmp"; return $rc
    fi
    echo "[Err] Don't know how to install Node.js here - install the LTS from https://nodejs.org, then run cc-install again."
    return 1
}

_tools_node() {  # <min major>
    local min="$1" cur major
    cur=$(_tools_node_version)
    major=$(_tools_major "$cur")
    if [ -n "$major" ] && [ "$major" -ge "$min" ]; then
        echo "[OK]  Node.js $cur (needs $min or newer)"
        return 0
    fi
    if [ -z "$cur" ]; then
        echo "[..]  Node.js is not installed (Claude Code needs version $min or newer)"
        _tools_ask "Install Node.js LTS now?" Y || { _tools_skip "Claude Code and Codex can't be installed without it."; return 1; }
    else
        echo "[..]  Node.js $cur is too old (Claude Code needs $min or newer)"
        _tools_ask "Upgrade Node.js to the current LTS now?" Y || { _tools_skip; return 1; }
    fi
    _tools_install_node || { echo "[Err] Node.js installation failed (see above)."; return 1; }
    hash -r 2>/dev/null
    cur=$(_tools_node_version); major=$(_tools_major "$cur")
    if [ -n "$major" ] && [ "$major" -ge "$min" ]; then
        echo "[OK]  Node.js $cur installed"
        return 0
    fi
    echo "[Err] 'node' is still ${cur:-missing} in this shell."
    command -v node >/dev/null 2>&1 && echo "      Another node comes first on PATH: $(command -v node) - open a new terminal, or remove the old one."
    return 1
}

# Global npm installs must not need sudo: offer npm's own ~/.npm-global setup.
_tools_npm_prefix() {
    local p rc
    p=$(npm prefix -g 2>/dev/null) || return 1
    if [ -w "$p/lib/node_modules" ] || { [ ! -e "$p/lib/node_modules" ] && [ -w "$p/lib" ]; } ||
       { [ ! -e "$p/lib" ] && [ -w "$p" ]; }; then
        return 0
    fi
    echo "[..]  Global npm packages go to $p, which needs sudo."
    _tools_ask "Use ~/.npm-global for them instead (npm's recommended fix, no sudo)?" Y || return 1
    mkdir -p "$HOME/.npm-global" && npm config set prefix "$HOME/.npm-global" || return 1
    export PATH="$HOME/.npm-global/bin:$PATH"
    case "$(basename "${SHELL:-}")" in zsh) rc="$HOME/.zshrc" ;; *) rc="$HOME/.bashrc" ;; esac
    if ! grep -q '.npm-global/bin' "$rc" 2>/dev/null; then
        printf '\nexport PATH="$HOME/.npm-global/bin:$PATH"   # npm global packages (cc-install)\n' >> "$rc"
    fi
    echo "[OK]  npm global prefix: ~/.npm-global (PATH added to $rc)"
}

_tools_pkg() {  # <label> <command> <npm package> <update hint when not installed by npm>
    local label="$1" bin="$2" pkg="$3" hint="$4" latest cur
    latest=$(npm view "$pkg" version 2>/dev/null)
    if command -v "$bin" >/dev/null 2>&1; then
        cur=$(_tools_semver "$(command "$bin" --version 2>/dev/null)")
        if [ -z "$latest" ]; then
            echo "[OK]  $label ${cur:-(version unknown)} installed (npm registry not reachable - can't check for updates)"
            return 0
        fi
        if ! _tools_older "$cur" "$latest"; then
            echo "[OK]  $label ${cur:-?} (latest: $latest)"
            return 0
        fi
        if ! npm ls -g "$pkg" --depth=0 >/dev/null 2>&1; then
            echo "[..]  $label $cur is older than $latest, but wasn't installed with npm - update it with: $hint"
            return 0
        fi
        echo "[..]  $label $cur is out of date (latest: $latest)"
        _tools_ask "Update $label to $latest now?" Y || { _tools_skip; return 0; }
    else
        if [ -z "$latest" ]; then
            echo "[Err] $label is not installed and the npm registry can't be reached (is the proxy up? try 'proxy-up')."
            return 1
        fi
        echo "[..]  $label is not installed (latest: $latest)"
        _tools_ask "Install $label now?" Y || { _tools_skip; return 0; }
    fi
    _tools_npm_prefix || { echo "[Err] Can't install without a writable npm prefix."; return 1; }
    echo "[Tools] npm install -g $pkg@latest"
    npm install -g "$pkg@latest" || { echo "[Err] npm install failed (see above)."; return 1; }
    hash -r 2>/dev/null
    cur=$(_tools_semver "$(command "$bin" --version 2>/dev/null)")
    if [ -n "$cur" ]; then
        echo "[OK]  $label $cur ready - run it through the proxy with '${5:-$bin}'"
    else
        echo "[Warn] $label installed, but '$bin' isn't found in this shell yet - open a new terminal."
    fi
}

cc-install() {
    local want="" a node_ok=1 min rc=0
    _TOOLS_YES=0 _TOOLS_CHECK=0
    local proxy=1
    for a in "$@"; do
        case "$a" in
            -y|--yes) _TOOLS_YES=1 ;;
            -n|--check) _TOOLS_CHECK=1 ;;
            --no-proxy) proxy=0 ;;
            node|claude|codex) want="$want $a" ;;
            -h|--help)
                echo "usage: cc-install [node] [claude] [codex] [--check] [-y] [--no-proxy]"
                echo "  checks Node.js, Claude Code and Codex; installs / updates what's missing or old (asks first)"
                return 0 ;;
            *) echo "[Err] Unknown argument '$a' - see: cc-install --help"; return 1 ;;
        esac
    done
    [ -n "$want" ] || want=" node claude codex"

    echo ""
    echo "=== Node.js / Claude Code / Codex$([ "$_TOOLS_CHECK" = 1 ] && echo ' (check only)') ==="
    if [ $proxy = 1 ] && [ -z "${HTTPS_PROXY:-}" ]; then
        echo "[Tools] Starting the proxy first, so downloads go through your VM..."
        proxy-up --no-verify >/dev/null 2>&1 && echo "[OK]  Proxy is up" ||
            echo "[Warn] Proxy didn't start - trying the internet directly ('proxy-doctor' explains why)"
    fi
    min=$(_tools_min_node)
    case "$want" in *node*) _tools_node "$min" || { node_ok=0; rc=1; } ;; esac
    if [ $node_ok = 1 ] && ! command -v npm >/dev/null 2>&1; then
        echo "[Err] npm is missing - it comes with Node.js; reinstall Node.js (cc-install node)."
        node_ok=0; rc=1
    fi
    if [ $node_ok = 1 ]; then
        case "$want" in *claude*) _tools_pkg "Claude Code" claude @anthropic-ai/claude-code "claude update" cc || rc=1 ;; esac
        case "$want" in *codex*)  _tools_pkg "Codex" codex @openai/codex "brew upgrade codex (or your package manager)" cx || rc=1 ;; esac
    else
        case "$want" in *claude*|*codex*) echo "[..]  Claude Code / Codex skipped - they need Node.js $min or newer first." ;; esac
    fi
    echo ""
    [ "$_TOOLS_CHECK" = 1 ] && echo "Check only - nothing was changed. Run 'cc-install' to install / update."
    return $rc
}

# ============================================================
# Help / command list
# ============================================================

cc-help() {
    echo ""
    echo "=== Claude / Codex + SSH Tunnel Quick Commands (claude-proxy v$CLAUDE_PROXY_VERSION) ==="
    echo "  cc              - Turn the proxy ON and launch Claude (skips permission prompts)"
    echo "  cc -c / cc -r   - Same, but continue the last session / pick one to resume"
    echo "  cc-safe         - Same as cc, but keeps Claude's permission prompts"
    echo "  cx              - Turn the proxy ON and launch Codex (skips approval prompts)"
    echo "  cx-safe         - Same, but keeps Codex's approval prompts"
    echo "                    (anything after cc/cx is passed to claude/codex as-is)"
    echo "  proxy-up        - Turn the proxy ON, but DON'T launch anything"
    echo "  proxy-restart   - Proxy stuck? New tunnel for ALL windows; Claude in other tabs keeps running"
    echo "  cc-stop         - Turn the proxy OFF (one off-switch for cc AND cx; refuses while other tabs use it, --force to insist)"
    echo "  proxy-notify test - show a real desktop test alert (no proxy/session changes)"
    echo "  proxy-test prolonged --fast - safely preview outage warnings (no live changes)"
    echo "  proxy-status    - Show what's running + your external IP"
    echo "  proxy-doctor    - Diagnose each part and say exactly what's wrong + how to fix"
    echo "  cc-install      - Check / install / update Node.js, Claude Code and Codex (--check: report only)"
    echo ""
    echo "  -- nodes (jp / sg / us ...) --"
    echo "  proxy-nodes     - List the nodes (--refresh: download the latest catalogue + create ssh aliases)"
    echo "  proxy-node sg   - Make 'sg' the node cc / cx use (also: cc --node sg, cx --node sg)"
    echo "  chrome-proxy sg - Chrome through 'sg' on its own tunnel + profile (jp and sg can be open together)"
    echo "  chrome-proxy jp --profile work - another Chrome profile through jp ('chrome-profiles' lists them)"
    echo "  proxy-nodes --from jpvpn - get the node list privately from a VM over SSH (--domain <d>: public DNS)"
    echo ""
    echo "  -- settings & updates --"
    echo "  proxy-config    - Show your settings (edit / set KEY VALUE) - stored in ~/.claude-proxy.conf"
    echo "  proxy-update    - Fetch the latest version of this profile; your settings are kept"
    echo ""
    echo "  -- advanced: manage one piece at a time --"
    echo "  tunnel-start    - Start the SSH tunnel (HTTP forward for Claude + SOCKS5 for Chrome)"
    echo "  tunnel-stop     - Stop the SSH tunnel"
    echo "  proxy-on        - Set proxy env vars + sync Claude settings.json"
    echo "  proxy-off       - Clear proxy env vars (Claude settings.json keeps the proxy while the kill switch is on)"
    echo "  proxy-killswitch - Show the kill switch (on/off): Claude/Codex never go out directly"
    echo ""
    echo "  chrome-proxy    - Open Chrome via SOCKS5 through the active node (auto-starts the tunnel, separate profile)"
    echo "                    chrome-proxy [node] [--profile name] [url]  - e.g. chrome-proxy us -p shop https://example.com"
    echo "  cc-help         - Show this list again"
    echo ""
}

# Kill switch: make sure Claude's settings point at the tunnel (also protects IDE
# launches that never run cc). Writes only when missing or wrong; silent otherwise.
{ _killswitch_ensure_pin 2>/dev/null; } >&2

# One line when a new shell loads this file. Silence it with
# CLAUDE_PROXY_BANNER=0 in ~/.claude-proxy.conf.
if [ "${CLAUDE_PROXY_BANNER:-1}" = "1" ] && [ "${_CLAUDE_PROXY_QUIET:-0}" != "1" ]; then
    _bn=$(_node_active_name)
    echo "claude-proxy v$CLAUDE_PROXY_VERSION ready (node: ${_bn:+$_bn / }$CLAUDE_SSH_HOST) - 'cc' launches Claude, 'cc-help' lists all commands"
    unset _bn
fi
