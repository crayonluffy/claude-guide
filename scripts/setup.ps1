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

# Any unexpected error: say WHAT failed and WHERE, instead of dying with a bare
# one-line exception (the wizard runs via 'irm | iex', so users can't see a stack).
trap {
    Write-Host ""
    Write-Host "[FAIL] Setup stopped unexpectedly." -ForegroundColor Red
    Write-Host "       Windows said: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Where: $("$($_.InvocationInfo.PositionMessage)".Trim())" -ForegroundColor DarkGray
    Write-Host "       Fix the cause above and re-run the wizard - it is safe to run again." -ForegroundColor Yellow
    break
}

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
# Download + patch in TEMP first, then install with ONE copy into $PROFILE -
# so a locked/blocked Documents folder fails in exactly one place, with a clear
# diagnosis and a rescue copy the user can install by hand.
$tmpProfile = Join-Path $env:TEMP 'Microsoft.PowerShell_profile.ps1'
try {
    Invoke-WebRequest -UseBasicParsing -Uri "$repoRaw/Microsoft.PowerShell_profile.ps1" -OutFile $tmpProfile
} catch {
    Write-Host "[FAIL] Could not download the profile from GitHub." -ForegroundColor Red
    Write-Host "       Windows said: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Check your network / corporate proxy, then re-run the wizard." -ForegroundColor Yellow
    return
}
# Patch the Settings block so the profile matches the answers above.
$raw = Get-Content $tmpProfile -Raw
$raw = $raw -replace '(?m)^(\$script:SSH_HOST\s*=\s*)"[^"]*"',        ('$1"' + $Alias + '"')
$raw = $raw -replace '(?m)^(\$script:SSH_PORT\s*=\s*)\d+',           ('${1}' + $SshPort)
$raw = $raw -replace '(?m)^(\$script:REMOTE_PROXY_PORT\s*=\s*)\d+',  ('${1}' + $ProxyPort)
Set-Content -Path $tmpProfile -Value $raw -Encoding utf8

$profileInstalled = $false
try {
    $profileDir = Split-Path $PROFILE
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    Copy-Item -LiteralPath $tmpProfile -Destination $PROFILE -Force
    Unblock-File -Path $PROFILE -ErrorAction SilentlyContinue
    Write-Host "[OK] Profile installed: $PROFILE" -ForegroundColor Green
    $profileInstalled = $true
} catch {
    Write-Host "[FAIL] Could not write the profile to: $PROFILE" -ForegroundColor Red
    Write-Host "       Windows said: $($_.Exception.Message)" -ForegroundColor Red
    # Type check, not message text - "access denied" is localized on non-English Windows.
    if ($_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception -is [System.IO.IOException] -or $_.Exception.Message -match 'denied|unauthorized') {
        Write-Host "       'Access denied' on the Documents folder is usually one of:" -ForegroundColor Yellow
        Write-Host "       1) Defender's CONTROLLED FOLDER ACCESS (ransomware protection) blocks PowerShell" -ForegroundColor Yellow
        Write-Host "          from writing to Documents. Fix: Windows Security > Virus & threat protection >" -ForegroundColor Yellow
        Write-Host "          Ransomware protection > 'Allow an app through Controlled folder access' > add" -ForegroundColor Yellow
        Write-Host "          PowerShell (powershell.exe / pwsh.exe). Then re-run the wizard." -ForegroundColor Yellow
        Write-Host "       2) Documents is locked by OneDrive or company policy (read-only sync folder)." -ForegroundColor Yellow
    }
    Write-Host "       Your CONFIGURED profile was saved to: $tmpProfile" -ForegroundColor Cyan
    Write-Host "       After fixing access, finish the install with:" -ForegroundColor Cyan
    Write-Host "           Copy-Item '$tmpProfile' `$PROFILE -Force; . `$PROFILE" -ForegroundColor White
}

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
if ($profileInstalled) {
    . $PROFILE
} else {
    Write-Host "[Warn] Profile NOT installed (see the [FAIL] above) - 'cc'/'cx' won't exist until you finish that step." -ForegroundColor Yellow
}
# Non-blocking: the proxy works without these CLIs, so only hint, never abort.
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[Info] Claude Code CLI not installed - 'cc' needs it:  npm install -g @anthropic-ai/claude-code" -ForegroundColor Yellow
}
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Write-Host "[Info] Codex CLI not installed (optional) - to use 'cx':  npm install -g @openai/codex" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Done! The profile is loaded in this window - just run:" -ForegroundColor Cyan
Write-Host "    cc        (Claude)   or   cx        (Codex)" -ForegroundColor White
Write-Host "(New windows pick it up automatically.)" -ForegroundColor DarkGray
