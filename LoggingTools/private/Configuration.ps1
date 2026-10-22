function Assert-LTKey {
    param([hashtable]$Configuration, [string[]]$Allowed)
    foreach ($key in $Configuration.Keys) {
        if ($key -notin $Allowed) { throw "Unknown destination setting '$key'. See Initialize-LTLogConfig help." }
    }
}
function Set-LTNumericOption {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only updates an in-memory configuration object; no external state is changed.')]
    [CmdletBinding()]
    param($Options, [hashtable]$Configuration, [string]$Name, [long]$Minimum, [long]$Maximum)
    if ($Configuration.ContainsKey($Name)) {
        $number = 0L
        if (-not [long]::TryParse([string]$Configuration[$Name], [ref]$number) -or $number -lt $Minimum -or $number -gt $Maximum) {
            throw "Setting '$Name' must be an integer between $Minimum and $Maximum."
        }
        $Options.$Name = $number
    }
}
function New-LTSinkOption {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs an in-memory configuration object without creating external resources.')]
    [CmdletBinding()]
    param([string]$Kind, [hashtable]$Configuration, [int]$Capacity, [long]$CapacityBytes)
    $options = [LoggingTools.SinkOptions]::new()
    $options.Name = $Kind; $options.Kind = $Kind
    $options.Capacity = $Capacity; $options.CapacityBytes = $CapacityBytes
    if ($Kind -eq 'Teams') { $options.MinimumLevel = 'ERROR'; $options.BatchCount = 1 }
    if ($Configuration.ContainsKey('MinimumLevel')) {
        if ($Configuration.MinimumLevel -notin @('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')) { throw 'MinimumLevel must be DEBUG, INFO, WARNING, ERROR, or CRITICAL.' }
        $options.MinimumLevel = ([string]$Configuration.MinimumLevel).ToUpperInvariant()
    }
    Set-LTNumericOption $options $Configuration Capacity 1 1000000
    Set-LTNumericOption $options $Configuration CapacityBytes 1024 1073741824
    Set-LTNumericOption $options $Configuration BatchCount 1 10000
    Set-LTNumericOption $options $Configuration BatchBytes 1024 1000000
    Set-LTNumericOption $options $Configuration IntervalMilliseconds 1 60000
    Set-LTNumericOption $options $Configuration TimeoutSeconds 1 300
    Set-LTNumericOption $options $Configuration MaximumRetries 0 10
    return $options
}
function Assert-LTHttpsUri {
    param([string]$Value, [string]$Setting)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw "Setting '$Setting' must be an absolute HTTPS URL without embedded credentials." }
    return $uri
}
function Assert-LTGuid {
    param([string]$Value, [string]$Setting)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw "Setting '$Setting' must be a nonempty GUID." }
    return $parsed.ToString()
}
function Assert-LTLogger {
    if (-not $script:Logger) { throw 'Initialize a logger with Initialize-LTLogConfig first.' }
}
function Write-LTDeliveryResult {
    param([LoggingTools.FlushResult]$Result, [bool]$Strict)
    if (-not $Result.Success) {
        $message = 'Logging delivery is incomplete or has reported failures/drops. Inspect the result or Get-LTLogStatus.'
        if ($Result.TimedOut) { $message = 'Logging flush timed out. Inspect Get-LTLogStatus for pending events.' }
        if ($Strict) { throw $message }
        Write-Warning $message
    }
    return $Result
}
