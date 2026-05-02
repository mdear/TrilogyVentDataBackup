# VBM-Export.psm1 — Write golden archive content to a target (SD card or folder)
# See DESIGN.md for DirectView compatibility layout requirements.

#region ── Export-ToTarget ───────────────────────────────────────────────────

function Export-ToTarget {
    <#
    .SYNOPSIS
        Copy golden archive content to a target folder or SD card.
    .DESCRIPTION
        Single-device: mirrors native SD card layout so DirectView can read directly.
        Multi-device: each device gets a subdirectory; root README explains layout.
    .PARAMETER GoldenPath
        Path to a golden archive directory (contains manifest.json and {SN}/ folders).
    .PARAMETER Target
        Destination path (SD card root or an empty folder).
    .PARAMETER Devices
        Optional subset of SNs to export. Defaults to all devices in the golden.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GoldenPath,
        [Parameter(Mandatory)][string]$Target,
        [string[]]$Devices
    )

    $manifestPath = Join-Path $GoldenPath 'manifest.json'
    if (-not (Test-Path $manifestPath)) {
        throw "manifest.json not found in golden archive: $GoldenPath"
    }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

    # Resolve device list
    $allSNs = @($manifest.devices.PSObject.Properties | ForEach-Object { $_.Name })
    $snList = @(if ($Devices -and $Devices.Count -gt 0) { $Devices } else { $allSNs })

    # Validate requested SNs exist in manifest
    foreach ($sn in $snList) {
        if ($allSNs -notcontains $sn) {
            throw "Device $sn not found in golden archive manifest. Available: $($allSNs -join ', ')"
        }
    }

    # Ensure target exists
    if (-not (Test-Path $Target)) {
        $null = New-Item -ItemType Directory -Path $Target -Force
    }

    $isSingle = ($snList.Count -eq 1)

    # Detect native layout from manifest
    $isNativeGolden = $manifest.PSObject.Properties['nativeLayout'] -and $manifest.nativeLayout

    if (-not $isSingle) {
        # Multi-device exports produce a per-device subfolder layout that Philips DirectView
        # cannot read directly.  Emit a prominent warning so the caller is aware.
        Write-Warning ('DIRECTVIEW INCOMPATIBLE: This multi-device export uses a subfolder layout ' +
            'that Philips DirectView cannot read directly from the SD card root. ' +
            'For a DirectView-compatible SD card, export ONE device at a time.')
    }

    if ($isSingle) {
        _ExportSingleDevice -SN $snList[0] -GoldenPath $GoldenPath -Target $Target -NativeLayout $isNativeGolden
    } else {
        foreach ($sn in $snList) {
            $snTarget = Join-Path $Target $sn
            $null = New-Item -ItemType Directory -Path $snTarget -Force
            _ExportSingleDevice -SN $sn -GoldenPath $GoldenPath -Target $snTarget -NativeLayout $isNativeGolden
        }
        # Root README for multi-device layout
        Write-ExportReadme -Target $Target -Devices ($snList | ForEach-Object {
            $snProp   = $manifest.devices.PSObject.Properties[$_]
            $snDevice = if ($snProp) { $snProp.Value } else { $null }
            [PSCustomObject]@{ SN = $_; Model = if ($snDevice) { $snDevice.model } else { $null } }
        })
    }

    Write-Host ''
    Write-Host "Export complete → $Target" -ForegroundColor Green
}

