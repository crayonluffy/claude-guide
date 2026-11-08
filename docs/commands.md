# Commands

You only need these eight. `cc` already starts the tunnel, sets the proxy, checks the connection and repairs an old tunnel, so you do not run those steps yourself. `cc-help` shows this list with your current mode, node, ports and tunnel state; `cc-help all` also shows the rest.

| Command | What it does |
|---------|--------------|
| `cc` | Proxy ON, then starts **Claude** (`--dangerously-skip-permissions`). It repairs the tunnel: it stops an old `ssh` and starts a new one. If a different program uses the port, `cc` stops and tells you the fix (kill switch on). With the kill switch off, it uses the next free port. Arguments go to `claude`: `cc -c` continues the last session, `cc -r` shows a list, `cc --resume <id>`, `cc "fix the tests"`. |
| `cx` | The same for **Codex** (no approval prompts). Arguments go to Codex: `cx resume`. |
| `cc --safe` / `cx --safe` | Keeps the app's own permission / approval prompts. |
| `cc --node sg` / `cx --node sg` | Starts Claude or Codex through node `sg` in **this terminal only**. The node has its own self-healing tunnel on fixed ports. Other terminals and the default node do not change. |
| `cc-stop` | Proxy OFF for `cc` and `cx`, for all nodes. It stops each tunnel (other programs stay) and tells you the result. It refuses while Claude or Codex runs in a different window (they use the same tunnel). Use `proxy-restart`, or `cc-stop --force`. `cc-stop sg` stops only node `sg`. |
| `proxy-status` | Shows what runs and its ports. `--debug` (`-Debug` on Windows) adds recovery details. |
| `proxy-status --fix` | Examines each part (tunnel, ports, proxy settings, Claude settings, kill switch, API connection) and tells you each problem and its fix. |
| `proxy-restart` | Replaces the tunnel for **all** terminal windows if it does not work. It does not change the proxy settings or `settings.json`, so Claude and Codex in other tabs continue. `proxy-restart sg` replaces only node `sg`. |
| `proxy-nodes` | Shows the nodes (JP / JP2 / SG / US …) and the active node. `--refresh` (`-Refresh`) gets the catalogue again and makes the `ssh` aliases. `proxy-nodes use sg` makes `sg` the default for `cc` / `cx` (it refuses while a session uses the default node; `--force`). `--from jpvpn` (`-From`) gets the list privately from one of your VMs over SSH (`--domain` / `-Domain`: public DNS). Refer to [Nodes](proxy-nodes.md). |
| `chrome-proxy` | Opens Chrome through the SOCKS5 proxy (a separate profile; it starts the tunnel if necessary). `chrome-proxy sg` uses node `sg` on its **own** tunnel and profile, so more regions can be open at the same time. `chrome-proxy sg https://…` also opens a URL. `--profile work` (`-Profile`) picks a different Chrome profile; `--list` shows the existing ones. |
| `proxy-config` | Shows settings. `edit` includes editable ports and every active node's port snapshot; `use-active` saves the main tunnel's running ports; `set SSH_HOST myvm` saves one value; `killswitch [on\|off]` shows or changes the [kill switch](kill-switch.md#kill-switch). |
| `cc-manual` | **Manual fallback.** Prints, without running anything, the exact `ssh` tunnel command, a `curl` check, and `claude` / `codex` commands with `HTTPS_PROXY` set, so you can do everything by hand if the profile misbehaves. `cc-manual sg` prints them for node `sg` (including the `--settings` override Claude needs for a node). |

## Maintenance and low-level commands

These still work and are listed by `cc-help all`; you rarely need them.

| Command | What it does |
|---------|--------------|
| `proxy-update` | Downloads the newest profile from this guide and installs it. **Your settings stay.** `proxy-update --check` (`-Check` on Windows) only tells you if a newer profile is available. `proxy-update --version 2.13.3` (`-Version` on Windows) installs that release, also an older one. |
| `cc-install` | Examines **Node.js**, **Claude Code** and **Codex**. It installs or updates the missing or old ones (it asks first; the downloads go through the proxy). `cc-install --check` (`-Check`) only reports. `cc-install claude` does only that tool. `-y` answers yes. The setup wizard runs it as its last step. |
| `proxy-up` | Proxy ON (tunnel, proxy settings, IP check), but it does not start an application. |
| `tunnel-start` / `tunnel-stop` | Starts or stops only the SSH tunnel of the default node. `tunnel-start sg` / `tunnel-stop sg` do this for node `sg` only. |
| `proxy-on` / `proxy-off` | Sets or clears the proxy settings in the terminal. With the kill switch on, `~/.claude/settings.json` keeps the proxy. |
| `proxy-notify status` / `proxy-notify test` | Shows if desktop alerts are available / sends one real test alert. It does not change the proxy. |
| `proxy-test prolonged --fast --desktop` | Shows the desktop alerts of an outage and a restore, with simulated network actions. |

## Renamed commands

The old names still work in this release and print the new name.

| Old | New |
|-----|-----|
| `cc-safe`, `cx-safe` | `cc --safe`, `cx --safe` |
| `cx-stop` | `cc-stop` |
| `proxy-doctor` | `proxy-status --fix` |
| `proxy-node sg` | `proxy-nodes use sg` |
| `chrome-profiles` | `chrome-proxy --list` |
| `proxy-killswitch` | `proxy-config killswitch` |
| `bridge-start`, `bridge-stop` | Removed (they did nothing since the VM runs the HTTP proxy). |

> **Codex note:** Codex reads the standard `HTTP(S)_PROXY` settings of the terminal, so it uses the same tunnel. It does not read a settings file. Plain `codex` uses the tunnel only with `PLAIN_COMMANDS=auto`. Claude also gets the proxy in `settings.json`, so plain `claude` uses the tunnel from all shells.
