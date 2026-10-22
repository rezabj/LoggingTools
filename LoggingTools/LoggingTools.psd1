@{
    RootModule = 'LoggingTools.psm1'
    ModuleVersion = '1.0.0'
    CompatiblePSEditions = @('Core')
    GUID = '48f193a7-d3e8-4b3f-8298-a7d4e1515eac'
    Author = 'Jan Rezab <honza@rezab.eu>'
    CompanyName = 'Rezab.EU'
    Copyright = 'GNU GENERAL PUBLIC LICENSE v3'
    Description = 'Asynchronous structured logging to files, Azure Log Analytics, and Teams Workflows.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Initialize-LTLogConfig', 'Set-LTLogDefaultLevel', 'Write-LTLog', 'Get-LTLogStatus', 'Sync-LTLog', 'Close-LTLog')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('PowerShell', 'Logging', 'Azure', 'Teams', 'Linux', 'Windows')
            LicenseUri = 'https://github.com/rezabj/LoggingTools/blob/Dev/LICENSE'
            ProjectUri = 'https://github.com/rezabj/LoggingTools'
            ReleaseNotes = 'Version 1: asynchronous file/Azure/Teams delivery, bounded queues, authentication, status and explicit flush/close.'
        }
    }
    HelpInfoURI = 'https://rezabj.github.io/LoggingTools/'
}
