#!/usr/bin/env bash
# ============================================================
# Interactive setup wizard - Claude SSH tunnel proxy (macOS / Linux)
# ============================================================
# Run with:
#   bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
#
# Does the whole one-time setup: prompts for your VM details, installs and
# locks your SSH key, writes an ~/.ssh/config alias, installs the cc profile,
# and tests the connection. Prefer the paste-blocks in the README if you'd
# rather not run a downloaded script.
# ============================================================

set -u
REPO_RAW="https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts"

# All prompts read from /dev/tty (the keyboard) rather than stdin, so the wizard
# still works when piped - e.g. curl ... | bash, where stdin is the script text.
prompt_required() {  # prompt_required <text> <varname>
    local text="$1" __var="$2" reply=""
    while [ -z "$reply" ]; do
        printf '%s: ' "$text" > /dev/tty
        IFS= read -r reply < /dev/tty || reply=""
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

confirm() {  # confirm <text> <Y|N default> ; returns 0 for yes
    local text="$1" def="${2:-Y}" reply="" hint
    if [ "$def" = "Y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf '%s %s: ' "$text" "$hint" > /dev/tty
    IFS= read -r reply < /dev/tty || reply=""
    [ -z "$reply" ] && reply="$def"
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

echo ""
echo "=== Claude proxy setup wizard (macOS / Linux) ==="
echo ""

# --- 1. Collect VM details -------------------------------------------------
prompt_required "Server IP or hostname"                     SERVER_IP
prompt_required "SSH username"                              SSH_USER
prompt_default  "SSH alias (the shortcut you'll type)"      ALIAS    "jpvpn"
prompt_default  "SSH port"                                  SSH_PORT "22"

# --- 2. Find / choose the private key --------------------------------------
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

found=""
for f in "$HOME"/Downloads/*; do
    [ -f "$f" ] || continue
    case "$f" in *.pub) continue ;; esac
    if head -n1 "$f" 2>/dev/null | grep -q "BEGIN .*PRIVATE KEY"; then
        if [ -z "$found" ] || [ "$f" -nt "$found" ]; then found="$f"; fi
    fi
done

KEY=""
if [ -n "$found" ]; then
    echo ""
    echo "[Found] Newest private key in Downloads: $found"
    if confirm "Use this key?" Y; then KEY="$found"; fi
fi
while [ -z "$KEY" ] || [ ! -f "$KEY" ]; do
    prompt_required "Full path to your private key" KEY
    KEY="${KEY/#\~/$HOME}"   # expand a leading ~
    [ -f "$KEY" ] || echo "  (no file at: $KEY)"
done

# --- 3. Install + lock the key ---------------------------------------------
DEST="$HOME/.ssh/$(basename "$KEY")"
if [ "$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")" != "$DEST" ]; then
    cp "$KEY" "$DEST"
fi
chmod 600 "$DEST"
echo "[OK] Key installed and locked: $DEST"

# --- 4. Write the ~/.ssh/config alias --------------------------------------
CFG="$HOME/.ssh/config"
if grep -qiE "^Host[[:space:]]+$ALIAS([[:space:]]|$)" "$CFG" 2>/dev/null; then
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
if [ "${SKIP_CFG:-0}" != "1" ]; then
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

# --- 5. Install the cc profile ---------------------------------------------
PROFILE_DEST="$HOME/.claude-proxy.sh"
if curl -fsSL "$REPO_RAW/claude-proxy.sh" -o "$PROFILE_DEST"; then
    # Patch the settings block to match the answers above.
    sed -i.bak -E "s|^export CLAUDE_SSH_HOST=.*|export CLAUDE_SSH_HOST=\"$ALIAS\"|" "$PROFILE_DEST"
    sed -i.bak -E "s|^export CLAUDE_SSH_PORT=.*|export CLAUDE_SSH_PORT=$SSH_PORT|"   "$PROFILE_DEST"
    rm -f "$PROFILE_DEST.bak"
    echo "[OK] Profile installed: $PROFILE_DEST"

    case "$(basename "${SHELL:-}")" in
        zsh)  RC="$HOME/.zshrc" ;;
        bash) RC="$HOME/.bashrc" ;;
        *)    [ "$(uname)" = "Darwin" ] && RC="$HOME/.zshrc" || RC="$HOME/.bashrc" ;;
    esac
    if grep -q 'claude-proxy.sh' "$RC" 2>/dev/null; then
        echo "[Info] $RC already sources the profile - leaving it."
    else
        echo 'source ~/.claude-proxy.sh' >> "$RC"
        echo "[OK] Added 'source ~/.claude-proxy.sh' to $RC"
    fi
else
    echo "[Warn] Could not download the profile - install it manually (README Step 2)."
fi

# --- 6. Verify the connection ----------------------------------------------
echo ""
echo "[Check] Testing: ssh $ALIAS ..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$ALIAS" exit </dev/tty; then
    echo "[OK] SSH connection works."
else
    echo "[Warn] Couldn't connect yet (passphrase, host key, or network)."
    echo "       Try once manually:  ssh $ALIAS"
fi

# --- 7. Next steps ----------------------------------------------------------
echo ""
echo "Done! Reload your shell, then launch Claude:"
echo "    source ${RC:-~/.zshrc}"
echo "    cc"
echo ""
