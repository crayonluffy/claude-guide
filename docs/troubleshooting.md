# Troubleshooting

## Start with `proxy-status --fix`

Type `proxy-status --fix`. It examines each part of the setup and shows one line for each part:

- `[ OK ]`: the part is correct.
- `[WARN]`: the part can cause a problem. The line tells you the fix.
- `[FAIL]`: the part does not work. The line tells you the fix.

`proxy-status --fix` examines these parts:

1. The tools: `jq`, `lsof` or `ss`, and `codex`.
2. The two tunnel ports. One `ssh` process must hold both ports.
3. The proxy settings in your terminal.
4. The proxy in Claude's `settings.json`, and the kill switch.
5. The connection to the API through the proxy.

Find the message or the symptom below. Commands are the same on all platforms; where Windows differs, it is shown in brackets (for example `--force` / `-Force`).

## While Claude or Codex runs

**The tunnel stops while `cc` or `cx` runs.**
The recovery owner connects SSH again on the same ports. Brief drops show nothing. After 60 seconds, the terminal shows one warning, and one more message when the connection is back. The recovery owner continues to try. Your session stays open. To see the status and the log files, type `proxy-status` in a different terminal.

**You cannot see the warnings, because Claude or Codex covers the terminal.**
Use the desktop alerts:

1. Keep `cx` open.
2. In a different terminal, type `proxy-notify test`.
3. Make sure that you see the test alert outside the Codex window.

