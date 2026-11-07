# Proxy work handoff for Claude — 2026-11-08

## Status

Continue branch `wip/proxy-sharing-and-node-config`. The user requested pushing
the current work so Claude can finish it. This is unfinished work with known
failing checks. Do not publish, install or merge it as a finished release.

Stable remote main and published release remain v2.12.2 (`e0d50be`). The Mac's
installed `~/.claude-proxy.sh` also remains v2.12.2. New source markers currently
say 2.12.3; the combined follow-up design targets 2.13.0. Reconcile those before
release. Keep the completed quieter-notice change when finishing the other work.

## User requirements

1. Stop repeated connection-lost/restored/progress messages interrupting Claude
   and Codex terminals.
2. `cc` and `cx` must work in another iTerm2 tab, including when the shared owner
   is reconnecting. Steady-state version checks alone are insufficient proof.
3. **Ming** (macOS UID 502) should be able to use the proxy listener already
   served by **Kimmy** (UID 501), on HTTP 8080/SOCKS 1080. Earlier mentions of
   “Crayon” as the second OS account were corrected to Ming.
4. Improve `proxy-config edit` to account for all active JP/SG/US tunnels, expose
   editable per-node ports, show saved versus running endpoints and conflicts,
   and handle ports occupied by other programs/accounts.
5. Explore and fix races around default-node switches and concurrent launches.
   A default-server switch should retain the main local ports. Explicitly named
   node routes must not silently change region when the default changes.
6. Git author and committer: `crayonluffy <crayonluffy@gmail.com>`.

The user authorized local fixes and GitHub pushes earlier. Their latest request
was to push this checkpoint and hand implementation over to Claude.

## What is implemented

### Quiet terminal notices — committed as ea11656

`TERMINAL_NOTIFICATIONS` / `CLAUDE_TERMINAL_NOTIFICATIONS` supports `quiet`
(default), `verbose` and `off`. Quiet hides brief outages and progress, warns
once for a prolonged outage, and restores once only after that subscriber warned.
Authentication, host-key and takeover warnings remain immediate. Owner recovery,
desktop alerts and event logs are unchanged. Existing CLI notifiers retain the
old behavior until the CLI is relaunched normally.

This isolated change passed 45/45 portable checks and focused code review before
the later sharing/editor changes. That result does not certify the whole branch.

### Shared clients and startup readiness — integrated, not release-ready

`PROXY_MODE=managed|shared` (shell `CLAUDE_PROXY_MODE`) defaults to managed.
Shared explicitly trusts the configured local proxy endpoints, probes HTTPS,
keeps NO_PROXY/pinning checks, and bypasses private owner startup/subscription.
Stop/restart/default-switch controls leave the serving account's tunnel alone;
`cc-stop` only clears the consumer shell environment. Explicit named routes use
the configured node endpoints. Relevant tests are `test_shared_proxy.py` and
`proxy-shared.ps1`; these passed focused fixture checks.

`proxy-up` now waits for transport recovery before its final owned-port check.
`test_startup_reconnect.py` reproduces the user's exact two-line error against
the previous source and passes against the new source in Bash/zsh for both apps:

```
[Info] Shared recovery owner is running; keeping HTTP :8080 / SOCKS :1080.
[Err] Tunnel ports are not ready (HTTP :8080 / SOCKS :1080).
```

### Operation coordination and stable node slots — integrated

New `scripts/lib/operations.sh` is embedded by `build-profiles.py`. It serializes
operations using existing identity-checked recovery leases in a sibling
`operations/` directory, outside the tunnel-owner enumeration. It supports nested
calls and early release. PowerShell's matching functions are embedded directly
in its standalone profile and use `FileShare.None`.

Public start/stop/switch/restart/proxy-up and launcher paths acquire the gate.
Launchers release after session registration and before running the application.
Explicit named nodes now use `node-<name>` even when selected as the default;
only an unqualified cc/cx/proxy-up uses main. Named Chrome JP/SG/US therefore
retains SOCKS 1180/1181/1182 across default switches. An unnamed Chrome launch
still follows main. A main switch warns about untracked clients/other accounts.

`proxy-operations.{sh,ps1}` and `proxy-switch-race.sh` passed focused checks;
shell suites also passed under zsh. Real process boundaries/leases/subscribers
are used with fake transport/apps and temporary state.

### Node editor — partly integrated; known bug remains

New `scripts/lib/node-ports.sh` is embedded by the builder. Shell NODE_PORTS data
is a multiline `CLAUDE_NODE_PORTS` value with `node HTTP SOCKS` rows. PowerShell
uses native nested `NODE_PORTS` hashtables. Known nodes are materialized in the
editor. Missing rows fall back to base+slot; explicit rows override those bases.
Helpers separate conflict-tolerant materialization from strict candidate
validation. Runtime/restart preflight consumes overrides; live owners retain
their existing endpoints until explicitly restarted.

Readable PSD1 serialization preserves native node-port data, including through
`_conf-write-all`; its focused regression passes. New summary helpers show
planned/running endpoints and local occupancy. macOS port-bound detection now
uses netstat to see listeners whose process belongs to another account, with
`proxy-port-visibility.sh` coverage.

