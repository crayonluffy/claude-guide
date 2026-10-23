# Kill switch, per-node tunnels, and watchdog fixes

## Agreed intent

Three changes to both launchers (PowerShell for Windows; Bash/zsh for macOS,
Linux and WSL), shipped as three PRs with one shared version number:

1. **2.8.0 - watchdog fixes.** Repair the remaining defects in the 2.6/2.7
   recovery owner and key it by node, so later work builds on a sound base.
2. **2.9.0 - app-level kill switch.** Claude and Codex fail closed: when the
   tunnel is down they cannot connect, instead of going out from the user's
   real IP.
3. **2.10.0 - parallel node tunnels.** Several nodes up at once; each terminal
   chooses its node (`cc --node sg`) without disturbing the others.

Out of scope: OS firewall rules, full-device VPN-style blocking, automatic
failover between nodes, the Claude Desktop app.

## Facts this design relies on

- `~/.claude/settings.json` `env` **overrides** the shell environment, and
  `claude --settings '<json>'` overrides settings.json. Verified on 2.1.309
  with two local listeners: shell `HTTPS_PROXY` :18081 vs settings :18082 ->
  only :18082 received CONNECTs; settings :18082 vs `--settings` :18083 ->
  only :18083. A per-terminal node for Claude therefore MUST use `--settings`.
- Codex reads only `HTTP(S)_PROXY`/`NO_PROXY` from the environment.
- With a proxy configured, Claude and Codex never fall back to a direct
  connection: a dead local port is "connection refused". Leaks come from (a)
  the proxy setting being absent, (b) `NO_PROXY` exempting API hosts, or (c)
  a different program listening on the proxy port.

## Part 1 - architecture (one tunnel + one owner per node)

A **node** is a catalogue entry (jp, sg ...) or, for users without a
catalogue, the configured server. Every node can have one tunnel: a single
ssh carrying `-L <http>:127.0.0.1:<remote proxy>` and `-D <socks>`, supervised
by its own recovery owner.

- **Ports.** The default node uses `HTTP_PORT`/`SOCKS_PORT` (8080/1080), so
  existing settings and docs stay valid. Catalogue node *i* (0-based) uses
  `NODE_HTTP_BASE + i` / `NODE_SOCKS_BASE + i` (8180+i / 1180+i - today's
  Chrome SOCKS scheme plus an HTTP forward). The default node always uses
  the main ports even though it also has a catalogue index. Ports are fixed
  per node and never change during recovery.
- **Identity.** The owner directory is keyed by **user + node name**, not by
  host and ports. Host, user, ports and remote proxy port are written into
  the owner record at start; every terminal reads them from there instead of
  recomputing from its own (possibly stale) settings.
- **Chrome.** `chrome-proxy <node>` uses that node's tunnel (its SOCKS
  forward). The separate SOCKS-only Chrome ssh goes away.
- **Commands.**

| Command | Behaviour |
|---|---|
| `cc` / `cx` | Default node, as today |
| `cc --node sg` / `cx --node sg` | This terminal only, through sg. Previously this switched the default and restarted the shared tunnel, cutting other terminals off |
| `proxy-node sg` | Changes the default node for new terminals; running tunnels are untouched |
| `tunnel-start [node]`, `tunnel-stop [node]`, `proxy-restart [node]` | One node; no argument = default node |
| `cc-stop` | Every node (guarded while sessions run, `--force` as today) |
| `proxy-status` | Every node tunnel: state, ports, sessions, outage, last error, log path |

## Part 2 - kill switch (app-level, fail-closed)

Setting `KILLSWITCH` (`on` default for new installs and upgrades / `off`),
command `proxy-killswitch [status|on|off]`.

1. **Pinned Claude settings.** settings.json keeps `HTTPS_PROXY`,
   `HTTP_PROXY` and `NO_PROXY` pointing at the default node's HTTP port
   permanently. `proxy-off` and `cc-stop` no longer remove them; only
   `proxy-killswitch off` does (and restores today's add/remove behaviour).
   Plain `claude` and IDE extensions then go through the tunnel or get
   "connection refused". WSL: the Windows-side settings too when
   `SYNC_WINDOWS_SETTINGS=1`.
2. **Per-terminal node.** `cc --node X` passes Claude
   `--settings '{"env":{...X's port...}}'`; `cx --node X` sets env only.
3. **Plain commands.** Setting `PLAIN_COMMANDS`:
   - `auto`: shell functions `claude` / `codex` bring the default node's
     tunnel up and launch through it with the app's normal prompts (like
     `cc-safe` / `cx-safe`). Refuse only if the tunnel cannot be made healthy.
   - `off`: no wrapper. Claude is still protected by the pin; plain `codex`
     is not, and `proxy-doctor` says so.
   The setup wizard asks. Existing users get `off` until they choose.
