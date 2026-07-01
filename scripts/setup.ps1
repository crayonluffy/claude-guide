# ============================================================
# Interactive setup wizard - Claude SSH tunnel proxy (Windows)
# ============================================================
# Run with:
#   irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
#
# Does the whole one-time setup: prompts for your VM details, installs and
# locks your SSH key, writes an ~/.ssh/config alias, installs the cc profile,
# and tests the connection. Prefer the paste-blocks in the README if you'd
# rather not run a downloaded script.
# ============================================================

$ErrorActionPreference = 'Stop'
$repoRaw = 'https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts'

function Read-Required($prompt) {
    do { $v = (Read-Host $prompt).Trim() } while (-not $v)
    return $v
}
function Read-Default($prompt, $default) {
    $v = (Read-Host "$prompt [$default]").Trim()
    if ($v) { return $v } else { return $default }
}
function Confirm-Yes($prompt, [bool]$defaultYes = $true) {
    $hint = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
    $v = (Read-Host "$prompt $hint").Trim()
    if (-not $v) { return $defaultYes }
    return ($v -match '^(y|yes)$')
}

Write-Host ""
Write-Host "=== Claude proxy setup wizard (Windows) ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Collect VM details -------------------------------------------------
$ServerIp  = Read-Required "Server IP or hostname"
$SshUser   = Read-Required "SSH username"
$Alias     = Read-Default  "SSH alias (the shortcut you'll type)" "jpvpn"
$SshPort   = Read-Default  "SSH port" "22"
$ProxyPort = Read-Default  "VM proxy port (tinyproxy on the VM)" "8888"

# --- 2. Find / choose the private key --------------------------------------
$downloads = Join-Path $HOME 'Downloads'
$sshDir    = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

$key = Get-ChildItem -File $downloads -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -ne '.pub' -and $_.Length -lt 100KB } |
    Where-Object { (Get-Content $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue) -match 'BEGIN .*PRIVATE KEY' } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$keyPath = $null
if ($key) {
    Write-Host ""
    Write-Host "[Found] Newest private key in Downloads: $($key.FullName)" -ForegroundColor Green
    if (Confirm-Yes "Use this key?") { $keyPath = $key.FullName }
}
while (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath)) {
    $keyPath = (Read-Host "Full path to your private key").Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $keyPath)) { Write-Host "  (no file at: $keyPath)" -ForegroundColor Yellow }
}

# --- 3. Install + lock the key ---------------------------------------------
$dest = Join-Path $sshDir ([System.IO.Path]::GetFileName($keyPath))
if ((Resolve-Path -LiteralPath $keyPath).Path -ne $dest) {
    Copy-Item -LiteralPath $keyPath -Destination $dest -Force
}
# OpenSSH refuses keys that others can read - strip inheritance, grant only you.
icacls $dest /inheritance:r            | Out-Null
icacls $dest /grant:r "$($env:USERNAME):R" | Out-Null
icacls $dest /remove "SYSTEM"          | Out-Null
icacls $dest /remove "Administrators"  | Out-Null
Write-Host "[OK] Key installed and locked: $dest" -ForegroundColor Green

# --- 4. Write the ~/.ssh/config alias --------------------------------------
$configPath = Join-Path $sshDir 'config'
$aliasExists = (Test-Path $configPath) -and
               (Select-String -Path $configPath -Pattern "^Host\s+$([regex]::Escape($Alias))(\s|$)" -Quiet)
$writeAlias = $true
if ($aliasExists) {
    if (Confirm-Yes "Alias '$Alias' already exists. Overwrite it?" $false) {
        # Drop the existing "Host <alias>" block (its Host line + indented body).
        $out = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($ln in (Get-Content $configPath)) {
            if ($ln -match '^\s*Host\s+(.+)$') { $skip = (($matches[1] -split '\s+') -contains $Alias) }
            if (-not $skip) { $out.Add($ln) }
        }
        Set-Content -Path $configPath -Value $out -Encoding ascii
    } else {
        Write-Host "[Info] Keeping the existing '$Alias' alias." -ForegroundColor Yellow
        $writeAlias = $false
    }
}
if ($writeAlias) {
    $entry = "`nHost $Alias`n    HostName $ServerIp`n    User $SshUser`n"
    if ($SshPort -ne '22') { $entry += "    Port $SshPort`n" }
    $entry += "    IdentityFile `"$dest`"`n"
    Add-Content -Path $configPath -Value $entry -Encoding ascii
    Write-Host "[OK] SSH alias '$Alias' written - connect with: ssh $Alias" -ForegroundColor Green
}

# --- 5. Install the cc profile ---------------------------------------------
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
} catch {
    Write-Host "[Warn] Could not set execution policy (managed by group policy?). The profile may not auto-load in new windows." -ForegroundColor Yellow
}
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Invoke-WebRequest -UseBasicParsing -Uri "$repoRaw/Microsoft.PowerShell_profile.ps1" -OutFile $PROFILE
Unblock-File -Path $PROFILE
# Patch the Settings block so the profile matches the answers above.
$raw = Get-Content $PROFILE -Raw
$raw = $raw -replace '(?m)^(\$script:SSH_HOST\s*=\s*)"[^"]*"',        ('$1"' + $Alias + '"')
$raw = $raw -replace '(?m)^(\$script:SSH_PORT\s*=\s*)\d+',           ('${1}' + $SshPort)
$raw = $raw -replace '(?m)^(\$script:REMOTE_PROXY_PORT\s*=\s*)\d+',  ('${1}' + $ProxyPort)
Set-Content -Path $PROFILE -Value $raw -Encoding utf8
Write-Host "[OK] Profile installed: $PROFILE" -ForegroundColor Green

# --- 6. Verify the connection ----------------------------------------------
Write-Host ""
Write-Host "[Check] Testing: ssh $Alias ..." -ForegroundColor Cyan
$sshOk = $false
try {
    & ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $Alias exit
    $sshOk = ($LASTEXITCODE -eq 0)
} catch {
    Write-Host "[Warn] 'ssh' not found - install the OpenSSH client (Settings > Optional features)." -ForegroundColor Yellow
}
if ($sshOk) {
    Write-Host "[OK] SSH connection works." -ForegroundColor Green
} else {
    Write-Host "[Warn] Couldn't connect yet (passphrase, host key, or network)." -ForegroundColor Yellow
    Write-Host "       Try once manually:  ssh $Alias" -ForegroundColor Yellow
}

# --- 7. Load the profile + next steps --------------------------------------
. $PROFILE
Write-Host ""
Write-Host "Done! The profile is loaded in this window - just run:" -ForegroundColor Cyan
Write-Host "    cc" -ForegroundColor White
Write-Host "(New windows pick it up automatically.)" -ForegroundColor DarkGray
