$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -like '*-Recovery*'){Invoke-Expression $f.Extent.Text}}
$script:Captured=@()
function curl.exe {$script:Captured+=,@($args);$global:LASTEXITCODE=7;'000 000'}
$null=Test-RecoveryTransport claude 8080 1080
foreach($call in $script:Captured){
 if($call -contains ''){throw 'Legacy Windows native command mode drops empty arguments'}
 if($call -notcontains '--noproxy='){throw 'NO_PROXY override missing'}
}
if($script:Captured[1] -notcontains '--proxy='){throw 'SOCKS crosscheck did not disable ambient HTTP proxy'}
$dir=Join-Path ([IO.Path]::GetTempPath()) ('recovery-review-'+[guid]::NewGuid())
[IO.Directory]::CreateDirectory($dir)|Out-Null
try {
 $file=Join-Path $dir 'installed profile.ps1';[IO.File]::WriteAllText($file,'# test')
 if((Resolve-RecoveryProfile -Path '' -Fallback $file) -ne $file){throw 'shortcut profile path not resolved'}
 function Test-RecoveryOwner {return $true}
 try {Stop-RecoveryOwner $dir -WaitSeconds 0;throw 'stop falsely reported success'}catch{if($_ -notmatch 'still stopping'){throw}}
}finally{Remove-Item $dir -Recurse -Force}
'PASS: legacy Windows arguments, shortcut loading, and pending-stop rejection'
if(-not(Get-Command Test-RecoveryPortConflict -ErrorAction SilentlyContinue)){throw 'live port conflicts are not classified'}
$script:HTTP_PORT=8080;$script:SOCKS_PORT=1080
function Get-NetTCPConnection {return [pscustomobject]@{OwningProcess=99999999}}
if(-not(Test-RecoveryPortConflict -OwnedProcessId 123)){throw 'foreign port owner ignored'}
if(Test-RecoveryPortConflict -OwnedProcessId 99999999){throw 'owned port classified foreign'}
'PASS: owned and foreign port classification'
