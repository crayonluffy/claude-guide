# Proxy — One-Command Setup (profile)

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

## Recovery while Claude or Codex is running

All terminals use **one recovery owner for each user** (2.8.0+). The owner writes a record of the tunnel that it runs (the server, user, key and ports). Each terminal uses this record. Thus a window with old settings uses the tunnel that runs. It does not start a second tunnel on the same ports.

**While a `cc` or `cx` session is open:**

- The owner examines the two providers about each five seconds (plus the time of the check).
- If the SSH process stops, the owner starts it again.
- After two tunnel failures in sequence, the owner restarts its own SSH process.
- The owner keeps the same HTTP and SOCKS ports.

**When no session is open,** the owner examines the tunnel one time each minute (`WATCHDOG_IDLE_INTERVAL`). Chrome can still use the tunnel. When `cc` or `cx` starts, the owner examines the tunnel at once.

When SSH stops, the owner reads the cause from the error output of SSH. It tells you the fix in the terminal that started the tunnel, one time in each open session, in `proxy-status`, and in the log:

| Cause | What you see | What to do |
|---|---|---|
| `auth` | `SSH login to <server> was refused` | Load your key (`ssh-add <key>`) or examine the user name. Then type `proxy-restart`. The owner tries again only each `WATCHDOG_MAX_BACKOFF` seconds. |
| `hostkey` | `The host key of <server> changed` | If your admin expected this: type `ssh-keygen -R <server>`, then `ssh <server>` one time. |
| `forward` | `A tunnel port is held by another program` | Type `proxy-status`. |
| `network` | `Cannot reach <server>` | You do not have to do anything. The owner continues to try (a changed Wi-Fi, sleep mode, or a server that is down). |

Before `cc` and `cx` start the application, an HTTPS connection through the HTTP proxy must work. `--no-verify` / `-NoVerify` does not skip this check. It skips only the optional check of the external IP address. An API error after a good CONNECT and TLS handshake counts as a working connection. The check does not send API credentials.

If a different program uses a tunnel port, the profile reports a `conflict`. The recovery waits. It does not change the port and it does not stop the other program. If a different program takes a proxy port **while the tunnel is down**, Claude or Codex can send traffic to that program. Thus the owner shows one special alert in each open session, in the log, and on the desktop: `Another program (<name>, PID <pid>) took proxy port <port> while the tunnel was down ... exit this session now; nothing was stopped.` The owner does not stop that program. When the port is free, the recovery continues automatically.

During an outage, each `cc` or `cx` terminal shows a warning. After 60 seconds, the terminal shows one more warning that the session stays open. Then the owner continues to try, and shows progress notices from time to time. The owner does not close the application, does not send input to it, and does not change its proxy settings. You can stop the application in the usual way and continue later. The recovery does not make sure that the application sends a failed request again. If necessary, send the request again. If you start an application by hand after `proxy-up`, the recovery works, but the session does not get warnings.

To see the two possible results without a real outage:

```sh
proxy-test recover --fast
proxy-test prolonged --fast
```

PowerShell also accepts `-Fast`. Each line shows `[SIMULATION]`. 60 simulated seconds take six real seconds. The demonstration uses only data in memory. It does not touch the real SSH, an application, the settings, or the files of the owner. `Ctrl+C` stops it without an effect on real sessions. Without `--fast`, the demonstration uses the normal times.

`proxy-status` shows the status of each provider, the duration of an outage, and the number of tries. It also shows the ports, the sessions, and the locations of the logs. Bash also writes events to `CLAUDE_TUNNEL_LOG`. PowerShell writes `events.log` in its recovery folder, and the SSH errors in `ssh.err`. These records stay available if the application covers a warning on the screen. The recovery state is private. It is in `${XDG_STATE_HOME:-$HOME/.local/state}/claude-proxy/recovery/main` (Bash) and `$HOME/.claude-proxy/recovery/main` (PowerShell). The folder contains the tunnel record, the last SSH errors (`ssh.err`) and one entry for each open session.

