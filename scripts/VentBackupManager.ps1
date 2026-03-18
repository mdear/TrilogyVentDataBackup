# VentBackupManager.ps1 — Entry point for the Vent Backup Manager tool
# Usage: .\VentBackupManager.ps1 [-Action <verb>] [options]
# If no -Action is provided, launches the interactive wizard.
# Always run with -File, not -Command, to avoid variable interpolation issues.

[CmdletBinding()]
param(
    [ValidateSet('Analyze','Backup','Golden','Export','Prepare','Compact')]
    [string]$Action,

    # Shared
    [string]$BackupRoot,

    # Backup (ingest)
    [string]$Source,

    # Golden archive
    [string]$GoldenRoot,
    [string[]]$Devices,

    # Forced device override — bypasses changed-data detection
    [string[]]$ForceDevices,
    [string]$ForceReason,

    # Export / Prepare
    [string]$GoldenPath,
    [string]$Target,

    # Compact
    [string]$SafetyBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Module imports ────────────────────────────────────────────────────────────
$modulesDir = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modulesDir 'VBM-Parsers.psm1')       -Force
Import-Module (Join-Path $modulesDir 'VBM-Analyzer.psm1')      -Force
Import-Module (Join-Path $modulesDir 'VBM-GoldenArchive.psm1') -Force
Import-Module (Join-Path $modulesDir 'VBM-Export.psm1')        -Force
Import-Module (Join-Path $modulesDir 'VBM-Backup.psm1')        -Force
Import-Module (Join-Path $modulesDir 'VBM-Dedup.psm1')         -Force
Import-Module (Join-Path $modulesDir 'VBM-UI.psm1')            -Force

# ── Helper: resolve BackupRoot ────────────────────────────────────────────────
function _ResolveBackupRoot {
    param([string]$Given)
    if ($Given) { return $Given }
    # Default: the parent of this script (workspace root)
    return (Split-Path $PSScriptRoot -Parent)
}

# ── Helper: run Analyze ───────────────────────────────────────────────────────
function _RunAnalyze {
    param([string]$Root)
    $Root = _ResolveBackupRoot $Root
    Write-Host "Scanning backup root: $Root" -ForegroundColor Cyan
    $inv = @(Get-BackupInventory -BackupRoot $Root)
    if ($inv.Count -eq 0) {
        Write-Host "No backup folders found in: $Root" -ForegroundColor Yellow
        return $null
    }
    Write-Host "Found $($inv.Count) top-level backup(s). Building TOC..."
    $progress = {
        param([string]$msg, [int]$cur, [int]$tot)
        Write-ProgressBar -Activity $msg -Current $cur -Total $tot
    }
    $toc = Get-BackupTOC -Inventory $inv -ProgressCallback $progress
    Write-Host ''   # newline after progress bar
    Show-TOC -TOC $toc

    # Detect split SD cards (annotates TOC.Devices[*].SplitSD for golden selection)
    $null = Find-SplitSD -TOC $toc

    # Write contamination READMEs for any contaminated backup
    foreach ($bName in $toc.Backups.Keys) {
        $b = $toc.Backups[$bName]
        if ($b.Integrity -eq 'Contaminated') {
            Write-ContaminationReadme -BackupPath $b.Path -Anomalies $b.Anomalies -TOC $toc
        }
    }

    # Show any existing golden archives found in the backup root
    $goldens = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^_golden_' } |
                 Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } |
                 Sort-Object Name)
    if ($goldens.Count -gt 0) {
        Write-Host ''
        Write-Host '  Golden archives in this backup root:' -ForegroundColor Cyan
        foreach ($gDir in $goldens) {
            $mPath = Join-Path $gDir.FullName 'manifest.json'
            try {
                $m       = Get-Content $mPath -Raw | ConvertFrom-Json
                $seq     = $m.goldenSequence
                $created = $m.created
                $devList = ($m.devices.PSObject.Properties.Name) -join ', '
                Write-Host "    $($gDir.Name)  [seq=$seq  created=$created  devices: $devList]"
            } catch {
                Write-Host "    $($gDir.Name)  [manifest unreadable]" -ForegroundColor Yellow
            }
        }
    }

    return $toc
}

