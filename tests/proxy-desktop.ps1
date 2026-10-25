$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -like '*-Recovery*' -or $f.Name -eq 'proxy-notify'){Invoke-Expression $f.Extent.Text}}
function Assert($ok,$message){if(-not $ok){throw "FAIL: $message"}}
Assert ([bool](Get-Command Get-RecoveryDesktopTransition -ErrorAction SilentlyContinue)) 'desktop outage aggregation is missing'
$s=$null
foreach($case in @(@(0,'healthy','healthy','none'),@(5,'recovering','recovering','lost'),@(65,'prolonged','healthy','prolonged'),@(66,'healthy','recovering','none'),@(80,'healthy','healthy','restored'))){
 $r=Get-RecoveryDesktopTransition -State $s -States @{claude=@{phase=$case[1]};codex=@{phase=$case[2]}} -Now $case[0] -NoticeAfter 60
 Assert ($r.Event -eq $case[3]) "desktop event at $($case[0])"
 $s=$r.State
}
'PASS: combined desktop outage, partial recovery, and one prolonged warning'
$script:DESKTOP_NOTIFICATIONS='off'
$script:WATCHDOG_IDLE_INTERVAL=0   # an idle owner would otherwise wait 60s per healthy pass
$c=New-RecoveryDesktopContext
Assert ($c.Backend -eq 'off') 'off switch ignored'
Assert (-not (Send-RecoveryDesktopNotification $c lost 'Claude and Codex')) 'off context delivered notification'
Stop-RecoveryDesktopContext $c
$queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$ctx=@{Backend='windows-tray';Queue=$queue;Sync=@{Ready=$true;Error=''};LastSubmission='not-tested'}
Assert (Send-RecoveryDesktopNotification $ctx lost Codex) 'notification not queued'
$item=$null;Assert ($queue.TryDequeue([ref]$item)) 'native UI queue empty'
Assert ($item.Title -match 'connection lost') 'lost title missing'
Assert ($item.Body -match 'Sessions stay open') 'session control text missing'
Assert (-not (Send-RecoveryDesktopNotification $ctx progress Codex)) 'periodic progress spammed desktop'
Assert ($queue.IsEmpty) 'progress notification queued'
$ctx.Sync.Ready=$false;$ctx.Async=[pscustomobject]@{IsCompleted=$false}
Assert (Send-RecoveryDesktopNotification $ctx prolonged Codex) 'cold-start UI initialization dropped an outage event'
$item=$null;$null=$queue.TryDequeue([ref]$item)
Assert ($item.Event -eq 'prolonged') 'cold-start alert was not queued for the UI thread'
$ctx.Sync.Ready=$true

Assert (Send-RecoveryDesktopNotification $ctx test 'Claude and Codex') 'test notification missing'
$item=$null;$null=$queue.TryDequeue([ref]$item)
Assert ($item.Tooltip -match 'test' -and $item.Tooltip -notmatch 'connected') 'test tooltip falsely claimed proxy connection state'
$ctx.Sync.Error='simulated desktop rejection'
Assert (-not (Send-RecoveryDesktopNotification $ctx restored Codex)) 'failed backend claimed submission'
'PASS: Windows notification queue, quiet progress, opt-out, and failure fallback'
# On Linux, exercising the actual Windows initialization path must fail safely
# at the missing WinForms backend and still dispose its real runspace resources.
if ($env:OS -ne 'Windows_NT' -and [Environment]::UserInteractive) {
 $oldOs=$env:OS;$native=$null
 try {
  $env:OS='Windows_NT';$script:DESKTOP_NOTIFICATIONS='auto'
  $native=New-RecoveryDesktopContext
  Assert ((Get-RecoveryDesktopStatus $native).submission -eq 'failed' -or $native.Backend -eq 'unavailable') 'unsupported native UI backend was reported ready'
  Stop-RecoveryDesktopContext $native
  Assert ($native.Closed) 'real native initialization failure did not dispose its context'
 } finally {
  Stop-RecoveryDesktopContext $native
  $env:OS=$oldOs;$script:DESKTOP_NOTIFICATIONS='off'
 }
 'PASS: actual UI initialization failure is contained and its runspace is disposed'
}

