[CmdletBinding()]
param([version]$ModuleVersion = '1.0.0')
$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path $PSScriptRoot '../LoggingTools'
$functions = @(Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'public') -Filter '*.ps1' | Select-Object -ExpandProperty BaseName | Sort-Object)
Update-ModuleManifest -Path (Join-Path $moduleRoot 'LoggingTools.psd1') `
    -ModuleVersion $ModuleVersion -PowerShellVersion '7.0' -CompatiblePSEditions Core `
    -FunctionsToExport $functions -VariablesToExport @() -AliasesToExport @() `
    -HelpInfoUri 'https://rezabj.github.io/LoggingTools/'

