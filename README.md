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
