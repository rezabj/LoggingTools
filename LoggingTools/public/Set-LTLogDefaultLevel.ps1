function Set-LTLogDefaultLevel {
    <#
    .SYNOPSIS
    Sets the severity used when Write-LTLog omits Level.
    .PARAMETER Level
    DEBUG, INFO, WARNING, ERROR, or CRITICAL. Does not change destination thresholds.
    .EXAMPLE
    Set-LTLogDefaultLevel -Level WARNING
    .LINK
    https://rezabj.github.io/LoggingTools/reference/#set-ltlogdefaultlevel
    #>
    [CmdletBinding(SupportsShouldProcess, HelpUri = 'https://rezabj.github.io/LoggingTools/reference/#set-ltlogdefaultlevel')]
    param([Parameter(Mandatory)][ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')][string]$Level)
    if ($PSCmdlet.ShouldProcess('Current logger', "Set default level to $Level")) { $script:DefaultLevel = $Level.ToUpperInvariant() }
}
