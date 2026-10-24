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

# 2) The pin: settings.json keeps the proxy while the kill switch is on.
fn _settings_targets _settings_file_pinned _settings_file_proxy_on _settings_file_proxy_off _claude_settings_proxy_on \
   _claude_settings_proxy_off _killswitch_on _killswitch_pin_state _killswitch_ensure_pin proxy-on proxy-off _count cc-stop
_is_wsl() { return 1; }
export CLAUDE_SETTINGS="$scratch/settings.json" CLAUDE_SYNC_SETTINGS=1 CLAUDE_SYNC_WINDOWS_SETTINGS=0
CLAUDE_HTTP_PORT=8080 CLAUDE_NO_PROXY='localhost,127.0.0.1' CLAUDE_KILLSWITCH=on
printf '{"model":"opus","env":{"FOO":"bar"}}\n' > "$CLAUDE_SETTINGS"
pin() { jq -r ".env.$1 // empty" "$CLAUDE_SETTINGS"; }
proxy-on >/dev/null
proxy-off > "$scratch/off.out"
assert test -z "${HTTPS_PROXY:-}"
assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8080
assert test "$(pin HTTP_PROXY)" = http://127.0.0.1:8080
assert test "$(pin NO_PROXY)" = 'localhost,127.0.0.1'
assert test "$(pin FOO)" = bar
assert test "$(jq -r .model "$CLAUDE_SETTINGS")" = opus
assert grep -q 'Kill switch' "$scratch/off.out"
echo 'PASS: proxy-off clears the shell but keeps Claude pinned to the tunnel'

tunnel-stop() { :; }; _node_tunnels_stop() { :; }; _other_agents() { :; }
_recovery_identity() { echo "$scratch/none"; }; _recovery_sessions() { echo 0; }
cc-stop >/dev/null
assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8080
echo 'PASS: cc-stop keeps the pin'

CLAUDE_KILLSWITCH=off
proxy-off >/dev/null
assert test -z "$(pin HTTPS_PROXY)"
assert test "$(pin FOO)" = bar
echo 'PASS: with the kill switch off, proxy-off unpins as before'

# Ensure: writes only what is missing or wrong, silently when nothing changes.
CLAUDE_KILLSWITCH=on
out=$(_killswitch_ensure_pin)
assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8080
case "$out" in *'[Kill switch]'*) ;; *) echo "FAIL: no notice when pinning: $out" >&2; exit 1;; esac
rm -f "$CLAUDE_SETTINGS.bak"; before=$(stat -c %Y.%s "$CLAUDE_SETTINGS"); sleep 1
out=$(_killswitch_ensure_pin)
assert test -z "$out"
assert test "$(stat -c %Y.%s "$CLAUDE_SETTINGS")" = "$before"
assert test ! -e "$CLAUDE_SETTINGS.bak"
CLAUDE_HTTP_PORT=8081
_killswitch_ensure_pin >/dev/null
assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8081
assert test "$(_killswitch_pin_state)" = 'pinned 8081'
CLAUDE_HTTP_PORT=8080
assert test "$(_killswitch_pin_state)" = 'mismatch 8081'
_killswitch_ensure_pin >/dev/null
echo 'PASS: the pin is written when missing or wrong, and left alone when right'

# Not pinnable: sync off, or no jq.
CLAUDE_SYNC_SETTINGS=0
assert test "$(_killswitch_pin_state)" = 'unpinned sync-off'
CLAUDE_SYNC_SETTINGS=1
mkdir -p "$scratch/nojq"; for t in sed grep cat tr mkdir cp mv mktemp rm dirname; do ln -sf "$(command -v $t)" "$scratch/nojq/$t"; done
(PATH="$scratch/nojq"; assert test "$(_killswitch_pin_state)" = 'unpinned no-jq')
rm -f "$CLAUDE_SETTINGS"
assert test "$(_killswitch_pin_state)" = 'unpinned missing'
echo 'PASS: an unpinnable setup is reported as such'

# WSL: the Windows-side settings are pinned too.
_is_wsl() { return 0; }
_win_claude_settings() { echo "$scratch/win/settings.json"; }
CLAUDE_SYNC_WINDOWS_SETTINGS=1
_killswitch_ensure_pin >/dev/null
assert test "$(jq -r .env.HTTPS_PROXY "$scratch/win/settings.json")" = http://127.0.0.1:8080
assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8080
_is_wsl() { return 1; }; CLAUDE_SYNC_WINDOWS_SETTINGS=0
echo 'PASS: WSL pins the Windows-side Claude settings too'

# Loading the profile pins; proxy-config set HTTP_PORT re-pins.
(
    export HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" CLAUDE_PROXY_CONF="$scratch/conf" CLAUDE_PROXY_BANNER=0
    mkdir -p "$HOME"; rm -f "$CLAUDE_SETTINGS"
    set +eu; . "$src" > "$scratch/load.out" 2>&1; set -eu   # sourced like a login shell does
    assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8080
    proxy-config set HTTP_PORT 8090 > /dev/null 2>&1
    assert test "$(pin HTTPS_PROXY)" = http://127.0.0.1:8090
)
echo 'PASS: loading the profile pins Claude; changing HTTP_PORT re-pins'
