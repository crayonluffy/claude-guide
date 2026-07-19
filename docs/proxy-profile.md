# Proxy — One-Command Setup (profile)

This installs a small shell profile **once**. After that, a single command does everything:

- **`cc`** → starts the SSH tunnel, sets the proxy env vars, verifies your IP is the proxy's, launches **Claude**.
- **`cx`** → exactly the same, but launches **Codex**.
- **`cc-stop`** → the one off-switch for both.

It reuses anything already running instead of starting duplicates.

**Before you start, you need:**

1. Your **SSH private key** file (ask your admin), downloaded into your **Downloads** folder.
2. The VM's **IP/hostname** and your **SSH username**.
3. The VM running [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on `:8888`) — your admin's job.

You do **not** need Claude Code or Codex installed yet — do the proxy first. On a blocked network their sign-in (and sometimes `npm install`) only works *through* this proxy, so [install them](install-claude.md) as the next step once `cc`/`cx` exist.

---

## The commands you get

| Command | What it does |
|---------|--------------|
| `cc` | Proxy ON + launch **Claude** (`--dangerously-skip-permissions`). Auto-heals: a dead/leftover ssh is killed and restarted; if another app has the port, it's left alone and the tunnel uses the next free port (`8081`, …) automatically |
| `cc-safe` | Same, but keeps Claude's permission prompts |
| `cx` | Proxy ON + launch **Codex** (approvals off) |
| `cx-safe` | Same, but keeps Codex's approval prompts |
| `proxy-up` | Proxy ON (tunnel + env vars + verify), but don't launch anything |
| `cc-stop` | Proxy OFF — one off-switch for both `cc` and `cx`; kills every **ssh** on the tunnel ports (other apps are left alone) and reports honestly |
| `proxy-status` | Show what's running + your current external IP |
| `proxy-doctor` | Diagnose each part (tunnel, ports, env, settings, API reachability) and print exactly what's wrong + how to fix it |
| `tunnel-start` / `tunnel-stop` | Manage just the SSH tunnel |
| `proxy-on` / `proxy-off` | Set / clear the proxy env vars **and** sync `~/.claude/settings.json` |
| `chrome-proxy` | Open Chrome routed through the SOCKS5 proxy (separate, isolated profile; auto-starts the tunnel) |
| `cc-help` | Print this command list (it also prints when a new shell opens) |

> **Codex note:** Codex reads the standard `HTTP(S)_PROXY` env vars, so it shares the same tunnel — no extra setup. Only Claude gets the extra `settings.json` sync (so `claude` works even from shells that never ran `cc`).

---

## 🪟 Windows

### Step 1 — Put your SSH key in Downloads

Download your private key file (any filename) into your **Downloads** folder. The wizard finds it there automatically.

### Step 2 — Run the setup wizard

Paste this into **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

It prompts for your server, user, and alias, then:

- installs and locks the key,
- writes the `~/.ssh/config` alias (so `ssh jpvpn` just works),
- installs the `cc`/`cx` profile,
- tests the connection.

> **If it ends with `[FAIL] Could not write the profile`:** Windows blocked writing into your Documents folder — usually Defender's **Controlled folder access** or a locked OneDrive folder. The wizard tells you the exact cause, keeps your configured profile in `%TEMP%`, and prints the one `Copy-Item` command that finishes the install once you unblock it. Details → [Troubleshooting](troubleshooting.md).

**✅ Check it worked:** the wizard ends with `[OK] SSH connection works.` and `Done!`.

### Step 3 — Use it

```powershell
proxy-up  # proxy ON (start here if Claude/Codex aren't installed yet)
cc        # proxy ON + launch Claude
cx        # proxy ON + launch Codex
cc-stop   # proxy OFF (both)
```

**✅ Check it worked:** `proxy-up`/`cc`/`cx` prints your external IP — it should be the **VM's** IP, not your own. If anything looks off, run `proxy-doctor`.

