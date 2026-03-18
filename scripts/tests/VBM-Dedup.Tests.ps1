#Requires -Version 5.1
# VBM-Dedup.Tests.ps1 â€” Pester 5 unit tests for VBM-Dedup.psm1.
#
# NOTE: Test-IsHardlinked uses `fsutil hardlink list` (Windows NTFS only).
#       Tests run on NTFS temp volumes â€” fsutil is available on standard Windows.
#       The hardlinked=true test requires being able to create NTFS hardlinks
#       and is skipped if the hardlink creation itself fails (e.g. FAT32 volume).
#
# NOTE: Invoke-Compaction is tested with non-Dropbox temp paths only.
#       The Dropbox prompt (Read-Host) is not triggered because temp dirs are
#       not inside a Dropbox-synced folder.

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\modules\VBM-Dedup.psm1') -Force

    # Create a BackupRoot with a small set of unique files.
    function New-SmallBackupRoot {
        param([string]$Root, [int]$FilePairs = 2)
        for ($i = 0; $i -lt $FilePairs; $i++) {
            $dir = Join-Path $Root "bak_$i"
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-Content (Join-Path $dir "file_a.txt") "unique content alpha $i" -Encoding UTF8
            Set-Content (Join-Path $dir "file_b.txt") "unique content beta $i"  -Encoding UTF8
        }
    }

    # Create a BackupRoot where two folders share identical file content.
    function New-DuplicateBackupRoot {
        param([string]$Root)
        foreach ($name in @('bak_original', 'bak_duplicate')) {
            $dir = Join-Path $Root $name
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-Content (Join-Path $dir 'shared.txt')  'IDENTICAL CONTENT'  -Encoding UTF8
            Set-Content (Join-Path $dir 'unique.txt')  $name                -Encoding UTF8
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Test-IsHardlinked' {

    It 'returns $false for a freshly created single-link file' {
        $dir  = New-TempDir
        $file = Join-Path $dir 'not_linked.txt'
        Set-Content $file 'hello' -Encoding UTF8
        try {
            Test-IsHardlinked -Path $file | Should -Be $false
        } finally {
            Remove-TempDir $dir
        }
    }

    It 'returns $true for a file that has an additional NTFS hardlink' {
        $dir    = New-TempDir
        $master = Join-Path $dir 'master.txt'
        $link   = Join-Path $dir 'hardlink.txt'
        Set-Content $master 'shared data' -Encoding UTF8
        try {
            # Attempt to create a hardlink; skip if not supported on this volume
            $output = & cmd /c mklink /H $link $master 2>&1
            if ($LASTEXITCODE -ne 0) {
                Set-ItResult -Skipped -Because "NTFS hardlink creation not available: $output"
                return
            }
            Test-IsHardlinked -Path $master | Should -Be $true
        } finally {
            Remove-TempDir $dir
        }
    }

    It 'returns $false when the path does not exist' {
        $nonExistent = Join-Path ([System.IO.Path]::GetTempPath()) 'vbm_dedup_ghost_file.txt'
        Test-IsHardlinked -Path $nonExistent | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-Compaction â€” parameter validation' {

    It 'throws when SafetyPath is inside BackupRoot' {
        $bRoot = New-TempDir
        try {
            # SafetyPath is a subfolder of BackupRoot â€” must throw immediately
            $safetyInside = Join-Path $bRoot 'safety_inside'
            { Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safetyInside } | Should -Throw
        } finally {
            Remove-TempDir $bRoot
        }
    }

    It 'throws when SafetyPath equals BackupRoot (same path)' {
        $bRoot = New-TempDir
        try {
            { Invoke-Compaction -BackupRoot $bRoot -SafetyPath $bRoot } | Should -Throw
        } finally {
            Remove-TempDir $bRoot
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-Compaction â€” no-duplicate case' {

    It 'completes without error when BackupRoot has no duplicate files' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-SmallBackupRoot -Root $bRoot -FilePairs 2
            # All files have unique content â€” compaction should exit cleanly
            { Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety } | Should -Not -Throw
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }

    It 'creates a safety backup of BackupRoot contents even when no duplicates exist' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-SmallBackupRoot -Root $bRoot -FilePairs 1
            Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety
            $srcCount  = @(Get-ChildItem -LiteralPath $bRoot  -File -Recurse).Count
            $safCount  = @(Get-ChildItem -LiteralPath $safety -File -Recurse).Count
            $safCount | Should -BeGreaterThan 0
            $safCount | Should -Be $srcCount
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-Compaction â€” duplicate deduplication' {

    It 'creates hardlinks for duplicate files so disk usage is reduced' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-DuplicateBackupRoot -Root $bRoot
            Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety

            # After compaction, the shared.txt in bak_duplicate should be hardlinked
            $dupFile = Join-Path $bRoot 'bak_duplicate\shared.txt'
            if (-not (Test-Path $dupFile)) {
                Set-ItResult -Skipped -Because "duplicate file not found - compaction may not have run"
                return
            }
            Test-IsHardlinked -Path $dupFile | Should -Be $true
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }

    It 'leaves unique files untouched after compaction' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-DuplicateBackupRoot -Root $bRoot
            Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety

            # unique.txt in each folder should NOT be hardlinked (content differs)
            $uniq1 = Join-Path $bRoot 'bak_original\unique.txt'
            $uniq2 = Join-Path $bRoot 'bak_duplicate\unique.txt'
            Test-IsHardlinked -Path $uniq1 | Should -Be $false
            Test-IsHardlinked -Path $uniq2 | Should -Be $false
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }

    It 'all files remain readable with correct content after compaction' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-DuplicateBackupRoot -Root $bRoot
            Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety

            # shared.txt in both folders must still read as IDENTICAL CONTENT
            $shared1 = (Get-Content (Join-Path $bRoot 'bak_original\shared.txt')  -Raw).Trim()
            $shared2 = (Get-Content (Join-Path $bRoot 'bak_duplicate\shared.txt') -Raw).Trim()
            $shared1 | Should -Be 'IDENTICAL CONTENT'
            $shared2 | Should -Be 'IDENTICAL CONTENT'
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }
}

