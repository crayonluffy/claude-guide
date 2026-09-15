# ============================================================
# claude-proxy.ps1 - SSH Tunnel + HTTP proxy (Claude/Codex) + SOCKS5 (Chrome)
# Installed as ~\.claude-proxy.ps1 and dot-sourced from $PROFILE (one line),
# or loaded by the "Claude Proxy Shell" shortcut when $PROFILE can't be edited.
# ============================================================
# One SSH connection carries two forwards:
#   -L 8080:127.0.0.1:8888  ->  VM's HTTP proxy (tinyproxy)  ->  used by Claude & Codex (HTTPS_PROXY)
#   -D 1080                 ->  SOCKS5 on the VM              ->  used by Chrome / other apps
#
# Claude Code only speaks HTTP proxies, so it uses the -L forward to the VM's HTTP
# proxy (see webproxy-manager: https://github.com/crayonluffy/forge/tree/main/webproxy-manager).
# Codex reads the same HTTP(S)_PROXY env vars, so it shares that forward too.
# Chrome is happier on SOCKS5 (full traffic, remote DNS), so it uses the -D forward.
#
# YOUR SETTINGS LIVE IN ~\.claude-proxy.conf.psd1, NOT IN THIS FILE.
#   proxy-config        show / edit them
#   proxy-update        replace this file with the latest version (settings are kept)
#
# NODES (v2.1): the admin publishes a catalogue of VMs (jp / sg / us ...) as
# scripts/nodes.json. 'proxy-nodes -Refresh' downloads it and creates the
# matching ~\.ssh\config aliases; 'proxy-node sg' makes sg the node that cc / cx
# use; 'chrome-proxy sg' opens a Chrome window through sg on its OWN tunnel and
# profile, so several regions can be open side by side.
# ============================================================

$script:PROFILE_VERSION = '2.1.1'
$script:REPO_RAW     = 'https://raw.githubusercontent.com/crayonluffy/claude-guide/main/scripts'
$script:PROXY_CONF   = Join-Path $HOME '.claude-proxy.conf.psd1'
$script:PROFILE_PATH = Join-Path $HOME '.claude-proxy.ps1'   # where proxy-update writes
# The one line $PROFILE needs. Lives in your HOME, so a locked Documents folder
# (Controlled folder access / OneDrive / policy) never blocks an update.
$script:LOADER_LINE  = 'if (Test-Path "$HOME\.claude-proxy.ps1") { . "$HOME\.claude-proxy.ps1" }   # claude-proxy'

# ============================================================
# Settings - built-in defaults. DO NOT EDIT HERE: put overrides in
# ~\.claude-proxy.conf.psd1 (created by the setup wizard / 'proxy-config edit').
# That file survives 'proxy-update', so you never re-enter anything.
# ============================================================
# If you ran the setup wizard, you already have an ~/.ssh/config alias -
# SSH_HOST points at it and SSH_USER / SSH_KEY stay blank.
$script:SSH_HOST          = "jpvpn"   # an ~/.ssh/config alias, OR a raw host/IP
$script:SSH_USER          = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_KEY           = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_PORT          = 22
$script:HTTP_PORT         = 8080       # local HTTP port -> forwarded to the VM proxy (Claude)
$script:REMOTE_PROXY_PORT = 8888       # tinyproxy port on the VM (webproxy-manager)
$script:SOCKS_PORT        = 1080       # local SOCKS5 port (Chrome / other apps)

# Node catalogue (jp / sg / us ...): downloaded by 'proxy-nodes -Refresh' from
# $REPO_RAW/nodes.json. 'chrome-proxy <node>' opens a SEPARATE SOCKS-only tunnel
# per node so several regions can be open at once; node i (0-based, catalogue
# order) listens on NODE_SOCKS_BASE + i.
$script:NODES_CACHE       = Join-Path $HOME '.claude-proxy.nodes.json'
$script:NODE_SOCKS_BASE   = 1180
$script:CHROME_EXE        = ''         # chrome.exe path, only if Chrome isn't in one of the usual places

# Also write the proxy into Claude's settings.json while the tunnel is up, so
# `claude` launched from ANY shell uses it. Removed again on proxy-off / cc-stop.
$script:SYNC_SETTINGS   = 1
$script:CLAUDE_SETTINGS = Join-Path $HOME ".claude\settings.json"

$script:NO_PROXY_LIST = @(
    "localhost",
    "127.0.0.1",
    "::1",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "*.local",
    "*.internal",
    "*.corp"
    # Company intranet ranges / domains go in the conf file as NO_PROXY_EXTRA, e.g.
    # NO_PROXY_EXTRA = '172.20.0.0/24,*.mycorp.example'
) -join ","

$script:BANNER         = 1     # one-line notice when a new window loads this profile (0 = silent)
$script:NO_PROXY_EXTRA = ''    # appended to NO_PROXY_LIST

# --- personal overrides (~\.claude-proxy.conf.psd1) ---------------------------
$script:CONF_KEYS = @('SSH_HOST','SSH_USER','SSH_KEY','SSH_PORT','HTTP_PORT','REMOTE_PROXY_PORT',
                      'SOCKS_PORT','NODE_SOCKS_BASE','CHROME_EXE','SYNC_SETTINGS','BANNER','NO_PROXY_EXTRA')
if (Test-Path $script:PROXY_CONF) {
    try {
        $cfg = Import-PowerShellDataFile $script:PROXY_CONF
        foreach ($k in $script:CONF_KEYS) {
            if ($cfg.ContainsKey($k)) { Set-Variable -Name $k -Value $cfg[$k] -Scope Script }
        }
    } catch {
        Write-Host "[Warn] Could not read $($script:PROXY_CONF) ($($_.Exception.Message)) - using built-in defaults" -ForegroundColor Yellow
    }
}
if ($script:NO_PROXY_EXTRA) { $script:NO_PROXY_LIST = "$($script:NO_PROXY_LIST),$($script:NO_PROXY_EXTRA)" }

# ============================================================
# Helper: Check if a port is in use
# ============================================================

function Test-Port {
    param([int]$Port)
    # -State Listen: a port is only "in use" if something actually LISTENS on it.
    # Without it, half-dead connections make a broken tunnel look alive.
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn)
}

# First free port at or after $Start (returns 0 if none within 20).
function Find-FreePort {
    param([int]$Start)
    for ($p = $Start; $p -lt $Start + 20; $p++) {
        if (-not (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)) { return $p }
    }
    return 0
}

# Classify what holds the tunnel ports, so callers can HEAL instead of guessing:
#   ok      - our ssh tunnel is up; HttpPort tells where the HTTP forward
#             actually listens (may be a fallback port like 8081)
#   down    - no tunnel, configured HTTP port is free
#   stale   - a broken leftover ssh holds a tunnel port - safe to kill/restart
#   foreign - a NON-ssh app holds the HTTP port - never killed; callers fall
#             back to another port instead
# Anchored on the SOCKS port: its ssh owner identifies OUR tunnel even when the
# HTTP forward went to a fallback port in an earlier shell.
function Get-TunnelHealth {
    $socksPids = @((Get-NetTCPConnection -LocalPort $script:SOCKS_PORT -State Listen -ErrorAction SilentlyContinue).OwningProcess | Select-Object -Unique)
    if ($socksPids.Count -eq 1) {
        $owner = Get-Process -Id $socksPids[0] -ErrorAction SilentlyContinue
        if ($owner -and $owner.ProcessName -match '^ssh') {
            $ports = @((Get-NetTCPConnection -OwningProcess $socksPids[0] -State Listen -ErrorAction SilentlyContinue).LocalPort |
                       Where-Object { $_ -ne $script:SOCKS_PORT } | Select-Object -Unique)
            if ($ports.Count -eq 1) {
                return @{ Status = 'ok'; OwnerPid = $socksPids[0]; OwnerName = $owner.ProcessName; HttpPort = $ports[0] }
            }
            if ($ports -contains $script:HTTP_PORT) {
                return @{ Status = 'ok'; OwnerPid = $socksPids[0]; OwnerName = $owner.ProcessName; HttpPort = $script:HTTP_PORT }
            }
            return @{ Status = 'stale'; OwnerPid = $socksPids[0]; OwnerName = $owner.ProcessName }
        }
    }

    # No healthy ssh anchor - classify whatever sits on the configured HTTP port.
    $httpPids = @((Get-NetTCPConnection -LocalPort $script:HTTP_PORT -State Listen -ErrorAction SilentlyContinue).OwningProcess | Select-Object -Unique)
    if (-not $httpPids) { return @{ Status = 'down' } }
    $owner = Get-Process -Id $httpPids[0] -ErrorAction SilentlyContinue
    $name  = if ($owner) { $owner.ProcessName } else { 'unknown' }
    if ($name -match '^ssh') {
        return @{ Status = 'stale'; OwnerPid = $httpPids[0]; OwnerName = $name }
    }
    return @{ Status = 'foreign'; OwnerPid = $httpPids[0]; OwnerName = $name }
}

