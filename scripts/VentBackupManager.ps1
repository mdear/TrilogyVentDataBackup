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
    $inv = Get-BackupInventory -BackupRoot $Root
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

    # Write contamination READMEs for any contaminated backup
    foreach ($bName in $toc.Backups.Keys) {
        $b = $toc.Backups[$bName]
        if ($b.Integrity -eq 'Contaminated') {
            Write-ContaminationReadme -BackupPath $b.Path -Anomalies $b.Anomalies -TOC $toc
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
            Detect-SplitSD -TOC $toc
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
    $settingsFile = Join-Path $PSScriptRoot 'settings.json'
    $settings = if (Test-Path $settingsFile) {
        Get-Content $settingsFile -Raw | ConvertFrom-Json
    } else { [pscustomobject]@{} }

    if ($settings.PSObject.Properties['skipShortcutPrompt'] -and $settings.skipShortcutPrompt) { return }

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Ventilator Backup Manager.lnk'
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

$backupRootDefault = _ResolveBackupRoot $BackupRoot
Write-Host "Using backup root: $backupRootDefault" -ForegroundColor DarkGray

while ($true) {
    $choice = Show-MainMenu
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
            }
            3 {
                # Golden Archive only
                $toc   = _RunAnalyze -Root $backupRootDefault
                if (-not $toc) { continue }
                Detect-SplitSD -TOC $toc
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
            }
            4 {
                # Back Up SD Card
                $sdPath = Read-ValidatedPath -Prompt 'SD card path (e.g. E:\)' -MustExist
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
            6 {
                # Contamination README for a specific backup
                $toc = _RunAnalyze -Root $backupRootDefault
                if (-not $toc) { continue }
                $contaminated = @($toc.Backups.Keys | Where-Object { $toc.Backups[$_].Integrity -eq 'Contaminated' })
                if ($contaminated.Count -eq 0) {
                    Write-Host 'No contaminated backups found.' -ForegroundColor Green
                } else {
                    Write-Host "Contaminated backups: $($contaminated -join ', ')" -ForegroundColor Yellow
                    foreach ($bName in $contaminated) {
                        $b = $toc.Backups[$bName]
                        Write-ContaminationReadme -BackupPath $b.Path -Anomalies $b.Anomalies -TOC $toc
                    }
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