If you do not see the alert, examine the notification settings of your operating system. "Focus" and "Do Not Disturb" can hide alerts. A headless SSH or WSL session can have no desktop service. Refer to [desktop alerts](kill-switch.md#desktop-alerts-while-the-cli-owns-the-terminal). To see all alerts without a real outage, type `proxy-test prolonged --fast --desktop`. Each alert shows `[SIMULATION]`.

**SSH works, but the HTTP proxy on the VM does not work.**
The recovery owner shows a proxy failure. It does not restart SSH again and again. On the VM, type `webproxy-status`. Ask your admin to examine tinyproxy: its `Allow` rules, its `ConnectPort` rules, and the internet connection of the VM. An API error (401, 403, 429 or 5xx) after a good connection does not show an SSH problem.

**`proxy-status --fix` says that the proxy is up, but the API does not answer.**
`proxy-status --fix` asks the VM and tells you which part has the problem:

| Part | Fix |
|---|---|
| Your tunnel | Type `proxy-restart`. |
| tinyproxy refuses the connection | On the VM, add `Allow 127.0.0.1` and `ConnectPort 443`. |
| tinyproxy does not run | On the VM, type `webproxy-status`. |
| The internet connection of the VM | Ask your admin. |

## Tunnel and connection

| Message or symptom | Fix |
|---|---|
| A new `cc` or `cx` does not start, or stops at once with no tunnel | Each start examines the HTTPS connection through the proxy (`--no-verify` does not skip it). The first connection must accept the host key: type `ssh jpvpn` one time, answer `yes`, and try again. The background SSH cannot ask for a passphrase: load your key with `ssh-add <key>`. Refer to [recovery](kill-switch.md#recovery-while-claude-or-codex-is-running). |
| `SSH login to <server> was refused` | The key is not loaded, or the user name is incorrect. Type `ssh-add <key>`, or correct `SSH_USER` (`CLAUDE_SSH_USER`) with `proxy-config`. Then type `proxy-restart`. |
| `The host key of <server> changed` | Ask your admin if the VM is new. If it is new, type `ssh-keygen -R <server>`. Then type `ssh <server>` one time and answer `yes`. |
| `Cannot reach <server> ... Retrying` | The network is down, the Wi-Fi changed, or the VM is off. You do not have to do anything. The sessions stay open and connect again when the server is available. |
| The tunnel does not start | `tunnel-start` shows the cause and the error from SSH. For more data, type `proxy-status`, or read the log (macOS/Linux: `/tmp/claude-tunnel-<uid>.log`). Make sure that the VM runs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on port `8888`). |
| The tunnel is up, but Claude or Codex cannot connect to the API | Make sure that `CLAUDE_NO_PROXY` (Windows: `NO_PROXY_EXTRA`) does **not** contain `api.anthropic.com`. Make sure that tinyproxy accepts CONNECT to port 443 (this is the default). |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | An old `ssh` from a lost connection holds the port. Type `cc`. It stops the old `ssh` and starts a new tunnel. |
| `[Err] <program> (PID n) is on proxy port 8080 ...`, or `[Kill switch] <program> (PID n) is on proxy port ...` | Another program (a development server, Docker, an emulator) uses the proxy port. The kill switch does not move the tunnel to a different port. Close that program, or move the tunnel: `proxy-config set HTTP_PORT 8090`, then `proxy-restart`. |
| `Another program (<name>, PID <pid>) took proxy port ...` | When the tunnel was down, `<name>` started to listen on the proxy port. Claude or Codex can send data to it. Stop the session. Close that program, or move the tunnel (`proxy-config set HTTP_PORT 8090`). Then type `cc` again. The profile did not stop any program. |
| `cc` says `Another user's program is on port 1080` (or 8080) | A program from a different account listens on that port on localhost or on all addresses. Move the tunnel: `proxy-config set SOCKS_PORT 1081` (or `HTTP_PORT`). A program on a LAN address only (`10.0.0.5:1080`) does not count. |
| `Account 'ming' runs its own proxy tunnel on port 8080` | Two accounts on one computer each run a tunnel on the same ports. In the other account: `cc-stop --force`, then `proxy-config set PROXY_MODE shared` (it then uses your tunnel). Refer to [shared mode](shared-mode.md). |
| `cc-stop --force` stops ssh, but a new ssh appears seconds later (often on port 8081) | A loop from a very old profile still runs without a terminal (macOS, Linux). 2.13.6+: `proxy-update`, then `cc-stop --force` stops the loop too. Older: `ps -o pid,ppid,tty,command -p $(ps -o ppid= -p <ssh PID>)` shows a `-zsh` with `??` and parent `1`; stop it with `kill -9 <that PID>`. |
| `cc-stop` refuses: `Claude/Codex session(s) still running` | A different window has `cc` or `cx` open. (Claude from npm shows as `node`.) Close that session. To connect again, type `proxy-restart`. To stop the tunnel anyway, type `cc-stop --force` (`-Force`). |
| `cc-stop` does not stop everything | `cc-stop` stops each `ssh` process on the two tunnel ports. It does not stop other programs on these ports; it shows them. If an `ssh` process does not stop, `cc-stop` tells you how to examine it. |

## Kill switch

| Message or symptom | Fix |
|---|---|
| Plain `claude` shows "connection refused" | The kill switch is on, and the tunnel is down. Start the tunnel: type `cc` or `proxy-up`. To let `claude` connect directly, type `proxy-config killswitch off`. |
| `[Kill switch] NO_PROXY would send ... DIRECT` | Your `NO_PROXY` setting sends API traffic directly. Remove the entry that the message shows (`proxy-config edit`). Then type `cc` again. |
| `[Kill switch] Claude's settings ... could not be pointed at the tunnel` | Claude's `settings.json` is not valid JSON. Repair the file, or use the `.bak` copy. |
| `[Kill switch] ssh (PID ...) is on proxy port 8080, not the tunnel` right after an update, or with `TUNNEL_WATCHDOG=0` | Type `proxy-update` (2.11.5 or newer). To fix it now: close Claude and Codex, then `cc-stop --force` and `cc`. |

How the kill switch uses Claude's `settings.json`: [Kill switch, recovery and alerts](kill-switch.md#claudes-settingsjson).

## Profile and setup

| Message or symptom | Fix |
|---|---|
| `proxy-update` or `proxy-config`: command not found | Your profile is older than 2.0. Run the installer one time; it keeps your settings. Refer to [Updating](upgrading.md). |
| `cc -c` starts a *new* session | Profiles before 2.0 did not send extra arguments. Update the profile as in the row above. |
| `tunnel-start:6: read-only variable: status` (macOS / zsh) | This is a bug in profiles before 2.0. Run the installer one time to get the current profile. It keeps your settings. |
| Every new tab prints `[Upgrade] Replacing the tunnel from an older profile ...` and the other tabs lose the proxy (macOS, zsh) | Type `proxy-update` (2.11.4 or newer) in one tab, then `cc-stop --force` (close Claude and Codex first). Then open new terminal windows. |
| The setup is incorrect (alias, host, key or profile) | Run the installer again. Answer **n** to "keep these settings". Each question shows the current value, so you type only the incorrect values. |
| You changed the node with `proxy-nodes use`, but a different terminal uses the old node | Each shell reads the settings when it starts. In that terminal, type `source ~/.claude-proxy.sh` (Windows: `. "$HOME\.claude-proxy.ps1"`). Or open a new window. |

### Windows

| Message or symptom | Fix |
|---|---|
| `... is not digitally signed`, or the profile does not load | Type `Unblock-File -Path $PROFILE`. Then make sure that `Get-ExecutionPolicy -Scope CurrentUser` shows `RemoteSigned`. |
| Incorrect characters, or parse errors | The file has an incorrect encoding (Big5 or CP950). Save the file again as **UTF-8**. |
| Installer: `[Warn] Could not write to $PROFILE`, or `Access denied` on Documents | Windows does not let PowerShell write the loader line into `$PROFILE`. The usual cause is **Controlled folder access** in Windows Defender. To allow PowerShell, go to Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell. OneDrive or a company policy can also lock Documents. **You can continue:** the profile is in `~\.claude-proxy.ps1`, and the installer makes a **"Claude Proxy Shell"** shortcut on the Desktop. This shortcut opens PowerShell with `cc` and `cx` loaded. To use normal windows, unlock Documents and run the installer again. You can also add the line by hand: [Set up by hand](proxy-profile.md#step-2--install-the-cccx-profile). |
| `running scripts is disabled on this system`, or a group policy sets `Restricted` | New windows cannot run `$PROFILE`. Use the **"Claude Proxy Shell"** shortcut. To make it, type `proxy-shortcut`. In one window only, you can also type `Invoke-Expression (Get-Content -Raw "$HOME\.claude-proxy.ps1")`. |
| New windows load an OLD profile | `$PROFILE` contains the full profile from before 2.0, not the loader line. `proxy-status --fix` shows this. Type `proxy-update`, or run the installer again. The installer keeps a copy of `$PROFILE` as `.bak` and writes the loader line. |

### macOS, Linux and WSL

| Message or symptom | Fix |
|---|---|
| `lsof: command not found` (Linux / WSL) | From 2.8.0, the profile uses `ss` if `lsof` is not installed. Most systems have `ss`. For older profiles: `sudo apt install lsof` (Debian/Ubuntu) or `sudo dnf install lsof`. |
| SSH asks for the passphrase again and again | On macOS, the setup adds the key to the Keychain. To do this again: `ssh-add --apple-use-keychain ~/.ssh/<your-key>` (macOS) or `ssh-add ~/.ssh/<your-key>` (Linux). |
| **WSL:** `cc` or `cx` stops at once, with no tunnel | A background `ssh` cannot ask for a passphrase, and WSL does not keep an ssh-agent. The profile starts an agent. If the problem continues, type `ssh-add ~/.ssh/<your-key>` one time. Or enable systemd in `/etc/wsl.conf` (`[boot]\nsystemd=true`). |
| **WSL:** the installer shows `No private key found`, but the key is in Downloads | The installer looks in `~/Downloads` in WSL *and* in `C:\Users\*\Downloads`. Your Windows drive can be at a different location than `/mnt/c` (a custom `automount` in `/etc/wsl.conf`). Then type the full path when the installer asks "Full path to your private key". |
| **WSL:** Claude on Windows does not use the tunnel | Type `proxy-config set SYNC_WINDOWS_SETTINGS 1` (it is off by default). Then type `cc` or `proxy-up` again. This needs WSL2 with `localhostForwarding` on (the default), and `cmd.exe` available from WSL (`appendWindowsPath` not disabled). |

## Codex

| Message or symptom | Fix |
|---|---|
| `cx` stops with `account/read failed ... workspace routing discovery failed` | New Codex versions use one shared background server, and this server keeps an old proxy. Type `proxy-update` (2.11.1 or newer). To fix it now, type `codex app-server daemon stop` and start `cx` again. |
| `cx` shows `'codex' not found` | Install Codex: [Install Codex](install-codex.md). On Windows, Codex works best in WSL. |
| Plain `codex` does not use the tunnel | Codex reads only the proxy settings of the terminal. Start it with `cx`, or type `proxy-config set PLAIN_COMMANDS auto`. |

## Installing Node.js, Claude Code and Codex (`cc-install`)

| Message | Fix |
|---|---|
| `Node.js vXX is too old (Claude Code needs 22 or newer)` | Answer **Y**. `cc-install` installs the current LTS version. Windows: winget or the official installer. macOS: Homebrew or the official installer. Linux: nvm or NodeSource. |
| `'node' is still vXX in this window`, or `isn't found in this window yet` | The new program is installed, but this window started before the installation. Open a **new** window and type `cc-install` again. |
| `Global npm packages go to /usr, which needs sudo` (Linux) | Answer **Y**. This is the fix that npm recommends: packages go to `~/.npm-global`, and the profile adds it to your PATH. |
| `… wasn't installed with npm - update it with: claude update` | A different installer installed Claude or Codex (the native installer or Homebrew). Use the command in the message. Then you do not get two copies. |
| `the npm registry can't be reached` | The proxy is not up. Type `proxy-status --fix`, then `cc-install` again. |
| `npm install failed` | Read the npm error above the message. For a network error, type `proxy-status --fix`. For a permission error on Linux, accept the `~/.npm-global` offer. |

## Nodes (several servers)

| Message or symptom | Fix |
|---|---|
| `proxy-nodes` shows *No node catalogue yet* | Type `proxy-nodes --refresh` (`-Refresh`). It downloads from the same GitHub URL as `proxy-update`. If GitHub is blocked, type `proxy-up` first and try again. |
| `Unknown node 'sg'` | The node list does not contain this name, and `~/.ssh/config` has no alias with this name. To get the latest node list, type `proxy-nodes --refresh`. Or add a `Host sg` alias to `~/.ssh/config`: from 2.11, a plain alias works as a node. |
| A node shows `<not provisioned>` | The admin added the node but not its address. You do not have to do anything. |
| `sg tunnel failed to start`, or *Permission denied (publickey)* | Your key is not on that VM. Ask the admin. To examine it, type `ssh sgvpn`. The `Host sgvpn` block in `~/.ssh/config` uses the same `IdentityFile` as `jpvpn`. |
| `[Err] <program> (PID n) is on port 8181, which this node's tunnel uses` | A different program uses a port of the node tunnel. Close that program, or move the node ports with the `proxy-config set NODE_…_BASE` command in the message. |
| `Node '<name>' would use port …, which the default tunnel uses` | The node ports and the main ports are the same. Use the `proxy-config set NODE_…_BASE` command in the message. |
| `The node list has a different host key for <host> than ~/.ssh/known_hosts - kept yours` | The node list (DNS, VM or this guide) names a different SSH host key than the one your computer already trusts. The profile kept yours and added nothing. If your admin rebuilt that VM, type `ssh-keygen -R <host>` and connect one time. Otherwise tell your admin: the node list can be wrong or forged. |
| `Node '<name>' has an invalid host, user or SSH port in the node list` | The node list contains a value that is not a plain host name, user or port. The profile wrote nothing to `~/.ssh/config`. Tell your admin. |
| `proxy-nodes use sg`: `[Node] n session(s) use the default node` | A `cc` or `cx` session uses the default node. It would move to the new node. For one terminal, type `cc --node sg`. To change the default anyway, type `proxy-nodes use sg --force`. |
| `cc --node sg` worked before, but now the default node does not change | From 2.10, `cc --node` changes only that terminal. To change the default, type `proxy-nodes use sg`. |
| `<vm> answered, but doesn't serve the node list yet` | That VM runs the old `ForceCommand` of sshu-manager. Admin: install forge `proxynodes-manager` on that VM with `--sshd`. The profile did not change your setup. |
| `<vm> has no 'claude-proxy-nodes' command` | forge `proxynodes-manager` is not installed on that VM. Or select a different VM that serves the list: `proxy-nodes --from <other vm>`. |
| `Could not get the node list from <vm>: …` | The last line is the error from ssh. Type `ssh <vm>` to examine the connection. The list download cannot ask for a passphrase, so load a key with a passphrase into `ssh-agent`. `proxy-nodes --refresh` also tries the other VMs in your list. |
| `<vm> didn't answer - took the list from <other> instead` | This is for your information only. Your VM did not answer, and a different VM answered. To use that VM permanently, type `proxy-nodes --from <other>`. |
| `No valid 'v=cp1' TXT records at _claude-proxy.<domain>` | The domain is incorrect, or your admin did not publish the records. To examine them, type `dig +short TXT _claude-proxy.<domain>` (Windows: `Resolve-DnsName -Type TXT _claude-proxy.<domain>`). The profile did not change the saved domain or your node list. To save the domain anyway (for example, before the admin publishes the records), add `--force` (`-Force`). To use the list of this guide again, type `proxy-nodes --domain ''`. |
| `PROXY_DOMAIN = '--domain' saved` (Windows, profile 2.2.1 or older) | Old Windows profiles know only `-Domain`. Type `proxy-update`. Then type `proxy-nodes -domain ''` to remove the incorrect value. From 2.2.2, `--domain` also works, and the profile refuses incorrect values. |
| `proxy-nodes` shows `jp`, `sg`, `us` as `<not provisioned>` | This was the old example list of this guide (profile 2.2.1 or older). Type `proxy-update` and `proxy-nodes --refresh`. The list of this guide is now empty. Your nodes come from `proxy-nodes --domain <your company domain>`. |
| `ssh alias 'jpvpn' points to X, the catalogue says Y` | Your alias is older than the domain setup. Change `HostName` in `~/.ssh/config`. Or delete that `Host` block and type `proxy-nodes --refresh`. |
| `Several nodes share slot(s) …` | Two nodes have the same `slot`. Tell your admin. Until the admin corrects it, do not open Chrome through these two nodes at the same time. |

## Chrome (`chrome-proxy`)

| Message or symptom | Fix |
|---|---|
| `chrome-proxy jp --profile work` opens the incorrect profile, or no new window | The profile name is the *folder* name (`chrome-proxy --list` shows it). The name that Chrome shows can be different. `chrome-proxy` must start Chrome for that node. A Chrome window that you started by hand with the same data folder takes priority. |
| `chrome-proxy sg` opens a window, but the window uses the *other* node | Two windows use one profile folder. Chrome ignores a new `--proxy-server` for a folder that is open. The profile uses one folder for each node (`…-jp`, `…-sg`). If you started Chrome by hand, close it and use a different `--user-data-dir` for each node. |
| In the proxied Chrome, a local address (`http://192.168.1.10`, `https://nas.local`, an intranet site) does not open | `chrome-proxy` 2.13.2+ sends the `NO_PROXY` hosts direct. Type `proxy-update`, quit the proxied Chrome, and run `chrome-proxy` again. An intranet domain must be in `NO_PROXY` (`CLAUDE_NO_PROXY="$CLAUDE_NO_PROXY,*.mycorp.example"`, Windows: `NO_PROXY_EXTRA`). A short name without a dot (`http://nas/`) cannot resolve: use its IP or full name. |
| browserleaks.com/webrtc shows your own IP, or the time zone is your own | The Chrome window was open before 2.13.2, so it keeps its old flags. Quit that Chrome (all its windows) and run `chrome-proxy --check`. Windows Chrome always uses the Windows time zone. |
| `You are using an unsupported command-line flag: --host-resolver-rules=...` | Chrome warns about this flag, which keeps DNS lookups in the tunnel. It is expected and harmless; close the bar with **×**. |
| **macOS:** after `chrome-proxy`, the Chrome icon in the Dock opens only the *proxied* Chrome | macOS gives an application one Dock icon. The proxied Chrome got it, because your normal Chrome was not open. The profile did not change your normal profile (the proxied one is in `~/.chrome-proxy-profile-<node>`). To open your normal Chrome as well, type `open -n -a "Google Chrome"`. Or quit the proxied Chrome (`Cmd+Q`) and click the icon again. To prevent this, start your normal Chrome *before* `chrome-proxy`. |

## Two accounts on one computer

Refer to [shared mode](shared-mode.md#when-something-is-wrong).

## Ports

Run `proxy-status`. The saved default ports and active node ports are shown
separately. For example, saved HTTP 8080 with main HTTP 8081 means the current
tunnel uses 8081. A new window keeps using that live tunnel.

`proxy-config edit` shows editable defaults and a snapshot of every running
node's ports. Use `proxy-config use-active` to save the running main ports,
or edit them and run `proxy-restart` to apply the saved values. A restart on
unchanged ports briefly reconnects sessions; `proxy-restart sg` affects sg only.
If local ports change, relaunch affected applications and source
`~/.claude-proxy.sh` in other shells before relaunching. A failed editor or
invalid port does not replace your saved settings.

If a different program holds a port, choose another port in `proxy-config edit`
and run `proxy-restart`. The kill switch refuses a conflicting program rather
than silently moving the proxy. Use `proxy-status --fix` for connection failures and
`proxy-status --debug` for raw recovery records.

On Windows, use `proxy-status -debug` and `proxy-restart -node sg`; reload another
window with `. "$HOME\.claude-proxy.ps1"`. `proxy-config edit` opens Notepad.
If it reports that the file changed in another window, reopen the editor;
the other window's saved changes have been kept. More: [Settings](settings.md).

## Do it by hand

`cc-manual` prints the exact commands for your setup, without running them:
the `ssh` tunnel, a `curl` check, and `claude` / `codex` with the proxy set for
that one start (`cc-manual sg` for node `sg`). Use them when the profile itself
misbehaves; they also show which step fails. Refer to [Manual setup](proxy-manual.md).

## Still stuck?

- Do the [manual steps](proxy-manual.md) one window at a time. They show which part has the problem.
- On the VM, type `webproxy-status` to make sure that tinyproxy works.
- Send the output of `proxy-status --fix` to your admin.
