# ============================================================
# PowerShell Profile - SSH Tunnel (local forward) + HTTP Proxy + Claude
# ============================================================
# Traffic flow:
#   claude --HTTPS_PROXY--> 127.0.0.1:8080 --ssh -L--> VM tinyproxy:8888 --> API
#
# The VM runs an HTTP proxy bound to loopback (see the webproxy-manager tool:
# https://github.com/crayonluffy/forge/tree/main/webproxy-manager). This profile
# just forwards a local port to it with `ssh -L`. No SOCKS, no http-proxy-to-socks
# bridge, no Node dependency for the proxy.
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
$script:HTTP_PORT         = 8080       # local port -> forwarded to the VM's proxy
$script:REMOTE_PROXY_PORT = 8888       # tinyproxy port on the VM (webproxy-manager)

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
# 1. Start SSH tunnel (local forward to the VM's HTTP proxy)
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

    # Wait for the forwarded port to come up
    $attempts = 0
    while (-not (Test-Port -Port $script:HTTP_PORT) -and $attempts -lt 10) {
        Start-Sleep -Milliseconds 500
        $attempts++
    }

    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[OK]  SSH tunnel up: 127.0.0.1:$($script:HTTP_PORT) -> VM tinyproxy:$($script:REMOTE_PROXY_PORT) (PID: $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "[Err] SSH tunnel failed to start within 5s" -ForegroundColor Red
        Write-Host "      Accept the host key once with 'ssh $($script:SSH_HOST)', then retry." -ForegroundColor DarkGray
    }
}

# Back-compat stubs: the separate HTTP bridge is gone - the VM runs the proxy now,
# and 'tunnel-start' forwards straight to it.
function bridge-start { Write-Host "[Info] No bridge needed anymore - the VM runs the HTTP proxy; 'tunnel-start' forwards straight to it." -ForegroundColor Yellow }
function bridge-stop  { Write-Host "[Info] No bridge to stop - the VM runs the HTTP proxy now. Use 'tunnel-stop'." -ForegroundColor Yellow }

# ============================================================
# 2. Set proxy env vars
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
# Bring the proxy stack up: tunnel + env vars + verify
# (everything 'cc' does EXCEPT launching Claude)
# ============================================================

function proxy-up {
    param([switch]$NoVerify)

    # Step 1: SSH tunnel (local forward)
    if (-not (Test-Port -Port $script:HTTP_PORT)) {
        tunnel-start
        if (-not (Test-Port -Port $script:HTTP_PORT)) { return $false }
    } else {
        Write-Host "[OK]  SSH tunnel already running" -ForegroundColor DarkGreen
    }

    # Step 2: Env vars
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
    if ($global:SSH_TUNNEL_PID) {
        Stop-Process -Id $global:SSH_TUNNEL_PID -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] SSH tunnel stopped (PID: $global:SSH_TUNNEL_PID)" -ForegroundColor Green
        $global:SSH_TUNNEL_PID = $null
    } else {
        # Try to find any ssh process listening on HTTP_PORT
        $conn = Get-NetTCPConnection -LocalPort $script:HTTP_PORT -ErrorAction SilentlyContinue
        if ($conn) {
            Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Killed process on port $($script:HTTP_PORT)" -ForegroundColor Green
        } else {
            Write-Host "[Info] No SSH tunnel running" -ForegroundColor Yellow
        }
    }
}

function cc-stop {
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

    # SSH tunnel (local forward)
    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[ON]  SSH tunnel    : 127.0.0.1:$($script:HTTP_PORT) -> VM tinyproxy:$($script:REMOTE_PROXY_PORT)" -ForegroundColor Green
    } else {
        Write-Host "[OFF] SSH tunnel    : not running" -ForegroundColor Red
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
# Launch Chrome through the proxy (separate, isolated profile)
# ============================================================

function chrome-proxy {
    # Locate Chrome first, so we don't start the tunnel only to find Chrome missing.
    $chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chrome)) { $chrome = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" }
    if (-not (Test-Path $chrome)) { Write-Host "[Err] Chrome not found" -ForegroundColor Red; return }

    # Chrome routes through the HTTP proxy, which the SSH tunnel exposes. Auto-start
    # the tunnel if it's down (same as 'cc' step 1); bail if it still won't come up.
    if (-not (Test-Port -Port $script:HTTP_PORT)) {
        Write-Host "[Info] SSH tunnel (port $($script:HTTP_PORT)) not running - starting it..." -ForegroundColor Yellow
        tunnel-start
        if (-not (Test-Port -Port $script:HTTP_PORT)) {
            Write-Host "[Err] SSH tunnel could not be started - Chrome not launched. Run 'cc' to diagnose." -ForegroundColor Red
            return
        }
    } else {
        Write-Host "[OK]  SSH tunnel already running" -ForegroundColor DarkGreen
    }

    $url = "http://127.0.0.1:$($script:HTTP_PORT)"
    Write-Host "[Launch] Opening Chrome via $url (separate profile)..." -ForegroundColor Cyan
    & $chrome --proxy-server="$url" --user-data-dir="C:\ChromeVPNProfile" --no-first-run
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
    Write-Host "  cc-stop         - Turn the proxy OFF (stop everything)" -ForegroundColor DarkGray
    Write-Host "  proxy-status    - Show what's running + your external IP" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- advanced: manage one piece at a time --" -ForegroundColor DarkGray
    Write-Host "  tunnel-start    - Start the SSH tunnel (local forward to the VM proxy)" -ForegroundColor DarkGray
    Write-Host "  tunnel-stop     - Stop the SSH tunnel" -ForegroundColor DarkGray
    Write-Host "  proxy-on        - Set the proxy env vars only" -ForegroundColor DarkGray
    Write-Host "  proxy-off       - Clear the proxy env vars only" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  chrome-proxy    - Open Chrome via the proxy (auto-starts the tunnel, separate profile)" -ForegroundColor DarkGray
    Write-Host "  cc-help         - Show this list again" -ForegroundColor DarkGray
    Write-Host ""
}

# Show the available commands when this profile loads
cc-help
