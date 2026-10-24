# PR 2 (2.9.0) - App-level kill switch - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Claude and Codex fail closed. When the tunnel is down they get
"connection refused" instead of going out from the user's real IP; when
something would make them leak (a `NO_PROXY` that exempts the API, a foreign
program on the proxy port, a stale pinned port) `cc`/`cx` refuse to launch and
say why. Spec: `docs/superpowers/specs/2026-10-24-killswitch-multinode-design.md`
(Part 2). Builds on PR 1 (2.8.0): the slot-keyed owner, its tunnel record and
the takeover alert (spec Part 2 item 6 - already shipped in 2.8.0).

**Out of scope here (PR 3, 2.10.0):** per-terminal node (`cc --node X` via
`claude --settings`), per-node ports and owners. PR 2 protects the default
node on the main ports only, but every helper takes the port/slot as an
argument so PR 3 can reuse it unchanged.

**Architecture:**

- New settings `KILLSWITCH` (`on` default, `off`) and `PLAIN_COMMANDS`
  (`off` default for existing users, `auto` / `off` asked by the wizard).
- **The pin.** With the kill switch on, settings.json `env.HTTPS_PROXY`,
  `env.HTTP_PROXY` (main HTTP port) and `env.NO_PROXY` stay written
  permanently. `proxy-off` / `cc-stop` clear only the shell env. Claude reads
  settings.json `env` *over* the shell env (verified on 2.1.309, see spec), so
  plain `claude` and the IDE extensions go through the tunnel or fail.
  Ensured (written only if missing/different, silently otherwise) on profile
  load, on `proxy-on`, and after `proxy-config set HTTP_PORT|NO_PROXY|...`.
  Needs `SYNC_SETTINGS=1` (+ `jq` on Bash); otherwise status/doctor say the pin
  is not active.
- **Pre-launch leak checks** in `proxy-up` (so `cc`, `cx`, the plain wrappers):
  NO_PROXY exemption, port owner, pin mismatch. Refuse with one reason + one fix.
- **No silent port fallback** while on: a foreign program on 8080/1080 stops
  `tunnel-start` with its name/PID and `proxy-config set HTTP_PORT 8090`.
- **Plain commands.** `PLAIN_COMMANDS=auto` defines `claude` / `codex` shell
  functions that run the `cc-safe` / `cx-safe` path quietly (all profile output
  to stderr, nothing on success) so `claude -p ... | jq` keeps working.

**Tech stack:** as PR 1. Tests: `tests/*.sh`, `tests/*.ps1`, `zsh tests/zsh-smoke.zsh`,
`bash tests/e2e/run.sh`. A real `claude` is installed on the dev VM
(`~/.npm-global/bin/claude`), so the e2e kill-switch check uses it.

**Conventions:** as PR 1 - failing test first, full suite before each commit,
match surrounding code, `[Tag] message` output, comments explain *why*. Test
state always under a scratch dir (`XDG_STATE_HOME`, `HOME`, `CLAUDE_SETTINGS`),
never the user's.

```bash
for t in tests/*.sh; do bash "$t" </dev/null || echo "FAIL $t"; done
for t in tests/*.ps1; do pwsh -NoLogo -NoProfile -File "$t" </dev/null || echo "FAIL $t"; done
zsh tests/zsh-smoke.zsh; bash tests/e2e/run.sh
```
(`tests/proxy-desktop.ps1` fails on Linux pwsh on `main` too - Windows tray
backend simulation; not a regression signal.)

---

### Task 1: Bash - NO_PROXY exemption matcher

**Files:** `scripts/claude-proxy.sh` (new `_noproxy_exempts`); test `tests/proxy-killswitch.sh` (new).

The API hosts that must never be exempt:
`api.anthropic.com claude.ai statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com`.

**Step 1: failing test** - table: `_noproxy_exempts "<list>"` prints the API
hosts the list exempts (one per line), nothing for a safe list.

| NO_PROXY | exempts |
|---|---|
| built-in default (`localhost,127.0.0.1,...,*.local,*.internal,*.corp`) | - |
| `*` | all |
| `*.com` / `.com` / `com` | all `.com` hosts |
| `anthropic.com` / `.anthropic.com` / `*.anthropic.com` | api.anthropic.com, statsig.anthropic.com |
| `api.openai.com:443` | api.openai.com |
| ` API.OpenAI.com ` (case, spaces) | api.openai.com |
| `claude.ai` | claude.ai |
| `notclaude.ai`, `10.0.0.0/8`, `openai.co` | - |

