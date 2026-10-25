# 🔄 Updating & upgrading

## How to get the newest profile

The profile keeps your settings in a separate file: `~/.claude-proxy.conf` (macOS, Linux, WSL) or `~\.claude-proxy.conf.psd1` (Windows). An update does not change this file.

1. Type this command:

   ```bash
   proxy-update            # download and install the newest profile; your settings stay
   proxy-update --check    # only tell me if a newer profile is available (Windows: proxy-update -Check)
   ```

2. Open a new terminal window. Or load the profile again: `source ~/.claude-proxy.sh` (Windows: `. $PROFILE`).

You can also run the setup wizard again. It finds your settings and asks *"Keep these settings and only update the cc/cx profile?"*.

**Your profile is older than 2.0** (there is no `proxy-update` command, and the settings are inside the script):

1. Run the wizard one time:

   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)   # macOS / Linux / WSL
   ```

   ```powershell
   irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex           # Windows
   ```

2. The wizard reads the settings from the old profile, saves them in the settings file, and installs the new profile. It keeps the old profile as `.bak`.

On Windows, the profile moves from `$PROFILE` (Documents) to `~\.claude-proxy.ps1`. `$PROFILE` keeps only one loader line. If Documents is locked, the wizard makes a shortcut on the Desktop.

---

## Version history

### 2.9.0 (Windows, macOS, Linux, WSL): kill switch

Claude and Codex do not connect directly any more. When the tunnel is down, they cannot connect.

- **Claude keeps the proxy.** The profile keeps the proxy in Claude's `settings.json`. `proxy-off` and `cc-stop` do not remove it. Plain `claude` and the IDE extensions use the tunnel. If the tunnel is down, they show "connection refused". To start the tunnel, type `cc` or `proxy-up`.
- **`cc` and `cx` examine the setup before they start.** They stop and tell you the fix if `NO_PROXY` sends an API host directly. They also stop if another program uses the proxy port.
- **The tunnel does not move to a different port.** If another program uses the proxy port, `tunnel-start` stops and tells you the fix.
- **Optional: plain `claude` and `codex` through the tunnel.** Type `proxy-config set PLAIN_COMMANDS auto`. The setup wizard asks new users.
- **New command:** `proxy-killswitch` shows the status.

The kill switch is on after the update. To use the behavior from before 2.9.0, type `proxy-killswitch off`.

Type `proxy-update` and open a new terminal window. Version tags: `powershell-v2.9.0` and `bash-v2.9.0`.

### 2.8.0 (Windows, macOS, Linux, WSL): one self-healing tunnel, clearer errors

- **One recovery owner for each user.** All terminals use the same tunnel. This is also true for a terminal with old settings. `tunnel-start` and `tunnel-stop` work from each terminal. After `tunnel-stop`, the tunnel stays stopped.
- **The upgrade is automatic.** The next `cc`, `cx` or `tunnel-start` replaces a tunnel from an older profile. It uses the same ports. Open sessions connect again in a few seconds. You do not have to type `proxy-restart`.
- **SSH errors have an explanation.** `tunnel-start`, `proxy-status` and each open session show the cause and the fix: a refused login, a changed host key, a port in use, or a server that does not answer. After a refused login, the profile tries again only each 30 seconds.
- **Fewer checks when you do not use the tunnel.** With no `cc` or `cx` open, the profile examines the tunnel each minute (`WATCHDOG_IDLE_INTERVAL`). When you start `cc` or `cx`, it examines the tunnel at once.
- **Port takeover alert.** Another program can start to use the proxy port while the tunnel is down. Then each session and the desktop show one alert with the name of the program. Stop the session. The profile does not stop any program.
- `cc-stop` also counts open `cc` and `cx` sessions. (On Windows, Claude from npm runs as `node.exe`. Older profiles did not see it.)
- Windows: `proxy-status` is easier to read. The background owner runs in PowerShell, not in the ISE. `tunnel-start` tells you if `ssh` is not installed.
- macOS, Linux, WSL: the profile works without `lsof` when `ss` is installed. A stopped `ssh` cannot stop the recovery any more.

Type `proxy-update` and open a new terminal window. Version tags: `powershell-v2.8.0` and `bash-v2.8.0`.

### 2.7.1 (Windows, macOS, Linux, WSL): `cc` and `cx` start again on Windows

From 2.7.1, the Windows profile and the macOS/Linux/WSL profile have ONE version number. The same number means the same features on all platforms.

The Windows profile 2.6.0 did not start Claude or Codex. The new connection check gave curl an option that curl does not accept. Thus each check failed with "transport unavailable". The same bug made the background recovery restart a good tunnel each few seconds, and show "connection lost" alerts. These problems are also corrected:

- One error in the background monitor (for example, a file that antivirus locks for a short time) does not stop the recovery permanently.
- The profile does not report a slow tunnel as lost. It does not stop and restart the tunnel before the tunnel can start (Windows, macOS, Linux, WSL). The "connection lost" and "restored" alerts at each start do not occur any more.
- macOS, Linux, WSL: when the tunnel does not start, the profile shows the newest lines of the log (before, it showed the oldest lines).

Type `proxy-update`, open a new terminal window, then type `proxy-restart` one time. Version tags: `powershell-v2.7.1` and `bash-v2.7.1`.

### PowerShell 2.6.0 / Bash 2.7.0: desktop alerts

This version adds desktop alerts for a lost connection, a long outage, and a restored connection. The alerts show while `cc` or `cx` stays in the foreground. The shared owner collects the failures of the two providers, so you do not get the same alert in each terminal tab. Windows uses a tray notification, macOS uses Notification Center, and Linux uses `notify-send`.

1. Update and load your profile again.
2. Type `proxy-restart` one time, so that the current owner uses the alerts.
3. Keep `cx` open. In a different terminal, type `proxy-notify test`. Make sure that you see the alert.

To see all alerts without a real outage, type `proxy-test prolonged --fast --desktop`. To stop the desktop alerts, set `DESKTOP_NOTIFICATIONS=off`. The terminal and the log continue to show the events.

Tags: `powershell-v2.6.0` and `bash-v2.7.0`. The settings of your operating system can hide the alerts. Refer to [desktop alerts, settings and tests](proxy-profile.md#desktop-alerts-while-the-cli-owns-the-terminal).

### PowerShell 2.5.0 / Bash 2.6.0: recovery

This version adds:

- SSH recovery on fixed ports.
- A live outage warning for each provider.
- A warning after a long outage (60 seconds, configurable).
- A mandatory check of the proxy connection before each start.
- Safe demonstrations: `proxy-test recover --fast` and `proxy-test prolonged --fast`.

Open sessions stay open and keep their proxy settings while the recovery tries again. Refer to [recovery behavior and settings](proxy-profile.md#recovery-while-claude-or-codex-is-running).

1. Type `proxy-update` and load your profile again.
2. If an older profile owns the tunnel, type `proxy-restart` one time.
3. Load keys that have a passphrase into the SSH agent before the recovery starts.

Version identifiers: `powershell-v2.5.0` and `bash-v2.6.0`.

### Windows 2.4.1 / macOS, Linux and WSL 2.5.2: `chrome-proxy` and unknown nodes

If the loaded catalogue does not contain a node name, `chrome-proxy` now stops with a clear error. Before, it gave the name to Chrome as a website (for example `http://sg/`). Node names (`sg`) and SSH aliases (`sgvpn`) both work when the catalogue contains them. Your settings and Chrome profiles stay.

