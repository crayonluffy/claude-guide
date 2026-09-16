# ============================================================
# Interactive setup wizard - Claude SSH tunnel proxy (Windows)
# ============================================================
# Run with:
#   irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
# If your company publishes its proxy nodes in DNS, name its domain first:
#   $env:CLAUDE_PROXY_DOMAIN = 'example.com'; irm https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts/setup.ps1 | iex
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
$repoRaw     = 'https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts'
$confPath    = Join-Path $HOME '.claude-proxy.conf.psd1'
$profilePath = Join-Path $HOME '.claude-proxy.ps1'   # the profile code lives in HOME, not Documents
$domainArg   = "$env:CLAUDE_PROXY_DOMAIN"
if ($env:CLAUDE_PROXY_REPO_RAW) { $repoRaw = $env:CLAUDE_PROXY_REPO_RAW }

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

# Fetch the profile now: the node lookup below reuses its functions. A failed
# download is reported (and stops the wizard) at step 6, as before.
$tmpProfile = Join-Path $env:TEMP 'claude-proxy.ps1'
$profileErr = $null
$raw = ''
try {
    Invoke-WebRequest -UseBasicParsing -Uri "$repoRaw/claude-proxy.ps1" -OutFile $tmpProfile
    $raw  = Get-Content $tmpProfile -Raw
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$null, [ref]$errs) | Out-Null
    if ($errs.Count -gt 0 -or $raw -notmatch '(?m)^\$script:PROFILE_VERSION\s*=') { $profileErr = 'invalid' }
} catch {
    $profileErr = $_.Exception.Message
}

# Nodes a company publishes in DNS (TXT _claude-proxy.<domain>), sorted by slot. @() if none.
function Get-DomainNodes($domain) {
    if ($profileErr) { return @() }
    $json = & {
        $ErrorActionPreference = 'Continue'
        . $tmpProfile
        ConvertTo-NodesJsonFromDns $domain
    } 6>$null
    if (-not $json) { return @() }
    try { return @(($json | ConvertFrom-Json).nodes) } catch { return @() }
}

# Ask for / check the company domain. Returns @{ Domain; Node } - Node is the
# node the user picked as their main one (only when $pick is set).
function Select-Domain($current, [bool]$pick, $alias) {
    $d = $domainArg
    if (-not $d) {
        Write-Host ""
        Write-Host "Does your company publish its proxy nodes in DNS? Then enter its domain (e.g. example.com)."
        $hint = if ($current) { "Enter = $current, '-' = none" } else { 'Enter = none' }
        $d = (Read-Host "Company domain ($hint)").Trim()
        if (-not $d) { $d = $current }
        if ($d -eq '-') { $d = '' }
    }
    $r = @{ Domain = $d; Node = $null }
    if (-not $d) { return $r }
    $nodes = Get-DomainNodes $d
    if ($nodes.Count -eq 0) {
        Write-Host "[Warn] No proxy nodes found at _claude-proxy.$d (DNS TXT)." -ForegroundColor Yellow
        if (-not (Confirm-Yes "Keep '$d' anyway (e.g. the records aren't published yet)?" $false)) { $r.Domain = '' }
        return $r
    }
    Write-Host "[OK] $d publishes these nodes:" -ForegroundColor Green
    foreach ($n in $nodes) { Write-Host ("       {0,-5} {1,-9} {2,-12} {3}" -f $n.name, $n.alias, $n.region, $n.host) }
    if (-not $pick) { return $r }
    # Default pick: the node behind the alias you already have, else the first one.
    $def = ($nodes | Where-Object { $_.alias -eq $alias } | Select-Object -First 1).name
    if (-not $def) { $def = $nodes[0].name }
    while (-not $r.Node) {
        $want = Read-Default "Your main node (the one cc / cx use)" $def
        $r.Node = $nodes | Where-Object { $_.name -eq $want -or $_.alias -eq $want } | Select-Object -First 1
        if (-not $r.Node) { Write-Host "  (not in the list above)" -ForegroundColor Yellow }
    }
    return $r
}

