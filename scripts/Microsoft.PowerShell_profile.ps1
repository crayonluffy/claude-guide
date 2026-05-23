# ============================================================
# PowerShell Profile - SSH Tunnel + HTTP Proxy + Claude
# ============================================================
# Workflow:
#   1. SSH tunnel  : Creates SOCKS5 proxy on 127.0.0.1:1080
#   2. HTTP bridge : Converts to HTTP proxy on 127.0.0.1:8080
#   3. Claude      : Uses HTTP proxy
# ============================================================

# ============================================================
# Settings - EDIT THESE
# ============================================================
# If you ran the "Step 1" setup, you already have an ~/.ssh/config alias -
# just point SSH_HOST at it and leave SSH_USER / SSH_KEY blank.
$script:SSH_HOST    = "jpvpn"   # an ~/.ssh/config alias, OR a raw host/IP
$script:SSH_USER    = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_KEY     = ""        # leave blank when SSH_HOST is a config alias
$script:SSH_PORT    = 22
$script:SOCKS_PORT  = 1080
$script:HTTP_PORT   = 8080

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

# ============================================================
# 1. Start SSH tunnel (background)
# ============================================================

function tunnel-start {
    if (Test-Port -Port $script:SOCKS_PORT) {
        Write-Host "[Info] Port $($script:SOCKS_PORT) already in use - tunnel may already be running" -ForegroundColor Yellow
        return
    }

    Write-Host "[SSH] Starting tunnel to $($script:SSH_HOST)..." -ForegroundColor Cyan

    $sshArgs = @(
        "-D", $script:SOCKS_PORT,
        "-N",
        "-C",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes"
    )
    # Explicit key/port/user are optional - leave SSH_KEY/SSH_USER blank to use an ~/.ssh/config alias
    if ($script:SSH_KEY)  { $sshArgs += @("-i", $script:SSH_KEY, "-p", "$($script:SSH_PORT)") }
    if ($script:SSH_USER) { $sshArgs += "$($script:SSH_USER)@$($script:SSH_HOST)" }
    else                  { $sshArgs += $script:SSH_HOST }

    $proc = Start-Process -FilePath "ssh" -ArgumentList $sshArgs -PassThru -WindowStyle Hidden
    $global:SSH_TUNNEL_PID = $proc.Id

    # Wait for tunnel to be ready
    $attempts = 0
    while (-not (Test-Port -Port $script:SOCKS_PORT) -and $attempts -lt 10) {
        Start-Sleep -Milliseconds 500
        $attempts++
    }

    if (Test-Port -Port $script:SOCKS_PORT) {
        Write-Host "[OK]  SSH tunnel up on 127.0.0.1:$($script:SOCKS_PORT) (PID: $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "[Err] SSH tunnel failed to start within 5s" -ForegroundColor Red
    }
}

# ============================================================
# 2. Start HTTP-to-SOCKS bridge (background)
# ============================================================

function bridge-start {
    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[Info] Port $($script:HTTP_PORT) already in use - bridge may already be running" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Port -Port $script:SOCKS_PORT)) {
        Write-Host "[Err] SOCKS port $($script:SOCKS_PORT) not active - run 'tunnel-start' first" -ForegroundColor Red
        return
    }

    Write-Host "[HTTP] Starting bridge on 127.0.0.1:$($script:HTTP_PORT)..." -ForegroundColor Cyan

    $bridgeArgs = @(
        "http-proxy-to-socks",
        "-p", $script:HTTP_PORT,
        "-s", "127.0.0.1:$($script:SOCKS_PORT)"
    )

    $proc = Start-Process -FilePath "npx" -ArgumentList $bridgeArgs -PassThru -WindowStyle Hidden
    $global:HTTP_BRIDGE_PID = $proc.Id

    # Wait for bridge to be ready
    $attempts = 0
    while (-not (Test-Port -Port $script:HTTP_PORT) -and $attempts -lt 10) {
        Start-Sleep -Milliseconds 500
        $attempts++
    }

    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[OK]  HTTP bridge up on 127.0.0.1:$($script:HTTP_PORT) (PID: $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "[Err] HTTP bridge failed to start within 5s" -ForegroundColor Red
    }
}

# ============================================================
# 3. Set proxy env vars
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
}

function proxy-off {
    $env:http_proxy = $null
    $env:HTTP_PROXY = $null
    $env:https_proxy = $null
    $env:HTTPS_PROXY = $null
    $env:no_proxy = $null
    $env:NO_PROXY = $null
    Write-Host "[OK] Env vars cleared" -ForegroundColor Green
}

