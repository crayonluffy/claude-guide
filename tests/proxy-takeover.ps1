$ErrorActionPreference='Stop'
# Port takeover alert (PowerShell): a program that binds a proxy port while the
# tunnel is down is named once - log, live windows, one desktop alert - and never
# killed. Mirrors tests/proxy-takeover.sh.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -like '*-Recovery*'){Invoke-Expression $f.Extent.Text}}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('takeover-'+[guid]::NewGuid()); $null=New-Item -ItemType Directory $scratch
try {
 # 1) The conflict names the first foreign listener; our own ssh is not one.
 $script:HTTP_PORT=18080;$script:SOCKS_PORT=11080
 function Get-NetTCPConnection {param($LocalPort,$State) if($LocalPort -eq 18080){[pscustomobject]@{OwningProcess=$script:Holder}}}
 function Get-Process {param($Id,$Name,$ErrorAction) [pscustomobject]@{ProcessName='clash'}}
 $script:Holder=777
 $c=Test-RecoveryPortConflict 555
 Assert ($c.Pid -eq 777 -and $c.Name -eq 'clash' -and $c.Port -eq 18080) "conflict: $($c|ConvertTo-Json -Compress)"
 $script:Holder=555
 Assert ($null -eq (Test-RecoveryPortConflict 555)) 'own ssh reported as a conflict'
 Remove-Item Function:\Get-NetTCPConnection, Function:\Get-Process
 'PASS: the conflict names the program, PID and port'

 # 2) Messages.
 $m=Get-RecoveryMessage takeover @{Pid=777;Name='clash';Port=18080}
 Assert ($m -match 'clash, PID 777' -and $m -match '18080' -and $m -match 'exit this session') "terminal message: $m"
 $d=Get-RecoveryDesktopMessage takeover '777|clash|18080'
 Assert ($d.Title -eq 'Proxy port taken' -and $d.Body -match '^clash \(PID 777\) took port 18080') "desktop message: $($d|ConvertTo-Json -Compress)"
 'PASS: terminal and desktop messages name the program and say to exit'

 # 3) Worker: clash holds 18080 for three passes, then the tunnel recovers.
 $script:CONF_KEYS=@('SSH_HOST','HTTP_PORT','SOCKS_PORT','WATCHDOG_INTERVAL','WATCHDOG_FAILS','WATCHDOG_NOTICE_AFTER','WATCHDOG_MAX_BACKOFF','WATCHDOG_STARTUP_GRACE','WATCHDOG_IDLE_INTERVAL')
 function New-RecoveryDesktopContext {[pscustomobject]@{Backend='tray';LastSubmission='not-tested'}}
 function Get-RecoveryDesktopStatus {param($Context)@{backend=$Context.Backend}}
 function Stop-RecoveryDesktopContext {param($Context)}
 function Send-RecoveryDesktopNotification {param($Context,$Event,$Scope)$script:Alerts+=$Event;return $true}
 function Stop-RecoveryProcess {param($ProcessId,$Started) if($ProcessId -eq 777){$script:Kills++}; return $true}
 function Start-RecoverySsh {param($ErrFile) return ([pscustomobject]@{Id=99999999;HasExited=$false;StartTime=[datetime]::UtcNow}|Add-Member ScriptMethod Dispose {} -PassThru|Add-Member ScriptMethod WaitForExit {param($ms)$true} -PassThru)}
 function Wait-RecoveryInterval {param($Identity,$Seconds,[switch]$Idle,$Ssh)}
 function Get-RecoveryTime {$script:Pass++;return $script:Pass*5}
 function Test-RecoveryPortConflict {param($OwnedProcessId) if($script:Pass -le 3){@{Pid=777;Name='clash';Port=18080}}}
 function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort)
  if($script:Pass -ge 6){[IO.File]::WriteAllText((Join-Path $dir 'stopped'),'stop')}
  @{kind='healthy'}}
 $dir=Join-Path $scratch 'owner';[IO.Directory]::CreateDirectory($dir)|Out-Null
 Write-RecoveryStatus $dir descriptor @{SSH_HOST='jp';HTTP_PORT=18080;SOCKS_PORT=11080;WATCHDOG_INTERVAL=0;WATCHDOG_FAILS=2;WATCHDOG_NOTICE_AFTER=60;WATCHDOG_MAX_BACKOFF=30;WATCHDOG_STARTUP_GRACE=0;WATCHDOG_IDLE_INTERVAL=60}
 $script:Pass=0;$script:Alerts=@();$script:Kills=0
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 $log=Get-Content (Join-Path $dir 'events.log') -Raw
 Assert (([regex]::Matches($log,'clash, PID 777')).Count -eq 1) "takeover not logged exactly once: $log"
 Assert (@($script:Alerts|Where-Object {$_ -eq 'takeover'}).Count -eq 1) "desktop alerts: $($script:Alerts -join ',')"
 Assert ($script:Alerts -contains 'restored') "no restored alert: $($script:Alerts -join ',')"
 Assert ($script:Kills -eq 0) 'the foreign program was killed'
 Assert (-not (Test-Path (Join-Path $dir 'takeover.json'))) 'takeover record left behind'
 $s=Get-RecoveryStatus $dir claude
 Assert ($s.phase -eq 'healthy' -and $s.event -eq 'restored') "final state: $($s|ConvertTo-Json -Compress)"
 'PASS: the owner alerts once, never kills the program, and recovers when the port frees'

 # 4) A live window names the program.
 Write-RecoveryStatus $dir takeover @{Pid=777;Name='clash';Port=18080}
 Write-RecoveryStatus $dir claude @{phase='recovering';generation=9;event='takeover'}
 $script:SSH_HOST='jp'
 $h=Start-RecoverySubscriber $dir claude
 Start-Sleep -Milliseconds 1500
 Stop-RecoverySubscriber $h
 Assert (@($h.Lines|Where-Object {$_ -match '^Another program \(clash, PID 777\) took proxy port 18080'}).Count -eq 1) "subscriber lines: $($h.Lines -join ' / ')"
 'PASS: a live window is told which program took the port'
} finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
