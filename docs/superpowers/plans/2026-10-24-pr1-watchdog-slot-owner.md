# PR 1 (2.8.0) - Slot-keyed recovery owner + watchdog fixes - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the 2.7 recovery owner sound on both platforms - one owner per
user and slot (`main`), adopted by every terminal; classified ssh failures;
automatic upgrade migration; session registration with idle probing; a loud
port-takeover alert - so the kill switch (2.9) and parallel nodes (2.10) can
build on it.

**Architecture:** The owner directory moves from `<root>/<cksum of host+ports>`
to `<root>/main`. The owner writes `tunnel.rec` (host, user, ssh port, key,
HTTP/SOCKS/remote ports) when it starts; `_recovery_adopt` loads those values
into the calling terminal, so stale settings can't split ownership. ssh
stderr goes to `<dir>/ssh.err` (truncated per launch) and is classified on
exit. Sessions register `<dir>/sessions/<pid>` heartbeats; with none alive the
owner probes every `WATCHDOG_IDLE_INTERVAL` (60s) and wakes on `<dir>/wake`.

**Tech stack:** Bash 3.2+/zsh 5 (macOS, Linux, WSL) in `scripts/claude-proxy.sh`;
Windows PowerShell 5.1 / pwsh 7 in `scripts/claude-proxy.ps1`. Tests:
`tests/*.sh` (bash), `tests/*.ps1` (pwsh), new `tests/zsh-smoke.zsh`, new
`tests/e2e/` (bash, private sshd). Spec:
`docs/superpowers/specs/2026-10-24-killswitch-multinode-design.md`.

**Conventions:** match the surrounding code (terse helpers, `[Tag] message`
output, comments explain *why*). Every behaviour change gets a failing test
first. Run the full suite before each commit:

```bash
for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done
for t in tests/*.ps1; do pwsh -NoLogo -NoProfile -File "$t" || echo "FAIL $t"; done
```

---

### Task 0: Tooling

**Step 1:** install zsh for the zsh smoke test: `sudo apt-get install -y zsh`.
pwsh 7.6.8 is already at `~/.local/bin/pwsh`.

**Step 2:** confirm `sshd` binary exists for e2e: `ls /usr/sbin/sshd`.

No commit.

---

### Task 1: Bash - slot identity + tunnel record + adoption

**Files:** `scripts/claude-proxy.sh` (recovery block, `_recovery_identity`,
`_recovery_owner_start`, `_recovery_worker`); test `tests/proxy-slot.sh` (new).

**Step 1: failing test** `tests/proxy-slot.sh`:
- `XDG_STATE_HOME=$scratch`; `_recovery_identity` -> `$scratch/claude-proxy/recovery/main`
  regardless of `CLAUDE_SSH_HOST` / `CLAUDE_HTTP_PORT` (call it twice with
  different values, assert same path, mode 700).
- `_recovery_record_write "$dir"` then change `CLAUDE_HTTP_PORT=9999
  CLAUDE_SSH_HOST=other`, fake a live owner (`_recovery_owner_pid() { echo $$; }`),
  call `_recovery_adopt` -> variables restored to the recorded values and it
  prints nothing harmful; with no live owner it changes nothing.
- the record is data: a value containing `$(touch pwned)` is not executed.

**Step 2:** run `bash tests/proxy-slot.sh` -> FAIL (`_recovery_record_write: command not found`).

