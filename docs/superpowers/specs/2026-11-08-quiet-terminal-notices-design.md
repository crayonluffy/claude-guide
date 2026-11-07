# Quiet proxy notices inside Claude and Codex

The user reports that repeated connection-lost and restored messages interrupt
Claude and Codex terminals. Each failed probe currently produces a lost event,
then each recovery produces a restored event; subscribers print both directly.

## Approaches

Increasing probe timeouts changes recovery behavior without controlling output.
Disabling all terminal output loses useful prolonged-outage and actionable SSH
warnings. The proposed default is quiet subscribers: brief outages are silent,
one prolonged warning appears at WATCHDOG_NOTICE_AFTER (60 seconds by default),
and one recovery message appears only if that subscriber warned first. This
default is the agent's assumption while the optional preference question is open.

Add TERMINAL_NOTIFICATIONS (`CLAUDE_TERMINAL_NOTIFICATIONS` in shell profiles):
`quiet` by default, `verbose` for existing lost/progress/restored output, `off`
for no routine terminal notices. Port-takeover, authentication and host-key
warnings remain immediate in every mode. Desktop notifications, health probes,
recovery timing, session registration, tunnel ownership and logs stay as they are.

Use each subscriber's observed phase and warning history, so joining an already
prolonged outage gives one warning even if its original event was missed.
Retain PowerShell, Bash 3.2 and zsh support. Existing running subscribers need
the CLI to be relaunched; installing the profile must not close applications or
restart the shared tunnel. Release version: 2.12.3.
