# Claude Code + Codex Guide

Use **Claude Code** and **Codex** from a network that blocks them. They connect through your company's proxy server (a VM) over an SSH tunnel. You run **one installer** one time. After that, you type **`cc`**.

## Before you start

Get these three items from your admin:

1. **Your key file** (for example `alice_ed25519`). Save it in your **Downloads** folder.
2. **The server address** (for example `vpn.example.com`).
3. **Your username** (for example `alice`).

## 1. Run the installer

**Windows:** open **PowerShell** (press the Windows key, type `PowerShell`, press Enter), paste this line and press Enter:

```powershell
irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
```

**macOS, Linux and WSL:** open **Terminal** (on a Mac: press ⌘ + Space, type `Terminal`, press Enter), paste this line and press Enter:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)
```

The installer asks a few questions:

| The installer asks | You answer |
|---|---|
| Server IP or hostname | The server address from your admin. |
| SSH username | Your username from your admin. |
| Use this key? | Press **Enter**. The installer found the key in Downloads. |
| Any other question | Press **Enter**. The text in `[…]` is the recommended answer. |

It also installs Node.js, Claude Code and Codex if they are missing. Windows can ask for permission, and a Mac for your password. When it shows **Done!**, close the window.

## 2. Use it

Open a **new** PowerShell or Terminal window and type:

| Type | To start |
|---|---|
| `cc` | **Claude Code** |
| `cx` | **Codex** |

The first time, each application asks you to sign in in your browser. To continue your last Claude conversation, type `cc -c`.

Claude and Codex never connect without the tunnel. This is the **kill switch**: if plain `claude` shows "connection refused", type `cc`.

## If something does not work

1. Type **`proxy-status --fix`**. It checks each part and tells you the problem and the fix.
2. If the problem continues, run the installer again (step 1). This is safe: it keeps your settings.
3. Send the output of `proxy-status --fix` to your admin.

`cc-help` lists the commands you need, with your current server, ports and tunnel. More: [Troubleshooting](docs/troubleshooting.md).

## Keep it up to date

| Type | To update |
|---|---|
| `proxy-update` | This setup (your settings stay) |
| `cc-install` | Node.js, Claude Code and Codex |
