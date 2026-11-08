# Kill switch, recovery and alerts

What keeps Claude and Codex off your own IP address, how the tunnel heals itself while they run, and how you are told about an outage.

## Kill switch

The kill switch keeps Claude and Codex from connecting directly. When the tunnel is down, they cannot connect. They do not use your own IP address. The kill switch is on by default.

What the kill switch does:

1. It keeps the proxy in Claude's `~/.claude/settings.json`. `proxy-off` and `cc-stop` remove the proxy from your terminal only. Claude reads its settings file before your terminal, so plain `claude` and the IDE extensions use the tunnel. If the tunnel is down, they show "connection refused".
2. It examines each `cc` and `cx` before the start. It stops the start and tells you the fix if:
   - `NO_PROXY` sends an API host directly (for example `*` or `*.com`).
   - Another program uses the proxy port.
   - The profile cannot write the proxy into Claude's settings file.
3. It does not move the tunnel to a different port. If another program uses the proxy port, `tunnel-start` stops and tells you the program and the fix.

Plain `codex` reads only the proxy in your terminal. To protect it, type `proxy-config set PLAIN_COMMANDS auto`. Then plain `claude` and `codex` start through the tunnel, the same as `cc --safe` and `cx --safe`. Only the application writes to the output, so `claude -p "..." | jq` continues to work.

| Command | What it does |
|---|---|
| `proxy-config killswitch` | Shows the status: Claude settings, Codex, `NO_PROXY`. |
| `proxy-config killswitch on` | Sets the kill switch on and writes the proxy into Claude's settings. |
| `proxy-config killswitch off` | Sets the kill switch off. This is the behavior before 2.9.0. |

The kill switch does not protect the Claude Desktop app, web browsers, or other applications. `chrome-proxy` has its own rules. The kill switch is not a firewall: a program that ignores proxy settings can still connect directly.

| Setting (PowerShell) | Bash setting | Default |
|---|---|---|
| `KILLSWITCH` | `CLAUDE_KILLSWITCH` | `on` (all values other than `off` mean on) |
| `PLAIN_COMMANDS` | `CLAUDE_PLAIN_COMMANDS` | `off`. The setup wizard asks. |

## Claude's `settings.json`

The profile writes `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` into the `env` block of `~/.claude/settings.json`. Claude reads this file before the settings of your terminal. Thus Claude uses the proxy, also when you start it from an IDE, a desktop application, or a different terminal.

- With the kill switch on (the default), the profile keeps these keys. `cc-stop` and `proxy-off` do not remove them. If the tunnel is down, Claude cannot connect. It does not connect directly. Refer to [Kill switch](#kill-switch).
- With the kill switch off (`proxy-config killswitch off`), `cc-stop` and `proxy-off` remove the keys.
- The profile changes only these three keys. On macOS and Linux, it needs [`jq`](https://jqlang.github.io/jq/). The setup wizard installs `jq`.
- Before its first change, the profile keeps your file as `settings.json.claude-proxy.orig`. `settings.json.bak` is the copy before the latest change. A `settings.json` that is a symbolic link stays a link.
- To stop this, type `proxy-config set SYNC_SETTINGS 0`. Then only Claude that you start with `cc` uses the proxy.
- **Codex** does not read a settings file. It reads only the proxy settings of the terminal. Start it with `cx`, or set `proxy-config set PLAIN_COMMANDS auto`.

## Recovery while Claude or Codex is running

All terminals use **one recovery owner for each user**. The owner writes a record of the tunnel that it runs (the server, user, key and ports). Each terminal uses this record. Thus a window with old settings uses the tunnel that runs. It does not start a second tunnel on the same ports.

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

Terminal notices default to `quiet`: brief outages produce no messages inside
Claude or Codex. After 60 seconds (`WATCHDOG_NOTICE_AFTER`), each affected
terminal shows one warning. It shows one recovery message when connectivity
returns, and no periodic progress messages. The owner keeps retrying and logs
every event throughout. Desktop alerts are configured separately.

Use `proxy-config set TERMINAL_NOTIFICATIONS off` to suppress routine terminal
notices entirely, or `verbose` for immediate lost/restored and periodic progress
messages. `quiet` restores the default. Authentication, host-key and port-takeover
warnings remain visible in every mode. Reload the profile and relaunch the CLI
to use the new subscriber policy; no proxy restart is needed. Applications that
are already running retain their existing notifier until they exit normally.

The owner does not close the application, send input to it, or change its proxy
settings. You can stop the application in the usual way and continue later. The
recovery does not make sure that the application sends a failed request again.
If necessary, send the request again. If you start an application by hand after
`proxy-up`, recovery works, but that session does not get terminal warnings.

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
| `TERMINAL_NOTIFICATIONS` | `CLAUDE_TERMINAL_NOTIFICATIONS` | `quiet`: prolonged warning once, then recovery once; `verbose` or `off` are also available |
| `WATCHDOG_PROBE_TIMEOUT` | `CLAUDE_WATCHDOG_PROBE_TIMEOUT` | `3` seconds for each check |
| `WATCHDOG_PROGRESS_INTERVAL` | `CLAUDE_WATCHDOG_PROGRESS_INTERVAL` | `30` seconds in logs and verbose terminal mode |
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

## Desktop alerts while the CLI owns the terminal

The profile shows desktop alerts, so a Codex or Claude screen cannot hide the only warning. One shared tunnel owner sends the alerts. More `cc` or `cx` tabs do not make more alerts.

Desktop alerts are quiet by default (`DESKTOP_NOTIFICATIONS = auto`), as the terminal is. A brief drop, for example after the Mac wakes up or the Wi-Fi changes, shows **no** alert: the owner reconnects by itself. Only a long outage alerts you, once, and then its end:

| Condition | Alert | What to do |
|---|---|---|
| The tunnel is still down after the limit (default 60 seconds, `WATCHDOG_NOTICE_AFTER`) | **Proxy still unavailable**: the owner continues to try | Wait, or stop the application in the usual way. |
| It works again after that long outage | **Proxy connection restored**: send a failed request again if necessary | Continue your work. |
| Another program takes the proxy port | **Proxy port taken** (always shown, at once), then **restored** when the tunnel has its port back | Exit the Claude/Codex sessions. |

`DESKTOP_NOTIFICATIONS = verbose` brings back the alert for every drop (**Proxy connection lost**) and every recovery. `off` stops the desktop alerts; the terminal still warns about a long outage.

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

Desktop alerts are `auto` (long outages only) by default. `verbose` shows every drop and recovery. To set them off:

```powershell
proxy-config set DESKTOP_NOTIFICATIONS off
```

```bash
proxy-config set DESKTOP_NOTIFICATIONS off
```

Bash saves this as `CLAUDE_DESKTOP_NOTIFICATIONS=off`. PowerShell saves `DESKTOP_NOTIFICATIONS = 'off'`. To set them on again, use `auto`. Then load the profile again and type `proxy-restart` one time, so that a running owner uses the new setting. This keeps the proxy settings and keeps the sessions open, but you possibly must send requests again. The terminal warnings and the logs stay on when the desktop alerts are off or fail.

The automated tests examine the alert sequence, the command arguments, failed alerts, the cleanup of the notifier, and the isolation of the demonstration. The real display on Windows and macOS, and the Windows tray icon, need the manual check above.
