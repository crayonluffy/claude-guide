#!/usr/bin/env bash
# PLAIN_COMMANDS=auto: plain 'claude' / 'codex' start through the tunnel like
# cc-safe / cx-safe, but quietly - only the app writes to stdout, so
# 'claude -p ... | jq' keeps working - and never call themselves.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
src="${PROXY_RECOVERY_SOURCE:-$repo/scripts/claude-proxy.sh}"
assert() { if ! "$@"; then echo "FAIL: $*" >&2; exit 1; fi; }
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
for b in claude codex; do
    printf '#!/bin/sh\necho "%s ARGS:$*"\necho call >> "%s/%s.calls"\nexit 3\n' "$b" "$scratch" "$b" > "$scratch/bin/$b"
    chmod +x "$scratch/bin/$b"
done
run() {  # <PLAIN_COMMANDS value> <commands...>: fresh isolated shell with the profile loaded
    local plain="$1"; shift
    (
        export HOME="$scratch/home" XDG_STATE_HOME="$scratch/state" CLAUDE_PROXY_CONF="$scratch/conf"
        export CLAUDE_SETTINGS="$scratch/settings.json" CLAUDE_PROXY_BANNER=0 PATH="$scratch/bin:$PATH"
        mkdir -p "$HOME"
        printf 'CLAUDE_PLAIN_COMMANDS="%s"\nCLAUDE_TUNNEL_WATCHDOG=0\n' "$plain" > "$CLAUDE_PROXY_CONF"
        set +eu; . "$src" >/dev/null 2>&1
        proxy-up() { echo "[OK] proxy up $*"; echo "$*" >> "$scratch/up.calls"; [ ! -e "$scratch/up.fail" ]; }
        eval "$*"
    )
}

# 1) off (the default for existing users): no wrapper, the binary runs as-is.
assert test "$(run off 'type -t claude')" = file
assert test "$(run off 'type -t codex')" = file
echo 'PASS: PLAIN_COMMANDS=off leaves claude and codex alone'

# 2) auto: through the tunnel, safe mode, stdout is only the app's, exit code kept.
rm -f "$scratch"/*.calls
set +e; out=$(run auto 'claude -p hi' 2>"$scratch/err"); rc=$?; set -e
assert test "$rc" = 3
assert test "$out" = 'claude ARGS:-p hi'
assert grep -q -- '--no-verify' "$scratch/up.calls"
assert grep -q 'proxy up' "$scratch/err"
assert test "$(run auto 'type -t claude')" = function
set +e; out=$(run auto 'codex exec ls' 2>/dev/null); set -e
assert test "$out" = 'codex ARGS:exec ls'
echo 'PASS: plain claude/codex go through the tunnel in safe mode, quietly, exit code kept'

# 3) A failed proxy-up means the app never runs.
rm -f "$scratch"/*.calls; touch "$scratch/up.fail"
if run auto 'claude -p hi' >/dev/null 2>&1; then echo 'FAIL: launched without a tunnel' >&2; exit 1; fi
assert test ! -e "$scratch/claude.calls"
rm -f "$scratch/up.fail"
echo 'PASS: no tunnel, no launch'

# 4) Version/help need no tunnel.
rm -f "$scratch"/*.calls
for a in --version -v --help -h; do
    set +e; out=$(run auto "claude $a" 2>/dev/null); set -e
    assert test "$out" = "claude ARGS:$a"
done
assert test ! -e "$scratch/up.calls"
echo 'PASS: --version / --help pass straight through'

# 5) No recursion: cc with the wrapper defined runs the binary exactly once.
rm -f "$scratch"/*.calls
set +e; run auto 'cc -p hi' >/dev/null 2>&1; set -e
assert test "$(wc -l < "$scratch/claude.calls" | tr -d ' ')" = 1
echo 'PASS: cc runs the real binary once with the wrapper defined'

# 6) Switching back to off removes the wrappers in the same shell.
assert test "$(run auto 'proxy-config set PLAIN_COMMANDS off >/dev/null 2>&1; type -t claude')" = file
echo 'PASS: proxy-config set PLAIN_COMMANDS off removes the wrappers'

# 7) Not installed: a clear error, not a function calling itself.
set +e; out=$(run auto 'PATH=/usr/bin:/bin; claude -p hi' 2>&1); rc=$?; set -e
assert test "$rc" != 0
case "$out" in *"'claude' not found"*) ;; *) echo "FAIL: missing binary: $out" >&2; exit 1;; esac
echo 'PASS: a missing binary is reported, not recursed into'