| Setting (PowerShell) | Bash setting | Default |
|---|---|---|
| `TUNNEL_WATCHDOG` | `CLAUDE_TUNNEL_WATCHDOG` | `1` (on) |
| `WATCHDOG_INTERVAL` | `CLAUDE_WATCHDOG_INTERVAL` | `5` seconds |
| `WATCHDOG_IDLE_INTERVAL` | `CLAUDE_WATCHDOG_IDLE_INTERVAL` | `60` seconds while no `cc` or `cx` session is open |
| `WATCHDOG_FAILS` | `CLAUDE_WATCHDOG_FAILS` | `2` checks |
| `WATCHDOG_NOTICE_AFTER` | `CLAUDE_WATCHDOG_NOTICE_AFTER` | `60` seconds |
| `WATCHDOG_PROBE_TIMEOUT` | `CLAUDE_WATCHDOG_PROBE_TIMEOUT` | `3` seconds for each check |
| `WATCHDOG_PROGRESS_INTERVAL` | `CLAUDE_WATCHDOG_PROGRESS_INTERVAL` | `30` seconds |
| `WATCHDOG_MAX_BACKOFF` | `CLAUDE_WATCHDOG_MAX_BACKOFF` | `30` seconds |
| `WATCHDOG_STARTUP_GRACE` | `CLAUDE_WATCHDOG_STARTUP_GRACE` | `20` seconds. A new SSH connection gets this time before failed checks count. |

- To change a setting, use `proxy-config`. Your old values for intervals and failure counts stay.
- The time between tries starts at two seconds and doubles until it gets to the maximum.
- If the recovery is off, `cc` and `cx` tell you at the start.
- The background SSH uses `BatchMode=yes`. Load keys that have a passphrase into your SSH agent first.
- The next `cc`, `cx` or `tunnel-start` replaces a tunnel from an older profile automatically, on the same ports. Open sessions connect again in a few seconds. The profile does not touch a program on the ports that is not SSH.
- Bash makes sure that the old watchdog is the parent of the tunnel SSH before it stops it. If this is not possible, stop the watchdog from the old shell and try again.
- `tunnel-stop` stops the owner from each terminal. After that, the tunnel stays stopped.
- A restart keeps the proxy settings and the Claude settings.

Bash uses `/proc/uptime` on Linux, or `osascript` and the system uptime on macOS. PowerShell uses the .NET Stopwatch to measure time. The tests include Bash, zsh and PowerShell 7 on Linux with simulated SSH and connections, and an end-to-end run with a real SSH server (`tests/e2e/run.sh`). Windows PowerShell 5.1 with OpenSSH, and the macOS console, still need manual tests.

## Kill switch (2.9.0+)

The kill switch keeps Claude and Codex from connecting directly. When the tunnel is down, they cannot connect. They do not use your own IP address. The kill switch is on by default.

What the kill switch does:

1. It keeps the proxy in Claude's `~/.claude/settings.json`. `proxy-off` and `cc-stop` remove the proxy from your terminal only. Claude reads its settings file before your terminal, so plain `claude` and the IDE extensions use the tunnel. If the tunnel is down, they show "connection refused".
2. It examines each `cc` and `cx` before the start. It stops the start and tells you the fix if:
   - `NO_PROXY` sends an API host directly (for example `*` or `*.com`).
   - Another program uses the proxy port.
   - The profile cannot write the proxy into Claude's settings file.
3. It does not move the tunnel to a different port. If another program uses the proxy port, `tunnel-start` stops and tells you the program and the fix.

Plain `codex` reads only the proxy in your terminal. To protect it, type `proxy-config set PLAIN_COMMANDS auto`. Then plain `claude` and `codex` start through the tunnel, the same as `cc-safe` and `cx-safe`. Only the application writes to the output, so `claude -p "..." | jq` continues to work.

