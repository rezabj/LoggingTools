[CmdletBinding()]
param([string]$Root = (Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$snippets = 0
$pages = @(Get-ChildItem -LiteralPath $Root -Filter '*.md')
$routes = @('/', '/styles.css', '/azure-resources.json', '/404.html')
foreach ($page in $pages) {
    $text = Get-Content -LiteralPath $page.FullName -Raw
    if ($text -match '(?m)^permalink:\s*(\S+)') { $routes += $Matches[1] }
    foreach ($block in [regex]::Matches($text, '(?ms)^```powershell\s*\r?\n(.*?)^```')) {
        $parseErrors = $null; $tokens = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors) { throw "Invalid PowerShell snippet in $($page.Name): $($parseErrors.Message -join '; ')" }
        $snippets++
    }
}
foreach ($page in $pages) {
    $text = Get-Content -LiteralPath $page.FullName -Raw
    foreach ($link in [regex]::Matches($text, "\{\{\s*'([^']+)'\s*\|\s*relative_url\s*\}\}")) {
        $route = $link.Groups[1].Value.Split('#')[0]
        if ($route -notin $routes) { throw "Unknown documentation route '$route' in $($page.Name)." }
    }
}
$template = Get-Content -LiteralPath (Join-Path $Root 'azure-resources.json') -Raw | ConvertFrom-Json
if ($template.resources.Count -ne 3 -or $template.variables.columns.Count -ne 10) { throw 'Azure template does not match the documented schema.' }
Write-Output "Validated $($pages.Count) Markdown pages, $snippets PowerShell snippets, local routes, and Azure template JSON."