**Step 2:** FAIL (`command not found`).

**Step 3: implement** (curl / Node `proxy-from-env` semantics: `*` = all;
an entry matches the host itself and its subdomains; leading `*` / `.` are
stripped; a `:port` suffix is ignored; IPs/CIDRs never match a hostname):
```bash
_CLAUDE_API_HOSTS="api.anthropic.com claude.ai statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com"
_noproxy_exempts() {  # <NO_PROXY list> -> API hosts it would send DIRECT
    local list h e
    list=$(printf '%s' "$1" | tr 'A-Z,' 'a-z\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/:[0-9]*$//')
    for h in $_CLAUDE_API_HOSTS; do
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            [ "$e" = '*' ] && { echo "$h"; break; }
            e=${e#\*}; e=${e#.}
            case "$h" in "$e"|*".$e") echo "$h"; break;; esac
        done <<< "$list"
    done
}
```
**Step 4:** PASS (+ zsh: add a line to `tests/zsh-smoke.zsh`). **Step 5:** commit
`Bash: detect a NO_PROXY that would send Claude/Codex API traffic direct`.

---

### Task 2: Bash - KILLSWITCH setting and the settings.json pin

**Files:** `scripts/claude-proxy.sh` (settings block, `_CLAUDE_CONF_KEYS`,
`_settings_file_proxy_on/off`, `_claude_settings_proxy_on/off`, `proxy-off`,
`cc-stop`, `proxy-config set`, load section); test `tests/proxy-killswitch.sh`.

**Step 1: failing tests** (isolated `CLAUDE_SETTINGS=$scratch/settings.json`, real jq):
- `CLAUDE_KILLSWITCH=on`: `proxy-on` then `proxy-off` -> env vars gone from the
  shell, settings.json still has `HTTPS_PROXY=http://127.0.0.1:8080`,
  `HTTP_PROXY`, `NO_PROXY`; other keys in the file (`model`, `env.FOO`) untouched.