# --- Claude settings.json sync (toggle-synced with the proxy) ---------------
function _settings-sync-on {
    if ($script:SYNC_SETTINGS -ne 1) { return }
    $settings = $script:CLAUDE_SETTINGS
    $url = "http://127.0.0.1:$($script:HTTP_PORT)"
    New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
    if (Test-Path $settings) {
        Copy-Item $settings "$settings.bak" -Force -ErrorAction SilentlyContinue
        try { $obj = Get-Content $settings -Raw | ConvertFrom-Json } catch {
            Write-Host "[Warn] $settings is invalid JSON - left it untouched" -ForegroundColor Yellow
            return
        }
    } else {
        $obj = [pscustomobject]@{}
    }
    if ($null -eq $obj.env) {
        $obj | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $obj.env | Add-Member -NotePropertyName HTTPS_PROXY -NotePropertyValue $url -Force
    $obj.env | Add-Member -NotePropertyName HTTP_PROXY  -NotePropertyValue $url -Force
    $obj.env | Add-Member -NotePropertyName NO_PROXY    -NotePropertyValue $script:NO_PROXY_LIST -Force
    $obj | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding utf8
    Write-Host "[OK] Proxy written into $settings (env block)" -ForegroundColor Green
}

function _settings-sync-off {
    if ($script:SYNC_SETTINGS -ne 1) { return }
    $settings = $script:CLAUDE_SETTINGS
    if (-not (Test-Path $settings)) { return }
    Copy-Item $settings "$settings.bak" -Force -ErrorAction SilentlyContinue
    try { $obj = Get-Content $settings -Raw | ConvertFrom-Json } catch { return }
    if ($obj.env) {
        foreach ($k in 'HTTPS_PROXY','HTTP_PROXY','NO_PROXY') {
            if ($obj.env.PSObject.Properties.Name -contains $k) {
                $obj.env.PSObject.Properties.Remove($k)
            }
        }
    }
    $obj | ConvertTo-Json -Depth 20 | Set-Content $settings -Encoding utf8
    Write-Host "[OK] Proxy removed from $settings" -ForegroundColor Green
}

# ============================================================
# Nodes: catalogue (nodes.json) + ~\.ssh\config aliases + per-node Chrome tunnels
# ============================================================

# The catalogue as objects: Idx Name Alias Host User SshPort ProxyPort Region Note HostKey
function Get-ProxyNodes {
    if (-not (Test-Path $script:NODES_CACHE)) { return @() }
    try { $cat = Get-Content $script:NODES_CACHE -Raw | ConvertFrom-Json } catch { return @() }
    $out = @(); $i = 0
    foreach ($n in @($cat.nodes)) {
        $out += [pscustomobject]@{
            Idx = $i; Name = "$($n.name)"; Alias = "$($n.alias)"; Host = "$($n.host)"; User = "$($n.user)"
            SshPort = $(if ($n.ssh_port) { [int]$n.ssh_port } else { 22 })
            ProxyPort = $(if ($n.proxy_port) { [int]$n.proxy_port } else { 8888 })
            Region = "$($n.region)"; Note = "$($n.note)"; HostKey = "$($n.hostkey)"
        }
        $i++
    }
    return $out
}

# Node object for a NAME or ALIAS ($null if unknown).
function Find-ProxyNode { param([string]$Want)
    if (-not $Want) { return $null }
    foreach ($n in Get-ProxyNodes) { if ($n.Name -eq $Want -or $n.Alias -eq $Want) { return $n } }
    return $null
}

# Name of the node cc/cx currently use ('' when SSH_HOST isn't in the catalogue).
function Get-ActiveNodeName {
    $n = Find-ProxyNode $script:SSH_HOST
    if ($n) { return $n.Name } else { return '' }
}

# A node's host is "provisioned" once the admin replaced the <placeholder>.
function Test-NodeProvisioned { param([string]$NodeHost) return ($NodeHost -and -not $NodeHost.StartsWith('<')) }

function Get-NodeSocksPort { param([int]$Idx) return ($script:NODE_SOCKS_BASE + $Idx) }

function Test-SshAlias { param([string]$Alias)
    $cfg = Join-Path $HOME '.ssh\config'
    return ((Test-Path $cfg) -and (Select-String -Path $cfg -Pattern "^Host\s+$([regex]::Escape($Alias))(\s|$)" -Quiet))
}

# A field (IdentityFile, User, ...) of an ~\.ssh\config alias ('' if none) - new
# nodes reuse the key AND the username the wizard set up for the first one.
function Get-SshField { param([string]$Alias, [string]$Field)
    $cfg = Join-Path $HOME '.ssh\config'
    if (-not (Test-Path $cfg)) { return '' }
    $in = $false
    foreach ($ln in (Get-Content $cfg)) {
        if ($ln -match '^\s*Host\s+(.+)$') { $in = (($Matches[1] -split '\s+') -contains $Alias); continue }
        if ($in -and $ln -match "^\s*$Field\s+(.+?)\s*$") { return ($Matches[1] -replace '^"|"$', '') }
    }
    return ''
}
function Get-SshIdentity { param([string]$Alias) return (Get-SshField $Alias 'IdentityFile') }

# Append a Host block (same shape as the setup wizard writes).
function Add-SshAlias { param([string]$Alias, [string]$NodeHost, [string]$User, [int]$Port, [string]$Key)
    $sshDir = Join-Path $HOME '.ssh'
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
    $entry  = "`nHost $Alias`n    HostName $NodeHost`n"
    if ($User)         { $entry += "    User $User`n" }
    if ($Port -ne 22)  { $entry += "    Port $Port`n" }
    if ($Key)          { $entry += "    IdentityFile `"$Key`"`n" }
    $entry += "    AddKeysToAgent yes`n"
    Add-Content -Path (Join-Path $sshDir 'config') -Value $entry -Encoding ascii
}

# Pin a node's host key so the first connection never stops at "Are you sure...?".
function Add-KnownHost { param([string]$NodeHost, [int]$Port, [string]$HostKey)
    if (-not $HostKey) { return }
    $kh = Join-Path $HOME '.ssh\known_hosts'
    if ((Test-Path $kh) -and (Select-String -Path $kh -SimpleMatch $HostKey -Quiet)) { return }
    $entry = if ($Port -eq 22) { $NodeHost } else { "[$NodeHost]:$Port" }
    Add-Content -Path $kh -Value "$entry $HostKey" -Encoding ascii
    Write-Host "[OK] Host key for $NodeHost pinned in ~\.ssh\known_hosts" -ForegroundColor Green
}

# Make sure a catalogue node has an ssh alias (creates it from the catalogue if
# missing, reusing the active alias's key). $false when the node has no host yet.
function Confirm-NodeAlias { param($Node)
    if (Test-SshAlias $Node.Alias) { Add-KnownHost $Node.Host $Node.SshPort $Node.HostKey; return $true }
    if (-not (Test-NodeProvisioned $Node.Host)) {
        Write-Host "[Err] Node '$($Node.Name)' has no host in the catalogue yet (not provisioned) - ask your admin, then 'proxy-nodes -Refresh'." -ForegroundColor Red
        return $false
    }
    $key = Get-SshIdentity $script:SSH_HOST
    if (-not $key) { $key = $script:SSH_KEY }
    # Catalogue 'user' empty = everyone has their own account: reuse the User of the active alias.
    $user = $Node.User
    if (-not $user) { $user = Get-SshField $script:SSH_HOST 'User' }
    if (-not $user) { $user = $script:SSH_USER }
    Add-SshAlias $Node.Alias $Node.Host $user $Node.SshPort $key
    $tgt = if ($user) { "$user@$($Node.Host)" } else { $Node.Host }
    if ($key) { Write-Host "[OK] ssh alias '$($Node.Alias)' -> $tgt written to ~\.ssh\config (key: $key)" -ForegroundColor Green }
    else      { Write-Host "[OK] ssh alias '$($Node.Alias)' -> $tgt written to ~\.ssh\config (no IdentityFile found on '$($script:SSH_HOST)' - ssh will use your default key)" -ForegroundColor Yellow }
    Add-KnownHost $Node.Host $Node.SshPort $Node.HostKey
    return $true
}

# --- per-node Chrome tunnels (SOCKS only; the main tunnel is untouched) ------
function Start-NodeTunnel { param($Node, [int]$Port)
    $pids = @((Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).OwningProcess | Select-Object -Unique)
    if ($pids.Count -gt 0) {
        $owner = (Get-Process -Id $pids[0] -ErrorAction SilentlyContinue).ProcessName
        if ($owner -match '^ssh') {
            Write-Host "[OK]  $($Node.Name) tunnel already running (PID $($pids[0]), SOCKS 127.0.0.1:$Port)" -ForegroundColor DarkGreen
            return $true
        }
        Write-Host "[Err] Port $Port (reserved for the $($Node.Name) tunnel) is used by '$owner' (PID $($pids[0])). Move the node ports: proxy-config set NODE_SOCKS_BASE 1280" -ForegroundColor Red
        return $false
    }
    Write-Host "[SSH] Starting $($Node.Name) tunnel to $($Node.Alias) (SOCKS 127.0.0.1:$Port)..." -ForegroundColor Cyan
    $sshArgs = @('-N', '-C', '-D', "$Port",
                 '-o', 'ServerAliveInterval=60', '-o', 'ServerAliveCountMax=3',
                 '-o', 'ExitOnForwardFailure=yes', '-o', 'StrictHostKeyChecking=accept-new',
                 $Node.Alias)
    try { Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -WindowStyle Hidden -ErrorAction Stop | Out-Null }
    catch { Write-Host "[Err] Failed to launch ssh: $($_.Exception.Message)" -ForegroundColor Red; return $false }
    $attempts = 0
    while (-not (Test-Port -Port $Port) -and $attempts -lt 10) { Start-Sleep -Milliseconds 500; $attempts++ }
    if (Test-Port -Port $Port) {
        Write-Host "[OK]  $($Node.Name) tunnel up: SOCKS 127.0.0.1:$Port -> $($Node.Alias)" -ForegroundColor Green
        return $true
    }
    Write-Host "[Err] $($Node.Name) tunnel failed to start within 5s. First time? Run 'ssh $($Node.Alias)' once to accept the host key." -ForegroundColor Red
    return $false
}

# Running per-node tunnels: objects {Name, Port, Pid}
function Get-NodeTunnels {
    $out = @()
    foreach ($n in Get-ProxyNodes) {
        $port = Get-NodeSocksPort $n.Idx
        foreach ($p in @((Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue).OwningProcess | Select-Object -Unique)) {
            if ((Get-Process -Id $p -ErrorAction SilentlyContinue).ProcessName -match '^ssh') {
                $out += [pscustomobject]@{ Name = $n.Name; Port = $port; Pid = $p }
            }
        }
    }
    return $out
}

function Stop-NodeTunnels {
    foreach ($t in Get-NodeTunnels) {
        taskkill /PID $t.Pid /T /F 2>$null | Out-Null
        Write-Host "[Kill] PID $($t.Pid) (ssh, $($t.Name) Chrome tunnel :$($t.Port))" -ForegroundColor DarkGray
    }
}

# --- commands ----------------------------------------------------------------
function proxy-nodes {
    param([switch]$Refresh)
    if ($Refresh) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'claude-proxy.nodes.json.new'
        Write-Host "[Nodes] Fetching the node catalogue..." -ForegroundColor Cyan
        try { _fetch-file "$($script:REPO_RAW)/nodes.json" $tmp } catch {
            Write-Host "[Err] Download failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "       GitHub not reachable from here? Try 'proxy-up' first, then again." -ForegroundColor Yellow
            return
        }
        $ok = $false
        try { $cat = Get-Content $tmp -Raw | ConvertFrom-Json; $ok = (@($cat.nodes).Count -gt 0) } catch {}
        if (-not $ok) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Write-Host "[Err] Downloaded file doesn't look like a node catalogue - nothing changed." -ForegroundColor Red
            return
        }
        Move-Item $tmp $script:NODES_CACHE -Force
        Write-Host "[OK] Catalogue saved: $($script:NODES_CACHE)" -ForegroundColor Green
        # Create the ssh aliases the catalogue promises (never touches existing ones).
        foreach ($n in Get-ProxyNodes) {
            if (Test-SshAlias $n.Alias)               { Confirm-NodeAlias $n | Out-Null }   # pins the host key if given
            elseif (Test-NodeProvisioned $n.Host)     { Confirm-NodeAlias $n | Out-Null }
            else { Write-Host "[Info] Node '$($n.Name)' is listed but has no host yet - skipped" -ForegroundColor DarkGray }
        }
    }

    $nodes = Get-ProxyNodes
    if (-not (Test-Path $script:NODES_CACHE) -or $nodes.Count -eq 0) {
        Write-Host ""
        Write-Host "[Info] No node catalogue yet - run 'proxy-nodes -Refresh' to download it." -ForegroundColor Yellow
        Write-Host "       Current server: $($script:SSH_HOST)"
        Write-Host ""
        return
    }
    $updated = ''
    try { $updated = "$((Get-Content $script:NODES_CACHE -Raw | ConvertFrom-Json).updated)" } catch {}
    Write-Host ""
    Write-Host "=== Proxy nodes (catalogue: $($script:NODES_CACHE)$(if ($updated) { ", updated $updated" })) ===" -ForegroundColor Cyan
    Write-Host ""
    $health  = Get-TunnelHealth
    $running = @(Get-NodeTunnels)
    $foundActive = $false
    foreach ($n in $nodes) {
        $mark = ' '; $where = ''
        if ($n.Alias -eq $script:SSH_HOST) {
            $mark = '*'; $foundActive = $true
            $hp = if ($health.HttpPort) { $health.HttpPort } else { $script:HTTP_PORT }
            $where = if ($health.Status -eq 'ok') { "ACTIVE - cc/cx tunnel UP (127.0.0.1:$hp / :$($script:SOCKS_PORT))" } else { "ACTIVE - tunnel down ('cc' starts it)" }
        }
        if ($running | Where-Object { $_.Name -eq $n.Name }) {
            $where = "$(if ($where) { "$where; " })Chrome tunnel UP (:$(Get-NodeSocksPort $n.Idx))"
        }
        if (Test-NodeProvisioned $n.Host) {
            $target = if ($n.User) { "$($n.User)@$($n.Host)" } else { $n.Host }
            if (-not (Test-SshAlias $n.Alias)) { $where = "$(if ($where) { "$where; " })no ssh alias yet ('proxy-nodes -Refresh' creates it)" }
        } else { $target = '<not provisioned>' }
        $color = if ($mark -eq '*') { 'Green' } else { 'Gray' }
        Write-Host ("  {0} {1,-4} {2,-8} {3,-11} {4,-30} {5}" -f $mark, $n.Name, $n.Alias, $n.Region, $target, $where) -ForegroundColor $color
    }
    if (-not $foundActive) { Write-Host "  * ($($script:SSH_HOST))  - current server, not in the catalogue" -ForegroundColor Green }
    Write-Host ""
    Write-Host "  proxy-node <name>        make it the node cc / cx use (restarts the tunnel if it's up)" -ForegroundColor DarkGray
    Write-Host "  chrome-proxy <name>      open a Chrome window through that node (own tunnel + profile; several can be open)" -ForegroundColor DarkGray
    Write-Host "  proxy-nodes -Refresh     re-download the catalogue and create any missing ssh aliases" -ForegroundColor DarkGray
    Write-Host ""
}

