# Port configuration and platform scripts implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make port configuration understandable and release platform scripts.
**Architecture:** Shared shell core, OS adapters, generated standalone profiles.
**Tech Stack:** Bash 3.2, zsh, Python 3 for builds/tests.
**Spec:** docs/superpowers/specs/2026-11-04-config-platforms-design.md

## Global Constraints

- Preserve user settings and live sessions; do not implicitly restart tunnels.
- Keep Bash 3.2, zsh, single-file installation and update compatibility.
- Use 2.12.0 for shell and PowerShell version markers.

## Review Focus

- Sparse config files must expose editable ports without dropping other settings.
- Saved/live mismatches must remain visible after reload and require explicit restart.
- Rejected editors and invalid ports must not claim success or alter a working tunnel.
- Platform-specific downloads must retain their platform through self-update.
- Startup, builds and tests must not modify real user state unexpectedly.

### Task 1: Configuration UX

Files: scripts/claude-proxy.sh, tests/test_shell_startup.py, tests/test_config.py.
Interfaces: save configured port snapshots before live adoption; add
`proxy-config use-active`; retain existing show/edit/set/path commands.

- [x] Add isolated regression tests; observe failures on old behavior.
- [x] Adopt live owner before startup pin; show saved/live port summary; materialize
  missing port settings for edit; validate ports; report editor failures and restart needs.
- [x] Make default status readable, retain raw state under --debug and fix misleading
  port-conflict/restart messages. Run new tests and existing regressions.

### Task 2: Platform packaging and release

Files: scripts/lib/common.sh, scripts/lib/platform-{macos,linux}.sh,
scripts/build-profiles.py, scripts/claude-proxy{,-macos,-linux}.sh,
scripts/setup.sh, scripts/claude-proxy.ps1, tests/test_platforms.py,
docs/{upgrading,proxy-profile,troubleshooting}.md, README.md, tests/run.py.
Interfaces: platform adapters consumed by common core; standalone files retain
CLAUDE_PROXY_SELF and select their platform filename during updates.

- [x] Test standalone loading, wrong-platform rejection, deterministic generation,
  installer/updater selection, and real macOS process identity.
- [x] Extract OS adapters, generate bundles, select downloads and bump versions.
- [x] Run all local checks; document Linux/PowerShell runtime limits and CI checks.
- [x] Obtain final code review, fix material findings, install locally, verify fresh
  concurrent shells, commit, push main and v2.12.0 and publish release notes.

Published in commit 0d4baaa and tag v2.12.0. See the
[2026-11-08 follow-up](2026-11-08-proxy-follow-up.md) for subsequent work.
