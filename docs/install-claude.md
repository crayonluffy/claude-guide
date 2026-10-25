# Install Claude Code

Claude Code is the coding agent of Anthropic. It runs in your terminal. The installation has two steps: first **Node.js**, then the **CLI**. Do the section for your operating system from the top to the bottom. Each step ends with a check.

> **🟢 You possibly do not need this page.** The [installer on the Home page](https://claude-guide.vercel.app/) installs Node.js, Claude Code and Codex as its last step. If you already did the setup, type **`cc-install`**. It examines the three tools, and installs or updates the missing or old ones. It asks before it changes anything. This page shows the manual procedure.
>
> **Do the [proxy setup](proxy-profile.md) first.** On a blocked network, the sign-in (step 3) works only through the proxy. If `npm install` stops with a timeout, it also needs the proxy. This page uses the `cc` and `proxy-up` commands from the proxy setup.
>
> If `claude` already works, go to **[Install Codex](install-codex.md)**.

---

## Step 1: Install Node.js

Node.js includes `npm`. `npm` installs the CLI. Use the section for **your operating system**.

### 🪟 Windows

In a PowerShell window, install Node.js with `winget`:

```powershell
winget install OpenJS.NodeJS.LTS
```

Or download the installer from [nodejs.org](https://nodejs.org/) and do its steps.

**✅ Check:**

1. Open a **new** PowerShell window. (An old window does not see new programs.)
2. Type these commands:

   ```powershell
   node --version
   npm --version
   ```

3. Make sure that you see version numbers, for example `v22.x.x` or newer. Claude Code needs **Node.js 22 or newer**.

### 🍎 macOS

1. If you do not have [Homebrew](https://brew.sh/), install it:

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. Install Node.js:

   ```bash
   brew install node
   ```

**✅ Check:** type these commands. Make sure that you see version numbers (for example `v22.x.x`), not `command not found`.

```bash
node --version
npm --version
```

### 🐧 Linux

NodeSource publishes current packages. For a specific release, replace `lts` with the release (for example `22.x`). Refer to [github.com/nodesource/distributions](https://github.com/nodesource/distributions).

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

**✅ Check:**

```bash
node --version
npm --version
```

---

## Step 2: Install the Claude Code CLI

Use this command on all operating systems:

```bash
npm install -g @anthropic-ai/claude-code
```

> **`npm install` stops, or shows a timeout?** Your network also blocks the npm registry. In this terminal, type `proxy-up` first (from the [proxy setup](proxy-profile.md)). npm uses the proxy settings that `proxy-up` sets. Then try again.

**✅ Check:**

```bash
claude --version
```

Make sure that you see a version number, for example `2.x.x`. If you see `command not found`, open a new terminal window and try again.

---

## Step 3: Sign in (through the proxy)

Start Claude through the proxy. On a blocked network, plain `claude` cannot connect to Anthropic for the sign-in.

```bash
cc
```

At the first start, Claude shows the sign-in steps for your Anthropic account. A browser window opens. After the sign-in, Claude is ready.

> **The browser page does not open?** The sign-in occurs in your browser. The browser does not use the tunnel automatically. Open the sign-in URL in a browser that uses the proxy: type `chrome-proxy` (from the [proxy setup](proxy-profile.md)) and paste the URL there. Or use the Chrome commands in [Manual → Browse through the proxy](proxy-manual.md#-optional-browse-through-the-proxy-chrome).

> **Note:** With the kill switch on (the default), plain `claude` always uses the tunnel. On a network that does not block Anthropic, you can type `proxy-killswitch off`. Then plain `claude` connects directly.

---

## Next

- **[Install Codex](install-codex.md)**: the CLI of OpenAI, if you want the two tools.
- **[Tips & commands](tips.md)**: daily use of `cc`, `cx`, `cc-stop` and `proxy-doctor`.
