# Claude Code + Codex — Setup Guide

This guide lets you use **Claude Code** and **Codex** from a network that blocks them.
You run **one installer** one time. After that, you type **`cc`**.

---

## ✅ Before you start

Get these three items from your admin:

1. **Your key file** (for example `alice_ed25519`). Save it in your **Downloads** folder.
2. **The server address** (for example `vpn.example.com`).
3. **Your username** (for example `alice`).

---

## 1️⃣ Run the installer

### 🪟 Windows

1. Open **PowerShell**: push the Windows key, type `PowerShell`, and push Enter.
2. Paste this line, then push Enter:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

### 🍎 Mac

1. Open **Terminal**: push ⌘ + Space, type `Terminal`, and push Enter.
2. Paste this line, then push Enter:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
```

### 🐧 Linux / WSL

Use the Mac line in your terminal.

### The questions of the installer

| The installer asks | You answer |
|---|---|
| Server IP or hostname | The server address from your admin. |
| SSH username | Your username from your admin. |
| Use this key? | Push **Enter**. The installer found the key in Downloads. |
| A question with `[…]` in it | Push **Enter**. The text in `[…]` is the recommended answer. |
| Make plain 'claude' and 'codex' start through the proxy too? | Push **Enter** (recommended). |
| Check / install Node.js, Claude Code and Codex now? | Push **Enter**. The installer installs the missing items. Windows can ask for permission. A Mac can ask for your password. |

When the installer shows **Done!**, close the window.

---

## 2️⃣ Use it

1. Open a **new** PowerShell or Terminal window.
2. Type one of these commands:

| Type | To start |
|---|---|
| `cc` | **Claude Code** |
| `cx` | **Codex** |

The first time, each application asks you to sign in. Your browser opens. Sign in one time.

To continue your last Claude conversation, type `cc -c`.

> **Note:** Claude and Codex do not connect without the tunnel. This is the "kill switch". It prevents a direct connection from your own computer. If plain `claude` shows "connection refused", type `cc`.

---

## 🆘 Something does not work?

1. Type **`proxy-doctor`**. It examines each part and tells you the problem and the fix.
2. If the problem continues, **run the installer again** (step 1). This is safe. The installer keeps your settings.
3. Send the output of `proxy-doctor` to your admin.

## 🔄 Keeping up to date

| Type | To update |
|---|---|
| `proxy-update` | This setup |
| `cc-install` | Node.js, Claude Code and Codex |

---

## 📚 More (optional)

These pages are for admins and for users who want more data. You do not need them to use `cc`:

- **[How it works](docs/how-it-works.md)**: the tunnel, the proxy, and security.
- **[All commands](docs/proxy-profile.md)**: each command and setting, for each operating system.
- **[Several servers & Chrome profiles](docs/proxy-nodes.md)**: JP / SG / US, and `chrome-proxy`.
- **[Manual setup](docs/proxy-manual.md)**: the setup without the installer.
- **[Install Claude Code](docs/install-claude.md)** · **[Install Codex](docs/install-codex.md)**: the installation by hand, step by step.
- **[Troubleshooting](docs/troubleshooting.md)** · **[Tips](docs/tips.md)** · **[Updating](docs/upgrading.md)**
