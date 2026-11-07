# Quiet terminal notices implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline.

**Goal:** Stop routine proxy flapping from interrupting Claude/Codex terminals.
**Architecture:** Gate subscriber output using a pure transition helper per
language; keep owner recovery state and logging intact.
**Tech Stack:** Bash 3.2, zsh, PowerShell 5.1-compatible source; portable PS 7 tests.
**Spec:** ../specs/2026-11-08-quiet-terminal-notices-design.md

## Constraints and review focus

Preserve immediate takeover/auth/host-key warnings in every mode. Quiet mode
must suppress short-drop recovery messages and repeated progress, warn once
for prolonged phases even when joining late, and reset after healthy state.
Subscriber registration and cleanup must remain intact. No shared tunnel restart.

## Task 1: Subscriber policy, tests, documentation and release

Files: scripts/lib/common.sh, scripts/claude-proxy.ps1, generated profiles,
tests/proxy-terminal.{sh,ps1}, existing subscriber regressions and docs.
Interfaces: `_recovery_terminal_step mode phase event warned` returns
`warned|event`; `Get-RecoveryTerminalTransition Mode Phase Event Warned`
returns Warned/Event; subscribers consume each helper without changing owners.

- [x] Add failing policy tests and real subscriber output/lifecycle checks.
- [x] Implement quiet/verbose/off settings and subscriber-only filtering.
- [x] Verify Bash, zsh and PowerShell; bump 2.12.3 and document behavior.
- [x] Run the full portable suite and focused code review; fix material findings.
- [ ] Install locally with backup and preserve live settings/tunnel; commit,
  publish v2.12.3 and verify remote/downloads.

45/45 checks passed; `.superpowers/2026-11-08-quiet-suite.log`. Focused review
found no remaining issues. Publishing is deferred while the user's subsequent
cross-account sharing, multi-node editor and switching-race requirements are
investigated. Preserve this work; do not mistake the later requests for cancellation.
