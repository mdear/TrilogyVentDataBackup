# VBM-Analyzer.psm1 — Backup scanning, TOC building, integrity checking
# See ARCHITECTURE.md and DESIGN.md for data format spec and algorithm details.

Import-Module (Join-Path $PSScriptRoot 'VBM-Parsers.psm1') -Force

#region ── Internal helpers ──────────────────────────────────────────────────

function _NewDeviceSlot {
    param([string]$SN, [string]$ActiveDevice)
    return @{
        TrilogyFiles   = [System.Collections.Generic.List[object]]::new()
        PSeriesFiles   = [System.Collections.Generic.List[object]]::new()
        EarliestDate   = $null
        LatestDate     = $null
        FileCount      = 0
        Model          = $null
        ProductType    = $null
        Firmware       = $null
        IsActiveDevice = ($SN -eq $ActiveDevice)
    }
}

function _UpdateDateRange {
    param([hashtable]$Device, [int]$Year, [int]$Month)
    $ds = '{0:D4}-{1:D2}' -f $Year, $Month
    if (-not $Device['EarliestDate'] -or $ds -lt $Device['EarliestDate']) {
        $Device['EarliestDate'] = $ds
    }
    if (-not $Device['LatestDate'] -or $ds -gt $Device['LatestDate']) {
        $Device['LatestDate'] = $ds
    }
}

function _ScanBackupFolder {
    param([PSCustomObject]$BackupEntry)

    $backupPath  = $BackupEntry.Path
    $backupName  = $BackupEntry.Name
    $devices     = @{}      # SN -> mutable hashtable
    $trilogyPath = Join-Path $backupPath 'Trilogy'
    $pSeriesPath = Join-Path $backupPath 'P-Series'

    # ── P-Series: build authoritative device roster first ─────────────────
    $activeDevice = $null
    if (Test-Path $pSeriesPath) {
        $lastPath = Join-Path $pSeriesPath 'last.txt'
        if (Test-Path $lastPath) { $activeDevice = Read-LastTxt -Path $lastPath }

        foreach ($snDir in Get-ChildItem -LiteralPath $pSeriesPath -Directory -ErrorAction SilentlyContinue) {
            $sn = $snDir.Name
            if (-not $devices.ContainsKey($sn)) {
                $devices[$sn] = _NewDeviceSlot -SN $sn -ActiveDevice $activeDevice
            } else {
                $devices[$sn]['IsActiveDevice'] = ($sn -eq $activeDevice)
            }

            # prop.txt
            $propPath = Join-Path $snDir.FullName 'prop.txt'
            if (Test-Path $propPath) {
                $prop = Read-PropFile -Path $propPath
                if ($prop) {
                    if ($prop.PSObject.Properties['MN']) { $devices[$sn]['Model']       = $prop.MN }
                    if ($prop.PSObject.Properties['PT']) { $devices[$sn]['ProductType'] = $prop.PT }
                }
            }

            # Collect all P-Series files (recursive — covers P0-P7 ring buffer)
            foreach ($pf in Get-ChildItem -LiteralPath $snDir.FullName -File -Recurse -ErrorAction SilentlyContinue) {
                $rel = $pf.FullName.Substring($backupPath.Length).TrimStart('\', '/')
                $devices[$sn]['PSeriesFiles'].Add([PSCustomObject]@{
                    Path         = $pf.FullName
                    RelativePath = $rel
                    FileName     = $pf.Name
                    Size         = $pf.Length
                })
            }
        }
    }

    # ── Trilogy: scan flat directory ───────────────────────────────────────
    if (Test-Path $trilogyPath) {
        foreach ($tf in Get-ChildItem -LiteralPath $trilogyPath -File -ErrorAction SilentlyContinue) {
            $ext  = $tf.Extension.ToLower()
            $name = $tf.Name

            $sn       = $null
            $dateInfo = $null

            if ($ext -eq '.edf') {
                $sn       = Get-EdfDeviceSerial -Path $tf.FullName
                $dateInfo = Get-EdfDateInfo -Path $tf.FullName
            } elseif ($ext -eq '.bin') {
                $binInfo = Get-BinFileInfo -Path $tf.FullName
                if ($binInfo) { $sn = $binInfo.SerialNumber }
            } elseif ($ext -eq '.csv' -and $name -match '^EL_') {
                $elInfo = Get-ElCsvInfo -Path $tf.FullName
                if ($elInfo) { $sn = $elInfo.SerialNumber }
            }

            if (-not $sn) { continue }

            if (-not $devices.ContainsKey($sn)) {
                $devices[$sn] = _NewDeviceSlot -SN $sn -ActiveDevice $activeDevice
            }

            $devices[$sn]['TrilogyFiles'].Add([PSCustomObject]@{
                Path     = $tf.FullName
                FileName = $name
                Size     = $tf.Length
                SN       = $sn
                FileType = if ($dateInfo) { $dateInfo.FileType } else { $null }
                Year     = if ($dateInfo) { $dateInfo.Year     } else { $null }
                Month    = if ($dateInfo) { $dateInfo.Month    } else { $null }
                Day      = if ($dateInfo) { $dateInfo.Day      } else { $null }
                Sequence = if ($dateInfo) { $dateInfo.Sequence } else { $null }
                IsDaily  = if ($dateInfo) { $dateInfo.IsDaily  } else { $false }
            })

            # Firmware from EDF RecordingID (lazy — only when not already known)
            if ($ext -eq '.edf' -and -not $devices[$sn]['Firmware']) {
                $hdr = Read-EdfHeader -Path $tf.FullName
                if ($hdr -and $hdr.RecordingID -match 'TGY200\s+0\s+\S+\s+\S+\s+\S+\s+(\S+)') {
                    $devices[$sn]['Firmware'] = $Matches[1]
                }
            }

            # Monthly date range (AD/DD only; WD is daily and noisier)
            if ($dateInfo -and -not $dateInfo.IsDaily -and $dateInfo.Year -and $dateInfo.Month) {
                _UpdateDateRange -Device $devices[$sn] -Year $dateInfo.Year -Month $dateInfo.Month
            }
        }
    }

    # ── Convert mutable hashtables → PSCustomObjects ───────────────────────
    $deviceObjs = @{}
    foreach ($sn in $devices.Keys) {
        $d        = $devices[$sn]
        $triArray = $d['TrilogyFiles'].ToArray()
        $psArray  = $d['PSeriesFiles'].ToArray()
        $deviceObjs[$sn] = [PSCustomObject]@{
            TrilogyFiles   = $triArray
            PSeriesFiles   = $psArray
            EarliestDate   = $d['EarliestDate']
            LatestDate     = $d['LatestDate']
            FileCount      = $triArray.Count + $psArray.Count
            Model          = $d['Model']
            ProductType    = $d['ProductType']
            Firmware       = $d['Firmware']
            IsActiveDevice = $d['IsActiveDevice']
        }
    }

    return [PSCustomObject]@{
        Name         = $backupName
        Path         = $backupPath
        Devices      = $deviceObjs
        ActiveDevice = $activeDevice
        Integrity    = 'Unknown'
        Anomalies    = @()
    }
}

#endregion

#region ── Get-BackupInventory ───────────────────────────────────────────────

function Get-BackupInventory {
    <#
    .SYNOPSIS
        Discover all backup folders under BackupRoot.
        Returns array of PSObjects: Name, Path, HasTrilogy, HasPSeries, SubBackups.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupRoot)

    # ── Edge case 19: Dropbox Smart Sync warning ───────────────────────────
    # Files may be "online only" and inaccessible. Warn so the user can make
    # them available offline before scanning (per DESIGN.md edge case 19).
    $dbCheck = $BackupRoot
    while ($dbCheck -and $dbCheck -ne (Split-Path $dbCheck -Parent)) {
        if ((Test-Path (Join-Path $dbCheck '.dropbox')) -or
            (Test-Path (Join-Path $dbCheck '.dropbox.cache'))) {
            Write-Warning 'BackupRoot appears to be inside a Dropbox-synced folder.'
            Write-Warning 'Files that are "online only" (Dropbox Smart Sync) will be silently'
            Write-Warning 'skipped during scanning. Make all files available offline first.'
            break
        }
        $dbCheck = Split-Path $dbCheck -Parent
    }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($item in Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue) {
        $name = $item.Name

        # Exclusion patterns per DESIGN.md
        if ($name -eq 'scripts')          { continue }
        if ($name -match '^_golden_')     { continue }
        if ($name -match '^[._]')         { continue }
        if ($name -eq 'nul')              { continue }

        $hasT = Test-Path (Join-Path $item.FullName 'Trilogy')
        $hasP = Test-Path (Join-Path $item.FullName 'P-Series')

        # Discover nested sub-backups (e.g. "4.10.2024/vent 2" or "SD card 26-03-18/F_").
        # Scanned before the skip guard so that folders with no direct Trilogy/P-Series
        # but with data one level deeper (any intermediate folder name) are still accepted.
        $subList = [System.Collections.Generic.List[object]]::new()
        foreach ($sub in Get-ChildItem -LiteralPath $item.FullName -Directory -ErrorAction SilentlyContinue) {
            $sName = $sub.Name
            if ($sName -match '^[._]') { continue }
            $sHasT = Test-Path (Join-Path $sub.FullName 'Trilogy')
            $sHasP = Test-Path (Join-Path $sub.FullName 'P-Series')
            if ($sHasT -or $sHasP) {
                $subList.Add([PSCustomObject]@{
                    Name       = "$name/$sName"
                    Path       = $sub.FullName
                    HasTrilogy = $sHasT
                    HasPSeries = $sHasP
                    SubBackups = @()
                })
            }
        }

        # Skip folders with no backup data at this level or one level down
        if (-not $hasT -and -not $hasP -and $subList.Count -eq 0) { continue }

        $results.Add([PSCustomObject]@{
            Name       = $name
            Path       = $item.FullName
            HasTrilogy = $hasT
            HasPSeries = $hasP
            SubBackups = $subList.ToArray()
        })
    }

    return $results.ToArray()
}