Done — the tunnel works. **Next: [install Claude Code](install-claude.md)** (and optionally [Codex](install-codex.md)) — their sign-in goes through this proxy, so keep it up. Setting the proxy up **by hand** instead? See [Set up by hand — Windows](#set-up-by-hand--windows) below.

---

## 🍎 macOS / 🐧 Linux

Same idea, written for **zsh** (macOS default) or **bash** (most Linux / WSL).

### Step 1 — Put your SSH key in Downloads

Download your private key file (any filename) into your **Downloads** folder. The wizard finds it there automatically.

### Step 2 — Run the setup wizard

Paste this into your terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
```

It prompts for your server, user, and alias, then:

- installs `jq` + `lsof` (client dependencies),
- installs and locks the key (and adds it to the macOS Keychain),
- writes the `~/.ssh/config` alias (so `ssh jpvpn` just works),
- installs the `cc`/`cx` profile into your shell rc,
- tests the connection.

**✅ Check it worked:** the wizard ends with `[OK] SSH connection works.` and `Done!`.

### Step 3 — Use it

```bash
source ~/.zshrc   # or ~/.bashrc — first time only; new terminals load it automatically

proxy-up  # proxy ON (start here if Claude/Codex aren't installed yet)
cc        # proxy ON + launch Claude
cx        # proxy ON + launch Codex
cc-stop   # proxy OFF (both)
```

**✅ Check it worked:** `proxy-up`/`cc`/`cx` prints your external IP — it should be the **VM's** IP, not your own. If anything looks off, run `proxy-doctor`.

Done — the tunnel works. **Next: [install Claude Code](install-claude.md)** (and optionally [Codex](install-codex.md)) — their sign-in goes through this proxy, so keep it up. Setting the proxy up **by hand** instead? See [Set up by hand — macOS / Linux](#set-up-by-hand--macos--linux) below.

---

## Set up by hand — Windows

Prefer not to run a downloaded wizard? These are the same steps, done manually.

### Step 1 — Install your SSH key + alias

Download your key (any filename) into **Downloads**, fill in the first two lines, then paste the whole block. It finds the key, moves it into `~/.ssh`, locks the permissions, and writes an `~/.ssh/config` alias so you can connect with just `ssh jpvpn`:

```powershell
# Fill in your VM details once - everything else is automatic:
$ServerIp = "YOUR_SERVER_IP"     # the VM's IP or hostname
$SshUser  = "YOUR_SSH_USER"      # the SSH username on the VM
$Alias    = "jpvpn"            # the shortcut you'll type: ssh jpvpn

$downloads = Join-Path $HOME 'Downloads'
$sshDir    = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

# Find the newest private key in Downloads (a small file whose first line is a key header)
$key = Get-ChildItem -File $downloads -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ne '.pub' -and $_.Length -lt 100KB } |
    Where-Object { (Get-Content $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue) -match 'BEGIN .*PRIVATE KEY' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $key) {
    Write-Host "[Err] No private key found in $downloads - download it there first." -ForegroundColor Red
} else {
    # 1. Move the key into ~/.ssh and lock it down (OpenSSH rejects keys others can read)
    $dest = Join-Path $sshDir $key.Name
    Move-Item -LiteralPath $key.FullName -Destination $dest -Force
    icacls $dest /inheritance:r | Out-Null
    icacls $dest /grant:r "$($env:USERNAME):R" | Out-Null
    icacls $dest /remove "SYSTEM" | Out-Null
    icacls $dest /remove "Administrators" | Out-Null
    Write-Host "[OK] Key installed and locked: $dest" -ForegroundColor Green

    # 2. Add an SSH alias so you never type the key path or user@host again
    $configPath = Join-Path $sshDir 'config'
    if ((Test-Path $configPath) -and (Select-String -Path $configPath -Pattern "^Host\s+$Alias\b" -Quiet)) {
        Write-Host "[Info] Alias '$Alias' already in $configPath - leaving it." -ForegroundColor Yellow
    } else {
        $entry = "`nHost $Alias`n    HostName $ServerIp`n    User $SshUser`n    IdentityFile `"$dest`"`n"
        Add-Content -Path $configPath -Value $entry -Encoding ascii
        Write-Host "[OK] SSH alias created - connect with: ssh $Alias" -ForegroundColor Green
    }
    Write-Host "Done. The '$Alias' alias is ready - now install the cc profile (Step 2)." -ForegroundColor Cyan
}
```

### Step 2 — Install the `cc`/`cx` profile

Your PowerShell profile lives at `$PROFILE` (usually `C:\Users\<you>\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`):

```powershell
# 1. Allow your own scripts to run (per-user, safe)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. Download the profile straight into $PROFILE
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force }
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/Microsoft.PowerShell_profile.ps1" -OutFile $PROFILE

