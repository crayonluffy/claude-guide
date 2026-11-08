# proxy-update (2.13.4): latest release by TAG, -Version, no accidental downgrade,
# main-branch fallback when the API fails. Fake GitHub; no network.
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($f.Name -in 'proxy-update','Get-UpdateRepo','Invoke-UpdateFetch','Get-UpdateLatestTag') { Invoke-Expression $f.Extent.Text }
}
function Assert($ok, $m) { if (-not $ok) { throw "FAIL: $m" } }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("upd-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $scratch | Out-Null
function Profile($v) { "`$script:PROFILE_VERSION = '$v'`n" }
$script:Files = @{
    'https://raw.githubusercontent.com/o/r/v2.13.4/scripts/claude-proxy.ps1' = (Profile '2.13.4')
    'https://raw.githubusercontent.com/o/r/v2.13.2/scripts/claude-proxy.ps1' = (Profile '2.13.2')
    'https://raw.githubusercontent.com/o/r/main/scripts/claude-proxy.ps1'    = (Profile '2.13.2')   # stale CDN copy
    'https://api.github.com/repos/o/r/releases/latest' = '{"tag_name":"v2.13.4"}'
}
$script:ApiDown = $false; $script:Urls = @()
function _fetch-file { param($Uri, $OutFile)
    $script:Urls += $Uri
    if ($script:ApiDown -and $Uri -like 'https://api.github.com/*') { throw 'rate limited' }
    if (-not $script:Files.ContainsKey($Uri)) { throw '404' }
    [IO.File]::WriteAllText($OutFile, $script:Files[$Uri])
}
function Start-Sleep {}
function Test-Port { param($Port) $false }
function _ensure-loader { 'ok' }
function _conf-write-all {}
function _reload-profile { $script:PROFILE_VERSION = [regex]::Match((Get-Content $script:PROFILE_PATH -Raw), "'([^']*)'").Groups[1].Value; $true }
$script:REPO_RAW = 'https://raw.githubusercontent.com/o/r/main/scripts'
$script:HTTP_PORT = 18080
$script:PROFILE_PATH = Join-Path $scratch 'claude-proxy.ps1'; $script:PROXY_CONF = Join-Path $scratch 'conf.psd1'
Set-Content $script:PROXY_CONF '@{}'; [IO.File]::WriteAllText($script:PROFILE_PATH, (Profile '2.13.3')); $script:PROFILE_VERSION = '2.13.3'
function Installed { [regex]::Match((Get-Content $script:PROFILE_PATH -Raw), "'([^']*)'").Groups[1].Value }
try {
    proxy-update 6>$null
    Assert ((Installed) -eq '2.13.4') "latest tag not installed: $(Installed)"
    Assert ($script:Urls -contains 'https://raw.githubusercontent.com/o/r/v2.13.4/scripts/claude-proxy.ps1') 'not fetched by tag'
    'PASS: proxy-update installs the latest release by its tag, not the cached branch'

    $script:ApiDown = $true
    proxy-update 6>$null
    Assert ((Installed) -eq '2.13.4') 'stale main downgraded the profile'
    'PASS: a stale older copy never downgrades; the API failure falls back to main'

    proxy-update -Version 2.13.2 6>$null
    Assert ((Installed) -eq '2.13.2') '-Version not installed'
    proxy-update --version v9.9.9 6>$null
    Assert ((Installed) -eq '2.13.2') 'unknown version changed the profile'
    proxy-update -Version 2.x 6>$null
    Assert ((Installed) -eq '2.13.2') 'bad version changed the profile'
    'PASS: -Version / --version picks a release (older on purpose too); bad or unknown versions are refused'

    $script:Urls = @(); $script:REPO_RAW = 'https://mirror.example/scripts'
    proxy-update 6>$null
    # (Retried, since the fake mirror has no file.)
    Assert (@($script:Urls | Select-Object -Unique) -join ',' -eq 'https://mirror.example/scripts/claude-proxy.ps1') "mirror: $($script:Urls -join ',')"
    'PASS: a custom REPO_RAW mirror is used as is'
} finally { Remove-Item $scratch -Recurse -Force }
