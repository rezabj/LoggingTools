Remove-Module LoggingTools -ErrorAction SilentlyContinue -Force
.\Helpers\Update-PSD.ps1
Import-Module .\LoggingTools\LoggingTools.psd1 -ErrorAction Stop -Force

$LTLogManager

Write-Output "Konec skriptu"