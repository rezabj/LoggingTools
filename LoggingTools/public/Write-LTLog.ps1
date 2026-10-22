function Write-LTLog {
    <#
    .SYNOPSIS
    Enqueues a structured event without waiting for file or network delivery.
    .PARAMETER Message
    Event message. Avoid including sensitive information.
    .PARAMETER Level
    DEBUG, INFO, WARNING, ERROR, or CRITICAL. Uses the configured default when omitted.
    .PARAMETER Data
    Optional JSON-serializable data; sensitive field names are redacted recursively.
    .PARAMETER ErrorRecord
    A caught PowerShell ErrorRecord, for example $_ inside catch.
    .PARAMETER CorrelationId
    Optional identifier shared by related events.
    .EXAMPLE
    Write-LTLog -Message 'Inventory complete' -Data @{ Count = 42 } -CorrelationId $runId
    .LINK
    https://rezabj.github.io/LoggingTools/reference/#write-ltlog
    #>
    [CmdletBinding(HelpUri = 'https://rezabj.github.io/LoggingTools/reference/#write-ltlog')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')][string]$Level,
        [AllowNull()][object]$Data,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$CorrelationId
    )
    process {
        Assert-LTLogger
        $eventLevel = if ($PSBoundParameters.ContainsKey('Level')) { $Level.ToUpperInvariant() } else { $script:DefaultLevel }
        if ($script:Logger.IsEnabled($eventLevel)) {
            $dataJson = $null; $errorJson = $null
            if ($null -ne $Data) { $dataJson = ConvertTo-Json -InputObject $Data -Depth 32 -Compress -WarningAction Stop -ErrorAction Stop }
            if ($ErrorRecord) {
                $errorJson = @{
                    Message = $ErrorRecord.Exception.Message
                    Type = $ErrorRecord.Exception.GetType().FullName
                    ErrorId = $ErrorRecord.FullyQualifiedErrorId
                    Category = [string]$ErrorRecord.CategoryInfo.Category
                    StackTrace = $ErrorRecord.ScriptStackTrace
                } | ConvertTo-Json -Depth 8 -Compress
            }
            foreach ($name in $script:Logger.Write($eventLevel, $Message, $dataJson, $errorJson, $CorrelationId)) {
                Write-Warning "Logging destination '$name' rejected events because its queue is full or unavailable. Inspect Get-LTLogStatus."
            }
        }
    }
}
