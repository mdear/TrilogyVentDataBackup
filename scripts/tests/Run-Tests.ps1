#Requires -Version 5.1
# Run-Tests.ps1 — Execute all Pester 5 unit tests for the VentBackupManager toolchain.
# Usage:
#   .\Run-Tests.ps1                       # Run all tests, detailed output
#   .\Run-Tests.ps1 -Filter 'GoldenArchive'  # Run only matching describe blocks
[CmdletBinding()]
param(
    [string]$Filter
)

$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule -or $pesterModule.Version.Major -lt 5) {
    Write-Error "Pester 5 or later is required. Install via: Install-Module Pester -MinimumVersion 5.0 -Force"
    exit 1
}
Import-Module Pester -MinimumVersion '5.0' -Force

$config = New-PesterConfiguration
$config.Run.Path        = $PSScriptRoot
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit        = $true   # non-zero exit code on failure

if ($Filter) {
    $config.Filter.FullName = "*$Filter*"
}

Invoke-Pester -Configuration $config