$downloads = Join-Path $HOME 'Downloads'
$sshDir    = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
$configPath = Join-Path $sshDir 'config'

# --- 0. Existing install? Pre-fill everything from it -----------------------
# Sources, in order of preference: ~\.claude-proxy.conf.psd1, the Settings block
# of an old-style profile, and the ~/.ssh/config alias itself.
$dAlias = 'jpvpn'; $dSshPort = '22'; $dProxyPort = '8888'; $dIp = ''; $dUser = ''; $dKey = ''; $dDomain = ''
$found = $null
$existingConf = @{}
if (Test-Path $confPath) {
    try {
        $existingConf = Import-PowerShellDataFile $confPath
        $found = $confPath
        if ($existingConf.SSH_HOST)          { $dAlias     = "$($existingConf.SSH_HOST)" }
        if ($existingConf.SSH_PORT)          { $dSshPort   = "$($existingConf.SSH_PORT)" }
        if ($existingConf.REMOTE_PROXY_PORT) { $dProxyPort = "$($existingConf.REMOTE_PROXY_PORT)" }
        if ($existingConf.PROXY_DOMAIN)      { $dDomain    = "$($existingConf.PROXY_DOMAIN)" }
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
    if ($dDomain) { Write-Host "        nodes from the DNS of: $dDomain" -ForegroundColor Green }
    if (Confirm-Yes "Keep these settings and only update the cc/cx profile?") { $quick = $true }
}

if ($quick) {
    $Alias = $dAlias; $SshPort = $dSshPort; $ProxyPort = $dProxyPort
    # Keep the saved domain; only ask when there is none yet.
    if ($domainArg -or -not $dDomain) { $Domain = (Select-Domain $dDomain $false $dAlias).Domain }
    else { $Domain = $dDomain }
} else {

# --- 1. Collect VM details (defaults = whatever we found) ------------------
$sel = Select-Domain $dDomain $true $dAlias
$Domain = $sel.Domain
if ($sel.Node) {
    $dAlias = $sel.Node.alias; $dIp = $sel.Node.host
    $dSshPort = "$($sel.Node.ssh_port)"; $dProxyPort = "$($sel.Node.proxy_port)"
}
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
$existingConf['PROXY_DOMAIN']      = "$Domain"
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
# The profile code goes to ~\.claude-proxy.ps1 (your HOME - practically always
# writable). $PROFILE only gets ONE loader line. If Documents is locked
# (Defender Controlled folder access, OneDrive, company policy) or scripts are
# blocked by policy, a Desktop shortcut gives you a window with cc/cx anyway.
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
} catch {
    Write-Host "[Warn] Could not set the execution policy (managed by group policy?)." -ForegroundColor Yellow
}
if ($profileErr -eq 'invalid') {
    Write-Host "[FAIL] The downloaded profile doesn't look valid - not installing it. Re-run the wizard later." -ForegroundColor Red
    return
} elseif ($profileErr) {
    Write-Host "[FAIL] Could not download the profile from GitHub." -ForegroundColor Red
    Write-Host "       Windows said: $profileErr" -ForegroundColor Red
    Write-Host "       Check your network / corporate proxy, then re-run the wizard." -ForegroundColor Yellow
    return
}
$newVer = [regex]::Match($raw, "(?m)^\`$script:PROFILE_VERSION\s*=\s*'([^']*)'").Groups[1].Value

$profileInstalled = $false
try {
    if ((Test-Path $profilePath) -and ((Get-Content $profilePath -Raw) -ne $raw)) {
        Copy-Item -LiteralPath $profilePath -Destination "$profilePath.bak" -Force
        Write-Host "[Info] Previous profile kept at $profilePath.bak" -ForegroundColor DarkGray
    }
    Copy-Item -LiteralPath $tmpProfile -Destination $profilePath -Force
    Unblock-File -Path $profilePath -ErrorAction SilentlyContinue
    Write-Host "[OK] Profile installed: $profilePath (v$newVer)" -ForegroundColor Green
    $profileInstalled = $true
} catch {
    Write-Host "[FAIL] Could not write $profilePath" -ForegroundColor Red
    Write-Host "       Windows said: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       The downloaded profile is at $tmpProfile - copy it there by hand once access is fixed." -ForegroundColor Yellow
}

# Hook it into $PROFILE (one line). Loading the profile first gives us
# _ensure-loader and proxy-shortcut from the profile itself.
$needShortcut = $false
if ($profileInstalled) {
    . $profilePath
    switch (_ensure-loader) {
        'ok'       { Write-Host "[OK] `$PROFILE already loads it" -ForegroundColor Green }
        'added'    { Write-Host "[OK] Added one loader line to `$PROFILE (your other profile content is untouched)" -ForegroundColor Green }
        'replaced' { Write-Host "[OK] `$PROFILE held the OLD full profile - replaced with the loader line (old copy: $PROFILE.bak)" -ForegroundColor Green }
        'locked'   {
            Write-Host "[Warn] Could not write to `$PROFILE ($PROFILE)." -ForegroundColor Yellow
            Write-Host "       Windows blocks PowerShell from editing your Documents folder - usually Defender's" -ForegroundColor Yellow
            Write-Host "       CONTROLLED FOLDER ACCESS (Windows Security > Virus & threat protection > Ransomware" -ForegroundColor Yellow
            Write-Host "       protection > 'Allow an app through Controlled folder access' > add powershell.exe)," -ForegroundColor Yellow
            Write-Host "       or OneDrive / company policy locking Documents. Nothing else is needed from Documents:" -ForegroundColor Yellow
            Write-Host "       the profile itself lives in $profilePath and updates there." -ForegroundColor Yellow
            $needShortcut = $true
        }
    }
    # Scripts blocked by policy? Then neither $PROFILE nor a dot-source will run in
    # new windows - the shortcut loads the profile with Invoke-Expression instead.
    $ep = Get-ExecutionPolicy
    if ($ep -in @('Restricted', 'AllSigned')) {
        Write-Host "[Warn] Execution policy is '$ep' (group policy) - new windows won't auto-load the profile." -ForegroundColor Yellow
        $needShortcut = $true
    }
    $shortcutOk = $false
    if ($needShortcut) {
        Write-Host "[Info] Creating a Desktop shortcut that opens PowerShell with cc/cx ready instead..." -ForegroundColor Cyan
        $shortcutOk = proxy-shortcut
    }

    # Node catalogue (jp / sg / us ...) + ssh aliases for the other nodes. Best
    # effort, done by the profile itself (from DNS when a domain is set, else from
    # this guide's nodes.json); 'proxy-nodes -Refresh' repeats it any time.
    Write-Host ""
    try {
        & { $ErrorActionPreference = 'Continue'; proxy-nodes -Refresh }
    } catch {
        Write-Host "[Info] Node catalogue not loaded (optional) - later: proxy-nodes -Refresh" -ForegroundColor DarkGray
    }
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

# --- 8. Next steps -----------------------------------------------------------
if (-not $profileInstalled) {
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
if ($needShortcut -and $shortcutOk) {
    Write-Host "(For new windows, double-click the 'Claude Proxy Shell' shortcut on your Desktop.)" -ForegroundColor DarkGray
} elseif ($needShortcut) {
    Write-Host "(For new windows, run:  Invoke-Expression (Get-Content -Raw '$profilePath')  - or fix the access issue above and re-run the wizard.)" -ForegroundColor DarkGray
} else {
    Write-Host "(New windows pick it up automatically.)" -ForegroundColor DarkGray
}
Write-Host "Later: 'proxy-update' fetches the newest profile (settings kept), 'proxy-config' shows/edits them." -ForegroundColor DarkGray
