[CmdletBinding()]
param([string]$OutputPath = (Join-Path $PSScriptRoot '../artifacts/pester.xml'))
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'The Pester 6 test runner requires PowerShell 7.4+. The module itself requires PowerShell 7.0+; use Smoke.ps1 for older runtimes.' }
$loaded = Get-Module Pester
if ($loaded -and $loaded.Version -lt [version]'6.2.0') { throw 'An older Pester is loaded. Start a fresh PowerShell session with Pester 6.2.0 or newer.' }
Import-Module Pester -MinimumVersion 6.2.0 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'LoggingTools.Tests.ps1'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = $OutputPath
$configuration.TestResult.OutputFormat = 'NUnitXml'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))))
$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.TotalCount -eq 0) { throw "Pester failed: $($result.FailedCount) failures; $($result.TotalCount) tests." }