- `cc-stop` (mock `tunnel-stop`, `_other_agents`, `_recovery_sessions`) -> pin stays.
- `CLAUDE_KILLSWITCH=off`: `proxy-off` removes the three keys (today's behaviour).
- `_killswitch_ensure_pin`: missing pin -> written, prints one `[Kill switch]`
  line; correct pin -> file not rewritten (mtime unchanged, no `.bak`
  churn), prints nothing; wrong port (8081) -> corrected.
- `proxy-config set HTTP_PORT 8090` -> pin now 8090.
- `SYNC_SETTINGS=0` or no jq (PATH without jq) -> `_killswitch_pin_state` prints
  `unpinned` and nothing is written.
- WSL (`_is_wsl` mocked true, `CLAUDE_SYNC_WINDOWS_SETTINGS=1`,
  `_win_claude_settings` -> a scratch path) -> both files pinned.

**Step 2:** FAIL.

**Step 3: implement**
- Defaults: `CLAUDE_KILLSWITCH=on`, comment explaining fail-closed and that
  `off` restores pre-2.9 add/remove; add to `_CLAUDE_CONF_KEYS`.
- `_killswitch_on() { [ "${CLAUDE_KILLSWITCH:-on}" = on ]; }`
- `_settings_file_proxy_on` gains an idempotence check: compare the three
  current values with jq first; when equal, return 0 without writing/backing up.
- `_killswitch_pin_state` -> `pinned <port>|mismatch <port>|unpinned <why>`
  (reads `env.HTTPS_PROXY` of `$CLAUDE_SETTINGS`; why = `sync-off|no-jq|missing`).
- `_killswitch_ensure_pin`: when on + sync + jq and state is not `pinned
  $CLAUDE_HTTP_PORT`, call `_claude_settings_proxy_on` quietly and print
  `[Kill switch] Claude settings now point at the tunnel (127.0.0.1:<port>) - without it Claude cannot connect.`
- `proxy-off`: clear env; call `_claude_settings_proxy_off` only when the kill
  switch is off; otherwise print `[Kill switch] Claude settings keep the proxy - plain 'claude' cannot go direct. ('proxy-killswitch off' to allow.)`
- Profile load (after the conf is sourced, skipped when `_CLAUDE_PROXY_QUIET=1`
  and in non-interactive shells? **No** - the pin must exist for IDE launches
  too; run it always but it is silent when nothing changes): `_killswitch_on && _killswitch_ensure_pin >&2`.
- `proxy-config set`: after `_conf_reload`, `_killswitch_ensure_pin`.

**Step 4:** PASS; suite PASS. **Step 5:** commit
`Bash: kill switch pins Claude's settings to the tunnel; proxy-off no longer unpins`.

---

### Task 3: Bash - `proxy-killswitch [status|on|off]`

**Files:** `scripts/claude-proxy.sh` (new command, `cc-help`); test `tests/proxy-killswitch.sh`.

**Step 1: failing tests**
- `status` with on + pinned prints: setting, `Claude: pinned to 127.0.0.1:8080 (<file>)`
  per target, `Codex: protected only when started with cx` (or
  `... and plain 'codex'` when `PLAIN_COMMANDS=auto`), `NO_PROXY: safe` (or the
  exempted hosts), and the limits line (Desktop app / browsers not covered).
- `off` -> conf has `CLAUDE_KILLSWITCH="off"`, pin removed **only if** no tunnel
  is running (`_watchdog_pid` mocked) - otherwise left until `proxy-off`.
- `on` -> conf `on`, pin written immediately.
- unknown arg -> usage, rc 2.

**Step 3: implement** using `_conf_set` + `_conf_reload`. **Step 5:** commit
`Bash: proxy-killswitch shows and switches the kill switch`.

---

### Task 4: Bash - pre-launch leak checks and no silent port fallback

**Files:** `scripts/claude-proxy.sh` (`_recovery_worker` writes `ssh.pid`,
new `_killswitch_check`, `proxy-up`, `tunnel-start` foreign branches); test
`tests/proxy-killswitch.sh`.

**Step 1: failing tests**
- Worker: after launching ssh, `$dir/ssh.pid` = `<pid>|<start identity>`;
  removed on exit (extend the existing fake-ssh worker test).
- `_killswitch_check <http> <socks>` (mocks for `_listeners`, `_proc_name`,
  `_port_bound`, `_killswitch_pin_state`) refuses (rc 1, one `[Kill switch]`
  reason line + one fix line) when:
  - `_noproxy_exempts "$CLAUDE_NO_PROXY"` is non-empty -> names the hosts,
    fix: `proxy-config set NO_PROXY "<list without the offending entries>"`;
  - a listener on either port is not the PID in `ssh.pid` (or its identity
    differs) -> `<name> (PID n) is on proxy port p`, fix: `proxy-config set HTTP_PORT 8090`;
  - `_port_bound` but no PID visible (another user) -> same, name `another user's program`;
  - pin state is `mismatch <q>` -> `Claude's settings point at port q, the tunnel is on p`,
    fix: `proxy-killswitch on` (re-pins);
  - and passes (rc 0, silent) when all is well; kill switch off -> always rc 0.
- `proxy-up` calls it after the transport check; refusing means no `proxy-on`, rc 1.
- `tunnel-start` with kill switch on and `_tunnel_health` = `foreign 99 nginx`:
  rc 1, prints `nginx (PID 99)` and `proxy-config set HTTP_PORT 8090`,
  never calls `_find_free_port`; same for a foreign SOCKS listener
  (`proxy-config set SOCKS_PORT 1090`). Kill switch off: today's fallback.

**Step 2:** FAIL. **Step 3: implement** - listeners are only checked on the
loopback/any address the proxy URL uses (`127.0.0.1`, `0.0.0.0`, `*`); a
`[::1]` squatter cannot receive `http://127.0.0.1:p` traffic, so it is not a
reason to refuse (add an `ss` address filter helper `_port_bound_v4` used here).
**Step 5:** commit `Bash: cc/cx refuse to launch when Claude/Codex traffic could leak`.

---

### Task 5: Bash - plain `claude` / `codex` (PLAIN_COMMANDS)

**Files:** `scripts/claude-proxy.sh` (setting, wrappers, `_launch_via_proxy`,
`_tools_pkg`/`_tools_*` call sites); test `tests/proxy-plain.sh` (new).

**Step 1: failing tests** (fake `claude`/`codex` scripts in a scratch PATH that
print their args and `HTTPS_PROXY`; `proxy-up` mocked):
- `PLAIN_COMMANDS=off` (default): no `claude` function is defined
  (`type -t claude` = `file`).
- `auto`: `claude -p hi` -> `proxy-up --no-verify` ran, the real binary got
  exactly `-p hi` (no skip-permissions flag), stdout is only the binary's
  output (profile messages on stderr), exit code passed through.
- `auto`, `proxy-up` fails -> rc 1, binary never ran, one-line reason on stderr.
- `claude --version`, `-v`, `--help`, `-h` pass straight through (no tunnel).
- No recursion: `cc` with the wrapper defined runs the binary once
  (`_launch_via_proxy` uses `command "$bin"`); `cc-install --check` calls the
  binary via `command` (mock records calls).
- Switching `proxy-config set PLAIN_COMMANDS off` + reload removes the
  functions (`unset -f claude codex`).

**Step 3: implement**
```bash
_plain_launch() {  # <label> <bin> <install hint> <skip flag> [args]
    local bin="$2"
    # Version/help need no network: never bring a tunnel up (or fail) for them.
    case "${5:-}" in --version|-v|--help|-h) shift 4; command "$bin" "$@"; return;; esac
    _launch_via_proxy "$@" --safe --no-verify --quiet
}
if [ "${CLAUDE_PLAIN_COMMANDS:-off}" = auto ]; then
    claude() { _plain_launch Claude claude "npm install -g @anthropic-ai/claude-code" --dangerously-skip-permissions "$@"; }
    codex()  { _plain_launch Codex  codex  "npm install -g @openai/codex" --dangerously-bypass-approvals-and-sandbox "$@"; }
else
    unset -f claude codex 2>/dev/null || :
fi
```
`_launch_via_proxy` learns `--quiet`: every profile line goes to stderr and the
`[Launch]`/`[Notify]` lines are dropped; the live subscriber still warns on stderr.
**Step 5:** commit `Bash: optional plain claude/codex that start through the tunnel`.

---

### Task 6: Bash - proxy-doctor and status

`proxy-doctor`: a `Kill switch` section - on/off, pin state per target file,
NO_PROXY exemptions, `PLAIN_COMMANDS=off` -> `[WARN] plain 'codex' is not
protected (proxy-config set PLAIN_COMMANDS auto)`. `proxy-status`: one line
`[ON] Kill switch : Claude pinned to :8080` / `[OFF] ...`. Test via mocks in
`tests/proxy-killswitch.sh`. Commit `Bash: doctor and status report the kill switch`.

---

### Task 7: PowerShell - matcher, setting, pin, proxy-off/cc-stop

Mirror Tasks 1-2: `Get-NoProxyExemption` (same table), `$script:KILLSWITCH='on'`
(+ `CONF_KEYS`), idempotent `_settings-sync-on` (compare before writing; keep
the `.bak` only when changing), `Get-KillswitchPinState`,
`Confirm-KillswitchPin` (profile load, `proxy-on`, `proxy-config set`),
`proxy-off` keeps the pin when on. Note `ConvertTo-Json -Depth 20` reorders
nothing but re-encodes the file: compare first so an unchanged pin never
rewrites the user's settings. Test `tests/proxy-killswitch.ps1` (isolated
`$script:CLAUDE_SETTINGS`). Commit `PowerShell: kill switch pins Claude's settings to the tunnel`.

