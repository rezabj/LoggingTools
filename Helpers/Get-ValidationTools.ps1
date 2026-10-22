# Downloads validation dependencies only into the ignored workspace artifacts directory.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$directory = Join-Path $PSScriptRoot '../artifacts/tools'
[void][IO.Directory]::CreateDirectory($directory)
$analyzerDirectory = Join-Path $directory 'PSScriptAnalyzer'
if (-not (Test-Path -LiteralPath (Join-Path $analyzerDirectory 'PSScriptAnalyzer.psd1'))) {
    $package = Join-Path $directory 'PSScriptAnalyzer.zip'
    Invoke-WebRequest 'https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.25.0' -OutFile $package
    Expand-Archive -LiteralPath $package -DestinationPath $analyzerDirectory -Force
}
if ($IsWindows) {
    $minimumDirectory = Join-Path $directory 'pwsh70'
    if (-not (Test-Path -LiteralPath (Join-Path $minimumDirectory 'pwsh.exe'))) {
        $archive = Join-Path $directory 'pwsh70.zip'
        Invoke-WebRequest 'https://github.com/PowerShell/PowerShell/releases/download/v7.0.13/PowerShell-7.0.13-win-x64.zip' -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $minimumDirectory -Force
    }
}
Write-Output "Validation tools downloaded to $directory"