# 3. Unblock it (only needed if Windows flagged the file as web content)
Unblock-File -Path $PROFILE

# 4. Open it and edit the Settings block
notepad $PROFILE     # or:  code $PROFILE

# 5. Reload the profile into the current window
. $PROFILE
```

> **`Access denied` on step 2?** Windows is blocking writes into Documents — usually Defender's **Controlled folder access** (Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell) or a locked OneDrive folder. Unblock it, then re-run step 2.

The profile reads the connection from your `jpvpn` alias (Step 1), so the **Settings block** just points at it — no key/user/host to re-enter:

```powershell
$script:SSH_HOST          = "jpvpn"   # the alias from Step 1 (or a raw host/IP)
$script:SSH_USER          = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_KEY           = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_PORT          = 22
$script:HTTP_PORT         = 8080       # local HTTP port -> forwarded to the VM proxy (Claude/Codex)
$script:REMOTE_PROXY_PORT = 8888       # tinyproxy port on the VM (webproxy-manager)
$script:SOCKS_PORT        = 1080       # local SOCKS5 port (Chrome / other apps)
$script:SYNC_SETTINGS     = 1          # also write the proxy into ~/.claude/settings.json; 0 to disable
# Add corporate intranet ranges to $script:NO_PROXY_LIST further down if needed.
```

> Not using an alias? Fill in `SSH_KEY`, `SSH_USER`, and `SSH_HOST` explicitly instead — the profile uses them when they're set.

📄 The full profile lives in the repo: [`scripts/Microsoft.PowerShell_profile.ps1`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/Microsoft.PowerShell_profile.ps1). The download command above pulls that exact file.

> **⚠️ Encoding gotcha (Traditional Chinese Windows):** Notepad on a zh-TW system often saves as **Big5 / CP950**, which corrupts the script and produces parse errors. Edit the profile in **VS Code** or **Notepad++** and save as **UTF-8** (the published script is ASCII-only, so any editor is safe if you don't add non-ASCII text).

### Step 3 — First connection

SSH prompts `Are you sure you want to continue connecting (yes/no)?` the first time. The background tunnel can't answer that prompt, so run this **once** interactively and type `yes`:

```powershell
ssh jpvpn
```

Then use `cc` / `cx` as usual.

---

## Set up by hand — macOS / Linux

### Step 1 — Install your SSH key + alias

Download your key (any filename) into your **Downloads** folder, fill in the first two lines, then paste. It moves the key into `~/.ssh`, locks it (`chmod 600`), writes an `~/.ssh/config` alias, and on macOS adds it to the Keychain so you aren't asked for the passphrase:

```bash
# Fill in your VM details once - everything else is automatic:
SERVER_IP="YOUR_SERVER_IP"     # the VM's IP or hostname
SSH_USER="YOUR_SSH_USER"       # the SSH username on the VM
ALIAS="jpvpn"                  # the shortcut you'll type: ssh jpvpn

mkdir -p ~/.ssh && chmod 700 ~/.ssh