### Task 8: PowerShell - proxy-killswitch, leak checks, no silent fallback

Mirror Tasks 3-4: `proxy-killswitch [status|on|off]`; worker writes
`ssh.json`-adjacent `sshpid.json` `{Pid;Started}` (add to the record names);
`Test-KillswitchLaunch` (NO_PROXY incl. `NO_PROXY_EXTRA`, port owner via
`Get-NetTCPConnection` filtered to `127.0.0.1`/`0.0.0.0`, pin mismatch) called
by `proxy-up`; `tunnel-start` foreign branches refuse instead of `Find-FreePort`
when on. Tests in `tests/proxy-killswitch.ps1`. Commit per bullet group.

### Task 9: PowerShell - plain commands

PowerShell functions shadow applications, so `cc`/`cx` must call the real
binary explicitly: `$exe = Get-Command claude -CommandType Application,ExternalScript | Select-Object -First 1`
(npm installs `claude.ps1` = ExternalScript and `claude.cmd`), then `& $exe @app`;
same in `_tool-run`. `PLAIN_COMMANDS=auto` defines `function claude` /
`function codex` -> safe path, quiet (`Write-Host` -> `[Console]::Error`),
`--version/-v/--help/-h` passthrough, `$LASTEXITCODE` preserved; `off` removes
them (`Remove-Item Function:\claude`). Test `tests/proxy-plain.ps1` with fake
`claude.ps1`/`codex.ps1` on a scratch `$env:PATH`. Commit.

