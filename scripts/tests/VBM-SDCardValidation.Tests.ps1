#Requires -Version 5.1
# VBM-SDCardValidation.Tests.ps1 — Pester 5 tests for SD card validation.
# Tests export → corrupt → validate cycle to ensure tampered files are detected.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')       -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1')      -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-GoldenArchive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Export.psm1')        -Force

    # Helper: build a golden and export it, return both paths.
    function New-ExportedSD {
        param(
            [string]$BackupRoot,
            [string]$GoldenRoot,
            [string]$Target,
            [string[]]$SNs = @('TV900000001'),
            [string]$YearMonth = '202408'
        )
        foreach ($sn in $SNs) {
            $null = New-SyntheticBackup -BackupRoot $BackupRoot -Name "bak_$sn" `
                -DeviceSNs @($sn) -YearMonth $YearMonth -EdfBodyBytes 256
        }
        $inv = Get-BackupInventory -BackupRoot $BackupRoot
        $toc = Get-BackupTOC -Inventory $inv
        $goldenPath = [string](New-GoldenArchive -TOC $toc -GoldenRoot $GoldenRoot -Devices $SNs)
        Export-ToTarget -GoldenPath $goldenPath -Target $Target
        return $goldenPath
    }

    # Helper: corrupt a random file in a directory tree by flipping bytes.
    function Invoke-CorruptRandomFile {
        param([string]$Root, [string]$Filter = '*')
        $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Filter $Filter |
            Where-Object { $_.Name -ne 'last.txt' -and $_.Name -ne 'README.md' })
        if ($files.Count -eq 0) { throw "No files found to corrupt in $Root" }
        $victim = $files | Get-Random
        $bytes  = [System.IO.File]::ReadAllBytes($victim.FullName)
        # Flip several bytes at random positions
        $rng = [System.Random]::new()
        for ($i = 0; $i -lt [Math]::Min(8, $bytes.Length); $i++) {
            $pos = $rng.Next(0, $bytes.Length)
            $bytes[$pos] = $bytes[$pos] -bxor 0xFF
        }
        [System.IO.File]::WriteAllBytes($victim.FullName, $bytes)
        return $victim.FullName
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — single-device native layout, clean export' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000001'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'passes validation for an untampered native-layout export' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $true
        $result.DetectedLayout | Should -Be 'native'
        $result.FileCount | Should -BeGreaterThan 0
    }

    It 'detects the correct device SN' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.DetectedDevices | Should -Contain $script:sn
    }

    It 'reports zero mismatches for clean export' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Mismatches.Count | Should -Be 0
        $result.ExtraOnCard.Count | Should -Be 0
        $result.MissingFromCard.Count | Should -Be 0
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — single-device, corrupted Trilogy EDF' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000010'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
        # Corrupt a Trilogy EDF file
        $script:corruptedFile = Invoke-CorruptRandomFile -Root (Join-Path $script:sdCard 'Trilogy') -Filter '*.edf'
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'fails validation when a Trilogy EDF is corrupted' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'reports the corrupted file in Mismatches' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Mismatches.Count | Should -BeGreaterThan 0
        # The corrupted filename should appear in at least one mismatch entry
        $corruptName = [System.IO.Path]::GetFileName($script:corruptedFile)
        ($result.Mismatches | Where-Object { $_ -match [regex]::Escape($corruptName) }).Count |
            Should -BeGreaterThan 0
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — single-device, corrupted P-Series file' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000011'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
        # Corrupt a P-Series file
        $script:corruptedFile = Invoke-CorruptRandomFile -Root (Join-Path $script:sdCard 'P-Series')
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'fails validation when a P-Series file is corrupted' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'identifies the corrupted P-Series file' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Mismatches.Count | Should -BeGreaterThan 0
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — single-device, multiple corrupted files' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000012'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
        # Corrupt two different files
        $script:corrupt1 = Invoke-CorruptRandomFile -Root (Join-Path $script:sdCard 'Trilogy') -Filter '*.edf'
        $script:corrupt2 = Invoke-CorruptRandomFile -Root (Join-Path $script:sdCard 'P-Series')
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'detects all corrupted files when multiple are tampered' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $false
        $result.Mismatches.Count | Should -BeGreaterOrEqual 2
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — single-device, file deleted from SD' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000013'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
        # Delete a Trilogy EDF
        $victim = Get-ChildItem -LiteralPath (Join-Path $script:sdCard 'Trilogy') -Filter '*.edf' | Select-Object -First 1
        Remove-Item $victim.FullName -Force
        $script:deletedName = $victim.Name
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'fails validation when a file is missing from the SD card' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'reports the missing file in MissingFromCard' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.MissingFromCard.Count | Should -BeGreaterThan 0
        ($result.MissingFromCard | Where-Object { $_ -match [regex]::Escape($script:deletedName) }).Count |
            Should -BeGreaterThan 0
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — multi-device layout, clean export' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sns    = @('TV900000020', 'TV900000021')
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs $script:sns
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'passes validation for an untampered multi-device export' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $true
        $result.DetectedLayout | Should -Be 'multi-device'
    }

    It 'detects both devices' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        foreach ($sn in $script:sns) {
            $result.DetectedDevices | Should -Contain $sn
        }
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — multi-device layout, one device corrupted' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sns    = @('TV900000030', 'TV900000031')
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs $script:sns
        # Corrupt a file in the second device's Trilogy
        $dev2Trilogy = Join-Path $script:sdCard "$($script:sns[1])\Trilogy"
        $script:corruptedFile = Invoke-CorruptRandomFile -Root $dev2Trilogy -Filter '*.edf'
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'fails validation when one device has a corrupted file' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'reports corruption only for the tampered device file' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Mismatches.Count | Should -Be 1
        $corruptName = [System.IO.Path]::GetFileName($script:corruptedFile)
        $escapedName = [regex]::Escape($corruptName)
        $escapedSN   = [regex]::Escape($script:sns[1])
        $result.Mismatches[0] | Should -Match $escapedName
        $result.Mismatches[0] | Should -Match $escapedSN
    }
}

# ===========================================================================
Describe 'Find-MatchingGolden — auto-discovery' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000040'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'auto-discovers the correct golden from search paths' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -SearchPaths @($script:gRoot)
        $result.Passed | Should -Be $true
        $result.AutoDiscovered | Should -Be $true
        $result.ReferenceGolden | Should -Be $script:golden
    }

    It 'does not match an unrelated golden' {
        # Create a second golden with a different device
        $b2 = New-TempDir; $g2 = New-TempDir; $t2 = New-TempDir
        try {
            $null = New-ExportedSD -BackupRoot $b2 -GoldenRoot $g2 `
                -Target $t2 -SNs @('TV900000099')
            # Search only in g2 — should not match our SD card
            $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
                -SearchPaths @($g2)
            $result.Passed | Should -Be $false
            $result.ReferenceGolden | Should -BeNullOrEmpty
        } finally {
            Remove-TempDir $b2; Remove-TempDir $g2; Remove-TempDir $t2
        }
    }
}

