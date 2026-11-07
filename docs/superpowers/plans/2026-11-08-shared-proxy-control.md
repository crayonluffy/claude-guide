# Shared proxy control implementation plan

> **For agentic workers:** Use executing-plans inline; isolated operation helper
> artifacts are delegated under dispatching-parallel-agents. Do not edit each
> other's files. One fresh review of the completed change precedes publishing.

**Goal:** Share a trusted local proxy across accounts and make node changes safe.
**Architecture:** Explicit shared-client mode, per-user serialized operations,
stable named node endpoints and editable per-node overrides.
**Tech Stack:** Bash 3.2, zsh, native-format PowerShell configuration, portable PS7.
**Spec:** ../specs/2026-11-08-shared-proxy-control-design.md

## Constraints / review focus

Never manage another account's listener. Shared mode still validates HTTPS,
NO_PROXY and Claude settings. No direct fallback on failure. Preserve settings
and existing sessions on validation errors. Release operation gates before the
app runs. Keep main and explicitly selected node endpoints distinct and stable.

## Task 1: Sharing and readiness

Files: common.sh, claude-proxy.ps1, tests/test_shared_proxy.py, tests/proxy-shared.ps1.
Interface: PROXY_MODE managed/shared; runtime helpers select client behavior;
existing proxy-up and cc/cx interfaces stay.

- [x] Reproduce hidden foreign ownership and live-owner reconnect rejection.
- [x] Add explicit shared clients with no owner lifecycle calls and guarded controls.
- [x] Wait for an owned reconnect before the final readiness/kill-switch checks.
- [x] Verify managed behavior, shared failure/NO_PROXY pinning and both providers.

## Task 2: Serialize operations and stabilize named nodes

Files: scripts/lib/operations.sh, build-profiles.py, common.sh, claude-proxy.ps1,
tests/proxy-operations.*, switch-race regression and existing node regressions.
Interfaces: shell _proxy_operation_owned/run/release; PowerShell
Test-RecoveryOperation / Invoke-RecoveryOperation / Exit-RecoveryOperation.

- [x] Integrate coordinator artifacts; prove concurrency/nesting/early release.
- [x] Guard main switch/restart/start and startup through subscriber registration.
- [x] Named nodes always get node-name slots; main is selected only implicitly.
- [x] Reproduce/fix switch races; retain selected server and main ports.

## Task 3: Node editor

Files: common.sh, claude-proxy.ps1, config regressions and docs.
Interface: NODE_PORTS data; shell multiline rows `node HTTP SOCKS`, PowerShell
native per-node hashtables. Missing entries fall back to base+slot.

- [x] Add failing multi-node editing, preservation and conflict regressions.
- [x] Expose editable saved assignments for every known node alongside running
  endpoints and occupied-port diagnostics; validate before replacing settings.
- [x] Use overrides consistently at node launch/restart/preflight; preserve owners.

## Task 4: Release

- [x] Update docs and all generated markers to 2.13.0; run full portable suite.
- [ ] Fresh focused review and necessary fixes; verify real local network startup
  without changing Kimmy's live owner/config or Ming's private files.
- [ ] Install/commit as crayonluffy <crayonluffy@gmail.com>; publish and verify.