function proxy-node {
    param([string]$Name)
    if (-not $Name) {
        $an = Get-ActiveNodeName
        if ($an) { Write-Host "[..] Active node: $an ($($script:SSH_HOST)) - 'proxy-node <name>' switches, 'proxy-nodes' lists them" }
        else     { Write-Host "[..] Active server: $($script:SSH_HOST) (not in the node catalogue) - 'proxy-nodes' lists the known nodes" }
        return $true
    }
    $n = Find-ProxyNode $Name
    if ($n) {
        if (-not (Confirm-NodeAlias $n)) { return $false }
        $alias = $n.Alias; $label = $n.Name; $pport = $n.ProxyPort
    } elseif (Test-SshAlias $Name) {
        $alias = $Name; $label = $Name; $pport = 0
        Write-Host "[Info] '$Name' is not in the node catalogue but exists in ~\.ssh\config - using it as-is." -ForegroundColor Yellow
    } else {
        Write-Host "[Err] Unknown node '$Name'. 'proxy-nodes' lists them ('proxy-nodes -Refresh' fetches the latest)." -ForegroundColor Red
        return $false
    }
    if ($alias -eq $script:SSH_HOST) {
        Write-Host "[OK] '$label' is already the active node ($alias)" -ForegroundColor Green
        return $true
    }
    $wasUp = ((Get-TunnelHealth).Status -eq 'ok')
    $envOn = [bool]$env:HTTPS_PROXY
    if ($wasUp) {
        Write-Host "[Node] Switching the cc/cx tunnel to $label ($alias)..." -ForegroundColor Cyan
        tunnel-stop | Out-Null
    }
    $script:SSH_HOST = $alias
    if ($pport) { $script:REMOTE_PROXY_PORT = $pport }
    _conf-write-all
    Write-Host "[OK] Active node: $label ($alias) - saved to $($script:PROXY_CONF)" -ForegroundColor Green
    if ($wasUp) {
        tunnel-start
        if ((Get-TunnelHealth).Status -ne 'ok') { return $false }
        if ($envOn) { proxy-on }
    }
    Write-Host "[Info] Other open windows keep the old node until they run:  . '$($script:PROFILE_PATH)'" -ForegroundColor DarkGray
    return $true
}

