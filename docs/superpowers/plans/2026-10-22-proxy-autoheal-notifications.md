# Proxy Auto-Healing and Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover a failed proxy during `cc`/`cx`, notify users without ending their sessions, and provide isolated outage simulations.

**Architecture:** Extend the existing Bash watchdog and add an equivalent detached PowerShell owner. One owner maintains fixed tunnel ports and provider-specific status; foreground launchers subscribe to notifications while preserving native CLI invocation and terminal input. Probe, clock, process, and output adapters are replaceable for deterministic tests and simulation.

**Tech Stack:** Existing Bash/OpenSSH/curl and PowerShell/.NET/OpenSSH/curl.exe; existing dependency-free Bash and PowerShell test conventions. Do not require a new installed package or a running Claude/Codex account for automated tests.

**Spec:** `docs/superpowers/specs/2026-10-22-proxy-autoheal-notifications-design.md`

## Global Constraints

- Never automatically exit, signal, kill, or inject input into Claude/Codex or their children.
- Failed mandatory startup transport checks prevent launch, even with optional IP verification disabled.
- Check approximately every five seconds with a three-second overall timeout per probe.
- Notify on the first failed check; require two failures before restarting a still-running owned SSH process.
- The default prolonged-outage notification threshold is 60 seconds, configurable, and never terminates a session.
- Keep retrying after the threshold; reconnect backoff starts at two seconds and is capped at 30 seconds.
- Keep established HTTP/SOCKS ports, SSH destination, proxy environment, and Claude settings unchanged during recovery.
- One recovery owner per user/tunnel identity; provider-specific failures do not mark the other provider unavailable.
- No remote sudo, remote service restarts, API credentials, direct-IP comparison probes, or automatic node switching.
- Simulation uses fake adapters and isolated state; it must never touch live settings, processes, watchers, or networks.
- Each platform's installed profile remains a standalone file; proxy-update currently downloads only that file.
- Existing explicit shutdown protections remain; intentional tunnel stop stops the recovery owner first.
- Script-level recovery is not an OS-enforced network kill switch; documentation must state the limit.

## File Responsibilities

- `scripts/claude-proxy.sh`: Bash probe/state helpers, shared owner, subscribers, launcher integration, and simulation entry point; retain self-contained installation.
- `scripts/claude-proxy.ps1`: equivalent PowerShell behavior, internal detached-worker entry point, and runspace notification subscriber.
- `tests/proxy-recovery.sh`, `tests/proxy-recovery.ps1`: state/probe/ownership/launcher/simulation regression tests using fake clocks and process adapters.
- Existing `tests/chrome-proxy.sh` and `tests/chrome-proxy.ps1`: unchanged behavior must continue passing.
- `docs/proxy-profile.md`, `docs/troubleshooting.md`, `docs/upgrading.md`: settings, warnings, demonstrations, coverage limits, and update instructions.

## Review Focus

1. Sleep, clock changes, and delayed probes must not duplicate warnings or convert the threshold into termination; pin in Task 1.
2. A single provider's denial/rate limit must not restart a healthy shared tunnel; pin in Task 1.
3. Concurrent tabs, stale/reused PIDs, and foreign port owners must not cause competing reconnects or unrelated process termination; pin in Tasks 2 and 3.
4. Ctrl+C, application errors, and closing one terminal must preserve native input behavior and other sessions; pin in Task 4.
5. Cancelling a simulation while real sessions exist must not affect production state or call real adapters; pin in Task 5.

## Common Data Contracts

Provider is `claude` or `codex`. Probe result fields are `kind` (`healthy`, `tunnel`, `proxy`, `foreign`), `curl_exit`, `connect_code`, `http_code`, and `reason`. State fields are `phase` (`healthy`, `recovering`, `prolonged`), `outage_start`, `retry_count`, `next_retry`, `generation`, and `failure_kind`. An unset outage_start is null in PowerShell and `-` in Bash records. All timing inputs are nondecreasing numeric seconds, never formatted wall-clock timestamps.

