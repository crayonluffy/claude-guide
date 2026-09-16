#!/usr/bin/env bash
# ============================================================
# Interactive setup wizard - Claude SSH tunnel proxy (macOS / Linux)
# ============================================================
# Run with:
#   bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
# The node list (jp / jp2 / sg ...) is then fetched privately from your VM over SSH.
# Only if your company publishes its nodes in PUBLIC DNS instead, add its domain:
#   bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh) --domain example.com
#
# First run: prompts for your VM details, installs and locks your SSH key,
# writes an ~/.ssh/config alias, installs the cc/cx profile, and tests the
# connection.
#
# Later runs: finds your existing settings (~/.claude-proxy.conf, or the
# Settings block of an older ~/.claude-proxy.sh) and offers to just update the
# profile - nothing to type again. Add --update to skip that question.
#
# Prefer the paste-blocks in the guide if you'd rather not run a downloaded script.
# ============================================================

set -u
REPO_RAW="${CLAUDE_PROXY_REPO_RAW:-https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts}"
PROFILE_DEST="$HOME/.claude-proxy.sh"
CONF="$HOME/.claude-proxy.conf"

UPDATE_ONLY=0
DOMAIN_ARG="${CLAUDE_PROXY_DOMAIN:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --update|-u) UPDATE_ONLY=1 ;;
        --domain)    shift; DOMAIN_ARG="${1:-}" ;;
        --domain=*)  DOMAIN_ARG="${1#--domain=}" ;;
        -h|--help)
            echo "usage: setup.sh [--update] [--domain <domain>]"
            echo "  --update            keep the existing settings and only refresh ~/.claude-proxy.sh"
            echo "  --domain <domain>   take the proxy nodes from that domain's DNS (TXT _claude-proxy.<domain>)"
            exit 0 ;;
    esac
    shift
done

# All prompts read from /dev/tty (the keyboard) rather than stdin, so the wizard
# still works when piped - e.g. curl ... | bash, where stdin is the script text.
prompt_required() {  # prompt_required <text> <varname>
    local text="$1" __var="$2" reply=""
    while [ -z "$reply" ]; do
        printf '%s: ' "$text" > /dev/tty
        if ! IFS= read -r reply < /dev/tty; then
            echo "" > /dev/tty
            echo "[Err] No more input (keyboard closed) - setup aborted." > /dev/tty
            exit 1
        fi
        [ -z "$reply" ] && echo "  (required - please enter a value)" > /dev/tty
    done
    printf -v "$__var" '%s' "$reply"
}

prompt_default() {  # prompt_default <text> <varname> <default>
    local text="$1" __var="$2" default="$3" reply=""
    printf '%s [%s]: ' "$text" "$default" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    [ -z "$reply" ] && reply="$default"
    printf -v "$__var" '%s' "$reply"
}

# prompt_default, but falls back to prompt_required when there is no default.
prompt_smart() {  # prompt_smart <text> <varname> <default-or-empty>
    if [ -n "$3" ]; then prompt_default "$1" "$2" "$3"; else prompt_required "$1" "$2"; fi
}

