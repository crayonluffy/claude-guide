$ErrorActionPreference='Stop'
# An ssh that exits is classified from its own stderr, so the owner can say WHY
# the tunnel is down (and how to fix it) and stop hammering the server with a
# login that cannot succeed. Same table as tests/proxy-ssh-class.sh.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -like '*-Recovery*'){Invoke-Expression $f.Extent.Text}}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('ssh-class-'+[guid]::NewGuid()); $null=New-Item -ItemType Directory $scratch
try {
 # 1) Classifier table.
 $err=Join-Path $scratch 'err'
 foreach($c in @(
  @('auth','user@jp: Permission denied (publickey).'),
  @('auth','Too many authentication failures'),
  @('auth','Load key "C:\\Users\\u\\.ssh\\id": bad permissions'),
  @('hostkey','Host key verification failed.'),
  @('hostkey','@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@'),
  @('forward','bind [127.0.0.1]:8080: Address already in use'),
  @('forward','channel_setup_fwd_listener_tcpip: cannot listen to port: 1080'),
  @('forward','Could not request local forwarding.'),
  @('network','ssh: connect to host jp port 22: Connection timed out'),
  @('network','ssh: Could not resolve hostname jp: No such host is known.'),
  @('network','ssh: connect to host jp port 22: Connection refused'),
  @('network','Connection closed by 1.2.3.4 port 22'),
  @('unknown','something nobody has seen before'),
  @('unknown',''))) {
  [IO.File]::WriteAllText($err,$c[1])
  $got=Get-RecoverySshClass $err
  Assert ($got -eq $c[0]) "expected $($c[0]), got $got for: $($c[1])"
 }
 Assert ((Get-RecoverySshClass (Join-Path $scratch 'missing')) -eq 'unknown') 'missing file must be unknown'
 'PASS: ssh stderr classified as auth, hostkey, forward, network or unknown'

 # 2) Each class says how to fix it and names the server.
 Assert ((Get-RecoverySshHint auth jp) -match 'ssh-add' -and (Get-RecoverySshHint auth jp) -match 'jp') 'auth hint'
 Assert ((Get-RecoverySshHint hostkey jp) -match 'ssh-keygen -R jp') 'hostkey hint'
 Assert ((Get-RecoverySshHint network jp) -match 'Retrying') 'network hint'
 'PASS: each failure class has a one-line fix'

 # 3) Worker with a fake ssh that exits at once with a refused login.
 $script:CONF_KEYS=@('SSH_HOST','HTTP_PORT','SOCKS_PORT','WATCHDOG_INTERVAL','WATCHDOG_FAILS','WATCHDOG_NOTICE_AFTER','WATCHDOG_MAX_BACKOFF','WATCHDOG_STARTUP_GRACE','WATCHDOG_IDLE_INTERVAL')
 $script:DESKTOP_NOTIFICATIONS='off'
 function Test-RecoveryPortConflict {return $null}
 function Get-RecoverySessionCount {param($Identity) return 1}
 function Stop-RecoveryProcess {param($ProcessId,$Started) return $true}
 function Start-RecoverySsh {param([string]$ErrFile)
  $script:SshStarts++
  [IO.File]::WriteAllText($ErrFile,$script:FakeErr)
  return ([pscustomobject]@{Id=99999999;HasExited=$true;ExitCode=255;StartTime=[datetime]::UtcNow}|Add-Member ScriptMethod Dispose {} -PassThru|Add-Member ScriptMethod WaitForExit {param($ms)$true} -PassThru)
 }
 function Get-RecoveryTime {$script:T+=5;return $script:T}
 function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort)
  if($script:T -ge 25){
   if(Test-Path (Join-Path $dir 'ssh.json')){Copy-Item (Join-Path $dir 'ssh.json') (Join-Path $scratch "status.$(Split-Path -Leaf $dir)")}
   [IO.File]::WriteAllText((Join-Path $dir 'stopped'),'stop')
  }
  return @{kind='tunnel'}}
 function New-WorkerDir([string]$Name) {
  $d=Join-Path $scratch $Name;[IO.Directory]::CreateDirectory($d)|Out-Null
  Write-RecoveryStatus $d descriptor @{SSH_HOST='jp';HTTP_PORT=18080;SOCKS_PORT=11080;WATCHDOG_INTERVAL=0;WATCHDOG_FAILS=2;WATCHDOG_NOTICE_AFTER=60;WATCHDOG_MAX_BACKOFF=30;WATCHDOG_STARTUP_GRACE=0;WATCHDOG_IDLE_INTERVAL=60}
  return $d
 }
 $dir=New-WorkerDir 'auth';$script:T=-5;$script:SshStarts=0;$script:FakeErr='user@jp: Permission denied (publickey).'
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ($script:SshStarts -eq 1) "refused login retried too soon ($($script:SshStarts) starts)"
 $st=[IO.File]::ReadAllText((Join-Path $scratch 'status.auth'))|ConvertFrom-Json
 Assert ($st.class -eq 'auth' -and $st.exit -eq 255) "ssh status: $($st|ConvertTo-Json -Compress)"
 Assert ((Get-RecoveryStatus $dir claude).next_retry -ge 30) 'auth failure must wait the maximum backoff'
 $log=Get-Content (Join-Path $dir 'events.log') -Raw
 Assert ($log -match 'SSH login to jp was refused' -and $log -match 'Permission denied') "log lacks hint/output: $log"
 Assert (-not (Test-Path (Join-Path $dir 'ssh.json'))) 'ssh status left behind after shutdown'
 'PASS: refused login is reported at once and retried only after the maximum backoff'

 $dir=New-WorkerDir 'net';$script:T=-5;$script:SshStarts=0;$script:FakeErr='ssh: connect to host jp port 22: Connection timed out'
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ((([IO.File]::ReadAllText((Join-Path $scratch 'status.net'))|ConvertFrom-Json).class) -eq 'network') 'network class'
 Assert ($script:SshStarts -ge 3) "network failures must keep the normal pace ($($script:SshStarts) starts)"
 'PASS: network failures keep retrying at the normal pace'

 # 4) A live window is told once that its login was refused.
 $dir=New-WorkerDir 'sub'
 Write-RecoveryStatus $dir ssh @{class='auth';exit=255;at=5;line='Permission denied (publickey).'}
 $script:SSH_HOST='jp'
 $h=Start-RecoverySubscriber $dir claude
 Start-Sleep -Milliseconds 1500
 Stop-RecoverySubscriber $h
 Assert (@($h.Lines|Where-Object {$_ -match 'SSH login to jp was refused'}).Count -eq 1) "subscriber lines: $($h.Lines -join ' / ')"
 'PASS: a live window is told once that its login was refused'
} finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
