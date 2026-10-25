$ErrorActionPreference='Stop'
# App-level kill switch (PowerShell). Mirrors tests/proxy-killswitch.sh: the
# NO_PROXY matcher, the settings.json pin, proxy-killswitch, the pre-launch leak
# checks and the doctor/status lines. Everything under a scratch directory.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $f.Extent.Text}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('killswitch-'+[guid]::NewGuid()); $null=New-Item -ItemType Directory $scratch
function Get-RecoveryRoot { Join-Path $scratch 'recovery' }
$script:PROXY_CONF=Join-Path $scratch 'conf.psd1'
$script:CLAUDE_SETTINGS=Join-Path $scratch 'settings.json'
$script:CONF_KEYS=@('SSH_HOST','HTTP_PORT','SOCKS_PORT','SYNC_SETTINGS','KILLSWITCH','PLAIN_COMMANDS','NO_PROXY_EXTRA')
$script:SSH_HOST='jp';$script:HTTP_PORT=8080;$script:SOCKS_PORT=1080;$script:SYNC_SETTINGS=1
$script:KILLSWITCH='on';$script:PLAIN_COMMANDS='off';$script:NO_PROXY_EXTRA='';$script:NO_PROXY_LIST='localhost,127.0.0.1'
function Pin([string]$k) { try { ((Get-Content $script:CLAUDE_SETTINGS -Raw | ConvertFrom-Json).env).$k } catch { $null } }
try {
 # 1) NO_PROXY matcher - same table as Bash.
 $all='api.anthropic.com claude.ai statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com'
 $com='api.anthropic.com statsig.anthropic.com api.openai.com chatgpt.com auth.openai.com'
 foreach($c in @(
  @('localhost,127.0.0.1,::1,10.0.0.0/8,*.local,*.internal,*.corp',''), @('*',$all), @('localhost, * ',$all),
  @('*.com',$com), @('.com',$com), @('com',$com),
  @('anthropic.com','api.anthropic.com statsig.anthropic.com'), @('.anthropic.com','api.anthropic.com statsig.anthropic.com'),
  @('*.anthropic.com','api.anthropic.com statsig.anthropic.com'), @('api.openai.com:443','api.openai.com'),
  @(' API.OpenAI.com ','api.openai.com'), @('claude.ai','claude.ai'),
  @('notclaude.ai,10.0.0.0/8,openai.co,api.anthropic.com.evil',''), @('',''))) {
  $got=(@(Get-NoProxyExemption $c[0]) -join ' ')
  Assert ($got -eq $c[1]) "NO_PROXY '$($c[0])' -> '$got', expected '$($c[1])'"
 }
 'PASS: NO_PROXY entries that would send API traffic direct are found'

 # 2) The pin.
 [IO.File]::WriteAllText($script:CLAUDE_SETTINGS,'{"model":"opus","env":{"FOO":"bar"}}')
 proxy-on 6>$null; proxy-off 6>$null
 Assert (-not $env:HTTPS_PROXY) 'shell env not cleared'
 Assert ((Pin HTTPS_PROXY) -eq 'http://127.0.0.1:8080' -and (Pin HTTP_PROXY) -eq 'http://127.0.0.1:8080') 'pin removed by proxy-off'
 Assert ((Pin NO_PROXY) -eq 'localhost,127.0.0.1' -and (Pin FOO) -eq 'bar') 'other settings changed'
 Assert ((Get-Content $script:CLAUDE_SETTINGS -Raw | ConvertFrom-Json).model -eq 'opus') 'model lost'
 'PASS: proxy-off clears the window but keeps Claude pinned to the tunnel'
 $script:KILLSWITCH='off'; proxy-off 6>$null
 Assert (-not (Pin HTTPS_PROXY) -and (Pin FOO) -eq 'bar') 'kill switch off must unpin as before'
 $script:KILLSWITCH='on'
 'PASS: with the kill switch off, proxy-off unpins as before'

 $msg=Confirm-KillswitchPin
 Assert ((Pin HTTPS_PROXY) -eq 'http://127.0.0.1:8080' -and $msg -match 'Kill switch') "ensure did not pin/notify: $msg"
 Remove-Item "$($script:CLAUDE_SETTINGS).bak" -ErrorAction SilentlyContinue
 $before=(Get-Item $script:CLAUDE_SETTINGS).LastWriteTimeUtc; Start-Sleep -Milliseconds 1100
 Assert (-not (Confirm-KillswitchPin)) 'ensure not silent when pinned'
 Assert ((Get-Item $script:CLAUDE_SETTINGS).LastWriteTimeUtc -eq $before) 'unchanged pin rewritten'
 Assert (-not (Test-Path "$($script:CLAUDE_SETTINGS).bak")) 'unchanged pin left a .bak'
 Assert ((Get-KillswitchPinState) -eq 'pinned 8080') "state: $(Get-KillswitchPinState)"
 $script:HTTP_PORT=8081; Assert ((Get-KillswitchPinState) -eq 'mismatch 8080') "mismatch state: $(Get-KillswitchPinState)"
 $null=Confirm-KillswitchPin; Assert ((Pin HTTPS_PROXY) -eq 'http://127.0.0.1:8081') 're-pin to new port'
 $script:HTTP_PORT=8080; $null=Confirm-KillswitchPin
 $script:SYNC_SETTINGS=0; Assert ((Get-KillswitchPinState) -eq 'unpinned sync-off') 'sync-off state'; $script:SYNC_SETTINGS=1
 'PASS: the pin is written when missing or wrong, and left alone when right'

 # proxy-config set HTTP_PORT re-pins.
 proxy-config set HTTP_PORT 8090 6>$null
 Assert ((Pin HTTPS_PROXY) -eq 'http://127.0.0.1:8090') 'proxy-config set HTTP_PORT did not re-pin'
 proxy-config set HTTP_PORT 8080 6>$null
 'PASS: changing HTTP_PORT re-pins'

 # 3) proxy-killswitch.
 function Test-RecoveryOwner { param($Identity) $script:TunnelUp }
 $script:TunnelUp=$false
 $out=(proxy-killswitch status 6>&1) -join "`n"
 Assert ($out -match 'Kill switch: ON' -and $out -match 'pinned to 127\.0\.0\.1:8080' -and $out -match 'no API host' -and $out -match "plain 'codex'" -and $out -match 'Claude Desktop') "status: $out"
 proxy-killswitch off 6>$null
 Assert ((Get-Content $script:PROXY_CONF -Raw) -match "KILLSWITCH\s*=\s*'off'") 'off not saved'
 Assert (-not (Pin HTTPS_PROXY)) 'off with no tunnel must unpin'
 proxy-killswitch on 6>$null
 Assert ((Get-Content $script:PROXY_CONF -Raw) -match "KILLSWITCH\s*=\s*'on'") 'on not saved'
 Assert ((Pin HTTPS_PROXY) -eq 'http://127.0.0.1:8080') 'on must pin'
 $script:TunnelUp=$true; proxy-killswitch off 6>$null
 Assert ((Pin HTTPS_PROXY) -eq 'http://127.0.0.1:8080') 'off while a tunnel runs must keep the pin until proxy-off'
 proxy-killswitch on 6>$null; $script:TunnelUp=$false
 $bad=$false; try { proxy-killswitch sideways 6>$null } catch { $bad=$true }; Assert $bad 'bad argument accepted'
 'PASS: proxy-killswitch shows and switches the kill switch safely'

 # 4) Leak checks.
 $dir=Get-RecoveryIdentity
 $me=Get-Process -Id $PID
 Write-RecoveryStatus $dir sshpid @{Pid=$PID;Started="$($me.StartTime.ToUniversalTime().Ticks)"}
 $script:Holders=@{8080=$PID;1080=$PID}
 function Get-NetTCPConnection { param($LocalPort,$State,$ErrorAction) if($script:Holders.ContainsKey([int]$LocalPort)){[pscustomobject]@{OwningProcess=$script:Holders[[int]$LocalPort]}} }
 function Get-Process { param($Id,$Name,$ErrorAction) if($Id -eq 777){[pscustomobject]@{ProcessName='clash';Id=777}} else {Microsoft.PowerShell.Management\Get-Process @PSBoundParameters} }
 function Refuses([string]$Text) {
  $o=(Test-KillswitchLaunch 8080 1080 6>&1) ; $ok=$o[-1]; $lines=($o|Select-Object -SkipLast 1) -join "`n"
  Assert ($ok -eq $false) "not refused (expected: $Text)"; Assert ($lines -match [regex]::Escape($Text)) "refusal lacks '$Text': $lines"
 }
 Assert ((Test-KillswitchLaunch 8080 1080 6>$null) -eq $true) 'clean setup refused'
 $script:NO_PROXY_LIST='localhost,.anthropic.com'; Refuses 'api.anthropic.com'; $script:NO_PROXY_LIST='localhost,127.0.0.1'
 $null=Confirm-KillswitchPin
 $script:Holders[8080]=777; Refuses 'clash (PID 777) is on proxy port 8080'; Refuses 'proxy-config set HTTP_PORT'; $script:Holders[8080]=$PID
 Write-RecoveryStatus $dir sshpid @{Pid=$PID;Started='stale'}; Refuses 'is on proxy port 8080'
 Write-RecoveryStatus $dir sshpid @{Pid=$PID;Started="$($me.StartTime.ToUniversalTime().Ticks)"}
 [IO.File]::WriteAllText($script:CLAUDE_SETTINGS,'not json'); Refuses "Claude's settings"
 [IO.File]::WriteAllText($script:CLAUDE_SETTINGS,'{}'); $null=Confirm-KillswitchPin
 $script:KILLSWITCH='off'; $script:NO_PROXY_LIST='*'
 Assert ((Test-KillswitchLaunch 8080 1080 6>$null) -eq $true) 'kill switch off must not refuse'
 $script:KILLSWITCH='on'; $script:NO_PROXY_LIST='localhost,127.0.0.1'
 'PASS: cc/cx refuse on a leaky NO_PROXY, a foreign port holder, or an unpinnable Claude'

 # proxy-up refuses before setting anything.
 function tunnel-start {}
 function Get-TunnelHealth { @{Status='ok'} }
 function Test-RecoveryTransport { param($Provider,$HttpPort,$SocksPort) @{kind='healthy'} }
 function Use-RecoveryRecord { param($Identity) $false }
 function proxy-on { $script:ProxyOn++ }
 $script:ProxyOn=0; $script:Holders[8080]=777
 Assert ((proxy-up -NoVerify 6>$null) -eq $false -and $script:ProxyOn -eq 0) 'proxy-up launched with a foreign port holder'
 $script:Holders[8080]=$PID
 Assert ((proxy-up -NoVerify 6>$null) -eq $true -and $script:ProxyOn -eq 1) 'proxy-up refused a clean setup'
 'PASS: proxy-up refuses before setting anything, and launches when clean'

 # tunnel-start: no silent fallback around a foreign program.
 Remove-Item Function:\tunnel-start
 foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -eq 'tunnel-start'){Invoke-Expression $f.Extent.Text}}
 function Get-Command { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{Name='ssh'} }
 function Find-FreePort { param($Start) $script:Fallback++; 8081 }
 function Get-TunnelHealth { @{Status='foreign';OwnerPid=99;OwnerName='nginx'} }
 function Test-Port { param($Port) $Port -eq 8080 }
 $script:Fallback=0
 $out=(tunnel-start 6>&1) -join "`n"
 Assert ($out -match 'nginx \(PID 99\)' -and $out -match 'proxy-config set HTTP_PORT' -and $script:Fallback -eq 0) "tunnel-start fell back: $out"
 'PASS: tunnel-start refuses a foreign port holder instead of moving the port'
 Remove-Item Function:\Get-Command

 # 6) Doctor / status lines.
 $out=(Write-KillswitchReport 6>&1) -join "`n"
 Assert ($out -match 'Kill switch on' -and $out -match 'pinned' -and $out -match "plain 'codex'") "doctor: $out"
 $script:NO_PROXY_LIST='localhost,*.openai.com'
 Assert (((Write-KillswitchReport 6>&1) -join "`n") -match 'api\.openai\.com') 'doctor NO_PROXY'
 $script:NO_PROXY_LIST='localhost,127.0.0.1'; $script:KILLSWITCH='off'
 Assert (((Write-KillswitchReport 6>&1) -join "`n") -match 'Kill switch OFF') 'doctor off'
 $script:KILLSWITCH='on'
 'PASS: proxy-doctor reports the kill switch'
} finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue; $env:HTTPS_PROXY=$null;$env:HTTP_PROXY=$null;$env:NO_PROXY=$null;$env:https_proxy=$null;$env:http_proxy=$null;$env:no_proxy=$null }
