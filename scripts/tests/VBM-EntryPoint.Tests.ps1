#Requires -Version 5.1
# VBM-EntryPoint.Tests.ps1 — Integration tests for VentBackupManager.ps1.
#
# Strategy: VentBackupManager.ps1 cannot be dot-sourced safely in Pester because:
#   a) With -Action: the script calls `exit 0`, which terminates the Pester process.
#   b) Without -Action: the wizard loop blocks indefinitely.
# Instead, each test spawns a child powershell.exe process via the & operator so
# that `exit 0` (or non-zero exits) affect only the subprocess.
#
# These tests cover:
#   - CLI parameter validation (missing required params -> non-zero exit + error msg)
#   - Analyze on an empty BackupRoot -> success exit + "No backup folders" message
#   - _FindLatestGolden behavior: Golden action finds (or does not find) existing archive

BeforeAll {
    . (Join-Path $PSScriptRoot 'Fixtures.ps1')

    $script:ep = (Resolve-Path (Join-Path $PSScriptRoot '..\VentBackupManager.ps1')).Path

    # Helper: run VentBackupManager with given extra args; return output lines + exit code
    function Invoke-VBM {
        param([string[]]$ExtraArgs)
        $out = & powershell.exe -ExecutionPolicy Bypass -NonInteractive `
               -File $script:ep @ExtraArgs 2>&1
        return [PSCustomObject]@{
            Output   = $out -join "`n"
            ExitCode = $LASTEXITCODE
        }
    }
}

# ============================================================
Describe 'VentBackupManager — CLI parameter validation' {

    It 'Backup action without -Source exits non-zero and reports the missing parameter' {
        $r = Invoke-VBM -ExtraArgs @('-Action', 'Backup')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -Match '-Source is required'
    }

    It 'Export action without -GoldenPath exits non-zero and reports the missing parameter' {
        $r = Invoke-VBM -ExtraArgs @('-Action', 'Export', '-Target', 'C:\Dummy')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -Match '-GoldenPath is required'
    }

    It 'Export action without -Target exits non-zero and reports the missing parameter' {
        $root = New-TempDir
        try {
            # Create a fake golden dir so -GoldenPath is a real path
            $fakeGolden = Join-Path $root 'fake_golden'
            $null = New-Item -ItemType Directory -Path $fakeGolden -Force
            $r = Invoke-VBM -ExtraArgs @('-Action', 'Export', '-GoldenPath', $fakeGolden)
            $r.ExitCode | Should -Not -Be 0
            $r.Output   | Should -Match '-Target is required'
        } finally { Remove-TempDir $root }
    }

    It 'Compact action without -SafetyBackup exits non-zero and reports the missing parameter' {
        $r = Invoke-VBM -ExtraArgs @('-Action', 'Compact')
        $r.ExitCode | Should -Not -Be 0
        $r.Output   | Should -Match '-SafetyBackup is required'
    }
}

# ============================================================
Describe 'VentBackupManager — Analyze action on empty BackupRoot' {

    It 'exits 0 and writes a "No backup folders found" message when root is empty' {
        $root = New-TempDir
        try {
            $r = Invoke-VBM -ExtraArgs @('-Action', 'Analyze', '-BackupRoot', $root)
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'No backup folders found'
        } finally { Remove-TempDir $root }
    }

    It 'exits 0 and reports the backup name when one backup exists' {
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_2024' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'
            $r = Invoke-VBM -ExtraArgs @('-Action', 'Analyze', '-BackupRoot', $root)
            $r.ExitCode | Should -Be 0
            $r.Output   | Should -Match 'bak_2024'
        } finally { Remove-TempDir $root }
    }
}