# ── Helper: resolve or discover an existing golden archive ────────────────────
function _FindLatestGolden {
    param([string]$Root)
    $goldens = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^_golden_' } |
                 Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } |
                 Sort-Object Name -Descending)
    if ($goldens.Count -gt 0) { return $goldens[0].FullName }
    return $null
}

# ── Helper: run Prepare (Golden + Export combined) ────────────────────────────
function _RunPrepare {
    param(
        [string]$Root,
        [string]$GoldenRootIn,
        [string]$TargetIn,
        [string[]]$DevicesIn,
        [string[]]$ForceDevicesIn,
        [string]$ForceReasonIn
    )

    $Root = _ResolveBackupRoot $Root
    $toc  = _RunAnalyze -Root $Root
    if (-not $toc) { return }

    $gRoot = if ($GoldenRootIn) { $GoldenRootIn } else { $Root }

    $existing = _FindLatestGolden -Root $gRoot
    $suggested = if ($existing) {
        Write-Host ''
        Write-Host "Existing golden found: $existing" -ForegroundColor Cyan
        # Suggest devices with NEW or CHANGED data since the last golden.
        # "Changed" means: a new file exists, or a file is larger (better tip), or hash differs.
        $manifest    = Get-Content (Join-Path $existing 'manifest.json') -Raw | ConvertFrom-Json
        $cleanNames  = @($toc.Backups.Keys | Where-Object { $toc.Backups[$_].Integrity -ne 'Contaminated' })
        $changedList = [System.Collections.Generic.List[string]]::new()
        foreach ($sn in $toc.Devices.Keys) {
            $snProp    = $manifest.devices.PSObject.Properties[$sn]
            $prevDevice = if ($snProp) { $snProp.Value } else { $null }
            if (-not $prevDevice) { $changedList.Add($sn); continue }   # New device
            $bestFiles = @{}
            foreach ($bName in $cleanNames) {
                $bkp = $toc.Backups[$bName]
                if (-not $bkp.Devices.ContainsKey($sn)) { continue }
                foreach ($f in $bkp.Devices[$sn].TrilogyFiles) {
                    $cur = $bestFiles[$f.FileName]
                    if (-not $cur -or $f.Size -gt $cur.Size) { $bestFiles[$f.FileName] = $f }
                }
            }
            $hasChange = $false
            foreach ($fname in $bestFiles.Keys) {
                $hProp    = $prevDevice.fileHashes.PSObject.Properties["Trilogy/$fname"]
                $prevHash = if ($hProp) { $hProp.Value } else { $null }
                if (-not $prevHash) { $hasChange = $true; break }
                $curHash  = (Get-FileHash -Path $bestFiles[$fname].Path -Algorithm MD5).Hash
                if ($curHash -ne $prevHash) { $hasChange = $true; break }
            }
            if ($hasChange) { $changedList.Add($sn) }
        }
        if ($changedList.Count -gt 0) { $changedList.ToArray() } else { @($toc.Devices.Keys) }
    } else {
        @($toc.Devices.Keys)   # First golden: all devices
    }

    # ── ForceDevices prompt (wizard path only — CLI path supplies params directly) ──
    $effectiveForceDevices = $ForceDevicesIn
    $effectiveForceReason  = $ForceReasonIn

    # In wizard mode (no CLI params given) offer the override prompt
    if ((-not $ForceDevicesIn -or $ForceDevicesIn.Count -eq 0) -and (-not $DevicesIn -or $DevicesIn.Count -eq 0)) {
        $forceResult = Show-ForceDevicesPrompt -Devices $toc.Devices
        if ($forceResult.ForceDevices) {
            $effectiveForceDevices = $forceResult.SelectedSNs
            $effectiveForceReason  = $forceResult.Reason
        }
    }

    # Device selection: ForceDevices skips Show-DeviceSelection; otherwise let user confirm
    $selectedSNs = if ($effectiveForceDevices -and $effectiveForceDevices.Count -gt 0) {
        $effectiveForceDevices
    } elseif ($DevicesIn -and $DevicesIn.Count -gt 0) {
        $DevicesIn
    } else {
        Show-DeviceSelection -Devices $toc.Devices -Suggested $suggested
    }
    if (@($selectedSNs).Count -eq 0) { Write-Host 'No devices selected. Aborting.'; return }

    # Build golden
    $goldenOut = if ($existing) {
        Update-GoldenArchive -TOC $toc -GoldenRoot $gRoot -PreviousGolden $existing `
            -ForceDevices $effectiveForceDevices -ForceReason $effectiveForceReason
    } else {
        New-GoldenArchive -TOC $toc -GoldenRoot $gRoot -Devices $selectedSNs `
            -ForceDevices $effectiveForceDevices -ForceReason $effectiveForceReason
    }

    # Export to target
    $tgtPath = if ($TargetIn) { $TargetIn } else {
        Read-ValidatedPath -Prompt 'Target path for export (SD card or folder)'
    }

    if (Test-Path $tgtPath) {
        $items = @(Get-ChildItem -LiteralPath $tgtPath)
        if ($items.Count -gt 0) {
            Show-TargetContents -Target $tgtPath
            if (-not (Read-YesNo -Prompt 'Target already has content. Overwrite?' -Default $false)) {
                Write-Host 'Export cancelled.' -ForegroundColor Yellow
                return
            }
        }
    }

    Export-ToTarget -GoldenPath $goldenOut -Target $tgtPath -Devices $selectedSNs
}

