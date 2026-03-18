# VBM-GoldenArchive.psm1 — Build and verify golden archives
# See DESIGN.md for algorithm details and manifest.json schema.

Import-Module (Join-Path $PSScriptRoot 'VBM-Parsers.psm1') -Force

#region ── Internal helpers ──────────────────────────────────────────────────

# Sort backup names to determine chronological order by latest device data date.
# Returns backup names sorted oldest-first.
function _SortBackupsByDate {
    param([hashtable]$Backups, [string]$DeviceSN)
    return $Backups.Keys | Sort-Object {
        $b = $Backups[$_]
        if ($b.Devices.ContainsKey($DeviceSN) -and $b.Devices[$DeviceSN].LatestDate) {
            $b.Devices[$DeviceSN].LatestDate
        } else { '0000-00' }
    }
}

# Collect all Trilogy files for a device across the given (clean) backups,
# grouped by filename. Returns hashtable: filename -> @{Path,Size,SN}
function _GatherTrilogyFiles {
    param([hashtable]$Backups, [string]$DeviceSN, [string[]]$CleanBackupNames)
    $groups = @{}  # filename -> best-so-far {Path, Size, SN}
    foreach ($bName in $CleanBackupNames) {
        $b = $Backups[$bName]
        if (-not $b.Devices.ContainsKey($DeviceSN)) { continue }
        foreach ($f in $b.Devices[$DeviceSN].TrilogyFiles) {
            # Edge case 14: verify the file belongs to the right device via EDF header
            if ($f.FileName -match '\.edf$') {
                $headerSN = Get-EdfDeviceSerial -Path $f.Path
                if ($headerSN -and $headerSN -ne $DeviceSN) { continue }  # Skip wrong-device file
            }
            $cur = $groups[$f.FileName]
            if (-not $cur -or $f.Size -gt $cur.Size) {
                $groups[$f.FileName] = [PSCustomObject]@{
                    Path     = $f.Path
                    Size     = $f.Size
                    SN       = $DeviceSN
                    BackupName = $bName
                }
            }
        }
    }
    return $groups
}

# Collect P-Series files for a device.
# - Steering files: most recent clean backup wins (they grow monotonically)
# - Ring buffer (P0-P7): all unique files from all backups
function _GatherPSeriesFiles {
    param([hashtable]$Backups, [string]$DeviceSN, [string[]]$SortedCleanNames)
    $steeringNames = @('prop.txt','FILES.SEQ','TRANSMITFILE.SEQ','SL_SAPPHIRE.json')
    $steering      = @{}   # FileName -> {Path, Size}
    $ringBuf       = @{}   # RelativePath-within-device-dir -> {Path, Size}

    foreach ($bName in $SortedCleanNames) {
        $b = $Backups[$bName]
        if (-not $b.Devices.ContainsKey($DeviceSN)) { continue }

        foreach ($pf in $b.Devices[$DeviceSN].PSeriesFiles) {
            $fn = $pf.FileName
            $rel = $pf.RelativePath  # relative to backup root

            # Determine if this is a ring-buffer file (lives under P0-P7)
            $isRing = $rel -match '[/\\]P[0-7][/\\]'

            if ($isRing) {
                # Ring buffer: collect ALL unique files from all backups (edge case 15).
                # Where the same ring-slot filename exists in multiple backups,
                # keep the largest (most complete) copy — same "largest wins" logic
                # as Trilogy files (edge case 14).
                # Strip leading "P-Series\{SN}\" from $rel to get a key relative to the device dir.
                # Use ^ anchor because $rel never has a leading slash (it is built with TrimStart).
                $ringKey = ($rel -replace '^P-Series[/\\][^/\\]+[/\\]', '') -replace '\\', '/'
                $cur = $ringBuf[$ringKey]
                if (-not $cur -or $pf.Size -gt $cur.Size) {
                    $ringBuf[$ringKey] = [PSCustomObject]@{
                        Path       = $pf.Path
                        Size       = $pf.Size
                        RingKey    = $ringKey
                        BackupName = $bName
                    }
                }
            } elseif ($steeringNames -contains $fn) {
                # Steering: larger (more complete) wins — chronologically last due to sorted order
                $cur = $steering[$fn]
                if (-not $cur -or $pf.Size -gt $cur.Size) {
                    $steering[$fn] = [PSCustomObject]@{
                        Path       = $pf.Path
                        Size       = $pf.Size
                        BackupName = $bName
                    }
                }
            }
            # Other files in P-Series/{SN}/ root (e.g. additional metadata) — take largest
            else {
                $cur = $steering[$fn]
                if (-not $cur -or $pf.Size -gt $cur.Size) {
                    $steering[$fn] = [PSCustomObject]@{
                        Path       = $pf.Path
                        Size       = $pf.Size
                        BackupName = $bName
                    }
                }
            }
        }
    }
    return @{ Steering = $steering; RingBuf = $ringBuf }
}

function _CopyFile {
    param([string]$Source, [string]$Dest)
    $dir = [System.IO.Path]::GetDirectoryName($Dest)
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Copy-Item -LiteralPath $Source -Destination $Dest -Force
}

function _WriteManifest {
    param([string]$GoldenPath, [hashtable]$ManifestData)
    $json = $ManifestData | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $GoldenPath 'manifest.json') -Value $json -Encoding UTF8
}

