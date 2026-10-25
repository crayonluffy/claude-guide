$ErrorActionPreference='Stop'
# Regression tests for the 2.7.1 PowerShell hotfix. Unlike the other recovery
# tests, the probe cases run the REAL curl binary (only against 127.0.0.1), so an
# argument curl rejects (exit 2) fails here instead of hiding behind a mock.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -like '*-Recovery*'){Invoke-Expression $f.Extent.Text}}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}

$real=(Get-Command curl.exe,curl -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1).Source
if(-not $real){throw 'curl is required for the real-argument probe tests'}
$script:Exits=@()
function curl.exe {& $real @args; $script:Exits+=$LASTEXITCODE}
function Get-FreePort {$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$l.Start();$p=$l.LocalEndpoint.Port;$l.Stop();return $p}

# A fake HTTP proxy: answers every CONNECT with 200 and hangs up, so curl gets
# http_connect=200 and then fails the TLS handshake without touching the network.
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
$fakePort=$listener.LocalEndpoint.Port
$ps=[powershell]::Create()
$null=$ps.AddScript({param($l,$log)
 while($true){
  $c=$l.AcceptTcpClient();$s=$c.GetStream();$buf=New-Object byte[] 1024;$n=$s.Read($buf,0,1024)
  $log.Add([Text.Encoding]::ASCII.GetString($buf,0,$n).Split("`r")[0])
  $r=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection established`r`n`r`n");$s.Write($r,0,$r.Length);$c.Close()
 }}).AddArgument($listener).AddArgument(($seen=[Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())))
$null=$ps.BeginInvoke()
$savedEnv=@{};foreach($k in 'HTTPS_PROXY','HTTP_PROXY','NO_PROXY','no_proxy','https_proxy','http_proxy','ALL_PROXY'){$savedEnv[$k]=[Environment]::GetEnvironmentVariable($k)}
try {
 $closed=Get-FreePort
 $r=Test-RecoveryTransport claude $closed (Get-FreePort)
 Assert ($script:Exits -notcontains 2) "curl rejected the probe arguments (exit 2): exits=$($script:Exits -join ',')"
 Assert ($r.curl_exit -eq 7) "closed HTTP port must be 'could not connect' (7), got $($r.curl_exit)"
 Assert ($r.kind -eq 'tunnel') "nothing listening must classify as tunnel, got $($r.kind)"
 Assert ($script:Exits.Count -eq 2) 'dead HTTP forward must be cross-checked over SOCKS'

 # Ambient settings must not steer the probe: NO_PROXY=* would send it DIRECT,
 # and HTTPS_PROXY would hijack the SOCKS cross-check.
 $env:NO_PROXY='*';$env:no_proxy='*';$env:HTTPS_PROXY="http://127.0.0.1:$fakePort";$env:HTTP_PROXY=$env:HTTPS_PROXY
 $script:Exits=@();$seen.Clear()
 $r=Test-RecoveryTransport codex $fakePort (Get-FreePort)
 Assert ($script:Exits -notcontains 2) "curl rejected the probe arguments (exit 2): exits=$($script:Exits -join ',')"
 Assert ($r.connect_code -eq '200') "CONNECT through the explicit proxy expected, got $($r.connect_code) (curl $($r.curl_exit))"
 Assert ($r.kind -eq 'proxy') "CONNECT ok but no TLS must classify as proxy, got $($r.kind)"
 Assert (($seen|Where-Object {$_ -like 'CONNECT api.openai.com:443*'}).Count -eq 1) "probe bypassed the explicit proxy: $($seen -join ' / ')"

 $script:Exits=@();$seen.Clear()
 $r=Test-RecoveryTransport claude (Get-FreePort) (Get-FreePort)
 Assert ($r.kind -eq 'tunnel') "with HTTPS_PROXY in the env a dead tunnel must still be 'tunnel', got $($r.kind)"
 Assert ($seen.Count -eq 0) "SOCKS cross-check used the ambient HTTP proxy: $($seen -join ' / ')"
} finally {
 foreach($k in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($k,$savedEnv[$k])}
 $listener.Stop();$ps.Dispose()
}
Write-Host 'PASS: probe arguments accepted by real curl, explicit proxy wins over NO_PROXY/HTTPS_PROXY'

