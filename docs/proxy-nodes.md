# 🌏 Nodes — JP / SG / US, several VMs per region, several Chrome profiles

Since **v2.1** the profile knows about more than one VM. The list of VMs (the **node catalogue**) comes from one of two places:

- **your company's DNS** (v2.2+): the admin publishes one TXT record per VM under their own domain, and you tell the profile that domain once — see [Nodes from your domain](#-nodes-from-your-domain-dns). Recommended for companies.
- **this guide's `nodes.json`** (default when no domain is set).

Either way you get the same commands:

| You want… | Command |
|-----------|---------|
| to see which nodes exist and which one you're on | `proxy-nodes` |
| **Claude / Codex** to go out through another VM | `proxy-node sg` — or just `cc --node sg` / `cx --node sg` |
| a **Chrome window** through a specific VM — *without* touching what `cc` uses, and with several VMs open at once | `chrome-proxy sg` |
| **another Chrome profile** (other logins) through the **same** VM | `chrome-proxy jp --profile work` (Windows: `-Profile work`) |
| the Chrome profiles that already exist | `chrome-profiles` |
| the node list to come from your company's DNS | `proxy-nodes --domain example.com` (Windows: `-Domain example.com`) |

Nothing changes for people who only use one node: `cc`, `cx` and `chrome-proxy` keep working exactly as before.

> **Profile older than 2.2?** `proxy-update` (settings kept), then `proxy-nodes --refresh` (`-Refresh` on Windows) once. The setup wizard also installs the catalogue when it (re)installs the profile.

---

## How it works

```mermaid
flowchart LR
    cc([cc / cx / chrome-proxy]) -->|main tunnel :8080 + :1080| active([active node, e.g. jpvpn])
    chj([chrome-proxy jp2 · profiles Default, work]) -->|own SOCKS tunnel :1183| jp2([jpvpn2 - 2nd JP VM])
    chu([chrome-proxy us]) -->|own SOCKS tunnel :1182| us([usvpn])
```

