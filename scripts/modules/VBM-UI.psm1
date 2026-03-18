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
    Write-Host ''
    Write-Host '  Q) Quit'
    Write-Host ''
    do {
        $choice = (Read-Host 'Choose an option').Trim().ToUpperInvariant()
    } while ($choice -notin @('1','2','3','4','5','6','7','Q'))

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

Export-ModuleMember -Function @(
    'Show-MainMenu',
    'Show-SourcePicker',
    'Read-ValidatedPath',
    'Read-YesNo',
    'Show-DeviceSelection',
    'Show-ForceDevicesPrompt',
    'Write-ProgressBar',
    'Write-TimelineChart'
)