# --- worker loop: fake SSH, fake clock, no real processes or network ---------
$script:CONF_KEYS=@('HTTP_PORT','SOCKS_PORT','WATCHDOG_INTERVAL','WATCHDOG_FAILS','WATCHDOG_NOTICE_AFTER','WATCHDOG_MAX_BACKOFF','WATCHDOG_STARTUP_GRACE')
$script:DESKTOP_NOTIFICATIONS='off'
$script:WATCHDOG_IDLE_INTERVAL=0   # an idle owner would otherwise wait 60s per healthy pass
function Test-RecoveryPortConflict {return $false}
function New-FakeSsh {[pscustomobject]@{Id=99999999;HasExited=$false;StartTime=[datetime]::UtcNow}|Add-Member ScriptMethod Dispose {} -PassThru|Add-Member ScriptMethod WaitForExit {param($ms)$true} -PassThru}
function Start-RecoverySsh {$script:SshStarts++;return (New-FakeSsh)}
# Only kills while running count; the shutdown in the worker's finally block is expected.
function Stop-RecoveryProcess {param($ProcessId,$Started)if(-not (Test-Path (Join-Path $dir 'stopped'))){$script:Kills++};return $true}
function New-WorkerDir {
 $d=Join-Path ([IO.Path]::GetTempPath()) ('recovery-hotfix-'+[guid]::NewGuid());[IO.Directory]::CreateDirectory($d)|Out-Null
 Write-RecoveryStatus $d descriptor @{HTTP_PORT=8080;SOCKS_PORT=1080;WATCHDOG_INTERVAL=0;WATCHDOG_FAILS=2;WATCHDOG_NOTICE_AFTER=60;WATCHDOG_MAX_BACKOFF=30;WATCHDOG_STARTUP_GRACE=20}
 return $d
}

# 1) One exception inside the loop must not end the worker (it used to fall into
#    the finally block, kill ssh and leave every session without recovery).
$dir=New-WorkerDir;$script:SshStarts=0;$script:Kills=0;$script:Probe=0;$script:T=0
function Get-RecoveryTime {$script:T+=5;return $script:T}
function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort)
 $script:Probe++
 if($script:Probe -eq 3){throw [IO.IOException]::new('The process cannot access the file because it is being used by another process.')}
 if($script:Probe -ge 10){[IO.File]::WriteAllText((Join-Path $dir 'stopped'),'stop')}
 return @{kind='healthy'}}
try {
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ($script:Probe -ge 10) "worker stopped after an exception (probes: $($script:Probe))"
 Assert ($script:SshStarts -eq 1) "exception restarted ssh ($($script:SshStarts) starts)"
 Assert ((Get-Content (Join-Path $dir 'events.log') -Raw) -match 'being used by another process') 'exception not logged'
} finally {Remove-Item $dir -Recurse -Force}
Write-Host 'PASS: worker survives an exception in its loop'

# 2) A fresh ssh that is still connecting is not "lost": no outage event, no
#    desktop alert, no kill until the startup grace has passed.
function New-RecoveryDesktopContext {[pscustomobject]@{Backend='tray';LastSubmission='not-tested'}}
function Get-RecoveryDesktopStatus {param($Context)@{backend=$Context.Backend}}
function Stop-RecoveryDesktopContext {param($Context)}
function Send-RecoveryDesktopNotification {param($Context,$Event,$Scope)$script:Alerts+=$Event;return $true}
$dir=New-WorkerDir;$script:SshStarts=0;$script:Kills=0;$script:Probe=0;$script:T=-5;$script:Alerts=@()
function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort)
 $script:Probe++
 if($script:T -ge 40){[IO.File]::WriteAllText((Join-Path $dir 'stopped'),'stop')}
 if($script:T -lt 15){return @{kind='tunnel'}}   # slow link: up after ~15s
 return @{kind='healthy'}}
try {
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ($script:Kills -eq 0) "ssh killed while still connecting ($($script:Kills) kills)"
 Assert ($script:SshStarts -eq 1) "ssh restarted during startup ($($script:SshStarts) starts)"
 $log=Join-Path $dir 'events.log'
 Assert (-not (Test-Path $log) -or -not ((Get-Content $log -Raw) -match 'connection lost')) 'startup reported as an outage'
 Assert ((Get-RecoveryStatus $dir claude).phase -eq 'healthy') 'not healthy once connected'
 Assert ($script:Alerts.Count -eq 0) "desktop alert during startup: $($script:Alerts -join ',')"
} finally {Remove-Item $dir -Recurse -Force}

# ...but an ssh that never comes up IS restarted once the grace is over.
$dir=New-WorkerDir;$script:SshStarts=0;$script:Kills=0;$script:T=-5;$script:Alerts=@()
function Test-RecoveryTransport {param($Provider,$HttpPort,$SocksPort)
 if($script:T -ge 60){[IO.File]::WriteAllText((Join-Path $dir 'stopped'),'stop')}
 return @{kind='tunnel'}}
try {
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ($script:Kills -ge 1) 'hung ssh never restarted after the grace period'
 Assert ((Get-RecoveryStatus $dir claude).phase -ne 'healthy') 'hung tunnel reported healthy'
 Assert ($script:Alerts[0] -eq 'lost') "hung tunnel raised no desktop alert: $($script:Alerts -join ',')"
} finally {Remove-Item $dir -Recurse -Force}
Write-Host 'PASS: startup grace - no false outage or kill while ssh connects; hung ssh still restarted'