### Task 10: PowerShell - doctor/status. Mirror Task 6. Commit.

### Task 11: Setup wizards

- `scripts/setup.sh` / `setup.ps1`: new installs write `KILLSWITCH=on`
  explicitly; ask once: `Make plain 'claude' and 'codex' start through the
  proxy too (recommended)? [Y/n]` -> `PLAIN_COMMANDS auto|off`; re-runs keep
  the saved answer as the default. `--update` / existing conf without the key:
  do not ask, print `[Info] New: proxy-config set PLAIN_COMMANDS auto ...`.
- Wizard end text mentions `proxy-killswitch status`.
- Tests: extend the wizard's non-interactive path (`_TOOLS_YES`-style env
  answers) in `tests/proxy-plain.sh` if the wizard exposes one; otherwise a
  manual smoke step in the PR description.
Commit `Setup: ask about plain claude/codex; new installs start with the kill switch on`.

### Task 12: zsh + end-to-end

- `tests/zsh-smoke.zsh`: `_noproxy_exempts`, pin ensure/idempotence with jq,
  `PLAIN_COMMANDS=auto` defines a working `claude` wrapper (fake binary).
- `tests/e2e/run.sh`, new scenarios (kill switch on, isolated `HOME` so the
  real `claude` reads `$HOME/.claude/settings.json`):
  1. after `tunnel-start`, settings.json is pinned to `:28080`;
  2. `tunnel-stop` + `proxy-off` -> pin still there;
  3. **fail closed:** start a recording listener on `:28080` (the
     CONNECT-proxy stand-in in record-only mode: `connect_proxy.py --record <file> --refuse`),
     run `timeout 20 claude -p hi` with the isolated HOME, assert the listener
     saw `CONNECT api.anthropic.com:443` (Claude used the pin) - then stop the
     listener and assert `claude -p hi` exits non-zero quickly (connection
     refused, no direct fallback);
  4. NO_PROXY leak: `CLAUDE_NO_PROXY='*.com'` -> `proxy-up` refuses, names
     `api.anthropic.com`;
  5. squatter on `:28080` with the tunnel stopped -> `tunnel-start` refuses
     naming it (no fallback port).
Commit `Tests: kill switch end-to-end with the real Claude CLI`.

### Task 13: Docs, versions, PR

- Both profiles `2.9.0` (`tests/version-aligned.sh`).
- `docs/upgrading.md` 2.9.0: what changes for existing users (plain `claude`
  now fails while the tunnel is down - that is the point; `proxy-killswitch off`
  restores the old behaviour; `PLAIN_COMMANDS` is opt-in for existing users).
- `docs/proxy-profile.md`: replace the "not an OS firewall kill switch"
  paragraph with the app-level kill switch: what is covered (Claude CLI + IDE
  extensions via the pin, `cc`/`cx`, plain commands when `auto`, tools they
  start) and what is not (Claude Desktop app, browsers, other apps, `codex`
  started outside these shells when `PLAIN_COMMANDS=off`); settings table rows.
- `docs/troubleshooting.md`: rows for each refusal message, and "plain `claude`
  says connection refused" -> `cc` / `proxy-up`, or `proxy-killswitch off`.
- Full suite + zsh + e2e green. Push, open PR "2.9.0: app-level kill switch"
  against `main` after PR 1 merges (rebase if needed). Ask before pushing.

---

## Open questions for review

1. **Pin on profile load.** Writing settings.json from a shell start is the
   only way an existing user's IDE gets protected without running `cc` first.
   It is silent and idempotent, but it does touch a file at login. Alternative:
   only on `proxy-on` / `proxy-killswitch on`.
2. **Default for existing users.** Spec: kill switch `on` for upgrades too.
   Effect: after `proxy-update`, plain `claude` with no tunnel stops working
   until they run `cc` once (which brings the tunnel up). The 2.9.0 notes and
   the one-line `[Kill switch]` message on first load explain it.
3. **Extra API hosts.** `statsig.anthropic.com` (telemetry) is included so an
   exemption cannot leak the user's IP via telemetry either; add others
   (`sentry.io`?) only if Claude/Codex are seen calling them.
