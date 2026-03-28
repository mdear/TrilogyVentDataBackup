# VBM-UI.psm1 — Wizard prompts, progress display, and console formatting

#region ── Show-MainMenu ─────────────────────────────────────────────────────

function Show-MainMenu {
    <#
    .SYNOPSIS
        Display the main wizard menu and return the user's choice (1-7) or 0 to quit.
    .PARAMETER BackupRoot
        When supplied, the current backup root is shown beneath the title bar.
    #>
    [CmdletBinding()]
    param(
        [string]$BackupRoot
    )

    Write-Host ''
    Write-Host ('═' * 65) -ForegroundColor Cyan
    Write-Host '  VENT BACKUP MANAGER' -ForegroundColor Cyan
    Write-Host ('═' * 65) -ForegroundColor Cyan
    if ($BackupRoot) {
        Write-Host "  Root: $BackupRoot" -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  1) Analyze        — Scan all backups, show table of contents'
    Write-Host '  2) Prepare        — Build golden archive and export to SD card'
    Write-Host '  3) Golden Archive — Build / update the verified archive only'
    Write-Host '  4) Back Up SD     — Copy SD card into a new timestamped backup'
    Write-Host '  5) Compact        — Deduplicate backups (NTFS hardlinks)'
    Write-Host '  6) Validate       — Check integrity of backup(s) and/or golden archive(s)'
    Write-Host '  7) Settings       — Change backup root directory'
    Write-Host '  8) Gap Analysis   — Chronological swim lanes showing data gaps per device'
    Write-Host ''
    Write-Host '  Q) Quit'
    Write-Host ''
    do {
        $choice = (Read-Host 'Choose an option').Trim().ToUpperInvariant()
    } while ($choice -notin @('1','2','3','4','5','6','7','8','Q'))

    if ($choice -eq 'Q') { return 0 }
    return [int]$choice
}

#endregion

#region ── Read-ValidatedPath ─────────────────────────────────────────────────

function Read-ValidatedPath {
    <#
    .SYNOPSIS
        Prompt for a filesystem path, optionally requiring it to already exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$MustExist
    )

    while ($true) {
        $raw  = (Read-Host $Prompt).Trim().Trim('"', "'")
        if (-not $raw) { Write-Host '  Path cannot be empty.' -ForegroundColor Yellow; continue }

        # Expand ~ on Windows (PowerShell handles $HOME but not ~)
        $raw = $raw -replace '^~', $HOME

        if ($MustExist -and -not (Test-Path $raw)) {
            Write-Host "  Path not found: $raw" -ForegroundColor Yellow
            continue
        }
        return $raw
    }
}

#endregion

#region ── Show-SourcePicker ─────────────────────────────────────────────────

function Show-SourcePicker {
    <#
    .SYNOPSIS
        Display available drives and let the user pick a source path,
        or enter any folder path manually (useful when SD card contents
        were already copied to a local folder).
    .OUTPUTS
        [string] The selected or entered path.
    #>
    [CmdletBinding()]
    param()

    # Enumerate ready drives (removable first, then others)
    $drives = [System.IO.DriveInfo]::GetDrives() |
              Where-Object { $_.IsReady } |
              Sort-Object { $_.DriveType -ne 'Removable' }, Name

    Write-Host ''
    Write-Host '  Available drives:' -ForegroundColor Cyan
    $i = 0
    $indexed = foreach ($d in $drives) {
        $i++
        $label = if ($d.VolumeLabel) { "($($d.VolumeLabel))" } else { '' }
        $type  = $d.DriveType
        Write-Host ("  [{0}] {1}  {2,-12} {3}" -f $i, $d.RootDirectory.FullName, $type, $label)
        [pscustomobject]@{ Index = $i; Path = $d.RootDirectory.FullName }
    }
    Write-Host '  [M] Enter a path manually (e.g. a local folder copy of the SD card)'
    Write-Host ''

    while ($true) {
        $answer = (Read-Host '  Select drive number or M for manual').Trim().ToUpperInvariant()
        if ($answer -eq 'M') {
            $raw = (Read-Host '  Source path').Trim().Trim('"', "'")
            if (-not $raw) { Write-Host '  Path cannot be empty.' -ForegroundColor Yellow; continue }
            $raw = $raw -replace '^~', $HOME
            if (-not (Test-Path $raw)) {
                Write-Host "  Path not found: $raw" -ForegroundColor Yellow; continue
            }
            return $raw
        }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n)) {
            $entry = $indexed | Where-Object { $_.Index -eq $n }
            if ($entry) { return $entry.Path }
        }
        Write-Host '  Invalid selection.' -ForegroundColor Yellow
    }
}

#endregion

#region ── Read-YesNo ────────────────────────────────────────────────────────

