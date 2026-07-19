# 🚑 Troubleshooting

**Start here: run `proxy-doctor`.** It checks each part in turn — `jq`/`lsof`/`codex` present, both tunnel ports listening (and held by the *same* `ssh` process — a mismatch flags a stale leftover, a non-ssh owner flags a port conflict), your shell env vars, whether `settings.json` has the proxy, and finally whether the API is actually reachable *through* the proxy — printing an `[ OK ]` / `[WARN]` / `[FAIL]` line with a concrete fix for each.

**Stale tunnels self-heal.** `cc` / `cx` / `tunnel-start` check the *health* of whatever holds the tunnel port, not just that the port is busy: a healthy tunnel is reused (even one running on a fallback port from an earlier shell), a **stale ssh** (dropped connection, missing SOCKS forward) is killed and restarted automatically, and a **foreign app** on the port is left alone — the tunnel simply falls back to the next free port (`8081`, `8082`, …) and every downstream piece (env vars, `settings.json`, status, doctor) follows it.

If a teardown ever looks stuck, `cc-stop` kills every **ssh** process on both ports (other apps are reported and left alone), escalates to `kill -9`, and tells you if an ssh survived (and how to inspect it) instead of falsely reporting success.

---

## 🪟 Windows

| Symptom | Fix |
|---------|-----|
| `... is not digitally signed` / cannot load profile | Run `Unblock-File -Path $PROFILE`, then confirm `Get-ExecutionPolicy -Scope CurrentUser` is `RemoteSigned`. |
| Garbled characters / parse errors | The file was saved with the wrong encoding (Big5/CP950). Re-save as **UTF-8** (or keep it ASCII-only). |
| SSH hangs or `cc`/`cx` returns immediately with no tunnel | First connection needs the host key accepted. Run `ssh jpvpn` once interactively, type `yes`, then retry. |
| Tunnel comes up but Claude/Codex can't reach the API | Confirm the VM runs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on `:8888`), and that `NO_PROXY_LIST` does **not** include `api.anthropic.com`. |
| `cx` says `'codex' not found` | Install it: [Install Codex](install-codex.md). On Windows, Codex is happiest under WSL. |
| Wizard: `[FAIL] Could not write the profile` / `Access denied` on Documents | Windows blocked PowerShell from writing into Documents — usually Defender's **Controlled folder access** (Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell), or OneDrive/company policy locking the folder. The wizard saves your configured profile to `%TEMP%\Microsoft.PowerShell_profile.ps1` and prints the exact `Copy-Item` command to finish once access is fixed. |
| `cc` says port 8080 `is used by '<app>' … leaving it alone` | Not an error — another program (dev server, Docker, emulator…) has the port, so the tunnel automatically uses the next free one (`8081`, …). To make that permanent, change `$script:HTTP_PORT` at the top of `$PROFILE`. |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | A leftover ssh from a dropped connection. Just run `cc` — it kills the stale ssh and starts a fresh tunnel automatically. |
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
| `cc` says port 8080 `is used by '<app>' … leaving it alone` | Not an error — another program has the port, so the tunnel automatically uses the next free one (`8081`, …). To make that permanent, change `CLAUDE_HTTP_PORT` in `~/.claude-proxy.sh`. |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | A leftover ssh from a dropped connection. Just run `cc` — it kills the stale ssh and starts a fresh tunnel automatically. |
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