#endregion

#region ── Get-BackupTOC ─────────────────────────────────────────────────────

function Get-BackupTOC {
    <#
    .SYNOPSIS
        Scan all backups and build the full data model (TOC).
        Automatically runs integrity checks after scanning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Inventory,
        [scriptblock]$ProgressCallback
    )

    $backups = @{}

    # Flatten inventory including sub-backups
    $allEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Inventory) {
        $allEntries.Add($entry)
        foreach ($sub in $entry.SubBackups) { $allEntries.Add($sub) }
    }

    $total = $allEntries.Count
    $i     = 0
    foreach ($entry in $allEntries) {
        $i++
        if ($ProgressCallback) {
            & $ProgressCallback "Scanning $($entry.Name)" $i $total
        }
        $detail = _ScanBackupFolder -BackupEntry $entry
        $backups[$entry.Name] = $detail
    }

    # ── Cross-backup device aggregation ───────────────────────────────────
    $devAgg = @{}
    foreach ($bName in $backups.Keys) {
        foreach ($sn in $backups[$bName].Devices.Keys) {
            if (-not $devAgg.ContainsKey($sn)) {
                $devAgg[$sn] = @{
                    BackupPresence  = [System.Collections.Generic.List[string]]::new()
                    OverallEarliest = $null
                    OverallLatest   = $null
                    UniqueFilenames = [System.Collections.Generic.HashSet[string]]::new()
                    Model           = $null
                    ProductType     = $null
                }
            }
            $devAgg[$sn]['BackupPresence'].Add($bName)
            $dev = $backups[$bName].Devices[$sn]
            if ($dev.EarliestDate) {
                $cur = $devAgg[$sn]['OverallEarliest']
                if (-not $cur -or $dev.EarliestDate -lt $cur) { $devAgg[$sn]['OverallEarliest'] = $dev.EarliestDate }
            }
            if ($dev.LatestDate) {
                $cur = $devAgg[$sn]['OverallLatest']
                if (-not $cur -or $dev.LatestDate -gt $cur) { $devAgg[$sn]['OverallLatest'] = $dev.LatestDate }
            }
            foreach ($f in $dev.TrilogyFiles) {
                [void]$devAgg[$sn]['UniqueFilenames'].Add("$sn|$($f.FileName)")
            }
            if (-not $devAgg[$sn]['Model']       -and $dev.Model)       { $devAgg[$sn]['Model']       = $dev.Model }
            if (-not $devAgg[$sn]['ProductType']  -and $dev.ProductType) { $devAgg[$sn]['ProductType'] = $dev.ProductType }
        }
    }

    $devicesSummary = @{}
    foreach ($sn in $devAgg.Keys) {
        $d = $devAgg[$sn]
        $devicesSummary[$sn] = [PSCustomObject]@{
            BackupPresence   = $d['BackupPresence'].ToArray()
            OverallEarliest  = $d['OverallEarliest']
            OverallLatest    = $d['OverallLatest']
            TotalUniqueFiles = $d['UniqueFilenames'].Count
            Model            = $d['Model']
            ProductType      = $d['ProductType']
        }
    }

    $toc = [PSCustomObject]@{
        Backups = $backups
        Devices = $devicesSummary
    }

    # ── Run integrity tests (requires full TOC for cross-backup comparisons)
    $j = 0
    foreach ($bName in $backups.Keys) {
        $j++
        if ($ProgressCallback) {
            & $ProgressCallback "Checking integrity: $bName" ($total + $j) ($total * 2)
        }
        $result = Test-BackupIntegrity -BackupDetail $backups[$bName] -TOC $toc
        $backups[$bName].Integrity = $result.Integrity
        $backups[$bName].Anomalies = $result.Anomalies
    }

    return $toc
}

