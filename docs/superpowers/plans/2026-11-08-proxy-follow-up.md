# Proxy follow-up, 2026-11-08

The v2.12.0 and v2.12.1 work was already committed and published. The installed
Mac profile still reported 2.12.0; its behavior matched the released Mac profile.
Claude settings and the live shared tunnel both used HTTP 8080.

Final review found that a stale window could stop a node, then reload saved
settings that made that node the default, and start main instead. The restart
now rejects that role change before stopping anything. Unix validation also
starts from the built-in server when sparse saved configuration omits it.
Live main owners continue to retain their established settings and node roles.

- [x] Reproduce the role change in Bash, zsh and PowerShell, then verify the fix.
- [x] Verify the sparse-config variant fails before the Unix fix and passes after.
- [x] Keep the Linux Chrome launcher regression independent of macOS nohup console requirements.
- [x] Complete focused code review with no remaining findings.
- [x] Install Mac v2.12.2 with a rollback copy; verify two concurrent fresh zsh
  windows run `cc --safe --no-verify --version` without changing personal
  configuration, Claude settings or the shared tunnel owner and record.
- [x] Run the final full portable suite: 43/43 checks passed (exit 0), using
  `PROXY_TEST_PWSH="$PWD/.superpowers/tools/powershell/pwsh" python3 tests/run.py`.
  Log: `.superpowers/2026-11-08-verified-suite.log`.
- [x] Commit the changes on `fix/2.12.2-targeted-restart`.

Release: [v2.12.2](https://github.com/crayonluffy/claude-guide/releases/tag/v2.12.2).
The previously supplied GitHub credential was recovered from the authorized
session and verified for publishing. Before publication, remote main remained
at v2.12.1; no v2.13 branch, tag or open pull request was present.

PowerShell execution uses portable 7.6.9 on macOS. Native Windows, Notepad and
Windows PowerShell 5.1 are not available. The live proxy TLS probe passed;
the Claude launch checks submit no prompt and do not test a full conversation.
