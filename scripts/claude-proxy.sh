# ============================================================
# Claude SSH Tunnel + HTTP Proxy   (source from ~/.zshrc or ~/.bashrc)
# ============================================================

# ============================================================
# Settings - EDIT THESE
# ============================================================
# If you ran "Step 1" you already have an ~/.ssh/config alias - just point at it.
export CLAUDE_SSH_HOST="jpvpn"   # an ~/.ssh/config alias, OR a raw host/IP
export CLAUDE_SSH_USER=""        # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_KEY=""         # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_PORT=22
export CLAUDE_SOCKS_PORT=1080
export CLAUDE_HTTP_PORT=8080

# Append your company intranet ranges/domains, e.g. ...,172.20.0.0/24,*.mycorp.example
export CLAUDE_NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,*.local,*.internal,*.corp"

# ============================================================
# Helper: is a port in use?
# ============================================================

_port_in_use() {
    lsof -ti:"$1" >/dev/null 2>&1
}

# ============================================================
# 1. SSH tunnel
# ============================================================

tunnel-start() {
    if _port_in_use "$CLAUDE_SOCKS_PORT"; then
        echo "[Info] SOCKS port $CLAUDE_SOCKS_PORT already in use - tunnel may already be running"
        return
    fi

    echo "[SSH] Starting tunnel to $CLAUDE_SSH_HOST..."
    local args=(-D "$CLAUDE_SOCKS_PORT" -N -C -f
        -o ServerAliveInterval=60
        -o ServerAliveCountMax=3
        -o ExitOnForwardFailure=yes)
    # Explicit key/port/user are optional - leave CLAUDE_SSH_KEY/USER blank to use an ~/.ssh/config alias
    [ -n "$CLAUDE_SSH_KEY" ] && args+=(-i "$CLAUDE_SSH_KEY" -p "$CLAUDE_SSH_PORT")
    if [ -n "$CLAUDE_SSH_USER" ]; then args+=("$CLAUDE_SSH_USER@$CLAUDE_SSH_HOST"); else args+=("$CLAUDE_SSH_HOST"); fi
    ssh "${args[@]}"

    local attempts=0
    while ! _port_in_use "$CLAUDE_SOCKS_PORT" && [ $attempts -lt 10 ]; do
        sleep 0.5
        attempts=$((attempts+1))
    done

    if _port_in_use "$CLAUDE_SOCKS_PORT"; then
        echo "[OK]  SSH tunnel up on 127.0.0.1:$CLAUDE_SOCKS_PORT"
    else
        echo "[Err] SSH tunnel failed to start within 5s"
    fi
}

tunnel-stop() {
    local pid
    pid=$(lsof -ti:"$CLAUDE_SOCKS_PORT")
    if [ -n "$pid" ]; then
        kill $pid
        echo "[OK] SSH tunnel stopped"
    else
        echo "[Info] No SSH tunnel running"
    fi
}

# ============================================================
# 2. HTTP-to-SOCKS bridge
# ============================================================

bridge-start() {
    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[Info] HTTP port $CLAUDE_HTTP_PORT already in use - bridge may already be running"
        return
    fi
    if ! _port_in_use "$CLAUDE_SOCKS_PORT"; then
        echo "[Err] SOCKS port $CLAUDE_SOCKS_PORT not active - run 'tunnel-start' first"
        return
    fi

    echo "[HTTP] Starting bridge on 127.0.0.1:$CLAUDE_HTTP_PORT..."
    nohup npx http-proxy-to-socks \
        -p "$CLAUDE_HTTP_PORT" \
        -s "127.0.0.1:$CLAUDE_SOCKS_PORT" \
        >/tmp/claude-bridge.log 2>&1 &

    local attempts=0
    while ! _port_in_use "$CLAUDE_HTTP_PORT" && [ $attempts -lt 10 ]; do
        sleep 0.5
        attempts=$((attempts+1))
    done

    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[OK]  HTTP bridge up on 127.0.0.1:$CLAUDE_HTTP_PORT"
    else
        echo "[Err] HTTP bridge failed to start (check /tmp/claude-bridge.log)"
    fi
}

bridge-stop() {
    local pid
    pid=$(lsof -ti:"$CLAUDE_HTTP_PORT")
    if [ -n "$pid" ]; then
        kill $pid
        echo "[OK] HTTP bridge stopped"
    else
        echo "[Info] No HTTP bridge running"
    fi
}

# ============================================================
# 3. Proxy env vars
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
}

proxy-off() {
    unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY
    echo "[OK] Env vars cleared"
}

# ============================================================
# All-in-one: tunnel + bridge + env vars + launch Claude
# ============================================================

cc() {
    local safe=0
    local no_verify=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --safe)      safe=1 ;;
            --no-verify) no_verify=1 ;;
        esac
        shift
    done

    # Step 1: SSH tunnel
    if ! _port_in_use "$CLAUDE_SOCKS_PORT"; then
        tunnel-start
        _port_in_use "$CLAUDE_SOCKS_PORT" || return 1
    else
        echo "[OK]  SSH tunnel already running"
    fi

    # Step 2: HTTP bridge
    if ! _port_in_use "$CLAUDE_HTTP_PORT"; then
        bridge-start
        _port_in_use "$CLAUDE_HTTP_PORT" || return 1
    else
        echo "[OK]  HTTP bridge already running"
    fi

    # Step 3: Env vars
    proxy-on

    # Step 4: Verify
    if [ $no_verify -eq 0 ]; then
        echo "[Check] Verifying IP via proxy..."
        local ip
        ip=$(curl -s --max-time 5 ipinfo.io)
        [ -n "$ip" ] && echo "$ip" | head -5
    fi

    # Step 5: Launch Claude
    echo "[Launch] Starting Claude..."
    if [ $safe -eq 1 ]; then
        claude
    else
        claude --dangerously-skip-permissions
    fi
}

cc-safe() { cc --safe; }

cc-stop() {
    bridge-stop
    tunnel-stop
    proxy-off
    echo "[OK] All proxy services stopped"
}

# ============================================================
# Status check
# ============================================================

proxy-status() {
    echo ""
    echo "=== Proxy Status ==="
    echo ""
    if _port_in_use "$CLAUDE_SOCKS_PORT"; then
        echo "[ON]  SSH tunnel    : 127.0.0.1:$CLAUDE_SOCKS_PORT (SOCKS5)"
    else
        echo "[OFF] SSH tunnel    : not running"
    fi

    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[ON]  HTTP bridge   : 127.0.0.1:$CLAUDE_HTTP_PORT (HTTP)"
    else
        echo "[OFF] HTTP bridge   : not running"
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
