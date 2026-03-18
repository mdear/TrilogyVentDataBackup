# VBM-Backup.psm1 — Ingest SD card contents into a timestamped backup folder

#region ── Import-SDCard ─────────────────────────────────────────────────────

function Import-SDCard {
    <#
    .SYNOPSIS
        Copy SD card contents into a new timestamped backup folder under BackupRoot.
    .DESCRIPTION
        1. Reads P-Series/last.txt from the source SD card
        2. Creates {BackupRoot}/backup_YYYY-MM-DD_{SN}
        3. Copies all SD card files with verification
        4. Returns the path to the new backup folder
    .PARAMETER Source
        Root path of the SD card (must contain Trilogy/ or P-Series/).
    .PARAMETER BackupRoot
        Parent directory where all backups live.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    # Validate source
    $hasT = Test-Path (Join-Path $Source 'Trilogy')
    $hasP = Test-Path (Join-Path $Source 'P-Series')
    if (-not $hasT -and -not $hasP) {
        throw "Source path '$Source' does not appear to be a Trilogy SD card root (no Trilogy/ or P-Series/ found)."
    }

    # Identify active device from last.txt
    $activeSN = $null
    $lastTxtPath = Join-Path (Join-Path $Source 'P-Series') 'last.txt'
    if (Test-Path $lastTxtPath) {
        $activeSN = (Get-Content $lastTxtPath -Raw).Trim()
    }

    # Create destination folder name
    $date  = Get-Date -Format 'yyyy-MM-dd'
    $label = if ($activeSN) { "backup_${date}_$activeSN" } else { "backup_$date" }
    $destPath = Join-Path $BackupRoot $label

    # Avoid collisions
    if (Test-Path $destPath) {
        $seq = 1
        while (Test-Path "${destPath}.$seq") { $seq++ }
        $destPath = "${destPath}.$seq"
    }

    $null = New-Item -ItemType Directory -Path $destPath -Force
    Write-Host "Backup destination: $destPath" -ForegroundColor Cyan

    # ── Copy with progress tracking ────────────────────────────────────────
    Write-Host "Copying SD card contents ..."
    $allFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse -ErrorAction SilentlyContinue)
    $total    = $allFiles.Count
    $i        = 0

    foreach ($f in $allFiles) {
        $i++
        $rel  = $f.FullName.Substring($Source.Length).TrimStart('\', '/')
        $dest = Join-Path $destPath $rel
        $dir  = [System.IO.Path]::GetDirectoryName($dest)
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        if ($i % 50 -eq 0 -or $i -eq $total) {
            Write-Progress -Activity 'Copying SD card' -Status "$i / $total files" `
                           -PercentComplete ([int](($i / $total) * 100))
        }
    }
    Write-Progress -Activity 'Copying SD card' -Completed

    # ── Integrity verification: compare hashes ────────────────────────────
    Write-Host "Verifying copy integrity ..."
    $failures = [System.Collections.Generic.List[string]]::new()
    $j = 0
    foreach ($f in $allFiles) {
        $j++
        $rel  = $f.FullName.Substring($Source.Length).TrimStart('\', '/')
        $dest = Join-Path $destPath $rel

        if (-not (Test-Path $dest)) {
            $failures.Add("MISSING: $rel")
            continue
        }

        # Skip corrupt/short EDF files — they're flagged later by integrity check
        $srcHash  = (Get-FileHash -LiteralPath $f.FullName  -Algorithm MD5).Hash
        $destHash = (Get-FileHash -LiteralPath $dest         -Algorithm MD5).Hash
        if ($srcHash -ne $destHash) {
            $failures.Add("HASH MISMATCH: $rel")
        }

        if ($j % 50 -eq 0 -or $j -eq $total) {
            Write-Progress -Activity 'Verifying copy' -Status "$j / $total" `
                           -PercentComplete ([int](($j / $total) * 100))
        }
    }
    Write-Progress -Activity 'Verifying copy' -Completed

    if ($failures.Count -gt 0) {
        Write-Host "Copy verification FAILED — $($failures.Count) issue(s):" -ForegroundColor Red
        foreach ($fail in $failures) {
            Write-Host "  • $fail" -ForegroundColor Red
        }
        Write-Host "Backup folder retained for inspection: $destPath" -ForegroundColor Yellow
        $msg = "SD card copy integrity check failed. $($failures.Count) issue(s) found."
        throw $msg
    }

    Write-Host "Copy verified: $total files OK" -ForegroundColor Green
    Write-Host "New backup: $destPath" -ForegroundColor Green
    return $destPath
}

#endregion

Export-ModuleMember -Function @(
    'Import-SDCard'
)