The pure reducer emits an event (`none`, `lost`, `progress`, `prolonged`, `restored`) plus the next state. Generation advances for meaningful transitions, not every poll. Progress output is rate-limited to once per 30 seconds; proxy-status always exposes the latest state. Use per-provider state under a single transport owner.

Bash helpers exchange fixed-field tab-delimited records rather than adding jq as a hard dependency. PowerShell uses hashtables and JSON status files. Persist wall-clock time separately only for human-readable audit logs. Tests must load helpers without running profile initialization, the banner, or background workers.

### Task 1: Explicit transport probes and recovery state

**Files:** modify both profile scripts; create both recovery test files.

**Interfaces:**
- Bash: `_recovery_probe <provider> <http-port> <socks-port>` prints the probe record; `_recovery_step <prior-record> <sample-record> <now> <notice-after>` prints the state/event record; `_recovery_now` prints monotonic seconds.
- PowerShell: `Test-RecoveryTransport -Provider <string> -HttpPort <int> -SocksPort <int>` returns the probe hashtable; `Get-RecoveryTransition -State <hashtable> -Sample <hashtable> -Now <double> -NoticeAfter <int>` returns `{ State, Event }`; `Get-RecoveryTime` returns monotonic seconds.
- Both expose notification formatting separately from writing output, so tests can assert the agreed text.

- [ ] **Write failing tests:** healthy at 0, failure at 5 => lost/recovering; continued failure at 64 => no prolonged event; at 65 => one prolonged event; at 70 => no repeated prolonged event; success at 75 => restored/healthy. A shorter outage never emits prolonged. Clamp a backwards injected timestamp to the previous observed value; do not reset an outage when the wall clock changes.
- [ ] **Run:** `bash tests/proxy-recovery.sh` and `pwsh -NoProfile -File tests/proxy-recovery.ps1`. Confirm failures reference missing production helpers, not test setup errors.
- [ ] **Implement adapters and reducer:** explicitly proxy curl/curl.exe to loopback with bypass disabled, TLS verification enabled, connect timeout 2 and max-time 3. Claude endpoint is `https://api.anthropic.com/`; Codex endpoint is `https://api.openai.com/`. Do not use curl --fail: a verified HTTPS response after CONNECT 200 establishes transport even for HTTP 401/403/429/5xx. A proxy CONNECT 403/407/502 is a proxy failure. On HTTP failure with live SSH, cross-check the same SSH's SOCKS forward before classifying SSH as broken; successful SOCKS transport identifies a remote HTTP-proxy failure, not an application fallback route.
- [ ] **Test actual adapter arguments** with a fake curl executable: NO_PROXY must not bypass it; HTTP failures with a successful SOCKS cross-check must not request SSH restart; API denial for one provider must not change the other's state. Use Linux /proc/uptime or the available macOS system monotonic facility for Bash and .NET Stopwatch timestamps for PowerShell; fail the monitoring preflight clearly if the required monotonic facility is unavailable.
- [ ] **Verify and commit:** run both recovery tests and existing Chrome tests; `git diff --check`; commit `feat: add explicit proxy transport health and recovery states`.

### Task 2: Bash shared recovery ownership and fixed-port reconnect

**Files:** modify `scripts/claude-proxy.sh`; extend `tests/proxy-recovery.sh`.

**Interfaces:**
- `_recovery_owner_start <provider>` ensures one owner using the already selected tunnel configuration and prints its identity.
- `_recovery_owner_stop <identity>` stops only that owned monitor and SSH; it never calls proxy-off.
- `_recovery_status <identity> <provider>` prints the current provider state and metadata.
- Existing `_tunnel_watchdog`, `_watchdog_spawn`, `_watchdog_stop`, `tunnel-start`, `tunnel-stop`, and `proxy-restart` delegate to these lifecycle helpers instead of retaining a second reconnect loop.

