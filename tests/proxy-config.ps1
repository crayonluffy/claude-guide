$ErrorActionPreference = 'Stop'
# Real PSD1 files and real recovery leases; replace only editor/transport boundaries.
$source = Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$text = [IO.File]::ReadAllText($source)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $definition.Extent.Text
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Assert-Throws([scriptblock]$Action) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw 'Operation must reject invalid configuration'
}
function Get-RecoveryRoot { Join-Path $script:ConfigTestRoot 'recovery' }
function Start-Process { throw 'Tests must use the editor boundary, not launch a real editor.' }
function New-ConfigTestOwner([string]$Slot,[hashtable]$Context) {
    $dir=Get-RecoveryIdentity -Slot $Slot
    Write-RecoveryStatus $dir descriptor $Context
    Write-RecoveryStatus $dir owner @{ProcessId=$PID;Started="$((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)"}
    $lease=Open-RecoveryLock $dir
    $script:Leases+=$lease; $script:LeaseBySlot[$Slot]=$lease
    return $dir
}
# Run failing I/O outside this harness's Stop preference and ancestor catches.
# Removing the config functions' terminating-error handling must fail these cases.
function Invoke-ConfigContinueRunspace([string]$Action) {
    $worker=[PowerShell]::Create()
    try {
        $null=$worker.AddScript({
            param($Source,$Root,$Defaults)
            $ErrorActionPreference='Continue'
            $tokens=$null; $parseErrors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$parseErrors)
            foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
                Invoke-Expression $definition.Extent.Text
            }
            $script:ConfigTestRoot=$Root
            $script:PROXY_CONF=Join-Path $Root 'proxy.conf.psd1'
            $script:CLAUDE_SETTINGS=Join-Path $Root 'claude-settings.json'
            $script:CONFIG_DEFAULTS=$Defaults
            $script:CONF_KEYS=@($Defaults.Keys)
            foreach ($key in $script:CONF_KEYS) { Set-Variable -Name $key -Value $Defaults[$key] -Scope Script }
            $script:NO_PROXY_LIST='localhost,127.0.0.1'
            $script:EditorInvoked=$false
            function Get-RecoveryRoot { Join-Path $script:ConfigTestRoot 'recovery' }
            function Invoke-ProxyConfigEditor { param([string]$Path)
                $script:EditorInvoked=$true
                [IO.File]::WriteAllText($Path,'@{HTTP_PORT=8090}')
                return 0
            }
        }).AddArgument($source).AddArgument($script:ConfigTestRoot).AddArgument($script:CONFIG_DEFAULTS)
        $null=$worker.Invoke()
        Assert (-not $worker.HadErrors) 'Failed to initialize isolated config runspace'
        $worker.Commands.Clear()
        $null=$worker.AddScript($Action + "`n'ACTION_COMPLETED'")
        # Catch only the host API's exception after the isolated pipeline stops.
        # The script running with Continue has no enclosing try/catch.
        $output=@(); $invocationError=@()
        try { $output=@($worker.Invoke()) } catch { $invocationError=@($_) }
        $runtime=@{}
        foreach ($key in $script:CONF_KEYS) { $runtime[$key]=$worker.Runspace.SessionStateProxy.GetVariable($key) }
        return @{
            Output=$output
            Errors=@($worker.Streams.Error)+$invocationError
            Information=(@($worker.Streams.Information) | Out-String)
            Runtime=$runtime
            EditorInvoked=$worker.Runspace.SessionStateProxy.GetVariable('EditorInvoked')
            Preference=$worker.Runspace.SessionStateProxy.GetVariable('ErrorActionPreference')
        }
    } finally { $worker.Dispose() }
}