function _ExportSingleDevice {
    param([string]$SN, [string]$GoldenPath, [string]$Target, [bool]$NativeLayout = $false)

    Write-Host "  Exporting $SN ..." -ForegroundColor Cyan
    # Native layout: files at golden root (no SN subfolder). Multi-device: files under {SN}/.
    $srcBase = if ($NativeLayout) { $GoldenPath } else { Join-Path $GoldenPath $SN }

    # ── Trilogy/ ──────────────────────────────────────────────────────────
    $srcTrilogy = Join-Path $srcBase 'Trilogy'
    $dstTrilogy = Join-Path $Target  'Trilogy'
    if (Test-Path $srcTrilogy) {
        $null = New-Item -ItemType Directory -Path $dstTrilogy -Force
        foreach ($f in Get-ChildItem -LiteralPath $srcTrilogy -File) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dstTrilogy $f.Name) -Force
        }
        Write-Host "    Trilogy: $((Get-ChildItem -LiteralPath $dstTrilogy -File).Count) files"
    }

    # ── P-Series/ ─────────────────────────────────────────────────────────
    # Source layout: {GoldenPath}/{SN}/P-Series/{SN}/*
    # Dest layout:   {Target}/P-Series/{SN}/*   + {Target}/P-Series/last.txt
    $srcPS  = Join-Path $srcBase "P-Series\$SN"
    $dstPS  = Join-Path $Target  "P-Series\$SN"
    if (Test-Path $srcPS) {
        $null = New-Item -ItemType Directory -Path $dstPS -Force
        foreach ($f in Get-ChildItem -LiteralPath $srcPS -Recurse -File) {
            $rel  = $f.FullName.Substring($srcPS.Length).TrimStart('\', '/')
            $dest = Join-Path $dstPS $rel
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($dest)) -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
    }

    # last.txt at P-Series root
    $dstLastTxt = Join-Path $Target "P-Series\last.txt"
    $null = New-Item -ItemType Directory -Path (Join-Path $Target 'P-Series') -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $dstLastTxt -Value $SN -Encoding UTF8
}

#endregion

#region ── Show-TargetContents ───────────────────────────────────────────────

function Show-TargetContents {
    <#
    .SYNOPSIS
        Display top-level directory of the target for pre-overwrite confirmation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)

    if (-not (Test-Path $Target)) {
        Write-Host "Target does not exist: $Target" -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host "Contents of: $Target" -ForegroundColor Cyan
    Write-Host ('-' * 60)
    '{0,-35} {1,-12} {2}' -f 'Name', 'Modified', 'Size' | Write-Host -ForegroundColor DarkGray
    Write-Host ('-' * 60)

    foreach ($item in Get-ChildItem -LiteralPath $Target | Sort-Object Name) {
        $sz   = if ($item.PSIsContainer) { '<DIR>' } else { "{0:N0}" -f $item.Length }
        $mod  = $item.LastWriteTime.ToString('yyyy-MM-dd')
        '{0,-35} {1,-12} {2}' -f $item.Name, $mod, $sz | Write-Host
    }
    Write-Host ''
}

#endregion

#region ── Write-ExportReadme ────────────────────────────────────────────────

function Write-ExportReadme {
    <#
    .SYNOPSIS
        Generate a clinician-facing README.md explaining the multi-device export layout.
    .PARAMETER Target
        The export root folder.
    .PARAMETER Devices
        Array of PSCustomObjects with SN and Model properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][array]$Devices
    )

    $readmePath = Join-Path $Target 'README.md'
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine('# Ventilator Data Export')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> Prepared by VentBackupManager. Each device has its own subdirectory.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Export date**: $(Get-Date -Format 'yyyy-MM-dd')")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Devices In This Export')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Device SN | Model | DirectView Path |')
    [void]$sb.AppendLine('|-----------|-------|-----------------|')
    foreach ($dev in $Devices) {
        $sn    = $dev.SN
        $model = if ($dev.Model) { $dev.Model } else { 'Trilogy 200' }
        [void]$sb.AppendLine("| $sn | $model | ``./$sn/`` |")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## How to Use with Philips DirectView')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('1. Open Philips DirectView software.')
    [void]$sb.AppendLine('2. For each device, point DirectView to the device-specific subfolder:')
    foreach ($dev in $Devices) {
        [void]$sb.AppendLine("   - ``$($dev.SN)/`` — $($dev.SN)")
    }
    [void]$sb.AppendLine('3. Each subfolder contains a complete, self-contained dataset for')
    [void]$sb.AppendLine('   that device (``Trilogy/``, ``P-Series/``, ``last.txt``).')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Folder Structure')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('```')
    [void]$sb.AppendLine('(this folder)/')
    foreach ($dev in $Devices) {
        [void]$sb.AppendLine("  $($dev.SN)/")
        [void]$sb.AppendLine("    Trilogy/           ← Telemetry (AD, DD, WD .edf files)")
        [void]$sb.AppendLine("    P-Series/")
        [void]$sb.AppendLine("      last.txt         ← Points to $($dev.SN)")
        [void]$sb.AppendLine("      $($dev.SN)/      ← Session data (ring buffer, firmware logs)")
    }
    [void]$sb.AppendLine('  README.md              ← This file')
    [void]$sb.AppendLine('```')

    Set-Content -LiteralPath $readmePath -Value $sb.ToString() -Encoding UTF8
    Write-Host "Export README written: $readmePath"
}