- [ ] **Write failing lifecycle tests:** two simultaneous starts yield one owner; owned SSH exit reconnects on the same destination/ports; a foreign port owner is left untouched; intentional stop does not reconnect; failure lasting past 60 seconds retains proxy env/settings and never signals the fake application PID.
- [ ] **Run** `bash tests/proxy-recovery.sh`; confirm those failures before implementation.
- [ ] **Implement ownership:** private state under `${XDG_STATE_HOME:-$HOME/.local/state}/claude-proxy/recovery/`, parent mode 700; use an atomic directory lock and PID plus process-start identity validation for stale ownership. Key by SSH destination and fixed ports. Write status atomically through a sibling temporary file. Avoid evaluating stored data as shell code. Preserve the existing user-configured log destination while moving default ownership files out of shared /tmp paths.
- [ ] **Implement reconnect:** one asynchronous owned SSH child with BatchMode=yes for background retries; two consecutive tunnel failures restart only that child. Backoff 2/4/8/16/30 seconds; reset after healthy transport. A proxy-only failure gets probes and notifications without repeated SSH restarts. Existing explicitly configured watchdog intervals/failure counts remain honored; new default interval/failure threshold is 5 seconds / 2. Add configurable notice-after=60, probe-timeout=3, progress-interval=30, max-backoff=30 through the existing config reader/writer. A disabled watchdog is reported clearly; mandatory startup health remains required.
- [ ] **Verify and commit:** tests include PID reuse, status-write interruption, stale lock, and two live provider subscriptions; run Bash syntax and Chrome tests; commit `feat: supervise Bash proxy recovery without disrupting sessions`.

### Task 3: PowerShell shared recovery owner

**Files:** modify `scripts/claude-proxy.ps1`; extend `tests/proxy-recovery.ps1`.

**Interfaces:**
- `Start-RecoveryOwner -Provider <string>` ensures one owner and returns its identity.
- `Stop-RecoveryOwner -Identity <string>` stops only the owned monitor and SSH.
- `Get-RecoveryStatus -Identity <string> -Provider <string>` returns the provider status.
- `Invoke-RecoveryWorker -DescriptorPath <string>` is the internal detached worker, dispatched only when the profile is invoked with internal `-RecoveryWorker -RecoveryDescriptor <path>` switches.

- [ ] **Write failing tests** matching Task 2: shared owner, frozen ports, proxy-only failure, foreign process safety, missing credentials without a hidden prompt, and explicit shutdown. Dot-sourcing the profile normally must not dispatch a worker.
- [ ] **Run** `pwsh -NoProfile -File tests/proxy-recovery.ps1` and verify the expected failures.
- [ ] **Implement worker entry and ownership:** launch the current PowerShell executable with -NoProfile and the installed profile's actual path; preserve ordinary dot-sourcing. Private descriptor/status directory under the current user's profile; no private key contents or tokens in descriptors/logs. Use an exclusive .NET FileStream lock held by the owner, separate atomically replaced JSON status, and process-start identity validation. Corrupt/incomplete status must be reported, not interpreted as healthy.
- [ ] **Integrate** with tunnel-start/tunnel-stop and the existing configuration keys. Use Task 1 transport/reducer helpers and the same defaults as Bash. Add a settings-preserving proxy-restart counterpart if missing. Background retries use BatchMode=yes and fixed ports; do not reuse startup's free-port fallback once a session is running.
- [ ] **Verify and commit:** PowerShell parsing, recovery tests, Chrome regression tests; commit `feat: add continuous PowerShell proxy auto-recovery`. Record that Linux-hosted pwsh does not validate Windows console/background behavior.

### Task 4: Launch checks, live notifications, and session-safe cleanup

**Files:** modify both profile scripts; extend both recovery test files.

**Interfaces:**
- Bash: `_recovery_subscribe <identity> <provider>` starts a stderr-only subscriber and prints its PID; `_recovery_unsubscribe <subscriber-pid>` stops only it.
- PowerShell: `Start-RecoverySubscriber -Identity <string> -Provider <string>` returns a disposable runspace handle; `Stop-RecoverySubscriber -Handle <object>` disposes that subscriber only.
- Existing `cc`/`cx`, `_launch_via_proxy`, proxy-up, proxy-status, proxy-off, cc-stop, and command help retain their public interfaces.

