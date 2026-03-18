#Requires -Version 5.1
# VBM-GoldenArchive.Tests.ps1 — Pester 5 unit tests for ForceDevices and SplitSD features.
# Run via: Invoke-Pester -Path $PSScriptRoot (or scripts\tests\Run-Tests.ps1)

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')    -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1')   -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-GoldenArchive.psm1') -Force
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — ForceDevices' {

    BeforeAll {
        $script:root = New-TempDir

        # Two distinct devices in one backup
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak01' `
            -DeviceSNs @('TV000000001', 'TV000000002') -YearMonth '202408'

        $inv          = Get-BackupInventory -BackupRoot $script:root
        $script:toc   = Get-BackupTOC -Inventory $inv
        $script:gRoot = New-TempDir
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'includes ONLY the forced device in the manifest' {
        $golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -ForceDevices @('TV000000001') -ForceReason 'Test — force single device'

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.devices.PSObject.Properties.Name | Should -Contain 'TV000000001'
        $manifest.devices.PSObject.Properties.Name | Should -Not -Contain 'TV000000002'
    }

    It 'records forcedDevicesReason in manifest when ForceDevices supplied' {
        $golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -ForceDevices @('TV000000001') -ForceReason 'Clinician request: device swap'

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.forcedDevicesReason | Should -Be 'Clinician request: device swap'
    }

    It 'writes a fallback reason when ForceDevices supplied with no ForceReason' {
        $golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -ForceDevices @('TV000000002')

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.forcedDevicesReason | Should -Not -BeNullOrEmpty
    }

    It 'sets forcedDevicesReason to null when ForceDevices not supplied' {
        $golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @('TV000000001', 'TV000000002')

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.forcedDevicesReason | Should -BeNullOrEmpty
    }

    It 'emits a warning for a forced SN that is not in the TOC' {
        { New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -ForceDevices @('TVXXXXXXUNKNOWN') -ForceReason 'test unknown' `
            -WarningAction Stop
        } | Should -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Update-GoldenArchive — ForceDevices bypass' {

    BeforeAll {
        $script:root  = New-TempDir
        $script:gRoot = New-TempDir

        # Single device backup — used to build the initial golden
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak01' `
            -DeviceSNs @('TV000000003') -YearMonth '202408'

        $inv          = Get-BackupInventory -BackupRoot $script:root
        $script:toc   = Get-BackupTOC -Inventory $inv

        # Build initial golden
        $script:prev = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @('TV000000003')

        # Add a second backup with IDENTICAL content so change detection finds no diff
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak02' `
            -DeviceSNs @('TV000000003') -YearMonth '202408'

        $inv2        = Get-BackupInventory -BackupRoot $script:root
        $script:toc2 = Get-BackupTOC -Inventory $inv2
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'returns previous golden when no device data has changed' {
        $result = Update-GoldenArchive -TOC $script:toc2 -GoldenRoot $script:gRoot `
            -PreviousGolden $script:prev

        $result | Should -Be $script:prev
    }

    It 'creates a NEW golden when ForceDevices overrides change detection' {
        $result = Update-GoldenArchive -TOC $script:toc2 -GoldenRoot $script:gRoot `
            -PreviousGolden $script:prev `
            -ForceDevices @('TV000000003') -ForceReason 'Override: SD card reload'

        $result | Should -Not -Be $script:prev
        Test-Path $result | Should -Be $true
    }

    It 'records forcedDevicesReason in manifest of forced update' {
        $result = Update-GoldenArchive -TOC $script:toc2 -GoldenRoot $script:gRoot `
            -PreviousGolden $script:prev `
            -ForceDevices @('TV000000003') -ForceReason 'Audit: re-export requested'

        $manifest = Get-Content (Join-Path $result 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.forcedDevicesReason | Should -Be 'Audit: re-export requested'
    }

    It 'sets forcedDevicesReason to null when no ForceDevices in update' {
        # Force change by using larger EDF body bytes so hash differs
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak03' `
            -DeviceSNs @('TV000000003') -YearMonth '202409' -EdfBodyBytes 512

        $inv3  = Get-BackupInventory -BackupRoot $script:root
        $toc3  = Get-BackupTOC -Inventory $inv3
        $result = Update-GoldenArchive -TOC $toc3 -GoldenRoot $script:gRoot `
            -PreviousGolden $script:prev

        $manifest = Get-Content (Join-Path $result 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.forcedDevicesReason | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — SplitSD manifest propagation' {

    BeforeAll {
        $script:root = New-TempDir

        # Create a split-SD scenario: same device, two non-overlapping backups 7 months apart
        New-SplitSDBackupPair -BackupRoot $script:root `
            -SN 'TV000000004' `
            -EarlyYearMonth '202401' -LateYearMonth '202408' `
            -EarlyBlowerHours 500    -LateBlowerHours 5000

        $inv        = Get-BackupInventory -BackupRoot $script:root
        $script:toc = Get-BackupTOC -Inventory $inv

        # Annotate TOC via Detect-SplitSD
        Detect-SplitSD -TOC $script:toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

        $script:gRoot = New-TempDir
    }

    AfterAll {
        Remove-TempDir $script:root
        Remove-TempDir $script:gRoot
    }

    It 'sets splitSD=true in manifest for a detected split-SD device' {
        $golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @('TV000000004')

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.devices.'TV000000004'.splitSD | Should -Be $true
    }

    It 'includes splitSDSpans with two span entries' {
        $golden = New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @('TV000000004')

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $spans = $manifest.devices.'TV000000004'.splitSDSpans
        $spans | Should -Not -BeNullOrEmpty
        @($spans).Count | Should -Be 2
    }

    It 'sets splitSD=false for device without split annotation' {
        # Add a non-split device
        New-SyntheticBackup -BackupRoot $script:root -Name 'bak_nonsplit' `
            -DeviceSNs @('TV000000005') -YearMonth '202408'

        $inv2 = Get-BackupInventory -BackupRoot $script:root
        $toc2 = Get-BackupTOC -Inventory $inv2
        # Do NOT call Detect-SplitSD — TV000000005 should have no annotation

        $golden = New-GoldenArchive -TOC $toc2 -GoldenRoot $script:gRoot `
            -Devices @('TV000000005')

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.devices.'TV000000005'.splitSD | Should -Be $false
    }
}