# ── CLI dispatch ──────────────────────────────────────────────────────────────

if ($Action) {
    switch ($Action) {
        'Analyze' {
            _RunAnalyze -Root $BackupRoot
        }
        'Backup' {
            if (-not $Source) { throw '-Source is required for Backup action.' }
            $root   = _ResolveBackupRoot $BackupRoot
            $newBak = Import-SDCard -Source $Source -BackupRoot $root
            Write-Host "New backup at: $newBak"
            $toc = _RunAnalyze -Root $root
        }
        'Golden' {
            $root  = _ResolveBackupRoot $BackupRoot
            $toc   = _RunAnalyze -Root $root
            Find-SplitSD -TOC $toc
            $gRoot = if ($GoldenRoot) { $GoldenRoot } else { $root }
            $exist = _FindLatestGolden -Root $gRoot
            if ($exist) {
                Update-GoldenArchive -TOC $toc -GoldenRoot $gRoot -PreviousGolden $exist `
                    -ForceDevices $ForceDevices -ForceReason $ForceReason
            } else {
                New-GoldenArchive -TOC $toc -GoldenRoot $gRoot -Devices $Devices `
                    -ForceDevices $ForceDevices -ForceReason $ForceReason
            }
        }
        'Export' {
            if (-not $GoldenPath) { throw '-GoldenPath is required for Export action.' }
            if (-not $Target)     { throw '-Target is required for Export action.' }
            if (Test-Path $Target) {
                Show-TargetContents -Target $Target
            }
            Export-ToTarget -GoldenPath $GoldenPath -Target $Target -Devices $Devices
        }
        'Prepare' {
            _RunPrepare -Root $BackupRoot -GoldenRootIn $GoldenRoot -TargetIn $Target -DevicesIn $Devices `
                -ForceDevicesIn $ForceDevices -ForceReasonIn $ForceReason
        }
        'Compact' {
            $root = _ResolveBackupRoot $BackupRoot
            if (-not $SafetyBackup) { throw '-SafetyBackup is required for Compact action.' }
            if (-not (Read-YesNo -Prompt 'Compact will create NTFS hardlinks. Continue?' -Default $false)) {
                Write-Host 'Compaction cancelled.'; exit 0
            }
            Invoke-Compaction -BackupRoot $root -SafetyPath $SafetyBackup
        }
    }
    exit 0
}

# ── Wizard mode ───────────────────────────────────────────────────────────────

# ── First-time setup: desktop shortcut ───────────────────────────────────────
function _CheckDesktopShortcut {
    $settingsFile = if ($env:VBM_SETTINGS_OVERRIDE) { $env:VBM_SETTINGS_OVERRIDE } else { Join-Path $PSScriptRoot 'settings.json' }
    $settings = if (Test-Path $settingsFile) {
        Get-Content $settingsFile -Raw | ConvertFrom-Json
    } else { [pscustomobject]@{} }

    if ($settings.PSObject.Properties['skipShortcutPrompt'] -and $settings.skipShortcutPrompt) { return }

    $desktopDir = if ($env:VBM_DESKTOP_OVERRIDE) { $env:VBM_DESKTOP_OVERRIDE } else { [Environment]::GetFolderPath('Desktop') }
    $lnk = Join-Path $desktopDir 'Ventilator Backup Manager.lnk'
    if (Test-Path $lnk) { return }

    Write-Host ''
    Write-Host '  No Desktop shortcut found.' -ForegroundColor Yellow
    Write-Host '  Would you like one so you can start this tool without opening this folder?'
    Write-Host ''
    Write-Host '    Y = Yes, create it now'
    Write-Host '    N = Not now  (you will be asked again next time)'
    Write-Host '    X = No, and never ask again'
    Write-Host ''
    $answer = (Read-Host '  Your choice [Y/N/X]').Trim().ToUpper()

    switch ($answer) {
        'Y' {
            $installer = Join-Path $PSScriptRoot 'Install-DesktopShortcut.ps1'
            if (Test-Path $installer) {
                & $installer
                Write-Host '  Desktop shortcut created.' -ForegroundColor Green
            } else {
                Write-Host "  Could not find Install-DesktopShortcut.ps1 — skipping." -ForegroundColor Yellow
            }
        }
        'X' {
            $settings | Add-Member -NotePropertyName skipShortcutPrompt -NotePropertyValue $true -Force
            $settings | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
            Write-Host '  OK — will not ask again.' -ForegroundColor DarkGray
        }
        default { <# N or anything else: skip silently, ask again next time #> }
    }
    Write-Host ''
}

_CheckDesktopShortcut

# ── Load persisted settings (written by _CheckDesktopShortcut and case 7) ────
$_wizSettingsFile = if ($env:VBM_SETTINGS_OVERRIDE) { $env:VBM_SETTINGS_OVERRIDE } else { Join-Path $PSScriptRoot 'settings.json' }
$_wizSettings = if (Test-Path $_wizSettingsFile) {
    Get-Content $_wizSettingsFile -Raw | ConvertFrom-Json
} else { [pscustomobject]@{} }

# CLI -BackupRoot takes priority, then saved setting, then workspace root
$backupRootDefault = if ($BackupRoot) {
    $BackupRoot
} elseif ($_wizSettings.PSObject.Properties['backupRoot'] -and $_wizSettings.backupRoot) {
    $_wizSettings.backupRoot
} else {
    Split-Path $PSScriptRoot -Parent
}
# Remember where goldens were last built — persists across backup-root changes
$_wizGoldenRoot = if ($_wizSettings.PSObject.Properties['goldenRoot'] -and $_wizSettings.goldenRoot) {
    $_wizSettings.goldenRoot
} else { $null }
Write-Host "Using backup root: $backupRootDefault" -ForegroundColor DarkGray

while ($true) {
    $choice = Show-MainMenu -BackupRoot $backupRootDefault
    if ($choice -eq 0) { Write-Host 'Goodbye.'; break }

    try {
        switch ($choice) {
            1 {
                # Analyze
                _RunAnalyze -Root $backupRootDefault
            }
            2 {
                # Prepare (Golden + Export)
                _RunPrepare -Root $backupRootDefault -GoldenRootIn $null -TargetIn $null -DevicesIn $null
                # Persist the golden root so Validate can find it even if backup root changes later
                $_wizGoldenRoot = $backupRootDefault
                $_wizSettings | Add-Member -NotePropertyName goldenRoot -NotePropertyValue $_wizGoldenRoot -Force
                $_wizSettings | ConvertTo-Json | Set-Content $_wizSettingsFile -Encoding UTF8
            }
            3 {
                # Golden Archive only
                $toc   = _RunAnalyze -Root $backupRootDefault
                if (-not $toc) { continue }
                Find-SplitSD -TOC $toc
                $gRoot = $backupRootDefault
                $exist = _FindLatestGolden -Root $gRoot

                # Offer ForceDevices override before device selection
                $wForceDevices = $null
                $wForceReason  = $null
                $forceResult   = Show-ForceDevicesPrompt -Devices $toc.Devices
                if ($forceResult.ForceDevices) {
                    $wForceDevices = $forceResult.SelectedSNs
                    $wForceReason  = $forceResult.Reason
                }

                $snList = if ($wForceDevices -and $wForceDevices.Count -gt 0) {
                    $wForceDevices
                } else {
                    Show-DeviceSelection -Devices $toc.Devices -Suggested @($toc.Devices.Keys)
                }
                if (@($snList).Count -eq 0) { Write-Host 'No devices selected. Aborting.'; continue }

                if ($exist) {
                    Update-GoldenArchive -TOC $toc -GoldenRoot $gRoot -PreviousGolden $exist `
                        -ForceDevices $wForceDevices -ForceReason $wForceReason
                } else {
                    New-GoldenArchive -TOC $toc -GoldenRoot $gRoot -Devices $snList `
                        -ForceDevices $wForceDevices -ForceReason $wForceReason
                }
                # Persist the golden root so Validate can find it even if backup root changes later
                $_wizGoldenRoot = $gRoot
                $_wizSettings | Add-Member -NotePropertyName goldenRoot -NotePropertyValue $_wizGoldenRoot -Force
                $_wizSettings | ConvertTo-Json | Set-Content $_wizSettingsFile -Encoding UTF8
            }
            4 {
                # Back Up SD Card
                Write-Host ''
                Write-Host '  You can select a physical drive or enter any folder that' -ForegroundColor DarkGray
                Write-Host '  already contains Trilogy/ and/or P-Series/ subdirectories.' -ForegroundColor DarkGray
                $sdPath = Show-SourcePicker
                Import-SDCard -Source $sdPath -BackupRoot $backupRootDefault
                Write-Host ''
                if (Read-YesNo -Prompt 'Run Analyze to see updated table of contents?' -Default $true) {
                    _RunAnalyze -Root $backupRootDefault
                }
            }
            5 {
                # Compact
                Write-Host ''
                Write-Host '  CAUTION: Compact creates NTFS hardlinks and modifies the backup tree.' -ForegroundColor Yellow
                Write-Host '  You will need a safety backup path (external drive recommended).' -ForegroundColor Yellow
                Write-Host ''
                if (-not (Read-YesNo -Prompt 'Continue with Compact?' -Default $false)) {
                    Write-Host 'Cancelled.'; continue
                }
                $safetyPath = Read-ValidatedPath -Prompt 'Safety backup destination path'
                Invoke-Compaction -BackupRoot $backupRootDefault -SafetyPath $safetyPath
            }
            7 {
                # Settings — change backup root
                Write-Host ''
                Write-Host "  Current backup root: $backupRootDefault" -ForegroundColor Cyan
                Write-Host '  Enter a new path, or leave blank to cancel.' -ForegroundColor DarkGray
                Write-Host ''
                $raw = (Read-Host '  New backup root').Trim().Trim('"', "'")
                if ($raw) {
                    $raw = $raw -replace '^~', $HOME
                    if (-not (Test-Path $raw)) {
                        Write-Host "  Path not found: $raw" -ForegroundColor Yellow
                    } else {
                        $backupRootDefault = $raw
                        Write-Host "  Backup root changed to: $backupRootDefault" -ForegroundColor Green
                        if (Read-YesNo -Prompt '  Save as default for future sessions?' -Default $true) {
                            $_wizSettings | Add-Member -NotePropertyName backupRoot -NotePropertyValue $backupRootDefault -Force
                            $_wizSettings | ConvertTo-Json | Set-Content $_wizSettingsFile -Encoding UTF8
                            Write-Host '  Saved.' -ForegroundColor Green
                        }
                    }
                }
            }
            6 {
                # Validate selected backup folder(s) and/or golden archive(s)
                $toc = _RunAnalyze -Root $backupRootDefault
                if (-not $toc) { continue }

                # Build unified entry list: backup folders + golden archives
                # Each entry: @{ Label; Kind ('backup'|'golden'); Key (backup name or golden path) }
                $entries = [System.Collections.Generic.List[hashtable]]::new()

                foreach ($bName in ($toc.Backups.Keys | Sort-Object)) {
                    $status = $toc.Backups[$bName].Integrity
                    $entries.Add(@{ Label = "$bName  ($status)"; Kind = 'backup'; Key = $bName })
                }

                # Scan backup root AND the saved golden root (they differ when the backup root
                # was changed after a golden was built, or when using the test-data path).
                $goldenSearchPaths = [System.Collections.Generic.List[string]]::new()
                $goldenSearchPaths.Add($backupRootDefault)
                if ($_wizGoldenRoot -and $_wizGoldenRoot -ne $backupRootDefault -and (Test-Path $_wizGoldenRoot)) {
                    $goldenSearchPaths.Add($_wizGoldenRoot)
                }
                $goldenItems = [System.Collections.Generic.List[object]]::new()
                foreach ($gsp in $goldenSearchPaths) {
                    $found = @(Get-ChildItem -LiteralPath $gsp -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^_golden_' } |
                        Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') })
                    foreach ($item in $found) { $goldenItems.Add($item) }
                }
                $goldens = @($goldenItems | Group-Object FullName | ForEach-Object { $_.Group[0] } | Sort-Object Name)
                foreach ($g in $goldens) {
                    $entries.Add(@{ Label = "$($g.Name)  [golden]"; Kind = 'golden'; Key = $g.FullName })
                }

                if ($entries.Count -eq 0) {
                    Write-Host '  No backup or golden archive folders found.' -ForegroundColor Yellow; continue
                }

                Write-Host ''
                Write-Host '  Select folder(s) to validate:' -ForegroundColor Cyan
                Write-Host ''
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    $e      = $entries[$i]
                    $colour = if ($e.Kind -eq 'golden') { 'Cyan' `
                              } elseif ($e.Label -match 'Contaminated') { 'Yellow' `
                              } else { 'Gray' }
                    Write-Host ("  [{0,2}] {1}" -f ($i + 1), $e.Label) -ForegroundColor $colour
                }
                Write-Host ''
                Write-Host '  [A] All listed above' -ForegroundColor Cyan
                Write-Host ''
                $raw = (Read-Host '  Enter number(s) separated by commas, or A for all').Trim().ToUpperInvariant()
                if (-not $raw) { continue }

                $selectedEntries = if ($raw -eq 'A') {
                    $entries.ToArray()
                } else {
                    $indices = $raw -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
                    @($indices | ForEach-Object {
                        $idx = [int]$_ - 1
                        if ($idx -ge 0 -and $idx -lt $entries.Count) { $entries[$idx] }
                    })
                }

                if (@($selectedEntries).Count -eq 0) {
                    Write-Host '  No valid selection.' -ForegroundColor Yellow; continue
                }

                Write-Host ''
                foreach ($e in $selectedEntries) {
                    if ($e.Kind -eq 'golden') {
                        # Golden archive: integrity hash check + deep content validation
                        $gPath = $e.Key
                        Write-Host "  $($e.Label)" -ForegroundColor Cyan

                        $integ = Test-GoldenIntegrity -GoldenPath $gPath
                        if ($integ.Passed) {
                            Write-Host "    Integrity check: PASSED ($($integ.FileCount) files verified)" -ForegroundColor Green
                        } else {
                            Write-Host "    Integrity check: FAILED — $($integ.Failures.Count) issue(s)" -ForegroundColor Red
                            foreach ($f in $integ.Failures | Select-Object -First 5) {
                                Write-Host "      • $f" -ForegroundColor Red
                            }
                        }

                        $content = Test-GoldenContent -GoldenPath $gPath
                        if ($content.Passed) {
                            Write-Host "    Content validation: PASSED ($($content.FileCount) files, $($content.WarningCount) warning(s))" -ForegroundColor Green
                        } else {
                            $nErr = $content.CriticalCount + $content.ErrorCount
                            Write-Host "    Content validation: $nErr issue(s) — $($content.CriticalCount) Critical, $($content.ErrorCount) Error, $($content.WarningCount) Warning" -ForegroundColor Red
                        }
                        # Always show warnings and errors so none are silently swallowed
                        $allIssues = @($content.Issues)
                        if ($allIssues.Count -gt 0) {
                            foreach ($issue in $allIssues | Select-Object -First 15) {
                                $ic = switch ($issue.Severity) { 'Critical' { 'Red' } 'Error' { 'Yellow' } default { 'DarkYellow' } }
                                Write-Host "      [$($issue.Severity.ToUpper())] $($issue.Category) $($issue.Device) $($issue.File): $($issue.Message)" -ForegroundColor $ic
                            }
                            if ($allIssues.Count -gt 15) {
                                Write-Host "      ... and $($allIssues.Count - 15) more issue(s)." -ForegroundColor DarkGray
                            }
                        }
                    } else {
                        # Regular backup folder: contamination / anomaly check
                        $b      = $toc.Backups[$e.Key]
                        $result = Test-BackupIntegrity -BackupDetail $b -TOC $toc
                        $colour = if ($result.Integrity -eq 'Clean') { 'Green' } else { 'Yellow' }
                        Write-Host ("  {0,-30} — {1}" -f $e.Key, $result.Integrity) -ForegroundColor $colour

                        $anomalies = @($result.Anomalies)
                        if ($anomalies.Count -eq 0) {
                            Write-Host '    No anomalies found.' -ForegroundColor DarkGray
                        } else {
                            # Group by (Type, Detail) so duplicate messages are collapsed with a file count
                            $groups = @($anomalies | Group-Object { "$($_.Type)|$($_.Detail)" } |
                                        Sort-Object {
                                            $sev = switch ($_.Group[0].Severity) { 'High' { 0 } 'Medium' { 1 } default { 2 } }
                                            $typ = switch ($_.Group[0].Type) {
                                                'Contamination'      { 0 }
                                                'TruncatedFile'      { 1 }
                                                'PSeriesConsistency' { 2 }
                                                'SizeRegression'     { 3 }
                                                'MissingPair'        { 4 }
                                                default              { 5 }
                                            }
                                            $sev * 10 + $typ
                                        })
                            $shownFiles = 0
                            foreach ($grp in $groups | Select-Object -First 10) {
                                $a         = $grp.Group[0]
                                $ac        = switch ($a.Severity) { 'High' { 'Red' } 'Medium' { 'Yellow' } default { 'DarkGray' } }
                                $countNote = if ($grp.Count -gt 1) { " [$($grp.Count) files]" } else { '' }
                                Write-Host "    [$($a.Type)] $($a.Detail)$countNote" -ForegroundColor $ac
                                $shownFiles += $grp.Count
                            }
                            $remaining = $anomalies.Count - $shownFiles
                            if ($remaining -gt 0) {
                                $word = if ($remaining -eq 1) { 'anomaly' } else { 'anomalies' }
                                Write-Host "    ... and $remaining more $word." -ForegroundColor DarkGray
                            }
                        }
                    }
                    Write-Host ''
                }
            }
        }
    } catch {
        Write-Host ''
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host ''
    }

    Write-Host ''
    Read-Host 'Press Enter to return to main menu' | Out-Null
}