#endregion

#region ── Test-BackupIntegrity ──────────────────────────────────────────────

function Test-BackupIntegrity {
    <#
    .SYNOPSIS
        Check a single backup for contamination, missing pairs, truncated files,
        and P-Series consistency issues.
    .NOTES
        Requires the full TOC object for cross-backup size comparisons.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$BackupDetail,
        [Parameter(Mandatory)][PSCustomObject]$TOC
    )

    $anomalies  = [System.Collections.Generic.List[object]]::new()
    $backupName = $BackupDetail.Name
    $devices    = $BackupDetail.Devices

    # ── Build expected device set from P-Series roster ─────────────────────
    # Per DESIGN.md: "P-Series/{SN}/ directory listing as authoritative device roster"
    # DO NOT use majority-SN voting as primary method.
    $expectedSnSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($sn in $devices.Keys) {
        $hasProp = $devices[$sn].PSeriesFiles | Where-Object { $_.FileName -eq 'prop.txt' }
        if ($hasProp) { [void]$expectedSnSet.Add($sn) }
    }
    # Fallback: if no P-Series at all, admit all observed SNs (can't determine contamination)
    $pSeriesPath = Join-Path $BackupDetail.Path 'P-Series'
    $hasPSeriesDir = Test-Path $pSeriesPath
    if (-not $hasPSeriesDir) {
        foreach ($sn in $devices.Keys) { [void]$expectedSnSet.Add($sn) }
    }

    # ── Cross-backup check for .NNN variant backups (DESIGN.md §7) ────────
    # Per DESIGN.md: "cross-reference against the clean copy of the same backup
    # if one exists (e.g., 12.1.2025 vs 12.1.2025.002)".
    # Contamination can also pollute the P-Series folder (the contaminating SD
    # card's P-Series subdir gets merged in), so the expected-set check above
    # cannot detect it alone. Solution: if this backup is named {base}.NNN,
    # find {base} in the TOC, build its P-Series device set, and treat any SN
    # present here but absent from {base} as a contaminating device.
    $taintedSnSet = [System.Collections.Generic.HashSet[string]]::new()
    if ($backupName -match '^(.+)\.\d{3}$') {
        $baseName = $Matches[1]
        if ($TOC.Backups.ContainsKey($baseName)) {
            $baseDevices = $TOC.Backups[$baseName].Devices
            $baseSnSet   = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($sn in $baseDevices.Keys) {
                $hasProp = $baseDevices[$sn].PSeriesFiles | Where-Object { $_.FileName -eq 'prop.txt' }
                if ($hasProp) { [void]$baseSnSet.Add($sn) }
            }
            foreach ($sn in @($expectedSnSet)) {
                if (-not $baseSnSet.Contains($sn)) { [void]$taintedSnSet.Add($sn) }
            }
        }
    }

    # ── 1. Contamination: EDF files whose SN is not in expected set,
    #       OR whose SN was injected relative to the base backup ───────────
    foreach ($sn in $devices.Keys) {
        $notExpected = $expectedSnSet.Count -gt 0 -and -not $expectedSnSet.Contains($sn)
        $tainted     = $taintedSnSet.Contains($sn)
        if ($notExpected -or $tainted) {
            $detail = if ($tainted) {
                "Device $sn is present in P-Series here but absent from base backup '$($backupName -replace '\.\d{3}$','')' — its SD card data was likely merged into this folder"
            } else {
                "SN in EDF header ($sn) not found in P-Series roster ($($expectedSnSet -join ', '))"
            }
            foreach ($f in $devices[$sn].TrilogyFiles) {
                $anomalies.Add([PSCustomObject]@{
                    Type       = 'Contamination'
                    Severity   = 'High'
                    File       = $f.Path
                    Detail     = $detail
                    Suggestion = "Verify against clean backup; this file may have overwritten a different device's data"
                })
            }
        }
    }

    # ── 2. Missing AD/DD pairs ─────────────────────────────────────────────
    $adKeys = @{}
    $ddKeys = @{}
    foreach ($sn in $devices.Keys) {
        foreach ($f in $devices[$sn].TrilogyFiles) {
            if ($null -eq $f.Year -or $null -eq $f.Month -or $null -eq $f.Sequence) { continue }
            $key = '{0}|{1:D4}{2:D2}_{3:D3}' -f $sn, $f.Year, $f.Month, $f.Sequence
            if ($f.FileType -eq 'AD') { $adKeys[$key] = $f }
            elseif ($f.FileType -eq 'DD') { $ddKeys[$key] = $f }
        }
    }
    foreach ($k in $adKeys.Keys) {
        if (-not $ddKeys.ContainsKey($k)) {
            $f = $adKeys[$k]
            $anomalies.Add([PSCustomObject]@{
                Type       = 'MissingPair'
                Severity   = 'Low'
                File       = $f.Path
                Detail     = "AD file '$($f.FileName)' (device $($f.SN)) has no matching DD_ file for same SN/month/sequence"
                Suggestion = "Check other backups for the matching DD file"
            })
        }
    }
    foreach ($k in $ddKeys.Keys) {
        if (-not $adKeys.ContainsKey($k)) {
            $f = $ddKeys[$k]
            $anomalies.Add([PSCustomObject]@{
                Type       = 'MissingPair'
                Severity   = 'Low'
                File       = $f.Path
                Detail     = "DD file '$($f.FileName)' (device $($f.SN)) has no matching AD_ file for same SN/month/sequence"
                Suggestion = "Check other backups for the matching AD file"
            })
        }
    }

    # ── 3. Truncated files: compare sizes against same SN+filename in other backups ──
    # Only flag when another backup has >20% larger version for the same device SN.
    foreach ($sn in $devices.Keys) {
        foreach ($f in $devices[$sn].TrilogyFiles) {
            foreach ($otherName in $TOC.Backups.Keys) {
                if ($otherName -eq $backupName) { continue }
                $other = $TOC.Backups[$otherName]
                if (-not $other.Devices.ContainsKey($sn)) { continue }
                $match = $other.Devices[$sn].TrilogyFiles |
                         Where-Object { $_.FileName -eq $f.FileName } |
                         Select-Object -First 1
                if ($match -and $match.Size -gt ($f.Size * 1.20)) {
                    $anomalies.Add([PSCustomObject]@{
                        Type       = 'TruncatedFile'
                        Severity   = 'Medium'
                        File       = $f.Path
                        Detail     = "$($f.FileName) is $($f.Size) bytes here; backup '$otherName' has $($match.Size) bytes for same SN/filename"
                        Suggestion = "Use larger version from '$otherName' when building golden archive"
                    })
                    break   # Report once per file
                }
            }
        }
    }

    # ── 4. P-Series: FILES.SEQ must be ≥ TRANSMITFILE.SEQ line count ──────
    foreach ($sn in $devices.Keys) {
        $psFiles = $devices[$sn].PSeriesFiles
        $fsEntry = $psFiles | Where-Object { $_.FileName -eq 'FILES.SEQ' }     | Select-Object -First 1
        $txEntry = $psFiles | Where-Object { $_.FileName -eq 'TRANSMITFILE.SEQ' } | Select-Object -First 1
        $fsPath  = if ($fsEntry) { $fsEntry.Path } else { $null }
        $txPath  = if ($txEntry) { $txEntry.Path } else { $null }
        if ($fsPath -and $txPath) {
            $fs = Read-FilesSeq -Path $fsPath
            $tx = Read-FilesSeq -Path $txPath
            if ($fs -and $tx -and $tx.LineCount -gt $fs.LineCount) {
                $anomalies.Add([PSCustomObject]@{
                    Type       = 'PSeriesConsistency'
                    Severity   = 'Medium'
                    File       = $fsPath
                    Detail     = "FILES.SEQ ($($fs.LineCount) entries) has fewer entries than TRANSMITFILE.SEQ ($($tx.LineCount)) for device $sn; FILES.SEQ must be a superset"
                    Suggestion = "FILES.SEQ may have been partially copied"
                })
            }
        }
    }

    # ── 5. Size regression on monotonically growing P-Series files ─────────
    # Report when another backup has a larger version of the same file for the same device.
    # .NNN variant backups of the current backup (e.g. "12.1.2025.002" when current is
    # "12.1.2025") are expected to be larger — skip them to avoid false positives.
    $growingFiles      = @('FILES.SEQ', 'TRANSMITFILE.SEQ', 'SL_SAPPHIRE.json')
    $nnnVariantPattern = '^' + [regex]::Escape($backupName) + '\.\d{3}$'
    foreach ($sn in $devices.Keys) {
        $psFiles = $devices[$sn].PSeriesFiles
        foreach ($gf in $growingFiles) {
            $thisEntry = $psFiles | Where-Object { $_.FileName -eq $gf } | Select-Object -First 1
            if (-not $thisEntry) { continue }
            # Find the backup with the MAXIMUM file size, ignoring .NNN variants of this backup
            $maxEntry      = $null
            $maxBackupName = $null
            foreach ($otherName in $TOC.Backups.Keys) {
                if ($otherName -eq $backupName)          { continue }
                if ($otherName -match $nnnVariantPattern) { continue }   # skip variants of current
                $other = $TOC.Backups[$otherName]
                if (-not $other.Devices.ContainsKey($sn)) { continue }
                $otherEntry = $other.Devices[$sn].PSeriesFiles |
                              Where-Object { $_.FileName -eq $gf } |
                              Select-Object -First 1
                if ($otherEntry -and $otherEntry.Size -gt $thisEntry.Size) {
                    if (-not $maxEntry -or $otherEntry.Size -gt $maxEntry.Size) {
                        $maxEntry      = $otherEntry
                        $maxBackupName = $otherName
                    }
                }
            }
            if ($maxEntry) {
                $contaminNote = if ($TOC.Backups[$maxBackupName].Integrity -eq 'Contaminated') { ' [contaminated]' } else { '' }
                $anomalies.Add([PSCustomObject]@{
                    Type       = 'SizeRegression'
                    Severity   = 'Medium'
                    File       = $thisEntry.Path
                    Detail     = "$gf is $($thisEntry.Size) bytes (device $sn); backup '$maxBackupName'$contaminNote has a larger version at $($maxEntry.Size) bytes"
                    Suggestion = "A larger version of $gf exists in another backup — this copy may be from an earlier date or may be truncated"
                })
            }
        }
    }

    $isContaminated = @($anomalies | Where-Object { $_.Type -eq 'Contamination' }).Count -gt 0
    return [PSCustomObject]@{
        Integrity = if ($isContaminated) { 'Contaminated' } else { 'Clean' }
        Anomalies = $anomalies.ToArray()
    }
}

