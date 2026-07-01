# ============================================================
# Claude SSH Tunnel (local forward) + HTTP Proxy   (source from ~/.zshrc or ~/.bashrc)
# ============================================================
# Traffic flow:
#   claude --HTTPS_PROXY--> 127.0.0.1:8080 --ssh -L--> VM tinyproxy:8888 --> Anthropic API
#
# The VM runs an HTTP proxy bound to loopback (see the webproxy-manager tool:
# https://github.com/crayonluffy/forge/tree/main/webproxy-manager). This script
# just forwards a local port to it with `ssh -L`. No SOCKS, no
# http-proxy-to-socks bridge, no Node dependency for the proxy.
# ============================================================

# ============================================================
# Settings - EDIT THESE
# ============================================================
# If you ran "Step 1" you already have an ~/.ssh/config alias - just point at it.
export CLAUDE_SSH_HOST="jpvpn"          # an ~/.ssh/config alias, OR a raw host/IP
export CLAUDE_SSH_USER=""               # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_KEY=""                # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_PORT=22
export CLAUDE_HTTP_PORT=8080            # local port -> forwarded to the VM's proxy
export CLAUDE_REMOTE_PROXY_PORT=8888    # tinyproxy port on the VM (webproxy-manager)

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

# ============================================================
# 1. SSH tunnel (local forward to the VM's HTTP proxy)
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
        echo "[OK]  SSH tunnel up: 127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT"
    else
        echo "[Err] SSH tunnel failed to start within 5s (see /tmp/claude-tunnel.log)"
    fi
}

tunnel-stop() {
    local pid
    pid=$(lsof -ti:"$CLAUDE_HTTP_PORT")
    if [ -n "$pid" ]; then
        kill $pid
        echo "[OK] SSH tunnel stopped"
    else
        echo "[Info] No SSH tunnel running"
    fi
}

# Back-compat stubs: the separate HTTP bridge is gone - the VM runs the proxy now,
# and 'tunnel-start' forwards straight to it. Kept so old muscle memory / scripts
# don't error out.
bridge-start() { echo "[Info] No bridge needed anymore - the VM runs the HTTP proxy; 'tunnel-start' forwards straight to it."; }
bridge-stop()  { echo "[Info] No bridge to stop - the VM runs the HTTP proxy now. Use 'tunnel-stop'."; }

# ============================================================
# 2. Proxy env vars
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

    # Step 1: SSH tunnel (local forward)
    if ! _port_in_use "$CLAUDE_HTTP_PORT"; then
        tunnel-start
        _port_in_use "$CLAUDE_HTTP_PORT" || return 1
    else
        echo "[OK]  SSH tunnel already running"
    fi

    # Step 2: Env vars
    proxy-on

    # Step 3: Verify
    if [ $no_verify -eq 0 ]; then
        echo "[Check] Verifying IP via proxy..."
        local ip
        ip=$(curl -s --max-time 5 ipinfo.io)
        [ -n "$ip" ] && echo "$ip" | head -5
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
    if _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[ON]  SSH tunnel    : 127.0.0.1:$CLAUDE_HTTP_PORT -> VM tinyproxy:$CLAUDE_REMOTE_PROXY_PORT"
    else
        echo "[OFF] SSH tunnel    : not running"
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
# Launch Chrome through the proxy (separate, isolated profile)
# ============================================================

chrome-proxy() {
    local url="http://127.0.0.1:$CLAUDE_HTTP_PORT"

    # Chrome routes through the HTTP proxy, which the SSH tunnel exposes. Ensure
    # the tunnel is up (same as 'cc' step 1); bail if it won't start.
    if ! _port_in_use "$CLAUDE_HTTP_PORT"; then
        echo "[Info] SSH tunnel (port $CLAUDE_HTTP_PORT) not running - starting it..."
        tunnel-start
        _port_in_use "$CLAUDE_HTTP_PORT" || {
            echo "[Err] SSH tunnel could not be started - Chrome not launched. Run 'cc' to diagnose."
            return 1
        }
    else
        echo "[OK]  SSH tunnel already running"
    fi

    if _is_wsl; then
        # WSL has no Linux Chrome; drive Windows Chrome instead. It reaches the
        # WSL-side forwarded port via WSL2 localhost forwarding (on by default).
        local win_chrome=""
        for c in \
            "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
            "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"; do
            [ -x "$c" ] && { win_chrome="$c"; break; }
        done
        [ -n "$win_chrome" ] || {
            echo "[Err] Windows Chrome not found under /mnt/c - launch it manually with --proxy-server=$url"
            return 1
        }
        "$win_chrome" \
            --proxy-server="$url" \
            --user-data-dir="C:\\wsl-proxy-profile" \
            --no-first-run >/dev/null 2>&1 &
        echo "[OK] Windows Chrome launched through $url (separate profile)"
        return
    fi

    # Native Linux / macOS
    if [ "$(uname)" = "Darwin" ]; then
        [ -d "/Applications/Google Chrome.app" ] || {
            echo "[Err] Google Chrome not found in /Applications"
            return 1
        }
        open -n -a "Google Chrome" --args \
            --proxy-server="$url" \
            --user-data-dir="$HOME/Library/Application Support/Google/Chrome/Profile 4" \
            --profile-directory="Default"
    else
        local bin
        bin=$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)
        [ -n "$bin" ] || { echo "[Err] Chrome/Chromium not found on PATH"; return 1; }
        nohup "$bin" \
            --proxy-server="$url" \
            --user-data-dir="$HOME/.config/google-chrome-vpn" \
            --no-first-run >/dev/null 2>&1 &
    fi
    echo "[OK] Chrome launched through $url (separate profile)"
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
    echo "  cc-stop         - Turn the proxy OFF (stop everything)"
    echo "  proxy-status    - Show what's running + your external IP"
    echo ""
    echo "  -- advanced: manage one piece at a time --"
    echo "  tunnel-start    - Start the SSH tunnel (local forward to the VM proxy)"
    echo "  tunnel-stop     - Stop the SSH tunnel"
    echo "  proxy-on        - Set the proxy env vars only"
    echo "  proxy-off       - Clear the proxy env vars only"
    echo ""
    echo "  chrome-proxy    - Open Chrome via the proxy (auto-starts the tunnel, separate profile)"
    echo "  cc-help         - Show this list again"
    echo ""
}

# Show the available commands when this script is sourced.
# (Comment out the next line if you don't want it on every new shell.)
cc-help
