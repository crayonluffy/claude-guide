$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$source = Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$wanted = @('Test-RecoveryProcess', 'Stop-RecoveryProcess', 'Test-RecoveryOwner',
    'Get-RecoveryStatus', 'Write-RecoveryStatus', 'Open-RecoveryLock',
    'Get-RecoveryOwnedDirs', 'Assert-ProxyRestartPorts', 'Test-ProxyConfigPort')
foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($definition.Name -in $wanted) { Invoke-Expression $definition.Extent.Text }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }

# Protected Windows processes and processes exiting mid-check are not portable
# fixtures. Replace only Get-Process for one stale PID; use real files and leases.
$script:UnreadablePid = 99999997
$script:UnreadableProcess = [pscustomobject]@{ Id = $script:UnreadablePid; StartTime = $null }
function Get-Process {
    param([int]$Id)
    if ($Id -eq $script:UnreadablePid) { return $script:UnreadableProcess }
    Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction SilentlyContinue
}
function Stop-Process { throw 'An unverified process must never be stopped.' }
$current = Get-Process -Id $PID
$started = "$($current.StartTime.ToUniversalTime().Ticks)"
Assert (Test-RecoveryProcess $PID $started) 'A live process with matching creation time was rejected'
Assert (-not (Test-RecoveryProcess $PID '1')) 'A reused PID was accepted'
Assert (-not (Test-RecoveryProcess $PID '')) 'A record without creation time was accepted'
Assert (-not (Test-RecoveryProcess 2147483647 $started)) 'A missing process was accepted'
Assert (-not (Test-RecoveryProcess $script:UnreadablePid $started)) 'An unreadable process was accepted'
Assert (-not (Stop-RecoveryProcess $script:UnreadablePid $started)) 'An unreadable process was stopped'

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$script:IdentityTestRoot = Join-Path $tempRoot ('proxy-process-identity-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($script:IdentityTestRoot) | Out-Null
function Get-RecoveryRoot { return $script:IdentityTestRoot }
$live = Join-Path $script:IdentityTestRoot 'main'
$stale = Join-Path $script:IdentityTestRoot 'node-old'
$lease = $null
try {
    foreach ($dir in @($live, $stale)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    Write-RecoveryStatus $live owner @{ ProcessId = $PID; Started = $started }
    Write-RecoveryStatus $live descriptor @{ HTTP_PORT = 8080; SOCKS_PORT = 1080 }
    $lease = Open-RecoveryLock $live
    Assert ($null -ne $lease) 'Could not establish a real live-owner lease'
    Write-RecoveryStatus $stale owner @{ ProcessId = $script:UnreadablePid; Started = $started }
    Write-RecoveryStatus $stale descriptor @{ HTTP_PORT = 8182; SOCKS_PORT = 1182 }

    $owners = @(Get-RecoveryOwnedDirs -All)
    Assert ($owners.Count -eq 1 -and $owners[0] -eq $live) 'A stale protected PID broke live-owner discovery'
    Assert-ProxyRestartPorts @{ Slot = 'node-us'; HTTP_PORT = 8182; SOCKS_PORT = 1182 }
    $conflict = $false
    try { Assert-ProxyRestartPorts @{ Slot = 'node-us'; HTTP_PORT = 8080; SOCKS_PORT = 1182 } }
    catch { if ($_.Exception.Message -notmatch 'conflicts with active main') { throw }; $conflict = $true }
    Assert $conflict 'A real live-owner port conflict was ignored'

    $script:UnreadableProcess = [pscustomobject]@{ Id = $script:UnreadablePid }
    $script:UnreadableProcess | Add-Member ScriptProperty StartTime { throw [InvalidOperationException]::new('Process exited during identity check.') }
    Assert (-not (Test-RecoveryProcess $script:UnreadablePid $started)) 'A process exiting during the check was accepted'
    Assert (-not (Stop-RecoveryProcess $script:UnreadablePid $started)) 'A process exiting during the check was stopped'
    Assert (-not (Test-RecoveryOwner $stale)) 'An unreadable owner was considered live'
} finally {
    if ($lease) { $lease.Dispose() }
    $cleanup = [IO.Path]::GetFullPath($script:IdentityTestRoot)
    if (-not $cleanup.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $cleanup) -notlike 'proxy-process-identity-*') { throw 'Refusing cleanup outside the test directory.' }
    [IO.Directory]::Delete($cleanup, $true)
}
'PASS: protected and exiting processes are rejected; owner discovery and restart retain real live-owner checks'
