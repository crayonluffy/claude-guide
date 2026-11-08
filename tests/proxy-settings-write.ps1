$ErrorActionPreference = 'Stop'
# Claude's settings.json: UTF-8 without BOM, first original kept, symlink kept.
$source = Join-Path $PSScriptRoot '../scripts/claude-proxy.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    Invoke-Expression $definition.Extent.Text
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('settings-write-'+[guid]::NewGuid())
$null = New-Item -ItemType Directory (Join-Path $scratch 'John Doe')
try {
    $script:SYNC_SETTINGS = 1; $script:NO_PROXY_LIST = 'localhost,127.0.0.1'
    $script:CLAUDE_SETTINGS = Join-Path $scratch 'John Doe/settings.json'
    [IO.File]::WriteAllText($script:CLAUDE_SETTINGS, '{"theme":"dark"}')
    function Test-ClaudeSettingsPinned { $false }
    $script:HTTP_PORT = 8080; _settings-sync-on 6>$null
    $script:HTTP_PORT = 8090; _settings-sync-on 6>$null
    $bytes = [IO.File]::ReadAllBytes($script:CLAUDE_SETTINGS)
    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'settings.json has a BOM'
    $now = Get-Content $script:CLAUDE_SETTINGS -Raw | ConvertFrom-Json
    Assert ($now.env.HTTPS_PROXY -eq 'http://127.0.0.1:8090' -and $now.theme -eq 'dark') 'settings not updated'
    $orig = Get-Content "$($script:CLAUDE_SETTINGS).claude-proxy.orig" -Raw | ConvertFrom-Json
    Assert ($null -eq $orig.env) 'the pre-proxy original was not kept'
    $bak = Get-Content "$($script:CLAUDE_SETTINGS).bak" -Raw | ConvertFrom-Json
    Assert ($bak.env.HTTPS_PROXY -eq 'http://127.0.0.1:8080') '.bak is not the previous version'
    Assert (-not (Get-ChildItem -LiteralPath (Join-Path $scratch 'John Doe') -Filter '*.tmp.*')) 'temp file left'
    'PASS: settings.json is written without BOM; first original and previous version kept'

    $target = Join-Path $scratch 'dotfiles.json'; [IO.File]::WriteAllText($target, '{"model":"x"}')
    $link = Join-Path $scratch 'linked.json'
    $made = $true
    try { $null = New-Item -ItemType SymbolicLink -Path $link -Target $target } catch { $made = $false }
    if ($made) {
        $script:CLAUDE_SETTINGS = $link; _settings-sync-on 6>$null
        Assert ((Get-Item -LiteralPath $link -Force).LinkType) 'symlink replaced by a plain file'
        $t = Get-Content $target -Raw | ConvertFrom-Json
        Assert ($t.env.HTTPS_PROXY -eq 'http://127.0.0.1:8090' -and $t.model -eq 'x') 'link target not updated'
        'PASS: a symlinked settings.json keeps its link'
    } else { 'SKIP: symlinks need extra rights on this host' }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
