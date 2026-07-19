# 🔄 Upgrading from the old (SOCKS + bridge) setup

Earlier versions ran a SOCKS tunnel (`ssh -D`) **plus** an `http-proxy-to-socks` bridge on the client. The new design moves the HTTP proxy onto the VM and drops the bridge, so migrating has three parts:

## 1. On the VM — install the HTTP proxy

This is new; the old setup had nothing here:

```bash
git clone https://github.com/crayonluffy/forge.git    # or: cd forge && git pull
sudo ./forge/webproxy-manager/install.sh              # tinyproxy on 127.0.0.1:8888
```

## 2. On each client — refresh the profile

Re-running the wizard **overwrites** `~/.claude-proxy.sh` (or `$PROFILE`) with the new version, installs `jq`/`lsof`, and asks for the VM proxy port:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)   # macOS / Linux / WSL
```

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex           # Windows
```

Prefer to do it by hand? Overwrite the profile and re-check its Settings block (host alias, and `CLAUDE_REMOTE_PROXY_PORT` if your VM's tinyproxy isn't on 8888):

```bash
curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/claude-proxy.sh -o ~/.claude-proxy.sh
```

## 3. Reload and clear any stale processes

```bash
source ~/.bashrc     # or ~/.zshrc; on Windows just open a new PowerShell window
cc-stop              # the new hardened teardown frees whatever the old tunnel/bridge left on 8080/1080
cc
```

Your SSH key and `~/.ssh/config` alias carry over — nothing to redo there. Leftover old processes are handled automatically: `cc` kills a stale ssh and restarts the tunnel by itself, and if some other app owns the port it just uses the next free one. The wizard fully overwrites `~/.claude-proxy.sh`, so old settings don't linger — and the `-D 1080` SOCKS forward still exists (now used by `chrome-proxy`).

> **Bonus after upgrading:** the refreshed profile also includes **`cx`** — the same one-command launch for [Codex](install-codex.md).