#endregion

#region ── Get-DeviceTimeline ────────────────────────────────────────────────

function Get-DeviceTimeline {
    <#
    .SYNOPSIS
        Return a chronological view of a single device across all backups.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TOC,
        [Parameter(Mandatory)][string]$DeviceSerial
    )

    if (-not $TOC.Devices.ContainsKey($DeviceSerial)) { return @() }

    $timeline = [System.Collections.Generic.List[object]]::new()
    foreach ($bName in ($TOC.Backups.Keys | Sort-Object)) {
        $b = $TOC.Backups[$bName]
        if (-not $b.Devices.ContainsKey($DeviceSerial)) { continue }
        $dev = $b.Devices[$DeviceSerial]
        $timeline.Add([PSCustomObject]@{
            BackupName   = $bName
            BackupPath   = $b.Path
            EarliestDate = $dev.EarliestDate
            LatestDate   = $dev.LatestDate
            FileCount    = $dev.FileCount
            Integrity    = $b.Integrity
            IsActive     = $dev.IsActiveDevice
        })
    }
    return $timeline.ToArray()
}

#endregion

#region ── Write-ContaminationReadme ─────────────────────────────────────────

function Write-ContaminationReadme {
    <#
    .SYNOPSIS
        Generate README.md inside a backup folder documenting contamination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][array]$Anomalies,
        [Parameter(Mandatory)][PSCustomObject]$TOC
    )

    $readmePath    = Join-Path $BackupPath 'README.md'
    $contamination = @($Anomalies | Where-Object { $_.Type -eq 'Contamination' })
    $others        = @($Anomalies | Where-Object { $_.Type -ne 'Contamination' })

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Backup Contamination Report')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> **Auto-generated by VentBackupManager** — do not edit manually.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Backup path**: ``$BackupPath``  ")
    [void]$sb.AppendLine("**Report date**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine('')

    if ($contamination.Count -eq 0) {
        [void]$sb.AppendLine('## Result: No contamination detected')
    } else {
        [void]$sb.AppendLine("## Result: $($contamination.Count) contaminated file(s) detected")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('The following files have an EDF header device serial number (SN) that does not')
        [void]$sb.AppendLine('match the expected device roster for this backup (from `P-Series/` directory).')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| File | Detail | Suggestion |')
        [void]$sb.AppendLine('|------|--------|------------|')
        foreach ($a in $contamination) {
            $fname = [System.IO.Path]::GetFileName($a.File)
            $det   = $a.Detail    -replace '\|', '\|'
            $sug   = $a.Suggestion -replace '\|', '\|'
            [void]$sb.AppendLine("| ``$fname`` | $det | $sug |")
        }
    }

    if ($others.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("## Other Anomalies ($($others.Count))")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Type | Severity | File | Detail |')
        [void]$sb.AppendLine('|------|----------|------|--------|')
        foreach ($a in $others) {
            $fname = [System.IO.Path]::GetFileName($a.File)
            $det   = $a.Detail -replace '\|', '\|'
            [void]$sb.AppendLine("| $($a.Type) | $($a.Severity) | ``$fname`` | $det |")
        }
    }

    # Where clean copies can be found for contaminated files
    if ($contamination.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('## Clean Sources in Other Backups')
        [void]$sb.AppendLine('')
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($a in $contamination) {
            $fname = [System.IO.Path]::GetFileName($a.File)
            if ($seen.Contains($fname)) { continue }
            [void]$seen.Add($fname)
            $cleanSources = foreach ($bName in $TOC.Backups.Keys) {
                $b = $TOC.Backups[$bName]
                if ($b.Integrity -ne 'Clean') { continue }
                foreach ($sn in $b.Devices.Keys) {
                    $match = $b.Devices[$sn].TrilogyFiles | Where-Object { $_.FileName -eq $fname }
                    if ($match) { "  - Backup ``$bName`` (SN: $sn, size: $($match.Size) bytes)" }
                }
            }
            if ($cleanSources) {
                [void]$sb.AppendLine("### ``$fname``")
                foreach ($cs in $cleanSources) { [void]$sb.AppendLine($cs) }
                [void]$sb.AppendLine('')
            }
        }
    }

    Set-Content -LiteralPath $readmePath -Value $sb.ToString() -Encoding UTF8
    Write-Host "Contamination report written: $readmePath"
}