confirm() {  # confirm <text> <Y|N default> ; returns 0 for yes
    local text="$1" def="${2:-Y}" reply="" hint
    if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf '%s %s: ' "$text" "$hint" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    [ -z "$reply" ] && reply="$def"
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- settings file helpers ----------------------------------------------------
# Value of KEY in ~/.claude-proxy.conf (sourced in a subshell, so quoting/comments
# are handled exactly like the profile handles them). Empty if unset.
conf_get() {
    [ -f "$CONF" ] || return 0
    ( . "$CONF" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" )
}

# Value of an `export KEY=...` line in an OLD-style profile (settings inside the script).
old_profile_get() {
    [ -f "$PROFILE_DEST" ] || return 0
    sed -n "s/^export $1=\"\{0,1\}\([^\"# ]*\).*/\1/p" "$PROFILE_DEST" | head -1
}

# Write KEY=VALUE into the conf (replace or append). Same format the profile's
# 'proxy-config set' writes, so the two never fight.
conf_set() {
    local key="$1" val="$2" tmp esc
    if [ ! -f "$CONF" ]; then
        {
            echo "# ~/.claude-proxy.conf - YOUR settings for claude-proxy.sh"
            echo "# 'proxy-update' replaces the script but never touches this file."
            echo "# Lines you leave out keep the script's built-in default."
        } > "$CONF"
    fi
    if grep -q "^${key}=" "$CONF"; then
        esc=$(printf '%s' "$val" | sed 's/[\/&|]/\\&/g')
        tmp=$(mktemp)
        sed "s|^${key}=.*|${key}=\"${esc}\"|" "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CONF"
    fi
}

alias_in_ssh_config() {
    grep -qiE "^Host[[:space:]]+$1([[:space:]]|$)" "$HOME/.ssh/config" 2>/dev/null
}

is_wsl() { grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; }

echo ""
echo "=== Claude proxy setup wizard (macOS / Linux) ==="
echo ""

# --- 0. Client dependencies ------------------------------------------------
# jq   - keeps the proxy in sync in ~/.claude/settings.json (settings.json sync)
# lsof - the cc profile uses it to detect / tear down the tunnel ports
ensure_deps() {
    local missing=()
    command -v jq   >/dev/null 2>&1 || missing+=(jq)
    command -v lsof >/dev/null 2>&1 || missing+=(lsof)
    if [ ${#missing[@]} -eq 0 ]; then
        echo "[OK] Dependencies present: jq, lsof"
        return
    fi

    echo "[Deps] Installing: ${missing[*]}"
    if [ "$(uname)" = "Darwin" ]; then
        if command -v brew >/dev/null 2>&1; then
            brew install "${missing[@]}"
        else
            echo "[Warn] Homebrew not found - install manually: brew install ${missing[*]}"
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${missing[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm "${missing[@]}"
    else
        echo "[Warn] No known package manager - install these manually: ${missing[*]}"
    fi

    # Re-check; jq is only a soft dep (sync is skipped without it), so warn, don't abort.
    command -v jq   >/dev/null 2>&1 || echo "[Warn] jq still missing - settings.json sync will be skipped (shell env vars still work)."
    command -v lsof >/dev/null 2>&1 || echo "[Warn] lsof still missing - 'cc' can't manage the tunnel ports until it's installed."
}
ensure_deps

# --- 0b. Fetch the profile now: the node lookup below reuses its functions ---
tmp_profile=$(mktemp)
PROFILE_OK=0
if curl -fsSL "$REPO_RAW/claude-proxy.sh" -o "$tmp_profile" && bash -n "$tmp_profile" 2>/dev/null \
   && grep -q '^CLAUDE_PROXY_VERSION=' "$tmp_profile"; then
    PROFILE_OK=1
fi

# Nodes a company publishes in DNS (TXT _claude-proxy.<domain>), as the profile's
# catalogue lines "slot|name|alias|host|user|ssh_port|proxy_port|region|...".
domain_nodes() {  # <domain>
    [ "$PROFILE_OK" = 1 ] || return 1
    (
        set +u
        _CLAUDE_PROXY_QUIET=1; CLAUDE_PROXY_CONF=/dev/null
        . "$tmp_profile" >/dev/null 2>&1
        CLAUDE_PROXY_NODES=$(mktemp)
        _nodes_json_from_dns "$1" > "$CLAUDE_PROXY_NODES" 2>/dev/null && _nodes_tsv
        rc=$?
        rm -f "$CLAUDE_PROXY_NODES"
        exit $rc
    )
}

# Check the public-DNS domain (--domain, or the one saved before - never asked:
# the default is the private list from your VM). With full=1 the server
# questions are pre-filled from the node the user picks.  use_domain <full:0|1>
DOMAIN=""
use_domain() {
    local full="$1" nodes pick line
    DOMAIN="${DOMAIN_ARG:-$D_DOMAIN}"
    [ -n "$DOMAIN" ] || return 0
    if ! nodes=$(domain_nodes "$DOMAIN") || [ -z "$nodes" ]; then
        echo "[Warn] No proxy nodes found at _claude-proxy.$DOMAIN (DNS TXT)."
        if ! confirm "Keep '$DOMAIN' anyway (e.g. the records aren't published yet)?" N; then DOMAIN=""; fi
        return 0
    fi
    echo "[OK] $DOMAIN publishes these nodes:"
    printf '%s\n' "$nodes" | awk -F'|' '{ printf "       %-5s %-9s %-12s %s\n", $2, $3, $8, $4 }'
    [ "$full" = 1 ] || return 0
    # Default pick: the node behind the alias you already have, else the first one.
    pick=$(printf '%s\n' "$nodes" | awk -F'|' -v a="$D_ALIAS" '$3 == a { print $2; exit }')
    [ -n "$pick" ] || pick=$(printf '%s\n' "$nodes" | head -1 | cut -d'|' -f2)
    while :; do
        prompt_default "Your main node (the one cc / cx use)" pick "$pick"
        line=$(printf '%s\n' "$nodes" | awk -F'|' -v n="$pick" '$2 == n || $3 == n { print; exit }')
        [ -n "$line" ] && break
        echo "  (not in the list above)"
    done
    IFS='|' read -r _ _ D_ALIAS D_IP _ D_SSH_PORT D_PROXY_PORT _ <<< "$line"
}

# --- 1. Existing install? Pre-fill everything from it -----------------------
# Sources, in order of preference: ~/.claude-proxy.conf, the Settings block of
# an old-style ~/.claude-proxy.sh, and the ~/.ssh/config alias itself.
D_ALIAS="jpvpn"; D_SSH_PORT="22"; D_PROXY_PORT="8888"; D_IP=""; D_USER=""; D_KEY=""; D_DOMAIN=""
FOUND=""
if [ -f "$CONF" ]; then
    FOUND="$CONF"
    D_DOMAIN=$(conf_get CLAUDE_PROXY_DOMAIN)
    v=$(conf_get CLAUDE_SSH_HOST);          [ -n "$v" ] && D_ALIAS="$v"
    v=$(conf_get CLAUDE_SSH_PORT);          [ -n "$v" ] && D_SSH_PORT="$v"
    v=$(conf_get CLAUDE_REMOTE_PROXY_PORT); [ -n "$v" ] && D_PROXY_PORT="$v"
elif [ -f "$PROFILE_DEST" ] && grep -q '^export CLAUDE_SSH_HOST=' "$PROFILE_DEST"; then
    FOUND="$PROFILE_DEST (settings inside the old profile)"
    v=$(old_profile_get CLAUDE_SSH_HOST);          [ -n "$v" ] && D_ALIAS="$v"
    v=$(old_profile_get CLAUDE_SSH_PORT);          [ -n "$v" ] && D_SSH_PORT="$v"
    v=$(old_profile_get CLAUDE_REMOTE_PROXY_PORT); [ -n "$v" ] && D_PROXY_PORT="$v"
fi
if alias_in_ssh_config "$D_ALIAS" && command -v ssh >/dev/null 2>&1; then
    # ssh -G resolves the alias exactly as ssh itself would.
    D_IP=$(ssh -G "$D_ALIAS" 2>/dev/null   | awk '$1=="hostname"{print $2; exit}')
    D_USER=$(ssh -G "$D_ALIAS" 2>/dev/null | awk '$1=="user"{print $2; exit}')
    D_KEY=$(ssh -G "$D_ALIAS" 2>/dev/null  | awk '$1=="identityfile"{print $2; exit}')
    p=$(ssh -G "$D_ALIAS" 2>/dev/null      | awk '$1=="port"{print $2; exit}'); [ -n "$p" ] && D_SSH_PORT="$p"
fi

QUICK=0
if [ -n "$FOUND" ]; then
    echo ""
    echo "[Found] Existing setup: $FOUND"
    echo "        server alias '$D_ALIAS' -> ${D_USER:-?}@${D_IP:-?} (ssh port $D_SSH_PORT), VM proxy port $D_PROXY_PORT"
    [ -n "$D_DOMAIN" ] && echo "        nodes from the DNS of: $D_DOMAIN"
    if [ $UPDATE_ONLY -eq 1 ]; then
        QUICK=1
    elif confirm "Keep these settings and only update the cc/cx profile?" Y; then
        QUICK=1
    fi
elif [ $UPDATE_ONLY -eq 1 ]; then
    echo "[Info] --update given but no existing setup found - running the full wizard."
fi

if [ $QUICK -eq 0 ]; then
    # --- 2. Collect VM details (defaults = whatever we found) -----------------
    use_domain 1
    echo ""
    prompt_smart   "Server IP or hostname"                     SERVER_IP  "$D_IP"
    prompt_smart   "SSH username"                              SSH_USER   "$D_USER"
    prompt_default "SSH alias (the shortcut you'll type)"      ALIAS      "$D_ALIAS"
    prompt_default "SSH port"                                  SSH_PORT   "$D_SSH_PORT"
    prompt_default "VM proxy port (tinyproxy on the VM)"       PROXY_PORT "$D_PROXY_PORT"

    # --- 3. Find / choose the private key ------------------------------------
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

    # Newest private key in ~/Downloads - and, under WSL, in the WINDOWS user's
    # Downloads too (that's where a browser puts it). It gets copied into the
    # Linux ~/.ssh below, which ssh requires anyway (files on /mnt/c are 0777).
    found=""
    key_dirs=("$HOME/Downloads")
    if is_wsl; then
        for d in /mnt/c/Users/*/Downloads; do
            case "$d" in */Public/*|*/Default/*|*/"Default User"/*|*/"All Users"/*) continue ;; esac
            [ -d "$d" ] && key_dirs+=("$d")
        done
    fi
    for d in "${key_dirs[@]}"; do
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            case "$f" in *.pub) continue ;; esac
            [ "$(wc -c < "$f")" -lt 100000 ] || continue
            if head -n1 "$f" 2>/dev/null | grep -q "BEGIN .*PRIVATE KEY"; then
                if [ -z "$found" ] || [ "$f" -nt "$found" ]; then found="$f"; fi
            fi
        done
    done

    KEY=""
    if [ -n "$found" ]; then
        echo ""
        echo "[Found] Newest private key in Downloads: $found"
        if confirm "Use this key?" Y; then KEY="$found"; fi
    fi
    if [ -z "$KEY" ] && [ -n "$D_KEY" ] && [ -f "$D_KEY" ]; then
        echo "[Found] Key already installed for '$D_ALIAS': $D_KEY"
        if confirm "Keep using it?" Y; then KEY="$D_KEY"; fi
    fi
    while [ -z "$KEY" ] || [ ! -f "$KEY" ]; do
        prompt_required "Full path to your private key" KEY
        KEY="${KEY/#\~/$HOME}"   # expand a leading ~
        [ -f "$KEY" ] || echo "  (no file at: $KEY)"
    done

    # --- 4. Install + lock the key -------------------------------------------
    DEST="$HOME/.ssh/$(basename "$KEY")"
    if [ "$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")" != "$DEST" ]; then
        cp "$KEY" "$DEST"
    fi
    chmod 600 "$DEST"
    echo "[OK] Key installed and locked: $DEST"

    # --- 5. Write the ~/.ssh/config alias ------------------------------------
    CFG="$HOME/.ssh/config"
    SKIP_CFG=0
    if alias_in_ssh_config "$ALIAS"; then
        if confirm "Alias '$ALIAS' already exists in $CFG. Overwrite it?" N; then
            tmp=$(mktemp)
            awk -v a="$ALIAS" '
                /^[Hh]ost[ \t]+/ { skip=0; for (i=2;i<=NF;i++) if ($i==a) skip=1 }
                skip==0 { print }
            ' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
        else
            echo "[Info] Keeping the existing '$ALIAS' alias."
            SKIP_CFG=1
        fi
    fi
    if [ "$SKIP_CFG" != "1" ]; then
        {
            printf '\nHost %s\n' "$ALIAS"
            printf '    HostName %s\n' "$SERVER_IP"
            printf '    User %s\n' "$SSH_USER"
            [ "$SSH_PORT" != "22" ] && printf '    Port %s\n' "$SSH_PORT"
            printf '    IdentityFile %s\n' "$DEST"
            printf '    AddKeysToAgent yes\n'
            [ "$(uname)" = "Darwin" ] && printf '    UseKeychain yes\n'
        } >> "$CFG"
        chmod 600 "$CFG"
        echo "[OK] SSH alias '$ALIAS' written - connect with: ssh $ALIAS"
    fi

    # macOS: store the passphrase in the Keychain so you aren't prompted each time
    if [ "$(uname)" = "Darwin" ]; then
        ssh-add --apple-use-keychain "$DEST" 2>/dev/null && echo "[OK] Key added to the macOS Keychain"
    fi
else
    ALIAS="$D_ALIAS"; SSH_PORT="$D_SSH_PORT"; PROXY_PORT="$D_PROXY_PORT"
    # Keep the saved domain unless --domain gives a new one.
    if [ -n "$DOMAIN_ARG" ]; then
        use_domain 0
    else
        DOMAIN="$D_DOMAIN"
    fi
fi

# --- 6. Save the settings (~/.claude-proxy.conf) ----------------------------
# The profile itself carries no personal settings anymore, so updating it
# (proxy-update, or re-running this wizard) never loses them.
conf_set CLAUDE_SSH_HOST          "$ALIAS"
conf_set CLAUDE_SSH_PORT          "$SSH_PORT"
conf_set CLAUDE_REMOTE_PROXY_PORT "$PROXY_PORT"
conf_set CLAUDE_PROXY_DOMAIN      "$DOMAIN"
[ -n "$DOMAIN" ] && conf_set CLAUDE_NODES_FROM ""     # one node-list source at a time
echo "[OK] Settings saved: $CONF"

# --- 7. Install / update the cc profile --------------------------------------
if [ "$PROFILE_OK" = 1 ]; then
    if [ -f "$PROFILE_DEST" ]; then
        if cmp -s "$tmp_profile" "$PROFILE_DEST"; then
            echo "[OK] Profile already up to date: $PROFILE_DEST"
        else
            cp "$PROFILE_DEST" "$PROFILE_DEST.bak"
            echo "[Info] Previous profile kept at $PROFILE_DEST.bak"
        fi
    fi
    mv "$tmp_profile" "$PROFILE_DEST"
    echo "[OK] Profile installed: $PROFILE_DEST ($(sed -n 's/^CLAUDE_PROXY_VERSION="\(.*\)"/v\1/p' "$PROFILE_DEST"))"

    case "$(basename "${SHELL:-}")" in
        zsh)  RC="$HOME/.zshrc" ;;
        bash) RC="$HOME/.bashrc" ;;
        *)    [ "$(uname)" = "Darwin" ] && RC="$HOME/.zshrc" || RC="$HOME/.bashrc" ;;
    esac
    if grep -q 'claude-proxy.sh' "$RC" 2>/dev/null; then
        echo "[OK] $RC already sources the profile"
    else
        echo 'source ~/.claude-proxy.sh' >> "$RC"
        echo "[OK] Added 'source ~/.claude-proxy.sh' to $RC"
    fi
else
    rm -f "$tmp_profile"
    echo "[Warn] Could not download a valid profile from $REPO_RAW - the existing one (if any) is untouched."
    echo "       Install it manually (guide: Proxy setup -> Set up by hand) or re-run this wizard later."
fi

# --- 7b. Node list (jp / jp2 / sg ...) + ssh aliases for the other nodes ---------
# Best effort, done by the profile itself. First choice: privately from the VM
# just set up (over SSH); if it doesn't serve a list (yet), this guide's (empty)
# list. A saved source (--from / --domain) is simply refreshed.
if [ "$PROFILE_OK" = 1 ]; then
    echo ""
    if ! ( set +u; _CLAUDE_PROXY_QUIET=1; . "$PROFILE_DEST"
           if [ -z "$CLAUDE_PROXY_DOMAIN" ] && [ -z "$CLAUDE_NODES_FROM" ]; then
               proxy-nodes --from "$ALIAS" && exit 0
               echo "[Info] $ALIAS doesn't serve a node list (yet) - fine for now. Once your admin sets it up: proxy-nodes --from $ALIAS"
           fi
           proxy-nodes --refresh ); then
        echo "[Info] Node list not loaded (optional) - later: proxy-nodes --refresh"
    fi
fi

# --- 8. Verify the connection ----------------------------------------------
echo ""
echo "[Check] Testing: ssh $ALIAS ..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$ALIAS" exit </dev/tty; then
    echo "[OK] SSH connection works."
else
    echo "[Warn] Couldn't connect yet (passphrase, host key, or network)."
    echo "       Try once manually:  ssh $ALIAS"
fi

# --- 9. Next steps ----------------------------------------------------------
# Non-blocking: the proxy works without these CLIs, so only hint, never abort.
command -v claude >/dev/null 2>&1 || \
    echo "[Info] Claude Code CLI not installed - 'cc' needs it:  npm install -g @anthropic-ai/claude-code"
command -v codex  >/dev/null 2>&1 || \
    echo "[Info] Codex CLI not installed (optional) - to use 'cx':  npm install -g @openai/codex"
echo ""
echo "Done! Reload your shell, then launch Claude (or Codex with 'cx'):"
echo "    source ${RC:-~/.zshrc}"
echo "    cc"
echo ""
echo "Later: 'proxy-update' fetches the newest profile (settings kept), 'proxy-config' shows/edits them."
echo ""
