# Port configuration and platform scripts

The user delegated the shared-versus-separate choice and requested local fixes,
then authorized pushing the finished release to crayonluffy/claude-guide.

Use a shared shell core plus macOS and Linux/WSL adapters. Generate standalone
macOS, Linux, and compatibility autodetect downloads from these sources. This
keeps single-file installation and updates while maintaining tunnel fixes once.
Fully separate copies were rejected because shared fixes would drift; keeping
all OS behavior in one handwritten file would retain the platform confusion.

Keep Bash 3.2 and zsh compatibility, existing commands, user settings, and the
live tunnel. Read live owner settings before startup pins Claude settings.
`proxy-config show` and `edit` distinguish saved ports from active ports.
Editing an existing sparse config includes editable HTTP, SOCKS and remote proxy
ports, with current values explained. A use-active command explicitly saves the
running ports. Configuration changes never restart other windows implicitly;
messages say when `proxy-restart` is required. Invalid ports and failed editors
must return errors without claiming success. Default status is readable; raw
recovery state moves to `proxy-status --debug`.

Platform adapters own process start identity, uptime, notifications, SSH keychain
options, Chrome launching and Node installation. Installer and updater choose
the right standalone file. Release version: 2.12.0, including the existing
PowerShell version marker to preserve the repository's version convention.
PowerShell configuration behavior is outside this Unix-shell change.

Test shell startup and configuration in isolated temporary files on real bash
and zsh. Run existing shell regressions, syntax checks and deterministic build
checks. Provide a portable test runner; report unavailable native runtimes honestly.
CI workflow publication is deferred: the authorized token has repository scope
but does not have the workflow scope needed to publish a new Actions workflow.
Review the final changes before installing locally and pushing main and v2.12.0.