function _BuildDeviceGolden {
    param(
        [string]$DeviceSN,
        [hashtable]$Backups,
        [string]$GoldenPath,
        [string[]]$CleanBackupNames
    )
    # Sort backups oldest-first so ring buffer key collisions prefer newer data
    $sortedNames = _SortBackupsByDate -Backups $Backups -DeviceSN $DeviceSN

    # Trilogy files
    $triGroups  = _GatherTrilogyFiles -Backups $Backups -DeviceSN $DeviceSN -CleanBackupNames $CleanBackupNames
    $trilogyDst = Join-Path $GoldenPath "$DeviceSN\Trilogy"

    $triHashes   = @{}
    $sourceFolderSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($fname in $triGroups.Keys) {
        $best = $triGroups[$fname]
        $dest = Join-Path $trilogyDst $fname
        _CopyFile -Source $best.Path -Destination $dest
        $triHashes["Trilogy/$fname"] = (Get-FileHash -Path $dest -Algorithm MD5).Hash
        [void]$sourceFolderSet.Add($best.BackupName)
    }

    # P-Series files
    $psData      = _GatherPSeriesFiles -Backups $Backups -DeviceSN $DeviceSN -SortedCleanNames $sortedNames
    $psDst       = Join-Path $GoldenPath "$DeviceSN\P-Series\$DeviceSN"
    $psHashes    = @{}

    # Steering files
    foreach ($fn in $psData.Steering.Keys) {
        $src  = $psData.Steering[$fn].Path
        $dest = Join-Path $psDst $fn
        _CopyFile -Source $src -Destination $dest
        $psHashes["P-Series/$DeviceSN/$fn"] = (Get-FileHash -Path $dest -Algorithm MD5).Hash
        [void]$sourceFolderSet.Add($psData.Steering[$fn].BackupName)
    }

    # Ring buffer files
    foreach ($rk in $psData.RingBuf.Keys) {
        $src  = $psData.RingBuf[$rk].Path
        # rk is like "P3/PP_20240823_000.json"
        $dest = Join-Path $psDst $rk
        _CopyFile -Source $src -Destination $dest
        $psHashes["P-Series/$DeviceSN/$rk"] = (Get-FileHash -Path $dest -Algorithm MD5).Hash
        [void]$sourceFolderSet.Add($psData.RingBuf[$rk].BackupName)
    }

    # last.txt — point to this device
    $lastTxtDst  = Join-Path $GoldenPath "$DeviceSN\P-Series\last.txt"
    $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($lastTxtDst)) -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $lastTxtDst -Value $DeviceSN -Encoding UTF8

    # Aggregate date range, model, and P-Series date range from all backups that observed this device
    $earliest = $null; $latest = $null; $model = $null; $pt = $null; $fw = $null
    $psEarliest = $null; $psLatest = $null
    foreach ($bn in $Backups.Keys) {
        $b = $Backups[$bn]
        if (-not $b.Devices.ContainsKey($DeviceSN)) { continue }
        $dev = $b.Devices[$DeviceSN]
        if ($dev.EarliestDate -and (-not $earliest -or $dev.EarliestDate -lt $earliest)) { $earliest = $dev.EarliestDate }
        if ($dev.LatestDate   -and (-not $latest   -or $dev.LatestDate   -gt $latest))   { $latest   = $dev.LatestDate }
        if (-not $model -and $dev.Model)       { $model = $dev.Model }
        if (-not $pt    -and $dev.ProductType) { $pt    = $dev.ProductType }
        if (-not $fw    -and $dev.Firmware)    { $fw    = $dev.Firmware }

        # P-Series date range from PP JSON timestamps
        foreach ($pf in $dev.PSeriesFiles) {
            if ($pf.FileName -match '^PP_') {
                $ppDate = Get-PpJsonDateInfo -Path $pf.Path
                if ($ppDate) {
                    $ds = '{0:D4}-{1:D2}-{2:D2}' -f $ppDate.Year, $ppDate.Month, $ppDate.Day
                    if (-not $psEarliest -or $ds -lt $psEarliest) { $psEarliest = $ds }
                    if (-not $psLatest   -or $ds -gt $psLatest)   { $psLatest   = $ds }
                }
            }
        }
    }

    $allHashes = $triHashes + $psHashes

    return [PSCustomObject]@{
        SN               = $DeviceSN
        Model            = $model
        ProductType      = $pt
        Firmware         = $fw
        TrilogyRange     = @{ Earliest = $earliest;   Latest = $latest   }
        PSeriesRange     = @{ Earliest = $psEarliest; Latest = $psLatest }
        TrilogyFileCount = $triGroups.Count
        PSeriesFileCount = $psData.Steering.Count + $psData.RingBuf.Count
        SourceFolders    = $sourceFolderSet.ToArray()
        FileHashes       = $allHashes
        SplitSD          = $false   # default; caller may override from TOC annotation
        SplitSDSpans     = $null
    }
}

#endregion

#region ── New-GoldenArchive ─────────────────────────────────────────────────

