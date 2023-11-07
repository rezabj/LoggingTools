$version = New-Object System.Version(0, 0, 0, 1)
$functions = Get-Item -Path $PSScriptRoot\..\LoggingTools\public\*.ps1
$functionlist = @()
foreach ($function in $functions) {
  $Lenght = $function.name.Length - 4
  $functionlist += $function.name.substring(0,$Lenght)
}
# $RequiredModules = @()
$PrivateData = @{
    Tags = @("PowerShell","Logging","Log","Graph")
    LicenseUri = 'https://github.com/rezabj/LoggingTools/blob/Dev/LICENSE'
    ProjectUri = 'https://github.com/rezabj/LoggingTools'
    ReleaseNotes = 'https://github.com/rezabj/LoggingTools/releases'
}
Update-ModuleManifest -Path $PSScriptRoot\..\LoggingTools\LoggingTools.psd1 `
  -Author "Jan Rezab <honza@rezab.eu>" `
  -ModuleVersion $version `
  -Description "PowerShell logging module with multiple targets" `
  -RootModule "LoggingTools.psm1" `
  -PowerShellVersion "5.1" `
  -ProjectUri "https://github.com/rezabj/LoggingTools" `
  -HelpInfoUri "https://github.com/rezabj/LoggingTools/Docs" `
  -PrivateData $PrivateData
  # -RequiredModules $RequiredModules `
  # -FunctionsToExport $functionlist `
  # -CmdletsToExport "" `
  # -AliasesToExport "" `
  