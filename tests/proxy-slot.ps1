$ErrorActionPreference='Stop'
# Slot-keyed recovery owner (PowerShell): one state directory per user and slot
# ('main') whatever host or ports this window's settings name; a window with
# stale settings adopts the live owner's tunnel; tunnel-stop always reaches the
# owner (and owners left by 2.7 in host/port-hashed directories).
$tokens=$null;$errors=$null
$src=Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($src,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){
 if($f.Name -like '*-Recovery*' -or $f.Name -in @('tunnel-stop')){Invoke-Expression $f.Extent.Text}
}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
$null=New-Item -ItemType Directory $scratch
function Get-RecoveryRoot { Join-Path $scratch 'recovery' }
try {
 # 1) Same directory whatever host/ports this window names.
 $script:SSH_HOST='jpvpn';$script:SSH_USER='';$script:SSH_PORT=22;$script:SSH_KEY=''
 $script:HTTP_PORT=8080;$script:SOCKS_PORT=1080;$script:REMOTE_PROXY_PORT=8888
 $a=Get-RecoveryIdentity
 $script:SSH_HOST='other';$script:HTTP_PORT=8081;$script:SOCKS_PORT=1081
 $b=Get-RecoveryIdentity
 Assert ($a -eq $b) "identity changed with settings: $a vs $b"
 Assert ($a -eq (Join-Path (Get-RecoveryRoot) 'main')) "unexpected identity $a"
 Assert ((Get-RecoveryIdentity -Slot 'node-sg') -eq (Join-Path (Get-RecoveryRoot) 'node-sg')) 'slot argument ignored'
 'PASS: owner directory is per user and slot, independent of host and ports'

 # 2) A live owner's descriptor wins over this window's stale settings.
 $rec=@{SSH_HOST='jpvpn';SSH_USER='alice';SSH_PORT=22;SSH_KEY='C:\keys\id';HTTP_PORT=8080;SOCKS_PORT=1080;REMOTE_PROXY_PORT=8888;WATCHDOG_INTERVAL=5}
 Write-RecoveryStatus $a descriptor $rec
 function Test-RecoveryOwner { param($Identity) return $true }
 $script:SSH_HOST='stale';$script:SSH_USER='bob';$script:SSH_PORT=2222;$script:SSH_KEY=''
 $script:HTTP_PORT=8081;$script:SOCKS_PORT=1081;$script:REMOTE_PROXY_PORT=9999
 Assert (Use-RecoveryRecord $a) 'live owner record was not adopted'
 Assert ($script:SSH_HOST -eq 'jpvpn' -and $script:SSH_USER -eq 'alice' -and $script:SSH_KEY -eq 'C:\keys\id') 'ssh destination not adopted'
 Assert ($script:HTTP_PORT -eq 8080 -and $script:SOCKS_PORT -eq 1080 -and $script:REMOTE_PROXY_PORT -eq 8888) 'ports not adopted'
 'PASS: a window with stale settings adopts the live owner tunnel'

 # 3) No live owner: settings are left alone.
 function Test-RecoveryOwner { param($Identity) return $false }
 $script:HTTP_PORT=8090
 Assert (-not (Use-RecoveryRecord $a)) 'adopted without a live owner'
 Assert ($script:HTTP_PORT -eq 8090) 'settings changed without a live owner'
 'PASS: without a live owner the window keeps its own settings'

 # 4) tunnel-stop stops the owner (and a 2.7 owner) and never kills ssh itself.
 $legacy=Join-Path (Get-RecoveryRoot) 'abc123legacy'; $null=New-Item -ItemType Directory $legacy -Force
 function Test-RecoveryOwner { param($Identity) return ((Split-Path -Leaf $Identity) -in @('main','abc123legacy')) -and -not (Test-Path (Join-Path $Identity 'stopped')) }
 $script:Stopped=@()
 function Stop-RecoveryOwner { param($Identity) $script:Stopped+=(Split-Path -Leaf $Identity); [IO.File]::WriteAllText((Join-Path $Identity 'stopped'),'stop') }
 function taskkill { throw 'tunnel-stop killed ssh behind the owner' }
 function Get-NetTCPConnection { throw 'tunnel-stop looked for ssh listeners although an owner exists' }
 $script:HTTP_PORT=18080;$script:SOCKS_PORT=11080
 Assert (tunnel-stop) 'tunnel-stop reported failure'
 Assert ($script:Stopped -contains 'main' -and $script:Stopped -contains 'abc123legacy') "owners stopped: $($script:Stopped -join ',')"
 Assert ($script:HTTP_PORT -eq 8080) 'tunnel-stop did not adopt the owner record first'
 'PASS: tunnel-stop stops the live owner (and older-version owners) without touching their ssh'
} finally { Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue }
