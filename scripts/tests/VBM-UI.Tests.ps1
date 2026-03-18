#Requires -Version 5.1
# VBM-UI.Tests.ps1 — Pester 5 unit tests for VBM-UI.psm1.
# All interactive functions are tested by mocking Read-Host within the module scope.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-UI.psm1') -Force

    # Build a small device hashtable used across multiple Describe blocks.
    function _MakeDevices {
        return @{
            'TV100000001' = [PSCustomObject]@{ Model = 'CA1032800'; OverallEarliest = '2023-01'; OverallLatest = '2024-06' }
            'TV100000002' = [PSCustomObject]@{ Model = 'CA1032800B'; OverallEarliest = '2024-01'; OverallLatest = '2025-03' }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-YesNo' {

    It 'returns $true when user enters Y' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'Y' }
        Read-YesNo -Prompt 'Test?' | Should -Be $true
    }

    It 'returns $false when user enters N' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'N' }
        Read-YesNo -Prompt 'Test?' | Should -Be $false
    }

    It 'returns $true on empty input when Default is $true' {
        Mock -ModuleName 'VBM-UI' Read-Host { '' }
        Read-YesNo -Prompt 'Test?' -Default $true | Should -Be $true
    }

    It 'returns $false on empty input when Default is $false' {
        Mock -ModuleName 'VBM-UI' Read-Host { '' }
        Read-YesNo -Prompt 'Test?' -Default $false | Should -Be $false
    }

    It 'accepts lowercase y as $true' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'y' }
        Read-YesNo -Prompt 'Test?' | Should -Be $true
    }

    It 'accepts lowercase n as $false' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'n' }
        Read-YesNo -Prompt 'Test?' | Should -Be $false
    }

    It 'reprompts on invalid input then accepts valid answer' {
        $script:callCount = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:callCount++
            if ($script:callCount -eq 1) { return 'MAYBE' }
            return 'Y'
        }
        $result = Read-YesNo -Prompt 'Test?'
        $result | Should -Be $true
        $script:callCount | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-ValidatedPath' {

    It 'returns path immediately when MustExist is not set' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'C:\SomeFakePath' }
        $result = Read-ValidatedPath -Prompt 'Enter path'
        $result | Should -Be 'C:\SomeFakePath'
    }

    It 'strips surrounding quotes from input' {
        Mock -ModuleName 'VBM-UI' Read-Host { '"C:\SomePath"' }
        $result = Read-ValidatedPath -Prompt 'Enter path'
        $result | Should -Be 'C:\SomePath'
    }

    It 'expands ~ to the user home directory' {
        Mock -ModuleName 'VBM-UI' Read-Host { "~\Documents" }
        $result = Read-ValidatedPath -Prompt 'Enter path'
        $result | Should -Not -Match '^\~'
        $escapedHome = [regex]::Escape($HOME)
        $result | Should -Match $escapedHome
    }

    It 'returns an existing path when -MustExist is specified' {
        $tmpDir = New-TempDir
        try {
            Mock -ModuleName 'VBM-UI' Read-Host { $tmpDir }
            $result = Read-ValidatedPath -Prompt 'Enter path' -MustExist
            $result | Should -Be $tmpDir
        } finally {
            Remove-TempDir $tmpDir
        }
    }

    It 'reprompts when -MustExist path does not exist then accepts valid path' {
        $tmpDir  = New-TempDir
        $script:c2 = 0
        try {
            Mock -ModuleName 'VBM-UI' Read-Host {
                $script:c2++
                if ($script:c2 -eq 1) { return 'Z:\DoesNotExist\NotHere' }
                return $tmpDir
            }
            $result = Read-ValidatedPath -Prompt 'Enter path' -MustExist
            $result | Should -Be $tmpDir
            $script:c2 | Should -Be 2
        } finally {
            Remove-TempDir $tmpDir
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Write-ProgressBar' {

    It 'runs without error for typical progress values' {
        { Write-ProgressBar -Activity 'Testing' -Current 50 -Total 100 } | Should -Not -Throw
    }

    It 'runs without error when Current equals Total' {
        { Write-ProgressBar -Activity 'Done' -Current 100 -Total 100 } | Should -Not -Throw
    }

    It 'runs without error when Total is zero (avoids divide-by-zero)' {
        { Write-ProgressBar -Activity 'Empty' -Current 0 -Total 0 } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Write-TimelineChart' {

    It 'runs without error when given a hashtable of timelines' {
        $timelines = @{
            'TV100000001' = @(
                [PSCustomObject]@{ EarliestDate = '2023-01'; LatestDate = '2023-12'; Integrity = 'Clean' }
            )
            'TV100000002' = @(
                [PSCustomObject]@{ EarliestDate = '2024-01'; LatestDate = '2025-03'; Integrity = 'Clean' }
            )
        }
        { Write-TimelineChart -DeviceTimelines $timelines } | Should -Not -Throw
    }

    It 'runs without error when given a direct array (single-device form)' {
        $entries = @(
            [PSCustomObject]@{ EarliestDate = '2023-06'; LatestDate = '2024-06'; Integrity = 'Clean' }
        )
        { Write-TimelineChart -DeviceTimelines $entries } | Should -Not -Throw
    }

    It 'runs without error when date information is absent' {
        $timelines = @{
            'TV999' = @( [PSCustomObject]@{ EarliestDate = $null; LatestDate = $null } )
        }
        { Write-TimelineChart -DeviceTimelines $timelines } | Should -Not -Throw
    }

    It 'handles contaminated integrity colour branch without error' {
        $timelines = @{
            'TV100000003' = @(
                [PSCustomObject]@{ EarliestDate = '2024-01'; LatestDate = '2024-12'; Integrity = 'Contaminated' }
            )
        }
        { Write-TimelineChart -DeviceTimelines $timelines } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-DeviceSelection — Enter to accept suggestion' {

    It 'returns the suggested SNs when user presses Enter' {
        Mock -ModuleName 'VBM-UI' Read-Host { '' }  # Empty = accept suggestion
        $devs = _MakeDevices
        $result = Show-DeviceSelection -Devices $devs -Suggested @('TV100000001')
        $result | Should -Contain 'TV100000001'
        $result.Count | Should -Be 1
    }

    It 'returns all suggested SNs unchanged when multiple are suggested' {
        Mock -ModuleName 'VBM-UI' Read-Host { '' }
        $devs = _MakeDevices
        $result = Show-DeviceSelection -Devices $devs -Suggested @('TV100000001', 'TV100000002')
        $result | Should -Contain 'TV100000001'
        $result | Should -Contain 'TV100000002'
        $result.Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-DeviceSelection — manual number override' {

    It 'returns the correct SN when user picks by number' {
        # Devices are sorted alphabetically: TV100000001=1, TV100000002=2
        Mock -ModuleName 'VBM-UI' Read-Host { '2' }
        $devs   = _MakeDevices
        $result = Show-DeviceSelection -Devices $devs -Suggested @('TV100000001')
        $result | Should -Contain 'TV100000002'
        $result.Count | Should -Be 1
    }

    It 'accepts comma-separated numbers selecting multiple devices' {
        Mock -ModuleName 'VBM-UI' Read-Host { '1,2' }
        $devs   = _MakeDevices
        $result = Show-DeviceSelection -Devices $devs -Suggested @()
        $result | Should -Contain 'TV100000001'
        $result | Should -Contain 'TV100000002'
        $result.Count | Should -Be 2
    }

    It 'reprompts on invalid number then accepts valid input' {
        $script:c3 = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:c3++
            if ($script:c3 -eq 1) { return '99' }  # Out-of-range
            return '1'
        }
        $devs   = _MakeDevices
        $result = Show-DeviceSelection -Devices $devs -Suggested @()
        $result.Count | Should -Be 1
        $script:c3 | Should -Be 2
    }

    It 'works with a hashtable input for Devices' {
        Mock -ModuleName 'VBM-UI' Read-Host { '' }
        $devs = @{
            'TV500000001' = [PSCustomObject]@{ Model = 'CA1032800'; OverallEarliest = '2023-01'; OverallLatest = '2023-12' }
        }
        $result = Show-DeviceSelection -Devices $devs -Suggested @('TV500000001')
        $result | Should -Contain 'TV500000001'
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-ForceDevicesPrompt — user declines the override' {

    It 'returns ForceDevices=$false when user answers N to the initial prompt' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'N' }
        $devs   = _MakeDevices
        $result = Show-ForceDevicesPrompt -Devices $devs
        $result.ForceDevices | Should -Be $false
        $result.SelectedSNs.Count | Should -Be 0
        $result.Reason | Should -Be ''
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-ForceDevicesPrompt — user forces all devices and confirms' {

    It 'returns ForceDevices=$true with all SNs when user types Y, A, reason, Y' {
        $script:fCalls = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:fCalls++
            switch ($script:fCalls) {
                1 { 'Y' }   # Force prompt: yes
                2 { 'A' }   # Device selection: all
                3 { 'Firmware update required' }  # Reason
                4 { 'Y' }   # Confirmation: yes
            }
        }
        $devs   = _MakeDevices
        $result = Show-ForceDevicesPrompt -Devices $devs
        $result.ForceDevices | Should -Be $true
        $result.SelectedSNs  | Should -Contain 'TV100000001'
        $result.SelectedSNs  | Should -Contain 'TV100000002'
        $result.Reason       | Should -Be 'Firmware update required'
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-ForceDevicesPrompt — user forces specific devices then cancels at confirmation' {

    It 'returns ForceDevices=$false when user cancels at confirmation step' {
        $script:cCalls = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:cCalls++
            switch ($script:cCalls) {
                1 { 'Y' }   # Force prompt: yes
                2 { '1' }   # Device selection: device 1 only
                3 { 'Card swap after service' }  # Reason
                4 { 'N' }   # Confirmation: NO — cancel
            }
        }
        $devs   = _MakeDevices
        $result = Show-ForceDevicesPrompt -Devices $devs
        $result.ForceDevices | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-ForceDevicesPrompt — requires non-empty reason' {

    It 'reprompts when reason is blank, accepts non-blank on retry' {
        $script:rCalls = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:rCalls++
            switch ($script:rCalls) {
                1 { 'Y' }   # Force prompt
                2 { '1' }   # Device number
                3 { '' }    # Empty reason — should reprompt
                4 { 'Audit requirement' }  # Valid reason
                5 { 'Y' }   # Confirm
            }
        }
        $devs   = _MakeDevices
        $result = Show-ForceDevicesPrompt -Devices $devs
        $result.ForceDevices | Should -Be $true
        $result.Reason       | Should -Be 'Audit requirement'
        $script:rCalls       | Should -BeGreaterOrEqual 5
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-MainMenu' {

    It 'returns 1 when user selects option 1' {
        Mock -ModuleName 'VBM-UI' Read-Host { '1' }
        $result = Show-MainMenu
        $result | Should -Be 1
    }

    It 'returns 6 when user selects option 6' {
        Mock -ModuleName 'VBM-UI' Read-Host { '6' }
        $result = Show-MainMenu
        $result | Should -Be 6
    }

    It 'returns 0 when user enters Q' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'Q' }
        $result = Show-MainMenu
        $result | Should -Be 0
    }

    It 'returns 0 when user enters lowercase q' {
        Mock -ModuleName 'VBM-UI' Read-Host { 'q' }
        $result = Show-MainMenu
        $result | Should -Be 0
    }

    It 'reprompts on invalid input then accepts valid choice' {
        $script:mCalls = 0
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:mCalls++
            if ($script:mCalls -eq 1) { return '9' }   # Invalid (9 > 7)
            return '3'
        }
        $result = Show-MainMenu
        $result | Should -Be 3
        $script:mCalls | Should -Be 2
    }

    It 'returns 7 when user selects option 7 (Settings)' {
        Mock -ModuleName 'VBM-UI' Read-Host { '7' }
        $result = Show-MainMenu
        $result | Should -Be 7
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-SourcePicker' {

    It 'returns a manually entered path when user chooses M' {
        $tmp = [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
        $script:spcCalls  = 0
        $script:spcTarget = $tmp
        Mock -ModuleName 'VBM-UI' Read-Host {
            $script:spcCalls++
            if ($script:spcCalls -eq 1) { return 'M' }   # choose manual entry
            return $script:spcTarget                       # provide the path
        }
        $result = Show-SourcePicker
        $result | Should -Be $tmp
    }
}