function Read-YesNo {
    <#
    .SYNOPSIS
        Prompt for a yes/no answer. Returns $true for Yes, $false for No.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $raw = (Read-Host "$Prompt $hint").Trim().ToUpperInvariant()
        if ($raw -eq '')  { return $Default }
        if ($raw -eq 'Y') { return $true    }
        if ($raw -eq 'N') { return $false   }
        Write-Host '  Please enter Y or N.' -ForegroundColor Yellow
    }
}

#endregion

#region ── Show-DeviceSelection ──────────────────────────────────────────────

function Show-DeviceSelection {
    <#
    .SYNOPSIS
        Present the device list with suggestions and return the selected SN array.
    .DESCRIPTION
        First golden: all devices suggested.
        Subsequent golden: only devices with changed data suggested.
        User may press Enter to accept or type comma-separated numbers to override.
    .PARAMETER Devices
        Hashtable (or PSCustomObject) of SN -> device summary from TOC.Devices.
    .PARAMETER Suggested
        Array of SNs pre-selected as suggested. All others are shown but unselected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Devices,
        [string[]]$Suggested
    )

    $snList = if ($Devices -is [hashtable]) {
        @($Devices.Keys)
    } else {
        @($Devices.PSObject.Properties | ForEach-Object { $_.Name })
    }
    $snList = @($snList | Sort-Object)

    Write-Host ''
    Write-Host 'Available devices:' -ForegroundColor Cyan
    Write-Host ('-' * 60)
    for ($i = 0; $i -lt $snList.Count; $i++) {
        $sn  = $snList[$i]
        $devProp = if ($Devices -is [hashtable]) { $null } else { $Devices.PSObject.Properties[$sn] }
        $dev     = if ($Devices -is [hashtable]) { $Devices[$sn] } elseif ($devProp) { $devProp.Value } else { $null }
        $isSuggested = $Suggested -contains $sn
        $marker  = if ($isSuggested) { '[*]' } else { '[ ]' }
        $model   = if ($dev -and $dev.Model)           { "  $($dev.Model)" } else { '' }
        $range   = if ($dev -and $dev.OverallEarliest) { "  $($dev.OverallEarliest) → $($dev.OverallLatest)" } else { '' }
        $color   = if ($isSuggested) { 'White' } else { 'Gray' }
        Write-Host ("  {0} {1,2}) {2,-16}{3}{4}" -f $marker, ($i+1), $sn, $model, $range) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host "  [*] = suggested  |  Press Enter to accept suggestion" -ForegroundColor DarkGray

    while ($true) {
        $raw = (Read-Host 'Select devices (Enter = accept, or e.g. "1,3")').Trim()
        if ($raw -eq '') {
            # Accept suggestion
            return @($Suggested)
        }
        $nums = $raw -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        $selected = foreach ($n in $nums) {
            $idx = [int]$n - 1
            if ($idx -ge 0 -and $idx -lt $snList.Count) { $snList[$idx] }
        }
        if (@($selected).Count -gt 0) {
            return @($selected)
        }
        Write-Host '  Invalid selection. Enter comma-separated numbers, or press Enter.' -ForegroundColor Yellow
    }
}

#endregion

#region ── Write-ProgressBar ─────────────────────────────────────────────────

function Write-ProgressBar {
    <#
    .SYNOPSIS
        Display an ASCII progress bar in the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total
    )

    $pct   = if ($Total -gt 0) { [int](($Current / $Total) * 100) } else { 0 }
    $width = 40
    $filled = [int](($pct / 100) * $width)
    $bar   = '[' + ('#' * $filled) + ('-' * ($width - $filled)) + ']'
    Write-Host "`r  $bar $pct%  $Activity          " -NoNewline
}

#endregion

#region ── Write-TimelineChart ────────────────────────────────────────────────