# Real worker lifecycle with a fake native context; no GUI/network/process mutations.
$dir=Join-Path ([IO.Path]::GetTempPath()) ('desktop-worker-'+[guid]::NewGuid())
[IO.Directory]::CreateDirectory($dir)|Out-Null
$script:CONF_KEYS=@('HTTP_PORT','SOCKS_PORT','WATCHDOG_INTERVAL','WATCHDOG_FAILS','WATCHDOG_NOTICE_AFTER','WATCHDOG_MAX_BACKOFF')
Write-RecoveryStatus $dir descriptor @{HTTP_PORT=18080;SOCKS_PORT=11080;WATCHDOG_INTERVAL=0;WATCHDOG_FAILS=2;WATCHDOG_NOTICE_AFTER=60;WATCHDOG_MAX_BACKOFF=30}
$script:DesktopTick=0
$script:TestDesktopContext=@{Backend='windows-tray';Reason='test adapter';Queue=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]');Sync=@{Ready=$true;Error='';LastSubmission='not-tested'};LastSubmission='not-tested';Disposed=$false}
function New-RecoveryDesktopContext {return $script:TestDesktopContext}
function Stop-RecoveryDesktopContext {param($Context)$Context.Disposed=$true}
function Test-RecoveryPortConflict {return $false}
function Start-RecoverySsh {return ([pscustomobject]@{Id=99999999;HasExited=$false;StartTime=[datetime]::UtcNow}|Add-Member ScriptMethod Dispose {} -PassThru)}
function Get-RecoveryTime {$script:DesktopTick++;return @(0,5,65,80)[[Math]::Min(3,$script:DesktopTick-1)]}
function Test-RecoveryTransport {
 param($Provider,$HttpPort,$SocksPort)
 if($script:DesktopTick -ge 4 -and $Provider -eq 'codex'){[IO.File]::WriteAllText((Join-Path $dir 'stopped'),'stop')}
 return @{kind=$(if($script:DesktopTick -eq 1 -or $script:DesktopTick -ge 4){'healthy'}else{'proxy'})}
}
try {
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ($script:TestDesktopContext.Queue.Count -eq 3) 'shared owner must emit lost/prolonged/restored exactly once'
 Assert ($script:TestDesktopContext.Disposed) 'desktop resources were not disposed at shutdown'
 Assert ((Get-RecoveryStatus $dir desktop).submission -eq 'queued') 'owner notification status not recorded'
 Remove-Item (Join-Path $dir 'stopped')
 $script:DesktopTick=0;$discard=$null;while($script:TestDesktopContext.Queue.TryDequeue([ref]$discard)){};$script:TestDesktopContext.Disposed=$false
 $script:TestDesktopContext.Sync.Error='simulated desktop service rejection'
 Invoke-RecoveryWorker (Join-Path $dir 'descriptor.json')
 Assert ((Get-RecoveryStatus $dir desktop).submission -eq 'failed') 'failed native backend claimed successful delivery'
 Assert ((Get-RecoveryStatus $dir codex).phase -eq 'healthy') 'UI failure prevented transport recovery'
 Assert ($script:TestDesktopContext.Disposed) 'failed desktop context was not cleaned up'
}finally{Remove-Item $dir -Recurse -Force}
'PASS: actual owner lifecycle groups desktop alerts and disposes notifier independently'
$demo=$ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'proxy-test'},$false)[0]
Invoke-Expression $demo.Extent.Text
function Wait-RecoveryDemo {}
$script:DemoAlerts=@()
function Send-RecoveryDesktopNotification {param($Context,$Event,$Providers,[switch]$Simulation)$script:DemoAlerts+=@{Event=$Event;Simulation=[bool]$Simulation};return $true}
$null=proxy-test prolonged --fast
Assert ($script:DemoAlerts.Count -eq 0) 'default demo called native notification adapter'
$null=proxy-test prolonged --fast --desktop
Assert ($script:DemoAlerts.Count -eq 3) 'desktop demo did not emit three transitions'
Assert (($script:DemoAlerts|Where-Object{-not $_.Simulation}).Count -eq 0) 'demo desktop alert was not labelled as simulated'
'PASS: opt-in desktop demo and untouched default isolation'

# An interrupted demo disposes its separate notifier without closing other sessions.
$script:TestDesktopContext.Disposed=$false
function Wait-RecoveryDemo {throw 'simulated demo cancellation'}
try {$null=proxy-test prolonged --fast --desktop;throw 'demo ignored cancellation'}catch{if($_ -notmatch 'simulated demo cancellation'){throw}}
Assert ($script:TestDesktopContext.Disposed) 'cancelled demo leaked its native notifier'
'PASS: cancelled desktop demo disposes its own notifier'