# Find the newest private key in ~/Downloads (a file whose first line is a key header)
key=""
for f in "$HOME"/Downloads/*; do
  [ -f "$f" ] || continue
  case "$f" in *.pub) continue ;; esac
  if head -n1 "$f" 2>/dev/null | grep -q "BEGIN .*PRIVATE KEY"; then
    if [ -z "$key" ] || [ "$f" -nt "$key" ]; then key="$f"; fi
  fi
done

if [ -z "$key" ]; then
  echo "[Err] No private key found in ~/Downloads - download it there first."
else
  dest="$HOME/.ssh/$(basename "$key")"
  mv "$key" "$dest" && chmod 600 "$dest"
  echo "[OK] Key installed and locked: $dest"

  cfg="$HOME/.ssh/config"
  if grep -qiE "^Host[[:space:]]+$ALIAS([[:space:]]|$)" "$cfg" 2>/dev/null; then
    echo "[Info] Alias '$ALIAS' already in $cfg - leaving it."
  else
    {
      printf '\nHost %s\n' "$ALIAS"
      printf '    HostName %s\n' "$SERVER_IP"
      printf '    User %s\n' "$SSH_USER"
      printf '    IdentityFile %s\n' "$dest"
      printf '    AddKeysToAgent yes\n'
      [ "$(uname)" = "Darwin" ] && printf '    UseKeychain yes\n'
    } >> "$cfg"
    chmod 600 "$cfg"
    echo "[OK] SSH alias created - connect with: ssh $ALIAS"
  fi

  # macOS: store the passphrase in the Keychain so you aren't prompted each time
  [ "$(uname)" = "Darwin" ] && ssh-add --apple-use-keychain "$dest" 2>/dev/null
fi
```

### Step 2 — Install the `cc`/`cx` profile

```bash
# 1. Download the script to ~/.claude-proxy.sh
curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/claude-proxy.sh -o ~/.claude-proxy.sh

# 2. Source it from your shell rc so it loads in every new shell
echo 'source ~/.claude-proxy.sh' >> ~/.zshrc      # macOS (zsh)
# echo 'source ~/.claude-proxy.sh' >> ~/.bashrc   # Linux (bash)

# 3. Reload your shell
source ~/.zshrc      # or: source ~/.bashrc
```

📄 The full script lives in the repo: [`scripts/claude-proxy.sh`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.sh). The `curl` command above downloads that exact file.

It already points at the `jpvpn` alias from Step 1, so there's nothing to re-enter — the **Settings block** just confirms:

```bash
export CLAUDE_SSH_HOST="jpvpn"          # the alias from Step 1 (or a raw host/IP)
export CLAUDE_SSH_USER=""               # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_KEY=""                # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_PORT=22
export CLAUDE_HTTP_PORT=8080            # local HTTP port -> forwarded to the VM proxy (Claude/Codex)
export CLAUDE_REMOTE_PROXY_PORT=8888    # tinyproxy port on the VM (webproxy-manager)
export CLAUDE_SOCKS_PORT=1080           # local SOCKS5 port (Chrome / other apps)
export CLAUDE_SYNC_SETTINGS=1           # also write the proxy into ~/.claude/settings.json (needs jq); 0 to disable
# Append corporate intranet ranges to CLAUDE_NO_PROXY if needed.
```

> Not using an alias? Fill in `CLAUDE_SSH_KEY`, `CLAUDE_SSH_USER`, and `CLAUDE_SSH_HOST` explicitly instead.

### Step 3 — First connection

Accept the host key once, interactively:

```bash
ssh jpvpn
```

Type `yes` when prompted, then exit. Now use `cc` / `cx` as usual.

---

## 🔁 Changing your server or user later

Your `jpvpn` alias lives in `~/.ssh/config` — that's why `ssh jpvpn`, `cc`, and `cx` need no key path, user, or host. Setup created it; edit that file if your server IP or user changes:

```
Host jpvpn
    HostName <your-host-or-ip>
    User <your-ssh-user>
    IdentityFile ~/.ssh/<your-key>
    AddKeysToAgent yes
    UseKeychain yes      # macOS only
```

---

## 🌐 (Optional) Browse through the proxy

With the profile installed, run **`chrome-proxy`** — it opens a **separate** Chrome routed through the **SOCKS5** proxy on `127.0.0.1:1080`, without touching your normal browsing session. It auto-starts the tunnel if needed, keeps a separate `--user-data-dir` (isolated logins/cookies/history), and resolves DNS through the tunnel (no DNS leaks). Under WSL it launches **Windows** Chrome.

---

## Next →

- **[Install Claude Code](install-claude.md)** (then optionally **[Codex](install-codex.md)**) — sign-in goes through this proxy, so it comes *after* this page.
- Something not working? → **[Troubleshooting](troubleshooting.md)** (start with `proxy-doctor`)
- Don't want a profile at all? → **[Manual — no profile](proxy-manual.md)**
