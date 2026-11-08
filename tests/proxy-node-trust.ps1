$ErrorActionPreference = 'Stop'
# Node-list data is untrusted: invalid fields never reach ~\.ssh\config, and a
# catalogue host key is pinned only for a host that has no key yet.
$source = Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $definition.Extent.Text
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { 'SKIP: ssh-keygen unavailable'; return }
$oldHome = $HOME
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('node-trust-'+[guid]::NewGuid())
$null = New-Item -ItemType Directory (Join-Path $scratch '.ssh')
try {
    Set-Variable -Name HOME -Value $scratch -Force -Scope Global
    $k1 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
    $k2 = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA0FvJaPQwz2kqBqvhAr6kqJu6ce26qmHlYxGjVN0uE7'
    foreach ($ok in @(@('alias','jpvpn2'),@('host','jp.example.com'),@('host','2001:db8::1'),@('user',''),@('port','2222'),@('hostkey',$k1))) {
        Assert (Test-NodeField $ok[0] $ok[1]) "rejected valid: $($ok -join ' ')"
    }
    foreach ($bad in @(@('alias','-oProxyCommand=x'),@('host','evil.com ProxyCommand=sh'),@('host',"a`nb"),@('user','-l'),@('port','0'),@('port','70000'),@('hostkey','garbage'))) {
        Assert (-not (Test-NodeField $bad[0] $bad[1])) "accepted invalid: $($bad -join ' ')"
    }
    'PASS: node-list fields are validated before they reach ssh files'

    $kh = Join-Path $scratch '.ssh/known_hosts'
    Add-KnownHost 'sg.example.com' 22 $k1 6>$null
    Add-KnownHost 'sg.example.com' 22 $k1 6>$null
    Assert (@(Get-Content $kh).Count -eq 1) 'key not pinned exactly once'
    $out = (Add-KnownHost 'sg.example.com' 22 $k2 6>&1 | Out-String)
    Assert ($out -match 'different host key' -and -not (Select-String -Path $kh -SimpleMatch $k2 -Quiet)) "second key for a pinned host: $out"
    Add-KnownHost 'us.example.com' 2222 $k1 6>$null
    Assert (Select-String -Path $kh -SimpleMatch "[us.example.com]:2222 $k1" -Quiet) 'shared key not pinned for a second host'
    'PASS: catalogue host keys are pinned only for hosts with no key yet'

    $script:SSH_HOST='jpvpn'; $script:SSH_KEY=''; $script:SSH_USER='alice'
    $cfg = Join-Path $scratch '.ssh/config'; [IO.File]::WriteAllText($cfg,'')
    $bad = [pscustomobject]@{Name='sg';Alias='sgvpn';Host='evil.com ProxyCommand=x';User='';SshPort=22;HostKey=''}
    Assert (-not (Confirm-NodeAlias $bad 6>$null)) 'injected host accepted'
    Assert (([IO.File]::ReadAllText($cfg)) -eq '') 'ssh config written for an invalid node'
    $good = [pscustomobject]@{Name='sg';Alias='sgvpn';Host='sg.example.com';User='';SshPort=2222;HostKey=''}
    Assert (Confirm-NodeAlias $good 6>$null) 'valid node refused'
    Assert ((Get-Content $cfg -Raw) -match '(?m)^Host sgvpn' -and (Get-Content $cfg -Raw) -match 'Port 2222') 'valid alias not written'
    'PASS: invalid node-list fields never reach ~\.ssh\config'
} finally {
    Set-Variable -Name HOME -Value $oldHome -Force -Scope Global
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
