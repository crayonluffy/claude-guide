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

# 3) proxy-killswitch status | on | off  (whole profile, isolated HOME/conf/settings)
ks() {  # <conf lines> <commands...>: run in a fresh isolated shell
    local conf="$1"; shift
    (
        export HOME="$scratch/ks-home" XDG_STATE_HOME="$scratch/ks-state" CLAUDE_PROXY_CONF="$scratch/ks.conf" CLAUDE_PROXY_BANNER=0
        export CLAUDE_SETTINGS="$scratch/ks-settings.json"
        mkdir -p "$HOME"; printf '%s\n' "$conf" > "$CLAUDE_PROXY_CONF"
        set +eu; . "$src" >/dev/null 2>&1
        _watchdog_pid() { [ -n "${KS_TUNNEL:-}" ] && echo 4242; }
        eval "$*"
    )
}
rm -f "$scratch/ks-settings.json"
out=$(ks '' 'proxy-killswitch status')
case "$out" in *'Kill switch: ON'*'pinned to 127.0.0.1:8080'*) ;; *) echo "FAIL: status on: $out" >&2; exit 1;; esac
case "$out" in *'NO_PROXY'*'no API host'*) ;; *) echo "FAIL: status lacks NO_PROXY check: $out" >&2; exit 1;; esac
case "$out" in *"plain 'codex'"*) ;; *) echo "FAIL: status lacks the codex limit: $out" >&2; exit 1;; esac
case "$out" in *'Claude Desktop'*) ;; *) echo "FAIL: status lacks the limits: $out" >&2; exit 1;; esac
out=$(ks 'CLAUDE_NO_PROXY="localhost,*.com"' 'proxy-killswitch status')
case "$out" in *'api.anthropic.com'*) ;; *) echo "FAIL: leaky NO_PROXY not shown: $out" >&2; exit 1;; esac
echo 'PASS: proxy-killswitch status shows the pin, NO_PROXY and the limits'

# off with no tunnel running: unpinned now. off while a tunnel runs: kept until proxy-off.
ks '' 'proxy-killswitch off' >/dev/null
assert grep -q '^CLAUDE_KILLSWITCH="off"' "$scratch/ks.conf"
assert test -z "$(jq -r '.env.HTTPS_PROXY // empty' "$scratch/ks-settings.json")"
ks '' 'proxy-killswitch on' >/dev/null
assert grep -q '^CLAUDE_KILLSWITCH="on"' "$scratch/ks.conf"
assert test "$(jq -r .env.HTTPS_PROXY "$scratch/ks-settings.json")" = http://127.0.0.1:8080
KS_TUNNEL=1 ks '' 'proxy-killswitch off' > "$scratch/ks-off.out"
assert test "$(jq -r .env.HTTPS_PROXY "$scratch/ks-settings.json")" = http://127.0.0.1:8080
assert grep -q 'proxy-off' "$scratch/ks-off.out"
out=$(ks 'CLAUDE_KILLSWITCH=off' 'proxy-killswitch status')
case "$out" in *'Kill switch: OFF'*) ;; *) echo "FAIL: status off: $out" >&2; exit 1;; esac
if ks '' 'proxy-killswitch sideways' >/dev/null 2>&1; then echo 'FAIL: bad argument accepted' >&2; exit 1; fi
echo 'PASS: proxy-killswitch on/off saves the setting and pins/unpins safely'

# 4) Pre-launch leak checks and no silent port fallback.
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$src")"
fn _killswitch_check _proxy_transport_wait proxy-up tunnel-start
export XDG_STATE_HOME="$scratch/state4"
dir=$(_recovery_identity)
CLAUDE_KILLSWITCH=on CLAUDE_HTTP_PORT=8080 CLAUDE_SOCKS_PORT=1080 CLAUDE_NO_PROXY='localhost,127.0.0.1'
printf '{}\n' > "$CLAUDE_SETTINGS"; _killswitch_ensure_pin >/dev/null
# "Our" ssh is this shell: the owner published its PID and start identity.
printf '%s|%s\n' "$$" "$(_recovery_process_identity $$)" > "$dir/ssh.pid"
_listeners() { case "$1" in 8080|1080) echo "$$";; esac; }
_proc_name() { case "$1" in 777) echo clash;; *) echo ssh;; esac; }
_port_bound() { [ -n "$(_listeners "$1")" ]; }
refuses() {  # <expected text> : _killswitch_check must refuse and say it
    local out
    if out=$(_killswitch_check 8080 1080 2>&1); then echo "FAIL: not refused (expected: $1)" >&2; exit 1; fi
    case "$out" in *"$1"*) ;; *) echo "FAIL: refusal lacks '$1': $out" >&2; exit 1;; esac
}
assert test -z "$(_killswitch_check 8080 1080)"
CLAUDE_NO_PROXY='localhost,.anthropic.com'; refuses 'api.anthropic.com'; CLAUDE_NO_PROXY='localhost,127.0.0.1'
_listeners() { case "$1" in 8080) echo 777;; 1080) echo "$$";; esac; }
refuses 'clash (PID 777) is on proxy port 8080'
refuses 'proxy-config set HTTP_PORT'
_listeners() { case "$1" in 8080) echo "$$";; esac; }
_port_bound() { [ "$1" = 1080 ] || [ -n "$(_listeners "$1")" ]; }
refuses "another user's program is on proxy port 1080"
_port_bound() { [ -n "$(_listeners "$1")" ]; }
_listeners() { case "$1" in 8080|1080) echo "$$";; esac; }
printf '%s|%s\n' "$$" 'stale-start' > "$dir/ssh.pid"     # a reused PID is not our ssh
refuses 'is on proxy port 8080'
printf '%s|%s\n' "$$" "$(_recovery_process_identity $$)" > "$dir/ssh.pid"
printf 'not json' > "$CLAUDE_SETTINGS"
refuses "Claude's settings"
printf '{}\n' > "$CLAUDE_SETTINGS"; _killswitch_ensure_pin >/dev/null
CLAUDE_KILLSWITCH=off; CLAUDE_NO_PROXY='*'
assert test -z "$(_killswitch_check 8080 1080)"
CLAUDE_KILLSWITCH=on; CLAUDE_NO_PROXY='localhost,127.0.0.1'
echo 'PASS: cc/cx refuse on a leaky NO_PROXY, a foreign port holder, or an unpinnable Claude'