#endregion

#region ── Test-SDCardIntegrity ──────────────────────────────────────────────

function Test-SDCardIntegrity {
    <#
    .SYNOPSIS
        Validate an SD card or exported folder for data integrity and tamper detection.
    .DESCRIPTION
        Two modes, selected automatically:

        MODE A — Manifest-free (external export / SD card):
        When the target path does NOT contain a manifest.json (the normal case for
        SD cards exported via Export-ToTarget, which deliberately omits the manifest
        to avoid interfering with vendor analysis software):
          1. Scan files, detect layout (native or multi-device), compute MD5 hashes.
          2. Auto-discover or manually compare against a local golden archive.
          3. Deep-diff to report corrupted / added / missing files.

        MODE B — Manifest-present (local golden or path with manifest.json):
        When the target path DOES contain a manifest.json (e.g. a golden archive on
        disk, or a folder that was not exported via the standard flow):
          1. Use the manifest's recorded hashes as ground truth.
          2. Recompute every file's hash and compare against the manifest.
          3. Report mismatches — same as Test-GoldenIntegrity but via this unified entry point.

    .PARAMETER SDCardPath
        Root path of the SD card or exported folder.
    .PARAMETER ReferenceGoldenPath
        Optional. Path to a specific golden archive to validate against (Mode A only).
    .PARAMETER SearchPaths
        Directories to search when auto-discovering the matching golden archive (Mode A only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SDCardPath,
        [string]$ReferenceGoldenPath,
        [string[]]$SearchPaths
    )

    # ── Mode B: manifest.json present — validate against embedded hashes ──
    $localManifestPath = Join-Path $SDCardPath 'manifest.json'
    if (Test-Path $localManifestPath) {
        return _ValidateWithManifest -TargetPath $SDCardPath -ManifestPath $localManifestPath
    }

    # ── Mode A: manifest-free (external export) ───────────────────────────
    $result = [PSCustomObject]@{
        Passed             = $false
        FileCount          = 0
        ComputedHashes     = @{}       # "SN|relPath" → hash
        DetectedLayout     = $null     # 'native' or 'multi-device'
        DetectedDevices    = @()
        ReferenceGolden    = $null
        AutoDiscovered     = $false
        Mismatches         = @()       # files with different hashes
        ExtraOnCard        = @()       # files on SD not in golden
        MissingFromCard    = @()       # files in golden not on SD
    }

    # ── Phase 1: Detect layout and compute hashes ─────────────────────────
    $layout = _DetectSDLayout -SDCardPath $SDCardPath
    $result.DetectedLayout  = $layout.Layout
    $result.DetectedDevices = $layout.Devices

    if ($layout.Devices.Count -eq 0) {
        $result.Mismatches = @("No recognisable device data found on SD card at: $SDCardPath")
        return $result
    }

    $computed = _ComputeSDHashes -SDCardPath $SDCardPath -Layout $layout
    $result.ComputedHashes = $computed
    $result.FileCount      = $computed.Count

    # ── Phase 2: Find matching golden ────────────────────────────────────
    $refPath = $ReferenceGoldenPath
    if (-not $refPath -and $SearchPaths) {
        $refPath = Find-MatchingGolden -ComputedHashes $computed -SearchPaths $SearchPaths
        if ($refPath) { $result.AutoDiscovered = $true }
    }

    if (-not $refPath) {
        # Try to find a partial match for deep diff
        if ($SearchPaths) {
            $refPath = Find-MatchingGolden -ComputedHashes $computed -SearchPaths $SearchPaths -AllowPartial
        }
        if (-not $refPath) {
            $result.Mismatches = @("No matching golden archive found. Cannot validate.")
            return $result
        }
    }

    $result.ReferenceGolden = $refPath

    # ── Phase 3: Deep comparison against the reference golden ─────────────
    $refManifestPath = Join-Path $refPath 'manifest.json'
    if (-not (Test-Path $refManifestPath)) {
        $result.Mismatches = @("Reference golden manifest.json not found: $refManifestPath")
        return $result
    }

    $refManifest = Get-Content $refManifestPath -Raw | ConvertFrom-Json

    # Build reference hash lookup (order-independent)
    $refLookup = @{}
    foreach ($snProp in $refManifest.devices.PSObject.Properties) {
        $sn  = $snProp.Name
        $dev = $snProp.Value
        foreach ($hashProp in $dev.fileHashes.PSObject.Properties) {
            $refLookup["$sn|$($hashProp.Name)"] = $hashProp.Value
        }
    }

    $mismatches      = [System.Collections.Generic.List[string]]::new()
    $extraOnCard     = [System.Collections.Generic.List[string]]::new()
    $missingFromCard = [System.Collections.Generic.List[string]]::new()

    # Compare SD → golden
    foreach ($key in $computed.Keys) {
        if ($refLookup.ContainsKey($key)) {
            if ($computed[$key] -ne $refLookup[$key]) {
                $mismatches.Add("CORRUPTED: $key (computed=$($computed[$key]), golden=$($refLookup[$key]))")
            }
        } else {
            $extraOnCard.Add($key)
        }
    }
    # Compare golden → SD (find missing)
    foreach ($key in $refLookup.Keys) {
        if (-not $computed.ContainsKey($key)) {
            $missingFromCard.Add($key)
        }
    }

    $result.Mismatches      = $mismatches.ToArray()
    $result.ExtraOnCard     = $extraOnCard.ToArray()
    $result.MissingFromCard = $missingFromCard.ToArray()
    $result.Passed          = ($mismatches.Count -eq 0 -and $extraOnCard.Count -eq 0 -and $missingFromCard.Count -eq 0)

    return $result
}

