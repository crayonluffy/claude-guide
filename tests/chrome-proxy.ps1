# Run with: pwsh -NoProfile -File tests/chrome-proxy.ps1
# Exercise the real node parser/launcher without opening Chrome or SSH.
param([string]$ProfilePath = (Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'))
$ErrorActionPreference = 'Stop'
$source = $ProfilePath
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$wanted = @('Get-ProxyNodes', 'Find-ProxyNode', 'Get-ActiveNodeName', 'Get-NodeSocksPort', 'chrome-proxy')
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
function Confirm-NodeAlias { param($Node) return $true }
function Start-NodeTunnel { param($Node, $Port) $script:TunnelPorts += $Port; return $true }
function Reset-Launch { $script:ChromeArgs = @(); $script:TunnelPorts = @() }
$script:CHROME_EXE = 'chrome-proxy-test-browser'
$script:CHROME_BASE = 'C:\ChromeVPNProfile'
$script:SSH_HOST = 'jpvpn'; $script:SOCKS_PORT = 1080; $script:NODE_SOCKS_BASE = 1180
$script:NODES_CACHE = [System.IO.Path]::GetTempFileName()
$catalogue = '{"nodes":[{"name":"jp","alias":"jpvpn","slot":0},{"name":"sg","alias":"sgvpn","slot":1}]}'
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
    Assert ($script:ChromeArgs -contains '--proxy-server=socks5://127.0.0.1:1080') 'Active SG must reuse a healthy main tunnel'
    Assert ($script:TunnelPorts.Count -eq 0) 'Reusing the main tunnel must not start another one'
    Write-Host 'PASS: six Chrome/node/profile scenarios'
} finally {
    Remove-Item -LiteralPath $script:NODES_CACHE -Force
}