function Write-TimelineChart {
    <#
    .SYNOPSIS
        Render an ASCII bar chart of device data timelines.
    .PARAMETER DeviceTimelines
        Hashtable (SN -> Timeline array from Get-DeviceTimeline) or a direct array
        from a single device.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DeviceTimelines
    )

    # Determine overall min/max months for axis
    $allDates = [System.Collections.Generic.List[string]]::new()
    if ($DeviceTimelines -is [hashtable]) {
        foreach ($sn in $DeviceTimelines.Keys) {
            foreach ($entry in $DeviceTimelines[$sn]) {
                if ($entry.EarliestDate) { $allDates.Add($entry.EarliestDate) }
                if ($entry.LatestDate)   { $allDates.Add($entry.LatestDate) }
            }
        }
    } else {
        foreach ($entry in $DeviceTimelines) {
            if ($entry.EarliestDate) { $allDates.Add($entry.EarliestDate) }
            if ($entry.LatestDate)   { $allDates.Add($entry.LatestDate) }
        }
    }

    if ($allDates.Count -eq 0) {
        Write-Host '  (No date information available)' -ForegroundColor DarkGray
        return
    }

    $sorted  = $allDates | Sort-Object
    $minDate = $sorted[0]
    $maxDate = $sorted[-1]

    $minY = [int]$minDate.Substring(0,4); $minM = [int]$minDate.Substring(5,2)
    $maxY = [int]$maxDate.Substring(0,4); $maxM = [int]$maxDate.Substring(5,2)
    $totalMonths = ($maxY - $minY) * 12 + ($maxM - $minM) + 1
    if ($totalMonths -le 0) { $totalMonths = 1 }

    $barWidth = [Math]::Min(60, $totalMonths)
    $scale    = $barWidth / $totalMonths

    # Print year markers
    $axisLine = ' ' * 20
    $year = $minY
    $month = $minM
    for ($m = 0; $m -lt $totalMonths; $m += [Math]::Max(1, [int](12/$scale))) {
        $lbl = '{0:D4}' -f ($minY + [int](($minM - 1 + $m) / 12))
        $axisLine += $lbl.Substring(2)
        $axisLine += '  '
    }

    function _MonthOffset([string]$dateStr) {
        $y = [int]$dateStr.Substring(0,4); $mo = [int]$dateStr.Substring(5,2)
        return ($y - $minY) * 12 + ($mo - $minM)
    }

    Write-Host ''
    Write-Host ('─' * ($barWidth + 22))

    $snGroups = if ($DeviceTimelines -is [hashtable]) { $DeviceTimelines } else { @{ '' = $DeviceTimelines } }
    foreach ($snKey in ($snGroups.Keys | Sort-Object)) {
        $label = if ($snKey) { $snKey } else { 'Device' }
        $entries = $snGroups[$snKey]
        foreach ($entry in $entries) {
            if (-not $entry.EarliestDate -or -not $entry.LatestDate) { continue }
            $startOff = _MonthOffset $entry.EarliestDate
            $endOff   = _MonthOffset $entry.LatestDate
            $startPos = [int]($startOff * $scale)
            $endPos   = [int]($endOff   * $scale)
            $barLen   = [Math]::Max(1, $endPos - $startPos + 1)
            $bar      = ' ' * $startPos + '█' * $barLen + ' ' * ($barWidth - $startPos - $barLen)
            $bkpLabel = if ($entry.PSObject.Properties['BackupName'] -and $entry.BackupName) { $entry.BackupName } else { $label }
            $color    = switch ($entry.Integrity) {
                'Contaminated' { 'Red'    }
                'Clean'        { 'Green'  }
                default        { 'Cyan'   }
            }
            Write-Host ('{0,-20}|{1}| {2}' -f $bkpLabel.Substring(0, [Math]::Min(19,$bkpLabel.Length)), $bar, $entry.LatestDate) -ForegroundColor $color
        }
    }
    Write-Host ('─' * ($barWidth + 22))
    Write-Host ('{0,-21}{1}' -f '', "$minDate  →  $maxDate")
    Write-Host ''
}

#endregion

#region ── Show-ForceDevicesPrompt ───────────────────────────────────────────

