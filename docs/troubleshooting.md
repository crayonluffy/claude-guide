# 🚑 Troubleshooting

**Start here: run `proxy-doctor`.** It checks each part in turn — `jq`/`lsof`/`codex` present, both tunnel ports listening (and held by the *same* process — a mismatch flags a stale leftover), your shell env vars, whether `settings.json` has the proxy, and finally whether the API is actually reachable *through* the proxy — printing an `[ OK ]` / `[WARN]` / `[FAIL]` line with a concrete fix for each.

If a teardown ever looks stuck, `cc-stop` kills every process on both ports, escalates to `kill -9`, and tells you if anything survived (and how to inspect it) instead of falsely reporting success.

---

## 🪟 Windows

| Symptom | Fix |
|---------|-----|
| `... is not digitally signed` / cannot load profile | Run `Unblock-File -Path $PROFILE`, then confirm `Get-ExecutionPolicy -Scope CurrentUser` is `RemoteSigned`. |
| Garbled characters / parse errors | The file was saved with the wrong encoding (Big5/CP950). Re-save as **UTF-8** (or keep it ASCII-only). |
| SSH hangs or `cc`/`cx` returns immediately with no tunnel | First connection needs the host key accepted. Run `ssh jpvpn` once interactively, type `yes`, then retry. |
| Tunnel comes up but Claude/Codex can't reach the API | Confirm the VM runs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on `:8888`), and that `NO_PROXY_LIST` does **not** include `api.anthropic.com`. |
| `cx` says `'codex' not found` | Install it: [Install Codex](install-codex.md). On Windows, Codex is happiest under WSL. |
| Setup looks wrong (bad alias, host, key, or profile) | Re-run the wizard to redo it cleanly: `irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 \| iex` |

---

## 🍎 macOS / 🐧 Linux / WSL

| Symptom | Fix |
|---------|-----|
| `lsof: command not found` (Linux / WSL) | Install it: `sudo apt install lsof` (Debian/Ubuntu) or `sudo dnf install lsof`. |
| Tunnel never comes up | Check the log: `cat /tmp/claude-tunnel.log` (auth error vs. network timeout). Also make sure the VM is running [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager). |
| SSH keeps asking for the passphrase | Setup adds the key to the Keychain on macOS. To redo it: `ssh-add --apple-use-keychain ~/.ssh/<your-key>` (macOS) or `ssh-add ~/.ssh/<your-key>` (Linux). |
| **WSL:** `cc`/`cx` returns immediately, no tunnel | A backgrounded `ssh -f` can't answer a passphrase prompt, and WSL has no persistent ssh-agent. The script auto-starts one; if it still fails, run `ssh-add ~/.ssh/<your-key>` once, or enable systemd in `/etc/wsl.conf` (`[boot]\nsystemd=true`). |
| `cc`/`cx` exits before launching the app | The tunnel didn't bind. Accept the host key once with `ssh jpvpn`, then retry. |
| `cx` says `'codex' not found` | Install it: [Install Codex](install-codex.md). |
| Tunnel up but Claude can't reach the API | Confirm `CLAUDE_NO_PROXY` does **not** contain `api.anthropic.com`, and that tinyproxy allows CONNECT to 443 (it does by default). |
| Setup looks wrong (bad alias, host, key, or profile) | Re-run the wizard to redo it cleanly: `bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)` |

---

## How the `settings.json` sync works

While the proxy is on, the profile also writes `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` into `~/.claude/settings.json`'s `env` block, so **Claude** picks up the proxy even when launched from a shell that never ran `cc` (an IDE, a GUI, another terminal). `cc-stop` / `proxy-off` removes exactly those keys again, so a down tunnel never leaves Claude pointed at a dead proxy.

- It only touches those three keys and needs [`jq`](https://jqlang.github.io/jq/) on macOS/Linux — the setup wizard installs it (and `lsof`) for you; if `jq` is missing it just skips the file and relies on shell env vars.
- Set `CLAUDE_SYNC_SETTINGS=0` (or `$script:SYNC_SETTINGS = 0` on Windows) to turn it off.
- **Codex** has no such file sync — it reads the `HTTP(S)_PROXY` env vars that `cx` sets, so launch it via `cx` (or from a shell where `proxy-on` ran).

---

## Still stuck?

- Re-check the [manual steps](proxy-manual.md) one window at a time — they isolate exactly which piece fails.
- On the VM, run `webproxy-status` to confirm tinyproxy is healthy.
