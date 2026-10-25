$ErrorActionPreference='Stop'
# PLAIN_COMMANDS=auto (PowerShell): plain 'claude' / 'codex' start through the
# tunnel in safe mode, quietly, and never call themselves. Mirrors tests/proxy-plain.sh.
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $f.Extent.Text}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('plain-'+[guid]::NewGuid()); $null=New-Item -ItemType Directory $scratch
$oldPath=$env:PATH
try {
 foreach($b in 'claude','codex'){
  [IO.File]::WriteAllText((Join-Path $scratch "$b.ps1"),"Add-Content '$scratch/$b.calls' 'call'; Write-Output ('$b ARGS:' + (`$args -join ' ')); `$global:LASTEXITCODE=3")
 }
 $env:PATH="$scratch$([IO.Path]::PathSeparator)$oldPath"
 $script:TUNNEL_WATCHDOG=0
 function proxy-up { param([switch]$NoVerify,[string]$Node,[string]$Provider) Write-Host "[OK] proxy up $Provider"; Add-Content "$scratch/up.calls" "$NoVerify $Provider"; return (-not (Test-Path "$scratch/up.fail")) }

 # 1) off: no function, the real program runs as-is.
 $script:PLAIN_COMMANDS='off'; Set-PlainCommands
 Assert (-not (Get-Item function:claude -ErrorAction SilentlyContinue)) 'claude function defined with PLAIN_COMMANDS=off'
 'PASS: PLAIN_COMMANDS=off leaves claude and codex alone'

 # 2) auto: through the tunnel, quiet, exit code kept.
 $script:PLAIN_COMMANDS='auto'; Set-PlainCommands
 Assert ((Get-Item function:claude).ScriptBlock -match 'Invoke-PlainLaunch') 'claude function missing'
 $out=@(claude -p hi 6>&1)
 Assert ($out.Count -eq 1 -and $out[0] -eq 'claude ARGS:-p hi') "output not only the app's: $($out -join ' / ')"
 Assert ($LASTEXITCODE -eq 3) "exit code $LASTEXITCODE"
 Assert ((Get-Content "$scratch/up.calls") -contains 'True claude') 'proxy-up not called with -NoVerify'
 $out=@(codex exec ls 6>&1)
 Assert ($out[-1] -eq 'codex ARGS:exec ls') "codex: $($out -join ' / ')"
 'PASS: plain claude/codex go through the tunnel quietly, exit code kept'

 # 3) No tunnel, no launch.
 Remove-Item "$scratch/claude.calls" -ErrorAction SilentlyContinue; New-Item "$scratch/up.fail" | Out-Null
 $null=claude -p hi 6>$null 2>$null
 Assert (-not (Test-Path "$scratch/claude.calls") -and $LASTEXITCODE -eq 1) 'launched without a tunnel'
 Remove-Item "$scratch/up.fail"
 'PASS: no tunnel, no launch'

 # 4) Version/help need no tunnel.
 Remove-Item "$scratch/up.calls" -ErrorAction SilentlyContinue
 foreach($a in '--version','-v','--help','-h'){ $o=@(claude $a); Assert ($o[-1] -eq "claude ARGS:$a") "passthrough $a" }
 Assert (-not (Test-Path "$scratch/up.calls")) 'tunnel started for --version/--help'
 'PASS: --version / --help pass straight through'

 # 5) cc runs the real program exactly once with the function defined.
 Remove-Item "$scratch/claude.calls" -ErrorAction SilentlyContinue
 $null=cc -p hi 6>$null
 Assert (@(Get-Content "$scratch/claude.calls").Count -eq 1) 'cc recursed or did not run the program once'
 'PASS: cc runs the real program once with the function defined'

 # 6) Switching off removes our functions but never a user's own.
 $script:PROXY_CONF=Join-Path $scratch 'conf.psd1'; $script:CONF_KEYS=@('PLAIN_COMMANDS')
 proxy-config set PLAIN_COMMANDS off 6>$null
 Assert (-not (Get-Item function:claude -ErrorAction SilentlyContinue)) 'proxy-config set PLAIN_COMMANDS off left the function'
 Set-Item function:global:codex { 'my own codex' }
 Set-PlainCommands
 Assert ((Get-Item function:codex -ErrorAction SilentlyContinue)) "a user's own codex function was removed"
 Remove-Item function:codex
 'PASS: switching off removes only our functions'

 # 6b) Codex without its shared background server (--no-daemon) when it supports it.
 [IO.File]::WriteAllText((Join-Path $scratch 'codex.ps1'),"if (`$args[0] -eq '--help') { '      --no-daemon   Run without the shared background server'; return }; Write-Output ('codex ARGS:' + (`$args -join ' ')); `$global:LASTEXITCODE=3")
 $script:CODEX_NO_DAEMON=$null
 $script:PLAIN_COMMANDS='auto'; Set-PlainCommands
 $out=@(codex resume 6>&1)
 Assert ($out[-1] -eq 'codex ARGS:--no-daemon resume') "plain codex: $($out -join ' / ')"
 $out=@(cx exec ls 6>&1)
 Assert ($out[-1] -eq 'codex ARGS:--no-daemon --dangerously-bypass-approvals-and-sandbox exec ls') "cx: $($out -join ' / ')"
 [IO.File]::WriteAllText((Join-Path $scratch 'codex.ps1'),"if (`$args[0] -eq '--help') { 'Usage: codex'; return }; Write-Output ('codex ARGS:' + (`$args -join ' '))")
 $script:CODEX_NO_DAEMON=$null
 $out=@(cx exec ls 6>&1)
 Assert ($out[-1] -eq 'codex ARGS:--dangerously-bypass-approvals-and-sandbox exec ls') "old codex: $($out -join ' / ')"
 'PASS: cx runs Codex without its shared background server (--no-daemon) when Codex supports it'

 # 7) Not installed: a clear error, not recursion.
 $script:PLAIN_COMMANDS='auto'; Set-PlainCommands
 $env:PATH='/nonexistent'
 $err=claude -p hi 2>&1 6>$null
 Assert ($LASTEXITCODE -eq 1) 'missing program did not fail'
 'PASS: a missing program is reported, not recursed into'
} finally {
 $env:PATH=$oldPath
 Remove-Item function:claude,function:codex -ErrorAction SilentlyContinue
 Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}
