$ErrorActionPreference = 'Stop'
# The slim command surface (2.13): new spellings dispatch to the real code, old
# names still work and say what replaced them, cc-help lists the core commands,
# and cc-manual prints a correct fallback without changing anything.
$source = Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $definition.Extent.Text
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('proxy-commands-'+[guid]::NewGuid())
$null = New-Item -ItemType Directory $scratch
try {
    function Get-RecoveryRoot { Join-Path $scratch 'recovery' }
    $script:CLAUDE_SETTINGS = Join-Path $scratch 'settings.json'
    [IO.File]::WriteAllText($script:CLAUDE_SETTINGS,'{"theme":"dark"}')
    $script:PROXY_CONF = Join-Path $scratch 'proxy.conf.psd1'
    $script:NODES_CACHE = Join-Path $scratch 'nodes.json'
    $script:LOCAL_NODES = Join-Path $scratch 'local-nodes'
    [IO.File]::WriteAllText($script:NODES_CACHE,'{"nodes":[{"name":"jp","alias":"jpvpn","host":"jp.example.com","slot":0},{"name":"sg","alias":"sgvpn","host":"sg.example.com","proxy_port":8899,"slot":1}]}')
    $script:SSH_HOST='jpvpn'; $script:SSH_USER=''; $script:SSH_KEY=''; $script:SSH_PORT=22
    $script:HTTP_PORT=8080; $script:SOCKS_PORT=1080; $script:REMOTE_PROXY_PORT=8888
    $script:NODE_HTTP_BASE=8180; $script:NODE_SOCKS_BASE=1180; $script:NODE_PORTS=$null
    $script:PROXY_MODE='managed'; $script:KILLSWITCH='on'; $script:PROFILE_VERSION='test'; $script:NO_PROXY_LIST='localhost,127.0.0.1'
    $script:CHROME_EXE=Join-Path $scratch 'chrome-missing'

    # New spellings reach the merged implementations; old names delegate with a hint.
    $script:Trace=@()
    function Invoke-ProxyDoctor { $script:Trace+='doctor' }
    function Set-ProxyDefaultNode { param([string]$Name,[switch]$Force) $script:Trace+="use:${Name}:$([bool]$Force)" }
    function Show-ChromeProfiles { param([string]$Node) $script:Trace+="list:$Node" }
    function Set-ProxyKillswitch { param([string]$Action='status') $script:Trace+="ks:$Action" }
    proxy-status -Fix; proxy-status --fix; proxy-nodes use sg --force; proxy-nodes use sg
    chrome-proxy --list jp; chrome-proxy -List; proxy-config killswitch on; proxy-config killswitch
    $expected='doctor,doctor,use:sg:True,use:sg:False,list:jp,list:,ks:on,ks:status'
    Assert (($script:Trace -join ',') -eq $expected) "new spellings: $($script:Trace -join ',')"
    $script:Trace=@()
    function cc { $script:Trace+="cc:$($args -join ' ')" }
    function cx { $script:Trace+="cx:$($args -join ' ')" }
    function cc-stop { $script:Trace+="stop:$($args -join ' ')" }
    $hints=(& { proxy-doctor; proxy-node sg; chrome-profiles; proxy-killswitch off; cc-safe -c; cx-safe; cx-stop sg } 6>&1 | Out-String)
    Assert (($script:Trace -join ',') -eq 'doctor,use:sg:False,list:,ks:off,cc:-Safe -c,cx:-Safe,stop:sg') "old names: $($script:Trace -join ',')"
    Assert ($hints -match "\[Renamed\] 'proxy-doctor' is now 'proxy-status -Fix'") "rename hint: $hints"
    Assert (-not (Get-Command bridge-start -ErrorAction SilentlyContinue)) 'bridge-start should be removed'
    'PASS: merged commands and renamed names'

    $help=(cc-help 6>&1 | Out-String)
    foreach ($word in @('Mode: managed','tunnel: not running','cc-stop','proxy-status -Fix','proxy-restart','cc-manual','proxy-nodes ','chrome-proxy','proxy-config','cc-help all')) {
        Assert ($help.Contains($word)) "cc-help lacks '$word'"
    }
    Assert (-not ($help -match 'tunnel-start|proxy-doctor|cc-safe')) 'cc-help shows non-core commands'
    Assert ((cc-help all 6>&1 | Out-String) -match '(?s)tunnel-start.*RENAMED.*proxy-doctor') 'cc-help all'
    'PASS: cc-help shows status and core commands; all shows the rest'

    $before=[IO.File]::ReadAllText($script:CLAUDE_SETTINGS)
    $manual=(cc-manual sg 6>&1 | Out-String)
    Assert ($manual.Contains('ssh -N -C -L 8181:127.0.0.1:8899 -D 1181') -and $manual.Contains('sgvpn')) "manual ssh: $manual"
    Assert ($manual.Contains('-x http://127.0.0.1:8181 https://api.anthropic.com')) "manual curl: $manual"
    Assert ($manual.Contains('--settings') -and $manual.Contains('"HTTPS_PROXY":"http://127.0.0.1:8181"')) "manual --settings: $manual"
    Assert ($manual.Contains('pinned to HTTP :8080')) "manual pinned port: $manual"
    $script:KILLSWITCH='off'
    $main=(cc-manual 6>&1 | Out-String)
    Assert ($main.Contains('Kill switch is OFF') -and -not $main.Contains('pinned to HTTP')) "manual kill switch off: $main"
    Assert ($main.Contains('-L 8080:127.0.0.1:8888 -D 1080') -and -not $main.Contains('--settings')) "manual main: $main"
    Assert ([IO.File]::ReadAllText($script:CLAUDE_SETTINGS) -eq $before) 'cc-manual changed Claude settings'
    'PASS: cc-manual prints node and main fallbacks without changing anything'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# Shared mode: status and -Fix check the shared endpoint instead of telling this
# account to start a tunnel it can neither see nor manage.
$scratch2 = Join-Path ([IO.Path]::GetTempPath()) ('proxy-commands-'+[guid]::NewGuid())
$null = New-Item -ItemType Directory $scratch2
try {
    $scratch=$scratch2
    $script:CLAUDE_SETTINGS=Join-Path $scratch2 'settings.json'; $script:PROXY_CONF=Join-Path $scratch2 'proxy.conf.psd1'
    $script:PROXY_MODE='shared'
    # Earlier cases stubbed the doctor; restore the real one.
    Invoke-Expression ($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ProxyDoctor'},$false)[0].Extent.Text)
    function Test-RecoveryTransport { param($Provider,$HttpPort,$SocksPort) @{kind='healthy'} }
    function Get-TunnelHealth { throw 'shared mode must not inspect local tunnel ownership' }
    $status=(proxy-status 6>&1 | Out-String)
    Assert ($status.Contains('[SHARED] Tunnel') -and $status.Contains('Proxy answers : yes')) "shared status: $status"
    Assert (-not $status.Contains('Run cc to start it')) 'shared status tells this account to start a tunnel'
    $doctor=(Invoke-ProxyDoctor 6>&1 | Out-String)
    Assert ($doctor.Contains('[SHARED] Tunnel') -and -not $doctor.Contains('NOT listening')) "shared doctor: $doctor"
    'PASS: shared mode status and -Fix check the shared endpoint'
} finally { Remove-Item -LiteralPath $scratch2 -Recurse -Force -ErrorAction SilentlyContinue }
