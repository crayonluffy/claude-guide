#!/usr/bin/env bash
# Run with: bash tests/chrome-proxy.sh (Linux/WSL; no Chrome or SSH required).
set -eu
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# Load only the real launcher, avoiding profile startup/configuration side effects.
eval "$(sed -n '/^chrome-proxy() {$/,/^}$/p' "$repo_dir/scripts/claude-proxy.sh")"
_node_lookup() { [ "$1" = sg ] && printf '1|sg|sgvpn|192.0.2.1\n'; }
_node_ensure_alias() { return 0; }
_node_socks_port() { echo "$((1180 + $1))"; }
_node_tunnel_start() { echo "$3" > "$test_dir/tunnel-port"; }
_node_active_name() { echo jp; }
_port_in_use() { return 0; }
_is_wsl() { return 1; }
_chrome_base_dir() { echo "$test_dir/profile"; }
_chrome_profile_dir() { echo "$1-$2"; }
CLAUDE_SSH_HOST=jpvpn
CLAUDE_SOCKS_PORT=1080
CLAUDE_CHROME_BIN="$test_dir/chrome"
export CHROME_TEST_ARGS="$test_dir/args"
cat > "$CLAUDE_CHROME_BIN" <<'BROWSER'
#!/bin/sh
printf '%s\n' "$@" > "$CHROME_TEST_ARGS"
BROWSER
chmod +x "$CLAUDE_CHROME_BIN"
if output=$(chrome-proxy sgg --profile sg); then
    echo 'FAIL: unknown node unexpectedly succeeded'; exit 1
fi
case "$output" in *"Unknown proxy node 'sgg'"*) ;; *) echo 'FAIL: missing diagnostic'; exit 1 ;; esac
[ ! -e "$CHROME_TEST_ARGS" ] && [ ! -e "$test_dir/tunnel-port" ]
chrome-proxy sg --profile sg https://example.com/
wait
[ "$(cat "$test_dir/tunnel-port")" = 1181 ]
grep -Fxq -- '--proxy-server=socks5://127.0.0.1:1181' "$CHROME_TEST_ARGS"
grep -Fxq -- '--profile-directory=sg' "$CHROME_TEST_ARGS"
grep -Fxq -- 'https://example.com/' "$CHROME_TEST_ARGS"
if grep -Fxq -- sg "$CHROME_TEST_ARGS"; then echo 'FAIL: sg became a URL'; exit 1; fi
echo 'PASS: Bash unknown-node rejection and SG/profile/URL launch'
