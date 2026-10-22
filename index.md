---
title: PowerShell logging that keeps your script moving
permalink: /
---
# PowerShell logging that keeps your script moving

LoggingTools creates structured events and delivers them to a file, Azure Log Analytics, and a Teams Workflows webhook. File and network writes run in independent background workers. Your script enqueues an event and continues.

Version 1 requires **PowerShell 7.0 or newer**. Windows and Linux are the tested platform targets. macOS uses the same portable APIs but is initially untested. Email and Windows PowerShell 5.1 are outside version 1.

```powershell
Import-Module ./LoggingTools/LoggingTools.psd1
Initialize-LTLogConfig -ApplicationName 'Inventory' -File @{
    Path = './logs/inventory.jsonl'
    CreateDirectory = $true
}
try {
    Write-LTLog -Message 'Inventory started'
    Write-LTLog -Message 'Inventory finished' -Data @{ Count = 42 }
} finally {
    $delivery = Close-LTLog -TimeoutSeconds 30
}
```

**Always close the logger in `finally`.** Enqueuing is not a delivery guarantee: queued data can be lost when a process is killed, a queue fills, or delivery fails. Inspect the close result or use strict mode when those conditions should fail a job.

- [Install and use the module]({{ '/usage/' | relative_url }}).
- [Configure the Azure workspace, table, DCR, and identity]({{ '/azure/' | relative_url }}).
- [Look up public commands and configuration settings]({{ '/reference/' | relative_url }}).
- [Understand buffering, failure handling, and performance]({{ '/reliability/' | relative_url }}).
- [Run Pester tests and benchmarks]({{ '/development/' | relative_url }}).

The module source lives on the repository's development branch. This documentation site's editable source is maintained in **`gh-pages`**. The GPL v3 license is available in the [source repository](https://github.com/rezabj/LoggingTools).