function Show-ForceDevicesPrompt {
    <#
    .SYNOPSIS
        Ask the operator whether to force specific devices into this golden run,
        bypassing the automatic changed-data detection algorithm.
    .DESCRIPTION
        Shown in wizard mode before Show-DeviceSelection, only for Golden / Prepare
        actions.  Returns a result object that the caller uses to decide whether to
        invoke New/Update-GoldenArchive with -ForceDevices.
    .PARAMETER Devices
        Hashtable or PSCustomObject of SN -> device summary from TOC.Devices.
    .OUTPUTS
        PSCustomObject:
          ForceDevices  [bool]    — $true if the user chose to force devices
          SelectedSNs   [string[]] — SNs to force (empty when ForceDevices=$false)
          Reason        [string]  — free-text reason (empty when ForceDevices=$false)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Devices
    )

    Write-Host ''
    Write-Host ('─' * 65)
    Write-Host '  FORCED DEVICE OVERRIDE' -ForegroundColor Yellow
    Write-Host ('─' * 65)
    Write-Host '  Normally VentBackupManager automatically selects devices:'
    Write-Host '    • First golden: all devices'
    Write-Host '    • Update golden: only devices with changed data'
    Write-Host ''
    Write-Host '  Override forces specific devices into this golden run'
    Write-Host '  regardless of whether their data has changed.  This is'
    Write-Host '  useful after a card swap, firmware update, or audit.'
    Write-Host ''

    $wantForce = Read-YesNo -Prompt '  Force specific devices into this golden run?' -Default $false
    if (-not $wantForce) {
        Write-Host ''
        return [PSCustomObject]@{ ForceDevices = $false; SelectedSNs = @(); Reason = '' }
    }

    # Show device list — no pre-selection (user must explicitly pick)
    $snList = if ($Devices -is [hashtable]) {
        @($Devices.Keys | Sort-Object)
    } else {
        @($Devices.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    }

    if ($snList.Count -eq 0) {
        Write-Host '  No devices available.' -ForegroundColor Yellow
        return [PSCustomObject]@{ ForceDevices = $false; SelectedSNs = @(); Reason = '' }
    }

    Write-Host ''
    Write-Host '  Select devices to force (no pre-selection — you must choose explicitly):'
    Write-Host ('-' * 60)
    for ($i = 0; $i -lt $snList.Count; $i++) {
        $sn  = $snList[$i]
        $dev = if ($Devices -is [hashtable]) { $Devices[$sn] } else {
            $p = $Devices.PSObject.Properties[$sn]; if ($p) { $p.Value } else { $null }
        }
        $model = if ($dev -and $dev.PSObject.Properties['Model'] -and $dev.Model) { "  $($dev.Model)" } else { '' }
        $range = if ($dev -and $dev.PSObject.Properties['OverallEarliest'] -and $dev.OverallEarliest) {
            "  $($dev.OverallEarliest) → $($dev.OverallLatest)"
        } else { '' }
        Write-Host ("  {0,2}) {1,-16}{2}{3}" -f ($i + 1), $sn, $model, $range) -ForegroundColor White
    }
    Write-Host ''

    $selectedSNs = @()
    while ($selectedSNs.Count -eq 0) {
        $raw  = (Read-Host '  Enter device numbers (e.g. "1,3") or A for all').Trim()
        if ($raw.ToUpperInvariant() -eq 'A') {
            $selectedSNs = $snList
            break
        }
        $nums = $raw -split '[,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        $picks = @(foreach ($n in $nums) {
            $idx = [int]$n - 1
            if ($idx -ge 0 -and $idx -lt $snList.Count) { $snList[$idx] }
        })
        if ($picks.Count -gt 0) { $selectedSNs = $picks }
        else { Write-Host '  Invalid selection. Enter comma-separated numbers or A.' -ForegroundColor Yellow }
    }

    # Prompt for reason
    $reason = ''
    while (-not $reason.Trim()) {
        $reason = Read-Host '  Reason for forcing these devices (recorded in manifest)'
        if (-not $reason.Trim()) {
            Write-Host '  A reason is required for audit purposes.' -ForegroundColor Yellow
        }
    }

    # Confirmation summary
    Write-Host ''
    Write-Host '  ┌─ Force Override Summary ─────────────────────────────────┐' -ForegroundColor Yellow
    Write-Host "  │  Devices : $($selectedSNs -join ', ')" -ForegroundColor Yellow
    Write-Host "  │  Reason  : $reason" -ForegroundColor Yellow
    Write-Host '  └──────────────────────────────────────────────────────────┘' -ForegroundColor Yellow
    Write-Host ''

    $confirmed = Read-YesNo -Prompt '  Confirm forced device override?' -Default $true
    if (-not $confirmed) {
        Write-Host '  Cancelled — proceeding with standard device selection.' -ForegroundColor DarkGray
        return [PSCustomObject]@{ ForceDevices = $false; SelectedSNs = @(); Reason = '' }
    }

    return [PSCustomObject]@{
        ForceDevices = $true
        SelectedSNs  = $selectedSNs
        Reason       = $reason
    }
}

#endregion

#region ── Show-GapSwimLanes ─────────────────────────────────────────────────

