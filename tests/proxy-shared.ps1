$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $f.Extent.Text }
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('proxy-shared-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($scratch)
$script:PROXY_MODE='shared'; $script:HTTP_PORT=18080; $script:SOCKS_PORT=11080
$script:SSH_HOST='test'; $script:SSH_PORT=22; $script:REMOTE_PROXY_PORT=8888
$script:CLAUDE_SETTINGS=Join-Path $scratch 'settings.json'
$script:SYNC_SETTINGS=1; $script:KILLSWITCH='on'; $script:TUNNEL_WATCHDOG=1
$script:NO_PROXY_LIST='localhost,127.0.0.1'; $script:WATCHDOG_STARTUP_GRACE=0
$script:ManagementCalls=0; $script:AppCalls=0; $script:Kind='healthy'
function Get-RecoveryRoot { Join-Path $scratch 'recovery' }
function Get-NetTCPConnection { @() }
function Get-TunnelHealth { @{Status='down'} }
function Test-Port { $true } # bound but foreign process is invisible to this account
function Test-RecoveryTransport { @{kind=$script:Kind} }
function Start-RecoveryOwner { $script:ManagementCalls++; throw 'Shared client attempted to start an owner' }
function Stop-RecoveryOwner { $script:ManagementCalls++; throw 'Shared client attempted to stop an owner' }
function Start-NodeTunnelOwner { $script:ManagementCalls++; return $false }
function Stop-NodeTunnels { $script:ManagementCalls++ }
function claude { $script:AppCalls++; Assert ($env:HTTPS_PROXY -eq 'http://127.0.0.1:18080') 'Wrong app proxy'; $global:LASTEXITCODE=0 }
function codex { if ($args -contains '--help') { return }; $script:AppCalls++; Assert ($env:HTTPS_PROXY -eq 'http://127.0.0.1:18080') 'Wrong app proxy'; $global:LASTEXITCODE=0 }
function Get-AppCommand { param($Name) Get-Command $Name -CommandType Function }
try {
    cc --safe --no-verify --version
    cx --safe --no-verify --version
    Assert ($script:AppCalls -eq 2) 'Shared cc/cx failed to launch on occupied foreign ports'
    Assert ($script:ManagementCalls -eq 0) 'Shared client managed the owner'
    Assert (-not (Test-Path (Join-Path $scratch 'recovery'))) 'Shared client created recovery ownership state'
    $settings=Get-Content $script:CLAUDE_SETTINGS -Raw | ConvertFrom-Json
    Assert ($settings.env.HTTPS_PROXY -eq 'http://127.0.0.1:18080') 'Shared client did not pin its own Claude settings'
    $script:Kind='tunnel'
    cx --safe --no-verify --version
    Assert ($script:AppCalls -eq 2) 'Unavailable shared proxy launched app'
    $script:Kind='healthy'; $script:NO_PROXY_LIST='api.openai.com'
    cx --safe --no-verify --version
    Assert ($script:AppCalls -eq 2) 'Shared mode bypassed NO_PROXY protection'
    $script:NO_PROXY_LIST='localhost,127.0.0.1'
    Assert (-not (tunnel-stop)) 'Shared client accepted tunnel stop'
    $rejected=$false; try { proxy-restart } catch { $rejected=$true }
    Assert $rejected 'Shared client accepted tunnel restart'
    Assert (-not (proxy-node jp)) 'Shared client accepted default-node switch'
    cc-stop -Force
    Assert ($script:ManagementCalls -eq 0) 'Shared control touched owner lifecycle'
    'PASS: PowerShell shared clients launch without foreign PID visibility and preserve transport/pinning safeguards'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
