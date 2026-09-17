# Claude Code + Codex — Setup Guide

Use **Claude Code** and **Codex** from a network that blocks them. You run **one installer**, and after that you just type **`cc`**.

---

## ✅ Before you start

Ask your admin for three things:

1. **Your key file** (for example `alice_ed25519`). Save it in your **Downloads** folder.
2. **The server address** (for example `vpn.example.com`).
3. **Your username** (for example `alice`).

---

## 1️⃣ Run the installer

### 🪟 Windows

Open **PowerShell** (press the Windows key, type `PowerShell`, press Enter), then paste this line and press Enter:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

### 🍎 Mac

Open **Terminal** (press ⌘ + Space, type `Terminal`, press Enter), then paste this line and press Enter:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
```

### 🐧 Linux / WSL

Same line as the Mac, in your terminal.

### What the installer asks

| It asks… | You answer |
|---|---|
| Server IP or hostname | the server address from your admin |
| SSH username | your username from your admin |
| Use this key? | **Enter** (it found the key in Downloads) |
| Anything with `[…]` in it | just press **Enter** — that's the suggested answer |
| Check / install Node.js, Claude Code and Codex now? | **Enter** — it installs whatever is missing (Windows may ask for permission, a Mac may ask for your password) |

When it says **Done!**, close the window.

---

## 2️⃣ Use it

Open a **new** PowerShell / Terminal window and type:

| Type | To start |
|---|---|
| `cc` | **Claude Code** |
| `cx` | **Codex** |

The first time, each one asks you to sign in (your browser opens) — sign in once and you're done.

To continue your last Claude conversation: `cc -c`

---

## 🆘 Something doesn't work?

1. Type **`proxy-doctor`** — it checks everything and tells you exactly what's wrong.
2. Still stuck? **Run the installer again** (step 1) — it's safe, it keeps your settings.
3. Then send your admin what `proxy-doctor` printed.

## 🔄 Keeping up to date

| Type | Updates |
|---|---|
| `proxy-update` | this setup |
| `cc-install` | Node.js, Claude Code and Codex |

---

## 📚 More (optional)

For the curious and for admins — you don't need any of this to use `cc`:

- **[How it works](docs/how-it-works.md)** — the tunnel, why a proxy, security
- **[All commands](docs/proxy-profile.md)** — every command and setting, per OS
- **[Several servers & Chrome profiles](docs/proxy-nodes.md)** — JP / SG / US, `chrome-proxy`
- **[Manual setup](docs/proxy-manual.md)** — the same without the installer
- **[Install Claude Code](docs/install-claude.md)** · **[Install Codex](docs/install-codex.md)** — by hand, step by step
- **[Troubleshooting](docs/troubleshooting.md)** · **[Tips](docs/tips.md)** · **[Updating](docs/upgrading.md)**
