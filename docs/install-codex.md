# Install Codex

Codex is OpenAI's coding agent for the terminal. Like Claude Code, it needs **Node.js** first, then the **CLI**, then a **sign-in**. Every step ends with a check so you know it worked.

> Already have `codex` working? Skip ahead to **[Proxy setup](proxy-profile.md)** — the `cx` command launches Codex through the same proxy `cc` uses for Claude.

---

## Step 1 — Install Node.js

Same prerequisite as Claude Code. **If you already did [Install Claude Code → Step 1](install-claude.md), skip this** — check with:

```bash
node --version
```

If that prints a version like `v22.x.x`, go to Step 2. Otherwise follow **[Install Claude Code → Step 1](install-claude.md)** for your OS, then come back.

---

## Step 2 — Install the Codex CLI

Same command on every OS:

```bash
npm install -g @openai/codex
```

macOS alternative, if you prefer Homebrew:

```bash
brew install codex
```

> **🪟 Windows note:** Codex works best on Windows inside **WSL** (Ubuntu). Native PowerShell support is newer and rougher — if `codex` misbehaves in PowerShell, run it from a WSL terminal instead (the proxy steps in this guide cover WSL too).

**✅ Check it worked:**

```bash
codex --version
```

You should see a version number — not `command not found`. If it's not found, open a new terminal window and try again.

---

## Step 3 — Sign in

Run Codex once from any folder:

```bash
codex
```

On first run it asks how to sign in — choose **Sign in with ChatGPT** (uses your ChatGPT Plus/Pro/Team plan; a browser window opens).

**Alternative — API key:** if you use OpenAI platform billing instead of a ChatGPT plan, follow the API-key option in the sign-in prompt (or see the [Codex docs](https://developers.openai.com/codex/) for the current flow).

**✅ Check it worked:** after signing in, Codex drops you into its interactive prompt. Type something like `hello`, get a reply, then quit.

> **🌏 Network blocked?** If your network can't reach OpenAI directly, finish the **[proxy setup](proxy-profile.md)** first, then launch Codex with `cx` — it signs in through the proxy.

---

## Next →

- **[Proxy setup — one command](proxy-profile.md)** — connect Claude **and** Codex through the VM proxy (`cc` / `cx`).
- **[Proxy — manual, no profile](proxy-manual.md)** — if you'd rather not install a shell profile.
