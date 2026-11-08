#!/usr/bin/env bash
# Writing Claude's settings.json: paths with spaces, symlinked files, the first
# original copy, and no stray temp files. All paths are private scratch files.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/scripts/claude-proxy.sh"
command -v jq >/dev/null 2>&1 || { echo 'SKIP: jq unavailable'; exit 0; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
fn() { local f; for f in "$@"; do eval "$(sed -n '/^'"$f"'() [{(]/,/^[})]$/p' "$src")"; done; }
fn _settings_file_pinned _settings_file_replace _settings_file_proxy_on _settings_file_proxy_off \
   _claude_settings_proxy_on _claude_settings_proxy_off
CLAUDE_SYNC_SETTINGS=1 CLAUDE_HTTP_PORT=8080 CLAUDE_NO_PROXY='localhost,127.0.0.1'
one="$scratch/Users/John Doe/.claude/settings.json"
two="$scratch/home/.claude/settings.json"
mkdir -p "$(dirname "$one")" "$(dirname "$two")"
printf '{"theme":"dark"}\n' > "$one"
_settings_targets() { printf '%s\n%s\n' "$two" "$one"; }

_claude_settings_proxy_on >/dev/null
for f in "$one" "$two"; do
    [ "$(jq -r .env.HTTPS_PROXY "$f")" = http://127.0.0.1:8080 ] || fail "not pinned: $f"
done
[ "$(jq -r .theme "$one")" = dark ] || fail 'existing settings lost'
[ ! -e "$scratch/Users/John" ] || fail 'a path with a space was split'
echo 'PASS: settings targets with spaces are written as one path'

CLAUDE_HTTP_PORT=8090 _claude_settings_proxy_on >/dev/null
[ "$(jq -r .env.HTTPS_PROXY "$one")" = http://127.0.0.1:8090 ] || fail 'second write'
[ "$(jq -r '.env // "none"' "$one.claude-proxy.orig")" = none ] || fail 'the pre-proxy original was not kept'
[ "$(jq -r .env.HTTPS_PROXY "$one.bak")" = http://127.0.0.1:8080 ] || fail '.bak is not the previous version'
_claude_settings_proxy_off >/dev/null
[ "$(jq -r '.env.HTTPS_PROXY // "none"' "$one")" = none ] || fail 'proxy not removed'
[ "$(jq -r '.env // "none"' "$one.claude-proxy.orig")" = none ] || fail 'original overwritten by a later change'
echo 'PASS: the first original survives later changes; .bak is the previous version'

# A symlinked settings file (dotfile managers) keeps its link.
mkdir -p "$scratch/dotfiles"; printf '{"model":"x"}\n' > "$scratch/dotfiles/settings.json"
ln -s "$scratch/dotfiles/settings.json" "$scratch/linked.json"
_settings_targets() { echo "$scratch/linked.json"; }
_claude_settings_proxy_on >/dev/null
[ -L "$scratch/linked.json" ] || fail 'symlink replaced by a plain file'
[ "$(jq -r .env.HTTPS_PROXY "$scratch/dotfiles/settings.json")" = http://127.0.0.1:8080 ] || fail 'link target not updated'
[ "$(jq -r .model "$scratch/dotfiles/settings.json")" = x ] || fail 'link target lost settings'
echo 'PASS: a symlinked settings.json keeps its link'

# Invalid JSON is left untouched and no temp files remain anywhere.
printf '{broken\n' > "$two"; _settings_targets() { echo "$two"; }
_claude_settings_proxy_on >/dev/null 2>&1 || :
[ "$(cat "$two")" = '{broken' ] || fail 'invalid JSON was changed'
[ -z "$(find "$scratch" -name '*.tmp.*')" ] || fail "temp files left: $(find "$scratch" -name '*.tmp.*')"
echo 'PASS: invalid JSON is untouched and no temp files are left'