# ===========================================================================
Describe 'Find-MatchingGolden — partial match for deep diff' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000050'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
        # Corrupt files to break exact match
        Invoke-CorruptRandomFile -Root (Join-Path $script:sdCard 'Trilogy') -Filter '*.edf'
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'still finds the golden via partial match when files are corrupted' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -SearchPaths @($script:gRoot)
        # Should find the golden (partial match) and report differences
        $result.ReferenceGolden | Should -Not -BeNullOrEmpty
        $result.Passed | Should -Be $false
        $result.Mismatches.Count | Should -BeGreaterThan 0
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — extra file added to SD card' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000060'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
        # Add an unexpected file to the Trilogy directory
        Set-Content (Join-Path $script:sdCard 'Trilogy\INJECTED_202408_000.edf') 'malicious content' -Encoding UTF8
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'fails validation when extra files are present on the SD card' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'reports the injected file in ExtraOnCard' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        $result.ExtraOnCard.Count | Should -BeGreaterThan 0
        ($result.ExtraOnCard | Where-Object { $_ -match 'INJECTED' }).Count |
            Should -BeGreaterThan 0
    }
}

# ===========================================================================
# MODE B — _ValidateWithManifest path (manifest.json present at target)
# ===========================================================================

Describe 'Test-SDCardIntegrity — Mode B: clean golden passes manifest validation' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sn     = 'TV900000070'
        # Build a golden archive (it has a manifest.json)
        $null = New-SyntheticBackup -BackupRoot $script:bRoot -Name "bak_$($script:sn)" `
            -DeviceSNs @($script:sn) -YearMonth '202408' -EdfBodyBytes 256
        $inv = Get-BackupInventory -BackupRoot $script:bRoot
        $toc = Get-BackupTOC -Inventory $inv
        $script:golden = [string](New-GoldenArchive -TOC $toc -GoldenRoot $script:gRoot -Devices @($script:sn))
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'selects Mode B when manifest.json is present at the target' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.Passed | Should -Be $true
        # Mode B self-references as its own golden
        $result.ReferenceGolden | Should -Be $script:golden
    }

    It 'reports correct file count from manifest' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.FileCount | Should -BeGreaterThan 0
    }

    It 'detects the device SN' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.DetectedDevices | Should -Contain $script:sn
    }

    It 'reports zero mismatches for an intact golden' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.Mismatches.Count | Should -Be 0
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — Mode B: corrupted file detected via manifest' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sn     = 'TV900000071'
        $null = New-SyntheticBackup -BackupRoot $script:bRoot -Name "bak_$($script:sn)" `
            -DeviceSNs @($script:sn) -YearMonth '202408' -EdfBodyBytes 256
        $inv = Get-BackupInventory -BackupRoot $script:bRoot
        $toc = Get-BackupTOC -Inventory $inv
        $script:golden = [string](New-GoldenArchive -TOC $toc -GoldenRoot $script:gRoot -Devices @($script:sn))
        # Corrupt a Trilogy EDF inside the golden
        $script:corruptedFile = Invoke-CorruptRandomFile -Root (Join-Path $script:golden 'Trilogy') -Filter '*.edf'
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'fails Mode B validation when a file is corrupted' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'reports the corrupted file as CORRUPTED in Mismatches' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.Mismatches.Count | Should -BeGreaterThan 0
        $corruptName = [System.IO.Path]::GetFileName($script:corruptedFile)
        $escapedName = [regex]::Escape($corruptName)
        ($result.Mismatches | Where-Object { $_ -match $escapedName }).Count |
            Should -BeGreaterThan 0
        $result.Mismatches[0] | Should -Match 'CORRUPTED'
    }
}

