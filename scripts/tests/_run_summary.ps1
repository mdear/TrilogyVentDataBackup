Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Output.Verbosity = 'Minimal'
$r = Invoke-Pester -Configuration $cfg
$summary = "P:$($r.PassedCount) F:$($r.FailedCount) S:$($r.SkippedCount)"
$summary | Set-Content "$env:TEMP\pester_summary.txt" -Encoding UTF8
Write-Host $summary
