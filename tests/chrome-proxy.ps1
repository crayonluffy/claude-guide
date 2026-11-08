# Run with: pwsh -NoProfile -File tests/chrome-proxy.ps1
# Exercise the real node parser/launcher without opening Chrome or SSH.
param([string]$ProfilePath = (Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'))
$ErrorActionPreference = 'Stop'
$source = $ProfilePath
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$wanted = @('Get-ProxyNodes', 'Find-ProxyNode', 'Get-ActiveNodeName', 'Get-NodeSocksPort', 'Get-NodeSlot', 'Test-NodeProvisioned', 'Get-NodeContext', 'Get-ProxyNodePorts', 'Test-ProxyNodePortValue', 'Test-RecoverySharedProxy', 'Get-NodeLocalSlot', 'Test-SshAlias', 'chrome-proxy', 'Get-ChromeLeakFlags', 'Get-ChromeDirectRules', 'Get-ProxyExitInfo', 'Invoke-WithAppEnv')
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($f.Name -in $wanted) { Invoke-Expression $f.Extent.Text }
}
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Test-Path {
    if ($args[0] -eq 'chrome-proxy-test-browser') { return $true }
    Microsoft.PowerShell.Management\Test-Path @args
}
function chrome-proxy-test-browser { $script:ChromeArgs = @($args) }
function Get-ChromeProfileDir { param($Base, $Name) return "$Base-$Name" }
function Get-TunnelHealth { return @{ Status = 'ok' } }
function Test-Port { param($Port) return $true }
# This launcher test has no recovery owners; live-node adoption is tested in proxy-config.ps1.
function Get-RecoveryRoot { [IO.Path]::GetTempPath() }
function Test-RecoveryOwner { param($Identity) return $false }
function Confirm-NodeAlias { param($Node) return $true }
# A node's Chrome uses that node's self-healing tunnel (2.10), not a bare ssh.
function Start-NodeTunnelOwner { param($Node) $script:TunnelPorts += $Node; return $true }
function Reset-Launch { $script:ChromeArgs = @(); $script:TunnelPorts = @() }
$script:CHROME_EXE = 'chrome-proxy-test-browser'
$script:CHROME_BASE = 'C:\ChromeVPNProfile'
$script:CHROME_BYPASS = 'on'; $script:TELEMETRY = 'on'
$script:NO_PROXY_LIST = 'localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16,*.local,.mycorp.example,*'
$script:SSH_HOST = 'jpvpn'; $script:HTTP_PORT = 8080; $script:SOCKS_PORT = 1080
$script:NODE_HTTP_BASE = 8180; $script:NODE_SOCKS_BASE = 1180; $script:NODE_PORTS = $null; $script:REMOTE_PROXY_PORT = 8888
$script:NODES_CACHE = [System.IO.Path]::GetTempFileName()
$catalogue = '{"nodes":[{"name":"jp","alias":"jpvpn","host":"jp.example.com","slot":0},{"name":"sg","alias":"sgvpn","host":"sg.example.com","slot":1}]}'
try {
    [System.IO.File]::WriteAllText($script:NODES_CACHE, $catalogue)
    Reset-Launch
    chrome-proxy sg -Profile sg
    Assert ($script:ChromeArgs -contains '--proxy-server=socks5://127.0.0.1:1181') 'SG must use its own SOCKS port'
    Assert ($script:ChromeArgs -contains '--profile-directory=sg') 'SG profile must be preserved'
    Assert ($script:ChromeArgs -contains '--user-data-dir=C:\ChromeVPNProfile-sg') 'SG needs a separate data folder'
    Assert ($script:ChromeArgs -notcontains 'sg') 'Node/profile names must never be passed as URLs'

    Reset-Launch
    chrome-proxy -Profile work sg https://example.com/
    Assert ($script:ChromeArgs -contains '--profile-directory=work') 'Profile before node must work'
    Assert ($script:ChromeArgs -contains 'https://example.com/') 'Explicit URLs must be passed to Chrome'

    Reset-Launch
    chrome-proxy sgg -Profile sg
    Assert ($script:ChromeArgs.Count -eq 0 -and $script:TunnelPorts.Count -eq 0) 'Unknown nodes must not open Chrome or a tunnel'

    [System.IO.File]::WriteAllText($script:NODES_CACHE, '{"nodes":[]}')
    Reset-Launch
    chrome-proxy sg -Profile sg
    Assert ($script:ChromeArgs.Count -eq 0) 'Missing catalogue entry must not become http://sg/'

    [System.IO.File]::WriteAllText($script:NODES_CACHE, $catalogue)
    Reset-Launch
    chrome-proxy https://example.com/
    Assert ($script:ChromeArgs -contains '--proxy-server=socks5://127.0.0.1:1080') 'URL-only launches must retain the main tunnel'

    Reset-Launch
    $script:SSH_HOST = 'sgvpn'
    chrome-proxy sg -p work
    Assert ($script:ChromeArgs -contains '--proxy-server=socks5://127.0.0.1:1181') 'Named SG must retain its stable node port'
    Assert ($script:TunnelPorts -contains 'sg') 'Named SG must ensure its independent tunnel'
    Write-Host 'PASS: six Chrome/node/profile scenarios'

    # Leak guards, LAN bypass with local DNS for bypassed names; '*' is never a bypass.
    Reset-Launch
    chrome-proxy jp
    Assert ($script:ChromeArgs -contains '--force-webrtc-ip-handling-policy=disable_non_proxied_udp') 'WebRTC must not use direct UDP'
    Assert ($script:ChromeArgs -contains '--disable-quic') 'QUIC must be off'
    Assert ($script:ChromeArgs -contains '--proxy-bypass-list=localhost;*.localhost;127.0.0.1;[::1];10.0.0.0/8;192.168.0.0/16;*.local;mycorp.example;*.mycorp.example') "LAN bypass: $($script:ChromeArgs -join ' | ')"
    Assert ($script:ChromeArgs -contains '--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost , EXCLUDE *.localhost , EXCLUDE 127.0.0.1 , EXCLUDE *.local , EXCLUDE mycorp.example , EXCLUDE *.mycorp.example') 'Bypassed names resolve locally'
    $script:CHROME_BYPASS = 'off'
    Reset-Launch
    chrome-proxy jp
    Assert ($script:ChromeArgs -contains '--proxy-bypass-list=localhost;*.localhost;127.0.0.1') 'CHROME_BYPASS=off proxies the LAN'
    $script:CHROME_BYPASS = 'on'
    # -Check opens the leak tests.
    function Get-ProxyExitInfo { param($Port, $Field) if ($Field -eq 'ip') { '203.0.113.9' } else { 'Asia/Tokyo' } }
    Reset-Launch
    chrome-proxy jp -Check 6>$null
    Assert ($script:ChromeArgs -contains 'https://browserleaks.com/webrtc') '-Check opens the WebRTC test'
    Assert ($script:ChromeArgs -notcontains '-Check') '-Check is not a URL'
    Write-Host 'PASS: Chrome WebRTC/QUIC guards, LAN bypass, -Check'

    # TELEMETRY=off: only Claude, only during the run.
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = $null
    $script:TELEMETRY = 'off'
    $seen = Invoke-WithAppEnv claude { $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC }
    $cx = Invoke-WithAppEnv codex { $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC }
    Assert ($seen -eq '1' -and -not $cx -and -not $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) 'TELEMETRY=off is scoped to Claude runs'
    $script:TELEMETRY = 'on'
    Assert (-not (Invoke-WithAppEnv claude { $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC })) 'TELEMETRY=on leaves Claude alone'
    Write-Host 'PASS: TELEMETRY=off scoped to Claude'
} finally {
    Remove-Item -LiteralPath $script:NODES_CACHE -Force
}