- [ ] **Write failing launch tests:** a failed mandatory probe prevents fake CLI launch even with --no-verify; recovery preserves all app arguments and the established proxy env. At 60 seconds the app remains alive, a prolonged warning appears once, and retries continue. A normal CLI exit or thrown error cleans its subscriber without stopping shared SSH; another subscriber continues. Deliberate stop first prevents owner restart.
- [ ] **Run** both recovery suites and confirm failures.
- [ ] **Implement integration:** mandatory transport preflight is distinct from optional IP comparison. Start/attach the owner before invoking the CLI. Keep Claude/Codex as the native foreground command: never background them to obtain a PID, replace their stdin, or send Ctrl+C/exit for notification purposes. Use a Bash background read-only subscriber and a PowerShell .NET runspace writing Console.Error; the application invocation stays on the normal foreground path. Cleanup subscriber resources on return, Ctrl+C, or exceptions without changing the application's exit status.
- [ ] **Expose status and notifications:** use the spec's exact lost/prolonged/restored text; progress no more than every 30 seconds. Each subscriber tracks generation so status polling cannot duplicate transition warnings. Logs/status remain readable if the CLI redraws its terminal. Automatic paths never invoke proxy-off/settings cleanup; existing explicit user shutdown is kept separate. A provider-only failure warns only its subscribers.
- [ ] **Verify and commit:** both suites, input/argument preservation tests, and existing Chrome tests; commit `feat: notify running CLI sessions during proxy recovery`.

### Task 5: Safe simulation, documentation, and release preparation

**Files:** modify both profile scripts and `docs/proxy-profile.md`, `docs/troubleshooting.md`, `docs/upgrading.md`; extend both recovery tests.

**Interfaces:**
- Public command on both platforms: `proxy-test <recover|prolonged> [--fast]`; PowerShell also accepts -Fast.
- Simulation calls the Task 1 reducer/formatter with fake clock, probe, and reconnect adapters. It never acquires the production owner's lock or calls its lifecycle helpers.

- [ ] **Write failing demonstration tests:** recover emits lost/progress/restored; prolonged emits lost/prolonged/restored and proves retry attempts continue past the threshold. Run with a fake live production owner and assert zero real curl/SSH/process/settings calls and no changes to its state. Cancellation must clean only the demo's temporary files. Reject unknown scenarios/options with usage and no side effects.
- [ ] **Run** both recovery suites and confirm failures.
- [ ] **Implement demonstrations:** isolated temporary state, every line prefixed `[SIMULATION]`, --fast scales elapsed time by ten and explicitly labels 60 simulated seconds as six wall-clock seconds. recover fails from simulated t=5 until t=20; prolonged fails from t=5 until t=80, warns at t=65, continues retrying, then restores. Non-fast uses real elapsed time; automated tests inject time and do not sleep for a minute. No real app is launched or closed.
- [ ] **Document and prepare versions:** add the test commands, five-second probing, configurable 60-second notice threshold, fixed-port/shared-session behavior, remote-service troubleshooting, manual normal-exit choice, mandatory startup check, and script-level protection limits. Explain required built-in monotonic-clock facilities and platform coverage. Prepare PowerShell 2.5.0 and Bash 2.6.0 with their established tag names; do not publish or create remote tags as part of local implementation.
- [ ] **Final verification and commit:** both complete recovery suites, both existing Chrome suites, Bash syntax and full PowerShell parse, git diff --check, and both --fast demonstrations. Run Windows PowerShell/OpenSSH and macOS terminal smoke tests when those environments are available; explicitly list any unavailable coverage. Commit `feat: add safe proxy recovery simulations and usage docs`.

## Completion Review and Handoff

Run the complete verification once after the final code changes. Review the whole diff for process ownership, accidental direct probes, worker recursion, foreground input handling, and simulation isolation. Report the commands/results and platform limits; do not describe network isolation or live Windows behavior as verified by mocked Linux tests. Publication, PR merge, and annotated version tags follow only when authorized.

The written spec is approved. This implementation plan now requires user review and an execution-method choice before product code changes.
