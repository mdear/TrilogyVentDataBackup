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

    if ($isSingle) {
        _ExportSingleDevice -SN $snList[0] -GoldenPath $GoldenPath -Target $Target
    } else {
        foreach ($sn in $snList) {
            $snTarget = Join-Path $Target $sn
            $null = New-Item -ItemType Directory -Path $snTarget -Force
            _ExportSingleDevice -SN $sn -GoldenPath $GoldenPath -Target $snTarget
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
    param([string]$SN, [string]$GoldenPath, [string]$Target)

    Write-Host "  Exporting $SN ..." -ForegroundColor Cyan
    $srcBase = Join-Path $GoldenPath $SN

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

Export-ModuleMember -Function @(
    'Export-ToTarget',
    'Show-TargetContents',
    'Write-ExportReadme'
)
