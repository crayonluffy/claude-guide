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
# ============================================================

CLAUDE_PROXY_VERSION="2.0.0"
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

# Also write the proxy into Claude's settings.json while the tunnel is up, so
# `claude` launched from ANY shell (not just this one) uses it. Removed again on
# proxy-off / cc-stop, so a down tunnel never leaves Claude pointed at a dead proxy.
# Needs `jq`; set to 0 to disable and rely on shell env vars only.
CLAUDE_SYNC_SETTINGS=1
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

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
CLAUDE_TUNNEL_LOG="/tmp/claude-tunnel.log"

# --- personal overrides ------------------------------------------------------
if [ -f "$CLAUDE_PROXY_CONF" ]; then
    . "$CLAUDE_PROXY_CONF"
fi
export CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_KEY CLAUDE_SSH_PORT \
       CLAUDE_HTTP_PORT CLAUDE_REMOTE_PROXY_PORT CLAUDE_SOCKS_PORT \
       CLAUDE_SYNC_SETTINGS CLAUDE_SETTINGS CLAUDE_NO_PROXY CLAUDE_PROXY_CONF

# The keys a conf file may carry (used by proxy-config / migration).
_CLAUDE_CONF_KEYS="CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_KEY CLAUDE_SSH_PORT CLAUDE_HTTP_PORT CLAUDE_REMOTE_PROXY_PORT CLAUDE_SOCKS_PORT CLAUDE_SYNC_SETTINGS CLAUDE_SYNC_WINDOWS_SETTINGS CLAUDE_PROXY_BANNER"

# ============================================================
# Helpers
# ============================================================

# PIDs listening on a TCP port, one per line (empty if none).
_listeners() {
    lsof -ti:"$1" -sTCP:LISTEN 2>/dev/null
}

_port_in_use() {
    [ -n "$(_listeners "$1")" ]
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
            other=$(lsof -aPn -p "$pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null \
                    | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p' | sort -u \
                    | grep -vx "$CLAUDE_SOCKS_PORT")
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

# --- Claude settings.json sync (toggle-synced with the proxy) ---------------
_settings_file_proxy_on() {  # <settings.json>
    local f="$1" url="http://127.0.0.1:$CLAUDE_HTTP_PORT" tmp
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

# ============================================================
# 1. SSH tunnel: -L (HTTP proxy for Claude) + -D (SOCKS5 for Chrome)
# ============================================================

tunnel-start() {
    # Auto-heal: a HEALTHY tunnel is reused (adopting its port if it's on a
    # fallback), a STALE ssh is killed and replaced, and a FOREIGN app keeps its
    # port - the tunnel simply falls back to the next free port instead.
    local tstate hpid hname hport newp
    read -r tstate hpid hname hport <<< "$(_tunnel_health)"
    case "$tstate" in
        ok)
            if [ -n "$hport" ] && [ "$hport" != "$CLAUDE_HTTP_PORT" ]; then
                export CLAUDE_HTTP_PORT=$hport
                echo "[OK]  SSH tunnel already running (PID $hpid) on fallback port $hport - using it"
            else
                echo "[OK]  SSH tunnel already running (PID $hpid)"
            fi
            return 0
            ;;
        stale)
            echo "[Heal] Stale ssh tunnel (PID $hpid) - killing it and starting fresh..."
            tunnel-stop
            ;;
        foreign)
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
    local args=(-N -f -C
        -L "${CLAUDE_HTTP_PORT}:127.0.0.1:${CLAUDE_REMOTE_PROXY_PORT}"
        -D "${CLAUDE_SOCKS_PORT}"
        -o ServerAliveInterval=60
        -o ServerAliveCountMax=3
        -o ExitOnForwardFailure=yes
        -o StrictHostKeyChecking=accept-new)
    # Explicit key/port/user are optional - leave CLAUDE_SSH_KEY/USER blank to use an ~/.ssh/config alias
    [ -n "$CLAUDE_SSH_KEY" ] && args+=(-i "$CLAUDE_SSH_KEY" -p "$CLAUDE_SSH_PORT")
    if [ -n "$CLAUDE_SSH_USER" ]; then args+=("$CLAUDE_SSH_USER@$CLAUDE_SSH_HOST"); else args+=("$CLAUDE_SSH_HOST"); fi
    # stderr -> log so a failed tunnel is debuggable (auth error vs. network timeout).
    ssh "${args[@]}" 2>"$CLAUDE_TUNNEL_LOG"

    local attempts=0
    while ! _port_in_use "$CLAUDE_HTTP_PORT" && [ $attempts -lt 10 ]; do
        sleep 0.5
        attempts=$((attempts+1))
    done

    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[OK]  SSH tunnel up:"
        echo "       HTTP  127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT   (Claude / Codex)"
        echo "       SOCKS 127.0.0.1:$CLAUDE_SOCKS_PORT                                   (Chrome / apps)"
    else
        echo "[Err] SSH tunnel failed to start within 5s. ssh said:"
        sed 's/^/       /' "$CLAUDE_TUNNEL_LOG" 2>/dev/null | head -5
        echo "       (full log: $CLAUDE_TUNNEL_LOG - 'proxy-doctor' for more)"
        return 1
    fi
}

