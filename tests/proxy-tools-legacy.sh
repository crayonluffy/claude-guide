#!/usr/bin/env bash
# Old Macs (2.13.10): cc-install takes the newest Node.js line the macOS version
# can run (22 on macOS 11-13.4, 20 on 10.15) and, before macOS 13, the last
# Claude Code that is plain JavaScript (2.1.112), with its auto-update off.
# Everything here runs against stand-ins: nothing is downloaded or installed.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$scratch/apps" "$scratch/home"
cat > "$scratch/index.json" <<'EOF'
[
{"version":"v27.0.0-alpha.0.1.0","date":"2026-11-12","files":["osx-arm64-tar","osx-x64-pkg"],"npm":"12.2.2","lts":false,"security":false},
{"version":"v26.13.1","date":"2026-11-10","files":["osx-x64-pkg"],"npm":"11.9.0","lts":"Lithium","security":false},
{"version":"v25.9.0","date":"2026-03-31","files":["osx-x64-pkg"],"npm":"11.6.2","lts":false,"security":false},
{"version":"v24.22.3","date":"2026-11-10","files":["osx-x64-pkg"],"npm":"11.6.2","lts":"Krypton","security":true},
{"version":"v22.23.5","date":"2026-11-11","files":["osx-x64-pkg"],"npm":"10.9.4","lts":"Jod","security":false},
{"version":"v22.23.4","date":"2026-10-01","files":["osx-x64-pkg"],"npm":"10.9.4","lts":"Jod","security":false},
{"version":"v20.20.2","date":"2026-03-24","files":["osx-x64-pkg"],"npm":"10.8.2","lts":"Iron","security":true},
{"version":"v2.5.0","date":"2015-08-04","files":["osx-x64-pkg"],"npm":"2.13.2","lts":false,"security":false}
]
EOF
run() {  # <shell> <code>: an isolated shell with the real profile loaded
    env -i PATH="$scratch/apps:$PATH" HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" SCRATCH="$scratch" \
        CLAUDE_PROXY_CONF="$scratch/proxy.conf" CLAUDE_PROXY_NODES="$scratch/nodes.json" \
        CLAUDE_SETTINGS="$scratch/settings.json" CLAUDE_KILLSWITCH=off CLAUDE_PROXY_BANNER=0 \
        "$1" -c '. "$0" >/dev/null 2>&1; '"$2" "$src"
}
app() {  # <name> <output of --version, or 'broken'>: a stand-in program on PATH
    if [ "$2" = broken ]; then printf '#!/bin/sh\nexit 126\n' > "$scratch/apps/$1"
    else printf '#!/bin/sh\necho "%s"\necho "AU=${DISABLE_AUTOUPDATER:-unset}"\n' "$2" > "$scratch/apps/$1"; fi
    chmod +x "$scratch/apps/$1"
}
printf 'CLAUDE_KILLSWITCH=off\nCLAUDE_PROXY_BANNER=0\n' > "$scratch/proxy.conf"

