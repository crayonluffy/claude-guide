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
| Tunnel comes up but Claude/Codex can't reach the API | Confirm the VM runs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy on `:8888`), and that `NO_PROXY_EXTRA` in your settings does **not** include `api.anthropic.com`. |
| `cx` says `'codex' not found` | Install it: [Install Codex](install-codex.md). On Windows, Codex is happiest under WSL. |
| Wizard: `[Warn] Could not write to $PROFILE` / `Access denied` on Documents | Windows blocked PowerShell from adding the one loader line to `$PROFILE` — usually Defender's **Controlled folder access** (Windows Security → Virus & threat protection → Ransomware protection → *Allow an app through Controlled folder access* → add PowerShell), or OneDrive/company policy locking Documents. **Not a blocker:** the profile itself is in `~\.claude-proxy.ps1`, and the wizard creates a **"Claude Proxy Shell"** Desktop shortcut that opens PowerShell with `cc`/`cx` loaded. `proxy-update` works from there too. To use normal windows instead, unblock Documents and re-run the wizard (or add the line by hand: [Set up by hand](proxy-profile.md#step-2--install-the-cccx-profile)). |
| `running scripts is disabled on this system` / execution policy is `Restricted` by group policy | New windows can't run `$PROFILE` at all. Use the **"Claude Proxy Shell"** shortcut (run `proxy-shortcut` to create it) — it loads the profile with `Invoke-Expression`, which the policy doesn't gate. One-off alternative in any window: `Invoke-Expression (Get-Content -Raw "$HOME\.claude-proxy.ps1")`. |
| New windows load an OLD version of the profile | `$PROFILE` still contains the whole pre-v2 profile instead of the loader line (`proxy-doctor` says so). Run `proxy-update` or re-run the wizard: it backs `$PROFILE` up to `.bak` and replaces it with the loader. |
| `cc` says port 8080 `is used by '<app>' … leaving it alone` | Not an error — another program (dev server, Docker, emulator…) has the port, so the tunnel automatically uses the next free one (`8081`, …). To make that permanent: `proxy-config set HTTP_PORT 8090`. |
| `proxy-update` / `proxy-config` : not recognized | Your profile is older than v2.0. Re-run the wizard once (it keeps your settings): `irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 \| iex` |
| `cc -c` starts a *new* session instead of continuing | Same cause — profiles before v2.0 dropped extra arguments. Update as above. |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | A leftover ssh from a dropped connection. Just run `cc` — it kills the stale ssh and starts a fresh tunnel automatically. |
| Setup looks wrong (bad alias, host, key, or profile) | Re-run the wizard: answer **n** to "keep these settings" and every prompt comes pre-filled with the current value, so you only retype what's wrong: `irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 \| iex` |

---

## 🍎 macOS / 🐧 Linux / WSL

| Symptom | Fix |
|---------|-----|
| `lsof: command not found` (Linux / WSL) | Install it: `sudo apt install lsof` (Debian/Ubuntu) or `sudo dnf install lsof`. |
| Tunnel never comes up | Check the log: `cat /tmp/claude-tunnel.log` (auth error vs. network timeout). Also make sure the VM is running [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager). |
| SSH keeps asking for the passphrase | Setup adds the key to the Keychain on macOS. To redo it: `ssh-add --apple-use-keychain ~/.ssh/<your-key>` (macOS) or `ssh-add ~/.ssh/<your-key>` (Linux). |
| **WSL:** `cc`/`cx` returns immediately, no tunnel | A backgrounded `ssh -f` can't answer a passphrase prompt, and WSL has no persistent ssh-agent. The script auto-starts one; if it still fails, run `ssh-add ~/.ssh/<your-key>` once, or enable systemd in `/etc/wsl.conf` (`[boot]\nsystemd=true`). |
| **WSL:** wizard says `No private key found` although it's in Downloads | It looks in WSL's `~/Downloads` *and* `C:\Users\*\Downloads`. If your Windows drive isn't mounted at `/mnt/c` (custom `automount` in `/etc/wsl.conf`), answer the "Full path to your private key" prompt with the mounted path. |
| **WSL:** Windows-side Claude ignores the tunnel | `proxy-config set SYNC_WINDOWS_SETTINGS 1` (the sync is off by default), then `cc`/`proxy-up` again. It needs WSL2 with `localhostForwarding` on (the default) and `cmd.exe` reachable from WSL (`appendWindowsPath` not disabled). |
| `cc`/`cx` exits before launching the app | The tunnel didn't bind. Accept the host key once with `ssh jpvpn`, then retry. |
| `cx` says `'codex' not found` | Install it: [Install Codex](install-codex.md). |
| `cc` says port 8080 `is used by '<app>' … leaving it alone` | Not an error — another program has the port, so the tunnel automatically uses the next free one (`8081`, …). To make that permanent: `proxy-config set HTTP_PORT 8090`. |
| `tunnel-start:6: read-only variable: status` (macOS / zsh) | A bug in profiles before v2.0 — `status` is reserved in zsh. Re-run the wizard once to get the current profile (settings kept). |
| `proxy-update` / `proxy-config` : command not found | Your profile is older than v2.0. Re-run the wizard once (it keeps your settings): `bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)` |
| `cc -c` starts a *new* session instead of continuing | Same cause — profiles before v2.0 dropped extra arguments. Update as above. |
| `proxy-status` shows `Tunnel BROKEN : stale ssh` | A leftover ssh from a dropped connection. Just run `cc` — it kills the stale ssh and starts a fresh tunnel automatically. |
| Tunnel up but Claude can't reach the API | Confirm `CLAUDE_NO_PROXY` does **not** contain `api.anthropic.com`, and that tinyproxy allows CONNECT to 443 (it does by default). |
| Setup looks wrong (bad alias, host, key, or profile) | Re-run the wizard: answer **n** to "keep these settings" and every prompt comes pre-filled with the current value, so you only retype what's wrong: `bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh)` |

