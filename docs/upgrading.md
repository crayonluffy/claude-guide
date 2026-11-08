# Updating

## How to get the newest profile

The profile keeps your settings in a separate file: `~/.claude-proxy.conf` (macOS, Linux, WSL) or `~\.claude-proxy.conf.psd1` (Windows). An update does not change this file.

1. Type this command:

   ```bash
   proxy-update            # download and install the newest profile; your settings stay
   proxy-update --check    # only tell me if a newer profile is available (Windows: proxy-update -check)
   proxy-update --version 2.13.3   # install that release, also to go back (Windows: -version 2.13.3)
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

<a id="version-history"></a>What changed in each version: [Changelog](changelog.md).

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

To do this by hand, replace the profile and make the settings file. Write the host alias in it. If tinyproxy on the VM does not use port 8888, also write `CLAUDE_REMOTE_PROXY_PORT`. Refer to [Set up by hand](proxy-profile.md#set-up-by-hand--macos-and-linux):

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
