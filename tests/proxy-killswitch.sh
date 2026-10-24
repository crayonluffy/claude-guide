#!/usr/bin/env bash
# App-level kill switch: Claude/Codex must never be sent DIRECT. Covers the
# NO_PROXY exemption matcher, the settings.json pin, proxy-killswitch, and the
# pre-launch leak checks.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}"
fn() { local f; for f in "$@"; do eval "$(sed -n "/^$f() {/,/^}/p" "$src")"; done; }
eval "$(grep '^_CLAUDE_API_HOSTS=' "$src")"
fn _noproxy_exempts
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT

# 1) NO_PROXY exemption matcher.
exempt() {  # <NO_PROXY> <expected hosts, space separated, '' for none>
    local got
    got=$(_noproxy_exempts "$1" | tr '\n' ' ' | sed 's/ $//')
    [ "$got" = "$2" ] || { echo "FAIL: NO_PROXY '$1' -> '$got', expected '$2'" >&2; exit 1; }
}
all='api.anthropic.com claude.ai statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com'
exempt 'localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,*.local,*.internal,*.corp' ''
exempt '*' "$all"
exempt 'localhost, * ' "$all"
exempt '*.com' 'api.anthropic.com statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com'
exempt '.com' 'api.anthropic.com statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com'
exempt 'com' 'api.anthropic.com statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com'
exempt 'anthropic.com' 'api.anthropic.com statsig.anthropic.com'
exempt '.anthropic.com' 'api.anthropic.com statsig.anthropic.com'
exempt '*.anthropic.com' 'api.anthropic.com statsig.anthropic.com'
exempt 'api.openai.com:443' 'api.openai.com'
exempt ' API.OpenAI.com ' 'api.openai.com'
exempt 'claude.ai' 'claude.ai'
exempt 'notclaude.ai,10.0.0.0/8,openai.co,api.anthropic.com.evil' ''
exempt '' ''
echo 'PASS: NO_PROXY entries that would send API traffic direct are found'
