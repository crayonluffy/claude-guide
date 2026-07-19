# Claude Code + Codex — Install & Proxy Guide

A copy-paste, step-by-step guide to installing **Claude Code** (Anthropic) and **Codex** (OpenAI), and running both through an SSH tunnel to a remote VM proxy.

**How traffic flows once everything is running:**

```mermaid
flowchart LR
    claude([claude / codex]) -->|HTTPS_PROXY :8080| httpf([ssh -L])
    chrome([Chrome]) -->|SOCKS5 :1080| socksf([ssh -D])
    httpf -->|SSH| vm([VM tinyproxy :8888])
    socksf -->|SSH| vm
    vm --> api([Anthropic / OpenAI API / web])
```

After a one-time setup you just type **`cc`** (Claude) or **`cx`** (Codex) and all of that happens automatically.

> **One tunnel, two forwards.** A single SSH connection carries both:
> - **`-L 8080 → VM:8888`** — an HTTP proxy for **Claude & Codex** ([Claude Code doesn't
>   support SOCKS proxies](https://code.claude.com/docs/en/network-config.md), so the HTTP proxy runs on the VM — set it up
>   with [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager)).
> - **`-D 1080`** — a **SOCKS5** proxy for **Chrome** / other apps (full traffic, remote DNS).

---

## 🚀 Start here — follow in order

| | Page | What you'll do | Time |
|---|------|----------------|------|
| 1 | **[Install Claude Code](docs/install-claude.md)** | Node.js → `claude` CLI → sign in | ~5 min |
| 2 | **[Install Codex](docs/install-codex.md)** *(optional)* | `codex` CLI → sign in | ~3 min |
| 3 | **[Proxy setup — one command](docs/proxy-profile.md)** | Run the wizard once, get `cc` / `cx` forever | ~5 min |

Prefer nothing installed in your shell? Use **[Proxy — manual, no profile](docs/proxy-manual.md)** instead of step 3 — the same thing as plain step-by-step commands, fully written out (no collapsed sections).

---

## Daily usage (after setup)

```bash
cc              # proxy ON + launch Claude   (cc-safe keeps permission prompts)
cx              # proxy ON + launch Codex    (cx-safe keeps approval prompts)
proxy-up        # proxy ON, launch nothing
cc-stop         # proxy OFF — one off-switch for both
proxy-status    # what's running + your external IP
proxy-doctor    # something wrong? this says exactly what + how to fix
```

---

## 📚 All pages

- **Install:** [Claude Code](docs/install-claude.md) · [Codex](docs/install-codex.md)
- **Proxy:** [One-command setup (profile)](docs/proxy-profile.md) · [Manual — no profile](docs/proxy-manual.md)
- **Reference:** [🚑 Troubleshooting](docs/troubleshooting.md) · [💡 Tips & commands](docs/tips.md) · [🔄 Upgrading from the old setup](docs/upgrading.md)
