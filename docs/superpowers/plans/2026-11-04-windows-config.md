# Windows configuration parity implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Match the active-node configuration experience across platforms.
**Architecture:** Reuse PowerShell recovery descriptors and the shared owner;
separate saved configuration data from adopted runtime settings.
**Tech Stack:** PowerShell 5.1-compatible syntax; portable PowerShell 7 execution;
existing Bash/zsh suite and deterministic shell builds.
**Spec:** docs/superpowers/specs/2026-11-04-windows-config-design.md

## Global Constraints

- Preserve existing PSD1 settings, comments, Unicode and unrelated keys.
- No implicit tunnel restarts or changes to other windows' running ports.
- Keep native PowerShell parameter syntax and Notepad editing.
- Release 2.12.1, with all profiles' version markers aligned.

## Review Focus

- Existing sparse PSD1 files gain editable ports and current active-node tables.
- Failed editors/invalid PSD1/invalid ports never replace saved configuration.
- Runtime adoption cannot overwrite pending saved values during set/use-active.
- Live node ports stay stable until explicit restart, whose probes use new ports.
- Only the target owner is restarted; changed endpoints require relaunch guidance.

### Task 1: Configuration parity

Files: scripts/claude-proxy.ps1, tests/proxy-config.ps1.
Interfaces: saved defaults snapshot; data reader/writer; active-node overview;
transactional editor boundary; `proxy-config use-active`.

- [x] Add failing execution tests using real temporary PSD1 files and descriptors.
- [x] Implement saved/live overview, materialized port keys, safe editing,
  validated set/use-active and startup adoption; verify red to green.

### Task 2: Runtime consistency and release

Files: scripts/claude-proxy.ps1, tests/proxy-config.ps1, tests/run.py,
scripts/lib/common.sh and generated profiles (version only), docs, README.md.
Interfaces: existing node context/restart/status functions use saved/live helpers.

- [x] Test and implement live-node adoption, explicit saved-setting restarts,
  conflict preflight, changed-endpoint guidance and status detail switch.
- [x] Run all PowerShell and shell tests; document native Windows/5.1 limitations.
- [x] Obtain final review, fix material findings, publish 2.12.1 and verify remote.

Remote main, tag and published release v2.12.1 were verified on 2026-11-08
(commit a63009c). The remaining targeted-restart edge was addressed in the
[2026-11-08 follow-up](2026-11-08-proxy-follow-up.md).