$script:cases = 0; $script:failed = @()
function Invoke-Case([string]$Name,[scriptblock]$Action) {
    $script:cases++
    $script:ConfigTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('proxy-config-'+[guid]::NewGuid())
    $null = New-Item -ItemType Directory $script:ConfigTestRoot
    $script:PROXY_CONF = Join-Path $script:ConfigTestRoot 'proxy.conf.psd1'
    $script:PROFILE_PATH = Join-Path $script:ConfigTestRoot 'not-installed.ps1'
    $script:CLAUDE_SETTINGS = Join-Path $script:ConfigTestRoot 'claude-settings.json'
    $script:NODES_CACHE = Join-Path $script:ConfigTestRoot 'nodes.json'
    $script:LOCAL_NODES = Join-Path $script:ConfigTestRoot 'local-nodes'
    $script:CONFIG_DEFAULTS = @{
        SSH_HOST='personal-host'; SSH_USER=''; SSH_KEY=''; SSH_PORT=22
        HTTP_PORT=8080; SOCKS_PORT=1080; REMOTE_PROXY_PORT=8888
        NODE_HTTP_BASE=8180; NODE_SOCKS_BASE=1180; SYNC_SETTINGS=0
        KILLSWITCH='on'; PLAIN_COMMANDS='off'; BANNER=0; NO_PROXY_EXTRA=''; TUNNEL_WATCHDOG=1
    }
    $script:CONF_KEYS = @($script:CONFIG_DEFAULTS.Keys)
    foreach ($key in $script:CONF_KEYS) { Set-Variable -Name $key -Value $script:CONFIG_DEFAULTS[$key] -Scope Script }
    $script:NO_PROXY_LIST = 'localhost,127.0.0.1'
    [IO.File]::WriteAllText($script:PROXY_CONF,"@{`n # personal comment`n SSH_HOST='personal-host'`n SYNC_SETTINGS=0`n BANNER=0`n UserNote='保留原設定'`n}`n",[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($script:NODES_CACHE,'{"nodes":[{"name":"jp","alias":"main-host","host":"192.0.2.1","slot":0},{"name":"sg","alias":"sg-host","host":"192.0.2.2","slot":1}]}')
    $script:Leases = @(); $script:LeaseBySlot=@{}
    foreach ($fixtureNode in @(@('main','main-host',8081,1080),@('node-sg','sg-host',8181,1181))) {
        $null=New-ConfigTestOwner $fixtureNode[0] @{SSH_HOST=$fixtureNode[1];SSH_USER='';SSH_KEY='';SSH_PORT=22;HTTP_PORT=$fixtureNode[2];SOCKS_PORT=$fixtureNode[3];REMOTE_PROXY_PORT=8888}
    }
    $script:EditorMode = 'keep'; $script:Seen = ''
    function Invoke-ProxyConfigEditor {
        param([string]$Path)
        $script:Seen = [IO.File]::ReadAllText($Path)
        if ($script:EditorMode -eq 'fail') { return 7 }
        if ($script:EditorMode -eq 'invalid') { [IO.File]::WriteAllText($Path,'@{HTTP_PORT="banana"}'); return 0 }
        if ($script:EditorMode -eq 'syntax') { [IO.File]::WriteAllText($Path,'@{broken'); return 0 }
        if ($script:EditorMode -eq 'repair') { [IO.File]::WriteAllText($Path,'@{HTTP_PORT=8090;SYNC_SETTINGS=0;BANNER=0}'); return 0 }
        if ($script:EditorMode -eq 'concurrent') { [IO.File]::AppendAllText($script:PROXY_CONF,"# changed in another window`n"); return 0 }
        return 0
    }
    try {
        & $Action
        "PASS: $Name"
    } catch {
        $script:failed += $Name
        "FAIL: $Name — $($_.Exception.Message)"
    } finally {
        foreach ($lease in $script:Leases) { if ($lease) { $lease.Dispose() } }
        Remove-Item -LiteralPath $script:ConfigTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Case 'show distinguishes saved and active ports for all nodes' {
    $null = Use-RecoveryRecord
    $out = (proxy-config show 6>&1 | Out-String)
    Assert ($out -match 'Saved.*8080') $out
    foreach ($value in @('Active node ports','main-host','8081','sg-host','8181','1181','use-active')) {
        Assert ($out.Contains($value)) "Missing '$value': $out"
    }
}
Invoke-Case 'edit materializes ports and preserves comments and Unicode settings' {
    $null = Use-RecoveryRecord
    proxy-config edit 6>$null
    foreach ($key in @('HTTP_PORT','SOCKS_PORT','REMOTE_PROXY_PORT','SSH_PORT','NODE_HTTP_BASE','NODE_SOCKS_BASE')) {
        Assert ($script:Seen -match "(?m)^\s*$key\s*=\s*\d+") "Missing editable $key"
    }
    foreach ($value in @('Active node ports','main-host','8081','sg-host','8181','1181')) {
        Assert ($script:Seen.Contains($value)) "Editor missing '$value'"
    }
    $saved = Import-PowerShellDataFile $script:PROXY_CONF
    Assert ($saved.HTTP_PORT -eq 8080) 'Runtime port replaced saved default'
    Assert ($saved.UserNote -eq '保留原設定') 'Unrelated Unicode setting was lost'
    Assert ([IO.File]::ReadAllText($script:PROXY_CONF).Contains('# personal comment')) 'Comment lost'
}
Invoke-Case 'failed editor keeps original file' {
    $before = [IO.File]::ReadAllText($script:PROXY_CONF); $script:EditorMode='fail'
    Assert-Throws { proxy-config edit 6>$null }
    Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'Failed editor changed saved file'
}
Invoke-Case 'edit allows repairing a malformed saved PSD1' {
    [IO.File]::WriteAllText($script:PROXY_CONF,'@{broken')
    $script:EditorMode='repair'
    proxy-config edit 6>$null
    Assert ((Import-PowerShellDataFile $script:PROXY_CONF).HTTP_PORT -eq 8090) 'Editor could not repair malformed data'
}
Invoke-Case 'editor cannot overwrite changes saved by another window' {
    $script:EditorMode='concurrent'
    Assert-Throws { proxy-config edit 6>$null }
    Assert ([IO.File]::ReadAllText($script:PROXY_CONF).Contains('# changed in another window')) 'Concurrent change was overwritten'
}
foreach ($mode in @('invalid','syntax')) {
    Invoke-Case "invalid editor $mode keeps original file" {
        $before = [IO.File]::ReadAllText($script:PROXY_CONF); $script:EditorMode=$mode
        Assert-Throws { proxy-config edit 6>$null }
        Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'Invalid edit changed saved file'
    }
}
Invoke-Case 'invalid set ports preserve file and runtime' {
    $before = [IO.File]::ReadAllText($script:PROXY_CONF)
    foreach ($value in @('0','65536','banana','-1','08080')) {
        Assert-Throws { proxy-config set HTTP_PORT $value 6>$null }
        Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) "Saved invalid port $value"
    }
}
foreach ($operation in @('complete','set','edit')) {
    Invoke-Case "$operation rejects replacement failure under Continue without applying unsaved settings" {
        $before=[IO.File]::ReadAllText($script:PROXY_CONF)
        $null=New-Item -ItemType Directory "$($script:PROXY_CONF).bak"
        $action=switch ($operation) {
            'complete' { @'
$candidate=Join-Path $script:ConfigTestRoot 'candidate.psd1'
[IO.File]::WriteAllText($candidate,'@{HTTP_PORT=8090}')
Complete-ProxyConfigSave $candidate ([IO.File]::ReadAllText($script:PROXY_CONF)) $true
'@ }
            'set' { 'proxy-config set HTTP_PORT 8090' }
            'edit' { 'proxy-config edit' }
        }
        $result=Invoke-ConfigContinueRunspace $action
        Assert ($result.Preference -eq 'Continue') 'Config save leaked its error preference into the caller'
        Assert ($result.Errors.Count -gt 0) 'Filesystem failure was not reported'
        Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'Failed replacement changed saved settings'
        foreach ($key in $script:CONF_KEYS) {
            Assert ($result.Runtime[$key] -eq $script:CONFIG_DEFAULTS[$key]) "Failed replacement changed runtime $key"
        }
        Assert ($result.Information -notmatch '\[OK\] Saved') 'Failed replacement reported success'
        Assert ($result.Output -notcontains 'ACTION_COMPLETED') 'Failed replacement did not stop the operation'
        if ($operation -ne 'complete') {
            Assert (@(Get-ChildItem $script:ConfigTestRoot -Filter '.claude-proxy-edit-*').Count -eq 0) 'Failed save leaked its candidate file'
        }
    }
}
Invoke-Case 'candidate write failure terminates under Continue' {
    $before=[IO.File]::ReadAllText($script:PROXY_CONF)
    $result=Invoke-ConfigContinueRunspace @'
Write-ProxyConfigCandidate $script:ConfigTestRoot '@{HTTP_PORT=8090}' (Get-ProxySavedConfig)
'@
    Assert ($result.Errors.Count -gt 0) 'Candidate write failure was not reported'
    Assert ($result.Output -notcontains 'ACTION_COMPLETED') 'Candidate write failure did not stop the operation'
    Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'Candidate write failure changed saved settings'
    Assert ($result.Runtime.HTTP_PORT -eq 8080) 'Candidate write failure changed runtime settings'
    Assert ($result.Information -notmatch '\[OK\] Saved') 'Candidate write failure reported success'
}
foreach ($operation in @('set','edit')) {
    Invoke-Case "$operation stops before using a candidate when its parent cannot be created under Continue" {
        $before=[IO.File]::ReadAllText($script:PROXY_CONF)
        [IO.File]::WriteAllText((Join-Path $script:ConfigTestRoot 'blocked'),'not a directory')
        $action="`$script:PROXY_CONF=Join-Path (Join-Path `$script:ConfigTestRoot 'blocked') 'config.psd1'`nproxy-config $operation"
        if ($operation -eq 'set') { $action+=' HTTP_PORT 8090' }
        $result=Invoke-ConfigContinueRunspace $action
        Assert ($result.Errors.Count -gt 0) 'Candidate parent failure was not reported'
        Assert (-not $result.EditorInvoked) 'Editor opened after candidate creation failed'
        Assert ($result.Output -notcontains 'ACTION_COMPLETED') 'Candidate parent failure did not stop the operation'
        Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'Candidate parent failure changed saved settings'
        Assert ($result.Runtime.HTTP_PORT -eq 8080) 'Candidate parent failure changed runtime settings'
        Assert ($result.Information -notmatch '\[OK\] Saved') 'Candidate parent failure reported success'
    }
}
Invoke-Case 'set saves pending port while retaining live owner ports' {
    $null = Use-RecoveryRecord
    $out = (proxy-config set HTTP_PORT 8090 6>&1 | Out-String)
    Assert ((Import-PowerShellDataFile $script:PROXY_CONF).HTTP_PORT -eq 8090) 'New port was not saved'
    Assert ($script:HTTP_PORT -eq 8081) 'Changing saved config moved the live port'
    Assert ($out -match 'proxy-restart' -and $out -notmatch 'applied in this window') $out
    Assert ((Import-PowerShellDataFile $script:PROXY_CONF).SSH_HOST -eq 'personal-host') 'Live server overwrote saved server'
}
Invoke-Case 'missing non-port value is rejected without saving' {
    $before=[IO.File]::ReadAllText($script:PROXY_CONF)
    Assert-Throws { proxy-config set SSH_HOST 6>$null }
    Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'Omitted value erased a setting'
}
Invoke-Case 'kill switch updates preserve pending ports and unrelated saved keys' {
    $null=Use-RecoveryRecord
    proxy-config set HTTP_PORT 8090 6>$null
    proxy-killswitch off 6>$null
    $saved=Import-PowerShellDataFile $script:PROXY_CONF
    Assert ($saved.HTTP_PORT -eq 8090) 'Kill switch update overwrote a pending port with a live value'
    Assert ($saved.UserNote -eq '保留原設定') 'Kill switch update discarded an unrelated key'
}
Invoke-Case 'use-active saves current ports without overwriting saved server' {
    proxy-config use-active 6>$null
    $saved = Import-PowerShellDataFile $script:PROXY_CONF
    Assert ($saved.HTTP_PORT -eq 8081 -and $saved.SOCKS_PORT -eq 1080 -and $saved.REMOTE_PROXY_PORT -eq 8888) 'Running ports not saved'
    Assert ($saved.SSH_HOST -eq 'personal-host' -and $saved.UserNote -eq '保留原設定') 'Unrelated saved settings changed'
}
Invoke-Case 'startup adopts running port before pinning Claude settings' {
    $script:SYNC_SETTINGS=1; $script:HTTP_PORT=8080
    $tail = $text.Substring($text.LastIndexOf('# Kill switch: make sure'))
    Invoke-Expression $tail
    $settings = [IO.File]::ReadAllText($script:CLAUDE_SETTINGS) | ConvertFrom-Json
    Assert ($settings.env.HTTPS_PROXY -eq 'http://127.0.0.1:8081') 'New window pinned wrong port'
}
Invoke-Case 'node context keeps active ports after saved base changes' {
    $script:NODE_HTTP_BASE=9000; $script:NODE_SOCKS_BASE=1900
    $context = Get-NodeContext sg
    Assert ($context.HTTP_PORT -eq 8181 -and $context.SOCKS_PORT -eq 1181) 'New bases overrode live node ports'
}
Invoke-Case 'status separates normal overview from debug recovery fields' {
    function Get-TunnelHealth { @{Status='down'} }
    function Write-NodeStatusLines { }
    function proxy-notify { }
    $normal = (proxy-status 6>&1 | Out-String)
    $detail = (proxy-status -Debug 6>&1 | Out-String)
    Assert ($normal -match 'Active node ports') 'Normal status lacks port overview'
    Assert ($normal -notmatch '\[Recovery\] Logs') 'Normal status exposes raw recovery detail'
    Assert ($detail -match '\[Recovery\] Logs') 'Debug status lacks recovery detail'
}
Invoke-Case 'use-active refuses when the main owner is absent' {
    $before=[IO.File]::ReadAllText($script:PROXY_CONF)
    $script:LeaseBySlot.main.Dispose()
    Remove-Item (Join-Path (Get-RecoveryIdentity) 'owner.json')
    Assert-Throws { proxy-config use-active 6>$null }
    Assert ([IO.File]::ReadAllText($script:PROXY_CONF) -ceq $before) 'No-owner use-active changed saved settings'
}
Invoke-Case 'editor refreshes active node snapshot without duplicating headers' {
    proxy-config edit 6>$null
    $dir=Get-RecoveryIdentity -Slot node-sg
    $record=Get-RecoveryStatus $dir descriptor; $record.HTTP_PORT=8191
    Write-RecoveryStatus $dir descriptor $record
    proxy-config edit 6>$null
    $edited=[IO.File]::ReadAllText($script:PROXY_CONF)
    Assert (([regex]::Matches($edited,'# BEGIN CLAUDE PROXY PORT STATUS')).Count -eq 1) 'Duplicate status sections'
    Assert (([regex]::Matches($edited,'(?m)^NODE_PORTS|^\s*NODE_PORTS\s*=')).Count -eq 1) 'Duplicate NODE_PORTS entries'
    # The running snapshot is refreshed; sg's saved assignment (8181) stays editable.
    Assert ($edited -match '(?m)^#\s+sg\s+sg-host\s+8191\s') 'Running snapshot missing refreshed port'
    Assert ($edited -notmatch '(?m)^#\s+sg\s+sg-host\s+8181\s') 'Stale active node snapshot'
    Assert ($edited -match '(?m)^#\s+sg\s+8181\s+1181\s+8191/1181\s') 'Plan does not show saved versus running ports'
}
foreach ($node in @('main','sg')) {
    Invoke-Case "restart $node applies saved ports and probes the new port" {
        $script:RestartTrace=@()
        $values=if ($node -eq 'main') { "HTTP_PORT=8090" } else { "NODE_HTTP_BASE=9000" }
        $savedHost=if ($node -eq 'main') { 'personal-host' } else { 'sg-host' }
        [IO.File]::WriteAllText($script:PROXY_CONF,"@{SSH_HOST='$savedHost';SYNC_SETTINGS=0;BANNER=0;$values}")
        function Stop-RecoveryOwner { param($Identity,$WaitSeconds)
            $slot=Split-Path -Leaf $Identity
            $script:RestartTrace+="stop:$slot"
            $script:LeaseBySlot[$slot].Dispose()
            Remove-Item (Join-Path $Identity 'owner.json')
        }
        function tunnel-start {
            $script:RestartTrace+="start:$($script:HTTP_PORT)"
            $context=@{}
            foreach ($k in @('SSH_HOST','SSH_USER','SSH_KEY','SSH_PORT','HTTP_PORT','SOCKS_PORT','REMOTE_PROXY_PORT')) { $context[$k]=Get-Variable -Name $k -Scope Script -ValueOnly }
            $null=New-ConfigTestOwner main $context
        }
        function Start-NodeTunnelOwner { param($Node)
            $ctx=Get-NodeContext $Node
            $script:RestartTrace+="start:$($ctx.HTTP_PORT)"
            $null=New-ConfigTestOwner $ctx.Slot $ctx
            return $true
        }
        function Wait-ProxyTransport { param($Provider,$HttpPort,$SocksPort,$Identity)
            $script:RestartTrace+="probe:$HttpPort"; return $true
        }
        function proxy-on { }
        $out=if ($node -eq 'main') { proxy-restart 6>&1 | Out-String } else { proxy-restart -Node sg 6>&1 | Out-String }
        $expected=if ($node -eq 'main') { 'stop:main,start:8090,probe:8090' } else { 'stop:node-sg,start:9001,probe:9001' }
        Assert (($script:RestartTrace -join ',') -eq $expected) ($script:RestartTrace -join ',')
        Assert ($out -match 'Relaunch' -and $out -notmatch 'same ports') $out
    }
}
Invoke-Case 'node restart keeps the named slot when saved settings make it the default' {
    # Explicit node routes keep node-<name>; main must stay untouched.
    $script:SSH_HOST='main-host'
    [IO.File]::WriteAllText($script:PROXY_CONF,"@{SSH_HOST='sg-host';SYNC_SETTINGS=0;BANNER=0;NODE_HTTP_BASE=9000}")
    $script:RestartTrace=@()
    function Stop-RecoveryOwner { param($Identity,$WaitSeconds)
        $slot=Split-Path -Leaf $Identity
        $script:RestartTrace+="stop:$slot"
        $script:LeaseBySlot[$slot].Dispose()
        Remove-Item (Join-Path $Identity 'owner.json')
    }
    function tunnel-start { $script:RestartTrace+='start:main' }
    function Start-NodeTunnelOwner { param($Node)
        $ctx=Get-NodeContext $Node
        $script:RestartTrace+="start:$($ctx.Slot):$($ctx.HTTP_PORT)"
        $null=New-ConfigTestOwner $ctx.Slot $ctx
        return $true
    }
    function Wait-ProxyTransport { param($Provider,$HttpPort,$SocksPort,$Identity) return $true }
    function proxy-on { $script:RestartTrace+='proxy-on' }
    proxy-restart -Node sg 6>$null | Out-Null
    Assert (($script:RestartTrace -join ',') -eq 'stop:node-sg,start:node-sg:9001') ($script:RestartTrace -join ',')
    $main=Get-RecoveryStatus (Get-RecoveryIdentity) descriptor
    Assert ($main.HTTP_PORT -eq 8081) 'Named restart changed the main tunnel'
    Assert (Test-Path (Join-Path (Get-RecoveryIdentity) 'owner.json')) 'Named restart stopped the main owner'
}
foreach ($values in @('HTTP_PORT=8181','HTTP_PORT=8090;SOCKS_PORT=8090')) {
    Invoke-Case "restart refuses conflicting saved ports: $values" {
        [IO.File]::WriteAllText($script:PROXY_CONF,"@{SSH_HOST='personal-host';SYNC_SETTINGS=0;$values}")
        $script:RestartStopped=$false
        function Stop-RecoveryOwner { $script:RestartStopped=$true }
        function tunnel-stop { $script:RestartStopped=$true; return $true }
        function Start-RecoveryOwner { return 'fake-identity' }
        Assert-Throws { proxy-restart 6>$null }
        Assert (-not $script:RestartStopped) 'Restart stopped a tunnel before rejecting conflicts'
    }
}
"$($script:cases-$script:failed.Count)/$script:cases config cases passed."
if ($script:failed.Count) { throw "Failed cases: $($script:failed -join ', ')" }
