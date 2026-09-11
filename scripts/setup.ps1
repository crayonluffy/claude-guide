# ============================================================
# Interactive setup wizard - Claude SSH tunnel proxy (Windows)
# ============================================================
# Run with:
#   irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
#
# First run: prompts for your VM details, installs and locks your SSH key,
# writes an ~/.ssh/config alias, installs the cc/cx profile, and tests the
# connection.
#
# Later runs: finds your existing settings (~\.claude-proxy.conf.psd1, or the
# Settings block of an older profile) and offers to just update the profile -
# nothing to type again.
#
# Prefer the paste-blocks in the guide if you'd rather not run a downloaded script.
# ============================================================

$ErrorActionPreference = 'Stop'
$repoRaw  = 'https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts'
$confPath = Join-Path $HOME '.claude-proxy.conf.psd1'

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

# Read-Default that becomes Read-Required when there is no default to offer.
function Read-Smart($prompt, $default) {
    if ($default) { return Read-Default $prompt $default } else { return Read-Required $prompt }
}

Write-Host ""
Write-Host "=== Claude proxy setup wizard (Windows) ===" -ForegroundColor Cyan
Write-Host ""

$downloads = Join-Path $HOME 'Downloads'
$sshDir    = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
$configPath = Join-Path $sshDir 'config'

# --- 0. Existing install? Pre-fill everything from it -----------------------
# Sources, in order of preference: ~\.claude-proxy.conf.psd1, the Settings block
# of an old-style profile, and the ~/.ssh/config alias itself.
$dAlias = 'jpvpn'; $dSshPort = '22'; $dProxyPort = '8888'; $dIp = ''; $dUser = ''; $dKey = ''
$found = $null
$existingConf = @{}
if (Test-Path $confPath) {
    try {
        $existingConf = Import-PowerShellDataFile $confPath
        $found = $confPath
        if ($existingConf.SSH_HOST)          { $dAlias     = "$($existingConf.SSH_HOST)" }
        if ($existingConf.SSH_PORT)          { $dSshPort   = "$($existingConf.SSH_PORT)" }
        if ($existingConf.REMOTE_PROXY_PORT) { $dProxyPort = "$($existingConf.REMOTE_PROXY_PORT)" }
    } catch { Write-Host "[Warn] Could not read $confPath - ignoring it." -ForegroundColor Yellow }
} elseif ((Test-Path $PROFILE) -and (Select-String -Path $PROFILE -Pattern '^\$script:SSH_HOST\s*=' -Quiet)) {
    $found = "$PROFILE (settings inside the old profile)"
    $old = Get-Content $PROFILE -Raw
    $m = [regex]::Match($old, '(?m)^\$script:SSH_HOST\s*=\s*"([^"]*)"');          if ($m.Success) { $dAlias     = $m.Groups[1].Value }
    $m = [regex]::Match($old, '(?m)^\$script:SSH_PORT\s*=\s*(\d+)');             if ($m.Success) { $dSshPort   = $m.Groups[1].Value }
    $m = [regex]::Match($old, '(?m)^\$script:REMOTE_PROXY_PORT\s*=\s*(\d+)');    if ($m.Success) { $dProxyPort = $m.Groups[1].Value }
}
$aliasExists = (Test-Path $configPath) -and
               (Select-String -Path $configPath -Pattern "^Host\s+$([regex]::Escape($dAlias))(\s|$)" -Quiet)
if ($aliasExists -and (Get-Command ssh -ErrorAction SilentlyContinue)) {
    # ssh -G resolves the alias exactly as ssh itself would.
    $g = @{}
    try { & ssh -G $dAlias 2>$null | ForEach-Object { $w = $_ -split '\s+', 2; if ($w.Count -eq 2 -and -not $g.ContainsKey($w[0])) { $g[$w[0]] = $w[1] } } } catch {}
    if ($g.hostname)     { $dIp = $g.hostname }
    if ($g.user)         { $dUser = $g.user }
    if ($g.port)         { $dSshPort = $g.port }
    if ($g.identityfile) { $dKey = $g.identityfile }
}

$quick = $false
if ($found) {
    Write-Host ""
    Write-Host "[Found] Existing setup: $found" -ForegroundColor Green
    Write-Host "        server alias '$dAlias' -> $(if ($dUser) { $dUser } else { '?' })@$(if ($dIp) { $dIp } else { '?' }) (ssh port $dSshPort), VM proxy port $dProxyPort" -ForegroundColor Green
    if (Confirm-Yes "Keep these settings and only update the cc/cx profile?") { $quick = $true }
}