function New-GoldenArchive {
    <#
    .SYNOPSIS
        Build the first golden archive from all clean backup data.
    .PARAMETER TOC
        TOC object from Get-BackupTOC (must have integrity already assessed).
    .PARAMETER GoldenRoot
        Parent directory where the golden folder will be created.
    .PARAMETER Devices
        Optional array of SNs to include. Default: all devices in TOC.
    .PARAMETER ForceDevices
        Override: use exactly this list of SNs, bypassing Devices and auto-detection.
        Must be combined with -ForceReason for audit trail.
    .PARAMETER ForceReason
        Free-text reason recorded in manifest.json when -ForceDevices is supplied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TOC,
        [Parameter(Mandatory)][string]$GoldenRoot,
        [string[]]$Devices,
        [string[]]$ForceDevices,
        [string]$ForceReason
    )

    $date       = Get-Date -Format 'yyyy-MM-dd'
    $goldenPath = Join-Path $GoldenRoot "_golden_$date"
    if (Test-Path $goldenPath) {
        # Append sequence suffix if folder already exists
        $seq = 1
        while (Test-Path "$goldenPath.$seq") { $seq++ }
        $goldenPath = "$goldenPath.$seq"
    }
    $null = New-Item -ItemType Directory -Path $goldenPath -Force

    $cleanNames = @($TOC.Backups.Keys | Where-Object { $TOC.Backups[$_].Integrity -ne 'Contaminated' })

    # ForceDevices takes precedence over Devices and the algorithm's default
    $targetSNs = if ($ForceDevices -and $ForceDevices.Count -gt 0) {
        Write-Host "  ForceDevices override active: $($ForceDevices -join ', ')" -ForegroundColor Yellow
        $ForceDevices
    } elseif ($Devices -and $Devices.Count -gt 0) {
        $Devices
    } else {
        @($TOC.Devices.Keys)
    }

    # Validate: warn if any forced SN does not appear in the TOC
    foreach ($fsn in $targetSNs) {
        if (-not $TOC.Devices.ContainsKey($fsn)) {
            Write-Warning "ForceDevices: SN '$fsn' not found in TOC — it will produce an empty device entry in the golden."
        }
    }

    $manifestDevices = @{}
    foreach ($sn in $targetSNs) {
        Write-Host "  Building golden for $sn ..." -ForegroundColor Cyan
        $devResult = _BuildDeviceGolden -DeviceSN $sn -Backups $TOC.Backups -GoldenPath $goldenPath -CleanBackupNames $cleanNames

        # Propagate SplitSD annotation from TOC (set by Detect-SplitSD if called beforehand)
        $tocDev = if ($TOC.Devices.ContainsKey($sn)) { $TOC.Devices[$sn] } else { $null }
        $splitSD    = $tocDev -and $tocDev.PSObject.Properties['SplitSD'] -and $tocDev.SplitSD
        $splitSpans = if ($splitSD -and $tocDev.PSObject.Properties['SplitSDSpans']) { $tocDev.SplitSDSpans } else { $null }

        $manifestDevices[$sn] = @{
            model            = $devResult.Model
            productType      = $devResult.ProductType
            firmware         = $devResult.Firmware
            trilogyDateRange = $devResult.TrilogyRange
            pSeriesDateRange = $devResult.PSeriesRange
            trilogyFileCount = $devResult.TrilogyFileCount
            pSeriesFileCount = $devResult.PSeriesFileCount
            sourceFolders    = $devResult.SourceFolders
            splitSD          = $splitSD
            splitSDSpans     = $splitSpans
            fileHashes       = $devResult.FileHashes
        }
    }

    $manifest = @{
        version             = 1
        created             = (Get-Date -Format 'o')
        goldenSequence      = 1
        previousGolden      = $null
        backupRoot          = (Split-Path $goldenPath -Parent)
        forcedDevicesReason = if ($ForceDevices -and $ForceDevices.Count -gt 0) {
            if ($ForceReason) { $ForceReason } else { 'Devices forced by operator (no reason provided)' }
        } else { $null }
        devices             = $manifestDevices
    }
    _WriteManifest -GoldenPath $goldenPath -ManifestData $manifest

    # README for the golden archive
    _WriteGoldenReadme -GoldenPath $goldenPath -Devices $targetSNs -Sequence 1

    Write-Host ''
    Write-Host "Golden archive created: $goldenPath" -ForegroundColor Green

    # Integrity check
    $integrity = Test-GoldenIntegrity -GoldenPath $goldenPath
    if ($integrity.Passed) {
        Write-Host "Integrity check: PASSED ($($integrity.FileCount) files verified)" -ForegroundColor Green
    } else {
        Write-Host "Integrity check: FAILED — $($integrity.Failures.Count) issue(s)" -ForegroundColor Red
        foreach ($f in $integrity.Failures | Select-Object -First 5) {
            Write-Host "  • $f" -ForegroundColor Red
        }
    }

    return $goldenPath
}

#endregion

#region ── Update-GoldenArchive ──────────────────────────────────────────────

