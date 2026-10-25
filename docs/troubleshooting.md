# 🚑 Troubleshooting

## Start with `proxy-doctor`

Type `proxy-doctor`. It examines each part of the setup and shows one line for each part:

- `[ OK ]`: the part is correct.
- `[WARN]`: the part can cause a problem. The line tells you the fix.
- `[FAIL]`: the part does not work. The line tells you the fix.

`proxy-doctor` examines these parts:

1. The tools: `jq`, `lsof` or `ss`, and `codex`.
2. The two tunnel ports. One `ssh` process must hold both ports.
3. The proxy settings in your terminal.
4. The proxy in Claude's `settings.json`, and the kill switch.
5. The connection to the API through the proxy.

## Common conditions

**The tunnel stops while `cc` or `cx` runs.**
The terminal shows a warning. The recovery owner connects SSH again on the same ports. After 60 seconds, the terminal shows one more warning. The recovery owner continues to try. Your session stays open. To see the status and the log files, type `proxy-status` in a different terminal.

**You cannot see the warnings, because Claude or Codex covers the terminal.**
Use the desktop alerts:

1. Keep `cx` open.
2. In a different terminal, type `proxy-notify test`.
3. Make sure that you see the test alert outside the Codex window.

If you do not see the alert, examine the notification settings of your operating system. "Focus" and "Do Not Disturb" can hide alerts. A headless SSH or WSL session can have no desktop service. Refer to [desktop alerts and testing](proxy-profile.md#desktop-alerts-while-the-cli-owns-the-terminal).

To see all alerts without a real outage, type `proxy-test prolonged --fast --desktop`. Each alert shows `[SIMULATION]`.

**SSH works, but the HTTP proxy on the VM does not work.**
The recovery owner shows a proxy failure. It does not restart SSH again and again. On the VM, type `webproxy-status`. Ask your admin to examine tinyproxy: its `Allow` rules, its `ConnectPort` rules, and the internet connection of the VM. An API error (401, 403, 429 or 5xx) after a good connection does not show an SSH problem.

**`proxy-doctor` says that the proxy is up, but the API does not answer.**
`proxy-doctor` asks the VM and tells you which part has the problem:

| Part | Fix |
|---|---|
| Your tunnel | Type `proxy-restart`. |
| tinyproxy refuses the connection | On the VM, add `Allow 127.0.0.1` and `ConnectPort 443`. |
| tinyproxy does not run | On the VM, type `webproxy-status`. |
| The internet connection of the VM | Ask your admin. |

**A new `cc` or `cx` does not start.**
Each start examines the HTTPS connection through the proxy. `--no-verify` does not skip this check. If the background SSH cannot log in:

1. Type `ssh <alias>` one time.
2. Load your key into the SSH agent (`ssh-add <key>`).

The background recovery cannot ask for a passphrase. Refer to [recovery settings and limits](proxy-profile.md#recovery-while-claude-or-codex-is-running).

**`cc-stop` does not stop everything.**
`cc-stop` stops each `ssh` process on the two tunnel ports. It does not stop other programs on these ports; it shows them. If an `ssh` process does not stop, `cc-stop` tells you. It also tells you how to examine the process.

---

## 🪟 Windows

| Symptom | Fix |
|---------|-----|
| `... is not digitally signed`, or the profile does not load | Type `Unblock-File -Path $PROFILE`. Then make sure that `Get-ExecutionPolicy -Scope CurrentUser` shows `RemoteSigned`. |
| Incorrect characters, or parse errors | The file has an incorrect encoding (Big5 or CP950). Save the file again as **UTF-8**. |
| SSH stops, or `cc`/`cx` stops at once with no tunnel | The first connection must accept the host key. Type `ssh jpvpn` one time, type `yes`, and try again. |
| The tunnel starts, but Claude or Codex cannot connect to the API | Make sure that the VM runs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on port `8888`). Make sure that `NO_PROXY_EXTRA` does **not** contain `api.anthropic.com`. |
| `cx` stops with `account/read failed ... workspace routing discovery failed` | New Codex versions use one shared background server, and this server keeps an old proxy. Type `proxy-update` (2.11.1 or newer). To fix it now, type `codex app-server daemon stop` and start `cx` again. |
| `cx` shows `'codex' not found` | Install Codex: [Install Codex](install-codex.md). On Windows, Codex works best in WSL. |
| Wizard: `[Warn] Could not write to $PROFILE`, or `Access denied` on Documents | Windows does not let PowerShell write the loader line into `$PROFILE`. The usual cause is **Controlled folder access** in Windows Defender. To allow PowerShell, go to Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell. OneDrive or a company policy can also lock Documents. **You can continue:** the profile is in `~\.claude-proxy.ps1`, and the wizard makes a **"Claude Proxy Shell"** shortcut on the Desktop. This shortcut opens PowerShell with `cc` and `cx` loaded. To use normal windows, unlock Documents and run the wizard again. You can also add the line by hand: [Set up by hand](proxy-profile.md#step-2--install-the-cccx-profile). |
| `running scripts is disabled on this system`, or a group policy sets `Restricted` | New windows cannot run `$PROFILE`. Use the **"Claude Proxy Shell"** shortcut. To make it, type `proxy-shortcut`. In one window only, you can also type `Invoke-Expression (Get-Content -Raw "$HOME\.claude-proxy.ps1")`. |
| New windows load an OLD profile | `$PROFILE` contains the full profile from before 2.0, not the loader line. `proxy-doctor` shows this. Type `proxy-update`, or run the wizard again. The wizard keeps a copy of `$PROFILE` as `.bak` and writes the loader line. |
| `[Err] <program> (PID n) is on proxy port 8080 ...` | Another program (a development server, Docker, an emulator) uses the proxy port. The kill switch does not move the tunnel to a different port. Close that program, or move the tunnel: `proxy-config set HTTP_PORT 8090`. |
| `proxy-update` or `proxy-config` is not recognized | Your profile is older than 2.0. Run the wizard one time. It keeps your settings: `irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 \| iex` |
| `cc -c` starts a *new* session | Profiles before 2.0 did not send extra arguments. Update the profile as in the row above. |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | An old `ssh` from a lost connection holds the port. Type `cc`. It stops the old `ssh` and starts a new tunnel. |
| `SSH login to <server> was refused` | The key is not loaded, or the user name is incorrect. Type `ssh-add <key>`, or correct `SSH_USER` with `proxy-config`. Then type `proxy-restart`. |
| `The host key of <server> changed` | Ask your admin if the VM is new. If it is new, type `ssh-keygen -R <server>`. Then type `ssh <server>` one time and answer `yes`. |
| `Cannot reach <server> ... Retrying` | The network is down, the Wi-Fi changed, or the VM is off. You do not have to do anything. The sessions stay open and connect again when the server is available. |
| `Another program (<name>, PID <pid>) took proxy port ...` | When the tunnel was down, `<name>` started to listen on the proxy port. Claude or Codex can send data to it. Stop the session. Close that program, or move the tunnel (`proxy-config set HTTP_PORT 8090`). Then type `cc` again. The profile did not stop any program. |
| `[Kill switch] NO_PROXY would send ... DIRECT` | Your `NO_PROXY` setting sends API traffic directly. Remove the entry that the message shows (`proxy-config edit`). Then type `cc` again. |
| `[Kill switch] <program> (PID n) is on proxy port ...` | Another program uses the proxy port. Close that program. Or move the tunnel: `proxy-config set HTTP_PORT 8090`. |
| `[Kill switch] Claude's settings ... could not be pointed at the tunnel` | Claude's `settings.json` is not valid JSON. Repair the file, or use the `.bak` copy. |
| Plain `claude` shows "connection refused" | The kill switch is on, and the tunnel is down. Start the tunnel: type `cc` or `proxy-up`. To let `claude` connect directly, type `proxy-killswitch off`. |
| `cc-stop` refuses: `Claude/Codex session(s) are still running` | A different window has `cc` or `cx` open. (Claude from npm shows as `node`.) Close that session. To connect again, type `proxy-restart`. To stop the tunnel anyway, type `cc-stop -Force`. |
| The setup is incorrect (alias, host, key or profile) | Run the wizard again. Answer **n** to "keep these settings". Each question shows the current value, so you type only the incorrect values: `irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 \| iex` |

---

## 🍎 macOS / 🐧 Linux / WSL

| Symptom | Fix |
|---------|-----|
| `lsof: command not found` (Linux / WSL) | From 2.8.0, the profile uses `ss` if `lsof` is not installed. Most systems have `ss`. For older profiles: `sudo apt install lsof` (Debian/Ubuntu) or `sudo dnf install lsof`. |
| The tunnel does not start | `tunnel-start` shows the cause and the error from SSH. For more data, type `proxy-status`, or read the log (`/tmp/claude-tunnel-<uid>.log`). Make sure that the VM runs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager). |
| `SSH login to <server> was refused` | The key is not loaded, or the user name is incorrect. Type `ssh-add ~/.ssh/<your-key>`, or correct `CLAUDE_SSH_USER` with `proxy-config`. Then type `proxy-restart`. |
| `The host key of <server> changed` | Ask your admin if the VM is new. If it is new, type `ssh-keygen -R <server>`. Then type `ssh <server>` one time and answer `yes`. |
| `Cannot reach <server> ... Retrying` | The network is down, the Wi-Fi changed, or the VM is off. You do not have to do anything. The sessions stay open and connect again when the server is available. |
| `Another program (<name>, PID <pid>) took proxy port ...` | When the tunnel was down, `<name>` started to listen on the proxy port. Claude or Codex can send data to it. Stop the session. Close that program, or move the tunnel (`proxy-config set HTTP_PORT 8090`). Then type `cc` again. The profile did not stop any program. |
| `[Kill switch] NO_PROXY would send ... DIRECT` | Your `NO_PROXY` setting sends API traffic directly. Remove the entry that the message shows (`proxy-config edit`). Then type `cc` again. |
| `[Kill switch] <program> (PID n) is on proxy port ...` | Another program uses the proxy port. Close that program. Or move the tunnel: `proxy-config set HTTP_PORT 8090`. |
| `[Kill switch] Claude's settings ... could not be pointed at the tunnel` | Claude's `settings.json` is not valid JSON. Repair the file, or use the `.bak` copy. |
| `[Err] <program> (PID n) is on proxy port 8080 ...` | Another program uses the proxy port. The kill switch does not move the tunnel to a different port. Close that program, or move the tunnel: `proxy-config set HTTP_PORT 8090`. |
| Plain `claude` shows "connection refused" | The kill switch is on, and the tunnel is down. Start the tunnel: type `cc` or `proxy-up`. To let `claude` connect directly, type `proxy-killswitch off`. |
| `cc-stop` refuses: `Claude/Codex session(s) still running` | A different terminal has `cc` or `cx` open. Close that session. To connect again, type `proxy-restart`. To stop the tunnel anyway, type `cc-stop --force`. |
| SSH asks for the passphrase again and again | On macOS, the setup adds the key to the Keychain. To do this again: `ssh-add --apple-use-keychain ~/.ssh/<your-key>` (macOS) or `ssh-add ~/.ssh/<your-key>` (Linux). |
| **WSL:** `cc` or `cx` stops at once, with no tunnel | A background `ssh` cannot ask for a passphrase, and WSL does not keep an ssh-agent. The profile starts an agent. If the problem continues, type `ssh-add ~/.ssh/<your-key>` one time. Or enable systemd in `/etc/wsl.conf` (`[boot]\nsystemd=true`). |
| **WSL:** the wizard shows `No private key found`, but the key is in Downloads | The wizard looks in `~/Downloads` in WSL *and* in `C:\Users\*\Downloads`. Your Windows drive can be at a different location than `/mnt/c` (a custom `automount` in `/etc/wsl.conf`). Then type the full path when the wizard asks "Full path to your private key". |
| **WSL:** Claude on Windows does not use the tunnel | Type `proxy-config set SYNC_WINDOWS_SETTINGS 1` (it is off by default). Then type `cc` or `proxy-up` again. This needs WSL2 with `localhostForwarding` on (the default), and `cmd.exe` available from WSL (`appendWindowsPath` not disabled). |
| `cc` or `cx` stops before the application starts | The tunnel did not start. Accept the host key one time with `ssh jpvpn`. Then try again. |
| `cx` stops with `account/read failed ... workspace routing discovery failed` | New Codex versions use one shared background server, and this server keeps an old proxy. Type `proxy-update` (2.11.1 or newer). To fix it now, type `codex app-server daemon stop` and start `cx` again. |
| `cx` shows `'codex' not found` | Install Codex: [Install Codex](install-codex.md). |
| `tunnel-start:6: read-only variable: status` (macOS / zsh) | This is a bug in profiles before 2.0. Run the wizard one time to get the current profile. It keeps your settings. |
| `proxy-update` or `proxy-config`: command not found | Your profile is older than 2.0. Run the wizard one time. It keeps your settings: `bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)` |
| `cc -c` starts a *new* session | Profiles before 2.0 did not send extra arguments. Update the profile as in the row above. |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | An old `ssh` from a lost connection holds the port. Type `cc`. It stops the old `ssh` and starts a new tunnel. |
| The tunnel is up, but Claude cannot connect to the API | Make sure that `CLAUDE_NO_PROXY` does **not** contain `api.anthropic.com`. Make sure that tinyproxy accepts CONNECT to port 443 (this is the default). |
| The setup is incorrect (alias, host, key or profile) | Run the wizard again. Answer **n** to "keep these settings". Each question shows the current value, so you type only the incorrect values: `bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)` |

---

## 🧰 Node.js / Claude Code / Codex (`cc-install`)

| Message | Fix |
|---|---|
| `Node.js vXX is too old (Claude Code needs 22 or newer)` | Answer **Y**. `cc-install` installs the current LTS version. Windows: winget or the official installer. macOS: Homebrew or the official installer. Linux: nvm or NodeSource. |
| `'node' is still vXX in this window`, or `isn't found in this window yet` | The new program is installed, but this window started before the installation. Open a **new** window and type `cc-install` again. |
| `Global npm packages go to /usr, which needs sudo` (Linux) | Answer **Y**. This is the fix that npm recommends: packages go to `~/.npm-global`, and the profile adds it to your PATH. |
| `… wasn't installed with npm - update it with: claude update` | A different installer installed Claude or Codex (the native installer or Homebrew). Use the command in the message. Then you do not get two copies. |
| `the npm registry can't be reached` | The proxy is not up. Type `proxy-doctor`, then `cc-install` again. |
| `npm install failed` | Read the npm error above the message. For a network error, type `proxy-doctor`. For a permission error on Linux, accept the `~/.npm-global` offer. |

## 🌏 Nodes (JP / SG / US)

| Symptom | Fix |
|---------|-----|
| `proxy-nodes` shows *No node catalogue yet* | Type `proxy-nodes --refresh` (`-Refresh` on Windows). It downloads from the same GitHub URL as `proxy-update`. If GitHub is blocked, type `proxy-up` first and try again. |
| `Unknown node 'sg'` | The node list does not contain this name, and `~/.ssh/config` has no alias with this name. To get the latest node list, type `proxy-nodes --refresh`. Or add a `Host sg` alias to `~/.ssh/config`: from 2.11, a plain alias works as a node. |
| A node shows `<not provisioned>` | The admin added the node but not its address. You do not have to do anything. |
| `sg tunnel failed to start`, or *Permission denied (publickey)* | Your key is not on that VM. Ask the admin. To examine it, type `ssh sgvpn`. The `Host sgvpn` block in `~/.ssh/config` uses the same `IdentityFile` as `jpvpn`. |
| `[Err] <program> (PID n) is on port 8181, which this node's tunnel uses` | A different program uses a port of the node tunnel. Close that program, or move the node ports with the `proxy-config set NODE_…_BASE` command in the message. |
| `Node '<name>' would use port …, which the default tunnel uses` | The node ports and the main ports are the same. Use the `proxy-config set NODE_…_BASE` command in the message. |
| `proxy-node sg`: `[Node] n session(s) use the default node` | A `cc` or `cx` session uses the default node. It would move to the new node. For one terminal, type `cc --node sg`. To change the default anyway, type `proxy-node sg --force`. |
| `cc --node sg` worked before, but now the default node does not change | From 2.10, `cc --node` changes only that terminal. To change the default, type `proxy-node sg`. |
| `<vm> answered, but doesn't serve the node list yet` | That VM runs the old `ForceCommand` of sshu-manager. Admin: install forge `proxynodes-manager` on that VM with `--sshd`. The profile did not change your setup. |
| `<vm> has no 'claude-proxy-nodes' command` | forge `proxynodes-manager` is not installed on that VM. Or select a different VM that serves the list: `proxy-nodes --from <other vm>`. |
| `Could not get the node list from <vm>: …` | The last line is the error from ssh. Type `ssh <vm>` to examine the connection. The list download cannot ask for a passphrase, so load a key with a passphrase into `ssh-agent`. `proxy-nodes --refresh` also tries the other VMs in your list. |
| `<vm> didn't answer - took the list from <other> instead` | This is for your information only. Your VM did not answer, and a different VM answered. To use that VM permanently, type `proxy-nodes --from <other>`. |
| `No valid 'v=cp1' TXT records at _claude-proxy.<domain>` | The domain is incorrect, or your admin did not publish the records. To examine them, type `dig +short TXT _claude-proxy.<domain>` (Windows: `Resolve-DnsName -Type TXT _claude-proxy.<domain>`). The profile did not change the saved domain or your node list. To save the domain anyway (for example, before the admin publishes the records), add `--force` (`-Force`). To use the list of this guide again, type `proxy-nodes --domain ''`. |
| `PROXY_DOMAIN = '--domain' saved` (Windows, profile 2.2.1 or older) | Old Windows profiles know only `-Domain`. Type `proxy-update`. Then type `proxy-nodes -Domain ''` to remove the incorrect value. From 2.2.2, `--domain` also works, and the profile refuses incorrect values. |
| `proxy-nodes` shows `jp`, `sg`, `us` as `<not provisioned>` | This was the old example list of this guide (profile 2.2.1 or older). Type `proxy-update` and `proxy-nodes --refresh`. The list of this guide is now empty. Your nodes come from `proxy-nodes --domain <your company domain>`. |
| `ssh alias 'jpvpn' points to X, the catalogue says Y` | Your alias is older than the domain setup. Change `HostName` in `~/.ssh/config`. Or delete that `Host` block and type `proxy-nodes --refresh`. |
| `Several nodes share slot(s) …` | Two nodes have the same `slot`. Tell your admin. Until the admin corrects it, do not open Chrome through these two nodes at the same time. |
| `chrome-proxy jp --profile work` opens the incorrect profile, or no new window | The profile name is the *folder* name (`chrome-profiles` shows it). The name that Chrome shows can be different. `chrome-proxy` must start Chrome for that node. A Chrome window that you started by hand with the same data folder takes priority. |
| `chrome-proxy sg` opens a window, but the window uses the *other* node | Two windows use one profile folder. Chrome ignores a new `--proxy-server` for a folder that is open. The profile uses one folder for each node (`…-jp`, `…-sg`). If you started Chrome by hand, close it and use a different `--user-data-dir` for each node. |
| **macOS:** after `chrome-proxy`, the Chrome icon in the Dock opens only the *proxied* Chrome | macOS gives an application one Dock icon. The proxied Chrome got it, because your normal Chrome was not open. The profile did not change your normal profile (the proxied one is in `~/.chrome-proxy-profile-<node>`). To open your normal Chrome as well, type `open -n -a "Google Chrome"`. Or quit the proxied Chrome (`Cmd+Q`) and click the icon again. To prevent this, start your normal Chrome *before* `chrome-proxy`. |
| You changed the node with `proxy-node`, but a different terminal uses the old node | Each shell reads the settings when it starts. In that terminal, type `source ~/.claude-proxy.sh` (Windows: `. "$HOME\.claude-proxy.ps1"`). Or open a new window. |

---

## How the profile uses Claude's `settings.json`

The profile writes `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` into the `env` block of `~/.claude/settings.json`. Claude reads this file before the settings of your terminal. Thus Claude uses the proxy, also when you start it from an IDE, a desktop application, or a different terminal.

- With the kill switch on (the default), the profile keeps these keys. `cc-stop` and `proxy-off` do not remove them. If the tunnel is down, Claude cannot connect. It does not connect directly. Refer to [Kill switch](proxy-profile.md#kill-switch-290).
- With the kill switch off (`proxy-killswitch off`), `cc-stop` and `proxy-off` remove the keys.
- The profile changes only these three keys. On macOS and Linux, it needs [`jq`](https://jqlang.github.io/jq/). The setup wizard installs `jq`.
- To stop this, type `proxy-config set SYNC_SETTINGS 0`. Then only Claude that you start with `cc` uses the proxy.
- **Codex** does not read a settings file. It reads only the proxy settings of the terminal. Start it with `cx`, or set `proxy-config set PLAIN_COMMANDS auto`.

---

## The problem continues?

- Do the [manual steps](proxy-manual.md) one window at a time. They show which part has the problem.
- On the VM, type `webproxy-status` to make sure that tinyproxy works.