# ============================================================
# All-in-one: tunnel + bridge + env vars + launch Claude
# ============================================================

function cc {
    param([switch]$Safe, [switch]$NoVerify)

    # Step 1: SSH tunnel
    if (-not (Test-Port -Port $script:SOCKS_PORT)) {
        tunnel-start
        if (-not (Test-Port -Port $script:SOCKS_PORT)) { return }
    } else {
        Write-Host "[OK]  SSH tunnel already running" -ForegroundColor DarkGreen
    }

    # Step 2: HTTP bridge
    if (-not (Test-Port -Port $script:HTTP_PORT)) {
        bridge-start
        if (-not (Test-Port -Port $script:HTTP_PORT)) { return }
    } else {
        Write-Host "[OK]  HTTP bridge already running" -ForegroundColor DarkGreen
    }

    # Step 3: Env vars
    proxy-on

    # Step 4: Verify
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

    # Step 5: Launch Claude
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
    if ($global:SSH_TUNNEL_PID) {
        Stop-Process -Id $global:SSH_TUNNEL_PID -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] SSH tunnel stopped (PID: $global:SSH_TUNNEL_PID)" -ForegroundColor Green
        $global:SSH_TUNNEL_PID = $null
    } else {
        # Try to find any ssh process listening on SOCKS_PORT
        $conn = Get-NetTCPConnection -LocalPort $script:SOCKS_PORT -ErrorAction SilentlyContinue
        if ($conn) {
            Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Killed process on port $($script:SOCKS_PORT)" -ForegroundColor Green
        } else {
            Write-Host "[Info] No SSH tunnel running" -ForegroundColor Yellow
        }
    }
}

function bridge-stop {
    if ($global:HTTP_BRIDGE_PID) {
        Stop-Process -Id $global:HTTP_BRIDGE_PID -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] HTTP bridge stopped (PID: $global:HTTP_BRIDGE_PID)" -ForegroundColor Green
        $global:HTTP_BRIDGE_PID = $null
    } else {
        $conn = Get-NetTCPConnection -LocalPort $script:HTTP_PORT -ErrorAction SilentlyContinue
        if ($conn) {
            Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Killed process on port $($script:HTTP_PORT)" -ForegroundColor Green
        } else {
            Write-Host "[Info] No HTTP bridge running" -ForegroundColor Yellow
        }
    }
}

function cc-stop {
    bridge-stop
    tunnel-stop
    proxy-off
    Write-Host "[OK] All proxy services stopped" -ForegroundColor Green
}

# ============================================================
# Status check
# ============================================================

function proxy-status {
    Write-Host ""
    Write-Host "=== Proxy Status ===" -ForegroundColor Cyan
    Write-Host ""

    # SSH tunnel
    if (Test-Port -Port $script:SOCKS_PORT) {
        Write-Host "[ON]  SSH tunnel    : 127.0.0.1:$($script:SOCKS_PORT) (SOCKS5)" -ForegroundColor Green
    } else {
        Write-Host "[OFF] SSH tunnel    : not running" -ForegroundColor Red
    }

    # HTTP bridge
    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[ON]  HTTP bridge   : 127.0.0.1:$($script:HTTP_PORT) (HTTP)" -ForegroundColor Green
    } else {
        Write-Host "[OFF] HTTP bridge   : not running" -ForegroundColor Red
    }

    # Env vars
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
# Welcome banner
# ============================================================

Write-Host ""
Write-Host "=== Claude + SSH Tunnel Quick Commands ===" -ForegroundColor DarkGray
Write-Host "  cc              - Tunnel + bridge + launch Claude (skip permissions)" -ForegroundColor DarkGray
Write-Host "  cc-safe         - Same but normal mode" -ForegroundColor DarkGray
Write-Host "  cc-stop         - Stop everything" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  tunnel-start    - Start SSH tunnel only" -ForegroundColor DarkGray
Write-Host "  tunnel-stop     - Stop SSH tunnel" -ForegroundColor DarkGray
Write-Host "  bridge-start    - Start HTTP bridge only" -ForegroundColor DarkGray
Write-Host "  bridge-stop     - Stop HTTP bridge" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  proxy-on        - Set env vars (HTTPS_PROXY etc.)" -ForegroundColor DarkGray
Write-Host "  proxy-off       - Clear env vars" -ForegroundColor DarkGray
Write-Host "  proxy-status    - Show full status" -ForegroundColor DarkGray
Write-Host ""
