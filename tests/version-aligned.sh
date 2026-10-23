#!/usr/bin/env bash
set -eu
# Both profiles carry ONE shared version number (since 2.7.1): bump them together.
repo=$(cd "$(dirname "$0")/.." && pwd)
sh_ver=$(sed -n 's/^CLAUDE_PROXY_VERSION="\(.*\)"$/\1/p' "$repo/scripts/claude-proxy.sh")
ps_ver=$(sed -n "s/^\$script:PROFILE_VERSION = '\(.*\)'.*$/\1/p" "$repo/scripts/claude-proxy.ps1")
[ -n "$sh_ver" ] && [ -n "$ps_ver" ] || { echo "FAIL: version not found (bash '$sh_ver', powershell '$ps_ver')"; exit 1; }
[ "$sh_ver" = "$ps_ver" ] || { echo "FAIL: versions differ - bash $sh_ver, powershell $ps_ver. Bump both."; exit 1; }
echo "PASS: both profiles are v$sh_ver"
