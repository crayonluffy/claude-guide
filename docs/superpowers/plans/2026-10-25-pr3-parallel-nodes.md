# PR 3 (2.10.0) - Parallel node tunnels - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Several nodes up at the same time. Each terminal chooses its node
(`cc --node sg`) without disturbing the others; `proxy-node sg` changes the
default only. Chrome uses the supervised node tunnel instead of its own
unsupervised `ssh -f`. Spec: `docs/superpowers/specs/2026-10-24-killswitch-multinode-design.md`
(Part 1, Part 2 item 2). Builds on PR 1 (slot-keyed owner, sessions, takeover)
and PR 2 (kill switch, `_killswitch_check`, plain commands).

**Architecture:**

- **One tunnel + one owner per node.** The default node keeps slot `main` on
  the main ports (8080/1080) - nothing changes for one-node users. Any other
  node runs in slot `node-<name>` on fixed ports `NODE_HTTP_BASE + slot`
  (new, default `8180`) and `NODE_SOCKS_BASE + slot` (`1180`, today's Chrome
  scheme). Ports never change during recovery.
- **The owner is parameterised by the node, not by new code.** The Bash worker
  reads its tunnel from the `CLAUDE_*` variables and PowerShell's from its
  descriptor. `_node_ctx <name>` sets those variables for a node in a
  subshell; `Start-RecoveryOwner -Node` writes a node descriptor. The tunnel
  record (`tunnel.rec` / `descriptor.json`) then makes every terminal agree on
  the node's ports, exactly as PR 1 does for `main`.
- **Per-terminal node for Claude needs `--settings`.** Claude reads
  settings.json `env` over the shell, and the kill switch pins settings.json to
  the default node. `cc --node sg` therefore launches
  `claude --settings '{"env":{"HTTPS_PROXY":"http://127.0.0.1:8181",...}}'`
  (verified on 2.1.309: `--settings` beats settings.json). Codex reads only the
  environment, so `cx --node sg` sets the three variables for the Codex
  process only. The shell's own environment is not changed.
- **Kill switch per node.** `_killswitch_check <http> <socks>` already takes
  the ports; for a node slot it checks NO_PROXY and the node's port holders
  (the pin check applies only to the main port, as today).

**Behaviour changes (documented in upgrading.md):**

| Command | 2.9 | 2.10 |
|---|---|---|
| `cc --node sg` / `cx --node sg` / `proxy-up --node sg` | Switched the default node (saved) and restarted the shared tunnel - cut other terminals off | This terminal only, through sg's own tunnel; nothing saved |
| `proxy-node sg` | Switched the default node, restarting the shared tunnel | Same, but refuses while `cc`/`cx` sessions use the default node (`--force` overrides) |
| `chrome-proxy sg` | Own unsupervised SOCKS-only `ssh -f` on `1180+slot` | sg's supervised node tunnel (same SOCKS port, now self-healing) |
| `tunnel-start` / `tunnel-stop` / `proxy-restart` | Default tunnel | Optional node argument; none = default node |
| `cc-stop` | Main tunnel + Chrome node tunnels | Every node owner (guarded while sessions run) |
| `proxy-status` | Main tunnel | One line per node tunnel: state, ports, sessions, last error |

**Tech stack / conventions:** as PR 1-2 (failing test first, full suite +
`zsh tests/zsh-smoke.zsh` + `bash tests/e2e/run.sh` before each commit,
scratch state only, docs in ASD-STE100).

---

### Task 1: Bash - node context and port map

**Files:** `scripts/claude-proxy.sh` (settings, new `_node_slot`, `_node_ctx`,
`_node_http_port`); test `tests/proxy-nodes-parallel.sh` (new).

**Step 1: failing tests** (catalogue fixture with jp slot 0, sg slot 1, us
unprovisioned; default node jp):
- `_node_slot jp` = `main`; `_node_slot sg` = `node-sg`; `_node_slot jpvpn`
  (alias) = `main`; unknown / unprovisioned -> rc 1 with a clear message.
- `( _node_ctx sg; echo "$CLAUDE_SSH_HOST $CLAUDE_HTTP_PORT $CLAUDE_SOCKS_PORT $CLAUDE_REMOTE_PROXY_PORT" )`
  = `sgvpn 8181 1181 <proxy_port or 8888>`; `CLAUDE_SSH_USER` / `KEY` empty
  (the alias carries them); the caller's variables are unchanged afterwards.
- `_node_ctx jp` keeps the main ports (8080/1080) and the configured host.
- A node whose ports collide with the main ports (`NODE_HTTP_BASE` = 8080) is
  refused with `proxy-config set NODE_HTTP_BASE 8180`.

**Step 3: implement**; new setting `CLAUDE_NODE_HTTP_BASE=8180`
(+ `_CLAUDE_CONF_KEYS`). **Step 5:** commit `Bash: node slots and fixed per-node ports`.