# ===========================================================================
Describe 'Test-SDCardIntegrity — Mode B: missing file detected via manifest' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sn     = 'TV900000072'
        $null = New-SyntheticBackup -BackupRoot $script:bRoot -Name "bak_$($script:sn)" `
            -DeviceSNs @($script:sn) -YearMonth '202408' -EdfBodyBytes 256
        $inv = Get-BackupInventory -BackupRoot $script:bRoot
        $toc = Get-BackupTOC -Inventory $inv
        $script:golden = [string](New-GoldenArchive -TOC $toc -GoldenRoot $script:gRoot -Devices @($script:sn))
        # Delete a file that the manifest expects
        $victim = Get-ChildItem -LiteralPath (Join-Path $script:golden 'Trilogy') -Filter '*.edf' | Select-Object -First 1
        Remove-Item $victim.FullName -Force
        $script:deletedName = $victim.Name
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
    }

    It 'fails Mode B validation when a manifest-listed file is missing' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.Passed | Should -Be $false
    }

    It 'reports the missing file as MISSING in Mismatches' {
        $result = Test-SDCardIntegrity -SDCardPath $script:golden
        $result.Mismatches.Count | Should -BeGreaterThan 0
        $escapedName = [regex]::Escape($script:deletedName)
        ($result.Mismatches | Where-Object { $_ -match $escapedName }).Count |
            Should -BeGreaterThan 0
        $result.Mismatches[0] | Should -Match 'MISSING'
    }
}

# ===========================================================================
# Export invariant: manifest.json must NOT be copied to the target
# ===========================================================================

Describe 'Export-ToTarget — does NOT copy manifest.json to target' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:target = New-TempDir
        $script:sn     = 'TV900000080'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:target -SNs @($script:sn)
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:target
    }

    It 'manifest.json exists in the golden archive source' {
        Test-Path (Join-Path $script:golden 'manifest.json') | Should -Be $true
    }

    It 'manifest.json is NOT present on the exported target' {
        Test-Path (Join-Path $script:target 'manifest.json') | Should -Be $false
    }

    It 'manifest.json is NOT present in any subdirectory of the target' {
        $found = @(Get-ChildItem -LiteralPath $script:target -Recurse -Filter 'manifest.json')
        $found.Count | Should -Be 0
    }
}

# ===========================================================================
# Mode routing: same path validates differently with/without manifest
# ===========================================================================

Describe 'Test-SDCardIntegrity — mode auto-selection based on manifest presence' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000090'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'uses Mode A (manifest-free) when target has no manifest.json' {
        Test-Path (Join-Path $script:sdCard 'manifest.json') | Should -Be $false
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -ReferenceGoldenPath $script:golden
        # Mode A requires an external reference — it was provided
        $result.Passed | Should -Be $true
        $result.ReferenceGolden | Should -Be $script:golden
    }

    It 'switches to Mode B when manifest.json is placed at the target' {
        # Copy manifest to the SD card to trigger Mode B
        Copy-Item (Join-Path $script:golden 'manifest.json') -Destination $script:sdCard -Force
        try {
            $result = Test-SDCardIntegrity -SDCardPath $script:sdCard
            # Mode B self-references
            $result.ReferenceGolden | Should -Be $script:sdCard
            $result.Passed | Should -Be $true
        } finally {
            # Clean up to not break other tests
            Remove-Item (Join-Path $script:sdCard 'manifest.json') -Force
        }
    }
}

# ===========================================================================
# Edge cases
# ===========================================================================

Describe 'Test-SDCardIntegrity — empty or unrecognised SD card path' {

    It 'returns failure with descriptive message for empty directory' {
        $emptyDir = New-TempDir
        try {
            $result = Test-SDCardIntegrity -SDCardPath $emptyDir -SearchPaths @($emptyDir)
            $result.Passed | Should -Be $false
            $result.Mismatches.Count | Should -BeGreaterThan 0
            $result.Mismatches[0] | Should -Match 'No recognisable device data'
        } finally {
            Remove-TempDir $emptyDir
        }
    }

    It 'returns failure for a directory with unrelated files' {
        $junkDir = New-TempDir
        try {
            Set-Content (Join-Path $junkDir 'notes.txt') 'not device data' -Encoding UTF8
            $null = New-Item -ItemType Directory -Path (Join-Path $junkDir 'Photos') -Force
            $result = Test-SDCardIntegrity -SDCardPath $junkDir -SearchPaths @($junkDir)
            $result.Passed | Should -Be $false
            $result.Mismatches[0] | Should -Match 'No recognisable device data'
        } finally {
            Remove-TempDir $junkDir
        }
    }
}

# ===========================================================================
Describe 'Find-MatchingGolden — multiple goldens, correct one selected' {

    BeforeAll {
        $script:gRoot  = New-TempDir
        # Golden A — device TV900000100
        $bA = New-TempDir; $tA = New-TempDir
        $null = New-SyntheticBackup -BackupRoot $bA -Name 'bak_A' `
            -DeviceSNs @('TV900000100') -YearMonth '202408' -EdfBodyBytes 256
        $invA = Get-BackupInventory -BackupRoot $bA
        $tocA = Get-BackupTOC -Inventory $invA
        $script:goldenA = [string](New-GoldenArchive -TOC $tocA -GoldenRoot $script:gRoot -Devices @('TV900000100'))
        Remove-TempDir $bA; Remove-TempDir $tA

        # Golden B — device TV900000101
        $bB = New-TempDir; $tB = New-TempDir
        $null = New-SyntheticBackup -BackupRoot $bB -Name 'bak_B' `
            -DeviceSNs @('TV900000101') -YearMonth '202409' -EdfBodyBytes 256
        $invB = Get-BackupInventory -BackupRoot $bB
        $tocB = Get-BackupTOC -Inventory $invB
        $script:goldenB = [string](New-GoldenArchive -TOC $tocB -GoldenRoot $script:gRoot -Devices @('TV900000101'))
        Remove-TempDir $bB; Remove-TempDir $tB

        # Export golden B to an SD card
        $script:sdCard = New-TempDir
        Export-ToTarget -GoldenPath $script:goldenB -Target $script:sdCard
    }

    AfterAll {
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'selects the correct golden when multiple exist in the search path' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -SearchPaths @($script:gRoot)
        $result.Passed | Should -Be $true
        $result.AutoDiscovered | Should -Be $true
        $result.ReferenceGolden | Should -Be $script:goldenB
    }

    It 'does not match the wrong golden' {
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -SearchPaths @($script:gRoot)
        $result.ReferenceGolden | Should -Not -Be $script:goldenA
    }
}

# ===========================================================================
Describe 'Find-MatchingGolden — graceful handling of missing/invalid paths' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:sdCard = New-TempDir
        $script:sn     = 'TV900000110'
        $script:golden = New-ExportedSD -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -Target $script:sdCard -SNs @($script:sn)
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:sdCard
    }

    It 'does not throw when search path does not exist' {
        $nonExistent = Join-Path ([System.IO.Path]::GetTempPath()) "vbm_nosuchdir_$([System.Guid]::NewGuid().ToString('N'))"
        { Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -SearchPaths @($nonExistent) } | Should -Not -Throw
    }

    It 'returns failure (no match) when search path is empty' {
        $emptySearch = New-TempDir
        try {
            $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
                -SearchPaths @($emptySearch)
            $result.Passed | Should -Be $false
            $result.ReferenceGolden | Should -BeNullOrEmpty
        } finally {
            Remove-TempDir $emptySearch
        }
    }

    It 'succeeds when one of multiple search paths is valid' {
        $nonExistent = Join-Path ([System.IO.Path]::GetTempPath()) "vbm_nosuchdir_$([System.Guid]::NewGuid().ToString('N'))"
        $result = Test-SDCardIntegrity -SDCardPath $script:sdCard `
            -SearchPaths @($nonExistent, $script:gRoot)
        $result.Passed | Should -Be $true
        $result.AutoDiscovered | Should -Be $true
    }
}
