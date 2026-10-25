# Install Codex

Codex is the coding agent of OpenAI for the terminal. Like Claude Code, it needs **Node.js**, then the **CLI**, then a **sign-in**. Each step ends with a check.

> **🟢 You possibly do not need this page.** The [installer on the Home page](https://claude-guide.vercel.app/) installs Node.js, Claude Code and Codex as its last step. If you already did the setup, type **`cc-install`**. It examines the three tools, and installs or updates the missing or old ones. It asks before it changes anything. This page shows the manual procedure.
>
> **Do the [proxy setup](proxy-profile.md) first.** On a blocked network, the sign-in (step 3) works only through the proxy. The `cx` command starts Codex through the same tunnel that `cc` uses for Claude. This page uses the `cx` and `proxy-up` commands from the proxy setup.

---

## Step 1: Install Node.js

Codex needs Node.js, the same as Claude Code. **If you did [Install Claude Code → Step 1](install-claude.md), skip this step.** To make sure, type:

```bash
node --version
```

If you see a version, for example `v22.x.x`, go to step 2. If not, do **[Install Claude Code → Step 1](install-claude.md)** for your operating system. Then come back to this page.

---

## Step 2: Install the Codex CLI

Use this command on all operating systems:

```bash
npm install -g @openai/codex
```

> **`npm install` stops, or shows a timeout?** In this terminal, type `proxy-up` first. npm uses the proxy settings that `proxy-up` sets. Then try again.

On macOS, you can also use Homebrew:

```bash
brew install codex
```

> **🪟 Windows:** Codex works best in **WSL** (Ubuntu) on Windows. Its PowerShell support is newer and has more problems. If `codex` does not work correctly in PowerShell, use a WSL terminal. The proxy steps in this guide also include WSL.

**✅ Check:**

```bash
codex --version
```

Make sure that you see a version number, not `command not found`. If you see `command not found`, open a new terminal window and try again.

---

## Step 3: Sign in (through the proxy)

Start Codex through the proxy. On a blocked network, plain `codex` cannot connect to OpenAI for the sign-in.

```bash
cx
```

1. At the first start, Codex asks how you want to sign in. Select **Sign in with ChatGPT**. This uses your ChatGPT Plus, Pro or Team plan. A browser window opens.
2. If the browser page does not open, open the URL with `chrome-proxy`. (The browser does not use the tunnel automatically.) Or use the Chrome commands in [Manual → Browse through the proxy](proxy-manual.md#-optional-browse-through-the-proxy-chrome).

**API key:** if you pay through the OpenAI platform and not through a ChatGPT plan, select the API key option in the sign-in prompt. Refer to the [Codex docs](https://developers.openai.com/codex/) for the current steps.

**✅ Check:** after the sign-in, Codex shows its interactive prompt. Type `hello`, make sure that you get an answer, then quit.

> **Note:** Codex reads only the proxy settings of the terminal. To make plain `codex` use the tunnel too, type `proxy-config set PLAIN_COMMANDS auto`. On a network that does not block OpenAI, plain `codex` can connect directly.

---

## Next

- **[Tips & commands](tips.md)**: daily use of `cc`, `cx`, `cc-stop` and `proxy-doctor`.
- **[Troubleshooting](troubleshooting.md)**: if something does not work correctly.
