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

    # npx ships with Node.js. Bail early with a clear message if it is missing,
    # rather than letting cmd.exe fail with a cryptic "'npx' is not recognized".
    if (-not (Get-Command npx     -ErrorAction SilentlyContinue) -and
        -not (Get-Command npx.cmd -ErrorAction SilentlyContinue)) {
        Write-Host "[Err] npx not found on PATH - install Node.js from https://nodejs.org/" -ForegroundColor Red
        return
    }

    # Two separate log files: Start-Process refuses to send stdout and stderr to
    # the SAME path. Without a log, npx fails inside a hidden window and you only
    # ever see "failed to start" with no reason - which is the whole mystery here.
    $script:BRIDGE_OUT_LOG = Join-Path $env:TEMP "claude-bridge.out.log"
    $script:BRIDGE_ERR_LOG = Join-Path $env:TEMP "claude-bridge.err.log"

    # Launch npx *through* cmd.exe instead of calling npx.cmd directly:
    #   * cmd.exe is a real .exe, so UseShellExecute=$false (required to redirect
    #     output) is happy - you cannot CreateProcess a .cmd batch file directly.
    #   * cmd's PATHEXT resolves the right "npx.cmd"; calling the extensionless
    #     bash-shim "npx" via ShellExecute throws "system cannot find all the
    #     information required".
    # "npx http-proxy-to-socks" is correct: npx auto-runs the package's single
    # bin ("hpts"). --yes skips the first-run install prompt (no stdin to answer
    # it). None of the args contain spaces, so no extra quoting is needed.
    $bridgeArgs = @(
        "/c", "npx", "--yes", "http-proxy-to-socks",
        "-p", "$($script:HTTP_PORT)",
        "-s", "127.0.0.1:$($script:SOCKS_PORT)"
    )

    # -NoNewWindow (not -WindowStyle Hidden) so the redirect params are allowed
    # and no console pops up. -PassThru returns the cmd.exe wrapper pid;
    # bridge-stop's "taskkill /T" walks down to the real node child.
    try {
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList $bridgeArgs `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $script:BRIDGE_OUT_LOG `
            -RedirectStandardError  $script:BRIDGE_ERR_LOG -ErrorAction Stop
    } catch {
        Write-Host "[Err] Failed to launch HTTP bridge via npx: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    if (-not $proc) {
        Write-Host "[Err] HTTP bridge process did not start" -ForegroundColor Red
        return
    }
    $global:HTTP_BRIDGE_PID = $proc.Id

    # The FIRST run downloads the package, which can take well over 5s - the old
    # timeout cried failure while npx was still working. Wait up to 30s.
    $attempts = 0
    while (-not (Test-Port -Port $script:HTTP_PORT) -and $attempts -lt 60) {
        Start-Sleep -Milliseconds 500
        $attempts++
    }

    if (Test-Port -Port $script:HTTP_PORT) {
        Write-Host "[OK]  HTTP bridge up on 127.0.0.1:$($script:HTTP_PORT) (PID: $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "[Err] HTTP bridge failed to start within 30s. npx said:" -ForegroundColor Red
        foreach ($f in @($script:BRIDGE_ERR_LOG, $script:BRIDGE_OUT_LOG)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
                Get-Content $f -Tail 15 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            }
        }
        Write-Host "      (full logs: $script:BRIDGE_OUT_LOG , $script:BRIDGE_ERR_LOG)" -ForegroundColor DarkGray
        Write-Host "      Common cause: your direct network blocks the npm registry, so the" -ForegroundColor DarkGray
        Write-Host "      package can't download. Run 'npx --yes http-proxy-to-socks -p $($script:HTTP_PORT) -s 127.0.0.1:$($script:SOCKS_PORT)'" -ForegroundColor DarkGray
        Write-Host "      once in a normal window to see the real error / cache the package." -ForegroundColor DarkGray
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
    $killed = $false

    # Start-Process returns the npx.cmd WRAPPER pid; the real listener is its node
    # child. Kill the whole tree (/T) or the child is orphaned and keeps port 8080.
    if ($global:HTTP_BRIDGE_PID) {
        taskkill /PID $global:HTTP_BRIDGE_PID /T /F 2>$null | Out-Null
        $global:HTTP_BRIDGE_PID = $null
        $killed = $true
    }

    # Belt and suspenders: free the port even if the pid was stale, untracked,
    # or the tree-kill missed a re-parented child.
    $conn = Get-NetTCPConnection -LocalPort $script:HTTP_PORT -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        $conn.OwningProcess | Select-Object -Unique | ForEach-Object { taskkill /PID $_ /T /F 2>$null | Out-Null }
        $killed = $true
    }

    if ($killed) {
        Write-Host "[OK] HTTP bridge stopped (port $($script:HTTP_PORT) released)" -ForegroundColor Green
    } else {
        Write-Host "[Info] No HTTP bridge running" -ForegroundColor Yellow
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
# Launch Chrome through the proxy (separate, isolated profile)
# ============================================================

function chrome-proxy {
    $chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chrome)) { $chrome = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" }
    if (-not (Test-Path $chrome)) { Write-Host "[Err] Chrome not found" -ForegroundColor Red; return }
    if (-not (Test-Port -Port $script:SOCKS_PORT)) {
        Write-Host "[Warn] SSH tunnel (port $($script:SOCKS_PORT)) not running - run 'cc' first." -ForegroundColor Yellow
    }
    & $chrome --proxy-server="socks5://127.0.0.1:$($script:SOCKS_PORT)" --user-data-dir="C:\ChromeVPNProfile" --no-first-run
}

# ============================================================
# Help / command list
# ============================================================

function cc-help {
    Write-Host ""
    Write-Host "=== Claude + SSH Tunnel Quick Commands ===" -ForegroundColor DarkGray
    Write-Host "  cc              - Tunnel + bridge + launch Claude (skip permissions)" -ForegroundColor DarkGray
    Write-Host "  cc-safe         - Same but keeps permission prompts" -ForegroundColor DarkGray
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
    Write-Host "  chrome-proxy    - Open Chrome via the proxy (separate profile)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  cc-help         - Show this list again" -ForegroundColor DarkGray
    Write-Host ""
}

# Show the available commands when this profile loads
cc-help
