# ============================================================
# Claude SSH Tunnel + HTTP proxy (Claude) + SOCKS5 (Chrome)   (source from ~/.zshrc or ~/.bashrc)
# ============================================================
# One SSH connection carries two forwards:
#   -L 8080:127.0.0.1:8888  ->  VM's HTTP proxy (tinyproxy)  ->  used by Claude (HTTPS_PROXY)
#   -D 1080                 ->  SOCKS5 on the VM              ->  used by Chrome / other apps
#
# Claude Code only speaks HTTP proxies, so it uses the -L forward to the VM's
# HTTP proxy (see webproxy-manager: https://github.com/crayonluffy/forge/tree/main/webproxy-manager).
# Chrome is happier on SOCKS5 (full traffic, remote DNS), so it uses the -D forward.
# ============================================================

# ============================================================
# Settings - EDIT THESE
# ============================================================
# If you ran "Step 1" you already have an ~/.ssh/config alias - just point at it.
export CLAUDE_SSH_HOST="jpvpn"          # an ~/.ssh/config alias, OR a raw host/IP
export CLAUDE_SSH_USER=""               # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_KEY=""                # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_PORT=22
export CLAUDE_HTTP_PORT=8080            # local HTTP port -> forwarded to the VM's HTTP proxy (Claude)
export CLAUDE_REMOTE_PROXY_PORT=8888    # tinyproxy port on the VM (webproxy-manager)
export CLAUDE_SOCKS_PORT=1080           # local SOCKS5 port (Chrome / other apps)

# Also write the proxy into Claude's settings.json while the tunnel is up, so
# `claude` launched from ANY shell (not just this one) uses it. Removed again on
# proxy-off / cc-stop, so a down tunnel never leaves Claude pointed at a dead proxy.
# Needs `jq`; set to 0 to disable and rely on shell env vars only.
export CLAUDE_SYNC_SETTINGS=1
export CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

# Append your company intranet ranges/domains, e.g. ...,172.20.0.0/24,*.mycorp.example
export CLAUDE_NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,*.local,*.internal,*.corp"

# ============================================================
# Helpers
# ============================================================

_port_in_use() {
    lsof -ti:"$1" >/dev/null 2>&1
}