if ($quick) {
    $Alias = $dAlias; $SshPort = $dSshPort; $ProxyPort = $dProxyPort
} else {

# --- 1. Collect VM details (defaults = whatever we found) ------------------
Write-Host ""
$ServerIp  = Read-Smart   "Server IP or hostname" $dIp
$SshUser   = Read-Smart   "SSH username" $dUser
$Alias     = Read-Default "SSH alias (the shortcut you'll type)" $dAlias
$SshPort   = Read-Default "SSH port" $dSshPort
$ProxyPort = Read-Default "VM proxy port (tinyproxy on the VM)" $dProxyPort

# --- 2. Find / choose the private key --------------------------------------

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
if (-not $keyPath -and $dKey -and (Test-Path -LiteralPath $dKey)) {
    Write-Host "[Found] Key already installed for '$dAlias': $dKey" -ForegroundColor Green
    if (Confirm-Yes "Keep using it?") { $keyPath = $dKey }
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

} # end of the full (non-quick) path

# --- 5. Save the settings (~\.claude-proxy.conf.psd1) ------------------------
# The profile itself carries no personal settings anymore, so updating it
# (proxy-update, or re-running this wizard) never loses them.
$existingConf['SSH_HOST']          = $Alias
$existingConf['SSH_PORT']          = [int]$SshPort
$existingConf['REMOTE_PROXY_PORT'] = [int]$ProxyPort
$confLines = @(
    '@{',
    '    # ~\.claude-proxy.conf.psd1 - YOUR settings for the cc/cx profile.',
    "    # 'proxy-update' replaces the profile but never touches this file.",
    "    # Remove a line to fall back to the profile's built-in default."
)
foreach ($k in ($existingConf.Keys | Sort-Object)) {
    $v = $existingConf[$k]
    if ($v -is [int]) { $confLines += "    $k = $v" } else { $confLines += "    $k = '$("$v" -replace "'", "''")'" }
}
$confLines += '}'
Set-Content -Path $confPath -Value $confLines -Encoding ascii
Write-Host "[OK] Settings saved: $confPath" -ForegroundColor Green

# --- 6. Install / update the cc profile ------------------------------------
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
} catch {
    Write-Host "[Warn] Could not set execution policy (managed by group policy?). The profile may not auto-load in new windows." -ForegroundColor Yellow
}
# Download into TEMP first, then install with ONE copy into $PROFILE - so a
# locked/blocked Documents folder fails in exactly one place, with a clear
# diagnosis and a rescue copy the user can install by hand. No patching:
# the profile reads its settings from the conf file written above.
$tmpProfile = Join-Path $env:TEMP 'Microsoft.PowerShell_profile.ps1'
try {
    Invoke-WebRequest -UseBasicParsing -Uri "$repoRaw/Microsoft.PowerShell_profile.ps1" -OutFile $tmpProfile
} catch {
    Write-Host "[FAIL] Could not download the profile from GitHub." -ForegroundColor Red
    Write-Host "       Windows said: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Check your network / corporate proxy, then re-run the wizard." -ForegroundColor Yellow
    return
}
$raw  = Get-Content $tmpProfile -Raw
$errs = $null
[System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$null, [ref]$errs) | Out-Null
if ($errs.Count -gt 0 -or $raw -notmatch '(?m)^\$script:PROFILE_VERSION\s*=') {
    Write-Host "[FAIL] The downloaded profile doesn't look valid - not installing it. Re-run the wizard later." -ForegroundColor Red
    return
}
$newVer = [regex]::Match($raw, "(?m)^\`$script:PROFILE_VERSION\s*=\s*'([^']*)'").Groups[1].Value

$profileInstalled = $false
try {
    $profileDir = Split-Path $PROFILE
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    if ((Test-Path $PROFILE) -and ((Get-Content $PROFILE -Raw) -ne $raw)) {
        Copy-Item -LiteralPath $PROFILE -Destination "$PROFILE.bak" -Force
        Write-Host "[Info] Previous profile kept at $PROFILE.bak" -ForegroundColor DarkGray
    }
    Copy-Item -LiteralPath $tmpProfile -Destination $PROFILE -Force
    Unblock-File -Path $PROFILE -ErrorAction SilentlyContinue
    Write-Host "[OK] Profile installed: $PROFILE (v$newVer)" -ForegroundColor Green
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

# --- 7. Verify the connection ----------------------------------------------
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

# --- 8. Load the profile + next steps --------------------------------------
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
Write-Host "Later: 'proxy-update' fetches the newest profile (settings kept), 'proxy-config' shows/edits them." -ForegroundColor DarkGray