function Update-GoldenArchive {
    <#
    .SYNOPSIS
        Build an incremental golden archive: only devices with changed data.
    .PARAMETER ForceDevices
        Override: include exactly these SNs regardless of change detection.
    .PARAMETER ForceReason
        Free-text reason recorded in manifest.json when -ForceDevices is supplied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$TOC,
        [Parameter(Mandatory)][string]$GoldenRoot,
        [Parameter(Mandatory)][string]$PreviousGolden,
        [string[]]$ForceDevices,
        [string]$ForceReason
    )

    $prevManifestPath = Join-Path $PreviousGolden 'manifest.json'
    if (-not (Test-Path $prevManifestPath)) {
        throw "Previous golden manifest.json not found at: $prevManifestPath"
    }
    $prevManifest = Get-Content $prevManifestPath -Raw | ConvertFrom-Json

    # Determine which devices have changed vs previous golden
    $cleanNames   = @($TOC.Backups.Keys | Where-Object { $TOC.Backups[$_].Integrity -ne 'Contaminated' })
    $changedSNs   = [System.Collections.Generic.List[string]]::new()

    if ($ForceDevices -and $ForceDevices.Count -gt 0) {
        # ForceDevices bypasses change detection entirely
        Write-Host "  ForceDevices override active: $($ForceDevices -join ', ')" -ForegroundColor Yellow
        foreach ($fsn in $ForceDevices) {
            if (-not $TOC.Devices.ContainsKey($fsn)) {
                Write-Warning "ForceDevices: SN '$fsn' not found in TOC — it will produce an empty device entry."
            }
            $changedSNs.Add($fsn)
        }
    } else {
        foreach ($sn in $TOC.Devices.Keys) {
            # Compute current best hash for each file
            $currentGroups = _GatherTrilogyFiles -Backups $TOC.Backups -DeviceSN $sn -CleanBackupNames $cleanNames
            $prevDevProp   = $prevManifest.devices.PSObject.Properties[$sn]
            $prevDevice    = if ($prevDevProp) { $prevDevProp.Value } else { $null }

            if (-not $prevDevice) {
                # New device not in previous golden
                $changedSNs.Add($sn)
                continue
            }

            $hasNewOrLarger = $false
            foreach ($fname in $currentGroups.Keys) {
                $prevHashProp = $prevDevice.fileHashes.PSObject.Properties["Trilogy/$fname"]
                $prevHash = if ($prevHashProp) { $prevHashProp.Value } else { $null }
                if (-not $prevHash) {
                    $hasNewOrLarger = $true; break
                }
                $curHash  = (Get-FileHash -Path $currentGroups[$fname].Path -Algorithm MD5).Hash
                if ($curHash -ne $prevHash) {
                    $hasNewOrLarger = $true; break
                }
            }
            if ($hasNewOrLarger) { $changedSNs.Add($sn) }
        }
    }  # end ForceDevices vs auto-detection

    if ($changedSNs.Count -eq 0) {
        Write-Host "No devices have changed since previous golden. Nothing to update." -ForegroundColor Yellow
        return $PreviousGolden
    }

    Write-Host "Changed devices: $($changedSNs -join ', ')" -ForegroundColor Cyan

    $date       = Get-Date -Format 'yyyy-MM-dd'
    $goldenPath = Join-Path $GoldenRoot "_golden_$date"
    if (Test-Path $goldenPath) {
        $seq = 1
        while (Test-Path "$goldenPath.$seq") { $seq++ }
        $goldenPath = "$goldenPath.$seq"
    }
    $null = New-Item -ItemType Directory -Path $goldenPath -Force

    $nextSeq = [int]$prevManifest.goldenSequence + 1
    $manifestDevices = @{}
    foreach ($sn in $changedSNs) {
        Write-Host "  Building golden for $sn ..." -ForegroundColor Cyan
        $devResult = _BuildDeviceGolden -DeviceSN $sn -Backups $TOC.Backups -GoldenPath $goldenPath -CleanBackupNames $cleanNames

        $tocDev = if ($TOC.Devices.ContainsKey($sn)) { $TOC.Devices[$sn] } else { $null }
        $splitSD    = $tocDev -and $tocDev.PSObject.Properties['SplitSD'] -and $tocDev.SplitSD
        $splitSpans = if ($splitSD -and $tocDev.PSObject.Properties['SplitSDSpans']) { $tocDev.SplitSDSpans } else { $null }

        $manifestDevices[$sn] = @{
            model            = $devResult.Model
            productType      = $devResult.ProductType
            firmware         = $devResult.Firmware
            trilogyDateRange = $devResult.TrilogyRange
            pSeriesDateRange = $devResult.PSeriesRange
            trilogyFileCount = $devResult.TrilogyFileCount
            pSeriesFileCount = $devResult.PSeriesFileCount
            sourceFolders    = $devResult.SourceFolders
            splitSD          = $splitSD
            splitSDSpans     = $splitSpans
            fileHashes       = $devResult.FileHashes
        }
    }

    $manifest = @{
        version             = 1
        created             = (Get-Date -Format 'o')
        goldenSequence      = $nextSeq
        previousGolden      = $PreviousGolden
        backupRoot          = (Split-Path $goldenPath -Parent)
        forcedDevicesReason = if ($ForceDevices -and $ForceDevices.Count -gt 0) {
            if ($ForceReason) { $ForceReason } else { 'Devices forced by operator (no reason provided)' }
        } else { $null }
        devices             = $manifestDevices
    }
    _WriteManifest -GoldenPath $goldenPath -ManifestData $manifest
    _WriteGoldenReadme -GoldenPath $goldenPath -Devices $changedSNs -Sequence $nextSeq

    Write-Host ''
    Write-Host "Golden archive created: $goldenPath" -ForegroundColor Green

    $integrity = Test-GoldenIntegrity -GoldenPath $goldenPath
    if ($integrity.Passed) {
        Write-Host "Integrity check: PASSED ($($integrity.FileCount) files verified)" -ForegroundColor Green
    } else {
        Write-Host "Integrity check: FAILED — $($integrity.Failures.Count) issue(s)" -ForegroundColor Red
        foreach ($f in $integrity.Failures | Select-Object -First 5) {
            Write-Host "  • $f" -ForegroundColor Red
        }
    }

    return $goldenPath
}

#endregion

#region ── Test-GoldenIntegrity ──────────────────────────────────────────────

