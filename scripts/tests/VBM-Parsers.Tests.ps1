#Requires -Version 5.1
# VBM-Parsers.Tests.ps1 — Pester 5 unit tests for VBM-Parsers.psm1
# All tests are pure unit or use minimal temp-file fixtures.
# Run via: Invoke-Pester -Path $PSScriptRoot (or scripts\tests\Run-Tests.ps1)

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1') -Force
}

# ---------------------------------------------------------------------------
Describe 'Get-EdfDateInfo' {

    It 'parses a monthly AD filename' {
        $r = Get-EdfDateInfo -Path 'C:\fake\AD_202408_003.edf'
        $r.FileType  | Should -Be 'AD'
        $r.Year      | Should -Be 2024
        $r.Month     | Should -Be 8
        $r.Sequence  | Should -Be 3
        $r.IsDaily   | Should -Be $false
        $r.Day       | Should -BeNullOrEmpty
    }

    It 'parses a monthly DD filename' {
        $r = Get-EdfDateInfo -Path 'C:\fake\DD_202412_000.edf'
        $r.FileType  | Should -Be 'DD'
        $r.Year      | Should -Be 2024
        $r.Month     | Should -Be 12
        $r.Sequence  | Should -Be 0
    }

    It 'parses a daily WD filename' {
        $r = Get-EdfDateInfo -Path 'C:\fake\WD_20240815_001.edf'
        $r.FileType  | Should -Be 'WD'
        $r.Year      | Should -Be 2024
        $r.Month     | Should -Be 8
        $r.Day       | Should -Be 15
        $r.Sequence  | Should -Be 1
        $r.IsDaily   | Should -Be $true
    }

    It 'parses a PD (P-Series daily) filename' {
        $r = Get-EdfDateInfo -Path 'D:\data\PD_20250101_000.edf'
        $r.FileType  | Should -Be 'PD'
        $r.Year      | Should -Be 2025
        $r.Month     | Should -Be 1
        $r.Day       | Should -Be 1
        $r.IsDaily   | Should -Be $true
    }

    It 'returns null for an unrecognised filename' {
        Get-EdfDateInfo -Path 'C:\fake\garbage.edf'       | Should -BeNullOrEmpty
        Get-EdfDateInfo -Path 'C:\fake\SL_SAPPHIRE.json'  | Should -BeNullOrEmpty
        Get-EdfDateInfo -Path 'C:\fake\AD_2024_000.edf'   | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-EdfHeader' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'returns null for a file shorter than 256 bytes' {
        $p = Join-Path $script:tmp 'short.edf'
        [System.IO.File]::WriteAllBytes($p, [byte[]]::new(100))
        Read-EdfHeader -Path $p | Should -BeNullOrEmpty
    }

    It 'returns null for a nonexistent path' {
        Read-EdfHeader -Path 'C:\does\not\exist.edf' | Should -BeNullOrEmpty
    }

    It 'extracts header fields from a synthetic EDF' {
        $p = Join-Path $script:tmp 'test.edf'
        New-SyntheticEdf -Path $p -SN 'TVXX0000001'
        $h = Read-EdfHeader -Path $p
        $h                | Should -Not -BeNullOrEmpty
        $h.Version        | Should -Be '0'
        $h.HeaderBytes    | Should -Be 256
        $h.NumDataRecords | Should -Be '-1'
        $h.NumSignals     | Should -Be 1
        $h.FileSize       | Should -Be 512   # 256 header + 256 extra body (default)
    }

    It 'RecordingID field contains the embedded SN' {
        $p = Join-Path $script:tmp 'sn_check.edf'
        New-SyntheticEdf -Path $p -SN 'TVXX0000002'
        $h = Read-EdfHeader -Path $p
        $h.RecordingID | Should -Match 'TVXX0000002'
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-EdfDeviceSerial' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'extracts the correct SN from a synthetic EDF' {
        $p = Join-Path $script:tmp 'sn.edf'
        New-SyntheticEdf -Path $p -SN 'TVXX000000D'
        Get-EdfDeviceSerial -Path $p | Should -Be 'TVXX000000D'
    }

    It 'returns null when file is too short' {
        $p = Join-Path $script:tmp 'truncated.edf'
        [System.IO.File]::WriteAllBytes($p, [byte[]]::new(128))
        Get-EdfDeviceSerial -Path $p | Should -BeNullOrEmpty
    }

    It 'returns null for a nonexistent path' {
        Get-EdfDeviceSerial -Path 'C:\no\such\file.edf' | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-PropFile' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'parses all standard keys' {
        $p = Join-Path $script:tmp 'prop.txt'
        Set-Content $p "SN=TVXX0000001`nMN=Trilogy 200`nPT=65`nSV=3.02`nDF=8" -Encoding UTF8
        $r = Read-PropFile -Path $p
        $r.SN | Should -Be 'TVXX0000001'
        $r.MN | Should -Be 'Trilogy 200'
        $r.PT | Should -Be '65'
        $r.SV | Should -Be '3.02'
        $r.DF | Should -Be '8'
    }

    It 'does not fail when the optional VC key is absent' {
        $p = Join-Path $script:tmp 'prop_novc.txt'
        Set-Content $p "SN=TVXX0000001`nMN=Trilogy 200`nPT=65" -Encoding UTF8
        $r = Read-PropFile -Path $p
        $r.SN | Should -Be 'TVXX0000001'
        $r.PSObject.Properties['VC'] | Should -BeNullOrEmpty
    }

    It 'parses the VC key when present (newer CA1032800B)' {
        $p = Join-Path $script:tmp 'prop_vc.txt'
        Set-Content $p "SN=TVXX0000001`nMN=Trilogy 200`nPT=65`nVC=1" -Encoding UTF8
        $r = Read-PropFile -Path $p
        $r.VC | Should -Be '1'
    }

    It 'returns null for a nonexistent path' {
        Read-PropFile -Path 'C:\no\such\prop.txt' | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-LastTxt' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'returns the trimmed active SN' {
        $p = Join-Path $script:tmp 'last.txt'
        Set-Content $p "TVXX0000001`n" -Encoding UTF8
        Read-LastTxt -Path $p | Should -Be 'TVXX0000001'
    }

    It 'returns null for a nonexistent path' {
        Read-LastTxt -Path 'C:\no\such\last.txt' | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-FilesSeq' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'splits paths from CRC-32 hash on last line' {
        $p = Join-Path $script:tmp 'FILES.SEQ'
        Set-Content $p "path/to/file1`npath/to/file2`npath/to/file3`nABCD1234" -Encoding UTF8
        $r = Read-FilesSeq -Path $p
        $r.LineCount | Should -Be 3
        $r.CrcHash   | Should -Be 'ABCD1234'
        $r.Paths[0]  | Should -Be 'path/to/file1'
        $r.Paths[2]  | Should -Be 'path/to/file3'
    }

    It 'treats all lines as paths when last line is not 8 hex digits' {
        $p = Join-Path $script:tmp 'FILES_nocrc.SEQ'
        Set-Content $p "path/to/file1`npath/to/file2" -Encoding UTF8
        $r = Read-FilesSeq -Path $p
        $r.LineCount | Should -Be 2
        $r.CrcHash   | Should -BeNullOrEmpty
    }

    It 'returns null for an empty file' {
        $p = Join-Path $script:tmp 'empty.SEQ'
        [System.IO.File]::WriteAllBytes($p, [byte[]]::new(0))
        Read-FilesSeq -Path $p | Should -BeNullOrEmpty
    }

    It 'returns null for a nonexistent path' {
        Read-FilesSeq -Path 'C:\no\such\FILES.SEQ' | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-PpJson' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'parses valid PP JSON and exposes SN and TimeStamp' {
        $p = Join-Path $script:tmp 'PP_20240823_000.json'
        Set-Content $p '{"SN":"TVXX0000001","TimeStamp":1724400000,"BlowerHours":1200}' -Encoding UTF8
        $r = Read-PpJson -Path $p
        $r.SN        | Should -Be 'TVXX0000001'
        $r.TimeStamp | Should -Be 1724400000
    }

    It 'returns null for malformed JSON' {
        $p = Join-Path $script:tmp 'bad.json'
        Set-Content $p '{not valid json' -Encoding UTF8
        Read-PpJson -Path $p | Should -BeNullOrEmpty
    }

    It 'returns null for a nonexistent path' {
        Read-PpJson -Path 'C:\no\such\PP_20240101_000.json' | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-BinFileInfo' {

    It 'parses a valid BIN filename' {
        $r = Get-BinFileInfo -Path 'C:\data\65_TVXX0000001_3_1724400000.bin'
        $r.ProductType   | Should -Be '65'
        $r.SerialNumber  | Should -Be 'TVXX0000001'
        $r.DumpType      | Should -Be 3
        $r.UnixTimestamp | Should -Be 1724400000
        $r.DateTime      | Should -Not -BeNullOrEmpty
    }

    It 'returns null for a filename that does not match the pattern' {
        Get-BinFileInfo -Path 'C:\data\randomfile.bin'    | Should -BeNullOrEmpty
        Get-BinFileInfo -Path 'C:\data\SL_SAPPHIRE.json'  | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-ElCsvInfo' {

    It 'parses a valid EL_ CSV filename' {
        $r = Get-ElCsvInfo -Path 'C:\data\EL_TVXX0000001_20240815.csv'
        $r.SerialNumber | Should -Be 'TVXX0000001'
        $r.DateString   | Should -Be '20240815'
    }

    It 'returns null for unrecognised filenames' {
        Get-ElCsvInfo -Path 'C:\data\somelog.csv'               | Should -BeNullOrEmpty
        Get-ElCsvInfo -Path 'C:\data\EL_TVXX0000001_2024.csv'   | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-PpJsonDateInfo' {

    It 'parses a valid PP JSON filename' {
        $r = Get-PpJsonDateInfo -Path 'D:\ring\P3\PP_20240823_005.json'
        $r.Year     | Should -Be 2024
        $r.Month    | Should -Be 8
        $r.Day      | Should -Be 23
        $r.Sequence | Should -Be 5
    }

    It 'returns null for unrecognised filenames' {
        Get-PpJsonDateInfo -Path 'D:\ring\P3\notamatch.json' | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-FileHashMD5' {

    BeforeAll { $script:tmp = New-TempDir }
    AfterAll  { Remove-TempDir $script:tmp }

    It 'returns the same hash as Get-FileHash for identical content' {
        $p = Join-Path $script:tmp 'hash_me.bin'
        [System.IO.File]::WriteAllBytes($p, [byte[]](0x41, 0x42, 0x43))
        $expected = (Get-FileHash -Path $p -Algorithm MD5).Hash
        Get-FileHashMD5 -Path $p | Should -Be $expected
    }

    It 'returns different hashes for different content' {
        $p1 = Join-Path $script:tmp 'a.bin'
        $p2 = Join-Path $script:tmp 'b.bin'
        [System.IO.File]::WriteAllBytes($p1, [byte[]](0x01))
        [System.IO.File]::WriteAllBytes($p2, [byte[]](0x02))
        $h1 = Get-FileHashMD5 -Path $p1
        $h2 = Get-FileHashMD5 -Path $p2
        $h1 | Should -Not -Be $h2
    }

    It 'returns null for a nonexistent path' {
        Get-FileHashMD5 -Path 'C:\no\such\file.bin' | Should -BeNullOrEmpty
    }
}
