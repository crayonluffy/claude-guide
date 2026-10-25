$ErrorActionPreference='Stop'
# Sessions, idle probing, wake-up, the cc-stop guard and automatic migration
# (PowerShell). Mirrors tests/proxy-sessions.sh and tests/proxy-migrate.sh.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){
 if($f.Name -like '*-Recovery*' -or $f.Name -in @('proxy-up','cc-stop','_split-launch-args','Wait-ProxyTransport','Set-ProxyEnv','Show-ProxyIp')){Invoke-Expression $f.Extent.Text}
}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('sessions-'+[guid]::NewGuid()); $null=New-Item -ItemType Directory $scratch
function Get-RecoveryRoot { Join-Path $scratch 'recovery' }
try {
 $dir=Get-RecoveryIdentity

 # 1) A subscriber registers its session and removes it when it stops.
 $h=Start-RecoverySubscriber $dir claude
 Assert ((Get-RecoverySessionCount $dir) -eq 1) 'subscriber did not register a session'
 Stop-RecoverySubscriber $h
 Assert ((Get-RecoverySessionCount $dir) -eq 0) 'session left behind after the subscriber stopped'
 'PASS: a session registers with the owner and unregisters on exit'

 # 2) Dead or reused PIDs do not count, and their entries are removed.
 $sd=Join-Path $dir 'sessions'; $null=New-Item -ItemType Directory $sd -Force
 [IO.File]::WriteAllText((Join-Path $sd '99999999-x'),'99999999|1')
 [IO.File]::WriteAllText((Join-Path $sd "$PID-y"),"$PID|1")
 Assert ((Get-RecoverySessionCount $dir) -eq 0) 'stale sessions counted'
 Assert (@(Get-ChildItem $sd).Count -eq 0) 'stale session entries not removed'
 'PASS: only live sessions count; stale entries are removed'

 # 3) Worker: idle interval with no sessions and a healthy tunnel, normal otherwise.
 $script:CONF_KEYS=@('SSH_HOST','HTTP_PORT','SOCKS_PORT','WATCHDOG_INTERVAL','WATCHDOG_FAILS','WATCHDOG_NOTICE_AFTER','WATCHDOG_MAX_BACKOFF','WATCHDOG_STARTUP_GRACE','WATCHDOG_IDLE_INTERVAL')
 $script:DESKTOP_NOTIFICATIONS='off'
 function Test-RecoveryPortConflict {return $null}
 function Stop-RecoveryProcess {param($ProcessId,$Started) return $true}
 function Start-RecoverySsh {param($ErrFile) return ([pscustomobject]@{Id=99999999;HasExited=$false;StartTime=[datetime]::UtcNow}|Add-Member ScriptMethod Dispose {} -PassThru|Add-Member ScriptMethod WaitForExit {param($ms)$true} -PassThru)}
 function Get-RecoveryTime {$script:T+=5;return $script:T}
 function Wait-RecoveryInterval {param($Identity,$Seconds,[switch]$Idle,$Ssh) $script:Waits+="$(if($Idle){'idle'}else{'busy'}) $Seconds"}
 function New-WorkerDir([string]$Name) {
  $d=Join-Path $scratch $Name;[IO.Directory]::CreateDirectory($d)|Out-Null
  Write-RecoveryStatus $d descriptor @{SSH_HOST='jp';HTTP_PORT=18080;SOCKS_PORT=11080;WATCHDOG_INTERVAL=5;WATCHDOG_FAILS=2;WATCHDOG_NOTICE_AFTER=60;WATCHDOG_MAX_BACKOFF=30;WATCHDOG_STARTUP_GRACE=0;WATCHDOG_IDLE_INTERVAL=60}
  return $d
 }
 $script:Kind='healthy'
 function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort) if($script:T -ge 10){[IO.File]::WriteAllText((Join-Path $wdir 'stopped'),'stop')}; return @{kind=$script:Kind}}
 $wdir=New-WorkerDir 'idle';$script:T=-5;$script:Waits=@()
 Invoke-RecoveryWorker (Join-Path $wdir 'descriptor.json')
 Assert ($script:Waits[0] -eq 'idle 60') "no sessions: $($script:Waits -join ',')"
 $wdir=New-WorkerDir 'busy';$script:T=-5;$script:Waits=@()
 $null=New-Item -ItemType Directory (Join-Path $wdir 'sessions')
 [IO.File]::WriteAllText((Join-Path $wdir "sessions/$PID-z"),"$PID|$((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)")
 Invoke-RecoveryWorker (Join-Path $wdir 'descriptor.json')
 Assert ($script:Waits[0] -eq 'busy 5') "with a session: $($script:Waits -join ',')"
 $script:Kind='tunnel'
 $wdir=New-WorkerDir 'down';$script:T=-5;$script:Waits=@()
 Invoke-RecoveryWorker (Join-Path $wdir 'descriptor.json')
 Assert ($script:Waits[0] -eq 'busy 5') "unhealthy tunnel idled: $($script:Waits -join ',')"
 'PASS: idle interval only with no sessions and a healthy tunnel'

 # 4) The real idle wait ends early on a wake request.
 Remove-Item Function:\Wait-RecoveryInterval
 foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -eq 'Wait-RecoveryInterval'){Invoke-Expression $f.Extent.Text}}
 $wdir=New-WorkerDir 'wake'
 $job=Start-ThreadJob -ScriptBlock {param($p) Start-Sleep -Milliseconds 400; [IO.File]::WriteAllText($p,'wake')} -ArgumentList (Join-Path $wdir 'wake')
 $sw=[Diagnostics.Stopwatch]::StartNew(); Wait-RecoveryInterval $wdir 10 -Idle; $sw.Stop()
 $null=$job|Wait-Job; $job|Remove-Job
 Assert ($sw.Elapsed.TotalSeconds -lt 3) "idle wait ignored wake ($($sw.Elapsed.TotalSeconds)s)"
 Assert (-not (Test-Path (Join-Path $wdir 'wake'))) 'wake file not consumed'
 'PASS: an idle owner wakes on demand'

 # 5) proxy-up wakes an idle owner and waits for health; a dead tunnel still refuses.
 function tunnel-start {}
 function Test-KillswitchLaunch {param($HttpPort,$SocksPort) $true}   # covered by tests/proxy-killswitch.ps1
 function proxy-on {}
 function proxy-node {param($n) $true}
 function Get-TunnelHealth {@{Status='ok'}}
 function Test-RecoveryOwner {param($Identity) $true}
 function Use-RecoveryRecord {param($Identity) $true}
 $script:Probes=0
 function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort) $script:Probes++; if($script:Probes -lt 3){@{kind='tunnel'}}else{@{kind='healthy'}}}
 $script:WATCHDOG_STARTUP_GRACE=5
 $ok=proxy-up -NoVerify 6>$null
 Assert ($ok -eq $true) 'proxy-up refused although the owner healed within the grace'
 Assert (Test-Path (Join-Path $dir 'wake')) 'proxy-up did not wake the owner'
 Assert ($script:Probes -eq 3) "probes: $($script:Probes)"
 function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort) @{kind='tunnel'}}
 $script:WATCHDOG_STARTUP_GRACE=1
 Assert ((proxy-up -NoVerify 6>$null) -eq $false) 'proxy-up launched over a dead tunnel'
 'PASS: proxy-up wakes the owner, waits for health, and still refuses a dead tunnel'

 # 6) cc-stop refuses while a registered session runs (npm Claude is node.exe).
 function tunnel-stop {$script:Stops++;$true}
 function Stop-NodeTunnels {}
 function proxy-off {}
 $script:Stops=0
 Remove-Item (Join-Path $dir 'sessions') -Recurse -Force -ErrorAction SilentlyContinue
 $null=New-Item -ItemType Directory (Join-Path $dir 'sessions')
 [IO.File]::WriteAllText((Join-Path $dir "sessions/$PID-s"),"$PID|$((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)")
 cc-stop 3>$null 6>$null
 Assert ($script:Stops -eq 0) 'cc-stop stopped the tunnel under a registered session'
 Remove-Item (Join-Path $dir 'sessions') -Recurse -Force
 cc-stop 6>$null
 Assert ($script:Stops -eq 1) 'cc-stop refused with no session'
 'PASS: cc-stop counts registered sessions'

 # 7) Migration: a tunnel from an older profile is replaced, a foreign program is not.
 $mdir=Join-Path (Get-RecoveryRoot) 'main'
 function Test-RecoveryOwner {param($Identity) $false}
 function Test-Port {param($Port) $script:PortBusy}
 function Get-TunnelHealth {@{Status=$script:Health;OwnerPid=4242;OwnerName=$script:HealthName}}
 function tunnel-stop {$script:Stops++;$script:PortBusy=$false;$true}
 function Start-Process {$script:Spawns++; [pscustomobject]@{HasExited=$true}}
 function Resolve-RecoveryProfile {param($p) 'profile.ps1'}
 $script:PortBusy=$true;$script:Health='ok';$script:Stops=0;$script:Spawns=0
 try { Start-RecoveryOwner 6>$null | Out-Null } catch { }
 Assert ($script:Stops -eq 1 -and $script:Spawns -eq 1) "old tunnel not replaced (stops $($script:Stops), spawns $($script:Spawns))"
 $script:PortBusy=$true;$script:Health='foreign';$script:HealthName='nginx';$script:Stops=0;$script:Spawns=0
 $msg=''; try { Start-RecoveryOwner 6>$null | Out-Null } catch { $msg=$_.Exception.Message }
 Assert ($script:Stops -eq 0 -and $script:Spawns -eq 0) 'foreign program was touched'
 Assert ($msg -match 'nginx') "refusal does not name the program: $msg"
 'PASS: an older tunnel is replaced automatically; a foreign program is refused, not touched'
} finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