function Test-GoldenIntegrity {
    <#
    .SYNOPSIS
        Verify every file in the manifest exists, hashes match, EDF SN correct.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GoldenPath)

    $manifestPath = Join-Path $GoldenPath 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        return [PSCustomObject]@{ Passed = $false; FileCount = 0; Failures = @("manifest.json not found") }
    }

    $manifest  = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $failures  = [System.Collections.Generic.List[string]]::new()
    $fileCount = 0

    foreach ($snProp in $manifest.devices.PSObject.Properties) {
        $sn  = $snProp.Name
        $dev = $snProp.Value

        foreach ($hashProp in $dev.fileHashes.PSObject.Properties) {
            $relPath  = $hashProp.Name                        # e.g. "Trilogy/AD_202303_000.edf"
            $expected = $hashProp.Value
            $fullPath = Join-Path $GoldenPath "$sn\$relPath"
            $fileCount++

            if (-not (Test-Path $fullPath)) {
                $failures.Add("MISSING: $fullPath")
                continue
            }

            $actual = (Get-FileHash -Path $fullPath -Algorithm MD5).Hash
            if ($actual -ne $expected) {
                $failures.Add("HASH MISMATCH: $fullPath (expected $expected, got $actual)")
                continue
            }

            # EDF header SN verification
            if ($fullPath -match '\.edf$') {
                $headerSN = Get-EdfDeviceSerial -Path $fullPath
                if ($headerSN -and $headerSN -ne $sn) {
                    $failures.Add("SN MISMATCH in EDF header: $fullPath (manifest says $sn, header says $headerSN)")
                }
            }
        }

        # AD/DD pair completeness check
        $trilogyPath = Join-Path $GoldenPath "$sn\Trilogy"
        if (Test-Path $trilogyPath) {
            $adFiles = @(Get-ChildItem -LiteralPath $trilogyPath -Filter 'AD_*.edf' | ForEach-Object {
                if ($_.Name -match '^AD_(\d{6}_\d{3})\.edf$') { $Matches[1] }
            })
            $ddFiles = @(Get-ChildItem -LiteralPath $trilogyPath -Filter 'DD_*.edf' | ForEach-Object {
                if ($_.Name -match '^DD_(\d{6}_\d{3})\.edf$') { $Matches[1] }
            })
            foreach ($key in $adFiles) {
                if ($ddFiles -notcontains $key) {
                    $failures.Add("MISSING DD PAIR for AD_$($key).edf in $sn")
                }
            }
        }
    }

    return [PSCustomObject]@{
        Passed    = ($failures.Count -eq 0)
        FileCount = $fileCount
        Failures  = $failures.ToArray()
    }
}

#endregion

#region ── Test-GoldenContent ───────────────────────────────────────────────

# Private helper — returns a single issue PSCustomObject.
function _NewContentIssue {
    param(
        [string]$Severity,   # Critical | Error | Warning
        [string]$Category,   # DirectViewCompat | EdfFormat | EdfPairing | PSeriesFormat | ManifestSchema | DirectoryStructure
        [string]$Device,
        [string]$File,
        [string]$Message
    )
    [PSCustomObject]@{
        Severity = $Severity
        Category = $Category
        Device   = $Device
        File     = $File
        Message  = $Message
    }
}

