<#
.SYNOPSIS
    Creates a desktop shortcut for VentBackupManager with a custom icon.

.DESCRIPTION
    Run this once to place a professional-looking shortcut on the Desktop.
    The shortcut points to Launch-VentBackupManager.cmd and uses a generated
    .ico file (ventilator waveform on dark monitor background) stored in
    scripts/assets/.

    Requires: Windows PowerShell 5.1+, .NET System.Drawing (ships with Windows).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Install-DesktopShortcut.ps1
#>
[CmdletBinding()]
param(
    [string]$ShortcutName = "Ventilator Backup Manager"
)

$ErrorActionPreference = 'Stop'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir    = Split-Path -Parent $scriptDir
$assetsDir  = Join-Path $scriptDir 'assets'
$icoPath    = Join-Path $assetsDir 'VentBackupManager.ico'
$cmdPath    = Join-Path $rootDir   'Launch-VentBackupManager.cmd'

# ── 1. Ensure assets directory exists ──────────────────────────────────────
if (-not (Test-Path $assetsDir)) {
    New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
}

# ── 2. Generate the .ico file if it doesn't exist ─────────────────────────
if (-not (Test-Path $icoPath)) {
    Write-Host "Generating icon..." -ForegroundColor Cyan

    Add-Type -AssemblyName System.Drawing

    # Create a 256×256 icon (large enough for modern displays)
    $sizes = @(256, 48, 32, 16)
    $bitmaps = @()

    foreach ($sz in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)

        # ── Dark monitor-style rounded-rect background ─────────────────────
        $pad = [int][Math]::Max(1, $sz * 0.04)
        $bgRect = New-Object System.Drawing.Rectangle($pad, $pad, ($sz - 2 * $pad), ($sz - 2 * $pad))
        $bgColor   = [System.Drawing.Color]::FromArgb(255, 22, 33, 50)       # dark navy
        $rimColor  = [System.Drawing.Color]::FromArgb(255, 0, 120, 140)      # teal rim
        $bgBrush   = New-Object System.Drawing.SolidBrush($bgColor)
        $rimPenW   = [float][Math]::Max(1, $sz * 0.025)
        $rimPen    = New-Object System.Drawing.Pen($rimColor, $rimPenW)

        $radius = [int]($sz * 0.16)
        $d = $radius * 2
        $bgPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $bgPath.AddArc($bgRect.X, $bgRect.Y, $d, $d, 180, 90)
        $bgPath.AddArc($bgRect.Right - $d, $bgRect.Y, $d, $d, 270, 90)
        $bgPath.AddArc($bgRect.Right - $d, $bgRect.Bottom - $d, $d, $d, 0, 90)
        $bgPath.AddArc($bgRect.X, $bgRect.Bottom - $d, $d, $d, 90, 90)
        $bgPath.CloseFigure()
        $g.FillPath($bgBrush, $bgPath)
        $g.DrawPath($rimPen, $bgPath)

        # ── Ventilator pressure waveform (2 cycles) ───────────────────────
        # Classic inspiratory pressure-time: sharp rise, plateau, sharp drop
        $waveColor = [System.Drawing.Color]::FromArgb(255, 0, 212, 170)      # bright teal-green
        $glowColor = [System.Drawing.Color]::FromArgb(60, 0, 212, 170)       # soft glow

        $xMargin   = $sz * 0.14
        $xStart    = $xMargin
        $xEnd      = $sz - $xMargin
        $waveW     = $xEnd - $xStart
        $yBaseline = $sz * 0.62
        $yPeak     = $sz * 0.24
        $cycleW    = $waveW / 2.0

        # Build waveform points
        $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
        for ($c = 0; $c -lt 2; $c++) {
            $cx = $xStart + $c * $cycleW
            if ($c -eq 0) {
                $pts.Add([System.Drawing.PointF]::new($cx, $yBaseline))
            }
            $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.08, $yBaseline))
            $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.12, $yPeak))
            $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.48, $yPeak))
            $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.52, $yBaseline))
        }
        $pts.Add([System.Drawing.PointF]::new($xEnd, $yBaseline))

        $waveArr = $pts.ToArray()

        # Glow pass (thicker, semi-transparent)
        $glowW = [float][Math]::Max(3, $sz * 0.07)
        $glowPen = New-Object System.Drawing.Pen($glowColor, $glowW)
        $glowPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $glowPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $glowPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawLines($glowPen, $waveArr)

        # Crisp waveform pass
        $wPenW = [float][Math]::Max(1.5, $sz * 0.032)
        $wavePen = New-Object System.Drawing.Pen($waveColor, $wPenW)
        $wavePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $wavePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $wavePen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawLines($wavePen, $waveArr)

        # ── Backup shield with checkmark (larger sizes only) ──────────────
        if ($sz -ge 48) {
            $shSz = $sz * 0.26
            $shX  = $sz * 0.68
            $shY  = $sz * 0.68
            $shFill    = [System.Drawing.Color]::FromArgb(210, 0, 110, 135)
            $shOutline = [System.Drawing.Color]::FromArgb(255, 160, 210, 220)
            $shBrush   = New-Object System.Drawing.SolidBrush($shFill)
            $shPenW    = [float][Math]::Max(1, $sz * 0.012)
            $shPen     = New-Object System.Drawing.Pen($shOutline, $shPenW)

            # Shield shape: rounded top, pointed bottom
            $shPath = New-Object System.Drawing.Drawing2D.GraphicsPath
            $sr = $shSz * 0.18
            $shPath.AddArc($shX, $shY, $sr * 2, $sr * 2, 180, 90)
            $shPath.AddArc($shX + $shSz - $sr * 2, $shY, $sr * 2, $sr * 2, 270, 90)
            $shPath.AddLine(($shX + $shSz), ($shY + $shSz * 0.55),
                            ($shX + $shSz * 0.5), ($shY + $shSz))
            $shPath.AddLine(($shX + $shSz * 0.5), ($shY + $shSz),
                            $shX, ($shY + $shSz * 0.55))
            $shPath.CloseFigure()
            $g.FillPath($shBrush, $shPath)
            $g.DrawPath($shPen, $shPath)

            # Checkmark
            $ckPenW = [float][Math]::Max(1.5, $sz * 0.022)
            $ckPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $ckPenW)
            $ckPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $ckPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ckPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
            $cmx = $shX + $shSz * 0.5
            $cmy = $shY + $shSz * 0.42
            $cs  = $shSz * 0.22
            $g.DrawLines($ckPen, @(
                [System.Drawing.PointF]::new($cmx - $cs * 0.8, $cmy + $cs * 0.1),
                [System.Drawing.PointF]::new($cmx - $cs * 0.1, $cmy + $cs * 0.7),
                [System.Drawing.PointF]::new($cmx + $cs * 0.9, $cmy - $cs * 0.5)
            ))

            $ckPen.Dispose(); $shPen.Dispose(); $shBrush.Dispose(); $shPath.Dispose()
        }

        # Clean up
        $glowPen.Dispose(); $wavePen.Dispose()
        $rimPen.Dispose(); $bgBrush.Dispose(); $bgPath.Dispose()
        $g.Dispose()
        $bitmaps += $bmp
    }

    # Write multi-resolution .ico file (ICO format: header + directory + PNG data)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # ICO header: reserved(2) + type=1(2) + count(2)
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$bitmaps.Count)

    # Collect PNG data for each size
    $pngDataList = @()
    foreach ($bmp in $bitmaps) {
        $pngStream = New-Object System.IO.MemoryStream
        $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngDataList += ,($pngStream.ToArray())
        $pngStream.Dispose()
    }

    # Directory entries (16 bytes each)
    # Offset starts after header (6) + directory (16 × count)
    $dataOffset = 6 + (16 * $bitmaps.Count)
    for ($i = 0; $i -lt $bitmaps.Count; $i++) {
        $sz = $sizes[$i]
        $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))  # width  (0 = 256)
        $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))  # height (0 = 256)
        $bw.Write([byte]0)      # color palette
        $bw.Write([byte]0)      # reserved
        $bw.Write([uint16]1)    # color planes
        $bw.Write([uint16]32)   # bits per pixel
        $bw.Write([uint32]$pngDataList[$i].Length)  # data size
        $bw.Write([uint32]$dataOffset)              # data offset
        $dataOffset += $pngDataList[$i].Length
    }

    # Image data
    foreach ($pngData in $pngDataList) {
        $bw.Write($pngData)
    }

    [System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
    foreach ($bmp in $bitmaps) { $bmp.Dispose() }

    Write-Host "  Created: $icoPath" -ForegroundColor Green
}

# ── 3. Create the desktop shortcut ────────────────────────────────────────
$desktopPath = [Environment]::GetFolderPath('Desktop')
$lnkPath     = Join-Path $desktopPath "$ShortcutName.lnk"

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath       = $cmdPath
$shortcut.WorkingDirectory = $rootDir
$shortcut.IconLocation     = "$icoPath, 0"
$shortcut.Description      = "Launch the Trilogy 200 ventilator backup wizard"
$shortcut.WindowStyle      = 1  # Normal window
$shortcut.Save()

Write-Host ""
Write-Host "  Desktop shortcut created:" -ForegroundColor Green
Write-Host "  $lnkPath" -ForegroundColor White
Write-Host ""
Write-Host "  You can also double-click Launch-VentBackupManager.cmd directly." -ForegroundColor Gray
Write-Host ""
