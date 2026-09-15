# 🔄 Updating & upgrading

## Getting the newest profile (any time)

> **New in v2.1 — nodes.** After `proxy-update`, run `proxy-nodes --refresh` (`-Refresh` on Windows) once to download the node catalogue (JP / SG / US …). Then `proxy-node sg` moves Claude/Codex to another region and `chrome-proxy sg` opens a Chrome through it — several regions at once. Your existing `jpvpn` alias, settings and Chrome logins carry over (the Chrome profile folder is renamed to `…-<node>` on first use). Details: **[Nodes](proxy-nodes.md)**.

Since **v2.0** the profile keeps your settings in a separate file (`~/.claude-proxy.conf`, or `~\.claude-proxy.conf.psd1` on Windows), so updating never touches them:

```bash
proxy-update            # fetch + install the newest profile, settings kept
proxy-update --check    # only report whether a newer one exists  (Windows: proxy-update -Check)
```

Open a new terminal afterwards (or `source ~/.claude-proxy.sh` / `. $PROFILE`). Re-running the setup wizard does the same: it finds your settings and asks *"Keep these settings and only update the cc/cx profile?"*.

**Profile older than v2.0 (no `proxy-update` command, settings still inside the script)?** Re-run the wizard once — it reads the settings out of the old profile, saves them to the settings file, and installs the new profile. From then on `proxy-update` exists. The previous profile is kept next to the new one as `.bak`. On Windows the profile code moves from `$PROFILE` (Documents) to `~\.claude-proxy.ps1`, and `$PROFILE` keeps only a one-line loader — if Documents is locked, the wizard makes a Desktop shortcut instead.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)   # macOS / Linux / WSL
```

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex           # Windows
```

---

## Upgrading from the old (SOCKS + bridge) setup

Earlier versions ran a SOCKS tunnel (`ssh -D`) **plus** an `http-proxy-to-socks` bridge on the client. The new design moves the HTTP proxy onto the VM and drops the bridge, so migrating has three parts:

## 1. On the VM — install the HTTP proxy

This is new; the old setup had nothing here:

```bash
git clone https://github.com/crayonluffy/forge.git    # or: cd forge && git pull
sudo ./forge/webproxy-manager/install.sh              # tinyproxy on 127.0.0.1:8888
```

## 2. On each client — refresh the profile

Re-running the wizard replaces `~/.claude-proxy.sh` (or `$PROFILE`) with the new version, installs `jq`/`lsof`, and asks for the VM proxy port (your existing answers are pre-filled):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)   # macOS / Linux / WSL
```

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex           # Windows
```

Prefer to do it by hand? Overwrite the profile and create the settings file (host alias, and `CLAUDE_REMOTE_PROXY_PORT` if your VM's tinyproxy isn't on 8888) — see [Set up by hand](proxy-profile.md#set-up-by-hand--macos--linux):

```bash
curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/claude-proxy.sh -o ~/.claude-proxy.sh
```

## 3. Reload and clear any stale processes

```bash
source ~/.bashrc     # or ~/.zshrc; on Windows just open a new PowerShell window
cc-stop              # the new hardened teardown frees whatever the old tunnel/bridge left on 8080/1080
cc
```

Your SSH key and `~/.ssh/config` alias carry over — nothing to redo there. Leftover old processes are handled automatically: `cc` kills a stale ssh and restarts the tunnel by itself, and if some other app owns the port it just uses the next free one. The `-D 1080` SOCKS forward still exists (now used by `chrome-proxy`).

> **Bonus after upgrading:** the refreshed profile also includes **`cx`** — the same one-command launch for [Codex](install-codex.md).
