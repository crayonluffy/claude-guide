$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $f.Extent.Text
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
function Get-ProxyNodes { return @([pscustomobject]@{Name='jp';Alias='jpvpn';Idx=0},[pscustomobject]@{Name='sg';Alias='sgvpn';Idx=1},[pscustomobject]@{Name='us';Alias='usvpn';Idx=2}) }
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('node-ports-'+[guid]::NewGuid())
$null=[IO.Directory]::CreateDirectory($scratch)
$script:LOCAL_NODES=Join-Path $scratch 'local'
try {
    [IO.File]::WriteAllText($script:LOCAL_NODES,"lab 100`n")
    $s=@{HTTP_PORT=8080;SOCKS_PORT=1080;NODE_HTTP_BASE=8180;NODE_SOCKS_BASE=1180;NODE_PORTS=@{}}
    $p=Get-ProxyNodePorts -Name jp -Index 0 -Settings $s
    Assert ($p.HTTP_PORT -eq 8180 -and $p.SOCKS_PORT -eq 1180) 'Fallback ports changed'
    $s.NODE_PORTS=@{jp=@{HTTP_PORT=9000;SOCKS_PORT=9001};manual=@{HTTP_PORT=9100;SOCKS_PORT=9101}}
    $p=Get-ProxyNodePorts -Name jp -Index 0 -Settings $s
    Assert ($p.HTTP_PORT -eq 9000 -and $p.SOCKS_PORT -eq 9001) 'Explicit ports were ignored'
    $rows=Get-ProxyNodePortRows -Settings $s
    foreach ($c in @(@('jp',9000,9001),@('sg',8181,1181),@('us',8182,1182),@('lab',8280,1280),@('manual',9100,9101))) {
        Assert ($rows[$c[0]].HTTP_PORT -eq $c[1] -and $rows[$c[0]].SOCKS_PORT -eq $c[2]) "Missing or incorrect row $($c[0])"
    }
    Assert (([IO.File]::ReadAllText($script:LOCAL_NODES)) -eq "lab 100`n") 'Materialization allocated slots'
    $candidate=Join-Path $scratch 'candidate.psd1'
    $data=@{NODE_PORTS=$rows;UNRELATED="a'b `$literal";BIG=[long]2147483648}
    $literal=ConvertTo-ProxyConfigLiteral -Value $data
    Assert (($literal -split "`n").Count -gt 15) 'Nested node assignments must be readable on separate lines'
    [IO.File]::WriteAllText($candidate,$literal)
    $round=Import-PowerShellDataFile -LiteralPath $candidate
    Assert ($round.UNRELATED -eq "a'b `$literal" -and $round.BIG -eq 2147483648) 'Literal serializer corrupted unrelated values'
    $updated=Update-ProxyConfigText -Text "@{ UNRELATED='keep'; NODE_PORTS=@{} }" -Values @{NODE_PORTS=$rows}
    [IO.File]::WriteAllText($candidate,$updated)
    $roundUpdated=Import-PowerShellDataFile -LiteralPath $candidate
    Assert ($roundUpdated.UNRELATED -eq 'keep' -and $roundUpdated.NODE_PORTS.sg.HTTP_PORT -eq 8181) 'Integrated config writer corrupted node assignments or unrelated settings'
    $script:PROXY_CONF=Join-Path $scratch 'snapshot.psd1'
    $script:CONF_KEYS=@('NODE_PORTS')
    $script:NODE_PORTS=$rows
    _conf-write-all
    $snapshot=Import-PowerShellDataFile -LiteralPath $script:PROXY_CONF
    Assert ($snapshot.NODE_PORTS -is [hashtable] -and $snapshot.NODE_PORTS.jp.HTTP_PORT -eq 9000) 'Full config snapshot must preserve native node-port data'
    $s.NODE_PORTS=$round.NODE_PORTS
    Assert-ProxyNodePorts -Settings $s
    foreach ($bad in @(
        @{jp=@{HTTP_PORT=8080;SOCKS_PORT=9001}},
        @{jp=@{HTTP_PORT=9000;SOCKS_PORT=9000}},
        @{jp=@{HTTP_PORT=9000;SOCKS_PORT=1181}},
        @{jp=@{HTTP_PORT=9000;SOCKS_PORT=9001};us=@{HTTP_PORT=9100;SOCKS_PORT=9000}},
        @{'bad/name'=@{HTTP_PORT=9000;SOCKS_PORT=9001}},
        @{jp=@{HTTP_PORT='09000';SOCKS_PORT=9001}},
        @{jp=@{HTTP_PORT=65536;SOCKS_PORT=9001}},
        @{jp=@{HTTP_PORT=0;SOCKS_PORT=9001}},
        @{jp=@{HTTP_PORT=[double]9000;SOCKS_PORT=9001}},
        @{jp=@{HTTP_PORT=9000}},
        @{jp='bad'}
    )) {
        $s.NODE_PORTS=$bad; $rejected=$false
        try { Assert-ProxyNodePorts -Settings $s } catch { $rejected=$true }
        Assert $rejected "Accepted invalid node ports $($bad | ConvertTo-Json -Compress)"
    }
    $s.NODE_PORTS=@{}; $s.NODE_HTTP_BASE=1080; $rejected=$false
    try { Assert-ProxyNodePorts -Settings $s } catch { $rejected=$true }
    Assert $rejected 'Fallback conflict with main was accepted'
    'PASS: node-port overrides, materialization, PSD1 round trip, and planned conflict validation'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
