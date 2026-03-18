$ErrorActionPreference = 'Continue'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$files = @(
    "$here\modules\VBM-Parsers.psm1",
    "$here\modules\VBM-Analyzer.psm1",
    "$here\modules\VBM-GoldenArchive.psm1",
    "$here\modules\VBM-Export.psm1",
    "$here\modules\VBM-Backup.psm1",
    "$here\modules\VBM-Dedup.psm1",
    "$here\modules\VBM-UI.psm1",
    "$here\VentBackupManager.ps1"
)
$anyFail = $false
foreach ($f in $files) {
    $tokens = $null
    $errs   = $null
    $null   = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
    if ($errs.Count -gt 0) {
        $anyFail = $true
        Write-Output "FAIL $f"
        foreach ($e in $errs) {
            Write-Output "  L$($e.Extent.StartLineNumber): $($e.Message)"
        }
    } else {
        Write-Output "OK   $([System.IO.Path]::GetFileName($f))"
    }
}
if (-not $anyFail) { Write-Output "ALL OK" }