for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue

    # --- which Node.js line a macOS version can run, and where Claude Code needs the old release
    for pair in '26.1:' '15.2:' '13.5:' '13.4.1:22' '13.0:22' '12.7.6:22' '11.0:22' '10.15.7:20' '10.14.6:0' '10.9:0'; do
        got=$(run "$sh" "_CLAUDE_MACOS_VERSION=${pair%%:*}; _macos_node_max")
        [ "$got" = "${pair#*:}" ] || fail "$sh macOS ${pair%%:*}: Node.js line '$got', expected '${pair#*:}'"
    done
    for pair in '26.1:new' '13.5:new' '13.0:new' '12.7.6:old' '11.0:old' '10.15.7:old'; do
        got=$(run "$sh" "_CLAUDE_MACOS_VERSION=${pair%%:*}; if _macos_claude_legacy; then echo old; else echo new; fi")
        [ "$got" = "${pair#*:}" ] || fail "$sh macOS ${pair%%:*}: Claude Code '$got', expected '${pair#*:}'"
    done
    # An unreadable version changes nothing (the newest LTS, the current Claude Code).
    got=$(run "$sh" 'sw_vers() { return 1; }; echo "max=$(_macos_node_max)"; if _macos_claude_legacy; then echo old; else echo new; fi')
    [ "$got" = "$(printf 'max=\nnew')" ] || fail "$sh unknown macOS version: $got"
    got=$(run "$sh" 'sw_vers() { echo 12.7.6; }; echo "max=$(_macos_node_max)"')
    [ "$got" = 'max=22' ] || fail "$sh sw_vers is not read: $got"
    got=$(run "$sh" 'echo "max=$(_linux_node_max)"; if _linux_claude_legacy; then echo old; else echo new; fi')
    [ "$got" = "$(printf 'max=\nnew')" ] || fail "$sh Linux must have no limit: $got"
    echo "PASS: $sh - Node.js line and Claude Code release per macOS version"

    # --- the newest release of a line, from nodejs.org's index
    stub='curl() { cat "$SCRATCH/index.json"; }; '
    got=$(run "$sh" "$stub"'echo "$(_tools_node_latest 22) $(_tools_node_latest 20) [$(_tools_node_latest 19)] $(_tools_node_lts)"')
    [ "$got" = 'v22.23.5 v20.20.2 [] v26.13.1' ] || fail "$sh Node.js versions from the index: $got"
    got=$(run "$sh" 'curl() { return 7; }; echo "[$(_tools_node_latest 22)]"')
    [ "$got" = '[]' ] || fail "$sh unreachable index: $got"

    # --- the Node.js version Claude Code needs: the release that will be installed decides
    stub='curl() { case "$*" in *claude-code/2.1.112*) echo "{\"engines\":{\"node\":\">=18.0.0\"}}";; *claude-code/latest*) echo "{\"engines\":{\"node\":\">=22.0.0\"}}";; *codex/latest*) echo "{\"engines\":{\"node\":\">=16\"}}";; *) return 22;; esac; }; '
    got=$(run "$sh" "$stub"'echo "$(_tools_min_node) $(_tools_min_node latest) $(_tools_min_node 2.1.112)"')
    [ "$got" = '22 22 18' ] || fail "$sh needed Node.js: $got"
    got=$(run "$sh" 'curl() { return 7; }; echo "$(_tools_min_node latest) $(_tools_min_node 2.1.112)"')
    [ "$got" = '22 18' ] || fail "$sh needed Node.js without the registry: $got"
    echo "PASS: $sh - Node.js versions from nodejs.org and the npm registry"

    # --- installing Node.js: the capped line goes to the installer
    stub='_tools_ask() { return 0; }; _tools_node_version() { cat "$SCRATCH/nodever" 2>/dev/null; }
        _platform_install_node() { echo "INSTALL:[$1]"; echo "${NEWVER:-v22.23.5}" > "$SCRATCH/nodever"; }; '
    rm -f "$scratch/nodever"
    out=$(run "$sh" "$stub"'_platform_node_max() { echo 22; }; _tools_node 22')
    case "$out" in *'Install Node.js 22 now'*) fail "$sh asked although answers were given";; esac
    case "$out" in *'INSTALL:[22]'*'[OK]  Node.js v22.23.5 installed'*) ;; *) fail "$sh capped install: $out";; esac
    case "$out" in *'Node.js 22 is the newest line that runs on this version'*) ;; *) fail "$sh capped install gives no reason: $out";; esac
    rm -f "$scratch/nodever"
    out=$(run "$sh" "$stub"'NEWVER=v20.20.2; _platform_node_max() { echo 20; }; _tools_node 18')
    case "$out" in *'INSTALL:[20]'*'[OK]  Node.js v20.20.2 installed'*) ;; *) fail "$sh Node.js 20 install: $out";; esac
    rm -f "$scratch/nodever"
    out=$(run "$sh" "$stub"'NEWVER=v26.13.1; _platform_node_max() { :; }; _tools_node 22')
    case "$out" in *'INSTALL:[]'*'[OK]  Node.js v26.13.1 installed'*) ;; *) fail "$sh uncapped install changed: $out";; esac
    case "$out" in *'newest line that runs'*) fail "$sh uncapped install talks about a limit: $out";; esac
    # Too old for any supported Node.js, or for the one Claude Code needs: stop, install nothing.
    rm -f "$scratch/nodever"
    rc=0; out=$(run "$sh" "$stub"'_platform_node_max() { echo 0; }; _tools_node 18') || rc=$?
    [ "$rc" -ne 0 ] || fail "$sh macOS before 10.15 was accepted"
    case "$out" in *INSTALL*) fail "$sh macOS before 10.15: installed anyway";; *'too old for Node.js 18'*) ;; *) fail "$sh macOS before 10.15: $out";; esac
    rc=0; out=$(run "$sh" "$stub"'_platform_node_max() { echo 20; }; _tools_node 22') || rc=$?
    [ "$rc" -ne 0 ] || fail "$sh Node.js 20 accepted where 22 is needed"
    case "$out" in *INSTALL*) fail "$sh cap below the minimum: installed anyway";; *'can run Node.js 20 at most'*'need 22'*) ;; *) fail "$sh cap below the minimum: $out";; esac
    # A Node.js that is new enough is kept, whatever the cap.
    echo v22.1.0 > "$scratch/nodever"
    out=$(run "$sh" "$stub"'_platform_node_max() { echo 22; }; _tools_node 22')
    [ "$out" = '[OK]  Node.js v22.1.0 (needs 22 or newer)' ] || fail "$sh good Node.js not kept: $out"
    # nvm installs the same line.
    rm -f "$scratch/nodever"; mkdir -p "$scratch/home/.nvm"
    printf 'nvm() { echo "NVM:$*"; [ "$1" != install ] || echo "v$2.0.0" > "$SCRATCH/nodever"; }\n' > "$scratch/home/.nvm/nvm.sh"
    out=$(run "$sh" "$stub"'_platform_node_max() { echo 22; }; _tools_node 22')
    case "$out" in *'NVM:install 22'*'NVM:alias default 22'*) ;; *) fail "$sh nvm with a cap: $out";; esac
    case "$out" in *INSTALL*) fail "$sh nvm present but the system installer ran";; esac
    rm -f "$scratch/nodever"
    out=$(run "$sh" "$stub"'_platform_node_max() { :; }; _tools_node 22' 2>&1) || :
    case "$out" in *'NVM:install --lts'*) ;; *) fail "$sh nvm without a cap changed: $out";; esac
    rm -rf "$scratch/home/.nvm"
    echo "PASS: $sh - cc-install takes the newest Node.js line the system can run"

    # --- the macOS installer: an old Mac gets the official package of its line, not Homebrew
    stub='curl() { case "$*" in *index.json*) cat "$SCRATCH/index.json";; *) echo "CURL:$*";; esac; }
        brew() { echo "BREW:$*"; }; sudo() { echo "SUDO:$*"; }; '
    out=$(run "$sh" "$stub"'_macos_install_node 22')
    case "$out" in *BREW*) fail "$sh old Mac: Homebrew was used: $out";; esac
    case "$out" in *'https://nodejs.org/dist/v22.23.5/node-v22.23.5.pkg'*'SUDO:installer -pkg'*) ;; *) fail "$sh old Mac: package of line 22: $out";; esac
    out=$(run "$sh" "$stub"'_macos_install_node')
    case "$out" in *'BREW:install node'*|*'BREW:upgrade node'*) ;; *) fail "$sh current Mac with Homebrew changed: $out";; esac
    out=$(run "$sh" 'curl() { case "$*" in *index.json*) cat "$SCRATCH/index.json";; *) echo "CURL:$*";; esac; }; sudo() { echo "SUDO:$*"; }
        command() { if [ "$1" = -v ] && [ "$2" = brew ]; then return 1; else builtin command "$@"; fi; }; _macos_install_node')
    case "$out" in *'node-v26.13.1.pkg'*) ;; *) fail "$sh current Mac without Homebrew: newest LTS expected: $out";; esac
    echo "PASS: $sh - macOS installs the official Node.js package of the capped line"

    # --- Claude Code pinned to the last release that runs
    stub='_tools_ask() { return 0; }; _tools_npm_prefix() { return 0; }
        npm() { case "$1" in view) echo "${REGISTRY-2.1.325}";; ls) return 0;; install) echo "NPM:$*"; printf "#!/bin/sh\necho \"%s (Claude Code)\"\n" "${3##*@}" > "$SCRATCH/apps/cg-claude"; chmod +x "$SCRATCH/apps/cg-claude";; esac; }; '
    pinned='_tools_pkg "Claude Code" cg-claude @anthropic-ai/claude-code "claude update" cc 2.1.112'
    rm -f "$scratch/apps/cg-claude"
    out=$(run "$sh" "$stub$pinned")
    case "$out" in *'NPM:install -g @anthropic-ai/claude-code@2.1.112'*'Claude Code 2.1.112 ready'*) ;; *) fail "$sh pinned install: $out";; esac
    case "$out" in *@latest*|*2.1.325*) fail "$sh pinned install mentions the newest release: $out";; esac
    out=$(run "$sh" "$stub$pinned")
    case "$out" in *NPM:*) fail "$sh pinned release installed twice: $out";; *'[OK]  Claude Code 2.1.112 (the newest release that runs'*) ;; *) fail "$sh pinned and present: $out";; esac
    app cg-claude '2.1.325 (Claude Code)'
    out=$(run "$sh" "$stub$pinned")
    case "$out" in *'Claude Code 2.1.325; this system needs Claude Code 2.1.112'*'NPM:install -g @anthropic-ai/claude-code@2.1.112'*) ;; *) fail "$sh newer release not replaced: $out";; esac
    app cg-claude broken   # what an auto-update leaves on an old Mac: a program that cannot start
    out=$(run "$sh" "$stub$pinned")
    case "$out" in *'is installed but does not start'*'NPM:install -g @anthropic-ai/claude-code@2.1.112'*) ;; *) fail "$sh broken install not repaired: $out";; esac
    rm -f "$scratch/apps/cg-claude"
    rc=0; out=$(run "$sh" "REGISTRY=; $stub$pinned") || rc=$?
    [ "$rc" -ne 0 ] || fail "$sh pinned install without the registry reported success"
    case "$out" in *NPM:*) fail "$sh pinned install without the registry ran npm";; esac
    # Without a pin nothing changes: the newest release.
    out=$(run "$sh" "$stub"'_tools_pkg "Claude Code" cg-claude @anthropic-ai/claude-code "claude update" cc')
    case "$out" in *'not installed (latest: 2.1.325)'*'NPM:install -g @anthropic-ai/claude-code@latest'*) ;; *) fail "$sh unpinned install changed: $out";; esac
    rm -f "$scratch/apps/cg-claude"
    echo "PASS: $sh - an old Mac gets Claude Code 2.1.112, a current one the newest"

    # --- automatic updates off in Claude's settings (jq), without losing anything
    if command -v jq >/dev/null 2>&1; then
        printf '{"theme":"dark","env":{"HTTPS_PROXY":"http://127.0.0.1:8080"}}\n' > "$scratch/settings.json"
        out=$(run "$sh" '_TOOLS_CHECK=1; _tools_claude_no_autoupdate')
        case "$out" in *'still on'*) ;; *) fail "$sh check mode says nothing: $out";; esac
        [ "$(jq -c . "$scratch/settings.json")" = '{"theme":"dark","env":{"HTTPS_PROXY":"http://127.0.0.1:8080"}}' ] || fail "$sh check mode changed the settings"
        out=$(run "$sh" '_tools_claude_no_autoupdate')
        [ "$(jq -c . "$scratch/settings.json")" = '{"theme":"dark","env":{"HTTPS_PROXY":"http://127.0.0.1:8080","DISABLE_AUTOUPDATER":"1"}}' ] || fail "$sh settings after: $(cat "$scratch/settings.json")"
        before=$(cat "$scratch/settings.json")
        out=$(run "$sh" '_tools_claude_no_autoupdate')
        [ -z "$out" ] && [ "$(cat "$scratch/settings.json")" = "$before" ] || fail "$sh second run is not silent: $out"
        rm -f "$scratch/settings.json"*; run "$sh" '_tools_claude_no_autoupdate' >/dev/null
        [ "$(jq -c . "$scratch/settings.json")" = '{"env":{"DISABLE_AUTOUPDATER":"1"}}' ] || fail "$sh missing settings file: $(cat "$scratch/settings.json")"
        : > "$scratch/settings.json"; run "$sh" '_tools_claude_no_autoupdate' >/dev/null
        [ "$(jq -c . "$scratch/settings.json")" = '{"env":{"DISABLE_AUTOUPDATER":"1"}}' ] || fail "$sh empty settings file: $(cat "$scratch/settings.json")"
        printf '{ not json\n' > "$scratch/settings.json"
        out=$(run "$sh" '_tools_claude_no_autoupdate')
        case "$out" in *'[Warn] Could not update'*) ;; *) fail "$sh invalid settings: $out";; esac
        [ "$(cat "$scratch/settings.json")" = '{ not json' ] || fail "$sh invalid settings were overwritten"
        printf '{"theme":"dark"}\n' > "$scratch/settings.json"
        run "$sh" 'CLAUDE_SYNC_SETTINGS=0; _tools_claude_no_autoupdate' >/dev/null
        [ "$(cat "$scratch/settings.json")" = '{"theme":"dark"}' ] || fail "$sh SYNC_SETTINGS=0 was ignored"
        rm -f "$scratch/settings.json"*
        echo "PASS: $sh - automatic updates are turned off in Claude's settings, nothing else changes"
    else
        echo "SKIP: $sh - settings checks need jq"
    fi

    # --- cc starts a pinned Claude Code with automatic updates off; Codex and current Macs are unchanged
    app claude '2.1.112 (Claude Code)'; app codex 'codex-cli 0.169.0'
    stub='proxy-up() { :; }; CLAUDE_TUNNEL_WATCHDOG=0; '
    out=$(run "$sh" "$stub"'_platform_claude_legacy() { return 0; }; cc --no-verify' 2>/dev/null)
    case "$out" in *'AU=1'*) ;; *) fail "$sh old Mac: cc left automatic updates on: $out";; esac
    out=$(run "$sh" "$stub"'_platform_claude_legacy() { return 0; }; cx --no-verify' 2>/dev/null)
    case "$out" in *'AU=unset'*) ;; *) fail "$sh old Mac: cx changed Codex: $out";; esac
    out=$(run "$sh" "$stub"'_platform_claude_legacy() { return 1; }; cc --no-verify' 2>/dev/null)
    case "$out" in *'AU=unset'*) ;; *) fail "$sh current Mac: cc turned automatic updates off: $out";; esac
    echo "PASS: $sh - cc starts the pinned Claude Code with automatic updates off"

    # --- cc-install on an old Mac, check only: says what it uses and changes nothing
    printf '{"theme":"dark"}\n' > "$scratch/settings.json"
    stub='curl() { case "$*" in *claude-code/2.1.112*) echo "{\"engines\":{\"node\":\">=18.0.0\"}}";; *codex/latest*) echo "{\"engines\":{\"node\":\">=16\"}}";; *) return 22;; esac; }
        npm() { case "$1:$2" in view:@openai/codex) echo 0.169.0;; view:*) echo 2.1.325;; ls:*) return 0;; *) echo "NPM:$*";; esac; }
        _platform_claude_legacy() { return 0; }; _platform_node_max() { echo 20; }; _tools_node_version() { echo v20.20.2; }; '
    out=$(run "$sh" "$stub"'cc-install --check --no-proxy' 2>&1)
    case "$out" in *'needs macOS 13 or newer; this Mac has an older macOS'*'gets Claude Code 2.1.112'*) ;; *) fail "$sh cc-install does not explain the old release: $out";; esac
    case "$out" in *'[OK]  Node.js v20.20.2 (needs 18 or newer)'*) ;; *) fail "$sh cc-install: Node.js 20 not accepted for the old release: $out";; esac
    case "$out" in *'[OK]  Claude Code 2.1.112 (the newest release that runs'*) ;; *) fail "$sh cc-install: pinned release: $out";; esac
    case "$out" in *'[OK]  Codex 0.169.0 (latest: 0.169.0)'*) ;; *) fail "$sh cc-install: Codex: $out";; esac
    case "$out" in *NPM:*) fail "$sh check mode ran npm: $out";; esac
    [ "$(cat "$scratch/settings.json")" = '{"theme":"dark"}' ] || fail "$sh check mode changed the settings"
    rm -f "$scratch/settings.json"* "$scratch/apps/claude" "$scratch/apps/codex"
    echo "PASS: $sh - cc-install explains and checks the old-Mac setup without changing anything"
done
