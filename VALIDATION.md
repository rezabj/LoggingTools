# Version 1 validation

Local validation on 2026-10-22 used Windows, PowerShell 7.6.7, Pester 6.2.0, and a two-processor execution environment.

- Pester: 27 passed, 0 failed. HTTP transport is mocked; Azure CLI uses a local process stub.
- PSScriptAnalyzer 1.25.0: no module errors or warnings using the repository settings.
- Minimum-runtime smoke: passed on PowerShell **7.0.13 Core on Windows**.
- Documentation: 7 Markdown pages, 18 PowerShell snippets, local routes, and Azure template JSON validated. Full Jekyll build is delegated to the documentation branch CI.

## Local performance observations

These measurements include approximately 1 KiB events and exclude initialization/warm-up. Azure transport is mocked, so they do not measure real Azure service throughput or end-to-end ingestion latency.

| Scenario | Events | Producer rate, events/s | p95 call, ms | p99 call, ms | Delivery |
| --- | ---: | ---: | ---: | ---: | --- |
| File, 60 seconds | 60000 | 1000.01 | 0.660 | 3.433 | No failures or drops |
| Mock Azure, 60 seconds | 60000 | 1000.01 | 0.542 | 3.028 | No failures or drops |
| Combined, 60 seconds | 60000 | 1000.01 | 0.590 | 2.377 | No failures or drops |
| Combined burst, structured-path warm-up | 10000 | 4989.32 | 0.431 | 0.994 | No failures or drops |
| Full queue, deliberate outage | 2000 | 1000.41 | 0.701 | 1.459 | New events rejected and reported as designed |

Results vary with workload and hardware. CI reruns the reference workloads on Windows and Linux, checks all event counts, and requires at least 95% of the requested producer rate together with the latency targets. JSON reports are uploaded as CI artifacts.

## External checks

Linux Pester, benchmarks, and PowerShell 7.0 smoke checks require CI because no local Linux runtime is installed. macOS remains untested. Real Azure managed identity/app registration/CLI credentials, Azure ingestion/query visibility, ARM resource deployment, and Teams workflow posting must be verified against the user's test resources using the published acceptance guide. Routine tests never assume access to a tenant or webhook.
