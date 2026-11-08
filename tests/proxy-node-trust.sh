#!/usr/bin/env bash
# Node-list data is untrusted: invalid fields never reach ~/.ssh/config, and a
# catalogue host key is pinned only for a host that has no key yet.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
command -v ssh-keygen >/dev/null 2>&1 || { echo 'SKIP: ssh-keygen unavailable'; exit 0; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
fn() { local f; for f in "$@"; do eval "$(sed -n '/^'"$f"'() [{(]/,/^[})]$/p' "$src")"; done; }
fn _node_field_ok _known_hosts_add _node_ensure_alias _ssh_config_has_alias _ssh_config_field \
   _ssh_config_identity _ssh_config_add_alias _node_provisioned
_platform_ssh_options() { :; }
export HOME="$scratch/home"; mkdir -p "$HOME/.ssh"
CLAUDE_SSH_HOST=jpvpn CLAUDE_SSH_KEY='' CLAUDE_SSH_USER=alice
kh="$HOME/.ssh/known_hosts"
k1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
k2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA0FvJaPQwz2kqBqvhAr6kqJu6ce26qmHlYxGjVN0uE7'

# Field validation.
for ok in 'alias jpvpn2' 'host jp.example.com' 'host 2001:db8::1' 'user ' 'user bob.k' 'port 2222' "hostkey $k1"; do
    _node_field_ok ${ok%% *} "${ok#* }" || fail "rejected valid: $ok"
done
for bad in 'alias -oProxyCommand=x' 'alias a b' 'host evil.com ProxyCommand=sh' 'host a|b' "host a
b" 'user -l' 'user a b' 'port 0' 'port 70000' 'port 22x' 'hostkey ssh-ed25519 AAAA BBBB' 'hostkey garbage'; do
    if _node_field_ok ${bad%% *} "${bad#* }"; then fail "accepted invalid: $bad"; fi
done
echo 'PASS: node-list fields are validated before they reach ssh files'

# known_hosts: pin when absent; skip when identical; never add a second key.
_known_hosts_add sg.example.com 22 "$k1" >/dev/null
[ "$(grep -c "^sg.example.com $k1\$" "$kh")" = 1 ] || fail 'key not pinned'
_known_hosts_add sg.example.com 22 "$k1" >/dev/null
[ "$(wc -l < "$kh" | tr -d ' ')" = 1 ] || fail 'identical key added twice'
out=$(_known_hosts_add sg.example.com 22 "$k2" 2>&1)
case "$out" in *'different host key'*'kept yours'*) ;; *) fail "mismatch not reported: $out";; esac
grep -qF "$k2" "$kh" && fail 'a second key was added for a pinned host'
_known_hosts_add us.example.com 2222 "$k1" >/dev/null   # same key on another VM is fine
grep -qxF "[us.example.com]:2222 $k1" "$kh" || fail 'shared key not pinned for a second host'
out=$(_known_hosts_add jp.example.com 22 'ssh-ed25519 not-base64!' 2>&1)
case "$out" in *'invalid host key'*) ;; *) fail "invalid key not refused: $out";; esac
grep -q '^jp.example.com' "$kh" && fail 'invalid key written'
echo 'PASS: catalogue host keys are pinned only for hosts with no key yet'

# Alias creation refuses injected fields and writes nothing.
: > "$HOME/.ssh/config"
if _node_ensure_alias '1|sg|sgvpn|evil.com ProxyCommand=touch /tmp/x|alice|22|8888|SG|||' >/dev/null 2>&1; then
    fail 'injected host accepted'
fi
if _node_ensure_alias '1|sg|-oProxyCommand=x|sg.example.com|alice|22|8888|SG|||' >/dev/null 2>&1; then
    fail 'injected alias accepted'
fi
[ ! -s "$HOME/.ssh/config" ] || fail 'ssh config written for an invalid node'
_node_ensure_alias '1|sg|sgvpn|sg.example.com||2222|8888|SG|||' >/dev/null
grep -q '^Host sgvpn$' "$HOME/.ssh/config" && grep -q 'HostName sg.example.com' "$HOME/.ssh/config" \
    && grep -q 'Port 2222' "$HOME/.ssh/config" || fail "valid alias not written: $(cat "$HOME/.ssh/config")"
echo 'PASS: invalid node-list fields never reach ~/.ssh/config'