---

### Task 2: Bash - one owner per node

**Files:** `_recovery_owner_start`, `_watchdog_pid`, `_watchdog_stop`,
`tunnel-start`, `tunnel-stop`, `proxy-restart`; tests `tests/proxy-nodes-parallel.sh`.

**Step 1: failing tests**
- `_recovery_owner_start claude sg` spawns the worker in a subshell after
  `_node_ctx sg`; the slot dir is `.../recovery/node-sg`; its `tunnel.rec` has
  `host=sgvpn http=8181 socks=1181`. A second call returns the same dir and
  spawns nothing.
- Default-node calls (`_recovery_owner_start claude`) behave exactly as in
  2.9 (all existing tests unchanged).
- `tunnel-stop sg` stops only `node-sg` (mock owner stop records dirs);
  `tunnel-stop` (no arg) stops only `main` - **change from 2.9, where it
  stopped every owned dir:** older-version owners (hashed dirs) are still
  stopped by the no-arg form; parallel nodes are not.
- `tunnel-start sg` with the kill switch on and a foreign program on 8181:
  refuses with `proxy-config set NODE_HTTP_BASE ...`.
- Migration from a 2.9 Chrome tunnel: an unsupervised `ssh` on `1181` (no
  owner) is stopped and replaced by the `node-sg` owner (`[Upgrade]` line), a
  foreign program on `1181` is refused - reuse `_recovery_migrate` with the
  node's ports.

**Step 3: implement** - `_recovery_owner_start <provider> [node]`: resolve the
slot, `( _node_ctx "$node"; _recovery_worker "$dir" ) &`. Callers that adopt
(`_recovery_adopt "$dir"`) pass the node's dir. **Step 5:** commit
`Bash: one self-healing tunnel per node`.

---

### Task 3: Bash - per-terminal node for cc / cx / proxy-up

**Files:** `_launch_via_proxy`, `proxy-up`, new `_node_settings_json`; tests
`tests/proxy-nodes-parallel.sh`, `tests/proxy-plain.sh`.

**Step 1: failing tests** (fake `claude`/`codex` binaries print their argv and
`$HTTPS_PROXY`; `proxy-up` mocked or real with mocked probes):
- `cc --node sg -p hi` -> the binary gets `--settings '{"env":{"HTTPS_PROXY":"http://127.0.0.1:8181","HTTP_PROXY":"http://127.0.0.1:8181","NO_PROXY":"<list>"}}'`
  **before** the app arguments, then `--dangerously-skip-permissions -p hi`;
  the shell's `HTTPS_PROXY` afterwards is what it was before (unset or main).
  JSON is valid (`jq -e .`) for a NO_PROXY with quotes/backslashes.
- `cx --node sg exec ls` -> the binary sees `HTTPS_PROXY=http://127.0.0.1:8181`;
  the shell does not.
- `proxy-up --node sg` -> this shell's env points at 8181 (that is what
  `proxy-up` is for), the conf file is unchanged (`CLAUDE_SSH_HOST` still jp),
  and a second terminal's default (`main`) owner is untouched.
- The session registers in `node-sg/sessions`, not `main/sessions`.
- `_killswitch_check 8181 1181` is used for the node (foreign program on
  8181 refuses; the main pin is not consulted).
- `cc --node jp` (the default node) is exactly `cc` (main slot, no `--settings`).
- Plain-command wrappers pass `--node` through.

