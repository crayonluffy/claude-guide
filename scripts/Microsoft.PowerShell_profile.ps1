# ============================================================
# PowerShell Profile - SSH Tunnel + HTTP proxy (Claude) + SOCKS5 (Chrome)
# ============================================================
# One SSH connection carries two forwards:
#   -L 8080:127.0.0.1:8888  ->  VM's HTTP proxy (tinyproxy)  ->  used by Claude (HTTPS_PROXY)
#   -D 1080                 ->  SOCKS5 on the VM              ->  used by Chrome / other apps
#
# Claude Code only speaks HTTP proxies, so it uses the -L forward to the VM's HTTP
# proxy (see webproxy-manager: https://github.com/crayonluffy/forge/tree/main/webproxy-manager).
# Chrome is happier on SOCKS5 (full traffic, remote DNS), so it uses the -D forward.
# ============================================================

# ============================================================
# Settings - EDIT THESE
# ============================================================
# If you ran the "Step 1" setup, you already have an ~/.ssh/config alias -
# just point SSH_HOST at it and leave SSH_USER / SSH_KEY blank.
$script:SSH_HOST          = "jpvpn"   # an ~/.ssh/config alias, OR a raw host/IP
$script:SSH_USER          = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_KEY           = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_PORT          = 22
$script:HTTP_PORT         = 8080       # local HTTP port -> forwarded to the VM proxy (Claude)
$script:REMOTE_PROXY_PORT = 8888       # tinyproxy port on the VM (webproxy-manager)
$script:SOCKS_PORT        = 1080       # local SOCKS5 port (Chrome / other apps)

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
    # Add your company intranet ranges / domains here, e.g.:
    # , "172.20.0.0/24", "*.mycorp.example"
) -join ","

# ============================================================
# Helper: Check if a port is in use
# ============================================================

function Test-Port {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    return ($null -ne $conn)
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
# 1. Start SSH tunnel: -L (HTTP for Claude) + -D (SOCKS5 for Chrome)
# ============================================================

function tunnel-start {
    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[Info] Port $($script:HTTP_PORT) already in use - tunnel may already be running" -ForegroundColor Yellow
        return
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
    param([switch]$NoVerify)

    # Step 1: SSH tunnel (HTTP + SOCKS forwards)
    if (-not (Test-Port -Port $script:HTTP_PORT)) {
        tunnel-start
        if (-not (Test-Port -Port $script:HTTP_PORT)) { return $false }
    } else {
        Write-Host "[OK]  SSH tunnel already running" -ForegroundColor DarkGreen
    }

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

    Write-Host "[OK]  Proxy ready in this shell - run 'claude' yourself, or 'cc-stop' to tear it down." -ForegroundColor Green
    return $true
}

# ============================================================
# All-in-one: proxy stack + launch Claude
# ============================================================

function cc {
    param([switch]$Safe, [switch]$NoVerify)

    # Steps 1-3: bring up tunnel + env vars + verify
    if (-not (proxy-up -NoVerify:$NoVerify)) { return }

    # Step 4: Launch Claude
    Write-Host "[Launch] Starting Claude..." -ForegroundColor Cyan
    Write-Host ""

    if ($Safe) {
        claude
    } else {
        claude --dangerously-skip-permissions
    }
}

function cc-safe { cc -Safe }

# ============================================================
# Stop everything
# ============================================================

function tunnel-stop {
    # Kill EVERY process listening on either forwarded port - not just the one we
    # tracked - then verify the ports actually freed and report survivors. Returns
    # $true only if both ports are clear.
    $ports = @($script:HTTP_PORT, $script:SOCKS_PORT)
    $procIds = @()
    foreach ($p in $ports) {
        $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($c) { $procIds += ($c.OwningProcess | Select-Object -Unique) }
    }
    $procIds = $procIds | Select-Object -Unique

    if (-not $procIds) {
        Write-Host "[Info] No tunnel running - ports $($script:HTTP_PORT) / $($script:SOCKS_PORT) are already free" -ForegroundColor Yellow
        $global:SSH_TUNNEL_PID = $null
        return $true
    }

    foreach ($procId in $procIds) {
        $name = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
        taskkill /PID $procId /T /F 2>$null | Out-Null
        Write-Host "[Kill] PID $procId ($name)" -ForegroundColor DarkGray
    }
    Start-Sleep -Milliseconds 500

    $survivors = @()
    foreach ($p in $ports) {
        if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $survivors += $p }
    }
    $global:SSH_TUNNEL_PID = $null

    if ($survivors.Count -eq 0) {
        Write-Host "[OK] Tunnel stopped - ports $($script:HTTP_PORT) and $($script:SOCKS_PORT) freed" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[Err] Still held: $($survivors -join ', '). Inspect: Get-NetTCPConnection -LocalPort $($script:HTTP_PORT),$($script:SOCKS_PORT) | Select LocalPort,OwningProcess" -ForegroundColor Red
        return $false
    }
}

