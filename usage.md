---
title: Installation and usage
permalink: /usage/
---
# Installation and usage

## Install from the repository

Clone the repository and import its module manifest. This does not require the module to be published to PowerShell Gallery.

```powershell
git clone https://github.com/rezabj/LoggingTools.git
Set-Location LoggingTools
Import-Module ./LoggingTools/LoggingTools.psd1
Get-Command -Module LoggingTools
```

Use an absolute manifest path in scheduled jobs, or copy the `LoggingTools` module directory into a directory listed in `$env:PSModulePath` and run `Import-Module LoggingTools`. No Azure or Graph PowerShell SDK, Pester, or Azure CLI is needed for file logging. Azure CLI is required only for `AzureCli` authentication.

The first import compiles the bundled C# worker source using PowerShell's built-in compiler. That initialization cost is separate from event enqueue performance. All exported commands follow `<Verb>-LT<Noun>`.

## File logging and error handling

Use a separate file path for each concurrently running script. A logger has one writer per configured file, and does not coordinate writes from other processes or runspaces to the same path.

```powershell
$runId = [guid]::NewGuid().ToString()
$fileName = './logs/inventory-' + $runId + '.jsonl'
Initialize-LTLogConfig -ApplicationName 'Inventory' -File @{
    Path = $fileName
    CreateDirectory = $true
    MinimumLevel = 'INFO'
    MaximumFileBytes = 10MB
    RetainedFiles = 5
}
try {
    Write-LTLog -Message 'Started' -CorrelationId $runId
    Write-LTLog -Message 'Detailed progress' -Level DEBUG # filtered out
    Write-LTLog -Message 'Processed items' -Data @{ Count = 42 } -CorrelationId $runId
    # Your script work goes here.
} catch {
    Write-LTLog -Message 'Inventory failed' -Level ERROR -ErrorRecord $_ -CorrelationId $runId
    throw
} finally {
    $delivery = Close-LTLog -TimeoutSeconds 30
    if (-not $delivery.Success) { $delivery.Destinations | Format-Table Name, Failed, Dropped, Pending }
}
```

Files contain UTF-8 JSON Lines without a byte-order mark. Rotation produces `name.jsonl.1` through `.5`, with `.1` the newest archive. `RetainedFiles` counts archives in addition to the active file. Set `MaximumFileBytes = 0` to disable rotation. One event larger than the rotation limit is written whole to its own file rather than split.

Read local events using `Get-Content ./logs/example.jsonl | ConvertFrom-Json`. Core fields are `TimeGenerated` (UTC), `EventId`, `Level`, `Message`, `Application`, `HostName`, `ProcessId`, `CorrelationId`, `Data`, and `Exception`.

## Levels, data, and redaction

Severity order is `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`. File and Azure default to `INFO`; Teams defaults to `ERROR`. Each destination has its own `MinimumLevel`. `Set-LTLogDefaultLevel WARNING` changes only the level used when a call omits `-Level`.

`-Data` accepts JSON-serializable objects. Data is captured at the logging call; later mutations do not change queued events. Serialization is limited to depth 32 and reports an error rather than silently accepting a depth warning. Avoid large or recursive objects in a high-volume logging path.

Default redacted field names include Password, Secret, ClientSecret, Token, AccessToken, RefreshToken, Authorization, WebhookUrl, and IDENTITY_HEADER. Matching is case-insensitive and recursive. Add field names and literal secret values:

```powershell
Initialize-LTLogConfig -ApplicationName 'Job' -File @{ Path = './job.jsonl' } `
    -RedactField @('ApiKey', 'ConnectionString') -RedactValue @($knownSensitiveValue)
```

Configured client secrets and Teams webhook URLs are automatically included in literal redaction. Redaction does not detect every possible password embedded in arbitrary prose; callers must avoid logging sensitive data. A `SecureString` protects configuration handling but the sending process necessarily holds usable credentials in memory.

## Combined file and Azure delivery

First complete the [Azure setup guide]({{ '/azure/' | relative_url }}), then configure both destinations once:

```powershell
Initialize-LTLogConfig -ApplicationName 'Inventory' `
    -File @{ Path = './inventory.jsonl' } `
    -LogAnalytics @{
        Endpoint = $ingestionEndpoint
        RuleId = $dcrImmutableId
        Stream = 'Custom-LoggingTools'
        Authentication = 'ManagedIdentity'
    }
try {
    Write-LTLog -Message 'Same event goes to file and Azure' -Data @{ Count = 42 }
} finally {
    $delivery = Close-LTLog -TimeoutSeconds 60
}
```

## Teams Workflows webhook

In Teams, use **Workflows** to create a webhook workflow that posts to the intended channel or chat. Choose a trigger configuration that permits requests without an Entra bearer token (commonly **Anyone**); version 1 treats the secret webhook URL as the credential and does not supply a Teams access token. Add a co-owner so the workflow survives an owner's departure. See [Microsoft's workflow instructions](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook).

```powershell
# Obtain this URL from your secret store; do not commit it to source control.
Initialize-LTLogConfig -ApplicationName 'Job' -Teams @{
    WebhookUrl = $teamsWebhookUrl
    MinimumLevel = 'ERROR'
    MinimumSendIntervalMilliseconds = 1000
}
try { Write-LTLog -Message 'An operation failed' -Level ERROR }
finally { $delivery = Close-LTLog }
```

The worker sends each qualifying event as an Adaptive Card, at most once per configured interval before retries. Default interval is one second. Payloads over 28 KiB fail explicitly. Teams HTTP acceptance is not confirmation that the downstream workflow posted the message; use the workflow run history to diagnose that step.

## Unattended jobs and shutdown

Use managed identity or an app registration in unattended jobs. The logger never starts an interactive sign-in. An `AzureCli` session must already exist and may need external renewal.

`Sync-LTLog` waits for events accepted before the call while leaving the logger open. `Close-LTLog` stops new writes and requests worker cleanup after flushing. Both return a result and warn by default on failure, drops, or timeout. Add `-Strict` to throw, or initialize with `-Strict` to make this the default; `-Strict:$false` overrides it for a particular call. In a `finally` block, consider whether a strict close failure should replace an earlier script error.

Logger state is local to the importing PowerShell runspace. Initialize and close one logger in each parallel runspace, with separate file paths. Forced termination or `Stop-Process` can bypass cleanup.
