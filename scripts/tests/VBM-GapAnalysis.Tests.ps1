#Requires -Version 5.1
# VBM-GapAnalysis.Tests.ps1 — Pester 5 unit tests for Get-DeviceGaps (VBM-Analyzer.psm1)
# and Show-GapSwimLanes (VBM-UI.psm1).
#
# These tests use synthetic PSCustomObject TOCs so no real files are required.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-UI.psm1')       -Force

    # Build a minimal synthetic TOC that Get-DeviceGaps can consume.
    # $MonthKeys is a [string[]] of 'YYYY-MM' strings, e.g. @('2023-03', '2023-05').
    # NOTE: do NOT pass @(@(2023,3)) — PS5.1 @(single-array) unwraps to the array itself.
    function New-SyntheticTOC {
        param(
            [string]  $SN,
            [string[]]$MonthKeys,           # e.g. @('2023-03', '2023-05')
            [string]  $Integrity = 'OK'     # or 'Contaminated'
        )
        $trilogyFiles = @($MonthKeys | ForEach-Object {
            [PSCustomObject]@{
                FileType = 'AD'
                IsDaily  = $false
                Year     = [int]$_.Substring(0, 4)
                Month    = [int]$_.Substring(5, 2)
            }
        })

        $backupEntry = [PSCustomObject]@{
            Integrity = $Integrity
            Devices   = @{
                $SN = [PSCustomObject]@{
                    TrilogyFiles = $trilogyFiles
                }
            }
        }

        return [PSCustomObject]@{
            Backups = @{ 'backup1' = $backupEntry }
            Devices = @{ $SN = [PSCustomObject]@{ SerialNumber = $SN } }
        }
    }

    # Build a GapResult PSCustomObject matching Get-DeviceGaps output format, for direct
    # use in Show-GapSwimLanes tests (bypasses the analyzer).
    function New-GapResult {
        param(
            [string]  $SN,
            [string[]]$CoveredMonths,
            [object[]]$Gaps               = @(),
            [string[]]$ContaminatedMonths = @()
        )
        $earliest = @($CoveredMonths | Sort-Object)[0]
        $latest   = @($CoveredMonths | Sort-Object)[-1]
        return [PSCustomObject]@{
            DeviceSerial       = $SN
            OverallEarliest    = $earliest
            OverallLatest      = $latest
            CoveredMonths      = $CoveredMonths
            Gaps               = $Gaps
            ContaminatedMonths = $ContaminatedMonths
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-DeviceGaps — device with no data' {

    It 'returns empty result when device has no AD/DD files' {
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @()
        $r   = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.OverallEarliest    | Should -BeNullOrEmpty
        $r.CoveredMonths      | Should -BeNullOrEmpty
        $r.Gaps               | Should -BeNullOrEmpty
        $r.ContaminatedMonths | Should -BeNullOrEmpty
    }

    It 'returns empty result when device SN is not in TOC' {
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-03')
        $r   = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN999'
        $r.OverallEarliest | Should -BeNullOrEmpty
        $r.CoveredMonths   | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-DeviceGaps — contiguous coverage' {

    It 'reports no gaps when every month in the range is covered' {
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-01', '2023-02', '2023-03')
        $r   = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.OverallEarliest | Should -Be '2023-01'
        $r.OverallLatest   | Should -Be '2023-03'
        $r.CoveredMonths   | Should -HaveCount 3
        $r.Gaps            | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-DeviceGaps — single-month gap debouncing' {

    BeforeAll {
        # Coverage: 2023-03 and 2023-05 — gap is 2023-04 (1 month = 4 weeks)
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-03', '2023-05')
    }

    It 'finds exactly one gap' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.Gaps | Should -HaveCount 1
    }

    It 'gap has correct Start, End, DurationMonths and DurationWeeks' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $g = $r.Gaps[0]
        $g.Start          | Should -Be '2023-04'
        $g.End            | Should -Be '2023-04'
        $g.DurationMonths | Should -Be 1
        $g.DurationWeeks  | Should -Be 4
    }

    It 'gap is debounced when DebounceWeeks=4 (4 <= 4)' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001' -DebounceWeeks 4
        $r.Gaps[0].IsDebounced | Should -Be $true
    }

    It 'gap is NOT debounced when DebounceWeeks=0 (4 > 0)' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001' -DebounceWeeks 0
        $r.Gaps[0].IsDebounced | Should -Be $false
    }

    It 'gap is NOT debounced when DebounceWeeks=3 (4 > 3)' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001' -DebounceWeeks 3
        $r.Gaps[0].IsDebounced | Should -Be $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-DeviceGaps — multi-month gap' {

    BeforeAll {
        # Gap: 2023-04, 2023-05, 2023-06 (3 months = 12 weeks)
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-03', '2023-07')
    }

    It 'reports DurationMonths=3 and DurationWeeks=12' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $g = $r.Gaps[0]
        $g.DurationMonths | Should -Be 3
        $g.DurationWeeks  | Should -Be 12
    }

    It 'gap is NOT debounced with DebounceWeeks=4' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001' -DebounceWeeks 4
        $r.Gaps[0].IsDebounced | Should -Be $false
    }

    It 'gap is debounced with DebounceWeeks=12 (12 <= 12)' {
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001' -DebounceWeeks 12
        $r.Gaps[0].IsDebounced | Should -Be $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-DeviceGaps — contaminated backup handling' {

    It 'months from contaminated backups appear in ContaminatedMonths when no clean backup covers them' {
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-03') -Integrity 'Contaminated'
        $r   = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.ContaminatedMonths | Should -Contain '2023-03'
    }

    It 'clean backup supersedes contaminated for the same month' {
        # Two backups: one clean, one contaminated — both covering 2023-03
        $cleanEntry  = [PSCustomObject]@{
            Integrity = 'OK'
            Devices   = @{
                'SN001' = [PSCustomObject]@{
                    TrilogyFiles = @(
                        [PSCustomObject]@{ FileType='AD'; IsDaily=$false; Year=2023; Month=3 }
                    )
                }
            }
        }
        $contamEntry = [PSCustomObject]@{
            Integrity = 'Contaminated'
            Devices   = @{
                'SN001' = [PSCustomObject]@{
                    TrilogyFiles = @(
                        [PSCustomObject]@{ FileType='AD'; IsDaily=$false; Year=2023; Month=3 }
                    )
                }
            }
        }
        $toc = [PSCustomObject]@{
            Backups = @{ 'backup_clean' = $cleanEntry; 'backup_contam' = $contamEntry }
            Devices = @{ 'SN001' = [PSCustomObject]@{ SerialNumber = 'SN001' } }
        }
        $r = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.ContaminatedMonths | Should -BeNullOrEmpty  # clean wins → not contaminated-only
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-DeviceGaps — YYYYMM key construction' {

    It 'single-digit months are zero-padded in OverallEarliest' {
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-01')
        $r   = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.OverallEarliest | Should -Be '2023-01'
    }

    It 'year rollover is handled correctly (DEC → JAN next year)' {
        # Coverage 2023-11, 2024-02 — gap spans 2023-12, 2024-01 (2 months)
        $toc = New-SyntheticTOC -SN 'SN001' -MonthKeys @('2023-11', '2024-02')
        $r   = Get-DeviceGaps -TOC $toc -DeviceSerial 'SN001'
        $r.Gaps            | Should -HaveCount 1
        $r.Gaps[0].Start   | Should -Be '2023-12'
        $r.Gaps[0].End     | Should -Be '2024-01'
        $r.Gaps[0].DurationMonths | Should -Be 2
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Show-GapSwimLanes — no exception with DebounceWeeks=0' {

    BeforeAll {
        Mock Write-Host {} -ModuleName VBM-UI
    }

    It 'renders without error when DebounceWeeks=0 and gaps are present' {
        $gap = [PSCustomObject]@{
            Start          = '2023-04'
            End            = '2023-04'
            DurationMonths = 1
            DurationWeeks  = 4
            IsDebounced    = $false
            Months         = @('2023-04')
        }
        $gr = New-GapResult -SN 'SN001' -CoveredMonths @('2023-03', '2023-05') -Gaps @($gap)

        { Show-GapSwimLanes -GapResults @($gr) -DebounceWeeks 0 } | Should -Not -Throw
    }

    It 'renders without error when DebounceWeeks=0 and there are no gaps' {
        $gr = New-GapResult -SN 'SN001' -CoveredMonths @('2023-01', '2023-02', '2023-03')

        { Show-GapSwimLanes -GapResults @($gr) -DebounceWeeks 0 } | Should -Not -Throw
    }

    It 'renders without error with a multi-device result spanning multiple years' {
        $gap = [PSCustomObject]@{
            Start          = '2024-04'
            End            = '2024-06'
            DurationMonths = 3
            DurationWeeks  = 12
            IsDebounced    = $false
            Months         = @('2024-04', '2024-05', '2024-06')
        }
        $gr1 = New-GapResult -SN 'DEVICE001' -CoveredMonths @('2023-01', '2023-06', '2024-01', '2024-11')
        $gr2 = New-GapResult -SN 'DEVICE002' -CoveredMonths @('2024-01', '2024-03', '2024-07', '2024-11') -Gaps @($gap)

        { Show-GapSwimLanes -GapResults @($gr1, $gr2) -DebounceWeeks 0 } | Should -Not -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Show-GapSwimLanes — no data case' {

    BeforeAll {
        Mock Write-Host {} -ModuleName VBM-UI
    }

    It 'renders without error when all devices have no data' {
        $gr = [PSCustomObject]@{
            DeviceSerial       = 'SN001'
            OverallEarliest    = $null
            OverallLatest      = $null
            CoveredMonths      = @()
            Gaps               = @()
            ContaminatedMonths = @()
        }
        { Show-GapSwimLanes -GapResults @($gr) -DebounceWeeks 4 } | Should -Not -Throw
    }
}
