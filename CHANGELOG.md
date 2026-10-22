# Changelog

## 1.0.0 — pending release

- Structured UTC events with IDs, correlation, data, caught errors, and configurable redaction.
- Independent asynchronous file, Azure Log Analytics, and Teams Workflows workers.
- Buffered UTF-8 JSON Lines, numbered rotation, Azure byte/count/interval batching, and bounded retries.
- Managed identity, app secret/certificate, and existing Azure CLI session authentication.
- Bounded queues with reported drops, delivery status, and explicit sync/close deadlines.
- PowerShell 7.0+ module; Pester 6.2.0+ tests, platform CI, and performance benchmarks.
- Usage, Azure setup, and command documentation maintained in gh-pages.

The pre-version-1 scaffold is replaced. Initialize-LTLogConfig now requires ApplicationName and at least one destination; there is no implicit console target. Existing Write-LTLog and Set-LTLogDefaultLevel command names are retained.
