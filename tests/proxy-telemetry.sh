#!/usr/bin/env bash
# TELEMETRY=off (2.13.2): cc runs Claude with CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1,
# for that process only; codex and the default (on) are left alone.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$scratch/bin"
for app in claude codex; do
    printf '#!/bin/sh\necho "%s:${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-unset}"\n' "$app" > "$scratch/bin/$app"
    chmod +x "$scratch/bin/$app"
done
printf '{}\n' > "$scratch/settings.json"
run() {  # <shell> <TELEMETRY> <code>   (settings come from the conf file, as for users)
    printf 'CLAUDE_KILLSWITCH=off\nCLAUDE_PROXY_BANNER=0\nCLAUDE_TUNNEL_WATCHDOG=0\nCLAUDE_TELEMETRY=%s\n' "$2" > "$scratch/proxy.conf"
    env -i PATH="$scratch/bin:$PATH" HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" \
        CLAUDE_PROXY_CONF="$scratch/proxy.conf" CLAUDE_SETTINGS="$scratch/settings.json" \
        CLAUDE_KILLSWITCH=off CLAUDE_PROXY_BANNER=0 \
        "$1" -c '. "$0" >/dev/null 2>&1; proxy-up() { return 0; }; _recovery_adopt() { :; }; '"$3" "$src" 2>/dev/null
}
for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out=$(run "$sh" off 'cc | tail -1; cx | tail -1; echo "shell:${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-unset}"')
    [ "$out" = "$(printf 'claude:1\ncodex:unset\nshell:unset')" ] || fail "$sh off: $out"
    out=$(run "$sh" on 'cc | tail -1')
    [ "$out" = 'claude:unset' ] || fail "$sh on: $out"
    echo "PASS: $sh TELEMETRY=off is scoped to Claude runs"
done
