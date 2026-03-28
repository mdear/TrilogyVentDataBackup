#Requires -Version 5.1
# VBM-UIGoldenMenu.Tests.ps1 — Pester 5 tests for Show-GoldenDeviceMenu.
# All interactive prompts are mocked at the module level.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-UI.psm1') -Force

    function _MakeDevices {
        return @{
            'TV100000001' = [PSCustomObject]@{ Model = 'CA1032800';  OverallEarliest = '2023-01'; OverallLatest = '2024-06' }
            'TV100000002' = [PSCustomObject]@{ Model = 'CA1032800B'; OverallEarliest = '2024-01'; OverallLatest = '2025-03' }
            'TV100000003' = [PSCustomObject]@{ Model = 'CA2052800';  OverallEarliest = '2023-06'; OverallLatest = '2024-12' }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-GoldenDeviceMenu — Recommended path' {

    It 'returns all suggested SNs when user chooses R' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'R' }
        $devs      = _MakeDevices
        $suggested = @('TV100000001','TV100000002')
        $result    = Show-GoldenDeviceMenu -Devices $devs -Suggested $suggested
        $result.SelectedSNs | Should -HaveCount 2
        $result.SelectedSNs | Should -Contain 'TV100000001'
        $result.SelectedSNs | Should -Contain 'TV100000002'
    }

    It 'sets IsCustom = false on Recommended path' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'R' }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.IsCustom | Should -Be $false
    }

    It 'sets Reason to empty string on Recommended path' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'R' }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.Reason | Should -Be ''
    }

    It 'sets FromDate and ToDate to empty string on Recommended path' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'R' }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.FromDate | Should -Be ''
        $result.ToDate   | Should -Be ''
    }

    It 'accepts lowercase r on Recommended path' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'r' }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.IsCustom | Should -Be $false
    }

    It 'uses all device SNs as suggested when Suggested param is empty' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'R' }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @()
        $result.SelectedSNs | Should -HaveCount 3
    }

    It 'reprompts on invalid input before accepting R' {
        $script:calls = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:calls++
            if ($script:calls -eq 1) { return 'X' }
            return 'R'
        }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.IsCustom  | Should -Be $false
        $script:calls     | Should -Be 2
    }

    It 'works when IsFirstGolden is set' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'R' }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001') -IsFirstGolden
        $result.IsCustom | Should -Be $false
        $result.SelectedSNs | Should -HaveCount 1
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-GoldenDeviceMenu — Custom path' {

    It 'sets IsCustom = true on Custom path' {
        # C → device "1" → reason → no date bounds
        $script:seq = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:seq++
            switch ($script:seq) {
                1 { 'C' }    # menu pick
                2 { '1' }    # device selection (Show-DeviceSelection)
                3 { 'Audit card swap' }   # reason
                4 { '' }     # from date (blank = no lower bound)
                5 { '' }     # to date   (blank = no upper bound)
                default { '' }
            }
        }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.IsCustom | Should -Be $true
    }

    It 'captures reason text on Custom path' {
        $script:seq = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:seq++
            switch ($script:seq) {
                1 { 'C' }
                2 { '2' }    # pick device 2
                3 { 'Firmware rollback test' }
                4 { '' }; 5 { '' }
                default { '' }
            }
        }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.Reason | Should -Be 'Firmware rollback test'
    }

    It 'requires a non-empty reason and reprompts blank entries' {
        # Call sequence:
        #  1: 'C'            — menu pick
        #  2: ''             — Show-DeviceSelection: blank = accept suggestion, exits immediately
        #  3: ''             — reason: blank → reprompts (displays the warning)
        #  4: 'Valid reason' — reason: accepted
        #  5: ''             — from date blank
        #  6: ''             — to date blank
        $script:seq = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:seq++
            switch ($script:seq) {
                1 { 'C' }
                2 { '' }     # Show-DeviceSelection: accept suggestion immediately
                3 { '' }     # reason: blank — triggers reprompt
                4 { 'Valid reason' }
                5 { '' }; 6 { '' }
                default { '' }
            }
        }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.Reason | Should -Be 'Valid reason'
    }

    It 'captures date range when provided on Custom path' {
        $script:seq = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:seq++
            switch ($script:seq) {
                1 { 'C' }
                2 { '1' }
                3 { 'Post-maintenance check' }
                4 { '2024-01-01' }   # from date
                5 { '2024-06-01' }   # to date
                default { '' }
            }
        }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.FromDate | Should -Be '2024-01-01'
        $result.ToDate   | Should -Be '2024-06-01'
    }

    It 'returns empty date strings when no date range is entered on Custom path' {
        $script:seq = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:seq++
            switch ($script:seq) {
                1 { 'C' }
                2 { '1' }
                3 { 'Ad hoc reason' }
                4 { '' }   # from date blank
                5 { '' }   # to date blank
                default { '' }
            }
        }
        $result = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested @('TV100000001')
        $result.FromDate | Should -Be ''
        $result.ToDate   | Should -Be ''
    }

    It 'falls back to suggested devices when Custom selection resolves to nothing' {
        # Show-DeviceSelection loops on invalid input until '' exits it with suggestion.
        # Call sequence:
        #  1: 'C'             — menu pick
        #  2: '999'           — Show-DeviceSelection: out-of-range index, loops
        #  3: ''              — Show-DeviceSelection: blank = accept suggestion, exits
        #  4: 'Revert reason' — reason (non-empty, required)
        #  5: ''              — from date blank
        #  6: ''              — to date blank
        $script:seq = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:seq++
            switch ($script:seq) {
                1 { 'C' }
                2 { '999' }         # invalid index — Show-DeviceSelection loops
                3 { '' }            # accept suggestion — Show-DeviceSelection exits
                4 { 'Revert reason' }  # reason (non-empty)
                5 { '' }; 6 { '' }
                default { '' }
            }
        }
        $suggested = @('TV100000002')
        $result    = Show-GoldenDeviceMenu -Devices (_MakeDevices) -Suggested $suggested
        # Show-DeviceSelection returns $Suggested when blank is entered;
        # the result should contain the suggested SN.
        $result.SelectedSNs | Should -Contain 'TV100000002'
    }
}