---

## 🌏 Nodes (JP / SG / US)

| Symptom | Fix |
|---------|-----|
| `proxy-nodes` says *No node catalogue yet* | `proxy-nodes --refresh` (`-Refresh` on Windows). It downloads from the same GitHub URL as `proxy-update`, so if that is blocked, `proxy-up` first and try again. |
| `Unknown node 'sg'` | Not in the catalogue (yet) — `proxy-nodes --refresh` fetches the latest. A raw alias that exists in `~/.ssh/config` is accepted too. |
| Node shows `<not provisioned>` | The admin listed it but hasn't filled in its address. Nothing to fix on your side. |
| `sg tunnel failed to start` / *Permission denied (publickey)* | Your key isn't on that VM yet — ask the admin. Check with `ssh sgvpn` by hand; the `Host sgvpn` block in `~/.ssh/config` reuses the same `IdentityFile` as `jpvpn`. |
| `Port 1181 (reserved for the sg tunnel) is used by '…'` | Something else lives on `1180`–`1189`: `proxy-config set NODE_SOCKS_BASE 1280` (Windows: same key without prefix). |
| `<vm> answered, but doesn't serve the node list yet` | That VM runs sshu-manager's old `ForceCommand`. Admin: install forge `proxynodes-manager` there with `--sshd`. Nothing was changed on your side. |
| `<vm> has no 'claude-proxy-nodes' command` | forge `proxynodes-manager` isn't installed on that VM — or pick another VM that serves the list: `proxy-nodes --from <other vm>`. |
| `Could not get the node list from <vm>: …` | The last line is ssh's own error. Try `ssh <vm>` by hand; the list is fetched without prompts, so a key with a passphrase must be loaded in `ssh-agent`. `proxy-nodes --refresh` also tries the other VMs in your list. |
| `<vm> didn't answer - took the list from <other> instead` | Just information: your chosen VM was unreachable, another one answered. `proxy-nodes --from <other>` makes it permanent. |
| `No valid 'v=cp1' TXT records at _claude-proxy.<domain>` | The domain is mistyped, or your admin hasn't published the records yet. Check with `dig +short TXT _claude-proxy.<domain>` (Windows: `Resolve-DnsName -Type TXT _claude-proxy.<domain>`). Nothing is changed — neither the saved domain nor your node list; add `--force` (`-Force`) to save the domain anyway, e.g. before the records exist. Back to the guide's list: `proxy-nodes --domain ''`. |
| `PROXY_DOMAIN = '--domain' saved` (Windows, profile 2.2.1 or older) | Older Windows profiles only understood `-Domain`. `proxy-update`, then `proxy-nodes -Domain ''` to clear the bad value; since 2.2.2 `--domain` works too and bad values are refused. |
| `proxy-nodes` lists `jp`, `sg`, `us` as `<not provisioned>` | That was the guide's old example list (profile 2.2.1 or older). `proxy-update` and `proxy-nodes --refresh` — the guide's list is empty now; your nodes come from `proxy-nodes --domain <your company domain>`. |
| `ssh alias 'jpvpn' points to X, the catalogue says Y` | Your alias predates the domain setup. Edit `HostName` in `~/.ssh/config` (or delete that `Host` block and run `proxy-nodes --refresh`). |
| `Several nodes share slot(s) …` | Two published nodes have the same `slot` — tell your admin; until fixed, don't open Chrome through both at once. |
| `chrome-proxy jp --profile work` opens the wrong profile / no new window | The profile name is the *folder* name (`chrome-profiles` shows it) — Chrome's display name may differ. Chrome must be the one started by `chrome-proxy` for that node; a window you opened by hand with the same data folder but other flags wins. |
| `chrome-proxy sg` opens a window but it still uses the *other* node | Two windows share one profile folder — Chrome ignores a new `--proxy-server` for a folder that's already open. The profile uses one folder per node (`…-jp`, `…-sg`); if you launched Chrome by hand, close it and use different `--user-data-dir`s. |
| Switched with `proxy-node`, but another terminal still uses the old node | Each shell loads the settings when it starts: `source ~/.claude-proxy.sh` there (Windows: `. "$HOME\.claude-proxy.ps1"`), or open a new window. |

---

## How the `settings.json` sync works

While the proxy is on, the profile also writes `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` into `~/.claude/settings.json`'s `env` block, so **Claude** picks up the proxy even when launched from a shell that never ran `cc` (an IDE, a GUI, another terminal). `cc-stop` / `proxy-off` removes exactly those keys again, so a down tunnel never leaves Claude pointed at a dead proxy.

- It only touches those three keys and needs [`jq`](https://jqlang.github.io/jq/) on macOS/Linux — the setup wizard installs it (and `lsof`) for you; if `jq` is missing it just skips the file and relies on shell env vars.
- `proxy-config set SYNC_SETTINGS 0` turns it off (that writes `CLAUDE_SYNC_SETTINGS=0` / `SYNC_SETTINGS = 0` into your settings file).
- **Codex** has no such file sync — it reads the `HTTP(S)_PROXY` env vars that `cx` sets, so launch it via `cx` (or from a shell where `proxy-on` ran).

---

## Still stuck?

- Re-check the [manual steps](proxy-manual.md) one window at a time — they isolate exactly which piece fails.
- On the VM, run `webproxy-status` to confirm tinyproxy is healthy.
