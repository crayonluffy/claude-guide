#!/usr/bin/env bash
# Settings files are sourced as shell code: any saved value must come back
# exactly as typed and never run. Covers the profile and the installer.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
fn() { local f; for f in "${@:2}"; do eval "$(sed -n '/^'"$f"'() [{(]/,/^[})]$/p' "$1")"; done; }
fn "$repo/scripts/claude-proxy.sh" _conf_write_line
fn "$repo/scripts/setup.sh" conf_set
values=('plain' 'with space' 'quote"inside' 'dollar $HOME and $(touch '"$scratch"'/pwned)' \
        'back`touch '"$scratch"'/pwned2`tick' 'back\slash\' 'amp & pipe | slash /' "single'quote" '')
check() {  # <file> <label>
    local i=0 v got
    for v in "${values[@]}"; do
        got=$(bash -c '. "$1"; eval "printf %s \"\${$2}\""' _ "$1" "CLAUDE_V$i")
        [ "$got" = "$v" ] || fail "$2: value $i came back as [$got], expected [$v]"
        i=$((i+1))
    done
    [ ! -e "$scratch/pwned" ] && [ ! -e "$scratch/pwned2" ] || fail "$2: a saved value ran as code"
    [ "$(grep -c '^CLAUDE_V0=' "$1")" = 1 ] || fail "$2: duplicate lines"
    [ -z "$(find "$scratch" -name "$(basename "$1").??????")" ] || fail "$2: temp file left"
}
conf="$scratch/profile.conf"; printf '# mine\nCLAUDE_V0="old"\n' > "$conf"
i=0; for v in "${values[@]}"; do _conf_write_line "$conf" "CLAUDE_V$i" "$v"; i=$((i+1)); done
check "$conf" profile
grep -qx '# mine' "$conf" || fail 'profile: comment lost'
if _conf_write_line "$conf" CLAUDE_V0 "two
lines" 2>/dev/null; then fail 'profile: a line break was accepted'; fi
check "$conf" 'profile after refused line break'
echo 'PASS: proxy-config set saves any value literally and never runs it'

CONF="$scratch/setup.conf"
i=0; for v in "${values[@]}"; do conf_set "CLAUDE_V$i" "$v"; i=$((i+1)); done
conf_set CLAUDE_V0 plain   # replace an existing line
check "$CONF" installer
echo 'PASS: the installer saves any value literally and never runs it'
