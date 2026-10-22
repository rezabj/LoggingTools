function Initialize-LTLogConfig {
    <#
    .SYNOPSIS
    Configures and starts an asynchronous logger for this PowerShell runspace.
    .DESCRIPTION
    At least one destination is required. Close the existing logger before reinitializing.
    Destination hashtables are documented online. ClientSecret must be a SecureString.
    Certificate must be an RSA X509Certificate2 with its private key.
    .PARAMETER ApplicationName
    Application/script name included in every event.
    .PARAMETER File
    File settings. Path is required. CreateDirectory explicitly permits directory creation.
    .PARAMETER LogAnalytics
    Azure settings including Endpoint, RuleId, Stream, and Authentication.
    .PARAMETER Teams
    Workflows settings including WebhookUrl. Requires a workflow accepting requests without an Entra bearer token.
    .PARAMETER DefaultLevel
    Level used when Write-LTLog omits Level. Defaults to INFO.
    .PARAMETER QueueCapacity
    Default maximum pending events per destination. Defaults to 10000.
    .PARAMETER QueueCapacityBytes
    Default maximum encoded pending payload bytes per destination. Defaults to 32 MiB.
    .PARAMETER RedactField
    Additional case-insensitive structured field names to redact recursively.
    .PARAMETER RedactValue
    Additional literal values to redact in all event string fields.
    .PARAMETER Strict
    Make flush/close throw on failures, drops, or timeout by default.
    .EXAMPLE
    Initialize-LTLogConfig -ApplicationName 'Inventory' -File @{ Path = './logs/inventory.jsonl'; CreateDirectory = $true }
    .LINK
    https://rezabj.github.io/LoggingTools/usage/
    #>
    [CmdletBinding(HelpUri = 'https://rezabj.github.io/LoggingTools/usage/')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ApplicationName,
        [hashtable]$File, [hashtable]$LogAnalytics, [hashtable]$Teams,
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL')][string]$DefaultLevel = 'INFO',
        [ValidateRange(1, 1000000)][int]$QueueCapacity = 10000,
        [ValidateRange(1024, 1073741824)][long]$QueueCapacityBytes = 32MB,
        [string[]]$RedactField = @(), [string[]]$RedactValue = @(), [switch]$Strict
    )
    if ($script:Logger -and -not $script:Logger.IsClosed) { throw 'Close the existing logger with Close-LTLog before reinitializing.' }
    if (-not $File -and -not $LogAnalytics -and -not $Teams) { throw 'Configure at least one destination: File, LogAnalytics, or Teams.' }
    $destinations = [System.Collections.Generic.List[LoggingTools.SinkOptions]]::new()
    $secrets = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $RedactValue) { if ($value) { $secrets.Add($value) } }
    $common = @('MinimumLevel', 'Capacity', 'CapacityBytes', 'BatchCount', 'BatchBytes', 'IntervalMilliseconds')
    $network = @('TimeoutSeconds', 'MaximumRetries')
    if ($File) {
        Assert-LTKey $File ($common + @('Path', 'CreateDirectory', 'MaximumFileBytes', 'RetainedFiles'))
        if (-not $File.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace($File.Path)) { throw 'File requires Path.' }
        $options = New-LTSinkOption File $File $QueueCapacity $QueueCapacityBytes
        $options.Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$File.Path)
        if (Test-Path -LiteralPath $options.Path -PathType Container) { throw 'File Path must name a file, not a directory.' }
        $parent = Split-Path -Parent $options.Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            if ($File.ContainsKey('CreateDirectory') -and $File.CreateDirectory -is [bool] -and $File.CreateDirectory) { [void][System.IO.Directory]::CreateDirectory($parent) }
            else { throw 'File parent directory does not exist. Set CreateDirectory = $true to create it.' }
        }
        Set-LTNumericOption $options $File MaximumFileBytes 0 ([long]::MaxValue)
        Set-LTNumericOption $options $File RetainedFiles 1 1000
        $destinations.Add($options)
    }
    if ($LogAnalytics) {
        Assert-LTKey $LogAnalytics ($common + $network + @('Endpoint', 'RuleId', 'Stream', 'Authentication', 'TenantId', 'ClientId', 'ClientSecret', 'Certificate'))
        foreach ($key in @('Endpoint', 'RuleId', 'Stream', 'Authentication')) {
            if (-not $LogAnalytics.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$LogAnalytics[$key])) { throw "LogAnalytics requires '$key'." }
        }
        $options = New-LTSinkOption LogAnalytics $LogAnalytics $QueueCapacity $QueueCapacityBytes
        $endpoint = Assert-LTHttpsUri $LogAnalytics.Endpoint Endpoint
        if (-not $endpoint.DnsSafeHost.EndsWith('.ingest.monitor.azure.com') -or $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.Fragment) { throw 'Endpoint must be an Azure public-cloud ingestion base URL ending in .ingest.monitor.azure.com.' }
        $options.Endpoint = $endpoint.AbsoluteUri.TrimEnd('/')
        if ($LogAnalytics.RuleId -notmatch '^dcr-[a-fA-F0-9]{32}$') { throw 'RuleId must be the DCR immutable ID (dcr- followed by 32 hexadecimal characters).' }
        if ($LogAnalytics.Stream -notmatch '^Custom-[a-zA-Z][a-zA-Z0-9_]{0,120}$') { throw 'Stream must be a Custom- stream name with letters, digits, and underscores.' }
        $options.RuleId = $LogAnalytics.RuleId; $options.Stream = $LogAnalytics.Stream
        $options.Authentication = switch ($LogAnalytics.Authentication) {
            'ManagedIdentity' { 'ManagedIdentity' }
            'ClientSecret' { 'ClientSecret' }
            'Certificate' { 'Certificate' }
            'AzureCli' { 'AzureCli' }
            default { throw 'Authentication must be ManagedIdentity, ClientSecret, Certificate, or AzureCli.' }
        }
        if ($LogAnalytics.ContainsKey('ClientId')) { $options.ClientId = Assert-LTGuid $LogAnalytics.ClientId ClientId }
        if ($LogAnalytics.ContainsKey('TenantId')) { $options.TenantId = Assert-LTGuid $LogAnalytics.TenantId TenantId }
        if ($options.Authentication -in @('ClientSecret', 'Certificate')) {
            if (-not $options.ClientId -or -not $options.TenantId) { throw 'App registration authentication requires TenantId and ClientId.' }
            if ($options.Authentication -eq 'ClientSecret') {
                if (-not $LogAnalytics.ContainsKey('ClientSecret') -or $LogAnalytics.ClientSecret -isnot [securestring] -or $LogAnalytics.ClientSecret.Length -eq 0) { throw 'ClientSecret authentication requires a nonempty SecureString ClientSecret.' }
                $options.ClientSecret = [System.Net.NetworkCredential]::new('', $LogAnalytics.ClientSecret).Password
                $secrets.Add($options.ClientSecret)
            } else {
                if (-not $LogAnalytics.ContainsKey('Certificate') -or $LogAnalytics.Certificate -isnot [System.Security.Cryptography.X509Certificates.X509Certificate2] -or -not $LogAnalytics.Certificate.HasPrivateKey) { throw 'Certificate authentication requires an X509Certificate2 with an RSA private key.' }
                $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($LogAnalytics.Certificate)
                if (-not $rsa) { throw 'Certificate must have an RSA private key.' }
                $rsa.Dispose()
                $options.Certificate = $LogAnalytics.Certificate
            }
        }
        if ($options.Authentication -eq 'AzureCli') {
            $cli = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cli) { throw 'AzureCli authentication requires Azure CLI (az) on PATH and an existing login.' }
            $options.CliPath = $cli.Source
        }
        $destinations.Add($options)
    }
    if ($Teams) {
        Assert-LTKey $Teams (@('MinimumLevel', 'Capacity', 'CapacityBytes', 'IntervalMilliseconds', 'WebhookUrl', 'MinimumSendIntervalMilliseconds') + $network)
        if (-not $Teams.ContainsKey('WebhookUrl')) { throw 'Teams requires WebhookUrl.' }
        $options = New-LTSinkOption Teams $Teams $QueueCapacity $QueueCapacityBytes
        $options.WebhookUrl = (Assert-LTHttpsUri $Teams.WebhookUrl WebhookUrl).AbsoluteUri
        $secrets.Add([string]$Teams.WebhookUrl); $secrets.Add($options.WebhookUrl)
        Set-LTNumericOption $options $Teams MinimumSendIntervalMilliseconds 250 60000
        $destinations.Add($options)
    }
    $fields = @('Password', 'Secret', 'ClientSecret', 'Token', 'AccessToken', 'RefreshToken', 'Authorization', 'WebhookUrl', 'IDENTITY_HEADER') + $RedactField
    $script:Logger = [LoggingTools.Logger]::new($ApplicationName, $destinations.ToArray(), $fields, $secrets.ToArray())
    $script:DefaultLevel = $DefaultLevel.ToUpperInvariant()
    $script:StrictDelivery = $Strict.IsPresent
}
