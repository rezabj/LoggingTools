# Pester 6 requires a newer test host; this script verifies the module on PowerShell 7.0.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../LoggingTools/LoggingTools.psd1') -Force
$directory = Join-Path ([IO.Path]::GetTempPath()) ('LoggingTools-smoke-' + [guid]::NewGuid())
$path = Join-Path $directory 'smoke.jsonl'
try {
    Initialize-LTLogConfig -ApplicationName smoke -File @{ Path = $path; CreateDirectory = $true }
    1..100 | ForEach-Object { Write-LTLog -Message "event-$_" -Data @{ Password = 'never-persist'; Count = $_ } }
    $result = Close-LTLog -Strict
    $lines = @(Get-Content -LiteralPath $path)
    if (-not $result.Success -or $lines.Count -ne 100) { throw 'Smoke test lost events.' }
    if (($lines -join '') -match 'never-persist') { throw 'Smoke test redaction failed.' }
    if (($lines[99] | ConvertFrom-Json).Data.Count -ne 100) { throw 'Smoke test event ordering failed.' }
    Write-Output "Smoke passed on $($PSVersionTable.PSVersion) / $($PSVersionTable.Platform)."
} finally {
    try { $null = Close-LTLog -TimeoutSeconds 1 -WarningAction SilentlyContinue } catch { }
    # Delete only the exact generated files; never recursively delete a computed path.
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
}
