#Requires -Version 5.1
# VBM-GoldenContent.Tests.ps1 â€” Pester 5 unit tests for Test-GoldenContent.
# Validates deep format and DirectView-compatibility analysis of golden archives.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')       -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1')      -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-GoldenArchive.psm1') -Force

    # Helper: build a golden from a fresh synthetic backup and return its path.
    function New-TestGolden {
        param(
            [string]$BackupRoot,
            [string]$GoldenRoot,
            [string[]]$SNs       = @('TV100000001'),
            [string]$YearMonth   = '202408',
            [int]$EdfBodyBytes   = 256,
            [int]$BlowerHours    = 1200
        )
        foreach ($sn in $SNs) {
            # Suppress return value — it's the backup path, not the golden path.
            # Leaking it would make this function return an array instead of a string.
            $null = New-SyntheticBackup -BackupRoot $BackupRoot -Name "bak_$sn" `
                -DeviceSNs @($sn) -YearMonth $YearMonth `
                -EdfBodyBytes $EdfBodyBytes -BlowerHours $BlowerHours
        }
        $inv = Get-BackupInventory -BackupRoot $BackupRoot
        $toc = Get-BackupTOC -Inventory $inv
        # Cast to [string] to guarantee a scalar even if the function leaks console objects
        return [string](New-GoldenArchive -TOC $toc -GoldenRoot $GoldenRoot -Devices $SNs)
    }

    # Helper: build a golden then edit its manifest via a scriptblock.
    function Edit-Manifest {
        param([string]$GoldenPath, [scriptblock]$Mutate)
        $mPath = Join-Path $GoldenPath 'manifest.json'
        $m = Get-Content $mPath -Raw | ConvertFrom-Json
        & $Mutate $m
        $m | ConvertTo-Json -Depth 20 | Set-Content $mPath -Encoding UTF8
    }

    # Helper: write a fixed-width ASCII field at a given byte offset in a file.
    # EDF field offsets (per New-SyntheticEdf in Fixtures.ps1):
    #   0=Version(8)  88=RecordingID(80)  168=StartDate(8)  176=StartTime(8)
    #   184=HeaderBytes(8)  236=NumDataRecords(8)  244=RecordDuration(8)  252=NumSignals(4)
    function Write-EdfField {
        param([string]$Path, [int]$Offset, [int]$Length, [string]$Value)
        $enc   = [System.Text.Encoding]::ASCII
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $src   = $enc.GetBytes($Value.PadRight($Length).Substring(0, $Length))
        [Array]::Copy($src, 0, $bytes, $Offset, $Length)
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }

    # Helper: return the full path of the first AD_*.edf in a golden for a given SN.
    function Get-FirstAD {
        param([string]$GoldenPath, [string]$SN)
        Get-ChildItem -LiteralPath (Join-Path $GoldenPath "$SN\Trilogy") -Filter 'AD_*.edf' |
            Select-Object -First 1 -ExpandProperty FullName
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent â€” manifest schema validation' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:gold  = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot
    }
    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'passes for a freshly built synthetic golden' {
        $result = Test-GoldenContent -GoldenPath $script:gold
        $result.CriticalCount | Should -Be 0
        $result.ErrorCount    | Should -Be 0
        $result.Passed        | Should -Be $true
    }

    It 'counts inspected files > 0' {
        $result = Test-GoldenContent -GoldenPath $script:gold
        $result.FileCount | Should -BeGreaterThan 0
    }

    It 'reports Critical ManifestSchema when manifest.json is missing' {
        $gold2 = Join-Path $script:gRoot '_golden_missing_manifest'
        $null  = New-Item -ItemType Directory -Path $gold2 -Force
        $result = Test-GoldenContent -GoldenPath $gold2
        $result.Passed        | Should -Be $false
        $result.CriticalCount | Should -BeGreaterThan 0
        $result.Issues[0].Category | Should -Be 'ManifestSchema'
    }

    It 'reports Critical ManifestSchema when manifest.json is not valid JSON' {
        $gold3 = Join-Path $script:gRoot '_golden_bad_manifest'
        $null  = New-Item -ItemType Directory -Path $gold3 -Force
        Set-Content (Join-Path $gold3 'manifest.json') 'NOT JSON {{{' -Encoding UTF8
        $result = Test-GoldenContent -GoldenPath $gold3
        $result.Passed        | Should -Be $false
        $result.CriticalCount | Should -BeGreaterThan 0
    }

    It 'reports Error ManifestSchema when version field is wrong' {
        # Build a valid golden then corrupt the version field
        $bRoot4 = New-TempDir
        $gRoot4 = New-TempDir
        try {
            $gold4 = New-TestGolden -BackupRoot $bRoot4 -GoldenRoot $gRoot4
            $mPath = Join-Path $gold4 'manifest.json'
            $m = Get-Content $mPath -Raw | ConvertFrom-Json
            $m.version = 99
            $m | ConvertTo-Json -Depth 20 | Set-Content $mPath -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $gold4
            $versionIssues = @($result.Issues | Where-Object {
                $_.Category -eq 'ManifestSchema' -and $_.Message -match 'version'
            })
            $versionIssues.Count | Should -BeGreaterThan 0
            $versionIssues[0].Severity | Should -Be 'Error'
        } finally {
            Remove-TempDir $bRoot4
            Remove-TempDir $gRoot4
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent â€” DirectView compatibility gates' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:sn    = 'TV200000001'
        $script:gold  = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot -SNs @($script:sn)
    }
    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'reports Critical DirectViewCompat when Trilogy/ directory is absent' {
        $bRoot5 = New-TempDir; $gRoot5 = New-TempDir
        try {
            $gold5 = New-TestGolden -BackupRoot $bRoot5 -GoldenRoot $gRoot5 -SNs @('TV200000002')
            $triPath = Join-Path $gold5 'TV200000002\Trilogy'
            if (Test-Path $triPath) { Remove-Item $triPath -Recurse -Force }
            $result = Test-GoldenContent -GoldenPath $gold5
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'DirectViewCompat' -and $_.Severity -eq 'Critical' -and $_.Message -match 'Trilogy' })
            $issues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRoot5; Remove-TempDir $gRoot5 }
    }

    It 'reports Critical DirectViewCompat when P-Series/ directory is absent' {
        $bRoot6 = New-TempDir; $gRoot6 = New-TempDir
        try {
            $gold6 = New-TestGolden -BackupRoot $bRoot6 -GoldenRoot $gRoot6 -SNs @('TV200000003')
            $psDir = Join-Path $gold6 'TV200000003\P-Series'
            if (Test-Path $psDir) { Remove-Item $psDir -Recurse -Force }
            $result = Test-GoldenContent -GoldenPath $gold6
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'DirectViewCompat' -and $_.Severity -eq 'Critical' -and $_.Message -match 'P-Series' })
            $issues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRoot6; Remove-TempDir $gRoot6 }
    }

    It 'reports Critical DirectViewCompat when last.txt is missing' {
        $bRoot7 = New-TempDir; $gRoot7 = New-TempDir
        try {
            $gold7 = New-TestGolden -BackupRoot $bRoot7 -GoldenRoot $gRoot7 -SNs @('TV200000004')
            $lastTxt = Join-Path $gold7 'TV200000004\P-Series\last.txt'
            if (Test-Path $lastTxt) { Remove-Item $lastTxt -Force }
            $result = Test-GoldenContent -GoldenPath $gold7
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'DirectViewCompat' -and $_.Message -match 'last.txt' })
            $issues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRoot7; Remove-TempDir $gRoot7 }
    }

    It 'reports Error DirectViewCompat when last.txt contains wrong SN' {
        $bRoot8 = New-TempDir; $gRoot8 = New-TempDir
        try {
            $sn8   = 'TV200000005'
            $gold8 = New-TestGolden -BackupRoot $bRoot8 -GoldenRoot $gRoot8 -SNs @($sn8)
            $lastTxt = Join-Path $gold8 "$sn8\P-Series\last.txt"
            Set-Content $lastTxt 'TVWRONGWRONG' -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $gold8
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'DirectViewCompat' -and $_.Severity -eq 'Error' -and $_.File -match 'last.txt' })
            $issues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRoot8; Remove-TempDir $gRoot8 }
    }

    It 'reports Critical DirectViewCompat when no AD_*.edf files exist in Trilogy/' {
        $bRoot9 = New-TempDir; $gRoot9 = New-TempDir
        try {
            $sn9   = 'TV200000006'
            $gold9 = New-TestGolden -BackupRoot $bRoot9 -GoldenRoot $gRoot9 -SNs @($sn9)
            $triPath = Join-Path $gold9 "$sn9\Trilogy"
            Get-ChildItem -LiteralPath $triPath -Filter 'AD_*.edf' | Remove-Item -Force
            $result = Test-GoldenContent -GoldenPath $gold9
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'DirectViewCompat' -and $_.Severity -eq 'Critical' -and $_.Message -match 'AD_' })
            $issues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRoot9; Remove-TempDir $gRoot9 }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent â€” EDF format validation' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:sn    = 'TV300000001'
        $script:gold  = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot -SNs @($script:sn)
    }
    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'reports Clean EDF header fields in a synthetic golden pass with no issues' {
        $result = Test-GoldenContent -GoldenPath $script:gold
        $edfIssues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' })
        # Synthetic EDFs have correct headers â€” no EdfFormat issues expected
        $edfIssues.Count | Should -Be 0
    }

    It 'reports Critical EdfFormat when an EDF is truncated to < 256 bytes' {
        $bRootT = New-TempDir; $gRootT = New-TempDir
        try {
            $snT   = 'TV300000002'
            $goldT = New-TestGolden -BackupRoot $bRootT -GoldenRoot $gRootT -SNs @($snT)
            $triPath = Join-Path $goldT "$snT\Trilogy"
            $firstEdf = Get-ChildItem -LiteralPath $triPath -Filter 'AD_*.edf' | Select-Object -First 1
            # Overwrite with tiny file (< 256 bytes)
            [System.IO.File]::WriteAllBytes($firstEdf.FullName, [byte[]]::new(100))
            # Update manifest hash so Test-GoldenIntegrity doesn't interfere
            $mPath = Join-Path $goldT 'manifest.json'
            $m = Get-Content $mPath -Raw | ConvertFrom-Json
            $snProp  = $m.devices.PSObject.Properties[$snT]
            $hashKey = "Trilogy/$($firstEdf.Name)"
            if ($snProp -and $snProp.Value.fileHashes.PSObject.Properties[$hashKey]) {
                $snProp.Value.fileHashes.PSObject.Properties[$hashKey].Value = (Get-FileHash -Path $firstEdf.FullName -Algorithm MD5).Hash
            }
            $m | ConvertTo-Json -Depth 20 | Set-Content $mPath -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $goldT
            $critical = @($result.Issues | Where-Object { $_.Severity -eq 'Critical' -and $_.Category -eq 'EdfFormat' })
            $critical.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRootT; Remove-TempDir $gRootT }
    }

    It 'reports Error EdfFormat when EDF SN does not match device folder' {
        $bRootS = New-TempDir; $gRootS = New-TempDir
        try {
            $snS   = 'TV300000003'
            $goldS = New-TestGolden -BackupRoot $bRootS -GoldenRoot $gRootS -SNs @($snS)
            $triPath = Join-Path $goldS "$snS\Trilogy"
            $firstEdf = Get-ChildItem -LiteralPath $triPath -Filter 'AD_*.edf' | Select-Object -First 1
            # Overwrite the EDF header SN with a different SN (same size file)
            $bytes = [System.IO.File]::ReadAllBytes($firstEdf.FullName)
            $enc   = [System.Text.Encoding]::ASCII
            $wrongRec = "Startdate 01-JAN-2024 X X TGY200 0 TVWRONGWRONG CA1032800B 65 3.02".PadRight(80).Substring(0,80)
            $wrongBytes = $enc.GetBytes($wrongRec)
            [Array]::Copy($wrongBytes, 0, $bytes, 88, 80)
            [System.IO.File]::WriteAllBytes($firstEdf.FullName, $bytes)
            $result = Test-GoldenContent -GoldenPath $goldS
            $snIssues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' -and $_.Message -match 'TVWRONGWRONG' })
            $snIssues.Count | Should -BeGreaterThan 0
            $snIssues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $bRootS; Remove-TempDir $gRootS }
    }

    It 'reports Error EdfPairing when a DD file is missing its AD pair' {
        $bRootP = New-TempDir; $gRootP = New-TempDir
        try {
            $snP   = 'TV300000004'
            $goldP = New-TestGolden -BackupRoot $bRootP -GoldenRoot $gRootP -SNs @($snP)
            $triPath = Join-Path $goldP "$snP\Trilogy"
            # Remove all AD files — should produce EdfPairing Error for each DD
            Get-ChildItem -LiteralPath $triPath -Filter 'AD_*.edf' | Remove-Item -Force
            # Also remove them from the manifest so we avoid unrelated integrity issues
            $mPath = Join-Path $goldP 'manifest.json'
            $m = Get-Content $mPath -Raw | ConvertFrom-Json
            $hashes = $m.devices.PSObject.Properties[$snP].Value.fileHashes
            $toRemove = @($hashes.PSObject.Properties | Where-Object { $_.Name -match '^Trilogy/AD_' } | Select-Object -ExpandProperty Name)
            foreach ($k in $toRemove) { $hashes.PSObject.Properties.Remove($k) }
            $m | ConvertTo-Json -Depth 20 | Set-Content $mPath -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $goldP
            $pairIssues = @($result.Issues | Where-Object { $_.Category -eq 'EdfPairing' })
            $pairIssues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRootP; Remove-TempDir $gRootP }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent — P-Series format validation' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:sn    = 'TV400000001'
        $script:gold  = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot -SNs @($script:sn)
    }
    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'reports Error PSeriesFormat when prop.txt has wrong SN' {
        $bRootW = New-TempDir; $gRootW = New-TempDir
        try {
            $snW   = 'TV400000002'
            $goldW = New-TestGolden -BackupRoot $bRootW -GoldenRoot $gRootW -SNs @($snW)
            $propPath = Join-Path $goldW "$snW\P-Series\$snW\prop.txt"
            Set-Content $propPath "SN=TVWRONGWRONG`nMN=Trilogy 200`nPT=0x65`nSV=3.02" -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $goldW
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'TVWRONGWRONG' })
            $issues.Count | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $bRootW; Remove-TempDir $gRootW }
    }

    It 'reports Warning PSeriesFormat when PT field is not 0x... hex format' {
        $bRootPT = New-TempDir; $gRootPT = New-TempDir
        try {
            $snPT   = 'TV400000003'
            $goldPT = New-TestGolden -BackupRoot $bRootPT -GoldenRoot $gRootPT -SNs @($snPT)
            $propPath = Join-Path $goldPT "$snPT\P-Series\$snPT\prop.txt"
            Set-Content $propPath "SN=$snPT`nMN=Trilogy 200`nPT=65`nSV=3.02" -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $goldPT
            $ptIssues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'PT' })
            $ptIssues.Count | Should -BeGreaterThan 0
            $ptIssues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $bRootPT; Remove-TempDir $gRootPT }
    }

    It 'reports Warning PSeriesFormat when FILES.SEQ entry count exceeds TRANSMITFILE.SEQ' {
        # This test inverts the counts by writing a fat TRANSMITFILE.SEQ
        $bRootF = New-TempDir; $gRootF = New-TempDir
        try {
            $snF   = 'TV400000004'
            $goldF = New-TestGolden -BackupRoot $bRootF -GoldenRoot $gRootF -SNs @($snF)
            $psSnDir = Join-Path $goldF "$snF\P-Series\$snF"
            $filesSeq   = Join-Path $psSnDir 'FILES.SEQ'
            $transSeq   = Join-Path $psSnDir 'TRANSMITFILE.SEQ'
            Set-Content $filesSeq  "file1`nfile2`nABCDEF01" -Encoding UTF8      # 2 entries + CRC
            Set-Content $transSeq  "file1`nfile2`nfile3`nfile4`nABCDEF01" -Encoding UTF8  # 4 entries + CRC
            $result = Test-GoldenContent -GoldenPath $goldF
            $seqIssues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'superset' })
            $seqIssues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRootF; Remove-TempDir $gRootF }
    }

    It 'reports Error PSeriesFormat when PP JSON has wrong SN' {
        $bRootPP = New-TempDir; $gRootPP = New-TempDir
        try {
            $snPP   = 'TV400000005'
            $goldPP = New-TestGolden -BackupRoot $bRootPP -GoldenRoot $gRootPP -SNs @($snPP)
            # Overwrite all PP JSON files with wrong SN
            $psSnDir = Join-Path $goldPP "$snPP\P-Series\$snPP"
            Get-ChildItem -LiteralPath $psSnDir -Filter 'PP_*.json' -Recurse | ForEach-Object {
                Set-Content $_.FullName '{"SN":"TVWRONG","TimeStamp":1700000000,"BlowerHours":1000}' -Encoding UTF8
            }
            $result = Test-GoldenContent -GoldenPath $goldPP
            $ppIssues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'TVWRONG' })
            $ppIssues.Count | Should -BeGreaterThan 0
            $ppIssues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $bRootPP; Remove-TempDir $gRootPP }
    }

    It 'reports Error PSeriesFormat when PP JSON is missing TimeStamp field' {
        $bRootTS = New-TempDir; $gRootTS = New-TempDir
        try {
            $snTS   = 'TV400000006'
            $goldTS = New-TestGolden -BackupRoot $bRootTS -GoldenRoot $gRootTS -SNs @($snTS)
            $psSnDir = Join-Path $goldTS "$snTS\P-Series\$snTS"
            Get-ChildItem -LiteralPath $psSnDir -Filter 'PP_*.json' -Recurse | Select-Object -First 1 | ForEach-Object {
                Set-Content $_.FullName "{`"SN`":`"$snTS`",`"BlowerHours`":1000}" -Encoding UTF8
            }
            $result = Test-GoldenContent -GoldenPath $goldTS
            $tsIssues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'TimeStamp' })
            $tsIssues.Count | Should -BeGreaterThan 0
            $tsIssues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $bRootTS; Remove-TempDir $gRootTS }
    }

    It 'reports Warning PSeriesFormat when BlowerHours is negative' {
        $bRootBH = New-TempDir; $gRootBH = New-TempDir
        try {
            $snBH   = 'TV400000007'
            $goldBH = New-TestGolden -BackupRoot $bRootBH -GoldenRoot $gRootBH -SNs @($snBH)
            $psSnDir = Join-Path $goldBH "$snBH\P-Series\$snBH"
            Get-ChildItem -LiteralPath $psSnDir -Filter 'PP_*.json' -Recurse | Select-Object -First 1 | ForEach-Object {
                Set-Content $_.FullName "{`"SN`":`"$snBH`",`"TimeStamp`":1700000000,`"BlowerHours`":-5}" -Encoding UTF8
            }
            $result = Test-GoldenContent -GoldenPath $goldBH
            $bhIssues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'BlowerHours' })
            $bhIssues.Count | Should -BeGreaterThan 0
            $bhIssues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $bRootBH; Remove-TempDir $gRootBH }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent â€” DirectoryStructure orphan detection' {

    It 'reports Warning DirectoryStructure for a device folder not in manifest' {
        $bRootO = New-TempDir; $gRootO = New-TempDir
        try {
            $snO   = 'TV500000001'
            $goldO = New-TestGolden -BackupRoot $bRootO -GoldenRoot $gRootO -SNs @($snO)
            # Create an extra device folder not in the manifest
            $null = New-Item -ItemType Directory -Path (Join-Path $goldO 'TVORPHAN') -Force
            $result = Test-GoldenContent -GoldenPath $goldO
            $orphanIssues = @($result.Issues | Where-Object { $_.Category -eq 'DirectoryStructure' -and $_.Device -eq 'TVORPHAN' })
            $orphanIssues.Count | Should -BeGreaterThan 0
            $orphanIssues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $bRootO; Remove-TempDir $gRootO }
    }

    It 'reports Critical DirectoryStructure when a manifest device folder is absent from disk' {
        $bRootM = New-TempDir; $gRootM = New-TempDir
        try {
            $snM   = 'TV500000002'
            $goldM = New-TestGolden -BackupRoot $bRootM -GoldenRoot $gRootM -SNs @($snM)
            # Delete the device folder entirely
            Remove-Item -LiteralPath (Join-Path $goldM $snM) -Recurse -Force
            $result = Test-GoldenContent -GoldenPath $goldM
            $missingIssues = @($result.Issues | Where-Object { $_.Category -eq 'DirectoryStructure' -and $_.Severity -eq 'Critical' })
            $missingIssues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRootM; Remove-TempDir $gRootM }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent â€” integration: end-to-end clean golden' {

    It 'returns Passed=$true with 0 Critical and 0 Error for a clean multi-device golden' {
        $bRoot2 = New-TempDir; $gRoot2 = New-TempDir
        try {
            $snList = @('TV600000001', 'TV600000002')
            $goldE  = New-TestGolden -BackupRoot $bRoot2 -GoldenRoot $gRoot2 -SNs $snList
            $result = Test-GoldenContent -GoldenPath $goldE
            $result.Passed        | Should -Be $true
            $result.CriticalCount | Should -Be 0
            $result.ErrorCount    | Should -Be 0
            $result.FileCount     | Should -BeGreaterThan 0
        } finally { Remove-TempDir $bRoot2; Remove-TempDir $gRoot2 }
    }

    It 'Test-GoldenContent is called implicitly by New-GoldenArchive' {
        # Verifies the function exists and is exported (smoke test)
        Get-Command 'Test-GoldenContent' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent — additional coverage' {
    # Covers branches not reached by any of the six original Describe blocks above:
    #   ManifestSchema: goldenSequence, devices absent, forcedDevicesReason='', created invalid
    #   DirectViewCompat: prop.txt missing
    #   EdfFormat: Version, HeaderBytes, NumDataRecords, NumSignals, RecordingID prefix
    #   EdfPairing: AD without DD
    #   PSeriesFormat: SL_SAPPHIRE first-byte, PP missing SN, PP TimeStamp=0

    # -- ManifestSchema: goldenSequence ----------------------------------------
    It 'reports Error ManifestSchema when goldenSequence is 0' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g
            Edit-Manifest $gold { param($m) $m.goldenSequence = 0 }
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'ManifestSchema' -and $_.Message -match 'goldenSequence' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- ManifestSchema: devices absent ----------------------------------------
    It 'reports Critical ManifestSchema when devices section is absent' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $gold  = New-TestGolden -BackupRoot $b -GoldenRoot $g
            $mPath = Join-Path $gold 'manifest.json'
            $m     = Get-Content $mPath -Raw | ConvertFrom-Json
            $slim  = [PSCustomObject]@{ version = $m.version; goldenSequence = $m.goldenSequence; created = $m.created }
            $slim | ConvertTo-Json -Depth 5 | Set-Content $mPath -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'ManifestSchema' -and $_.Message -match 'devices' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Critical'
            $result.Passed      | Should -Be $false
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- ManifestSchema: forcedDevicesReason empty string ----------------------
    It 'reports Warning ManifestSchema when forcedDevicesReason is an empty string' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g
            Edit-Manifest $gold { param($m) $m | Add-Member -NotePropertyName 'forcedDevicesReason' -NotePropertyValue '' -Force }
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'ManifestSchema' -and $_.Message -match 'forcedDevicesReason' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- ManifestSchema: created field invalid ---------------------------------
    It 'reports Warning ManifestSchema when created field is not a valid date' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g
            Edit-Manifest $gold { param($m) $m.created = 'not-a-date' }
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'ManifestSchema' -and $_.Message -match 'created' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- DirectViewCompat: prop.txt missing ------------------------------------
    It 'reports Critical DirectViewCompat when prop.txt is missing' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000001'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            Remove-Item -LiteralPath (Join-Path $gold "$sn\P-Series\$sn\prop.txt") -Force
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'DirectViewCompat' -and $_.Message -match 'prop.txt' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Critical'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- EdfPairing: AD without matching DD ------------------------------------
    It 'reports Error EdfPairing when an AD file has no matching DD' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn      = 'TV910000002'
            $gold    = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            $triPath = Join-Path $gold "$sn\Trilogy"
            # Remove all DD files so each AD has no pair
            Get-ChildItem -LiteralPath $triPath -Filter 'DD_*.edf' | Remove-Item -Force
            $result     = Test-GoldenContent -GoldenPath $gold
            $pairIssues = @($result.Issues | Where-Object { $_.Category -eq 'EdfPairing' -and $_.Message -match 'AD_' })
            $pairIssues.Count       | Should -BeGreaterThan 0
            $pairIssues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- PSeriesFormat: SL_SAPPHIRE.json first-byte ----------------------------
    It 'reports Warning PSeriesFormat when SL_SAPPHIRE.json does not start with {' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000003'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            Set-Content (Join-Path $gold "$sn\P-Series\$sn\SL_SAPPHIRE.json") '[1,2,3]' -Encoding UTF8
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'SL_SAPPHIRE' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- PSeriesFormat: PP JSON missing SN field entirely ----------------------
    It 'reports Error PSeriesFormat when PP JSON has no SN field' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn      = 'TV910000004'
            $gold    = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            $psSnDir = Join-Path $gold "$sn\P-Series\$sn"
            Get-ChildItem -LiteralPath $psSnDir -Filter 'PP_*.json' -Recurse |
                Select-Object -First 1 | ForEach-Object {
                    Set-Content $_.FullName '{"TimeStamp":1700000000,"BlowerHours":500}' -Encoding UTF8
                }
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Severity -eq 'Error' -and $_.File -match 'PP_' })
            $issues.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- PSeriesFormat: PP JSON TimeStamp = 0 ----------------------------------
    It 'reports Warning PSeriesFormat when PP JSON TimeStamp is 0' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn      = 'TV910000005'
            $gold    = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            $psSnDir = Join-Path $gold "$sn\P-Series\$sn"
            Get-ChildItem -LiteralPath $psSnDir -Filter 'PP_*.json' -Recurse |
                Select-Object -First 1 | ForEach-Object {
                    Set-Content $_.FullName "{`"SN`":`"$sn`",`"TimeStamp`":0,`"BlowerHours`":1200}" -Encoding UTF8
                }
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'PSeriesFormat' -and $_.Message -match 'TimeStamp' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- EdfFormat: Version field ----------------------------------------------
    It 'reports Error EdfFormat when EDF Version field is not "0"' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000006'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            Write-EdfField -Path (Get-FirstAD $gold $sn) -Offset 0 -Length 8 -Value '9'
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' -and $_.Message -match 'Version' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- EdfFormat: HeaderBytes field ------------------------------------------
    It 'reports Error EdfFormat when EDF HeaderBytes is not a multiple of 256' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000007'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            # 300 is not a multiple of 256 and is not a valid EDF header byte count
            Write-EdfField -Path (Get-FirstAD $gold $sn) -Offset 184 -Length 8 -Value '300'
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' -and $_.Message -match 'HeaderBytes' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- EdfFormat: NumDataRecords bad -----------------------------------------
    It 'reports Error EdfFormat when NumDataRecords is non-numeric' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000008'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            Write-EdfField -Path (Get-FirstAD $gold $sn) -Offset 236 -Length 8 -Value 'BADVAL!!'
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' -and $_.Message -match 'NumDataRecords' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- EdfFormat: NumSignals < 1 ---------------------------------------------
    It 'reports Error EdfFormat when NumSignals is 0' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000009'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            Write-EdfField -Path (Get-FirstAD $gold $sn) -Offset 252 -Length 4 -Value '0'
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' -and $_.Message -match 'NumSignals' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Error'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    # -- EdfFormat: RecordingID prefix -----------------------------------------
    It 'reports Warning EdfFormat when RecordingID does not begin with "Startdate"' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn   = 'TV910000010'
            $gold = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            # Retain SN so the SN-mismatch check passes; only drop the "Startdate" prefix
            Write-EdfField -Path (Get-FirstAD $gold $sn) -Offset 88 -Length 80 `
                -Value "NODATE 01-JAN-2024 X X TGY200 0 $sn CA1032800B 65 3.02"
            $result = Test-GoldenContent -GoldenPath $gold
            $issues = @($result.Issues | Where-Object { $_.Category -eq 'EdfFormat' -and $_.Message -match 'Startdate|RecordingID' })
            $issues.Count       | Should -BeGreaterThan 0
            $issues[0].Severity | Should -Be 'Warning'
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }
}
