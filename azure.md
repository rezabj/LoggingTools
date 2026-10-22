---
title: Azure Log Analytics setup
permalink: /azure/
---
# Azure Log Analytics setup

This guide sets up a workspace, custom table, DCR, and sending identity for Azure public cloud. The module uses the Logs Ingestion API with Entra bearer tokens, not a workspace shared key. Resource setup happens outside the module.

## 1. Prepare the subscription and permissions

Choose an Azure subscription and region. For setup, obtain permission to create resources in the chosen resource group (for example Contributor), plus permission to assign roles at the DCR scope (for example Owner or User Access Administrator). Creating an app registration may require separate Entra permissions. The sending script only needs ingestion access to its DCR; it does not need these provisioning permissions.

Install Azure CLI on the setup workstation and sign in. These CLI commands are PowerShell examples usable on Windows or Linux:

```powershell
az login
az account set --subscription '<subscription-guid>'
$group = 'rg-loggingtools-test'
$location = 'westeurope'
$workspace = '<your-unique-workspace-name>'
az group create --name $group --location $location
```

## 2. Create the workspace, table, and DCR

Download [azure-resources.json]({{ '/azure-resources.json' | relative_url }}) to your working directory, then deploy it. This creates a billable Log Analytics workspace with 30-day retention, a `LoggingTools_CL` table, and a direct-ingestion DCR in the same region.

```powershell
az deployment group create --resource-group $group --name loggingtools `
    --template-file ./azure-resources.json `
    --parameters "workspaceName=$workspace" "location=$location"
if ($LASTEXITCODE) { throw 'Azure resource deployment failed.' }

$outputs = az deployment group show --resource-group $group --name loggingtools `
    --query properties.outputs --output json | ConvertFrom-Json
$ingestionEndpoint = $outputs.ingestionEndpoint.value
$dcrImmutableId = $outputs.ruleImmutableId.value
$dcrResourceId = $outputs.ruleResourceId.value
```

To use an **existing workspace**, set `$group`, `$workspace`, and `$location` to that workspace's actual values and add `createWorkspace=false` to `--parameters`. Review any existing `LoggingTools_CL` table before deploying over it. The template creates/updates the table and DCR and does not modify the existing workspace when this parameter is false.

The DCR declares input stream **`Custom-LoggingTools`**, applies the identity transform `source`, and writes to table **`LoggingTools_CL`** through output stream `Custom-LoggingTools_CL`. Input and table columns are:

| Column | Type |
| --- | --- |
| TimeGenerated | datetime |
| EventId, Level, Message, Application, HostName, CorrelationId | string |
| ProcessId | int |
| Data, Exception | dynamic |

Keep these names and types aligned with the module event schema. `RuleId` is the DCR's **immutable ID**, not its ARM resource ID. `Endpoint` is the base logs-ingestion URL; omit the dataCollectionRules path and query string.

For **Private Link**, create a DCE in the workspace/DCR region, associate it with the DCR, and configure Azure Monitor Private Link Scope and DNS for the sending host. Use the DCE's logs-ingestion endpoint as the module Endpoint. Follow the [DCE and Private Link setup guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-endpoint-overview); the supplied template creates the simpler public-ingestion setup.

## 3. Choose the sending identity and grant access

Use one of the following and obtain its **principal/object ID**:

- **Managed identity:** Enable a system-assigned identity on the Azure VM or App Service/Functions host, or attach a user-assigned identity. Copy its principal/object ID from Azure. Version 1 supports VM IMDS and App Service/Functions identity endpoint protocols.
- **App registration:** In Entra ID → App registrations, register an application and record tenant ID and application/client ID. Under Certificates & secrets, create a secret or upload a public RSA certificate. Obtain the enterprise application's **service principal object ID**; the application registration's object ID and client ID are different identifiers.
- **Azure CLI user session:** Run `az login --tenant '<tenant-guid>'` on the script host. Obtain the signed-in user's object ID with `az ad signed-in-user show --query id --output tsv`. CLI logged in as a service principal uses that principal's object ID instead.

Assign **Monitoring Metrics Publisher** on this DCR to the selected sender:

```powershell
$senderObjectId = '<sender-principal-object-guid>'
$principalType = 'ServicePrincipal' # Use 'User' for a CLI signed-in user.
az role assignment create --assignee-object-id $senderObjectId `
    --assignee-principal-type $principalType --role 'Monitoring Metrics Publisher' `
    --scope $dcrResourceId
