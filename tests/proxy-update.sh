#!/usr/bin/env bash
# proxy-update (2.13.4): the latest release TAG is installed (a branch can be
# CDN-stale), --version picks one, a stale older copy never downgrades, and a
# failed API call falls back to the main branch.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in _update_repo _update_valid_tag _update_fetch _update_latest_tag _version_lt proxy-update; do
    eval "$(sed -n "/^$f() {/,/^}\$/p" "$src")"
done
grep -q '^_update_valid_tag() {.*}$' "$src" && eval "$(sed -n '/^_update_valid_tag() {/p' "$src")"
profile() { printf '#!/bin/sh\nCLAUDE_PROXY_VERSION="%s"\n' "$1"; }
mkdir -p "$scratch/gh/v2.13.2/scripts" "$scratch/gh/v2.13.4/scripts" "$scratch/gh/main/scripts"
profile 2.13.2 > "$scratch/gh/v2.13.2/scripts/claude-proxy.sh"
profile 2.13.4 > "$scratch/gh/v2.13.4/scripts/claude-proxy.sh"
profile 2.13.2 > "$scratch/gh/main/scripts/claude-proxy.sh"     # stale CDN copy of main
printf '{\n  "url": "x",\n  "tag_name": "v2.13.4",\n  "name": "y"\n}\n' > "$scratch/latest.json"
curl() {  # fake GitHub: raw files by ref, the releases API
    local url='' out='' a
    while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift;; http*) url=$1;; esac; shift; done
    echo "$url" >> "$scratch/urls"
    case "$url" in
        https://api.github.com/repos/o/r/releases/latest) [ -e "$scratch/api-down" ] && return 22; cp "$scratch/latest.json" "$out" ;;
        https://raw.githubusercontent.com/o/r/*) local p=${url#https://raw.githubusercontent.com/o/r/}; [ -f "$scratch/gh/$p" ] || return 22; cp "$scratch/gh/$p" "$out" ;;
        *) return 6 ;;
    esac
}
_profile_download_name() { echo claude-proxy.sh; }
_port_in_use() { return 1; }
_conf_reload() { CLAUDE_PROXY_VERSION=$(sed -n 's/^CLAUDE_PROXY_VERSION="\(.*\)"/\1/p' "$CLAUDE_PROXY_SELF"); }
_conf_write_all() { :; }
CLAUDE_PROXY_REPO_RAW=https://raw.githubusercontent.com/o/r/main/scripts
CLAUDE_HTTP_PORT=18080
# Run in this shell (not $(...)), so the reloaded version sticks like in a real shell.
upd() { local rc=0; proxy-update "$@" > "$scratch/out" 2>&1 || rc=$?; out=$(cat "$scratch/out"); return $rc; }
CLAUDE_PROXY_SELF="$scratch/installed.sh"; CLAUDE_PROXY_CONF="$scratch/conf"; : > "$CLAUDE_PROXY_CONF"
profile 2.13.3 > "$CLAUDE_PROXY_SELF"; CLAUDE_PROXY_VERSION=2.13.3

upd
grep -q 'CLAUDE_PROXY_VERSION="2.13.4"' "$CLAUDE_PROXY_SELF" || fail "latest tag not installed: $out"
grep -qx 'https://raw.githubusercontent.com/o/r/v2.13.4/scripts/claude-proxy.sh' "$scratch/urls" || fail 'not fetched by tag'
case "$out" in *'latest release (v2.13.4)'*) ;; *) fail "message: $out";; esac
echo 'PASS: proxy-update installs the latest release by its tag, not the cached branch'

# API down -> main branch; its stale older copy must not downgrade.
touch "$scratch/api-down"
upd
grep -q '"2.13.4"' "$CLAUDE_PROXY_SELF" || fail 'stale main downgraded the profile'
case "$out" in *'older than your v2.13.4'*'nothing changed'*) ;; *) fail "downgrade message: $out";; esac
echo 'PASS: a stale older copy never downgrades; the API failure falls back to main'

# --version installs exactly that release (also older, on purpose); unknown -> clear error.
upd --version 2.13.2
grep -q '"2.13.2"' "$CLAUDE_PROXY_SELF" || fail "--version not installed: $out"
upd --version v9.9.9 && fail 'unknown version accepted'
case "$out" in *'Could not download v9.9.9'*releases*) ;; *) fail "unknown version message: $out";; esac
upd --version 2.x && fail 'bad version accepted'
rm -f "$scratch/api-down"; upd --check
case "$out" in *'v2.13.2 -> v2.13.4'*) ;; *) fail "check: $out";; esac
grep -q '"2.13.2"' "$CLAUDE_PROXY_SELF" || fail '--check changed the profile'
echo 'PASS: --version picks a release (older on purpose too); bad or unknown versions are refused'

# A custom mirror is used as is, without tags.
: > "$scratch/urls"; CLAUDE_PROXY_REPO_RAW=https://mirror.example/scripts
proxy-update >/dev/null 2>&1 || :
[ "$(cat "$scratch/urls")" = 'https://mirror.example/scripts/claude-proxy.sh' ] || fail "mirror: $(cat "$scratch/urls")"
echo 'PASS: a custom CLAUDE_PROXY_REPO_RAW mirror is used as is'

# GitHub blocked directly: one more try through the tunnel's HTTP port.
CLAUDE_PROXY_REPO_RAW=https://raw.githubusercontent.com/o/r/main/scripts
eval "real_$(declare -f curl)"
curl() { case " $* " in *" -x http://127.0.0.1:18080 "*) real_curl "$@";; *) return 7;; esac; }
_port_in_use() { [ "$1" = 18080 ]; }
upd --version 2.13.4
grep -q '"2.13.4"' "$CLAUDE_PROXY_SELF" || fail "tunnel fallback: $out"
case "$out" in *'trying through the tunnel (HTTP :18080)'*) ;; *) fail "tunnel message: $out";; esac
echo 'PASS: a blocked direct download is retried through the tunnel'
