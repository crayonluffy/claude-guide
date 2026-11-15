# Old Macs: Node.js 20 / 22 and a Claude Code that still runs (plan, 2026-11-15)

Status: research done, **nothing implemented yet**. Target release: 2.13.10.

## Problem

`cc-install` (and the installer's last step) installs the newest Node.js LTS
(`brew install node`, or the newest LTS `.pkg`). On an older MacBook that
fails: the newest lines do not run there. The request: support Macs that can
only install Node.js 20 or 22.

## Facts (each checked on 2026-11-15)

| Fact | Source |
|---|---|
| Node 20: macOS x64 >= 10.15, arm64 >= 11. Node 22: >= 11.0. Node 24 and 26: >= 13.5 | `BUILDING.md` on the `v20.x`, `v22.x`, `v24.x`, `v26.x` branches of nodejs/node |
| Newest LTS is v26.13.1; newest of each line: v24.22.3, v22.23.5, v20.20.2 (20 is end-of-life). All have a `node-<ver>.pkg` | `https://nodejs.org/dist/index.json` |
| `@anthropic-ai/claude-code` latest (2.1.325) has `engines.node >= 22` | npm registry |
| Since 2.1.113 (2026-04-17) that package is a wrapper around a native program; **every native build needs macOS 13.0** (checked 2.1.113, 2.1.182, 2.1.252, 2.1.325, x64 and arm64) | `LC_BUILD_VERSION` of the binaries in `@anthropic-ai/claude-code-darwin-*`; the docs also say "macOS 13.0+" |
| **2.1.112 (2026-04-16) is the last plain-JavaScript release**, `engines.node >= 18`, `bin: cli.js` | npm registry |
| `@openai/codex` latest (0.169.0): launcher needs Node >= 16; its macOS binary needs 10.12 (x64) / 11.0 (arm64). No pin needed | npm registry, Mach-O headers |
| `DISABLE_AUTOUPDATER=1` disables automatic background updates | `code.claude.com/docs/en/env-vars` |

**Not verified:** that 2.1.112 really runs on Node 20 / 22 and still signs in
and works against the service today (running the package was blocked in the
session; nobody tested on a real old Mac). Verify on a real Mac before release.

## Consequence

Choosing an older Node.js is not enough: on macOS 12 and older the current
Claude Code cannot start at all. Those Macs need Node 20/22 **and** Claude Code
2.1.112, with its auto-update off (an auto-update would install a native build
that does not start).

| macOS | Node.js to install | Claude Code |
|---|---|---|
| >= 13.5 | newest LTS (as now) | latest |
| 13.0 - 13.4 | newest 22.x | latest (needs Node >= 22) |
| 11.0 - 12.x | newest 22.x | 2.1.112, auto-update off |
| 10.15 | newest 20.x (Intel) | 2.1.112, auto-update off |
| < 10.15 | not supported: say so, install nothing | - |

Codex: latest everywhere.

Trade-off to tell the user (output and docs): 2.1.112 is frozen at April 2026:
no new features or fixes, and it may stop working with the service one day.

## Implementation (shell profiles; edit `scripts/lib/`, then `build-profiles.py`)

1. `scripts/build-profiles.py`: add `node_max` and `claude_legacy` to `APIS`.
2. `scripts/lib/platform-macos.sh`:
   - `_macos_version_num`: `sw_vers -productVersion` as major*100+minor
     (`_CLAUDE_MACOS_VERSION` overrides it: test hook and escape hatch).
   - `_macos_node_max`: '' (>= 13.5), `22` (11.0-13.4), `20` (10.15), `0` (older).
   - `_macos_claude_legacy`: true below 13.0.
   - `_macos_install_node [major]`: with a major, skip Homebrew (no bottles for
     old macOS) and install `https://nodejs.org/dist/<ver>/node-<ver>.pkg` for
     the newest `<ver>` of that line.
3. `scripts/lib/platform-linux.sh`: `_linux_node_max` prints nothing,
   `_linux_claude_legacy` returns 1; `_linux_install_node` ignores the argument.
4. `scripts/lib/common.sh` (cc-install section):
   - `CLAUDE_LEGACY_CLAUDE_VERSION=2.1.112`.
   - `_tools_node_latest <major>`: newest version of a line from `index.json`.
   - `_tools_install_node [major]`: nvm -> `nvm install <major>` + default alias.
   - `_tools_node`: read `_platform_node_max`; `0` -> clear error; a cap below
     the needed minimum -> clear error; otherwise install the capped line and
     say why ("the newest this macOS can run").
   - `_tools_min_node`: ask the registry about the Claude Code version that
     will be installed (`.../claude-code/2.1.112` when legacy); fallback 18
     when legacy, 22 otherwise.
   - `_tools_pkg`: optional pinned version. Installed and equal -> OK with the
     reason; older, newer, or not runnable (`--version` prints nothing) ->
     offer `npm install -g <pkg>@<pin>`; never offer `@latest`.
   - After a legacy install: write `env.DISABLE_AUTOUPDATER = "1"` into
     `$CLAUDE_SETTINGS` with jq (`_settings_file_replace`), and say so.
   - `_launch_via_proxy`: on a legacy OS add `DISABLE_AUTOUPDATER=1` to the
     Claude process environment (`app_env`).
5. Version 2.13.10 in `common.sh` and `claude-proxy.ps1`; changelog; docs:
   a short "Older Macs" section in `docs/install-claude.md` and one row in
   `docs/troubleshooting.md`.

## Tests (`tests/proxy-tools-legacy.sh`, bash and zsh, stubs only)

- `_macos_node_max` / `_macos_claude_legacy` for 26.1, 15.2, 13.5, 13.4, 13.0,
  12.7.6, 11.0, 10.15.7, 10.14.6 and unknown.
- `_tools_node_latest 22` and `_tools_node_lts` against an `index.json` fixture
  whose first entry is a v27 alpha.
- `_tools_node` with stubs: cap 22 passes `22` to the platform installer; cap 0
  and cap < minimum stop without installing.
- `_tools_pkg` with a pin: installs `@2.1.112`; equal version -> no install;
  not runnable -> reinstall; a stub `npm` records the arguments.
- `cc` on a legacy OS starts Claude with `DISABLE_AUTOUPDATER=1` (stand-in
  `claude` on PATH, as in `tests/proxy-commands.sh`).
- Run the suite on office-sg (bash 5.3) and on claude-prod (bash 5.2), in the
  foreground.

## Also open

- The CI workflow is on the local branch `ci/tests-workflow` (not pushed: the
  gh tokens lack the `workflow` scope).