**Step 3: implement**
```bash
_recovery_identity() {  # [slot]  - default slot 'main'
    local root="${XDG_STATE_HOME:-$HOME/.local/state}/claude-proxy/recovery" slot="${1:-main}"
    (umask 077; mkdir -p "$root/$slot") || return 1
    chmod 700 "$root" "$root/$slot" || return 1
    printf '%s/%s\n' "$root" "$slot"
}
# One line per field, key=value, read back WITHOUT eval.
_recovery_record_write() {
    _recovery_write "$1/tunnel.rec" "$(printf 'host=%s\nuser=%s\nport=%s\nkey=%s\nhttp=%s\nsocks=%s\nremote=%s' \
        "$CLAUDE_SSH_HOST" "$CLAUDE_SSH_USER" "$CLAUDE_SSH_PORT" "$CLAUDE_SSH_KEY" \
        "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT" "$CLAUDE_REMOTE_PROXY_PORT")" rec
}
_recovery_record_get() { sed -n "s/^$2=//p" "$1/tunnel.rec" 2>/dev/null | head -1; }
# A live owner's record wins over this terminal's settings (stale conf, fallback port).
_recovery_adopt() {
    local dir="${1:-}" v
    [ -n "$dir" ] || dir=$(_recovery_identity) || return 1
    _recovery_owner_pid "$dir" >/dev/null || return 1
    [ -r "$dir/tunnel.rec" ] || return 1
    v=$(_recovery_record_get "$dir" host);   [ -z "$v" ] || CLAUDE_SSH_HOST=$v
    v=$(_recovery_record_get "$dir" user);   CLAUDE_SSH_USER=$v
    v=$(_recovery_record_get "$dir" port);   [ -z "$v" ] || CLAUDE_SSH_PORT=$v
    v=$(_recovery_record_get "$dir" key);    CLAUDE_SSH_KEY=$v
    v=$(_recovery_record_get "$dir" http);   [ -z "$v" ] || CLAUDE_HTTP_PORT=$v
    v=$(_recovery_record_get "$dir" socks);  [ -z "$v" ] || CLAUDE_SOCKS_PORT=$v
    v=$(_recovery_record_get "$dir" remote); [ -z "$v" ] || CLAUDE_REMOTE_PROXY_PORT=$v
    export CLAUDE_SSH_HOST CLAUDE_SSH_USER CLAUDE_SSH_PORT CLAUDE_SSH_KEY CLAUDE_HTTP_PORT CLAUDE_SOCKS_PORT CLAUDE_REMOTE_PROXY_PORT
}
```
In `_recovery_worker`, right after a successful `_recovery_claim`: `_recovery_record_write "$dir"`.
Callers: `tunnel-start`, `tunnel-stop`, `proxy-status`, `proxy-restart`,
`_launch_via_proxy`, `proxy-notify status`, `_watchdog_pid` call
`_recovery_adopt` first (silently; ignore failure).

**Step 4:** `bash tests/proxy-slot.sh` PASS; full suite PASS (existing tests
that pass a dir explicitly are unaffected).

**Step 5:** commit `Bash: one recovery owner per user (slot 'main'), adopted by every terminal`.

---

### Task 2: Bash - explicit stop always reaches the owner

**Files:** `scripts/claude-proxy.sh` (`tunnel-stop`, `_recovery_owner_start`); test `tests/proxy-slot.sh`.

**Step 1: failing tests**
- With a live fake owner recorded on ports 18080/11080 and this terminal's
  `CLAUDE_HTTP_PORT=8080`, `tunnel-stop` calls `_recovery_owner_stop` (mock
  records it) and never reaches the ssh-listener kill loop (mock `_listeners`
  to return a PID and `kill` to record -> must stay empty).
- `_recovery_owner_start` with a live owner returns its dir, never spawns.

**Step 2:** run -> FAIL (legacy kill loop reached because ports differ).

**Step 3:** in `tunnel-stop`, replace the first block with
`_recovery_adopt >/dev/null 2>&1 || :` followed by the existing
`if _watchdog_pid ...` branch (it now finds the owner because identity no
longer depends on ports).

**Step 4:** PASS; suite PASS. **Step 5:** commit `Bash: tunnel-stop always stops the owner, never its ssh behind its back`.

---

### Task 3: Bash - ssh failure classification

**Files:** `scripts/claude-proxy.sh` (`_recovery_worker`, new
`_recovery_ssh_class`, `_recovery_ssh_hint`, `tunnel-start` failure branch,
`proxy-status`, `_recovery_subscribe`); test `tests/proxy-ssh-class.sh` (new).

**Step 1: failing test** - table-driven:

