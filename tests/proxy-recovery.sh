#!/usr/bin/env bash
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^# BEGIN PROXY RECOVERY$/,/^# END PROXY RECOVERY$/p' "$repo/scripts/claude-proxy.sh")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
if ! declare -F _recovery_step >/dev/null; then echo 'FAIL: recovery state reducer is missing'; exit 1; fi
field() { printf '%s\n' "$1" | cut -d '|' -f "$2"; }
s=$(_recovery_step '' 'healthy|0|200|401|ok' 0 60)
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 5 60)
assert test "$(field "$s" 1)" = recovering
assert test "$(field "$s" 9)" = lost
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 64 60)
assert test "$(field "$s" 1)" = recovering
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 65 60)
assert test "$(field "$s" 9)" = prolonged
s=$(_recovery_step "$s" 'tunnel|7|000|000|dead' 70 60)
assert test "$(field "$s" 9)" = none
s=$(_recovery_step "$s" 'healthy|0|200|429|ok' 75 60)
assert test "$(field "$s" 9)" = restored
s=$(_recovery_step "$s" 'healthy|0|200|500|ok' 1 60)
assert test "$(field "$s" 3)" = 75
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
curl() {
 printf '%s\n' "$*" >> "$scratch/args"
 case "$*" in *--socks5-hostname*) printf '000 200'; return 0;; esac
 printf '%s' "$HTTP_RESULT"; return "$HTTP_RC"
}
HTTP_RESULT='200 403'; HTTP_RC=0
s=$(_recovery_probe claude 18080 11080)
assert test "$(field "$s" 1)" = healthy
assert grep -q -- '--noproxy' "$scratch/args"
assert grep -q -- '--proxy http://127.0.0.1:18080' "$scratch/args"
HTTP_RESULT='407 000'; HTTP_RC=56
s=$(_recovery_probe codex 18080 11080)
assert test "$(field "$s" 1)" = proxy
HTTP_RESULT='000 000'; HTTP_RC=52
s=$(_recovery_probe claude 18080 11080)
assert test "$(field "$s" 1)" = proxy
assert grep -q -- '--socks5-hostname 127.0.0.1:11080' "$scratch/args"
echo 'PASS: Bash recovery transitions, backwards time, and explicit proxy probes'
