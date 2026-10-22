#Requires -Version 7.0
Set-StrictMode -Version Latest
if (-not ('LoggingTools.Logger' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Engine/LoggingEngine.cs') -ErrorAction Stop
}
$script:Logger = $null
$script:DefaultLevel = 'INFO'
$script:StrictDelivery = $false
foreach ($folder in @('private', 'public')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1') { . $file.FullName }
}
$ExecutionContext.SessionState.Module.OnRemove = { if ($script:Logger) { [void]$script:Logger.Close(2000) } }
Export-ModuleMember -Function @('Initialize-LTLogConfig', 'Set-LTLogDefaultLevel', 'Write-LTLog', 'Get-LTLogStatus', 'Sync-LTLog', 'Close-LTLog')