tunnel-stop() {
    # Kill every SSH process listening on either forwarded port (ours, including
    # stale leftovers), then verify. Non-ssh apps that happen to sit on a tunnel
    # port are NOT ours - they are reported and left alone.
    local pid name port still p
    local ssh_pids=() survivors=()

    for pid in $( { _listeners "$CLAUDE_HTTP_PORT"; _listeners "$CLAUDE_SOCKS_PORT"; } | sort -u ); do
        name=$(_proc_name "$pid")
        if [ -z "$name" ] || _is_ssh_name "$name"; then
            ssh_pids+=("$pid")
        else
            echo "[Skip] PID $pid ($name) on a tunnel port - another app, left alone"
        fi
    done

    if [ ${#ssh_pids[@]} -eq 0 ]; then
        echo "[Info] No tunnel running on ports $CLAUDE_HTTP_PORT / $CLAUDE_SOCKS_PORT"
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
    _claude_settings_proxy_off
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
    local no_verify=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-verify) no_verify=1 ;;
        esac
        shift
    done

    # Step 1: SSH tunnel (HTTP + SOCKS forwards).
    # tunnel-start no-ops when the tunnel is healthy, auto-heals a stale one,
    # and falls back to a free port when a foreign app holds the configured one -
    # so require actual health afterwards, not just "something is on the port".
    tunnel-start || return 1
    [ "$(_tunnel_health | awk '{print $1}')" = "ok" ] || return 1

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

# _launch_via_proxy <label> <binary> <install hint> <skip-prompts flag> [args...]
# Flags the wrapper understands: --safe (keep the app's prompts), --no-verify.
# EVERYTHING ELSE is passed straight to the app, so 'cc -c', 'cc -r',
# 'cc --resume <id>', 'cx resume' ... all work.
_launch_via_proxy() {
    local label="$1" bin="$2" hint="$3" skip_flag="$4"
    shift 4
    local safe=0
    local up_args=() app_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --safe)      safe=1 ;;
            --no-verify) up_args+=(--no-verify) ;;
            *)           app_args+=("$1") ;;
        esac
        shift
    done

    # Locate the app first, so we don't bring the tunnel up only to find it missing.
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "[Err] '$bin' not found - install it first: $hint"
        return 1
    fi

    # Steps 1-3: bring up tunnel + env vars + verify
    proxy-up "${up_args[@]}" || return 1

    # Step 4: launch (it picks up HTTP(S)_PROXY from this shell's env)
    echo "[Launch] Starting $label${app_args:+ (${app_args[*]})}..."
    if [ $safe -eq 1 ]; then
        "$bin" "${app_args[@]}"
    else
        "$bin" "$skip_flag" "${app_args[@]}"
    fi
}

cc() { _launch_via_proxy Claude claude "npm install -g @anthropic-ai/claude-code" --dangerously-skip-permissions "$@"; }
cx() { _launch_via_proxy Codex  codex  "npm install -g @openai/codex"            --dangerously-bypass-approvals-and-sandbox "$@"; }
cc-safe() { cc --safe "$@"; }
cx-safe() { cx --safe "$@"; }

cc-stop() {
    # tunnel-stop does the hardened kill-all-on-both-ports + verify; honour its
    # result so cc-stop never falsely claims success when a port is still held.
    local rc=0
    tunnel-stop || rc=1
    proxy-off
    if [ $rc -eq 0 ]; then
        echo "[OK] All proxy services stopped"
    else
        echo "[Err] Env cleared, but the tunnel did NOT fully stop (see above). Run 'proxy-doctor' to see what's stuck."
        return 1
    fi
}

# ============================================================
# Status check
# ============================================================

