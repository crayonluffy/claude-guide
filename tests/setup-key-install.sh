#!/usr/bin/env bash
# The installer never replaces a different private key that has the same name.
# Runs the installer's real key-install block (bash), and the PowerShell one
# when pwsh is available.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
block=$(sed -n '/# --- 4. Install + lock the key/,/chmod 600 "\$DEST"/p' "$repo/scripts/setup.sh")
[ -n "$block" ] || fail 'key-install block not found in setup.sh'
install_key() (  # <key path>; prints DEST
    HOME="$scratch/home"; KEY="$1"
    eval "$block" >/dev/null
    echo "$DEST"
)
mkdir -p "$scratch/home/.ssh" "$scratch/dl"
printf 'MINE\n' > "$scratch/home/.ssh/id_ed25519"
printf 'ADMIN\n' > "$scratch/dl/id_ed25519"
dest=$(install_key "$scratch/dl/id_ed25519")
[ "$(cat "$scratch/home/.ssh/id_ed25519")" = MINE ] || fail 'existing key was overwritten'
[ "$dest" = "$scratch/home/.ssh/id_ed25519-claude-proxy" ] || fail "unexpected destination: $dest"
[ "$(cat "$dest")" = ADMIN ] || fail 'new key not installed'
# Running the installer again reuses the identical copy instead of adding more.
dest=$(install_key "$scratch/dl/id_ed25519")
[ "$dest" = "$scratch/home/.ssh/id_ed25519-claude-proxy" ] || fail "re-run picked $dest"
[ ! -e "$scratch/home/.ssh/id_ed25519-claude-proxy2" ] || fail 're-run made another copy'
# A third, different key with the same name gets the next free name.
printf 'OTHER\n' > "$scratch/dl/id_ed25519"
dest=$(install_key "$scratch/dl/id_ed25519")
[ "$dest" = "$scratch/home/.ssh/id_ed25519-claude-proxy2" ] && [ "$(cat "$dest")" = OTHER ] || fail "third key: $dest"
# An identical key with the same name is reused in place.
printf 'MINE\n' > "$scratch/dl/id_ed25519"
dest=$(install_key "$scratch/dl/id_ed25519")
[ "$dest" = "$scratch/home/.ssh/id_ed25519" ] || fail "identical key not reused: $dest"
echo 'PASS: setup.sh never replaces a different private key of the same name'

pwsh=${PROXY_TEST_PWSH:-$(command -v pwsh || :)}
[ -n "$pwsh" ] || { echo 'SKIP: setup.ps1 key install (no pwsh)'; exit 0; }
rm -rf "$scratch/home/.ssh"; mkdir -p "$scratch/home/.ssh"
printf 'MINE\n' > "$scratch/home/.ssh/id_ed25519"; printf 'ADMIN\n' > "$scratch/dl/id_ed25519"
cat > "$scratch/run.ps1" <<'PS1'
param([string]$Setup, [string]$SshDir, [string]$KeyPath)
$ErrorActionPreference = "Stop"
$text = [IO.File]::ReadAllText($Setup)
$start = $text.IndexOf("# --- 3. Install + lock the key"); $end = $text.IndexOf("# OpenSSH refuses keys")
if ($start -lt 0 -or $end -lt $start) { throw "key-install block not found in setup.ps1" }
$sshDir = $SshDir; $keyPath = $KeyPath
Invoke-Expression $text.Substring($start, $end - $start) 6>$null
$dest
PS1
"$pwsh" -NoProfile -NonInteractive -File "$scratch/run.ps1" "$repo/scripts/setup.ps1" "$scratch/home/.ssh" "$scratch/dl/id_ed25519" > "$scratch/ps.out"
[ "$(cat "$scratch/home/.ssh/id_ed25519")" = MINE ] || fail 'setup.ps1 overwrote the existing key'
[ "$(tr -d '\r' < "$scratch/ps.out")" = "$scratch/home/.ssh/id_ed25519-claude-proxy" ] || fail "setup.ps1 destination: $(cat "$scratch/ps.out")"
[ "$(cat "$scratch/home/.ssh/id_ed25519-claude-proxy")" = ADMIN ] || fail 'setup.ps1 did not install the key'
echo 'PASS: setup.ps1 never replaces a different private key of the same name'