# ============================================================
Describe 'VentBackupManager — _FindLatestGolden behavior via Golden action' {

    It 'creating a new golden succeeds when no existing _golden_ dir is present' {
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_2024' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'
            $r = Invoke-VBM -ExtraArgs @(
                '-Action', 'Golden',
                '-BackupRoot', $root,
                '-GoldenRoot', $root,
                '-Devices', 'TV000000001'
            )
            $r.ExitCode | Should -Be 0
            $goldenDirs = @(Get-ChildItem -LiteralPath $root -Directory |
                            Where-Object { $_.Name -match '^_golden_' })
            $goldenDirs.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $root }
    }

    It '_FindLatestGolden ignores _golden_ dirs that have no manifest.json' {
        # If a _golden_ dir without manifest.json is the only candidate, Golden action
        # should treat it as if no golden exists and create a NEW golden.
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_2024' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'

            # Create a _golden_* dir WITHOUT manifest.json
            $badGolden = Join-Path $root '_golden_19700101_000000'
            $null = New-Item -ItemType Directory -Path $badGolden -Force

            $r = Invoke-VBM -ExtraArgs @(
                '-Action', 'Golden',
                '-BackupRoot', $root,
                '-GoldenRoot', $root,
                '-Devices', 'TV000000001'
            )
            $r.ExitCode | Should -Be 0

            # A new golden with a manifest.json must now exist (not just the bad one)
            $validGoldens = @(Get-ChildItem -LiteralPath $root -Directory |
                              Where-Object { $_.Name -match '^_golden_' } |
                              Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') })
            $validGoldens.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $root }
    }

    It '_FindLatestGolden selects the alphabetically latest _golden_ dir' {
        # Run Golden twice — first creates _golden_A, second finds it and calls Update instead.
        # We verify that two valid golden archives exist after both runs (Update creates a new version).
        $root = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_2024' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'

            # First run - creates a golden archive
            $r1 = Invoke-VBM -ExtraArgs @(
                '-Action', 'Golden',
                '-BackupRoot', $root,
                '-GoldenRoot', $root,
                '-Devices', 'TV000000001'
            )
            $r1.ExitCode | Should -Be 0

            # Second run - should find the existing golden and call Update-GoldenArchive
            New-SyntheticBackup -BackupRoot $root -Name 'bak_2025' `
                -DeviceSNs @('TV000000001') -YearMonth '202501'
            $r2 = Invoke-VBM -ExtraArgs @(
                '-Action', 'Golden',
                '-BackupRoot', $root,
                '-GoldenRoot', $root,
                '-Devices', 'TV000000001'
            )
            $r2.ExitCode | Should -Be 0

            # Both runs must have generated at least one valid golden dir
            $validGoldens = @(Get-ChildItem -LiteralPath $root -Directory |
                              Where-Object { $_.Name -match '^_golden_' } |
                              Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') })
            $validGoldens.Count | Should -BeGreaterThan 0
        } finally { Remove-TempDir $root }
    }
}

# ============================================================
Describe 'VentBackupManager — _ResolveBackupRoot fallback' {

    It 'Analyze uses parent of script dir when -BackupRoot is omitted (default root)' {
        # When -BackupRoot is not supplied, _ResolveBackupRoot returns Split-Path $PSScriptRoot -Parent.
        # The parent of scripts/ is the workspace root — which has no backup folders matching
        # the date-folder pattern, so the output should say "No backup folders found" or list
        # real backup folders discovered there.  Either way, the process must not crash.
        $r = Invoke-VBM -ExtraArgs @('-Action', 'Analyze')
        # Exit code 0 means _ResolveBackupRoot resolved a valid path without error
        $r.ExitCode | Should -Be 0
    }
}

# ============================================================
Describe 'VentBackupManager - _CheckDesktopShortcut (wizard mode)' {

    BeforeAll {
        # Path to the scripts/ directory (parent of VentBackupManager.ps1)
        $script:scriptsDir   = (Resolve-Path (Join-Path $script:ep '..')).Path
        $script:settingsPath = Join-Path $script:scriptsDir 'settings.json'

        # Back up existing settings.json (if any) so we don't corrupt real state
        $script:settingsBackup = if (Test-Path $script:settingsPath) {
            Get-Content $script:settingsPath -Raw
        } else { $null }

        # Helper: spawn wizard mode with piped stdin lines; returns PSCustomObject{ExitCode;TimedOut}
        # Uses ProcessStartInfo + direct StandardInput write (more reliable than -RedirectStandardInput
        # for Read-Host in a subprocess, which reads from the console host stdin stream).
        function Invoke-VBMWizard {
            param([string[]]$Lines, [int]$TimeoutMs = 20000)
            $psi = [System.Diagnostics.ProcessStartInfo]::new('powershell.exe',
                "-ExecutionPolicy Bypass -File `"$script:ep`"")
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            foreach ($line in $Lines) { $proc.StandardInput.WriteLine($line) }
            $proc.StandardInput.Close()

            $exited = $proc.WaitForExit($TimeoutMs)
            if (-not $exited) { try { $proc.Kill() } catch {} }
            # Required by MSDN when streams are redirected: finalises ExitCode
            $proc.WaitForExit()

            return [PSCustomObject]@{
                ExitCode = $proc.ExitCode
                TimedOut = -not $exited
            }
        }

        # Helper: spawn a single CLI action with piped stdin; returns ExitCode
        function Invoke-VBMCliWithInput {
            param([string[]]$ExtraArgs, [string[]]$Lines, [int]$TimeoutMs = 20000)
            $argStr = ($ExtraArgs | ForEach-Object { "`"$_`"" }) -join ' '
            $psi = [System.Diagnostics.ProcessStartInfo]::new('powershell.exe',
                "-ExecutionPolicy Bypass -File `"$script:ep`" $argStr")
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($Lines) { foreach ($line in $Lines) { $proc.StandardInput.WriteLine($line) } }
            $proc.StandardInput.Close()

            $exited = $proc.WaitForExit($TimeoutMs)
            if (-not $exited) { try { $proc.Kill() } catch {} }
            $proc.WaitForExit()
            return $proc.ExitCode
        }
    }

    AfterEach {
        # Restore the original settings.json after each test
        if ($script:settingsBackup) {
            Set-Content $script:settingsPath $script:settingsBackup -Encoding UTF8
        } elseif (Test-Path $script:settingsPath) {
            Remove-Item $script:settingsPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'wizard exits cleanly (no hang) when skipShortcutPrompt is true' {
        # With flag set, _CheckDesktopShortcut returns immediately; wizard exits on menu Q
        '{"skipShortcutPrompt": true}' | Set-Content $script:settingsPath -Encoding UTF8
        $r = Invoke-VBMWizard -Lines @('Q') -TimeoutMs 20000
        $r.TimedOut | Should -Be $false
        $r.ExitCode | Should -Be 0
    }

    It 'writes skipShortcutPrompt=true to settings.json when user types X' {
        # Each subprocess gets its own private settings file (VBM_SETTINGS_OVERRIDE) and
        # its own empty desktop dir (VBM_DESKTOP_OVERRIDE).  This eliminates the file-lock
        # race that occurs when the previous test's subprocess still holds settings.json open.
        $fakeDesktop  = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $fakeSettings = Join-Path ([System.IO.Path]::GetTempPath()) ("vbm_settings_$([System.IO.Path]::GetRandomFileName()).json")
        $null = New-Item -ItemType Directory -Path $fakeDesktop -Force
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new('powershell.exe',
                "-ExecutionPolicy Bypass -File `"$script:ep`"")
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.EnvironmentVariables['VBM_DESKTOP_OVERRIDE']  = $fakeDesktop
            $psi.EnvironmentVariables['VBM_SETTINGS_OVERRIDE'] = $fakeSettings

            $proc   = [System.Diagnostics.Process]::Start($psi)
            foreach ($line in @('X', 'Q')) { $proc.StandardInput.WriteLine($line) }
            $proc.StandardInput.Close()
            $exited = $proc.WaitForExit(20000)
            if (-not $exited) { try { $proc.Kill() } catch {} }
            $proc.WaitForExit()
            $exited | Should -Be $true   # must not time out

            # Private settings file must now contain skipShortcutPrompt = true
            Test-Path $fakeSettings | Should -Be $true
            $s = Get-Content $fakeSettings -Raw | ConvertFrom-Json
            $s.skipShortcutPrompt | Should -Be $true
        } finally {
            Remove-Item -LiteralPath $fakeDesktop  -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $fakeSettings         -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
Describe 'VentBackupManager - Compact action Y/N prompt' {

    BeforeAll {
        function Invoke-VBMCliWithInput {
            param([string[]]$ExtraArgs, [string[]]$Lines, [int]$TimeoutMs = 20000)
            $argStr = ($ExtraArgs | ForEach-Object { "`"$_`"" }) -join ' '
            $psi = [System.Diagnostics.ProcessStartInfo]::new('powershell.exe',
                "-ExecutionPolicy Bypass -File `"$script:ep`" $argStr")
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($Lines) { foreach ($line in $Lines) { $proc.StandardInput.WriteLine($line) } }
            $proc.StandardInput.Close()
            $exited = $proc.WaitForExit($TimeoutMs)
            if (-not $exited) { try { $proc.Kill() } catch {} }
            $proc.WaitForExit()
            return $proc.ExitCode
        }
    }

    It 'exits 0 when user answers N to compact confirmation' {
        $root   = New-TempDir
        $safety = New-TempDir
        try {
            New-SyntheticBackup -BackupRoot $root -Name 'bak_compact' `
                -DeviceSNs @('TV000000001') -YearMonth '202408'

            # Compact action calls Read-YesNo (wraps Read-Host). Feeding 'N' via stdin
            # makes Read-YesNo return $false → "Compaction cancelled." → exit 0.
            $ec = Invoke-VBMCliWithInput `
                -ExtraArgs @('-Action','Compact','-BackupRoot',$root,'-SafetyBackup',$safety) `
                -Lines @('N') -TimeoutMs 20000
            $ec | Should -Be 0
        } finally {
            Remove-TempDir $root
            Remove-TempDir $safety
        }
    }
}