| Command | What it does |
|---|---|
| `proxy-killswitch` | Shows the status: Claude settings, Codex, `NO_PROXY`. |
| `proxy-killswitch on` | Sets the kill switch on and writes the proxy into Claude's settings. |
| `proxy-killswitch off` | Sets the kill switch off. This is the behavior before 2.9.0. |

The kill switch does not protect the Claude Desktop app, web browsers, or other applications. `chrome-proxy` has its own rules. The kill switch is not a firewall: a program that ignores proxy settings can still connect directly.

| Setting (PowerShell) | Bash setting | Default |
|---|---|---|
| `KILLSWITCH` | `CLAUDE_KILLSWITCH` | `on` (all values other than `off` mean on) |
| `PLAIN_COMMANDS` | `CLAUDE_PLAIN_COMMANDS` | `off`. The setup wizard asks. |

## Desktop alerts while the CLI owns the terminal

From PowerShell 2.6.0 and Bash 2.7.0, the profile shows desktop alerts. Thus a Codex or Claude screen cannot hide the only warning. One shared tunnel owner sends the alerts. More `cc` or `cx` tabs do not make more alerts.

| Condition | Alert | What to do |
|---|---|---|
| The first check fails | **Proxy connection lost**: the owner connects again; the sessions stay open | Wait. |
| The tunnel is still down after the limit (default 60 seconds) | **Proxy still unavailable**: the owner continues to try | Wait, or stop the application in the usual way. |
| All affected providers work again | **Proxy connection restored**: send a failed request again if necessary | Continue your work. |

The owner collects the Claude and Codex failures into one desktop outage. If only one provider works again, there is no "restored" alert. The outage timer does not start again, and the long-outage warning does not show again. The progress of the tries shows only in the terminal and the log. It does not make a desktop alert at each check. An alert does not take the focus, does not open a dialog, does not send keys, and does not stop a session.

| Platform | Desktop alert | Availability |
|---|---|---|
| Windows PowerShell / pwsh | A Windows taskbar notification with a tray icon: a warning while the owner connects, information after the restore | Uses .NET WinForms. You do not need the BurntToast module. The icon shows after the first alert and goes away when its owner stops. |
| macOS Bash / zsh | A Notification Center banner through `osascript` | The notification permissions and the Focus settings of the user apply. |
| Linux Bash | A desktop notification through `notify-send` | Needs the libnotify client, a session D-Bus and a notification service. |
| Headless SSH / WSL without a desktop notification service | Terminal warnings, status and logs | Cannot show an alert on the computer only because it opened the SSH connection. On Windows, use the Windows profile for desktop alerts. |

