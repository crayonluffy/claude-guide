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

From 2.8.0, each version has one tag, `v<version>`, and a [GitHub release](https://github.com/crayonluffy/claude-guide/releases) with its release notes.

### 2.13.1: audit fixes (safer node lists, keys and settings)

From a review of the profiles, installers and docs
([findings](superpowers/audits/2026-11-07-audit.md)):

- **Node lists are checked before they reach your SSH files.** A host key from
  the node list is pinned only for a host that has no key yet; a different key
  is reported, never added. Invalid host names, users or ports are refused.
- **The installer keeps your own SSH key.** If `~/.ssh` already has a different
  key with the name of the one in Downloads, the new key is installed as
  `<name>-claude-proxy`.
- **Claude's `settings.json`:** paths with spaces (WSL with a Windows user name
  such as "John Doe") now work; the file is replaced in one step; a symlinked
  file stays a link; the first original is kept as
  `settings.json.claude-proxy.orig`; Windows writes it without a byte-order mark.
- **Settings values** with `"`, `$`, `` ` `` or `\` are saved exactly instead of
  breaking the settings file.
- `proxy-update` swaps the new profile in one step, so an interrupted update
  cannot leave a broken profile.
- Windows installer: the key is locked to your account by its security ID, so
  Microsoft-account and work/school logins no longer risk an unreadable key.
- Windows: desktop alerts report "unavailable" when the notification thread
  cannot start (for example on Server Core) instead of claiming to work.

### 2.13.0: fewer commands, shared accounts, steadier nodes

#### Fewer commands, clearer help, manual fallback

You now need eight commands: `cc`, `cx`, `cc-stop`, `proxy-status`,
`proxy-restart`, `proxy-nodes`, `chrome-proxy` and `proxy-config`. Several
commands became options of these:

| Old | New |
|-----|-----|
| `cc-safe`, `cx-safe` | `cc --safe`, `cx --safe` |
| `cx-stop` | `cc-stop` |
| `proxy-doctor` | `proxy-status --fix` |
| `proxy-node sg` | `proxy-nodes use sg` |
| `chrome-profiles` | `chrome-proxy --list` |
| `proxy-killswitch` | `proxy-config killswitch` |

The old names still work in this release and print the new name. `bridge-start`
and `bridge-stop`, which did nothing, are removed.

`cc-help` now starts with your mode, default node, ports and tunnel state, and
groups commands by task; `cc-help all` lists maintenance and low-level commands.
The new `cc-manual [node]` prints the exact `ssh`, `curl`, `claude` and `codex`
commands for running everything by hand, without running anything.

#### Two accounts, one tunnel

A second macOS account can use the tunnel that another account already runs:
`proxy-config set PROXY_MODE shared` in the second account. It never starts or
stops that tunnel. Refer to [shared mode](proxy-profile.md#two-accounts-on-one-mac-shared-mode-2130).

#### Nodes keep their ports; safer switches and restarts

- Explicitly named nodes (`cc --node jp`, `chrome-proxy jp`, `proxy-restart jp`,
  `cc-stop jp`) always use that node's own tunnel and ports, even when it is the
  default node, so changing the default no longer moves them. Plain `cc` / `cx`
  use the main tunnel, whose ports do not change.
- Starts, stops, restarts and default-node changes from different tabs now wait
  for each other instead of racing.
- `proxy-config edit` lists every known node with editable ports (`NODE_PORTS`),
  the ports it runs on now, and ports that another program or account uses.
  Conflicting ports are refused before any tunnel stops.
- When a tunnel is reconnecting, a new `cc` / `cx` waits for it instead of
  failing with "Tunnel ports are not ready".

#### Quieter notices inside Claude and Codex

Brief connection drops no longer print lost/restored messages inside each CLI.
By default, an outage lasting 60 seconds gets one warning, followed by one
recovery message when it ends. Progress stays in the logs. Use
`proxy-config set TERMINAL_NOTIFICATIONS verbose` for the previous output, or
`off` for no routine terminal messages. Actionable SSH and port-takeover warnings
remain visible. Desktop notifications and automatic recovery keep working.

Update, reload the profile and relaunch the CLI to use the new policy. Existing
running notifiers retain their behavior until those CLI sessions exit normally;
the shared tunnel does not need to restart.

### 2.12.2: targeted restart keeps the selected node

If saved settings make the selected node the default server and no main owner
is running, a targeted restart now refuses before stopping any tunnel. Previously,
a stale terminal could stop that node and start the main tunnel on different
ports. Run `proxy-restart` without a node to apply the saved default server.
When the main owner is running, targeted restarts still retain its active settings
and restart only the selected node. This applies to Windows, macOS, Linux and WSL.

The portable Chrome regression also runs without requiring a macOS console.

Type `proxy-update`, then open a new terminal window. Release tag: `v2.12.2`.

### 2.12.1 (Windows): active-node configuration parity

- **`proxy-config edit` now lists every running node's ports on Windows too.**
  The Notepad header distinguishes saved main ports, node base ports and the
  running HTTP/SOCKS/remote/SSH ports. Missing editable port settings are included.
- **`proxy-config use-active` saves the main tunnel's running ports.** Editing
  or setting values preserves pending saved settings and live tunnels separately.
  Unrelated settings, Unicode and comments remain intact.
- **Safe editing.** Failed editors and invalid PSD1 files or ports do not replace
  saved settings. Malformed existing files can be repaired in the editor.
  If another window saves changes while the editor is open, retry rather than
  overwriting those changes.
- **Consistent restart behavior.** A new window adopts the running main port
  before pinning Claude. Running nodes retain their ports after saved base
  changes. `proxy-restart` applies saved settings; `proxy-restart -Node sg`
  affects sg only. Conflicting ports are rejected before stopping a tunnel.
  Changed local ports require affected applications to be relaunched.
- **Readable Windows status.** `proxy-status` leads with saved and active ports;
  `proxy-status -Debug` adds recovery details.

Type `proxy-update`, then open a new PowerShell window. Release tag: `v2.12.1`.
Shell profiles keep their 2.12.0 behavior, with the version marker aligned.

### 2.12.0 (macOS, Linux, WSL): visible ports and platform profiles

- **New windows keep the live tunnel's port.** Startup reads the running owner's
  port before writing Claude's shared settings. A live tunnel on 8081 is no
  longer overwritten with the default 8080 when another window opens.
- **`proxy-config edit` includes ports in existing config files.** It shows saved
  defaults, node base ports and HTTP/SOCKS/remote ports for every running node
  owner. The running-node table is a snapshot; edit the settings below it.
- **Choose how to handle saved/running differences.** `proxy-config use-active`
  saves the main tunnel's running ports. `proxy-restart` now reads saved settings
  after stopping the old tunnel. Use `proxy-restart sg` for a specific node.
  Configuration edits keep tunnels running until you explicitly restart them.
  Saved node base changes also keep existing node ports until their restart.
  When local ports change, relaunch affected applications; they retain old URLs.
  A restart rejects conflicts with another active node before stopping anything.
- **Safer editing.** Failed editors, invalid shell syntax and invalid ports do
  not replace the saved file. Ports must be 1–65535 without leading zeroes.
  `$VISUAL` or `$EDITOR` can include flags or an executable path with spaces.
- **Readable status.** `proxy-status` shows saved/active ports and useful next
  commands. `proxy-status --debug` adds raw recovery details.
- **Platform downloads.** Separate standalone macOS and Linux/WSL profiles are
  built from a shared core and OS adapters. Existing commands and installation
  paths stay the same. macOS diagnostics avoid Linux package-manager advice.
  The active SSH column resolves alias settings with `ssh -G`.
- **Bash 3.2:** empty SSH/launcher argument arrays work with `set -u` enabled.

PowerShell retains its existing behavior; its version marker is aligned.
Type `proxy-update`, then open a new terminal window. Release tag: `v2.12.0`.

### 2.11.5 (macOS): kill switch accepts a tunnel started before the update

- **Fixed: right after the update to 2.11.4, `cc` stopped with `[Kill switch] ssh (PID ...) is on proxy port 8080, not the tunnel`.** The tunnel was still run by the owner from 2.11.3, which saved its ssh start time in the old format. The kill switch now reads both formats.

Type `proxy-update` and open a new terminal window. Release tag: `v2.11.5`.

### 2.11.4 (macOS): tabs share one tunnel; kill switch works without recovery

- **Fixed: on macOS, every new tab started its own tunnel owner, and the owners fought over the same ports.** You saw `[Upgrade] Replacing the tunnel ...` in new tabs, and many `Local port conflict` / `Proxy connection lost` / `restored` messages. The cause: macOS `ps` adds spaces at the end of a start time, so the profile never recognized a running owner. This was wrong since 2.6.0. Linux and WSL were not affected.
- **Fixed: with `TUNNEL_WATCHDOG=0`, the kill switch refused the tunnel's own ssh** (`ssh (PID ...) is on proxy port 8080, not the tunnel`). It now accepts the ssh that forwards the tunnel ports.
- **Tip: plain `claude` and `codex` through the tunnel.** Type `proxy-config set PLAIN_COMMANDS auto`. Then plain `claude` starts the tunnel when needed and runs through it, the same as `cc-safe`.

If you turned recovery or the kill switch off as a workaround, turn them on again after the update:

```zsh
proxy-update
proxy-config set TUNNEL_WATCHDOG 1
proxy-killswitch on
cc-stop --force      # close Claude and Codex first
```

Then open new terminal windows. Release tag: `v2.11.4`.

### 2.11.3 (macOS, Linux, WSL): old tunnel loops are stopped on update

- **Fixed: after updating to 2.11.2, tunnel loops started by 2.11.1 kept running in the background and restarting their own ssh.** 2.11.1 wrote down the wrong process ID for them, so `tunnel-stop` could not find them. The first `cc` after the update now stops them. This takes a few seconds and prints `[Upgrade] Stopping tunnel loops left by an older profile`. You no longer need to restart your computer.

Type `proxy-update` and open a new terminal window. Release tag: `v2.11.3`.

### 2.11.2 (macOS, Linux, WSL): a second tab no longer replaces the tunnel

- **Fixed: on macOS (zsh), every new tab printed `[Upgrade] Replacing the tunnel from an older profile ...` and broke the tunnel of the other tabs.** When zsh has a trap set (oh-my-zsh, iTerm or Powerlevel10k often set one), the tunnel owner wrote down the wrong process ID. Then the next tab thought no owner was running and started a new tunnel on the same ports. Now all tabs share one tunnel again.

Type `proxy-update` and open a new terminal window. Release tag: `v2.11.2`.

### 2.11.1 (Windows, macOS, Linux, WSL): `cx --node` works with new Codex versions

- **Fixed: `cx --node sg` stops with `workspace routing discovery failed`.** New Codex versions (0.16x and later) use one shared background server. This server keeps the proxy it started with, so `cx` could not use the proxy of the node. `cx` and plain `codex` now start Codex with `--no-daemon` when Codex has this option. Each Codex window then uses its own proxy. This also closes a kill switch gap: before, the shared server could connect without the tunnel.

Type `proxy-update` and open a new terminal window. Release tag: `v2.11.1`.

### 2.11.0 (Windows, macOS, Linux, WSL): stop one node; plain ssh aliases as nodes

- **New: `cc-stop sg` / `cx-stop sg`.** Stops only the tunnel of node `sg`. The other nodes continue. It refuses while a session uses `sg` (`--force` stops it anyway). `cc-stop` without a node still stops all tunnels.
- **Fixed: plain ssh aliases work with `--node` again.** In 2.10.0, `cc --node devbox` worked only for a node in the node list. Now an alias in `~/.ssh/config` also works. It gets fixed ports from slot 100 up (`8280` / `1280` …), saved in `~/.claude-proxy.local-nodes`.
- **Changed: `cc-help`** shows how to use more nodes at the same time.

Type `proxy-update` and open a new terminal window. Release tag: `v2.11.0`. The release notes are on the GitHub release of the same name.

### 2.10.0 (Windows, macOS, Linux, WSL): more nodes at the same time

Each node can have its own tunnel. You can use different nodes in different terminals at the same time.

| Command | Before 2.10 | From 2.10 |
|---|---|---|
| `cc --node sg`, `cx --node sg`, `proxy-up --node sg` | Changed the default node and restarted the shared tunnel. Other terminals lost their connection. | Changes **this terminal only**. Node `sg` gets its own tunnel. Nothing is saved. |
| `proxy-node sg` | Changed the default node. | The same, but it refuses while a `cc` or `cx` session uses the default node (`--force` changes it anyway). |
| `chrome-proxy sg` | Started its own `ssh` that did not repair itself. | Uses the self-healing tunnel of `sg`. |
| `tunnel-start`, `tunnel-stop`, `proxy-restart` | The default tunnel. | The default tunnel, or one node: `tunnel-stop sg`. |
| `cc-stop` | The default tunnel and the Chrome tunnels. | All tunnels of all nodes. |
| `proxy-status`, `proxy-doctor` | The default tunnel. | One line for each node tunnel. |

> **Note:** If you used `cc --node sg` to change the default node, use `proxy-node sg` now.

A node tunnel uses the ports `NODE_HTTP_BASE` + slot (new, default `8180`) and `NODE_SOCKS_BASE` + slot (`1180`). The first `chrome-proxy` or `tunnel-start` for a node replaces an old Chrome tunnel on these ports.

Type `proxy-update` and open a new terminal window. Release tag: `v2.10.0`. The release notes are on the GitHub release of the same name.

### 2.9.0 (Windows, macOS, Linux, WSL): kill switch

Claude and Codex do not connect directly any more. When the tunnel is down, they cannot connect.

- **Claude keeps the proxy.** The profile keeps the proxy in Claude's `settings.json`. `proxy-off` and `cc-stop` do not remove it. Plain `claude` and the IDE extensions use the tunnel. If the tunnel is down, they show "connection refused". To start the tunnel, type `cc` or `proxy-up`.
- **`cc` and `cx` examine the setup before they start.** They stop and tell you the fix if `NO_PROXY` sends an API host directly. They also stop if another program uses the proxy port.
- **The tunnel does not move to a different port.** If another program uses the proxy port, `tunnel-start` stops and tells you the fix.
- **Optional: plain `claude` and `codex` through the tunnel.** Type `proxy-config set PLAIN_COMMANDS auto`. The setup wizard asks new users.
- **New command:** `proxy-killswitch` shows the status.

The kill switch is on after the update. To use the behavior from before 2.9.0, type `proxy-killswitch off`.

Type `proxy-update` and open a new terminal window. Release tag: `v2.9.0`. The release notes are on the GitHub release of the same name.

### 2.8.0 (Windows, macOS, Linux, WSL): one self-healing tunnel, clearer errors

- **One recovery owner for each user.** All terminals use the same tunnel. This is also true for a terminal with old settings. `tunnel-start` and `tunnel-stop` work from each terminal. After `tunnel-stop`, the tunnel stays stopped.
- **The upgrade is automatic.** The next `cc`, `cx` or `tunnel-start` replaces a tunnel from an older profile. It uses the same ports. Open sessions connect again in a few seconds. You do not have to type `proxy-restart`.
- **SSH errors have an explanation.** `tunnel-start`, `proxy-status` and each open session show the cause and the fix: a refused login, a changed host key, a port in use, or a server that does not answer. After a refused login, the profile tries again only each 30 seconds.
- **Fewer checks when you do not use the tunnel.** With no `cc` or `cx` open, the profile examines the tunnel each minute (`WATCHDOG_IDLE_INTERVAL`). When you start `cc` or `cx`, it examines the tunnel at once.
- **Port takeover alert.** Another program can start to use the proxy port while the tunnel is down. Then each session and the desktop show one alert with the name of the program. Stop the session. The profile does not stop any program.
- `cc-stop` also counts open `cc` and `cx` sessions. (On Windows, Claude from npm runs as `node.exe`. Older profiles did not see it.)
- Windows: `proxy-status` is easier to read. The background owner runs in PowerShell, not in the ISE. `tunnel-start` tells you if `ssh` is not installed.
- macOS, Linux, WSL: the profile works without `lsof` when `ss` is installed. A stopped `ssh` cannot stop the recovery any more.

Type `proxy-update` and open a new terminal window. Release tag: `v2.8.0`. The release notes are on the GitHub release of the same name.

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

Each script has its own version tag: `powershell-v2.4.1` for `claude-proxy.ps1` and `bash-v2.5.2` for `claude-proxy.sh`. From 2.8.0, each version has one tag for the two profiles: `v<version>` (for example `v2.10.0`).

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
