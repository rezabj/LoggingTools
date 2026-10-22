function Get-LTLogStatus {
    <#
    .SYNOPSIS
    Returns delivery counters, backlog, worker state, and sanitized errors per destination.
    .DESCRIPTION
    Counters are cumulative for the current logger, including after close. Pending includes in-flight events.
    .EXAMPLE
    Get-LTLogStatus | Format-Table Name, Accepted, Delivered, Failed, Dropped, Pending
    .LINK
    https://rezabj.github.io/LoggingTools/reference/#get-ltlogstatus
    #>
    [CmdletBinding(HelpUri = 'https://rezabj.github.io/LoggingTools/reference/#get-ltlogstatus')]
    param()
    Assert-LTLogger
    $script:Logger.GetStatus()
}