- A **node** is one VM, reached through an `~/.ssh/config` alias (`jpvpn`, `jpvpn2`, `sgvpn`, …) — the same kind the setup wizard created for your first server. All of them reuse the **same SSH key and username**; `proxy-nodes --refresh` copies `IdentityFile` and `User` from your existing alias when it writes the new ones.
- **Several VMs in one region** are simply several nodes: `jp`, `jp2`, `jp3` (aliases `jpvpn`, `jpvpn2`, `jpvpn3`), each with its own IP. `proxy-nodes` lists them grouped by region.
- The **active node** is the one `cc` / `cx` (and a plain `chrome-proxy`) use. It's simply `SSH_HOST` in your settings file — `proxy-node <name>` changes it and, if the tunnel is up, restarts it on the new node.
- `chrome-proxy <name>` for a node that is **not** active starts a **second, SOCKS-only tunnel** to that node on its own port (`NODE_SOCKS_BASE` + the node's **slot**: `1180`, `1181`, … — the admin gives every node a fixed slot) and opens Chrome with a **data folder of its own** (`…-jp`, `…-jp2`, …). That's what lets a JP window and an SG window run side by side — Chrome ignores a different `--proxy-server` for a data folder that is already open, so one folder per node is a must.
- **Chrome profiles** live *inside* a node's data folder: `chrome-proxy jp --profile work` opens (or creates) the profile `work` in `…-jp`. Every profile of `jp` goes out through `jp`'s tunnel and IP, but has its own logins, cookies, history and extensions. Profiles you add from Chrome's own profile menu (*Profile 1*, …) work the same way — `chrome-profiles` lists them all. Want a profile on a **different IP**? Put it on another VM: `chrome-proxy jp2 --profile work`.
- `cc-stop` stops everything: the main tunnel **and** every per-node Chrome tunnel. `proxy-status` shows them all.

---

## Commands

```bash
proxy-nodes                        # list: * marks the active node, plus which tunnels are up
proxy-nodes --refresh              # reload the catalogue + create any missing ssh aliases        (Windows: -Refresh)
proxy-nodes --domain example.com   # from now on, take the catalogue from example.com's DNS     (Windows: -Domain example.com)
proxy-nodes --domain ''            # back to this guide's nodes.json

proxy-node                         # show the active node
proxy-node jp2                     # switch Claude/Codex to jp2 (saved in your settings; restarts the tunnel if it's running)
cc --node jp2                      # same as 'proxy-node jp2' followed by 'cc'   (also cx --node, proxy-up --node)

chrome-proxy                       # Chrome through the ACTIVE node (main tunnel, started if needed)
chrome-proxy jp2                   # Chrome through jp2 on its own tunnel + data folder (main tunnel untouched)
chrome-proxy jp --profile work     # ...as Chrome profile 'work' (created on first use)   (Windows: -Profile work, or -p work)
chrome-proxy us -p shop https://x  # ...and open a URL there (any other argument goes to Chrome)
chrome-profiles                    # the profiles of every node (chrome-profiles jp: just jp's)
```

`proxy-nodes` output looks like this:

```
=== Proxy nodes (catalogue: ~/.claude-proxy.nodes.json, from dns:example.com, updated 2026-09-16) ===

  * jp    jpvpn    Japan       jpvpn.example.com              ACTIVE - cc/cx tunnel UP (127.0.0.1:8080 / :1080)
    jp2   jpvpn2   Japan       jpvpn2.example.com             Chrome tunnel UP (:1183)
    sg    sgvpn    Singapore   sgvpn.example.com
    us    usvpn    US          <not provisioned>
```

and `chrome-profiles` like this:

```
=== Chrome profiles per node (data dirs: ~/.chrome-proxy-profile-<node>) ===

  jp (jpvpn)  (Chrome open)
      Default              "Person 1"
      work                 "Work"

  jp2 (jpvpn2)
      Default              "Person 1"
```

`<not provisioned>` means the admin listed the node but hasn't given it an address yet — you can't switch to it until they do.

**Switching nodes while Claude is running:** `proxy-node` restarts the tunnel underneath the *same* local port, so a running `claude` just sees a brief reconnect. Other terminals keep the old node until they reload the profile (`source ~/.claude-proxy.sh`, or a new window).

**Profile names:** letters, digits, space, `.`, `_`, `-`. `default` means Chrome's first profile (`Default`). To delete a profile, use Chrome's own profile menu (or close Chrome and delete its folder inside the node's data folder).

---

## Settings involved

| macOS / Linux key | Windows key | Default | Meaning |
|---|---|---|---|
| `CLAUDE_SSH_HOST` | `SSH_HOST` | `jpvpn` | the active node's alias — what `proxy-node` changes |
| `CLAUDE_PROXY_DOMAIN` | `PROXY_DOMAIN` | *(empty)* | take the catalogue from this domain's DNS instead of this guide — what `proxy-nodes --domain` sets |
| `CLAUDE_NODE_SOCKS_BASE` | `NODE_SOCKS_BASE` | `1180` | first port for per-node Chrome tunnels (a node uses base + its slot). Change it if something else lives on `1180`–`1199` |
| `CLAUDE_CHROME_BIN` | `CHROME_EXE` | *(auto)* | only if Chrome isn't in the usual place (Windows also checks `%LOCALAPPDATA%`) |
| `CLAUDE_PROXY_NODES` *(env only)* | — | `~/.claude-proxy.nodes.json` | where the catalogue is cached |

Chrome data folders: `~/.chrome-proxy-profile-<node>` (macOS), `~/.config/google-chrome-vpn-<node>` (Linux), `C:\ChromeVPNProfile-<node>` (Windows), `C:\wsl-proxy-profile-<node>` (WSL). The first time you run `chrome-proxy` after upgrading from 2.0, the old single folder is renamed to the active node's folder, so your existing logins survive.

---

## No profile? The manual equivalent

One extra `ssh` per VM, SOCKS only, each on its own port — then Chrome with a *different* `--user-data-dir` per VM (add `--profile-directory=<name>` for another profile inside it):

```bash
ssh sgvpn  -N -C -D 1181        # terminal A (keep open)
ssh jpvpn2 -N -C -D 1183        # terminal B (keep open)

# macOS - one Chrome per VM, each with its own data folder
open -n -a "Google Chrome" --args --proxy-server="socks5://127.0.0.1:1181" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" --user-data-dir="$HOME/.chrome-proxy-profile-sg" --no-first-run
open -n -a "Google Chrome" --args --proxy-server="socks5://127.0.0.1:1183" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" --user-data-dir="$HOME/.chrome-proxy-profile-jp2" \
    --profile-directory=work --no-first-run
```

To move **Claude/Codex** to another VM without the profile, just open the [manual Step-1 tunnel](proxy-manual.md) against the other alias (`ssh jpvpn2 -N -C -L 8080:127.0.0.1:8888 -D 1080`) — the env vars in Step 2 stay the same.

---

## 🛠 For admins — nodes from your domain (DNS)

Publishing the node list in **your own DNS** means: no IPs in this public repo, one place (your DNS provider, e.g. Cloudflare) to add, move or remove VMs, and users only ever type your domain.

**1. Give every VM a DNS name** — `A` records, one per VM. The profile's default name is `<alias>.<domain>`:

| Node | Alias (default) | A record (default host) |
|---|---|---|
| `jp` | `jpvpn` | `jpvpn.example.com` |
| `jp2` | `jpvpn2` | `jpvpn2.example.com` |
| `sg` | `sgvpn` | `sgvpn.example.com` |

(The alias is the node name's letters + `vpn` + its digits. Use `alias=` / `host=` in the TXT record when you want something else.) On Cloudflare, keep these records **DNS only** (grey cloud) — SSH can't go through Cloudflare's HTTP proxy.

**2. Publish the list** — one `TXT` record **per VM**, all on the same name `_claude-proxy.example.com`:

```
_claude-proxy.example.com.  TXT  "v=cp1 name=jp  slot=0 region=Japan"
_claude-proxy.example.com.  TXT  "v=cp1 name=sg  slot=1 region=Singapore"
_claude-proxy.example.com.  TXT  "v=cp1 name=us  slot=2 region=US"
_claude-proxy.example.com.  TXT  "v=cp1 name=jp2 slot=3 region=Japan note=Second_JP_VM hostkey=ssh-ed25519:AAAAC3Nza..."
```

| Key | Required | Meaning |
|---|---|---|
| `v=cp1` | ✅ first word | marks the record as a node (other TXT records on that name are ignored) |
| `name` | ✅ | short id users type: `proxy-node jp2`. Letters then digits, no `-` |
| `slot` | ✅ | fixed number `0, 1, 2, …`, **unique**, never reused. The node's Chrome tunnel listens on `NODE_SOCKS_BASE` + slot on every client, so records can be in any order |
| `region` | | label shown in lists; nodes are grouped by it. `_` = space (`Hong_Kong`) |
| `alias` | | `~/.ssh/config` alias to create — default `<letters>vpn<digits>` |
| `host` | | IP or DNS name — default `<alias>.<domain>` |
| `user` | | leave out when every person has their own account ([`sshu-manager`](https://github.com/crayonluffy/forge/tree/main/sshu-manager)) — clients reuse the `User` of their existing alias |
| `ssh` / `proxy` | | SSH port (default `22`) / tinyproxy port (default `8888`) |
| `note` | | free text, `_` = space |
| `hostkey` | | recommended: the VM's host key with `:` instead of the space — `ssh-keyscan -t ed25519 <host> \| cut -d' ' -f2- \| tr ' ' ':'`. Clients pin it in `known_hosts` |

Check what clients will see: `dig +short TXT _claude-proxy.example.com` (Windows: `Resolve-DnsName -Type TXT _claude-proxy.example.com`), or `proxy-doctor`.

**3. Tell users the domain** — once:

```bash
# new users: the wizard asks for it, or pass it up front
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh) --domain example.com
# existing users
proxy-update && proxy-nodes --domain example.com
```

```powershell
# Windows, new users
$env:CLAUDE_PROXY_DOMAIN = 'example.com'; irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
# Windows, existing users
proxy-update; . "$HOME\.claude-proxy.ps1"; proxy-nodes -Domain example.com
```

**Adding a VM later** = one `A` record + one `TXT` record with the next free slot. Users get it on their next `proxy-nodes --refresh`. **Moving a VM** = change its `A` record; nobody has to do anything. **Removing** = delete its TXT record (don't reuse its slot).

**How clients look it up:** `dig` / `host` (macOS / Linux / WSL) or `Resolve-DnsName` (Windows) through the normal resolver, so split-horizon / internal DNS works; if that finds nothing, DNS-over-HTTPS via Cloudflare / Google. The result is cached in `~/.claude-proxy.nodes.json`, so nothing is looked up on `cc`.

> **Why a TXT list and not "guess the names"?** Probing `jpvpn.example.com`, `jpvpn2…`, `jpvpn3…`, `sgvpn…` only finds names someone thought to try, costs a lookup (and a timeout) per guess, can't tell a VM from any other host, carries no slot / region / port / host key, and never notices a removed VM. The TXT list is one lookup that says exactly what exists — and the `A` records still follow the same `jpvpn2.example.com` naming.
>
> **Security:** DNS answers aren't signed unless your zone uses **DNSSEC** (Cloudflare: one click; the DNS-over-HTTPS fallback validates it). Turn it on, and publish `hostkey` so clients pin the right VM. Even a spoofed node never sees your private key or your HTTPS content — but it could see which sites you connect to.

---

## 🛠 For admins — the guide's `nodes.json` (no domain)

Without a domain, the catalogue is [`scripts/nodes.json`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/nodes.json) in this repo (served at `https://claude-guide.vercel.app/scripts/nodes.json` and via the GitHub raw URL the profile already uses for `proxy-update`). **This repo is public** — use placeholders or DNS names there, and prefer the DNS setup above for real addresses. One line per node:

```json
{ "name": "jp2", "alias": "jpvpn2", "host": "jpvpn2.example.com", "user": "", "ssh_port": 22, "proxy_port": 8888, "region": "Japan", "note": "", "hostkey": "ssh-ed25519 AAAA...", "slot": 3 }
```

The fields mean the same as the TXT keys above (`ssh_port` / `proxy_port`, and `hostkey` with a normal space). Rules that matter:

- **Give every node a unique `slot`** and never change it. (Old catalogues without `slot` use the position in the list — then append new nodes at the end and never reorder.)
- **Keep one node object per line** — the shell profile has a `jq`-free fallback parser that relies on it.
- Every VM needs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy) and the users' accounts + public keys. With [`sshu-manager`](https://github.com/crayonluffy/forge/tree/main/sshu-manager) that's `sshu-add --tunnel-only --sync <user>` on the primary node (one key, every node), and `sshu-node-info` prints this node's catalogue line ready to paste.
- Push to `main`; clients pick it up on their next `proxy-nodes --refresh` (or wizard run). Existing aliases are never overwritten — if a node's address changes, `proxy-nodes --refresh` warns and users edit `~/.ssh/config` (or delete that `Host` block and refresh). With DNS names as hosts, this never comes up.
