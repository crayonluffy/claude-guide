# 🌏 Nodes — JP / SG / US, several VMs per region, several Chrome profiles

From **2.1**, the profile can use more than one VM. The list of VMs is the **node list**. It comes from one of three sources:

| Source | Who can read the list | Command to select it |
|---|---|---|
| 🔒 **One of your VMs, over SSH** (2.3+, **recommended**) | Only persons who can log in to that VM | `proxy-nodes --from jpvpn` (Windows: `-From jpvpn`) |
| 🌐 The **public DNS** of your company (2.2+) | All persons who know the name | `proxy-nodes --domain example.com` (Windows: `-Domain`) |
| The `nodes.json` of this guide (default) | All persons. Thus it is **empty**. | `proxy-nodes --from ''` |

**Why SSH is recommended:** DNS is public. A public list of your proxy VMs makes them easy to find and to block. Over SSH, your key gives access to the list, the list goes through the encrypted connection, and **you select the VM that gives the list**. If that VM is removed, type `proxy-nodes --from sgvpn` to use a different VM. If your VM does not answer, `proxy-nodes --refresh` asks the other VMs in your list (your setting does not change). For the admin part, refer to [For admins](#-for-admins--the-private-list-over-ssh-recommended) and [forge `proxynodes-manager`](https://github.com/crayonluffy/forge/tree/main/proxynodes-manager).

The commands are the same for all sources:

| To do this | Type |
|-----------|---------|
| See the nodes, and the node that you use | `proxy-nodes` |
| Send **Claude and Codex** through a different VM | `proxy-node sg`, or `cc --node sg` / `cx --node sg` |
| Open a **Chrome window** through a specific VM, without a change to `cc`, and with more VMs open at the same time | `chrome-proxy sg` |
| Open a **different Chrome profile** (different logins) through the **same** VM | `chrome-proxy jp --profile work` (Windows: `-Profile work`) |
| See the Chrome profiles | `chrome-profiles` |
| Get the node list (privately) from one of your VMs | `proxy-nodes --from jpvpn` (Windows: `-From jpvpn`). Use a VM that gives the list. |

If you use only one node, nothing changes: `cc`, `cx` and `chrome-proxy` work as before.

> **Your profile is older than 2.3?** Type `proxy-update` (your settings stay). Then type `proxy-nodes --from <your VM alias>` one time. The setup wizard does this for you when it installs the profile and your VM gives the list.

---

## How it works

![How nodes work: cc, cx and a plain chrome-proxy share the main tunnel (-L 8080 + -D 1080) to the active node jpvpn; chrome-proxy jp2 opens its own SOCKS tunnel on :1183 to jpvpn2, a second VM in Japan, and its Chrome profiles Default and work share that tunnel; chrome-proxy us opens :1182 to usvpn. The node list comes from DNS TXT _claude-proxy.example.com or the guide nodes.json.](assets/nodes-flow.svg)

- A **node** is one VM. The profile connects to it through an alias in `~/.ssh/config` (`jpvpn`, `jpvpn2`, `sgvpn`, …). This is the same type of alias that the setup wizard made for your first server. All nodes use the **same SSH key and username**. When `proxy-nodes --refresh` writes a new alias, it copies `IdentityFile` and `User` from your current alias.
- **More VMs in one region** are more nodes: `jp`, `jp2`, `jp3` (aliases `jpvpn`, `jpvpn2`, `jpvpn3`). Each one has its own IP address. `proxy-nodes` shows them in groups by region.
- The **active node** is the node that `cc`, `cx` and a plain `chrome-proxy` use. It is `SSH_HOST` in your settings file. `proxy-node <name>` changes it. If the tunnel is up, `proxy-node` restarts the tunnel on the new node.
- `chrome-proxy <name>` for a node that is **not** active starts a **second tunnel, with SOCKS only**, to that node. This tunnel uses its own port: `NODE_SOCKS_BASE` + the **slot** of the node (`1180`, `1181`, …). The admin gives each node a fixed slot. Chrome opens with **its own data folder** for each node (`…-jp`, `…-jp2`, …). Thus a JP window and an SG window can be open at the same time. (Chrome ignores a different `--proxy-server` for a data folder that is already open. Thus each node needs its own folder.)
- **Chrome profiles** are *in* the data folder of a node. `chrome-proxy jp --profile work` opens the profile `work` in `…-jp` (and makes it if necessary). All profiles of `jp` use the tunnel and the IP address of `jp`, but each profile has its own logins, cookies, history and extensions. Profiles that you add from the profile menu of Chrome (*Profile 1*, …) work the same way. `chrome-profiles` shows all of them. For a profile on a **different IP address**, put it on a different VM: `chrome-proxy jp2 --profile work`.
- `cc-stop` stops all tunnels: the main tunnel **and** the Chrome tunnel of each node. `proxy-status` shows all of them.

---

## Commands

```bash
proxy-nodes                        # the list: * shows the active node, and which tunnels are up
proxy-nodes --refresh              # get the list again + make the missing ssh aliases              (Windows: -Refresh)
proxy-nodes --from jpvpn           # from now on, get the list privately from VM jpvpn over SSH      (Windows: -From jpvpn)
proxy-nodes --from sgvpn           # ...or from a different VM that gives the list (for example, the old VM is removed)
proxy-nodes --domain example.com   # ...or from the PUBLIC DNS of example.com                       (Windows: -Domain)
proxy-nodes --from ''              # use the (empty) list of this guide again
# The profile saves a new source only when it answers; --force (-Force) saves it anyway. Only one source at a time:
# --from removes --domain, and --domain removes --from. The two spellings work on all systems (--from / -From, ...).

proxy-node                         # show the active node
proxy-node jp2                     # move Claude and Codex to jp2 (saved in your settings; restarts the tunnel if it runs)
cc --node jp2                      # the same as 'proxy-node jp2' and then 'cc'   (also cx --node, proxy-up --node)

chrome-proxy                       # Chrome through the ACTIVE node (main tunnel; the profile starts it if necessary)
chrome-proxy jp2                   # Chrome through jp2 on its own tunnel and data folder (no change to the main tunnel)
chrome-proxy jp --profile work     # ...as the Chrome profile 'work' (made at the first use)   (Windows: -Profile work, or -p work)
chrome-proxy us -p shop https://x  # ...and open a URL there (all other arguments go to Chrome)
chrome-profiles                    # the profiles of all nodes (chrome-profiles jp: only the profiles of jp)
```

The output of `proxy-nodes` looks like this:

```
=== Proxy nodes (catalogue: ~/.claude-proxy.nodes.json, from ssh:jpvpn, updated 2026-09-17) ===

  * jp    jpvpn    Japan       jpvpn.example.com              ACTIVE - cc/cx tunnel UP (127.0.0.1:8080 / :1080)
    jp2   jpvpn2   Japan       jpvpn2.example.com             Chrome tunnel UP (:1183)
    sg    sgvpn    Singapore   sgvpn.example.com
    us    usvpn    US          <not provisioned>
```

The output of `chrome-profiles` looks like this:

```
=== Chrome profiles per node (data dirs: ~/.chrome-proxy-profile-<node>) ===

  jp (jpvpn)  (Chrome open)
      Default              "Person 1"
      work                 "Work"

  jp2 (jpvpn2)
      Default              "Person 1"
```

`<not provisioned>` means that the admin added the node to the list, but did not give it an address. You cannot use the node until the admin adds the address. If you have an `ssh` alias for that node, the list shows its address, with `(your alias)`.

**Change the node while Claude runs:** `proxy-node` restarts the tunnel on the *same* local port. A `claude` that runs sees only a short interruption. Other terminals use the old node until they load the profile again (`source ~/.claude-proxy.sh`, or a new window).

**Profile names:** use letters, digits, spaces, `.`, `_` and `-`. `default` is the first profile of Chrome (`Default`). To delete a profile, use the profile menu of Chrome. Or close Chrome and delete the profile folder in the data folder of the node.

---

## Settings for nodes

| macOS / Linux key | Windows key | Default | Meaning |
|---|---|---|---|
| `CLAUDE_SSH_HOST` | `SSH_HOST` | `jpvpn` | The alias of the active node. `proxy-node` changes it. |
| `CLAUDE_NODES_FROM` | `NODES_FROM` | *(empty)* | The VM (ssh alias) that gives the node list over SSH. `proxy-nodes --from` sets it. |
| `CLAUDE_PROXY_DOMAIN` | `PROXY_DOMAIN` | *(empty)* | Get the list from the public DNS of this domain. `proxy-nodes --domain` sets it. |
| `CLAUDE_NODE_SOCKS_BASE` | `NODE_SOCKS_BASE` | `1180` | The first port for the Chrome tunnels of the nodes (a node uses this number + its slot). Change it if a different program uses ports `1180`–`1199`. |
| `CLAUDE_CHROME_BIN` | `CHROME_EXE` | *(auto)* | Set it only if Chrome is not in the usual location (Windows also looks in `%LOCALAPPDATA%`). |
| `CLAUDE_PROXY_NODES` *(environment only)* | — | `~/.claude-proxy.nodes.json` | The location of the saved catalogue. |

Chrome data folders: `~/.chrome-proxy-profile-<node>` (macOS), `~/.config/google-chrome-vpn-<node>` (Linux), `C:\ChromeVPNProfile-<node>` (Windows), `C:\wsl-proxy-profile-<node>` (WSL). When you use `chrome-proxy` for the first time after an upgrade from 2.0, the profile renames the old folder to the folder of the active node. Thus your logins stay.

### Chrome opens `http://sg/` or reports `ERR_SOCKS_CONNECTION_FAILED`

`sg` is a node name, not a website. If Chrome opens `http://sg/`, the `chrome-proxy` command gave the name to Chrome as a URL. It did not select the SG node. Two causes are possible: an old version of the command is still loaded in that PowerShell window, or the catalogue in that window does not contain the node. `proxy-nodes -Refresh` updates the catalogue. It does not update the command.

On Windows, update and load the profile again in the window that has the problem:

```powershell
proxy-update
. "$HOME\.claude-proxy.ps1"
proxy-nodes -From jpvpn    # use your JP SSH alias
chrome-proxy sg -Profile sg https://www.google.com/
```

Make sure that the `[Launch]` line shows `sg`, uses `C:\ChromeVPNProfile-sg`, and usually shows the SOCKS port `1181` (base `1180` + SG slot `1`). If SG is the active node, it can use the main tunnel on port `1080`. Before you try again, close the Chrome windows of that node. A Chrome data folder that is already open keeps its old proxy settings.

If the problem continues, examine the SSH target and the forward from the computer:

```powershell
ssh -G sgvpn | Select-String '^(hostname|user|port|identityfile) '
ssh -N -D 127.0.0.1:1281 -o ExitOnForwardFailure=yes sgvpn
# Keep that terminal open. In a different terminal:
curl.exe --socks5-hostname 127.0.0.1:1281 https://www.cloudflare.com/cdn-cgi/trace
```

The trace must show the IP address of SG.

- `Permission denied`: the SSH username or the key is incorrect.
- A timeout: the network or a firewall blocks the access.
- A good trace, but the browser fails: the problem is the local command, the port, or a Chrome process that is already open.

The commands refuse unknown node names. They do not open them as websites. If a single word is a website, use a full URL, for example `http://localhost/`.

---

## No profile? The manual equivalent

Start one more `ssh` for each VM, with SOCKS only, each on its own port. Then start Chrome with a *different* `--user-data-dir` for each VM. For a different profile in it, add `--profile-directory=<name>`:

```bash
ssh sgvpn  -N -C -D 1181        # terminal A (keep it open)
ssh jpvpn2 -N -C -D 1183        # terminal B (keep it open)

# macOS - one Chrome for each VM, each with its own data folder
open -n -a "Google Chrome" --args --proxy-server="socks5://127.0.0.1:1181" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" --user-data-dir="$HOME/.chrome-proxy-profile-sg" --no-first-run
open -n -a "Google Chrome" --args --proxy-server="socks5://127.0.0.1:1183" \
    --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" --user-data-dir="$HOME/.chrome-proxy-profile-jp2" \
    --profile-directory=work --no-first-run
```

To move **Claude and Codex** to a different VM without the profile, open the [manual step 1 tunnel](proxy-manual.md) to the other alias (`ssh jpvpn2 -N -C -L 8080:127.0.0.1:8888 -D 1080`). The settings of step 2 stay the same.

---

## 🛠 For admins — the private list over SSH (recommended)

The list is a file on one or more of your VMs. A small command, `claude-proxy-nodes`, gives it to each person who can log in. Nothing is published. All the commands below are part of [forge `proxynodes-manager`](https://github.com/crayonluffy/forge/tree/main/proxynodes-manager):

```bash
# on the VM that keeps the list (any VM - you can have more than one)
git clone https://github.com/crayonluffy/forge.git && cd forge
sudo ./proxynodes-manager/install.sh --sshd      # --sshd: tunnel-only accounts can run claude-proxy-nodes (and nothing else)
sudo proxynodes-add jp --self --region Japan     # this VM: the address, host key and ports are filled in automatically
sudo proxynodes-add jp2 --host jpvpn2.example.com --region Japan --hostkey 'ssh-ed25519 AAAA...'
sudo proxynodes-remove jp3                       # remove a VM (its slot is never used again)
proxynodes-list

# on a NEW VM: show the line to paste on the VM that keeps the list
proxynodes-self --name jp2 --region Japan

# a second VM must also give the list (or the first VM will be removed) - from your computer:
ssh jpvpn claude-proxy-nodes | ssh sgvpn sudo proxynodes-import -y
```

The users then type `proxy-nodes --from jpvpn` (or `--from sgvpn`) one time. The setup wizard does this for them.

- **Tunnel-only accounts** (`sshu-add --tunnel-only`) have no shell. `install.sh --sshd` changes their `ForceCommand` to `proxynodes-shell`. It answers `claude-proxy-nodes` and refuses all other commands. Their `ssh -N` tunnels do not change.
- **IP addresses that change:** put DNS names in the list (`--host jpvpn2.example.com`). Let [forge `proxydns-manager`](https://github.com/crayonluffy/forge/tree/main/proxydns-manager) keep the **A record** of each VM current, with `PUBLISH_TXT=0` (then it does not publish a node list). An IP address also works as `--host`, but then you must update the list when the address changes.
- The host key is a *public* key. New computers use it to make sure that they connect to the correct VM, so their first connection does not ask *"Are you sure…"*. It is optional.

---

## 🛠 For admins — nodes from your domain (public DNS)

Use this only if a **public** list is acceptable. When you publish the list in **your own DNS**, you add, move and remove VMs in one location (your DNS provider, for example Cloudflare). Users type only your domain. All persons who know the name can read the list.

**1. Give each VM a DNS name.** Make one `A` record for each VM. The default name in the profile is `<alias>.<domain>`:

| Node | Alias (default) | A record (default host) |
|---|---|---|
| `jp` | `jpvpn` | `jpvpn.example.com` |
| `jp2` | `jpvpn2` | `jpvpn2.example.com` |
| `sg` | `sgvpn` | `sgvpn.example.com` |

The alias is the letters of the node name + `vpn` + its digits. To use a different value, use `alias=` or `host=` in the TXT record. On Cloudflare, set these records to **DNS only** (grey cloud). SSH cannot go through the HTTP proxy of Cloudflare.

**2. Publish the list.** Make one `TXT` record **for each VM**, all on the same name `_claude-proxy.example.com`:

```
_claude-proxy.example.com.  TXT  "v=cp1 name=jp  slot=0 region=Japan"
_claude-proxy.example.com.  TXT  "v=cp1 name=sg  slot=1 region=Singapore"
_claude-proxy.example.com.  TXT  "v=cp1 name=us  slot=2 region=US"
_claude-proxy.example.com.  TXT  "v=cp1 name=jp2 slot=3 region=Japan note=Second_JP_VM hostkey=ssh-ed25519:AAAAC3Nza..."
```

| Key | Necessary | Meaning |
|---|---|---|
| `v=cp1` | ✅ first word | Shows that the record is a node. The profile ignores other TXT records on that name. |
| `name` | ✅ | The short ID that users type: `proxy-node jp2`. Letters, then digits. No `-`. |
| `slot` | ✅ | A fixed number `0, 1, 2, …`. It must be **unique**. Do not use it again. The Chrome tunnel of the node listens on `NODE_SOCKS_BASE` + slot on each computer. Thus the order of the records is not important. |
| `region` | | The label in the lists. The nodes show in groups by region. `_` = space (`Hong_Kong`). |
| `alias` | | The `~/.ssh/config` alias to make. Default: `<letters>vpn<digits>`. |
| `host` | | The IP address or DNS name. Default: `<alias>.<domain>`. |
| `user` | | Do not use it if each person has their own account ([`sshu-manager`](https://github.com/crayonluffy/forge/tree/main/sshu-manager)). Then the computers use the `User` of their current alias. |
| `ssh` / `proxy` | | The SSH port (default `22`) / the tinyproxy port (default `8888`). |
| `note` | | Free text. `_` = space. |
| `hostkey` | | Recommended. The host key of the VM, with `:` in place of the space: `ssh-keyscan -t ed25519 <host> \| cut -d' ' -f2- \| tr ' ' ':'`. The computers add it to `known_hosts`. |

To see what the computers will see, type `dig +short TXT _claude-proxy.example.com` (Windows: `Resolve-DnsName -Type TXT _claude-proxy.example.com`), or `proxy-doctor`.

**3. Tell the users the domain** (one time):

```bash
# new users: the wizard asks for it, or give it at the start
bash <(curl -fsSL https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.sh) --domain example.com
# current users
proxy-update && proxy-nodes --domain example.com
```

```powershell
# Windows, new users
$env:CLAUDE_PROXY_DOMAIN = 'example.com'; irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
# Windows, current users
proxy-update; . "$HOME\.claude-proxy.ps1"; proxy-nodes -Domain example.com
```

- **To add a VM:** add one `A` record and one `TXT` record with the next free slot. Users get it with their next `proxy-nodes --refresh`.
- **To move a VM:** change its `A` record. The users do not have to do anything.
- **To remove a VM:** delete its TXT record. Do not use its slot again.

**How the computers find the list:** `dig` or `host` (macOS / Linux / WSL), or `Resolve-DnsName` (Windows), through the normal resolver. Thus split-horizon and internal DNS work. If the resolver finds nothing, the profile uses DNS-over-HTTPS through Cloudflare or Google. The profile saves the result in `~/.claude-proxy.nodes.json`. Thus `cc` does not look up anything.

> **Why a TXT list, and not a guess of the names?** A guess of `jpvpn.example.com`, `jpvpn2…`, `jpvpn3…`, `sgvpn…` finds only the names that somebody thought of. Each guess costs a lookup (and a timeout). A guess cannot tell a VM from a different host, it has no slot, region, port or host key, and it does not see a removed VM. The TXT list is one lookup that shows all nodes. The `A` records still use the same names (`jpvpn2.example.com`).
>
> **Security:** DNS answers are not signed unless your zone uses **DNSSEC** (Cloudflare: one click; the DNS-over-HTTPS fallback validates it). Set it on, and publish `hostkey` so that the computers connect to the correct VM. A false node never sees your private key or your HTTPS content. But it can see which websites you connect to.

---

## 🛠 For admins — the guide's `nodes.json` (no domain)

Without a domain, the catalogue is [`scripts/nodes.json`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/nodes.json) in this repository. It is available at `https://claude-guide.vercel.app/scripts/nodes.json`, and at the GitHub raw URL that `proxy-update` uses. **This repository is public.** Thus the published list is empty (`"nodes": []`). For real VMs, use the DNS setup above. If you make a private copy of the guide, write one line for each node:

```json
{ "name": "jp2", "alias": "jpvpn2", "host": "jpvpn2.example.com", "user": "", "ssh_port": 22, "proxy_port": 8888, "region": "Japan", "note": "", "hostkey": "ssh-ed25519 AAAA...", "slot": 3 }
```

The fields have the same meaning as the TXT keys above (`ssh_port` / `proxy_port`, and `hostkey` with a normal space). Important rules:

- **Give each node a unique `slot`.** Do not change it. (Old catalogues without `slot` use the position in the list. Then add new nodes at the end and do not change the order.)
- **Write one node object on each line.** The shell profile has a parser without `jq` that needs this.
- Each VM needs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy), and the accounts and public keys of the users. With [`sshu-manager`](https://github.com/crayonluffy/forge/tree/main/sshu-manager), type `sshu-add --tunnel-only --sync <user>` on the primary node (one key, all nodes). `sshu-node-info` shows the catalogue line of this node, ready to paste.
- Push to `main`. The computers get the change with their next `proxy-nodes --refresh` (or wizard run). The profile does not overwrite current aliases. If the address of a node changes, `proxy-nodes --refresh` shows a warning, and the users edit `~/.ssh/config` (or delete that `Host` block and refresh). With DNS names as hosts, this does not occur.