| stderr sample | class |
|---|---|
| `user@h: Permission denied (publickey).` | auth |
| `Too many authentication failures` | auth |
| `Load key "/k": bad permissions` | auth |
| `Host key verification failed.` | hostkey |
| `@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@` | hostkey |
| `bind [127.0.0.1]:8080: Address already in use` | forward |
| `channel_setup_fwd_listener_tcpip: cannot listen to port: 1080` | forward |
| `Could not request local forwarding.` | forward |
| `ssh: connect to host h port 22: Connection timed out` | network |
| `ssh: Could not resolve hostname h: Name or service not known` | network |
| `ssh: connect to host h port 22: Connection refused` | network |
| `Connection closed by 1.2.3.4 port 22` | network |
| `` (empty) | unknown |

Plus worker test (fake `ssh() { echo 'Permission denied (publickey).' >&2; return 255; }`):
after two passes `$dir/ssh.status` starts with `auth|255|`, the retry delay
jumped to `CLAUDE_WATCHDOG_MAX_BACKOFF`, and the log line contains the hint.

**Step 2:** run -> FAIL.

**Step 3: implement**
```bash
_recovery_ssh_class() {  # <stderr file> -> auth|hostkey|forward|network|unknown
    local f="$1"
    grep -qiE 'host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' "$f" 2>/dev/null && { echo hostkey; return; }
    grep -qiE 'permission denied|too many authentication failures|load key|no such identity|bad permissions' "$f" 2>/dev/null && { echo auth; return; }
    grep -qiE 'address already in use|cannot listen to port|could not request local forwarding|forwarding failed' "$f" 2>/dev/null && { echo forward; return; }
    grep -qiE 'timed out|could not resolve|connection refused|no route to host|network is unreachable|connection closed|connection reset|broken pipe' "$f" 2>/dev/null && { echo network; return; }
    echo unknown
}
_recovery_ssh_hint() {  # <class> <host>
    case "$1" in
        auth)    echo "SSH login to $2 was refused - load your key (ssh-add <key>) or check the user name, then proxy-restart." ;;
        hostkey) echo "The host key of $2 changed. If your admin expected that: ssh-keygen -R $2, then 'ssh $2' once." ;;
        forward) echo "A local tunnel port is taken by another program - see proxy-status." ;;
        network) echo "Cannot reach $2 - network down, Wi-Fi changed, or the server is offline. Retrying." ;;
        *)       echo "ssh to $2 exited - see the log: $CLAUDE_TUNNEL_LOG" ;;
    esac
}
```
Worker: launch `ssh -o BatchMode=yes "${_CP_SSH_ARGS[@]}" 2>"$dir/ssh.err" &`.
When the owned ssh is found dead (before relaunch): `rc` from `wait "$spid"`,
`class=$(_recovery_ssh_class "$dir/ssh.err")`, write
`$dir/ssh.status` = `class|rc|now|<last stderr line>`, append
`[ssh] <class>: <hint>` plus the stderr lines to `$CLAUDE_TUNNEL_LOG` once per
class change, and for `auth|hostkey` set `delay=$CLAUDE_WATCHDOG_MAX_BACKOFF`.
A healthy probe clears `ssh.status`.
`tunnel-start` failure branch: print the hint for `ssh.status` and
`tail -n 5 "$dir/ssh.err"` (falls back to the log when absent).
`proxy-status`: one line `[!!]  Last ssh error : <class> - <hint>` when set.
Subscriber: also watch `ssh.status`; print the hint once per class change
when class is `auth` or `hostkey`.

**Step 4:** PASS; suite PASS. **Step 5:** commit `Bash: classify ssh failures (auth/hostkey/forward/network) and say how to fix them`.

---

### Task 4: Bash - automatic migration from older profiles

**Files:** `scripts/claude-proxy.sh` (`_recovery_owner_start`); test `tests/proxy-slot.sh`.

**Step 1: failing test** - no owner, `_tunnel_health` mocked to `ok 4242 ssh 8080`,
`_legacy_watchdog_pid` fails: `_recovery_owner_start` must call a mocked
`tunnel-stop` once, then spawn the worker (mock `_recovery_worker` claims the
lock), print `[Upgrade]`, and return the dir. With `_tunnel_health` =
`foreign 99 nginx` it must refuse (return 1) without calling `tunnel-stop`.

**Step 2:** FAIL (currently prints "Run proxy-restart" and returns 1).

