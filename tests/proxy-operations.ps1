param([string]$Mode,[string]$Scratch)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$profileFile=Join-Path $repo 'scripts/claude-proxy.ps1'
$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($profileFile,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
foreach($definition in $ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $definition.Extent.Text}
if(-not (Get-Command Invoke-RecoveryOperation -ErrorAction SilentlyContinue)){throw 'FAIL: operation coordinator is missing'}
function Assert($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"}}
function Await-File([string]$Path){for($i=0;$i -lt 800 -and -not (Test-Path $Path);$i++){Start-Sleep -Milliseconds 25};Assert (Test-Path $Path) "missing $Path"}
if(-not $Scratch){$Scratch=Join-Path ([IO.Path]::GetTempPath()) ('proxy-operations-'+[guid]::NewGuid());$null=[IO.Directory]::CreateDirectory($Scratch)}
function Get-RecoveryRoot {Join-Path $script:Scratch 'state/recovery'}
$exe=Join-Path $PSHOME ('pwsh'+$(if($env:OS -eq 'Windows_NT'){'.exe'}else{''}))
$testFile=$PSCommandPath
function Start-TestChild([string]$Name){
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-File',('"'+$testFile+'"'),'-Mode',$Name,'-Scratch',('"'+$Scratch+'"')) -PassThru -RedirectStandardOutput (Join-Path $Scratch "$Name.out") -RedirectStandardError (Join-Path $Scratch "$Name.err")
}
function Enter-Critical {param([string]$Label)
    [IO.File]::AppendAllText((Join-Path $Scratch 'order'),"enter-$Label`n")
    [IO.File]::WriteAllText((Join-Path $Scratch "$Label.entered"),'')
    if($Label -eq 'first'){Await-File (Join-Path $Scratch 'release')}
    [IO.File]::AppendAllText((Join-Path $Scratch 'order'),"leave-$Label`n")
}
function Hold-Operation {[IO.File]::WriteAllText((Join-Path $Scratch 'holder.entered'),'');Await-File (Join-Path $Scratch 'holder.release')}
function Release-Early {Exit-RecoveryOperation;$p=Start-TestChild holder;[IO.File]::WriteAllText((Join-Path $Scratch 'holder.pid'),"$($p.Id)");Await-File (Join-Path $Scratch 'holder.entered')}
if($Mode){
    [IO.File]::WriteAllText((Join-Path $Scratch "$Mode.attempted"),'')
    switch($Mode){
        {$_ -in @('first','second','third')} {Invoke-RecoveryOperation -Operation Enter-Critical -Parameters @{Label=$Mode}}
        holder {Invoke-RecoveryOperation -Operation Hold-Operation}
        early {Invoke-RecoveryOperation -Operation Release-Early;[IO.File]::WriteAllText((Join-Path $Scratch 'early.done'),'')}
        crash {function Crash-Operation {Stop-Process -Id $PID -Force};Invoke-RecoveryOperation -Operation Crash-Operation}
        timeout {function Start-Sleep {param($Milliseconds,$Seconds)};$rejected=$false;try{Invoke-RecoveryOperation -Operation Enter-Critical -Parameters @{Label='timeout'}}catch{$rejected=$_.Exception.Message -match 'operation'};Assert $rejected 'occupied operation did not time out'}
    }
    exit
}
$children=@()
try {
    $first=Start-TestChild first;$children+=$first;Await-File (Join-Path $Scratch 'first.entered')
    $second=Start-TestChild second;$children+=$second;Await-File (Join-Path $Scratch 'second.attempted')
    Start-Sleep -Milliseconds 200;Assert (-not (Test-Path (Join-Path $Scratch 'second.entered'))) 'overlapping critical sections'
    [IO.File]::WriteAllText((Join-Path $Scratch 'release'),'')
    $first.WaitForExit();$second.WaitForExit();Assert ($first.ExitCode -eq 0 -and $second.ExitCode -eq 0) 'child failed'
    Assert (([IO.File]::ReadAllText((Join-Path $Scratch 'order')) -replace "`r",'') -eq "enter-first`nleave-first`nenter-second`nleave-second`n") 'operation order'
    'PASS: unrelated PowerShell processes serialize operations'
    function Inner {Assert (Test-RecoveryOperation) 'nested operation lost ownership'}
    function Nested {Invoke-RecoveryOperation -Operation Inner;Invoke-RecoveryOperation -Operation Inner}
    Invoke-RecoveryOperation -Operation Nested
    Assert (-not (Test-RecoveryOperation)) 'outer operation remained held'
    function Fail-Operation {throw 'expected operation failure'}
    $failed=$false;try{Invoke-RecoveryOperation -Operation Fail-Operation}catch{$failed=$_.Exception.Message -eq 'expected operation failure'}
    Assert $failed 'operation failure was lost'
    Invoke-RecoveryOperation -Operation Inner
    'PASS: nested operations and failure cleanup'
    function Arguments-Operation {param([string]$Named) Assert ($Named -eq 'named' -and ($args -join '|') -eq 'one|two') 'parameter or extra-argument forwarding'}
    Invoke-RecoveryOperation -Operation Arguments-Operation -Parameters @{Named='named'} -ExtraArguments @('one','two')
    'PASS: named parameters and extra arguments reach the operation'
    function Stream-Inner {'stream-first';Assert (Test-Path (Join-Path $Scratch 'stream.seen')) 'nested operation buffered output'}
    function Stream-Outer {Invoke-RecoveryOperation -Operation Stream-Inner}
    Invoke-RecoveryOperation -Operation Stream-Outer | ForEach-Object {if($_ -eq 'stream-first'){[IO.File]::WriteAllText((Join-Path $Scratch 'stream.seen'),'')}}
    'PASS: nested operation output streams to its caller'
    $early=Start-TestChild early;$children+=$early;Await-File (Join-Path $Scratch 'early.done');$early.WaitForExit()
    Assert ($early.ExitCode -eq 0) 'early release failed'
    $third=Start-TestChild third;$children+=$third;Await-File (Join-Path $Scratch 'third.attempted')
    Start-Sleep -Milliseconds 200;Assert (-not (Test-Path (Join-Path $Scratch 'third.entered'))) 'old cleanup released another process operation'
    $timeout=Start-TestChild timeout;$children+=$timeout;$timeout.WaitForExit();Assert ($timeout.ExitCode -eq 0) 'bounded operation wait failed'
    [IO.File]::WriteAllText((Join-Path $Scratch 'holder.release'),'');$third.WaitForExit();Assert ($third.ExitCode -eq 0) 'third process failed'
    'PASS: early release and generation-safe outer cleanup'
    function Reenter {Exit-RecoveryOperation;Invoke-RecoveryOperation -Operation Inner;Exit-RecoveryOperation;Exit-RecoveryOperation}
    Invoke-RecoveryOperation -Operation Reenter
    $crash=Start-TestChild crash;$children+=$crash;$crash.WaitForExit()
    Invoke-RecoveryOperation -Operation Inner
    Assert (-not (Test-Path (Join-Path (Get-RecoveryRoot) 'operations.lock'))) 'coordinator polluted tunnel owner directories'
    'PASS: idempotent exit, reentry and crashed-process recovery'
} finally {
    Exit-RecoveryOperation
    foreach($p in $children){if(-not $p.HasExited){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue}}
    $holder=Join-Path $Scratch 'holder.pid';if(Test-Path $holder){Stop-Process -Id ([int](Get-Content $holder)) -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $Scratch -Recurse -Force
}