Shell editor work was most recently split into `_conf_edit`, `_conf_edit_run`
and `_conf_commit_edit` to snapshot settings and reject concurrent overwrites.
**Its Bash re-open regression now fails; investigate before trusting saves.**
PowerShell editing also needs a coherent single snapshot: its saved-data read
currently precedes the raw original-text read, which can race with a writer.

## Verification and known failures

Run the project runner:

```sh
PROXY_TEST_PWSH="$PWD/.superpowers/tools/powershell/pwsh" python3 tests/run.py
```

Portable PowerShell 7.6.9 is available at that ignored local path on this Mac.
Elsewhere install pwsh or set PROXY_TEST_PWSH. Native Windows/Notepad/Windows
PowerShell 5.1 have not been exercised.

The last full integration run was **39/49 checks passed**, before several later
fixture/integration updates. Do not treat that as a final result. Its failures
included Python config tests, shell killswitch/node/recovery/session/slot tests,
zsh smoke, and PowerShell Chrome/config/node tests. Some fixtures were updated
afterward, but the full suite has not been rerun on the final checkpoint.

The latest focused `test_config.py` run was **31/36 passed**:

- `test_node_restart_checks_builtin_default_when_saved_host_is_absent` fails
  in Bash and zsh.
- `test_node_restart_rejects_pending_default_change_before_stopping` fails in
  Bash and zsh.
- `test_reopening_editor_refreshes_snapshot_without_duplicate_sections` fails
  in Bash: expected one status header, got zero after the second edit.

The first four assert the old v2.12.2 role-change refusal. Stable explicit node
slots intentionally remove that role change. Replace those assertions with
checks that the correct node/ports are restarted while main stays untouched;
do not simply delete their regression coverage. The fifth is an actual editor
integration issue and needs a fix.

Other remaining fixture work: old named-default-main expectations in zsh smoke,
parts of node/Chrome tests, and partial function loaders that need new helper
dependencies. Isolated operation tests already cover coordination directly;
some legacy tunnel fixtures now bypass the coordinator because they mock every
owner identity, including unrelated paths. Preserve the real race tests.

Latest build `--check` and `git diff --check` passed before this handoff was
written. New helper, sharing, reconnect and race tests passed individually at
their recorded stages, but changes since then still require a final full run.

## Finish before release

Read the shared-proxy control spec and plan alongside this file. Complete the
editor snapshot/validation integration and its real save/reopen/concurrent-edit
tests. Check shared-mode status/doctor/Chrome paths for misleading local-owner
messages. Ensure named-node preflight cannot stop a different live node during
legacy-SSH migration; same-port HTTP/SOCKS and cross-node conflicts must fail
before teardown. Verify default switches retain main ports even with pending
saved port edits. Review the entire combined change after the final green suite.

Update docs for stable explicit nodes, shared clients, per-node overrides and
the final version. Then install with a rollback copy, commit, push and publish
only after validation. Do not restart the user's live tunnel unnecessarily.

## Local/account limits and Git history

Kimmy's installed profile/tunnel were preserved. Real local TLS probes passed,
and four concurrent Kimmy zsh sessions ran cc/cx version checks without changing
shared settings/ownership. These were not paid full conversations and did not
execute as Ming. Ming's profile/config are mode 600 and its state is private;
Kimmy cannot inspect or update them, and `sudo -n` requires a password. Do not
claim a real Ming-account verification or weaken those permissions. After a
finished release, Ming needs to update/reload its own profile and explicitly
select shared mode to use Kimmy's configured endpoints.

The user's requested Git identity correction is already pushed. Wrong auto-Mac
commits 0285b87/2bf94cc were rewritten as de9c958/e0d50be with identical trees;
the v2.12.2 tagger and release target were corrected too. Local backup refs exist
under `refs/backup/2026-11-08-author-fix/`. Keep the corrected history. Never
include authentication tokens or private local credentials in Git.

## Completed by Claude — 2026-11-07 (Linux host)

- Named-node restart: removed the unreachable "saved settings make this node
  the default" guard (Bash and PowerShell). The four old tests now assert the
  new contract: `proxy-restart sg` restarts only node-sg on its saved ports and
  leaves main untouched; a conflict with another live node fails before teardown.
- Editor re-open: behaviour was correct; assertions now check the running
  snapshot row instead of the bare port (the saved NODE_PORTS row legitimately
  keeps 8181). PowerShell editing now parses, materializes and compares one
  snapshot of the file.
- Malformed lines in the machine-written local-nodes file are skipped (as the
  allocator already did) instead of disabling every local alias node.
- PowerShell `Write-NodeSettingsFile` creates the slot folder (shared clients
  never start a local owner).
- Shared mode: `proxy-status` and `proxy-status --fix` probe the shared
  endpoint instead of telling the client account to start its own tunnel.
- Command surface: eight core commands; old names are rename wrappers;
  `bridge-*` removed; new `cc-manual`; task-oriented `cc-help`.
- Test fixtures updated for stable node slots; runner per-test timeout 300 s
  (`PROXY_TEST_TIMEOUT`), since the race suite takes ~100 s alone.
- Not verified here: native Windows / Windows PowerShell 5.1, a real Ming
  account, and installation on the Mac. `tests/proxy-desktop.ps1` fails on a
  non-Windows host also on main (fake-Windows init fails lazily); see audit.
