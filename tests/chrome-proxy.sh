#!/usr/bin/env bash
# Run with: bash tests/chrome-proxy.sh (Linux/WSL; no Chrome or SSH required).
set -eu
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# Load only the real launcher, avoiding profile startup/configuration side effects.
eval "$(sed -n '/^# BEGIN PLATFORM ADAPTERS$/,/^# END PLATFORM ADAPTERS$/p' "$repo_dir/scripts/claude-proxy.sh")"
# This test exercises the Linux launcher; macOS launching is covered separately.
uname() { echo Linux; }
# Keep the real launcher arguments without macOS nohup's console requirement.
nohup() { "$@"; }
for f in chrome-proxy _chrome_leak_flags _chrome_direct_rules _chrome_tz _chrome_running_note; do
    eval "$(sed -n "/^$f() {/,/^}\$/p" "$repo_dir/scripts/claude-proxy.sh")"
done
eval "$(sed -n '/^_chrome_leak_flags() {/p' "$repo_dir/scripts/claude-proxy.sh")"
CLAUDE_NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,*.local,.mycorp.example,*"
CLAUDE_CHROME_TZ=Asia/Tokyo
_node_lookup() { case "$1" in sg) printf '1|sg|sgvpn|192.0.2.1\n';; jp) printf '0|jp|jpvpn|192.0.2.0\n';; *) return 1;; esac; }
_node_slot() { case "$1" in sg) echo node-sg;; *) echo main;; esac; }
_ssh_config_has_alias() { return 1; }
_node_ctx() { case "$1" in sg) CLAUDE_SOCKS_PORT=1181;; esac; }
_node_ensure_alias() { return 0; }
_node_socks_port() { echo "$((1180 + $1))"; }
# A node's Chrome uses that node's self-healing tunnel (2.10), not a bare ssh -f.
tunnel-start() { echo "${1:-main}" >> "$test_dir/tunnel-start"; }
_node_active_name() { echo jp; }
_port_in_use() { return 0; }
_is_wsl() { return 1; }
_proxy_shared() { return 1; }
_chrome_base_dir() { echo "$test_dir/profile"; }
_chrome_profile_dir() { echo "$1-$2"; }
CLAUDE_SSH_HOST=jpvpn
CLAUDE_SOCKS_PORT=1080
CLAUDE_CHROME_BIN="$test_dir/chrome"
export CHROME_TEST_ARGS="$test_dir/args"
cat > "$CLAUDE_CHROME_BIN" <<'BROWSER'
#!/bin/sh
printf '%s\n' "$@" "TZ=${TZ:-}" > "$CHROME_TEST_ARGS"
BROWSER
chmod +x "$CLAUDE_CHROME_BIN"
if output=$(chrome-proxy sgg --profile sg); then
    echo 'FAIL: unknown node unexpectedly succeeded'; exit 1
fi
case "$output" in *"Unknown proxy node 'sgg'"*) ;; *) echo 'FAIL: missing diagnostic'; exit 1 ;; esac
[ ! -e "$CHROME_TEST_ARGS" ] && [ ! -e "$test_dir/tunnel-start" ]
chrome-proxy sg --profile sg https://example.com/
wait
[ "$(cat "$test_dir/tunnel-start")" = sg ]
grep -Fxq -- '--proxy-server=socks5://127.0.0.1:1181' "$CHROME_TEST_ARGS"
grep -Fxq -- '--profile-directory=sg' "$CHROME_TEST_ARGS"
grep -Fxq -- 'https://example.com/' "$CHROME_TEST_ARGS"
if grep -Fxq -- sg "$CHROME_TEST_ARGS"; then echo 'FAIL: sg became a URL'; exit 1; fi
echo 'PASS: Bash unknown-node rejection and SG/profile/URL launch'

# The default node uses the main tunnel (started if it is down), never a second tunnel.
rm -f "$test_dir/tunnel-start" "$CHROME_TEST_ARGS"
_port_in_use() { [ -e "$test_dir/main-up" ]; }
tunnel-start() { echo "${1:-main}" >> "$test_dir/tunnel-start"; touch "$test_dir/main-up"; }
chrome-proxy jp
wait
[ "$(cat "$test_dir/tunnel-start")" = main ]
grep -Fxq -- '--proxy-server=socks5://127.0.0.1:1080' "$CHROME_TEST_ARGS"
echo 'PASS: Bash default node uses the main tunnel; other nodes their own self-healing tunnel'

