# Settings

Your settings are in a small file that updates never change: `~/.claude-proxy.conf` (macOS, Linux, WSL) or `~\.claude-proxy.conf.psd1` (Windows). A key that is not in the file keeps its default.

```bash
proxy-config                  # show the current values
proxy-config set KEY VALUE    # change one value (for example: proxy-config set HTTP_PORT 8090)
proxy-config edit             # open the file (Windows: Notepad)
```

Kill switch, recovery and alert settings are on [Kill switch, recovery and alerts](kill-switch.md). Node settings are on [Several servers](proxy-nodes.md#settings-for-nodes).

## macOS, Linux and WSL

| Key | Default | Meaning |
|-----|---------|---------|
| `CLAUDE_SSH_HOST` | `"jpvpn"` | The alias from step 1, or a host name or IP address. |
| `CLAUDE_SSH_USER` / `CLAUDE_SSH_KEY` | `""` | Only when `CLAUDE_SSH_HOST` is a host, not an alias. |
| `CLAUDE_SSH_PORT` | `22` | |
| `CLAUDE_HTTP_PORT` | `8080` | The local HTTP port. The tunnel forwards it to the VM proxy (Claude and Codex). |
| `CLAUDE_REMOTE_PROXY_PORT` | `8888` | The tinyproxy port on the VM (webproxy-manager). |
| `CLAUDE_SOCKS_PORT` | `1080` | The local SOCKS5 port (Chrome and other applications). |
| `CLAUDE_NODE_HTTP_BASE` | `8180` | The first HTTP port for the node tunnels (`cc --node <node>`). Refer to [Nodes](proxy-nodes.md). |
| `CLAUDE_NODE_SOCKS_BASE` | `1180` | The first SOCKS port for the node tunnels (`chrome-proxy <node>`). Refer to [Nodes](proxy-nodes.md). |
| `CLAUDE_NODES_FROM` | `""` | The VM that gives the node list over SSH (`proxy-nodes --from` sets it). Refer to [Nodes](proxy-nodes.md). |
| `CLAUDE_PROXY_DOMAIN` | `""` | Get the node list from the public DNS of this domain (`proxy-nodes --domain` sets it). |
| `CLAUDE_CHROME_BIN` | `""` | Set it only if Chrome is not in the usual location (macOS: the application name or path; WSL: `/mnt/c/.../chrome.exe`). |
| `CLAUDE_CHROME_TZ` | `auto` | The time zone of `chrome-proxy`: `auto` (the proxy exit IP's), a zone such as `Asia/Tokyo`, or `off`. Windows Chrome (also from WSL) follows Windows. |
| `CLAUDE_CHROME_BYPASS` | `on` | `on`: `chrome-proxy` reaches the `NO_PROXY` hosts (your local network) directly. `off`: everything goes through the proxy. |
| `CLAUDE_TELEMETRY` | `on` | `off`: `cc` runs Claude with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reports or auto-update). |
| `CLAUDE_SYNC_SETTINGS` | `1` | Also write the proxy into `~/.claude/settings.json` (needs `jq`). `0` stops this. |
| `CLAUDE_SYNC_WINDOWS_SETTINGS` | `0` | **WSL only:** `1` also writes the proxy into the settings of Claude on *Windows* (`%USERPROFILE%\.claude\settings.json`). Refer to [WSL](proxy-profile.md#wsl-windows-subsystem-for-linux). |
| `CLAUDE_KILLSWITCH` | `on` | Claude and Codex cannot connect directly. Refer to [Kill switch](kill-switch.md#kill-switch). |
| `CLAUDE_PLAIN_COMMANDS` | `off` | `auto`: plain `claude` and `codex` also start through the tunnel. |
| `CLAUDE_NO_PROXY` | private ranges, `*.local`, … | The hosts that do not use the proxy. To add more: `CLAUDE_NO_PROXY="$CLAUDE_NO_PROXY,172.20.0.0/24,*.mycorp.example"`. Do not add an API host. |
| `CLAUDE_PROXY_BANNER` | `1` | One line when a new shell opens. `0` stops it. |

## Windows

The same keys without the `CLAUDE_` prefix, in `~\.claude-proxy.conf.psd1`.

| Key | Default | Meaning |
|-----|---------|---------|
| `SSH_HOST` | `'jpvpn'` | The alias from step 1, or a host name or IP address. |
| `SSH_USER` / `SSH_KEY` | `''` | Only when `SSH_HOST` is a host, not an alias. |
| `SSH_PORT` | `22` | |
| `HTTP_PORT` | `8080` | The local HTTP port. The tunnel forwards it to the VM proxy (Claude and Codex). |
| `REMOTE_PROXY_PORT` | `8888` | The tinyproxy port on the VM (webproxy-manager). |
| `SOCKS_PORT` | `1080` | The local SOCKS5 port (Chrome and other applications). |
| `NODE_HTTP_BASE` | `8180` | The first HTTP port for the node tunnels (`cc --node <node>`). Refer to [Nodes](proxy-nodes.md). |
| `NODE_SOCKS_BASE` | `1180` | The first SOCKS port for the node tunnels (`chrome-proxy <node>`). Refer to [Nodes](proxy-nodes.md). |
| `NODES_FROM` | `''` | The VM that gives the node list over SSH (`proxy-nodes -From` sets it). Refer to [Nodes](proxy-nodes.md). |
| `PROXY_DOMAIN` | `''` | Get the node list from the public DNS of this domain (`proxy-nodes -Domain` sets it). |
| `CHROME_EXE` | `''` | Set it only if `chrome.exe` is not in Program Files or `%LOCALAPPDATA%`. |
| `CHROME_BYPASS` | `'on'` | `on`: `chrome-proxy` reaches the `NO_PROXY` hosts (your local network) directly. `off`: everything goes through the proxy. |
| `TELEMETRY` | `'on'` | `off`: `cc` runs Claude with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reports or auto-update). |
| `SYNC_SETTINGS` | `1` | Also write the proxy into `~/.claude/settings.json`. `0` stops this. |
| `KILLSWITCH` | `'on'` | Claude and Codex cannot connect directly. Refer to [Kill switch](kill-switch.md#kill-switch). |
| `PLAIN_COMMANDS` | `'off'` | `'auto'`: plain `claude` and `codex` also start through the tunnel. |
| `NO_PROXY_EXTRA` | `''` | Company intranet ranges or domains that do not use the proxy, for example `'172.20.0.0/24,*.mycorp.example'`. Do not add an API host. |
| `BANNER` | `1` | One line when a new window opens. `0` stops it. |

## Changing your server, user or ports

Your `jpvpn` alias is in `~/.ssh/config`. Thus `ssh jpvpn`, `cc` and `cx` need no key path, user or host. The setup made the alias. If your server IP address or user changes, edit that file. Or run the wizard again, answer **n** to "keep these settings", press Enter for the values that stay, and type only the values that changed.

```
Host jpvpn
    HostName <your-host-or-ip>
    User <your-ssh-user>
    IdentityFile ~/.ssh/<your-key>
    AddKeysToAgent yes
    UseKeychain yes      # macOS only
```

On all platforms, `proxy-config edit` shows editable HTTP, SOCKS, remote proxy
and SSH ports, plus node HTTP/SOCKS base ports. Its header lists every running
node owner's server and HTTP/SOCKS/remote ports, including nodes opened with
`cc --node`, `cx --node` or `chrome-proxy`. That table is informational; check
connection health with `proxy-status`.

Edit `CLAUDE_HTTP_PORT` / `CLAUDE_SOCKS_PORT` for the main tunnel. Other nodes
use `CLAUDE_NODE_HTTP_BASE` / `CLAUDE_NODE_SOCKS_BASE` plus their catalogue slot.
Changing a node base affects subsequent starts of all non-default nodes;
restart each affected node explicitly with `proxy-restart <node>` when ready.

```bash
proxy-config use-active          # save the main tunnel's running ports
proxy-config set HTTP_PORT 8090  # save another port
proxy-restart                   # reconnect main tunnel using saved settings
```

`edit` and `set` save without restarting tunnels. A restart on unchanged ports
briefly reconnects sessions; `proxy-restart sg` affects only sg. If local ports
change, relaunch affected Claude/Codex/Chrome instances because they retain the
old proxy URLs. In other shells, source `~/.claude-proxy.sh` before relaunching.
Conflicts with another active node are rejected before any tunnel is stopped.
A new terminal keeps adopting a running owner's ports until that owner is
restarted. Failed editors or invalid ports leave the saved file unchanged.

To use another alias, save `proxy-config set SSH_HOST other-vm` and run
`proxy-restart`. If your admin publishes more nodes, `proxy-nodes use sg` changes
the default for you. Refer to **[Nodes](proxy-nodes.md)**.

On Windows, the equivalent keys are `HTTP_PORT`, `SOCKS_PORT`,
`REMOTE_PROXY_PORT`, `SSH_PORT`, `NODE_HTTP_BASE` and `NODE_SOCKS_BASE` in
`~\.claude-proxy.conf.psd1`, without the `CLAUDE_` prefix. The same commands
`proxy-config edit`, `proxy-config set HTTP_PORT 8090` and
`proxy-config use-active` work in PowerShell. Restart a specific node with
`proxy-restart -Node sg`; use `proxy-status -Debug` for recovery details.
Notepad edits a temporary copy and the profile validates it before replacing
the saved file. If another window saves first, reopen the editor to include
that change. Configuration files and their comments remain in the native
format for each platform.