```

Allow time for role assignments to propagate before testing. Repeat this role assignment for every distinct identity that will send events. The role belongs to the sender at DCR scope; a DCR resource identity does not authenticate your script.

## 4. Configure authentication in PowerShell

Start with the shared destination settings:

```powershell
$azure = @{
    Endpoint = $ingestionEndpoint
    RuleId = $dcrImmutableId
    Stream = 'Custom-LoggingTools'
}
```

### Managed identity

```powershell
$azure.Authentication = 'ManagedIdentity'
# For a user-assigned identity, add its application/client ID:
# $azure.ClientId = '<managed-identity-client-guid>'
```

Run on the Azure host with that identity attached. No Azure CLI installation is required. VM metadata calls bypass HTTP proxies; App Service calls use the host-provided IDENTITY_ENDPOINT and IDENTITY_HEADER.

### App registration with a secret

```powershell
$azure.Authentication = 'ClientSecret'
$azure.TenantId = '<tenant-guid>'
$azure.ClientId = '<application-client-guid>'
$azure.ClientSecret = Read-Host 'Application secret value' -AsSecureString
```

In an unattended job, retrieve the SecureString from your secret store rather than prompting. Use the secret **value**, not its ID, and arrange rotation outside the logger.

### App registration with a certificate

Load an RSA certificate with its private key from a protected PFX file, and ensure its public certificate is registered on the app:

```powershell
$pfxPath = '<absolute-path-to-protected-pfx>'
$pfxPassword = Read-Host 'PFX password' -AsSecureString
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pfxPath, $pfxPassword,
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
)
$azure.Authentication = 'Certificate'
$azure.TenantId = '<tenant-guid>'
$azure.ClientId = '<application-client-guid>'
$azure.Certificate = $certificate
```

Keep the certificate alive until after Close-LTLog, then call `$certificate.Dispose()`. The logger uses a short-lived PS256-signed client assertion. Protect the PFX and arrange certificate renewal externally.

### Existing Azure CLI session

```powershell
$azure.Authentication = 'AzureCli'
$azure.TenantId = '<tenant-guid>' # Optional; constrain the desired tenant.
```

Azure CLI must be installed and authenticated on the script host. The worker requests an Azure Monitor token using `az account get-access-token --resource https://monitor.azure.com`. It caches tokens and obtains replacements during active logging. It never runs `az login` or reads CLI cache files directly. An expired/unusable session requires you to renew the login outside the logger.

## 5. Send and verify an event

```powershell
Import-Module ./LoggingTools/LoggingTools.psd1
$runId = [guid]::NewGuid().ToString()
Initialize-LTLogConfig -ApplicationName 'LoggingToolsAcceptance' -LogAnalytics $azure
try {
    Write-LTLog -Message 'Azure acceptance event' -Data @{ Count = 42 } -CorrelationId $runId
} finally {
    $result = Close-LTLog -TimeoutSeconds 60 -Strict
}
Get-LTLogStatus
$runId
```

In the workspace's Logs page, replace the placeholder with the displayed run ID:

```kusto
LoggingTools_CL
| where TimeGenerated > ago(1h)
| where CorrelationId == '<run-id>'
| project TimeGenerated, EventId, Level, Message, Application, Data
| order by TimeGenerated asc
```

HTTP success confirms request acceptance. Query visibility may take several minutes, particularly for a new table. Check DCR ingestion metrics/errors if an accepted request does not produce records.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| HTTP 400 | DCR stream declaration, column names/types, transformation, and input stream name |
| HTTP 401/403 | Monitor token audience, tenant, credentials, DCR-scoped role assignment, and propagation delay |
| HTTP 413 or oversized-event failure | Reduce event size or batch size; Azure has a 1 MB request limit |
| HTTP 429 | Throttling; worker honors Retry-After while queue limits still apply |
| CLI failure | Existing login, tenant selection, CLI on PATH, and conditional-access requirements |
| Managed identity failure | Supported Azure host, attached identity, client ID selection, and metadata endpoint access |
| Accepted but no query results | Ingestion delay, DCR transform failures, table name, query time range, and DCR metrics |

See [Microsoft's Logs Ingestion API overview](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview), [ARM setup tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/tutorial-logs-ingestion-api), and [service limits](https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits) for platform details.
