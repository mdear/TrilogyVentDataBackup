<#
.SYNOPSIS
    Creates a desktop shortcut for VentBackupManager with a custom icon.

.DESCRIPTION
    Run this once to place a professional-looking shortcut on the Desktop.
    The shortcut points to Launch-VentBackupManager.cmd and uses a generated
    .ico file (ventilator waveform on dark monitor background) stored in
    scripts/assets/.

    Requires: Windows PowerShell 5.1+, .NET System.Drawing (ships with Windows).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Install-DesktopShortcut.ps1
#>
[CmdletBinding()]
param(
    [string]$ShortcutName = "Ventilator Backup Manager"
)

$ErrorActionPreference = 'Stop'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootDir    = Split-Path -Parent $scriptDir
$assetsDir  = Join-Path $scriptDir 'assets'
$icoPath    = Join-Path $assetsDir 'VentBackupManager.ico'
$cmdPath    = Join-Path $rootDir   'Launch-VentBackupManager.cmd'

# ── 1. Ensure assets directory exists ──────────────────────────────────────
if (-not (Test-Path $assetsDir)) {
    New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
}

# ── 2. Generate the .ico file if it doesn't exist ─────────────────────────
if (-not (Test-Path $icoPath)) {
    Write-Host "Generating icon..." -ForegroundColor Cyan
    & (Join-Path $scriptDir 'Build-Icon.ps1')
}

# ── 3. Create the desktop shortcut ────────────────────────────────────────
$desktopPath = [Environment]::GetFolderPath('Desktop')
$lnkPath     = Join-Path $desktopPath "$ShortcutName.lnk"

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath       = $cmdPath
$shortcut.WorkingDirectory = $rootDir
$shortcut.IconLocation     = "$icoPath, 0"
$shortcut.Description      = "Launch the Trilogy 200 ventilator backup wizard"
$shortcut.WindowStyle      = 1  # Normal window
$shortcut.Save()

Write-Host ""
Write-Host "  Desktop shortcut created:" -ForegroundColor Green
Write-Host "  $lnkPath" -ForegroundColor White
Write-Host ""
Write-Host "  You can also double-click Launch-VentBackupManager.cmd directly." -ForegroundColor Gray
Write-Host ""