#endregion

#region ── Show-TOC ──────────────────────────────────────────────────────────

function Show-TOC {
    <#
    .SYNOPSIS
        Render the Table of Contents to the console.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$TOC)

    $w = 70
    Write-Host ''
    Write-Host ('═' * $w) -ForegroundColor Cyan
    Write-Host '  VENT BACKUP MANAGER — TABLE OF CONTENTS' -ForegroundColor Cyan
    Write-Host ('═' * $w) -ForegroundColor Cyan

    # ── Backup summary table ───────────────────────────────────────────────
    Write-Host ''
    Write-Host 'BACKUPS' -ForegroundColor Yellow
    Write-Host ('-' * $w)
    '{0,-26} {1,-13} {2}' -f 'Backup Folder', 'Integrity', 'Devices' | Write-Host -ForegroundColor DarkGray
    Write-Host ('-' * $w)
    foreach ($bName in ($TOC.Backups.Keys | Sort-Object)) {
        $b     = $TOC.Backups[$bName]
        $color = switch ($b.Integrity) {
            'Contaminated' { 'Red'   }
            'Clean'        { 'Green' }
            default        { 'Gray'  }
        }
        $snList = ($b.Devices.Keys | Sort-Object) -join ', '
        if ($snList.Length -gt 30) { $snList = $snList.Substring(0,27) + '...' }
        '{0,-26} {1,-13} {2}' -f $bName, $b.Integrity, $snList | Write-Host -ForegroundColor $color
    }

    # ── Per-device timeline ────────────────────────────────────────────────
    Write-Host ''
    Write-Host 'DEVICE TIMELINES' -ForegroundColor Yellow
    Write-Host ('-' * $w)
    foreach ($sn in ($TOC.Devices.Keys | Sort-Object)) {
        $dev   = $TOC.Devices[$sn]
        $model = if ($dev.Model) { "  [$($dev.Model)]" } else { '' }
        Write-Host "  $sn$model" -ForegroundColor Cyan
        Write-Host "    Range   : $($dev.OverallEarliest) → $($dev.OverallLatest)"
        Write-Host "    Files   : $($dev.TotalUniqueFiles) unique filenames"
        Write-Host "    Backups : $($dev.BackupPresence -join ', ')"
        Write-Host ''
    }

    # ── Contamination warnings ─────────────────────────────────────────────
    $contaminated = @($TOC.Backups.Values | Where-Object { $_.Integrity -eq 'Contaminated' })
    if ($contaminated.Count -gt 0) {
        Write-Host ('!' * $w) -ForegroundColor Red
        Write-Host '  CONTAMINATION WARNINGS' -ForegroundColor Red
        Write-Host ('!' * $w) -ForegroundColor Red
        foreach ($b in $contaminated) {
            $cnt = ($b.Anomalies | Where-Object { $_.Type -eq 'Contamination' }).Count
            Write-Host "  Backup '$($b.Name)': $cnt contaminated file(s)" -ForegroundColor Red
            # Group by unique detail text so each distinct reason appears once with its file count
            $groups = @($b.Anomalies | Where-Object { $_.Type -eq 'Contamination' } |
                        Group-Object Detail | Sort-Object { -$_.Count })
            $shownFiles = 0
            foreach ($grp in $groups | Select-Object -First 3) {
                $countNote = if ($grp.Count -gt 1) { " ($($grp.Count) files)" } else { '' }
                Write-Host "    • $($grp.Name)$countNote" -ForegroundColor Red
                $shownFiles += $grp.Count
            }
            if ($cnt -gt $shownFiles) {
                Write-Host "    ... and $($cnt - $shownFiles) more. Run Analyze to generate full report." -ForegroundColor Red
            }
        }
        Write-Host ''
    }
}

