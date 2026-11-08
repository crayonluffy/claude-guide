# Installer details and setup by hand

The [home page](/) has the short version. This page explains what the installer does on each platform, and how to do the same steps by hand.

You install a small shell profile **one time**. After that, one command does all the steps:

- **`cc`** starts the SSH tunnel, sets the proxy settings, makes sure that your IP address is the IP address of the proxy, and starts **Claude**.
- **`cx`** does the same steps and starts **Codex**.
- **`cc-stop`** stops the proxy for the two applications.

The profile uses a tunnel that already runs. It does not start a second one.

Your server data is in a small **settings file**: `~/.claude-proxy.conf` on macOS and Linux, `~\.claude-proxy.conf.psd1` on Windows. This file is *separate* from the profile script. Thus **`proxy-update`** (or the wizard) gives you the newest profile, and **you do not type your settings again**.

**Before you start, you need:**

1. Your **SSH private key** file (ask your admin), in your **Downloads** folder.
2. The **IP address or hostname** of the VM, and your **SSH username**.
3. [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) on the VM (tinyproxy on port `8888`). Your admin installs it.

You do **not** have to install Node.js, Claude Code or Codex first. The last step of the wizard (`cc-install`) installs them **through** the proxy. This is important on a blocked network. (To install them by hand, refer to [Install Claude Code](install-claude.md).)

---

## Windows

### Step 1 — Put your SSH key in Downloads

Download your private key file (the filename is not important) into your **Downloads** folder. The wizard finds it there automatically.

### Step 2 — Run the setup wizard

Paste this into **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

The wizard asks for your server, user and alias. Then it:

- installs and locks the key,
- keeps an existing different key of the same name in `~/.ssh`, and installs yours as `<name>-claude-proxy`,
- writes the `~/.ssh/config` alias (then `ssh jpvpn` works),
- saves your settings in `~\.claude-proxy.conf.psd1`, with the kill switch on,
- asks if plain `claude` and `codex` must also start through the proxy,
- installs the `cc`/`cx` profile,
- tests the connection.

If you already did the setup, run the same command again. It finds your settings and asks **"Keep these settings and only update the cc/cx profile?"**. Press Enter. You get the newest profile and you do not type anything again.

> **Where the files go:** the profile goes to **`~\.claude-proxy.ps1`** (your home folder), and your settings go to `~\.claude-proxy.conf.psd1`. `$PROFILE` (in Documents) gets only **one loader line**. The other content of `$PROFILE` stays.
>
> **Documents is locked?** Windows can block that one line: Defender **Controlled folder access**, a locked OneDrive folder, or a company policy. Or a group policy can stop scripts. Then the wizard tells you, and makes a **"Claude Proxy Shell"** shortcut on your Desktop. Double-click it to get a PowerShell window with `cc` and `cx`. Nothing needs Documents, and `proxy-update` continues to work. (`proxy-shortcut` makes the shortcut again.) For more data, refer to [Troubleshooting](troubleshooting.md).

**✅ Check:** the wizard ends with `[OK] SSH connection works.` and `Done!`.

### Step 3 — Use it

```powershell
proxy-up  # proxy ON (start here if Claude or Codex is not installed yet)
cc        # proxy ON + start Claude
cx        # proxy ON + start Codex
cc-stop   # proxy OFF (both)
```

**✅ Check:** `proxy-up`, `cc` and `cx` show your external IP address. It must be the IP address of the **VM**, not your own. If something is not correct, type `proxy-status --fix`.

