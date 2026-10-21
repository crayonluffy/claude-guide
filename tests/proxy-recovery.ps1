$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
 if ($f.Name -like '*-Recovery*' -or $f.Name -eq 'proxy-test') { Invoke-Expression $f.Extent.Text }
}
function Assert($Condition,$Message) { if (-not $Condition) {throw "FAIL: $Message"} }
Assert ([bool](Get-Command Get-RecoveryTransition -ErrorAction SilentlyContinue)) 'recovery state reducer is missing'
$s=$null
foreach ($case in @(@(0,'healthy','healthy','none'),@(5,'tunnel','recovering','lost'),@(64,'tunnel','recovering','progress'),@(65,'tunnel','prolonged','prolonged'),@(70,'tunnel','prolonged','none'),@(75,'healthy','healthy','restored'))) {
 $r=Get-RecoveryTransition -State $s -Sample @{kind=$case[1]} -Now $case[0] -NoticeAfter 60
 Assert ($r.State.phase -eq $case[2]) "phase at $($case[0])"
 Assert ($r.Event -eq $case[3]) "event at $($case[0])"
 $s=$r.State
}
$r=Get-RecoveryTransition -State $s -Sample @{kind='healthy'} -Now 1 -NoticeAfter 60
Assert ($r.State.observed_at -eq 75) 'backwards clock must not change elapsed time'
$script:Calls=@(); $script:HttpResult='200 403'; $script:HttpRc=0
function curl.exe {
 $script:Calls+=,@($args)
 if ($args -contains '--socks5-hostname') {$global:LASTEXITCODE=0;return '000 200'}
 $global:LASTEXITCODE=$script:HttpRc; return $script:HttpResult
}
$r=Test-RecoveryTransport -Provider claude -HttpPort 18080 -SocksPort 11080
Assert ($r.kind -eq 'healthy') 'API 403 after successful CONNECT is healthy transport'
Assert ($script:Calls[0] -contains '--noproxy=') 'ambient NO_PROXY must be overridden'
Assert ($script:Calls[0] -contains 'http://127.0.0.1:18080') 'proxy must be explicit'
$script:HttpResult='407 000';$script:HttpRc=56
Assert ((Test-RecoveryTransport codex 18080 11080).kind -eq 'proxy') 'CONNECT rejection is proxy failure'
$script:HttpResult='000 000';$script:HttpRc=52
Assert ((Test-RecoveryTransport claude 18080 11080).kind -eq 'proxy') 'healthy SOCKS means SSH need not restart'
Write-Host 'PASS: PowerShell recovery transitions, backwards time, and explicit proxy probes'

