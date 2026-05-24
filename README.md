# Claude via VM Proxy Guide

A minimal, copy-paste guide to connecting Anthropic's `claude` CLI through an SSH tunnel to a remote VM / proxy.

**How traffic flows once everything is running:**

```mermaid
flowchart LR
    claude([claude]) -->|HTTP :8080| bridge([bridge])
    bridge -->|SOCKS :1080| tunnel([tunnel])
    tunnel -->|SSH| vm([VM / proxy])
    vm --> api([Anthropic API])
```

After a one-time setup you just type **`cc`** and all of that happens automatically.

## ⚠️ Prerequisites

You need **Node.js** (it ships with `npm` and `npx`) and the **Claude Code CLI**.

**🍎 macOS — Homebrew**

If you don't have [Homebrew](https://brew.sh/) yet, install it first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install Node.js:

```bash
brew install node
```

**🐧 Linux — NodeSource**

NodeSource publishes up-to-date apt/dnf packages — see [github.com/nodesource/distributions](https://github.com/nodesource/distributions) for the current version (replace `lts` with e.g. `22.x` if you want a specific release).

```bash
# Debian / Ubuntu
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
```

```bash
# Fedora / RHEL / Rocky
curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
sudo dnf install -y nodejs
```

**🪟 Windows**

Use the official installer from [nodejs.org](https://nodejs.org/), or install from a terminal with `winget`:

```powershell
winget install OpenJS.NodeJS.LTS
```

> NodeSource only ships **Linux** (apt/dnf) packages — there's no Windows build there, so use the installer or `winget` above.

**Then install the Claude Code CLI** (any OS):

```bash
npm install -g @anthropic-ai/claude-code
```

Verify everything:

```bash
node --version
npm --version
claude --version
```

---

## 🚀 One-Command Setup — `cc` :id=one-command-setup

Set up a shell profile **once**, then a single **`cc`** command:

1. starts the **SSH tunnel** in the background (SOCKS5 on `127.0.0.1:1080`),
2. starts the **HTTP-to-SOCKS bridge** in the background (HTTP on `127.0.0.1:8080`),
3. sets the `HTTP(S)_PROXY` / `NO_PROXY` environment variables,
4. verifies your external IP, then launches **Claude**.

It reuses anything already running instead of starting duplicates, and `cc-stop` tears it all back down.

| Command | What it does |
|---------|--------------|
| `cc` | One-shot: tunnel + bridge + env vars + launch Claude (`--dangerously-skip-permissions`) |
| `cc-safe` | Same, but launches plain `claude` (keeps permission prompts) |
| `proxy-up` | Same setup as `cc` (tunnel + bridge + env vars + verify) but stops short of launching Claude |
| `cc-stop` | Stop tunnel + bridge and clear the proxy env vars |
| `proxy-status` | Show what's running and your current external IP |
| `tunnel-start` / `tunnel-stop` | Manage just the SSH tunnel |
| `bridge-start` / `bridge-stop` | Manage just the HTTP bridge |
| `proxy-on` / `proxy-off` | Set / clear the proxy env vars only |
| `chrome-proxy` | Open Chrome routed through the proxy (separate, isolated profile) |
| `cc-help` | Print this command list (it also prints when a new shell/profile loads) |

---

### 🪟 Windows

**Quick setup (recommended) — one interactive command.** Download your private key into your **Downloads** folder, then paste this into PowerShell. It prompts for your server, user, and alias, then installs and locks the key, writes the `~/.ssh/config` alias, installs the `cc` profile, and tests the connection:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

That's the whole setup — head straight to **Daily usage** below. Prefer to set it up by hand? See **Manual setup (fallback)** at the end of this section.

**Daily usage:**

```powershell
# Everyday — your on/off switch:
cc              # turn the proxy ON and launch Claude (skips permission prompts)
cc-safe         # same, but keeps Claude's permission prompts
proxy-up        # turn the proxy ON, but DON'T launch Claude
cc-stop         # turn the proxy OFF (stop everything)
proxy-status    # show what's running + your external IP

# Advanced — manage one piece at a time:
tunnel-start    # start the SSH tunnel only
tunnel-stop     # stop the SSH tunnel
bridge-start    # start the HTTP bridge only
bridge-stop     # stop the HTTP bridge
proxy-on        # set the proxy env vars only
proxy-off       # clear the proxy env vars only

chrome-proxy    # open Chrome routed through the proxy (separate profile)
cc-help         # print this list again (it also prints when you open a shell)
```

**Troubleshooting (Windows):**

| Symptom | Fix |
|---------|-----|
| `... is not digitally signed` / cannot load profile | Run `Unblock-File -Path $PROFILE`, then confirm `Get-ExecutionPolicy -Scope CurrentUser` is `RemoteSigned`. |
| Garbled characters / parse errors | The file was saved with the wrong encoding (Big5/CP950). Re-save as **UTF-8** (or keep it ASCII-only). |
| SSH hangs or `cc` returns immediately with no tunnel | First connection needs the host key accepted. Run `ssh jpvpn` once interactively, type `yes`, then retry. |
| `npx : The term 'npx' is not recognized` | Install **Node.js** from [nodejs.org](https://nodejs.org/) (gives you `npm` + `npx`). |
| Tunnel + bridge are up but Claude can't reach the API | Make sure your `NO_PROXY_LIST` does **not** include `api.anthropic.com` — that traffic must go *through* the proxy. |
| Setup looks wrong (bad alias, host, key, or profile) | Re-run the wizard to redo it cleanly: `irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 \| iex` |

<details>
<summary><b>Manual setup (fallback)</b> — set things up by hand instead of using the wizard above.</summary>

**Step 1 — Install your SSH key (run once, no admin).** Download your key (any filename) into your **Downloads** folder, fill in the first two lines, then paste the whole block. It finds the key, moves it into `~/.ssh`, locks the permissions, and writes an `~/.ssh/config` alias so you can connect with just `ssh jpvpn`.

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

**Step 2 — Install the `cc` profile.** Your PowerShell profile lives at `$PROFILE` (usually `C:\Users\<you>\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`).

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

The profile reads the connection from your `jpvpn` alias (Step 1), so the **Settings block** just points at it — no key/user/host to re-enter:

```powershell
$script:SSH_HOST    = "jpvpn"   # the alias from Step 1 (or a raw host/IP)
$script:SSH_USER    = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_KEY     = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_PORT    = 22
$script:SOCKS_PORT  = 1080
$script:HTTP_PORT   = 8080
# Add corporate intranet ranges to $script:NO_PROXY_LIST further down if needed.
```

> Not using an alias? Fill in `SSH_KEY`, `SSH_USER`, and `SSH_HOST` explicitly instead — the profile uses them when they're set.

📄 The full profile lives in the repo: [`scripts/Microsoft.PowerShell_profile.ps1`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/Microsoft.PowerShell_profile.ps1). The download command above pulls that exact file.

> **⚠️ Encoding gotcha (Traditional Chinese Windows):** Notepad on a zh-TW system often saves as
> **Big5 / CP950**, which corrupts the script and produces parse errors. To avoid this:
> - Edit the profile in **VS Code** or **Notepad++** and explicitly save as **UTF-8**, or
> - Write it from PowerShell with UTF-8: `Get-Content .\profile.ps1 | Set-Content -Path $PROFILE -Encoding UTF8`, or
> - Keep the profile **ASCII-only** (the published script already is) so any editor is safe.

> **First connection:** SSH will prompt `Are you sure you want to continue connecting (yes/no)?`
> the first time. The background tunnel can't answer that prompt, so run `ssh jpvpn` (or
> `ssh <user>@<host>`) **once** interactively to accept the host key, then use `cc`.

</details>

---

### 🍎 macOS / 🐧 Linux

Same idea, written for **zsh** (macOS default) or **bash** (most Linux). SSH is native (we background it with `ssh -f`), there's no execution-policy step, and ports are detected with `lsof`.

**Quick setup (recommended) — one interactive command.** Download your private key into your **Downloads** folder, then paste this into your terminal. It prompts for your server, user, and alias, then installs and locks the key, writes the `~/.ssh/config` alias (and macOS Keychain entry), installs the `cc` profile, and tests the connection:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
```

That's the whole setup — head straight to **Daily usage** below. Prefer to set it up by hand? See **Manual setup (fallback)** at the end of this section.

**Daily usage:**

```bash
# Everyday — your on/off switch:
cc              # turn the proxy ON and launch Claude (skips permission prompts)
cc-safe         # same, but keeps Claude's permission prompts
proxy-up        # turn the proxy ON, but DON'T launch Claude
cc-stop         # turn the proxy OFF (stop everything)
proxy-status    # show what's running + your external IP

# Advanced — manage one piece at a time:
tunnel-start    # start the SSH tunnel only
tunnel-stop     # stop the SSH tunnel
bridge-start    # start the HTTP bridge only
bridge-stop     # stop the HTTP bridge
proxy-on        # set the proxy env vars only
proxy-off       # clear the proxy env vars only

chrome-proxy    # open Chrome routed through the proxy (separate profile)
cc-help         # print this list again (it also prints when you open a shell)
```

**Troubleshooting (macOS / Linux):**

| Symptom | Fix |
|---------|-----|
| `lsof: command not found` (Linux) | Install it: `sudo apt install lsof` (Debian/Ubuntu) or `sudo dnf install lsof`. |
| Bridge never comes up | Check the log: `cat /tmp/claude-bridge.log`. Usually missing Node.js (`npx`) — install from [nodejs.org](https://nodejs.org/). |
| SSH keeps asking for the passphrase | Step 1 adds the key to the Keychain on macOS. To redo it: `ssh-add --apple-use-keychain ~/.ssh/<your-key>` (macOS) or `ssh-add ~/.ssh/<your-key>` (Linux). |
| `cc` exits before launching Claude | The tunnel/bridge didn't bind. Accept the host key once with `ssh <user>@<host>`, then retry. |
| Tunnel up but Claude can't reach the API | Confirm `CLAUDE_NO_PROXY` does **not** contain `api.anthropic.com`. |
| Setup looks wrong (bad alias, host, key, or profile) | Re-run the wizard to redo it cleanly: `bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)` |

<details>
<summary><b>Manual setup (fallback)</b> — set things up by hand instead of using the wizard above.</summary>

**Step 1 — Install your SSH key + create the `jpvpn` alias (run once).** Download your key (any filename) into your **Downloads** folder, fill in the first two lines, then paste. It moves the key into `~/.ssh`, locks it (`chmod 600`), writes an `~/.ssh/config` alias, and on macOS adds it to the Keychain so you aren't asked for the passphrase.

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

**Step 2 — Install the `cc` profile.**

```bash
# 1. Download the script to ~/.claude-proxy.sh
curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/claude-proxy.sh -o ~/.claude-proxy.sh

# 2. Source it from your shell rc so it loads in every new shell
echo 'source ~/.claude-proxy.sh' >> ~/.zshrc      # macOS (zsh)
# echo 'source ~/.claude-proxy.sh' >> ~/.bashrc   # Linux (bash)

# 3. Reload your shell
source ~/.zshrc      # or: source ~/.bashrc

# 4. First connection: accept the host key once
ssh jpvpn
```

📄 The full script lives in the repo: [`scripts/claude-proxy.sh`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.sh). The `curl` command above downloads that exact file.

It already points at the `jpvpn` alias from Step 1, so there's nothing to re-enter — the **Settings block** just confirms:

```bash
export CLAUDE_SSH_HOST="jpvpn"   # the alias from Step 1 (or a raw host/IP)
export CLAUDE_SSH_USER=""        # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_KEY=""         # leave blank when CLAUDE_SSH_HOST is a config alias
export CLAUDE_SSH_PORT=22
export CLAUDE_SOCKS_PORT=1080
export CLAUDE_HTTP_PORT=8080
# Append corporate intranet ranges to CLAUDE_NO_PROXY if needed.
```

> Not using an alias? Fill in `CLAUDE_SSH_KEY`, `CLAUDE_SSH_USER`, and `CLAUDE_SSH_HOST` explicitly instead.

</details>

---

### 🔁 Changing your server or user later

Your `jpvpn` alias lives in `~/.ssh/config` — that's why `ssh jpvpn` and `cc` need no key path, user, or host. Setup created it; edit that file if your server IP or user changes:

```
Host jpvpn
    HostName <your-host-or-ip>
    User <your-ssh-user>
    IdentityFile ~/.ssh/<your-key>
    AddKeysToAgent yes
    UseKeychain yes      # macOS only
```

---

## 🌐 (Optional) Browse Through the Proxy

With the profile installed, run **`chrome-proxy`** — it opens a **separate** Chrome routed through the proxy (Windows via the SOCKS tunnel on `127.0.0.1:1080`; macOS/Linux via the HTTP bridge on `127.0.0.1:8080`), without touching your normal browsing session.

> - The separate `--user-data-dir` keeps this profile's logins, cookies, and history isolated from your everyday Chrome.
> - To also route **DNS** through the tunnel on Windows (avoid DNS leaks), add `--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"` to the `chrome-proxy` command in the profile.

---

## 🧰 Manual Setup (no profile)

Prefer not to install a profile, or want to run/debug one piece at a time? These are the exact steps `cc` automates — keep each window/terminal open.

<details>
<summary>🪟 Windows — 3 PowerShell windows</summary>

Requires the SSH key + `jpvpn` alias from **Step 1** above.

**Window 1 — SSH tunnel (keep open):**
```powershell
ssh jpvpn -D 1080 -N -C
```

**Window 2 — bridge (keep open):**
```powershell
npx http-proxy-to-socks -p 8080 -s 127.0.0.1:1080
```

**Window 3 — run Claude:**
```powershell
$env:http_proxy="http://127.0.0.1:8080"
$env:HTTP_PROXY="http://127.0.0.1:8080"
$env:https_proxy="http://127.0.0.1:8080"
$env:HTTPS_PROXY="http://127.0.0.1:8080"

# Verify connectivity (optional)
curl.exe ipinfo.io

# Launch (skip permission prompts)
claude --dangerously-skip-permissions
```

</details>

<details>
<summary>🍎 macOS / 🐧 Linux — 3 terminals</summary>

**Terminal 1 — tunnel (keep open):**
```bash
ssh -i ~/.ssh/<your-key> -D 1080 -N -C <your-ssh-user>@<your-gcp-hostname>
```

**Terminal 2 — bridge (keep open):**
```bash
npx http-proxy-to-socks -p 8080 -s 127.0.0.1:1080
```

**Terminal 3 — run Claude:**
```bash
export http_proxy=http://127.0.0.1:8080
export HTTP_PROXY=http://127.0.0.1:8080
export https_proxy=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080
export NO_PROXY="localhost,127.0.0.1"   # add your corp intranet ranges here if needed

# Verify connectivity (optional)
curl ipinfo.io

# Launch (skip permission prompts)
claude --dangerously-skip-permissions
```

**Screenshots**

![Step 1 - SSH Tunnel](images/step1-ssh-tunnel.png)

![Step 2 - Bridge](images/step2-bridge.png)

![Step 3 - Run Claude](images/step3-run-claude.png)

</details>

---

## 📖 Useful Claude Code Commands & Tips

> Verified against Claude Code **v2.1.150** (May 2026). Check yours with `claude --version`, upgrade with `claude update`.

### CLI Flags

| Flag | Description |
|------|-------------|
| `claude` | Start an interactive session |
| `claude "query"` | Start with an initial prompt |
| `claude -c` | Continue the most recent conversation |
| `claude -r` | Resume a previous session (pick from a list) |
| `claude -p "query"` | Print mode — run non-interactively and exit |
| `claude --model sonnet` | Pick a model: `sonnet` / `opus` / `haiku`, or a full ID (`claude-opus-4-7`, `claude-sonnet-4-6`) |
| `claude --effort high` | Effort level: `low`, `medium`, `high`, `xhigh`, `max`, `auto` |
| `claude --permission-mode plan` | Start in a mode: `default`, `acceptEdits`, `plan`, `bypassPermissions` |
| `claude --dangerously-skip-permissions` | Skip all permission prompts |
| `claude -w` / `--worktree` | Run in an isolated git worktree |
| `claude --agent <name>` | Use a specific subagent for the main thread |
| `claude --max-turns 5` | Limit agentic turns (print mode) |
| `claude --verbose` | Enable verbose logging |
| `claude update` | Update to the latest version |
| `claude --version` | Show the version number |

### Slash Commands (Inside Interactive Mode)

| Command | Purpose |
|---------|---------|
| `/help` | Show help and available commands |
| `/clear` | Clear conversation history |
| `/compact` | Compact the conversation to free context |
| `/context` | Visualize context-window usage |
| `/cost` | Show token usage / cost (alias `/usage`) |
| `/model` | Change the model |
| `/effort` | Set the effort level |
| `/fast` | Toggle fast mode (faster Opus output) |
| `/config` | Open settings (alias `/settings`) |
| `/status` | Show version, model, account info |
| `/doctor` | Diagnose installation issues |
| `/memory` | Edit project CLAUDE.md |
| `/init` | Initialize the project with a CLAUDE.md |
| `/diff` | Review uncommitted changes |
| `/rewind` | Undo edits / restore a checkpoint (also `Esc Esc`) |
| `/plan` | Enter plan mode (analyze without executing) |
| `/resume` | Resume a previous session |
| `/fork` | Branch the current conversation |
| `/agents` | Manage subagents & background sessions |
| `/code-review` | Review the current diff for bugs (`--comment` posts to a PR) |
| `/ultrareview` | Multi-agent cloud review of the branch (or `/ultrareview <PR#>`) |
| `/run` · `/verify` | Launch & drive the real app to confirm a change works |
| `/export` | Export the conversation as text |
| `/copy` | Copy the last response to the clipboard |
| `/bug` | Submit feedback (alias `/feedback`) |

> Note: the standalone `/vim` command was removed — set Vim keys via `/config` → editor mode (or `"editorMode": "vim"` in settings.json).

**Automation & advanced** (newer; several are bundled skills — run `/help` to see what's installed on your version):

| Command | Purpose |
|---------|---------|
| `/goal [condition]` | Set a completion condition — Claude keeps working until it's met |
| `/batch <instruction>` | Split a large change into parallel units, each in its own worktree + PR |
| `/loop [interval] [cmd]` | Run a prompt/command repeatedly on an interval (or self-paced) |
| `/schedule` | Create / manage recurring scheduled agents (cron) |
| `/tasks` | List & manage background tasks |
| `/background` · `/bg` | Detach the current session as a background agent |
| `/autofix-pr [prompt]` | Watch a PR and auto-fix on CI failures / review comments |
| `/teleport` | Pull a claude.ai web session down into your terminal |
| `/remote-control` · `/rc` | Drive this terminal session from claude.ai |
| `/ultraplan` | Draft a plan in a cloud session, review it in the browser |
| `/security-review` | Security-focused review of the pending changes |
| `/tui [fullscreen]` | Switch the renderer (e.g. flicker-free fullscreen) |
| `/voice [hold\|tap\|off]` | Toggle voice dictation |
| `/team-onboarding` | Generate a team onboarding guide from your usage |

### Keyboard Shortcuts

| Shortcut | Description |
|----------|-------------|
| `Ctrl+C` | Cancel the current generation |
| `Esc` | Stop Claude mid-response |
| `Ctrl+D` | Exit Claude Code |
| `Ctrl+L` | Clear the terminal screen |
| `Ctrl+O` | Toggle the transcript view (full tool output) |
| `Shift+Tab` | Cycle permission modes (default → acceptEdits → plan → …) |
| `Esc Esc` | Open the rewind / checkpoint menu |
| `\ + Enter` | New line (also `Shift+Enter`) |
| `Ctrl+G` | Open the prompt in your `$EDITOR` |
| `Alt+P` | Switch model (Option+P on macOS) |
| `Alt+T` | Toggle extended thinking (Option+T on macOS) |
| `!` | Shell mode — run a command directly |
| `@` | File-path autocomplete |
| `/` | Slash-command / skills menu |

### Configuration

**Settings file locations:**
- **User:** `~/.claude/settings.json` (applies to all projects)
- **Project:** `.claude/settings.json` (shared with team)
- **Local:** `.claude/settings.local.json` (personal, gitignored)

**Example `settings.json`:**
```json
{
  "model": "claude-sonnet-4-6",
  "permissions": {
    "allow": ["Bash(npm run test *)", "Read"],
    "deny": ["Bash(curl *)"]
  },
  "attribution": {
    "commit": "",
    "pr": ""
  }
}
```

Current model IDs: `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5` — or use the aliases `opus` / `sonnet` / `haiku` to always track the latest.

**CLAUDE.md** — Create at project root to give Claude persistent context about your project (coding standards, architecture, common commands, etc.). It loads automatically when Claude starts.

### Tips

- Use `/compact` when context fills up (or rely on auto-compact) to free space
- Pipe files into Claude: `cat logs.txt | claude -p "summarize the errors"`
- Use `claude -p "query" | command` to feed Claude's output into other tools
- `Esc Esc` or `/rewind` to undo changes and restore a checkpoint
- `/diff` to review everything before committing
- `claude -w` to work in an isolated git worktree — great for parallel features
- `/fast` for snappier Opus output; `/effort` to dial reasoning up or down
- `/plan` to analyze safely without making changes
- Run `/doctor` if something isn't working right
