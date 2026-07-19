# Install Claude Code

Claude Code is Anthropic's coding agent that runs in your terminal. Installing it takes two steps: **Node.js** first, then the **CLI itself**. Follow your OS section top to bottom — every step ends with a check so you know it worked.

> Already have `claude` working? Skip ahead to **[Install Codex](install-codex.md)** or **[Proxy setup](proxy-profile.md)**.

---

## Step 1 — Install Node.js

Node.js ships with `npm`, which installs the CLI. Pick **your OS** below.

### 🪟 Windows

Install with `winget` from a PowerShell window:

```powershell
winget install OpenJS.NodeJS.LTS
```

Or download the installer from [nodejs.org](https://nodejs.org/) and click through it.

**✅ Check it worked** — open a **new** PowerShell window (the old one doesn't see new programs):

```powershell
node --version
npm --version
```

You should see version numbers like `v22.x.x` — not an error.

### 🍎 macOS

If you don't have [Homebrew](https://brew.sh/) yet, install it first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install Node.js:

```bash
brew install node
```

**✅ Check it worked:**

```bash
node --version
npm --version
```

You should see version numbers like `v22.x.x` — not `command not found`.

### 🐧 Linux

NodeSource publishes up-to-date packages (replace `lts` with e.g. `22.x` for a specific release — see [github.com/nodesource/distributions](https://github.com/nodesource/distributions)):

```bash
# Debian / Ubuntu
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
```

```bash
# Fedora / RHEL / Rocky
curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
sudo dnf install -y nodejs
```

**✅ Check it worked:**

```bash
node --version
npm --version
```

---

## Step 2 — Install the Claude Code CLI

Same command on every OS:

```bash
npm install -g @anthropic-ai/claude-code
```

**✅ Check it worked:**

```bash
claude --version
```

You should see a version number like `2.x.x`. If you get `command not found`, open a new terminal window and try again.

---

## Step 3 — Sign in

Run Claude Code once from any folder:

```bash
claude
```

On first run it walks you through signing in with your Anthropic account (a browser window opens). After that, you're in.

> **🌏 Network blocked?** If your network can't reach `api.anthropic.com` directly (that's why this guide exists), finish the **[proxy setup](proxy-profile.md)** first, then launch Claude with `cc` — it signs in through the proxy.

---

## Next →

- **[Install Codex](install-codex.md)** — OpenAI's CLI, if you want both.
- **[Proxy setup — one command](proxy-profile.md)** — connect Claude through the VM proxy.