proxy-status() {
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

    if [ -n "${HTTPS_PROXY:-}" ]; then
        echo "[ON]  Env HTTPS_PROXY: $HTTPS_PROXY"
    else
        echo "[OFF] Env HTTPS_PROXY: not set"
    fi
    echo "[..]  Server        : $CLAUDE_SSH_HOST  (settings: $CLAUDE_PROXY_CONF)"

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
    if command -v lsof >/dev/null 2>&1; then
        echo "$ok  lsof installed"
    else
        echo "$bad lsof NOT installed - status/teardown can't see ports. Fix: sudo apt install lsof"
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

    # --- end-to-end: can we actually reach the API through the proxy? ---
    if [ -n "$http_pid" ]; then
        local code
        code=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' \
               -x "http://127.0.0.1:$CLAUDE_HTTP_PORT" https://api.anthropic.com/ 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            echo "$ok  api.anthropic.com reachable through the proxy (HTTP $code)"
        else
            echo "$bad Proxy up but can't reach api.anthropic.com (curl code ${code:-none})."
            echo "       Check the VM: run 'webproxy-status' there, confirm tinyproxy is up and allows CONNECT 443."
        fi
    fi
    echo ""
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
        echo "[OK] Already up to date (v$CLAUDE_PROXY_VERSION)"
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

chrome-proxy() {
    local socks="socks5://127.0.0.1:$CLAUDE_SOCKS_PORT"

    # Chrome routes through the SOCKS5 forward, which the SSH tunnel provides.
    # Ensure the tunnel is up (same as 'cc' step 1); bail if it won't start.
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

    local c
    if _is_wsl; then
        # WSL has no Linux Chrome; drive Windows Chrome instead. It reaches the
        # WSL-side SOCKS port via WSL2 localhost forwarding (on by default).
        local win_chrome=""
        for c in \
            "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
            "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"; do
            [ -x "$c" ] && { win_chrome="$c"; break; }
        done
        [ -n "$win_chrome" ] || {
            echo "[Err] Windows Chrome not found under /mnt/c - launch it manually with --proxy-server=$socks"
            return 1
        }
        "$win_chrome" \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="C:\\wsl-proxy-profile" \
            --no-first-run >/dev/null 2>&1 &
        echo "[OK] Windows Chrome launched through $socks (separate profile)"
        return
    fi

    # Native Linux / macOS
    if [ "$(uname)" = "Darwin" ]; then
        [ -d "/Applications/Google Chrome.app" ] || {
            echo "[Err] Google Chrome not found in /Applications"
            return 1
        }
        # A dedicated user-data-dir OUTSIDE the real Chrome folder: the proxied
        # Chrome is fully isolated and can never touch your normal profiles.
        open -n -a "Google Chrome" --args \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="$HOME/.chrome-proxy-profile" \
            --no-first-run
    else
        local bin
        bin=$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)
        [ -n "$bin" ] || { echo "[Err] Chrome/Chromium not found on PATH"; return 1; }
        nohup "$bin" \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="$HOME/.config/google-chrome-vpn" \
            --no-first-run >/dev/null 2>&1 &
    fi
    echo "[OK] Chrome launched through $socks (separate profile)"
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
    echo "  cc-stop         - Turn the proxy OFF (one off-switch for cc AND cx)"
    echo "  proxy-status    - Show what's running + your external IP"
    echo "  proxy-doctor    - Diagnose each part and say exactly what's wrong + how to fix"
    echo ""
    echo "  -- settings & updates --"
    echo "  proxy-config    - Show your settings (edit / set KEY VALUE) - stored in ~/.claude-proxy.conf"
    echo "  proxy-update    - Fetch the latest version of this profile; your settings are kept"
    echo ""
    echo "  -- advanced: manage one piece at a time --"
    echo "  tunnel-start    - Start the SSH tunnel (HTTP forward for Claude + SOCKS5 for Chrome)"
    echo "  tunnel-stop     - Stop the SSH tunnel"
    echo "  proxy-on        - Set proxy env vars + sync Claude settings.json"
    echo "  proxy-off       - Clear proxy env vars + unsync Claude settings.json"
    echo ""
    echo "  chrome-proxy    - Open Chrome via SOCKS5 (auto-starts the tunnel, separate profile)"
    echo "  cc-help         - Show this list again"
    echo ""
}

# One line when a new shell loads this file. Silence it with
# CLAUDE_PROXY_BANNER=0 in ~/.claude-proxy.conf.
if [ "${CLAUDE_PROXY_BANNER:-1}" = "1" ] && [ "${_CLAUDE_PROXY_QUIET:-0}" != "1" ]; then
    echo "claude-proxy v$CLAUDE_PROXY_VERSION ready (server: $CLAUDE_SSH_HOST) - 'cc' launches Claude, 'cc-help' lists all commands"
fi