function Show-GapSwimLanes {
    <#
    .SYNOPSIS
        Render chronological swim lanes for one or more devices, highlighting data gaps.
    .DESCRIPTION
        Each device gets one row. Each character in the bar represents one or more
        months (scaled when the timeline is long). Characters:
          █  clean data present      (Green)
          ▓  contaminated-only data  (Magenta)
          ░  real gap                (Red)
          ▒  noise / debounced gap   (DarkYellow)
    .PARAMETER GapResults
        Array of PSCustomObjects from Get-DeviceGaps (one per device).
    .PARAMETER DebounceWeeks
        Gap threshold value (in weeks) that was used — displayed in the header.
    .PARAMETER MaxWidth
        Maximum bar width in characters. Default: 72 (fits standard 80-col terminal).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject[]]$GapResults,
        [int]$DebounceWeeks = 4,
        [int]$MaxWidth      = 72
    )

    $withData = @($GapResults | Where-Object { $_.OverallEarliest })
    if ($withData.Count -eq 0) {
        Write-Host '  (No date information available for any selected device)' -ForegroundColor DarkGray
        return
    }

    # Global axis spanning all selected devices
    $globalMin = @($withData | Select-Object -ExpandProperty OverallEarliest | Sort-Object)[0]
    $globalMax = @($withData | Select-Object -ExpandProperty OverallLatest   | Sort-Object)[-1]

    $minY = [int]$globalMin.Substring(0,4); $minM = [int]$globalMin.Substring(5,2)
    $maxY = [int]$globalMax.Substring(0,4); $maxM = [int]$globalMax.Substring(5,2)
    $totalMonths = ($maxY - $minY) * 12 + ($maxM - $minM) + 1
    if ($totalMonths -lt 1) { $totalMonths = 1 }

    $barWidth    = [Math]::Min($MaxWidth, $totalMonths)
    $scaleDouble = if ($barWidth -gt 0) { [double]$totalMonths / [double]$barWidth } else { 1.0 }

    # Scriptblock closure — captures $minY, $minM, $barWidth, $scaleDouble from this call frame
    $gapPos = {
        param([string]$dateStr)
        $y   = [int]$dateStr.Substring(0,4)
        $m   = [int]$dateStr.Substring(5,2)
        $idx = [double](($y - $minY) * 12 + ($m - $minM))
        $raw = if ($scaleDouble -gt 0) { $idx / $scaleDouble } else { 0.0 }
        if ([double]::IsNaN($raw) -or [double]::IsInfinity($raw)) { $raw = 0.0 }
        [Math]::Min($barWidth - 1, [Math]::Max(0, [int]([Math]::Floor($raw))))
    }

    # Build year-label axis string via StringBuilder (avoids char/string array edge cases).
    # Allocate 3 extra chars so a year label whose tick falls near the right edge is not clipped.
    $axisCap = $barWidth + 3
    $axisBuilder = [System.Text.StringBuilder]::new(' ' * $axisCap)
    $yrStr = $minY.ToString()
    for ($li = 0; $li -lt $yrStr.Length -and $li -lt $axisCap; $li++) {
        [void]$axisBuilder.Remove($li, 1)
        [void]$axisBuilder.Insert($li, $yrStr[$li].ToString())
    }
    for ($yr = $minY + 1; $yr -le $maxY; $yr++) {
        $mIdx = [double](($yr - $minY) * 12 - ($minM - 1))
        $pos  = if ($scaleDouble -gt 0) { [int]([Math]::Floor($mIdx / $scaleDouble)) } else { 0 }
        if ($pos -ge 0 -and $pos -lt $barWidth) {
            $yrStr = $yr.ToString()
            for ($li = 0; $li -lt $yrStr.Length -and ($pos + $li) -lt $axisCap; $li++) {
                if ($axisBuilder[$pos + $li] -eq ' ') {
                    [void]$axisBuilder.Remove($pos + $li, 1)
                    [void]$axisBuilder.Insert($pos + $li, $yrStr[$li].ToString())
                }
            }
        }
    }
    $axisStr = $axisBuilder.ToString().TrimEnd()

    # Summary header
    $totalReal      = @($GapResults | ForEach-Object { $_.Gaps } | Where-Object { -not $_.IsDebounced }).Count
    $totalDebounced = @($GapResults | ForEach-Object { $_.Gaps } | Where-Object {  $_.IsDebounced }).Count
    $lineWidth      = [Math]::Min(18 + 1 + $barWidth + 26, 100)

    Write-Host ''
    Write-Host ('═' * $lineWidth) -ForegroundColor Cyan
    Write-Host '  GAP ANALYSIS — DEVICE SWIM LANES' -ForegroundColor Cyan
    Write-Host ('═' * $lineWidth) -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  $($GapResults.Count) device(s)   $totalReal real gap(s)   $totalDebounced debounced   threshold ≤$DebounceWeeks week(s)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Legend: ' -NoNewline -ForegroundColor DarkGray
    Write-Host '█' -NoNewline -ForegroundColor Green
    Write-Host ' data  '          -NoNewline -ForegroundColor DarkGray
    Write-Host '▓' -NoNewline -ForegroundColor Magenta
    Write-Host ' contaminated  '  -NoNewline -ForegroundColor DarkGray
    Write-Host '░' -NoNewline -ForegroundColor Red
    Write-Host ' gap  '           -NoNewline -ForegroundColor DarkGray
    Write-Host '▒' -NoNewline -ForegroundColor DarkYellow
    Write-Host " noise (≤$DebounceWeeks wk)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('─' * $lineWidth) -ForegroundColor DarkGray
    Write-Host ($('Device'.PadRight(18)) + ' ' + $axisStr) -ForegroundColor DarkGray
    Write-Host ('─' * $lineWidth) -ForegroundColor DarkGray

    foreach ($gapResult in $GapResults) {
        $sn = $gapResult.DeviceSerial

        if (-not $gapResult.OverallEarliest) {
            Write-Host ($sn.PadRight(18) + ' (no monthly AD/DD data found)') -ForegroundColor DarkGray
            Write-Host ''
            continue
        }

        # Build bar as char array (one character per bar position)
        $bar = [char[]](' ' * $barWidth)

        # Paint covered months — clean (█) wins over contaminated-only (▓)
        foreach ($month in $gapResult.CoveredMonths) {
            $pos = & $gapPos $month
            $ch  = if ($gapResult.ContaminatedMonths -contains $month) { [char]'▓' } else { [char]'█' }
            if ($bar[$pos] -eq [char]' ' -or ($bar[$pos] -eq [char]'▓' -and $ch -eq [char]'█')) {
                $bar[$pos] = $ch
            }
        }

        # Paint gaps — only positions not already occupied by data
        foreach ($gap in $gapResult.Gaps) {
            $gapCh = if ($gap.IsDebounced) { [char]'▒' } else { [char]'░' }
            foreach ($month in $gap.Months) {
                $pos = & $gapPos $month
                if ($bar[$pos] -eq [char]' ') { $bar[$pos] = $gapCh }
            }
        }

        # Print: label + colored bar + date range
        $snLabel = $sn.Substring(0, [Math]::Min(17, $sn.Length))
        Write-Host ($snLabel.PadRight(18) + ' ') -NoNewline -ForegroundColor Cyan
        foreach ($ch in $bar) {
            $color = switch ([string]$ch) {
                '█'     { 'Green'      }
                '▓'     { 'Magenta'    }
                '░'     { 'Red'        }
                '▒'     { 'DarkYellow' }
                default { 'DarkGray'   }
            }
            Write-Host $ch -NoNewline -ForegroundColor $color
        }
        Write-Host "  $($gapResult.OverallEarliest) → $($gapResult.OverallLatest)" -ForegroundColor Cyan

        # Detail lines below the bar
        $realGaps      = @($gapResult.Gaps | Where-Object { -not $_.IsDebounced })
        $debouncedGaps = @($gapResult.Gaps | Where-Object {  $_.IsDebounced })

        foreach ($g in $realGaps) {
            $mWord = if ($g.DurationMonths -eq 1) { '1 month' } else { "$($g.DurationMonths) months" }
            Write-Host "              ↳ GAP  $($g.Start) → $($g.End)  [$mWord / ~$($g.DurationWeeks) weeks]" -ForegroundColor Red
        }
        if ($debouncedGaps.Count -gt 0) {
            Write-Host "              ↳ $($debouncedGaps.Count) noise gap(s) ≤$DebounceWeeks week(s) — not shown" -ForegroundColor DarkYellow
        }
        if ($gapResult.ContaminatedMonths.Count -gt 0) {
            Write-Host "              ↳ $($gapResult.ContaminatedMonths.Count) month(s) covered only by contaminated backup(s)" -ForegroundColor Magenta
        }
        if ($realGaps.Count -eq 0 -and $debouncedGaps.Count -eq 0 -and $gapResult.ContaminatedMonths.Count -eq 0) {
            Write-Host '              ↳ Complete — no gaps detected' -ForegroundColor Green
        }
        Write-Host ''
    }

    Write-Host ('─' * $lineWidth) -ForegroundColor DarkGray
    Write-Host "  Axis: $globalMin → $globalMax  ($totalMonths months total)" -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region ── Show-DateRangePrompt ──────────────────────────────────────────────

