# Windows configuration parity

Bring the v2.12.0 active-node/configuration experience to native Windows
PowerShell, as requested. Keep the existing PSD1 format, Notepad default,
PowerShell 5.1 compatibility, `cc`/`cx` commands and shared recovery owners.

`proxy-config show` and `edit` show saved main ports, saved node base ports and
every running node owner's HTTP/SOCKS/remote/SSH ports. Editing materializes
missing port settings, preserves unrelated saved settings, and validates a
temporary PSD1 file before replacing the saved file. Failed editors and invalid
ports must preserve the original. `proxy-config use-active` saves the main
tunnel's running ports without capturing unrelated runtime overrides.

Settings changes do not restart owners. Startup adopts the main live record
before pinning Claude; node contexts adopt their live record until restarted.
Restart explicitly applies saved settings, preflights node port conflicts and
warns that changed local endpoints require affected applications to relaunch.
Default status shows actionable information; `proxy-status -Debug` adds recovery
details. Windows parameter syntax remains idiomatic PowerShell.

Use portable PowerShell 7 on this Mac for execution tests; Windows-specific
Notepad/process boundaries are isolated in tests. Do not claim native Windows
or Windows PowerShell 5.1 execution without those runtimes. Run existing shell
and PowerShell regressions, request code review and publish v2.12.1 using the
previously authorized repository access, with all version markers aligned.
