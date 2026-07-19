# Install Codex

Codex is OpenAI's coding agent for the terminal. Like Claude Code, it needs **Node.js** first, then the **CLI**, then a **sign-in**. Every step ends with a check so you know it worked.

> **Do the [proxy setup](proxy-profile.md) first.** On a blocked network, signing in (Step 3) only works through the proxy — the `cx` command launches Codex through the same tunnel `cc` uses for Claude. This page assumes `cx` / `proxy-up` already exist.

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

> **`npm install` hangs or times out?** Run `proxy-up` in this terminal first — npm respects the proxy env vars it sets — then retry.

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

## Step 3 — Sign in (through the proxy)

Launch Codex through the proxy — on a blocked network a plain `codex` can't reach OpenAI to sign in:

```bash
cx
```

On first run it asks how to sign in — choose **Sign in with ChatGPT** (uses your ChatGPT Plus/Pro/Team plan; a browser window opens). If the browser page won't load either, open the URL via `chrome-proxy` (the browser doesn't use the tunnel automatically).

**Alternative — API key:** if you use OpenAI platform billing instead of a ChatGPT plan, follow the API-key option in the sign-in prompt (or see the [Codex docs](https://developers.openai.com/codex/) for the current flow).

**✅ Check it worked:** after signing in, Codex drops you into its interactive prompt. Type something like `hello`, get a reply, then quit.

> On an unrestricted network you can simply run `codex` directly instead.

---

## Next →

- **[Tips & commands](tips.md)** — daily usage: `cc`, `cx`, `cc-stop`, `proxy-doctor`.
- **[Troubleshooting](troubleshooting.md)** — if anything misbehaves.
