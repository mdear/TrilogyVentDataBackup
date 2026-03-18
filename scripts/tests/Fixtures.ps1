# Fixtures.ps1 - Shared test helpers for VentBackupManager Pester test suite.
# Dot-source inside BeforeAll:  . (Join-Path $PSScriptRoot 'Fixtures.ps1')

function New-TempDir {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

function Remove-TempDir {
    param([string]$Path)
    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-SyntheticEdf {
    <#
    .SYNOPSIS
        Write a minimal valid EDF binary file (256-byte header + extra body bytes).
        RecordingID is set to "Startdate 01-JAN-2024 X X TGY200 0 {SN} CA1032800B 65 3.02"
        so that Get-EdfDeviceSerial extracts $SN and _ScanBackupFolder extracts firmware "3.02".
    .PARAMETER Path        Full path of the file to create. Parent directories are created as needed.
    .PARAMETER SN          Device serial number embedded in the EDF RecordingID field.
    .PARAMETER ExtraBodyBytes
        Bytes appended after the 256-byte header (default 256 -> 512-byte total file).
        Increase this value to simulate a "larger" version of the same file for truncation tests.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SN             = 'TVXX0000001',
        [int]   $ExtraBodyBytes = 256
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $enc   = [System.Text.Encoding]::ASCII
    $bytes = [byte[]]::new(256 + $ExtraBodyBytes)

    # Inline helper: stamp a fixed-width ASCII field into $bytes.
    # $bytes and $enc are visible via PowerShell dynamic scoping.
    $stamp = {
        param([string]$Val, [int]$Off, [int]$Len)
        $src = $enc.GetBytes($Val.PadRight($Len).Substring(0, $Len))
        [Array]::Copy($src, 0, $bytes, $Off, $Len)
    }

    # EDF fixed-format header fields (offsets per ARCHITECTURE.md spec)
    & $stamp '0'                                                               0    8   # Version
    & $stamp "Startdate 01-JAN-2024 X X TGY200 0 $SN CA1032800B 65 3.02"    88   80   # RecordingID
    & $stamp '01.01.24'                                                      168    8   # StartDate
    & $stamp '00.00.00'                                                      176    8   # StartTime
    & $stamp '256'                                                           184    8   # HeaderBytes
    & $stamp '-1'                                                            236    8   # NumDataRecords (-1 = active recording, per spec)
    & $stamp '1'                                                             244    8   # RecordDuration
    & $stamp '1'                                                             252    4   # NumSignals

    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-SyntheticBackup {
    <#
    .SYNOPSIS
        Create a complete backup folder tree with valid EDF headers and P-Series ring buffer structure.
    .PARAMETER BackupRoot   Parent directory; the backup folder is created underneath it.
    .PARAMETER Name         Backup folder name.
    .PARAMETER DeviceSNs    Array of device SNs to include. First entry becomes last.txt (active).
                            Each device gets its own P-Series/{SN}/ tree and Trilogy EDF pair.
    .PARAMETER YearMonth    Six-digit date component (YYYYMM) used in EDF filenames and PP JSON names.
    .PARAMETER EdfBodyBytes Extra bytes appended after the EDF header, controlling file size.
    .OUTPUTS    Full path to the newly created backup folder.
    #>
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$DeviceSNs    = @('TVXX0000001'),
        [string]  $YearMonth    = '202408',
        [int]     $EdfBodyBytes = 256,
        [int]     $BlowerHours  = 1200
    )

    $backupPath = Join-Path $BackupRoot $Name
    $null = New-Item -ItemType Directory -Path $backupPath -Force

    $primarySN = $DeviceSNs[0]
    $triDir    = Join-Path $backupPath 'Trilogy'
    $null = New-Item -ItemType Directory -Path $triDir -Force

    for ($i = 0; $i -lt $DeviceSNs.Count; $i++) {
        $sn  = $DeviceSNs[$i]
        $seq = '{0:D3}' -f $i

        # P-Series tree: steering files + ring buffer P0-P7
        $psDir = Join-Path $backupPath "P-Series\$sn"
        $null  = New-Item -ItemType Directory -Path $psDir -Force

        Set-Content (Join-Path $psDir 'prop.txt')         "SN=$sn`nMN=Trilogy 200`nPT=65`nSV=3.02"  -Encoding UTF8
        Set-Content (Join-Path $psDir 'FILES.SEQ')        "file1`nfile2`nfile3`n12345678"            -Encoding UTF8
        Set-Content (Join-Path $psDir 'TRANSMITFILE.SEQ') "file1`nfile2`nABCDEF01"                  -Encoding UTF8
        Set-Content (Join-Path $psDir 'SL_SAPPHIRE.json') '{"bluefin":"v1","data":"sapphire"}'      -Encoding UTF8

        for ($p = 0; $p -le 7; $p++) {
            $ringDir = Join-Path $psDir "P$p"
            $null    = New-Item -ItemType Directory -Path $ringDir -Force
            $ppName  = "PP_${YearMonth}23_00${p}.json"
            $ts      = 1724400000 + $p + ($i * 100)
            Set-Content (Join-Path $ringDir $ppName) `
                "{`"SN`":`"$sn`",`"TimeStamp`":$ts,`"BlowerHours`":$BlowerHours}" -Encoding UTF8
        }

        # Trilogy EDF pair — sequence offset by device index to avoid filename collisions
        New-SyntheticEdf -Path (Join-Path $triDir "AD_${YearMonth}_$seq.edf") -SN $sn -ExtraBodyBytes $EdfBodyBytes
        New-SyntheticEdf -Path (Join-Path $triDir "DD_${YearMonth}_$seq.edf") -SN $sn -ExtraBodyBytes $EdfBodyBytes
    }

    Set-Content (Join-Path $backupPath 'P-Series\last.txt') $primarySN -Encoding UTF8
    return $backupPath
}

function New-SplitSDBackupPair {
    <#
    .SYNOPSIS
        Create two synthetic backup folders for the SAME device SN with non-overlapping
        date ranges, simulating data from two separate SD cards.
    .PARAMETER BackupRoot       Parent directory where backup folders are created.
    .PARAMETER SN               Device serial number.
    .PARAMETER EarlyYearMonth   YYYYMM for the first (earlier) backup.  Default: 202401.
    .PARAMETER LateYearMonth    YYYYMM for the second (later) backup.   Default: 202408.
    .PARAMETER EarlyBlowerHours BlowerHours embedded in PP JSON for the early backup.
    .PARAMETER LateBlowerHours  BlowerHours embedded in PP JSON for the late backup.
    .OUTPUTS    PSCustomObject @{ EarlyBackup; LateBackup; SN }
    #>
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [string]$SN               = 'TVXX0000001',
        [string]$EarlyYearMonth   = '202401',
        [string]$LateYearMonth    = '202408',
        [int]   $EarlyBlowerHours = 500,
        [int]   $LateBlowerHours  = 5000
    )
    $early = New-SyntheticBackup -BackupRoot $BackupRoot `
        -Name "bak_early_$EarlyYearMonth" `
        -DeviceSNs @($SN) `
        -YearMonth $EarlyYearMonth `
        -BlowerHours $EarlyBlowerHours

    $late  = New-SyntheticBackup -BackupRoot $BackupRoot `
        -Name "bak_late_$LateYearMonth" `
        -DeviceSNs @($SN) `
        -YearMonth $LateYearMonth `
        -BlowerHours $LateBlowerHours

    return [PSCustomObject]@{
        EarlyBackup = $early
        LateBackup  = $late
        SN          = $SN
    }
}
