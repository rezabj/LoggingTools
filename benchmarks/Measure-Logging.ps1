[CmdletBinding()]
param(
    [ValidateSet('File', 'MockAzure', 'Combined', 'QueueFull')][string]$Scenario = 'File',
    [ValidateRange(1, 100000)][int]$Rate = 1000,
    [ValidateRange(1, 600)][int]$Seconds = 60,
    [ValidateRange(1, 100000)][int]$PayloadCharacters = 700,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/benchmarks')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../LoggingTools/LoggingTools.psd1') -Force
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$runId = [guid]::NewGuid().ToString('N')
$path = Join-Path $OutputDirectory "$Scenario-$runId.jsonl"
$handler = $null; $client = $null
try {
    if ($Scenario -eq 'File') {
        Initialize-LTLogConfig -ApplicationName benchmark -File @{ Path = $path; MaximumFileBytes = 0 }
    } else {
        if (-not ('LoggingToolsTests.Handler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot '../tests/HttpTestHandler.cs') }
        $handler = [LoggingToolsTests.Handler]::new()
        $handler.MaximumCapturedRequests = 2
        $client = [Net.Http.HttpClient]::new($handler)
        $azure = [LoggingTools.SinkOptions]::new()
        $azure.Name = 'LogAnalytics'; $azure.Kind = 'LogAnalytics'
        $azure.Endpoint = 'https://benchmark.ingest.monitor.azure.com'; $azure.RuleId = 'dcr-benchmark'; $azure.Stream = 'Custom-Benchmark'
        $azure.Authentication = 'ClientSecret'; $azure.TenantId = 'benchmark'; $azure.ClientId = 'benchmark'; $azure.ClientSecret = 'test-only'
        $azure.TestClient = $client
        if ($Scenario -eq 'QueueFull') { $handler.Block = $true; $azure.Capacity = 1; $azure.BatchCount = 1 }
        $options = [Collections.Generic.List[LoggingTools.SinkOptions]]::new(); $options.Add($azure)
        if ($Scenario -eq 'Combined') {
            $file = [LoggingTools.SinkOptions]::new()
            $file.Name = 'File'; $file.Kind = 'File'; $file.Path = $path; $file.MaximumFileBytes = 0
            $options.Add($file)
        }
        $engine = [LoggingTools.Logger]::new('benchmark', $options.ToArray(), @(), @())
        & (Get-Module LoggingTools) { param($value) $script:Logger = $value } $engine
    }
    # Warm up the exact structured-data path, not just the message-only path.
    $message = 'x' * $PayloadCharacters
    if ($Scenario -eq 'QueueFull') {
        Write-LTLog -Message $message -Data @{ Sequence = -1 }
        if (-not $handler.Started.Wait(5000)) { throw 'Mock transport did not start.' }
        1..1000 | ForEach-Object { Write-LTLog -Message $message -Data @{ Sequence = -1 } -WarningAction SilentlyContinue }
    } else {
        1..1000 | ForEach-Object { Write-LTLog -Message $message -Data @{ Sequence = -1 } -WarningAction SilentlyContinue }
        $null = Sync-LTLog -Strict
    }
    $before = @(Get-LTLogStatus)
    $count = $Rate * $Seconds
    $latency = [double[]]::new($count)
    $frequency = [Diagnostics.Stopwatch]::Frequency
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $peak = $process.WorkingSet64
    $timer = [Diagnostics.Stopwatch]::StartNew()
    for ($index = 0; $index -lt $count; $index++) {
        $due = $index / [double]$Rate
        while ($timer.Elapsed.TotalSeconds -lt $due) {
            if (($due - $timer.Elapsed.TotalSeconds) -gt 0.002) { [Threading.Thread]::Sleep(1) }
            else { [Threading.Thread]::SpinWait(20) }
        }
        $start = [Diagnostics.Stopwatch]::GetTimestamp()
        Write-LTLog -Message $message -Data @{ Sequence = $index } -WarningAction SilentlyContinue
        $latency[$index] = ([Diagnostics.Stopwatch]::GetTimestamp() - $start) * 1000.0 / $frequency
        if ($index % 1000 -eq 0) { $process.Refresh(); $peak = [Math]::Max($peak, $process.WorkingSet64) }
    }
    $producerSeconds = $timer.Elapsed.TotalSeconds
    $pendingBeforeFlush = @(Get-LTLogStatus)
    if ($handler) { $handler.Release.Set() }
    $flushTimer = [Diagnostics.Stopwatch]::StartNew()
    $result = Close-LTLog -TimeoutSeconds 60 -WarningAction SilentlyContinue
    $flushMilliseconds = $flushTimer.Elapsed.TotalMilliseconds
    [Array]::Sort($latency)
    $process.Refresh(); $peak = [Math]::Max($peak, $process.WorkingSet64)
    $encodedEventBytes = if (Test-Path -LiteralPath $path) {
        [Text.Encoding]::UTF8.GetByteCount((Get-Content -LiteralPath $path -Tail 1))
    } elseif ($handler -and $handler.Requests.Count -gt 0) {
        $request = @($handler.Requests.ToArray() | Where-Object Uri -Match 'dataCollectionRules')[-1]
        $document = [Text.Json.JsonDocument]::Parse($request.Body)
        try { [Text.Encoding]::UTF8.GetByteCount($document.RootElement[0].GetRawText()) } finally { $document.Dispose() }
    } else { 0 }
    $report = [ordered]@{
        Scenario = $Scenario; PowerShell = $PSVersionTable.PSVersion.ToString(); Platform = $PSVersionTable.Platform
        OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        ProcessorCount = [Environment]::ProcessorCount; Events = $count; RequestedRate = $Rate
        EncodedEventBytes = $encodedEventBytes; ProducerSeconds = $producerSeconds
        ActualEventsPerSecond = $count / $producerSeconds
        MeanMilliseconds = ($latency | Measure-Object -Average).Average
        P50Milliseconds = $latency[[int][Math]::Floor(($count - 1) * 0.50)]
        P95Milliseconds = $latency[[int][Math]::Floor(($count - 1) * 0.95)]
        P99Milliseconds = $latency[[int][Math]::Floor(($count - 1) * 0.99)]
        FlushMilliseconds = $flushMilliseconds; PeakWorkingSetMiB = $peak / 1MB
        BaselineStatus = $before; BeforeFlush = $pendingBeforeFlush; FinalStatus = $result.Destinations
        Success = $result.Success; Transport = if ($Scenario -eq 'File') { 'Local file' } else { 'In-memory mocked HTTP; not an Azure service benchmark' }
    }
    $targetsMet = $report.P95Milliseconds -le 1 -and $report.P99Milliseconds -le 5 -and $report.ActualEventsPerSecond -ge ($Rate * 0.95)
    foreach ($status in $result.Destinations) {
        $baseline = $before | Where-Object Name -EQ $status.Name
        if ($Scenario -eq 'QueueFull') {
            $targetsMet = $targetsMet -and ($status.Dropped - $baseline.Dropped -eq $count)
        } else {
            $targetsMet = $targetsMet -and $result.Success -and ($status.Accepted - $baseline.Accepted -eq $count) -and ($status.Delivered - $baseline.Delivered -eq $count)
        }
    }
    $report['TargetsMet'] = $targetsMet
    $reportPath = Join-Path $OutputDirectory "$Scenario-$Rate-$Seconds.json"
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
    [pscustomobject]$report | Select-Object Scenario, Events, ActualEventsPerSecond, P95Milliseconds, P99Milliseconds, FlushMilliseconds, Success, TargetsMet
    if (-not $targetsMet) {
        throw "Benchmark target missed; inspect $reportPath."
    }
} finally {
    try { $null = Close-LTLog -TimeoutSeconds 1 -WarningAction SilentlyContinue } catch { }
    if ($client) { $client.Dispose() }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