# proxy-up refuses before setting anything; on success the pin follows the live port.
_recovery_adopt() { :; }; tunnel-start() { :; }; _tunnel_health() { echo "ok $$ ssh 8080"; }
_recovery_probe() { echo 'healthy|0|200|404|healthy'; }
proxy-on() { echo on >> "$scratch/proxy-on"; }
_listeners() { case "$1" in 8080) echo 777;; 1080) echo "$$";; esac; }
if proxy-up --no-verify > "$scratch/up.out" 2>&1; then echo 'FAIL: proxy-up launched with a foreign port holder' >&2; exit 1; fi
assert test ! -e "$scratch/proxy-on"
_listeners() { case "$1" in 8080|1080) echo "$$";; esac; }
proxy-up --no-verify > "$scratch/up.out" 2>&1
assert test -e "$scratch/proxy-on"
echo 'PASS: proxy-up refuses before setting anything, and launches when clean'

# tunnel-start: with the kill switch on, a foreign program is never "fallen back" around.
fn tunnel-start
_watchdog_pid() { return 1; }
_find_free_port() { echo "$1" >> "$scratch/fallback"; echo 8081; }
_tunnel_health() { echo 'foreign 99 nginx'; }
_listeners() { case "$1" in 8080) echo 99;; esac; }
if tunnel-start > "$scratch/ts.out" 2>&1; then echo 'FAIL: tunnel-start fell back' >&2; exit 1; fi
assert grep -q 'nginx (PID 99)' "$scratch/ts.out"
assert grep -q 'proxy-config set HTTP_PORT' "$scratch/ts.out"
assert test ! -e "$scratch/fallback"
_tunnel_health() { echo down; }
_listeners() { case "$1" in 1080) echo 99;; esac; }
_port_in_use() { [ "$1" = 1080 ]; }
if tunnel-start > "$scratch/ts2.out" 2>&1; then echo 'FAIL: tunnel-start fell back on SOCKS' >&2; exit 1; fi
assert grep -q 'proxy-config set SOCKS_PORT' "$scratch/ts2.out"
assert test ! -e "$scratch/fallback"
echo 'PASS: tunnel-start refuses a foreign port holder instead of moving the port'

# 6) proxy-doctor / proxy-status report the kill switch.
rm -f "$scratch/ks-settings.json"
out=$(ks '' '_killswitch_report OK WARN FAIL')
case "$out" in *'OK'*'Kill switch on'*'pinned'*) ;; *) echo "FAIL: doctor on: $out" >&2; exit 1;; esac
case "$out" in *"WARN"*"plain 'codex'"*'PLAIN_COMMANDS auto'*) ;; *) echo "FAIL: doctor codex warning: $out" >&2; exit 1;; esac
out=$(ks 'CLAUDE_PLAIN_COMMANDS=auto' '_killswitch_report OK WARN FAIL')
case "$out" in *"plain 'codex'"*'PLAIN_COMMANDS auto'*) echo "FAIL: codex warning with auto: $out" >&2; exit 1;; esac
out=$(ks 'CLAUDE_NO_PROXY="localhost,*.openai.com"' '_killswitch_report OK WARN FAIL')
case "$out" in *'FAIL'*'api.openai.com'*) ;; *) echo "FAIL: doctor NO_PROXY: $out" >&2; exit 1;; esac
out=$(ks 'CLAUDE_KILLSWITCH=off' '_killswitch_report OK WARN FAIL')
case "$out" in *'WARN'*'Kill switch OFF'*) ;; *) echo "FAIL: doctor off: $out" >&2; exit 1;; esac
out=$(ks '' '_tunnel_health() { echo down; }; proxy-notify() { :; }; curl() { :; }; proxy-status')
case "$out" in *'Kill switch'*'127.0.0.1:8080'*) ;; *) echo "FAIL: status line: $out" >&2; exit 1;; esac
echo 'PASS: proxy-doctor and proxy-status report the kill switch'