#endregion

#region ── Find-SplitSD ─────────────────────────────────────────────────────

function Find-SplitSD {
    <#
    .SYNOPSIS
        Analyse TOC to detect device SNs that appear to have come from two or more
        separate SD cards (non-overlapping date ranges for the same SN).
    .PARAMETER TOC
        Full TOC from Get-BackupTOC.
    .PARAMETER SplitGapMonths
        Minimum gap (in months) between two clean-backup date ranges to consider a
        card swap rather than a tip-file boundary.  Default: 2.
    .PARAMETER BlowerHoursJumpThreshold
        Minimum BlowerHours jump (in 10th-hour units) between the latest value in
        the earlier span and the earliest value in the later span to confirm a card
        swap.  Default: 1440 (= 144 hours = 6 days worth of continuous use).
        If PP JSON data is unavailable the gap-only heuristic is used with a warning.
    .OUTPUTS
        Hashtable of SN -> @{ SplitSD=$true; Spans=@( @{BackupNames=@(); Earliest=""; Latest="" } ) }
        Only SNs where a split is detected are included.  All others are absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TOC,
        [int]$SplitGapMonths            = 2,
        [int]$BlowerHoursJumpThreshold  = 1440
    )

    # Helper: convert "YYYY-MM" to a total-months integer for arithmetic
    function _ToMonths([string]$dateStr) {
        if (-not $dateStr -or $dateStr.Length -lt 7) { return -1 }
        return ([int]$dateStr.Substring(0,4)) * 12 + ([int]$dateStr.Substring(5,2)) - 1
    }

    $result = @{}

    $cleanNames = @($TOC.Backups.Keys | Where-Object { $TOC.Backups[$_].Integrity -ne 'Contaminated' })

    foreach ($sn in $TOC.Devices.Keys) {
        # Collect (BackupName, Earliest, Latest) tuples from clean backups only
        $spans = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($bName in $cleanNames) {
            $b = $TOC.Backups[$bName]
            if (-not $b.Devices.ContainsKey($sn)) { continue }
            $dev = $b.Devices[$sn]
            if (-not $dev.EarliestDate -or -not $dev.LatestDate) { continue }
            $spans.Add(@{
                BackupName = $bName
                Earliest   = $dev.EarliestDate
                Latest     = $dev.LatestDate
            })
        }

        if ($spans.Count -lt 2) { continue }   # Need at least 2 clean backups to detect a split

        # Sort by Earliest date
        $sorted = @($spans | Sort-Object { $_['Earliest'] })

        # Walk sorted list, look for gaps > SplitGapMonths
        $foundSplit   = $false
        $groupedSpans = [System.Collections.Generic.List[hashtable]]::new()
        $curGroup     = @{
            BackupNames = [System.Collections.Generic.List[string]]::new()
            Earliest    = $sorted[0]['Earliest']
            Latest      = $sorted[0]['Latest']
        }
        $curGroup.BackupNames.Add($sorted[0]['BackupName'])

        for ($idx = 1; $idx -lt $sorted.Count; $idx++) {
            $prev = $sorted[$idx - 1]
            $curr = $sorted[$idx]

            $gapMonths = (_ToMonths $curr['Earliest']) - (_ToMonths $prev['Latest'])

            if ($gapMonths -gt $SplitGapMonths) {
                # Potential split — check BlowerHours if PP JSON data is available
                $splitConfirmed = $true   # Default true; PP JSON can override

                # Collect latest BlowerHours from earlier span backups
                $prevLatestBH    = $null
                foreach ($bn in $curGroup.BackupNames) {
                    $bk = $TOC.Backups[$bn]
                    if (-not $bk.Devices.ContainsKey($sn)) { continue }
                    $ppFiles = @($bk.Devices[$sn].PSeriesFiles | Where-Object { $_.FileName -match '^PP_' } |
                    Sort-Object { $ppTmp = Read-PpJson -Path $_.Path; if ($ppTmp) { $ppTmp.TimeStamp } else { 0 } } -Descending)
                    foreach ($ppf in $ppFiles) {
                        $ppData = Read-PpJson -Path $ppf.Path
                        if ($ppData -and $ppData.PSObject.Properties['BlowerHours']) {
                            $bh = [int]$ppData.BlowerHours
                            if ($null -eq $prevLatestBH -or $bh -gt $prevLatestBH) { $prevLatestBH = $bh }
                            break
                        }
                    }
                }

                # Collect earliest BlowerHours from the current (later) backup
                $currEarliestBH = $null
                $bk = $TOC.Backups[$curr['BackupName']]
                if ($bk.Devices.ContainsKey($sn)) {
                    $ppFiles = @($bk.Devices[$sn].PSeriesFiles | Where-Object { $_.FileName -match '^PP_' } |
                    Sort-Object { $ppTmp = Read-PpJson -Path $_.Path; if ($ppTmp) { $ppTmp.TimeStamp } else { 0 } })
                    foreach ($ppf in $ppFiles) {
                        $ppData = Read-PpJson -Path $ppf.Path
                        if ($ppData -and $ppData.PSObject.Properties['BlowerHours']) {
                            $currEarliestBH = [int]$ppData.BlowerHours
                            break
                        }
                    }
                }

                if ($null -ne $prevLatestBH -and $null -ne $currEarliestBH) {
                    # If BlowerHours are continuous (later card picks up where earlier left off)
                    # the jump should be small (proportional to the gap in calendar time).
                    # A large jump (more than threshold) means a different card started fresh.
                    $bhJump = $currEarliestBH - $prevLatestBH
                    if ([Math]::Abs($bhJump) -lt $BlowerHoursJumpThreshold) {
                        # BlowerHours are continuous — not a card swap, just a long offline period
                        $splitConfirmed = $false
                    }
                } else {
                    # No PP JSON data — emit a warning but still flag based on date gap
                    Write-Warning "Find-SplitSD: No PP JSON BlowerHours data for SN '$sn' — using date gap heuristic only (less reliable)"
                }

                if ($splitConfirmed) {
                    $foundSplit = $true
                    # Close current group and save it
                    $groupedSpans.Add(@{
                        BackupNames = $curGroup.BackupNames.ToArray()
                        Earliest    = $curGroup.Earliest
                        Latest      = $curGroup.Latest
                    })
                    # Start new group
                    $curGroup = @{
                        BackupNames = [System.Collections.Generic.List[string]]::new()
                        Earliest    = $curr['Earliest']
                        Latest      = $curr['Latest']
                    }
                    $curGroup.BackupNames.Add($curr['BackupName'])
                    continue
                }
            }

            # Extend current group
            $curGroup.BackupNames.Add($curr['BackupName'])
            if ($curr['Latest'] -gt $curGroup.Latest) { $curGroup.Latest = $curr['Latest'] }
        }

        if ($foundSplit) {
            # Save the last group
            $groupedSpans.Add(@{
                BackupNames = $curGroup.BackupNames.ToArray()
                Earliest    = $curGroup.Earliest
                Latest      = $curGroup.Latest
            })

            $result[$sn] = [PSCustomObject]@{
                SplitSD = $true
                Spans   = $groupedSpans.ToArray()
            }

            # Annotate the TOC device summary
            if ($TOC.Devices.ContainsKey($sn)) {
                $tocDev = $TOC.Devices[$sn]
                # Add SplitSD annotation as a note property (safe even if property already exists)
                if (-not $tocDev.PSObject.Properties['SplitSD']) {
                    $tocDev | Add-Member -NotePropertyName SplitSD -NotePropertyValue $true
                    $tocDev | Add-Member -NotePropertyName SplitSDSpans -NotePropertyValue $groupedSpans.ToArray()
                } else {
                    $tocDev.SplitSD      = $true
                    $tocDev.SplitSDSpans = $groupedSpans.ToArray()
                }
            }
        }
    }

    return $result
}

