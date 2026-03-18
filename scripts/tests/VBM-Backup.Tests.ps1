#Requires -Version 5.1
# VBM-Backup.Tests.ps1 — Pester 5 unit tests for VBM-Backup.psm1 (Import-SDCard).

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Backup.psm1') -Force

    # Helper: build a minimal fake SD card root using New-SyntheticBackup structure.
    # New-SyntheticBackup produces Trilogy/ + P-Series/ at <root>/<Name>/ — the same
    # layout that Import-SDCard expects at its $Source root.
    function New-FakeSD {
        param(
            [string]$BackupRoot,
            [string]$SN          = 'TVSDFAKE001',
            [string]$YearMonth   = '202408',
            [switch]$NoLastTxt   # omit P-Series/last.txt for testing the no-SN fallback
        )
        $sdPath = New-SyntheticBackup -BackupRoot $BackupRoot -Name 'sd_card' `
            -DeviceSNs @($SN) -YearMonth $YearMonth
        if ($NoLastTxt) {
            $lastTxt = Join-Path $sdPath 'P-Series\last.txt'
            if (Test-Path $lastTxt) { Remove-Item $lastTxt -Force }
        }
        return $sdPath
    }
}

# ---------------------------------------------------------------------------
Describe 'Import-SDCard — destination folder naming' {

    It 'uses backup_YYYY-MM-DD_{SN} when last.txt is present' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $sdRoot = New-FakeSD -BackupRoot $sd -SN 'TVNAME00001'
            $result = Import-SDCard -Source $sdRoot -BackupRoot $bRoot
            $result | Should -Match "backup_\d{4}-\d{2}-\d{2}_TVNAME00001$"
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }

    It 'uses backup_YYYY-MM-DD (no SN) when last.txt is absent' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $sdRoot = New-FakeSD -BackupRoot $sd -SN 'TVNAME00002' -NoLastTxt
            $result = Import-SDCard -Source $sdRoot -BackupRoot $bRoot
            $result | Should -Match "backup_\d{4}-\d{2}-\d{2}$"
            $result | Should -Not -Match 'TVNAME00002'
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }

    It 'appends .1 when the default destination folder already exists' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $sn   = 'TVCOLL00001'
            $date = Get-Date -Format 'yyyy-MM-dd'
            # Pre-create the collision folder
            $null = New-Item -ItemType Directory -Path (Join-Path $bRoot "backup_${date}_$sn") -Force
            $sdRoot = New-FakeSD -BackupRoot $sd -SN $sn
            $result = Import-SDCard -Source $sdRoot -BackupRoot $bRoot
            $result | Should -Match "backup_${date}_${sn}\.1$"
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }

    It 'appends .2 when both the default and .1 collision folders already exist' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $sn   = 'TVCOLL00002'
            $date = Get-Date -Format 'yyyy-MM-dd'
            # Pre-create both collision folders
            $null = New-Item -ItemType Directory -Path (Join-Path $bRoot "backup_${date}_$sn")   -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $bRoot "backup_${date}_$sn.1") -Force
            $sdRoot = New-FakeSD -BackupRoot $sd -SN $sn
            $result = Import-SDCard -Source $sdRoot -BackupRoot $bRoot
            $result | Should -Match "backup_${date}_${sn}\.2$"
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Import-SDCard — file copy and return value' {

    BeforeAll {
        $script:sd     = New-TempDir
        $script:bRoot  = New-TempDir
        $script:sn     = 'TVCOPY00001'
        $script:sdRoot = New-FakeSD -BackupRoot $script:sd -SN $script:sn
        $script:result = Import-SDCard -Source $script:sdRoot -BackupRoot $script:bRoot
    }
    AfterAll {
        Remove-TempDir $script:sd
        Remove-TempDir $script:bRoot
    }

    It 'returns the absolute path to the new backup folder' {
        Test-Path $script:result | Should -Be $true
    }

    It 'copies all source files into the backup folder' {
        $srcCount = @(Get-ChildItem -LiteralPath $script:sdRoot -File -Recurse).Count
        $dstCount = @(Get-ChildItem -LiteralPath $script:result -File -Recurse).Count
        $dstCount | Should -Be $srcCount
    }

    It 'destination files have the same content as their source counterparts' {
        # Sample the first EDF file for a hash comparison
        $srcEdf = Get-ChildItem -LiteralPath $script:sdRoot -Filter '*.edf' -Recurse |
            Select-Object -First 1
        $rel    = $srcEdf.FullName.Substring($script:sdRoot.Length).TrimStart('\', '/')
        $dstEdf = Join-Path $script:result $rel
        (Get-FileHash -Path $srcEdf.FullName -Algorithm MD5).Hash |
            Should -Be (Get-FileHash -Path $dstEdf -Algorithm MD5).Hash
    }
}

# ---------------------------------------------------------------------------
Describe 'Import-SDCard — source validation' {

    It 'throws when source has neither Trilogy/ nor P-Series/' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            # Empty source — no Trilogy or P-Series dirs
            { Import-SDCard -Source $sd -BackupRoot $bRoot } | Should -Throw
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }

    It 'succeeds when source has only Trilogy/ (no P-Series/)' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $triPath = Join-Path $sd 'Trilogy'
            $null    = New-Item -ItemType Directory -Path $triPath -Force
            New-SyntheticEdf -Path (Join-Path $triPath 'AD_202408_000.edf') -SN 'TVONLY0001'
            # Should not throw — Trilogy/ alone is sufficient
            { Import-SDCard -Source $sd -BackupRoot $bRoot } | Should -Not -Throw
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Import-SDCard — integrity verification on copy failure' {

    It 'throws and reports hash mismatch when a copied file is corrupted' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $sdRoot = New-FakeSD -BackupRoot $sd -SN 'TVHASH00001'

            # Mock Copy-Item within VBM-Backup scope: copy the file normally then
            # corrupt one byte in the destination to force a hash mismatch.
            Mock Copy-Item -ModuleName 'VBM-Backup' -MockWith {
                param([string]$LiteralPath, [string]$Destination, [switch]$Force)
                # Forward to the real cmdlet first
                Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
                # Then corrupt the destination if it is an EDF file
                if ($Destination -and $Destination -match '\.edf$') {
                    $data = [System.IO.File]::ReadAllBytes($Destination)
                    if ($data.Length -gt 0) {
                        $data[0] = [byte]($data[0] -bxor 0xFF)
                        [System.IO.File]::WriteAllBytes($Destination, $data)
                    }
                }
            }

            { Import-SDCard -Source $sdRoot -BackupRoot $bRoot } | Should -Throw
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }

    It 'retains the backup folder on failure so inspection is possible' {
        $sd    = New-TempDir
        $bRoot = New-TempDir
        try {
            $sdRoot = New-FakeSD -BackupRoot $sd -SN 'TVRETAIN001'
            Mock Copy-Item -ModuleName 'VBM-Backup' -MockWith {
                param([string]$LiteralPath, [string]$Destination, [switch]$Force)
                Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
                if ($Destination -and $Destination -match '\.edf$') {
                    $data = [System.IO.File]::ReadAllBytes($Destination)
                    if ($data.Length -gt 0) {
                        $data[0] = [byte]($data[0] -bxor 0xFF)
                        [System.IO.File]::WriteAllBytes($Destination, $data)
                    }
                }
            }
            try { Import-SDCard -Source $sdRoot -BackupRoot $bRoot } catch {}
            # Backup folder must still exist for post-mortem inspection
            @(Get-ChildItem -LiteralPath $bRoot -Directory).Count | Should -BeGreaterThan 0
        } finally {
            Remove-TempDir $sd; Remove-TempDir $bRoot
        }
    }
}