function Test-GoldenContent {
    <#
    .SYNOPSIS
        Deep per-file format and DirectView-compatibility validation for a golden archive.
        Runs after Test-GoldenIntegrity — inspects every file (not just manifest-listed files).
    .DESCRIPTION
        Returns a PSCustomObject with Passed (bool), FileCount, CriticalCount, ErrorCount,
        WarningCount, and Issues array.  Passed = $true only when CriticalCount + ErrorCount = 0.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GoldenPath)

    $issues    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $fileCount = 0

    # ── 1. manifest.json schema ───────────────────────────────────────────────
    $manifestPath = Join-Path $GoldenPath 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        return [PSCustomObject]@{
            Passed='$false'; FileCount=0; CriticalCount=1; ErrorCount=0; WarningCount=0
            Issues=@((_NewContentIssue 'Critical' 'ManifestSchema' '' 'manifest.json' 'manifest.json not found'))
        }
    }

    $manifest = $null
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{
            Passed=$false; FileCount=0; CriticalCount=1; ErrorCount=0; WarningCount=0
            Issues=@((_NewContentIssue 'Critical' 'ManifestSchema' '' 'manifest.json' "manifest.json is not valid JSON: $_"))
        }
    }

    if (-not $manifest.PSObject.Properties['version']) {
        $issues.Add((_NewContentIssue 'Error' 'ManifestSchema' '' 'manifest.json' "Missing 'version' field"))
    } elseif ($manifest.version -ne 1) {
        $issues.Add((_NewContentIssue 'Error' 'ManifestSchema' '' 'manifest.json' "version is '$($manifest.version)', expected 1"))
    }

    if (-not $manifest.PSObject.Properties['goldenSequence'] -or [int]$manifest.goldenSequence -lt 1) {
        $issues.Add((_NewContentIssue 'Error' 'ManifestSchema' '' 'manifest.json' "goldenSequence is missing or < 1"))
    }

    if (-not $manifest.PSObject.Properties['created'] -or
        $manifest.created -notmatch '^\d{4}-\d{2}-\d{2}') {
        $issues.Add((_NewContentIssue 'Warning' 'ManifestSchema' '' 'manifest.json' "created is missing or not a valid ISO-8601 timestamp"))
    }

    $frProp = $manifest.PSObject.Properties['forcedDevicesReason']
    if ($frProp -and $frProp.Value -is [string] -and $frProp.Value -eq '') {
        $issues.Add((_NewContentIssue 'Warning' 'ManifestSchema' '' 'manifest.json' "forcedDevicesReason is empty string — should be null or a non-empty description"))
    }

    if (-not $manifest.PSObject.Properties['devices']) {
        $issues.Add((_NewContentIssue 'Critical' 'ManifestSchema' '' 'manifest.json' "Missing 'devices' section"))
        # Cannot continue without a devices section
        return [PSCustomObject]@{
            Passed        = $false
            FileCount     = $fileCount
            CriticalCount = @($issues | Where-Object { $_.Severity -eq 'Critical' }).Count
            ErrorCount    = @($issues | Where-Object { $_.Severity -eq 'Error'    }).Count
            WarningCount  = @($issues | Where-Object { $_.Severity -eq 'Warning'  }).Count
            Issues        = $issues.ToArray()
        }
    }

    # Orphan device folders (on disk but absent from manifest)
    $onDiskSNs = @(Get-ChildItem -LiteralPath $GoldenPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^_' -and $_.Name -ne 'scripts' } |
        Select-Object -ExpandProperty Name)
    foreach ($diskSN in $onDiskSNs) {
        if (-not $manifest.devices.PSObject.Properties[$diskSN]) {
            $issues.Add((_NewContentIssue 'Warning' 'DirectoryStructure' $diskSN '' "Device folder '$diskSN' exists on disk but has no entry in manifest.devices"))
        }
    }

    # ── 2. Per-device validation ──────────────────────────────────────────────
    foreach ($snProp in $manifest.devices.PSObject.Properties) {
        $sn       = $snProp.Name
        $devPath  = Join-Path $GoldenPath $sn
        $triPath  = Join-Path $devPath 'Trilogy'
        $psPath   = Join-Path $devPath 'P-Series'
        $snPsPath = Join-Path $psPath $sn

        if (-not (Test-Path $devPath)) {
            $issues.Add((_NewContentIssue 'Critical' 'DirectoryStructure' $sn '' "Device folder missing from golden output"))
            continue
        }

        # 2a. Top-level directory structure
        if (-not (Test-Path $triPath)) {
            $issues.Add((_NewContentIssue 'Critical' 'DirectViewCompat' $sn 'Trilogy/' 'Trilogy/ directory missing — DirectView cannot load this device'))
        }
        if (-not (Test-Path $psPath)) {
            $issues.Add((_NewContentIssue 'Critical' 'DirectViewCompat' $sn 'P-Series/' 'P-Series/ directory missing — DirectView cannot load this device'))
        }

        # 2b. last.txt
        $lastTxtPath = Join-Path $psPath 'last.txt'
        if (-not (Test-Path $lastTxtPath)) {
            $issues.Add((_NewContentIssue 'Critical' 'DirectViewCompat' $sn 'P-Series/last.txt' 'last.txt missing — DirectView cannot identify the active device'))
        } else {
            $lastVal = (Get-Content $lastTxtPath -Raw -Encoding UTF8).Trim()
            if ($lastVal -ne $sn) {
                $issues.Add((_NewContentIssue 'Error' 'DirectViewCompat' $sn 'P-Series/last.txt' "last.txt contains '$lastVal' but device folder is '$sn'"))
            }
        }

        # 2c. prop.txt
        $propPath = Join-Path $snPsPath 'prop.txt'
        if (-not (Test-Path $propPath)) {
            $issues.Add((_NewContentIssue 'Critical' 'DirectViewCompat' $sn "P-Series/$sn/prop.txt" 'prop.txt missing — DirectView cannot identify device model'))
        } else {
            $fileCount++
            $prop = Read-PropFile -Path $propPath
            if (-not $prop) {
                $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" 'prop.txt could not be parsed'))
            } else {
                if (-not $prop.PSObject.Properties['SN'] -or -not $prop.SN) {
                    $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" 'prop.txt missing SN field'))
                } elseif ($prop.SN -ne $sn) {
                    $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" "prop.txt SN '$($prop.SN)' does not match device folder '$sn'"))
                }
                if (-not $prop.PSObject.Properties['MN'] -or -not $prop.MN) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" 'prop.txt missing MN (model number) field'))
                }
                if (-not $prop.PSObject.Properties['PT'] -or -not $prop.PT) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" 'prop.txt missing PT (product type) field'))
                } elseif ($prop.PT -notmatch '^0x[0-9a-fA-F]+$') {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" "prop.txt PT '$($prop.PT)' is not in expected '0x...' hex format"))
                }
                if (-not $prop.PSObject.Properties['SV'] -or -not $prop.SV) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/prop.txt" 'prop.txt missing SV (software version) field'))
                }
            }
        }

        # 2d. Trilogy/ files
        if (Test-Path $triPath) {
            # Require at least one AD file for DirectView
            $adFilesList = @(Get-ChildItem -LiteralPath $triPath -Filter 'AD_*.edf' -ErrorAction SilentlyContinue)
            if ($adFilesList.Count -eq 0) {
                $issues.Add((_NewContentIssue 'Critical' 'DirectViewCompat' $sn 'Trilogy/' 'No AD_*.edf files — DirectView has no alarm-detail data to load'))
            }

            # EDF files: full header validation
            $adKeys = [System.Collections.Generic.Dictionary[string,bool]]::new()
            $ddKeys = [System.Collections.Generic.Dictionary[string,bool]]::new()

            Get-ChildItem -LiteralPath $triPath -Filter '*.edf' -ErrorAction SilentlyContinue | ForEach-Object {
                $fileCount++
                $relFile  = "Trilogy/$($_.Name)"
                $filePath = $_.FullName

                if ($_.Length -lt 256) {
                    $issues.Add((_NewContentIssue 'Critical' 'EdfFormat' $sn $relFile "File is $($_.Length) bytes — too short to contain a 256-byte EDF header"))
                    return  # continue to next file
                }

                $hdr = Read-EdfHeader -Path $filePath
                if (-not $hdr) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile 'EDF header could not be parsed'))
                    return
                }

                if ($hdr.Version -ne '0') {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "Version field is '$($hdr.Version)', expected '0'"))
                }
                if ($hdr.HeaderBytes -ne 256) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "HeaderBytes is $($hdr.HeaderBytes), expected 256"))
                }
                if ($hdr.StartDate -and $hdr.StartDate -notmatch '^\d{2}\.\d{2}\.\d{2}$') {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile "StartDate '$($hdr.StartDate)' does not match expected dd.mm.yy format"))
                }
                if ($hdr.StartTime -and $hdr.StartTime -notmatch '^\d{2}\.\d{2}\.\d{2}$') {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile "StartTime '$($hdr.StartTime)' does not match expected hh.mm.ss format"))
                }
                $ndr = $hdr.NumDataRecords
                if ($ndr -ne '-1') {
                    $ndrInt = 0
                    if (-not [int]::TryParse($ndr.Trim(), [ref]$ndrInt) -or $ndrInt -lt 0) {
                        $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "NumDataRecords '$ndr' is neither '-1' nor a non-negative integer"))
                    }
                }
                if ($hdr.NumSignals -lt 1) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "NumSignals is $($hdr.NumSignals), expected >= 1"))
                }
                $rdInt = 0
                if ($hdr.RecordDuration -and
                    (-not [int]::TryParse($hdr.RecordDuration.Trim(), [ref]$rdInt) -or $rdInt -lt 0)) {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile "RecordDuration '$($hdr.RecordDuration)' is not a non-negative integer"))
                }
                if ($hdr.RecordingID -and $hdr.RecordingID -notmatch '^Startdate ') {
                    $preview = $hdr.RecordingID.Substring(0, [Math]::Min(40, $hdr.RecordingID.Length))
                    $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile "RecordingID does not begin with 'Startdate': '$preview...'"))
                }

                $headerSN = Get-EdfDeviceSerial -Path $filePath
                if (-not $headerSN) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile 'Cannot extract SN from RecordingID — device identity cannot be confirmed'))
                } elseif ($headerSN -ne $sn) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "EDF header SN '$headerSN' does not match device folder '$sn'"))
                }

                # Filename date vs StartDate consistency (month must agree)
                $dateInfo = Get-EdfDateInfo -Path $filePath
                if ($dateInfo -and $hdr.StartDate -match '^(\d{2})\.(\d{2})\.(\d{2})$') {
                    $hdrMonth = [int]$Matches[2]
                    if ($dateInfo.Month -ne $hdrMonth) {
                        $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile "Filename month ($($dateInfo.Month)) does not match EDF StartDate month ($hdrMonth)"))
                    }
                }

                # Track keys for pair check
                if ($_.Name -match '^AD_(\d{6}_\d{3})\.edf$') { $adKeys[$Matches[1]] = $true }
                if ($_.Name -match '^DD_(\d{6}_\d{3})\.edf$') { $ddKeys[$Matches[1]] = $true }
            }

            # AD/DD pair completeness (bidirectional)
            foreach ($k in @($adKeys.Keys)) {
                if (-not $ddKeys.ContainsKey($k)) {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfPairing' $sn "Trilogy/AD_$k.edf" "AD_$k.edf has no matching DD_$k.edf"))
                }
            }
            foreach ($k in @($ddKeys.Keys)) {
                if (-not $adKeys.ContainsKey($k)) {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfPairing' $sn "Trilogy/DD_$k.edf" "DD_$k.edf has no matching AD_$k.edf"))
                }
            }

            # BIN files — filename pattern + SN
            Get-ChildItem -LiteralPath $triPath -Filter '*.bin' -ErrorAction SilentlyContinue | ForEach-Object {
                $fileCount++
                $relFile = "Trilogy/$($_.Name)"
                $binInfo = Get-BinFileInfo -Path $_.FullName
                if (-not $binInfo) {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile 'BIN filename does not match expected {PT}_{SN}_{Type}_{UnixTS}.bin pattern'))
                } elseif ($binInfo.SerialNumber -and $binInfo.SerialNumber -ne $sn) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "BIN filename SN '$($binInfo.SerialNumber)' does not match device folder '$sn'"))
                }
            }

            # EL_ CSV files — filename SN + binary content SN check
            Get-ChildItem -LiteralPath $triPath -Filter 'EL_*.csv' -ErrorAction SilentlyContinue | ForEach-Object {
                $fileCount++
                $relFile = "Trilogy/$($_.Name)"
                $elInfo  = Get-ElCsvInfo -Path $_.FullName
                if (-not $elInfo) {
                    $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile 'EL_ CSV filename does not match expected EL_{SN}_{YYYYMMDD}.csv pattern'))
                } elseif ($elInfo.SerialNumber -and $elInfo.SerialNumber -ne $sn) {
                    $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "EL_ CSV filename SN '$($elInfo.SerialNumber)' does not match device folder '$sn'"))
                } else {
                    # Binary content: first 100 bytes must contain the device SN
                    try {
                        $rawBytes = [System.IO.File]::ReadAllBytes($_.FullName)
                        $head = [System.Text.Encoding]::ASCII.GetString($rawBytes, 0, [Math]::Min($rawBytes.Length, 100))
                        if ($head -notmatch [regex]::Escape($sn)) {
                            $issues.Add((_NewContentIssue 'Error' 'EdfFormat' $sn $relFile "EL_ CSV first 100 bytes do not contain device SN '$sn' — content may belong to a different device"))
                        }
                    } catch {
                        $issues.Add((_NewContentIssue 'Warning' 'EdfFormat' $sn $relFile "EL_ CSV could not be read as binary: $_"))
                    }
                }
            }
        }

        # 2e. P-Series: FILES.SEQ, TRANSMITFILE.SEQ, SL_SAPPHIRE.json, PP JSON
        if (Test-Path $snPsPath) {
            $filesSeqPath = Join-Path $snPsPath 'FILES.SEQ'
            $filesSeqLines = $null
            if (Test-Path $filesSeqPath) {
                $fileCount++
                $filesSeq = Read-FilesSeq -Path $filesSeqPath
                if (-not $filesSeq) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/FILES.SEQ" 'FILES.SEQ is not parseable or empty'))
                } elseif ($filesSeq.LineCount -eq 0) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/FILES.SEQ" 'FILES.SEQ has no entries'))
                } else {
                    $filesSeqLines = $filesSeq.LineCount
                }
            }

            $transSeqPath = Join-Path $snPsPath 'TRANSMITFILE.SEQ'
            if (Test-Path $transSeqPath) {
                $fileCount++
                $transSeq = Read-FilesSeq -Path $transSeqPath
                if (-not $transSeq) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/TRANSMITFILE.SEQ" 'TRANSMITFILE.SEQ is not parseable'))
                } elseif ($filesSeqLines -and $transSeq.LineCount -gt $filesSeqLines) {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/TRANSMITFILE.SEQ" "TRANSMITFILE.SEQ ($($transSeq.LineCount) entries) exceeds FILES.SEQ ($filesSeqLines entries) — FILES.SEQ must be a superset"))
                }
            }

            $slPath = Join-Path $snPsPath 'SL_SAPPHIRE.json'
            if (Test-Path $slPath) {
                $fileCount++
                try {
                    $slBytes = [System.IO.File]::ReadAllBytes($slPath)
                    # Lightweight check: first non-whitespace byte must be '{' (JSON object)
                    $firstChar = ''
                    foreach ($b in $slBytes) {
                        if ($b -gt 32) { $firstChar = [char]$b; break }
                    }
                    if ($firstChar -ne '{') {
                        $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/SL_SAPPHIRE.json" "SL_SAPPHIRE.json does not start with '{' — may not be a valid JSON object"))
                    }
                } catch {
                    $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn "P-Series/$sn/SL_SAPPHIRE.json" "SL_SAPPHIRE.json could not be read: $_"))
                }
            }

            # PP JSON across all P0-P7 ring slots
            for ($slot = 0; $slot -le 7; $slot++) {
                $slotPath = Join-Path $snPsPath "P$slot"
                if (-not (Test-Path $slotPath)) { continue }
                Get-ChildItem -LiteralPath $slotPath -Filter 'PP_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
                    $fileCount++
                    $relFile = "P-Series/$sn/P$slot/$($_.Name)"
                    $ppData  = Read-PpJson -Path $_.FullName
                    if (-not $ppData) {
                        $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn $relFile 'PP JSON could not be parsed'))
                        return
                    }
                    if (-not $ppData.PSObject.Properties['SN'] -or -not $ppData.SN) {
                        $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn $relFile "PP JSON missing 'SN' field"))
                    } elseif ($ppData.SN -ne $sn) {
                        $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn $relFile "PP JSON SN '$($ppData.SN)' does not match device folder '$sn'"))
                    }
                    if (-not $ppData.PSObject.Properties['TimeStamp']) {
                        $issues.Add((_NewContentIssue 'Error' 'PSeriesFormat' $sn $relFile "PP JSON missing 'TimeStamp' field"))
                    } else {
                        $tsLong = [long]0
                        if (-not [long]::TryParse([string]$ppData.TimeStamp, [ref]$tsLong) -or $tsLong -le 0) {
                            $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn $relFile "PP JSON TimeStamp '$($ppData.TimeStamp)' is not a valid positive Unix epoch value"))
                        }
                    }
                    if ($ppData.PSObject.Properties['BlowerHours']) {
                        $bhInt = 0
                        if (-not [int]::TryParse([string]$ppData.BlowerHours, [ref]$bhInt) -or $bhInt -lt 0) {
                            $issues.Add((_NewContentIssue 'Warning' 'PSeriesFormat' $sn $relFile "PP JSON BlowerHours '$($ppData.BlowerHours)' is not a non-negative integer"))
                        }
                    }
                }
            }
        }
    }

    $critCount = @($issues | Where-Object { $_.Severity -eq 'Critical' }).Count
    $errCount  = @($issues | Where-Object { $_.Severity -eq 'Error'    }).Count
    $warnCount = @($issues | Where-Object { $_.Severity -eq 'Warning'  }).Count

    return [PSCustomObject]@{
        Passed        = ($critCount -eq 0 -and $errCount -eq 0)
        FileCount     = $fileCount
        CriticalCount = $critCount
        ErrorCount    = $errCount
        WarningCount  = $warnCount
        Issues        = $issues.ToArray()
    }
}