function cc-stop {
    $stopped = tunnel-stop
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
    Write-Host "=== Proxy Status ===" -ForegroundColor Cyan
    Write-Host ""

    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[ON]  HTTP tunnel   : 127.0.0.1:$($script:HTTP_PORT) -> VM tinyproxy:$($script:REMOTE_PROXY_PORT) (Claude)" -ForegroundColor Green
    } else {
        Write-Host "[OFF] HTTP tunnel   : not running" -ForegroundColor Red
    }

    if (Test-Port -Port $script:SOCKS_PORT) {
        Write-Host "[ON]  SOCKS tunnel  : 127.0.0.1:$($script:SOCKS_PORT) (Chrome / apps)" -ForegroundColor Green
    } else {
        Write-Host "[OFF] SOCKS tunnel  : not running" -ForegroundColor Red
    }

    if ($env:HTTPS_PROXY) {
        Write-Host "[ON]  Env HTTPS_PROXY: $env:HTTPS_PROXY" -ForegroundColor Green
    } else {
        Write-Host "[OFF] Env HTTPS_PROXY: not set" -ForegroundColor Red
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
    Write-Host "=== Proxy Doctor ===" -ForegroundColor Cyan

    # --- tunnel / ports ---
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
        Write-Host "[WARN] Ports held by DIFFERENT PIDs - likely a stale process. Fix: cc-stop, then cc" -ForegroundColor Yellow
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
# Launch Chrome through the SOCKS5 proxy (separate, isolated profile)
# ============================================================

function chrome-proxy {
    # Locate Chrome first, so we don't start the tunnel only to find Chrome missing.
    $chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chrome)) { $chrome = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" }
    if (-not (Test-Path $chrome)) { Write-Host "[Err] Chrome not found" -ForegroundColor Red; return }

    # Chrome routes through the SOCKS5 forward, which the SSH tunnel provides.
    # Auto-start the tunnel if it's down; bail if it still won't come up.
    if (-not (Test-Port -Port $script:SOCKS_PORT)) {
        Write-Host "[Info] SSH tunnel (SOCKS port $($script:SOCKS_PORT)) not running - starting it..." -ForegroundColor Yellow
        tunnel-start
        if (-not (Test-Port -Port $script:SOCKS_PORT)) {
            Write-Host "[Err] SSH tunnel could not be started - Chrome not launched. Run 'cc' to diagnose." -ForegroundColor Red
            return
        }
    } else {
        Write-Host "[OK]  SSH tunnel already running" -ForegroundColor DarkGreen
    }

    $socks = "socks5://127.0.0.1:$($script:SOCKS_PORT)"
    Write-Host "[Launch] Opening Chrome via $socks (separate profile)..." -ForegroundColor Cyan
    # --host-resolver-rules routes DNS through the tunnel too (avoids DNS leaks).
    & $chrome --proxy-server="$socks" `
              --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" `
              --user-data-dir="C:\ChromeVPNProfile" --no-first-run
}

# ============================================================
# Help / command list
# ============================================================

function cc-help {
    Write-Host ""
    Write-Host "=== Claude + SSH Tunnel Quick Commands ===" -ForegroundColor DarkGray
    Write-Host "  cc              - Turn the proxy ON and launch Claude (skips permission prompts)" -ForegroundColor DarkGray
    Write-Host "  cc-safe         - Same, but keeps Claude's permission prompts" -ForegroundColor DarkGray
    Write-Host "  proxy-up        - Turn the proxy ON, but DON'T launch Claude" -ForegroundColor DarkGray
    Write-Host "  cc-stop         - Turn the proxy OFF (stop everything, reports what it freed)" -ForegroundColor DarkGray
    Write-Host "  proxy-status    - Show what's running + your external IP" -ForegroundColor DarkGray
    Write-Host "  proxy-doctor    - Diagnose each part and say exactly what's wrong + how to fix" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- advanced: manage one piece at a time --" -ForegroundColor DarkGray
    Write-Host "  tunnel-start    - Start the SSH tunnel (HTTP forward for Claude + SOCKS5 for Chrome)" -ForegroundColor DarkGray
    Write-Host "  tunnel-stop     - Stop the SSH tunnel" -ForegroundColor DarkGray
    Write-Host "  proxy-on        - Set proxy env vars + sync Claude settings.json" -ForegroundColor DarkGray
    Write-Host "  proxy-off       - Clear proxy env vars + unsync Claude settings.json" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  chrome-proxy    - Open Chrome via SOCKS5 (auto-starts the tunnel, separate profile)" -ForegroundColor DarkGray
    Write-Host "  cc-help         - Show this list again" -ForegroundColor DarkGray
    Write-Host ""
}

# Show the available commands when this profile loads
cc-help
