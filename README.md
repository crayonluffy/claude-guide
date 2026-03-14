# Claude via GCloud VM Proxy Guide

A minimal, copy-paste guide to connecting Anthropic's `claude` CLI to a Google Cloud VM proxy.

### ⚠️ Prerequisites
* **Install Node.js:** [nodejs.org](https://nodejs.org/) (This installs `npm` and `npx` automatically).

---

## 🔑 Quick Start (Windows)

Replace `YOUR_SERVER_IP` with the actual server IP, `YOUR_USERNAME` with your Windows username, and `YOUR_KEY_FILENAME` with your SSH key filename. You need **3 PowerShell windows** open.

### Screenshots

**Step 1 - SSH Tunnel:**

![Step 1 - SSH Tunnel](images/step1-ssh-tunnel.png)

**Step 2 - Bridge:**

![Step 2 - Bridge](images/step2-bridge.png)

**Step 3 - Run Claude:**

![Step 3 - Run Claude](images/step3-run-claude.png)

---

**⚠️ First Time Setup - Fix Key Permissions (Run as Administrator):**
```powershell
$keyPath = "C:\Users\YOUR_USERNAME\.ssh\YOUR_KEY_FILENAME"

icacls $keyPath /inheritance:r
icacls $keyPath /grant:r "$($env:USERNAME):R"
icacls $keyPath /remove "SYSTEM"
icacls $keyPath /remove "Administrators"
```

**Window 1 - SSH Tunnel (keep open):**
```powershell
ssh -i C:\Users\YOUR_USERNAME\.ssh\YOUR_KEY_FILENAME -D 1080 -N -C YOUR_USERNAME@YOUR_SERVER_IP
```

**Window 2 - Bridge (keep open):**
```powershell
npx http-proxy-to-socks -p 8080 -s 127.0.0.1:1080
```

**Window 3 - Run Claude:**
```powershell
$env:http_proxy="http://127.0.0.1:8080"
$env:HTTP_PROXY="http://127.0.0.1:8080"
$env:https_proxy="http://127.0.0.1:8080"
$env:HTTPS_PROXY="http://127.0.0.1:8080"

# Verify connectivity (Optional)
curl ipinfo.io

# Launch
claude

# Launch (skip permission prompts)
claude --dangerously-skip-permissions
```

---

##  Mac / Linux Users

### 1. The Tunnel (Keep Terminal Open)
Run this to create a local SOCKS proxy at port `1080` that tunnels through your VM.
```bash
# -D 1080: Listen locally on port 1080
# -N: Do not execute remote commands (just forward ports)
# -C: Compress data for speed
ssh -i ~/.ssh/your_ssh_key -D 1080 -N -C username@gcloud_vm_ip
````

### 2\. The Bridge (Keep Terminal Open)

Run this to convert the SOCKS proxy (`1080`) to an HTTP proxy (`8080`) so `npm` and `claude` can use it.

```bash
npx http-proxy-to-socks -p 8080 -s 127.0.0.1:1080
```

### 3\. Install & Run

Run these commands in a **new** terminal window.

**Step A: Configure NPM & Install**

```bash
# Install Claude Code globally
npm install -g @anthropic-ai/claude-code
```

**Step B: Run Claude**

```bash
# Set environment variables for this session ONLY
export http_proxy=http://127.0.0.1:8080
export HTTP_PROXY=http://127.0.0.1:8080
export https_proxy=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080

# Verify connectivity (Optional but recommended)
curl ipinfo.io

# Launch
claude

# Launch (skip permission prompts)
claude --dangerously-skip-permissions
```

-----

## ⊞ Windows Users (PowerShell)

### 1\. The Tunnel (Keep PowerShell Open)

Run this to create a local SOCKS proxy at port `1080`.

```powershell
ssh -i C:\path\to\key -D 1080 -N -C username@gcloud_vm_ip
```

### 2\. The Bridge (Keep PowerShell Open)

Run this to convert the SOCKS proxy (`1080`) to an HTTP proxy (`8080`).

```powershell
npx http-proxy-to-socks -p 8080 -s 127.0.0.1:1080
```

### 3\. Install & Run

Run these commands in a **new** PowerShell window.

**Step A: Configure NPM & Install**

```powershell
# Install Claude Code globally
npm install -g @anthropic-ai/claude-code
```

**Step B: Run Claude**

```powershell
# Set environment variables for this session ONLY
$env:http_proxy="http://127.0.0.1:8080"
$env:HTTP_PROXY="http://127.0.0.1:8080"
$env:https_proxy="http://127.0.0.1:8080"
$env:HTTPS_PROXY="http://127.0.0.1:8080"

# Verify connectivity (Optional but recommended)
curl ipinfo.io

# Launch
claude

# Launch (skip permission prompts)
claude --dangerously-skip-permissions
```

---

## 📖 Useful Claude Code Commands & Tips

### CLI Flags

| Flag | Description |
|------|-------------|
| `claude` | Start interactive session |
| `claude "query"` | Start session with initial prompt |
| `claude -c` | Continue most recent conversation |
| `claude -r` | Resume a previous session |
| `claude -p "query"` | Non-interactive mode (print and exit) |
| `claude --model sonnet` | Use a specific model (`sonnet`, `opus`, `haiku`) |
| `claude --effort high` | Set effort level (`low`, `medium`, `high`, `max`, `auto`) |
| `claude --dangerously-skip-permissions` | Skip all permission prompts |
| `claude --max-turns 5` | Limit agentic turns (print mode) |
| `claude --verbose` | Enable verbose logging |
| `claude update` | Update to latest version |
| `claude --version` | Show version number |

### Slash Commands (Inside Interactive Mode)

| Command | Purpose |
|---------|---------|
| `/help` | Show help and available commands |
| `/clear` | Clear conversation history |
| `/compact` | Compact conversation to free context |
| `/model` | Change AI model |
| `/effort` | Set effort level |
| `/config` | Open settings interface |
| `/status` | Show version, model, account info |
| `/doctor` | Diagnose installation issues |
| `/diff` | Review uncommitted code changes |
| `/cost` | Show token usage statistics |
| `/context` | Visualize context window usage |
| `/memory` | Edit project CLAUDE.md |
| `/vim` | Toggle Vim editing mode |
| `/init` | Initialize project with CLAUDE.md |
| `/export` | Export conversation as text |
| `/copy` | Copy last response to clipboard |
| `/resume` | Resume a previous session |
| `/fork` | Branch current conversation |
| `/rewind` | Undo bad edits and restore previous code |
| `/plan` | Enter plan mode (analysis without execution) |
| `/bug` | Submit feedback about Claude Code |

### Keyboard Shortcuts

| Shortcut | Description |
|----------|-------------|
| `Ctrl+C` | Cancel current generation |
| `Ctrl+D` | Exit Claude Code |
| `Ctrl+L` | Clear terminal screen |
| `Shift+Tab` | Toggle permission modes |
| `Esc + Esc` | Rewind conversation |
| `\ + Enter` | New line in input |
| `Ctrl+G` | Open prompt in external editor |
| `Alt+P` | Switch model |
| `Alt+T` | Toggle extended thinking |

### Configuration

**Settings file locations:**
- **User:** `~/.claude/settings.json` (applies to all projects)
- **Project:** `.claude/settings.json` (shared with team)
- **Local:** `.claude/settings.local.json` (personal, gitignored)

**Example `settings.json`:**
```json
{
  "model": "claude-sonnet-4-6",
  "permissions": {
    "allow": ["Bash(npm run test *)", "Read"],
    "deny": ["Bash(curl *)"]
  },
  "attribution": {
    "commit": "",
    "pr": ""
  }
}
```

**CLAUDE.md** — Create at project root to give Claude persistent context about your project (coding standards, architecture, common commands, etc.). It loads automatically when Claude starts.

### Tips

- Use `/compact` when context gets full to summarize and free up space
- Use `claude -p "query" | command` to pipe Claude output into other tools
- Pipe files into Claude: `cat logs.txt | claude -p "summarize errors"`
- Use `/rewind` or `Esc+Esc` to undo bad changes
- Use `/diff` to review all changes before committing
- Name sessions with `claude -n "feature-name"` for easy resuming later
- Use `/plan` mode to analyze code safely without making changes
- Run `/doctor` if something isn't working right
