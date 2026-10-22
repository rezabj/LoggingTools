function Close-LTLog {
    <#
    .SYNOPSIS
    Stops accepting events, flushes pending events, and closes background workers.
    .DESCRIPTION
    Call in a finally block. On timeout, pending delivery is cancelled; inspect the returned result.
    .PARAMETER TimeoutSeconds
    Total close deadline including flush and worker cleanup. Defaults to 30 seconds.
    .PARAMETER Strict
    Throw on timeout, failures, or drops after requesting worker cleanup.
    .EXAMPLE
    $result = Close-LTLog -TimeoutSeconds 30 -Strict
    .LINK
    https://rezabj.github.io/LoggingTools/reference/#close-ltlog
    #>
    [CmdletBinding(HelpUri = 'https://rezabj.github.io/LoggingTools/reference/#close-ltlog')]
    param([ValidateRange(0.001, 3600)][double]$TimeoutSeconds = 30, [switch]$Strict)
    Assert-LTLogger
    $strictMode = if ($PSBoundParameters.ContainsKey('Strict')) { $Strict.IsPresent } else { $script:StrictDelivery }
    Write-LTDeliveryResult -Result $script:Logger.Close([int]($TimeoutSeconds * 1000)) -Strict $strictMode
}
