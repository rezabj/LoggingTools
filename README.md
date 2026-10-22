# LoggingTools

PowerShell 7 structured logging to **files**, **Azure Log Analytics**, and **Teams Workflows**. Each destination has an independent background worker and bounded memory queue. Windows and Linux are required test platforms; macOS is initially untested. Windows PowerShell 5.1 and email are outside version 1.

```powershell
Import-Module ./LoggingTools/LoggingTools.psd1
Initialize-LTLogConfig -ApplicationName 'Inventory' -File @{
    Path = './logs/inventory.jsonl'
    CreateDirectory = $true
}
try {
    Write-LTLog -Message 'Started'
    Write-LTLog -Message 'Completed' -Data @{ Count = 42 }
} finally {
    $delivery = Close-LTLog -TimeoutSeconds 30
}
```

Use a separate file path for each concurrent script/runspace. Default capacity per destination is 10,000 pending events or 32 MiB of encoded payload. Overflow rejects new events for the full destination and reports drops; it never waits for queue capacity. Always flush/close before normal exit. In-memory queues do not guarantee delivery after crashes, overflow, or exhausted retries.

## Documentation

- [Installation and usage](https://rezabj.github.io/LoggingTools/usage/)
- [Azure workspace, DCR, and authentication setup](https://rezabj.github.io/LoggingTools/azure/)
- [Command reference](https://rezabj.github.io/LoggingTools/reference/)
- [Delivery guarantees and performance](https://rezabj.github.io/LoggingTools/reliability/)
- [Development and testing](https://rezabj.github.io/LoggingTools/development/)

Editable documentation source lives in the repository's **gh-pages branch**. It is published to the existing GitHub Pages site. Module changes do not force-push generated site output over that source.

## Commands

`Initialize-LTLogConfig`, `Write-LTLog`, `Set-LTLogDefaultLevel`, `Get-LTLogStatus`, `Sync-LTLog`, and `Close-LTLog`.

Azure supports ManagedIdentity (VM and App Service/Functions), ClientSecret, Certificate, and AzureCli authentication. Only AzureCli requires Azure CLI. Secrets and webhook URLs belong in a secret store. Teams uses a Workflows webhook configured to accept requests without a Teams bearer token.

## Development checks

The module requires PowerShell 7.0+. Pester 6 requires a newer test host: run the suite on PowerShell 7.4+ with **Pester 6.2.0 or newer**. Pester is not a module runtime dependency.

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force -SkipPublisherCheck
./tests/Invoke-Tests.ps1
./tests/Smoke.ps1
./benchmarks/Measure-Logging.ps1 -Scenario File -Rate 1000 -Seconds 60
```

CI runs Pester and PSScriptAnalyzer on Windows/Linux, separate PowerShell 7.0.13 smoke checks, and reference benchmarks. Cloud transports are mocked in routine tests; verify real Azure credentials, ingestion, and Teams workflow posting using the acceptance guide. Benchmark reports are written to `artifacts/benchmarks`; mocked Azure results are not measurements of the Azure service.
