# Maintaining the shell profiles

The shell profiles share tunnel, configuration and recovery logic. OS-specific
behavior lives in separate adapters:

- `scripts/lib/common.sh`: common implementation, with a platform insertion marker.
- `scripts/lib/platform-macos.sh`: macOS process identity, uptime, notifications,
  SSH Keychain options, Chrome launching and Node installation.
- `scripts/lib/platform-linux.sh`: Linux/WSL equivalents.

Generate the downloadable profiles after changing these sources:

```sh
python3 scripts/build-profiles.py
python3 tests/run.py
```

Commit the sources and all generated files together. `build-profiles.py --check`
fails if any generated profile differs from its sources. Do not edit generated
files by hand.

The outputs are standalone; users need no build tools or adjacent library files:

| Download | Platform |
| --- | --- |
| `scripts/claude-proxy-macos.sh` | macOS, bash or zsh |
| `scripts/claude-proxy-linux.sh` | Linux/WSL, bash or zsh |
| `scripts/claude-proxy.sh` | Compatibility download; detects macOS/Linux |

The installer and `proxy-update` select the native download. All install to
`~/.claude-proxy.sh`, preserving the existing shell startup line and user config.
The platform-specific files reject an incompatible OS before writing state.

`tests/run.py` removes inherited proxy configuration variables, runs isolated
Python regression tests and the existing shell suites, then checks shell syntax
and generated-file consistency. Run it on both macOS and Linux to cover the
native adapters. PowerShell has separate `tests/*.ps1`; its behavior is unchanged
in 2.12.0. The optional `tests/e2e/run.sh` needs a Linux sshd setup and network
access; it is not part of this local portable suite.