**Step 3:** replace the refusal:
```bash
if _legacy_watchdog_pid >/dev/null 2>&1 || _port_in_use "$CLAUDE_HTTP_PORT" || _port_in_use "$CLAUDE_SOCKS_PORT"; then
    case "$(_tunnel_health | awk '{print $1}')" in
        ok|stale)
            echo '[Upgrade] Replacing the tunnel from an older profile with a self-healing one on the same ports (open sessions reconnect within seconds).' >&2
            tunnel-stop >/dev/null || { echo '[Err] The old tunnel could not be stopped - run proxy-doctor.' >&2; return 1; } ;;
        *)  echo "[Err] Port $CLAUDE_HTTP_PORT/$CLAUDE_SOCKS_PORT is held by another program - see proxy-status." >&2
            return 1 ;;
    esac
fi
```

**Step 4:** PASS; suite PASS. **Step 5:** commit `Bash: cc migrates a tunnel from an older profile automatically`.

---

### Task 5: Bash - session registration, idle probing, wake

**Files:** `scripts/claude-proxy.sh` (`_recovery_subscribe`, `_recovery_worker`,
new `_recovery_sessions`, `cc-stop`, `proxy-up`); new setting
`CLAUDE_WATCHDOG_IDLE_INTERVAL=60` (+ `_CLAUDE_CONF_KEYS`, docs table);
test `tests/proxy-sessions.sh` (new).

**Step 1: failing tests**
- `_recovery_subscribe` creates `$dir/sessions/<subscriber pid>` containing its
  start identity; after `_recovery_unsubscribe` the file is gone.
- `_recovery_sessions "$dir"` counts only live entries (a file for PID
  99999999 is ignored and removed).
- worker with no sessions and a healthy probe sleeps `IDLE_INTERVAL`
  (mock `_wd_sleep` records its argument; expect 60), with a session 5.
- idle sleep returns early when `$dir/wake` appears (real `_recovery_idle_sleep 3`
  with `touch wake` after 0.3s returns in < 2s and removes `wake`).
- `proxy-up`: owner alive, first probe fails, then healthy -> launches
  (it touched `wake` and waited) instead of refusing.

**Step 2:** FAIL.

**Step 3: implement**
```bash
_recovery_sessions() {  # <dir> -> number of live cc/cx sessions on this slot
    local f pid stamp n=0
    for f in "$1"/sessions/*; do
        [ -f "$f" ] || continue
        pid=${f##*/}; read -r stamp < "$f" 2>/dev/null || stamp=''
        if [ -n "$stamp" ] && [ "$(_recovery_process_identity "$pid" 2>/dev/null)" = "$stamp" ]; then n=$((n+1)); else rm -f "$f"; fi
    done
    echo "$n"
}
_recovery_idle_sleep() {  # <seconds> - wakes early on <dir>/wake or a new session
    local i=0 dir="$2"
    while [ "$i" -lt "$1" ]; do
        if [ -e "$dir/wake" ]; then rm -f "$dir/wake"; return 0; fi
        [ "$(_recovery_sessions "$dir")" -eq 0 ] || return 0
        _wd_sleep 1; i=$((i+1))
    done
}
```
Subscriber: inside its subshell, after start, write `$BASHPID`-equivalent
(`sh -c 'echo $PPID'`, as the worker does) + identity to
`$dir/sessions/<pid>` (mkdir -p, umask 077), `trap 'rm -f ...; exit 0' TERM`.
Worker sleep: `if all healthy && [ "$(_recovery_sessions "$dir")" -eq 0 ]; then
_recovery_idle_sleep "${CLAUDE_WATCHDOG_IDLE_INTERVAL:-60}" "$dir"; else
_wd_sleep "${CLAUDE_WATCHDOG_INTERVAL:-5}"; fi`.
`proxy-up` transport check: on failure with a live owner, `touch "$dir/wake"`
and re-probe each second up to `CLAUDE_WATCHDOG_STARTUP_GRACE` before refusing.
`cc-stop` guard: union of `_other_agents` and `_recovery_sessions`.

**Step 4:** PASS; suite PASS. **Step 5:** commit `Bash: sessions register with the owner; idle owners probe every 60s and wake on demand`.

---

### Task 6: Bash - port takeover alert