function _DetectSDLayout {
    <#
    .SYNOPSIS
        Detect whether an SD card uses native (single-device) or multi-device layout.
        Native: Trilogy/ and/or P-Series/ at root.
        Multi-device: SN-named subdirectories each containing Trilogy/ and/or P-Series/.
    #>
    param([string]$SDCardPath)

    # Check for native layout (Trilogy/ or P-Series/ at root)
    $hasTrilogyAtRoot  = Test-Path (Join-Path $SDCardPath 'Trilogy')
    $hasPSeriesAtRoot  = Test-Path (Join-Path $SDCardPath 'P-Series')

    if ($hasTrilogyAtRoot -or $hasPSeriesAtRoot) {
        # Native layout — detect device SN from P-Series/last.txt or EDF headers
        $devices = [System.Collections.Generic.List[string]]::new()
        $lastTxt = Join-Path $SDCardPath 'P-Series\last.txt'
        if (Test-Path $lastTxt) {
            $sn = (Get-Content $lastTxt -Raw).Trim()
            if ($sn) { $devices.Add($sn) }
        }
        # Fallback: look at P-Series subdirectories that look like serial numbers
        if ($devices.Count -eq 0) {
            $psRoot = Join-Path $SDCardPath 'P-Series'
            if (Test-Path $psRoot) {
                Get-ChildItem -LiteralPath $psRoot -Directory | Where-Object { $_.Name -match '^TV' } |
                    ForEach-Object { $devices.Add($_.Name) }
            }
        }
        return [PSCustomObject]@{ Layout = 'native'; Devices = @($devices) }
    }

    # Multi-device layout — look for subdirectories containing Trilogy/ or P-Series/
    $devices = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in Get-ChildItem -LiteralPath $SDCardPath -Directory -ErrorAction SilentlyContinue) {
        $hasTri = Test-Path (Join-Path $dir.FullName 'Trilogy')
        $hasPS  = Test-Path (Join-Path $dir.FullName 'P-Series')
        if ($hasTri -or $hasPS) {
            $devices.Add($dir.Name)
        }
    }

    if ($devices.Count -gt 0) {
        return [PSCustomObject]@{ Layout = 'multi-device'; Devices = @($devices) }
    }

    return [PSCustomObject]@{ Layout = $null; Devices = @() }
}