function Show-DateRangePrompt {
    <#
    .SYNOPSIS
        Optionally prompt the operator for an inclusive date range to restrict
        which device data is included in this golden archive build.
    .DESCRIPTION
        Both bounds are optional — leaving either blank imposes no restriction on
        that side.  When no dates are entered, the result HasFilter=$false and
        the caller should apply no date restriction.

        When the accepted From date is not the 1st of its month, or the accepted
        To date is not the last day of its month, an inline warning is printed
        immediately after the prompt explaining that AD_/DD_ monthly therapy files
        span the full calendar month and will be included in full despite the
        mid-month boundary.  Daily WD_/EL_/PP_ files honour the exact day.  The
        return value is not affected — the date the user entered is preserved as-is.
    .OUTPUTS
        PSCustomObject:
          HasFilter  [bool]   — $true if at least one bound was supplied
          FromDate   [string] — YYYY-MM-DD lower bound, or '' when unrestricted
          ToDate     [string] — YYYY-MM-DD upper bound, or '' when unrestricted
    #>
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host ('─' * 65)
    Write-Host '  DATE RANGE FILTER  (optional)' -ForegroundColor Yellow
    Write-Host ('─' * 65)
    Write-Host '  Restrict the golden archive to data within an inclusive date'
    Write-Host '  range across all selected devices.  Data outside the range is'
    Write-Host '  excluded from every device in this build.'
    Write-Host ''
    Write-Host '  Leave both prompts blank to include ALL available data.' -ForegroundColor DarkGray
    Write-Host '  Format: YYYY-MM-DD  (e.g. 2024-03-01)' -ForegroundColor DarkGray
    Write-Host ''

    $fromDate = ''
    while ($true) {
        $raw = (Read-Host '  From date (inclusive) [blank = no lower bound]').Trim()
        if ($raw -eq '') { break }
        if ($raw -match '^\d{4}-\d{2}-\d{2}$') {
            $__dt = [datetime]::MinValue
            if ([datetime]::TryParse($raw, [ref]$__dt)) {
                $fromDate = $raw
                if ($__dt.Day -ne 1) {
                    Write-Host ''
                    Write-Host '  [!] Mid-month start date — AD_/DD_ monthly therapy files cover the' -ForegroundColor Yellow
                    Write-Host "      full calendar month and cannot be split.  All of $($__dt.ToString('MMMM yyyy'))'s" -ForegroundColor Yellow
                    Write-Host '      AD_/DD_ files will be included regardless of this start day.' -ForegroundColor Yellow
                    Write-Host '      Daily WD_/EL_/PP_ files will be filtered to start on this date.' -ForegroundColor Yellow
                    Write-Host ''
                }
                break
            }
        }
        Write-Host '  Invalid format — use YYYY-MM-DD (e.g. 2024-03-01).' -ForegroundColor Yellow
    }

    $toDate = ''
    while ($true) {
        $raw = (Read-Host '  To date   (inclusive) [blank = no upper bound]').Trim()
        if ($raw -eq '') { break }
        if ($raw -match '^\d{4}-\d{2}-\d{2}$') {
            $__dt = [datetime]::MinValue
            if ([datetime]::TryParse($raw, [ref]$__dt)) {
                if ($fromDate -and $raw -lt $fromDate) {
                    Write-Host "  To date '$raw' is before From date '$fromDate' — please re-enter." -ForegroundColor Yellow
                    continue
                }
                $toDate = $raw
                $lastDay = [System.DateTime]::DaysInMonth($__dt.Year, $__dt.Month)
                if ($__dt.Day -ne $lastDay) {
                    Write-Host ''
                    Write-Host '  [!] Mid-month end date — AD_/DD_ monthly therapy files cover the' -ForegroundColor Yellow
                    Write-Host "      full calendar month and cannot be split.  All of $($__dt.ToString('MMMM yyyy'))'s" -ForegroundColor Yellow
                    Write-Host '      AD_/DD_ files will be included regardless of this end day.' -ForegroundColor Yellow
                    Write-Host '      Daily WD_/EL_/PP_ files will be filtered to end on this date.' -ForegroundColor Yellow
                    Write-Host ''
                }
                break
            }
        }
        Write-Host '  Invalid format — use YYYY-MM-DD (e.g. 2024-03-01).' -ForegroundColor Yellow
    }

    $hasFilter = ($fromDate -ne '' -or $toDate -ne '')
    if ($hasFilter) {
        $fromDisp = if ($fromDate) { $fromDate } else { 'any' }
        $toDisp   = if ($toDate  ) { $toDate   } else { 'any' }
        Write-Host ''
        Write-Host "  Date filter: $fromDisp → $toDisp" -ForegroundColor Cyan
        Write-Host '  Data outside this range will be excluded from the golden archive.' -ForegroundColor DarkGray
    } else {
        Write-Host '  No date filter — all available data will be included.' -ForegroundColor DarkGray
    }
    Write-Host ''

    return [PSCustomObject]@{
        HasFilter = $hasFilter
        FromDate  = $fromDate
        ToDate    = $toDate
    }
}