4. **Pre-launch leak checks** (every `cc`/`cx`, and `auto` wrappers). Refuse
   with a plain-language reason when:
   - `NO_PROXY` would exempt `api.anthropic.com`, `claude.ai`,
     `api.openai.com`, `chatgpt.com` or `auth.openai.com` (e.g. `*`, `*.com`);
   - the node's HTTP or SOCKS port is held by anything other than that node
     owner's ssh;
   - the pinned settings.json port differs from the default node's port
     (only when this terminal uses the default node).
5. **No silent port fallback while on.** A foreign program on a node port
   stops `cc` with its name/PID and one fix
   (`proxy-config set HTTP_PORT 8090`, which re-pins). With the kill switch
   off the existing fallback stays.
6. **Port takeover alert.** If a foreign process binds a node port while its
   ssh is down, the owner raises a distinct terminal + desktop alert naming
   the program and PID and advising to exit the session. It never kills
   Claude/Codex or the foreign process.

Limits (documented): covers Claude Code (CLI and IDE extensions) and Codex
started from terminals. Not the Claude Desktop app, browsers or other apps
(`chrome-proxy` already fails closed via its resolver rules). Tools started
by Claude/Codex inherit the proxy environment.

## Part 3 - watchdog fixes (2.8.0)

1. **Node-keyed owner** (part 1) - fixes "explicit stop does not stay
   stopped", competing owners after a fallback port or node switch, and the
   legacy kill path hitting an owner's ssh. The legacy path refuses while any
   owner for that node exists.
2. **ssh failure classification.** Each ssh launch writes stderr to a
   per-node file truncated at launch. On exit the last lines are classified:
   `auth` (Permission denied, no key / agent), `hostkey` (Host key
   verification failed), `forward` (bind: Address already in use / forwarding
   failed), `network` (timeout, unreachable, DNS). Stored in state, shown by
   `tunnel-start`, `proxy-status` and the live notice with a one-line fix.
   `auth`/`hostkey` back off straight to `WATCHDOG_MAX_BACKOFF`.
3. **Automatic migration.** A tunnel from an older profile (ssh on the ports,
   no owner) is replaced by an owner on the same ports when `cc`/`cx` or
   `tunnel-start` run, with a message - instead of refusing.
4. **Session registration.** Each `cc`/`cx` writes a heartbeat (PID + start
   identity) into its node's owner directory and removes it on exit; stale
   entries are ignored. Used for per-node session counts in the stop guards
   (fixes Windows missing npm-installed Claude, which runs as `node.exe`) and
   for idle probing: with no live session the owner probes every 60 s instead
   of every 5 s. Owners keep running (Chrome may use the node).
5. **Port takeover alert** (part 2, item 6).
6. **PowerShell:** launch the worker via `$PSHOME` (powershell.exe /
   pwsh.exe), not the current host (broken under the ISE); readable
   `proxy-status` (outage duration, ports, log path, last error instead of
   raw JSON); missing-ssh guard matching Bash.

## Error handling

- Background recovery never prompts; missing credentials surface as `auth`.
- No automatic path clears env vars, settings.json or the pin, changes a
  live session's port or node, or signals Claude/Codex or a foreign process.
- An explicit stop of a node first stops its owner so it stays stopped.
- State files are data only (never sourced/evaluated), user-private.

## Testing

- **Unit** (existing style, both platforms): node port map, owner identity,
  failure classifier, leak checks (`NO_PROXY` matching, port owner,
  pin mismatch), `--settings` JSON builder, idle interval, migration.
- **End-to-end on the dev VM, no system changes:** a private `sshd` on a high
  port with its own host key and authorized-keys file, configured as two
  fake nodes (jp, sg), and a local CONNECT proxy standing in for tinyproxy.
  Scenarios: ssh killed -> recovered; link hung -> restarted; auth failure
  classified; foreign listener takes a port mid-outage -> alert; two nodes in
  parallel terminals; `tunnel-stop sg` leaves jp running; kill switch: with
  the tunnel down a fake-config Claude hits the dead pinned port, not the
  network (listener method above).
- **Shells:** Bash tests under bash and zsh; PowerShell tests under pwsh 7.
  Windows PowerShell 5.1 + Windows OpenSSH remain a manual smoke test.

## Rollout

Feature branch `feat/killswitch-multinode`, three PRs reviewed and tested
separately: 2.8.0 (watchdog fixes + node-keyed owner, includes the per-user
tunnel log / `ss` port check / missing-ssh guard commit), 2.9.0 (kill
switch), 2.10.0 (parallel nodes + Chrome merge). Each bumps both profiles to
the same number and updates `docs/upgrading.md`, `docs/proxy-profile.md`,
`docs/proxy-nodes.md`, `docs/troubleshooting.md` and, for 2.9.0, the setup
wizards. Tags `powershell-v<version>` and `bash-v<version>` after merge.
