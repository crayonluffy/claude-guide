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
# ============================================================

CLAUDE_PROXY_VERSION="2.2.1"
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
CLAUDE_CHROME_BIN=""             # Chrome binary/app, only if it isn't in the usual place (macOS: app name or path)

# Where 'proxy-nodes --refresh' gets the catalogue from:
#   ""            -> $CLAUDE_PROXY_REPO_RAW/nodes.json (this guide's repo)
#   "example.com" -> DNS TXT records at _claude-proxy.example.com (your admin manages them in DNS)
CLAUDE_PROXY_DOMAIN=""

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
       CLAUDE_SYNC_SETTINGS CLAUDE_SETTINGS CLAUDE_NO_PROXY CLAUDE_PROXY_CONF \
       CLAUDE_PROXY_NODES CLAUDE_NODE_SOCKS_BASE CLAUDE_CHROME_BIN CLAUDE_PROXY_DOMAIN

# The keys a conf file may carry (used by proxy-config / migration).
_CLAUDE_CONF_KEYS="CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_KEY CLAUDE_SSH_PORT CLAUDE_HTTP_PORT CLAUDE_REMOTE_PROXY_PORT CLAUDE_SOCKS_PORT CLAUDE_NODE_SOCKS_BASE CLAUDE_CHROME_BIN CLAUDE_PROXY_DOMAIN CLAUDE_SYNC_SETTINGS CLAUDE_SYNC_WINDOWS_SETTINGS CLAUDE_PROXY_BANNER"

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
            sl = f("slot"); if (sl == "") sl = i
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

# Download / discover the catalogue into <file>.
_nodes_fetch() {  # <file>
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
    while [ $# -gt 0 ]; do
        case "$1" in
            --refresh|-r|refresh) refresh=1 ;;
            --domain)   shift; _conf_set CLAUDE_PROXY_DOMAIN "${1:-}"; _conf_reload; refresh=1 ;;
            --domain=*) _conf_set CLAUDE_PROXY_DOMAIN "${1#--domain=}"; _conf_reload; refresh=1 ;;
            list) ;;
            *) echo "usage: proxy-nodes [--refresh] [--domain <domain>]   (--domain '' goes back to the guide's catalogue)"; return 1 ;;
        esac
        shift
    done

    if [ $refresh -eq 1 ]; then
        tmp=$(mktemp) || return 1
        if ! _nodes_fetch "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        if ! grep -q '"nodes"' "$tmp" || { command -v jq >/dev/null 2>&1 && ! jq -e '.nodes | length > 0' "$tmp" >/dev/null 2>&1; }; then
            rm -f "$tmp"
            echo "[Err] Downloaded file doesn't look like a node catalogue - nothing changed."
            return 1
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

    if [ ! -f "$CLAUDE_PROXY_NODES" ]; then
        echo ""
        echo "[Info] No node catalogue yet - run 'proxy-nodes --refresh' to download it."
        echo "       Current server: $CLAUDE_SSH_HOST"
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
    if [ -n "$CLAUDE_PROXY_DOMAIN" ] && [ "$source" != "dns:$CLAUDE_PROXY_DOMAIN" ]; then
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
            target="<not provisioned>"
        fi
        printf '  %s %-5s %-8s %-11s %-30s %s\n' "$mark" "$name" "$alias" "$region" "$target" "$where"
    done <<< "$(_nodes_tsv | sort -t'|' -k8,8 -k1,1n)"
    if [ $found_active -eq 0 ]; then
        echo "  * ($CLAUDE_SSH_HOST)  - current server, not in the catalogue"
    fi
    echo ""
    echo "  proxy-node <name>                  make it the node cc / cx use (restarts the tunnel if it's up)"
    echo "  chrome-proxy <name>                open a Chrome window through that node (own tunnel; several nodes can be open)"
    echo "  chrome-proxy <name> --profile <p>  another Chrome profile through the same node ('chrome-profiles' lists them)"
    echo "  proxy-nodes --refresh              reload the catalogue and create any missing ssh aliases"
    echo "  proxy-nodes --domain <domain>      take the nodes from your company's DNS from now on"
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
    local no_verify=0 node=""
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
            --node)      up_args+=(--node "${2:-}"); shift ;;
            --node=*)    up_args+=("$1") ;;
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
    _node_tunnels_stop      # per-node Chrome tunnels (chrome-proxy <node>) go too
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

    local c pdir
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
    echo "  -- nodes (jp / sg / us ...) --"
    echo "  proxy-nodes     - List the nodes (--refresh: download the latest catalogue + create ssh aliases)"
    echo "  proxy-node sg   - Make 'sg' the node cc / cx use (also: cc --node sg, cx --node sg)"
    echo "  chrome-proxy sg - Chrome through 'sg' on its own tunnel + profile (jp and sg can be open together)"
    echo "  chrome-proxy jp --profile work - another Chrome profile through jp ('chrome-profiles' lists them)"
    echo "  proxy-nodes --domain example.com - take the node list from your company's DNS"
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
    echo "  chrome-proxy    - Open Chrome via SOCKS5 through the active node (auto-starts the tunnel, separate profile)"
    echo "                    chrome-proxy [node] [--profile name] [url]  - e.g. chrome-proxy us -p shop https://example.com"
    echo "  cc-help         - Show this list again"
    echo ""
}

# One line when a new shell loads this file. Silence it with
# CLAUDE_PROXY_BANNER=0 in ~/.claude-proxy.conf.
if [ "${CLAUDE_PROXY_BANNER:-1}" = "1" ] && [ "${_CLAUDE_PROXY_QUIET:-0}" != "1" ]; then
    _bn=$(_node_active_name)
    echo "claude-proxy v$CLAUDE_PROXY_VERSION ready (node: ${_bn:+$_bn / }$CLAUDE_SSH_HOST) - 'cc' launches Claude, 'cc-help' lists all commands"
    unset _bn
fi