**Step 3: implement** - `_node_settings_json <port>` builds the JSON with `jq -n
--arg` when jq exists, else a small escaper (`\` and `"`); the launcher keeps
`up_args` for the main path and, for a node, runs `proxy-up` in the node
context but applies env only to the app: `HTTPS_PROXY=... command "$bin" ...`.
**Step 5:** commit `Bash: cc --node / cx --node choose the node for this terminal only`.

---

### Task 4: Bash - proxy-node guards the default

`proxy-node sg`: when `_recovery_sessions main` > 0 and no `--force`, refuse:
`<n> session(s) use the default node <jp>. They would move to sg. Use 'cc --node sg' for this terminal, or 'proxy-node sg --force'.`
Otherwise as today (stop main owner, save, restart main on the new node if it
was up, re-pin via `_killswitch_ensure_pin`). Tests in
`tests/proxy-nodes-parallel.sh`. Commit `Bash: proxy-node refuses to move running sessions`.

---

### Task 5: Bash - chrome-proxy uses the node tunnel

`chrome-proxy <node>` for a non-default node: `_recovery_owner_start claude <node>`
(starts or adopts `node-<name>`), waits for its SOCKS port, launches Chrome on
`NODE_SOCKS_BASE + slot` as today. Remove `_node_tunnel_start`; keep
`_node_tunnels_running` / `_node_tunnels_stop` only for the migration of 2.9
leftovers (unsupervised ssh on a node SOCKS port with no owner). Chrome does
not register a session (it is not a CLI); an owner without sessions idles at
`WATCHDOG_IDLE_INTERVAL`. Tests: mocked owner start + Chrome binary; legacy
ssh on 1181 is replaced. Commit `Bash: chrome-proxy uses the self-healing node tunnel`.

---

### Task 6: Bash - proxy-status and cc-stop for all nodes

- `proxy-status`: the current detailed block for the default node, then
  `=== Node tunnels ===` with one line per live `node-*` owner:
  `[ON]  sg  sgvpn  HTTP :8181  SOCKS :1181  sessions 1  (last ssh error: ...)`.
- `cc-stop`: session guard counts every slot; then `_recovery_stop_owners`
  (all dirs) + legacy Chrome tunnels.
- `proxy-doctor`: one line per node owner (health probe through its port).
Tests via mocks. Commit `Bash: status, doctor and cc-stop cover every node tunnel`.

---

### Task 7-9: PowerShell mirror

- **7:** `Get-NodeSlot`, `Get-NodeContext` (hashtable of the node's
  SSH_HOST/ports), `$script:NODE_HTTP_BASE=8180` (+ CONF_KEYS);
  `Start-RecoveryOwner -Node sg` writes `node-sg/descriptor.json` with the
  node's values (the worker needs no change); `tunnel-start/-stop/proxy-restart [-Node]`.
- **8:** `cc -Node sg` / `--node sg`: `& $exe --settings $json @app` where
  `$json = @{env=@{HTTPS_PROXY=...;HTTP_PROXY=...;NO_PROXY=...}} | ConvertTo-Json -Compress`
  - Windows PowerShell 5.1 mangles embedded double quotes in native
  arguments: pass `($json -replace '"','\"')` when `$PSVersionTable.PSVersion.Major -lt 7`
  (and under 7.x with `$PSNativeCommandArgumentPassing -eq 'Legacy'`); test
  both branches with a fake `claude.ps1` that echoes its args.
  `cx -Node sg`: set the three `$env:` values around the call in `try/finally`
  and restore the previous values.
- **9:** `proxy-node` guard, `chrome-proxy` via the node owner (remove
  `Start-NodeTunnel`'s `ssh -f`), `proxy-status` / `cc-stop` / `proxy-doctor`
  for every slot.
Tests `tests/proxy-nodes-parallel.ps1`. One commit per task.

### Task 10: zsh + end-to-end

- `tests/zsh-smoke.zsh`: `_node_slot`, `_node_ctx` in a subshell (no leak to
  the caller), `_node_settings_json` valid JSON.
- `tests/e2e/run.sh`: a second alias `e2e-sg` to the same private sshd with
  its own remote proxy port (a second `connect_proxy.py`), catalogue fixture
  with jp (default) and sg. Scenarios: `tunnel-start sg` -> `node-sg` owner on
  8181/1181 while jp stays on 28080; a request through 8181 reaches sg's
  proxy, through 28080 jp's (each CONNECT proxy logs what it serves);
  `kill` sg's ssh -> recovered, jp untouched; `tunnel-stop sg` leaves jp up;
  real `claude -p` with `--node sg` semantics (run through `cc --node sg -p`
  with `--no-verify` and a fake key) sends CONNECT to sg's port only, while
  settings.json stays pinned to jp's port; `proxy-node sg` refuses while a
  session is registered on `main`.
Commit `Tests: parallel node tunnels end-to-end`.

### Task 11: Docs, versions, PR

Both profiles `2.10.0`. ASD-STE100 text. `docs/upgrading.md` 2.10.0 entry
with the behaviour-change table above (especially: `cc --node` no longer
switches the default). `docs/proxy-nodes.md`: the node model (one tunnel per
node, ports, `cc --node` vs `proxy-node`, Chrome on the node tunnel) - update
`assets/nodes-flow.svg` labels if they say "SOCKS-only". `docs/proxy-profile.md`:
`NODE_HTTP_BASE` rows, command table. `docs/troubleshooting.md`: rows for the
new refusals. Full suite + zsh + e2e. Push only after asking.

---

## Open questions for review

1. **`cc --node` no longer switches the default.** The spec says so, and it is
   what makes parallel terminals possible, but people who used
   `cc --node sg` to switch permanently must now use `proxy-node sg`. The
   2.10.0 notes and a one-time hint (`[Node] This terminal uses sg. To make sg
   the default: proxy-node sg`) cover it.
2. **Idle node owners.** A node owner keeps running after its last session
   (Chrome may use it; idle probing costs one check a minute). `cc-stop` or
   `tunnel-stop sg` ends it. Alternative: stop a node owner after N idle
   minutes with no Chrome attached - more moving parts; not planned.
3. **`NODE_HTTP_BASE` = 8180.** Keeps 8080-8099 free for the main port and its
   neighbours; mirrors the 1180 SOCKS base. Ten nodes use 8180-8189.
