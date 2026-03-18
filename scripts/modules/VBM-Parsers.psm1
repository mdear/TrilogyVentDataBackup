# VBM-Parsers.psm1 — File format parsers for Trilogy 200 ventilator SD card data

function Read-EdfHeader {
    <#
    .SYNOPSIS
        Parse the 256-byte fixed header of an EDF/EDF+ file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 256) { return $null }
        $enc = [System.Text.Encoding]::ASCII
        [PSCustomObject]@{
            Version        = $enc.GetString($bytes, 0, 8).Trim()
            PatientID      = $enc.GetString($bytes, 8, 80).Trim()
            RecordingID    = $enc.GetString($bytes, 88, 80).Trim()
            StartDate      = $enc.GetString($bytes, 168, 8).Trim()
            StartTime      = $enc.GetString($bytes, 176, 8).Trim()
            HeaderBytes    = [int]($enc.GetString($bytes, 184, 8).Trim())
            Reserved       = $enc.GetString($bytes, 192, 44).Trim()
            NumDataRecords = $enc.GetString($bytes, 236, 8).Trim()
            RecordDuration = $enc.GetString($bytes, 244, 8).Trim()
            NumSignals     = [int]($enc.GetString($bytes, 252, 4).Trim())
            FileSize       = $bytes.Length
            FilePath       = $Path
        }
    }
    catch { return $null }
}

function Get-EdfDeviceSerial {
    <#
    .SYNOPSIS
        Extract device serial number from EDF RecordingID field.
        Format: "Startdate DD-MMM-YYYY X X TGY200 0 {SN} {MN} {PT} {FW}"
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $hdr = Read-EdfHeader -Path $Path
    if (-not $hdr -or -not $hdr.RecordingID) { return $null }
    # SN is typically the token after "TGY200 0" — pattern: TV followed by digits and optional letters
    if ($hdr.RecordingID -match '\b(TV\w+)\b') {
        return $Matches[1]
    }
    return $null
}

function Get-EdfDateInfo {
    <#
    .SYNOPSIS
        Extract date info from EDF filename and header.
        Returns file type (AD/DD/WD/PD/PA), date component, sequence number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $result = [PSCustomObject]@{
        FileType = $null
        Year     = $null
        Month    = $null
        Day      = $null
        Sequence = $null
        IsDaily  = $false
    }

    # Monthly format: AD_YYYYMM_NNN or DD_YYYYMM_NNN
    if ($name -match '^(AD|DD)_(\d{4})(\d{2})_(\d{3})$') {
        $result.FileType = $Matches[1]
        $result.Year     = [int]$Matches[2]
        $result.Month    = [int]$Matches[3]
        $result.Sequence = [int]$Matches[4]
    }
    # Daily format: WD_YYYYMMDD_NNN
    elseif ($name -match '^(WD)_(\d{4})(\d{2})(\d{2})_(\d{3})$') {
        $result.FileType = $Matches[1]
        $result.Year     = [int]$Matches[2]
        $result.Month    = [int]$Matches[3]
        $result.Day      = [int]$Matches[4]
        $result.Sequence = [int]$Matches[5]
        $result.IsDaily  = $true
    }
    # P-Series daily: PD_YYYYMMDD_NNN or PA_YYYYMMDD_NNN
    elseif ($name -match '^(PD|PA)_(\d{4})(\d{2})(\d{2})_(\d{3})$') {
        $result.FileType = $Matches[1]
        $result.Year     = [int]$Matches[2]
        $result.Month    = [int]$Matches[3]
        $result.Day      = [int]$Matches[4]
        $result.Sequence = [int]$Matches[5]
        $result.IsDaily  = $true
    }
    else { return $null }

    return $result
}

function Read-PropFile {
    <#
    .SYNOPSIS
        Parse prop.txt (key=value per line): CF, SN, MN, PT, SV, DF, VC
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    $props = @{}
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*(\w+)\s*=\s*(.+)\s*$') {
            $props[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return [PSCustomObject]$props
}

function Read-LastTxt {
    <#
    .SYNOPSIS
        Read last.txt — single line containing active device serial number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    return (Get-Content $Path -Raw).Trim()
}

function Read-FilesSeq {
    <#
    .SYNOPSIS
        Parse FILES.SEQ or TRANSMITFILE.SEQ — list of paths ending with CRC-32 hash.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    $lines = @(Get-Content $Path)
    if ($lines.Count -eq 0) { return $null }

    # Last line is CRC-32 hash (8 hex chars)
    $hash = $null
    $paths = @()
    if ($lines[-1] -match '^[0-9a-fA-F]{8}$') {
        $hash = $lines[-1]
        $paths = $lines[0..($lines.Count - 2)]
    }
    else {
        $paths = $lines
    }

    [PSCustomObject]@{
        Paths     = $paths
        CrcHash   = $hash
        LineCount = $paths.Count
        FilePath  = $Path
    }
}

function Read-PpJson {
    <#
    .SYNOPSIS
        Parse PP_*.json (Periodic Properties snapshot).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw
        return $raw | ConvertFrom-Json
    }
    catch { return $null }
}

function Get-BinFileInfo {
    <#
    .SYNOPSIS
        Parse BIN filename: {PT}_{SN}_{Type}_{UnixTimestamp}.bin
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -match '^(\w+)_(TV\w+)_(\d+)_(\d+)$') {
        $ts = [int64]$Matches[4]
        $epoch = [DateTimeOffset]::FromUnixTimeSeconds($ts)
        [PSCustomObject]@{
            ProductType   = $Matches[1]
            SerialNumber  = $Matches[2]
            DumpType      = [int]$Matches[3]
            UnixTimestamp = $ts
            DateTime      = $epoch.UtcDateTime
            FilePath      = $Path
        }
    }
    else { return $null }
}

function Get-ElCsvInfo {
    <#
    .SYNOPSIS
        Extract SN and date from EL_ CSV filename and binary header.
        Filename: EL_{SN}_{YYYYMMDD}.csv
        Binary header row 1: "File Creation Date (GMT),Device Serial Number,,"
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -match '^EL_(TV\w+)_(\d{8})$') {
        [PSCustomObject]@{
            SerialNumber = $Matches[1]
            DateString   = $Matches[2]
            FilePath     = $Path
        }
    }
    else { return $null }
}

function Get-FileHashMD5 {
    <#
    .SYNOPSIS
        Compute MD5 hash of a file for dedup/integrity comparison.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm MD5).Hash
}

function Get-PpJsonDateInfo {
    <#
    .SYNOPSIS
        Extract date from PP_*.json filename: PP_YYYYMMDD_NNN.json
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -match '^PP_(\d{4})(\d{2})(\d{2})_(\d{3})$') {
        [PSCustomObject]@{
            Year     = [int]$Matches[1]
            Month    = [int]$Matches[2]
            Day      = [int]$Matches[3]
            Sequence = [int]$Matches[4]
            FilePath = $Path
        }
    }
    else { return $null }
}

Export-ModuleMember -Function @(
    'Read-EdfHeader',
    'Get-EdfDeviceSerial',
    'Get-EdfDateInfo',
    'Read-PropFile',
    'Read-LastTxt',
    'Read-FilesSeq',
    'Read-PpJson',
    'Get-BinFileInfo',
    'Get-ElCsvInfo',
    'Get-FileHashMD5',
    'Get-PpJsonDateInfo'
)
