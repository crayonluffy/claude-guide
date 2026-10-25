$ErrorActionPreference='Stop'
# The Windows setup wizard's kill-switch step (mirrors tests/setup-killswitch.sh).
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/setup.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){if($f.Name -eq 'Set-WizardKillswitch'){Invoke-Expression $f.Extent.Text}}
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"}}
$script:Defaults=@()
function Confirm-Yes($prompt,[bool]$defaultYes=$true) { $script:Defaults+=$defaultYes; return ($script:Answer -eq 'y') }

$c=@{}; $script:Answer='y'; Set-WizardKillswitch $c $false 6>$null
Assert ($c.KILLSWITCH -eq 'on' -and $c.PLAIN_COMMANDS -eq 'auto' -and $script:Defaults[-1]) "full run, yes: $($c|ConvertTo-Json -Compress)"
$script:Answer='n'; Set-WizardKillswitch $c $false 6>$null
Assert ($c.PLAIN_COMMANDS -eq 'off') 'full run, no'
Set-WizardKillswitch $c $false 6>$null
Assert (-not $script:Defaults[-1]) "the saved 'off' must be the new default"
'PASS: a full run asks about plain commands and saves the answer'

$c=@{KILLSWITCH='off'}; Set-WizardKillswitch $c $false 6>$null
Assert ($c.KILLSWITCH -eq 'off') 'a kill switch turned off must stay off'
'PASS: a kill switch turned off stays off'

$script:Defaults=@(); $c=@{}
$out=(Set-WizardKillswitch $c $true 6>&1) -join ' '
Assert ($script:Defaults.Count -eq 0 -and -not $c.ContainsKey('PLAIN_COMMANDS') -and $out -match 'PLAIN_COMMANDS auto') "quick: $out"
$c=@{PLAIN_COMMANDS='off'}
Assert (-not ((Set-WizardKillswitch $c $true 6>&1) -join '')) 'quick update with a saved choice must stay quiet'
'PASS: a quick update never asks, and mentions it only when never chosen'