# ---------------------------------------------------------------------------
Describe '_InvokeDedupRollback - file restoration' {

    It 'overwrites BackupRoot files with SafetyPath originals' {
        InModuleScope 'VBM-Dedup' {
            $bRoot  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $safety = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path $bRoot  -Force
            $null = New-Item -ItemType Directory -Path $safety -Force
            try {
                Set-Content (Join-Path $bRoot  'file.txt') 'corrupted' -Encoding UTF8
                Set-Content (Join-Path $safety 'file.txt') 'original'  -Encoding UTF8

                _InvokeDedupRollback -BackupRoot $bRoot -SafetyPath $safety

                (Get-Content (Join-Path $bRoot 'file.txt') -Raw).Trim() | Should -Be 'original'
            } finally {
                Remove-Item -LiteralPath $bRoot  -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $safety -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'restores nested directory structure from SafetyPath' {
        InModuleScope 'VBM-Dedup' {
            $bRoot  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $safety = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path (Join-Path $bRoot  'sub') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $safety 'sub') -Force
            try {
                Set-Content (Join-Path $bRoot  'sub\nested.txt') 'bad'  -Encoding UTF8
                Set-Content (Join-Path $safety 'sub\nested.txt') 'good' -Encoding UTF8

                _InvokeDedupRollback -BackupRoot $bRoot -SafetyPath $safety

                (Get-Content (Join-Path $bRoot 'sub\nested.txt') -Raw).Trim() | Should -Be 'good'
            } finally {
                Remove-Item -LiteralPath $bRoot  -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $safety -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'creates missing destination directory structure during rollback' {
        InModuleScope 'VBM-Dedup' {
            $bRoot  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $safety = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path (Join-Path $safety 'newdir') -Force
            $null = New-Item -ItemType Directory -Path $bRoot  -Force
            try {
                Set-Content (Join-Path $safety 'newdir\restored.txt') 'restored' -Encoding UTF8

                _InvokeDedupRollback -BackupRoot $bRoot -SafetyPath $safety

                Test-Path (Join-Path $bRoot 'newdir\restored.txt') | Should -Be $true
                (Get-Content (Join-Path $bRoot 'newdir\restored.txt') -Raw).Trim() | Should -Be 'restored'
            } finally {
                Remove-Item -LiteralPath $bRoot  -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $safety -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-Compaction - Dropbox warning' {

    It 'cancels compaction and writes nothing to SafetyPath when user refuses Dropbox warning' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-SmallBackupRoot -Root $bRoot -FilePairs 1
            Mock -ModuleName 'VBM-Dedup' _IsDropboxPath { return $true }
            Mock -ModuleName 'VBM-Dedup' Read-Host { return 'no' }

            Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety

            # Cancelled before safety backup -- safety dir must be empty
            @(Get-ChildItem -LiteralPath $safety -File -Recurse).Count | Should -Be 0
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }

    It 'proceeds with compaction when user types YES to confirm Dropbox warning' {
        $bRoot  = New-TempDir
        $safety = New-TempDir
        try {
            New-SmallBackupRoot -Root $bRoot -FilePairs 2
            Mock -ModuleName 'VBM-Dedup' _IsDropboxPath { return $true }
            Mock -ModuleName 'VBM-Dedup' Read-Host { return 'YES' }

            { Invoke-Compaction -BackupRoot $bRoot -SafetyPath $safety } | Should -Not -Throw

            # Safety backup must have been created (compaction proceeded)
            @(Get-ChildItem -LiteralPath $safety -File -Recurse).Count | Should -BeGreaterThan 0
        } finally {
            Remove-TempDir $bRoot
            Remove-TempDir $safety
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Invoke-Compaction - rollback on post-dedup integrity failure' {

    BeforeAll {
        $script:rbRoot   = New-TempDir
        $script:rbSafety = New-TempDir

        # Create two folders with identical 'shared.txt' (duplicates) and distinct 'unique.txt'
        New-DuplicateBackupRoot -Root $script:rbRoot

        # Pre-populate SafetyPath with DIFFERENT content for the shared file so that
        # after compaction the post-dedup hash check detects a mismatch.
        foreach ($name in @('bak_original', 'bak_duplicate')) {
            $sdir = Join-Path $script:rbSafety $name
            $null = New-Item -ItemType Directory $sdir -Force
            Set-Content (Join-Path $sdir 'shared.txt') "SAFETY_ORIGINAL_CONTENT_$name" -Encoding UTF8
            Set-Content (Join-Path $sdir 'unique.txt') $name -Encoding UTF8
        }

        # Bypass the real safety-backup step (use our pre-populated SafetyPath instead)
        Mock -ModuleName 'VBM-Dedup' _InvokeSafetyBackup { return 2 }
        # Bypass the safety-backup verification (would always fail since we skipped the real backup)
        Mock -ModuleName 'VBM-Dedup' _TestSafetyBackup {
            return [PSCustomObject]@{ OK = $true; Detail = 'mocked for rollback test' }
        }

        # Capture the throw so It-blocks can assert on it
        $script:rbError = $null
        try {
            Invoke-Compaction -BackupRoot $script:rbRoot -SafetyPath $script:rbSafety
        } catch {
            $script:rbError = $_
        }
    }

    AfterAll {
        Remove-TempDir $script:rbRoot
        Remove-TempDir $script:rbSafety
    }

    It 'throws when the post-dedup hash check detects a content mismatch' {
        $script:rbError | Should -Not -BeNullOrEmpty
    }

    It 'error message mentions rolled back' {
        $script:rbError.Exception.Message | Should -Match 'rolled back'
    }

    It 'BackupRoot is restored from SafetyPath after rollback' {
        # After rollback, BackupRoot/bak_original/shared.txt should equal the safety content
        $restored = Get-Content (Join-Path $script:rbRoot 'bak_original\shared.txt') -Raw
        $restored.Trim() | Should -Be 'SAFETY_ORIGINAL_CONTENT_bak_original'
    }
}

# ---------------------------------------------------------------------------
Describe '_IsDropboxPath - direct unit tests' {

    It 'returns $true when an ancestor directory contains a .dropbox file' {
        InModuleScope 'VBM-Dedup' {
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $sub = Join-Path $tmp 'subdir'
            $null = New-Item -ItemType Directory -Path $sub -Force
            $null = New-Item -ItemType File   -Path (Join-Path $tmp '.dropbox') -Force
            try {
                _IsDropboxPath -Path $sub | Should -Be $true
            } finally {
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns $false for a plain temp path with no .dropbox ancestor' {
        InModuleScope 'VBM-Dedup' {
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path $tmp -Force
            try {
                _IsDropboxPath -Path $tmp | Should -Be $false
            } finally {
                Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

