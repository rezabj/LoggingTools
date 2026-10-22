---
title: Testing and development
permalink: /development/
---
# Testing and development

The module targets PowerShell 7.0+. The **Pester test runner requires PowerShell 7.4+ and Pester 6.2.0 or newer**, as required by Pester 6. Pester is not a runtime dependency of LoggingTools.

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force -SkipPublisherCheck
./tests/Invoke-Tests.ps1
./tests/Smoke.ps1
```

The Pester suite covers the public interface, JSON event schema, filtering, redaction, file rotation, queue limits, asynchronous delivery, retry and timeout behavior, Azure authentication, and Teams cards. Its HTTP transport is mocked through a .NET handler, so normal tests do not send logs or require cloud credentials. A local executable stub tests Azure CLI invocation without calling your real session.

CI runs Pester 6.2.0 and PSScriptAnalyzer on Windows and Linux. Separate smoke jobs run the module on PowerShell 7.0.13 because Pester 6 cannot run on that older runtime. macOS is initially untested. Passing mocked authentication tests does not replace live validation of your tenant, role assignments, managed-identity host, or Teams workflow.

## Benchmarks

```powershell
./benchmarks/Measure-Logging.ps1 -Scenario File -Rate 1000 -Seconds 60
./benchmarks/Measure-Logging.ps1 -Scenario MockAzure -Rate 1000 -Seconds 60
./benchmarks/Measure-Logging.ps1 -Scenario Combined -Rate 1000 -Seconds 60
./benchmarks/Measure-Logging.ps1 -Scenario Combined -Rate 5000 -Seconds 2
./benchmarks/Measure-Logging.ps1 -Scenario QueueFull -Rate 1000 -Seconds 2
```

Reports under `artifacts/benchmarks` record platform/runtime, event size, producer throughput, latency percentiles, working set, backlog, final counters, and flush duration. MockAzure and Combined use mocked HTTP; file operations are real. Initialization and warm-up are excluded from measured enqueue latency. QueueFull deliberately stalls remote delivery to verify responsive overflow behavior.

## Live acceptance

On each required deployment platform, follow the Azure guide and verify test events using the query shown there. Exercise the configured managed identity, app registration, and CLI session separately. Send a Teams ERROR notification and confirm the workflow run and channel post. Use disposable test resources and never commit credentials. These live checks require the user's actual cloud configuration; routine CI does not presume access to a tenant.

## Documentation publishing

Editable website source lives in `gh-pages`. Make documentation changes on a branch based on `gh-pages`, then open a pull request targeting that branch. Markdown files have Jekyll front matter and share `_layouts/default.html` and `styles.css`.

The documentation workflow builds a Jekyll preview artifact for review. The existing GitHub Pages branch publisher publishes the site when changes reach `gh-pages`. In repository **Settings → Pages**, use **Deploy from a branch**, branch **gh-pages**, folder **/(root)**. Source-branch workflows must not force-push generated MkDocs output over the documentation source.