# Leak guards: WebRTC never uses direct UDP, no QUIC, DNS only through the proxy.
grep -Fxq -- '--force-webrtc-ip-handling-policy=disable_non_proxied_udp' "$CHROME_TEST_ARGS"
grep -Fxq -- '--disable-quic' "$CHROME_TEST_ARGS"
# The LAN (NO_PROXY) stays direct, and its names still resolve locally; '*' is never a bypass.
grep -Fxq -- '--proxy-bypass-list=localhost;*.localhost;127.0.0.1;[::1];10.0.0.0/8;192.168.0.0/16;*.local;mycorp.example;*.mycorp.example' "$CHROME_TEST_ARGS"
grep -Fxq -- '--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost , EXCLUDE *.localhost , EXCLUDE 127.0.0.1 , EXCLUDE *.local , EXCLUDE mycorp.example , EXCLUDE *.mycorp.example' "$CHROME_TEST_ARGS"
grep -Fxq -- 'TZ=Asia/Tokyo' "$CHROME_TEST_ARGS"
echo 'PASS: Bash Chrome WebRTC/QUIC guards, LAN bypass with local DNS, fixed time zone'

# CHROME_BYPASS=off sends the LAN through the proxy too; CHROME_TZ=off leaves TZ alone.
rm -f "$CHROME_TEST_ARGS"
CLAUDE_CHROME_BYPASS=off CLAUDE_CHROME_TZ=off chrome-proxy jp
wait
grep -Fxq -- '--proxy-bypass-list=localhost;*.localhost;127.0.0.1' "$CHROME_TEST_ARGS"
grep -Fxq -- 'TZ=' "$CHROME_TEST_ARGS"
echo 'PASS: Bash CHROME_BYPASS=off and CHROME_TZ=off'

# auto: the exit IP's zone through the tunnel; --check opens the leak tests.
rm -f "$CHROME_TEST_ARGS"
curl() {
    case "$*" in *--socks5-hostname\ 127.0.0.1:1080*) ;; *) return 7 ;; esac
    case "$*" in *ipinfo.io/timezone*) printf 'Asia/Singapore';; *ipinfo.io/ip*) printf '203.0.113.9';; esac
}
CLAUDE_CHROME_TZ=auto chrome-proxy jp --check > "$test_dir/out"
wait
out=$(cat "$test_dir/out")
grep -Fxq -- 'TZ=Asia/Singapore' "$CHROME_TEST_ARGS"
grep -Fxq -- 'https://browserleaks.com/webrtc' "$CHROME_TEST_ARGS"
case "$out" in *"203.0.113.9 - not your own"*) ;; *) echo "FAIL: check output: $out"; exit 1 ;; esac
# A bad lookup answer is never passed on as TZ.
curl() { printf 'x;rm -rf /'; }
rm -f "$CHROME_TEST_ARGS"
CLAUDE_CHROME_TZ=auto chrome-proxy jp 2>/dev/null
wait
grep -Fxq -- 'TZ=' "$CHROME_TEST_ARGS"
echo 'PASS: Bash auto time zone through the tunnel, rejected bad answers, --check'

# macOS: 'open --env' passes the time zone where supported; flags reach Chrome.
open() {
    case "$1" in --help) echo 'Usage: open [-e] [--env VAR] [-a <application>]'; return 1 ;; esac
    printf '%s\n' "$@" > "$CHROME_TEST_ARGS"
}
ps() { :; }
rm -f "$CHROME_TEST_ARGS"
CLAUDE_CHROME_BIN='Google Chrome' _CLAUDE_CHROME_LAUNCH_TZ=Asia/Tokyo \
    _macos_chrome_launch jp socks5://127.0.0.1:1080 '' 'jp (main tunnel)' --disable-quic >/dev/null
[ "$(sed -n '1,3p' "$CHROME_TEST_ARGS" | tr '\n' ' ')" = '-n --env TZ=Asia/Tokyo ' ]
grep -Fxq -- '--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost , EXCLUDE *.localhost , EXCLUDE 127.0.0.1 , EXCLUDE *.local , EXCLUDE mycorp.example , EXCLUDE *.mycorp.example' "$CHROME_TEST_ARGS"
grep -Fxq -- '--disable-quic' "$CHROME_TEST_ARGS"
open() { case "$1" in --help) echo 'Usage: open [-a <application>]'; return 1 ;; esac; printf '%s\n' "$@" > "$CHROME_TEST_ARGS"; }
out=$(CLAUDE_CHROME_BIN='Google Chrome' _CLAUDE_CHROME_LAUNCH_TZ=Asia/Tokyo _macos_chrome_launch jp socks5://127.0.0.1:1080 '' jp)
case "$out" in *"can't pass a time zone"*) ;; *) echo 'FAIL: old macOS note'; exit 1 ;; esac
! grep -Fxq -- '--env' "$CHROME_TEST_ARGS"
echo 'PASS: macOS Chrome gets the time zone via open --env, or says it cannot'
