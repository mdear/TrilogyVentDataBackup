#Requires -Version 5.1
# Run-Tests.ps1 — Execute all Pester 5 unit tests for the VentBackupManager toolchain.
# Usage:
#   .\Run-Tests.ps1                       # Run all tests, detailed output
#   .\Run-Tests.ps1 -Filter 'Analyzer'    # Match file name: runs VBM-Analyzer.Tests.ps1
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
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit        = $true   # non-zero exit code on failure

if ($Filter) {
    # First check if the filter matches a test file name (e.g. 'Analyzer' -> VBM-Analyzer.Tests.ps1)
    $matchingFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "VBM-$Filter.Tests.ps1" -ErrorAction SilentlyContinue)
    if ($matchingFiles.Count -eq 0) {
        $matchingFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*$Filter*.Tests.ps1" -ErrorAction SilentlyContinue)
    }
    if ($matchingFiles.Count -gt 0) {
        # File-based filter: run only the matched test file(s)
        $config.Run.Path = @($matchingFiles.FullName)
    } else {
        # Fall back to FullName filter (matches Describe/It block names)
        $config.Run.Path        = $PSScriptRoot
        $config.Filter.FullName = "*$Filter*"
    }
} else {
    $config.Run.Path = $PSScriptRoot
}

Invoke-Pester -Configuration $config