# ============================================================
# 1. Start SSH tunnel: -L (HTTP for Claude) + -D (SOCKS5 for Chrome)
# ============================================================

function tunnel-start {
    # Auto-heal: a HEALTHY tunnel is reused (adopting its port if it's on a
    # fallback), a STALE ssh is killed and replaced, and a FOREIGN app keeps its
    # port - the tunnel simply falls back to the next free port instead.
    $health = Get-TunnelHealth
    switch ($health.Status) {
        'ok' {
            if ($health.HttpPort -ne $script:HTTP_PORT) {
                $script:HTTP_PORT = $health.HttpPort
                Write-Host "[OK]  SSH tunnel already running (PID $($health.OwnerPid)) on fallback port $($health.HttpPort) - using it" -ForegroundColor DarkGreen
            } else {
                Write-Host "[OK]  SSH tunnel already running (PID $($health.OwnerPid))" -ForegroundColor DarkGreen
            }
            return
        }
        'stale' {
            Write-Host "[Heal] Stale ssh tunnel (PID $($health.OwnerPid)) - killing it and starting fresh..." -ForegroundColor Yellow
            tunnel-stop | Out-Null
        }
        'foreign' {
            Write-Host "[Info] Port $($script:HTTP_PORT) is used by '$($health.OwnerName)' (PID $($health.OwnerPid)) - that's another app, leaving it alone." -ForegroundColor Yellow
            $free = Find-FreePort ($script:HTTP_PORT + 1)
            if (-not $free) {
                Write-Host "[Err] No free port found in $($script:HTTP_PORT + 1)-$($script:HTTP_PORT + 20) - free one up or change `$script:HTTP_PORT in `$PROFILE." -ForegroundColor Red
                return
            }
            $script:HTTP_PORT = $free
            Write-Host "[Info] Falling back to free port $free for the HTTP proxy (this session)." -ForegroundColor Yellow
        }
    }

    # The SOCKS port can be squatted by another app too (ssh owners were handled
    # above) - fall back the same way so ExitOnForwardFailure doesn't kill ssh.
    if (Test-Port -Port $script:SOCKS_PORT) {
        $sPid   = @((Get-NetTCPConnection -LocalPort $script:SOCKS_PORT -State Listen -ErrorAction SilentlyContinue).OwningProcess | Select-Object -Unique)[0]
        $sName  = (Get-Process -Id $sPid -ErrorAction SilentlyContinue).ProcessName
        $sFree  = Find-FreePort ($script:SOCKS_PORT + 1)
        if (-not $sFree) {
            Write-Host "[Err] SOCKS port $($script:SOCKS_PORT) is used by '$sName' and no free port found nearby." -ForegroundColor Red
            return
        }
        Write-Host "[Info] SOCKS port $($script:SOCKS_PORT) is used by '$sName' (PID $sPid) - falling back to $sFree." -ForegroundColor Yellow
        $script:SOCKS_PORT = $sFree
    }

    Write-Host "[SSH] Starting tunnel to $($script:SSH_HOST)..." -ForegroundColor Cyan

    $sshArgs = @(
        "-N",
        "-C",
        "-L", "$($script:HTTP_PORT):127.0.0.1:$($script:REMOTE_PROXY_PORT)",
        "-D", "$($script:SOCKS_PORT)",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StrictHostKeyChecking=accept-new"
    )
    # Explicit key/port/user are optional - leave SSH_KEY/SSH_USER blank to use an ~/.ssh/config alias
    if ($script:SSH_KEY)  { $sshArgs += @("-i", $script:SSH_KEY, "-p", "$($script:SSH_PORT)") }
    if ($script:SSH_USER) { $sshArgs += "$($script:SSH_USER)@$($script:SSH_HOST)" }
    else                  { $sshArgs += $script:SSH_HOST }

    try {
        $proc = Start-Process -FilePath "ssh" -ArgumentList $sshArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Write-Host "[Err] Failed to launch ssh: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    if (-not $proc) {
        Write-Host "[Err] ssh process did not start" -ForegroundColor Red
        return
    }
    $global:SSH_TUNNEL_PID = $proc.Id

    # Wait for the forwarded HTTP port to come up
    $attempts = 0
    while (-not (Test-Port -Port $script:HTTP_PORT) -and $attempts -lt 10) {
        Start-Sleep -Milliseconds 500
        $attempts++
    }

    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[OK]  SSH tunnel up (PID: $($proc.Id)):" -ForegroundColor Green
        Write-Host "       HTTP  127.0.0.1:$($script:HTTP_PORT) -> VM tinyproxy:$($script:REMOTE_PROXY_PORT)   (Claude)" -ForegroundColor Green
        Write-Host "       SOCKS 127.0.0.1:$($script:SOCKS_PORT)                                   (Chrome / apps)" -ForegroundColor Green
    } else {
        Write-Host "[Err] SSH tunnel failed to start within 5s" -ForegroundColor Red
        Write-Host "      Accept the host key once with 'ssh $($script:SSH_HOST)', then retry." -ForegroundColor DarkGray
    }
}

# Back-compat stubs: the separate HTTP bridge is gone - the VM runs the proxy now.
function bridge-start { Write-Host "[Info] No bridge needed anymore - the VM runs the HTTP proxy; 'tunnel-start' forwards straight to it." -ForegroundColor Yellow }
function bridge-stop  { Write-Host "[Info] No bridge to stop - the VM runs the HTTP proxy now. Use 'tunnel-stop'." -ForegroundColor Yellow }

# ============================================================
# 2. Set proxy env vars (+ Claude settings.json sync)
# ============================================================

function proxy-on {
    $url = "http://127.0.0.1:$($script:HTTP_PORT)"
    $env:http_proxy = $url
    $env:HTTP_PROXY = $url
    $env:https_proxy = $url
    $env:HTTPS_PROXY = $url
    $env:no_proxy = $script:NO_PROXY_LIST
    $env:NO_PROXY = $script:NO_PROXY_LIST
    Write-Host "[OK] Env vars set: HTTPS_PROXY=$url" -ForegroundColor Green
    _settings-sync-on
}

function proxy-off {
    $env:http_proxy = $null
    $env:HTTP_PROXY = $null
    $env:https_proxy = $null
    $env:HTTPS_PROXY = $null
    $env:no_proxy = $null
    $env:NO_PROXY = $null
    Write-Host "[OK] Env vars cleared" -ForegroundColor Green
    _settings-sync-off
}

# ============================================================
# Bring the proxy stack up: tunnel + env vars + verify
# (everything 'cc' does EXCEPT launching Claude)
# ============================================================

function proxy-up {
    param([switch]$NoVerify, [string]$Node)

    # Step 0: -Node sg  ==  proxy-node sg first (persists, like running it yourself).
    if ($Node) { if (-not (proxy-node $Node)) { return $false } }

    # Step 1: SSH tunnel (HTTP + SOCKS forwards).
    # tunnel-start no-ops when the tunnel is healthy, auto-heals a stale one,
    # and refuses (with a named culprit) when a foreign app holds the port -
    # so require actual health afterwards, not just "something is on the port".
    tunnel-start
    if ((Get-TunnelHealth).Status -ne 'ok') { return $false }

    # Step 2: Env vars (+ settings.json sync)
    proxy-on

    # Step 3: Verify
    if (-not $NoVerify) {
        Write-Host "[Check] Verifying IP via proxy..." -ForegroundColor Cyan
        $ipResult = curl.exe -s --max-time 5 ipinfo.io 2>$null
        if ($LASTEXITCODE -eq 0 -and $ipResult) {
            try {
                $json = $ipResult | ConvertFrom-Json
                Write-Host "        IP: $($json.ip) | $($json.city), $($json.country)" -ForegroundColor Green
            } catch {
                Write-Host $ipResult -ForegroundColor Green
            }
        } else {
            Write-Host "[Warn] Could not verify" -ForegroundColor Yellow
        }
    }

    Write-Host "[OK]  Proxy ready in this shell - run 'claude' or 'codex' yourself, or 'cc-stop' to tear it down." -ForegroundColor Green
    return $true
}

