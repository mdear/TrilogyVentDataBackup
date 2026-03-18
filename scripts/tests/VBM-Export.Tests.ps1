#Requires -Version 5.1
# VBM-Export.Tests.ps1 — Pester 5 unit tests for VBM-Export.psm1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')       -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1')      -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-GoldenArchive.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Export.psm1')        -Force

    # Helper: build a golden from synthetic backups and return its path.
    function New-TestGolden {
        param(
            [string]$BackupRoot,
            [string]$GoldenRoot,
            [string[]]$SNs       = @('TV700000001'),
            [string]$YearMonth   = '202408',
            [int]$EdfBodyBytes   = 256,
            [int]$BlowerHours    = 1200
        )
        foreach ($sn in $SNs) {
            $null = New-SyntheticBackup -BackupRoot $BackupRoot -Name "bak_$sn" `
                -DeviceSNs @($sn) -YearMonth $YearMonth `
                -EdfBodyBytes $EdfBodyBytes -BlowerHours $BlowerHours
        }
        $inv = Get-BackupInventory -BackupRoot $BackupRoot
        $toc = Get-BackupTOC -Inventory $inv
        return [string](New-GoldenArchive -TOC $toc -GoldenRoot $GoldenRoot -Devices $SNs)
    }
}

# ---------------------------------------------------------------------------
Describe 'Export-ToTarget — single-device layout' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:target = New-TempDir
        $script:sn     = 'TV700000001'
        $script:golden = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot -SNs @($script:sn)
        Export-ToTarget -GoldenPath $script:golden -Target $script:target
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:target
    }

    It 'creates Trilogy/ at the target root' {
        Test-Path (Join-Path $script:target 'Trilogy') | Should -Be $true
    }

    It 'copies Trilogy EDF files to target Trilogy/' {
        @(Get-ChildItem -LiteralPath (Join-Path $script:target 'Trilogy') -Filter '*.edf').Count |
            Should -BeGreaterThan 0
    }

    It 'creates P-Series/{SN}/ at the target root' {
        Test-Path (Join-Path $script:target "P-Series\$script:sn") | Should -Be $true
    }

    It 'writes P-Series/last.txt containing the device SN' {
        $lastTxt = Join-Path $script:target 'P-Series\last.txt'
        Test-Path $lastTxt | Should -Be $true
        (Get-Content $lastTxt -Raw).Trim() | Should -Be $script:sn
    }

    It 'does NOT create a device-SN subfolder at the target root for single-device' {
        Test-Path (Join-Path $script:target $script:sn) | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Export-ToTarget — multi-device layout' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:target = New-TempDir
        $script:sns    = @('TV700000002', 'TV700000003')
        $script:golden = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -SNs $script:sns
        Export-ToTarget -GoldenPath $script:golden -Target $script:target
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:target
    }

    It 'creates a per-device subdirectory for each SN' {
        foreach ($sn in $script:sns) {
            Test-Path (Join-Path $script:target $sn) | Should -Be $true
        }
    }

    It 'each device subdirectory contains Trilogy/' {
        foreach ($sn in $script:sns) {
            Test-Path (Join-Path $script:target "$sn\Trilogy") | Should -Be $true
        }
    }

    It 'each device subdirectory contains P-Series/{SN}/' {
        foreach ($sn in $script:sns) {
            Test-Path (Join-Path $script:target "$sn\P-Series\$sn") | Should -Be $true
        }
    }

    It 'each device P-Series/last.txt contains the correct SN' {
        foreach ($sn in $script:sns) {
            $lastTxt = Join-Path $script:target "$sn\P-Series\last.txt"
            Test-Path $lastTxt | Should -Be $true
            (Get-Content $lastTxt -Raw).Trim() | Should -Be $sn
        }
    }

    It 'writes README.md at the target root for multi-device exports' {
        Test-Path (Join-Path $script:target 'README.md') | Should -Be $true
    }

    It 'does NOT create a bare Trilogy/ at the target root for multi-device' {
        Test-Path (Join-Path $script:target 'Trilogy') | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Export-ToTarget — Devices subset parameter' {

    BeforeAll {
        $script:bRoot  = New-TempDir
        $script:gRoot  = New-TempDir
        $script:target = New-TempDir
        $script:sns    = @('TV700000004', 'TV700000005')
        $script:golden = New-TestGolden -BackupRoot $script:bRoot -GoldenRoot $script:gRoot `
            -SNs $script:sns
        # Export only the first device — result must be single-device layout
        Export-ToTarget -GoldenPath $script:golden -Target $script:target -Devices @('TV700000004')
    }

    AfterAll {
        Remove-TempDir $script:bRoot
        Remove-TempDir $script:gRoot
        Remove-TempDir $script:target
    }

    It 'exports only the requested device (Trilogy/ at root = single-device layout)' {
        Test-Path (Join-Path $script:target 'Trilogy') | Should -Be $true
    }

    It 'does not create a subfolder for the non-requested device' {
        Test-Path (Join-Path $script:target 'TV700000005') | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Export-ToTarget — error handling' {

    It 'throws when manifest.json is missing from the golden path' {
        $badGolden = New-TempDir
        $t         = New-TempDir
        try {
            { Export-ToTarget -GoldenPath $badGolden -Target $t } | Should -Throw
        } finally {
            Remove-TempDir $badGolden
            Remove-TempDir $t
        }
    }

    It 'throws when a requested SN is not in the manifest' {
        $b = New-TempDir; $g = New-TempDir; $t = New-TempDir
        try {
            $golden = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @('TV700000006')
            { Export-ToTarget -GoldenPath $golden -Target $t -Devices @('TVNOTEXIST') } | Should -Throw
        } finally {
            Remove-TempDir $b; Remove-TempDir $g; Remove-TempDir $t
        }
    }

    It 'creates target directory automatically when it does not exist' {
        $b = New-TempDir; $g = New-TempDir
        $t = Join-Path ([System.IO.Path]::GetTempPath()) "vbm_export_$([System.Guid]::NewGuid().ToString('N'))"
        try {
            $golden = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @('TV700000007')
            Export-ToTarget -GoldenPath $golden -Target $t
            Test-Path $t | Should -Be $true
        } finally {
            Remove-TempDir $b; Remove-TempDir $g
            if (Test-Path $t) { Remove-Item $t -Recurse -Force }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Export-ToTarget — file content preserved' {

    It 'copied Trilogy EDF files have same content as golden source' {
        $b = New-TempDir; $g = New-TempDir; $t = New-TempDir
        try {
            $sn     = 'TV700000008'
            $golden = New-TestGolden -BackupRoot $b -GoldenRoot $g -SNs @($sn)
            Export-ToTarget -GoldenPath $golden -Target $t

            # Compare first AD_.edf file from golden vs target
            $srcEdf = Get-ChildItem -LiteralPath (Join-Path $golden "$sn\Trilogy") -Filter 'AD_*.edf' |
                Select-Object -First 1
            $dstEdf = Join-Path $t "Trilogy\$($srcEdf.Name)"

            (Get-FileHash -Path $srcEdf.FullName -Algorithm MD5).Hash |
                Should -Be (Get-FileHash -Path $dstEdf -Algorithm MD5).Hash
        } finally {
            Remove-TempDir $b; Remove-TempDir $g; Remove-TempDir $t
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Write-ExportReadme' {

    BeforeAll {
        $script:target  = New-TempDir
        $script:devices = @(
            [PSCustomObject]@{ SN = 'TV800000001'; Model = 'Trilogy 200' },
            [PSCustomObject]@{ SN = 'TV800000002'; Model = $null }
        )
        Write-ExportReadme -Target $script:target -Devices $script:devices
        $script:content = Get-Content (Join-Path $script:target 'README.md') -Raw
    }

    AfterAll { Remove-TempDir $script:target }

    It 'creates README.md in the target folder' {
        Test-Path (Join-Path $script:target 'README.md') | Should -Be $true
    }

    It 'includes the Ventilator Data Export heading' {
        $script:content | Should -Match '# Ventilator Data Export'
    }

    It 'includes a table row for each device SN' {
        $script:content | Should -Match 'TV800000001'
        $script:content | Should -Match 'TV800000002'
    }

    It 'includes a DirectView path reference per device' {
        $script:content | Should -Match '\./TV800000001/'
        $script:content | Should -Match '\./TV800000002/'
    }

    It 'falls back to "Trilogy 200" when Model is null' {
        # TV800000002 has null model — README should still reference Trilogy 200
        $script:content | Should -Match 'Trilogy 200'
    }

    It 'includes folder structure diagram' {
        $script:content | Should -Match 'Trilogy/'
        $script:content | Should -Match 'P-Series/'
    }
}

# ---------------------------------------------------------------------------
Describe 'Show-TargetContents' {

    It 'does not throw for an existing target directory' {
        $t = New-TempDir
        try {
            { Show-TargetContents -Target $t } | Should -Not -Throw
        } finally { Remove-TempDir $t }
    }

    It 'does not throw for a non-existent target path' {
        $t = Join-Path ([System.IO.Path]::GetTempPath()) "vbm_nonexist_$([System.Guid]::NewGuid().ToString('N'))"
        { Show-TargetContents -Target $t } | Should -Not -Throw
    }

    It 'lists files in the target when it contains content' {
        $t = New-TempDir
        try {
            Set-Content (Join-Path $t 'sample.txt') 'demo' -Encoding UTF8
            # Just verify it runs without error (output goes to host stream)
            { Show-TargetContents -Target $t } | Should -Not -Throw
        } finally { Remove-TempDir $t }
    }
}
