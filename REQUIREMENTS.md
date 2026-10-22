# PowerShell logging module — version 1 requirements

Status: version 1 development specification
Date: 2026-10-22

Source repository: [rezabj/LoggingTools](https://github.com/rezabj/LoggingTools.git). Its current default branch is `Dev`. The repository already contains a `LoggingTools` module scaffold, public `Write-LTLog` and configuration commands, documentation, and a PSScriptAnalyzer workflow. Version 1 requirements should be implemented in that module rather than starting an unrelated module.

Documentation site: [LoggingTools on GitHub Pages](https://rezabj.github.io/LoggingTools/). The documentation website source must be maintained in the repository's `gh-pages` branch and published to this existing site.

## 1. Purpose and scope

Provide a reusable PowerShell 7 module that lets scripts create structured log events and deliver them to one or more configured destinations: a local file, Azure Log Analytics, and a Microsoft Teams webhook. A script should use one logging call regardless of destination. The module must work in unattended jobs as well as interactive scripts.

Windows and Linux are required, tested platforms. The module should also work on macOS using portable APIs, but macOS is initially untested and must be documented as such. The minimum required engine version is PowerShell 7.0.

Version 1 covers event creation, level filtering, routing, delivery, and clear reporting of delivery failures. Email delivery, a log viewer, Azure resource provisioning, alert rules, and management of Teams accounts are outside version 1. Windows PowerShell 5.1 compatibility is not required.

## 2. Proposed public behavior

| ID | Requirement | Acceptance criterion |
| --- | --- | --- |
| FR-01 | A script can initialize a logger with one or more named destinations and independently configure each destination. | One event can be sent to any selected combination of the three destinations without changing the script's logging call. |
| FR-02 | Extend the existing `Write-LTLog` command with `-Message`, `-Level`, and optional structured `-Data` and `-ErrorRecord`. | A caller can log ordinary messages and caught errors; no destination-specific parameters are needed on each call. |
| FR-03 | Supported levels are `DEBUG`, `INFO`, `WARNING`, `ERROR`, and `CRITICAL`, matching the existing `Write-LTLog` values, with per-destination minimum levels. | Events below a destination's threshold are not delivered there. Recommended defaults: file and Log Analytics `INFO`; Teams `ERROR`. |
| FR-04 | Every event has a common schema: UTC timestamp in ISO 8601 format, level, message, application/script name, host, process ID, correlation ID (when supplied), event ID (unique per event), and optional structured data and exception details. | A test event retains the same core values across all configured destinations. Missing optional fields do not prevent logging. |
| FR-05 | File logging appends one UTF-8 JSON object per line to a configured path. It creates the parent directory only when explicitly configured to do so. | Consecutive writes produce parseable JSON Lines without overwriting earlier entries; invalid paths cause a clear error. |
| FR-06 | File logging supports a maximum file size and numbered rotation with a configurable retention count. | Once the limit is reached, subsequent writes move to a new file and remove only files belonging to this logger beyond retention. |
| FR-07 | Azure Log Analytics delivery uses the Azure Monitor Logs Ingestion API with a configured ingestion endpoint, DCR immutable ID, and stream name. The destination table and DCR are prerequisites. | A valid event reaches the configured stream; missing configuration or authorization yields a destination-specific failure. |
| FR-08 | Azure authentication supports managed identity, an app registration using a client secret or certificate, and an existing Azure CLI session. The caller can explicitly select the authentication method and identity/tenant where applicable. Cache tokens and renew them before expiry in the background; logging calls must not acquire tokens or invoke Azure CLI. | Each authentication method can obtain a token for Azure Monitor ingestion and renew it during a long-running script. An unavailable or expired CLI session produces an actionable failure without launching interactive sign-in. Credentials are absent from events and diagnostics. |
| FR-09 | The Azure destination serializes to the DCR's declared input schema and batches within the API request-size limit. | Larger event sequences are split into valid requests; a single oversized event is rejected with an actionable error instead of silently truncated. |
| FR-10 | Teams delivery posts each qualifying event as an Adaptive Card to a configured Teams Workflows webhook URL. It supports a severity threshold and defaults to at most one new event delivery per second before retries. | An `ERROR` event appears in the chosen chat or channel, and the webhook payload stays within the documented size limit. |
| FR-11 | Network destinations use bounded timeouts and retry transient failures (`429` and server errors), honoring `Retry-After` where present. Authentication, validation, and other permanent errors are not retried. | Tests simulate transient and permanent failures and verify retry count, delay policy, and final status. |
| FR-12 | A failure in one destination does not block delivery to other destinations. Background delivery failures are exposed through status and flush/close results. The caller can select strict behavior that raises an error when it checks delivery results or closes the logger. | When Teams fails and file logging succeeds, the file event remains present and the Teams failure is observable. A background worker never attempts to terminate the caller's script directly. |
| FR-13 | The module exposes explicit flush and close operations with configurable timeouts. These operations may wait for pending file and remote writes, and close releases workers and file handles. | On normal script completion, a caller can wait for queued events to be delivered and receive counts of pending, failed, and dropped events. A timeout is reported rather than waiting indefinitely. Documentation shows cleanup in a `finally` block and explains that forced process termination can lose buffered events. |
| FR-14 | Configuration can be supplied programmatically and validated before the first event is sent. | Invalid level, endpoint, path, or missing required setting produces an actionable validation error. |
| FR-15 | Every exported public command uses the name pattern `<Verb>-LT<Noun>`, with an approved PowerShell verb. This includes configuration, logging, and flush/close commands. | The module manifest exports no public command outside the pattern; examples include `Write-LTLog` and `Set-LTLogDefaultLevel`. |
| FR-16 | File and Log Analytics delivery are asynchronous. `Write-LTLog` captures the event and enqueues it without waiting for destination I/O, authentication, retry delays, rotation, or batch delivery. Destinations have independent background processing so a slow destination does not hold up another. | Tests deliberately stall file writes and Azure requests and confirm that logging calls continue to enqueue while capacity remains, return promptly under the overflow policy when capacity is exhausted, and allow other destinations to continue processing. |
| FR-17 | Background file delivery uses buffered, batched appends; Azure delivery batches by event count, encoded payload size, and maximum delivery interval. Batch and interval settings are configurable. | Bursts are processed without opening a file or sending an HTTP request for every event. Partially filled batches are delivered within the configured interval under normal operation, and flush handles the remaining events. |
| FR-18 | Expose destination status including queue depth, accepted, delivered, failed, and dropped event counts, and the last delivery error, without exposing secrets. Enqueuing an event does not mean it has been delivered. | A caller can detect an unhealthy worker, backlog, failed delivery, and overflow without inspecting module internals. |

## 3. Security and privacy requirements

| ID | Requirement |
| --- | --- |
| SR-01 | Treat Azure credentials, access tokens, and the Teams webhook URL as secrets. Never include them in events, exception output, verbose output, or failure reports. |
| SR-02 | Use HTTPS with TLS 1.2 or newer for network delivery. Do not disable certificate validation. |
| SR-03 | Provide a configurable redaction step for known sensitive field names and values before an event reaches any destination. Document that callers remain responsible for avoiding sensitive data in messages. |
| SR-04 | Keep destination configuration and authentication separate from event data. Do not require plaintext secrets in a checked-in configuration file. |
| SR-05 | Document the permissions required for the Azure DCR; use the narrowest practical access. |

## 4. Operational and quality requirements

| ID | Requirement |
| --- | --- |
| NFR-01 | Logging must have bounded memory use. Queues and batches have configurable limits. By default, each destination queue holds at most 10,000 events or 32 MiB of encoded event payload, whichever limit is reached first. Account for object and worker overhead separately when measuring total memory. When a queue is full, reject the new event for that destination without waiting and preserve already queued events. Count drops by destination and level, expose them through status and flush/close, and issue a diagnostic at most once every 30 seconds per affected destination. Strict flush/close must treat dropped events as a failure. |
| NFR-02 | File logging should remain usable when network destinations are unavailable. A network outage must not hang a script indefinitely. |
| NFR-03 | Preserve event ordering within a file and within each destination's queue. Cross-destination arrival order is not guaranteed. |
| NFR-04 | Document delivery guarantees accurately: remote retries may create duplicates, and in-memory queues can lose pending events on forced termination. Include the event ID to support deduplication. Do not claim guaranteed delivery solely because an event was enqueued. |
| NFR-05 | Update the existing module manifest, comment-based help, repository documentation, examples for each destination and combined use, and an unattended-job example. |
| NFR-06 | Prepare automated Pester tests using Pester 6.2.0 or newer for schema, filtering, routing, redaction, rotation, batching, retry, failure isolation, queue overflow, asynchronous delivery, authentication, and flush. External services should be mocked in routine tests, with optional integration tests against test resources. Pester is a development/test dependency, not a module runtime dependency. |
| NFR-07 | Require PowerShell 7.0 or newer and the Core edition in the module manifest. Windows and Linux are required platforms. Use portable APIs to accommodate macOS, with its initially untested status clearly documented. Windows PowerShell 5.1 compatibility is not required. |
| NFR-08 | Run PSScriptAnalyzer and automated Pester tests on Windows and Linux using a current PowerShell release. Test setup must require Pester 6.2.0 or newer and fail clearly if an older version is loaded. Verify Pester 6.2.0 as the minimum test framework version on PowerShell 7.4+, which Pester 6 requires. Verify the module's PowerShell 7.0 baseline using separate smoke checks on Windows and Linux. |
| NFR-09 | Repository documentation must give step-by-step instructions to create or select an Azure Log Analytics workspace, create the destination table and DCR with a matching stream schema, choose the DCR ingestion endpoint or a DCE when required, grant the sending identity access to the DCR, configure the module, send a test event, and verify the event with a Log Analytics query. A user with the documented Azure permissions must be able to complete the setup and ingest a test event without consulting the module source code. |
| NFR-10 | The repository must contain a user guide for the module: installation and import, minimum supported PowerShell version, public command reference, configuration for each destination, log levels and filtering, structured data and error logging, combined destinations, flush/close behavior, delivery failures, and runnable examples. A user must be able to add the module to a new script using only this guide. |
| NFR-11 | Benchmark file-only, Azure-only, and combined logging on Windows and Linux against the initial targets below. Record producer throughput, median and 95th/99th percentile logging-call latency, memory use, backlog, delivery throughput, and event counts under normal load, bursts, slow disks, throttling, and network outages. Measure enqueue time separately from final flush time and document the machine, PowerShell version, destination configuration, and batch settings used. |
| NFR-12 | Publish the module user guide, public command reference, and Azure setup guide to the existing GitHub Pages site at `https://rezabj.github.io/LoggingTools/`. Maintain the website source in the repository's `gh-pages` branch. The module README and command help must link to the corresponding published documentation. |

### 4.1 Initial performance targets and queue defaults

These are proposed engineering targets to validate during implementation, not measured performance claims. They can be revised using benchmark evidence and real script workloads.

| Area | Initial target or default |
| --- | --- |
| Sustained workload | 1,000 events per second for 60 seconds, with approximately 1 KiB per encoded event. |
| Burst workload | 5,000 events per second for 2 seconds, with approximately 1 KiB per encoded event. |
| Logging-call latency | After initialization and warm-up, 95th percentile at most 1 ms and 99th percentile at most 5 ms for the reference workloads, including the queue-full case. |
| Healthy destinations | No dropped events at the reference workloads; queues drain after a burst and successful flush accounts for every accepted event. Azure acceptance means successful API submission, not immediate query visibility. |
| Queue capacity | Configurable; default 10,000 events or 32 MiB of encoded payload per destination, whichever is reached first. |
| Queue overflow | Reject the newest event for the full destination; continue other destinations and report drops by destination and severity. No per-event warning output. |
| Delivery outage | Keep retry and queue memory bounded, continue normal script execution, and report delivery failures and drops. An outage is not subject to the healthy-destination no-drop target. |
| Durability | Version 1 uses memory queues without a durable disk spool. Logs may be lost through overflow or forced termination; normal exit must explicitly flush/close. |

The reference throughput benchmarks cover file and Log Analytics delivery, separately and together. They do not target 1,000 Teams notifications per second. Larger records must also be tested to verify payload limits and bounded memory behavior.

## 5. External prerequisites and constraints

- **Azure Log Analytics:** A Log Analytics workspace, destination table, DCR, stream, ingestion endpoint, and Microsoft Entra identity with access to the DCR must exist before logging to Azure. The repository documentation will describe how to configure these resources. A DCR ingestion endpoint can be used in ordinary cases; a data collection endpoint is needed for Private Link. The Logs Ingestion API has a 1 MB request limit, and throttling responses should be retried using `Retry-After`.
- **Azure authentication:** Document managed identity, app registration (secret and certificate), and existing Azure CLI session configuration. Azure CLI must be installed and authenticated only when that method is selected; other methods must not require it. Obtain an Azure Monitor token rather than relying on the CLI's default Azure Resource Manager token audience.
- **Teams:** Provision a Teams Workflows webhook for the target chat or channel and assign a co-owner so the workflow does not depend on one person. The webhook URL must be stored as a secret. The documented incoming webhook message limit is 28 KB; Teams can throttle high request rates.

## 6. Chosen defaults

1. **Teams notifications:** Send each qualifying event individually, with a configurable one-second minimum send interval by default.
2. **Failure policy:** Sync/close return a result and warn by default; optional strict mode raises an error after reporting asynchronous failures, drops, or timeout.
3. **File retention:** Rotate at 10 MiB and retain five archives in addition to the active file. Allow rotation to be disabled explicitly.

## 7. Version 1 completion criteria

Version 1 is ready when all three destinations pass their acceptance tests on Windows and Linux, all three Azure authentication methods are verified in appropriate test environments, combined routing and partial-failure behavior are verified, agreed performance targets are met, secrets are absent from events and diagnostics, and the documentation describes Azure setup, usage, delivery guarantees, and macOS's untested status. The documentation website source must be in `gh-pages`, and the version 1 guides must be available on the existing GitHub Pages site. User-guide examples must run with only documented prerequisites.

## References

- [Azure Monitor Logs Ingestion API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview)
- [Azure Monitor service limits](https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits)
- [Teams webhooks and Workflows](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook)
- [Azure CLI token acquisition](https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token)
