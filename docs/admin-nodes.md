# Node lists (for admins)

How an admin publishes the list of proxy servers (nodes) that `proxy-nodes --refresh` downloads. Users only need [Several servers](proxy-nodes.md).

## The private list over SSH (recommended)

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

## Nodes from your domain (public DNS)

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
| `name` | ✅ | The short ID that users type: `proxy-nodes use jp2`. Letters, then digits. No `-`. |
| `slot` | ✅ | A fixed number `0, 1, 2, …`. It must be **unique**. Do not use it again. The Chrome tunnel of the node listens on `NODE_SOCKS_BASE` + slot on each computer. Thus the order of the records is not important. |
| `region` | | The label in the lists. The nodes show in groups by region. `_` = space (`Hong_Kong`). |
| `alias` | | The `~/.ssh/config` alias to make. Default: `<letters>vpn<digits>`. |
| `host` | | The IP address or DNS name. Default: `<alias>.<domain>`. |
| `user` | | Do not use it if each person has their own account ([`sshu-manager`](https://github.com/crayonluffy/forge/tree/main/sshu-manager)). Then the computers use the `User` of their current alias. |
| `ssh` / `proxy` | | The SSH port (default `22`) / the tinyproxy port (default `8888`). |
| `note` | | Free text. `_` = space. |
| `hostkey` | | Recommended. The host key of the VM, with `:` in place of the space: `ssh-keyscan -t ed25519 <host> \| cut -d' ' -f2- \| tr ' ' ':'`. The computers add it to `known_hosts`. |

To see what the computers will see, type `dig +short TXT _claude-proxy.example.com` (Windows: `Resolve-DnsName -Type TXT _claude-proxy.example.com`), or `proxy-status --fix`.

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
proxy-update; . "$HOME\.claude-proxy.ps1"; proxy-nodes -domain example.com
```

- **To add a VM:** add one `A` record and one `TXT` record with the next free slot. Users get it with their next `proxy-nodes --refresh`.
- **To move a VM:** change its `A` record. The users do not have to do anything.
- **To remove a VM:** delete its TXT record. Do not use its slot again.

**How the computers find the list:** `dig` or `host` (macOS / Linux / WSL), or `Resolve-DnsName` (Windows), through the normal resolver. Thus split-horizon and internal DNS work. If the resolver finds nothing, the profile uses DNS-over-HTTPS through Cloudflare or Google. The profile saves the result in `~/.claude-proxy.nodes.json`. Thus `cc` does not look up anything.

> **Why a TXT list, and not a guess of the names?** A guess of `jpvpn.example.com`, `jpvpn2…`, `jpvpn3…`, `sgvpn…` finds only the names that somebody thought of. Each guess costs a lookup (and a timeout). A guess cannot tell a VM from a different host. It has no slot, region, port or host key. It does not see a removed VM. The TXT list is one lookup that shows all nodes. The `A` records still use the same names (`jpvpn2.example.com`).
>
> **Security:** DNS answers are not signed unless your zone uses **DNSSEC** (Cloudflare: one click; the DNS-over-HTTPS fallback validates it). Set it on, and publish `hostkey` so that the computers connect to the correct VM. A false node never sees your private key or your HTTPS content. But it can see which websites you connect to.

---

## The guide's `nodes.json` (no domain)

Without a domain, the catalogue is [`scripts/nodes.json`](https://github.com/crayonluffy/claude-guide/blob/main/scripts/nodes.json) in this repository. It is available at `https://claude-guide.vercel.app/scripts/nodes.json`, and at the GitHub raw URL that `proxy-update` uses. **This repository is public.** Thus the published list is empty (`"nodes": []`). For real VMs, use the DNS setup above. If you make a private copy of the guide, write one line for each node:

```json
{ "name": "jp2", "alias": "jpvpn2", "host": "jpvpn2.example.com", "user": "", "ssh_port": 22, "proxy_port": 8888, "region": "Japan", "note": "", "hostkey": "ssh-ed25519 AAAA...", "slot": 3 }
```

The fields have the same meaning as the TXT keys above (`ssh_port` / `proxy_port`, and `hostkey` with a normal space). Important rules:

- **Give each node a unique `slot`.** Do not change it. (Old catalogues without `slot` use the position in the list. Then add new nodes at the end and do not change the order.)
- **Write one node object on each line.** The shell profile has a parser without `jq` that needs this.
- Each VM needs [`webproxy-manager`](https://github.com/crayonluffy/forge/tree/main/webproxy-manager) (tinyproxy), and the accounts and public keys of the users. With [`sshu-manager`](https://github.com/crayonluffy/forge/tree/main/sshu-manager), type `sshu-add --tunnel-only --sync <user>` on the primary node (one key, all nodes). `sshu-node-info` shows the catalogue line of this node, ready to paste.
- Push to `main`. The computers get the change with their next `proxy-nodes --refresh` (or wizard run). The profile does not overwrite current aliases. If the address of a node changes, `proxy-nodes --refresh` shows a warning, and the users edit `~/.ssh/config` (or delete that `Host` block and refresh). With DNS names as hosts, this does not occur.
