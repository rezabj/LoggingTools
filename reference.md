---
title: Command and configuration reference
permalink: /reference/
---
# Command and configuration reference

## Initialize-LTLogConfig

Starts one logger in the current module/runspace. Close the previous logger before starting another. Requires `-ApplicationName` and at least one of `-File`, `-LogAnalytics`, or `-Teams`, each supplied as a hashtable. Initialization validates configuration and opens the file but does not contact Azure or Teams. Check delivery using `Sync-LTLog` or `Close-LTLog`.

| Parameter | Default | Meaning |
| --- | --- | --- |
| ApplicationName | Required | Script/application name in events |
| DefaultLevel | INFO | Level for calls omitting Level |
| QueueCapacity | 10000 | Pending event limit per destination |
| QueueCapacityBytes | 32MB | Encoded pending payload byte limit per destination |
| RedactField | Built-in sensitive names | Additional structured field names |
| RedactValue | None | Additional literal sensitive strings |
| Strict | False | Default flush/close failure behavior |

### Common destination keys

`MinimumLevel`, `Capacity`, `CapacityBytes`, and `IntervalMilliseconds` apply to every destination. `Capacity` and `CapacityBytes` override the logger defaults. Interval defaults to 1000 ms. `BatchCount` defaults to 500 and `BatchBytes` to 512 KiB for file/Azure; both are configurable. `BatchBytes` is limited to 1,000,000 bytes to stay below Azure's request limit. A byte limit includes JSON array overhead for Azure. Teams uses one event per request and does not accept the batch keys.

### File keys

| Key | Default | Meaning |
| --- | --- | --- |
| Path | Required | Local absolute or PowerShell-relative file path |
| CreateDirectory | False | Explicit Boolean permitting parent directory creation |
| MaximumFileBytes | 10MB | Rotate before exceeding this size; 0 disables rotation |
| RetainedFiles | 5 | Numbered archives retained, between 1 and 1000 |

### LogAnalytics keys

| Key | Required | Meaning |
| --- | --- | --- |
| Endpoint | Yes | HTTPS DCR/DCE ingestion base URL ending in `.ingest.monitor.azure.com` |
| RuleId | Yes | Immutable ID in `dcr-<32 hex characters>` format, not an ARM resource ID |
| Stream | Yes | Declared `Custom-` stream, for example `Custom-LoggingTools` |
| Authentication | Yes | ManagedIdentity, ClientSecret, Certificate, or AzureCli |
| ClientId | App registration; optional for managed identity | Application or user-assigned identity client GUID |
| TenantId | App registration; optional for CLI | Tenant GUID |
| ClientSecret | ClientSecret mode | Nonempty SecureString |
| Certificate | Certificate mode | RSA X509Certificate2 with private key; keep it alive until close |

Version 1 targets Azure public cloud. Private Link is supported through a configured DCE and external private networking/DNS; the module does not provision that networking. Managed identity supports Azure VM IMDS and App Service/Functions identity endpoints. Other managed-identity host protocols are not automatically supported.

Azure events with a top-level field over 64 KiB are rejected explicitly to avoid service truncation. String fields are measured as UTF-8 values; dynamic fields are conservatively measured as encoded JSON. A failed batch is reported through status and flush/close.

### Teams keys

| Key | Default | Meaning |
| --- | --- | --- |
| WebhookUrl | Required | HTTPS Workflows URL stored as a secret |
| MinimumLevel | ERROR | Per-event notification threshold |
| MinimumSendIntervalMilliseconds | 1000 | Minimum interval before starting another event's delivery; range 250–60000 |

### Network keys

`TimeoutSeconds` defaults to 30 per HTTP request or CLI invocation, and `MaximumRetries` to 3 after the initial attempt. The timeout range is 1–300 seconds and retry range 0–10. HTTP 429 and server errors, connection failures, and request timeouts receive bounded retries. Backoff starts at 500 ms and doubles up to 30 seconds; a valid `Retry-After` takes precedence. The close deadline can cancel a longer retry delay. Permanent HTTP validation/authentication errors are not retried for the current batch.

## Write-LTLog

`Write-LTLog -Message <string> [-Level <level>] [-Data <object>] [-ErrorRecord <ErrorRecord>] [-CorrelationId <string>]`

Message is required and can be supplied through the pipeline. A filtered event is not serialized or queued. A normal accepted event produces no pipeline output. Overflow is counted separately for each destination and emits a warning at most once per destination every 30 seconds. `-WarningAction SilentlyContinue` suppresses warning output without hiding counters.

## Set-LTLogDefaultLevel

`Set-LTLogDefaultLevel -Level <DEBUG|INFO|WARNING|ERROR|CRITICAL>` sets the level for future calls that omit `-Level`. It does not change destination thresholds or queued events.

## Get-LTLogStatus

Returns one status object per destination. `Accepted`, `Delivered`, `Failed`, and `Dropped` are cumulative for the logger lifetime; `Pending` includes queued and in-flight events. `QueueDepth` excludes the active batch. `PendingBytes` includes active batch payloads. `DroppedByLevel` maps severity names to drop counts. `LastError` is a sanitized summary; it remains set after a later successful delivery so an earlier failure remains visible. States are Running, Stopping, Closed, or Faulted.

## Sync-LTLog

`Sync-LTLog [-TimeoutSeconds <number>] [-Strict]`

Requests delivery of all events accepted before the call and waits up to 30 seconds by default. Returns `Success`, `TimedOut`, and `Destinations`. A successful Azure result confirms API acceptance, not ingestion/query visibility. Retrying delivery can create duplicate events; `EventId` remains unchanged for a retried batch.

## Close-LTLog

`Close-LTLog [-TimeoutSeconds <number>] [-Strict]`

Stops new writes, flushes, then cancels workers and waits for cleanup within the same deadline. On timeout, inspect status: cancellation cleanup may still be finishing. A blocked operating-system file operation cannot always be interrupted immediately. Reinitializing the same path before the old writer releases it can fail. After a successful close, reinitialization is allowed and counters restart. Repeated close calls are safe; failed/dropped counts remain visible.
