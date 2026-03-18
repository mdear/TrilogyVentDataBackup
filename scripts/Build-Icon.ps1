<#
.SYNOPSIS
    One-time build script: generates scripts/assets/VentBackupManager.ico.
    Run this once. The .ico is then a pre-built asset used by Install-DesktopShortcut.ps1.
    Not intended for end users — this is a dev/build tool.

.DESCRIPTION
    Draws a ventilator pressure waveform (2 cycles, bright teal-green) on a dark
    navy monitor-style background, with a small backup shield+checkmark in the
    lower-right corner. Outputs a multi-resolution .ico (256/48/32/16).
#>
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$assetsDir = Join-Path $scriptDir 'assets'
$icoPath   = Join-Path $assetsDir 'VentBackupManager.ico'

if (-not (Test-Path $assetsDir)) {
    New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
}

Add-Type -AssemblyName System.Drawing

$sizes   = @(256, 48, 32, 16)
$bitmaps = @()

foreach ($sz in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # ── Dark monitor-style rounded-rect background ─────────────────────
    $pad    = [int][Math]::Max(1, $sz * 0.04)
    $bgRect = New-Object System.Drawing.Rectangle($pad, $pad, ($sz - 2 * $pad), ($sz - 2 * $pad))
    $bgColor  = [System.Drawing.Color]::FromArgb(255, 22, 33, 50)
    $rimColor = [System.Drawing.Color]::FromArgb(255, 0, 120, 140)
    $bgBrush  = New-Object System.Drawing.SolidBrush($bgColor)
    $rimPenW  = [float][Math]::Max(1, $sz * 0.025)
    $rimPen   = New-Object System.Drawing.Pen($rimColor, $rimPenW)

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
    $waveColor = [System.Drawing.Color]::FromArgb(255, 0, 212, 170)
    $glowColor = [System.Drawing.Color]::FromArgb(60, 0, 212, 170)

    # Waveform: full usable width, reduced amplitude, more breathing room top and bottom.
    # Peak at ~14% (10% clear margin from rim at 4%), baseline at ~52%.
    $xStart    = $sz * 0.13
    $xEnd      = $sz * 0.87
    $waveW     = $xEnd - $xStart
    $yBaseline = $sz * 0.52
    $yPeak     = $sz * 0.14
    $cycleW    = $waveW / 2.0

    # Trapezoidal ventilator pressure cycle: expiry baseline → fast rise → plateau → fast drop
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    for ($c = 0; $c -lt 2; $c++) {
        $cx = $xStart + $c * $cycleW
        if ($c -eq 0) { $pts.Add([System.Drawing.PointF]::new($cx, $yBaseline)) }
        $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.08, $yBaseline))  # pre-breath baseline
        $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.18, $yPeak))      # top of rise
        $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.52, $yPeak))      # end of plateau
        $pts.Add([System.Drawing.PointF]::new($cx + $cycleW * 0.62, $yBaseline))  # end of drop
    }
    $pts.Add([System.Drawing.PointF]::new($xEnd, $yBaseline))
    $waveArr = $pts.ToArray()

    # Glow pass
    $glowW   = [float][Math]::Max(3, $sz * 0.07)
    $glowPen = New-Object System.Drawing.Pen($glowColor, $glowW)
    $glowPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $glowPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $glowPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLines($glowPen, $waveArr)

    # Crisp waveform
    $wPenW   = [float][Math]::Max(1.5, $sz * 0.032)
    $wavePen = New-Object System.Drawing.Pen($waveColor, $wPenW)
    $wavePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $wavePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $wavePen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLines($wavePen, $waveArr)

    # ── Classic shield badge with checkmark (48px+) ────────────────────
    if ($sz -ge 48) {
        # Shield: same dimensions, vertically centered in the space between
        # the waveform baseline and the bottom rim, with equal margins above and below.
        $shW     = $sz * 0.27
        $shH     = [float]($shW * 300.0 / 260.0)   # locked to Wikimedia SVG aspect ratio
        $shX     = ($sz - $shW) / 2.0              # horizontally centered
        $zoneTop = $yBaseline + $sz * 0.06          # 6% gap below waveform baseline
        $zoneBtm = [float]($sz - $pad - $sz * 0.04) # 4% margin above bottom rim
        $shY     = [float](($zoneTop + $zoneBtm - $shH) / 2.0)  # centered in zone

        $shFill    = [System.Drawing.Color]::FromArgb(220, 0, 100, 130)
        $shOutline = [System.Drawing.Color]::FromArgb(255, 140, 210, 225)
        $shBrush   = New-Object System.Drawing.SolidBrush($shFill)
        $shPenW    = [float][Math]::Max(1, $sz * 0.014)
        $shPen     = New-Object System.Drawing.Pen($shOutline, $shPenW)

        $midX = $shX + $shW * 0.5

        # ── Shield path from Wikimedia SVG (Coa_Illustration_Shield_Triangular_3) ──
        # Source: 260×300 viewBox. All coords normalized: x/260, y/300.
        # Segments: left-edge line → left-side cubic → right-side cubic →
        #           right-edge line → right-top-lobe cubic → left-top-lobe cubic → close.
        # The two top lobes give the classic heraldic two-pointed top.

        $shPath = New-Object System.Drawing.Drawing2D.GraphicsPath

        # Left straight edge: top-left corner → bottom of straight section
        $shPath.AddLine(
            [float]($shX + 0.025  * $shW), [float]($shY + 0.0217 * $shH),
            [float]($shX + 0.025  * $shW), [float]($shY + 0.2569 * $shH) )

        # Left side sweeps to pointed bottom tip
        $shPath.AddBezier(
            [float]($shX + 0.025  * $shW), [float]($shY + 0.2569 * $shH),
            [float]($shX + 0.025  * $shW), [float]($shY + 0.7265 * $shH),
            [float]($shX + 0.4246 * $shW), [float]($shY + 0.9433 * $shH),
            [float]($shX + 0.5    * $shW), [float]($shY + 0.9783 * $shH) )

        # Right side sweeps from tip back up
        $shPath.AddBezier(
            [float]($shX + 0.5    * $shW), [float]($shY + 0.9783 * $shH),
            [float]($shX + 0.5754 * $shW), [float]($shY + 0.9433 * $shH),
            [float]($shX + 0.975  * $shW), [float]($shY + 0.7265 * $shH),
            [float]($shX + 0.975  * $shW), [float]($shY + 0.2569 * $shH) )

        # Right straight edge: bottom of straight section → top-right corner
        $shPath.AddLine(
            [float]($shX + 0.975  * $shW), [float]($shY + 0.2569 * $shH),
            [float]($shX + 0.975  * $shW), [float]($shY + 0.0217 * $shH) )

        # Right top lobe: top-right corner curves inward to center crest
        $shPath.AddBezier(
            [float]($shX + 0.975  * $shW), [float]($shY + 0.0217 * $shH),
            [float]($shX + 0.7815 * $shW), [float]($shY + 0.0881 * $shH),
            [float]($shX + 0.6954 * $shW), [float]($shY + 0.0946 * $shH),
            [float]($shX + 0.5    * $shW), [float]($shY + 0.0217 * $shH) )

        # Left top lobe: center crest curves inward to top-left corner
        $shPath.AddBezier(
            [float]($shX + 0.5    * $shW), [float]($shY + 0.0217 * $shH),
            [float]($shX + 0.3046 * $shW), [float]($shY + 0.0946 * $shH),
            [float]($shX + 0.2185 * $shW), [float]($shY + 0.0881 * $shH),
            [float]($shX + 0.025  * $shW), [float]($shY + 0.0217 * $shH) )

        $shPath.CloseFigure()

        $g.FillPath($shBrush, $shPath)
        $g.DrawPath($shPen, $shPath)

        # Checkmark centered in shield body (below the dip)
        $ckPenW = [float][Math]::Max(1.5, $sz * 0.025)
        $ckPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $ckPenW)
        $ckPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $ckPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $ckPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $cmx = $midX
        $cmy = $shY + $shH * 0.50
        $cs  = $shW * 0.22
        $g.DrawLines($ckPen, @(
            [System.Drawing.PointF]::new($cmx - $cs * 0.9, $cmy + $cs * 0.1),
            [System.Drawing.PointF]::new($cmx - $cs * 0.1, $cmy + $cs * 0.8),
            [System.Drawing.PointF]::new($cmx + $cs * 1.0, $cmy - $cs * 0.6)
        ))
        $ckPen.Dispose(); $shPen.Dispose(); $shBrush.Dispose(); $shPath.Dispose()
    }

    $glowPen.Dispose(); $wavePen.Dispose()
    $rimPen.Dispose(); $bgBrush.Dispose(); $bgPath.Dispose()
    $g.Dispose()
    $bitmaps += $bmp
}

# ── Write multi-resolution .ico ───────────────────────────────────────────
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$bitmaps.Count)

$pngDataList = @()
foreach ($bmp in $bitmaps) {
    $pngStream = New-Object System.IO.MemoryStream
    $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngDataList += ,($pngStream.ToArray())
    $pngStream.Dispose()
}

$dataOffset = 6 + (16 * $bitmaps.Count)
for ($i = 0; $i -lt $bitmaps.Count; $i++) {
    $sz = $sizes[$i]
    $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
    $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$pngDataList[$i].Length)
    $bw.Write([uint32]$dataOffset)
    $dataOffset += $pngDataList[$i].Length
}

foreach ($pngData in $pngDataList) { $bw.Write($pngData) }

[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Dispose()
$ms.Dispose()
foreach ($bmp in $bitmaps) { $bmp.Dispose() }

Write-Host "Icon generated: $icoPath ($((Get-Item $icoPath).Length) bytes)" -ForegroundColor Green
