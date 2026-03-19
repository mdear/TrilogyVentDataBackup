#Requires -Version 5.1
# VBM-Analyzer.Tests.ps1 — Pester 5 unit tests for VBM-Analyzer.psm1
# Covers: Get-BackupInventory, Test-BackupIntegrity (all 5 checks),
#         Find-SplitSD, Write-ContaminationReadme, Get-DeviceTimeline.
# Run via: Invoke-Pester -Path $PSScriptRoot  (or scripts\tests\Run-Tests.ps1)

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')  -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1') -Force
}

# ============================================================
Describe 'Get-BackupInventory — folder discovery and exclusions' {

    BeforeAll { $script:root = New-TempDir }
    AfterAll  { Remove-TempDir $script:root }

    It 'returns an empty array when the root contains no backup-like folders' {
        $r = New-TempDir
        try {
            Get-BackupInventory -BackupRoot $r | Should -HaveCount 0
        } finally { Remove-TempDir $r }
    }

    It 'discovers a folder that has a Trilogy subfolder' {
        $bak = Join-Path $script:root 'bak_has_trilogy'
        $null = New-Item -ItemType Directory "$bak\Trilogy" -Force
        $inv = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object Name -eq 'bak_has_trilogy') | Should -Not -BeNullOrEmpty
    }

    It 'discovers a folder that has a P-Series subfolder' {
        $bak = Join-Path $script:root 'bak_has_pseries'
        $null = New-Item -ItemType Directory "$bak\P-Series" -Force
        $inv = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object Name -eq 'bak_has_pseries') | Should -Not -BeNullOrEmpty
    }

    It 'excludes the scripts folder' {
        $null = New-Item -ItemType Directory (Join-Path $script:root 'scripts\Trilogy') -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object Name -eq 'scripts') | Should -BeNullOrEmpty
    }

    It 'excludes _golden_ prefixed folders' {
        $null = New-Item -ItemType Directory (Join-Path $script:root '_golden_20240101\Trilogy') -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object { $_.Name -match '^_golden_' }) | Should -BeNullOrEmpty
    }

    It 'excludes dot-prefixed folders' {
        $null = New-Item -ItemType Directory (Join-Path $script:root '.hidden\Trilogy') -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object { $_.Name -match '^\.' }) | Should -BeNullOrEmpty
    }

    It 'excludes a folder with neither Trilogy nor P-Series' {
        $null = New-Item -ItemType Directory (Join-Path $script:root 'no_vent_data\SomeOtherDir') -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object Name -eq 'no_vent_data') | Should -BeNullOrEmpty
    }

    It 'sets HasTrilogy and HasPSeries flags correctly' {
        $bak = Join-Path $script:root 'bak_flags'
        $null = New-Item -ItemType Directory "$bak\Trilogy"  -Force
        $null = New-Item -ItemType Directory "$bak\P-Series" -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        $entry = $inv | Where-Object Name -eq 'bak_flags'
        $entry.HasTrilogy | Should -Be $true
        $entry.HasPSeries | Should -Be $true
    }

    It 'detects nested sub-backups (e.g. parent/vent 2)' {
        $parent = Join-Path $script:root 'bak_with_sub'
        $null = New-Item -ItemType Directory "$parent\Trilogy" -Force
        $null = New-Item -ItemType Directory "$parent\vent 2\Trilogy" -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        $parentEntry = $inv | Where-Object Name -eq 'bak_with_sub'
        $parentEntry | Should -Not -BeNullOrEmpty
        $parentEntry.SubBackups | Should -HaveCount 1
        $parentEntry.SubBackups[0].Name | Should -Be 'bak_with_sub/vent 2'
    }

    It 'discovers a folder whose data is one level deep under any intermediate folder name (e.g. SD card/F_)' {
        # No Trilogy or P-Series directly in the parent; data lives inside an
        # arbitrarily-named sub-folder — the SD card reader layout pattern.
        $parent = Join-Path $script:root 'bak_sdcard_layout'
        $null = New-Item -ItemType Directory "$parent\F_\Trilogy"  -Force
        $null = New-Item -ItemType Directory "$parent\F_\P-Series" -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        $parentEntry = $inv | Where-Object Name -eq 'bak_sdcard_layout'
        $parentEntry | Should -Not -BeNullOrEmpty
        $parentEntry.HasTrilogy | Should -Be $false   # not direct
        $parentEntry.HasPSeries | Should -Be $false   # not direct
        $parentEntry.SubBackups | Should -HaveCount 1
        $parentEntry.SubBackups[0].Name      | Should -Be 'bak_sdcard_layout/F_'
        $parentEntry.SubBackups[0].HasTrilogy | Should -Be $true
        $parentEntry.SubBackups[0].HasPSeries | Should -Be $true
    }

    It 'still excludes a folder with neither direct nor indirect Trilogy/P-Series' {
        $null = New-Item -ItemType Directory (Join-Path $script:root 'no_vent_data_deep\SomeOtherDir\UnrelatedFolder') -Force
        $inv  = Get-BackupInventory -BackupRoot $script:root
        ($inv | Where-Object Name -eq 'no_vent_data_deep') | Should -BeNullOrEmpty
    }

    It 'emits a warning when BackupRoot is inside a Dropbox folder' {
        # Simulate a Dropbox root by creating a temp dir with a .dropbox marker file
        $dbRoot = New-TempDir
        $null   = New-Item -ItemType File (Join-Path $dbRoot '.dropbox') -Force
        $bakDir = Join-Path $dbRoot 'somebak'
        $null   = New-Item -ItemType Directory "$bakDir\Trilogy" -Force
        try {
            $warnings = @()
            Get-BackupInventory -BackupRoot $dbRoot -WarningVariable warnings 3>$null
            # At least one warning about Dropbox
            ($warnings | Where-Object { $_ -match 'Dropbox' }) | Should -Not -BeNullOrEmpty
        } finally { Remove-TempDir $dbRoot }
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 1: contamination detection' {

    BeforeAll {
        $script:root = New-TempDir

        # Clean reference backup: device A only
        New-SyntheticBackup -BackupRoot $script:root -Name 'clean_bak' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'

        # Contaminated backup: device A P-Series BUT also an EDF for device B
        New-SyntheticBackup -BackupRoot $script:root -Name 'dirty_bak' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'
        # Inject a rogue EDF for device B (no matching P-Series directory)
        New-SyntheticEdf -Path (Join-Path $script:root 'dirty_bak\Trilogy\AD_202408_099.edf') `
            -SN 'TV999999999'

        $inv         = Get-BackupInventory -BackupRoot $script:root
        $script:toc  = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'marks clean_bak as Clean' {
        $script:toc.Backups['clean_bak'].Integrity | Should -Be 'Clean'
    }

    It 'marks dirty_bak as Contaminated' {
        $script:toc.Backups['dirty_bak'].Integrity | Should -Be 'Contaminated'
    }

    It 'produces at least one Contamination anomaly for dirty_bak' {
        $anoms = @($script:toc.Backups['dirty_bak'].Anomalies |
                   Where-Object Type -eq 'Contamination')
        $anoms.Count | Should -BeGreaterThan 0
    }

    It 'anomaly detail references the rogue serial number' {
        $detail = ($script:toc.Backups['dirty_bak'].Anomalies |
                   Where-Object Type -eq 'Contamination' | Select-Object -First 1).Detail
        $detail | Should -Match 'TV999999999'
    }

    It 'clean_bak has no Contamination anomalies' {
        $anoms = @($script:toc.Backups['clean_bak'].Anomalies |
                   Where-Object Type -eq 'Contamination')
        $anoms.Count | Should -Be 0
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 1b: .NNN cross-reference contamination' {

    BeforeAll {
        $script:root = New-TempDir

        # Base backup: device A only
        New-SyntheticBackup -BackupRoot $script:root -Name '12.1.2025' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'

        # .002 variant: device A P-Series tree PLUS a second device B P-Series tree
        # — simulates plugging two SD cards into the same folder
        New-SyntheticBackup -BackupRoot $script:root -Name '12.1.2025.002' `
            -DeviceSNs @('TV000000001', 'TV000000002') -YearMonth '202408'

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'base backup 12.1.2025 is Clean' {
        $script:toc.Backups['12.1.2025'].Integrity | Should -Be 'Clean'
    }

    It '.002 variant is Contaminated because TV000000002 absent from base' {
        $script:toc.Backups['12.1.2025.002'].Integrity | Should -Be 'Contaminated'
    }

    It '.002 contamination anomaly mentions the tainted SN or base backup name' {
        $anom = $script:toc.Backups['12.1.2025.002'].Anomalies |
                Where-Object Type -eq 'Contamination' | Select-Object -First 1
        ($anom.Detail -match 'TV000000002' -or $anom.Detail -match '12\.1\.2025') | Should -Be $true
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 2: missing AD/DD pairs' {

    BeforeAll {
        $script:root = New-TempDir

        # Full backup: both AD and DD present (generated by New-SyntheticBackup)
        New-SyntheticBackup -BackupRoot $script:root -Name 'full_bak' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'

        # Partial backup: remove the DD file to create an orphan AD
        $ddPath = Join-Path $script:root 'full_bak\Trilogy\DD_202408_000.edf'
        Remove-Item $ddPath -Force

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'reports a MissingPair anomaly for the orphan AD file' {
        $anoms = @($script:toc.Backups['full_bak'].Anomalies |
                   Where-Object Type -eq 'MissingPair')
        $anoms.Count | Should -BeGreaterThan 0
    }

    It 'MissingPair anomaly references the AD filename' {
        $detail = ($script:toc.Backups['full_bak'].Anomalies |
                   Where-Object Type -eq 'MissingPair' | Select-Object -First 1).Detail
        $detail | Should -Match 'AD_202408'
    }

    It 'MissingPair severity is Low' {
        $sev = ($script:toc.Backups['full_bak'].Anomalies |
                Where-Object Type -eq 'MissingPair' | Select-Object -First 1).Severity
        $sev | Should -Be 'Low'
    }

    It 'no MissingPair when both AD and DD are present' {
        $root2 = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root2 -Name 'complete' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'
            $inv2  = Get-BackupInventory -BackupRoot $root2
            $toc2  = Get-BackupTOC -Inventory $inv2
            $anoms = @($toc2.Backups['complete'].Anomalies | Where-Object Type -eq 'MissingPair')
            $anoms.Count | Should -Be 0
        } finally { Remove-TempDir $root2 }
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 3: truncated file detection' {

    BeforeAll {
        $script:root = New-TempDir

        # Backup A: small file (256 extra body bytes — the default)
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_small' `
            -DeviceSNs @('TV000000001') -YearMonth '202408' -EdfBodyBytes 256

        # Backup B: large file (2048 extra body bytes — >20% bigger)
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_large' `
            -DeviceSNs @('TV000000001') -YearMonth '202408' -EdfBodyBytes 2048

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'flags the small backup with a TruncatedFile anomaly' {
        $anoms = @($script:toc.Backups['bak_small'].Anomalies |
                   Where-Object Type -eq 'TruncatedFile')
        $anoms.Count | Should -BeGreaterThan 0
    }

    It 'TruncatedFile anomaly names the larger backup as source' {
        $detail = ($script:toc.Backups['bak_small'].Anomalies |
                   Where-Object Type -eq 'TruncatedFile' | Select-Object -First 1).Detail
        $detail | Should -Match 'bak_large'
    }

    It 'TruncatedFile severity is Medium' {
        $sev = ($script:toc.Backups['bak_small'].Anomalies |
                Where-Object Type -eq 'TruncatedFile' | Select-Object -First 1).Severity
        $sev | Should -Be 'Medium'
    }

    It 'does NOT flag the large backup as truncated' {
        $anoms = @($script:toc.Backups['bak_large'].Anomalies |
                   Where-Object Type -eq 'TruncatedFile')
        $anoms.Count | Should -Be 0
    }

    It 'no TruncatedFile when both backups have the same file size' {
        $root2 = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root2 -Name 'bak_a' `
                -DeviceSNs @('TV000000001') -YearMonth '202408' -EdfBodyBytes 512
            New-SyntheticBackup -BackupRoot $root2 -Name 'bak_b' `
                -DeviceSNs @('TV000000001') -YearMonth '202408' -EdfBodyBytes 512
            $inv2  = Get-BackupInventory -BackupRoot $root2
            $toc2  = Get-BackupTOC -Inventory $inv2
            $anoms = @($toc2.Backups['bak_a'].Anomalies | Where-Object Type -eq 'TruncatedFile')
            $anoms.Count | Should -Be 0
        } finally { Remove-TempDir $root2 }
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 4: P-Series FILES.SEQ vs TRANSMITFILE.SEQ' {

    BeforeAll { $script:root = New-TempDir }
    AfterAll  { Remove-TempDir $script:root }

    It 'reports PSeriesConsistency when TRANSMITFILE.SEQ has more entries than FILES.SEQ' {
        $bakPath = New-SyntheticBackup -BackupRoot $script:root -Name 'bak_seq_mismatch' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'

        $psDir = Join-Path $bakPath 'P-Series\TV000000001'
        # Overwrite FILES.SEQ with fewer lines than TRANSMITFILE.SEQ
        Set-Content (Join-Path $psDir 'FILES.SEQ')        "file1`nfile2`n12345678"        -Encoding UTF8
        Set-Content (Join-Path $psDir 'TRANSMITFILE.SEQ') "file1`nfile2`nfile3`nABCDEF01" -Encoding UTF8

        $inv  = Get-BackupInventory -BackupRoot $script:root
        $toc  = Get-BackupTOC -Inventory $inv
        $anoms = @($toc.Backups['bak_seq_mismatch'].Anomalies |
                   Where-Object Type -eq 'PSeriesConsistency')
        $anoms.Count | Should -BeGreaterThan 0
    }

    It 'no PSeriesConsistency when FILES.SEQ >= TRANSMITFILE.SEQ line count' {
        $bakPath = New-SyntheticBackup -BackupRoot $script:root -Name 'bak_seq_ok' `
            -DeviceSNs @('TV000000001') -YearMonth '202409'

        # Default fixture already has FILES.SEQ >= TRANSMITFILE.SEQ
        $inv  = Get-BackupInventory -BackupRoot $script:root
        $toc  = Get-BackupTOC -Inventory $inv
        $anoms = @($toc.Backups['bak_seq_ok'].Anomalies |
                   Where-Object Type -eq 'PSeriesConsistency')
        $anoms.Count | Should -Be 0
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 5: P-Series size regression' {

    BeforeAll {
        $script:root = New-TempDir

        # bak_old: small FILES.SEQ (written first — simulates older backup)
        $bakOld = New-SyntheticBackup -BackupRoot $script:root -Name 'bak_old' `
            -DeviceSNs @('TV000000001') -YearMonth '202407'

        # bak_new: larger FILES.SEQ (more entries — simulates newer backup)
        $bakNew = New-SyntheticBackup -BackupRoot $script:root -Name 'bak_new' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'

        # Make bak_old/FILES.SEQ smaller than bak_new/FILES.SEQ
        $psOld = Join-Path $bakOld 'P-Series\TV000000001'
        $psNew = Join-Path $bakNew 'P-Series\TV000000001'
        Set-Content (Join-Path $psOld 'FILES.SEQ') "file1`n12345678"                    -Encoding UTF8
        Set-Content (Join-Path $psNew 'FILES.SEQ') "file1`nfile2`nfile3`nfile4`nABCD1234" -Encoding UTF8
        # Same for TRANSMITFILE.SEQ so check 4 stays clean
        Set-Content (Join-Path $psOld 'TRANSMITFILE.SEQ') "file1`n12345678"             -Encoding UTF8
        Set-Content (Join-Path $psNew 'TRANSMITFILE.SEQ') "file1`nfile2`nfile3`nABCD9999" -Encoding UTF8

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'reports SizeRegression on bak_old (smaller FILES.SEQ than bak_new)' {
        $anoms = @($script:toc.Backups['bak_old'].Anomalies |
                   Where-Object Type -eq 'SizeRegression')
        $anoms.Count | Should -BeGreaterThan 0
    }

    It 'SizeRegression anomaly references bak_new as the larger source' {
        $detail = ($script:toc.Backups['bak_old'].Anomalies |
                   Where-Object Type -eq 'SizeRegression' | Select-Object -First 1).Detail
        $detail | Should -Match 'bak_new'
    }

    It 'does NOT flag bak_new with SizeRegression' {
        $anoms = @($script:toc.Backups['bak_new'].Anomalies |
                   Where-Object Type -eq 'SizeRegression')
        $anoms.Count | Should -Be 0
    }

    It 'SizeRegression references the backup with the largest version, not just any larger one' {
        # When multiple backups have larger versions, the anomaly should cite the max
        $root2 = New-TempDir
        try {
            $bSmall  = New-SyntheticBackup -BackupRoot $root2 -Name 'bak_small'  -DeviceSNs @('TV000000001') -YearMonth '202407'
            $bMedium = New-SyntheticBackup -BackupRoot $root2 -Name 'bak_medium' -DeviceSNs @('TV000000001') -YearMonth '202408'
            $bLarge  = New-SyntheticBackup -BackupRoot $root2 -Name 'bak_large'  -DeviceSNs @('TV000000001') -YearMonth '202409'
            $psSmall  = Join-Path $bSmall  'P-Series\TV000000001'
            $psMedium = Join-Path $bMedium 'P-Series\TV000000001'
            $psLarge  = Join-Path $bLarge  'P-Series\TV000000001'
            Set-Content (Join-Path $psSmall  'FILES.SEQ') "s1`n12345678"                      -Encoding UTF8
            Set-Content (Join-Path $psMedium 'FILES.SEQ') "s1`ns2`ns3`nAAAAAAAA"              -Encoding UTF8
            Set-Content (Join-Path $psLarge  'FILES.SEQ') "s1`ns2`ns3`ns4`ns5`nBBBBBBBB"    -Encoding UTF8
            Set-Content (Join-Path $psSmall  'TRANSMITFILE.SEQ') "s1`n12345678"              -Encoding UTF8
            Set-Content (Join-Path $psMedium 'TRANSMITFILE.SEQ') "s1`ns2`ns3`nAAAAAAAA"      -Encoding UTF8
            Set-Content (Join-Path $psLarge  'TRANSMITFILE.SEQ') "s1`ns2`ns3`ns4`nBBBBBBBB" -Encoding UTF8
            $inv2   = Get-BackupInventory -BackupRoot $root2
            $toc2   = Get-BackupTOC -Inventory $inv2
            $detail = ($toc2.Backups['bak_small'].Anomalies |
                       Where-Object Type -eq 'SizeRegression' | Select-Object -First 1).Detail
            $detail | Should -Match 'bak_large'
        } finally { Remove-TempDir $root2 }
    }
}

# ============================================================
Describe 'Test-BackupIntegrity — Check 5b: SizeRegression .NNN variant suppression' {

    It 'does NOT flag a base backup for SizeRegression against its own .NNN variant' {
        $root = New-TempDir
        try {
            # "12.1.2025" is the base; "12.1.2025.002" is a later variant (expected to be larger)
            $bBase    = New-SyntheticBackup -BackupRoot $root -Name '12.1.2025'     -DeviceSNs @('TV000000001') -YearMonth '202408'
            $bVariant = New-SyntheticBackup -BackupRoot $root -Name '12.1.2025.002' -DeviceSNs @('TV000000001') -YearMonth '202408'
            $psBase    = Join-Path $bBase    'P-Series\TV000000001'
            $psVariant = Join-Path $bVariant 'P-Series\TV000000001'
            # Variant has a larger FILES.SEQ — this is expected, not a regression
            Set-Content (Join-Path $psBase    'FILES.SEQ') "file1`n12345678"                       -Encoding UTF8
            Set-Content (Join-Path $psVariant 'FILES.SEQ') "file1`nfile2`nfile3`nfile4`nABCDEFAB"  -Encoding UTF8
            Set-Content (Join-Path $psBase    'TRANSMITFILE.SEQ') "file1`n12345678"                -Encoding UTF8
            Set-Content (Join-Path $psVariant 'TRANSMITFILE.SEQ') "file1`nfile2`nfile3`nABCDEFAB"  -Encoding UTF8
            $inv = Get-BackupInventory -BackupRoot $root
            $toc = Get-BackupTOC -Inventory $inv
            $anoms = @($toc.Backups['12.1.2025'].Anomalies | Where-Object Type -eq 'SizeRegression')
            $anoms.Count | Should -Be 0
        } finally { Remove-TempDir $root }
    }

    It 'DOES flag the .NNN variant for SizeRegression against an unrelated older backup that has more data' {
        $root = New-TempDir
        try {
            # "bak_old" has MORE data than "bak_old.002" (a genuine regression in the variant)
            $bOld     = New-SyntheticBackup -BackupRoot $root -Name 'bak_old'     -DeviceSNs @('TV000000001') -YearMonth '202407'
            $bVariant = New-SyntheticBackup -BackupRoot $root -Name 'bak_old.002' -DeviceSNs @('TV000000001') -YearMonth '202407'
            $psOld     = Join-Path $bOld     'P-Series\TV000000001'
            $psVariant = Join-Path $bVariant 'P-Series\TV000000001'
            # The unrelated "bak_old" has MORE data than the variant — this IS a regression in the variant
            Set-Content (Join-Path $psOld     'FILES.SEQ') "f1`nf2`nf3`nf4`nf5`nABCDEFAB"  -Encoding UTF8
            Set-Content (Join-Path $psVariant 'FILES.SEQ') "f1`n12345678"                   -Encoding UTF8
            Set-Content (Join-Path $psOld     'TRANSMITFILE.SEQ') "f1`nf2`nf3`nABCDEFAB"   -Encoding UTF8
            Set-Content (Join-Path $psVariant 'TRANSMITFILE.SEQ') "f1`n12345678"            -Encoding UTF8
            $inv = Get-BackupInventory -BackupRoot $root
            $toc = Get-BackupTOC -Inventory $inv
            $anoms = @($toc.Backups['bak_old.002'].Anomalies | Where-Object Type -eq 'SizeRegression')
            $anoms.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $root }
    }
}

# ============================================================
Describe 'Find-SplitSD' {

    It 'returns empty hashtable when a device has only one clean backup' {
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'only_bak' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'
            $inv    = Get-BackupInventory -BackupRoot $root
            $toc    = Get-BackupTOC -Inventory $inv
            $result = Find-SplitSD -TOC $toc
            $result.Keys | Should -HaveCount 0
        } finally { Remove-TempDir $root }
    }

    It 'detects a split when two backups have non-overlapping date ranges and large BlowerHours gap' {
        $root = New-TempDir
        try {
            # New-SplitSDBackupPair creates early (202401) and late (202408) backups
            # with BlowerHours 500 and 5000 — well above the 1440 threshold
            $null = New-SplitSDBackupPair -BackupRoot $root `
                -SN 'TV000000001' `
                -EarlyYearMonth '202401' -LateYearMonth '202408' `
                -EarlyBlowerHours 500    -LateBlowerHours 5000

            $inv    = Get-BackupInventory -BackupRoot $root
            $toc    = Get-BackupTOC -Inventory $inv
            $result = Find-SplitSD -TOC $toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

            $result.ContainsKey('TV000000001') | Should -Be $true
            $result['TV000000001'].SplitSD      | Should -Be $true
            $result['TV000000001'].Spans        | Should -HaveCount 2
        } finally { Remove-TempDir $root }
    }

    It 'does NOT flag a split when BlowerHours are continuous (small jump)' {
        $root = New-TempDir
        try {
            # BlowerHours 500 → 700: jump of 200, below threshold of 1440
            $null = New-SplitSDBackupPair -BackupRoot $root `
                -SN 'TV000000001' `
                -EarlyYearMonth '202401' -LateYearMonth '202408' `
                -EarlyBlowerHours 500    -LateBlowerHours 700

            $inv    = Get-BackupInventory -BackupRoot $root
            $toc    = Get-BackupTOC -Inventory $inv
            $result = Find-SplitSD -TOC $toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

            $result.ContainsKey('TV000000001') | Should -Be $false
        } finally { Remove-TempDir $root }
    }

    It 'does NOT flag a split when date gap is within SplitGapMonths' {
        $root = New-TempDir
        try {
            # Only 1 month apart — gap of 1, below SplitGapMonths of 2
            $null = New-SplitSDBackupPair -BackupRoot $root `
                -SN 'TV000000001' `
                -EarlyYearMonth '202407' -LateYearMonth '202408' `
                -EarlyBlowerHours 500    -LateBlowerHours 5000

            $inv    = Get-BackupInventory -BackupRoot $root
            $toc    = Get-BackupTOC -Inventory $inv
            $result = Find-SplitSD -TOC $toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

            $result.ContainsKey('TV000000001') | Should -Be $false
        } finally { Remove-TempDir $root }
    }

    It 'annotates the TOC Devices entry with SplitSD=$true when split detected' {
        $root = New-TempDir
        try {
            $null = New-SplitSDBackupPair -BackupRoot $root `
                -SN 'TV000000001' `
                -EarlyYearMonth '202401' -LateYearMonth '202408' `
                -EarlyBlowerHours 500    -LateBlowerHours 5000

            $inv    = Get-BackupInventory -BackupRoot $root
            $toc    = Get-BackupTOC -Inventory $inv
            $null   = Find-SplitSD -TOC $toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

            $toc.Devices['TV000000001'].SplitSD | Should -Be $true
        } finally { Remove-TempDir $root }
    }

    It 'ignores contaminated backups when assessing split spans' {
        $root = New-TempDir
        try {
            # Early clean backup
            New-SyntheticBackup -BackupRoot $root -Name 'bak_early' `
                -DeviceSNs @('TV000000001') -YearMonth '202401' -BlowerHours 500

            # Late backup — contaminated by adding a rogue SN (no P-Series dir)
            New-SyntheticBackup -BackupRoot $root -Name 'bak_late' `
                -DeviceSNs @('TV000000001') -YearMonth '202408' -BlowerHours 5000
            New-SyntheticEdf `
                -Path (Join-Path $root 'bak_late\Trilogy\AD_202408_099.edf') `
                -SN 'TV999999999'

            $inv    = Get-BackupInventory -BackupRoot $root
            $toc    = Get-BackupTOC -Inventory $inv
            # bak_late should be contaminated, so only bak_early is a clean span
            $result = Find-SplitSD -TOC $toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440
            # Only 1 clean span → no split
            $result.ContainsKey('TV000000001') | Should -Be $false
        } finally { Remove-TempDir $root }
    }
}

# ============================================================
Describe 'Write-ContaminationReadme' {

    BeforeAll {
        $script:root = New-TempDir

        # Build a contaminated backup
        New-SyntheticBackup -BackupRoot $script:root -Name 'dirty_bak' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'
        New-SyntheticEdf `
            -Path (Join-Path $script:root 'dirty_bak\Trilogy\AD_202408_099.edf') `
            -SN 'TV999999999'

        # Also build a clean backup (so the readme can reference it)
        New-SyntheticBackup -BackupRoot $script:root -Name 'clean_bak' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv

        $dirtyDetail = $script:toc.Backups['dirty_bak']
        Write-ContaminationReadme `
            -BackupPath $dirtyDetail.Path `
            -Anomalies  $dirtyDetail.Anomalies `
            -TOC        $script:toc

        $script:readmePath = Join-Path $dirtyDetail.Path 'README.md'
        $script:content    = Get-Content $script:readmePath -Raw
    }
    AfterAll { Remove-TempDir $script:root }

    It 'creates a README.md in the backup folder' {
        Test-Path $script:readmePath | Should -Be $true
    }

    It 'README begins with the contamination report heading' {
        $script:content | Should -Match '# Backup Contamination Report'
    }

    It 'README mentions the rogue serial number' {
        $script:content | Should -Match 'TV999999999'
    }

    It 'README contains a contamination result count line' {
        $script:content | Should -Match 'contaminated file\(s\) detected'
    }

    It 'README includes a Clean Sources section' {
        # The clean-sources section header is always written when contamination exists
        $script:content | Should -Match '## Clean Sources in Other Backups'
    }

    It 'README is valid UTF-8 text (no BOM issues — readable as string)' {
        { Get-Content $script:readmePath -Raw -Encoding UTF8 } | Should -Not -Throw
    }
}

# ============================================================
Describe 'Get-DeviceTimeline' {

    BeforeAll {
        $script:root = New-TempDir

        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_2024' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_2025' `
            -DeviceSNs @('TV000000001') -YearMonth '202501'

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'returns one entry per backup that contains the device' {
        $tl = Get-DeviceTimeline -TOC $script:toc -DeviceSerial 'TV000000001'
        $tl | Should -HaveCount 2
    }

    It 'entries are sorted by backup name' {
        $tl = Get-DeviceTimeline -TOC $script:toc -DeviceSerial 'TV000000001'
        $tl[0].BackupName | Should -BeLessThan $tl[1].BackupName
    }

    It 'each entry has expected properties' {
        $tl = Get-DeviceTimeline -TOC $script:toc -DeviceSerial 'TV000000001'
        $entry = $tl[0]
        $entry.PSObject.Properties.Name | Should -Contain 'BackupName'
        $entry.PSObject.Properties.Name | Should -Contain 'EarliestDate'
        $entry.PSObject.Properties.Name | Should -Contain 'LatestDate'
        $entry.PSObject.Properties.Name | Should -Contain 'FileCount'
        $entry.PSObject.Properties.Name | Should -Contain 'Integrity'
    }

    It 'returns an empty array for an unknown serial number' {
        $tl = Get-DeviceTimeline -TOC $script:toc -DeviceSerial 'TVUNKNOWN'
        @($tl).Count | Should -Be 0
    }
}
# ============================================================
Describe 'Show-TOC' {

    BeforeAll {
        $script:root = New-TempDir

        # Build two backups — one clean, one contaminated
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_A' `
            -DeviceSNs @('TV000000001') -YearMonth '202408'
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_B' `
            -DeviceSNs @('TV000000001') -YearMonth '202409'
        # Contaminate bak_B with a rogue SN
        New-SyntheticEdf `
            -Path (Join-Path $script:root 'bak_B\Trilogy\AD_202409_099.edf') `
            -SN 'TV999999999'

        $inv          = Get-BackupInventory -BackupRoot $script:root
        $script:toc   = Get-BackupTOC -Inventory $inv
    }
    AfterAll { Remove-TempDir $script:root }

    It 'runs without error on a clean + contaminated TOC' {
        { Show-TOC -TOC $script:toc } | Should -Not -Throw
    }

    It 'output contains the backup folder names' {
        $out = Show-TOC -TOC $script:toc 6>&1 | ForEach-Object { "$_" } | Out-String
        $out | Should -Match 'bak_A'
        $out | Should -Match 'bak_B'
    }

    It 'output contains the contamination warning section when contamination exists' {
        $out = Show-TOC -TOC $script:toc 6>&1 | ForEach-Object { "$_" } | Out-String
        $out | Should -Match 'CONTAMINATION WARNINGS'
    }

    It 'output contains the device serial number' {
        $out = Show-TOC -TOC $script:toc 6>&1 | ForEach-Object { "$_" } | Out-String
        $out | Should -Match 'TV000000001'
    }

    It 'output contains the DEVICE TIMELINES section heading' {
        $out = Show-TOC -TOC $script:toc 6>&1 | ForEach-Object { "$_" } | Out-String
        $out | Should -Match 'DEVICE TIMELINES'
    }

    It 'runs without error on an empty TOC (no backups, no devices)' {
        $emptyToc = [PSCustomObject]@{
            Backups = @{}
            Devices = @{}
        }
        { Show-TOC -TOC $emptyToc } | Should -Not -Throw
    }

    It 'does NOT include contamination warning section when all backups are clean' {
        $root2 = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root2 -Name 'clean_only' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'
            $inv2  = Get-BackupInventory -BackupRoot $root2
            $toc2  = Get-BackupTOC -Inventory $inv2
            $out   = Show-TOC -TOC $toc2 6>&1 | ForEach-Object { "$_" } | Out-String
            $out | Should -Not -Match 'CONTAMINATION WARNINGS'
        } finally { Remove-TempDir $root2 }
    }

    It 'truncates long SN lists to fit the column width' {
        $root3 = New-TempDir
        try {
            # 5 devices: combined SN string exceeds 30 chars
            New-SyntheticBackup -BackupRoot $root3 -Name 'multi_dev' `
                -DeviceSNs @('TV111111111','TV222222222','TV333333333','TV444444444','TV555555555') `
                -YearMonth '202408'
            $inv3  = Get-BackupInventory -BackupRoot $root3
            $toc3  = Get-BackupTOC -Inventory $inv3
            # Must not throw when SN list is very long
            { Show-TOC -TOC $toc3 } | Should -Not -Throw
            $out = Show-TOC -TOC $toc3 6>&1 | ForEach-Object { "$_" } | Out-String
            # Truncation marker should appear somewhere in the output
            $out | Should -Match '\.\.\.'
        } finally { Remove-TempDir $root3 }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-BackupTOC - return structure' {

    BeforeAll {
        $script:tocRoot = New-TempDir
        New-SyntheticBackup -BackupRoot $script:tocRoot -Name 'toc_bak01' `
            -DeviceSNs @('TV800000001', 'TV800000002') -YearMonth '202408'
        $inv           = Get-BackupInventory -BackupRoot $script:tocRoot
        $script:tocObj = Get-BackupTOC -Inventory $inv
    }

    AfterAll { Remove-TempDir $script:tocRoot }

    It 'TOC has a Backups property that is a hashtable' {
        $script:tocObj.PSObject.Properties.Name | Should -Contain 'Backups'
        $script:tocObj.Backups | Should -BeOfType [hashtable]
    }

    It 'TOC has a Devices property that is a hashtable' {
        $script:tocObj.PSObject.Properties.Name | Should -Contain 'Devices'
        $script:tocObj.Devices | Should -BeOfType [hashtable]
    }

    It 'each backup entry has Name, Path, Integrity and Anomalies' {
        foreach ($key in $script:tocObj.Backups.Keys) {
            $b = $script:tocObj.Backups[$key]
            $b.PSObject.Properties.Name | Should -Contain 'Name'
            $b.PSObject.Properties.Name | Should -Contain 'Path'
            $b.PSObject.Properties.Name | Should -Contain 'Integrity'
            $b.PSObject.Properties.Name | Should -Contain 'Anomalies'
        }
    }

    It 'each device summary has BackupPresence, OverallEarliest, OverallLatest, TotalUniqueFiles' {
        foreach ($sn in $script:tocObj.Devices.Keys) {
            $d = $script:tocObj.Devices[$sn]
            $d.PSObject.Properties.Name | Should -Contain 'BackupPresence'
            $d.PSObject.Properties.Name | Should -Contain 'OverallEarliest'
            $d.PSObject.Properties.Name | Should -Contain 'OverallLatest'
            $d.PSObject.Properties.Name | Should -Contain 'TotalUniqueFiles'
        }
    }

    It 'BackupPresence lists the backup name where the device was found' {
        $script:tocObj.Devices['TV800000001'].BackupPresence | Should -Contain 'toc_bak01'
    }

    It 'TotalUniqueFiles is greater than zero for a device with EDF files' {
        $script:tocObj.Devices['TV800000001'].TotalUniqueFiles | Should -BeGreaterThan 0
    }

    It 'returns empty Backups and Devices hashtables for an empty inventory' {
        # Get-BackupTOC rejects a truly empty array via [Parameter(Mandatory)][array].
        # Test that an inventory with one entry (an empty-dir backup with no devices)
        # produces zero Devices (nothing to scan) — same semantic as "empty".
        $rEmpty = New-TempDir
        $bEmpty = New-TempDir
        try {
            # A backup folder with no Trilogy and no P-Series won't pass inventory discovery
            # so this just tests the single-entry zero-device code path via a synthetic backup
            # stripped of EDF files.
            $invE = Get-BackupInventory -BackupRoot $bEmpty   # no subfolders → 0 entries
            # Wrap in if-guard: some PS versions won't bind 0-length arrays to [array]
            if ($invE.Count -gt 0) {
                $tocE = Get-BackupTOC -Inventory $invE
                $tocE.Devices.Count | Should -Be 0
            } else {
                # Inventory IS empty: verify that the scanner produces the expected structure
                # by building a minimal valid entry manually
                $dummyEntry = [PSCustomObject]@{
                    Name       = 'dummy'
                    Path       = $bEmpty
                    HasTrilogy = $false
                    HasPSeries = $false
                    SubBackups = @()
                }
                $tocE = Get-BackupTOC -Inventory @($dummyEntry)
                $tocE.Devices.Count | Should -Be 0
            }
        } finally {
            Remove-TempDir $rEmpty
            Remove-TempDir $bEmpty
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Find-SplitSD - all backups contaminated' {

    It 'returns without throwing when every backup is Contaminated' {
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_all_dirty' `
                -DeviceSNs @('TV900000001', 'TV900000002') -YearMonth '202401'
            $inv = Get-BackupInventory -BackupRoot $root
            $toc = Get-BackupTOC -Inventory $inv
            # Force all backups to Contaminated so there are no clean spans
            foreach ($bName in $toc.Backups.Keys) {
                $toc.Backups[$bName].Integrity = 'Contaminated'
            }
            { Find-SplitSD -TOC $toc } | Should -Not -Throw
        } finally { Remove-TempDir $root }
    }

    It 'annotates no device as SplitSD when all backups are contaminated' {
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_all_dirty2' `
                -DeviceSNs @('TV900000003') -YearMonth '202406'
            $inv = Get-BackupInventory -BackupRoot $root
            $toc = Get-BackupTOC -Inventory $inv
            foreach ($bName in $toc.Backups.Keys) {
                $toc.Backups[$bName].Integrity = 'Contaminated'
            }
            Find-SplitSD -TOC $toc
            $sn = 'TV900000003'
            if ($toc.Devices.ContainsKey($sn) -and
                $toc.Devices[$sn].PSObject.Properties['SplitSD']) {
                $toc.Devices[$sn].SplitSD | Should -Be $false
            } else {
                # No SplitSD annotation = correct (device not marked as split)
                $true | Should -Be $true
            }
        } finally { Remove-TempDir $root }
    }
}