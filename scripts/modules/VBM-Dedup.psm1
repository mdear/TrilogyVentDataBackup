# VBM-Dedup.psm1 — Hardlink-based deduplication of backup files
# See DESIGN.md for the full safety protocol and Dropbox warning.
#
# WARNING: This operation modifies files using NTFS hardlinks.
# It requires a confirmed safety backup before proceeding.
# Dropbox does NOT properly support NTFS hardlinks — see DESIGN.md.

#region ── Test-IsHardlinked ─────────────────────────────────────────────────

function Test-IsHardlinked {
    <#
    .SYNOPSIS
        Return $true if the file has more than one NTFS hardlink (link count > 1).
    .NOTES
        Uses fsutil hardlink list. May require elevation on some systems.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $false }
    try {
        $output = & fsutil hardlink list $Path 2>&1
        # fsutil prints one line per link; multiple lines = hardlinked
        $lines = @($output | Where-Object { $_ -match '\S' })
        return ($lines.Count -gt 1)
    } catch {
        return $false
    }
}

#endregion

#region ── Internal helpers ───────────────────────────────────────────────────

function _IsDropboxPath {
    param([string]$Path)
    $current = $Path
    while ($current -and $current -ne (Split-Path $current -Parent)) {
        if ((Test-Path (Join-Path $current '.dropbox')) -or
            (Test-Path (Join-Path $current '.dropbox.cache'))) {
            return $true
        }
        $current = Split-Path $current -Parent
    }
    return $false
}

