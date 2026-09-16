# Proxy — One-Command Setup (profile)

This installs a small shell profile **once**. After that, a single command does everything:

- **`cc`** → starts the SSH tunnel, sets the proxy env vars, verifies your IP is the proxy's, launches **Claude**.
- **`cx`** → exactly the same, but launches **Codex**.
- **`cc-stop`** → the one off-switch for both.

It reuses anything already running instead of starting duplicates.

Your server details live in a small **settings file** (`~/.claude-proxy.conf` on macOS/Linux, `~\.claude-proxy.conf.psd1` on Windows), *separate* from the profile script — so **`proxy-update`** (or simply re-running the wizard) always gives you the newest profile **without retyping anything**.

**Before you start, you need:**

1. Your **SSH private key** file (ask your admin), downloaded into your **Downloads** folder.
2. The VM's **IP/hostname** and your **SSH username**.
3. The VM running [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on `:8888`) — your admin's job.

You do **not** need Node.js, Claude Code or Codex installed yet — the wizard's last step (`cc-install`) installs them **through** the proxy, which matters on a blocked network. (Prefer doing it by hand? [Install Claude Code](install-claude.md).)

---

## The commands you get

| Command | What it does |
|---------|--------------|
| `cc` | Proxy ON + launch **Claude** (`--dangerously-skip-permissions`). Auto-heals: a dead/leftover ssh is killed and restarted; if another app has the port, it's left alone and the tunnel uses the next free port (`8081`, …) automatically |
| `cc -c` / `cc -r` | Same, but **continue** the last Claude session / **pick one to resume**. Anything after `cc` is passed to `claude` as-is (`cc --resume <id>`, `cc "fix the tests"`, …) |
| `cc-safe` | Same as `cc`, but keeps Claude's permission prompts (accepts the same extra arguments) |
| `cx` | Proxy ON + launch **Codex** (approvals off). Extra arguments pass through too: `cx resume` |
| `cx-safe` | Same, but keeps Codex's approval prompts |
| `proxy-up` | Proxy ON (tunnel + env vars + verify), but don't launch anything |
| `cc-stop` | Proxy OFF — one off-switch for both `cc` and `cx`; kills every **ssh** on the tunnel ports (other apps are left alone) and reports honestly |
| `proxy-status` | Show what's running + your current external IP |
| `proxy-doctor` | Diagnose each part (tunnel, ports, env, settings, API reachability) and print exactly what's wrong + how to fix it |
| `cc-install` | Check **Node.js**, **Claude Code** and **Codex**; install or update whatever is missing or too old (asks first; downloads go through the proxy). `cc-install --check` (`-Check`) only reports; `cc-install claude` does just that one; `-y` answers yes. The setup wizard runs it as its last step |
| `tunnel-start` / `tunnel-stop` | Manage just the SSH tunnel |
| `proxy-on` / `proxy-off` | Set / clear the proxy env vars **and** sync `~/.claude/settings.json` |
| `proxy-config` | Show your settings; `proxy-config edit` opens the settings file, `proxy-config set SSH_HOST myvm` changes one value |
| `proxy-update` | Download the newest profile from this guide and install it — **your settings are kept**. `proxy-update --check` (`-Check` on Windows) only tells you whether there is one |
| `proxy-nodes` | List the nodes (JP / JP2 / SG / US …) and which one is active; `proxy-nodes --refresh` (`-Refresh` on Windows) reloads the catalogue and creates the `ssh` aliases; `proxy-nodes --from jpvpn` (`-From`) gets the list privately from one of your VMs over SSH (`--domain` / `-Domain`: public DNS) — see [Nodes](proxy-nodes.md) |
| `proxy-node sg` | Make `sg` the node `cc` / `cx` use (restarts the tunnel if it's up). Shortcut: `cc --node sg` |
| `chrome-proxy` | Open Chrome routed through the SOCKS5 proxy (separate, isolated profile; auto-starts the tunnel). `chrome-proxy sg` opens one through node `sg` on its **own** tunnel + profile, so several regions can be open at once; `chrome-proxy sg https://…` also opens a URL; `chrome-proxy jp --profile work` (`-Profile` on Windows) opens another Chrome profile through the same node |
| `chrome-profiles` | List the Chrome profiles of every node (`chrome-profiles jp`: just `jp`'s) |
| `cc-help` | Print this command list. (A new shell prints a one-line "claude-proxy v… ready" notice instead of the whole list; `BANNER=0` in the settings file silences it) |

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
- saves your settings to `~\.claude-proxy.conf.psd1`,
- installs the `cc`/`cx` profile,
- tests the connection.

Already set up? Run the same command again: it finds your settings and asks **"Keep these settings and only update the cc/cx profile?"** — press Enter and you have the newest profile with nothing retyped.

> **Where things go:** the profile code is installed to **`~\.claude-proxy.ps1`** (your home folder) and your settings to `~\.claude-proxy.conf.psd1`. `$PROFILE` (in Documents) only gets **one loader line**; anything else you already had in it is kept.
>
> **Documents locked?** If Windows blocks that one line — Defender's **Controlled folder access**, a locked OneDrive folder, or company policy — or if scripts are disabled by group policy, the wizard says so and instead creates a **"Claude Proxy Shell"** shortcut on your Desktop. Double-click it and you get a PowerShell window with `cc`/`cx` ready; nothing needs Documents, and `proxy-update` keeps working. (`proxy-shortcut` re-creates the shortcut any time.) Details → [Troubleshooting](troubleshooting.md).

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
- saves your settings to `~/.claude-proxy.conf`,
- installs the `cc`/`cx` profile into your shell rc,
- tests the connection.

Already set up? Run the same command again: it finds your settings and asks **"Keep these settings and only update the cc/cx profile?"** — press Enter and you have the newest profile with nothing retyped. (Add `--update` to skip even that question: `bash <(curl -fsSL …/setup.sh) --update`.)

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

## 🐧 WSL (Windows Subsystem for Linux)

Windows users who work in **WSL** (Ubuntu) — the recommended way to run Codex on Windows — follow the **macOS / Linux** steps above *inside the WSL terminal*; nothing needs to be installed on the Windows side. The differences:

- **Key:** download it with your Windows browser as usual. The wizard also searches your **Windows** Downloads folder (`C:\Users\<you>\Downloads`) and copies the key into WSL's `~/.ssh` (ssh refuses to use a key straight from `/mnt/c`, where every file looks world-readable).
- **Claude / Codex** are installed *inside* WSL (Node.js in WSL, then `npm install -g …` as in [Install Claude Code](install-claude.md)), and `cc` / `cx` launch them there.
- **Passphrase:** WSL has no ssh-agent that survives between terminals, so a key *with* a passphrase would block the background tunnel. The profile starts an agent and loads the key for you; if the tunnel still doesn't come up, run `ssh-add ~/.ssh/<your-key>` once in that terminal (or use a key without a passphrase).
- **Chrome:** `chrome-proxy` finds **Windows** Chrome under `/mnt/c` and launches it through the tunnel — WSL2 forwards `127.0.0.1` ports to Windows automatically.
- **Windows-side Claude too?** The tunnel is reachable from Windows at `http://127.0.0.1:8080`, so a Claude Code installed in *Windows* PowerShell can use it as well. `proxy-config set SYNC_WINDOWS_SETTINGS 1` makes `cc` / `proxy-up` write the proxy into the Windows `%USERPROFILE%\.claude\settings.json` too (and `cc-stop` remove it again), exactly like it does for the WSL one. Needs WSL2's default `localhostForwarding`; `proxy-doctor` shows whether the sync is on.

Everything else — `cc -c`, `proxy-update`, `proxy-config`, `proxy-doctor` — is identical to Linux.

---

## 🔄 Updating the profile later

The profile carries **no personal settings** — those live in your settings file — so updating is one command, on any OS:

```bash
proxy-update            # fetch + install the newest profile; settings untouched
proxy-update --check    # just tell me if there is a newer one   (Windows: proxy-update -Check)
```

Then open a new terminal (or `source ~/.claude-proxy.sh` / `. "$HOME\.claude-proxy.ps1"`). Re-running the setup wizard does the same thing and additionally offers to keep your settings. If your profile is older than v2.0 and has no `proxy-update` yet, re-run the wizard once — it reads the settings out of the old profile for you (on Windows it also moves the profile out of `$PROFILE` into `~\.claude-proxy.ps1`, leaving a one-line loader behind, so a locked Documents folder never blocks future updates).

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

The profile code lives in your **home folder** (`~\.claude-proxy.ps1`), not in Documents; `$PROFILE` only needs one line that loads it:

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

> **`Access denied` on step 4, or `running scripts is disabled` on step 5?** Documents is locked (Defender's **Controlled folder access**: Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell; or OneDrive / company policy), or scripts are blocked by group policy. You don't need either: skip step 4 and run **`proxy-shortcut`** once (after step 5 — or, if even that is blocked, after `Invoke-Expression (Get-Content -Raw "$HOME\.claude-proxy.ps1")`, which no policy stops). It puts a **"Claude Proxy Shell"** shortcut on your Desktop that opens PowerShell with `cc`/`cx` loaded.

The profile reads the connection from your `jpvpn` alias (Step 1), so the settings file just points at it — no key/user/host to re-enter. Every key it understands (anything you leave out keeps the built-in default; `proxy-config` shows the current values, `proxy-config set KEY VALUE` changes one):

| Key | Default | Meaning |
|-----|---------|---------|
| `SSH_HOST` | `'jpvpn'` | the alias from Step 1, or a raw host/IP |
| `SSH_USER` / `SSH_KEY` | `''` | only when `SSH_HOST` is a raw host, not an alias |
| `SSH_PORT` | `22` | |
| `HTTP_PORT` | `8080` | local HTTP port → forwarded to the VM proxy (Claude/Codex) |
| `REMOTE_PROXY_PORT` | `8888` | tinyproxy port on the VM (webproxy-manager) |
| `SOCKS_PORT` | `1080` | local SOCKS5 port (Chrome / other apps) |
| `NODE_SOCKS_BASE` | `1180` | first port for per-node Chrome tunnels (`chrome-proxy <node>`) — see [Nodes](proxy-nodes.md) |
| `NODES_FROM` | `''` | the VM that serves the node list over SSH (`proxy-nodes -From` sets it) — see [Nodes](proxy-nodes.md) |
| `PROXY_DOMAIN` | `''` | take the node list from this domain's public DNS instead (`proxy-nodes -Domain` sets it) |
| `CHROME_EXE` | `''` | only if `chrome.exe` isn't in Program Files / `%LOCALAPPDATA%` |
| `SYNC_SETTINGS` | `1` | also write the proxy into `~/.claude/settings.json`; `0` to disable |
| `NO_PROXY_EXTRA` | `''` | corporate intranet ranges/domains to bypass, e.g. `'172.20.0.0/24,*.mycorp.example'` |
| `BANNER` | `1` | one-line notice when a new window opens; `0` for silence |

📄 The full profile lives in the repo: [`scripts/claude-proxy.ps1`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.ps1). The download command above pulls that exact file.

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

📄 The full script lives in the repo: [`scripts/claude-proxy.sh`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.sh). The `curl` command above downloads that exact file; it works in **zsh and bash**.

Every key the settings file understands (anything you leave out keeps the built-in default; `proxy-config` shows the current values, `proxy-config set KEY VALUE` changes one, `proxy-config edit` opens the file):

| Key | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_SSH_HOST` | `"jpvpn"` | the alias from Step 1, or a raw host/IP |
| `CLAUDE_SSH_USER` / `CLAUDE_SSH_KEY` | `""` | only when `CLAUDE_SSH_HOST` is a raw host, not an alias |
| `CLAUDE_SSH_PORT` | `22` | |
| `CLAUDE_HTTP_PORT` | `8080` | local HTTP port → forwarded to the VM proxy (Claude/Codex) |
| `CLAUDE_REMOTE_PROXY_PORT` | `8888` | tinyproxy port on the VM (webproxy-manager) |
| `CLAUDE_SOCKS_PORT` | `1080` | local SOCKS5 port (Chrome / other apps) |
| `CLAUDE_NODE_SOCKS_BASE` | `1180` | first port for per-node Chrome tunnels (`chrome-proxy <node>`) — see [Nodes](proxy-nodes.md) |
| `CLAUDE_NODES_FROM` | `""` | the VM that serves the node list over SSH (`proxy-nodes --from` sets it) — see [Nodes](proxy-nodes.md) |
| `CLAUDE_PROXY_DOMAIN` | `""` | take the node list from this domain's public DNS instead (`proxy-nodes --domain` sets it) |
| `CLAUDE_CHROME_BIN` | `""` | only if Chrome isn't in the usual place (macOS: app name or path; WSL: `/mnt/c/.../chrome.exe`) |
| `CLAUDE_SYNC_SETTINGS` | `1` | also write the proxy into `~/.claude/settings.json` (needs `jq`); `0` to disable |
| `CLAUDE_SYNC_WINDOWS_SETTINGS` | `0` | **WSL only:** `1` also keeps the *Windows-side* Claude (`%USERPROFILE%\.claude\settings.json`) pointed at this tunnel — see [WSL](#-wsl-windows-subsystem-for-linux) |
| `CLAUDE_NO_PROXY` | private ranges, `*.local`, … | hosts that bypass the proxy — extend with `CLAUDE_NO_PROXY="$CLAUDE_NO_PROXY,172.20.0.0/24,*.mycorp.example"` |
| `CLAUDE_PROXY_BANNER` | `1` | one-line notice when a new shell opens; `0` for silence |

### Step 3 — First connection

Accept the host key once, interactively:

```bash
ssh jpvpn
```

Type `yes` when prompted, then exit. Now use `cc` / `cx` as usual.

---

## 🔁 Changing your server or user later

Your `jpvpn` alias lives in `~/.ssh/config` — that's why `ssh jpvpn`, `cc`, and `cx` need no key path, user, or host. Setup created it; edit that file if your server IP or user changes (or just re-run the wizard, answer **n** to "keep these settings", and press Enter through the pre-filled answers, changing only what moved):

```
Host jpvpn
    HostName <your-host-or-ip>
    User <your-ssh-user>
    IdentityFile ~/.ssh/<your-key>
    AddKeysToAgent yes
    UseKeychain yes      # macOS only
```

Switching to a *different* alias, or changing a port? That's the settings file: `proxy-config set SSH_HOST other-vm`, `proxy-config set REMOTE_PROXY_PORT 8899`, … — and if your admin publishes several nodes (JP / SG / US), `proxy-node sg` does exactly that for you: see **[Nodes](proxy-nodes.md)**.

---

## 🌐 (Optional) Browse through the proxy

With the profile installed, run **`chrome-proxy`** — it opens a **separate** Chrome routed through the **SOCKS5** proxy on `127.0.0.1:1080`, without touching your normal browsing session. It auto-starts the tunnel if needed, keeps a separate `--user-data-dir` (isolated logins/cookies/history), and resolves DNS through the tunnel (no DNS leaks). Under WSL it launches **Windows** Chrome.

**Several regions at once?** `chrome-proxy jp`, `chrome-proxy sg`, … each open a Chrome through that node on its own tunnel and data folder. **Several accounts on the same node?** `chrome-proxy jp --profile work` — see **[Nodes](proxy-nodes.md)**.

No profile, or want the raw command? These are the equivalent copy-paste commands. The **tunnel must already be up** (`proxy-up`, or the manual Step-1 `ssh` command — that's what provides the `-D 1080` SOCKS forward):

**🪟 Windows (PowerShell)**

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
    --proxy-server="socks5://127.0.0.1:1080" `
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" `
    --user-data-dir="C:\ChromeVPNProfile" --no-first-run
```

**🍎 macOS**

```bash
open -n -a "Google Chrome" --args \
    --proxy-server="socks5://127.0.0.1:1080" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
    --user-data-dir="$HOME/.chrome-proxy-profile" --no-first-run
```

**🐧 Linux** (use `chromium` if you don't have `google-chrome`)

```bash
google-chrome \
    --proxy-server="socks5://127.0.0.1:1080" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
    --user-data-dir="$HOME/.config/google-chrome-vpn" --no-first-run &
```

**🐧 WSL:** run the **Windows PowerShell** command above — WSL2 forwards `127.0.0.1:1080` to Windows automatically (or just use `chrome-proxy`, which finds Windows Chrome for you).

What the flags do: `--proxy-server` sends all traffic through the SOCKS5 forward; `--host-resolver-rules` forces **DNS** through the tunnel too (no DNS leaks); `--user-data-dir` keeps this Chrome a **separate profile**, so your normal browser session is untouched. If port `1080` was busy and the tunnel fell back to another SOCKS port, `proxy-status` shows the actual port — adjust the command to match.

---

## Next →

- **[Install Claude Code](install-claude.md)** (then optionally **[Codex](install-codex.md)**) — sign-in goes through this proxy, so it comes *after* this page.
- Something not working? → **[Troubleshooting](troubleshooting.md)** (start with `proxy-doctor`)
- Don't want a profile at all? → **[Manual — no profile](proxy-manual.md)**
