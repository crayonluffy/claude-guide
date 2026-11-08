# macOS adapters. Included in the generated standalone profile at build time.
_macos_port_bound() {
    command -v netstat >/dev/null 2>&1 || return 2
    # Only loopback or any-address listeners clash with the tunnel's 127.0.0.1 forward.
    netstat -an -p tcp 2>/dev/null | awk -v port="$1" '
        function lb(x) { sub(/\.[0-9]+$/, "", x); sub(/%.*/, "", x); return x ~ /^(127\.0\.0\.1|\*|::1|::|::ffff:127\.0\.0\.1)$/ }
        $6 == "LISTEN" && $4 ~ ("[.:]" port "$") && lb($4) { found=1 } END { exit !found }'
}
_macos_uptime() {
    osascript -l JavaScript -e 'ObjC.import("Foundation"); Math.floor($.NSProcessInfo.processInfo.systemUptime);' 2>/dev/null
}
_macos_process_start() {
    # ps pads both ends; saved identities must compare after read strips padding.
    LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//'
}
_macos_desktop_backend() {
    if command -v osascript >/dev/null 2>&1; then echo macos; else echo unavailable; fi
}
_macos_desktop_send() {
    [ "$1" = macos ] || return 1
    _recovery_desktop_exec osascript -e 'on run argv
        display notification (item 2 of argv) with title (item 1 of argv)
    end run' -- "$3" "$4"
}
_macos_is_wsl() { return 1; }
_macos_ssh_options() { printf '    UseKeychain yes\n'; }
_macos_chrome_base() { echo "$HOME/.chrome-proxy-profile"; }
_macos_install_hint() { echo "brew install $1"; }
_macos_chrome_launch() {
    local name="$1" socks="$2" profile="$3" label="$4" pdir dock_tip='' procs bundle
    local app="${CLAUDE_CHROME_BIN:-Google Chrome}"
    shift 4
    [ -n "$CLAUDE_CHROME_BIN" ] || [ -d '/Applications/Google Chrome.app' ] || {
        echo "[Err] Google Chrome not found in /Applications - set it: proxy-config set CHROME_BIN 'Chromium' (app name or path)"
        return 1
    }
    pdir=$(_chrome_profile_dir "$(_chrome_base_dir)" "$name")
    bundle="${app##*/}"; bundle="${bundle%.app}.app/Contents/MacOS/"
    procs=$(ps -axo command= 2>/dev/null)
    printf '%s\n' "$procs" | grep -F -- "$bundle" | grep -qv -- '--user-data-dir=' \
        || dock_tip="open -n -a \"$app\""
    _chrome_running_note "$pdir"
    # 'open --env' (macOS 12+) hands Chrome its time zone; older macOS skips it.
    local envs=()
    if [ -n "${_CLAUDE_CHROME_LAUNCH_TZ:-}" ]; then
        if open --help 2>&1 | grep -q -- '--env'; then envs=(--env "TZ=$_CLAUDE_CHROME_LAUNCH_TZ")
        else echo "[Info] This macOS 'open' can't pass a time zone - Chrome uses the Mac's."; fi
    fi
    open -n ${envs[@]+"${envs[@]}"} -a "$app" --args --proxy-server="$socks" \
        --host-resolver-rules="$(_chrome_direct_rules resolver)" \
        --user-data-dir="$pdir" --no-first-run "$@" || return 1
    [ -z "$profile" ] || label="$label, profile '$profile'"
    echo "[OK] Chrome launched through $label - $socks, data dir $pdir"
    [ -z "$dock_tip" ] || echo "[Tip] To open your normal Chrome next to it: $dock_tip"
    return 0
}

_macos_install_node() {
    local ver tmp
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
}