# ============================================================
# All-in-one: proxy stack + launch Claude
# ============================================================

# Split wrapper flags (-Safe / -NoVerify, any dash style) from app arguments.
# Everything else is passed straight to the app, so 'cc -c', 'cc -r',
# 'cc --resume <id>', 'cx resume' ... all work.
function _split-launch-args {
    param($ArgList)
    $r = @{ Safe = $false; NoVerify = $false; Node = ''; App = @() }
    $list = @($ArgList)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $a = "$($list[$i])"
        switch -Regex ($a) {
            '^-{1,2}safe$'       { $r.Safe = $true }
            '^-{1,2}no-?verify$' { $r.NoVerify = $true }
            '^-{1,2}node$'       { $i++; $r.Node = "$($list[$i])" }
            '^-{1,2}node=(.+)$'  { $r.Node = $Matches[1] }
            default              { $r.App += $a }
        }
    }
    return $r
}

function cc {
    $o = _split-launch-args $args
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host "[Err] 'claude' not found - install it first: npm install -g @anthropic-ai/claude-code" -ForegroundColor Red
        return
    }

    # Steps 1-3: bring up tunnel + env vars + verify
    if (-not (proxy-up -NoVerify:$o.NoVerify -Node $o.Node)) { return }

    # Step 4: Launch Claude
    Write-Host "[Launch] Starting Claude $($o.App -join ' ')..." -ForegroundColor Cyan
    Write-Host ""

    $app = $o.App
    if ($o.Safe) {
        claude @app
    } else {
        claude --dangerously-skip-permissions @app
    }
}

function cc-safe { cc -Safe @args }

# ============================================================
# All-in-one: proxy stack + launch Codex (same tunnel as cc)
# ============================================================

function cx {
    $o = _split-launch-args $args

    # Locate codex first, so we don't bring the tunnel up only to find it missing.
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Write-Host "[Err] 'codex' not found - install it first: npm install -g @openai/codex" -ForegroundColor Red
        return
    }

    # Steps 1-3: bring up tunnel + env vars + verify (the same stack cc uses)
    if (-not (proxy-up -NoVerify:$o.NoVerify -Node $o.Node)) { return }

    # Step 4: Launch Codex (it picks up HTTP(S)_PROXY from this shell's env)
    Write-Host "[Launch] Starting Codex $($o.App -join ' ')..." -ForegroundColor Cyan
    Write-Host ""

    $app = $o.App
    if ($o.Safe) {
        codex @app
    } else {
        codex --dangerously-bypass-approvals-and-sandbox @app
    }
}

function cx-safe { cx -Safe @args }

# ============================================================
# Stop everything
# ============================================================