function _InvokeSafetyBackup {
    param([string]$BackupRoot, [string]$SafetyPath)
    Write-Host "Creating safety backup at: $SafetyPath ..."
    $null = New-Item -ItemType Directory -Path $SafetyPath -Force

    $allFiles = @(Get-ChildItem -LiteralPath $BackupRoot -File -Recurse -ErrorAction SilentlyContinue)
    $total    = $allFiles.Count
    $i        = 0
    foreach ($f in $allFiles) {
        $i++
        $rel  = $f.FullName.Substring($BackupRoot.Length).TrimStart('\', '/')
        $dest = Join-Path $SafetyPath $rel
        $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($dest)) -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        if ($i % 100 -eq 0 -or $i -eq $total) {
            Write-Progress -Activity 'Safety backup' -Status "$i / $total" `
                           -PercentComplete ([int](($i / $total) * 100))
        }
    }
    Write-Progress -Activity 'Safety backup' -Completed
    return $total
}

function _TestSafetyBackup {
    param([string]$BackupRoot, [string]$SafetyPath)
    $srcFiles  = @(Get-ChildItem -LiteralPath $BackupRoot -File -Recurse)
    $destFiles = @(Get-ChildItem -LiteralPath $SafetyPath -File -Recurse)
    if ($srcFiles.Count -ne $destFiles.Count) {
        return [PSCustomObject]@{ OK = $false; Detail = "File count mismatch: source=$($srcFiles.Count), safety=$($destFiles.Count)" }
    }
    # Spot-check 10% of files by hash
    $sample = $srcFiles | Get-Random -Count ([Math]::Max(1, [int]($srcFiles.Count * 0.10)))
    foreach ($f in $sample) {
        $rel     = $f.FullName.Substring($BackupRoot.Length).TrimStart('\', '/')
        $sfPath  = Join-Path $SafetyPath $rel
        if (-not (Test-Path $sfPath)) {
            return [PSCustomObject]@{ OK = $false; Detail = "Missing in safety: $rel" }
        }
        $sh = (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash
        $dh = (Get-FileHash -LiteralPath $sfPath     -Algorithm MD5).Hash
        if ($sh -ne $dh) {
            return [PSCustomObject]@{ OK = $false; Detail = "Hash mismatch: $rel" }
        }
    }
    return [PSCustomObject]@{ OK = $true; Detail = "Verified $($srcFiles.Count) files (sampled $($sample.Count) hashes)" }
}

function _InvokeDedupRollback {
    param([string]$BackupRoot, [string]$SafetyPath)
    Write-Host "Rolling back from safety backup ..." -ForegroundColor Yellow
    $safeFiles = @(Get-ChildItem -LiteralPath $SafetyPath -File -Recurse)
    foreach ($f in $safeFiles) {
        $rel  = $f.FullName.Substring($SafetyPath.Length).TrimStart('\', '/')
        $dest = Join-Path $BackupRoot $rel
        $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($dest)) -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
    Write-Host "Rollback complete. BackupRoot restored from safety copy." -ForegroundColor Yellow
}

#endregion

#region ── Invoke-Compaction ─────────────────────────────────────────────────

function Invoke-Compaction {
    <#
    .SYNOPSIS
        Deduplicate backup files using NTFS hardlinks to reclaim storage.
    .DESCRIPTION
        Full safety protocol:
        1. Dropbox warning if BackupRoot is Dropbox-synced
        2. Safety backup at SafetyPath + verification
        3. Scan and group by MD5 hash
        4. Replace duplicates with hardlinks using fsutil
        5. Post-dedup integrity check
        6. Rollback from safety backup on failure
    .PARAMETER BackupRoot
        Directory containing all backup folders.
    .PARAMETER SafetyPath
        Path for the pre-dedup safety copy (should be on external/non-synced drive).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$SafetyPath
    )

    # ── Dropbox warning ────────────────────────────────────────────────────
    if (_IsDropboxPath -Path $BackupRoot) {
        Write-Host ''
        Write-Host '  WARNING: BackupRoot appears to be inside a Dropbox-synced folder.' -ForegroundColor Yellow
        Write-Host '  Dropbox does NOT honor NTFS hardlinks. It will treat each hardlinked' -ForegroundColor Yellow
        Write-Host '  file as a separate copy during sync, defeating storage savings.' -ForegroundColor Yellow
        Write-Host '  Syncing hardlinks may also cause file corruption on other devices.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  To use Compact safely, run it on a local non-synced copy of BackupRoot.' -ForegroundColor Yellow
        Write-Host ''
        $yn = Read-Host 'Continue anyway? (type YES to confirm, anything else cancels)'
        if ($yn -ne 'YES') {
            Write-Host 'Compaction cancelled.' -ForegroundColor Cyan
            return
        }
    }

    # ── Validate SafetyPath is not inside BackupRoot (would defeat the purpose)
    if ($SafetyPath.StartsWith($BackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SafetyPath must be outside BackupRoot. Choose a different drive or folder."
    }

    # ── Hardlink cross-volume check ────────────────────────────────────────
    $backupDrive = [System.IO.Path]::GetPathRoot($BackupRoot)
    $safetyDrive = [System.IO.Path]::GetPathRoot($SafetyPath)
    if ($backupDrive -ne $safetyDrive) {
        # This is expected and fine — safety backup is on a different volume
        # just note that rollback uses Copy-Item (no hardlinks across volumes)
    }

    # ── Safety backup ──────────────────────────────────────────────────────
    $count = _InvokeSafetyBackup -BackupRoot $BackupRoot -SafetyPath $SafetyPath
    Write-Host "Safety backup: $count files copied" -ForegroundColor Cyan

    $verify = _TestSafetyBackup -BackupRoot $BackupRoot -SafetyPath $SafetyPath
    if (-not $verify.OK) {
        throw "Safety backup verification FAILED: $($verify.Detail). Compaction aborted."
    }
    Write-Host "Safety backup verified: $($verify.Detail)" -ForegroundColor Green

    # ── Scan all files, group by MD5 hash ─────────────────────────────────
    Write-Host "Scanning for duplicate files ..."
    $allFiles = @(Get-ChildItem -LiteralPath $BackupRoot -File -Recurse -ErrorAction SilentlyContinue)
    $hashMap  = @{}  # hash -> List of paths (master = first entry)
    $total    = $allFiles.Count
    $i        = 0

    foreach ($f in $allFiles) {
        $i++
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash
        if (-not $hashMap.ContainsKey($hash)) {
            $hashMap[$hash] = [System.Collections.Generic.List[string]]::new()
        }
        $hashMap[$hash].Add($f.FullName)
        if ($i % 200 -eq 0 -or $i -eq $total) {
            Write-Progress -Activity 'Computing hashes' -Status "$i / $total" `
                           -PercentComplete ([int](($i / $total) * 100))
        }
    }
    Write-Progress -Activity 'Computing hashes' -Completed

    $dupGroups = @($hashMap.Values | Where-Object { $_.Count -gt 1 })
    $dupCount  = ($dupGroups | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
    Write-Host "Found $($dupGroups.Count) duplicate groups, $dupCount redundant files" -ForegroundColor Cyan

    if ($dupCount -eq 0) {
        Write-Host "No duplicates found. Nothing to compact." -ForegroundColor Green
        return
    }

    # ── Replace duplicates with hardlinks ─────────────────────────────────
    Write-Host "Creating hardlinks ..."
    $linked  = 0
    $errList = [System.Collections.Generic.List[string]]::new()

    foreach ($group in $dupGroups) {
        $master = $group[0]   # Keep the first file as master

        for ($k = 1; $k -lt $group.Count; $k++) {
            $dup = $group[$k]

            # Guard: never modify a file that is already hardlinked outside this group
            if (Test-IsHardlinked -Path $dup) {
                # Already hardlinked — skip rather than corrupt
                continue
            }

            # Remove the duplicate and create a hardlink to master
            try {
                Remove-Item -LiteralPath $dup -Force
                $result = & fsutil hardlink create $dup $master 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $errList.Add("fsutil failed for '$dup': $result")
                    # Restore from safety backup for this file
                    $rel      = $dup.Substring($BackupRoot.Length).TrimStart('\', '/')
                    $safeFile = Join-Path $SafetyPath $rel
                    if (Test-Path $safeFile) { Copy-Item -LiteralPath $safeFile -Destination $dup -Force }
                } else {
                    $linked++
                }
            } catch {
                $errList.Add("Exception linking '$dup': $_")
            }
        }
    }

    Write-Host "Hardlinks created: $linked"
    if ($errList.Count -gt 0) {
        Write-Host "$($errList.Count) error(s) during hardlink creation:" -ForegroundColor Yellow
        foreach ($e in ($errList | Select-Object -First 5)) { Write-Host "  • $e" -ForegroundColor Yellow }
    }

    # ── Post-dedup integrity check ─────────────────────────────────────────
    Write-Host "Post-dedup integrity check ..."
    $postFiles = @(Get-ChildItem -LiteralPath $BackupRoot -File -Recurse -ErrorAction SilentlyContinue)
    $intFail   = [System.Collections.Generic.List[string]]::new()

    foreach ($pf in $postFiles) {
        $rel      = $pf.FullName.Substring($BackupRoot.Length).TrimStart('\', '/')
        $sfPath   = Join-Path $SafetyPath $rel
        if (-not (Test-Path $sfPath)) { continue }  # New file added during compaction — skip
        $ph = (Get-FileHash -LiteralPath $pf.FullName -Algorithm MD5).Hash
        $sh = (Get-FileHash -LiteralPath $sfPath      -Algorithm MD5).Hash
        if ($ph -ne $sh) {
            $intFail.Add("CONTENT MISMATCH after dedup: $rel")
        }
    }

    if ($intFail.Count -gt 0) {
        Write-Host "Integrity check FAILED ($($intFail.Count) issues). Rolling back..." -ForegroundColor Red
        foreach ($e in ($intFail | Select-Object -First 5)) { Write-Host "  • $e" -ForegroundColor Red }
        _InvokeDedupRollback -BackupRoot $BackupRoot -SafetyPath $SafetyPath
        throw "Compaction rolled back due to $($intFail.Count) integrity failure(s)."
    }

    Write-Host ''
    Write-Host "Compaction complete: $linked files deduplicated via hardlinks." -ForegroundColor Green
    Write-Host "Safety backup retained at: $SafetyPath" -ForegroundColor Cyan
    Write-Host "(You may delete the safety backup once you have confirmed everything looks correct.)" -ForegroundColor DarkGray
}

#endregion

Export-ModuleMember -Function @(
    'Test-IsHardlinked',
    'Invoke-Compaction'
)
