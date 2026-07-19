# Install Claude Code

Claude Code is Anthropic's coding agent that runs in your terminal. Installing it takes two steps: **Node.js** first, then the **CLI itself**. Follow your OS section top to bottom — every step ends with a check so you know it worked.

> **Do the [proxy setup](proxy-profile.md) first.** On a blocked network, signing in (Step 3) only works through the proxy — and if `npm install` times out for you, it needs the proxy too. This page assumes `cc` / `proxy-up` already exist.
>
> Already have `claude` working? Skip ahead to **[Install Codex](install-codex.md)**.

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

> **`npm install` hangs or times out?** Your network blocks the npm registry too. Run `proxy-up` in this terminal first (from the [proxy setup](proxy-profile.md)) — npm respects the proxy env vars it sets — then retry.

**✅ Check it worked:**

```bash
claude --version
```

You should see a version number like `2.x.x`. If you get `command not found`, open a new terminal window and try again.

---

## Step 3 — Sign in (through the proxy)

Launch Claude through the proxy — on a blocked network a plain `claude` can't reach Anthropic to sign in:

```bash
cc
```

On first run it walks you through signing in with your Anthropic account (a browser window opens). After that, you're in.

> **Browser page won't load either?** The sign-in happens in your browser, which doesn't use the tunnel automatically. Open the sign-in URL in a proxied browser instead: run `chrome-proxy` (from the [proxy setup](proxy-profile.md)) and paste the URL there — or use the copy-paste Chrome commands in [Manual → Browse through the proxy](proxy-manual.md#-optional-browse-through-the-proxy-chrome).

> On an unrestricted network you can simply run `claude` directly instead.

---

## Next →

- **[Install Codex](install-codex.md)** — OpenAI's CLI, if you want both.
- **[Tips & commands](tips.md)** — daily usage: `cc`, `cx`, `cc-stop`, `proxy-doctor`.
