#Requires -Version 5.1
# VBM-GoldenDateFilter.Tests.ps1 — Pester 5 tests for the optional inclusive
# date-range filter on New-GoldenArchive and Update-GoldenArchive.
#
# The filter restricts which EDF therapy-data files and PP ring-buffer entries
# are included in a golden archive, while keeping device identity files
# (prop.txt, FILES.SEQ, SL_SAPPHIRE.json, etc.) unconditionally.
# The resulting golden must always pass Test-GoldenIntegrity and
# Test-GoldenContent (self-consistency guarantee).
#
# Run via:  Invoke-Pester -Path $PSScriptRoot
#       or  .\scripts\tests\Run-Tests.ps1

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')       -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1')      -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-GoldenArchive.psm1') -Force

    # Create several backups of the same device at different months, then return a TOC.
    function New-MultiMonthTOC {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$SN,
            [string[]]$Months   # YYYYMM values
        )
        foreach ($ym in $Months) {
            New-SyntheticBackup -BackupRoot $Root -Name "bak_$ym" `
                -DeviceSNs @($SN) -YearMonth $ym
        }
        $inv = Get-BackupInventory -BackupRoot $Root
        return Get-BackupTOC -Inventory $inv
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'New-GoldenArchive — no date filter' {

    BeforeAll {
        $script:sn    = 'TV000AAA001'
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir
        $script:toc   = New-MultiMonthTOC -Root $script:root -SN $script:sn `
                            -Months @('202401', '202403', '202406')
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'includes EDF files from all months when neither FromDate nor ToDate supplied' {
        $golden  = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
                       -Devices @($script:sn)
        $triDir  = Join-Path $golden "$($script:sn)\Trilogy"
        $adFiles = @(Get-ChildItem $triDir -Filter 'AD_*.edf').Name

        $adFiles | Should -Contain 'AD_202401_000.edf'
        $adFiles | Should -Contain 'AD_202403_000.edf'
        $adFiles | Should -Contain 'AD_202406_000.edf'
    }

    It 'records dateFilter as null in manifest when no filter is supplied' {
        $golden   = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
                        -Devices @($script:sn)
        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.dateFilter | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'New-GoldenArchive — FromDate + ToDate (mid-range)' {

    BeforeAll {
        $script:sn    = 'TV000AAA002'
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir
        $script:toc   = New-MultiMonthTOC -Root $script:root -SN $script:sn `
                            -Months @('202401', '202403', '202406')

        # Single golden built once; all It blocks in this Describe share it
        $script:golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
                             -Devices @($script:sn) -FromDate '2024-02-01' -ToDate '2024-04-30'
        $script:triDir = Join-Path $script:golden "$($script:sn)\Trilogy"
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'excludes AD/DD files whose month is before FromDate' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Not -Contain 'AD_202401_000.edf'
        $ddFiles = @(Get-ChildItem $script:triDir -Filter 'DD_*.edf').Name
        $ddFiles | Should -Not -Contain 'DD_202401_000.edf'
    }

    It 'excludes AD/DD files whose month is after ToDate' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Not -Contain 'AD_202406_000.edf'
        $ddFiles = @(Get-ChildItem $script:triDir -Filter 'DD_*.edf').Name
        $ddFiles | Should -Not -Contain 'DD_202406_000.edf'
    }

    It 'includes AD/DD files whose month falls within the range' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Contain 'AD_202403_000.edf'
        $ddFiles = @(Get-ChildItem $script:triDir -Filter 'DD_*.edf').Name
        $ddFiles | Should -Contain 'DD_202403_000.edf'
    }

    It 'excludes PP ring-buffer entries whose month is before FromDate' {
        $psDevDir = Join-Path $script:golden "$($script:sn)\P-Series\$($script:sn)"
        $allPP    = @(Get-ChildItem $psDevDir -Recurse -Filter 'PP_*.json').Name
        $jan      = @($allPP | Where-Object { $_ -like 'PP_202401*' })
        $jan.Count | Should -Be 0
    }

    It 'excludes PP ring-buffer entries whose month is after ToDate' {
        $psDevDir = Join-Path $script:golden "$($script:sn)\P-Series\$($script:sn)"
        $allPP    = @(Get-ChildItem $psDevDir -Recurse -Filter 'PP_*.json').Name
        $jun      = @($allPP | Where-Object { $_ -like 'PP_202406*' })
        $jun.Count | Should -Be 0
    }

    It 'includes PP ring-buffer entries whose month is within the range' {
        $psDevDir = Join-Path $script:golden "$($script:sn)\P-Series\$($script:sn)"
        $allPP    = @(Get-ChildItem $psDevDir -Recurse -Filter 'PP_*.json').Name
        $mar      = @($allPP | Where-Object { $_ -like 'PP_202403*' })
        $mar.Count | Should -BeGreaterThan 0
    }

    It 'keeps steering files (prop.txt, FILES.SEQ, SL_SAPPHIRE.json) regardless of date range' {
        $psDevDir = Join-Path $script:golden "$($script:sn)\P-Series\$($script:sn)"
        (Test-Path (Join-Path $psDevDir 'prop.txt'))        | Should -Be $true
        (Test-Path (Join-Path $psDevDir 'FILES.SEQ'))       | Should -Be $true
        (Test-Path (Join-Path $psDevDir 'SL_SAPPHIRE.json'))| Should -Be $true
    }

    It 'records dateFilter.from and dateFilter.to in manifest.json' {
        $manifest = Get-Content (Join-Path $script:golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.dateFilter      | Should -Not -BeNullOrEmpty
        $manifest.dateFilter.from | Should -Be '2024-02-01'
        $manifest.dateFilter.to   | Should -Be '2024-04-30'
    }

    It 'passes Test-GoldenIntegrity (hash + SN consistency)' {
        $result = Test-GoldenIntegrity -GoldenPath $script:golden
        $result.Passed | Should -Be $true
    }

    It 'passes Test-GoldenContent (self-consistent DirectView-compatible archive)' {
        $result = Test-GoldenContent -GoldenPath $script:golden
        $result.Passed | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'New-GoldenArchive — FromDate only (lower bound)' {

    BeforeAll {
        $script:sn    = 'TV000AAA003'
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir
        $script:toc   = New-MultiMonthTOC -Root $script:root -SN $script:sn `
                            -Months @('202401', '202403', '202406')

        $script:golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
                             -Devices @($script:sn) -FromDate '2024-03-01'
        $script:triDir = Join-Path $script:golden "$($script:sn)\Trilogy"
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'excludes files before the lower-bound month' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Not -Contain 'AD_202401_000.edf'
    }

    It 'includes the boundary month (FromDate is inclusive)' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Contain 'AD_202403_000.edf'
    }

    It 'includes months after the lower bound (no upper restriction)' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Contain 'AD_202406_000.edf'
    }

    It 'records dateFilter.from but leaves dateFilter.to null in manifest' {
        $manifest = Get-Content (Join-Path $script:golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.dateFilter.from | Should -Be '2024-03-01'
        $manifest.dateFilter.to   | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'New-GoldenArchive — ToDate only (upper bound)' {

    BeforeAll {
        $script:sn    = 'TV000AAA004'
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir
        $script:toc   = New-MultiMonthTOC -Root $script:root -SN $script:sn `
                            -Months @('202401', '202403', '202406')

        $script:golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
                             -Devices @($script:sn) -ToDate '2024-03-31'
        $script:triDir = Join-Path $script:golden "$($script:sn)\Trilogy"
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'includes months before the upper bound (no lower restriction)' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Contain 'AD_202401_000.edf'
    }

    It 'includes the boundary month (ToDate is inclusive)' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Contain 'AD_202403_000.edf'
    }

    It 'excludes files after the upper-bound month' {
        $adFiles = @(Get-ChildItem $script:triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Not -Contain 'AD_202406_000.edf'
    }

    It 'records dateFilter.to but leaves dateFilter.from null in manifest' {
        $manifest = Get-Content (Join-Path $script:golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.dateFilter.from | Should -BeNullOrEmpty
        $manifest.dateFilter.to   | Should -Be '2024-03-31'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'New-GoldenArchive — input validation' {

    BeforeAll {
        $script:sn    = 'TV000AAA005'
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir
        $script:toc   = New-MultiMonthTOC -Root $script:root -SN $script:sn `
                            -Months @('202403')
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'throws when FromDate is not in YYYY-MM-DD format' {
        { New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @($script:sn) -FromDate '2024/03'
        } | Should -Throw
    }

    It 'throws when ToDate is not in YYYY-MM-DD format' {
        { New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @($script:sn) -ToDate 'March-2024'
        } | Should -Throw
    }

    It 'throws when ToDate is before FromDate' {
        { New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @($script:sn) -FromDate '2024-06-01' -ToDate '2024-03-01'
        } | Should -Throw
    }

    It 'does not throw when FromDate equals ToDate (single-day window)' {
        { New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @($script:sn) -FromDate '2024-03-01' -ToDate '2024-03-01'
        } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Update-GoldenArchive — date range filter' {

    BeforeAll {
        $script:sn    = 'TV000BBB002'
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir

        # Initial data: Jan 2024 and Jun 2024
        $script:toc1      = New-MultiMonthTOC -Root $script:root -SN $script:sn `
                                -Months @('202401', '202406')
        $script:initGolden = New-GoldenArchive -TOC $script:toc1 -GoldenRoot $script:gRoot `
                                 -Devices @($script:sn)

        # Add Mar 2024 so Update-GoldenArchive sees a change
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_202403' `
            -DeviceSNs @($script:sn) -YearMonth '202403'
        $inv2          = Get-BackupInventory -BackupRoot $script:root
        $script:toc2   = Get-BackupTOC -Inventory $inv2

        # Build filtered incremental golden
        $script:filtGolden = Update-GoldenArchive -TOC $script:toc2 `
                                 -GoldenRoot $script:gRoot `
                                 -PreviousGolden $script:initGolden `
                                 -FromDate '2024-02-01' -ToDate '2024-04-30'
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'applies date filter — only in-range month present in Trilogy/' {
        $triDir  = Join-Path $script:filtGolden "$($script:sn)\Trilogy"
        $adFiles = @(Get-ChildItem $triDir -Filter 'AD_*.edf').Name
        $adFiles | Should -Contain 'AD_202403_000.edf'
        $adFiles | Should -Not -Contain 'AD_202401_000.edf'
        $adFiles | Should -Not -Contain 'AD_202406_000.edf'
    }

    It 'records dateFilter in manifest of the incremental golden' {
        $manifest = Get-Content (Join-Path $script:filtGolden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.dateFilter.from | Should -Be '2024-02-01'
        $manifest.dateFilter.to   | Should -Be '2024-04-30'
    }

    It 'passes Test-GoldenIntegrity on the date-filtered incremental golden' {
        $result = Test-GoldenIntegrity -GoldenPath $script:filtGolden
        $result.Passed | Should -Be $true
    }

    It 'passes Test-GoldenContent on the date-filtered incremental golden' {
        $result = Test-GoldenContent -GoldenPath $script:filtGolden
        $result.Passed | Should -Be $true
    }

    It 'increments goldenSequence relative to the initial golden' {
        $manifest = Get-Content (Join-Path $script:filtGolden 'manifest.json') -Raw | ConvertFrom-Json
        [int]$manifest.goldenSequence | Should -BeGreaterThan 1
    }
}