if (-not (Get-Command Open-RecoveryLock -ErrorAction SilentlyContinue)) { throw 'shared recovery ownership is missing' }
$ownerDir = Join-Path ([IO.Path]::GetTempPath()) ('recovery-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($ownerDir) | Out-Null
try {
    $lease = Open-RecoveryLock $ownerDir
    if (-not $lease) { throw 'first owner failed' }
    if (Open-RecoveryLock $ownerDir) { throw 'second owner acquired occupied lock' }
    $lease.Dispose()
    $lease = Open-RecoveryLock $ownerDir
    if (-not $lease) { throw 'lock not released' }
    $lease.Dispose()
    Write-RecoveryStatus $ownerDir claude @{ Phase='recovering'; Generation=1; Event='lost' }
    if ((Get-RecoveryStatus $ownerDir claude).Phase -ne 'recovering') { throw 'status not published' }
    Set-Content (Join-Path $ownerDir 'claude.json') '{broken'
    if ((Get-RecoveryStatus $ownerDir claude).Phase -ne 'unknown') { throw 'corrupt status treated as healthy' }
    if (Stop-RecoveryProcess -ProcessId $PID -Started 'bogus') { throw 'PID reuse identity accepted' }
} finally { Remove-Item $ownerDir -Recurse -Force }
Write-Host 'PASS: PowerShell exclusive owner, atomic status, corrupt data, and stale identity'
# Exercise the worker with fake SSH/probes and no real network/process/settings calls.
$ownerDir=Join-Path ([IO.Path]::GetTempPath()) ('recovery-worker-'+[guid]::NewGuid())
[IO.Directory]::CreateDirectory($ownerDir)|Out-Null
$script:CONF_KEYS=@('HTTP_PORT','SOCKS_PORT','WATCHDOG_INTERVAL','WATCHDOG_FAILS','WATCHDOG_NOTICE_AFTER','WATCHDOG_MAX_BACKOFF')
Write-RecoveryStatus $ownerDir descriptor @{HTTP_PORT=8080;SOCKS_PORT=1080;WATCHDOG_INTERVAL=0;WATCHDOG_FAILS=2;WATCHDOG_NOTICE_AFTER=60;WATCHDOG_MAX_BACKOFF=30}
function Test-RecoveryPortConflict {return $false}
$script:SshStarts=0; $script:ProbeCalls=0
function Start-RecoverySsh {
 $script:SshStarts++
 return [pscustomobject]@{Id=99999999;HasExited=$false;StartTime=[datetime]::UtcNow} | Add-Member ScriptMethod Dispose {} -PassThru
}
function Test-RecoveryTransport {
 param($Provider,$HttpPort,$SocksPort)
 if ($HttpPort -ne 8080 -or $SocksPort -ne 1080) {throw 'worker changed ports'}
 $script:ProbeCalls++
 if ($script:ProbeCalls -ge 8) { [IO.File]::WriteAllText((Join-Path $ownerDir 'stopped'),'stop') }
 return @{kind='proxy'}
}
try {
 Invoke-RecoveryWorker (Join-Path $ownerDir 'descriptor.json')
 Assert ($script:SshStarts -eq 1) 'proxy failure must not restart SSH'
 Assert ((Get-RecoveryStatus $ownerDir codex).failure_kind -eq 'proxy') 'both providers monitored'
} finally {Remove-Item $ownerDir -Recurse -Force}
Write-Host 'PASS: PowerShell worker preserves fixed ports during proxy outage and honors stop'
if (-not (Get-Command Start-RecoverySubscriber -ErrorAction SilentlyContinue)) {throw 'live recovery subscriber is missing'}
foreach ($f in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
 if ($f.Name -in @('proxy-up','cc','cx','_split-launch-args')) { Invoke-Expression $f.Extent.Text }
}
function tunnel-start {}
function Get-TunnelHealth {return @{Status='ok'}}
function proxy-on {$env:HTTPS_PROXY='http://127.0.0.1:8080'}
$script:AppCalls=0; $script:TestKind='proxy'; $script:TUNNEL_WATCHDOG=0
function Test-RecoveryTransport {return @{kind=$script:TestKind}}
function claude {$script:AppCalls++;$script:AppArgs=@($args);$global:LASTEXITCODE=17}
cc --no-verify --safe 'hello world'
Assert ($script:AppCalls -eq 0) 'NoVerify bypassed mandatory preflight'
$script:TestKind='healthy'
cc --no-verify --safe 'hello world'
Assert ($script:AppCalls -eq 1) 'healthy launch missing'
Assert ($script:AppArgs.Count -eq 1 -and $script:AppArgs[0] -eq 'hello world') 'arguments changed'
Assert ($global:LASTEXITCODE -eq 17) 'exit code changed by cleanup'
Write-Host 'PASS: PowerShell mandatory preflight, arguments, and native exit code'
if (-not (Get-Command proxy-test -ErrorAction SilentlyContinue)) {throw 'safe simulation is missing'}
function Wait-RecoveryDemo {}
function curl.exe {throw 'demo called live curl'}
function Start-RecoverySsh {throw 'demo called live SSH'}
foreach ($scenario in @('recover','prolonged')) {
 $demo=@(proxy-test $scenario --fast)
 Assert (($demo -match 'Proxy connection lost').Count -eq 1) 'lost warning missing or duplicated'
 Assert (($demo -match 'Proxy connection restored').Count -eq 1) 'restored warning missing'
 Assert (($demo -notmatch '^\[SIMULATION\]').Count -eq 0) 'unlabelled demo output'
 if ($scenario -eq 'prolonged') {
  Assert (($demo -match 'session has not been terminated').Count -eq 1) 'prolonged warning must appear once'
  Assert (($demo -match 't=75.*retry').Count -eq 1) 'retries stopped at grace threshold'
 }
}
try {proxy-test unknown;throw 'invalid scenario accepted'} catch {if ($_ -notmatch 'usage:') {throw}}
Write-Host 'PASS: PowerShell isolated simulations and retries beyond grace period'