The tunnel works. **Next: [install Claude Code](install-claude.md)** (and, if you want, [Codex](install-codex.md)). Their sign-in goes through this proxy, so keep it up. To set up the proxy **by hand**, refer to [Set up by hand — Windows](#set-up-by-hand--windows) below.

---

## macOS and Linux

These steps are for **zsh** (the macOS default) or **bash** (most Linux and WSL systems).

### Step 1 — Put your SSH key in Downloads

Download your private key file (the filename is not important) into your **Downloads** folder. The wizard finds it there automatically.

### Step 2 — Run the setup wizard

Paste this into your terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
```

The wizard asks for your server, user and alias. Then it:

- installs `jq` and `lsof` (the tools that the profile needs),
- installs and locks the key (and adds it to the macOS Keychain),
- keeps an existing different key of the same name in `~/.ssh`, and installs yours as `<name>-claude-proxy`,
- writes the `~/.ssh/config` alias (then `ssh jpvpn` works),
- saves your settings in `~/.claude-proxy.conf`, with the kill switch on,
- asks if plain `claude` and `codex` must also start through the proxy,
- adds the `cc`/`cx` profile to your shell startup file,
- tests the connection.

If you already did the setup, run the same command again. It finds your settings and asks **"Keep these settings and only update the cc/cx profile?"**. Press Enter. You get the newest profile and you do not type anything again. (To skip that question too, add `--update`: `bash <(curl -fsSL …/setup.sh) --update`.)

**✅ Check:** the wizard ends with `[OK] SSH connection works.` and `Done!`.

### Step 3 — Use it

```bash
source ~/.zshrc   # or ~/.bashrc - only the first time; new terminals load it automatically

proxy-up  # proxy ON (start here if Claude or Codex is not installed yet)
cc        # proxy ON + start Claude
cx        # proxy ON + start Codex
cc-stop   # proxy OFF (both)
```

**✅ Check:** `proxy-up`, `cc` and `cx` show your external IP address. It must be the IP address of the **VM**, not your own. If something is not correct, type `proxy-status --fix`.

The tunnel works. **Next: [install Claude Code](install-claude.md)** (and, if you want, [Codex](install-codex.md)). Their sign-in goes through this proxy, so keep it up. To set up the proxy **by hand**, refer to [Set up by hand — macOS / Linux](#set-up-by-hand--macos-and-linux) below.

---

## WSL (Windows Subsystem for Linux)

If you work in **WSL** (Ubuntu) on Windows, do the **macOS / Linux** steps above *in the WSL terminal*. (WSL is the recommended way to run Codex on Windows.) You do not have to install anything on the Windows side. The differences are:

- **Key:** download it with your Windows browser. The wizard also looks in your **Windows** Downloads folder (`C:\Users\<you>\Downloads`). It copies the key into `~/.ssh` in WSL. (ssh does not use a key directly from `/mnt/c`, because there all files look readable by all users.)
- **Claude and Codex** are installed *in* WSL (Node.js in WSL, then `npm install -g …` as in [Install Claude Code](install-claude.md)). `cc` and `cx` start them there.
- **Passphrase:** WSL does not keep an ssh-agent between terminals. A key *with* a passphrase would block the background tunnel. The profile starts an agent and loads the key for you. If the tunnel still does not start, type `ssh-add ~/.ssh/<your-key>` one time in that terminal (or use a key without a passphrase).
- **Chrome:** `chrome-proxy` finds **Windows** Chrome in `/mnt/c` and starts it through the tunnel. WSL2 forwards the `127.0.0.1` ports to Windows automatically.
- **Claude on Windows too:** Windows can use the tunnel at `http://127.0.0.1:8080`. Thus Claude Code in *Windows* PowerShell can also use it. Type `proxy-config set SYNC_WINDOWS_SETTINGS 1`. Then the profile also writes the proxy into the Windows `%USERPROFILE%\.claude\settings.json`, the same as for WSL. With the kill switch on, the profile keeps it there. This needs the default `localhostForwarding` of WSL2. `proxy-status --fix` shows if this setting is on.

All other commands (`cc -c`, `proxy-update`, `proxy-config`, `proxy-status --fix`) are the same as on Linux.

---

## Set up by hand — Windows

These are the same steps as the wizard, done by hand.

### Step 1 — Install your SSH key + alias

1. Download your key (the filename is not important) into **Downloads**.
2. Fill in the first two lines of the block below.
3. Paste the full block into PowerShell.

The block finds the key, moves it into `~/.ssh`, locks the permissions, and writes an alias in `~/.ssh/config`. Then you can connect with `ssh jpvpn`:

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

The profile is in your **home folder** (`~\.claude-proxy.ps1`), not in Documents. `$PROFILE` needs only one line that loads it:

```powershell
# 1. Allow your own scripts to run (per-user, safe)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. Download the profile into your home folder
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/claude-proxy.ps1" -OutFile "$HOME\.claude-proxy.ps1"
Unblock-File -Path "$HOME\.claude-proxy.ps1"

# 3. Your settings live in a separate file (the profile itself has none) - point it at the alias from Step 1
@"
@{
    SSH_HOST          = 'jpvpn'   # the alias from Step 1 (or a raw host/IP)
    SSH_PORT          = 22
    REMOTE_PROXY_PORT = 8888      # tinyproxy port on the VM (webproxy-manager)
}
"@ | Set-Content -Path (Join-Path $HOME '.claude-proxy.conf.psd1') -Encoding ascii

# 4. Make every new window load it: ONE line appended to $PROFILE (your existing profile content stays)
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content -Path $PROFILE -Value 'if (Test-Path "$HOME\.claude-proxy.ps1") { . "$HOME\.claude-proxy.ps1" }   # claude-proxy'

# 5. Load it into the current window
. "$HOME\.claude-proxy.ps1"
```

> **`Access denied` in step 4, or `running scripts is disabled` in step 5?** Documents is locked, or a group policy blocks scripts. (Documents: Defender **Controlled folder access**, at Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell; or OneDrive or a company policy.) You do not need step 4. Skip it and type **`proxy-shortcut`** one time after step 5. If step 5 is also blocked, first type `Invoke-Expression (Get-Content -Raw "$HOME\.claude-proxy.ps1")`. No policy stops this command. `proxy-shortcut` puts a **"Claude Proxy Shell"** shortcut on your Desktop. It opens PowerShell with `cc` and `cx`.

The settings file only needs to point at your alias. All keys and their defaults: [Settings](settings.md).

📄 The full profile is in the repository: [`scripts/claude-proxy.ps1`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.ps1). The download command above gets this file.

> **⚠️ Caution: encoding (Traditional Chinese Windows):** Notepad on a zh-TW system often saves files as **Big5 / CP950**. This damages the script and causes parse errors. Edit the profile in **VS Code** or **Notepad++** and save it as **UTF-8**. (The published script contains only ASCII characters. Thus all editors are safe if you do not add other characters.)

### Step 3 — First connection

The first time, SSH asks `Are you sure you want to continue connecting (yes/no)?`. The background tunnel cannot answer. Thus type this **one time** and answer `yes`:

```powershell
ssh jpvpn
```

Then use `cc` and `cx` as usual.

---

## Set up by hand — macOS and Linux

### Step 1 — Install your SSH key + alias

1. Download your key (the filename is not important) into your **Downloads** folder.
2. Fill in the first two lines of the block below.
3. Paste the block into your terminal.

The block moves the key into `~/.ssh`, locks it (`chmod 600`), and writes an alias in `~/.ssh/config`. On macOS, it also adds the key to the Keychain, so you do not have to type the passphrase:

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

# 2. Your settings live in a separate file (the script itself has none) - point it at the alias from Step 1
cat > ~/.claude-proxy.conf <<'EOF'
CLAUDE_SSH_HOST="jpvpn"          # the alias from Step 1 (or a raw host/IP)
CLAUDE_SSH_PORT=22
CLAUDE_REMOTE_PROXY_PORT=8888    # tinyproxy port on the VM (webproxy-manager)
EOF

# 3. Source the script from your shell rc so it loads in every new shell
echo 'source ~/.claude-proxy.sh' >> ~/.zshrc      # macOS (zsh)
# echo 'source ~/.claude-proxy.sh' >> ~/.bashrc   # Linux (bash)

# 4. Reload your shell
source ~/.zshrc      # or: source ~/.bashrc
```

📄 The full script is in the repository: [`scripts/claude-proxy.sh`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.sh). The `curl` command above downloads this file. It works in **zsh and bash**.

All keys and their defaults: [Settings](settings.md).

### Step 3 — First connection

Accept the host key one time:

```bash
ssh jpvpn
```

Type `yes` when SSH asks, then exit. Now use `cc` and `cx` as usual.

---

## Next

- **[Install Claude Code](install-claude.md)** (then, if you want, **[Codex](install-codex.md)**). The sign-in goes through this proxy, so do it *after* this page.
- Something does not work? Refer to **[Troubleshooting](troubleshooting.md)** (start with `proxy-status --fix`).
- You do not want a profile? Refer to **[Manual — no profile](proxy-manual.md)**.

---

## Moved sections

These sections used to be on this page:

- <a id="the-commands-you-get"></a>The commands: [Commands](commands.md)
- <a id="kill-switch-290"></a>Kill switch: [Kill switch, recovery and alerts](kill-switch.md#kill-switch)
- <a id="recovery-while-claude-or-codex-is-running"></a>Recovery while Claude or Codex runs: [Kill switch, recovery and alerts](kill-switch.md#recovery-while-claude-or-codex-is-running)
- <a id="desktop-alerts-while-the-cli-owns-the-terminal"></a>Desktop alerts: [Kill switch, recovery and alerts](kill-switch.md#desktop-alerts-while-the-cli-owns-the-terminal)
- <a id="two-accounts-on-one-mac-shared-mode-2130"></a>Two accounts on one Mac: [Shared mode](shared-mode.md)
- <a id="-optional-browse-through-the-proxy"></a>Browse through the proxy: [Chrome](chrome.md)
- <a id="-changing-your-server-or-user-later"></a>Changing your server, user or ports: [Settings](settings.md#changing-your-server-user-or-ports)
- <a id="-updating-the-profile-later"></a>Updating the profile: [Updating](upgrading.md)

