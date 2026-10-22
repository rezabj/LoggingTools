Describe 'LoggingTools version 1' {
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LoggingTools/LoggingTools.psd1') -Force
    if (-not ('LoggingToolsTests.Handler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'HttpTestHandler.cs') }
    function New-TestNetwork {
        param([string]$Kind = 'LogAnalytics', [string]$Authentication = 'ClientSecret')
        $handler = [LoggingToolsTests.Handler]::new()
        $client = [System.Net.Http.HttpClient]::new($handler)
        $options = [LoggingTools.SinkOptions]::new()
        $options.Name = $Kind; $options.Kind = $Kind
        $options.Endpoint = 'https://test.ingest.monitor.azure.com'
        $options.RuleId = 'dcr-00000000000000000000000000000001'
        $options.Stream = 'Custom-LoggingTools'
        $options.Authentication = $Authentication
        $options.ClientId = '00000000-0000-0000-0000-000000000001'
        $options.TenantId = '00000000-0000-0000-0000-000000000002'
        $options.ClientSecret = 'sensitive-client-secret'
        $options.WebhookUrl = 'https://example.invalid/workflow?sig=secret'
        $options.TestClient = $client
        $options.RetryBaseMilliseconds = 1
        $options.IntervalMilliseconds = 10
        $options.MinimumSendIntervalMilliseconds = 1
        if ($Kind -eq 'Teams') { $options.BatchCount = 1 }
        return @{ Options = $options; Handler = $handler; Client = $client }
    }
    function Start-TestLogger {
        param([LoggingTools.SinkOptions[]]$Options)
        $script:engine = [LoggingTools.Logger]::new('tests', $Options, @('password', 'token'), @('sensitive-client-secret'))
        return $script:engine
    }
}

AfterEach {
    if ($script:engine) { [void]$script:engine.Close(500); $script:engine = $null }
    try { $null = Close-LTLog -TimeoutSeconds 0.2 -WarningAction SilentlyContinue } catch { }
}

Describe 'Public module contract and file logging' {
    It 'exports only approved LT commands and no variables' {
        $manifest = Test-ModuleManifest (Join-Path $PSScriptRoot '../LoggingTools/LoggingTools.psd1')
        $manifest.Version | Should -Be '1.0.0'
        $manifest.PowerShellVersion | Should -Be '7.0'
        $manifest.ExportedVariables.Count | Should -Be 0
        $commands = @(Get-Command -Module LoggingTools)
        $commands.Count | Should -Be 6
        foreach ($command in $commands) {
            $command.Name | Should -Match '^[A-Za-z]+-LT[A-Za-z]+$'
            $command.Verb | Should -BeIn (Get-Verb).Verb
        }
    }
    It 'writes ordered UTF-8 JSON Lines with a consistent schema and snapshots data' {
        $path = Join-Path $TestDrive 'events.jsonl'
        Initialize-LTLogConfig -ApplicationName Inventory -File @{ Path = $path }
        $data = @{ Count = 42 }
        Write-LTLog -Message 'Příliš žluťoučký 🐧' -Data $data -CorrelationId run-1
        $data.Count = 99
        Write-LTLog -Message second
        $result = Close-LTLog -Strict
        $result.Success | Should -BeTrue
        $result.Destinations[0].Delivered | Should -Be 2
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 2
        $first = $lines[0] | ConvertFrom-Json
        $first.Message | Should -Be 'Příliš žluťoučký 🐧'
        $first.Data.Count | Should -Be 42
        $first.Application | Should -Be Inventory
        $first.CorrelationId | Should -Be run-1
        $first.EventId | Should -Match '^[a-f0-9-]{36}$'
        # PowerShell 7.6 converts JSON dates to local DateTime objects. Inspect the wire value.
        $wire = [Text.Json.JsonDocument]::Parse($lines[0])
        try { [DateTimeOffset]::Parse($wire.RootElement.GetProperty('TimeGenerated').GetString()).Offset | Should -Be ([TimeSpan]::Zero) }
        finally { $wire.Dispose() }
        ($lines[1] | ConvertFrom-Json).Message | Should -Be second
        [System.IO.File]::ReadAllBytes($path)[0] | Should -Be 123
    }
    It 'honors explicit levels, default levels, filtering, and pipeline messages' {
        $path = Join-Path $TestDrive 'levels.jsonl'
        Initialize-LTLogConfig -ApplicationName tests -DefaultLevel WARNING -File @{ Path = $path; MinimumLevel = 'WARNING' }
        Write-LTLog -Message omitted
        Write-LTLog -Message debug -Level DEBUG
        Write-LTLog -Message explicit -Level CRITICAL
        Set-LTLogDefaultLevel ERROR
        'pipeline-1', 'pipeline-2' | Write-LTLog
        $null = Close-LTLog -Strict
        $events = @(Get-Content $path | ConvertFrom-Json)
        ($events.Level -join ',') | Should -Be 'WARNING,CRITICAL,ERROR,ERROR'
    }
    It 'redacts nested fields and configured values before any destination receives them' {
        $path = Join-Path $TestDrive 'redacted.jsonl'
        Initialize-LTLogConfig -ApplicationName 'private-value' -File @{ Path = $path } -RedactField ApiKey -RedactValue private-value
        Write-LTLog -Message 'private-value present' -Data @{ Items = @(@{ Password = 'hunter2'; apiKEY = 'abcd'; Visible = 'private-value' }) }
        $null = Close-LTLog -Strict
        $raw = Get-Content $path -Raw
        $raw | Should -Not -Match 'hunter2|abcd|private-value'
        ($raw | ConvertFrom-Json).Data.Items[0].Password | Should -Be '[REDACTED]'
    }
    It 'captures a caught error without serializing the entire ErrorRecord' {
        $path = Join-Path $TestDrive 'errors.jsonl'
        Initialize-LTLogConfig -ApplicationName tests -File @{ Path = $path }
        try { throw 'example failure' } catch { Write-LTLog -Message failed -Level ERROR -ErrorRecord $_ }
        $null = Close-LTLog -Strict
        $event = Get-Content $path | ConvertFrom-Json
        $event.Exception.Message | Should -Be 'example failure'
        $event.Exception.Type | Should -Not -BeNullOrEmpty
    }
    It 'rotates only owned files and respects retention' {
        $path = Join-Path $TestDrive 'rotate.jsonl'
        $unrelated = Join-Path $TestDrive 'unrelated.jsonl'
        Set-Content $unrelated keep
        Initialize-LTLogConfig -ApplicationName tests -File @{ Path = $path; MaximumFileBytes = 500; RetainedFiles = 2 }
        1..10 | ForEach-Object { Write-LTLog -Message ('event-' + $_) }
        $null = Close-LTLog -Strict
        (Get-Content $path | ConvertFrom-Json).Message | Should -Be 'event-10'
        Test-Path "$path.1" | Should -BeTrue
        Test-Path "$path.2" | Should -BeTrue
        Test-Path "$path.3" | Should -BeFalse
        (Get-Content $unrelated).Trim() | Should -Be keep
    }
    It 'can disable rotation and append across logger instances' {
        $path = Join-Path $TestDrive 'append.jsonl'
        foreach ($message in @('one', 'two')) {
            Initialize-LTLogConfig -ApplicationName tests -File @{ Path = $path; MaximumFileBytes = 0 }
            Write-LTLog $message
            $null = Close-LTLog -Strict
        }
        @(Get-Content $path).Count | Should -Be 2
        Test-Path "$path.1" | Should -BeFalse
    }
    It 'validates destinations and rejects typos and insecure endpoints' {
        { Initialize-LTLogConfig -ApplicationName tests } | Should -Throw '*at least one*'
        { Initialize-LTLogConfig -ApplicationName tests -File @{ Path = (Join-Path $TestDrive 'missing/log.jsonl') } } | Should -Throw '*parent directory*'
        { Initialize-LTLogConfig -ApplicationName tests -File @{ Path = $TestDrive; Typo = 1 } } | Should -Throw '*Unknown*'
        { Initialize-LTLogConfig -ApplicationName tests -Teams @{ WebhookUrl = 'http://example.invalid' } } | Should -Throw '*HTTPS*'
    }
    It 'closes explicitly and rejects writes until reinitialized' {
        Initialize-LTLogConfig -ApplicationName tests -File @{ Path = (Join-Path $TestDrive 'closed.jsonl') }
        $null = Close-LTLog -Strict
        { Write-LTLog after-close } | Should -Throw '*closed*'
        { Close-LTLog -Strict } | Should -Not -Throw
    }
}

Describe 'Asynchronous queues and network delivery with mocked HTTP transport' {
    BeforeEach { $script:network = New-TestNetwork }
    AfterEach { $script:network.Client.Dispose() }

    It 'batches Azure events and reuses a cached Monitor token' {
        $logger = Start-TestLogger @($network.Options)
        1..20 | ForEach-Object { $null = $logger.Write('INFO', "event-$_", $null, $null, 'run-1') }
        $logger.Flush(5000).Success | Should -BeTrue
        $network.Handler.TokenCalls | Should -Be 1
        $network.Handler.DeliveryCalls | Should -BeLessThan 20
        $requests = @($network.Handler.Requests.ToArray() | Where-Object Uri -Match 'dataCollectionRules')
        $events = @($requests | ForEach-Object { $_.Body | ConvertFrom-Json })
        $events.Count | Should -Be 20
        $events[0].Message | Should -Be event-1
        $requests[0].Authorization | Should -Be 'Bearer test-token'
        $tokenRequest = @($network.Handler.Requests.ToArray() | Where-Object Uri -Match 'oauth2')[0]
        [uri]::UnescapeDataString($tokenRequest.Body) | Should -Match 'https://monitor.azure.com/.default'
    }
    It 'refreshes tokens nearing expiry between batches' {
        $network.Handler.TokenLifetime = 60
        $network.Options.BatchCount = 1
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'first', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeTrue
        $null = $logger.Write('INFO', 'second', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeTrue
        $network.Handler.TokenCalls | Should -Be 2
    }
    It 'retries 429 and 503 responses but never retries a permanent 400' {
        $network.Handler.Responses.Enqueue(429)
        $network.Handler.Responses.Enqueue(503)
        $network.Handler.Responses.Enqueue(204)
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('ERROR', 'retry', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeTrue
        $network.Handler.DeliveryCalls | Should -Be 3
        $network.Handler.Responses.Enqueue(400)
        $null = $logger.Write('ERROR', 'permanent', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeFalse
        $network.Handler.DeliveryCalls | Should -Be 4
        $logger.GetStatus()[0].LastError | Should -Match 'HTTP 400'
        $logger.GetStatus()[0].LastError | Should -Not -Match 'private response'
    }
    It 'bounds network retries and sanitizes connection exceptions' {
        $network.Handler.FailNetwork = $true
        $network.Options.MaximumRetries = 1
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'failed', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeFalse
        $network.Handler.DeliveryCalls | Should -Be 2
        $logger.GetStatus()[0].LastError | Should -Not -Match 'sensitive|secret|https://'
    }
    It 'honors Retry-After and cancels a pending retry at close timeout' {
        $network.Handler.Responses.Enqueue(429)
        $network.Handler.RetryAfter = '60'
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'wait', $null, $null, $null)
        $network.Handler.Started.Wait(3000) | Should -BeTrue
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $result = $logger.Close(100)
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 2
        $result.TimedOut | Should -BeTrue
        $network.Handler.DeliveryCalls | Should -Be 1
    }
    It 'rejects oversized Azure events without sending truncated JSON' {
        $network.Options.BatchBytes = 1024
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', ('x' * 2000), $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeFalse
        $network.Handler.DeliveryCalls | Should -Be 0
        $logger.GetStatus()[0].Failed | Should -Be 1
    }
    It 'splits encoded Azure batches within their byte limit' {
        $network.Options.BatchBytes = 1200
        $logger = Start-TestLogger @($network.Options)
        1..12 | ForEach-Object { $null = $logger.Write('INFO', ('ž' * 25), $null, $null, $null) }
        $logger.Flush(5000).Success | Should -BeTrue
        $deliveries = @($network.Handler.Requests.ToArray() | Where-Object Uri -Match 'dataCollectionRules')
        foreach ($request in $deliveries) { [Text.Encoding]::UTF8.GetByteCount($request.Body) | Should -BeLessOrEqual 1200 }
        @($deliveries | ForEach-Object { $_.Body | ConvertFrom-Json }).Count | Should -Be 12
    }
    It 'rejects Azure field values that would be truncated by the service' {
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'valid before', $null, $null, $null)
        $null = $logger.Write('INFO', ('x' * 65537), $null, $null, $null)
        $null = $logger.Write('INFO', 'valid after', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeFalse
        $logger.GetStatus()[0].Failed | Should -Be 1
        $logger.GetStatus()[0].Delivered | Should -Be 2
        $logger.GetStatus()[0].LastError | Should -Match '64 KiB'
    }
    It 'keeps slow Azure independent from file delivery and reports overflow by level' {
        $network.Options.Capacity = 2
        $network.Options.BatchCount = 1
        $network.Handler.Block = $true
        $file = [LoggingTools.SinkOptions]::new()
        $file.Name = 'File'; $file.Kind = 'File'; $file.Path = Join-Path $TestDrive 'independent.jsonl'
        $file.IntervalMilliseconds = 1
        $logger = Start-TestLogger @($network.Options, $file)
        $null = $logger.Write('INFO', 'first', $null, $null, $null)
        $network.Handler.Started.Wait(3000) | Should -BeTrue
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $warnings = @()
        1..10 | ForEach-Object { $warnings += $logger.Write('ERROR', "next-$_", $null, $null, $null) }
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 1
        $warnings.Count | Should -Be 1
        $status = $logger.GetStatus() | Where-Object Name -EQ LogAnalytics
        $status.Accepted | Should -Be 2
        $status.Dropped | Should -Be 9
        $status.DroppedByLevel.ERROR | Should -Be 9
        $network.Handler.Release.Set()
        $logger.Flush(5000).Success | Should -BeFalse
        ($logger.GetStatus() | Where-Object Name -EQ File).Delivered | Should -Be 11
    }
    It 'enforces the queue payload byte limit independently of event capacity' {
        $network.Options.CapacityBytes = 1024
        $network.Options.Capacity = 100
        $network.Handler.Block = $true
        $network.Options.BatchCount = 1
        $logger = Start-TestLogger @($network.Options)
        1..20 | ForEach-Object { $null = $logger.Write('INFO', ('x' * 400), $null, $null, $null) }
        $status = $logger.GetStatus()[0]
        $status.PendingBytes | Should -BeLessOrEqual 1024
        $status.Dropped | Should -BeGreaterThan 0
    }
    It 'uses managed identity metadata with the Monitor resource audience' {
        $oldEndpoint = $env:IDENTITY_ENDPOINT; $oldHeader = $env:IDENTITY_HEADER
        try {
            $env:IDENTITY_ENDPOINT = $null; $env:IDENTITY_HEADER = $null
            $network.Options.Authentication = 'ManagedIdentity'
            $logger = Start-TestLogger @($network.Options)
            $null = $logger.Write('INFO', 'managed', $null, $null, $null)
            $logger.Flush(5000).Success | Should -BeTrue
            $request = $network.Handler.Requests.ToArray()[0]
            $request.Uri | Should -Match '169.254.169.254/metadata/identity/oauth2/token'
            [uri]::UnescapeDataString($request.Uri) | Should -Match 'resource=https://monitor.azure.com'
            $request.Metadata | Should -Be true
        } finally { $env:IDENTITY_ENDPOINT = $oldEndpoint; $env:IDENTITY_HEADER = $oldHeader }
    }
    It 'creates a verifiable PS256 client assertion for certificate authentication' {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=LoggingTools-test', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        try {
            $network.Options.Authentication = 'Certificate'; $network.Options.Certificate = $certificate
            $logger = Start-TestLogger @($network.Options)
            $null = $logger.Write('INFO', 'certificate', $null, $null, $null)
            $logger.Flush(5000).Success | Should -BeTrue
            $form = [uri]::UnescapeDataString($network.Handler.Requests.ToArray()[0].Body)
            $assertion = ([regex]::Match($form, '(?:^|&)client_assertion=([^&]+)')).Groups[1].Value
            $parts = $assertion.Split('.')
            $signature = $parts[2].Replace('-', '+').Replace('_', '/')
            $signature = $signature.PadRight([int]([Math]::Ceiling($signature.Length / 4.0) * 4), '=')
            $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($parts[0] + '.' + $parts[1]), [Convert]::FromBase64String($signature), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss) | Should -BeTrue
        } finally { [void]$logger.Close(1000); $certificate.Dispose(); $rsa.Dispose() }
    }
    It 'uses an App Service identity endpoint and its required secret header' {
        $oldEndpoint = $env:IDENTITY_ENDPOINT; $oldHeader = $env:IDENTITY_HEADER
        try {
            $env:IDENTITY_ENDPOINT = 'http://127.0.0.1/metadata/identity/oauth2/token'
            $env:IDENTITY_HEADER = 'private-identity-header'
            $network.Options.Authentication = 'ManagedIdentity'
            $logger = Start-TestLogger @($network.Options)
            $null = $logger.Write('INFO', 'managed', $null, $null, $null)
            $logger.Flush(5000).Success | Should -BeTrue
            $request = $network.Handler.Requests.ToArray()[0]
            $request.IdentityHeader | Should -Be 'private-identity-header'
            $request.Uri | Should -Match 'api-version=2019-08-01'
        } finally { $env:IDENTITY_ENDPOINT = $oldEndpoint; $env:IDENTITY_HEADER = $oldHeader }
    }
    It 'obtains and caches a token through a local Azure CLI stub with a spaced path' {
        $expiry = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        $argumentsPath = Join-Path $TestDrive 'cli-arguments.txt'
        if ($IsWindows) {
            $cli = Join-Path $TestDrive 'azure cli stub.cmd'
            $content = "@echo off`r`necho %*> `"$argumentsPath`"`r`necho {`"accessToken`":`"cli-token`",`"expires_on`":$expiry}`r`n"
        } else {
            $cli = Join-Path $TestDrive 'azure cli stub'
            $content = '#!/bin/sh' + "`n" + 'printf ''%s\n'' "$*" > "' + $argumentsPath + '"' + "`n" + 'printf ''%s\n'' ''{"accessToken":"cli-token","expires_on":' + $expiry + '}''' + "`n"
        }
        [IO.File]::WriteAllText($cli, $content, [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { & chmod +x $cli }
        $network.Options.Authentication = 'AzureCli'; $network.Options.CliPath = $cli
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'cli', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeTrue
        $network.Handler.Requests.ToArray()[0].Authorization | Should -Be 'Bearer cli-token'
        Get-Content -LiteralPath $argumentsPath | Should -Match 'account get-access-token --resource https://monitor.azure.com'
    }
    It 'reports failure when the configured CLI process cannot be started' {
        $network.Options.Authentication = 'AzureCli'; $network.Options.CliPath = Join-Path $TestDrive 'missing-cli'
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'cli-failure', $null, $null, $null)
        $logger.Flush(5000).Success | Should -BeFalse
        $network.Handler.DeliveryCalls | Should -Be 0
        $logger.GetStatus()[0].LastError | Should -Not -Match ([regex]::Escape($TestDrive))
    }
    It 'surfaces asynchronous failures through strict public flush and close' {
        $network.Handler.Responses.Enqueue(403)
        $logger = Start-TestLogger @($network.Options)
        & (Get-Module LoggingTools) { param($value) $script:Logger = $value } $logger
        Write-LTLog -Message forbidden -Level ERROR
        { Sync-LTLog -Strict } | Should -Throw '*failures/drops*'
        { Close-LTLog -Strict } | Should -Throw '*failures/drops*'
        $logger.IsClosed | Should -BeTrue
    }
    It 'delivers a partial batch on its interval without requiring explicit flush' {
        $network.Options.IntervalMilliseconds = 20
        $logger = Start-TestLogger @($network.Options)
        $null = $logger.Write('INFO', 'interval', $null, $null, $null)
        $network.Handler.Started.Wait(3000) | Should -BeTrue
        $network.Handler.DeliveryCalls | Should -Be 1
    }
}

Describe 'Teams workflow payloads' {
    It 'sends an Adaptive Card containing the original event and enforces payload size' {
        $network = New-TestNetwork Teams
        try {
            $logger = Start-TestLogger @($network.Options)
            $null = $logger.Write('ERROR', 'Teams failure', $null, $null, 'teams-run')
            $logger.Flush(5000).Success | Should -BeTrue
            $card = $network.Handler.Requests.ToArray()[0].Body | ConvertFrom-Json
            $card.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
            ($card.attachments[0].content.body[0].text | ConvertFrom-Json).CorrelationId | Should -Be teams-run
            $null = $logger.Write('CRITICAL', ('x' * 30000), $null, $null, $null)
            $logger.Flush(5000).Success | Should -BeFalse
            $network.Handler.DeliveryCalls | Should -Be 1
        } finally { [void]$logger.Close(1000); $network.Client.Dispose() }
    }
}
}
