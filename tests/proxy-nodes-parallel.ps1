$ErrorActionPreference='Stop'
# Parallel node tunnels (PowerShell). Mirrors tests/proxy-nodes-parallel.sh:
# node slots and ports, one owner per node, cc/cx -Node for one window,
# proxy-node guard, chrome-proxy on the node tunnel, cc-stop / status for all.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $f.Extent.Text}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('nodes-'+[guid]::NewGuid()); $null=New-Item -ItemType Directory $scratch
function Get-RecoveryRoot { Join-Path $scratch 'recovery' }
$script:NODES_CACHE=Join-Path $scratch 'nodes.json'
[IO.File]::WriteAllText($script:NODES_CACHE,@'
{ "nodes": [
{ "name": "jp", "alias": "jpvpn", "host": "jp.example.com", "ssh_port": 22, "proxy_port": 8888, "slot": 0 },
{ "name": "sg", "alias": "sgvpn", "host": "sg.example.com", "ssh_port": 2222, "proxy_port": 8899, "slot": 1 },
{ "name": "us", "alias": "usvpn", "host": "<not provisioned>", "slot": 2 }
] }
'@)
$script:SSH_HOST='jpvpn';$script:SSH_USER='alice';$script:SSH_KEY='C:\k';$script:SSH_PORT=22
$script:HTTP_PORT=8080;$script:SOCKS_PORT=1080;$script:REMOTE_PROXY_PORT=8888
$script:NODE_HTTP_BASE=8180;$script:NODE_SOCKS_BASE=1180
$script:CONF_KEYS=@('SSH_HOST','SSH_USER','SSH_KEY','SSH_PORT','HTTP_PORT','SOCKS_PORT','REMOTE_PROXY_PORT','NODE_HTTP_BASE','NODE_SOCKS_BASE','PLAIN_COMMANDS','TUNNEL_WATCHDOG')
$script:PROXY_CONF=Join-Path $scratch 'conf.psd1'
$script:NO_PROXY_LIST='localhost,127.0.0.1'; $script:KILLSWITCH='on'; $script:PLAIN_COMMANDS='off'; $script:TUNNEL_WATCHDOG=0
$oldPath=$env:PATH
try {
 # 1) Slots and node context.
 Assert ((Get-NodeSlot jp) -eq 'main' -and (Get-NodeSlot jpvpn) -eq 'main') 'default node must be main'
 Assert ((Get-NodeSlot sg) -eq 'node-sg' -and (Get-NodeSlot sgvpn) -eq 'node-sg') 'sg slot'
 Assert ($null -eq (Get-NodeSlot nowhere 6>$null)) 'unknown node accepted'
 Assert ($null -eq (Get-NodeSlot us 6>$null)) 'unprovisioned node accepted'
 $c=Get-NodeContext sg
 Assert ($c.SSH_HOST -eq 'sgvpn' -and $c.SSH_USER -eq '' -and $c.HTTP_PORT -eq 8181 -and $c.SOCKS_PORT -eq 1181 -and $c.REMOTE_PROXY_PORT -eq 8899) "context: $($c|ConvertTo-Json -Compress)"
 $script:NODE_HTTP_BASE=8079
 $msg=(Get-NodeContext sg 6>&1) -join ' '
 Assert ($msg -match 'proxy-config set NODE_HTTP_BASE') "collision: $msg"
 $script:NODE_HTTP_BASE=8180
 'PASS: node slots, context and port collisions'

 # 2) One owner per node, started with the node's descriptor; settings restored.
 function Test-Port { param($Port) $false }
 function Get-NetTCPConnection { param($LocalPort,$State,$ErrorAction) }
 function Resolve-RecoveryProfile { param($p) 'profile.ps1' }
 function Test-RecoveryOwner { param($Identity) Test-Path (Join-Path $Identity 'owner.up') }
 function Start-Process { param($FilePath,$ArgumentList,$PassThru,$WindowStyle)
  $desc=($ArgumentList | Where-Object { $_ -like '*descriptor.json*' }).Trim('"')
  New-Item -ItemType File (Join-Path (Split-Path $desc) 'owner.up') -Force | Out-Null
  $script:Spawns+=(Split-Path -Leaf (Split-Path $desc))
  [pscustomobject]@{HasExited=$false} }
 $script:Spawns=@()
 $d=Start-RecoveryOwner claude sg
 Assert ($d -eq (Join-Path (Get-RecoveryRoot) 'node-sg')) "node dir: $d"
 $desc=Get-Content (Join-Path $d 'descriptor.json') -Raw | ConvertFrom-Json
 Assert ($desc.SSH_HOST -eq 'sgvpn' -and $desc.HTTP_PORT -eq 8181 -and $desc.SOCKS_PORT -eq 1181 -and $desc.REMOTE_PROXY_PORT -eq 8899 -and $desc.SSH_USER -eq '') "descriptor: $($desc|ConvertTo-Json -Compress)"
 Assert ($script:SSH_HOST -eq 'jpvpn' -and $script:HTTP_PORT -eq 8080 -and $script:SSH_USER -eq 'alice') 'window settings not restored'
 $null=Start-RecoveryOwner claude sg
 Assert ($script:Spawns.Count -eq 1) "second start spawned again: $($script:Spawns -join ',')"
 $dm=Start-RecoveryOwner claude
 Assert ($dm -eq (Join-Path (Get-RecoveryRoot) 'main')) 'default node must use main'
 'PASS: each node gets its own owner with its own descriptor; the window keeps its settings'

 # 3) tunnel-stop -Node stops only that node; plain tunnel-stop leaves node tunnels.
 function Stop-RecoveryOwner { param($Identity,$WaitSeconds) $script:Stopped+=(Split-Path -Leaf $Identity); Remove-Item (Join-Path $Identity 'owner.up') -ErrorAction SilentlyContinue }
 function Use-RecoveryRecord { param($Identity) $false }
 $script:Stopped=@()
 $null=tunnel-stop -Node sg 6>$null
 Assert ($script:Stopped -join ',' -eq 'node-sg') "tunnel-stop sg stopped: $($script:Stopped -join ',')"
 $null=Start-RecoveryOwner claude sg; $script:Stopped=@()
 $null=tunnel-stop 6>$null
 Assert ($script:Stopped -contains 'main' -and $script:Stopped -notcontains 'node-sg') "plain tunnel-stop stopped: $($script:Stopped -join ',')"
 'PASS: tunnel-stop -Node stops one node; plain tunnel-stop leaves node tunnels running'

 # 4) Migration: an old Chrome tunnel (ssh) on a node port is replaced; a foreign program refused.
 $null=tunnel-stop -Node sg 6>$null
 $script:Holder=@{Pid=4444;Name='ssh'}; $script:Killed=@()
 function Get-NetTCPConnection { param($LocalPort,$State,$ErrorAction) if($LocalPort -eq 1181 -and $script:Holder){[pscustomobject]@{OwningProcess=$script:Holder.Pid}} }
 function Get-Process { param($Id,$Name,$ErrorAction) if($Id -eq 4444){[pscustomobject]@{ProcessName=$script:Holder.Name;Id=4444}} else {Microsoft.PowerShell.Management\Get-Process @PSBoundParameters} }
  function Stop-Process { param($Id,[switch]$Force,$ErrorAction) $script:Killed+=$Id; $script:Holder=$null }
 function Test-Port { param($Port) [bool](Get-NetTCPConnection -LocalPort $Port) }
 $null=Start-RecoveryOwner claude sg 6>$null
 Assert ($script:Killed -contains 4444) 'old Chrome tunnel not replaced'
 $null=tunnel-stop -Node sg 6>$null
 $script:Holder=@{Pid=4444;Name='python3'}; $script:Killed=@(); $err=''
 try { $null=Start-RecoveryOwner claude sg 6>$null } catch { $err=$_.Exception.Message }
 Assert ($script:Killed.Count -eq 0 -and $err -match 'python3 \(PID 4444\)' -and $err -match 'NODE_SOCKS_BASE') "foreign: killed=$($script:Killed) err=$err"
 $script:Holder=$null
 'PASS: an old Chrome tunnel on a node port is replaced; a foreign program is refused'

 # 5) cc / cx -Node: this window only.
 foreach($b in 'claude','codex'){
  [IO.File]::WriteAllText((Join-Path $scratch "$b.ps1"),"Set-Content '$scratch/$b.argv' -Value `$args; Set-Content '$scratch/$b.proxy' -Value `$env:HTTPS_PROXY; `$global:LASTEXITCODE=0")
 }
 $env:PATH="$scratch$([IO.Path]::PathSeparator)$oldPath"
 function tunnel-start { param([string]$Node) $script:Started+=$(if($Node){$Node}else{'main'}) }
 function Get-TunnelHealth { @{Status='ok'} }
 function Test-RecoveryTransport { param($Provider,$HttpPort,$SocksPort) $script:Probed+=$HttpPort; @{kind='healthy'} }
 function Test-KillswitchLaunch { param($HttpPort,$SocksPort,$Identity) $script:Checked+="$HttpPort|$(if($Identity){Split-Path -Leaf $Identity}else{'main'})"; $true }
 function proxy-on { $env:HTTPS_PROXY='http://127.0.0.1:8080' }
 $script:Started=@(); $script:Probed=@(); $script:Checked=@(); $env:HTTPS_PROXY=$null
 cc -Node sg -NoVerify -p hi 6>$null
 $argv=@(Get-Content "$scratch/claude.argv")
 Assert ($argv[0] -eq '--settings') "claude argv: $($argv -join ' | ')"
 $node=Get-Content $argv[1] -Raw | ConvertFrom-Json
 Assert ($node.env.HTTPS_PROXY -eq 'http://127.0.0.1:8181' -and $node.env.HTTP_PROXY -eq 'http://127.0.0.1:8181' -and $node.env.NO_PROXY -eq 'localhost,127.0.0.1') "settings file: $($node|ConvertTo-Json -Compress)"
 Assert (($argv[2..4] -join ' ') -eq '--dangerously-skip-permissions -p hi') "claude app args: $($argv -join ' | ')"
 Assert ((Get-Content "$scratch/claude.proxy") -eq 'http://127.0.0.1:8181') 'claude did not get the node proxy'
 Assert (-not $env:HTTPS_PROXY) "cc -Node changed the window: $env:HTTPS_PROXY"
 Assert ($script:Started -contains 'sg' -and $script:Probed -contains 8181 -and $script:Checked -contains '8181|node-sg') "node checks: started=$($script:Started) probed=$($script:Probed) checked=$($script:Checked)"
 'PASS: cc -Node sg runs Claude through sg (--settings file + env) and leaves the window alone'

 $env:HTTPS_PROXY='http://127.0.0.1:8080'
 cx --node sg --no-verify exec ls 6>$null
 Assert ((Get-Content "$scratch/codex.proxy") -eq 'http://127.0.0.1:8181') 'codex did not get the node proxy'
 Assert (@(Get-Content "$scratch/codex.argv") -notcontains '--settings') 'codex got --settings'
 Assert ($env:HTTPS_PROXY -eq 'http://127.0.0.1:8080') "cx -Node did not restore the window: $env:HTTPS_PROXY"
 'PASS: cx --node sg runs Codex through sg and restores the window'

 $env:HTTPS_PROXY=$null
 $ok=proxy-up -Node sg -NoVerify 6>$null
 Assert ($ok -eq $true -and $env:HTTPS_PROXY -eq 'http://127.0.0.1:8181' -and $script:SSH_HOST -eq 'jpvpn') "proxy-up -Node: ok=$ok env=$env:HTTPS_PROXY host=$($script:SSH_HOST)"
 $env:HTTPS_PROXY=$null
 Remove-Item "$scratch/claude.argv"
 cc -Node jp -NoVerify -p hi 6>$null
 Assert ((@(Get-Content "$scratch/claude.argv"))[0] -eq '--dangerously-skip-permissions') 'cc -Node <default> must be plain cc'
 'PASS: proxy-up -Node sets this window only; -Node <default node> is plain cc'

 # 6) proxy-node refuses to move running sessions.
 $sd=Join-Path (Get-RecoveryIdentity) 'sessions'; $null=New-Item -ItemType Directory $sd -Force
 [IO.File]::WriteAllText((Join-Path $sd "$PID-a"),"$PID|$((Microsoft.PowerShell.Management\Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)")
 function Confirm-NodeAlias { param($n) $true }
 $out=(proxy-node sg 6>&1) -join ' '
 Assert ($script:SSH_HOST -eq 'jpvpn' -and $out -match '1 session' -and $out -match 'cc --node sg' -and $out -match '-Force') "guard: $out"
 function Get-TunnelHealth { @{Status='down'} }
 $null=proxy-node sg -Force 6>$null
 Assert ($script:SSH_HOST -eq 'sgvpn') 'proxy-node -Force did not switch'
 $script:SSH_HOST='jpvpn'; Remove-Item $sd -Recurse -Force
 'PASS: proxy-node refuses to move running sessions unless -Force'

 # 7) cc-stop: sessions on every slot; every owner; old Chrome tunnels last.
 $nsd=Join-Path (Get-RecoveryIdentity -Slot node-sg) 'sessions'; $null=New-Item -ItemType Directory $nsd -Force
 [IO.File]::WriteAllText((Join-Path $nsd "$PID-b"),"$PID|$((Microsoft.PowerShell.Management\Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)")
 function Get-Process { param($Id,$Name,$ErrorAction) if($Name){return}; Microsoft.PowerShell.Management\Get-Process @PSBoundParameters }
 function Stop-NodeTunnels { $script:Order+='legacy' }
 function proxy-off {}
 $script:Order=@()
 cc-stop 3>$null 6>$null
 Assert ($script:Order.Count -eq 0) 'cc-stop ignored a node session'
 Remove-Item $nsd -Recurse -Force
 $null=Start-RecoveryOwner claude sg; $null=Start-RecoveryOwner claude
 function Stop-RecoveryOwner { param($Identity,$WaitSeconds) $script:Order+=(Split-Path -Leaf $Identity); Remove-Item (Join-Path $Identity 'owner.up') -ErrorAction SilentlyContinue }
 cc-stop 6>$null
 Assert ($script:Order -contains 'node-sg' -and $script:Order[-1] -eq 'legacy') "cc-stop order: $($script:Order -join ',')"
 'PASS: cc-stop counts sessions on every node and stops node owners before the old-tunnel sweep'

 # 8) chrome-proxy <node> uses the node tunnel.
 $script:Started=@()
 function Start-NodeTunnelOwner { param([string]$Node) $script:Started+=$Node; $true }
 $script:CHROME_EXE=Join-Path $scratch 'chrome.ps1'
 [IO.File]::WriteAllText($script:CHROME_EXE,"Set-Content '$scratch/chrome.argv' -Value `$args")
 function Get-ChromeProfileDir { param($Base,$Name) Join-Path $scratch "chrome-$Name" }
 chrome-proxy sg 6>$null
 Start-Sleep -Milliseconds 300
 Assert ($script:Started -contains 'sg') "chrome-proxy sg did not start the sg tunnel: $($script:Started -join ',')"
 'PASS: chrome-proxy <node> uses the self-healing node tunnel'

 # 9) proxy-status lists node tunnels.
 $nd=Get-RecoveryIdentity -Slot node-sg
 Write-RecoveryStatus $nd descriptor @{SSH_HOST='sgvpn';HTTP_PORT=8181;SOCKS_PORT=1181}
 Write-RecoveryStatus $nd ssh @{class='auth';exit=255;at=5;line='Permission denied'}
 New-Item -ItemType File (Join-Path $nd 'owner.up') -Force | Out-Null
 $out=(Write-NodeStatusLines 6>&1) -join "`n"
 Assert ($out -match 'Node tunnels' -and $out -match 'sg' -and $out -match '8181' -and $out -match '1181' -and $out -match 'SSH login to sgvpn was refused') "status: $out"
 'PASS: proxy-status shows each node tunnel with its ports and last error'
} finally {
 $env:PATH=$oldPath; $env:HTTPS_PROXY=$null; $env:HTTP_PROXY=$null; $env:NO_PROXY=$null; $env:https_proxy=$null; $env:http_proxy=$null; $env:no_proxy=$null
 Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
