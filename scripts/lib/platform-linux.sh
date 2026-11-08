# Linux and WSL adapters. Included in the generated profile at build time.
_linux_port_bound() { return 2; } # common helper uses ss, then lsof
_linux_uptime() {
    local up
    read -r up _ < /proc/uptime
    echo "${up%%.*}"
}
_linux_process_start() {
    if [ -r "/proc/$1/stat" ]; then
        sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
    else
        LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//'
    fi
}
_linux_desktop_backend() {
    if command -v notify-send >/dev/null 2>&1 && { [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; }; then echo linux
    else echo unavailable; fi
}
_linux_desktop_send() {
    local icon=network-error
    [ "$1" = linux ] || return 1
    case "$2" in restored|test) icon=network-transmit-receive;; esac
    _recovery_desktop_exec notify-send --app-name='Claude Proxy' --urgency=normal \
        --expire-time=10000 --icon="$icon" -- "$3" "$4"
}
_linux_is_wsl() { grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; }
_linux_ssh_options() { :; }
_linux_chrome_base() {
    if _is_wsl; then echo /mnt/c/wsl-proxy-profile
    else echo "$HOME/.config/google-chrome-vpn"; fi
}
_linux_install_hint() {
    if command -v dnf >/dev/null 2>&1; then echo "sudo dnf install $1"
    else echo "sudo apt install $1"; fi
}
_linux_chrome_launch() {
    local name="$1" socks="$2" profile="$3" label="$4" pdir bin c
    shift 4
    pdir=$(_chrome_profile_dir "$(_chrome_base_dir)" "$name")
    if _is_wsl; then
        bin=''
        for c in "$CLAUDE_CHROME_BIN" \
            '/mnt/c/Program Files/Google/Chrome/Application/chrome.exe' \
            '/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe'; do
            [ -n "$c" ] && [ -x "$c" ] && { bin="$c"; break; }
        done
        [ -n "$bin" ] || { echo "[Err] Windows Chrome not found - set CHROME_BIN with proxy-config edit."; return 1; }
        _chrome_running_note "$pdir"
        # Windows Chrome takes its time zone from Windows, not from TZ.
        [ -z "${_CLAUDE_CHROME_LAUNCH_TZ:-}" ] || echo "[Info] Windows Chrome uses the Windows time zone; to match the proxy, set Windows to ${_CLAUDE_CHROME_LAUNCH_TZ}."
        pdir="C:\\${pdir#/mnt/c/}"
        "$bin" --proxy-server="$socks" \
            --host-resolver-rules="$(_chrome_direct_rules resolver)" \
            --user-data-dir="$pdir" --no-first-run "$@" >/dev/null 2>&1 &
    else
        bin="$CLAUDE_CHROME_BIN"
        [ -n "$bin" ] || bin=$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || command -v chromium-browser)
        [ -n "$bin" ] || { echo '[Err] Chrome/Chromium not found - set CHROME_BIN with proxy-config edit.'; return 1; }
        _chrome_running_note "$pdir"
        nohup env ${_CLAUDE_CHROME_LAUNCH_TZ:+"TZ=$_CLAUDE_CHROME_LAUNCH_TZ"} "$bin" --proxy-server="$socks" \
            --host-resolver-rules="$(_chrome_direct_rules resolver)" \
            --user-data-dir="$pdir" --no-first-run "$@" >/dev/null 2>&1 &
    fi
    [ -z "$profile" ] || label="$label, profile '$profile'"
    echo "[OK] Chrome launched through $label - $socks, data dir $pdir"
    return 0
}

_linux_install_node() {
    local ver tmp
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