#endregion

#region ── Internal: Write Golden README ──────────────────────────────────────

function _WriteGoldenReadme {
    param([string]$GoldenPath, [string[]]$Devices, [int]$Sequence)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Golden Archive — Sequence $Sequence")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> **Auto-generated by VentBackupManager** — verified, per-device data.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Created**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ")
    [void]$sb.AppendLine("**Devices included**: $($Devices -join ', ')")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Layout')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine("$([System.IO.Path]::GetFileName($GoldenPath))/")
    foreach ($sn in $Devices) {
        [void]$sb.AppendLine("  $sn/")
        [void]$sb.AppendLine("    Trilogy/        ← EDF telemetry files")
        [void]$sb.AppendLine("    P-Series/       ← P-Series session data")
        [void]$sb.AppendLine("      last.txt      ← Points to $sn")
        [void]$sb.AppendLine("      $sn/")
    }
    [void]$sb.AppendLine('  manifest.json   ← File hashes + chain of custody')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Using with Philips DirectView')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Point DirectView at the individual device subfolder:')
    foreach ($sn in $Devices) {
        [void]$sb.AppendLine("  DirectView → ``$sn/``")
    }

    Set-Content -LiteralPath (Join-Path $GoldenPath 'README.md') -Value $sb.ToString() -Encoding UTF8
}

#endregion

# Expose _WriteGoldenReadme is internal — not exported
Export-ModuleMember -Function @(
    'New-GoldenArchive',
    'Update-GoldenArchive',
    'Test-GoldenIntegrity'
)
