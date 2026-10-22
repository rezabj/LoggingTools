---
title: Delivery guarantees and performance
permalink: /reliability/
---
# Delivery guarantees and performance

`Write-LTLog` constructs a snapshot, redacts it, and enqueues it. It performs no destination file writes, network calls, token acquisition, or retry sleeps. Capturing data still takes CPU time; serialize small structured objects rather than whole application objects.

Each destination has an independent worker and queue. File delivery uses a persistent buffered writer and batched flushing. Azure delivery combines events into JSON arrays bounded by count, encoded bytes, and maximum interval. Explicit sync/close bypasses the interval for partial batches. A stalled Azure request does not hold up file delivery.

## Capacity and event loss

The default per-destination limit is **10,000 pending events or 32 MiB of encoded event payload**, whichever is reached first. An active batch counts against these limits. Actual process memory also includes object/string overhead, PowerShell, workers, HTTP buffers, and the caller's objects; 32 MiB is not a total process-memory limit.

When full, the destination rejects the newest event, preserving previously accepted events and their ordering. Other destinations can still accept it. Drops are counted by destination and severity, with a warning at most once every 30 seconds. Strict sync/close fails if any event was dropped or failed earlier in that logger's lifetime.

Version 1 has no durable spool. Process termination, overflow, or exhausted retries can lose events. A file batch interrupted by a disk error can be partially written; the batch is conservatively reported failed. Remote retries can create duplicates. Use `EventId` for deduplication; do not use this module as a guaranteed audit trail.

## Monitoring and shutdown

```powershell
Get-LTLogStatus | Format-Table Name, State, Accepted, Delivered, Failed, Dropped, Pending
$checkpoint = Sync-LTLog -TimeoutSeconds 30
$finished = Close-LTLog -TimeoutSeconds 60
```

Choose a close timeout that accommodates your volume and rate limits. A large Teams notification backlog can take much longer to drain than file or Azure batches. Network acceptance confirms the receiving API accepted the request; Azure ingestion transformations and Teams workflow steps can still fail downstream.

## Reference targets

Initial targets are 1,000 approximately 1 KiB events per second for 60 seconds, with 5,000 events/second bursts for two seconds. After warm-up, target logging-call latency is at most 1 ms at the 95th percentile and 5 ms at the 99th percentile. Healthy destinations should deliver every accepted event without drops. These targets cover file/Azure separately and together, not high-volume Teams notifications.

These are test targets, not universal latency guarantees. Disk speed, CPU, PowerShell version, payload complexity, Azure throttling, and queue settings affect results. Run the included benchmark on your deployment host. CI uploads its reports as artifacts. Mocked Azure reports measure module enqueue/batching behavior without measuring actual Azure network throughput or end-to-end ingestion latency.