function tunnel-stop {
    # Kill every SSH process listening on either forwarded port (ours, including
    # stale leftovers), then verify. Non-ssh apps that happen to sit on a tunnel
    # port are NOT ours - they are reported and left alone.
    $ports = @($script:HTTP_PORT, $script:SOCKS_PORT)
    $sshPids = @()
    foreach ($p in $ports) {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        foreach ($procId in @($c.OwningProcess | Select-Object -Unique)) {
            $name = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
            if ($name -match '^ssh') {
                $sshPids += $procId
            } elseif ($name) {
                Write-Host "[Skip] PID $procId ($name) on port $p - another app, left alone" -ForegroundColor DarkGray
            }
        }
    }
    $sshPids = $sshPids | Select-Object -Unique

    if (-not $sshPids) {
        Write-Host "[Info] No tunnel running on ports $($script:HTTP_PORT) / $($script:SOCKS_PORT)" -ForegroundColor Yellow
        $global:SSH_TUNNEL_PID = $null
        return $true
    }

    foreach ($procId in $sshPids) {
        taskkill /PID $procId /T /F 2>$null | Out-Null
        Write-Host "[Kill] PID $procId (ssh)" -ForegroundColor DarkGray
    }
    Start-Sleep -Milliseconds 500

    # Only SSH survivors count as failure - foreign apps are none of our business.
    $survivors = @()
    foreach ($p in $ports) {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        foreach ($procId in @($c.OwningProcess | Select-Object -Unique)) {
            if ((Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName -match '^ssh') { $survivors += $p }
        }
    }
    $global:SSH_TUNNEL_PID = $null

    if ($survivors.Count -eq 0) {
        Write-Host "[OK] Tunnel stopped" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[Err] ssh still holds: $($survivors -join ', '). Inspect: Get-NetTCPConnection -LocalPort $($script:HTTP_PORT),$($script:SOCKS_PORT) | Select LocalPort,OwningProcess" -ForegroundColor Red
        return $false
    }
}

function cc-stop {
    $stopped = tunnel-stop
    Stop-NodeTunnels      # per-node Chrome tunnels (chrome-proxy <node>) go too
    proxy-off
    if ($stopped) {
        Write-Host "[OK] All proxy services stopped" -ForegroundColor Green
    } else {
        Write-Host "[Err] Env cleared, but the tunnel did NOT fully stop (see above). Run 'proxy-doctor'." -ForegroundColor Red
    }
}

# ============================================================
# Status check
# ============================================================

function proxy-status {
    Write-Host ""
    Write-Host "=== Proxy Status (claude-proxy v$($script:PROFILE_VERSION)) ===" -ForegroundColor Cyan
    Write-Host ""

    $health = Get-TunnelHealth
    switch ($health.Status) {
        'ok' {
            $note = ''
            if ($health.HttpPort -ne $script:HTTP_PORT) { $script:HTTP_PORT = $health.HttpPort; $note = ' [fallback port]' }
            Write-Host "[ON]  HTTP tunnel   : 127.0.0.1:$($script:HTTP_PORT) -> VM tinyproxy:$($script:REMOTE_PROXY_PORT) (Claude)$note" -ForegroundColor Green
            Write-Host "[ON]  SOCKS tunnel  : 127.0.0.1:$($script:SOCKS_PORT) (Chrome / apps)" -ForegroundColor Green
        }
        'down' {
            Write-Host "[OFF] HTTP tunnel   : not running" -ForegroundColor Red
            Write-Host "[OFF] SOCKS tunnel  : not running" -ForegroundColor Red
        }
        'stale' {
            Write-Host "[!!]  Tunnel BROKEN : stale ssh (PID $($health.OwnerPid)) - run 'cc' to auto-heal (or 'cc-stop')" -ForegroundColor Yellow
        }
        'foreign' {
            Write-Host "[!!]  No tunnel     : port $($script:HTTP_PORT) is used by '$($health.OwnerName)' (PID $($health.OwnerPid))" -ForegroundColor Red
            Write-Host "      Run 'cc' - it leaves that app alone and uses the next free port automatically." -ForegroundColor Yellow
        }
    }

    if ($env:HTTPS_PROXY) {
        Write-Host "[ON]  Env HTTPS_PROXY: $env:HTTPS_PROXY" -ForegroundColor Green
    } else {
        Write-Host "[OFF] Env HTTPS_PROXY: not set" -ForegroundColor Red
    }
    $an = Get-ActiveNodeName
    if ($an) { Write-Host "[..]  Node          : $an ($($script:SSH_HOST))  - 'proxy-node <name>' switches, 'proxy-nodes' lists  (settings: $($script:PROXY_CONF))" }
    else     { Write-Host "[..]  Server        : $($script:SSH_HOST)  (settings: $($script:PROXY_CONF))" }
    foreach ($t in Get-NodeTunnels) {
        Write-Host "[ON]  Chrome tunnel : $($t.Name) -> 127.0.0.1:$($t.Port) (PID $($t.Pid))" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Current external IP:" -ForegroundColor Cyan
    curl.exe -s --max-time 5 ipinfo.io
    Write-Host ""
}

# ============================================================
# Doctor - check every part and say exactly what's wrong + how to fix it
# ============================================================

function proxy-doctor {
    Write-Host ""
    Write-Host "=== Proxy Doctor (claude-proxy v$($script:PROFILE_VERSION)) ===" -ForegroundColor Cyan

    # --- profile + settings ---
    Write-Host "[ OK ]  Profile: $($script:PROFILE_PATH) (v$($script:PROFILE_VERSION)) - 'proxy-update -Check' to see if a newer one exists" -ForegroundColor Green
    $profRaw = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { '' }
    if ($profRaw -match '\.claude-proxy\.ps1') {
        Write-Host "[ OK ]  `$PROFILE loads it in every new window" -ForegroundColor Green
    } elseif ($profRaw -match '(?m)^\$script:(PROFILE_VERSION|SSH_HOST)\s*=') {
        Write-Host "[WARN] `$PROFILE still holds an OLD full copy of the profile - new windows load that, not $($script:PROFILE_PATH). Fix: proxy-update (or re-run the wizard)" -ForegroundColor Yellow
    } else {
        Write-Host "[WARN] `$PROFILE does not load $($script:PROFILE_PATH) - only this window has cc/cx. Fix: re-run the wizard, or use the 'Claude Proxy Shell' shortcut (proxy-shortcut)" -ForegroundColor Yellow
    }
    if (Test-Path $script:PROXY_CONF) {
        Write-Host "[ OK ]  Settings: $($script:PROXY_CONF) (server '$($script:SSH_HOST)', VM proxy port $($script:REMOTE_PROXY_PORT))" -ForegroundColor Green
    } else {
        Write-Host "[WARN] No $($script:PROXY_CONF) - using built-in defaults (server '$($script:SSH_HOST)'). Fix: proxy-config edit (or re-run the setup wizard)" -ForegroundColor Yellow
    }
    $sshCfg = Join-Path $HOME '.ssh\config'
    if ((Test-Path $sshCfg) -and (Select-String -Path $sshCfg -Pattern "^Host\s+$([regex]::Escape($script:SSH_HOST))(\s|$)" -Quiet)) {
        Write-Host "[ OK ]  ~/.ssh/config has an alias '$($script:SSH_HOST)'" -ForegroundColor Green
    } elseif (-not $script:SSH_USER) {
        Write-Host "[WARN] No 'Host $($script:SSH_HOST)' in ~/.ssh/config and SSH_USER is blank - ssh may not know how to reach it. Fix: re-run the setup wizard, or set SSH_USER/SSH_KEY (proxy-config edit)" -ForegroundColor Yellow
    }
    if (Test-Path $script:NODES_CACHE) {
        $nn = @(Get-ProxyNodes).Count; $an = Get-ActiveNodeName
        $anTxt = if ($an) { $an } else { "none - '$($script:SSH_HOST)' is not a catalogue node" }
        Write-Host "[ OK ]  Node catalogue: $($script:NODES_CACHE) ($nn nodes, active: $anTxt) - 'proxy-nodes -Refresh' updates it" -ForegroundColor Green
    } else {
        Write-Host "[WARN] No node catalogue ($($script:NODES_CACHE)) - only needed for 'proxy-node' / 'chrome-proxy <node>'. Fix: proxy-nodes -Refresh" -ForegroundColor Yellow
    }

    # --- tools ---
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        Write-Host "[ OK ]  codex installed - 'cx' available" -ForegroundColor Green
    } else {
        Write-Host "[WARN] codex NOT installed (optional) - 'cx' won't work. Fix: npm install -g @openai/codex" -ForegroundColor Yellow
    }

    # --- tunnel / ports ---
    # If the tunnel runs on a fallback port (configured one was busy), adopt it
    # so every check below looks at the right port.
    $health = Get-TunnelHealth
    if ($health.Status -eq 'ok' -and $health.HttpPort -ne $script:HTTP_PORT) {
        $script:HTTP_PORT = $health.HttpPort
        Write-Host "[ OK ]  Tunnel runs on fallback port $($health.HttpPort) (configured port was busy) - checks use it" -ForegroundColor Green
    }
    $httpConn  = Get-NetTCPConnection -LocalPort $script:HTTP_PORT  -State Listen -ErrorAction SilentlyContinue
    $socksConn = Get-NetTCPConnection -LocalPort $script:SOCKS_PORT -State Listen -ErrorAction SilentlyContinue
    $httpPids  = @($httpConn.OwningProcess  | Select-Object -Unique)
    $socksPids = @($socksConn.OwningProcess | Select-Object -Unique)

    if ($httpPids) {
        Write-Host "[ OK ]  HTTP forward  :$($script:HTTP_PORT) listening (PID $($httpPids -join ','))" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] HTTP forward  :$($script:HTTP_PORT) NOT listening - Claude has no proxy. Fix: tunnel-start (or cc)" -ForegroundColor Red
    }
    if ($socksPids) {
        Write-Host "[ OK ]  SOCKS forward :$($script:SOCKS_PORT) listening (PID $($socksPids -join ',')) - Chrome OK" -ForegroundColor Green
    } else {
        Write-Host "[WARN] SOCKS forward :$($script:SOCKS_PORT) NOT listening - chrome-proxy won't work. Fix: tunnel-start" -ForegroundColor Yellow
    }
    if ($httpPids -and $socksPids -and (Compare-Object $httpPids $socksPids)) {
        Write-Host "[WARN] Ports held by DIFFERENT PIDs - likely a stale process. Fix: run 'cc' (auto-heals stale ssh) or cc-stop" -ForegroundColor Yellow
    }
    if ($httpPids) {
        $ownerName = (Get-Process -Id $httpPids[0] -ErrorAction SilentlyContinue).ProcessName
        if ($ownerName -and $ownerName -notmatch '^ssh') {
            Write-Host "[FAIL] Port $($script:HTTP_PORT) is held by '$ownerName' (PID $($httpPids[0])) - NOT an ssh tunnel. Fix: run 'cc' - it uses the next free port automatically." -ForegroundColor Red
        }
    }
    if ($httpPids.Count -gt 1) {
        Write-Host "[WARN] Port $($script:HTTP_PORT) has MULTIPLE listeners ($($httpPids -join ',')) - stale process. Fix: cc-stop" -ForegroundColor Yellow
    }

    # --- shell env ---
    if ($env:HTTPS_PROXY) {
        Write-Host "[ OK ]  Env HTTPS_PROXY=$env:HTTPS_PROXY" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Env HTTPS_PROXY not set in THIS shell. Fix: proxy-on (or cc)" -ForegroundColor Yellow
    }

    # --- Claude settings.json (check it has an env block) ---
    $settings = $script:CLAUDE_SETTINGS
    if ($script:SYNC_SETTINGS -ne 1) {
        Write-Host "[ OK ]  settings.json sync disabled (SYNC_SETTINGS=0)" -ForegroundColor Green
    } elseif (-not (Test-Path $settings)) {
        Write-Host "[WARN] $settings does not exist yet (created on first proxy-on)" -ForegroundColor Yellow
    } else {
        try {
            $obj = Get-Content $settings -Raw | ConvertFrom-Json
            if ($null -eq $obj.env) {
                Write-Host "[WARN] $settings has no 'env' block yet - proxy-on will add it" -ForegroundColor Yellow
            } elseif ($obj.env.HTTPS_PROXY) {
                Write-Host "[ OK ]  settings.json env.HTTPS_PROXY=$($obj.env.HTTPS_PROXY)" -ForegroundColor Green
            } else {
                Write-Host "[WARN] settings.json has an 'env' block but no HTTPS_PROXY (proxy currently OFF in config)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[FAIL] $settings is INVALID JSON - sync is skipped. Fix by hand, or restore $settings.bak" -ForegroundColor Red
        }
    }

    # --- end-to-end: reach the API through the proxy ---
    if ($httpPids) {
        $code = curl.exe -s --max-time 8 -o NUL -w "%{http_code}" -x "http://127.0.0.1:$($script:HTTP_PORT)" https://api.anthropic.com/ 2>$null
        if ($code -and $code -ne "000") {
            Write-Host "[ OK ]  api.anthropic.com reachable through the proxy (HTTP $code)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Proxy up but can't reach api.anthropic.com (code $code). Check the VM's tinyproxy (webproxy-status)." -ForegroundColor Red
        }
    }
    Write-Host ""
}

# ============================================================
# Settings file: show / edit / set  (~\.claude-proxy.conf.psd1)
# ============================================================

# Write EVERY current setting to the conf file (regenerated each time, so the
# format stays valid). Used by the wizard-less first update and proxy-config.
function _conf-write-all {
    $lines = @(
        '@{',
        '    # ~\.claude-proxy.conf.psd1 - YOUR settings for the cc/cx profile.',
        "    # 'proxy-update' replaces the profile but never touches this file.",
        "    # Remove a line to fall back to the profile's built-in default."
    )
    foreach ($k in $script:CONF_KEYS) {
        $v = Get-Variable -Name $k -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($v -is [int]) { $lines += "    $k = $v" }
        else              { $lines += "    $k = '$("$v" -replace "'", "''")'" }
    }
    $lines += '}'
    Set-Content -Path $script:PROXY_CONF -Value $lines -Encoding ascii
}

function proxy-config {
    param([string]$Action = 'show', [string]$Key, [string]$Value)
    switch ($Action.ToLower()) {
        'show' {
            Write-Host ""
            Write-Host "=== claude-proxy settings (v$($script:PROFILE_VERSION)) ===" -ForegroundColor Cyan
            if (Test-Path $script:PROXY_CONF) { Write-Host "  file: $($script:PROXY_CONF)" }
            else { Write-Host "  file: $($script:PROXY_CONF)  (not created yet - built-in defaults in use)" -ForegroundColor Yellow }
            Write-Host ""
            foreach ($k in $script:CONF_KEYS) {
                $v = Get-Variable -Name $k -Scope Script -ValueOnly -ErrorAction SilentlyContinue
                Write-Host ("  {0,-18} = {1}" -f $k, $v)
            }
            Write-Host ("  {0,-18} = {1}" -f 'NO_PROXY_LIST', $script:NO_PROXY_LIST)
            Write-Host ""
            Write-Host "  proxy-config edit              open the file in Notepad" -ForegroundColor DarkGray
            Write-Host "  proxy-config set KEY VALUE     e.g. proxy-config set SSH_HOST myvm" -ForegroundColor DarkGray
            Write-Host "  proxy-config path              print the file path" -ForegroundColor DarkGray
            Write-Host ""
        }
        'path' { $script:PROXY_CONF }
        'edit' {
            if (-not (Test-Path $script:PROXY_CONF)) { _conf-write-all }
            Start-Process notepad.exe -ArgumentList "`"$($script:PROXY_CONF)`"" -Wait
            Write-Host "[OK] Saved. Load the new settings with:  . '$($script:PROFILE_PATH)'   (new windows pick them up automatically)" -ForegroundColor Green
        }
        'set' {
            if (-not $Key -or $null -eq $Value) {
                Write-Host "usage: proxy-config set KEY VALUE   (KEY = one of: $($script:CONF_KEYS -join ', '))" -ForegroundColor Yellow
                return
            }
            $k = $script:CONF_KEYS | Where-Object { $_ -ieq $Key } | Select-Object -First 1
            if (-not $k) {
                Write-Host "[Err] Unknown key '$Key'. Valid: $($script:CONF_KEYS -join ', ')" -ForegroundColor Red
                return
            }
            $v = if ($Value -match '^\d+$') { [int]$Value } else { $Value }
            Set-Variable -Name $k -Value $v -Scope Script
            _conf-write-all
            Write-Host "[OK] $k = $v saved to $($script:PROXY_CONF) and applied in this window." -ForegroundColor Green
        }
        default { Write-Host "usage: proxy-config [show|edit|set KEY VALUE|path]" -ForegroundColor Yellow }
    }
}

# ============================================================
# Self-update: fetch the latest profile, keep ~\.claude-proxy.conf.psd1
# ============================================================

function _fetch-file { param($Uri, $OutFile) Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile }

function proxy-update {
    param([switch]$Check, [switch]$Force)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'claude-proxy.ps1.new'
    Write-Host "[Update] Fetching latest profile from GitHub..." -ForegroundColor Cyan
    try {
        _fetch-file "$($script:REPO_RAW)/claude-proxy.ps1" $tmp
    } catch {
        Write-Host "[Err] Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       GitHub not reachable from here? Try 'proxy-up' first, then 'proxy-update' again." -ForegroundColor Yellow
        return
    }
    # Sanity: must be this profile and must parse, or we'd brick every new window.
    $raw  = Get-Content $tmp -Raw
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$null, [ref]$errs) | Out-Null
    if ($errs.Count -gt 0 -or $raw -notmatch '(?m)^\$script:PROFILE_VERSION\s*=') {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "[Err] Downloaded file doesn't look like a valid profile - nothing changed." -ForegroundColor Red
        return
    }
    $newver  = [regex]::Match($raw, "(?m)^\`$script:PROFILE_VERSION\s*=\s*'([^']*)'").Groups[1].Value
    $current = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { '' }
    if (-not $Force -and $current -eq $raw) {
        Remove-Item $tmp -Force
        Write-Host "[OK] Already up to date (v$($script:PROFILE_VERSION))" -ForegroundColor Green
        return
    }
    if ($Check) {
        Remove-Item $tmp -Force
        Write-Host "[Info] Update available: v$($script:PROFILE_VERSION) -> v$newver. Run 'proxy-update' to install it." -ForegroundColor Yellow
        return
    }
    # First update from an install that still had settings inside the profile:
    # snapshot them to the conf file so nothing has to be typed again.
    if (-not (Test-Path $script:PROXY_CONF)) {
        _conf-write-all
        Write-Host "[OK] Saved your current settings to $($script:PROXY_CONF) (they survive every future update)" -ForegroundColor Green
    }
    $dest = $script:PROFILE_PATH
    try {
        if (Test-Path $dest) { Copy-Item $dest "$dest.bak" -Force }
        Copy-Item $tmp $dest -Force
    } catch {
        Write-Host "[Err] Could not write $dest : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       The new version is saved at $tmp - copy it there by hand:  Copy-Item '$tmp' '$dest' -Force" -ForegroundColor Yellow
        return
    }
    Remove-Item $tmp -Force
    if ($env:OS -eq 'Windows_NT') { try { Unblock-File -Path $dest -ErrorAction SilentlyContinue } catch {} }
    Write-Host "[OK] Updated $dest : v$($script:PROFILE_VERSION) -> v$newver  (previous copy: $dest.bak)" -ForegroundColor Green
    # Make sure $PROFILE actually loads that file (older installs had the whole
    # profile INSIDE $PROFILE). Best effort - Documents may be locked.
    switch (_ensure-loader) {
        'ok'       { }
        'replaced' { Write-Host "[OK] `$PROFILE now just loads $dest (old copy kept at $PROFILE.bak)" -ForegroundColor Green }
        'added'    { Write-Host "[OK] Added the loader line to `$PROFILE" -ForegroundColor Green }
        'locked'   { Write-Host "[Warn] Could not edit `$PROFILE (locked Documents folder). New windows keep loading whatever is in it;" -ForegroundColor Yellow
                     Write-Host "       use the 'Claude Proxy Shell' shortcut (proxy-shortcut creates it) or run:  . '$dest'" -ForegroundColor Yellow }
    }
    Write-Host "[OK] Load it now with:  . '$dest'" -ForegroundColor Green
}

# Make $PROFILE load ~\.claude-proxy.ps1. Returns ok | added | replaced | locked.
#   - $PROFILE already has the loader line            -> ok
#   - $PROFILE IS an old full copy of this profile    -> back it up, replace with the loader
#   - anything else (user's own profile, or none)     -> append the loader
function _ensure-loader {
    try {
        $cur = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw } else { '' }
        if ($cur -match '\.claude-proxy\.ps1') { return 'ok' }
        $dir = Split-Path $PROFILE
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if ($cur -match '(?m)^\$script:(PROFILE_VERSION|SSH_HOST)\s*=') {
            Copy-Item -LiteralPath $PROFILE -Destination "$PROFILE.bak" -Force
            Set-Content -Path $PROFILE -Value $script:LOADER_LINE -Encoding ascii
            return 'replaced'
        }
        Add-Content -Path $PROFILE -Value "`r`n$($script:LOADER_LINE)" -Encoding ascii
        return 'added'
    } catch {
        return 'locked'
    }
}

# Desktop shortcut "Claude Proxy Shell": a PowerShell window that loads
# ~\.claude-proxy.ps1 without needing $PROFILE or a script execution policy
# (the profile is read with Invoke-Expression, which policies don't gate).
function proxy-shortcut {
    $lnkPath = '(Desktop)\Claude Proxy Shell.lnk'
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'Claude Proxy Shell.lnk'
        $exe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
        $ws  = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $exe
        $lnk.Arguments        = "-NoExit -ExecutionPolicy Bypass -Command `"Invoke-Expression (Get-Content -Raw '$($script:PROFILE_PATH)')`""
        $lnk.WorkingDirectory = $HOME
        $lnk.Description      = 'PowerShell with the cc / cx proxy commands loaded'
        $lnk.Save()
        Write-Host "[OK] Shortcut created: $lnkPath  - double-click it to get a window with cc / cx ready" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[Warn] Could not create the shortcut ($($_.Exception.Message)). Manual alternative - open PowerShell and run:" -ForegroundColor Yellow
        Write-Host "       Invoke-Expression (Get-Content -Raw '$($script:PROFILE_PATH)')" -ForegroundColor White
        return $false
    }
}

# ============================================================
# Launch Chrome through the SOCKS5 proxy (separate, isolated profile)
# ============================================================

# Chrome keys a RUNNING instance on its --user-data-dir, not on its flags: a
# second launch into the same dir just opens a window in the existing instance
# and silently ignores a different --proxy-server. So every node gets its own
# profile dir (<base>-<node>), which is also what keeps logins/cookies per region.
# The pre-2.1 dir (<base>) is renamed to the active node's dir once, so nobody
# loses their existing logins.
function Get-ChromeProfileDir { param([string]$Base, [string]$Name)
    if (-not $Name) { return $Base }
    $target = "$Base-$Name"
    if (-not (Test-Path $target) -and (Test-Path $Base) -and $Name -eq (Get-ActiveNodeName)) {
        try {
            Move-Item -LiteralPath $Base -Destination $target -ErrorAction Stop
            Write-Host "[Info] Chrome profile moved to $target (per-node profiles since v2.1) - your logins are kept" -ForegroundColor DarkGray
        } catch { return $Base }
    }
    return $target
}

# chrome-proxy [node] [url ...]
#   chrome-proxy            Chrome through the node cc/cx use (main tunnel; starts it if needed)
#   chrome-proxy sg         Chrome through node 'sg' on its OWN SOCKS tunnel + profile -
#                           the main tunnel and other nodes' windows are untouched
#   chrome-proxy sg URL     ...and open URL there (any non-node argument is passed to Chrome)
function chrome-proxy {
    # Locate Chrome first, so we don't start a tunnel only to find Chrome missing.
    $chrome = $null
    foreach ($c in @($script:CHROME_EXE,
                     "C:\Program Files\Google\Chrome\Application\chrome.exe",
                     "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                     $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe" }))) {
        if ($c -and (Test-Path $c)) { $chrome = $c; break }
    }
    if (-not $chrome) { Write-Host "[Err] Chrome not found - if it lives somewhere unusual: proxy-config set CHROME_EXE 'D:\path\to\chrome.exe'" -ForegroundColor Red; return }

    $node = $null; $extra = @()
    foreach ($a in $args) {
        $n = if ($null -eq $node) { Find-ProxyNode "$a" } else { $null }
        if ($n) { $node = $n } else { $extra += "$a" }
    }

    if ($node) {
        $name = $node.Name
        if ($node.Alias -eq $script:SSH_HOST -and (Get-TunnelHealth).Status -eq 'ok') {
            $port = $script:SOCKS_PORT; $label = "$name (main tunnel)"
            Write-Host "[OK]  $name is the active node and its tunnel is up - reusing it" -ForegroundColor DarkGreen
        } else {
            if (-not (Confirm-NodeAlias $node)) { return }
            $port = Get-NodeSocksPort $node.Idx
            if (-not (Start-NodeTunnel $node $port)) {
                Write-Host "[Err] $name tunnel could not be started - Chrome not launched. Try 'ssh $($node.Alias)' by hand to see why." -ForegroundColor Red
                return
            }
            $label = "$name (own tunnel)"
        }
    } else {
        # Main tunnel (the node cc/cx use). Ensure it's up; bail if it won't start.
        if (-not (Test-Port -Port $script:SOCKS_PORT)) {
            Write-Host "[Info] SSH tunnel (SOCKS port $($script:SOCKS_PORT)) not running - starting it..." -ForegroundColor Yellow
            tunnel-start
            if (-not (Test-Port -Port $script:SOCKS_PORT)) {
                Write-Host "[Err] SSH tunnel could not be started - Chrome not launched. Run 'proxy-doctor' to diagnose." -ForegroundColor Red
                return
            }
        } else {
            Write-Host "[OK]  SSH tunnel already running" -ForegroundColor DarkGreen
        }
        $port = $script:SOCKS_PORT
        $name = Get-ActiveNodeName
        $label = "$(if ($name) { $name } else { $script:SSH_HOST }) (main tunnel)"
    }

    $socks = "socks5://127.0.0.1:$port"
    $pdir  = Get-ChromeProfileDir "C:\ChromeVPNProfile" $name
    Write-Host "[Launch] Opening Chrome through $label - $socks, profile $pdir" -ForegroundColor Cyan
    # --host-resolver-rules routes DNS through the tunnel too (avoids DNS leaks).
    & $chrome --proxy-server="$socks" `
              --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" `
              --user-data-dir="$pdir" --no-first-run @extra
}

# ============================================================
# Help / command list
# ============================================================

function cc-help {
    Write-Host ""
    Write-Host "=== Claude / Codex + SSH Tunnel Quick Commands (claude-proxy v$($script:PROFILE_VERSION)) ===" -ForegroundColor DarkGray
    Write-Host "  cc              - Turn the proxy ON and launch Claude (skips permission prompts)" -ForegroundColor DarkGray
    Write-Host "  cc -c / cc -r   - Same, but continue the last session / pick one to resume" -ForegroundColor DarkGray
    Write-Host "  cc-safe         - Same as cc, but keeps Claude's permission prompts" -ForegroundColor DarkGray
    Write-Host "  cx              - Turn the proxy ON and launch Codex (skips approval prompts)" -ForegroundColor DarkGray
    Write-Host "  cx-safe         - Same, but keeps Codex's approval prompts" -ForegroundColor DarkGray
    Write-Host "                    (anything after cc/cx is passed to claude/codex as-is)" -ForegroundColor DarkGray
    Write-Host "  proxy-up        - Turn the proxy ON, but DON'T launch anything" -ForegroundColor DarkGray
    Write-Host "  cc-stop         - Turn the proxy OFF (one off-switch for cc AND cx)" -ForegroundColor DarkGray
    Write-Host "  proxy-status    - Show what's running + your external IP" -ForegroundColor DarkGray
    Write-Host "  proxy-doctor    - Diagnose each part and say exactly what's wrong + how to fix" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- nodes (jp / sg / us ...) --" -ForegroundColor DarkGray
    Write-Host "  proxy-nodes     - List the nodes (-Refresh: download the latest catalogue + create ssh aliases)" -ForegroundColor DarkGray
    Write-Host "  proxy-node sg   - Make 'sg' the node cc / cx use (also: cc --node sg, cx --node sg)" -ForegroundColor DarkGray
    Write-Host "  chrome-proxy sg - Chrome through 'sg' on its own tunnel + profile (jp and sg can be open together)" -ForegroundColor DarkGray
    Write-Host "" -ForegroundColor DarkGray
    Write-Host "  -- settings & updates --" -ForegroundColor DarkGray
    Write-Host "  proxy-config    - Show your settings (edit / set KEY VALUE) - stored in ~\.claude-proxy.conf.psd1" -ForegroundColor DarkGray
    Write-Host "  proxy-update    - Fetch the latest version of this profile; your settings are kept" -ForegroundColor DarkGray
    Write-Host "  proxy-shortcut  - Desktop shortcut that opens a window with cc/cx ready (no `$PROFILE needed)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- advanced: manage one piece at a time --" -ForegroundColor DarkGray
    Write-Host "  tunnel-start    - Start the SSH tunnel (HTTP forward for Claude + SOCKS5 for Chrome)" -ForegroundColor DarkGray
    Write-Host "  tunnel-stop     - Stop the SSH tunnel" -ForegroundColor DarkGray
    Write-Host "  proxy-on        - Set proxy env vars + sync Claude settings.json" -ForegroundColor DarkGray
    Write-Host "  proxy-off       - Clear proxy env vars + unsync Claude settings.json" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  chrome-proxy    - Open Chrome via SOCKS5 through the active node (auto-starts the tunnel, separate profile)" -ForegroundColor DarkGray
    Write-Host "                    chrome-proxy [node] [url]  - e.g. chrome-proxy us https://example.com" -ForegroundColor DarkGray
    Write-Host "  cc-help         - Show this list again" -ForegroundColor DarkGray
    Write-Host ""
}

# One line when a new window loads this profile. Silence it with BANNER = 0 in
# ~\.claude-proxy.conf.psd1.
if ($script:BANNER -eq 1) {
    $bn = Get-ActiveNodeName
    Write-Host "claude-proxy v$($script:PROFILE_VERSION) ready (node: $(if ($bn) { "$bn / " })$($script:SSH_HOST)) - 'cc' launches Claude, 'cc-help' lists all commands" -ForegroundColor DarkGray
}