#endregion

#region ── Show-GoldenDeviceMenu ─────────────────────────────────────────────

function Show-GoldenDeviceMenu {
    <#
    .SYNOPSIS
        Unified device-selection entry point for the golden archive wizard flow.
    .DESCRIPTION
        Presents two clear paths to the operator:
          R)  Recommended — accept the pre-computed suggested device set and proceed.
          C)  Custom      — manually choose devices, enter a brief audit note, and
                           optionally apply an inclusive date-range filter.

        This replaces the former two-step Show-ForceDevicesPrompt +
        Show-DeviceSelection + Show-DateRangePrompt sequence with a single,
        professional interaction.
    .PARAMETER Devices
        Hashtable or PSCustomObject of SN -> device summary from TOC.Devices.
    .PARAMETER Suggested
        Array of SNs pre-selected as the recommended set (all devices for a first
        golden; devices with changed data for an update golden).
    .PARAMETER IsFirstGolden
        When $true the recommendation header reads "first golden — all devices".
        When $false it reads "devices with updated data since last golden".
    .OUTPUTS
        PSCustomObject:
          SelectedSNs  [string[]]  — SNs chosen for this golden run
          IsCustom     [bool]      — $true when the user chose the Custom path
          Reason       [string]    — audit note (empty string on Recommended path)
          FromDate     [string]    — YYYY-MM-DD lower bound, or '' (Custom path only)
          ToDate       [string]    — YYYY-MM-DD upper bound, or '' (Custom path only)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Devices,
        [string[]]$Suggested,
        [switch]$IsFirstGolden
    )

    $snList = if ($Devices -is [hashtable]) {
        @($Devices.Keys | Sort-Object)
    } else {
        @($Devices.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    }

    if (-not $Suggested -or $Suggested.Count -eq 0) { $Suggested = $snList }

    $recommendLabel = if ($IsFirstGolden) {
        "All $($snList.Count) device(s)  —  first golden, no prior archive exists"
    } else {
        "$($Suggested.Count) of $($snList.Count) device(s) with updated data since last golden"
    }

    Write-Host ''
    Write-Host ('─' * 65)
    Write-Host '  DEVICE SELECTION FOR GOLDEN ARCHIVE' -ForegroundColor Cyan
    Write-Host ('─' * 65)
    Write-Host ''
    Write-Host '  Recommended:' -ForegroundColor White
    Write-Host "    $recommendLabel" -ForegroundColor DarkGray
    Write-Host "    SNs: $($Suggested -join ', ')" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  R)  Accept recommended selection and proceed'
    Write-Host '  C)  Custom selection  —  choose specific devices and add a note'
    Write-Host ''

    $pick = ''
    while ($pick -notin @('R', 'C')) {
        $pick = (Read-Host '  Your choice [R/C]').Trim().ToUpperInvariant()
        if ($pick -notin @('R', 'C')) {
            Write-Host '  Please enter R or C.' -ForegroundColor Yellow
        }
    }

    if ($pick -eq 'R') {
        Write-Host ''
        Write-Host '  Proceeding with recommended device selection.' -ForegroundColor Green
        Write-Host ''
        return [PSCustomObject]@{
            SelectedSNs = @($Suggested)
            IsCustom    = $false
            Reason      = ''
            FromDate    = ''
            ToDate      = ''
        }
    }

    # ── Custom path ────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  CUSTOM DEVICE SELECTION' -ForegroundColor Cyan
    Write-Host '  Choose which devices to include.  Pre-selected ([*]) = recommended.' -ForegroundColor DarkGray

    $selectedSNs = Show-DeviceSelection -Devices $Devices -Suggested $Suggested
    if (@($selectedSNs).Count -eq 0) {
        Write-Host '  No devices chosen — reverting to recommended.' -ForegroundColor Yellow
        $selectedSNs = @($Suggested)
    }

    # Audit note (required so there is always a record of why a custom selection was made)
    Write-Host ''
    Write-Host '  Please enter a brief note explaining this custom selection.' -ForegroundColor DarkGray
    Write-Host '  It will be recorded in the archive manifest.' -ForegroundColor DarkGray
    $reason = ''
    while (-not $reason.Trim()) {
        $reason = (Read-Host '  Note').Trim()
        if (-not $reason) {
            Write-Host '  A note is required. Please enter some text.' -ForegroundColor Yellow
        }
    }

    # Optional date range filter
    $dateResult = Show-DateRangePrompt

    Write-Host ''
    Write-Host '  ┌─ Custom Selection Summary ─────────────────────────────────┐' -ForegroundColor Cyan
    Write-Host "  │  Devices : $($selectedSNs -join ', ')" -ForegroundColor Cyan
    Write-Host "  │  Note    : $reason" -ForegroundColor Cyan
    if ($dateResult.HasFilter) {
        $fd = if ($dateResult.FromDate) { $dateResult.FromDate } else { 'any' }
        $td = if ($dateResult.ToDate  ) { $dateResult.ToDate   } else { 'any' }
        Write-Host "  │  Filter  : $fd → $td" -ForegroundColor Cyan
    }
    Write-Host '  └────────────────────────────────────────────────────────────┘' -ForegroundColor Cyan
    Write-Host ''

    return [PSCustomObject]@{
        SelectedSNs = @($selectedSNs)
        IsCustom    = $true
        Reason      = $reason
        FromDate    = $dateResult.FromDate
        ToDate      = $dateResult.ToDate
    }
}

#endregion

Export-ModuleMember -Function @(
    'Show-MainMenu',
    'Show-SourcePicker',
    'Read-ValidatedPath',
    'Read-YesNo',
    'Show-DeviceSelection',
    'Show-ForceDevicesPrompt',
    'Show-DateRangePrompt',
    'Show-GoldenDeviceMenu',
    'Write-ProgressBar',
    'Write-TimelineChart',
    'Show-GapSwimLanes'
)
