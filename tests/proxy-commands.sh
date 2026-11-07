#!/usr/bin/env bash
# The slim command surface (2.13): new spellings dispatch to the real code,
# old names still work and say what replaced them, cc-help lists the core
# commands, and cc-manual prints a correct fallback without changing anything.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$scratch/nodes.json" <<'EOF'
{ "nodes": [
{ "name": "jp", "alias": "jpvpn", "host": "jp.example.com", "slot": 0 },
{ "name": "sg", "alias": "sgvpn", "host": "sg.example.com", "proxy_port": 8899, "slot": 1 }
] }
EOF
printf '{"theme":"dark"}\n' > "$scratch/settings.json"
run() {  # <shell> <code>: an isolated shell with the real profile loaded
    env -i PATH="$PATH" HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" \
        CLAUDE_PROXY_CONF="$scratch/proxy.conf" CLAUDE_PROXY_NODES="$scratch/nodes.json" \
        CLAUDE_SETTINGS="$scratch/settings.json" CLAUDE_KILLSWITCH=off CLAUDE_PROXY_BANNER=0 \
        "$1" -c '. "$0" >/dev/null 2>&1; '"$2" "$src"
}
for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    printf 'CLAUDE_KILLSWITCH=off\nCLAUDE_PROXY_BANNER=0\n' > "$scratch/proxy.conf"

    # New spellings reach the merged implementations.
    out=$(run "$sh" '_proxy_doctor() { echo DOCTOR; }; _proxy_node_use() { echo "USE:$*"; }
        _chrome_profiles() { echo "LIST:$*"; }; _proxy_killswitch() { echo "KS:$*"; }
        proxy-status --fix; proxy-nodes use sg --force; chrome-proxy --list jp; proxy-config killswitch on' 2>&1)
    [ "$out" = "$(printf 'DOCTOR\nUSE:sg --force\nLIST:jp\nKS:on')" ] || fail "$sh new spellings: $out"

    # Old names delegate, with one rename line on stderr only.
    out=$(run "$sh" '_proxy_doctor() { echo DOCTOR; }; _proxy_node_use() { echo "USE:$*"; }
        _chrome_profiles() { echo LIST; }; _proxy_killswitch() { echo "KS:$*"; }
        cc() { echo "cc:$*"; }; cx() { echo "cx:$*"; }; cc-stop() { echo "stop:$*"; }
        proxy-doctor; proxy-node sg; chrome-profiles; proxy-killswitch off; cc-safe -c; cx-safe; cx-stop sg' 2>/dev/null)
    [ "$out" = "$(printf 'DOCTOR\nUSE:sg\nLIST\nKS:off\ncc:--safe -c\ncx:--safe\nstop:sg')" ] || fail "$sh old names: $out"
    err=$(run "$sh" '_proxy_doctor() { :; }; proxy-doctor' 2>&1 >/dev/null)
    case "$err" in *"[Renamed] 'proxy-doctor' is now 'proxy-status --fix'"*) ;; *) fail "$sh rename hint: $err";; esac
    run "$sh" 'type bridge-start >/dev/null 2>&1' && fail "$sh: bridge-start should be removed"

    # cc-help: status line, the core commands, and the rest only under 'all'.
    out=$(run "$sh" 'cc-help')
    for word in 'Mode: managed' 'tunnel: not running' cc-stop 'proxy-status --fix' proxy-restart \
                cc-manual 'proxy-nodes ' chrome-proxy proxy-config 'cc-help all'; do
        case "$out" in *"$word"*) ;; *) fail "$sh cc-help lacks '$word'";; esac
    done
    case "$out" in *tunnel-start*|*proxy-doctor*|*cc-safe*) fail "$sh cc-help shows non-core commands";; esac
    case "$(run "$sh" 'cc-help all')" in *'tunnel-start'*'RENAMED'*'proxy-doctor'*) ;; *) fail "$sh cc-help all";; esac

    # cc-manual: the node's own ports and alias, Claude's --settings override, no changes.
    before=$(cat "$scratch/settings.json")
    out=$(run "$sh" 'CLAUDE_KILLSWITCH=on; cc-manual sg')
    case "$out" in *'ssh -N -C -L 8181:127.0.0.1:8899 -D 1181'*'sgvpn'*) ;; *) fail "$sh manual ssh: $out";; esac
    case "$out" in *"-x http://127.0.0.1:8181 https://api.anthropic.com"*) ;; *) fail "$sh manual curl: $out";; esac
    case "$out" in *'--settings '\''{"env":{"HTTPS_PROXY":"http://127.0.0.1:8181"'*) ;; *) fail "$sh manual --settings: $out";; esac
    case "$out" in *'pinned to HTTP :8080'*) ;; *) fail "$sh manual pinned port: $out";; esac
    out=$(run "$sh" 'cc-manual')
    case "$out" in *'Kill switch is OFF'*) ;; *) fail "$sh manual kill switch off: $out";; esac
    case "$out" in *'pinned to HTTP'*) fail "$sh manual claims a pin with the kill switch off";; esac
    case "$out" in *'-L 8080:127.0.0.1:8888 -D 1080'*'jpvpn'*) ;; *) fail "$sh manual main: $out";; esac
    case "$out" in *'--settings'*) fail "$sh manual main must not need --settings";; esac
    [ "$(cat "$scratch/settings.json")" = "$before" ] || fail "$sh cc-manual changed Claude settings"
    echo "PASS: $sh - merged commands, renamed names, cc-help and cc-manual"
done

# Shared mode: status and --fix check the shared endpoint instead of telling
# this account to start a tunnel it can neither see nor manage.
for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    printf 'CLAUDE_KILLSWITCH=off\nCLAUDE_PROXY_BANNER=0\nCLAUDE_PROXY_MODE=shared\n' > "$scratch/proxy.conf"
    stub='_proxy_probe() { echo "ok 0 200 404"; }; _listeners() { :; }; _proxy_doctor_network() { :; }; '
    out=$(run "$sh" "$stub"'proxy-status' 2>&1)
    case "$out" in *'[SHARED] Tunnel'*':8080'*'Proxy answers : yes'*) ;; *) fail "$sh shared status: $out";; esac
    case "$out" in *'Run cc to start it'*|*'HTTP tunnel   : not running'*) fail "$sh shared status tells this account to start a tunnel";; esac
    out=$(run "$sh" "$stub"'proxy-status --fix' 2>&1 || :)
    case "$out" in *'Shared mode: another account serves'*) ;; *) fail "$sh shared doctor: $out";; esac
    case "$out" in *'NOT listening'*) fail "$sh shared doctor blames this account's tunnel";; esac
    echo "PASS: $sh - shared mode status and --fix check the shared endpoint"
done
