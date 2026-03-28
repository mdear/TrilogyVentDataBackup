#Requires -Version 5.1
# VBM-TOCCache.Tests.ps1 — Pester 5 tests for Get-CachedBackupTOC.
# Exercises cache hit, cache miss (changed files), invalidation on change,
# -Force bypass, corrupted-cache recovery, and golden manifest tracking.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Parsers.psm1')  -Force
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Analyzer.psm1') -Force

    # Build a minimal single-backup inventory under a temp root.
    function New-CacheTestRoot {
        $root  = New-TempDir
        $bakD  = Join-Path $root 'bak1'
        $triD  = Join-Path $bakD 'Trilogy'
        $null  = New-Item -ItemType Directory -Path $triD -Force
        # Stub inventory entry (non-golden, no real EDF files needed for cache tests)
        $inv   = @([PSCustomObject]@{
            Name        = 'bak1'
            Path        = $bakD
            HasTrilogy  = $true
            HasPSeries  = $false
            SubBackups  = @()
            IsGolden    = $false
        })
        return [PSCustomObject]@{ Root = $root; Inv = $inv; TrilogyDir = $triD }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — first run (cold cache)' {

    It 'returns a TOC object with Backups and Devices properties' {
        $ctx = New-CacheTestRoot
        try {
            $toc = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv
            $toc                    | Should -Not -BeNullOrEmpty
            $toc.PSObject.Properties['Backups'] | Should -Not -BeNullOrEmpty
            $toc.PSObject.Properties['Devices'] | Should -Not -BeNullOrEmpty
        } finally { Remove-TempDir $ctx.Root }
    }

    It 'writes fingerprint and clixml files to .toc-cache on first run' {
        $ctx = New-CacheTestRoot
        try {
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv
            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            (Test-Path (Join-Path $cacheDir 'toc.fingerprint')) | Should -Be $true
            (Test-Path (Join-Path $cacheDir 'toc.clixml'))       | Should -Be $true
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — cache hit (no changes)' {

    It 'returns a TOC on the second call without rebuilding (cache hit)' {
        $ctx = New-CacheTestRoot
        try {
            # First call builds the cache
            $toc1 = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            # Second call should hit the cache
            $rebuiltCount = 0
            # We detect a cache hit by verifying the fingerprint file timestamp does NOT change
            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            $toc2 = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            # Fingerprint file should not have been rewritten on cache hit
            $ts2 | Should -Be $ts1

            $toc2.PSObject.Properties['Backups'] | Should -Not -BeNullOrEmpty
        } finally { Remove-TempDir $ctx.Root }
    }

    It 'returns the same backup names on cache hit as on first run' {
        $ctx = New-CacheTestRoot
        try {
            $toc1 = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv
            $toc2 = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv
            # Both should expose bak1
            $toc1.Backups.Keys | Should -Contain 'bak1'
            $toc2.Backups.Keys | Should -Contain 'bak1'
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — cache miss (file added)' {

    It 'rebuilds when a new file is added after first run' {
        $ctx = New-CacheTestRoot
        try {
            # Prime the cache
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            # Add a new file to the backup folder to invalidate the fingerprint
            Start-Sleep -Milliseconds 100   # ensure timestamp difference
            $null = New-Item -ItemType File -Path (Join-Path $ctx.TrilogyDir 'dummy.txt') -Force

            # Rebuild the inventory so the new file is seen
            $newInv = @([PSCustomObject]@{
                Name        = 'bak1'
                Path        = (Join-Path $ctx.Root 'bak1')
                HasTrilogy  = $true
                HasPSeries  = $false
                SubBackups  = @()
                IsGolden    = $false
            })

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $newInv

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            # Cache should have been rewritten (fingerprint file timestamp changed)
            $ts2 | Should -BeGreaterThan $ts1
        } finally { Remove-TempDir $ctx.Root }
    }

    It 'rebuilds when a file is removed after first run' {
        $ctx = New-CacheTestRoot
        try {
            # Add a file before first cache build
            $dummyFile = Join-Path $ctx.TrilogyDir 'to-remove.txt'
            $null = New-Item -ItemType File -Path $dummyFile -Force

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100
            Remove-Item -LiteralPath $dummyFile -Force

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            $ts2 | Should -BeGreaterThan $ts1
        } finally { Remove-TempDir $ctx.Root }
    }

    It 'rebuilds when a file is modified after first run' {
        $ctx = New-CacheTestRoot
        try {
            $dummyFile = Join-Path $ctx.TrilogyDir 'modifiable.txt'
            'original' | Set-Content -LiteralPath $dummyFile -Encoding UTF8

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100
            'modified content with more bytes' | Set-Content -LiteralPath $dummyFile -Encoding UTF8

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            $ts2 | Should -BeGreaterThan $ts1
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — -Force flag' {

    It 'always rebuilds when -Force is specified even with a valid cache' {
        $ctx = New-CacheTestRoot
        try {
            # Build and cache
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100

            # Force rebuild
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv -Force

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            $ts2 | Should -BeGreaterThan $ts1
        } finally { Remove-TempDir $ctx.Root }
    }

    It 'still returns a valid TOC when -Force rebuilds' {
        $ctx = New-CacheTestRoot
        try {
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv
            $toc  = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv -Force
            $toc                    | Should -Not -BeNullOrEmpty
            $toc.Backups.Keys       | Should -Contain 'bak1'
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — corrupted cache recovery' {

    It 'rebuilds gracefully when the clixml file is corrupt' {
        $ctx = New-CacheTestRoot
        try {
            # Build valid cache
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            # Corrupt the clixml
            $clixmlFile = Join-Path $ctx.Root '.toc-cache\toc.clixml'
            'THIS IS NOT VALID XML' | Set-Content -LiteralPath $clixmlFile -Encoding UTF8

            # Should recover without throwing
            $script:toc = $null
            { $script:toc = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv } | Should -Not -Throw
            $script:toc | Should -Not -BeNullOrEmpty
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — README.md changes excluded from fingerprint' {

    It 'does not rebuild when a README.md inside a backup folder is written or modified' {
        $ctx = New-CacheTestRoot
        try {
            # Prime the cache
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100
            # Write / overwrite a README.md inside the backup folder (simulates
            # Write-ContaminationReadme stamping a new timestamp-containing README)
            $backupPath = $ctx.Inv[0].Path
            "# Report\n\nGenerated: $(Get-Date)" | Set-Content `
                -LiteralPath (Join-Path $backupPath 'README.md') -Encoding UTF8

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            # Fingerprint must NOT change — README.md is excluded from the hash
            $ts2 | Should -Be $ts1
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — golden entries excluded from fingerprint' {

    It 'does not rebuild when non-manifest files inside a golden folder change' {
        $ctx = New-CacheTestRoot
        try {
            # Create a fake golden folder in the root
            $goldenDir = Join-Path $ctx.Root '_golden_20260101'
            $null = New-Item -ItemType Directory -Path $goldenDir -Force
            '{}' | Set-Content -LiteralPath (Join-Path $goldenDir 'manifest.json') -Encoding UTF8

            # Produce an inventory with the golden marked as IsGolden=$true
            $invWithGolden = @(
                $ctx.Inv[0],
                [PSCustomObject]@{
                    Name        = '_golden_20260101'
                    Path        = $goldenDir
                    HasTrilogy  = $false
                    HasPSeries  = $false
                    SubBackups  = @()
                    IsGolden    = $true
                }
            )

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $invWithGolden

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100
            # Modify a file inside the golden folder
            'extra data' | Set-Content -LiteralPath (Join-Path $goldenDir 'extra.txt') -Encoding UTF8

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $invWithGolden

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            # Fingerprint should NOT have changed — internal golden file changes are ignored
            $ts2 | Should -Be $ts1
        } finally { Remove-TempDir $ctx.Root }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-CachedBackupTOC — new golden invalidates fingerprint' {

    It 'rebuilds when a new golden archive (manifest.json) is added to the inventory' {
        $ctx = New-CacheTestRoot
        try {
            # Prime cache with regular backup only
            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $ctx.Inv

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100

            # Create a new golden directory + manifest.json
            $goldenDir = Join-Path $ctx.Root '_golden_20260101'
            $null = New-Item -ItemType Directory -Path $goldenDir -Force
            '{"goldenSequence":1}' | Set-Content -LiteralPath (Join-Path $goldenDir 'manifest.json') -Encoding UTF8

            $invWithGolden = @(
                $ctx.Inv[0],
                [PSCustomObject]@{
                    Name        = '_golden_20260101'
                    Path        = $goldenDir
                    HasTrilogy  = $false
                    HasPSeries  = $false
                    SubBackups  = @()
                    IsGolden    = $true
                }
            )

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $invWithGolden

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            # Fingerprint MUST change — a new golden was introduced
            $ts2 | Should -BeGreaterThan $ts1
        } finally { Remove-TempDir $ctx.Root }
    }

    It 'rebuilds when an existing golden manifest.json is modified' {
        $ctx = New-CacheTestRoot
        try {
            $goldenDir = Join-Path $ctx.Root '_golden_20260101'
            $null = New-Item -ItemType Directory -Path $goldenDir -Force
            $manifestPath = Join-Path $goldenDir 'manifest.json'
            '{"goldenSequence":1}' | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            $invWithGolden = @(
                $ctx.Inv[0],
                [PSCustomObject]@{
                    Name        = '_golden_20260101'
                    Path        = $goldenDir
                    HasTrilogy  = $false
                    HasPSeries  = $false
                    SubBackups  = @()
                    IsGolden    = $true
                }
            )

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $invWithGolden

            $cacheDir = Join-Path $ctx.Root '.toc-cache'
            $fpFile   = Join-Path $cacheDir 'toc.fingerprint'
            $ts1      = (Get-Item $fpFile).LastWriteTimeUtc

            Start-Sleep -Milliseconds 100
            # Simulate Update-GoldenArchive rewriting the manifest (seq 2)
            '{"goldenSequence":2}' | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            $null = Get-CachedBackupTOC -BackupRoot $ctx.Root -Inventory $invWithGolden

            $ts2 = (Get-Item $fpFile).LastWriteTimeUtc
            $ts2 | Should -BeGreaterThan $ts1
        } finally { Remove-TempDir $ctx.Root }
    }
}