**Files:** `scripts/claude-proxy.sh` (`_recovery_worker`, `_recovery_message`,
`_recovery_desktop_message`, subscriber); test `tests/proxy-takeover.sh` (new).

**Step 1: failing test** - worker with ssh dead and `_listeners` returning a
foreign PID whose `_proc_name` is `clash`: within one pass the log and the
provider state carry event `takeover`; the message names `clash` and the PID
and says to exit the session; the desktop mock receives `takeover` once (not
on every pass); when the port frees up the normal `lost`/`restored` flow
resumes. No `kill` of the foreign PID (mock `kill` records -> empty).

**Step 2:** FAIL.

**Step 3:** `_recovery_port_conflict` echoes `pid name port` of the first
foreign listener (name `another user's program` when `_port_bound` sees a
socket but `_listeners` returns no PID). The worker keeps `conflict_seen`
(pid:port); on a new value it sets the sample to `conflict|...` and forces
event `takeover` for both providers (generation bump), writes
`$dir/takeover` = `pid|name|port`, sends one desktop alert. Messages:
- terminal: `Another program (<name>, PID <pid>) took proxy port <port> while the tunnel was down. Claude/Codex traffic may go to it - exit this session now; nothing was stopped.`
- desktop: `Proxy port taken|<name> (PID <pid>) took port <port>. Exit Claude/Codex sessions now.`

**Step 4:** PASS; suite PASS. **Step 5:** commit `Bash: loud alert when another program takes a proxy port during an outage`.

---

### Task 7: PowerShell - slot identity, record, adoption, explicit stop

Mirror Tasks 1-2 in `scripts/claude-proxy.ps1`: `Get-RecoveryIdentity
[-Slot main]` -> `~/.claude-proxy/recovery/main`; owner writes `tunnel.json`
(SSH_HOST, SSH_USER, SSH_PORT, SSH_KEY, HTTP_PORT, SOCKS_PORT,
REMOTE_PROXY_PORT) via `Write-RecoveryStatus` (add `tunnel` to the allowed
record names); `Use-RecoveryRecord` sets the `$script:` values when
`Test-RecoveryOwner` is true. Call it first in `tunnel-start`, `tunnel-stop`,
`proxy-status`, `proxy-restart`, `cc`, `cx`, `proxy-notify`. `tunnel-stop`
then always reaches `Stop-RecoveryOwner`. Test `tests/proxy-slot.ps1` with the
same cases as the Bash test. Commit `PowerShell: one recovery owner per user (slot 'main'), adopted by every window`.

### Task 8: PowerShell - ssh failure classification

Mirror Task 3: `Get-RecoverySshClass`/`Get-RecoverySshHint` (same table,
`-match` with the same patterns), `Start-RecoverySsh` redirects stderr to
`<dir>/ssh.err`; on `HasExited` read `$ssh.ExitCode`, write `ssh.json`
`{class,exit,at,line}`, log once per class change, max backoff for
auth/hostkey; `tunnel-start` prints the hint + last 5 lines when the port
does not come up (today it is silent); subscriber prints auth/hostkey hints.
Test `tests/proxy-ssh-class.ps1` (same table). Commit.

### Task 9: PowerShell - migration, sessions, idle, takeover, minor fixes

- Migration (Task 4): `Start-RecoveryOwner` replaces an ok/stale legacy
  tunnel (`tunnel-stop`) instead of throwing; refuses only for foreign.
