$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($f.Name -like '*-Recovery*') { Invoke-Expression $f.Extent.Text }
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('terminal-notices-'+[guid]::NewGuid())
$script:SSH_HOST='test-node'
$script:TERMINAL_NOTIFICATIONS=$null
$handle=$null
try {
    $null=[IO.Directory]::CreateDirectory($scratch)
    Write-RecoveryStatus $scratch claude @{phase='healthy';generation=0;event='none'}
    $handle=Start-RecoverySubscriber $scratch claude
    Start-Sleep -Milliseconds 700
    Write-RecoveryStatus $scratch claude @{phase='recovering';generation=1;event='lost'}
    Start-Sleep -Milliseconds 700
    Write-RecoveryStatus $scratch claude @{phase='healthy';generation=2;event='restored'}
    Start-Sleep -Milliseconds 700
    Assert ($handle.Lines.Count -eq 0) "Brief outage interrupted terminal: $($handle.Lines -join ' / ')"
    Write-RecoveryStatus $scratch claude @{phase='prolonged';generation=4;event='progress'}
    Start-Sleep -Milliseconds 700
    Write-RecoveryStatus $scratch claude @{phase='prolonged';generation=5;event='progress'}
    Start-Sleep -Milliseconds 700
    Write-RecoveryStatus $scratch claude @{phase='healthy';generation=6;event='restored'}
    Start-Sleep -Milliseconds 700
    Assert (@($handle.Lines | Where-Object { $_ -match 'session has not been terminated' }).Count -eq 1) 'Missing or repeated prolonged warning'
    Assert (@($handle.Lines | Where-Object { $_ -match 'connection restored' }).Count -eq 1) 'Missing or repeated recovery'
    Assert ($handle.Lines.Count -eq 2) 'Unexpected routine notices'
    $session=$handle.Session
    Stop-RecoverySubscriber $handle; $handle=$null
    Assert (-not (Test-Path -LiteralPath $session)) 'Session registration was not cleaned up'
    'PASS: quiet real subscriber suppresses brief drops, warns once and restores once'

    $script:TERMINAL_NOTIFICATIONS='off'
    $handle=Start-RecoverySubscriber $scratch claude
    Start-Sleep -Milliseconds 700
    Write-RecoveryStatus $scratch claude @{phase='prolonged';generation=7;event='prolonged'}
    Start-Sleep -Milliseconds 700
    Assert ($handle.Lines.Count -eq 0) 'Off mode emitted a routine warning'
    Write-RecoveryStatus $scratch ssh @{class='auth'}
    Write-RecoveryStatus $scratch takeover @{Pid=777;Name='test-process';Port=18080}
    Write-RecoveryStatus $scratch claude @{phase='prolonged';generation=8;event='takeover'}
    Start-Sleep -Milliseconds 700
    Assert (@($handle.Lines | Where-Object { $_ -match 'SSH login to test-node was refused' }).Count -eq 1) 'Off mode hid authentication warning'
    Assert (@($handle.Lines | Where-Object { $_ -match '^Another program \(test-process, PID 777\) took proxy port 18080' }).Count -eq 1) 'Off mode hid takeover warning'
    'PASS: off mode silences routine notices while retaining actionable warnings'
} finally {
    if ($handle) { Stop-RecoverySubscriber $handle }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($case in @(
    @('quiet','recovering','lost',$false,$false,'none'),
    @('quiet','healthy','restored',$false,$false,'none'),
    @('quiet','prolonged','prolonged',$false,$true,'prolonged'),
    @('quiet','prolonged','progress',$true,$true,'none'),
    @('quiet','healthy','restored',$true,$false,'restored'),
    @('quiet','healthy','restored',$false,$false,'none'),
    @('quiet','prolonged','progress',$false,$true,'prolonged'),
    @('quiet','prolonged','takeover',$false,$false,'takeover'),
    @('off','prolonged','prolonged',$false,$false,'none'),
    @('off','healthy','restored',$false,$false,'none'),
    @('off','recovering','takeover',$false,$false,'takeover'),
    @('verbose','recovering','lost',$false,$false,'lost'),
    @('verbose','prolonged','progress',$false,$false,'progress'),
    @('verbose','healthy','restored',$false,$false,'restored'),
    @('invalid','recovering','lost',$false,$false,'none')
)) {
    $r=Get-RecoveryTerminalTransition $case[0] $case[1] $case[2] $case[3]
    Assert ($r.Warned -eq $case[4] -and $r.Event -eq $case[5]) ($case -join ',')
}
'PASS: terminal policies preserve critical alerts and support verbose/off modes'