Update and load the profile again in the terminal that has the problem:

```powershell
proxy-update
. "$HOME\.claude-proxy.ps1"
proxy-nodes -Refresh
chrome-proxy sg -Profile sg https://www.google.com/
```

```bash
proxy-update
source ~/.claude-proxy.sh
proxy-nodes --refresh
chrome-proxy sg --profile sg https://www.google.com/
```

Close the proxy Chrome windows that have the problem before you try again. `proxy-nodes --refresh` updates the catalogue. The new load of the profile updates the `chrome-proxy` command. If the browser continues to fail, refer to [node troubleshooting](proxy-nodes.md#chrome-opens-httpsg-or-reports-err_socks_connection_failed) for the SSH and SOCKS checks.

Each script has its own version tag: `powershell-v2.4.1` for `claude-proxy.ps1` and `bash-v2.5.2` for `claude-proxy.sh`. Later versions use the same names: `powershell-v<version>` and `bash-v<version>`.

### Earlier versions

- **2.4: `cc-install`.** One command examines **Node.js**, **Claude Code** and **Codex**, and installs or updates the missing or old items (through the proxy). The setup wizard runs it as the last step. To update the tools, type `cc-install`. To update this setup, type `proxy-update`.
- **2.3: a private node list.** `proxy-nodes --from <your VM alias>` (`-From` on Windows) gets the list over SSH from a VM that you select. The list is not public. Your admin installs it with forge `proxynodes-manager`. On Windows, `proxy-update` also loads the new version into the open window. Refer to **[Nodes](proxy-nodes.md)**.
- **2.2: nodes from your domain, more VMs for each region, Chrome profiles.** If your company publishes its nodes in DNS, type `proxy-nodes --domain example.com` (`-Domain` on Windows). `chrome-proxy jp --profile work` opens a different Chrome profile through `jp`. `jp2`, `jp3` … are more VMs in the same region. If you do not use these features, you do not have to change anything. Refer to **[Nodes](proxy-nodes.md)**.
- **2.1: nodes.** After `proxy-update`, type `proxy-nodes --refresh` (`-Refresh` on Windows) one time to download the node catalogue (JP / SG / US …). Then `proxy-node sg` moves Claude and Codex to a different region, and `chrome-proxy sg` opens Chrome through it. You can use more regions at the same time. Your `jpvpn` alias, your settings and your Chrome logins stay. (On the first use, the profile renames the Chrome profile folder to `…-<node>`.) Refer to **[Nodes](proxy-nodes.md)**.
- **2.0: a separate settings file.** An update does not change your settings.

---

## Upgrade from the old setup (SOCKS + bridge)

Old versions used a SOCKS tunnel (`ssh -D`) **and** an `http-proxy-to-socks` bridge on your computer. The new design puts the HTTP proxy on the VM and removes the bridge. The upgrade has three parts.

### 1. On the VM: install the HTTP proxy

The old setup did not have this part:

```bash
git clone https://github.com/crayonluffy/forge.git    # or: cd forge && git pull
sudo ./forge/webproxy-manager/install.sh              # tinyproxy on 127.0.0.1:8888
```

### 2. On each computer: install the new profile

Run the wizard again. It replaces `~/.claude-proxy.sh` (or `$PROFILE`) with the new version, installs `jq` and `lsof`, and asks for the VM proxy port. Each question shows your current answer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)   # macOS / Linux / WSL
```

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex           # Windows
```

To do this by hand, replace the profile and make the settings file. Write the host alias in it. If tinyproxy on the VM does not use port 8888, also write `CLAUDE_REMOTE_PROXY_PORT`. Refer to [Set up by hand](proxy-profile.md#set-up-by-hand--macos--linux):

```bash
curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/claude-proxy.sh -o ~/.claude-proxy.sh
```

### 3. Load the profile and remove old processes

```bash
source ~/.bashrc     # or ~/.zshrc; on Windows, open a new PowerShell window
cc-stop              # stops what the old tunnel or bridge left on ports 8080 and 1080
cc
```

Your SSH key and your `~/.ssh/config` alias stay. You do not have to do them again. `cc` stops an old `ssh` and starts the tunnel. The SOCKS forward (`-D 1080`) is still there. `chrome-proxy` uses it.

> **Note:** The new profile also contains **`cx`**. It starts [Codex](install-codex.md) through the proxy with one command.