- Sessions (Task 5): `Start-RecoverySubscriber` writes
  `<dir>/sessions/<subscriber runspace host PID>-<guid>` with `$PID` +
  StartTime ticks and removes it in `Stop-RecoverySubscriber`;
  `Get-RecoverySessions` counts live ones; worker idles at
  `WATCHDOG_IDLE_INTERVAL` and wakes on `<dir>/wake`; `proxy-up` wakes + waits;
  `cc-stop` guard = sessions + `Get-Process claude,codex` filtered to the
  current user (`-IncludeUserName` needs admin, so compare `SessionId` to
  `$PID`'s instead).
- Takeover (Task 6): `Test-RecoveryPortConflict` returns the foreign
  `{Pid,Name,Port}`; same `takeover` event, messages and single desktop alert.
- Minor: worker launched via `Join-Path $PSHOME ($(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh'}else{'powershell'}) + '.exe')`
  (Linux/macOS: without `.exe`); `proxy-status` prints
  phase / outage duration (now - outage_started) / retries / ports / log path /
  last ssh error instead of raw JSON; `tunnel-start` missing-ssh guard
  (`Get-Command ssh` -> "Settings > Apps > Optional features > OpenSSH Client").
Tests `tests/proxy-sessions.ps1`, `tests/proxy-takeover.ps1`. One commit per bullet.

### Task 10: zsh smoke test

`tests/zsh-smoke.zsh` (run `zsh tests/zsh-smoke.zsh`): sources the profile
with an isolated `HOME`/`XDG_STATE_HOME`/`CLAUDE_PROXY_CONF`, then exercises
`_recovery_step`, `_recovery_identity`, `_recovery_record_write` /
`_recovery_adopt`, `_recovery_ssh_class`, `_recovery_sessions`, and one
worker run with fake ssh/probes (the Task 3 auth case). Fix every zsh
incompatibility it finds (watch: word splitting in `for x in $(...)`,
`read <<<`, `local` inside `( )`, `$BASHPID`). Commit `Tests: zsh smoke test for the recovery owner`.

### Task 11: End-to-end harness (bash, no system changes)

`tests/e2e/run.sh`:
1. scratch dir; `ssh-keygen` a host key and a client key; write
   `sshd_config` (Port 22022, ListenAddress 127.0.0.1, HostKey, AuthorizedKeysFile
   <scratch>/authorized_keys, PidFile, `UsePAM no`, `StrictModes no`) and start
   `/usr/sbin/sshd -D -f <cfg> -E <log> &`.
2. a tiny CONNECT proxy (`python3 -I tests/e2e/connect_proxy.py <port>`) that
   answers `CONNECT` with 200 and splices to the target - stands in for
   tinyproxy; probes reach the real api.anthropic.com / api.openai.com.
3. isolated `HOME` with `~/.ssh/config` alias `e2e-jp` (HostName 127.0.0.1,
   Port 22022, IdentityFile, UserKnownHostsFile <scratch>/known_hosts) and a
   conf with `CLAUDE_SSH_HOST=e2e-jp CLAUDE_HTTP_PORT=28080
   CLAUDE_SOCKS_PORT=21080 CLAUDE_REMOTE_PROXY_PORT=<proxy port>
   CLAUDE_SYNC_SETTINGS=0 CLAUDE_DESKTOP_NOTIFICATIONS=off`.
4. scenarios (each asserts on `proxy-status` output, state files, and
   `curl -x http://127.0.0.1:28080 https://api.anthropic.com/` exit code):
   start -> healthy; `kill` the owner's ssh -> healthy again within 15s with
   the same ports; `kill -STOP` ssh (hung link) -> restarted after grace+fails;
   remove the client key from authorized_keys -> `ssh.status` = auth and the
   hint shown; foreign `python3 -m http.server 28080` started while ssh is
   down -> `takeover` event; second "terminal" (subshell with a stale conf
   `CLAUDE_HTTP_PORT=8080`) runs `tunnel-stop` -> the owner stops and stays
   stopped.
5. trap cleanup: stop owner, sshd, proxy, remove scratch.
Commit `Tests: end-to-end recovery harness with a private sshd`.

### Task 12: Docs, versions, PR

- Bump both profiles to `2.8.0` (`tests/version-aligned.sh` must pass).
- `docs/upgrading.md`: 2.8.0 entry (migration is automatic now; ssh errors
  explained; idle probing; takeover alert; one owner per user).
- `docs/proxy-profile.md`: settings table (`WATCHDOG_IDLE_INTERVAL`), state
  location `.../recovery/main`, takeover alert text.
- `docs/troubleshooting.md`: rows for the four ssh error classes and the
  takeover alert.
- Full suite + `zsh tests/zsh-smoke.zsh` + `bash tests/e2e/run.sh` green.
- Push branch, open PR "2.8.0: one recovery owner per user, ssh error
  classification, migration, idle probing, takeover alert" against `main`
  (after PR #24 merges; rebase if needed). Ask the user before pushing.
