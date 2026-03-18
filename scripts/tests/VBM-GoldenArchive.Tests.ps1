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

        # Annotate TOC via Find-SplitSD
        Find-SplitSD -TOC $script:toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

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
        # Do NOT call Find-SplitSD — TV000000005 should have no annotation

        $golden = New-GoldenArchive -TOC $toc2 -GoldenRoot $script:gRoot `
            -Devices @('TV000000005')

        $manifest = Get-Content (Join-Path $golden 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.devices.'TV000000005'.splitSD | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenIntegrity' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:sn    = 'TV000000010'
        New-SyntheticBackup -BackupRoot $script:bRoot -Name 'bak01' `
            -DeviceSNs @($script:sn) -YearMonth '202408'
        $inv         = Get-BackupInventory -BackupRoot $script:bRoot
        $toc         = Get-BackupTOC -Inventory $inv
        $script:gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $script:gRoot `
            -Devices @($script:sn))
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'passes for a freshly built valid golden' {
        $result = Test-GoldenIntegrity -GoldenPath $script:gold
        $result.Passed    | Should -Be $true
        $result.FileCount | Should -BeGreaterThan 0
        $result.Failures  | Should -BeNullOrEmpty
    }

    It 'fails when manifest.json is not present' {
        $emptyDir = New-TempDir
        try {
            $result = Test-GoldenIntegrity -GoldenPath $emptyDir
            $result.Passed | Should -Be $false
        } finally {
            Remove-TempDir $emptyDir
        }
    }

    It 'fails and reports MISSING when a manifest-listed file is deleted' {
        $b2 = New-TempDir; $g2 = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $b2 -Name 'bak01' `
                -DeviceSNs @('TV000000011') -YearMonth '202408'
            $inv2 = Get-BackupInventory -BackupRoot $b2
            $toc2 = Get-BackupTOC -Inventory $inv2
            $gold2 = [string](New-GoldenArchive -TOC $toc2 -GoldenRoot $g2 `
                -Devices @('TV000000011'))

            # Delete one EDF file from the golden
            $edf = Get-ChildItem -LiteralPath (Join-Path $gold2 'TV000000011\Trilogy') `
                -Filter 'AD_*.edf' | Select-Object -First 1
            Remove-Item $edf.FullName -Force

            $result = Test-GoldenIntegrity -GoldenPath $gold2
            $result.Passed   | Should -Be $false
            @($result.Failures | Where-Object { $_ -match 'MISSING' }).Count |
                Should -BeGreaterThan 0
        } finally {
            Remove-TempDir $b2; Remove-TempDir $g2
        }
    }

    It 'fails and reports HASH MISMATCH when a file is tampered after build' {
        $b3 = New-TempDir; $g3 = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $b3 -Name 'bak01' `
                -DeviceSNs @('TV000000012') -YearMonth '202408'
            $inv3 = Get-BackupInventory -BackupRoot $b3
            $toc3 = Get-BackupTOC -Inventory $inv3
            $gold3 = [string](New-GoldenArchive -TOC $toc3 -GoldenRoot $g3 `
                -Devices @('TV000000012'))

            # Overwrite an EDF file with different content (same path, different bytes)
            $edf   = Get-ChildItem -LiteralPath (Join-Path $gold3 'TV000000012\Trilogy') `
                -Filter 'AD_*.edf' | Select-Object -First 1
            $bytes = [System.IO.File]::ReadAllBytes($edf.FullName)
            $bytes[0] = [byte]($bytes[0] -bxor 0xFF)
            [System.IO.File]::WriteAllBytes($edf.FullName, $bytes)

            $result = Test-GoldenIntegrity -GoldenPath $gold3
            $result.Passed | Should -Be $false
            @($result.Failures | Where-Object { $_ -match 'HASH MISMATCH' }).Count |
                Should -BeGreaterThan 0
        } finally {
            Remove-TempDir $b3; Remove-TempDir $g3
        }
    }

    It 'fails and reports SN MISMATCH when an EDF header contains the wrong device serial' {
        $b4 = New-TempDir; $g4 = New-TempDir
        try {
            $snGood  = 'TV000000014'
            $snWrong = 'TV000000099'
            New-SyntheticBackup -BackupRoot $b4 -Name 'bak01' `
                -DeviceSNs @($snGood) -YearMonth '202408'
            $inv4  = Get-BackupInventory -BackupRoot $b4
            $toc4  = Get-BackupTOC -Inventory $inv4
            $gold4 = [string](New-GoldenArchive -TOC $toc4 -GoldenRoot $g4 -Devices @($snGood))

            # Overwrite the Recording ID field (offset 88, 80 bytes) so the EDF header
            # embeds a different SN — then update the manifest hash so only the SN check fails.
            $adPath = Get-ChildItem -LiteralPath (Join-Path $gold4 "$snGood\Trilogy") `
                -Filter 'AD_*.edf' | Select-Object -First 1 -ExpandProperty FullName
            $bytes  = [System.IO.File]::ReadAllBytes($adPath)
            $enc    = [System.Text.Encoding]::ASCII
            $recId  = ("Startdate 01-AUG-2024 X X TGY200 0 $snWrong CA1032800B 65 3.02").PadRight(80).Substring(0, 80)
            [Array]::Copy($enc.GetBytes($recId), 0, $bytes, 88, 80)
            [System.IO.File]::WriteAllBytes($adPath, $bytes)

            $mPath   = Join-Path $gold4 'manifest.json'
            $m       = Get-Content $mPath -Raw | ConvertFrom-Json
            $relKey  = "Trilogy/$((Get-Item $adPath).Name)"
            $newHash = (Get-FileHash -Path $adPath -Algorithm MD5).Hash
            $m.devices.PSObject.Properties[$snGood].Value.fileHashes.PSObject.Properties[$relKey].Value = $newHash
            $m | ConvertTo-Json -Depth 20 | Set-Content $mPath -Encoding UTF8

            $result = Test-GoldenIntegrity -GoldenPath $gold4
            $result.Passed | Should -Be $false
            @($result.Failures | Where-Object { $_ -match 'SN MISMATCH' }).Count | Should -BeGreaterThan 0
        } finally {
            Remove-TempDir $b4; Remove-TempDir $g4
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Update-GoldenArchive — goldenSequence and previousGolden chain' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:sn    = 'TV000000020'

        # Build initial golden (sequence = 1)
        New-SyntheticBackup -BackupRoot $script:bRoot -Name 'bak01' `
            -DeviceSNs @($script:sn) -YearMonth '202408' -EdfBodyBytes 256
        $inv1         = Get-BackupInventory -BackupRoot $script:bRoot
        $toc1         = Get-BackupTOC -Inventory $inv1
        $script:gold1 = [string](New-GoldenArchive -TOC $toc1 -GoldenRoot $script:gRoot `
            -Devices @($script:sn))

        # Add a new backup with different EDF body size so hash changes → forced update
        New-SyntheticBackup -BackupRoot $script:bRoot -Name 'bak02' `
            -DeviceSNs @($script:sn) -YearMonth '202409' -EdfBodyBytes 512
        $inv2         = Get-BackupInventory -BackupRoot $script:bRoot
        $toc2         = Get-BackupTOC -Inventory $inv2
        $script:gold2 = [string](Update-GoldenArchive -TOC $toc2 -GoldenRoot $script:gRoot `
            -PreviousGolden $script:gold1)
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'increments goldenSequence by 1 in the updated manifest' {
        $m1 = Get-Content (Join-Path $script:gold1 'manifest.json') -Raw | ConvertFrom-Json
        $m2 = Get-Content (Join-Path $script:gold2 'manifest.json') -Raw | ConvertFrom-Json
        [int]$m2.goldenSequence | Should -Be ([int]$m1.goldenSequence + 1)
    }

    It 'sets previousGolden field to the path of the previous golden' {
        $m2 = Get-Content (Join-Path $script:gold2 'manifest.json') -Raw | ConvertFrom-Json
        $m2.previousGolden | Should -Be $script:gold1
    }

    It 'initial golden has goldenSequence = 1' {
        $m1 = Get-Content (Join-Path $script:gold1 'manifest.json') -Raw | ConvertFrom-Json
        [int]$m1.goldenSequence | Should -Be 1
    }

    It 'initial golden has previousGolden = null' {
        $m1 = Get-Content (Join-Path $script:gold1 'manifest.json') -Raw | ConvertFrom-Json
        $m1.previousGolden | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — SplitSD file merging from both spans' {

    BeforeAll {
        $script:bRoot = New-TempDir
        $script:gRoot = New-TempDir
        $script:sn    = 'TV000000030'

        # Create two backups for the same device, non-overlapping months
        New-SplitSDBackupPair -BackupRoot $script:bRoot `
            -SN $script:sn `
            -EarlyYearMonth '202401' -LateYearMonth '202408' `
            -EarlyBlowerHours 100    -LateBlowerHours 2000

        $inv        = Get-BackupInventory -BackupRoot $script:bRoot
        $script:toc = Get-BackupTOC -Inventory $inv

        # Annotate split-SD BEFORE building the golden
        Find-SplitSD -TOC $script:toc -SplitGapMonths 2 -BlowerHoursJumpThreshold 1440

        $script:golden = [string](New-GoldenArchive -TOC $script:toc -GoldenRoot $script:gRoot `
            -Devices @($script:sn))
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'includes EDF files from the early span in the golden Trilogy/' {
        $triPath = Join-Path $script:golden "$script:sn\Trilogy"
        $files   = @(Get-ChildItem -LiteralPath $triPath -Filter '*202401*.edf')
        $files.Count | Should -BeGreaterThan 0
    }

    It 'includes EDF files from the late span in the golden Trilogy/' {
        $triPath = Join-Path $script:golden "$script:sn\Trilogy"
        $files   = @(Get-ChildItem -LiteralPath $triPath -Filter '*202408*.edf')
        $files.Count | Should -BeGreaterThan 0
    }

    It 'total Trilogy file count spans both months' {
        $triPath = Join-Path $script:golden "$script:sn\Trilogy"
        $total   = @(Get-ChildItem -LiteralPath $triPath -Filter '*.edf').Count
        # 2 devices * 2 months = at least 4 EDF files (each month has AD + DD pair)
        $total | Should -BeGreaterThan 3
    }

    It 'last.txt in the golden P-Series root points to the correct SN' {
        $lastTxt = Join-Path $script:golden "$script:sn\P-Series\last.txt"
        Test-Path $lastTxt | Should -Be $true
        (Get-Content $lastTxt -Raw).Trim() | Should -Be $script:sn
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive - basic path (no ForceDevices no SplitSD)' {

    BeforeAll {
        $script:bRootB = New-TempDir
        $script:gRootB = New-TempDir
        $script:snB    = 'TV000000040'
        New-SyntheticBackup -BackupRoot $script:bRootB -Name 'bak_basic' `
            -DeviceSNs @($script:snB) -YearMonth '202408'
        $inv          = Get-BackupInventory -BackupRoot $script:bRootB
        $toc          = Get-BackupTOC -Inventory $inv
        $script:goldB = [string](New-GoldenArchive -TOC $toc -GoldenRoot $script:gRootB `
            -Devices @($script:snB))
    }

    AfterAll {
        Remove-TempDir $script:bRootB
        Remove-TempDir $script:gRootB
    }

    It 'returns a path that exists on disk' {
        Test-Path $script:goldB | Should -Be $true
    }

    It 'creates the device Trilogy/ directory with EDF files' {
        $triPath = Join-Path $script:goldB "$script:snB\Trilogy"
        Test-Path $triPath | Should -Be $true
        @(Get-ChildItem -LiteralPath $triPath -Filter '*.edf').Count | Should -BeGreaterThan 0
    }

    It 'creates P-Series/{SN}/ with prop.txt' {
        $propPath = Join-Path $script:goldB "$script:snB\P-Series\$script:snB\prop.txt"
        Test-Path $propPath | Should -Be $true
    }

    It 'creates P-Series/{SN}/ with FILES.SEQ' {
        $seqPath = Join-Path $script:goldB "$script:snB\P-Series\$script:snB\FILES.SEQ"
        Test-Path $seqPath | Should -Be $true
    }

    It 'manifest.json has version=1 and goldenSequence=1' {
        $manifest = Get-Content (Join-Path $script:goldB 'manifest.json') -Raw | ConvertFrom-Json
        [int]$manifest.version       | Should -Be 1
        [int]$manifest.goldenSequence | Should -Be 1
    }

    It 'manifest.json lists the device SN under devices' {
        $manifest = Get-Content (Join-Path $script:goldB 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.devices.PSObject.Properties.Name | Should -Contain $script:snB
    }

    It 'manifest device entry has non-zero trilogyFileCount' {
        $manifest = Get-Content (Join-Path $script:goldB 'manifest.json') -Raw | ConvertFrom-Json
        [int]$manifest.devices.$($script:snB).trilogyFileCount | Should -BeGreaterThan 0
    }

    It 'manifest device entry has non-zero pSeriesFileCount' {
        $manifest = Get-Content (Join-Path $script:goldB 'manifest.json') -Raw | ConvertFrom-Json
        [int]$manifest.devices.$($script:snB).pSeriesFileCount | Should -BeGreaterThan 0
    }
}

# ---------------------------------------------------------------------------
Describe 'Update-GoldenArchive - changed-data detection' {

    BeforeAll {
        $script:bRootC = New-TempDir
        $script:gRootC = New-TempDir
        $script:snC1   = 'TV000000050'
        $script:snC2   = 'TV000000051'

        # Initial backup: both devices, 256-byte EDF body
        New-SyntheticBackup -BackupRoot $script:bRootC -Name 'bak_v1' `
            -DeviceSNs @($script:snC1, $script:snC2) -YearMonth '202408' -EdfBodyBytes 256
        $inv1          = Get-BackupInventory -BackupRoot $script:bRootC
        $toc1          = Get-BackupTOC -Inventory $inv1
        $script:goldC1 = [string](New-GoldenArchive -TOC $toc1 -GoldenRoot $script:gRootC `
            -Devices @($script:snC1, $script:snC2))

        # Second backup: snC1 gets LARGER EDF (new data), snC2 not present here
        New-SyntheticBackup -BackupRoot $script:bRootC -Name 'bak_v2' `
            -DeviceSNs @($script:snC1) -YearMonth '202409' -EdfBodyBytes 512
        $inv2          = Get-BackupInventory -BackupRoot $script:bRootC
        $script:toc2   = Get-BackupTOC -Inventory $inv2
        $script:goldC2 = [string](Update-GoldenArchive -TOC $script:toc2 `
            -GoldenRoot $script:gRootC -PreviousGolden $script:goldC1)
    }

    AfterAll {
        Remove-TempDir $script:bRootC
        Remove-TempDir $script:gRootC
    }

    It 'creates a new golden (different path) when a device has new data' {
        $script:goldC2 | Should -Not -Be $script:goldC1
        Test-Path $script:goldC2 | Should -Be $true
    }

    It 'new golden manifest includes the changed device (snC1)' {
        $m2 = Get-Content (Join-Path $script:goldC2 'manifest.json') -Raw | ConvertFrom-Json
        $m2.devices.PSObject.Properties.Name | Should -Contain $script:snC1
    }

    It 'new golden manifest does NOT include the unchanged device (snC2)' {
        $m2 = Get-Content (Join-Path $script:goldC2 'manifest.json') -Raw | ConvertFrom-Json
        $m2.devices.PSObject.Properties.Name | Should -Not -Contain $script:snC2
    }

    It 'includes a brand-new device not present in the previous golden' {
        $snNew = 'TV000000052'
        New-SyntheticBackup -BackupRoot $script:bRootC -Name 'bak_v3' `
            -DeviceSNs @($snNew) -YearMonth '202501'
        $inv3  = Get-BackupInventory -BackupRoot $script:bRootC
        $toc3  = Get-BackupTOC -Inventory $inv3
        $gold3 = [string](Update-GoldenArchive -TOC $toc3 -GoldenRoot $script:gRootC `
            -PreviousGolden $script:goldC2)
        $m3 = Get-Content (Join-Path $gold3 'manifest.json') -Raw | ConvertFrom-Json
        $m3.devices.PSObject.Properties.Name | Should -Contain $snNew
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenIntegrity - corrupt manifest schema' {

    It 'fails when manifest.json exists but has no devices property' {
        $b = New-TempDir
        $g = New-TempDir
        try {
            # Write a minimal manifest that is valid JSON but missing the devices key
            $badManifest = '{"version":1,"goldenSequence":1,"created":"2024-01-01T00:00:00Z"}'
            Set-Content (Join-Path $g 'manifest.json') $badManifest -Encoding UTF8

            $result = Test-GoldenIntegrity -GoldenPath $g
            # Without a devices section the integrity check cannot verify any files
            # It should either fail or pass with 0 files — both are acceptable.
            # The key requirement: it must NOT throw an unhandled exception.
            $result | Should -Not -BeNullOrEmpty
        } finally {
            Remove-TempDir $b
            Remove-TempDir $g
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-GoldenContent - 512-byte EDF header variant' {

    BeforeAll {
        $script:bRoot512 = New-TempDir
        $script:gRoot512 = New-TempDir
        $script:sn512    = 'TV512000001'

        # Build a standard backup, then overwrite its EDF files with 512-byte headers
        # (extended EDF+ variant seen on newer Trilogy firmware generations).
        New-SyntheticBackup -BackupRoot $script:bRoot512 -Name 'bak_512hdr' `
            -DeviceSNs @($script:sn512) -YearMonth '202401'
        $triDir512 = Join-Path $script:bRoot512 "bak_512hdr\Trilogy"
        Get-ChildItem -LiteralPath $triDir512 -Filter '*.edf' | ForEach-Object {
            New-SyntheticEdf -Path $_.FullName -SN $script:sn512 -HeaderBytesValue 512
        }

        $inv512            = Get-BackupInventory -BackupRoot $script:bRoot512
        $toc512            = Get-BackupTOC -Inventory $inv512
        $script:golden512  = [string](New-GoldenArchive -TOC $toc512 `
            -GoldenRoot $script:gRoot512 -Devices @($script:sn512))
    }

    AfterAll {
        Remove-TempDir $script:bRoot512
        Remove-TempDir $script:gRoot512
    }

    It 'reports no EdfFormat HeaderBytes errors for 512-byte header files' {
        $result = Test-GoldenContent -GoldenPath $script:golden512
        $hdrErrors = @($result.Issues | Where-Object {
            $_.Category -eq 'EdfFormat' -and $_.Message -like '*HeaderBytes*'
        })
        $hdrErrors | Should -HaveCount 0
    }

    It 'still flags non-multiple-of-256 HeaderBytes value (300) as an error' {
        $root300 = New-TempDir
        $g300    = New-TempDir
        $sn300   = 'TV300000001'
        try {
            New-SyntheticBackup -BackupRoot $root300 -Name 'bak_300' `
                -DeviceSNs @($sn300) -YearMonth '202401'
            $triDir300 = Join-Path $root300 "bak_300\Trilogy"
            Get-ChildItem -LiteralPath $triDir300 -Filter '*.edf' | ForEach-Object {
                # 300 is not a multiple of 256 — clearly invalid per EDF spec
                New-SyntheticEdf -Path $_.FullName -SN $sn300 -HeaderBytesValue 300
            }
            $inv300   = Get-BackupInventory -BackupRoot $root300
            $toc300   = Get-BackupTOC -Inventory $inv300
            $g300Path = [string](New-GoldenArchive -TOC $toc300 `
                -GoldenRoot $g300 -Devices @($sn300))
            $result300  = Test-GoldenContent -GoldenPath $g300Path
            $hdrErrors2 = @($result300.Issues | Where-Object {
                $_.Category -eq 'EdfFormat' -and $_.Message -like '*HeaderBytes*'
            })
            $hdrErrors2.Count | Should -BeGreaterThan 0
        } finally {
            Remove-TempDir $root300
            Remove-TempDir $g300
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — Rewind: orphaned Trilogy pairs' {

    BeforeAll {
        $script:bRootRw = New-TempDir
        $script:gRootRw = New-TempDir
        $script:snRw    = 'TV990001001'

        # Backup with a complete AD+DD pair for month 202409 (survives rewind)
        # plus orphaned AD for 202408, a WD for 202408, and an EL_ for 202408.
        # The orphaned AD_202408 + WD_202408 + EL_202408 must all be dropped by rewind.
        $bPath = New-SyntheticBackup -BackupRoot $script:bRootRw -Name 'bak_orphan' `
            -DeviceSNs @($script:snRw) -YearMonth '202409'

        # Orphaned AD for 202408 — no matching DD
        New-SyntheticEdf -Path (Join-Path $bPath 'Trilogy\AD_202408_000.edf') -SN $script:snRw
        # WD file for 202408 — month has no complete pair
        New-SyntheticEdf -Path (Join-Path $bPath 'Trilogy\WD_20240823_000.edf') -SN $script:snRw
        # EL_ CSV for 202408 — month has no complete pair
        Set-Content (Join-Path $bPath "Trilogy\EL_$($script:snRw)_20240823.csv") `
            "SN=$($script:snRw)" -Encoding UTF8

        $inv               = Get-BackupInventory -BackupRoot $script:bRootRw
        $toc               = Get-BackupTOC -Inventory $inv
        $script:goldRw     = [string](New-GoldenArchive -TOC $toc `
            -GoldenRoot $script:gRootRw -Devices @($script:snRw))
    }

    AfterAll {
        Remove-TempDir $script:bRootRw
        Remove-TempDir $script:gRootRw
    }

    It 'drops orphaned AD_202408 (no matching DD) from the golden Trilogy/' {
        $triPath = Join-Path $script:goldRw "$($script:snRw)\Trilogy"
        Test-Path (Join-Path $triPath 'AD_202408_000.edf') | Should -Be $false
    }

    It 'keeps the complete AD+DD pair for month 202409' {
        $triPath = Join-Path $script:goldRw "$($script:snRw)\Trilogy"
        @(Get-ChildItem -LiteralPath $triPath -Filter 'AD_202409_*.edf').Count | Should -BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $triPath -Filter 'DD_202409_*.edf').Count | Should -BeGreaterThan 0
    }

    It 'drops WD file whose month (202408) has no complete AD+DD pair' {
        $triPath = Join-Path $script:goldRw "$($script:snRw)\Trilogy"
        @(Get-ChildItem -LiteralPath $triPath -Filter 'WD_202408*.edf').Count | Should -Be 0
    }

    It 'drops EL_ CSV whose month (202408) has no complete AD+DD pair' {
        $triPath = Join-Path $script:goldRw "$($script:snRw)\Trilogy"
        @(Get-ChildItem -LiteralPath $triPath -Filter 'EL_*_202408*.csv').Count | Should -Be 0
    }

    It 'records DroppedOrphan events in manifest rewindLog for the orphaned files' {
        $manifest = Get-Content (Join-Path $script:goldRw 'manifest.json') -Raw | ConvertFrom-Json
        $log      = @($manifest.devices.$($script:snRw).rewindLog |
                      Where-Object { $_.Action -eq 'DroppedOrphan' })
        $log.Count | Should -BeGreaterThan 0
    }

    It 'manifest rewindLog contains a DroppedOrphan entry mentioning the EL_ file' {
        $manifest = Get-Content (Join-Path $script:goldRw 'manifest.json') -Raw | ConvertFrom-Json
        $elEntry  = @($manifest.devices.$($script:snRw).rewindLog |
                      Where-Object { $_.Action -eq 'DroppedOrphan' -and $_.File -match 'EL_' })
        $elEntry.Count | Should -BeGreaterThan 0
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — Rewind: orphaned DD (no matching AD)' {

    It 'drops orphaned DD file and records DroppedOrphan in rewindLog' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn    = 'TV990001002'
            $bPath = New-SyntheticBackup -BackupRoot $b -Name 'bak_orphanDD' `
                -DeviceSNs @($sn) -YearMonth '202409'
            # Add orphaned DD for 202408 (no matching AD for that month)
            New-SyntheticEdf -Path (Join-Path $bPath 'Trilogy\DD_202408_000.edf') -SN $sn

            $inv  = Get-BackupInventory -BackupRoot $b
            $toc  = Get-BackupTOC -Inventory $inv
            $gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $g -Devices @($sn))

            # Orphaned DD must not be present
            $triPath = Join-Path $gold "$sn\Trilogy"
            Test-Path (Join-Path $triPath 'DD_202408_000.edf') | Should -Be $false

            # rewindLog must have DroppedOrphan
            $manifest = Get-Content (Join-Path $gold 'manifest.json') -Raw | ConvertFrom-Json
            $dropped  = @($manifest.devices.$sn.rewindLog |
                          Where-Object { $_.Action -eq 'DroppedOrphan' -and $_.File -match 'DD_202408' })
            $dropped.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — Rewind: P-Series consistency' {

    It 'falls back to valid SL_SAPPHIRE.json when newest version is invalid JSON' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn = 'TV990002001'

            # Backup 1 (older): valid SL_SAPPHIRE.json
            New-SyntheticBackup -BackupRoot $b -Name 'bak_sl_old' `
                -DeviceSNs @($sn) -YearMonth '202408'

            # Backup 2 (newer, EDF is larger): invalid SL_SAPPHIRE.json
            New-SyntheticBackup -BackupRoot $b -Name 'bak_sl_new' `
                -DeviceSNs @($sn) -YearMonth '202409' -EdfBodyBytes 512
            # Make the invalid SL_SAPPHIRE.json larger than the valid one so "largest wins"
            # selects it during _GatherPSeriesFiles
            $slPath = Join-Path $b "bak_sl_new\P-Series\$sn\SL_SAPPHIRE.json"
            Set-Content $slPath ('THIS IS NOT JSON ' + ('X' * 20)) -Encoding UTF8

            $inv  = Get-BackupInventory -BackupRoot $b
            $toc  = Get-BackupTOC -Inventory $inv
            $gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $g -Devices @($sn))

            # Golden SL_SAPPHIRE.json must start with '{' (valid JSON object start)
            $slGolden = Join-Path $gold "$sn\P-Series\$sn\SL_SAPPHIRE.json"
            Test-Path $slGolden | Should -Be $true
            (Get-Content $slGolden -Raw).Trim()[0] | Should -Be '{'

            # rewindLog must have ReplacedInvalid for SL_SAPPHIRE.json
            $manifest = Get-Content (Join-Path $gold 'manifest.json') -Raw | ConvertFrom-Json
            $entry    = @($manifest.devices.$sn.rewindLog | Where-Object {
                $_.Action -eq 'ReplacedInvalid' -and $_.File -match 'SL_SAPPHIRE'
            })
            $entry.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    It 'falls back to valid prop.txt when newest version has wrong SN= and records ReplacedInvalid' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn = 'TV990002002'

            # Backup 1 (older): valid prop.txt with correct SN
            New-SyntheticBackup -BackupRoot $b -Name 'bak_prop_old' `
                -DeviceSNs @($sn) -YearMonth '202408'

            # Backup 2 (newer): prop.txt with wrong SN but larger so it wins gather
            New-SyntheticBackup -BackupRoot $b -Name 'bak_prop_new' `
                -DeviceSNs @($sn) -YearMonth '202409' -EdfBodyBytes 512
            $propPath = Join-Path $b "bak_prop_new\P-Series\$sn\prop.txt"
            Set-Content $propPath "SN=TVWRONGWRONG`nMN=Trilogy 200`nPT=0x65`nSV=3.02`nXX=padding_makes_it_larger" `
                -Encoding UTF8

            $inv  = Get-BackupInventory -BackupRoot $b
            $toc  = Get-BackupTOC -Inventory $inv
            $gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $g -Devices @($sn))

            # Golden prop.txt must have the correct SN
            $propGolden = Join-Path $gold "$sn\P-Series\$sn\prop.txt"
            $snLine     = (Get-Content $propGolden) | Where-Object { $_ -match '^SN\s*=' } |
                          Select-Object -First 1
            ($snLine -split '=', 2)[1].Trim() | Should -Be $sn

            # rewindLog must have ReplacedInvalid for prop.txt
            $manifest = Get-Content (Join-Path $gold 'manifest.json') -Raw | ConvertFrom-Json
            $entry    = @($manifest.devices.$sn.rewindLog | Where-Object {
                $_.Action -eq 'ReplacedInvalid' -and $_.File -match 'prop\.txt'
            })
            $entry.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    It 'drops PP JSON ring-buffer entry when its month has no committed AD+DD pair' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn      = 'TV990002003'
            $ymGood  = '202409'   # complete AD+DD pair → month committed
            $ymBad   = '202408'   # orphaned AD only → month NOT committed → PP files must be dropped

            # Base backup: complete pair for 202409 (sets CompleteMonths = {'202409'})
            $bPath = New-SyntheticBackup -BackupRoot $b -Name 'bak_pp_orphan' `
                -DeviceSNs @($sn) -YearMonth $ymGood

            # Orphaned AD for 202408 (no matching DD for that month)
            New-SyntheticEdf -Path (Join-Path $bPath "Trilogy\AD_${ymBad}_000.edf") -SN $sn

            # PP JSON files for 202408 injected directly into each ring slot
            for ($p = 0; $p -le 7; $p++) {
                $ringDir = Join-Path $bPath "P-Series\$sn\P$p"
                $null    = New-Item -ItemType Directory -Path $ringDir -Force -ErrorAction SilentlyContinue
                Set-Content (Join-Path $ringDir "PP_20240823_00${p}.json") `
                    "{`"SN`":`"$sn`",`"TimeStamp`":1700000000,`"BlowerHours`":1000}" -Encoding UTF8
            }

            $inv  = Get-BackupInventory -BackupRoot $b
            $toc  = Get-BackupTOC -Inventory $inv
            $gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $g -Devices @($sn))

            # PP JSON for month 202408 must be absent (month has no committed pair)
            $psSnDir = Join-Path $gold "$sn\P-Series\$sn"
            $ppBad   = @(Get-ChildItem -LiteralPath $psSnDir -Filter "PP_${ymBad}*.json" `
                -Recurse -ErrorAction SilentlyContinue)
            $ppBad.Count | Should -Be 0

            # PP JSON for month 202409 must be present (complete pair exists)
            $ppGood  = @(Get-ChildItem -LiteralPath $psSnDir -Filter "PP_${ymGood}*.json" `
                -Recurse -ErrorAction SilentlyContinue)
            $ppGood.Count | Should -BeGreaterThan 0

            # rewindLog must have DroppedOrphan for the 202408 PP files
            $manifest = Get-Content (Join-Path $gold 'manifest.json') -Raw | ConvertFrom-Json
            $entry    = @($manifest.devices.$sn.rewindLog | Where-Object {
                $_.Action -eq 'DroppedOrphan' -and $_.File -match 'PP_'
            })
            $entry.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }

    It 'drops SL_SAPPHIRE.json from golden and records DroppedInvalid when no valid version exists in any backup' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn    = 'TV990002004'
            $bPath = New-SyntheticBackup -BackupRoot $b -Name 'bak_only' `
                -DeviceSNs @($sn) -YearMonth '202408'
            # Overwrite SL_SAPPHIRE.json with invalid JSON in the only (and only) backup
            Set-Content (Join-Path $bPath "P-Series\$sn\SL_SAPPHIRE.json") 'NOT VALID JSON' `
                -Encoding UTF8

            $inv  = Get-BackupInventory -BackupRoot $b
            $toc  = Get-BackupTOC -Inventory $inv
            $gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $g -Devices @($sn))

            # SL_SAPPHIRE.json must be absent when no valid fallback exists
            $slPath = Join-Path $gold "$sn\P-Series\$sn\SL_SAPPHIRE.json"
            Test-Path $slPath | Should -Be $false

            # rewindLog must record DroppedInvalid (not ReplacedInvalid)
            $manifest = Get-Content (Join-Path $gold 'manifest.json') -Raw | ConvertFrom-Json
            $entry    = @($manifest.devices.$sn.rewindLog | Where-Object {
                $_.Action -eq 'DroppedInvalid' -and $_.File -match 'SL_SAPPHIRE'
            })
            $entry.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — Rewind: manifest rewindLog field' {

    It 'manifest device entry has rewindLog array empty for a fully clean device' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn = 'TV990003001'
            New-SyntheticBackup -BackupRoot $b -Name 'bk_clean' `
                -DeviceSNs @($sn) -YearMonth '202408'
            $inv  = Get-BackupInventory -BackupRoot $b
            $toc  = Get-BackupTOC -Inventory $inv
            $gold = [string](New-GoldenArchive -TOC $toc -GoldenRoot $g -Devices @($sn))

            $manifest = Get-Content (Join-Path $gold 'manifest.json') -Raw | ConvertFrom-Json
            # The rewindLog field must exist on the device entry
            $manifest.devices.$sn.PSObject.Properties['rewindLog'] | Should -Not -BeNullOrEmpty
            # A fully clean device must produce zero rewind events
            @($manifest.devices.$sn.rewindLog).Count | Should -Be 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }
}

# ---------------------------------------------------------------------------
Describe 'Update-GoldenArchive — Rewind: rewindLog recorded in updated golden' {

    It 'records DroppedOrphan in manifest rewindLog when update detects orphaned EDF pairs' {
        $b = New-TempDir; $g = New-TempDir
        try {
            $sn = 'TV990005001'
            # Build initial golden with a complete 202408 pair
            New-SyntheticBackup -BackupRoot $b -Name 'bak_v1' `
                -DeviceSNs @($sn) -YearMonth '202408'
            $inv1  = Get-BackupInventory -BackupRoot $b
            $toc1  = Get-BackupTOC -Inventory $inv1
            $gold1 = [string](New-GoldenArchive -TOC $toc1 -GoldenRoot $g -Devices @($sn))

            # Add a second backup: complete 202409 pair (larger EDF → change detected by Update)
            # plus an orphaned AD_202410 (no matching DD) that triggers a DroppedOrphan event
            $bPath2 = New-SyntheticBackup -BackupRoot $b -Name 'bak_v2' `
                -DeviceSNs @($sn) -YearMonth '202409' -EdfBodyBytes 512
            New-SyntheticEdf -Path (Join-Path $bPath2 "Trilogy\AD_202410_000.edf") -SN $sn

            $inv2  = Get-BackupInventory -BackupRoot $b
            $toc2  = Get-BackupTOC -Inventory $inv2
            $gold2 = [string](Update-GoldenArchive -TOC $toc2 -GoldenRoot $g -PreviousGolden $gold1)

            $manifest = Get-Content (Join-Path $gold2 'manifest.json') -Raw | ConvertFrom-Json
            $entry    = @($manifest.devices.$sn.rewindLog | Where-Object { $_.Action -eq 'DroppedOrphan' })
            $entry.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $b; Remove-TempDir $g }
    }
}

# ---------------------------------------------------------------------------
Describe 'New-GoldenArchive — Salvage from contaminated backup' {

    BeforeAll {
        $script:bRootSv = New-TempDir
        $script:gRootSv = New-TempDir
        $script:snA     = 'TV990004001'   # device present in a clean backup
        $script:snB     = 'TV990004002'   # device ONLY in a contaminated backup

        # Clean base backup: device A only
        New-SyntheticBackup -BackupRoot $script:bRootSv -Name 'bak_base' `
            -DeviceSNs @($script:snA) -YearMonth '202408'

        # Contaminated .001 variant: device A + device B
        # Get-BackupTOC flags this as Contaminated because snB is absent from bak_base
        New-SyntheticBackup -BackupRoot $script:bRootSv -Name 'bak_base.001' `
            -DeviceSNs @($script:snA, $script:snB) -YearMonth '202408'

        $inv            = Get-BackupInventory -BackupRoot $script:bRootSv
        $script:tocSv   = Get-BackupTOC -Inventory $inv
        # Let algorithm pick all devices automatically
        # snB is in TOC.Devices even though it only appears in the contaminated backup
        $script:goldSv  = [string](New-GoldenArchive -TOC $script:tocSv `
            -GoldenRoot $script:gRootSv)
    }

    AfterAll {
        Remove-TempDir $script:bRootSv
        Remove-TempDir $script:gRootSv
    }

    It 'test precondition: bak_base.001 is marked Contaminated by the TOC' {
        $script:tocSv.Backups['bak_base.001'].Integrity | Should -Be 'Contaminated'
    }

    It 'includes device B in the golden despite its only source being a contaminated backup' {
        Test-Path (Join-Path $script:goldSv $script:snB) | Should -Be $true
    }

    It 'includes Trilogy EDF files for device B salvaged from contaminated backup' {
        $triPath = Join-Path $script:goldSv "$($script:snB)\Trilogy"
        Test-Path $triPath | Should -Be $true
        @(Get-ChildItem -LiteralPath $triPath -Filter '*.edf').Count | Should -BeGreaterThan 0
    }

    It 'includes P-Series prop.txt for device B salvaged from contaminated backup' {
        $propPath = Join-Path $script:goldSv "$($script:snB)\P-Series\$($script:snB)\prop.txt"
        Test-Path $propPath | Should -Be $true
    }

    It 'records SalvagedFromContaminated in manifest rewindLog for device B' {
        $manifest = Get-Content (Join-Path $script:goldSv 'manifest.json') -Raw | ConvertFrom-Json
        $log      = @($manifest.devices.$($script:snB).rewindLog | Where-Object {
            $_.Action -eq 'SalvagedFromContaminated'
        })
        $log.Count | Should -BeGreaterThan 0
    }

    It 'device A (from clean backup) has no SalvagedFromContaminated events' {
        $manifest = Get-Content (Join-Path $script:goldSv 'manifest.json') -Raw | ConvertFrom-Json
        $log      = @($manifest.devices.$($script:snA).rewindLog | Where-Object {
            $_.Action -eq 'SalvagedFromContaminated'
        })
        $log.Count | Should -Be 0
    }

    It 'includes PP JSON ring-buffer files for device B salvaged from contaminated backup' {
        $psSnDir = Join-Path $script:goldSv "$($script:snB)\P-Series\$($script:snB)"
        $ppFiles = @(Get-ChildItem -LiteralPath $psSnDir -Filter 'PP_*.json' `
            -Recurse -ErrorAction SilentlyContinue)
        $ppFiles.Count | Should -BeGreaterThan 0
    }

    It 'Test-GoldenContent reports no Critical or Error issues for the salvaged golden' {
        $result = Test-GoldenContent -GoldenPath $script:goldSv
        $result.CriticalCount | Should -Be 0
        $result.ErrorCount    | Should -Be 0
    }
}