_is_wsl() {
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
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
_claude_settings_proxy_on() {
    [ "${CLAUDE_SYNC_SETTINGS:-0}" = "1" ] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        echo "[Info] jq not found - skipping ~/.claude/settings.json sync (shell env vars still set)"
        return 0
    fi
    local url="http://127.0.0.1:$CLAUDE_HTTP_PORT" tmp
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
    cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.bak" 2>/dev/null
    tmp=$(mktemp)
    if jq --arg url "$url" --arg np "$CLAUDE_NO_PROXY" \
        '.env = (.env // {}) | .env.HTTPS_PROXY=$url | .env.HTTP_PROXY=$url | .env.NO_PROXY=$np' \
        "$CLAUDE_SETTINGS" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$CLAUDE_SETTINGS"
        echo "[OK] Proxy written into $CLAUDE_SETTINGS (env block)"
    else
        rm -f "$tmp"
        echo "[Warn] Could not update $CLAUDE_SETTINGS (invalid JSON?) - left it untouched"
    fi
}

_claude_settings_proxy_off() {
    [ "${CLAUDE_SYNC_SETTINGS:-0}" = "1" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    [ -f "$CLAUDE_SETTINGS" ] || return 0
    local tmp
    cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.bak" 2>/dev/null
    tmp=$(mktemp)
    if jq 'if .env then .env |= del(.HTTPS_PROXY, .HTTP_PROXY, .NO_PROXY) else . end' \
        "$CLAUDE_SETTINGS" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$CLAUDE_SETTINGS"
        echo "[OK] Proxy removed from $CLAUDE_SETTINGS"
    else
        rm -f "$tmp"
    fi
}

# ============================================================
# 1. SSH tunnel: -L (HTTP proxy for Claude) + -D (SOCKS5 for Chrome)
# ============================================================

tunnel-start() {
    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[Info] Local port $CLAUDE_HTTP_PORT already in use - tunnel may already be running"
        return
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
    ssh "${args[@]}" 2>/tmp/claude-tunnel.log

    local attempts=0
    while ! _port_in_use "$CLAUDE_HTTP_PORT" && [ $attempts -lt 10 ]; do
        sleep 0.5
        attempts=$((attempts+1))
    done

    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[OK]  SSH tunnel up:"
        echo "       HTTP  127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT   (Claude)"
        echo "       SOCKS 127.0.0.1:$CLAUDE_SOCKS_PORT                                   (Chrome / apps)"
    else
        echo "[Err] SSH tunnel failed to start within 5s (see /tmp/claude-tunnel.log)"
    fi
}

tunnel-stop() {
    # Kill EVERY process listening on either forwarded port - not just the one we
    # think we started. This catches stale tunnels and leftovers from the old
    # SOCKS+bridge setup (where killing npx orphaned the node child on 8080).
    local all_pids survivors=() pid cmd port still p

    all_pids=$(
        { lsof -ti:"$CLAUDE_HTTP_PORT" 2>/dev/null; lsof -ti:"$CLAUDE_SOCKS_PORT" 2>/dev/null; } \
        | sort -u | sed '/^$/d'
    )

    if [ -z "$all_pids" ]; then
        echo "[Info] No tunnel running - ports $CLAUDE_HTTP_PORT / $CLAUDE_SOCKS_PORT are already free"
        return 0
    fi

    for pid in $all_pids; do
        cmd=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
        kill "$pid" 2>/dev/null
        echo "[Kill] PID $pid (${cmd:-unknown})"
    done

    # Verify the ports actually freed; escalate to SIGKILL if a process lingers.
    sleep 0.5
    for port in "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT"; do
        still=$(lsof -ti:"$port" 2>/dev/null)
        if [ -n "$still" ]; then
            for p in $still; do kill -9 "$p" 2>/dev/null; done
            sleep 0.3
            still=$(lsof -ti:"$port" 2>/dev/null)
        fi
        [ -n "$still" ] && survivors+=("$port held by PID(s) $(echo $still | tr '\n' ' ')")
    done

    if [ ${#survivors[@]} -eq 0 ]; then
        echo "[OK] Tunnel stopped - ports $CLAUDE_HTTP_PORT and $CLAUDE_SOCKS_PORT freed"
    else
        echo "[Err] Could not free everything (even with SIGKILL):"
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

    # Step 1: SSH tunnel (HTTP + SOCKS forwards)
    if ! _port_in_use "$CLAUDE_HTTP_PORT"; then
        tunnel-start
        _port_in_use "$CLAUDE_HTTP_PORT" || return 1
    else
        echo "[OK]  SSH tunnel already running"
    fi

    # Step 2: Env vars (+ settings.json sync)
    proxy-on

    # Step 3: Verify the external IP really is the proxy's (VM's), not yours
    if [ $no_verify -eq 0 ]; then
        _verify_proxy_ip
    fi

    echo "[OK]  Proxy ready in this shell - run 'claude' yourself, or 'cc-stop' to tear it down."
}

# ============================================================
# All-in-one: proxy stack + launch Claude
# ============================================================

cc() {
    local safe=0
    local up_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --safe)      safe=1 ;;
            --no-verify) up_args+=(--no-verify) ;;
        esac
        shift
    done

    # Steps 1-3: bring up tunnel + env vars + verify
    proxy-up "${up_args[@]}" || return 1

    # Step 4: Launch Claude
    echo "[Launch] Starting Claude..."
    if [ $safe -eq 1 ]; then
        claude
    else
        claude --dangerously-skip-permissions
    fi
}

cc-safe() { cc --safe; }

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
    echo "=== Proxy Status ==="
    echo ""
    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[ON]  HTTP tunnel   : 127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT (Claude)"
    else
        echo "[OFF] HTTP tunnel   : not running"
    fi

    if _port_in_use "$CLAUDE_SOCKS_PORT"; then
        echo "[ON]  SOCKS tunnel  : 127.0.0.1:$CLAUDE_SOCKS_PORT (Chrome / apps)"
    else
        echo "[OFF] SOCKS tunnel  : not running"
    fi

    if [ -n "$HTTPS_PROXY" ]; then
        echo "[ON]  Env HTTPS_PROXY: $HTTPS_PROXY"
    else
        echo "[OFF] Env HTTPS_PROXY: not set"
    fi

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
    echo "=== Proxy Doctor ==="

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

    # --- tunnel / ports ---
    local http_pids socks_pids http_pid socks_pid
    http_pids=$(lsof -ti:"$CLAUDE_HTTP_PORT" 2>/dev/null)
    socks_pids=$(lsof -ti:"$CLAUDE_SOCKS_PORT" 2>/dev/null)
    http_pid=$(echo "$http_pids" | head -1)
    socks_pid=$(echo "$socks_pids" | head -1)

    if [ -n "$http_pid" ]; then
        echo "$ok  HTTP forward  :$CLAUDE_HTTP_PORT listening (PID $http_pid $(ps -p $http_pid -o comm= 2>/dev/null | tr -d ' '))"
    else
        echo "$bad HTTP forward  :$CLAUDE_HTTP_PORT NOT listening - Claude has no proxy. Fix: tunnel-start (or cc)"
    fi
    if [ -n "$socks_pid" ]; then
        echo "$ok  SOCKS forward :$CLAUDE_SOCKS_PORT listening (PID $socks_pid) - Chrome OK"
    else
        echo "$warn SOCKS forward :$CLAUDE_SOCKS_PORT NOT listening - chrome-proxy won't work. Fix: tunnel-start"
    fi
    # Both ports should belong to the SAME ssh process. Different PIDs => a stale
    # leftover (e.g. an old SOCKS+bridge session) is squatting on one of them.
    if [ -n "$http_pid" ] && [ -n "$socks_pid" ] && [ "$http_pid" != "$socks_pid" ]; then
        echo "$warn Ports held by DIFFERENT PIDs ($http_pid vs $socks_pid) - likely a stale process. Fix: cc-stop, then cc"
    fi
    # More than one PID on a single port is also a leftover.
    if [ "$(echo "$http_pids" | sed '/^$/d' | wc -l)" -gt 1 ]; then
        echo "$warn Port $CLAUDE_HTTP_PORT has MULTIPLE listeners ($(echo $http_pids | tr '\n' ' ')) - stale process. Fix: cc-stop"
    fi

    # --- shell env ---
    if [ -n "$HTTPS_PROXY" ]; then
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
        # This is the "check json has env" the user asked for.
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
            echo "[Err] SSH tunnel could not be started - Chrome not launched. Run 'cc' to diagnose."
            return 1
        }
    else
        echo "[OK]  SSH tunnel already running"
    fi

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
        open -n -a "Google Chrome" --args \
            --proxy-server="$socks" \
            --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
            --user-data-dir="$HOME/Library/Application Support/Google/Chrome/Profile 4" \
            --profile-directory="Default"
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
    echo "=== Claude + SSH Tunnel Quick Commands ==="
    echo "  cc              - Turn the proxy ON and launch Claude (skips permission prompts)"
    echo "  cc-safe         - Same, but keeps Claude's permission prompts"
    echo "  proxy-up        - Turn the proxy ON, but DON'T launch Claude"
    echo "  cc-stop         - Turn the proxy OFF (stop everything, reports what it freed)"
    echo "  proxy-status    - Show what's running + your external IP"
    echo "  proxy-doctor    - Diagnose each part and say exactly what's wrong + how to fix"
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

# Show the available commands when this script is sourced.
# (Comment out the next line if you don't want it on every new shell.)
cc-help