#endregion

#region ── Get-DeviceGaps ────────────────────────────────────────────────────

function Get-DeviceGaps {
    <#
    .SYNOPSIS
        Compute the covered months and chronological gaps for one device across all backups.
    .PARAMETER TOC
        Full TOC from Get-BackupTOC.
    .PARAMETER DeviceSerial
        The device SN to analyse.
    .PARAMETER DebounceWeeks
        Gaps whose approximate duration in weeks is <= this value are flagged IsDebounced.
        Each missing month is treated as 4 weeks for comparison purposes.
        Default: 4 (debounce single-month gaps).
        Set to 0 to surface every gap regardless of size.
    .OUTPUTS
        PSCustomObject:
          DeviceSerial       string
          OverallEarliest    'YYYY-MM' or $null
          OverallLatest      'YYYY-MM' or $null
          CoveredMonths      string[]   sorted list of 'YYYY-MM' months with AD/DD data
          Gaps               PSCustomObject[]  {
                               Start, End, DurationMonths, DurationWeeks,
                               IsDebounced, Months }
          ContaminatedMonths string[]   months covered only by contaminated backups
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TOC,
        [Parameter(Mandatory)][string]$DeviceSerial,
        [int]$DebounceWeeks = 4
    )

    # Internal helper: build a safe YYYY-MM key without using format specifiers that
    # require the argument to be an integer type (avoids FormatException if the stored
    # value has been boxed as a different numeric type by PowerShell's type system).
    function _MonthKey([int]$yr, [int]$mo) {
        [string]$yr + '-' + ([string]$mo).PadLeft(2,'0')
    }

    # Collect months with AD/DD coverage, separated into clean vs contaminated-only
    $cleanMonths      = [System.Collections.Generic.HashSet[string]]::new()
    $contamOnlyMonths = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($bName in $TOC.Backups.Keys) {
        $b = $TOC.Backups[$bName]
        if (-not $b.Devices.ContainsKey($DeviceSerial)) { continue }
        $dev     = $b.Devices[$DeviceSerial]
        $isClean = ($b.Integrity -ne 'Contaminated')
        foreach ($f in $dev.TrilogyFiles) {
            if ($f.FileType -notin @('AD', 'DD')) { continue }
            if ($f.IsDaily)                        { continue }
            if (-not $f.Year -or -not $f.Month)   { continue }
            $key = _MonthKey ([int]$f.Year) ([int]$f.Month)
            if ($isClean) {
                [void]$cleanMonths.Add($key)
                [void]$contamOnlyMonths.Remove($key)   # clean supersedes
            } elseif (-not $cleanMonths.Contains($key)) {
                [void]$contamOnlyMonths.Add($key)
            }
        }
    }

    $allCovered = [System.Collections.Generic.HashSet[string]]::new($cleanMonths)
    foreach ($m in $contamOnlyMonths) { [void]$allCovered.Add($m) }

    if ($allCovered.Count -eq 0) {
        return [PSCustomObject]@{
            DeviceSerial       = $DeviceSerial
            OverallEarliest    = $null
            OverallLatest      = $null
            CoveredMonths      = @()
            Gaps               = @()
            ContaminatedMonths = @()
        }
    }

    $sortedCovered = @($allCovered | Sort-Object)
    $earliest = $sortedCovered[0]
    $latest   = $sortedCovered[-1]

    # Enumerate every month within [earliest, latest]
    $sy = [int]$earliest.Substring(0,4); $sm = [int]$earliest.Substring(5,2)
    $ey = [int]$latest.Substring(0,4);   $em = [int]$latest.Substring(5,2)
    $allMonths = [System.Collections.Generic.List[string]]::new()
    $cy = $sy; $cm = $sm
    while (($cy * 12 + $cm) -le ($ey * 12 + $em)) {
        $allMonths.Add((_MonthKey $cy $cm))
        $cm++
        if ($cm -gt 12) { $cm = 1; $cy++ }
    }

    # Find contiguous gap runs
    $gaps     = [System.Collections.Generic.List[object]]::new()
    $gapStart = $null
    $gapBuf   = [System.Collections.Generic.List[string]]::new()
    foreach ($month in $allMonths) {
        if (-not $allCovered.Contains($month)) {
            if (-not $gapStart) { $gapStart = $month }
            $gapBuf.Add($month)
        } else {
            if ($gapStart) {
                $dur      = $gapBuf.Count
                $durWeeks = $dur * 4        # 4 weeks per month (approximate)
                $gaps.Add([PSCustomObject]@{
                    Start          = $gapStart
                    End            = $gapBuf[$gapBuf.Count - 1]
                    DurationMonths = $dur
                    DurationWeeks  = $durWeeks
                    IsDebounced    = ($durWeeks -le $DebounceWeeks)
                    Months         = $gapBuf.ToArray()
                })
                $gapStart = $null
                $gapBuf   = [System.Collections.Generic.List[string]]::new()
            }
        }
    }
    # Flush any trailing gap at the end of the covered range
    if ($gapStart) {
        $dur      = $gapBuf.Count
        $durWeeks = $dur * 4
        $gaps.Add([PSCustomObject]@{
            Start          = $gapStart
            End            = $gapBuf[$gapBuf.Count - 1]
            DurationMonths = $dur
            DurationWeeks  = $durWeeks
            IsDebounced    = ($durWeeks -le $DebounceWeeks)
            Months         = $gapBuf.ToArray()
        })
    }

    return [PSCustomObject]@{
        DeviceSerial       = $DeviceSerial
        OverallEarliest    = $earliest
        OverallLatest      = $latest
        CoveredMonths      = $sortedCovered
        Gaps               = $gaps.ToArray()
        ContaminatedMonths = @($contamOnlyMonths | Sort-Object)
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-BackupInventory',
    'Get-BackupTOC',
    'Test-BackupIntegrity',
    'Get-DeviceTimeline',
    'Get-DeviceGaps',
    'Write-ContaminationReadme',
    'Show-TOC',
    'Find-SplitSD'
)