Windows uses the [NotifyIcon taskbar notification API](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.notifyicon.showballoontip). macOS uses the [scripted Notification Center interface](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/DisplayNotifications.html) of Apple. Linux uses the [desktop notification service model](https://specifications.freedesktop.org/notification/latest-single/).

- The accessibility settings and the notification settings of Windows control if and how long an alert shows.
- Focus and Do Not Disturb can hide alerts.
- "Submitted" means that the operating system accepted the alert. It does not mean that you saw it.
- The tray icon is only an addition. Windows can hide it in the overflow area.

### Check visibility while `cx` is running

1. Keep `cx` open in one terminal.
2. In a second terminal with the new profile, type:

   ```sh
   proxy-notify status
   proxy-notify test
   ```

3. Make sure that you can see the alert while Codex stays open.

`test` sends one **[TEST]** desktop alert. It does not touch SSH, the network settings or the application. On Windows, it keeps its test tray icon for ten seconds, then removes it. If you do not see the alert, examine the notification permissions, Do Not Disturb, and if the shell has a desktop session. `status` shows the selected adapter and the last result of the owner. The selected adapter alone does not show that a notification service is available.

To see the three alerts without a real outage:

```sh
proxy-test prolonged --fast --desktop
```

PowerShell also accepts `-Fast -Desktop`. These alerts show **[SIMULATION]**. This command sends real desktop alerts, but all proxy, network and session actions are simulated. Windows waits ten more seconds for the last alert before it removes the test icon. `Ctrl+C` stops only the notifier of the demonstration. Without `--desktop`, the simulation sends no desktop alerts and does not touch the owner.

### Settings and updating an existing owner

Desktop alerts are `auto` by default. To set them off:

```powershell
proxy-config set DESKTOP_NOTIFICATIONS off
```

```bash
proxy-config set DESKTOP_NOTIFICATIONS off
```

Bash saves this as `CLAUDE_DESKTOP_NOTIFICATIONS=off`. PowerShell saves `DESKTOP_NOTIFICATIONS = 'off'`. To set them on again, use `auto`. Then load the profile again and type `proxy-restart` one time, so that a running owner uses the new setting. This keeps the proxy settings and keeps the sessions open, but you possibly must send requests again. The terminal warnings and the logs stay on when the desktop alerts are off or fail.

The automated tests examine the alert sequence, the command arguments, failed alerts, the cleanup of the notifier, and the isolation of the demonstration. The real display on Windows and macOS, and the Windows tray icon, need the manual check above.

## The commands you get

| Command | What it does |
|---------|--------------|
| `cc` | Proxy ON, then starts **Claude** (`--dangerously-skip-permissions`). It repairs the tunnel: it stops an old `ssh` and starts a new one. If a different program uses the port, `cc` stops and tells you the fix (kill switch on). With the kill switch off, it uses the next free port. |
| `cc -c` / `cc -r` | The same, but **continues** the last Claude session, or **shows a list** of sessions. All arguments after `cc` go to `claude` (`cc --resume <id>`, `cc "fix the tests"`, …). |
| `cc-safe` | The same as `cc`, but Claude asks for permission (it accepts the same arguments). |
| `cx` | Proxy ON, then starts **Codex** (no approval prompts). Arguments go to Codex: `cx resume`. |
| `cx-safe` | The same, but Codex asks for approval. |
| `proxy-up` | Proxy ON (tunnel, proxy settings, IP check), but it does not start an application. |
| `proxy-restart` | Replaces the tunnel for **all** terminal windows if it does not work. It does not change the proxy settings or `settings.json`, so Claude and Codex in other tabs continue. |
| `cc-stop` | Proxy OFF for `cc` and `cx`. It stops each **ssh** on the tunnel ports (other programs stay) and tells you the result. It refuses while Claude or Codex runs in a different window (they use the same tunnel). Use `proxy-restart`, or `cc-stop --force`. |
| `proxy-notify status` / `proxy-notify test` | Shows if desktop alerts are available / sends one real test alert. It does not change the proxy. |
| `proxy-test prolonged --fast --desktop` | Shows the desktop alerts of an outage and a restore, with simulated network actions. |
| `proxy-status` | Shows what runs, and your current external IP address. |
| `proxy-doctor` | Examines each part (tunnel, ports, proxy settings, Claude settings, kill switch, API connection) and tells you each problem and its fix. |
| `proxy-killswitch` | Shows the kill switch. `proxy-killswitch on` / `off` changes it. Refer to [Kill switch](#kill-switch-290). |
| `cc-install` | Examines **Node.js**, **Claude Code** and **Codex**. It installs or updates the missing or old ones (it asks first; the downloads go through the proxy). `cc-install --check` (`-Check`) only reports. `cc-install claude` does only that tool. `-y` answers yes. The setup wizard runs it as its last step. |
| `tunnel-start` / `tunnel-stop` | Starts or stops only the SSH tunnel. |
| `proxy-on` / `proxy-off` | Sets or clears the proxy settings in the terminal. With the kill switch on, `~/.claude/settings.json` keeps the proxy. |
| `proxy-config` | Shows your settings. `proxy-config edit` opens the settings file. `proxy-config set SSH_HOST myvm` changes one value. |
| `proxy-update` | Downloads the newest profile from this guide and installs it. **Your settings stay.** `proxy-update --check` (`-Check` on Windows) only tells you if a newer profile is available. |
| `proxy-nodes` | Shows the nodes (JP / JP2 / SG / US …) and the active node. `proxy-nodes --refresh` (`-Refresh` on Windows) gets the catalogue again and makes the `ssh` aliases. `proxy-nodes --from jpvpn` (`-From`) gets the list privately from one of your VMs over SSH (`--domain` / `-Domain`: public DNS). Refer to [Nodes](proxy-nodes.md). |
| `proxy-node sg` | Makes `sg` the node that `cc` and `cx` use (restarts the tunnel if it is up). Short form: `cc --node sg`. |
| `chrome-proxy` | Opens Chrome through the SOCKS5 proxy (a separate profile; it starts the tunnel if necessary). `chrome-proxy sg` opens Chrome through node `sg` on its **own** tunnel and profile, so more regions can be open at the same time. `chrome-proxy sg https://…` also opens a URL. `chrome-proxy jp --profile work` (`-Profile` on Windows) opens a different Chrome profile through the same node. |
| `chrome-profiles` | Shows the Chrome profiles of all nodes (`chrome-profiles jp`: only the profiles of `jp`). |
| `cc-help` | Shows this list. (A new shell shows only one line: "claude-proxy v… ready". `BANNER=0` in the settings file stops it.) |

> **Codex note:** Codex reads the standard `HTTP(S)_PROXY` settings of the terminal, so it uses the same tunnel. It does not read a settings file. Plain `codex` uses the tunnel only with `PLAIN_COMMANDS=auto`. Claude also gets the proxy in `settings.json`, so plain `claude` uses the tunnel from all shells.

---

## 🪟 Windows

### Step 1 — Put your SSH key in Downloads

Download your private key file (the filename is not important) into your **Downloads** folder. The wizard finds it there automatically.

### Step 2 — Run the setup wizard

Paste this into **PowerShell**:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

The wizard asks for your server, user and alias. Then it:

- installs and locks the key,
- writes the `~/.ssh/config` alias (then `ssh jpvpn` works),
- saves your settings in `~\.claude-proxy.conf.psd1`, with the kill switch on,
- asks if plain `claude` and `codex` must also start through the proxy,
- installs the `cc`/`cx` profile,
- tests the connection.

If you already did the setup, run the same command again. It finds your settings and asks **"Keep these settings and only update the cc/cx profile?"**. Push Enter. You get the newest profile and you do not type anything again.

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

**✅ Check:** `proxy-up`, `cc` and `cx` show your external IP address. It must be the IP address of the **VM**, not your own. If something is not correct, type `proxy-doctor`.

The tunnel works. **Next: [install Claude Code](install-claude.md)** (and, if you want, [Codex](install-codex.md)). Their sign-in goes through this proxy, so keep it up. To set up the proxy **by hand**, refer to [Set up by hand — Windows](#set-up-by-hand--windows) below.

---

## 🍎 macOS / 🐧 Linux

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
- writes the `~/.ssh/config` alias (then `ssh jpvpn` works),
- saves your settings in `~/.claude-proxy.conf`, with the kill switch on,
- asks if plain `claude` and `codex` must also start through the proxy,
- adds the `cc`/`cx` profile to your shell startup file,
- tests the connection.

If you already did the setup, run the same command again. It finds your settings and asks **"Keep these settings and only update the cc/cx profile?"**. Push Enter. You get the newest profile and you do not type anything again. (To skip that question too, add `--update`: `bash <(curl -fsSL …/setup.sh) --update`.)

**✅ Check:** the wizard ends with `[OK] SSH connection works.` and `Done!`.

### Step 3 — Use it

```bash
source ~/.zshrc   # or ~/.bashrc - only the first time; new terminals load it automatically

proxy-up  # proxy ON (start here if Claude or Codex is not installed yet)
cc        # proxy ON + start Claude
cx        # proxy ON + start Codex
cc-stop   # proxy OFF (both)
```

**✅ Check:** `proxy-up`, `cc` and `cx` show your external IP address. It must be the IP address of the **VM**, not your own. If something is not correct, type `proxy-doctor`.

The tunnel works. **Next: [install Claude Code](install-claude.md)** (and, if you want, [Codex](install-codex.md)). Their sign-in goes through this proxy, so keep it up. To set up the proxy **by hand**, refer to [Set up by hand — macOS / Linux](#set-up-by-hand--macos--linux) below.

---

## 🐧 WSL (Windows Subsystem for Linux)

If you work in **WSL** (Ubuntu) on Windows, do the **macOS / Linux** steps above *in the WSL terminal*. (WSL is the recommended way to run Codex on Windows.) You do not have to install anything on the Windows side. The differences are:

- **Key:** download it with your Windows browser. The wizard also looks in your **Windows** Downloads folder (`C:\Users\<you>\Downloads`). It copies the key into `~/.ssh` in WSL. (ssh does not use a key directly from `/mnt/c`, because there all files look readable by all users.)
- **Claude and Codex** are installed *in* WSL (Node.js in WSL, then `npm install -g …` as in [Install Claude Code](install-claude.md)). `cc` and `cx` start them there.
- **Passphrase:** WSL does not keep an ssh-agent between terminals. A key *with* a passphrase would block the background tunnel. The profile starts an agent and loads the key for you. If the tunnel still does not start, type `ssh-add ~/.ssh/<your-key>` one time in that terminal (or use a key without a passphrase).
- **Chrome:** `chrome-proxy` finds **Windows** Chrome in `/mnt/c` and starts it through the tunnel. WSL2 forwards the `127.0.0.1` ports to Windows automatically.
- **Claude on Windows too:** Windows can use the tunnel at `http://127.0.0.1:8080`. Thus Claude Code in *Windows* PowerShell can also use it. Type `proxy-config set SYNC_WINDOWS_SETTINGS 1`. Then the profile also writes the proxy into the Windows `%USERPROFILE%\.claude\settings.json`, the same as for WSL. With the kill switch on, the profile keeps it there. This needs the default `localhostForwarding` of WSL2. `proxy-doctor` shows if this setting is on.

All other commands (`cc -c`, `proxy-update`, `proxy-config`, `proxy-doctor`) are the same as on Linux.

---

## 🔄 Updating the profile later

The profile contains **no personal settings**. They are in your settings file. Thus one command updates the profile, on all operating systems:

```bash
proxy-update            # download and install the newest profile; your settings stay
proxy-update --check    # only tell me if a newer profile is available   (Windows: proxy-update -Check)
```

Then open a new terminal (or type `source ~/.claude-proxy.sh` / `. "$HOME\.claude-proxy.ps1"`). The setup wizard does the same and also offers to keep your settings. If your profile is older than 2.0 and has no `proxy-update`, run the wizard one time. It reads the settings from the old profile. On Windows, it also moves the profile from `$PROFILE` to `~\.claude-proxy.ps1` and leaves a loader line. Thus a locked Documents folder does not block later updates.

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

The profile reads the connection from your `jpvpn` alias (step 1). Thus the settings file only points to it. You do not type the key, user or host again. The table shows all the keys of the settings file. A key that you do not write keeps its default value. `proxy-config` shows the current values. `proxy-config set KEY VALUE` changes one value.

| Key | Default | Meaning |
|-----|---------|---------|
| `SSH_HOST` | `'jpvpn'` | The alias from step 1, or a host name or IP address. |
| `SSH_USER` / `SSH_KEY` | `''` | Only when `SSH_HOST` is a host, not an alias. |
| `SSH_PORT` | `22` | |
| `HTTP_PORT` | `8080` | The local HTTP port. The tunnel forwards it to the VM proxy (Claude and Codex). |
| `REMOTE_PROXY_PORT` | `8888` | The tinyproxy port on the VM (webproxy-manager). |
| `SOCKS_PORT` | `1080` | The local SOCKS5 port (Chrome and other applications). |
| `NODE_SOCKS_BASE` | `1180` | The first port for the Chrome tunnels of the nodes (`chrome-proxy <node>`). Refer to [Nodes](proxy-nodes.md). |
| `NODES_FROM` | `''` | The VM that gives the node list over SSH (`proxy-nodes -From` sets it). Refer to [Nodes](proxy-nodes.md). |
| `PROXY_DOMAIN` | `''` | Get the node list from the public DNS of this domain (`proxy-nodes -Domain` sets it). |
| `CHROME_EXE` | `''` | Set it only if `chrome.exe` is not in Program Files or `%LOCALAPPDATA%`. |
| `SYNC_SETTINGS` | `1` | Also write the proxy into `~/.claude/settings.json`. `0` stops this. |
| `KILLSWITCH` | `'on'` | Claude and Codex cannot connect directly. Refer to [Kill switch](#kill-switch-290). |
| `PLAIN_COMMANDS` | `'off'` | `'auto'`: plain `claude` and `codex` also start through the tunnel. |
| `NO_PROXY_EXTRA` | `''` | Company intranet ranges or domains that do not use the proxy, for example `'172.20.0.0/24,*.mycorp.example'`. Do not add an API host. |
| `BANNER` | `1` | One line when a new window opens. `0` stops it. |

📄 The full profile is in the repository: [`scripts/claude-proxy.ps1`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/claude-proxy.ps1). The download command above gets this file.

> **⚠️ Caution: encoding (Traditional Chinese Windows):** Notepad on a zh-TW system often saves files as **Big5 / CP950**. This damages the script and causes parse errors. Edit the profile in **VS Code** or **Notepad++** and save it as **UTF-8**. (The published script contains only ASCII characters. Thus all editors are safe if you do not add other characters.)

### Step 3 — First connection

The first time, SSH asks `Are you sure you want to continue connecting (yes/no)?`. The background tunnel cannot answer. Thus type this **one time** and answer `yes`:

```powershell
ssh jpvpn
```

Then use `cc` and `cx` as usual.

---

## Set up by hand — macOS / Linux

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

The table shows all the keys of the settings file. A key that you do not write keeps its default value. `proxy-config` shows the current values. `proxy-config set KEY VALUE` changes one value. `proxy-config edit` opens the file.

| Key | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_SSH_HOST` | `"jpvpn"` | The alias from step 1, or a host name or IP address. |
| `CLAUDE_SSH_USER` / `CLAUDE_SSH_KEY` | `""` | Only when `CLAUDE_SSH_HOST` is a host, not an alias. |
| `CLAUDE_SSH_PORT` | `22` | |
| `CLAUDE_HTTP_PORT` | `8080` | The local HTTP port. The tunnel forwards it to the VM proxy (Claude and Codex). |
| `CLAUDE_REMOTE_PROXY_PORT` | `8888` | The tinyproxy port on the VM (webproxy-manager). |
| `CLAUDE_SOCKS_PORT` | `1080` | The local SOCKS5 port (Chrome and other applications). |
| `CLAUDE_NODE_SOCKS_BASE` | `1180` | The first port for the Chrome tunnels of the nodes (`chrome-proxy <node>`). Refer to [Nodes](proxy-nodes.md). |
| `CLAUDE_NODES_FROM` | `""` | The VM that gives the node list over SSH (`proxy-nodes --from` sets it). Refer to [Nodes](proxy-nodes.md). |
| `CLAUDE_PROXY_DOMAIN` | `""` | Get the node list from the public DNS of this domain (`proxy-nodes --domain` sets it). |
| `CLAUDE_CHROME_BIN` | `""` | Set it only if Chrome is not in the usual location (macOS: the application name or path; WSL: `/mnt/c/.../chrome.exe`). |
| `CLAUDE_SYNC_SETTINGS` | `1` | Also write the proxy into `~/.claude/settings.json` (needs `jq`). `0` stops this. |
| `CLAUDE_SYNC_WINDOWS_SETTINGS` | `0` | **WSL only:** `1` also writes the proxy into the settings of Claude on *Windows* (`%USERPROFILE%\.claude\settings.json`). Refer to [WSL](#-wsl-windows-subsystem-for-linux). |
| `CLAUDE_KILLSWITCH` | `on` | Claude and Codex cannot connect directly. Refer to [Kill switch](#kill-switch-290). |
| `CLAUDE_PLAIN_COMMANDS` | `off` | `auto`: plain `claude` and `codex` also start through the tunnel. |
| `CLAUDE_NO_PROXY` | private ranges, `*.local`, … | The hosts that do not use the proxy. To add more: `CLAUDE_NO_PROXY="$CLAUDE_NO_PROXY,172.20.0.0/24,*.mycorp.example"`. Do not add an API host. |
| `CLAUDE_PROXY_BANNER` | `1` | One line when a new shell opens. `0` stops it. |

### Step 3 — First connection

Accept the host key one time:

```bash
ssh jpvpn
```

Type `yes` when SSH asks, then exit. Now use `cc` and `cx` as usual.

---

## 🔁 Changing your server or user later

Your `jpvpn` alias is in `~/.ssh/config`. Thus `ssh jpvpn`, `cc` and `cx` need no key path, user or host. The setup made the alias. If your server IP address or user changes, edit that file. Or run the wizard again, answer **n** to "keep these settings", push Enter for the values that stay, and type only the values that changed.

```
Host jpvpn
    HostName <your-host-or-ip>
    User <your-ssh-user>
    IdentityFile ~/.ssh/<your-key>
    AddKeysToAgent yes
    UseKeychain yes      # macOS only
```

To use a *different* alias, or to change a port, change the settings file: `proxy-config set SSH_HOST other-vm`, `proxy-config set REMOTE_PROXY_PORT 8899`, … If your admin publishes more nodes (JP / SG / US), `proxy-node sg` does this for you. Refer to **[Nodes](proxy-nodes.md)**.

---

## 🌐 (Optional) Browse through the proxy

With the profile installed, type **`chrome-proxy`**. It opens a **separate** Chrome through the **SOCKS5** proxy on `127.0.0.1:1080`. Your normal browser does not change. `chrome-proxy` starts the tunnel if necessary. It uses a separate `--user-data-dir` (separate logins, cookies and history). It sends the DNS lookups through the tunnel (no DNS leaks). In WSL, it starts **Windows** Chrome.

- **More regions at the same time:** `chrome-proxy jp`, `chrome-proxy sg`, … each open a Chrome through that node, on its own tunnel and data folder.
- **More accounts on the same node:** `chrome-proxy jp --profile work`. Refer to **[Nodes](proxy-nodes.md)**.

Without the profile, use these commands. The **tunnel must be up** first (`proxy-up`, or the manual step 1 `ssh` command, which gives the `-D 1080` SOCKS forward):

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

**🐧 Linux** (if you do not have `google-chrome`, use `chromium`)

```bash
google-chrome \
    --proxy-server="socks5://127.0.0.1:1080" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
    --user-data-dir="$HOME/.config/google-chrome-vpn" --no-first-run &
```

**🐧 WSL:** use the **Windows PowerShell** command above. WSL2 forwards `127.0.0.1:1080` to Windows automatically. (Or use `chrome-proxy`. It finds Windows Chrome for you.)

What the flags do:

- `--proxy-server` sends all traffic through the SOCKS5 forward.
- `--host-resolver-rules` also sends the **DNS** lookups through the tunnel (no DNS leaks).
- `--user-data-dir` keeps this Chrome a **separate profile**. Your normal browser does not change.

If you changed `SOCKS_PORT`, use that port in place of `1080`. `proxy-status` shows the port.

---

## Next

- **[Install Claude Code](install-claude.md)** (then, if you want, **[Codex](install-codex.md)**). The sign-in goes through this proxy, so do it *after* this page.
- Something does not work? Refer to **[Troubleshooting](troubleshooting.md)** (start with `proxy-doctor`).
- You do not want a profile? Refer to **[Manual — no profile](proxy-manual.md)**.
