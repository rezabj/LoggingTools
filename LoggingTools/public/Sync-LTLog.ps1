function Sync-LTLog {
    <#
    .SYNOPSIS
    Waits for events accepted before this call to finish delivery, up to a timeout.
    .PARAMETER TimeoutSeconds
    Maximum time to wait. Defaults to 30 seconds.
    .PARAMETER Strict
    Throw on timeout, failures, or drops. Defaults to the initialization setting.
    .EXAMPLE
    $result = Sync-LTLog -TimeoutSeconds 60 -Strict
    .LINK
    https://rezabj.github.io/LoggingTools/reference/#sync-ltlog
    #>
    [CmdletBinding(HelpUri = 'https://rezabj.github.io/LoggingTools/reference/#sync-ltlog')]
    param([ValidateRange(0.001, 3600)][double]$TimeoutSeconds = 30, [switch]$Strict)
    Assert-LTLogger
    $strictMode = if ($PSBoundParameters.ContainsKey('Strict')) { $Strict.IsPresent } else { $script:StrictDelivery }
    Write-LTDeliveryResult -Result $script:Logger.Flush([int]($TimeoutSeconds * 1000)) -Strict $strictMode
}
