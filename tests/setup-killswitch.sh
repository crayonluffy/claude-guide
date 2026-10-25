#!/usr/bin/env bash
# The setup wizard's kill-switch step: KILLSWITCH stays on unless turned off,
# PLAIN_COMMANDS is asked on a full run (saved answer = default) and only
# mentioned on a quick update.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^conf_get() {/,/^}/p;/^conf_set() {/,/^}/p;/^killswitch_step() {/,/^}/p' "$repo/scripts/setup.sh")"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
CONF="$scratch/conf"
confirm() { echo "$2" >> "$scratch/defaults"; [ "$ANSWER" = y ]; }

ANSWER=y; killswitch_step 0 >/dev/null
assert test "$(conf_get CLAUDE_KILLSWITCH)" = on
assert test "$(conf_get CLAUDE_PLAIN_COMMANDS)" = auto
assert test "$(tail -1 "$scratch/defaults")" = Y
ANSWER=n; killswitch_step 0 >/dev/null
assert test "$(conf_get CLAUDE_PLAIN_COMMANDS)" = off
ANSWER=n; killswitch_step 0 >/dev/null
assert test "$(tail -1 "$scratch/defaults")" = N     # the saved 'off' is the new default
echo 'PASS: a full run asks about plain commands and saves the answer'

conf_set CLAUDE_KILLSWITCH off
killswitch_step 0 >/dev/null
assert test "$(conf_get CLAUDE_KILLSWITCH)" = off
echo 'PASS: a kill switch turned off stays off'

rm -f "$CONF" "$scratch/defaults"
out=$(killswitch_step 1)
assert test ! -e "$scratch/defaults"
assert test -z "$(conf_get CLAUDE_PLAIN_COMMANDS)"
case "$out" in *'PLAIN_COMMANDS auto'*) ;; *) echo "FAIL: quick update did not mention it: $out" >&2; exit 1;; esac
conf_set CLAUDE_PLAIN_COMMANDS off
assert test -z "$(killswitch_step 1)"
echo 'PASS: a quick update never asks, and mentions it only when never chosen'