function _ComputeSDHashes {
    <#
    .SYNOPSIS
        Walk all data files on the SD card and compute MD5 hashes.
        Returns a hashtable keyed by "SN|relPath" matching the golden manifest format.
    #>
    param([string]$SDCardPath, [object]$Layout)

    $hashes = @{}

    if ($Layout.Layout -eq 'native') {
        $sn = if ($Layout.Devices.Count -gt 0) { $Layout.Devices[0] } else { 'UNKNOWN' }

        # Trilogy files
        $triDir = Join-Path $SDCardPath 'Trilogy'
        if (Test-Path $triDir) {
            foreach ($f in Get-ChildItem -LiteralPath $triDir -File -Recurse) {
                $rel  = "Trilogy/$($f.Name)"
                $hash = (Get-FileHash -Path $f.FullName -Algorithm MD5).Hash
                $hashes["$sn|$rel"] = $hash
            }
        }

        # P-Series files — stored as P-Series/{SN}/... in manifest
        $psRoot = Join-Path $SDCardPath 'P-Series'
        if (Test-Path $psRoot) {
            foreach ($snDir in Get-ChildItem -LiteralPath $psRoot -Directory -ErrorAction SilentlyContinue) {
                foreach ($f in Get-ChildItem -LiteralPath $snDir.FullName -File -Recurse) {
                    $rel  = $f.FullName.Substring($psRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                    $hash = (Get-FileHash -Path $f.FullName -Algorithm MD5).Hash
                    $hashes["$sn|P-Series/$rel"] = $hash
                }
            }
        }
    } else {
        # Multi-device layout
        foreach ($sn in $Layout.Devices) {
            $snDir = Join-Path $SDCardPath $sn

            # Trilogy files
            $triDir = Join-Path $snDir 'Trilogy'
            if (Test-Path $triDir) {
                foreach ($f in Get-ChildItem -LiteralPath $triDir -File -Recurse) {
                    $rel  = "Trilogy/$($f.Name)"
                    $hash = (Get-FileHash -Path $f.FullName -Algorithm MD5).Hash
                    $hashes["$sn|$rel"] = $hash
                }
            }

            # P-Series files
            $psRoot = Join-Path $snDir 'P-Series'
            if (Test-Path $psRoot) {
                foreach ($snSubDir in Get-ChildItem -LiteralPath $psRoot -Directory -ErrorAction SilentlyContinue) {
                    foreach ($f in Get-ChildItem -LiteralPath $snSubDir.FullName -File -Recurse) {
                        $rel  = $f.FullName.Substring($psRoot.Length).TrimStart('\', '/') -replace '\\', '/'
                        $hash = (Get-FileHash -Path $f.FullName -Algorithm MD5).Hash
                        $hashes["$sn|P-Series/$rel"] = $hash
                    }
                }
            }
        }
    }

    return $hashes
}

function _ValidateWithManifest {
    <#
    .SYNOPSIS
        Validate a folder that contains a manifest.json by recomputing hashes of every
        listed file and comparing against the manifest's recorded hashes.
        Used when the target IS a local golden archive (or any path with a manifest).
    #>
    param([string]$TargetPath, [string]$ManifestPath)

    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $isNative = $manifest.PSObject.Properties['nativeLayout'] -and $manifest.nativeLayout

    $failures   = [System.Collections.Generic.List[string]]::new()
    $fileCount  = 0
    $deviceList = [System.Collections.Generic.List[string]]::new()

    foreach ($snProp in $manifest.devices.PSObject.Properties) {
        $sn  = $snProp.Name
        $dev = $snProp.Value
        $deviceList.Add($sn)

        foreach ($hashProp in $dev.fileHashes.PSObject.Properties) {
            $relPath  = $hashProp.Name
            $expected = $hashProp.Value
            $fullPath = if ($isNative) { Join-Path $TargetPath $relPath } else { Join-Path $TargetPath "$sn\$relPath" }
            $fileCount++

            if (-not (Test-Path $fullPath)) {
                $failures.Add("MISSING: $sn|$relPath (expected at $fullPath)")
                continue
            }

            $actual = (Get-FileHash -Path $fullPath -Algorithm MD5).Hash
            if ($actual -ne $expected) {
                $failures.Add("CORRUPTED: $sn|$relPath (computed=$actual, manifest=$expected)")
            }
        }
    }

    $layout = if ($isNative) { 'native' } else { 'multi-device' }

    return [PSCustomObject]@{
        Passed          = ($failures.Count -eq 0)
        FileCount       = $fileCount
        ComputedHashes  = @{}
        DetectedLayout  = $layout
        DetectedDevices = @($deviceList)
        ReferenceGolden = $TargetPath       # self-referencing: validated against own manifest
        AutoDiscovered  = $false
        Mismatches      = $failures.ToArray()
        ExtraOnCard     = @()
        MissingFromCard = @()
    }
}

#endregion

#region ── Find-MatchingGolden ──────────────────────────────────────────────

function Find-MatchingGolden {
    <#
    .SYNOPSIS
        Auto-discover which local golden archive matches a set of computed file hashes.
    .DESCRIPTION
        Searches the given paths for _golden_* directories and performs order-independent
        comparison of file-hash sets. Returns the path of the first matching golden, or
        $null if no match is found.
    .PARAMETER ComputedHashes
        Hashtable keyed by "SN|relPath" → MD5 hash (computed from SD card files).
    .PARAMETER SearchPaths
        Directories to scan for _golden_* folders.
    .PARAMETER AllowPartial
        When set, return the best-matching golden even if not all hashes agree.
        Used for deep-diff analysis when an exact match isn't found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ComputedHashes,
        [Parameter(Mandatory)][string[]]$SearchPaths,
        [switch]$AllowPartial
    )

    # Scan all search paths for golden archives
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($searchPath in $SearchPaths) {
        if (-not (Test-Path $searchPath)) { continue }
        $found = @(Get-ChildItem -LiteralPath $searchPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^_golden_' } |
            Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') })
        foreach ($item in $found) { $candidates.Add($item.FullName) }
    }

    # Extract device SNs from the computed hashes for quick filtering
    $computedSNs = @($ComputedHashes.Keys | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique)

    $bestMatch      = $null
    $bestMatchCount = 0

    foreach ($candidatePath in $candidates) {
        $cManifestPath = Join-Path $candidatePath 'manifest.json'
        try {
            $cManifest = Get-Content $cManifestPath -Raw | ConvertFrom-Json
        } catch { continue }

        # Quick filter: at least one overlapping device SN
        $cSNs = @($cManifest.devices.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        $overlap = @($computedSNs | Where-Object { $cSNs -contains $_ })
        if ($overlap.Count -eq 0) { continue }

        # Build reference lookup from this candidate
        $refLookup = @{}
        foreach ($snProp in $cManifest.devices.PSObject.Properties) {
            $sn  = $snProp.Name
            $dev = $snProp.Value
            foreach ($hashProp in $dev.fileHashes.PSObject.Properties) {
                $refLookup["$sn|$($hashProp.Name)"] = $hashProp.Value
            }
        }

        # Order-independent comparison
        $matchCount = 0
        $totalKeys  = [Math]::Max($ComputedHashes.Count, $refLookup.Count)
        $isExact    = $true

        if ($ComputedHashes.Count -ne $refLookup.Count) { $isExact = $false }

        foreach ($key in $ComputedHashes.Keys) {
            if ($refLookup.ContainsKey($key) -and $ComputedHashes[$key] -eq $refLookup[$key]) {
                $matchCount++
            } else {
                $isExact = $false
            }
        }
        # Check for keys in ref but not in computed
        if ($isExact) {
            foreach ($key in $refLookup.Keys) {
                if (-not $ComputedHashes.ContainsKey($key)) {
                    $isExact = $false
                    break
                }
            }
        }

        if ($isExact) {
            return $candidatePath
        }

        if ($AllowPartial -and $matchCount -gt $bestMatchCount) {
            $bestMatchCount = $matchCount
            $bestMatch      = $candidatePath
        }
    }

    if ($AllowPartial -and $bestMatch) {
        return $bestMatch
    }

    return $null
}

#endregion

Export-ModuleMember -Function @(
    'Export-ToTarget',
    'Show-TargetContents',
    'Write-ExportReadme',
    'Test-SDCardIntegrity',
    'Find-MatchingGolden'
)
