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
Assert ($script:Calls[0] -contains '--noproxy') 'ambient NO_PROXY must be overridden'
Assert ($script:Calls[0] -contains 'http://127.0.0.1:18080') 'proxy must be explicit'
$script:HttpResult='407 000';$script:HttpRc=56
Assert ((Test-RecoveryTransport codex 18080 11080).kind -eq 'proxy') 'CONNECT rejection is proxy failure'
$script:HttpResult='000 000';$script:HttpRc=52
Assert ((Test-RecoveryTransport claude 18080 11080).kind -eq 'proxy') 'healthy SOCKS means SSH need not restart'
Write-Host 'PASS: PowerShell recovery transitions, backwards time, and explicit proxy probes'
